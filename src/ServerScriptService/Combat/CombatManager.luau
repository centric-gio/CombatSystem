--[[
    CombatManager.luau  (Server)  v3
    ──────────────────────────────────────────────────────────
    CHANGES FROM v2:
      • COMBO_COUNT is now 5. All hits are non-heavy (isHeavy removed).
      • Ragdoll / float trigger: comboIndex == CombatConfig.COMBO_COUNT
        (i.e., hit 5), NOT hitData.isHeavy. This removes the isHeavy
        gating and makes the ragdoll purely positional in the combo.
      • _processHit now receives attackerPlayer explicitly so we can
        pass them to RagdollService.float as the attacker that gets
        the air boost remote.
      • RagdollService.float signature updated:
          float(character, targetPlayer, attackerPlayer)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConfig = require(ReplicatedStorage.Shared.CombatConfig)
local StateMachine = require(ReplicatedStorage.Shared.StateMachine)
local HitboxService = require(script.Parent.HitboxService)
local RagdollService = require(script.Parent.RagdollService)

-- ─── TYPES ───────────────────────────────────────────────────────────────────
type PlayerData = {
	stateMachine: typeof(StateMachine.new("Idle", {})),
	blockMeter: number,
	blockBroken: boolean,
	blockStartTime: number,
	lastHitTime: number,
	lastAttackTime: number,
}

type NPCCombatData = {
	blockMeter: number,
	blockBroken: boolean,
	blockStartTime: number,
	lastHitTime: number,
	isBlocking: boolean,
	isStunned: boolean,
	stunUntil: number,
	onBlockBroken: (() -> ())?,
	onParried: (() -> ())?,
	onHit: ((damage: number) -> ())?,
}

-- ─── MODULE ──────────────────────────────────────────────────────────────────
local CombatManager = {}

local _playerData: { [Player]: PlayerData } = {}
local _npcData: { [Model]: NPCCombatData } = {}

local _remotes: {
	HitConfirmed: RemoteEvent,
	BlockSync: RemoteEvent,
	BlockBroken: RemoteEvent,
	ParrySuccess: RemoteEvent,
	StateSync: RemoteEvent,
	RagdollStart: RemoteEvent,
	RagdollEnd: RemoteEvent,
	FloatStart: RemoteEvent,
	FloatEnd: RemoteEvent,
	AttackerFloat: RemoteEvent,
} =
	{} :: any

-- ─── INIT ────────────────────────────────────────────────────────────────────

function CombatManager.init(remotes: typeof(_remotes))
	_remotes = remotes
	RagdollService.init({
		RagdollStart = remotes.RagdollStart,
		RagdollEnd = remotes.RagdollEnd,
		FloatStart = remotes.FloatStart,
		FloatEnd = remotes.FloatEnd,
		AttackerFloat = remotes.AttackerFloat,
	})

	for _, player in ipairs(Players:GetPlayers()) do
		CombatManager.onPlayerAdded(player)
	end
	Players.PlayerAdded:Connect(CombatManager.onPlayerAdded)
	Players.PlayerRemoving:Connect(CombatManager.onPlayerRemoving)

	-- Block regen loop: runs every 0.5s (cheap)
	task.spawn(function()
		while true do
			task.wait(0.5)
			local now = os.clock()
			for player, data in pairs(_playerData) do
				if data.blockBroken then
					continue
				end
				if data.blockMeter >= CombatConfig.BLOCK_MAX_METER then
					continue
				end
				if (now - data.lastHitTime) < CombatConfig.BLOCK_REGEN_DELAY then
					continue
				end
				if data.stateMachine:is("Blocking") then
					continue
				end

				local newMeter =
					math.min(data.blockMeter + CombatConfig.BLOCK_REGEN_RATE * 0.5, CombatConfig.BLOCK_MAX_METER)
				if newMeter ~= data.blockMeter then
					data.blockMeter = newMeter
					_remotes.BlockSync:FireClient(player, { meter = newMeter, isBroken = false })
				end
			end
		end
	end)
end

-- ─── PLAYER LIFECYCLE ────────────────────────────────────────────────────────

function CombatManager.onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function(_char: Model)
		CombatManager._initPlayerData(player)
	end)
	if player.Character then
		CombatManager._initPlayerData(player)
	end
end

function CombatManager.onPlayerRemoving(player: Player)
	local data = _playerData[player]
	if data then
		data.stateMachine:destroy()
		_playerData[player] = nil
	end
end

function CombatManager._initPlayerData(player: Player)
	if _playerData[player] then
		_playerData[player].stateMachine:destroy()
	end

	local sm = StateMachine.new("Idle", {
		Idle = { canTransitionTo = { "Attacking", "Blocking", "Stunned", "Dead" } },
		Attacking = { canTransitionTo = { "Idle", "Stunned", "Dead" } },
		Blocking = { canTransitionTo = { "Idle", "BlockStun", "Stunned", "Dead" } },
		BlockStun = { canTransitionTo = { "Idle", "Blocking", "Dead" } },
		Stunned = {
			canTransitionTo = { "Idle", "Dead" },
			onEnter = function(_prev)
				_remotes.StateSync:FireClient(player, "Stunned")
			end,
		},
		Dead = {
			canTransitionTo = {},
			onEnter = function(_prev)
				_remotes.StateSync:FireClient(player, "Dead")
			end,
		},
	})

	_playerData[player] = {
		stateMachine = sm,
		blockMeter = CombatConfig.BLOCK_MAX_METER,
		blockBroken = false,
		blockStartTime = 0,
		lastHitTime = 0,
		lastAttackTime = 0,
	}
end

-- ─── ATTACK REQUEST ──────────────────────────────────────────────────────────

function CombatManager.handleAttackRequest(
	attacker: Player,
	payload: { comboIndex: number, clientTime: number, isAirCombo: boolean? }
)
	local attackerData = _playerData[attacker]
	if not attackerData then
		return
	end
	local attackerChar = attacker.Character
	if not attackerChar then
		return
	end

	-- Rate limit
	local now = os.clock()
	if (now - attackerData.lastAttackTime) < CombatConfig.MIN_ATTACK_INTERVAL then
		warn(("[CombatManager] Rate limit: %s"):format(attacker.Name))
		return
	end
	attackerData.lastAttackTime = now

	-- State check
	local sm = attackerData.stateMachine
	if sm:is("Stunned") or sm:is("Dead") or sm:is("Blocking") then
		return
	end

	-- Validate combo index
	local comboIndex = payload.comboIndex
	if type(comboIndex) ~= "number" or comboIndex < 1 or comboIndex > CombatConfig.COMBO_COUNT then
		warn(("[CombatManager] Invalid comboIndex %s from %s"):format(tostring(comboIndex), attacker.Name))
		return
	end

	local hitData = CombatConfig.COMBO_HITS[comboIndex]
	if not hitData then
		return
	end

	if not sm:is("Attacking") then
		sm:transition("Attacking")
	end

	local hits = HitboxService.cast(attackerChar, hitData.hitboxSize, hitData.hitboxOffset)

	-- isAirCombo is only valid on the LAST hit (hit 5)
	local isAirCombo = (payload.isAirCombo == true) and (comboIndex == CombatConfig.COMBO_COUNT)

	for _, candidate in ipairs(hits) do
		CombatManager._processHit(attacker, attackerData, candidate, hitData, comboIndex, isAirCombo)
	end

	-- Return attacker to Idle after action recovery
	task.delay(hitData.totalDuration, function()
		if _playerData[attacker] == attackerData and sm:is("Attacking") then
			sm:transition("Idle")
		end
	end)
end

-- ─── HIT PROCESSING ──────────────────────────────────────────────────────────

function CombatManager._processHit(
	attacker: Player?,
	_attackerData: PlayerData?,
	candidate: HitboxService.HitCandidate,
	hitData: typeof(CombatConfig.COMBO_HITS[1]),
	comboIndex: number,
	isAirCombo: boolean?
)
	isAirCombo = isAirCombo == true
	local now = os.clock()
	local wasBlocked = false
	local wasParried = false
	local blockBroken = false
	local damageToDeal = hitData.damage

	-- ── Is this the finisher hit? ─────────────────────────
	-- Ragdoll/float is triggered on hit 5, regardless of isHeavy.
	local isFinisher = (comboIndex == CombatConfig.COMBO_COUNT)

	-- ─────────────────────────────────────────────────────────
	-- BRANCH A: Player target
	-- ─────────────────────────────────────────────────────────
	if candidate.player then
		local targetPlayer = candidate.player
		local targetData = _playerData[targetPlayer]
		if not targetData then
			return
		end

		local targetSM = targetData.stateMachine
		if targetSM:is("Dead") then
			return
		end

		-- Parry / block check
		if targetSM:is("Blocking") and not targetData.blockBroken then
			local timeSince = now - targetData.blockStartTime

			-- Parry window check — works on ALL hits (no isHeavy exclusion)
			if timeSince <= CombatConfig.BLOCK_PARRY_WINDOW then
				wasParried = true
				if attacker then
					CombatManager._applyParry(attacker, targetPlayer)
				end
				return
			end

			-- Regular block
			wasBlocked = true
			damageToDeal = math.ceil(hitData.damage * CombatConfig.BLOCK_DAMAGE_MULT)
			targetData.lastHitTime = now

			local newMeter = targetData.blockMeter - hitData.blockMeterDamage
			if newMeter <= 0 then
				newMeter = 0
				blockBroken = true
				targetData.blockMeter = 0
				targetData.blockBroken = true
				targetSM:forceTransition("Stunned")
				_remotes.BlockBroken:FireClient(targetPlayer)
				_remotes.BlockSync:FireClient(targetPlayer, { meter = 0, isBroken = true })

				task.delay(CombatConfig.BLOCK_BREAK_STUN, function()
					if _playerData[targetPlayer] == targetData then
						targetData.blockBroken = false
						targetData.blockMeter = 0
						if targetSM:is("Stunned") then
							targetSM:transition("Idle")
							_remotes.StateSync:FireClient(targetPlayer, "Idle")
						end
					end
				end)
			else
				targetData.blockMeter = newMeter
				_remotes.BlockSync:FireClient(targetPlayer, { meter = newMeter, isBroken = false })

				if not targetSM:is("BlockStun") then
					targetSM:transition("BlockStun")
					task.delay(CombatConfig.BLOCK_STUN_DURATION, function()
						if _playerData[targetPlayer] == targetData and targetSM:is("BlockStun") then
							targetSM:transition("Blocking")
						end
					end)
				end
			end
		end

		candidate.humanoid:TakeDamage(damageToDeal)

		-- ── Finisher (hit 5): ragdoll OR air float ─────────
		if isFinisher and not wasBlocked and not wasParried then
			local attackerChar = attacker and attacker.Character
			local aHRP = attackerChar and attackerChar:FindFirstChild("HumanoidRootPart") :: BasePart?

			if isAirCombo then
				-- Air combo: target floats, attacker gets air boost
				targetSM:forceTransition("Stunned")
				RagdollService.float(candidate.character, targetPlayer, attacker)
			else
				-- Ground finisher: ragdoll with knockback
				local worldKB = aHRP and aHRP.CFrame:VectorToWorldSpace(CombatConfig.RAGDOLL_VELOCITY)
					or CombatConfig.RAGDOLL_VELOCITY
				targetSM:forceTransition("Stunned")
				RagdollService.ragdoll(candidate.character, targetPlayer, worldKB)
			end
		end

		-- Regular knockback for hits 1–4 (and blocked finisher)
		if not isFinisher or wasBlocked then
			local attackerChar = attacker and attacker.Character
			local aHRP = attackerChar and attackerChar:FindFirstChild("HumanoidRootPart") :: BasePart?
			if aHRP then
				local worldKB = aHRP.CFrame:VectorToWorldSpace(hitData.knockback)
				candidate.hrp.AssemblyLinearVelocity = worldKB
			end
		end

		if attacker then
			_remotes.HitConfirmed:FireClient(attacker, {
				targetUserId = targetPlayer.UserId,
				damage = damageToDeal,
				wasBlocked = wasBlocked,
				wasParried = wasParried,
				blockBroken = blockBroken,
				newBlockMeter = targetData.blockMeter,
				position = candidate.hrp.Position,
				comboIndex = comboIndex,
			})
		end
		return
	end

	-- ─────────────────────────────────────────────────────────
	-- BRANCH B: NPC target
	-- ─────────────────────────────────────────────────────────
	local npcData = _npcData[candidate.character]
	if not npcData then
		return
	end

	if npcData.isStunned and os.clock() < npcData.stunUntil then
		return
	end

	if npcData.isBlocking and not npcData.blockBroken then
		local timeSince = now - npcData.blockStartTime

		if timeSince <= CombatConfig.BLOCK_PARRY_WINDOW then
			wasParried = true
			if attacker then
				CombatManager._applyParry(attacker, nil)
			end
			if npcData.onParried then
				npcData.onParried()
			end
			return
		end

		wasBlocked = true
		damageToDeal = math.ceil(hitData.damage * CombatConfig.BLOCK_DAMAGE_MULT)
		npcData.lastHitTime = now

		local newMeter = npcData.blockMeter - hitData.blockMeterDamage
		if newMeter <= 0 then
			newMeter = 0
			blockBroken = true
			npcData.blockMeter = 0
			npcData.blockBroken = true
			npcData.isBlocking = false
			npcData.isStunned = true
			npcData.stunUntil = now + CombatConfig.BLOCK_BREAK_STUN
			if npcData.onBlockBroken then
				npcData.onBlockBroken()
			end
		else
			npcData.blockMeter = newMeter
		end
	end

	candidate.humanoid:TakeDamage(damageToDeal)
	if npcData.onHit then
		npcData.onHit(damageToDeal)
	end

	if attacker then
		_remotes.HitConfirmed:FireClient(attacker, {
			targetUserId = 0,
			damage = damageToDeal,
			wasBlocked = wasBlocked,
			wasParried = wasParried,
			blockBroken = blockBroken,
			newBlockMeter = npcData.blockMeter,
			position = candidate.hrp.Position,
			comboIndex = comboIndex,
		})
	end
end

-- ─── PARRY ───────────────────────────────────────────────────────────────────

function CombatManager._applyParry(attacker: Player, defender: Player?)
	local attackerData = _playerData[attacker]
	if not attackerData then
		return
	end

	local sm = attackerData.stateMachine
	sm:forceTransition("Stunned")

	_remotes.StateSync:FireClient(attacker, "Stunned", CombatConfig.PARRY_STUN_DURATION, "parried")
	if defender then
		_remotes.ParrySuccess:FireClient(defender)
	end

	task.delay(CombatConfig.PARRY_STUN_DURATION, function()
		if _playerData[attacker] == attackerData and sm:is("Stunned") then
			sm:transition("Idle")
			_remotes.StateSync:FireClient(attacker, "Idle")
		end
	end)
end

-- ─── BLOCK STATE ─────────────────────────────────────────────────────────────

function CombatManager.handleBlockState(player: Player, isBlocking: boolean)
	local data = _playerData[player]
	if not data then
		return
	end

	if isBlocking then
		if data.stateMachine:is("Idle") then
			data.stateMachine:transition("Blocking")
			data.blockStartTime = os.clock()
		end
	else
		if data.stateMachine:is("Blocking") or data.stateMachine:is("BlockStun") then
			data.stateMachine:transition("Idle")
		end
	end
end

-- ─── NPC PUBLIC API ──────────────────────────────────────────────────────────

function CombatManager.registerNPC(
	character: Model,
	options: {
		onBlockBroken: (() -> ())?,
		onParried: (() -> ())?,
		onHit: ((damage: number) -> ())?,
	}?
)
	_npcData[character] = {
		blockMeter = CombatConfig.BLOCK_MAX_METER,
		blockBroken = false,
		blockStartTime = 0,
		lastHitTime = 0,
		isBlocking = false,
		isStunned = false,
		stunUntil = 0,
		onBlockBroken = options and options.onBlockBroken or nil,
		onParried = options and options.onParried or nil,
		onHit = options and options.onHit or nil,
	}
	HitboxService.registerNPC(character)
end

function CombatManager.unregisterNPC(character: Model)
	_npcData[character] = nil
	HitboxService.unregisterNPC(character)
end

function CombatManager.setNPCBlocking(character: Model, isBlocking: boolean)
	local data = _npcData[character]
	if not data then
		return
	end
	data.isBlocking = isBlocking
	data.blockBroken = false
	if isBlocking then
		data.blockStartTime = os.clock()
	end
end

function CombatManager.refreshNPCParryWindow(character: Model)
	local data = _npcData[character]
	if not data then
		return
	end
	data.blockStartTime = os.clock()
	data.isBlocking = true
	data.blockBroken = false
end

function CombatManager.npcAttack(attackerCharacter: Model, comboIndex: number)
	local hitData = CombatConfig.COMBO_HITS[comboIndex]
	if not hitData then
		return
	end

	local hits = HitboxService.cast(attackerCharacter, hitData.hitboxSize, hitData.hitboxOffset)
	for _, candidate in ipairs(hits) do
		if not candidate.player then
			continue
		end
		CombatManager._processHit(nil, nil, candidate, hitData, comboIndex, false)
	end
end

return CombatManager
