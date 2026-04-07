--[[
    HitboxService.luau  (Server)
    ──────────────────────────────────────────────────────────
    Performs the server-side hitbox cast for melee attacks.
    Uses workspace:GetPartBoundsInBox() (faster than Region3
    and supports OverlapParams properly in 2024+).

    Returns a list of valid hit Characters (with their Players)
    after all anti-exploit checks.

    Anti-exploit layers:
      1. Distance check: attacker must be ≤ MAX_REACH_STUDS from target.
      2. Alive check: target must have health > 0.
      3. Self-hit excluded automatically via OverlapParams.
      4. Rate limiting done in CombatManager before calling here.
]]

local Players = game:GetService("Players")
local CombatConfig = require(game:GetService("ReplicatedStorage").Shared.CombatConfig)

-- ─── MODULE ──────────────────────────────────────────────────────────────────
local HitboxService = {}

-- Pre-build OverlapParams once (expensive to construct per-frame at scale).
-- We modify the FilterDescendantsInstances per-call to exclude the attacker.
local _overlapParams = OverlapParams.new()
_overlapParams.FilterType = Enum.RaycastFilterType.Exclude
_overlapParams.CollisionGroup = "Default"
_overlapParams.MaxParts = 20 -- cap: we never need more than ~20 parts per swing

-- ─── TYPES ───────────────────────────────────────────────────────────────────
export type HitCandidate = {
	player: Player,
	character: Model,
	humanoid: Humanoid,
	hrp: BasePart,
	distance: number,
}

-- ─── CAST ────────────────────────────────────────────────────────────────────
--[[
    Cast a box hitbox in front of the attacker and return all valid targets.

    Parameters:
      attackerCharacter – the attacker's character model
      hitboxSize        – Vector3 size of the hitbox
      hitboxOffset      – local-space offset from HRP (forward = -Z)

    Returns an array of HitCandidate (may be empty).
]]
function HitboxService.cast(attackerCharacter: Model, hitboxSize: Vector3, hitboxOffset: Vector3): { HitCandidate }
	local attackerHRP = attackerCharacter:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not attackerHRP then
		return {}
	end

	-- Build the world-space CFrame for the hitbox centre.
	-- hitboxOffset is in local space (forward = -Z in Roblox).
	local boxCFrame = attackerHRP.CFrame * CFrame.new(hitboxOffset)

	-- Exclude the attacker's own parts so they can't hit themselves.
	_overlapParams.FilterDescendantsInstances = { attackerCharacter }

	local parts: { BasePart } = workspace:GetPartBoundsInBox(boxCFrame, hitboxSize, _overlapParams)

	-- Deduplicate characters and validate each candidate.
	local seen: { [Model]: boolean } = {}
	local results: { HitCandidate } = {}

	for _, part in ipairs(parts) do
		local character = part.Parent :: Model?
		if not character then
			continue
		end
		if seen[character] then
			continue
		end -- already processed
		seen[character] = true

		-- Must be a valid player character (not an NPC for now — hook here for NPCs)
		local targetPlayer = Players:GetPlayerFromCharacter(character)
		if not targetPlayer then
			continue
		end

		local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid?
		if not humanoid then
			continue
		end
		if humanoid.Health <= 0 then
			continue
		end -- already dead

		local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not hrp then
			continue
		end

		-- Distance check (anti-teleport / anti-reach exploit)
		local dist = (hrp.Position - attackerHRP.Position).Magnitude
		if dist > CombatConfig.MAX_REACH_STUDS then
			warn(
				("[HitboxService] Hit rejected: distance %.1f > max %.1f (attacker: %s, target: %s)"):format(
					dist,
					CombatConfig.MAX_REACH_STUDS,
					attackerCharacter.Name,
					character.Name
				)
			)
			continue
		end

		table.insert(results, {
			player = targetPlayer,
			character = character,
			humanoid = humanoid,
			hrp = hrp,
			distance = dist,
		})
	end

	return results
end

return HitboxService
