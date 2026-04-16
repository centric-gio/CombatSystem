--[[
    CombatConfig.luau  v3
    ──────────────────────────────────────────────────────────
    No value changes from v2. Comments updated to reflect v4
    RagdollService behaviour:
      • Air combo finisher (hit 5 + space held): target floats,
        NO ragdoll joints. Attacker Y-locked next to target.
      • Ground finisher (hit 5, no space): ragdoll + knockback.
    ATTACKER_AIR_BOOST is the upward velocity applied to the attacker
    client immediately when the air launcher connects.
]]

local ANIM = {
	COMBO_1 = "rbxassetid://124192568876661",
	COMBO_2 = "rbxassetid://87768775093348",
	COMBO_3 = "rbxassetid://124192568876661",
	COMBO_4 = "rbxassetid://87768775093348",
	COMBO_5 = "rbxassetid://124192568876661",
	BLOCK_IDLE = "rbxassetid://83146853780823",
	STUNNED = "rbxassetid://100679173821281",
	BLOCK_BROKEN = "rbxassetid://91395768560395",
}

local CombatConfig = {}

CombatConfig.TOOL_NAME = "CombatWeapon"
CombatConfig.COMBO_COUNT = 5
CombatConfig.COMBO_RESET_WINDOW = 1.8

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
		-- Finisher: ragdolls on ground, floats on air combo.
		-- isHeavy = false → CAN be parried.
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

CombatConfig.BLOCK_MAX_METER = 100
CombatConfig.BLOCK_REGEN_RATE = 22
CombatConfig.BLOCK_REGEN_DELAY = 2.4
CombatConfig.BLOCK_DAMAGE_MULT = 0.15
CombatConfig.BLOCK_PARRY_WINDOW = 0.22
CombatConfig.BLOCK_STUN_DURATION = 0.28
CombatConfig.PARRY_STUN_DURATION = 1.80
CombatConfig.BLOCK_BREAK_STUN = 1.10
CombatConfig.ANIM = ANIM
CombatConfig.MIN_ATTACK_INTERVAL = 0.24
CombatConfig.MAX_REACH_STUDS = 13
CombatConfig.LATENCY_TOLERANCE = 0.35

CombatConfig.BLOCK_UI_TWEEN_TIME = 0.08
CombatConfig.BLOCK_BROKEN_FLASH_COLOR = Color3.fromRGB(255, 55, 55)
CombatConfig.PARRY_FLASH_COLOR = Color3.fromRGB(255, 235, 80)
CombatConfig.BLOCK_LOW_THRESHOLD = 30

-- Ground finisher ragdoll
CombatConfig.RAGDOLL_DURATION = 1.50
CombatConfig.RAGDOLL_VELOCITY = Vector3.new(0, 10, -35)

-- Air combo
-- AIR_LAUNCH_VELOCITY: upward impulse on the TARGET (studs/s)
-- ATTACKER_AIR_BOOST:  upward impulse on the ATTACKER CLIENT (studs/s)
-- AIR_FLOAT_HEIGHT:    used to offset the AlignPosition anchor slightly above rise point
-- AIR_FLOAT_DURATION:  how long both target and attacker stay suspended
CombatConfig.AIR_FLOAT_HEIGHT = 10
CombatConfig.AIR_FLOAT_DURATION = 3.50
CombatConfig.AIR_LAUNCH_VELOCITY = 75
CombatConfig.ATTACKER_AIR_BOOST = 55

CombatConfig.PARRY_BW_DURATION = 1.60

return CombatConfig
