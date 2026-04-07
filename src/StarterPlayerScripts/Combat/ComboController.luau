--[[
    ComboController.luau  (Client)
    ──────────────────────────────────────────────────────────
    Handles the full M1 combo chain:
      • 4-hit combo with input buffering.
      • Snappy feel: next swing fires the moment the
        inputWindowStart of the current swing is reached.
      • Sends AttackRequest to server for each swing.
      • Client-predicts animation; server authorises damage.

    Combo flow per hit:
      [0s]                → animation starts (client)
      [hitActiveStart]    → server processes hitbox
      [inputWindowStart]  → player CAN queue next M1
      [totalDuration]     → action ends, buffered input fires OR → Idle
      [COMBO_RESET_WINDOW]→ if no input, combo index resets to 0

    Depends on:
      AnimationController, StateMachine, InputController,
      CombatConfig, Types, and the CombatRemotes folder.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConfig = require(ReplicatedStorage.Shared.CombatConfig)

-- ─── TYPES ───────────────────────────────────────────────────────────────────
type ComboHit = typeof(CombatConfig.COMBO_HITS[1])
type SMType = { is: any, transition: any, getState: any } -- partial, filled by caller

-- ─── MODULE ──────────────────────────────────────────────────────────────────
local ComboController = {}
ComboController.__index = ComboController

export type ComboControllerType = {
	handleAttackInput: (self: ComboControllerType) -> (),
	update: (self: ComboControllerType, dt: number) -> (),
	reset: (self: ComboControllerType) -> (),
	destroy: (self: ComboControllerType) -> (),
}

-- ─── CONSTRUCTOR ─────────────────────────────────────────────────────────────
function ComboController.new(deps: {
	stateMachine: SMType,
	animController: { play: any, stop: any },
	attackRemote: RemoteEvent,
	onHitEffectRequest: ((comboIndex: number) -> ())?,
}): ComboControllerType
	local self = setmetatable({
		_sm = deps.stateMachine,
		_anim = deps.animController,
		_attackRemote = deps.attackRemote,
		_onHitEffect = deps.onHitEffectRequest,

		-- Combo state
		_comboIndex = 0, -- 0 = not in combo, 1-4 = current step
		_bufferedInput = false, -- player pressed M1 in the input window
		_inInputWindow = false, -- true once inputWindowStart is reached
		_actionActive = false, -- true while an action's timer is running
		_actionTimer = 0, -- time elapsed in the current action
		_resetTimer = 0, -- time since last completed hit (for combo reset)
		_currentHit = nil :: ComboHit?,
	}, ComboController)

	return self :: ComboControllerType
end

-- ─── PUBLIC API ──────────────────────────────────────────────────────────────

-- Called by InputController signal. Entry point for every M1 press.
function ComboController:handleAttackInput()
	local sm = self._sm

	-- Cannot attack while blocking, stunned, or dead.
	if sm:is("Blocking") or sm:is("BlockStun") or sm:is("Stunned") or sm:is("Dead") then
		return
	end

	if self._actionActive then
		-- Mid-action: buffer only if we're in the input window.
		if self._inInputWindow then
			self._bufferedInput = true
		end
		return
	end

	-- Free to start a new swing.
	self:_startNextHit()
end

-- Called every frame by CombatClient.
function ComboController:update(dt: number)
	if not self._actionActive then
		-- Count down combo reset when idle.
		if self._comboIndex > 0 then
			self._resetTimer += dt
			if self._resetTimer >= CombatConfig.COMBO_RESET_WINDOW then
				self:reset()
			end
		end
		return
	end

	-- ── Action Timer ─────────────────────────────────────
	self._actionTimer += dt
	local hit = self._currentHit :: ComboHit

	-- Open the input window once inputWindowStart is reached.
	if not self._inInputWindow and self._actionTimer >= hit.inputWindowStart then
		self._inInputWindow = true
		-- If player pressed M1 before window opened (too early), we discarded it.
		-- They'll need to press again. This prevents mashing spam feeling.
	end

	-- Action is complete.
	if self._actionTimer >= hit.totalDuration then
		self:_endAction()
	end
end

function ComboController:reset()
	self._comboIndex = 0
	self._bufferedInput = false
	self._inInputWindow = false
	self._actionActive = false
	self._actionTimer = 0
	self._resetTimer = 0
	self._currentHit = nil
end

function ComboController:destroy()
	self:reset()
end

-- ─── PRIVATE ─────────────────────────────────────────────────────────────────

function ComboController:_startNextHit()
	-- Advance combo index; wrap at COMBO_COUNT → 1
	local nextIndex = (self._comboIndex % CombatConfig.COMBO_COUNT) + 1
	local hit = CombatConfig.COMBO_HITS[nextIndex] :: ComboHit

	self._comboIndex = nextIndex
	self._actionActive = true
	self._actionTimer = 0
	self._inInputWindow = false
	self._bufferedInput = false
	self._resetTimer = 0
	self._currentHit = hit

	-- ── Client Prediction ────────────────────────────────
	-- Play animation immediately for zero perceived input lag.
	self._anim:play(hit.animationId, 0.05)

	-- Transition state machine to Attacking.
	-- If we're coming from Idle this always succeeds.
	-- If somehow still Attacking, forceTransition ensures correctness.
	if not self._sm:transition("Attacking") then
		self._sm:forceTransition("Attacking")
	end

	-- ── Server Request ───────────────────────────────────
	-- Send the request to the server.
	-- Server will validate timing, cast hitbox, and apply damage.
	self._attackRemote:FireServer({
		comboIndex = nextIndex,
		clientTime = tick(),
	} :: { comboIndex: number, clientTime: number })

	-- ── VFX Hook ─────────────────────────────────────────
	if self._onHitEffect then
		self._onHitEffect(nextIndex)
	end
end

function ComboController:_endAction()
	self._actionActive = false
	self._inInputWindow = false
	self._actionTimer = 0
	self._currentHit = nil

	-- Return state machine to Idle unless server has already
	-- forced us to Stunned/Dead (server override takes priority).
	if self._sm:is("Attacking") then
		self._sm:transition("Idle")
	end

	-- Fire buffered input as the very next swing with no perceptible delay.
	if self._bufferedInput then
		self._bufferedInput = false
		-- Use task.defer so the frame's update cycle finishes cleanly
		-- before starting the next action, avoiding double-advance issues.
		task.defer(function()
			self:_startNextHit()
		end)
	end
end

return ComboController
