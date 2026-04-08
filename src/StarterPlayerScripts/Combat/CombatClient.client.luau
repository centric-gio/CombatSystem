--[[
    CombatClient.client.luau
    ──────────────────────────────────────────────────────────
    v3: Fixed declaration order, completed ComboController.new()
    call, wired all ragdoll/float remotes.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- IMPORTANT: Script reference must be declared before any sibling requires.
local Script = script

-- ── Shared Modules ─────────────────────────────────────────
local StateMachine = require(ReplicatedStorage.Shared.StateMachine)
local CombatConfig = require(ReplicatedStorage.Shared.CombatConfig)

-- ── Client Modules ─────────────────────────────────────────
local InputController = require(Script.Parent.InputController)
local AnimationController = require(Script.Parent.AnimationController)
local ComboController = require(Script.Parent.ComboController)
local BlockController = require(Script.Parent.BlockController)
local BlockUI = require(Script.Parent.BlockUI)
local HitEffects = require(Script.Parent.HitEffects)
local ScreenEffects = require(Script.Parent.ScreenEffects)

local LocalPlayer = Players.LocalPlayer

-- ─── REMOTE REFERENCES ───────────────────────────────────────────────────────
local CombatRemotes = ReplicatedStorage:WaitForChild("CombatRemotes", 10)
assert(CombatRemotes, "[CombatClient] CombatRemotes folder not found!")

-- Client → Server
local AttackRequestRemote = CombatRemotes:WaitForChild("AttackRequest") :: RemoteEvent
local BlockStateRemote = CombatRemotes:WaitForChild("BlockState") :: RemoteEvent

-- Server → Client
local HitConfirmedRemote = CombatRemotes:WaitForChild("HitConfirmed") :: RemoteEvent
local BlockSyncRemote = CombatRemotes:WaitForChild("BlockSync") :: RemoteEvent
local BlockBrokenRemote = CombatRemotes:WaitForChild("BlockBroken") :: RemoteEvent
local ParrySuccessRemote = CombatRemotes:WaitForChild("ParrySuccess") :: RemoteEvent
local StateSyncRemote = CombatRemotes:WaitForChild("StateSync") :: RemoteEvent
local RagdollStartRemote = CombatRemotes:WaitForChild("RagdollStart") :: RemoteEvent
local RagdollEndRemote = CombatRemotes:WaitForChild("RagdollEnd") :: RemoteEvent
local FloatStartRemote = CombatRemotes:WaitForChild("FloatStart") :: RemoteEvent
local FloatEndRemote = CombatRemotes:WaitForChild("FloatEnd") :: RemoteEvent

-- ─── SESSION TYPE ────────────────────────────────────────────────────────────
type CombatSession = {
	stateMachine: { is: any, transition: any, forceTransition: any, update: any, destroy: any },
	animCtrl: { play: any, stop: any, stopAll: any, destroy: any },
	comboCtrl: { handleAttackInput: any, update: any, reset: any, destroy: any },
	blockCtrl: { onBlockStart: any, onBlockEnd: any, setMeter: any, isBlocking: any, destroy: any },
	blockUI: { setMeter: any, flash: any, setVisible: any, destroy: any },
	heartbeatConn: RBXScriptConnection,
	humanoid: Humanoid?,
	hrp: BasePart?,
}

local _session: CombatSession? = nil

-- ─── STATE MACHINE BUILDER ───────────────────────────────────────────────────
local function buildStateMachine()
	return StateMachine.new("Idle", {
		Idle = {
			canTransitionTo = { "Attacking", "Blocking", "Stunned", "Dead" },
			onEnter = function(_prev) end,
		},
		Attacking = {
			canTransitionTo = { "Idle", "Stunned", "Dead" },
		},
		Blocking = {
			canTransitionTo = { "Idle", "BlockStun", "Stunned", "Dead" },
		},
		BlockStun = {
			canTransitionTo = { "Idle", "Blocking", "Dead" },
		},
		Stunned = {
			canTransitionTo = { "Idle", "Dead" },
		},
		Dead = {
			canTransitionTo = {},
		},
	})
end

-- ─── INIT SESSION ────────────────────────────────────────────────────────────
local function initSession(character: Model)
	-- Clean up previous session (respawn)
	if _session then
		_session.heartbeatConn:Disconnect()
		_session.stateMachine:destroy()
		_session.animCtrl:destroy()
		_session.comboCtrl:destroy()
		_session.blockCtrl:destroy()
		_session.blockUI:destroy()
		_session = nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid?
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?

	local sm = buildStateMachine()
	local animCtrl = AnimationController.new(character)
	local blockUi = BlockUI.new()

	-- Wire jump toggle to state transitions.
	-- ComboController also disables jump per-swing; this is a backup layer.
	sm:onChanged(function(from: string, to: string)
		if not humanoid then
			return
		end
		if to == "Attacking" then
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		elseif from == "Attacking" and to == "Idle" then
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		end
	end)

	local blockCtrl = BlockController.new({
		stateMachine = sm,
		animController = animCtrl,
		blockUI = blockUi,
		blockRemote = BlockStateRemote,
	})

	-- ── THIS IS THE BUG THAT WAS MISSING: the function body + closing ──
	local comboCtrl = ComboController.new({
		stateMachine = sm,
		animController = animCtrl,
		attackRemote = AttackRequestRemote,
		humanoidRef = humanoid,
		onHitEffectRequest = function(comboIndex: number)
			HitEffects.onSwingStart(comboIndex)
		end,
	})

	-- Per-frame update loop
	local hbConn = RunService.Heartbeat:Connect(function(dt: number)
		sm:update(dt)
		comboCtrl:update(dt)
	end)

	_session = {
		stateMachine = sm,
		animCtrl = animCtrl,
		comboCtrl = comboCtrl,
		blockCtrl = blockCtrl,
		blockUI = blockUi,
		heartbeatConn = hbConn,
		humanoid = humanoid,
		hrp = hrp,
	}

	blockUi:setVisible(false)
end

-- ─── INPUT WIRING ────────────────────────────────────────────────────────────

InputController.onAttack:Connect(function()
	if not _session then
		return
	end
	_session.comboCtrl:handleAttackInput()
end)

InputController.onBlockStart:Connect(function()
	if not _session then
		return
	end
	_session.blockCtrl:onBlockStart()
end)

InputController.onBlockEnd:Connect(function()
	if not _session then
		return
	end
	_session.blockCtrl:onBlockEnd()
end)

-- ─── SERVER EVENT HANDLERS ───────────────────────────────────────────────────

HitConfirmedRemote.OnClientEvent:Connect(function(result: {
	targetUserId: number,
	damage: number,
	wasBlocked: boolean,
	wasParried: boolean,
	blockBroken: boolean,
	newBlockMeter: number,
	position: Vector3,
})
	if not _session then
		return
	end

	if result.wasParried then
		HitEffects.onParry()
		return
	end

	-- targetUserId == 0 means we hit an NPC dummy
	local targetChar: Model? = nil
	if result.targetUserId ~= 0 then
		local targetPlayer = Players:GetPlayerByUserId(result.targetUserId)
		targetChar = targetPlayer and targetPlayer.Character or nil
	end

	if result.wasBlocked then
		HitEffects.onBlockHit(result.position)
		if result.blockBroken then
			HitEffects.onBlockBreak(result.position)
		end
	elseif targetChar then
		local hitData = CombatConfig.COMBO_HITS[_session.comboCtrl._comboIndex]
		local shakeMag = hitData and hitData.cameraShakeMagnitude or 0.4
		HitEffects.onHitConfirmed(targetChar, shakeMag, result.position)
	end
end)

BlockSyncRemote.OnClientEvent:Connect(function(payload: {
	meter: number,
	isBroken: boolean,
})
	if not _session then
		return
	end
	_session.blockCtrl:setMeter(payload.meter, payload.isBroken)
end)

BlockBrokenRemote.OnClientEvent:Connect(function()
	if not _session then
		return
	end
	_session.blockCtrl:setMeter(0, true)
end)

ParrySuccessRemote.OnClientEvent:Connect(function()
	if not _session then
		return
	end
	HitEffects.onParry()
	if _session.blockUI then
		_session.blockUI:flash(CombatConfig.PARRY_FLASH_COLOR)
	end
end)

StateSyncRemote.OnClientEvent:Connect(function(newState: string, duration: number?, effectType: string?)
	if not _session then
		return
	end
	local sm = _session.stateMachine
	local humanoid = _session.humanoid

	if newState == "Stunned" then
		sm:forceTransition("Stunned")

		if humanoid then
			humanoid.WalkSpeed = 0
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		end

		if _session.animCtrl then
			_session.animCtrl:play(CombatConfig.ANIM.STUNNED, 0.05)
		end

		if effectType == "parried" then
			ScreenEffects.parryBW(duration or CombatConfig.PARRY_BW_DURATION)
		end

		if duration then
			task.delay(duration, function()
				if _session and sm:is("Stunned") then
					sm:transition("Idle")
					if humanoid then
						humanoid.WalkSpeed = 16
						humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
					end
				end
			end)
		end
	elseif newState == "Dead" then
		sm:forceTransition("Dead")
		InputController.setEnabled(false)
		ScreenEffects.clearAll()
		if humanoid then
			humanoid.WalkSpeed = 0
		end
	elseif newState == "Idle" then
		if not sm:is("Dead") then
			sm:forceTransition("Idle")
		end
		if humanoid then
			humanoid.WalkSpeed = 16
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		end
	end
end)

-- ─── RAGDOLL EVENTS ──────────────────────────────────────────────────────────

RagdollStartRemote.OnClientEvent:Connect(function(knockback: Vector3)
	if not _session then
		return
	end
	local humanoid = _session.humanoid
	local hrp = _session.hrp

	if humanoid then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
		humanoid.WalkSpeed = 0
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	end

	if hrp then
		hrp.AssemblyLinearVelocity = knockback
	end
end)

RagdollEndRemote.OnClientEvent:Connect(function()
	if not _session then
		return
	end
	local humanoid = _session.humanoid

	if humanoid then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		humanoid.WalkSpeed = 16
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
	end

	if _session and _session.stateMachine:is("Stunned") then
		_session.stateMachine:transition("Idle")
	end
end)

-- ─── FLOAT EVENTS ────────────────────────────────────────────────────────────

FloatStartRemote.OnClientEvent:Connect(function(_duration: number)
	if not _session then
		return
	end
	local humanoid = _session.humanoid

	if humanoid then
		humanoid.WalkSpeed = 0
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	end
end)

FloatEndRemote.OnClientEvent:Connect(function()
	if not _session then
		return
	end
	local humanoid = _session.humanoid

	if humanoid then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		humanoid.WalkSpeed = 16
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
	end

	if _session and _session.stateMachine:is("Stunned") then
		_session.stateMachine:transition("Idle")
	end
end)

-- ─── CHARACTER LIFECYCLE ─────────────────────────────────────────────────────

local function onCharacterAdded(character: Model)
	character:WaitForChild("HumanoidRootPart", 5)
	character:WaitForChild("Humanoid", 5)
	initSession(character)
	InputController.setEnabled(true)
end

local function onCharacterRemoving()
	InputController.setEnabled(false)
	ScreenEffects.clearAll()
end

if LocalPlayer.Character then
	task.spawn(onCharacterAdded, LocalPlayer.Character)
end

LocalPlayer.CharacterAdded:Connect(onCharacterAdded)
LocalPlayer.CharacterRemoving:Connect(onCharacterRemoving)
