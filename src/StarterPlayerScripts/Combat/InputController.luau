--[[
    InputController.luau  (Client)
    ──────────────────────────────────────────────────────────
    v2: Added Space hold/release signals for air combo arming.
    Everything else unchanged from v1.
]]

local UserInputService = game:GetService("UserInputService")

local _attackEvent = Instance.new("BindableEvent")
local _blockStartEvent = Instance.new("BindableEvent")
local _blockEndEvent = Instance.new("BindableEvent")
local _spaceHoldEvent = Instance.new("BindableEvent") -- NEW
local _spaceReleaseEvent = Instance.new("BindableEvent") -- NEW

local _enabled = true
local _blockHeld = false
local _spaceHeld = false -- NEW

local InputController = {}

InputController.onAttack = _attackEvent.Event
InputController.onBlockStart = _blockStartEvent.Event
InputController.onBlockEnd = _blockEndEvent.Event
InputController.onSpaceHold = _spaceHoldEvent.Event -- NEW
InputController.onSpaceRelease = _spaceReleaseEvent.Event -- NEW

function InputController.setEnabled(enabled: boolean)
	_enabled = enabled
	if not enabled then
		if _blockHeld then
			_blockHeld = false
			_blockEndEvent:Fire()
		end
		-- Release space tracking so air combo state stays clean on disable.
		if _spaceHeld then
			_spaceHeld = false
			_spaceReleaseEvent:Fire()
		end
	end
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
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
	elseif input.KeyCode == Enum.KeyCode.Space then
		-- We track space independently from the engine jump so we can
		-- arm air combos even when jump is currently disabled.
		if not _spaceHeld then
			_spaceHeld = true
			_spaceHoldEvent:Fire()
		end
	end
end)

UserInputService.InputEnded:Connect(function(input: InputObject, _gp: boolean)
	if not _enabled then
		return
	end

	if input.KeyCode == Enum.KeyCode.F and _blockHeld then
		_blockHeld = false
		_blockEndEvent:Fire()
	elseif input.KeyCode == Enum.KeyCode.Space and _spaceHeld then
		_spaceHeld = false
		_spaceReleaseEvent:Fire()
	end
end)

UserInputService.WindowFocusReleased:Connect(function()
	if _blockHeld then
		_blockHeld = false
		_blockEndEvent:Fire()
	end
	if _spaceHeld then
		_spaceHeld = false
		_spaceReleaseEvent:Fire()
	end
end)

return InputController
