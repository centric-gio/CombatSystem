--[[
    CombatConfig.luau
    ──────────────────────────────────────────────────────────
    Single source of truth for ALL combat numbers.
    Designers tweak here; no logic changes needed.

    HOW TO REPLACE ANIMATIONS:
      1. Upload each animation to Roblox.
      2. Copy the asset ID (e.g. 123456789).
      3. Replace the placeholder strings below with
         "rbxassetid://123456789".
      4. Ensure animations are authored for the R15 rig
         (or your custom rig with matching Motor6D names).
]]

-- ─── ANIMATION IDS ───────────────────────────────────────────────────────────
-- TODO: Replace with real asset IDs before shipping.
local ANIM = {
	COMBO_1 = "rbxassetid://0000000001",
	COMBO_2 = "rbxassetid://0000000002",
	COMBO_3 = "rbxassetid://0000000003",
	COMBO_4 = "rbxassetid://0000000004", -- finisher
	BLOCK_IDLE = "rbxassetid://83146853780823",
	STUNNED = "rbxassetid://100679173821281",
	BLOCK_BROKEN = "rbxassetid://91395768560395",
}

-- ─── MODULE ──────────────────────────────────────────────────────────────────
local CombatConfig = {}

-- ── Combo ────────────────────────────────────────────────
CombatConfig.COMBO_COUNT = 4 -- M1s before auto-reset
CombatConfig.COMBO_RESET_WINDOW = 1.8 -- seconds of inactivity before combo resets

-- Per-hit data — feel free to tune per-hit independently.
-- totalDuration should equal roughly hitActiveEnd + recoveryTime.
-- inputWindowStart controls when the player can buffer the NEXT M1.
-- A small inputWindowStart = very forgiving chain timing (TSB style).
-- A larger inputWindowStart = tighter chain timing (Deepwoken style).
CombatConfig.COMBO_HITS = {
	[1] = {
		damage = 10,
		blockMeterDamage = 14,
		isHeavy = false,
		hitboxSize = Vector3.new(5.5, 5.5, 5.5),
		hitboxOffset = Vector3.new(0, 0, -2.5),
		hitActiveStart = 0.10,
		hitActiveEnd = 0.25,
		totalDuration = 0.52,
		inputWindowStart = 0.22, -- can chain after 0.22s
		animationId = ANIM.COMBO_1,
		knockback = Vector3.new(0, 2, -12),
		cameraShakeMagnitude = 0.30,
	},
	[2] = {
		damage = 10,
		blockMeterDamage = 14,
		isHeavy = false,
		hitboxSize = Vector3.new(5.5, 5.5, 5.5),
		hitboxOffset = Vector3.new(0, 0, -2.5),
		hitActiveStart = 0.08,
		hitActiveEnd = 0.22,
		totalDuration = 0.48,
		inputWindowStart = 0.20,
		animationId = ANIM.COMBO_2,
		knockback = Vector3.new(0, 2, -12),
		cameraShakeMagnitude = 0.30,
	},
	[3] = {
		damage = 12,
		blockMeterDamage = 20,
		isHeavy = false,
		hitboxSize = Vector3.new(6.0, 5.5, 6.0),
		hitboxOffset = Vector3.new(0, 0, -2.8),
		hitActiveStart = 0.10,
		hitActiveEnd = 0.28,
		totalDuration = 0.56,
		inputWindowStart = 0.24,
		animationId = ANIM.COMBO_3,
		knockback = Vector3.new(0, 3, -15),
		cameraShakeMagnitude = 0.45,
	},
	[4] = {
		-- Finisher: heavy, big knockback, long recovery — punishes whiffing.
		damage = 22,
		blockMeterDamage = 38,
		isHeavy = true, -- cannot be perfect-parried
		hitboxSize = Vector3.new(7.0, 6.0, 7.0),
		hitboxOffset = Vector3.new(0, 0, -3.2),
		hitActiveStart = 0.18,
		hitActiveEnd = 0.42,
		totalDuration = 0.95,
		inputWindowStart = 0.55,
		animationId = ANIM.COMBO_4,
		knockback = Vector3.new(0, 6, -26),
		cameraShakeMagnitude = 0.75,
	},
}

-- ── Block ─────────────────────────────────────────────────
CombatConfig.BLOCK_MAX_METER = 100
CombatConfig.BLOCK_REGEN_RATE = 22 -- meter / second (only when NOT blocking)
CombatConfig.BLOCK_REGEN_DELAY = 2.4 -- seconds after last hit before regen starts
CombatConfig.BLOCK_DAMAGE_MULT = 0.15 -- 85% damage reduction while blocking
CombatConfig.BLOCK_PARRY_WINDOW = 0.22 -- seconds from block-press = perfect parry window
CombatConfig.BLOCK_STUN_DURATION = 0.28 -- brief freeze on defender after absorbing a hit

-- ── Stun Durations ────────────────────────────────────────
CombatConfig.PARRY_STUN_DURATION = 1.80 -- attacker stunned after being parried
CombatConfig.BLOCK_BREAK_STUN = 1.10 -- defender stunned when block fully breaks

-- ── Animation IDs (re-exported for AnimationController) ──
CombatConfig.ANIM = ANIM

-- ── Anti-Exploit (server-side checks) ────────────────────
-- Minimum gap between server-accepted attack requests.
-- Set just below the fastest possible combo chain.
CombatConfig.MIN_ATTACK_INTERVAL = 0.28 -- seconds
CombatConfig.MAX_REACH_STUDS = 13 -- max valid hit distance
-- How much extra latency tolerance to give clients (generous for ping spikes)
CombatConfig.LATENCY_TOLERANCE = 0.35 -- seconds

-- ── UI Polish ─────────────────────────────────────────────
CombatConfig.BLOCK_UI_TWEEN_TIME = 0.08
CombatConfig.BLOCK_BROKEN_FLASH_COLOR = Color3.fromRGB(255, 55, 55)
CombatConfig.PARRY_FLASH_COLOR = Color3.fromRGB(255, 235, 80)
CombatConfig.BLOCK_LOW_THRESHOLD = 30 -- meter % below which bar turns red

-- ── Ragdoll (finisher hit 4, non-air) ────────────────────
CombatConfig.RAGDOLL_DURATION = 1.50 -- seconds body stays ragdolled
-- Local-space velocity applied to attacker's HRP on ragdoll hit.
-- X = side, Y = up, Z = back (negative Z = away from attacker)
CombatConfig.RAGDOLL_VELOCITY = Vector3.new(0, 10, -35)

-- ── Air Combo ─────────────────────────────────────────────
-- Space held during hits 1–3 → hit 4 launches up instead of ragdolling.
CombatConfig.AIR_FLOAT_HEIGHT = 10 -- extra studs above hit position
CombatConfig.AIR_FLOAT_DURATION = 3.50 -- seconds target is suspended
CombatConfig.AIR_LAUNCH_VELOCITY = 70 -- upward studs/s impulse on launch

-- ── Screen FX ─────────────────────────────────────────────
CombatConfig.PARRY_BW_DURATION = 1.60 -- seconds of B&W effect on the parried player

return CombatConfig
