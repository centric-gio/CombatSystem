--[[
    RagdollService.luau  (Server)
    ──────────────────────────────────────────────────────────
    Handles two physics-driven reactions to hit 4:

    RAGDOLL  (normal finisher)
      • Creates BallSocketConstraints at every Motor6D joint.
      • Disables Motor6Ds → parts become loose but stay connected.
      • Fires RagdollStart to the target client: client applies
        velocity impulse and changes Humanoid state to Physics.
      • Auto-unragdolls after RAGDOLL_DURATION.

    FLOAT  (air combo finisher)
      • Fires a large upward velocity impulse via RagdollStart (velocity only).
      • After 0.15 s (time for character to rise), creates an AlignPosition
        on the server — replicated to ALL clients so everyone sees the float.
      • Fires FloatStart to target client: they lock WalkSpeed and jump.
      • Auto-unfloats after AIR_FLOAT_DURATION.

    Architecture note:
      Physics constraints (BallSocketConstraint, AlignPosition) are created on
      the SERVER so they replicate to ALL observing clients automatically.
      Only the Humanoid state change and velocity application are done on the
      TARGET CLIENT (via remotes), because Humanoid state lives on the owning client.

    Test dummy caveat:
      Dummy parts are anchored — AlignPosition and ragdoll physics are a no-op
      visually. Unanchor HRP in DummySpawner to test physics reactions.
]]

local CombatConfig = require(game:GetService("ReplicatedStorage").Shared.CombatConfig)

-- ─── MODULE ──────────────────────────────────────────────────────────────────
local RagdollService = {}

type Remotes = {
	RagdollStart: RemoteEvent,
	RagdollEnd: RemoteEvent,
	FloatStart: RemoteEvent,
	FloatEnd: RemoteEvent,
}

type FloatData = {
	worldAtt: Attachment,
	hrpAtt: Attachment,
	align: AlignPosition,
}

local _remotes: Remotes = {} :: any

-- Track active floats so we don't double-launch a floating character.
local _activeFloats: { [Model]: FloatData } = {}

function RagdollService.init(remotes: Remotes)
	_remotes = remotes
end

-- ─── INTERNAL: Joint helpers ──────────────────────────────────────────────────

-- Iterates all Motor6D instances in the character and builds a BallSocket
-- constraint pair for each, then disables the motor.
-- We skip "RootJoint" (LowerTorso ↔ HumanoidRootPart) to keep the body
-- anchored to the HRP's world position — otherwise the whole character drifts.
local function _buildRagdollJoints(character: Model)
	for _, desc in ipairs(character:GetDescendants()) do
		if not desc:IsA("Motor6D") then
			continue
		end
		local motor = desc :: Motor6D
		if motor.Name == "RootJoint" then
			continue
		end
		if not motor.Part0 then
			continue
		end
		if not motor.Part1 then
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
		bsc.UpperAngle = 50 -- allows flailing but keeps limbs recognisable
		bsc.TwistLimitsEnabled = false
		bsc.Parent = motor.Part0

		motor.Enabled = false -- replicates to all clients immediately
	end
end

-- Reverses _buildRagdollJoints: destroys constraints, re-enables motors.
local function _clearRagdollJoints(character: Model)
	for _, desc in ipairs(character:GetDescendants()) do
		if desc:IsA("BallSocketConstraint") and desc.Name == "RgdBSC" then
			desc:Destroy()
		elseif desc:IsA("Attachment") and (desc.Name == "RgdAtt0" or desc.Name == "RgdAtt1") then
			desc:Destroy()
		elseif desc:IsA("Motor6D") then
			desc.Enabled = true -- re-enable all motors
		end
	end
end

-- ─── PUBLIC: Ragdoll ──────────────────────────────────────────────────────────
--[[
    ragdoll(character, targetPlayer, knockbackWorld)
      character      – the target's character model
      targetPlayer   – Player? (nil for NPCs)
      knockbackWorld – world-space velocity Vector3 to apply on the client
]]
function RagdollService.ragdoll(character: Model, targetPlayer: Player?, knockbackWorld: Vector3)
	_buildRagdollJoints(character)

	-- Tell the target client: apply the knockback velocity and enter Physics state.
	if targetPlayer then
		_remotes.RagdollStart:FireClient(targetPlayer, knockbackWorld)
	end

	-- Auto-unragdoll after duration.
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
--[[
    float(character, targetPlayer)
      Launches the character upward then suspends them mid-air via AlignPosition.
      The constraint is server-created → replicated to all clients.
      Only the target client receives FloatStart for movement lock.
]]
function RagdollService.float(character: Model, targetPlayer: Player?)
	-- Guard: don't double-launch a character already in the air.
	if _activeFloats[character] then
		return
	end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	-- Initial upward impulse — applied server-side.
	-- Physics simulate on target client's machine (they own the character).
	hrp.AssemblyLinearVelocity = Vector3.new(0, CombatConfig.AIR_LAUNCH_VELOCITY, 0)

	-- Wait for the character to rise before locking the height.
	-- 0.15 s at ~70 studs/s ≈ 10.5 studs up — close to AIR_FLOAT_HEIGHT.
	task.delay(0.15, function()
		if not (character and character.Parent) then
			return
		end
		if not (hrp and hrp.Parent) then
			return
		end

		local suspendY = hrp.Position.Y + (CombatConfig.AIR_FLOAT_HEIGHT * 0.35)

		-- World-space anchor on Terrain (always exists, always accessible).
		local worldAtt = Instance.new("Attachment")
		worldAtt.Name = "FloatWorldAtt"
		worldAtt.WorldPosition = Vector3.new(hrp.Position.X, suspendY, hrp.Position.Z)
		worldAtt.Parent = workspace.Terrain

		local hrpAtt = Instance.new("Attachment")
		hrpAtt.Name = "FloatHRPAtt"
		hrpAtt.Parent = hrp

		-- AlignPosition: pulls HRP toward worldAtt position with soft spring feel.
		local align = Instance.new("AlignPosition")
		align.Name = "FloatAlign"
		align.Attachment0 = hrpAtt
		align.Attachment1 = worldAtt
		align.MaxForce = 55000
		align.Responsiveness = 25 -- low = gentle bounce, not stiff lock
		align.ApplyAtCenterOfMass = true
		align.ReactionForceEnabled = false -- don't push the world attachment
		align.Parent = hrp

		_activeFloats[character] = {
			worldAtt = worldAtt,
			hrpAtt = hrpAtt,
			align = align,
		}

		-- Tell the TARGET client to lock movement (visual is already handled by
		-- AlignPosition replication, but the client needs to set WalkSpeed = 0).
		if targetPlayer then
			_remotes.FloatStart:FireClient(targetPlayer, CombatConfig.AIR_FLOAT_DURATION)
		end

		-- Schedule unfloat.
		task.delay(CombatConfig.AIR_FLOAT_DURATION, function()
			RagdollService.unfloat(character, targetPlayer)
		end)
	end)
end

function RagdollService.unfloat(character: Model, targetPlayer: Player?)
	local data = _activeFloats[character]
	if data then
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

	if targetPlayer then
		_remotes.FloatEnd:FireClient(targetPlayer)
	end
end

return RagdollService
