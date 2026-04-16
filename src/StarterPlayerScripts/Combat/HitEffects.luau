--[[
    HitEffects.luau  (Client)  v2 — VFX Edition
    ──────────────────────────────────────────────────────────
    CHANGES FROM v1:
      • All VFX use ParticleEmitter + Attachment placed at the
        hit position / target HRP. Burst-then-destroy pattern:
        Emit(n) then Debris:AddItem after longest particle lifetime.

      • VFX added:
          onHitConfirmed   → spark burst (orange/white shards)
          onBlockHit       → shield ripple (blue ring of particles)
          onBlockBreak     → explosion burst (red + white, bigger)
          onParry          → golden ring + screen flash

      • Sound system unchanged but now also called for NPC hits.
        (CombatClient passes position even when targetChar is nil.)

      • hitFlash unchanged (white flash on character parts).
      • cameraShake unchanged (Humanoid.CameraOffset spring).

    VFX ARCHITECTURE:
      Each effect creates a temporary Part (Anchored, invisible) at
      the world position, attaches a ParticleEmitter, fires a burst,
      then destroys the part after the particle lifetime expires.
      Parts are CanCollide = false, CastShadow = false.
      This pattern is allocation-heavy for high fire rates — at 200
      players these should be pooled. For a test environment it is
      perfectly fine.

    TODO for production:
      • Replace with a pre-allocated EffectPool.
      • Add hit-stop: freeze attacker anim track for 2–3 frames.
      • Add a Beam between attacker hand and hit position for slashes.
]]

local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

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

local _shakeTween: Tween? = nil

-- ─── INTERNAL HELPERS ────────────────────────────────────────────────────────

-- Creates a temporary invisible anchor at a world position, valid for `lifetime` seconds.
local function _makeBurstAnchor(position: Vector3, lifetime: number): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.one
	p.CFrame = CFrame.new(position)
	p.Parent = workspace
	Debris:AddItem(p, lifetime)
	return p
end

-- Creates a ParticleEmitter on an Attachment inside the anchor part,
-- fires a burst of `count` particles, returns the emitter (already fired).
local function _burst(
	anchor: Part,
	count: number,
	color0: Color3,
	color1: Color3,
	size: number,
	speed: NumberRange,
	lifetime: NumberRange,
	spread: number, -- SpreadAngle degrees (half-angle each axis)
	lightEmit: number? -- LightEmission 0–1, optional
): ParticleEmitter
	local att = Instance.new("Attachment")
	att.Parent = anchor

	local pe = Instance.new("ParticleEmitter")
	pe.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, color0),
		ColorSequenceKeypoint.new(1, color1),
	})
	pe.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, size),
		NumberSequenceKeypoint.new(0.4, size * 0.6),
		NumberSequenceKeypoint.new(1, 0),
	})
	pe.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.0),
		NumberSequenceKeypoint.new(0.7, 0.3),
		NumberSequenceKeypoint.new(1, 1.0),
	})
	pe.LightEmission = lightEmit or 0.6
	pe.LightInfluence = 0.3
	pe.Speed = speed
	pe.Lifetime = lifetime
	pe.SpreadAngle = Vector2.new(spread, spread)
	pe.RotSpeed = NumberRange.new(-200, 200)
	pe.Rotation = NumberRange.new(0, 360)
	pe.Rate = 0 -- manual burst only
	pe.Enabled = false
	pe.Parent = att

	pe:Emit(count)
	return pe
end

-- Plays a one-shot sound at a world position (self-cleaning Part).
function HitEffects.playSound(soundId: string, position: Vector3?, volume: number?)
	local anchor = _makeBurstAnchor(position or Vector3.zero, 5)
	anchor.CFrame = CFrame.new(position or Vector3.zero)

	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume or 0.8
	sound.RollOffMaxDistance = 70
	sound.RollOffMinDistance = 5
	sound.Parent = anchor
	sound:Play()

	sound.Ended:Once(function()
		if anchor and anchor.Parent then
			anchor:Destroy()
		end
	end)
end

-- ─── CAMERA SHAKE ────────────────────────────────────────────────────────────

function HitEffects.cameraShake(magnitude: number)
	if _shakeTween then
		_shakeTween:Cancel()
	end

	local char = LocalPlayer.Character
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	humanoid.CameraOffset = Vector3.new(
		math.random(-10, 10) / 100 * magnitude,
		math.random(-10, 10) / 100 * magnitude,
		0
	) * magnitude

	_shakeTween =
		TweenService:Create(humanoid, TweenInfo.new(0.20, Enum.EasingStyle.Elastic), { CameraOffset = Vector3.zero })
	_shakeTween:Play()
end

-- ─── HIT FLASH on target character ───────────────────────────────────────────

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

-- ─── PARRY FLASH ─────────────────────────────────────────────────────────────

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
	frame.BackgroundTransparency = 0.25
	frame.BorderSizePixel = 0
	frame.Parent = gui

	TweenService:Create(frame, TweenInfo.new(0.42, Enum.EasingStyle.Quad), {
		BackgroundTransparency = 1,
	}):Play()

	task.delay(0.5, function()
		gui:Destroy()
	end)
end

-- ─── VFX: NORMAL HIT SPARKS ──────────────────────────────────────────────────
--[[
    Orange/white directional sparks at the hit point.
    Two layers:
      • Main sparks: fast, directional, short lifetime
      • Glow: slow spherical bloom, light emission
]]
function HitEffects.vfxHitSparks(position: Vector3)
	local anchor = _makeBurstAnchor(position, 0.8)

	-- Directional spark shards
	_burst(
		anchor,
		14,
		Color3.fromRGB(255, 160, 40), -- hot orange
		Color3.fromRGB(255, 240, 180), -- pale yellow
		0.18,
		NumberRange.new(14, 28),
		NumberRange.new(0.20, 0.50),
		80,
		0.9
	)

	-- Small white core bloom
	_burst(
		anchor,
		6,
		Color3.fromRGB(255, 255, 255),
		Color3.fromRGB(255, 200, 100),
		0.28,
		NumberRange.new(2, 6),
		NumberRange.new(0.10, 0.25),
		360,
		1.0
	)
end

-- ─── VFX: BLOCK HIT SHIELD RIPPLE ────────────────────────────────────────────
--[[
    Blue shield "ripple" — particles expand outward in a ring.
    Uses SpreadAngle=360 to simulate a disc.
]]
function HitEffects.vfxBlockHit(position: Vector3)
	local anchor = _makeBurstAnchor(position, 0.7)

	-- Ring of blue sparks
	_burst(
		anchor,
		20,
		Color3.fromRGB(100, 180, 255),
		Color3.fromRGB(200, 230, 255),
		0.14,
		NumberRange.new(10, 20),
		NumberRange.new(0.18, 0.45),
		360,
		0.8
	)

	-- Tight centre glow
	_burst(
		anchor,
		5,
		Color3.fromRGB(180, 220, 255),
		Color3.fromRGB(255, 255, 255),
		0.35,
		NumberRange.new(1, 4),
		NumberRange.new(0.12, 0.22),
		45,
		1.0
	)
end

-- ─── VFX: BLOCK BREAK EXPLOSION ──────────────────────────────────────────────
--[[
    Large red + white explosion burst when the block meter hits 0.
    Bigger particles, more count, longer lifetime.
]]
function HitEffects.vfxBlockBreak(position: Vector3)
	local anchor = _makeBurstAnchor(position, 1.2)

	-- Outer red shrapnel ring
	_burst(
		anchor,
		30,
		Color3.fromRGB(255, 50, 50),
		Color3.fromRGB(255, 160, 60),
		0.30,
		NumberRange.new(18, 38),
		NumberRange.new(0.30, 0.80),
		360,
		0.95
	)

	-- Inner white core flash
	_burst(
		anchor,
		12,
		Color3.fromRGB(255, 255, 255),
		Color3.fromRGB(255, 100, 50),
		0.55,
		NumberRange.new(4, 10),
		NumberRange.new(0.15, 0.40),
		180,
		1.0
	)

	-- Fine ember drift (slow, upward bias)
	local att2 = Instance.new("Attachment")
	att2.Parent = anchor

	local embers = Instance.new("ParticleEmitter")
	embers.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 120, 30)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(180, 60, 0)),
	})
	embers.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.08),
		NumberSequenceKeypoint.new(1, 0),
	})
	embers.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	embers.LightEmission = 0.7
	embers.Speed = NumberRange.new(3, 9)
	embers.Lifetime = NumberRange.new(0.6, 1.1)
	embers.SpreadAngle = Vector2.new(70, 70)
	embers.RotSpeed = NumberRange.new(-150, 150)
	embers.Rate = 0
	embers.Enabled = false
	embers.Parent = att2
	embers:Emit(20)
end

-- ─── VFX: PARRY GOLDEN RING ──────────────────────────────────────────────────
--[[
    Expanding golden ring of particles on successful parry.
    Two burst layers: ring disc + radiant core beams.
]]
function HitEffects.vfxParry(position: Vector3)
	local anchor = _makeBurstAnchor(position, 1.0)

	-- Outer golden ring
	_burst(
		anchor,
		28,
		Color3.fromRGB(255, 230, 60),
		Color3.fromRGB(255, 200, 100),
		0.20,
		NumberRange.new(16, 30),
		NumberRange.new(0.28, 0.65),
		360,
		1.0
	)

	-- Inner white radiant core
	_burst(
		anchor,
		10,
		Color3.fromRGB(255, 255, 255),
		Color3.fromRGB(255, 240, 120),
		0.45,
		NumberRange.new(2, 7),
		NumberRange.new(0.15, 0.35),
		180,
		1.0
	)

	-- Long slow streaks (high speed, very low count — "rays")
	_burst(
		anchor,
		6,
		Color3.fromRGB(255, 245, 180),
		Color3.fromRGB(255, 215, 50),
		0.06,
		NumberRange.new(35, 55),
		NumberRange.new(0.40, 0.70),
		360,
		1.0
	)
end

-- ─── PUBLIC EVENT HOOKS ───────────────────────────────────────────────────────

function HitEffects.onSwingStart(_comboIndex: number)
	HitEffects.playSound(SOUND.WHOOSH)
end

--[[
    onHitConfirmed now accepts an optional position as fallback for NPC hits
    where targetChar may be nil. VFX fires regardless; hitFlash only fires
    when a live character model is available.
]]
function HitEffects.onHitConfirmed(targetChar: Model?, magnitude: number, position: Vector3)
	if targetChar then
		HitEffects.hitFlash(targetChar)
	end
	HitEffects.cameraShake(magnitude)
	HitEffects.vfxHitSparks(position)
	HitEffects.playSound(SOUND.HIT, position, 1.0)
end

function HitEffects.onBlockHit(position: Vector3)
	HitEffects.vfxBlockHit(position)
	HitEffects.playSound(SOUND.BLOCK, position, 1.0)
end

function HitEffects.onParry()
	local char = LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local pos = hrp and hrp.Position or Vector3.zero

	HitEffects.parryFlash()
	HitEffects.vfxParry(pos)
	HitEffects.playSound(SOUND.PARRY, pos)
end

function HitEffects.onBlockBreak(position: Vector3)
	HitEffects.cameraShake(0.65)
	HitEffects.vfxBlockBreak(position)
	HitEffects.playSound(SOUND.BLOCK_BREAK, position, 1.3)
end

return HitEffects
