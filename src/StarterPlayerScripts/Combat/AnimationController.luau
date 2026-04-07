--[[
    AnimationController.luau  (Client)
    ──────────────────────────────────────────────────────────
    Wraps Roblox's Animator API.
    • Pre-loads all combat animation tracks once on init.
    • Handles priority, fade times, and stopping old tracks.
    • Returns the AnimationTrack so callers can hook .Stopped etc.
    • Future-proofed for custom Motor6D rigs.

    NOTE: Animations must be owned by the GAME (or the player's
    account in Studio testing). Upload via Animation Editor.
]]

local Players = game:GetService("Players")
local CombatConfig = require(game:GetService("ReplicatedStorage").Shared.CombatConfig)

-- ─── TYPES ───────────────────────────────────────────────────────────────────
type TrackCache = { [string]: AnimationTrack }

export type AnimationControllerType = {
	play: (self: AnimationControllerType, animId: string, fadeTime: number?) -> AnimationTrack?,
	stop: (self: AnimationControllerType, animId: string, fadeTime: number?) -> (),
	stopAll: (self: AnimationControllerType, fadeTime: number?) -> (),
	isPlaying: (self: AnimationControllerType, animId: string) -> boolean,
	preload: (self: AnimationControllerType, animIds: { string }) -> (),
	destroy: (self: AnimationControllerType) -> (),
}

-- ─── MODULE ──────────────────────────────────────────────────────────────────
local AnimationController = {}
AnimationController.__index = AnimationController

-- ── Constructor ──────────────────────────────────────────
-- Pass the Character model (not the Player).
function AnimationController.new(character: Model): AnimationControllerType
	local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
	assert(humanoid, "[AnimationController] No Humanoid found in character.")

	local animator = humanoid:WaitForChild("Animator", 5) :: Animator?
	assert(animator, "[AnimationController] No Animator found in Humanoid.")

	local self = setmetatable({
		_animator = animator,
		_cache = {} :: TrackCache,
		_active = {} :: TrackCache, -- currently playing tracks by animId
	}, AnimationController)

	-- Pre-load all combat animations upfront so there's zero latency
	-- when the player first swings.
	local animIds: { string } = {}
	for _, hit in ipairs(CombatConfig.COMBO_HITS) do
		table.insert(animIds, hit.animationId)
	end
	table.insert(animIds, CombatConfig.ANIM.BLOCK_IDLE)
	table.insert(animIds, CombatConfig.ANIM.STUNNED)
	table.insert(animIds, CombatConfig.ANIM.BLOCK_BROKEN)

	self:preload(animIds)

	return self :: AnimationControllerType
end

-- ── Preload ──────────────────────────────────────────────
-- Creates and loads AnimationTracks without playing them.
-- Call during character spawn so tracks are hot in memory.
function AnimationController:preload(animIds: { string })
	for _, id in ipairs(animIds) do
		if self._cache[id] then
			continue
		end -- already loaded

		local anim = Instance.new("Animation")
		anim.AnimationId = id

		-- LoadAnimation can error on invalid IDs — catch gracefully.
		local ok, track = pcall(function()
			return self._animator:LoadAnimation(anim)
		end)

		if ok and track then
			self._cache[id] = track :: AnimationTrack
		else
			warn(("[AnimationController] Failed to load animation: %s"):format(id))
		end

		anim:Destroy() -- the track holds a reference; the Animation Instance itself isn't needed
	end
end

-- ── Play ─────────────────────────────────────────────────
-- Plays a track by its asset ID string.
-- Returns the AnimationTrack for external .Stopped hooks.
function AnimationController:play(animId: string, fadeTime: number?): AnimationTrack?
	local track = self._cache[animId]
	if not track then
		warn(("[AnimationController] Track not preloaded: %s"):format(animId))
		return nil
	end

	-- If this exact track is already playing, restart it cleanly.
	if track.IsPlaying then
		track:Stop(0)
	end

	track:Play(fadeTime or 0.1)
	self._active[animId] = track
	return track
end

-- ── Stop ─────────────────────────────────────────────────
function AnimationController:stop(animId: string, fadeTime: number?)
	local track = self._active[animId]
	if track and track.IsPlaying then
		track:Stop(fadeTime or 0.1)
	end
	self._active[animId] = nil
end

-- ── Stop All ─────────────────────────────────────────────
function AnimationController:stopAll(fadeTime: number?)
	for animId, track in pairs(self._active) do
		if track.IsPlaying then
			track:Stop(fadeTime or 0.1)
		end
		self._active[animId] = nil
	end
end

-- ── isPlaying ────────────────────────────────────────────
function AnimationController:isPlaying(animId: string): boolean
	local track = self._active[animId]
	return track ~= nil and track.IsPlaying
end

-- ── Cleanup ──────────────────────────────────────────────
function AnimationController:destroy()
	self:stopAll(0)
	for _, track in pairs(self._cache) do
		track:Destroy()
	end
	table.clear(self._cache)
	table.clear(self._active)
end

return AnimationController
