--[[
    CombatServer.server.luau  v2
    Creates all remotes including ragdoll/float, inits CombatManager.
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

	-- Server → Client: ragdoll + air float
	RagdollStart = makeRemote("RagdollStart"),
	RagdollEnd = makeRemote("RagdollEnd"),
	FloatStart = makeRemote("FloatStart"),
	FloatEnd = makeRemote("FloatEnd"),
}

-- Init CombatManager — this also calls RagdollService.init() internally.
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

print("[CombatServer] All remotes created. RagdollStart/End + FloatStart/End included.")
