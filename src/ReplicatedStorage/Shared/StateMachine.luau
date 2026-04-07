--[[
    StateMachine.luau
    ──────────────────────────────────────────────────────────
    Generic, reusable Finite State Machine.
    Works identically on Client and Server.

    Usage:
        local SM = require(...)
        local fsm = SM.new("Idle", {
            Idle = {
                canTransitionTo = {"Attacking", "Blocking", "Stunned", "Dead"},
                onEnter = function(from) ... end,
                onExit  = function(to)   ... end,
            },
            Attacking = { ... },
        })
        fsm:transition("Attacking")
        fsm:update(dt)  -- call every frame if using onUpdate callbacks
]]

-- ─── TYPES (local, not exported – use Types.luau for shared types) ─────────
type StateDefinition = {
	canTransitionTo: { string },
	onEnter: ((prev: string) -> ())?,
	onExit: ((next: string) -> ())?,
	onUpdate: ((dt: number) -> ())?,
}

type ChangeCallback = (from: string, to: string) -> ()

export type StateMachineType = {
	getState: (self: StateMachineType) -> string,
	is: (self: StateMachineType, state: string) -> boolean,
	canTransition: (self: StateMachineType, to: string) -> boolean,
	transition: (self: StateMachineType, to: string) -> boolean,
	forceTransition: (self: StateMachineType, to: string) -> (),
	onChanged: (self: StateMachineType, cb: ChangeCallback) -> (),
	update: (self: StateMachineType, dt: number) -> (),
	destroy: (self: StateMachineType) -> (),
}

-- ─── MODULE ──────────────────────────────────────────────────────────────────
local StateMachine = {}
StateMachine.__index = StateMachine

-- ── Constructor ──────────────────────────────────────────
function StateMachine.new(initialState: string, states: { [string]: StateDefinition }): StateMachineType
	assert(
		states[initialState] ~= nil,
		("[StateMachine] Initial state %q is not defined in the states table."):format(initialState)
	)

	local self = setmetatable({
		_current = initialState,
		_states = states,
		_listeners = {} :: { ChangeCallback },
		_destroyed = false,
	}, StateMachine)

	-- Fire onEnter for the starting state with an empty "previous" marker
	local initDef = states[initialState]
	if initDef.onEnter then
		initDef.onEnter("")
	end

	return self :: StateMachineType
end

-- ── Getters ──────────────────────────────────────────────
function StateMachine:getState(): string
	return self._current
end

function StateMachine:is(state: string): boolean
	return self._current == state
end

-- Check if a transition is valid WITHOUT performing it.
function StateMachine:canTransition(to: string): boolean
	local def = self._states[self._current]
	if not def then
		return false
	end
	for _, allowed in ipairs(def.canTransitionTo) do
		if allowed == to then
			return true
		end
	end
	return false
end

-- ── Transition ───────────────────────────────────────────
-- Returns true on success, false + warning on failure.
function StateMachine:transition(to: string): boolean
	if self._destroyed then
		return false
	end

	if not self:canTransition(to) then
		warn(("[StateMachine] Blocked: %q → %q. Not in canTransitionTo list."):format(self._current, to))
		return false
	end

	self:_doTransition(to)
	return true
end

-- Force a transition bypassing the whitelist.
-- Use ONLY for emergency cases (e.g., sudden death, server override).
function StateMachine:forceTransition(to: string)
	if self._destroyed then
		return
	end
	assert(self._states[to] ~= nil, ("[StateMachine] forceTransition to unknown state %q"):format(to))
	self:_doTransition(to)
end

-- Internal shared transition logic.
function StateMachine:_doTransition(to: string)
	local from = self._current
	local fromDef = self._states[from]
	local toDef = self._states[to]

	-- Exit current state
	if fromDef and fromDef.onExit then
		fromDef.onExit(to)
	end

	self._current = to

	-- Enter new state
	if toDef and toDef.onEnter then
		toDef.onEnter(from)
	end

	-- Notify all change listeners
	for _, cb in ipairs(self._listeners) do
		cb(from, to)
	end
end

-- ── Update ───────────────────────────────────────────────
-- Call every frame (RunService.Heartbeat / task.wait loop).
function StateMachine:update(dt: number)
	if self._destroyed then
		return
	end
	local def = self._states[self._current]
	if def and def.onUpdate then
		def.onUpdate(dt)
	end
end

-- ── Event Subscription ───────────────────────────────────
function StateMachine:onChanged(cb: ChangeCallback)
	table.insert(self._listeners, cb)
end

-- ── Cleanup ──────────────────────────────────────────────
function StateMachine:destroy()
	self._destroyed = true
	table.clear(self._listeners)
end

return StateMachine
