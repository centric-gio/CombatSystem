--[[
    RagdollService.luau  (Server)  v4
    ──────────────────────────────────────────────────────────
    CHANGES FROM v3:

    1. NO RAGDOLL JOINTS DURING AIR FLOAT
       float() no longer calls _buildRagdollJoints. The target stays
       in their humanoid pose, frozen mid-air by AlignPosition + the
       client's Physics Humanoid state. This removes the floppy look
       and lets the target be a valid combo target during the float.

    2. ATTACKER Y-LOCK (two-phase remote)
       AttackerFloat is fired TWICE to the attacker client:
         Phase "boost"  (t=0)    → apply upward velocity immediately
         Phase "ylock"  (t=0.18s)→ create a client-side AlignPosition
                                   that holds Y only, locking the
                                   attacker at (suspendY + 1.5) studs
                                   above the target's float height.
       The attacker can still move XZ freely. On FloatEnd the client
       destroys their own AlignPosition and recovers normally.

    3. DUMMY/ANCHORED HRP SUPPORT
       If the target HRP is Anchored, we unanchor it before applying
       velocity and AlignPosition (forces are no-ops on anchored parts).
       wasAnchored is stored in _activeFloats and the HRP is re-anchored
       on unfloat so the dummy returns to its original test state.

    4. CLEAN GROUND RAGDOLL UNCHANGED
       ragdoll() still builds BallSocket joints + fires RagdollStart.
       No changes to ground combo finisher behaviour.
]]

local CombatConfig = require(game:GetService("ReplicatedStorage").Shared.CombatConfig)

local RagdollService = {}

type Remotes = {
	RagdollStart: RemoteEvent,
	RagdollEnd: RemoteEvent,
	FloatStart: RemoteEvent,
	FloatEnd: RemoteEvent,
	AttackerFloat: RemoteEvent,
}

type FloatData = {
	worldAtt: Attachment,
	hrpAtt: Attachment,
	align: AlignPosition,
	wasAnchored: boolean,
}

local _remotes: Remotes = {} :: any
local _activeFloats: { [Model]: FloatData } = {}

-- R6 root joint — must NOT be disabled or the character detaches from HRP
local R6_ROOT_NAMES: { [string]: boolean } = {
	["RootJoint"] = true,
	["Root"] = true,
}

function RagdollService.init(remotes: Remotes)
	_remotes = remotes
end

-- ─── R6 BallSocket helpers ────────────────────────────────────────────────────

local function _buildRagdollJoints(character: Model)
	for _, desc in ipairs(character:GetDescendants()) do
		if not desc:IsA("Motor6D") then
			continue
		end
		local motor = desc :: Motor6D
		if R6_ROOT_NAMES[motor.Name] then
			continue
		end
		if not motor.Part0 or not motor.Part1 then
			continue
		end

		local att0 = Instance.new("Attachment")
		att0.CFrame = motor.C0
		att0.Name = "RgdAtt0"
		att0.Parent = motor.Part0

		local att1 = Instance.new("Attachment")
		att1.CFrame = motor.C1
		att1.Name = "RgdAtt1"
		att1.Parent = motor.Part1

		local bsc = Instance.new("BallSocketConstraint")
		bsc.Name = "RgdBSC"
		bsc.Attachment0 = att0
		bsc.Attachment1 = att1
		bsc.LimitsEnabled = true
		bsc.UpperAngle = 55
		bsc.TwistLimitsEnabled = false
		bsc.Parent = motor.Part0

		motor.Enabled = false
	end
end

local function _clearRagdollJoints(character: Model)
	for _, desc in ipairs(character:GetDescendants()) do
		if desc:IsA("BallSocketConstraint") and desc.Name == "RgdBSC" then
			desc:Destroy()
		elseif desc:IsA("Attachment") and (desc.Name == "RgdAtt0" or desc.Name == "RgdAtt1") then
			desc:Destroy()
		elseif desc:IsA("Motor6D") then
			desc.Enabled = true
		end
	end
end

-- ─── PUBLIC: Ground Ragdoll ───────────────────────────────────────────────────

function RagdollService.ragdoll(character: Model, targetPlayer: Player?, knockbackWorld: Vector3)
	_buildRagdollJoints(character)

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp and not hrp.Anchored then
		hrp.AssemblyLinearVelocity = knockbackWorld
	end

	if targetPlayer then
		_remotes.RagdollStart:FireClient(targetPlayer, knockbackWorld)
	end

	task.delay(CombatConfig.RAGDOLL_DURATION, function()
		if not (character and character.Parent) then
			return
		end
		RagdollService.unragdoll(character, targetPlayer)
	end)
end

function RagdollService.unragdoll(character: Model, targetPlayer: Player?)
	_clearRagdollJoints(character)
	if targetPlayer then
		_remotes.RagdollEnd:FireClient(targetPlayer)
	end
end

-- ─── PUBLIC: Air Float ────────────────────────────────────────────────────────

function RagdollService.float(character: Model, targetPlayer: Player?, attackerPlayer: Player?)
	if _activeFloats[character] then
		return
	end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	-- Temporarily unanchor so velocity and constraints work on test dummies
	local wasAnchored = hrp.Anchored
	if wasAnchored then
		hrp.Anchored = false
	end

	-- Immediate upward impulse on target
	hrp.AssemblyLinearVelocity = Vector3.new(0, CombatConfig.AIR_LAUNCH_VELOCITY, 0)

	-- Notify target client: lock humanoid, enter Physics
	if targetPlayer then
		_remotes.FloatStart:FireClient(targetPlayer, CombatConfig.AIR_FLOAT_DURATION)
	end

	-- Phase 1 for attacker: immediate upward boost so they rise with the target
	if attackerPlayer then
		_remotes.AttackerFloat:FireClient(attackerPlayer, {
			phase = "boost",
			velocity = CombatConfig.ATTACKER_AIR_BOOST,
			duration = CombatConfig.AIR_FLOAT_DURATION,
		})
	end

	-- After 0.18s the target has risen; now pin them in place
	task.delay(0.18, function()
		if not (character and character.Parent) then
			if wasAnchored then
				local h = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
				if h then
					h.Anchored = true
				end
			end
			return
		end
		if not (hrp and hrp.Parent) then
			return
		end

		local suspendY = hrp.Position.Y + CombatConfig.AIR_FLOAT_HEIGHT * 0.15

		local worldAtt = Instance.new("Attachment")
		worldAtt.Name = "FloatWorldAtt"
		worldAtt.WorldPosition = Vector3.new(hrp.Position.X, suspendY, hrp.Position.Z)
		worldAtt.Parent = workspace.Terrain

		local hrpAtt = Instance.new("Attachment")
		hrpAtt.Name = "FloatHRPAtt"
		hrpAtt.Parent = hrp

		local align = Instance.new("AlignPosition")
		align.Name = "FloatAlign"
		align.Attachment0 = hrpAtt
		align.Attachment1 = worldAtt
		align.MaxForce = 75000
		align.Responsiveness = 35
		align.ApplyAtCenterOfMass = true
		align.ReactionForceEnabled = false
		align.Parent = hrp

		_activeFloats[character] = {
			worldAtt = worldAtt,
			hrpAtt = hrpAtt,
			align = align,
			wasAnchored = wasAnchored,
		}

		-- Phase 2 for attacker: lock their Y to just below the target
		if attackerPlayer then
			_remotes.AttackerFloat:FireClient(attackerPlayer, {
				phase = "ylock",
				suspendY = suspendY + 1.5,
				duration = CombatConfig.AIR_FLOAT_DURATION,
			})
		end

		task.delay(CombatConfig.AIR_FLOAT_DURATION, function()
			RagdollService.unfloat(character, targetPlayer)
		end)
	end)
end

function RagdollService.unfloat(character: Model, targetPlayer: Player?)
	local data = _activeFloats[character]
	local wasAnchored = false
	if data then
		wasAnchored = data.wasAnchored
		if data.align and data.align.Parent then
			data.align:Destroy()
		end
		if data.hrpAtt and data.hrpAtt.Parent then
			data.hrpAtt:Destroy()
		end
		if data.worldAtt and data.worldAtt.Parent then
			data.worldAtt:Destroy()
		end
		_activeFloats[character] = nil
	end

	-- Restore anchor state
	if wasAnchored then
		local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if hrp then
			hrp.Anchored = true
		end
	end

	if targetPlayer then
		_remotes.FloatEnd:FireClient(targetPlayer)
	end
end

return RagdollService
