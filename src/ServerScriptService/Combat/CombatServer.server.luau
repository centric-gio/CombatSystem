--[[
    CombatServer.server.luau
    ──────────────────────────────────────────────────────────
    Server entry point. Responsibilities:
      1. Creates all RemoteEvents in ReplicatedStorage.
      2. Initialises CombatManager with the remote references.
      3. Connects incoming remote events to their handlers.

    Keep this file THIN — no logic lives here, only wiring.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CombatManager = require(script.Parent.CombatManager)

-- ─── CREATE REMOTES ──────────────────────────────────────────────────────────
-- We create these at server startup so clients can :WaitForChild() them safely.

local folder = Instance.new("Folder")
folder.Name = "CombatRemotes"
folder.Parent = ReplicatedStorage

local function makeRemote(name: string): RemoteEvent
	local r = Instance.new("RemoteEvent")
	r.Name = name
	r.Parent = folder
	return r
end

local Remotes = {
	-- Client → Server
	AttackRequest = makeRemote("AttackRequest"),
	BlockState = makeRemote("BlockState"),

	-- Server → Client
	HitConfirmed = makeRemote("HitConfirmed"),
	BlockSync = makeRemote("BlockSync"),
	BlockBroken = makeRemote("BlockBroken"),
	ParrySuccess = makeRemote("ParrySuccess"),
	StateSync = makeRemote("StateSync"),
}

-- ─── INIT COMBAT MANAGER ─────────────────────────────────────────────────────
CombatManager.init({
	HitConfirmed = Remotes.HitConfirmed,
	BlockSync = Remotes.BlockSync,
	BlockBroken = Remotes.BlockBroken,
	ParrySuccess = Remotes.ParrySuccess,
	StateSync = Remotes.StateSync,
})

-- ─── INCOMING REMOTE HANDLERS ────────────────────────────────────────────────

-- Player requesting to perform a swing
Remotes.AttackRequest.OnServerEvent:Connect(
	function(player: Player, payload: { comboIndex: number, clientTime: number })
		-- Basic type-safety check before passing to CombatManager.
		if type(payload) ~= "table" then
			return
		end

		CombatManager.handleAttackRequest(player, payload)
	end
)

-- Player toggling block on/off
Remotes.BlockState.OnServerEvent:Connect(function(player: Player, isBlocking: boolean)
	if type(isBlocking) ~= "boolean" then
		return
	end

	CombatManager.handleBlockState(player, isBlocking)
end)

print("[CombatServer] Initialised. Remotes created in ReplicatedStorage.CombatRemotes")
