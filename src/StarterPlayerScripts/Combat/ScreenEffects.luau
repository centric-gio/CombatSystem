--[[
    ScreenEffects.luau  (Client)
    ──────────────────────────────────────────────────────────
    Full-screen post-processing effects for high-impact moments.
    All effects use ColorCorrectionEffect in Lighting so they
    apply to the entire rendered scene with zero performance cost.

    Currently:
      parryBW(duration)  — B&W desaturation when the LOCAL player is parried.
                           Snaps to grey instantly, fades back to colour over
                           the last 25% of the stun duration.

    Hook ideas for future:
      hitStopFlash()     — brief overexposed white on heavy hit received
      lowHealthVignette()— persistent red vignette below 20% HP
      deathFade()        — fade-to-black on death
]]

local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local ScreenEffects = {}

-- Internal: single ColorCorrectionEffect reused across calls.
-- We never stack two B&W effects; the second call cancels the first.
local _bwEffect: ColorCorrectionEffect? = nil

-- ── Parry B&W ────────────────────────────────────────────
function ScreenEffects.parryBW(duration: number)
	-- Clean up any existing instance before creating a new one.
	if _bwEffect and _bwEffect.Parent then
		_bwEffect:Destroy()
	end

	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "ParryBWEffect"
	cc.Enabled = true
	cc.Saturation = 0 -- start at colour (tweened to B&W immediately)
	cc.Brightness = -0.04 -- slight dim for dramatic feel
	cc.Contrast = 0.12 -- slightly higher contrast in B&W
	cc.TintColor = Color3.new(1, 1, 1)
	cc.Parent = Lighting
	_bwEffect = cc

	-- Snap to full desaturation in 1 frame (instant feel).
	TweenService:Create(cc, TweenInfo.new(0.05, Enum.EasingStyle.Linear), { Saturation = -1 }):Play()

	-- Hold B&W for 75% of the stun duration, then fade colour back in.
	local holdTime = duration * 0.72
	local fadeTime = duration * 0.28

	task.delay(holdTime, function()
		if not (cc and cc.Parent) then
			return
		end

		TweenService:Create(
			cc,
			TweenInfo.new(fadeTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Saturation = 0, Brightness = 0, Contrast = 0 }
		):Play()

		task.delay(fadeTime + 0.05, function()
			if cc and cc.Parent then
				cc:Destroy()
			end
			if _bwEffect == cc then
				_bwEffect = nil
			end
		end)
	end)
end

-- ── Force clear (e.g. on death / respawn) ────────────────
function ScreenEffects.clearAll()
	if _bwEffect and _bwEffect.Parent then
		_bwEffect:Destroy()
		_bwEffect = nil
	end
end

return ScreenEffects
