--[[
    Types.luau
    ──────────────────────────────────────────────────────────
    Central type definitions for the entire combat system.
    Every module imports this for strict Luau typing.
    Never put runtime logic here — types only.
]]

-- ─── STATES ──────────────────────────────────────────────────────────────────

export type CombatState =
	"Idle"
	| "Attacking" -- actively in a combo swing animation
	| "Blocking" -- F held, meter > 0
	| "BlockStun" -- brief freeze after absorbing a blocked hit
	| "Stunned" -- full stun: parried OR block broken
	| "Dead"

-- ─── COMBO ───────────────────────────────────────────────────────────────────

export type ComboHit = {
	damage: number,
	blockMeterDamage: number, -- how much block meter this attack drains
	isHeavy: boolean, -- heavy hits can't be perfect-parried, big meter drain
	hitboxSize: Vector3,
	hitboxOffset: Vector3, -- local-space offset from HRP
	hitActiveStart: number, -- seconds into the action when hitbox turns ON
	hitActiveEnd: number, -- seconds into the action when hitbox turns OFF
	totalDuration: number, -- full action length (windup + active + recovery)
	inputWindowStart: number, -- when the next M1 can be buffered (chain window opens)
	animationId: string,
	knockback: Vector3, -- local-space dir × magnitude
	cameraShakeMagnitude: number,
}

-- ─── BLOCK ───────────────────────────────────────────────────────────────────

export type BlockData = {
	meter: number, -- 0 – CombatConfig.BLOCK_MAX_METER
	isBroken: boolean,
	lastHitTime: number, -- tick() of last hit absorbed, used for regen delay
}

-- ─── NETWORKING ──────────────────────────────────────────────────────────────

-- Client → Server: request to perform a swing
export type AttackRequest = {
	comboIndex: number, -- 1-based index into CombatConfig.COMBO_HITS
	clientTime: number, -- tick() at moment of input (server uses for latency check)
}

-- Server → Client: result of a hit that landed
export type HitResult = {
	targetUserId: number,
	damage: number,
	wasBlocked: boolean,
	wasParried: boolean,
	blockBroken: boolean,
	newBlockMeter: number, -- target's remaining block meter
}

-- Server → Client: sync a player's block meter (on hit or regen)
export type BlockSyncPayload = {
	meter: number,
	isBroken: boolean,
}

-- ─── STATE MACHINE ───────────────────────────────────────────────────────────

-- One entry per state in the FSM
export type StateDefinition = {
	-- Callbacks – all optional
	onEnter: ((previousState: CombatState) -> ())?,
	onExit: ((nextState: CombatState) -> ())?,
	onUpdate: ((dt: number) -> ())?,
	-- Whitelist: which states this state is allowed to move into
	canTransitionTo: { CombatState },
}

return {}
