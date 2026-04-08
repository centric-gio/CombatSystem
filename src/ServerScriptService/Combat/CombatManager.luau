--[[
    CombatManager.luau  (Server)
    ──────────────────────────────────────────────────────────
    Per-player server-authoritative combat state.
    Owns:
      • Server-side state machine per player (Idle/Attacking/Blocking/etc.)
      • Block meter storage (authoritative)
      • Parry validation (compares server timestamps)
      • Rate limiting for attack requests
      • Damage application via Humanoid:TakeDamage()
      • Regen loop for block meter

    Does NOT own:
      • Visual effects (fired to clients via remotes)
      • Input (received from remotes, validated here)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

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
	blockStartTime: number, -- os.clock() when block started
	lastHitTime: number, -- os.clock() of last block-hit (for regen delay)
	lastAttackTime: number, -- os.clock() of last accepted attack (rate limiter)
	regenConn: RBXScriptConnection?,
}

-- ─── MODULE ──────────────────────────────────────────────────────────────────
local CombatManager = {}

-- Map: Player → PlayerData
local _playerData: { [Player]: PlayerData } = {}

-- ─── NPC COMBAT DATA ─────────────────────────────────────────────────────────
-- Mirrors PlayerData but keyed by character Model.
-- Callbacks let DummySpawner AI react to hit events without polling.
type NPCCombatData = {
	blockMeter: number,
	blockBroken: boolean,
	blockStartTime: number, -- os.clock() when block was last activated
	lastHitTime: number,
	isBlocking: boolean,
	isStunned: boolean,
	stunUntil: number, -- os.clock() timestamp when stun expires
	onBlockBroken: (() -> ())?,
	onParried: (() -> ())?,
	onHit: ((damage: number) -> ())?,
}

local _npcData: { [Model]: NPCCombatData } = {}

-- Remote references (set by CombatServer.server.luau after creation)
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
	})

	-- Register existing players (Studio test case)
	for _, player in ipairs(Players:GetPlayers()) do
		CombatManager.onPlayerAdded(player)
	end

	Players.PlayerAdded:Connect(CombatManager.onPlayerAdded)
	Players.PlayerRemoving:Connect(CombatManager.onPlayerRemoving)

	-- Block meter regen loop — runs every 0.5s to avoid per-frame cost.
	-- 0.5s granularity is imperceptible for a regen mechanic.
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

				-- Only regen after REGEN_DELAY has passed since last hit.
				if (now - data.lastHitTime) < CombatConfig.BLOCK_REGEN_DELAY then
					continue
				end

				-- Don't regen while actively blocking (holding F).
				if data.stateMachine:is("Blocking") then
					continue
				end

				local newMeter =
					math.min(data.blockMeter + CombatConfig.BLOCK_REGEN_RATE * 0.5, CombatConfig.BLOCK_MAX_METER)

				if newMeter ~= data.blockMeter then
					data.blockMeter = newMeter
					_remotes.BlockSync:FireClient(player, {
						meter = newMeter,
						isBroken = false,
					})
				end
			end
		end
	end)
end

-- ─── PLAYER LIFECYCLE ────────────────────────────────────────────────────────

function CombatManager.onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function(_character: Model)
		CombatManager._initPlayerData(player)
	end)
	-- Handle already-spawned character
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
	-- Destroy old data if respawning
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
				-- Sync stun state to client
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

-- ─── ATTACK REQUEST HANDLER ──────────────────────────────────────────────────

function CombatManager.handleAttackRequest(attacker: Player, payload: { comboIndex: number, clientTime: number })
	local attackerData = _playerData[attacker]
	if not attackerData then
		return
	end

	local attackerChar = attacker.Character
	if not attackerChar then
		return
	end

	-- ── Rate Limit ───────────────────────────────────────
	local now = os.clock()
	if (now - attackerData.lastAttackTime) < CombatConfig.MIN_ATTACK_INTERVAL then
		warn(("[CombatManager] Rate limit hit for %s"):format(attacker.Name))
		return
	end
	attackerData.lastAttackTime = now

	-- ── State Check ──────────────────────────────────────
	local sm = attackerData.stateMachine
	if sm:is("Stunned") or sm:is("Dead") or sm:is("Blocking") then
		return -- server rejects the request silently
	end

	-- ── Validate Combo Index ─────────────────────────────
	local comboIndex = payload.comboIndex
	if type(comboIndex) ~= "number" or comboIndex < 1 or comboIndex > CombatConfig.COMBO_COUNT then
		warn(("[CombatManager] Invalid comboIndex %s from %s"):format(tostring(comboIndex), attacker.Name))
		return
	end

	local hitData = CombatConfig.COMBO_HITS[comboIndex]
	if not hitData then
		return
	end

	-- ── Transition Server State ───────────────────────────
	if not sm:is("Attacking") then
		sm:transition("Attacking")
	end

	-- ── Cast Hitbox ───────────────────────────────────────
	local hits = HitboxService.cast(attackerChar, hitData.hitboxSize, hitData.hitboxOffset)

	-- ── Process Each Hit ─────────────────────────────────
	local isAirCombo = (payload.isAirCombo == true) and (comboIndex == CombatConfig.COMBO_COUNT) -- only valid on the finisher

	for _, candidate in ipairs(hits) do
		CombatManager._processHit(attacker, attackerData, candidate, hitData, isAirCombo)
	end

	-- Return attacker to Idle after action duration.
	-- A real implementation would use a more precise timer keyed to animation.
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
	isAirCombo: boolean? -- only true on hit 4 with space held
)
	isAirCombo = isAirCombo == true -- normalise nil → false
	local now = os.clock()
	local wasBlocked = false
	local wasParried = false
	local blockBroken = false
	local damageToDeal = hitData.damage

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

			if timeSince <= CombatConfig.BLOCK_PARRY_WINDOW and not hitData.isHeavy then
				wasParried = true
				if attacker then
					CombatManager._applyParry(attacker, targetPlayer)
				end
				return
			end

			wasBlocked = true
			damageToDeal = math.ceil(hitData.damage * CombatConfig.BLOCK_DAMAGE_MULT)

			local newMeter = targetData.blockMeter - hitData.blockMeterDamage
			targetData.lastHitTime = now

			if newMeter <= 0 then
				newMeter = 0
				blockBroken = true
				targetData.blockMeter = 0
				targetData.blockBroken = true

				targetSM:forceTransition("Stunned")
				_remotes.BlockBroken:FireClient(targetPlayer)
				_remotes.BlockSync:FireClient(targetPlayer, {
					meter = 0,
					isBroken = true,
				})

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
				_remotes.BlockSync:FireClient(targetPlayer, {
					meter = newMeter,
					isBroken = false,
				})

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

		-- ── Hit 4 finisher: ragdoll OR air float ─────────
		-- isHeavy marks the combo finisher (hit 4).
		-- We skip this if the hit was blocked to avoid ragdolling through a guard.
		if hitData.isHeavy and not wasBlocked and not wasParried then
			if isAirCombo then
				-- Air combo: launch the target upward and suspend them.
				-- Target is force-transitioned to Stunned so they can't block
				-- or attack while floating. Stun recovers when FloatEnd fires.
				targetSM:forceTransition("Stunned")
				RagdollService.float(candidate.character, candidate.player)
			else
				-- Normal finisher: full ragdoll with knockback.
				-- World-space knockback computed from attacker's facing direction.
				local attackerChar = attacker and attacker.Character
				local aHRP = attackerChar and attackerChar:FindFirstChild("HumanoidRootPart") :: BasePart?
				local worldKB = aHRP and aHRP.CFrame:VectorToWorldSpace(CombatConfig.RAGDOLL_VELOCITY)
					or CombatConfig.RAGDOLL_VELOCITY

				targetSM:forceTransition("Stunned")
				RagdollService.ragdoll(candidate.character, candidate.player, worldKB)
			end
		end

		-- ── Regular knockback for hits 1–3 ───────────────
		if attacker then
			local attackerChar = attacker.Character
			if attackerChar then
				local aHRP = attackerChar:FindFirstChild("HumanoidRootPart") :: BasePart?
				if aHRP then
					local worldKB = aHRP.CFrame:VectorToWorldSpace(hitData.knockback)
					candidate.hrp.AssemblyLinearVelocity = worldKB
				end
			end
		end

		-- Notify attacker of result
		if attacker then
			_remotes.HitConfirmed:FireClient(attacker, {
				targetUserId = targetPlayer.UserId,
				damage = damageToDeal,
				wasBlocked = wasBlocked,
				wasParried = wasParried,
				blockBroken = blockBroken,
				newBlockMeter = targetData.blockMeter,
				position = candidate.hrp.Position,
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

	-- Respect block-break stun: ignore hits until stun expires
	if npcData.isStunned and os.clock() < npcData.stunUntil then
		return
	end

	if npcData.isBlocking and not npcData.blockBroken then
		local timeSince = now - npcData.blockStartTime

		-- Perfect parry check
		if timeSince <= CombatConfig.BLOCK_PARRY_WINDOW and not hitData.isHeavy then
			wasParried = true
			if attacker then
				CombatManager._applyParry(attacker, nil)
			end
			if npcData.onParried then
				npcData.onParried()
			end
			return
		end

		-- Regular block
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
			targetUserId = 0, -- 0 signals "NPC target" to the client
			damage = damageToDeal,
			wasBlocked = wasBlocked,
			wasParried = wasParried,
			blockBroken = blockBroken,
			newBlockMeter = npcData.blockMeter,
			position = candidate.hrp.Position,
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

	-- The 4th argument "parried" tells the client to trigger
	-- the B&W screen effect in addition to the normal stun handling.
	_remotes.StateSync:FireClient(attacker, "Stunned", CombatConfig.PARRY_STUN_DURATION, "parried")
	-- Only send ParrySuccess to human defenders (not NPCs)
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

-- ─── BLOCK STATE HANDLER ─────────────────────────────────────────────────────

function CombatManager.handleBlockState(player: Player, isBlocking: boolean)
	local data = _playerData[player]
	if not data then
		return
	end

	if isBlocking then
		-- Validate: can only block from Idle
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

-- Register a character model as a hittable NPC with optional event callbacks.
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
	-- Also register in HitboxService so the overlap query picks it up.
	HitboxService.registerNPC(character)
end

function CombatManager.unregisterNPC(character: Model)
	_npcData[character] = nil
	HitboxService.unregisterNPC(character)
end

-- Toggle blocking state on an NPC (resets meter broken flag on activation).
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

-- Called every ~0.08s by PerfectParryDummy to keep its parry window fresh.
-- This simulates a player who perfectly times their block every time.
function CombatManager.refreshNPCParryWindow(character: Model)
	local data = _npcData[character]
	if not data then
		return
	end
	data.blockStartTime = os.clock()
	data.isBlocking = true
	data.blockBroken = false
end

-- Fire an NPC melee attack that targets nearby players only.
-- Casts a hitbox from the NPC's HRP position/facing.
function CombatManager.npcAttack(attackerCharacter: Model, comboIndex: number)
	local hitData = CombatConfig.COMBO_HITS[comboIndex]
	if not hitData then
		return
	end

	local hits = HitboxService.cast(attackerCharacter, hitData.hitboxSize, hitData.hitboxOffset)

	for _, candidate in ipairs(hits) do
		-- NPC attackers only hit players; no NPC vs NPC for now.
		if not candidate.player then
			continue
		end
		CombatManager._processHit(nil, nil, candidate, hitData, false)
	end
end

return CombatManager
