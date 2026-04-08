--[[
    HitboxService.luau  (Server)  — v2: NPC support
    ──────────────────────────────────────────────────────────
    Changes from v1:
      • HitCandidate.player is now Player? (nil for NPC targets)
      • Added _npcCharacters registry: CombatManager registers
        dummy models here so GetPartBoundsInBox picks them up.
      • registerNPC / unregisterNPC public API.
]]

local Players = game:GetService("Players")
local CombatConfig = require(game:GetService("ReplicatedStorage").Shared.CombatConfig)

-- ─── NPC REGISTRY ────────────────────────────────────────────────────────────
-- Any Model registered here will be treated as a valid hit target.
-- Used by DummySpawner (and future NPC systems).
local _npcCharacters: { [Model]: true } = {}

-- ─── OVERLAP PARAMS (created once, mutated per-cast) ─────────────────────────
local _overlapParams = OverlapParams.new()
_overlapParams.FilterType = Enum.RaycastFilterType.Exclude
_overlapParams.CollisionGroup = "Default"
_overlapParams.MaxParts = 20

-- ─── MODULE ──────────────────────────────────────────────────────────────────
local HitboxService = {}

-- ─── TYPES ───────────────────────────────────────────────────────────────────
export type HitCandidate = {
	player: Player?, -- nil when the target is a registered NPC
	character: Model,
	humanoid: Humanoid,
	hrp: BasePart,
	distance: number,
}

-- ── NPC Registration API ─────────────────────────────────────────────────────
function HitboxService.registerNPC(character: Model)
	_npcCharacters[character] = true
end

function HitboxService.unregisterNPC(character: Model)
	_npcCharacters[character] = nil
end

-- ── Cast ─────────────────────────────────────────────────────────────────────
function HitboxService.cast(attackerCharacter: Model, hitboxSize: Vector3, hitboxOffset: Vector3): { HitCandidate }
	local attackerHRP = attackerCharacter:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not attackerHRP then
		return {}
	end

	-- Project hitbox forward in the attacker's local space.
	local boxCFrame = attackerHRP.CFrame * CFrame.new(hitboxOffset)

	_overlapParams.FilterDescendantsInstances = { attackerCharacter }

	local parts: { BasePart } = workspace:GetPartBoundsInBox(boxCFrame, hitboxSize, _overlapParams)

	local seen: { [Model]: boolean } = {}
	local results: { HitCandidate } = {}

	for _, part in ipairs(parts) do
		local character = part.Parent :: Model?
		if not character then
			continue
		end
		if seen[character] then
			continue
		end
		seen[character] = true

		-- Accept player characters OR registered NPCs; skip everything else.
		local targetPlayer = Players:GetPlayerFromCharacter(character)
		local isRegisteredNPC = _npcCharacters[character] == true
		if not targetPlayer and not isRegisteredNPC then
			continue
		end

		local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid?
		if not humanoid then
			continue
		end
		if humanoid.Health <= 0 then
			continue
		end

		local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not hrp then
			continue
		end

		-- Anti-exploit: distance gate.
		local dist = (hrp.Position - attackerHRP.Position).Magnitude
		if dist > CombatConfig.MAX_REACH_STUDS then
			warn(
				("[HitboxService] Rejected: dist %.1fs > max %.1f  (%s → %s)"):format(
					dist,
					CombatConfig.MAX_REACH_STUDS,
					attackerCharacter.Name,
					character.Name
				)
			)
			continue
		end

		table.insert(results, {
			player = targetPlayer, -- nil for NPC targets
			character = character,
			humanoid = humanoid,
			hrp = hrp,
			distance = dist,
		})
	end

	return results
end

return HitboxService
