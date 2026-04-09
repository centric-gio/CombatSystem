--[[
    ComboController.luau  (Client)  v3
    ──────────────────────────────────────────────────────────
    CHANGES FROM v2:
      • COMBO_COUNT is now 5. Logic unchanged — just follows the config.
      • Air combo arm now covers hits 1–4 (previously 1–3).
      • Tool gate: CombatClient passes `isToolEquipped` function ref.
        Every handleAttackInput call checks this first.
        This is the ONLY client-side gate — server validates separately.
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
	_comboIndex: number, -- exposed for HitEffects shake lookup
}

function ComboController.new(
	deps: {
		stateMachine: SM,
		animController: { play: any, stop: any },
		attackRemote: RemoteEvent,
		humanoidRef: Humanoid?,
		isToolEquipped: () -> boolean, -- NEW: gate function
		onHitEffectRequest: ((comboIndex: number) -> ())?,
	}
): ComboControllerType
	local self = setmetatable({
		_sm = deps.stateMachine,
		_anim = deps.animController,
		_attackRemote = deps.attackRemote,
		_humanoid = deps.humanoidRef,
		_toolGate = deps.isToolEquipped,
		_onHitEffect = deps.onHitEffectRequest,

		_comboIndex = 0,
		_bufferedInput = false,
		_inInputWindow = false,
		_actionActive = false,
		_actionTimer = 0,
		_resetTimer = 0,
		_currentHit = nil :: ComboHit?,
		_airComboArmed = false,

		_connections = {} :: { RBXScriptConnection },
	}, ComboController)

	-- Arm air combo when Space is held during hits 1–4
	local spaceConn = InputController.onSpaceHold:Connect(function()
		if self._actionActive and self._comboIndex >= 1 and self._comboIndex < CombatConfig.COMBO_COUNT then
			self._airComboArmed = true
		end
	end)
	table.insert(self._connections, spaceConn)

	return self :: ComboControllerType
end

-- ─── PUBLIC ──────────────────────────────────────────────────────────────────

function ComboController:handleAttackInput()
	-- Tool gate: client rejects input before even reaching state machine
	if not self._toolGate() then
		return
	end

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
	self._airComboArmed = false

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

	-- Pre-poll space for hits 1–4
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

	if self._humanoid then
		self._humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	end

	self._anim:play(hit.animationId, 0.05)

	if not self._sm:transition("Attacking") then
		self._sm:forceTransition("Attacking")
	end

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

	if self._humanoid then
		self._humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
	end

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
