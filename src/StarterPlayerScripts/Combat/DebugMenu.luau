--[[
    DebugMenu.luau  (Client)
    ──────────────────────────────────────────────────────────
    Collapsible debug overlay showing real-time combat state.
    Toggle with: L

    Displays:
      • Current FSM state
      • Combo index / total
      • Block meter (numeric + bar)
      • Tool equipped status
      • Air combo armed
      • Last 8 server events (HitConfirmed, BlockSync, etc.)
      • Player position + ping estimate (workspace:GetServerTimeNow)

    Architecture:
      DebugMenu.new(deps) → returns DebugMenuType.
      Call :update(data) every frame from CombatClient heartbeat.
      Call :logEvent(tag, text) from remote handlers.

    Styling: dark terminal aesthetic — intentionally developer-facing.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

-- ─── CONSTANTS ───────────────────────────────────────────────────────────────
local MAX_LOG_ENTRIES = 8

local PALETTE = {
	BG = Color3.fromRGB(12, 14, 20),
	BORDER = Color3.fromRGB(50, 55, 70),
	HEADER = Color3.fromRGB(100, 210, 255),
	LABEL = Color3.fromRGB(140, 148, 170),
	VALUE = Color3.fromRGB(220, 228, 255),
	STATE_IDLE = Color3.fromRGB(100, 210, 120),
	STATE_ATTACK = Color3.fromRGB(255, 170, 60),
	STATE_BLOCK = Color3.fromRGB(80, 160, 255),
	STATE_STUN = Color3.fromRGB(255, 80, 80),
	STATE_DEAD = Color3.fromRGB(120, 40, 40),
	COMBO_FILLED = Color3.fromRGB(255, 200, 60),
	COMBO_EMPTY = Color3.fromRGB(50, 55, 70),
	LOG_NORMAL = Color3.fromRGB(160, 165, 185),
	LOG_HIT = Color3.fromRGB(255, 140, 50),
	LOG_BLOCK = Color3.fromRGB(80, 160, 255),
	LOG_PARRY = Color3.fromRGB(255, 235, 80),
	LOG_BREAK = Color3.fromRGB(255, 55, 55),
	TOOL_ON = Color3.fromRGB(80, 220, 100),
	TOOL_OFF = Color3.fromRGB(200, 70, 70),
}

local STATE_COLORS: { [string]: Color3 } = {
	Idle = PALETTE.STATE_IDLE,
	Attacking = PALETTE.STATE_ATTACK,
	Blocking = PALETTE.STATE_BLOCK,
	BlockStun = PALETTE.STATE_BLOCK,
	Stunned = PALETTE.STATE_STUN,
	Dead = PALETTE.STATE_DEAD,
}

-- ─── MODULE ──────────────────────────────────────────────────────────────────
local DebugMenu = {}
DebugMenu.__index = DebugMenu

export type DebugData = {
	state: string,
	comboIndex: number,
	blockMeter: number,
	blockMax: number,
	toolEquipped: boolean,
	airArmed: boolean,
}

export type DebugMenuType = {
	update: (self: DebugMenuType, data: DebugData) -> (),
	logEvent: (self: DebugMenuType, tag: string, text: string) -> (),
	destroy: (self: DebugMenuType) -> (),
}

-- ─── CONSTRUCTOR ─────────────────────────────────────────────────────────────
function DebugMenu.new(): DebugMenuType
	local self = setmetatable({
		_visible = false,
		_logEntries = {} :: { { tag: string, text: string, time: number } },
		_connections = {} :: { RBXScriptConnection },
	}, DebugMenu)

	-- ── Build GUI ────────────────────────────────────────
	local playerGui = LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui

	local gui = Instance.new("ScreenGui")
	gui.Name = "DebugMenuGui"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 99
	gui.IgnoreGuiInset = true
	gui.Enabled = false
	gui.Parent = playerGui
	self._gui = gui

	-- Main panel: top-right corner, semi-transparent dark card
	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.new(0, 300, 0, 440)
	panel.Position = UDim2.new(1, -316, 0, 12)
	panel.BackgroundColor3 = PALETTE.BG
	panel.BackgroundTransparency = 0.08
	panel.BorderSizePixel = 0
	panel.Parent = gui
	self._panel = panel

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color = PALETTE.BORDER
	stroke.Thickness = 1
	stroke.Transparency = 0.4
	stroke.Parent = panel

	-- ── Header ───────────────────────────────────────────
	local header = self:_makeLabel(panel, "⚔  COMBAT DEBUG", 13, PALETTE.HEADER)
	header.Size = UDim2.new(1, -16, 0, 24)
	header.Position = UDim2.new(0, 8, 0, 6)
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Font = Enum.Font.Code

	-- Divider line
	local div1 = Instance.new("Frame")
	div1.Size = UDim2.new(1, -16, 0, 1)
	div1.Position = UDim2.new(0, 8, 0, 32)
	div1.BackgroundColor3 = PALETTE.BORDER
	div1.BackgroundTransparency = 0.3
	div1.BorderSizePixel = 0
	div1.Parent = panel

	-- ── State row ────────────────────────────────────────
	local stateLabel = self:_makeRow(panel, "STATE", "Idle", 38)
	self._stateValue = stateLabel

	-- ── Combo dots ───────────────────────────────────────
	self:_makeLabel(panel, "COMBO", 11, PALETTE.LABEL).Position = UDim2.new(0, 8, 0, 60)

	local dotsFrame = Instance.new("Frame")
	dotsFrame.Name = "Dots"
	dotsFrame.Size = UDim2.new(0, 130, 0, 14)
	dotsFrame.Position = UDim2.new(0, 62, 0, 62)
	dotsFrame.BackgroundTransparency = 1
	dotsFrame.Parent = panel
	self._dotsFrame = dotsFrame

	local dotsLayout = Instance.new("UIListLayout")
	dotsLayout.FillDirection = Enum.FillDirection.Horizontal
	dotsLayout.Padding = UDim.new(0, 5)
	dotsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	dotsLayout.Parent = dotsFrame

	self._dots = {}
	for i = 1, 5 do -- always 5 dots (COMBO_COUNT)
		local dot = Instance.new("Frame")
		dot.Name = "Dot" .. i
		dot.Size = UDim2.new(0, 16, 0, 14)
		dot.BackgroundColor3 = PALETTE.COMBO_EMPTY
		dot.BorderSizePixel = 0
		dot.Parent = dotsFrame
		local dc = Instance.new("UICorner")
		dc.CornerRadius = UDim.new(0, 3)
		dc.Parent = dot
		self._dots[i] = dot
	end

	-- ── Block meter ──────────────────────────────────────
	self:_makeLabel(panel, "BLOCK", 11, PALETTE.LABEL).Position = UDim2.new(0, 8, 0, 84)

	local blockBg = Instance.new("Frame")
	blockBg.Size = UDim2.new(0, 160, 0, 12)
	blockBg.Position = UDim2.new(0, 62, 0, 85)
	blockBg.BackgroundColor3 = Color3.fromRGB(30, 33, 45)
	blockBg.BorderSizePixel = 0
	blockBg.Parent = panel
	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(0, 3)
	bc.Parent = blockBg

	local blockFill = Instance.new("Frame")
	blockFill.Name = "Fill"
	blockFill.Size = UDim2.new(1, 0, 1, 0)
	blockFill.BackgroundColor3 = PALETTE.STATE_BLOCK
	blockFill.BorderSizePixel = 0
	blockFill.Parent = blockBg
	local bfc = Instance.new("UICorner")
	bfc.CornerRadius = UDim.new(0, 3)
	bfc.Parent = blockFill
	self._blockFill = blockFill

	local blockNum = self:_makeLabel(panel, "100", 10, PALETTE.VALUE)
	blockNum.Position = UDim2.new(0, 228, 0, 84)
	blockNum.Size = UDim2.new(0, 50, 0, 14)
	blockNum.TextXAlignment = Enum.TextXAlignment.Left
	self._blockNum = blockNum

	-- ── Tool equipped ─────────────────────────────────────
	local toolLabel, toolValue = self:_makeTwoCol(panel, "TOOL", "—", 106)
	self._toolValue = toolValue
	self._toolLabel = toolLabel

	-- ── Air combo armed ───────────────────────────────────
	local _, airValue = self:_makeTwoCol(panel, "AIR ARM", "NO", 124)
	self._airValue = airValue

	-- ── Position ──────────────────────────────────────────
	local _, posValue = self:_makeTwoCol(panel, "POS", "—", 142)
	self._posValue = posValue

	-- Divider
	local div2 = Instance.new("Frame")
	div2.Size = UDim2.new(1, -16, 0, 1)
	div2.Position = UDim2.new(0, 8, 0, 162)
	div2.BackgroundColor3 = PALETTE.BORDER
	div2.BackgroundTransparency = 0.3
	div2.BorderSizePixel = 0
	div2.Parent = panel

	-- ── Event log header ─────────────────────────────────
	local logHeader = self:_makeLabel(panel, "EVENT LOG", 11, PALETTE.LABEL)
	logHeader.Position = UDim2.new(0, 8, 0, 167)

	-- Log entries
	self._logLabels = {}
	for i = 1, MAX_LOG_ENTRIES do
		local lbl = self:_makeLabel(panel, "", 10, PALETTE.LOG_NORMAL)
		lbl.Position = UDim2.new(0, 8, 0, 167 + i * 16)
		lbl.Size = UDim2.new(1, -16, 0, 14)
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.Font = Enum.Font.Code
		self._logLabels[i] = lbl
	end

	-- ── Toggle hint ───────────────────────────────────────
	local hint = self:_makeLabel(panel, "L to toggle", 9, PALETTE.LABEL)
	hint.Position = UDim2.new(0, 0, 1, -20)
	hint.Size = UDim2.new(1, 0, 0, 16)
	hint.TextXAlignment = Enum.TextXAlignment.Center
	hint.TextTransparency = 0.4

	-- ── Toggle keybind ────────────────────────────────────
	local togConn = UserInputService.InputBegan:Connect(function(input: InputObject, gp: boolean)
		if gp then
			return
		end
		if input.KeyCode == Enum.KeyCode.L then
			self._visible = not self._visible
			gui.Enabled = self._visible
		end
	end)
	table.insert(self._connections, togConn)

	return self :: DebugMenuType
end

-- ─── UPDATE ──────────────────────────────────────────────────────────────────
function DebugMenu:update(data: DebugData)
	if not self._visible then
		return
	end

	-- State
	local stateColor = STATE_COLORS[data.state] or PALETTE.VALUE
	self._stateValue.Text = data.state
	self._stateValue.TextColor3 = stateColor

	-- Combo dots
	for i, dot in ipairs(self._dots) do
		dot.BackgroundColor3 = if i <= data.comboIndex then PALETTE.COMBO_FILLED else PALETTE.COMBO_EMPTY
	end

	-- Block meter
	local fraction = math.clamp(data.blockMeter / data.blockMax, 0, 1)
	self._blockFill.Size = UDim2.new(fraction, 0, 1, 0)
	local bc2 = if fraction > 0.5
		then PALETTE.STATE_BLOCK
		elseif fraction > 0.25 then Color3.fromRGB(255, 200, 60)
		else Color3.fromRGB(255, 80, 80)
	self._blockFill.BackgroundColor3 = bc2
	self._blockNum.Text = tostring(math.round(data.blockMeter))

	-- Tool
	self._toolValue.Text = if data.toolEquipped then "EQUIPPED ✓" else "NOT EQUIPPED"
	self._toolValue.TextColor3 = if data.toolEquipped then PALETTE.TOOL_ON else PALETTE.TOOL_OFF

	-- Air armed
	self._airValue.Text = if data.airArmed then "ARMED ▲" else "NO"
	self._airValue.TextColor3 = if data.airArmed then PALETTE.COMBO_FILLED else PALETTE.LABEL

	-- Position
	local char = Players.LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
		local p = hrp.Position
		self._posValue.Text = ("%.1f, %.1f, %.1f"):format(p.X, p.Y, p.Z)
	else
		self._posValue.Text = "—"
	end
end

-- ─── LOG EVENT ───────────────────────────────────────────────────────────────
local TAG_COLORS: { [string]: Color3 } = {
	HIT = PALETTE.LOG_HIT,
	BLOCK = PALETTE.LOG_BLOCK,
	PARRY = PALETTE.LOG_PARRY,
	BREAK = PALETTE.LOG_BREAK,
	STATE = PALETTE.LOG_NORMAL,
	FLOAT = Color3.fromRGB(180, 120, 255),
	RAGDOLL = Color3.fromRGB(255, 100, 100),
}

function DebugMenu:logEvent(tag: string, text: string)
	table.insert(self._logEntries, 1, {
		tag = tag,
		text = text,
		time = os.clock(),
	})
	-- Trim
	while #self._logEntries > MAX_LOG_ENTRIES do
		table.remove(self._logEntries)
	end

	-- Redraw labels
	for i, lbl in ipairs(self._logLabels) do
		local entry = self._logEntries[i]
		if entry then
			local age = os.clock() - entry.time
			local prefix = ("[%s] "):format(entry.tag)
			lbl.Text = prefix .. entry.text
			lbl.TextColor3 = TAG_COLORS[entry.tag] or PALETTE.LOG_NORMAL
			lbl.TextTransparency = math.clamp(age / 6, 0, 0.6)
		else
			lbl.Text = ""
		end
	end
end

-- ─── DESTROY ─────────────────────────────────────────────────────────────────
function DebugMenu:destroy()
	for _, conn in ipairs(self._connections) do
		conn:Disconnect()
	end
	table.clear(self._connections)
	self._gui:Destroy()
end

-- ─── PRIVATE HELPERS ─────────────────────────────────────────────────────────

function DebugMenu:_makeLabel(parent: Instance, text: string, size: number, color: Color3): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(1, -16, 0, 16)
	lbl.Position = UDim2.new(0, 8, 0, 0)
	lbl.BackgroundTransparency = 1
	lbl.TextColor3 = color
	lbl.Text = text
	lbl.Font = Enum.Font.GothamBold
	lbl.TextSize = size
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Parent = parent
	return lbl
end

function DebugMenu:_makeRow(parent: Instance, label: string, value: string, yOffset: number): TextLabel
	local lbl = self:_makeLabel(parent, label, 11, PALETTE.LABEL)
	lbl.Size = UDim2.new(0, 50, 0, 16)
	lbl.Position = UDim2.new(0, 8, 0, yOffset)

	local val = self:_makeLabel(parent, value, 12, PALETTE.VALUE)
	val.Size = UDim2.new(0, 200, 0, 16)
	val.Position = UDim2.new(0, 62, 0, yOffset)
	val.Font = Enum.Font.Code
	return val
end

function DebugMenu:_makeTwoCol(parent: Instance, label: string, value: string, yOffset: number): (TextLabel, TextLabel)
	local lbl = self:_makeLabel(parent, label, 11, PALETTE.LABEL)
	lbl.Size = UDim2.new(0, 54, 0, 14)
	lbl.Position = UDim2.new(0, 8, 0, yOffset)

	local val = self:_makeLabel(parent, value, 11, PALETTE.VALUE)
	val.Size = UDim2.new(0, 200, 0, 14)
	val.Position = UDim2.new(0, 68, 0, yOffset)
	val.Font = Enum.Font.Code
	return lbl, val
end

return DebugMenu
