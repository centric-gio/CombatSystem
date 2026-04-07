--[[
    CombatClient.client.luau
    ──────────────────────────────────────────────────────────
    Entry point for all client-side combat logic.
    Initialises every module and wires them together.
    Handles character respawns cleanly.

    Dependency graph:
      InputController ──► ComboController ──► AnimController
                      └──► BlockController ──► AnimController
                                          └──► BlockUI
      All receive StateMachine reference.
      All combat remotes wired here.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Shared Modules ─────────────────────────────────────────
local StateMachine = require(ReplicatedStorage.Shared.StateMachine)
local CombatConfig = require(ReplicatedStorage.Shared.CombatConfig)

-- ── Client Modules (siblings of this Script) ───────────────
local Script = script -- reference for sibling requires
local InputController = require(Script.Parent.InputController)
local AnimationController = require(Script.Parent.AnimationController)
local ComboController = require(Script.Parent.ComboController)
local BlockController = require(Script.Parent.BlockController)
local BlockUI = require(Script.Parent.BlockUI)
local HitEffects = require(Script.Parent.HitEffects)

local LocalPlayer = Players.LocalPlayer

-- ─── REMOTE REFERENCES ───────────────────────────────────────────────────────
-- These are created by CombatServer on startup. We wait for them.
local CombatRemotes = ReplicatedStorage:WaitForChild("CombatRemotes", 10)
assert(CombatRemotes, "[CombatClient] CombatRemotes folder not found!")

local AttackRequestRemote = CombatRemotes:WaitForChild("AttackRequest") :: RemoteEvent
local BlockStateRemote = CombatRemotes:WaitForChild("BlockState") :: RemoteEvent
local HitConfirmedRemote = CombatRemotes:WaitForChild("HitConfirmed") :: RemoteEvent
local BlockSyncRemote = CombatRemotes:WaitForChild("BlockSync") :: RemoteEvent
local BlockBrokenRemote = CombatRemotes:WaitForChild("BlockBroken") :: RemoteEvent
local ParrySuccessRemote = CombatRemotes:WaitForChild("ParrySuccess") :: RemoteEvent
local StateSyncRemote = CombatRemotes:WaitForChild("StateSync") :: RemoteEvent

-- ─── SESSION STATE ───────────────────────────────────────────────────────────
-- Holds all per-character module instances.
-- Cleaned up and recreated on respawn.
type CombatSession = {
	stateMachine: { is: any, transition: any, forceTransition: any, update: any, destroy: any },
	animCtrl: { play: any, stop: any, stopAll: any, destroy: any },
	comboCtrl: { handleAttackInput: any, update: any, reset: any, destroy: any },
	blockCtrl: { onBlockStart: any, onBlockEnd: any, setMeter: any, isBlocking: any, destroy: any },
	blockUI: { setMeter: any, flash: any, setVisible: any, destroy: any },
	heartbeatConn: RBXScriptConnection,
}

local _session: CombatSession? = nil

-- ─── BUILD COMBAT STATE MACHINE ──────────────────────────────────────────────
local function buildStateMachine(): typeof(StateMachine.new("Idle", {}))
	--[[
        State transition whitelist.
        Changing this table is the ONLY place to add new states.
        Transitions NOT in the whitelist are blocked with a warning.
    ]]
	return StateMachine.new("Idle", {
		Idle = {
			canTransitionTo = { "Attacking", "Blocking", "Stunned", "Dead" },
			onEnter = function(_prev)
				-- Nothing special — future: play idle animation
			end,
		},
		Attacking = {
			canTransitionTo = { "Idle", "Stunned", "Dead" },
			-- We intentionally DON'T allow Attacking → Blocking mid-swing.
			-- Player must finish their swing first (punishes over-aggression).
		},
		Blocking = {
			canTransitionTo = { "Idle", "BlockStun", "Stunned", "Dead" },
		},
		BlockStun = {
			-- Brief freeze after absorbing a hit; can return to block or idle.
			canTransitionTo = { "Idle", "Blocking", "Dead" },
		},
		Stunned = {
			canTransitionTo = { "Idle", "Dead" },
		},
		Dead = {
			-- Terminal state — only forceTransition out (on respawn we rebuild).
			canTransitionTo = {},
		},
	})
end

-- ─── INIT SESSION ────────────────────────────────────────────────────────────
local function initSession(character: Model)
	-- Clean up any previous session (respawn case)
	if _session then
		_session.heartbeatConn:Disconnect()
		_session.stateMachine:destroy()
		_session.animCtrl:destroy()
		_session.comboCtrl:destroy()
		_session.blockCtrl:destroy()
		_session.blockUI:destroy()
		_session = nil
	end

	-- Build all module instances for this character.
	local sm = buildStateMachine()
	local animCtrl = AnimationController.new(character)
	local blockUi = BlockUI.new()

	local blockCtrl = BlockController.new({
		stateMachine = sm,
		animController = animCtrl,
		blockUI = blockUi,
		blockRemote = BlockStateRemote,
	})

	local comboCtrl = ComboController.new({
		stateMachine = sm,
		animController = animCtrl,
		attackRemote = AttackRequestRemote,
		onHitEffectRequest = function(comboIndex: number)
			HitEffects.onSwingStart(comboIndex)
		end,
	})

	-- ── Per-frame update ─────────────────────────────────
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
	}

	-- Show initial block meter as invisible/full
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

-- ─── SERVER EVENT WIRING ─────────────────────────────────────────────────────

-- Server confirmed a hit landed on someone we attacked.
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
		-- We were parried — server will also send StateSync to stun us.
		HitEffects.onParry()
		return
	end

	local targetChar = Players:GetPlayerByUserId(result.targetUserId)
		and Players:GetPlayerByUserId(result.targetUserId).Character

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

-- Server syncing THIS player's block meter (after we got hit while blocking).
BlockSyncRemote.OnClientEvent:Connect(function(payload: {
	meter: number,
	isBroken: boolean,
})
	if not _session then
		return
	end
	_session.blockCtrl:setMeter(payload.meter, payload.isBroken)
end)

-- Server telling THIS player their block was broken (explicit event, failsafe).
BlockBrokenRemote.OnClientEvent:Connect(function()
	if not _session then
		return
	end
	_session.blockCtrl:setMeter(0, true)
end)

-- Server syncing a parry that THIS player performed successfully.
ParrySuccessRemote.OnClientEvent:Connect(function()
	if not _session then
		return
	end
	HitEffects.onParry()
	if _session.blockUI then
		_session.blockUI:flash(CombatConfig.PARRY_FLASH_COLOR)
	end
end)

-- Server forcing our state (e.g., stunned, death authorised).
StateSyncRemote.OnClientEvent:Connect(function(newState: string, duration: number?)
	if not _session then
		return
	end
	local sm = _session.stateMachine

	if newState == "Stunned" then
		sm:forceTransition("Stunned")
		if _session.animCtrl then
			_session.animCtrl:play(CombatConfig.ANIM.STUNNED, 0.05)
		end
		if duration then
			task.delay(duration, function()
				if _session and sm:is("Stunned") then
					sm:transition("Idle")
				end
			end)
		end
	elseif newState == "Dead" then
		sm:forceTransition("Dead")
		InputController.setEnabled(false)
	elseif newState == "Idle" then
		if not sm:is("Dead") then
			sm:forceTransition("Idle")
		end
	end
end)

-- ─── CHARACTER LIFECYCLE ─────────────────────────────────────────────────────

local function onCharacterAdded(character: Model)
	-- Wait for the character to fully load (HRP must exist before animation)
	character:WaitForChild("HumanoidRootPart", 5)
	character:WaitForChild("Humanoid", 5)

	initSession(character)
	InputController.setEnabled(true)
end

local function onCharacterRemoving()
	InputController.setEnabled(false)
	-- Session cleaned up in next onCharacterAdded call
end

-- Handle already-spawned character on script init
if LocalPlayer.Character then
	task.spawn(onCharacterAdded, LocalPlayer.Character)
end

LocalPlayer.CharacterAdded:Connect(onCharacterAdded)
LocalPlayer.CharacterRemoving:Connect(onCharacterRemoving)
