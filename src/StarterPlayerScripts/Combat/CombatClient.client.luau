--[[
    CombatClient.client.luau  v4
    ──────────────────────────────────────────────────────────
    CHANGES FROM v3:
      • Tool gate: M1 attacks only fire when CombatConfig.TOOL_NAME
        is actively equipped. Detects via character ChildAdded/Removed
        listening for Tool with matching Name.
      • DebugMenu integrated: updates every Heartbeat with live state,
        logs every server event.
      • HitCounter integrated: left-side hit counter, incremented on
        every HitConfirmed. Streak resets when combo resets.
      • AttackerFloat remote: when the LOCAL player lands an air-combo
        finisher, they receive this remote and apply an upward velocity
        impulse so they visually "chase" the target into the air.
      • ComboController.new() now receives isToolEquipped gate function.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Script = script -- must be declared before sibling requires

-- ── Shared ────────────────────────────────────────────────
local StateMachine = require(ReplicatedStorage.Shared.StateMachine)
local CombatConfig = require(ReplicatedStorage.Shared.CombatConfig)

-- ── Client Modules ────────────────────────────────────────
local InputController = require(Script.Parent.InputController)
local AnimationController = require(Script.Parent.AnimationController)
local ComboController = require(Script.Parent.ComboController)
local BlockController = require(Script.Parent.BlockController)
local BlockUI = require(Script.Parent.BlockUI)
local HitEffects = require(Script.Parent.HitEffects)
local ScreenEffects = require(Script.Parent.ScreenEffects)
local DebugMenu = require(Script.Parent.DebugMenu)
local HitCounter = require(Script.Parent.HitCounter)

local LocalPlayer = Players.LocalPlayer

-- ─── REMOTE REFERENCES ───────────────────────────────────────────────────────
local CombatRemotes = ReplicatedStorage:WaitForChild("CombatRemotes", 10)
assert(CombatRemotes, "[CombatClient] CombatRemotes folder not found!")

local AttackRequestRemote = CombatRemotes:WaitForChild("AttackRequest") :: RemoteEvent
local BlockStateRemote = CombatRemotes:WaitForChild("BlockState") :: RemoteEvent
local HitConfirmedRemote = CombatRemotes:WaitForChild("HitConfirmed") :: RemoteEvent
local BlockSyncRemote = CombatRemotes:WaitForChild("BlockSync") :: RemoteEvent
local BlockBrokenRemote = CombatRemotes:WaitForChild("BlockBroken") :: RemoteEvent
local ParrySuccessRemote = CombatRemotes:WaitForChild("ParrySuccess") :: RemoteEvent
local StateSyncRemote = CombatRemotes:WaitForChild("StateSync") :: RemoteEvent
local RagdollStartRemote = CombatRemotes:WaitForChild("RagdollStart") :: RemoteEvent
local RagdollEndRemote = CombatRemotes:WaitForChild("RagdollEnd") :: RemoteEvent
local FloatStartRemote = CombatRemotes:WaitForChild("FloatStart") :: RemoteEvent
local FloatEndRemote = CombatRemotes:WaitForChild("FloatEnd") :: RemoteEvent
local AttackerFloatRemote = CombatRemotes:WaitForChild("AttackerFloat") :: RemoteEvent -- NEW

-- ─── GLOBAL SINGLETONS (persist across respawns) ─────────────────────────────
-- DebugMenu and HitCounter are not destroyed on respawn.
local _debugMenu = DebugMenu.new()
local _hitCounter = HitCounter.new()

-- ─── SESSION TYPE ────────────────────────────────────────────────────────────
type CombatSession = {
	stateMachine: { is: any, transition: any, forceTransition: any, update: any, onChanged: any, destroy: any },
	animCtrl: { play: any, stop: any, stopAll: any, destroy: any },
	comboCtrl: {
		handleAttackInput: any,
		update: any,
		reset: any,
		destroy: any,
		_comboIndex: number,
		_airComboArmed: boolean,
	},
	blockCtrl: { onBlockStart: any, onBlockEnd: any, setMeter: any, getMeter: any, isBlocking: any, destroy: any },
	blockUI: { setMeter: any, flash: any, setVisible: any, destroy: any },
	heartbeatConn: RBXScriptConnection,
	humanoid: Humanoid?,
	hrp: BasePart?,
	toolConn1: RBXScriptConnection?,
	toolConn2: RBXScriptConnection?,
	toolEquipped: boolean,
}

local _session: CombatSession? = nil

-- ─── TOOL GATE HELPERS ───────────────────────────────────────────────────────
-- Returns true if the local character has the combat tool currently equipped.
-- "Equipped" in Roblox terms = the Tool is a child of the Character, not the Backpack.
local function isToolEquipped(): boolean
	if not _session then
		return false
	end
	return _session.toolEquipped
end

local function _detectToolInCharacter(character: Model): boolean
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") and child.Name == CombatConfig.TOOL_NAME then
			return true
		end
	end
	return false
end

local function _setupToolListeners(character: Model, session: CombatSession)
	-- Disconnect previous listeners if any
	if session.toolConn1 then
		session.toolConn1:Disconnect()
	end
	if session.toolConn2 then
		session.toolConn2:Disconnect()
	end

	-- Initial check
	session.toolEquipped = _detectToolInCharacter(character)

	session.toolConn1 = character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") and child.Name == CombatConfig.TOOL_NAME then
			session.toolEquipped = true
			_debugMenu:logEvent("STATE", "Tool EQUIPPED")
		end
	end)

	session.toolConn2 = character.ChildRemoved:Connect(function(child)
		if child:IsA("Tool") and child.Name == CombatConfig.TOOL_NAME then
			session.toolEquipped = false
			_debugMenu:logEvent("STATE", "Tool UNEQUIPPED — interrupting combo")
			-- Interrupt any active combo when tool is put away
			if _session then
				_session.comboCtrl:reset()
				if _session.stateMachine:is("Attacking") then
					_session.stateMachine:transition("Idle")
				end
			end
		end
	end)
end

-- ─── STATE MACHINE BUILDER ───────────────────────────────────────────────────
local function buildStateMachine()
	return StateMachine.new("Idle", {
		Idle = { canTransitionTo = { "Attacking", "Blocking", "Stunned", "Dead" } },
		Attacking = { canTransitionTo = { "Idle", "Stunned", "Dead" } },
		Blocking = { canTransitionTo = { "Idle", "BlockStun", "Stunned", "Dead" } },
		BlockStun = { canTransitionTo = { "Idle", "Blocking", "Dead" } },
		Stunned = { canTransitionTo = { "Idle", "Dead" } },
		Dead = { canTransitionTo = {} },
	})
end

-- ─── INIT SESSION ────────────────────────────────────────────────────────────
local function initSession(character: Model)
	if _session then
		_session.heartbeatConn:Disconnect()
		if _session.toolConn1 then
			_session.toolConn1:Disconnect()
		end
		if _session.toolConn2 then
			_session.toolConn2:Disconnect()
		end
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

	-- Jump toggle tied to attack state
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

	-- Build a partial session table first so isToolEquipped can close over it
	local sessionRef: CombatSession = {
		stateMachine = sm,
		animCtrl = animCtrl,
		comboCtrl = nil :: any, -- filled below
		blockCtrl = blockCtrl,
		blockUI = blockUi,
		heartbeatConn = nil :: any,
		humanoid = humanoid,
		hrp = hrp,
		toolConn1 = nil,
		toolConn2 = nil,
		toolEquipped = false,
	}
	_session = sessionRef

	-- Wire tool detection
	_setupToolListeners(character, sessionRef)

	local comboCtrl = ComboController.new({
		stateMachine = sm,
		animController = animCtrl,
		attackRemote = AttackRequestRemote,
		humanoidRef = humanoid,
		isToolEquipped = isToolEquipped,
		onHitEffectRequest = function(comboIndex: number)
			HitEffects.onSwingStart(comboIndex)
		end,
	})
	sessionRef.comboCtrl = comboCtrl

	-- Combo reset → tell hit counter to reset streak
	-- (ComboController calls reset() on timeout — hook via update polling)
	local lastComboIndex = 0

	local hbConn = RunService.Heartbeat:Connect(function(dt: number)
		sm:update(dt)
		comboCtrl:update(dt)

		-- Detect combo reset (index went from >0 to 0)
		if lastComboIndex > 0 and comboCtrl._comboIndex == 0 then
			_hitCounter:resetStreak()
		end
		lastComboIndex = comboCtrl._comboIndex

		-- Debug menu update
		_debugMenu:update({
			state = sm:getState(),
			comboIndex = comboCtrl._comboIndex,
			blockMeter = blockCtrl:getMeter(),
			blockMax = CombatConfig.BLOCK_MAX_METER,
			toolEquipped = sessionRef.toolEquipped,
			airArmed = comboCtrl._airComboArmed or false,
		})
	end)

	sessionRef.heartbeatConn = hbConn

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
	comboIndex: number,
})
	if not _session then
		return
	end

	-- Update hit counter
	_hitCounter:registerHit(result.wasBlocked, result.wasParried, result.damage)

	-- Debug log
	local tag = if result.wasParried
		then "PARRY"
		elseif result.blockBroken then "BREAK"
		elseif result.wasBlocked then "BLOCK"
		else "HIT"
	_debugMenu:logEvent(
		tag,
		("dmg=%d  blk=%.0f  combo=%d"):format(result.damage, result.newBlockMeter, result.comboIndex)
	)

	if result.wasParried then
		HitEffects.onParry()
		return
	end

	local targetChar: Model? = nil
	if result.targetUserId ~= 0 then
		local tp = Players:GetPlayerByUserId(result.targetUserId)
		targetChar = tp and tp.Character or nil
	end

	if result.wasBlocked then
		HitEffects.onBlockHit(result.position)
		if result.blockBroken then
			HitEffects.onBlockBreak(result.position)
		end
	elseif targetChar then
		local hitData = CombatConfig.COMBO_HITS[result.comboIndex]
		local shakeMag = hitData and hitData.cameraShakeMagnitude or 0.4
		HitEffects.onHitConfirmed(targetChar, shakeMag, result.position)
	end
end)

BlockSyncRemote.OnClientEvent:Connect(function(payload: { meter: number, isBroken: boolean })
	if not _session then
		return
	end
	_session.blockCtrl:setMeter(payload.meter, payload.isBroken)
	_debugMenu:logEvent("BLOCK", ("meter=%.0f broken=%s"):format(payload.meter, tostring(payload.isBroken)))
end)

BlockBrokenRemote.OnClientEvent:Connect(function()
	if not _session then
		return
	end
	_session.blockCtrl:setMeter(0, true)
	_debugMenu:logEvent("BREAK", "block broken!")
end)

ParrySuccessRemote.OnClientEvent:Connect(function()
	if not _session then
		return
	end
	HitEffects.onParry()
	if _session.blockUI then
		_session.blockUI:flash(CombatConfig.PARRY_FLASH_COLOR)
	end
	_debugMenu:logEvent("PARRY", "successful parry!")
end)

StateSyncRemote.OnClientEvent:Connect(function(newState: string, duration: number?, effectType: string?)
	if not _session then
		return
	end
	local sm = _session.stateMachine
	local humanoid = _session.humanoid

	_debugMenu:logEvent("STATE", ("→ %s (dur=%.2fs)"):format(newState, duration or 0))

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
	_debugMenu:logEvent("RAGDOLL", "started")

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
	_debugMenu:logEvent("RAGDOLL", "ended")

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

-- ─── FLOAT EVENTS (TARGET — this player is being floated) ────────────────────

FloatStartRemote.OnClientEvent:Connect(function(_duration: number)
	if not _session then
		return
	end
	local humanoid = _session.humanoid
	_debugMenu:logEvent("FLOAT", "float START (target)")

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
	_debugMenu:logEvent("FLOAT", "float END (target)")

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

-- ─── ATTACKER FLOAT (this player LAUNCHED the air combo) ─────────────────────
-- The server fires this so the attacker visually "jumps" with the target.
-- We apply an upward velocity directly — no humanoid state change needed,
-- the player can still move horizontally while rising.
AttackerFloatRemote.OnClientEvent:Connect(function(boostVelocity: number)
	if not _session then
		return
	end
	local hrp = _session.hrp
	_debugMenu:logEvent("FLOAT", ("attacker boost +%.0f"):format(boostVelocity))

	if hrp then
		-- Preserve horizontal velocity; override vertical
		local vel = hrp.AssemblyLinearVelocity
		hrp.AssemblyLinearVelocity = Vector3.new(vel.X, boostVelocity, vel.Z)
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
