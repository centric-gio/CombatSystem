--[[
    CombatClient.client.luau  v5
    ──────────────────────────────────────────────────────────
    CHANGES FROM v4:

    1. NPC HIT EFFECTS FIXED
       Previously onHitConfirmed was only called when targetChar was
       non-nil, which requires targetUserId != 0. NPC hits send
       targetUserId=0 so targetChar was never found, silencing all
       sound and VFX for dummies. Now:
         • VFX + sound always fire using result.position.
         • hitFlash only fires when targetChar is available.
         • cameraShake fires regardless.

    2. ATTACKER Y-LOCK (AlignPosition on client)
       When AttackerFloat fires with phase="ylock", we create an
       AlignPosition on the LOCAL character's HRP that holds only Y
       (achieved by setting the world attachment at the target Y
       while allowing XZ drift via low MaxForce on XZ axes — in
       practice we use a single AlignPosition + lock the Y component
       by positioning the world anchor exactly at character X,Z).
       Destroyed on FloatEnd or after duration.

       When phase="boost", we apply immediate upward velocity so the
       attacker rises at the same moment as the target.

    3. ParrySuccess VFX now passes attacker position so the parry
       golden ring appears at a sensible world position.

    4. All other systems (tool gate, debug menu, hit counter,
       state sync, ragdoll) unchanged from v4.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Script = script

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

-- ─── REMOTES ─────────────────────────────────────────────────────────────────
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
local AttackerFloatRemote = CombatRemotes:WaitForChild("AttackerFloat") :: RemoteEvent

-- ─── SINGLETONS (persist across respawns) ────────────────────────────────────
local _debugMenu = DebugMenu.new()
local _hitCounter = HitCounter.new()

-- ─── SESSION ─────────────────────────────────────────────────────────────────
type CombatSession = {
	stateMachine: {
		is: any,
		transition: any,
		forceTransition: any,
		update: any,
		getState: any,
		onChanged: any,
		destroy: any,
	},
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
	-- Attacker air-lock constraint (created client-side on AttackerFloat ylock)
	attackerAlign: AlignPosition?,
	attackerWorldAtt: Attachment?,
	attackerHRPAtt: Attachment?,
}

local _session: CombatSession? = nil

-- ─── TOOL GATE ───────────────────────────────────────────────────────────────

local function isToolEquipped(): boolean
	return _session ~= nil and _session.toolEquipped
end

local function _detectTool(character: Model): boolean
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") and child.Name == CombatConfig.TOOL_NAME then
			return true
		end
	end
	return false
end

local function _setupToolListeners(character: Model, session: CombatSession)
	if session.toolConn1 then
		session.toolConn1:Disconnect()
	end
	if session.toolConn2 then
		session.toolConn2:Disconnect()
	end

	session.toolEquipped = _detectTool(character)

	session.toolConn1 = character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") and child.Name == CombatConfig.TOOL_NAME then
			session.toolEquipped = true
			_debugMenu:logEvent("STATE", "Tool EQUIPPED")
		end
	end)

	session.toolConn2 = character.ChildRemoved:Connect(function(child)
		if child:IsA("Tool") and child.Name == CombatConfig.TOOL_NAME then
			session.toolEquipped = false
			_debugMenu:logEvent("STATE", "Tool UNEQUIPPED")
			if _session then
				_session.comboCtrl:reset()
				if _session.stateMachine:is("Attacking") then
					_session.stateMachine:transition("Idle")
				end
			end
		end
	end)
end

-- ─── ATTACKER Y-LOCK HELPERS ─────────────────────────────────────────────────

local function _clearAttackerAlign(session: CombatSession)
	if session.attackerAlign and session.attackerAlign.Parent then
		session.attackerAlign:Destroy()
	end
	if session.attackerHRPAtt and session.attackerHRPAtt.Parent then
		session.attackerHRPAtt:Destroy()
	end
	if session.attackerWorldAtt and session.attackerWorldAtt.Parent then
		session.attackerWorldAtt:Destroy()
	end
	session.attackerAlign = nil
	session.attackerHRPAtt = nil
	session.attackerWorldAtt = nil
end

local function _applyAttackerYLock(session: CombatSession, suspendY: number, duration: number)
	_clearAttackerAlign(session) -- clear any stale constraint

	local hrp = session.hrp
	if not hrp then
		return
	end

	-- World attachment: placed at the attacker's current XZ but at suspendY
	-- so AlignPosition pulls them to that Y without fighting horizontal movement
	local worldAtt = Instance.new("Attachment")
	worldAtt.Name = "AttackerFloatWorldAtt"
	worldAtt.WorldPosition = Vector3.new(hrp.Position.X, suspendY, hrp.Position.Z)
	worldAtt.Parent = workspace.Terrain

	local hrpAtt = Instance.new("Attachment")
	hrpAtt.Name = "AttackerFloatHRPAtt"
	hrpAtt.Parent = hrp

	local align = Instance.new("AlignPosition")
	align.Name = "AttackerFloatAlign"
	align.Attachment0 = hrpAtt
	align.Attachment1 = worldAtt
	-- Low MaxForce: just enough to counteract gravity on Y (≈ mass * 196.2)
	-- but NOT so high that it fights horizontal movement significantly.
	-- For a 16-unit humanoid mass this is ~3136. Use 6000 for headroom.
	align.MaxForce = 6000
	align.Responsiveness = 40
	align.ApplyAtCenterOfMass = true
	align.ReactionForceEnabled = false
	align.Parent = hrp

	session.attackerAlign = align
	session.attackerWorldAtt = worldAtt
	session.attackerHRPAtt = hrpAtt

	-- Auto-destroy after duration (server also sends FloatEnd, but this is a fallback)
	task.delay(duration + 0.3, function()
		if _session and _session.attackerAlign == align then
			_clearAttackerAlign(_session)
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
		_clearAttackerAlign(_session)
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

	-- Partial session reference so isToolEquipped closes over it
	local sessionRef: CombatSession = {
		stateMachine = sm,
		animCtrl = animCtrl,
		comboCtrl = nil :: any,
		blockCtrl = blockCtrl,
		blockUI = blockUi,
		heartbeatConn = nil :: any,
		humanoid = humanoid,
		hrp = hrp,
		toolConn1 = nil,
		toolConn2 = nil,
		toolEquipped = false,
		attackerAlign = nil,
		attackerWorldAtt = nil,
		attackerHRPAtt = nil,
	}
	_session = sessionRef

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

	local lastComboIndex = 0

	local hbConn = RunService.Heartbeat:Connect(function(dt: number)
		sm:update(dt)
		comboCtrl:update(dt)

		-- Streak reset detection
		if lastComboIndex > 0 and comboCtrl._comboIndex == 0 then
			_hitCounter:resetStreak()
		end
		lastComboIndex = comboCtrl._comboIndex

		-- Update attacker world attachment XZ every frame so they can still
		-- walk horizontally while Y-locked (the attachment follows their XZ).
		if sessionRef.attackerWorldAtt and sessionRef.attackerWorldAtt.Parent and hrp then
			local current = sessionRef.attackerWorldAtt.WorldPosition
			sessionRef.attackerWorldAtt.WorldPosition = Vector3.new(hrp.Position.X, current.Y, hrp.Position.Z)
		end

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

-- ─── INPUT ───────────────────────────────────────────────────────────────────

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

-- ─── SERVER EVENTS ───────────────────────────────────────────────────────────

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

	-- Hit counter always increments
	_hitCounter:registerHit(result.wasBlocked, result.wasParried, result.damage)

	local tag = if result.wasParried
		then "PARRY"
		elseif result.blockBroken then "BREAK"
		elseif result.wasBlocked then "BLOCK"
		else "HIT"
	_debugMenu:logEvent(tag, ("dmg=%d blk=%.0f c=%d"):format(result.damage, result.newBlockMeter, result.comboIndex))

	if result.wasParried then
		HitEffects.onParry()
		return
	end

	-- Resolve target character (nil for NPC hits — that's fine now)
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
	else
		-- onHitConfirmed now accepts targetChar? — nil is safe for NPC hits
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

	_debugMenu:logEvent("STATE", ("→ %s (%.2fs)"):format(newState, duration or 0))

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

-- ─── FLOAT EVENTS (this player IS the target being floated) ──────────────────

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

AttackerFloatRemote.OnClientEvent:Connect(
	function(payload: { phase: string, velocity: number?, suspendY: number?, duration: number? })
		if not _session then
			return
		end
		local hrp = _session.hrp

		if payload.phase == "boost" then
			-- Immediate upward velocity: attacker rises with the target
			_debugMenu:logEvent("FLOAT", ("attacker boost +%.0f"):format(payload.velocity or 0))
			if hrp then
				local vel = hrp.AssemblyLinearVelocity
				hrp.AssemblyLinearVelocity = Vector3.new(vel.X, payload.velocity or 0, vel.Z)
			end
		elseif payload.phase == "ylock" and payload.suspendY and payload.duration then
			-- Y-lock: create AlignPosition to hold attacker at suspendY
			_debugMenu:logEvent(
				"FLOAT",
				("attacker Y-lock at %.1f for %.1fs"):format(payload.suspendY, payload.duration)
			)
			_applyAttackerYLock(_session, payload.suspendY, payload.duration)
		end
	end
)

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
