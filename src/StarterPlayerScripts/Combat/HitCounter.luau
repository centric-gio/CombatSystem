--[[
    HitCounter.luau  (Client)
    ──────────────────────────────────────────────────────────
    Left-side hit counter displayed during combat.
    Shows:
      • Running total hit count (large number)
      • "+N" burst for each new hit, fades out upward
      • Combo streak label (resets when combo resets)
      • Colour-coded based on hit type (normal / blocked / parried)

    Architecture:
      HitCounter.new()                → creates the GUI
      :registerHit(wasBlocked, wasParried, damage)
                                      → increments and animates
      :resetStreak()                  → called when combo resets
      :destroy()                      → cleans up
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer

-- ─── PALETTE ─────────────────────────────────────────────────────────────────
local C_BG = Color3.fromRGB(12, 14, 20)
local C_BORDER = Color3.fromRGB(50, 55, 70)
local C_TOTAL = Color3.fromRGB(230, 235, 255)
local C_NORMAL = Color3.fromRGB(100, 210, 255)
local C_BLOCKED = Color3.fromRGB(80, 160, 255)
local C_PARRIED = Color3.fromRGB(255, 235, 80)
local C_LABEL = Color3.fromRGB(120, 130, 160)
local C_STREAK = Color3.fromRGB(255, 180, 50)

-- ─── MODULE ──────────────────────────────────────────────────────────────────
local HitCounter = {}
HitCounter.__index = HitCounter

export type HitCounterType = {
	registerHit: (self: HitCounterType, wasBlocked: boolean, wasParried: boolean, damage: number) -> (),
	resetStreak: (self: HitCounterType) -> (),
	destroy: (self: HitCounterType) -> (),
	getTotalHits: (self: HitCounterType) -> number,
}

function HitCounter.new(): HitCounterType
	local self = setmetatable({
		_totalHits = 0,
		_streakHits = 0,
	}, HitCounter)

	local playerGui = LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui

	local gui = Instance.new("ScreenGui")
	gui.Name = "HitCounterGui"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 12
	gui.IgnoreGuiInset = true
	gui.Parent = playerGui
	self._gui = gui

	-- ── Main card (left side, vertically centred) ─────────
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.Size = UDim2.new(0, 120, 0, 100)
	card.Position = UDim2.new(0, 16, 0.5, -50)
	card.BackgroundColor3 = C_BG
	card.BackgroundTransparency = 0.15
	card.BorderSizePixel = 0
	card.Parent = gui
	self._card = card

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = card

	local stroke = Instance.new("UIStroke")
	stroke.Color = C_BORDER
	stroke.Thickness = 1
	stroke.Transparency = 0.4
	stroke.Parent = card

	-- "HITS" label
	local topLabel = Instance.new("TextLabel")
	topLabel.Size = UDim2.new(1, 0, 0, 20)
	topLabel.Position = UDim2.new(0, 0, 0, 8)
	topLabel.BackgroundTransparency = 1
	topLabel.TextColor3 = C_LABEL
	topLabel.Text = "HITS"
	topLabel.Font = Enum.Font.GothamBold
	topLabel.TextSize = 11
	topLabel.Parent = card

	-- Big hit number
	local totalLabel = Instance.new("TextLabel")
	totalLabel.Name = "Total"
	totalLabel.Size = UDim2.new(1, 0, 0, 48)
	totalLabel.Position = UDim2.new(0, 0, 0, 22)
	totalLabel.BackgroundTransparency = 1
	totalLabel.TextColor3 = C_TOTAL
	totalLabel.Text = "0"
	totalLabel.Font = Enum.Font.Code
	totalLabel.TextSize = 42
	totalLabel.Parent = card
	self._totalLabel = totalLabel

	-- Streak sub-label
	local streakLabel = Instance.new("TextLabel")
	streakLabel.Name = "Streak"
	streakLabel.Size = UDim2.new(1, 0, 0, 18)
	streakLabel.Position = UDim2.new(0, 0, 0, 72)
	streakLabel.BackgroundTransparency = 1
	streakLabel.TextColor3 = C_STREAK
	streakLabel.Text = ""
	streakLabel.Font = Enum.Font.GothamBold
	streakLabel.TextSize = 11
	streakLabel.Parent = card
	self._streakLabel = streakLabel

	-- Burst frame (for floating "+N" animations — parented to gui, not card)
	self._burstParent = gui

	-- Start hidden; shown on first hit
	card.Visible = false
	self._shown = false

	return self :: HitCounterType
end

-- ─── REGISTER HIT ────────────────────────────────────────────────────────────
function HitCounter:registerHit(wasBlocked: boolean, wasParried: boolean, damage: number)
	self._totalHits += 1
	self._streakHits += 1

	-- Show card if first hit
	if not self._shown then
		self._shown = true
		self._card.Visible = true
		-- Pop-in scale animation
		self._card.Size = UDim2.new(0, 100, 0, 80)
		TweenService:Create(self._card, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Size = UDim2.new(0, 120, 0, 100),
		}):Play()
	end

	-- Update total label with a quick scale pulse
	self._totalLabel.Text = tostring(self._totalHits)
	TweenService:Create(self._totalLabel, TweenInfo.new(0.06, Enum.EasingStyle.Quad), {
		TextTransparency = 0,
		TextColor3 = if wasParried then C_PARRIED elseif wasBlocked then C_BLOCKED else C_NORMAL,
	}):Play()

	-- Streak label
	if self._streakHits >= 3 then
		self._streakLabel.Text = ("× %d STREAK"):format(self._streakHits)
	else
		self._streakLabel.Text = ""
	end

	-- ── Floating "+N" burst ───────────────────────────────
	local hitColor = if wasParried then C_PARRIED elseif wasBlocked then C_BLOCKED else C_NORMAL
	self:_spawnBurst("+" .. tostring(damage), hitColor)
end

-- ─── RESET STREAK ────────────────────────────────────────────────────────────
function HitCounter:resetStreak()
	self._streakHits = 0
	self._streakLabel.Text = ""
end

-- ─── GET TOTAL ───────────────────────────────────────────────────────────────
function HitCounter:getTotalHits(): number
	return self._totalHits
end

-- ─── BURST ANIMATION ─────────────────────────────────────────────────────────
function HitCounter:_spawnBurst(text: string, color: Color3)
	-- Position the burst just to the right of the card
	local burst = Instance.new("TextLabel")
	burst.Size = UDim2.new(0, 80, 0, 24)
	burst.Position = UDim2.new(0, 148, 0.5, -38)
	burst.BackgroundTransparency = 1
	burst.TextColor3 = color
	burst.TextTransparency = 0
	burst.Text = text
	burst.Font = Enum.Font.Code
	burst.TextSize = 20
	burst.Parent = self._burstParent

	-- Float upward and fade out
	TweenService:Create(burst, TweenInfo.new(0.65, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = UDim2.new(0, 148, 0.5, -80),
		TextTransparency = 1,
	}):Play()

	task.delay(0.7, function()
		if burst and burst.Parent then
			burst:Destroy()
		end
	end)
end

-- ─── DESTROY ─────────────────────────────────────────────────────────────────
function HitCounter:destroy()
	self._gui:Destroy()
end

return HitCounter
