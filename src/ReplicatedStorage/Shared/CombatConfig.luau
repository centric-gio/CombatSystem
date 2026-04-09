--[[
    CombatConfig.luau
    ──────────────────────────────────────────────────────────
    Single source of truth for ALL combat numbers.
    Designers tweak here; no logic changes needed.

    CHANGES (v2):
      • COMBO_COUNT bumped 4 → 5.
      • All 5 hits are NORMAL (no isHeavy flag).
      • Hit 5 still ragdolls the target — that logic now lives in
        CombatManager and is triggered by comboIndex == COMBO_COUNT,
        not by isHeavy. This lets us keep the snappy feel while
        making the ragdoll feel like a natural finisher.
      • TOOL_NAME: the exact Name of the Tool in the hotbar that
        must be equipped before any M1 attack is accepted client-side.

    HOW TO REPLACE ANIMATIONS:
      1. Upload each animation to Roblox.
      2. Copy the asset ID.
      3. Replace the placeholder strings below with "rbxassetid://ID".
      4. Animations must target the R6 rig (Root, Torso, etc.).
]]

-- ─── ANIMATION IDS ───────────────────────────────────────────────────────────
-- TODO: Replace with real asset IDs before shipping.
local ANIM = {
	COMBO_1 = "rbxassetid://0000000001",
	COMBO_2 = "rbxassetid://0000000002",
	COMBO_3 = "rbxassetid://0000000003",
	COMBO_4 = "rbxassetid://0000000004",
	COMBO_5 = "rbxassetid://0000000005", -- finisher (ragdoll, NOT heavy)
	BLOCK_IDLE = "rbxassetid://83146853780823",
	STUNNED = "rbxassetid://100679173821281",
	BLOCK_BROKEN = "rbxassetid://91395768560395",
}

-- ─── MODULE ──────────────────────────────────────────────────────────────────
local CombatConfig = {}

-- ── Tool Gate ────────────────────────────────────────────
-- The Tool in the player's hotbar that must be Equipped before M1 works.
-- Must match the Tool.Name exactly (case-sensitive).
CombatConfig.TOOL_NAME = "CombatWeapon"

-- ── Combo ────────────────────────────────────────────────
CombatConfig.COMBO_COUNT = 5
CombatConfig.COMBO_RESET_WINDOW = 1.8 -- seconds of inactivity before reset

--[[
    Per-hit data table.
    ALL hits are normal (no isHeavy).
    Hit 5 ragdolls the opponent — gated in CombatManager by
    comboIndex == COMBO_COUNT, not by any flag here.

    Tune freely:
      hitActiveStart / hitActiveEnd  = hitbox window within the action.
      inputWindowStart               = when the next M1 can be buffered.
      totalDuration                  = full action length (must ≥ hitActiveEnd).
]]
CombatConfig.COMBO_HITS = {
	[1] = {
		damage = 10,
		blockMeterDamage = 12,
		isHeavy = false,
		hitboxSize = Vector3.new(5.5, 5.5, 5.5),
		hitboxOffset = Vector3.new(0, 0, -2.5),
		hitActiveStart = 0.10,
		hitActiveEnd = 0.24,
		totalDuration = 0.50,
		inputWindowStart = 0.20,
		animationId = ANIM.COMBO_1,
		knockback = Vector3.new(0, 2, -10),
		cameraShakeMagnitude = 0.28,
	},
	[2] = {
		damage = 10,
		blockMeterDamage = 12,
		isHeavy = false,
		hitboxSize = Vector3.new(5.5, 5.5, 5.5),
		hitboxOffset = Vector3.new(0, 0, -2.5),
		hitActiveStart = 0.08,
		hitActiveEnd = 0.22,
		totalDuration = 0.48,
		inputWindowStart = 0.18,
		animationId = ANIM.COMBO_2,
		knockback = Vector3.new(0, 2, -10),
		cameraShakeMagnitude = 0.28,
	},
	[3] = {
		damage = 12,
		blockMeterDamage = 16,
		isHeavy = false,
		hitboxSize = Vector3.new(6.0, 5.5, 6.0),
		hitboxOffset = Vector3.new(0, 0, -2.8),
		hitActiveStart = 0.10,
		hitActiveEnd = 0.26,
		totalDuration = 0.54,
		inputWindowStart = 0.22,
		animationId = ANIM.COMBO_3,
		knockback = Vector3.new(0, 3, -12),
		cameraShakeMagnitude = 0.40,
	},
	[4] = {
		damage = 14,
		blockMeterDamage = 20,
		isHeavy = false,
		hitboxSize = Vector3.new(6.0, 5.5, 6.0),
		hitboxOffset = Vector3.new(0, 0, -2.8),
		hitActiveStart = 0.10,
		hitActiveEnd = 0.26,
		totalDuration = 0.54,
		inputWindowStart = 0.22,
		animationId = ANIM.COMBO_4,
		knockback = Vector3.new(0, 3, -12),
		cameraShakeMagnitude = 0.45,
	},
	[5] = {
		-- Finisher: ragdolls on land, launches on air combo.
		-- Normal damage — NOT isHeavy, so it CAN be parried.
		-- Longer recovery punishes whiffing.
		damage = 20,
		blockMeterDamage = 30,
		isHeavy = false,
		hitboxSize = Vector3.new(7.0, 6.0, 7.0),
		hitboxOffset = Vector3.new(0, 0, -3.0),
		hitActiveStart = 0.16,
		hitActiveEnd = 0.38,
		totalDuration = 0.90,
		inputWindowStart = 0.50,
		animationId = ANIM.COMBO_5,
		knockback = Vector3.new(0, 5, -22),
		cameraShakeMagnitude = 0.70,
	},
}

-- ── Block ─────────────────────────────────────────────────
CombatConfig.BLOCK_MAX_METER = 100
CombatConfig.BLOCK_REGEN_RATE = 22 -- meter/second (only when NOT blocking)
CombatConfig.BLOCK_REGEN_DELAY = 2.4 -- seconds before regen starts
CombatConfig.BLOCK_DAMAGE_MULT = 0.15 -- 85% damage reduction while blocking
CombatConfig.BLOCK_PARRY_WINDOW = 0.22 -- seconds = perfect parry window
CombatConfig.BLOCK_STUN_DURATION = 0.28 -- brief freeze on defender per blocked hit

-- ── Stun Durations ────────────────────────────────────────
CombatConfig.PARRY_STUN_DURATION = 1.80 -- attacker stunned after being parried
CombatConfig.BLOCK_BREAK_STUN = 1.10 -- defender stunned when block fully breaks

-- ── Animation IDs (re-exported for AnimationController) ──
CombatConfig.ANIM = ANIM

-- ── Anti-Exploit ─────────────────────────────────────────
CombatConfig.MIN_ATTACK_INTERVAL = 0.24 -- slightly looser for 5-hit chain
CombatConfig.MAX_REACH_STUDS = 13
CombatConfig.LATENCY_TOLERANCE = 0.35

-- ── UI Polish ─────────────────────────────────────────────
CombatConfig.BLOCK_UI_TWEEN_TIME = 0.08
CombatConfig.BLOCK_BROKEN_FLASH_COLOR = Color3.fromRGB(255, 55, 55)
CombatConfig.PARRY_FLASH_COLOR = Color3.fromRGB(255, 235, 80)
CombatConfig.BLOCK_LOW_THRESHOLD = 30

-- ── Ragdoll ───────────────────────────────────────────────
-- Triggered on hit 5 (comboIndex == COMBO_COUNT). NOT isHeavy-gated.
CombatConfig.RAGDOLL_DURATION = 1.50
CombatConfig.RAGDOLL_VELOCITY = Vector3.new(0, 10, -35)

-- ── Air Combo ─────────────────────────────────────────────
-- Space held during hits 1–4 arms hit 5 as an upward launcher.
-- The ATTACKER also gets a brief upward boost so they rise with the target.
CombatConfig.AIR_FLOAT_HEIGHT = 10
CombatConfig.AIR_FLOAT_DURATION = 3.50
CombatConfig.AIR_LAUNCH_VELOCITY = 75 -- target upward impulse (studs/s)
CombatConfig.ATTACKER_AIR_BOOST = 55 -- attacker upward impulse (studs/s)

-- ── Screen FX ─────────────────────────────────────────────
CombatConfig.PARRY_BW_DURATION = 1.60

return CombatConfig
