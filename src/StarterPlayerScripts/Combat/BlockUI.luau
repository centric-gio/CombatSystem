--[[
    BlockUI.luau  (Client)
    ──────────────────────────────────────────────────────────
    Renders the block meter as a sleek progress bar.
    Visually:
      • Bar shrinks smoothly left as meter depletes.
      • Turns red below BLOCK_LOW_THRESHOLD %.
      • Flashes a color on block-broken or perfect parry.
      • Pulses when meter is critically low.
      • Fades out when not blocking.

    All instances created programmatically — no external UI file needed.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local CombatConfig = require(game:GetService("ReplicatedStorage").Shared.CombatConfig)

-- ─── COLORS ──────────────────────────────────────────────────────────────────
local COLOR_FULL = Color3.fromRGB(80, 200, 255) -- healthy block: cyan
local COLOR_MID = Color3.fromRGB(255, 200, 60) -- mid block: yellow
local COLOR_LOW = Color3.fromRGB(255, 65, 65) -- critical block: red
local COLOR_BACKING = Color3.fromRGB(20, 20, 20)
local COLOR_BORDER = Color3.fromRGB(255, 255, 255)

-- ─── MODULE ──────────────────────────────────────────────────────────────────
local BlockUI = {}
BlockUI.__index = BlockUI

export type BlockUIType = {
	setMeter: (self: BlockUIType, fraction: number) -> (),
	setVisible: (self: BlockUIType, visible: boolean) -> (),
	flash: (self: BlockUIType, color: Color3) -> (),
	destroy: (self: BlockUIType) -> (),
}

function BlockUI.new(): BlockUIType
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

	-- ── Build ScreenGui ──────────────────────────────────
	local gui = Instance.new("ScreenGui")
	gui.Name = "BlockMeterGui"
	gui.ResetOnSpawn = false -- we manage lifecycle manually
	gui.DisplayOrder = 10
	gui.IgnoreGuiInset = true
	gui.Parent = playerGui

	-- ── Container (anchored bottom-centre) ───────────────
	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.new(0, 280, 0, 22)
	container.Position = UDim2.new(0.5, -140, 1, -80)
	container.BackgroundColor3 = COLOR_BACKING
	container.BackgroundTransparency = 0.3
	container.BorderSizePixel = 0
	container.Parent = gui

	-- Rounded corners
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = container

	-- Border stroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = COLOR_BORDER
	stroke.Thickness = 1.2
	stroke.Transparency = 0.6
	stroke.Parent = container

	-- ── Fill Bar ─────────────────────────────────────────
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(1, -4, 1, -4)
	fill.Position = UDim2.new(0, 2, 0, 2)
	fill.BackgroundColor3 = COLOR_FULL
	fill.BorderSizePixel = 0
	fill.Parent = container

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = fill

	-- ── Shield Label ─────────────────────────────────────
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.new(1, 0, 1, 0)
	label.Position = UDim2.new(0, 0, 0, 0)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextTransparency = 0.2
	label.Font = Enum.Font.GothamBold
	label.TextSize = 11
	label.Text = "BLOCK"
	label.ZIndex = 3
	label.Parent = container

	-- ── Flash Overlay (for parry / block break) ───────────
	local flash = Instance.new("Frame")
	flash.Name = "Flash"
	flash.Size = UDim2.new(1, 0, 1, 0)
	flash.BackgroundColor3 = Color3.new(1, 1, 1)
	flash.BackgroundTransparency = 1
	flash.BorderSizePixel = 0
	flash.ZIndex = 4
	flash.Parent = container

	local flashCorner = Instance.new("UICorner")
	flashCorner.CornerRadius = UDim.new(0, 6)
	flashCorner.Parent = flash

	-- ── Self ─────────────────────────────────────────────
	local self = setmetatable({
		_gui = gui,
		_container = container,
		_fill = fill,
		_label = label,
		_flash = flash,
		_fraction = 1,
		_visible = false,
		_flashTween = nil :: Tween?,
	}, BlockUI)

	-- Start hidden; shown when player starts blocking
	self:setVisible(false)

	return self :: BlockUIType
end

-- ── Set Meter ─────────────────────────────────────────────
function BlockUI:setMeter(fraction: number)
	fraction = math.clamp(fraction, 0, 1)
	self._fraction = fraction

	-- Show the bar whenever it's not full (damaged or being held)
	self:setVisible(true)

	-- Determine fill color based on how depleted the meter is.
	local barColor: Color3
	if fraction > 0.5 then
		barColor = COLOR_FULL:Lerp(COLOR_MID, (1 - fraction) * 2)
	else
		barColor = COLOR_MID:Lerp(COLOR_LOW, (0.5 - fraction) * 2)
	end

	-- Smooth tween for the bar width.
	TweenService:Create(self._fill, TweenInfo.new(CombatConfig.BLOCK_UI_TWEEN_TIME, Enum.EasingStyle.Quad), {
		Size = UDim2.new(fraction, -4, 1, -4),
		BackgroundColor3 = barColor,
	}):Play()

	-- Pulse the container when critically low (< 25%)
	if fraction < 0.25 and fraction > 0 then
		TweenService:Create(
			self._container,
			TweenInfo.new(0.15, Enum.EasingStyle.Sine, Enum.EasingDirection.Out, 0, true),
			{ BackgroundTransparency = 0.05 }
		):Play()
	end

	-- If meter is full and not being held, hide after a moment
	if fraction >= 1 then
		task.delay(0.8, function()
			if self._fraction >= 1 then
				self:setVisible(false)
			end
		end)
	end
end

-- ── Flash Effect ──────────────────────────────────────────
function BlockUI:flash(color: Color3)
	if self._flashTween then
		self._flashTween:Cancel()
	end

	self._flash.BackgroundColor3 = color
	self._flash.BackgroundTransparency = 0.0

	self._flashTween =
		TweenService:Create(self._flash, TweenInfo.new(0.35, Enum.EasingStyle.Quad), { BackgroundTransparency = 1 })
	self._flashTween:Play()
end

-- ── Visibility ────────────────────────────────────────────
function BlockUI:setVisible(visible: boolean)
	self._visible = visible
	self._container.Visible = visible
end

-- ── Cleanup ───────────────────────────────────────────────
function BlockUI:destroy()
	self._gui:Destroy()
end

return BlockUI
