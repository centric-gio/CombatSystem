--[[
    RagdollService.luau  (Server)  v3 — R6 + Attacker Air Boost
    ──────────────────────────────────────────────────────────
    CHANGES FROM v2:
      • R6 joint support: skips "RootJoint" and "Root" (HRP↔LowerTorso
        equivalent in R6 is the root motor). For R6, the joints are:
            Neck            (Head ↔ Torso)
            Left Shoulder   (Torso ↔ Left Arm)
            Right Shoulder  (Torso ↔ Right Arm)
            Left Hip        (Torso ↔ Left Leg)
            Right Hip       (Torso ↔ Right Leg)
        All of these become BallSocketConstraints during ragdoll.

      • Air combo float REWORKED:
          1. Target gets upward impulse (AIR_LAUNCH_VELOCITY).
          2. Server fires AttackerFloat remote → attacker's CLIENT
             applies their own upward boost (ATTACKER_AIR_BOOST)
             so they visually "jump" with the target.
          3. After 0.15s, AlignPosition is created on the TARGET
             (same as before) so they float in place.
          4. Ragdoll joints are built on the target so they tumble
             in place mid-air (floppy feel while suspended).
          5. On FloatEnd: ragdoll joints cleared, target recovers.

      • Removed old choppy direct HRP velocity assignment from
        within the float task.delay — moved to immediate application
        before the delay so physics has time to react.

    Architecture reminder:
      BallSocketConstraints live on the SERVER → replicate to all clients.
      Humanoid state changes + velocity impulses fire to the TARGET client.
      The AttackerFloat remote fires to the ATTACKER client.
]]

local CombatConfig = require(game:GetService("ReplicatedStorage").Shared.CombatConfig)

-- ─── MODULE ──────────────────────────────────────────────────────────────────
local RagdollService = {}

type Remotes = {
	RagdollStart: RemoteEvent,
	RagdollEnd: RemoteEvent,
	FloatStart: RemoteEvent,
	FloatEnd: RemoteEvent,
	AttackerFloat: RemoteEvent, -- NEW: tells the attacker to jump up
}

type FloatData = {
	worldAtt: Attachment,
	hrpAtt: Attachment,
	align: AlignPosition,
}

local _remotes: Remotes = {} :: any

-- Track active floats per character
local _activeFloats: { [Model]: FloatData } = {}

function RagdollService.init(remotes: Remotes)
	_remotes = remotes
end

-- ─── INTERNAL: R6 Joint Helpers ──────────────────────────────────────────────

-- R6 root-joint name — must be skipped so the body doesn't fly apart
local R6_ROOT_NAMES = {
	["RootJoint"] = true, -- standard R6 root
	["Root"] = true, -- sometimes named "Root"
	["HumanoidRootPart"] = true,
}

--[[
    Build BallSocketConstraints for every Motor6D in the character,
    EXCEPT the root joint. This makes the character go limp while the
    HRP stays anchored to its world position.
]]
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
		bsc.UpperAngle = 55 -- R6 limbs need slightly more freedom
		bsc.TwistLimitsEnabled = false
		bsc.Parent = motor.Part0

		motor.Enabled = false -- disabling replicates immediately
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

-- ─── PUBLIC: Ragdoll ──────────────────────────────────────────────────────────
function RagdollService.ragdoll(character: Model, targetPlayer: Player?, knockbackWorld: Vector3)
	_buildRagdollJoints(character)

	-- Apply the knockback velocity server-side so ALL clients see it.
	-- Also tell the target client to enter Physics state.
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
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

-- ─── PUBLIC: Air Float (REWORKED) ────────────────────────────────────────────
--[[
    float(character, targetPlayer, attackerPlayer)
      character      – target's character Model
      targetPlayer   – Player? (nil for NPC targets — floats still work visually)
      attackerPlayer – Player? who threw the launcher; they get the air boost
]]
function RagdollService.float(character: Model, targetPlayer: Player?, attackerPlayer: Player?)
	if _activeFloats[character] then
		return
	end -- don't double-launch

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	-- ── Step 1: Immediate upward impulse on target ────────
	-- Applied SERVER-SIDE so physics runs on the network owner's machine.
	-- The magnitude is high so the character visibly rises quickly.
	hrp.AssemblyLinearVelocity = Vector3.new(0, CombatConfig.AIR_LAUNCH_VELOCITY, 0)

	-- Also notify target client: Humanoid → Physics state (no gravity lock yet)
	if targetPlayer then
		_remotes.FloatStart:FireClient(targetPlayer, CombatConfig.AIR_FLOAT_DURATION)
	end

	-- ── Step 2: Attacker jumps up simultaneously ──────────
	-- The attacker gets a smaller boost so they "chase" the target into the air.
	-- This is CLIENT-SIDE only (attacker owns their character's physics).
	if attackerPlayer then
		_remotes.AttackerFloat:FireClient(attackerPlayer, CombatConfig.ATTACKER_AIR_BOOST)
	end

	-- ── Step 3: Lock target height with AlignPosition ─────
	-- Wait 0.18s so the character has risen ~13 studs before we pin it.
	task.delay(0.18, function()
		if not (character and character.Parent) then
			return
		end
		if not (hrp and hrp.Parent) then
			return
		end

		-- Suspend at the character's current risen position.
		local suspendY = hrp.Position.Y + (CombatConfig.AIR_FLOAT_HEIGHT * 0.2)

		local worldAtt = Instance.new("Attachment")
		worldAtt.Name = "FloatWorldAtt"
		worldAtt.WorldPosition = Vector3.new(hrp.Position.X, suspendY, hrp.Position.Z)
		worldAtt.Parent = workspace.Terrain

		local hrpAtt = Instance.new("Attachment")
		hrpAtt.Name = "FloatHRPAtt"
		hrpAtt.Parent = hrp

		-- Soft spring feel: not rigid, but holds the character in the air
		local align = Instance.new("AlignPosition")
		align.Name = "FloatAlign"
		align.Attachment0 = hrpAtt
		align.Attachment1 = worldAtt
		align.MaxForce = 65000
		align.Responsiveness = 30 -- higher = snappier lock, less drift
		align.ApplyAtCenterOfMass = true
		align.ReactionForceEnabled = false
		align.Parent = hrp

		-- Build ragdoll joints so the target flops around mid-air (juicy feel)
		_buildRagdollJoints(character)

		_activeFloats[character] = {
			worldAtt = worldAtt,
			hrpAtt = hrpAtt,
			align = align,
		}

		-- Auto-unfloat
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

	-- Clear ragdoll joints that were built on float start
	_clearRagdollJoints(character)

	if targetPlayer then
		_remotes.FloatEnd:FireClient(targetPlayer)
	end
end

return RagdollService
