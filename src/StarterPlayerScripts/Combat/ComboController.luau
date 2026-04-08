--[[
    ComboController.luau  (Client)
    ──────────────────────────────────────────────────────────
    v2 changes vs v1:
      • Tracks _airComboArmed: space held during hits 1–3 arms
        the 4th M1 as an air launcher instead of a knockback finisher.
      • Space state is checked BOTH via signal (held during swing)
        and via UserInputService poll (pre-held before each hit).
      • Disables jump (SetStateEnabled) while any action is active.
      • AttackRequest payload now includes isAirCombo: boolean.
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConfig = require(ReplicatedStorage.Shared.CombatConfig)
local InputController = require(script.Parent.InputController)

-- ─── TYPES ───────────────────────────────────────────────────────────────────
type ComboHit = typeof(CombatConfig.COMBO_HITS[1])
type SM = { is: any, transition: any, forceTransition: any }

-- ─── MODULE ──────────────────────────────────────────────────────────────────
local ComboController = {}
ComboController.__index = ComboController

export type ComboControllerType = {
	handleAttackInput: (self: ComboControllerType) -> (),
	update: (self: ComboControllerType, dt: number) -> (),
	reset: (self: ComboControllerType) -> (),
	destroy: (self: ComboControllerType) -> (),
}

function ComboController.new(deps: {
	stateMachine: SM,
	animController: { play: any, stop: any },
	attackRemote: RemoteEvent,
	humanoidRef: Humanoid?,
	onHitEffectRequest: ((comboIndex: number) -> ())?,
}): ComboControllerType
	local self = setmetatable({
		_sm = deps.stateMachine,
		_anim = deps.animController,
		_attackRemote = deps.attackRemote,
		_humanoid = deps.humanoidRef,
		_onHitEffect = deps.onHitEffectRequest,

		_comboIndex = 0,
		_bufferedInput = false,
		_inInputWindow = false,
		_actionActive = false,
		_actionTimer = 0,
		_resetTimer = 0,
		_currentHit = nil :: ComboHit?,

		-- Air combo: armed when space is held during hits 1–3.
		-- Resets when the full combo resets.
		_airComboArmed = false,

		_connections = {} :: { RBXScriptConnection },
	}, ComboController)

	-- ── Wire space signal ─────────────────────────────────
	-- Arm mid-swing: if space is held while the action is active on hits 1–3.
	local spaceConn = InputController.onSpaceHold:Connect(function()
		if self._actionActive and self._comboIndex < CombatConfig.COMBO_COUNT and self._comboIndex >= 1 then
			self._airComboArmed = true
		end
	end)
	table.insert(self._connections, spaceConn)

	return self :: ComboControllerType
end

-- ─── PUBLIC ──────────────────────────────────────────────────────────────────

function ComboController:handleAttackInput()
	local sm = self._sm
	if sm:is("Blocking") or sm:is("BlockStun") or sm:is("Stunned") or sm:is("Dead") then
		return
	end

	if self._actionActive then
		if self._inInputWindow then
			self._bufferedInput = true
		end
		return
	end

	self:_startNextHit()
end

function ComboController:update(dt: number)
	if not self._actionActive then
		if self._comboIndex > 0 then
			self._resetTimer += dt
			if self._resetTimer >= CombatConfig.COMBO_RESET_WINDOW then
				self:reset()
			end
		end
		return
	end

	self._actionTimer += dt
	local hit = self._currentHit :: ComboHit

	if not self._inInputWindow and self._actionTimer >= hit.inputWindowStart then
		self._inInputWindow = true
	end

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
	self._airComboArmed = false -- full reset clears air combo arm

	-- Restore jump when combo resets manually (safety net)
	if self._humanoid then
		self._humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
	end
end

function ComboController:destroy()
	for _, conn in ipairs(self._connections) do
		conn:Disconnect()
	end
	table.clear(self._connections)
	self:reset()
end

-- ─── PRIVATE ─────────────────────────────────────────────────────────────────

function ComboController:_startNextHit()
	local nextIndex = (self._comboIndex % CombatConfig.COMBO_COUNT) + 1
	local hit = CombatConfig.COMBO_HITS[nextIndex] :: ComboHit

	-- Poll space RIGHT NOW for pre-held case:
	-- Player may have held space before pressing M1 for this hit.
	-- Only arms for hits 1–3 (not 4, which IS the launcher).
	if nextIndex < CombatConfig.COMBO_COUNT then
		if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
			self._airComboArmed = true
		end
	end

	self._comboIndex = nextIndex
	self._actionActive = true
	self._actionTimer = 0
	self._inInputWindow = false
	self._bufferedInput = false
	self._resetTimer = 0
	self._currentHit = hit

	-- ── Disable jump while swinging ──────────────────────
	-- Prevents bunny-hopping through combos.
	-- Re-enabled in _endAction (or on full reset).
	if self._humanoid then
		self._humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	end

	-- ── Client Prediction ────────────────────────────────
	self._anim:play(hit.animationId, 0.05)

	if not self._sm:transition("Attacking") then
		self._sm:forceTransition("Attacking")
	end

	-- ── Server Request ───────────────────────────────────
	-- isAirCombo is only meaningful on hit 4; server ignores it for hits 1–3.
	self._attackRemote:FireServer({
		comboIndex = nextIndex,
		clientTime = tick(),
		isAirCombo = (nextIndex == CombatConfig.COMBO_COUNT) and self._airComboArmed,
	})

	if self._onHitEffect then
		self._onHitEffect(nextIndex)
	end
end

function ComboController:_endAction()
	self._actionActive = false
	self._inInputWindow = false
	self._actionTimer = 0
	self._currentHit = nil

	-- Restore jump now that the swing has fully recovered.
	if self._humanoid then
		self._humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
	end

	-- Air combo arm resets after hit 4 fires; keep it through hits 1–3.
	if self._comboIndex >= CombatConfig.COMBO_COUNT then
		self._airComboArmed = false
	end

	if self._sm:is("Attacking") then
		self._sm:transition("Idle")
	end

	if self._bufferedInput then
		self._bufferedInput = false
		task.defer(function()
			self:_startNextHit()
		end)
	end
end

return ComboController
