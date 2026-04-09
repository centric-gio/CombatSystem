--[[
    HitEffects.luau  (Client)
    ──────────────────────────────────────────────────────────
    Visual and audio feedback hooks.
    All effects are purely cosmetic — safe to run client-only.

    Currently provides:
      • Screen shake (camera offset impulse via TweenService)
      • Hit flash (brief white highlight on target)
      • Perfect parry flash (full-screen golden flash)
      • Whoosh sound on swing
      • Impact sound on hit confirmation

    TODO: Replace placeholder SoundIds with real assets.
    TODO: Add particle emitters for blood/sparks if desired.
    TODO: Add hit-stop (briefly freeze animation for ~3 frames)
          by setting AnimationTrack.TimePosition on the attacker.
]]

local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

-- ─── SOUND IDS ── TODO: replace with real asset IDs ─────────────────────────
local SOUND = {
	WHOOSH = "rbxassetid://139731037802687",
	HIT = "rbxassetid://139890294541073",
	BLOCK = "rbxassetid://136811265205147",
	PARRY = "rbxassetid://116964347071838",
	BLOCK_BREAK = "rbxassetid://85805517776968",
}

-- ─── MODULE ──────────────────────────────────────────────────────────────────
local HitEffects = {}

-- Internal: original camera CFrame offset (used for shake)
local _shakeOffset = CFrame.new()
local _shakeTween: Tween? = nil

-- ── Camera Shake ─────────────────────────────────────────
-- Simple: tween a CFrame offset then tween it back.
-- For a more advanced shake, replace with a spring or noise approach.
function HitEffects.cameraShake(magnitude: number)
	if _shakeTween then
		_shakeTween:Cancel()
	end

	local randomOffset = CFrame.new(math.random(-10, 10) / 100 * magnitude, math.random(-10, 10) / 100 * magnitude, 0)
		* CFrame.Angles(
			math.rad(math.random(-3, 3) * magnitude * 0.5),
			math.rad(math.random(-3, 3) * magnitude * 0.5),
			0
		)

	-- Apply via a Humanoid camera offset so it doesn't fight the engine.
	local char = LocalPlayer.Character
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	humanoid.CameraOffset = Vector3.new(randomOffset.X, randomOffset.Y, 0) * magnitude

	_shakeTween =
		TweenService:Create(humanoid, TweenInfo.new(0.18, Enum.EasingStyle.Elastic), { CameraOffset = Vector3.zero })
	_shakeTween:Play()
end

-- ── Hit Flash on Target ───────────────────────────────────
-- Briefly sets all BasePart colors to white for 1 frame, then reverts.
function HitEffects.hitFlash(targetCharacter: Model)
	local parts: { BasePart } = {}
	local origColors: { Color3 } = {}

	for _, part in ipairs(targetCharacter:GetDescendants()) do
		if part:IsA("BasePart") then
			table.insert(parts, part)
			table.insert(origColors, part.Color)
			part.Color = Color3.new(1, 1, 1)
		end
	end

	task.delay(0.06, function()
		for i, part in ipairs(parts) do
			if part and part.Parent then
				part.Color = origColors[i]
			end
		end
	end)
end

-- ── Parry Flash (full screen golden overlay) ─────────────
function HitEffects.parryFlash()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
	local existing = playerGui:FindFirstChild("ParryFlashGui")
	if existing then
		existing:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "ParryFlashGui"
	gui.DisplayOrder = 20
	gui.ResetOnSpawn = false
	gui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, 0, 1, 0)
	frame.BackgroundColor3 = Color3.fromRGB(255, 240, 100)
	frame.BackgroundTransparency = 0.3
	frame.BorderSizePixel = 0
	frame.Parent = gui

	TweenService:Create(frame, TweenInfo.new(0.40, Enum.EasingStyle.Quad), { BackgroundTransparency = 1 }):Play()

	task.delay(0.5, function()
		gui:Destroy()
	end)
end

-- ── Play a Sound ─────────────────────────────────────────
-- Plays a one-shot sound at a world position.
function HitEffects.playSound(soundId: string, position: Vector3?, volume: number?)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.Transparency = 1
	part.Size = Vector3.one
	part.CFrame = CFrame.new(position or Vector3.zero)
	part.Parent = workspace

	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume or 0.8
	sound.RollOffMaxDistance = 60
	sound.Parent = part
	sound:Play()

	-- Self-clean after sound ends
	sound.Ended:Once(function()
		part:Destroy()
	end)

	-- Safety destroy in case Ended never fires
	task.delay(5, function()
		if part and part.Parent then
			part:Destroy()
		end
	end)
end

-- ── Convenience wrappers ──────────────────────────────────

function HitEffects.onSwingStart(comboIndex: number)
	HitEffects.playSound(SOUND.WHOOSH)
end

function HitEffects.onHitConfirmed(targetChar: Model, magnitude: number, position: Vector3)
	HitEffects.hitFlash(targetChar)
	HitEffects.cameraShake(magnitude)
	HitEffects.playSound(SOUND.HIT, position, 1.0)
end

function HitEffects.onBlockHit(position: Vector3)
	HitEffects.playSound(SOUND.BLOCK, position, 1.0)
end

function HitEffects.onParry()
	HitEffects.parryFlash()
	HitEffects.playSound(SOUND.PARRY)
end

function HitEffects.onBlockBreak(position: Vector3)
	HitEffects.cameraShake(0.6)
	HitEffects.playSound(SOUND.BLOCK_BREAK, position, 1.2)
end

return HitEffects
