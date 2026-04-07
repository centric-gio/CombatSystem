--[[
    InputController.luau  (Client)
    ──────────────────────────────────────────────────────────
    Single point of truth for raw input on the client.
    No game logic here — just clean signal forwarding.
    Swap this file to support gamepad/mobile without touching
    any other module.

    Signals (using BindableEvents):
        onAttack  → fired on M1 press (left-click)
        onBlockStart → fired when F is held down
        onBlockEnd   → fired when F is released
]]

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

-- ─── PRIVATE STATE ───────────────────────────────────────────────────────────
-- We use BindableEvents as lightweight typed signals.
-- These are module-local; only InputController fires them.
local _attackEvent = Instance.new("BindableEvent")
local _blockStartEvent = Instance.new("BindableEvent")
local _blockEndEvent = Instance.new("BindableEvent")

local _enabled = true
local _blockHeld = false

-- ─── MODULE ──────────────────────────────────────────────────────────────────
local InputController = {}

-- Public read-only signal references.
-- Other modules do: InputController.onAttack:Connect(...)
InputController.onAttack = _attackEvent.Event
InputController.onBlockStart = _blockStartEvent.Event
InputController.onBlockEnd = _blockEndEvent.Event

-- ── Enable / Disable ─────────────────────────────────────
-- Disable during cutscenes, menus, emotes, etc.
function InputController.setEnabled(enabled: boolean)
	_enabled = enabled
	-- If disabled while block is held, fire blockEnd so state is consistent.
	if not enabled and _blockHeld then
		_blockHeld = false
		_blockEndEvent:Fire()
	end
end

-- ── Input Connections ─────────────────────────────────────
-- InputBegan: M1 click, F press
UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	-- Ignore if UI is eating this input (chat, menus, etc.)
	if gameProcessed then
		return
	end
	if not _enabled then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		_attackEvent:Fire()
	elseif input.KeyCode == Enum.KeyCode.F then
		if not _blockHeld then
			_blockHeld = true
			_blockStartEvent:Fire()
		end
	end
end)

-- InputEnded: F release
UserInputService.InputEnded:Connect(function(input: InputObject, _gameProcessed: boolean)
	if not _enabled then
		return
	end

	if input.KeyCode == Enum.KeyCode.F and _blockHeld then
		_blockHeld = false
		_blockEndEvent:Fire()
	end
end)

-- Guard: if focus is lost (e.g., alt-tab), release block automatically.
UserInputService.WindowFocusReleased:Connect(function()
	if _blockHeld then
		_blockHeld = false
		_blockEndEvent:Fire()
	end
end)

return InputController
