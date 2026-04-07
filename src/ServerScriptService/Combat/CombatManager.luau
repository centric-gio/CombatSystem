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

-- Remote references (set by CombatServer.server.luau after creation)
local _remotes: {
	HitConfirmed: RemoteEvent,
	BlockSync: RemoteEvent,
	BlockBroken: RemoteEvent,
	ParrySuccess: RemoteEvent,
	StateSync: RemoteEvent,
} =
	{} :: any

-- ─── INIT ────────────────────────────────────────────────────────────────────

function CombatManager.init(remotes: typeof(_remotes))
	_remotes = remotes

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
	for _, candidate in ipairs(hits) do
		CombatManager._processHit(attacker, attackerData, candidate, hitData)
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
	attacker: Player,
	_attackerData: PlayerData,
	candidate: HitboxService.HitCandidate,
	hitData: typeof(CombatConfig.COMBO_HITS[1])
)
	local targetPlayer = candidate.player
	local targetData = _playerData[targetPlayer]
	if not targetData then
		return
	end

	local targetSM = targetData.stateMachine

	-- Dead targets shouldn't receive hits.
	if targetSM:is("Dead") then
		return
	end

	local now = os.clock()
	local wasBlocked = false
	local wasParried = false
	local blockBroken = false
	local damageToDeal = hitData.damage

	-- ── Parry / Block Check ───────────────────────────────
	if targetSM:is("Blocking") and not targetData.blockBroken then
		local timeSinceBlockStart = now - targetData.blockStartTime

		-- Perfect parry: block started within PARRY_WINDOW seconds, hit is not heavy.
		if timeSinceBlockStart <= CombatConfig.BLOCK_PARRY_WINDOW and not hitData.isHeavy then
			wasParried = true
			CombatManager._applyParry(attacker, targetPlayer)
			return -- no damage applied on a parry
		end

		-- Regular block: reduce damage and drain block meter.
		wasBlocked = true
		damageToDeal = math.ceil(hitData.damage * CombatConfig.BLOCK_DAMAGE_MULT)

		local newMeter = targetData.blockMeter - hitData.blockMeterDamage
		targetData.lastHitTime = now

		if newMeter <= 0 then
			-- Block breaks!
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

			-- Auto-recover from block-break stun
			task.delay(CombatConfig.BLOCK_BREAK_STUN, function()
				if _playerData[targetPlayer] == targetData then
					targetData.blockBroken = false
					targetData.blockMeter = 0 -- start at 0, let regen bring it back
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

			-- Brief block-stun on defender
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

	-- ── Apply Damage ──────────────────────────────────────
	-- Humanoid:TakeDamage() respects ForceField automatically.
	candidate.humanoid:TakeDamage(damageToDeal)

	-- ── Apply Knockback ───────────────────────────────────
	-- Convert local-space knockback to world space.
	local attackerChar = attacker.Character
	if attackerChar then
		local hrp = attackerChar:FindFirstChild("HumanoidRootPart") :: BasePart?
		local targetHRP = candidate.hrp
		if hrp and targetHRP then
			local worldKnockback = hrp.CFrame:VectorToWorldSpace(hitData.knockback)
			local targetVelocity = targetHRP:FindFirstChildOfClass("LinearVelocity") :: LinearVelocity?

			-- Use VectorForce / LinearVelocity (Assembly API) for knockback.
			-- Fallback: direct AssemblyLinearVelocity assignment (works but less smooth).
			-- TODO: Replace with a proper VectorForce + timer for smooth knockback.
			targetHRP.AssemblyLinearVelocity = worldKnockback
		end
	end

	-- ── Notify Attacker of Hit Result ─────────────────────
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

-- ─── PARRY ───────────────────────────────────────────────────────────────────

function CombatManager._applyParry(attacker: Player, defender: Player)
	local attackerData = _playerData[attacker]
	if not attackerData then
		return
	end

	-- Stun the attacker.
	local sm = attackerData.stateMachine
	sm:forceTransition("Stunned")

	-- Notify both sides.
	_remotes.StateSync:FireClient(attacker, "Stunned", CombatConfig.PARRY_STUN_DURATION)
	_remotes.ParrySuccess:FireClient(defender)

	-- Auto-recover attacker after stun.
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

return CombatManager
