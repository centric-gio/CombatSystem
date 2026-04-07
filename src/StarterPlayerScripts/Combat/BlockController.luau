--[[
    BlockController.luau  (Client)
    ──────────────────────────────────────────────────────────
    Manages:
      • F-key block hold → tells server, plays block anim.
      • Client-side parry window tracking (visual feedback).
      • Responds to server block-hit, block-broken, parry events.
      • Drives BlockUI (meter bar).

    Security note:
      The client never decides whether a block or parry *succeeds*.
      It only sends the block state and receives outcomes from server.
      The server stores the authoritative block start timestamp.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local CombatConfig = require(ReplicatedStorage.Shared.CombatConfig)

-- ─── MODULE ──────────────────────────────────────────────────────────────────
local BlockController = {}
BlockController.__index = BlockController

export type BlockControllerType = {
	onBlockStart: (self: BlockControllerType) -> (),
	onBlockEnd: (self: BlockControllerType) -> (),
	setMeter: (self: BlockControllerType, meter: number, isBroken: boolean) -> (),
	getMeter: (self: BlockControllerType) -> number,
	isBlocking: (self: BlockControllerType) -> boolean,
	isInParryWindow: (self: BlockControllerType) -> boolean,
	destroy: (self: BlockControllerType) -> (),
}

function BlockController.new(deps: {
	stateMachine: { is: any, transition: any, forceTransition: any },
	animController: { play: any, stop: any },
	blockUI: { setMeter: any, flash: any }?,
	blockRemote: RemoteEvent,
}): BlockControllerType
	local self = setmetatable({
		_sm = deps.stateMachine,
		_anim = deps.animController,
		_ui = deps.blockUI,
		_blockRemote = deps.blockRemote,

		_isBlocking = false,
		_meter = CombatConfig.BLOCK_MAX_METER,
		_parryWindowEnd = 0, -- tick() timestamp when parry window closes
		_parryActive = false,
	}, BlockController)

	return self :: BlockControllerType
end

-- ── Called when F is pressed ──────────────────────────────
function BlockController:onBlockStart()
	local sm = self._sm

	-- Can't block while attacking, already blocking, stunned, or dead.
	if sm:is("Attacking") or sm:is("Blocking") or sm:is("BlockStun") or sm:is("Stunned") or sm:is("Dead") then
		return
	end

	self._isBlocking = true
	self._parryWindowEnd = tick() + CombatConfig.BLOCK_PARRY_WINDOW
	self._parryActive = true

	sm:transition("Blocking")
	self._anim:play(CombatConfig.ANIM.BLOCK_IDLE, 0.08)

	-- Tell the server: player is now blocking.
	-- Server records the exact server-side timestamp for parry validation.
	self._blockRemote:FireServer(true)

	-- Schedule parry window close (visual cue can go here)
	task.delay(CombatConfig.BLOCK_PARRY_WINDOW, function()
		self._parryActive = false
		-- TODO: fire a small visual cue that the parry window just closed
	end)
end

-- ── Called when F is released ─────────────────────────────
function BlockController:onBlockEnd()
	if not self._isBlocking then
		return
	end

	self._isBlocking = false
	self._parryActive = false

	-- Tell server: player stopped blocking.
	self._blockRemote:FireServer(false)

	self._anim:stop(CombatConfig.ANIM.BLOCK_IDLE, 0.1)

	if self._sm:is("Blocking") or self._sm:is("BlockStun") then
		self._sm:transition("Idle")
	end
end

-- ── Called by server events ───────────────────────────────

-- Server tells us our new block meter value after absorbing a hit.
function BlockController:setMeter(meter: number, isBroken: boolean)
	self._meter = meter

	if self._ui then
		self._ui:setMeter(meter / CombatConfig.BLOCK_MAX_METER)
	end

	if isBroken then
		self:_onBlockBroken()
	end
end

function BlockController:_onBlockBroken()
	self._isBlocking = false
	self._parryActive = false

	-- Tell server (in case it didn't already force the state)
	self._blockRemote:FireServer(false)

	self._anim:stop(CombatConfig.ANIM.BLOCK_IDLE, 0)
	self._anim:play(CombatConfig.ANIM.BLOCK_BROKEN, 0.05)

	self._sm:forceTransition("Stunned")

	if self._ui then
		self._ui:flash(CombatConfig.BLOCK_BROKEN_FLASH_COLOR)
	end

	-- Auto-recover from stun after BLOCK_BREAK_STUN duration.
	-- (Server also enforces this, client just reflects it visually.)
	task.delay(CombatConfig.BLOCK_BREAK_STUN, function()
		if self._sm:is("Stunned") then
			self._sm:transition("Idle")
		end
	end)
end

-- ── Getters ───────────────────────────────────────────────
function BlockController:getMeter(): number
	return self._meter
end

function BlockController:isBlocking(): boolean
	return self._isBlocking
end

function BlockController:isInParryWindow(): boolean
	return self._parryActive and tick() <= self._parryWindowEnd
end

function BlockController:destroy()
	self._isBlocking = false
	self._parryActive = false
end

return BlockController
