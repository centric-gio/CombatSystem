--[[
    CombatServer.server.luau  v3
    ──────────────────────────────────────────────────────────
    CHANGES FROM v2:
      • Added AttackerFloat RemoteEvent (Server → attacker client).
        This fires when the attacker's air-combo launcher connects,
        telling their client to apply an upward velocity boost so
        they visually "jump" with the target.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CombatManager = require(script.Parent.CombatManager)

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

	-- Server → Client: hit results
	HitConfirmed = makeRemote("HitConfirmed"),
	BlockSync = makeRemote("BlockSync"),
	BlockBroken = makeRemote("BlockBroken"),
	ParrySuccess = makeRemote("ParrySuccess"),
	StateSync = makeRemote("StateSync"),

	-- Server → Client: ragdoll + air float (target)
	RagdollStart = makeRemote("RagdollStart"),
	RagdollEnd = makeRemote("RagdollEnd"),
	FloatStart = makeRemote("FloatStart"),
	FloatEnd = makeRemote("FloatEnd"),

	-- Server → Client: attacker air boost (NEW)
	AttackerFloat = makeRemote("AttackerFloat"),
}

CombatManager.init({
	HitConfirmed = Remotes.HitConfirmed,
	BlockSync = Remotes.BlockSync,
	BlockBroken = Remotes.BlockBroken,
	ParrySuccess = Remotes.ParrySuccess,
	StateSync = Remotes.StateSync,
	RagdollStart = Remotes.RagdollStart,
	RagdollEnd = Remotes.RagdollEnd,
	FloatStart = Remotes.FloatStart,
	FloatEnd = Remotes.FloatEnd,
	AttackerFloat = Remotes.AttackerFloat,
})

Remotes.AttackRequest.OnServerEvent:Connect(
	function(player: Player, payload: { comboIndex: number, clientTime: number, isAirCombo: boolean? })
		if type(payload) ~= "table" then
			return
		end
		CombatManager.handleAttackRequest(player, payload)
	end
)

Remotes.BlockState.OnServerEvent:Connect(function(player: Player, isBlocking: boolean)
	if type(isBlocking) ~= "boolean" then
		return
	end
	CombatManager.handleBlockState(player, isBlocking)
end)

print("[CombatServer] v3 ready. AttackerFloat remote included.")
