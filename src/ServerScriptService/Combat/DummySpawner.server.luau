--[[
    DummySpawner.server.luau  (v2 — R6 Workspace Rigs)
    ──────────────────────────────────────────────────────────
    CHANGE FROM v1:
      • No longer builds procedural dummy models.
      • Expects 4 pre-built R6 character models to already exist
        in workspace with these exact Names:
            "NormalDummy"        → gray  → role: normal  (infinite HP)
            "BlockingDummy"      → blue  → role: block
            "PerfectParryDummy"  → gold  → role: parry
            "AttackingDummy"     → red   → role: attack

        Each model MUST have:
          • HumanoidRootPart  (BasePart, anchored or unanchored)
          • Humanoid
          • Standard R6 parts: Torso, Head, Left Arm, Right Arm,
            Left Leg, Right Leg (used by RagdollService for joints)
          • Motor6Ds at: Neck, Left Shoulder, Right Shoulder,
            Left Hip, Right Hip (standard R6 rig)

      • NormalDummy has infinite HP: Humanoid.MaxHealth = math.huge
        and damage is intercepted via :TakeDamage override trick —
        actually we reconnect HealthChanged to always reset to max.

      • Billboard UI (name + status + HP bar) is injected onto
        each dummy's Head at runtime — no manual setup needed.

    HOW TO SET UP IN STUDIO:
      1. Insert a default R6 Dummy (or rig) into workspace via
         Avatar → Rig Builder → R6.
      2. Rename it to one of the 4 names above.
      3. Repeat for all 4.
      4. Position them where you like.
      5. Make sure each has Anchored = true on HumanoidRootPart
         if you want them stationary (recommended for test env).
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConfig = require(ReplicatedStorage.Shared.CombatConfig)
local CombatManager = require(script.Parent.CombatManager)

-- ─── DUMMY DEFINITIONS ───────────────────────────────────────────────────────
local DUMMY_DEFS: { { name: string, color: Color3, role: string } } = {
	{ name = "NormalDummy", color = Color3.fromRGB(150, 150, 150), role = "normal" },
	{ name = "BlockingDummy", color = Color3.fromRGB(60, 120, 220), role = "block" },
	{ name = "PerfectParryDummy", color = Color3.fromRGB(230, 185, 30), role = "parry" },
	{ name = "AttackingDummy", color = Color3.fromRGB(210, 55, 55), role = "attack" },
}

-- ─── FETCH MODELS FROM WORKSPACE ─────────────────────────────────────────────
local models: { [string]: Model } = {}

for _, def in ipairs(DUMMY_DEFS) do
	local found = workspace:FindFirstChild(def.name) :: Model?
	assert(
		found and found:IsA("Model"),
		("[DummySpawner] Could not find Model named %q in Workspace. " .. "Please add an R6 rig with that exact name."):format(
			def.name
		)
	)
	models[def.role] = found
end

-- ─── BILLBOARD INJECTOR ──────────────────────────────────────────────────────
-- Injects a floating UI above the dummy's head with:
--   • Name label
--   • Status label  (BLOCKING / STUNNED / etc.)
--   • HP bar

local function injectBillboard(dummyModel: Model, accentColor: Color3)
	local head = dummyModel:FindFirstChild("Head") :: BasePart?
	assert(head, ("[DummySpawner] %s has no 'Head' part."):format(dummyModel.Name))
	local humanoid = dummyModel:FindFirstChildOfClass("Humanoid") :: Humanoid
	assert(humanoid, ("[DummySpawner] %s has no Humanoid."):format(dummyModel.Name))

	-- Remove any pre-existing billboard from Studio
	local old = head:FindFirstChildOfClass("BillboardGui")
	if old then
		old:Destroy()
	end

	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.new(0, 220, 0, 70)
	bb.StudsOffset = Vector3.new(0, 2.2, 0)
	bb.AlwaysOnTop = false
	bb.LightInfluence = 0
	bb.Parent = head

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.new(1, 0, 0.45, 0)
	nameLabel.BackgroundTransparency = 1
	nameLabel.TextColor3 = Color3.new(1, 1, 1)
	nameLabel.TextStrokeTransparency = 0
	nameLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	nameLabel.Text = dummyModel.Name
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextSize = 14
	nameLabel.Parent = bb

	local statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "Status"
	statusLabel.Size = UDim2.new(1, 0, 0.30, 0)
	statusLabel.Position = UDim2.new(0, 0, 0.45, 0)
	statusLabel.BackgroundTransparency = 1
	statusLabel.TextColor3 = accentColor
	statusLabel.TextStrokeTransparency = 0
	statusLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	statusLabel.Text = ""
	statusLabel.Font = Enum.Font.GothamBold
	statusLabel.TextSize = 11
	statusLabel.Parent = bb

	local hpBack = Instance.new("Frame")
	hpBack.Name = "HPBacking"
	hpBack.Size = UDim2.new(1, 0, 0.22, 0)
	hpBack.Position = UDim2.new(0, 0, 0.78, 0)
	hpBack.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	hpBack.BorderSizePixel = 0
	hpBack.Parent = bb

	local hpFill = Instance.new("Frame")
	hpFill.Name = "Fill"
	hpFill.Size = UDim2.new(1, 0, 1, 0)
	hpFill.BackgroundColor3 = Color3.fromRGB(80, 215, 80)
	hpFill.BorderSizePixel = 0
	hpFill.Parent = hpBack

	-- HP bar live update
	humanoid.HealthChanged:Connect(function(hp: number)
		local maxHp = humanoid.MaxHealth
		-- Clamp for math.huge (infinite HP dummy)
		local fraction = if maxHp == math.huge then 1 else math.clamp(hp / maxHp, 0, 1)
		TweenService:Create(hpFill, TweenInfo.new(0.10, Enum.EasingStyle.Linear), {
			Size = UDim2.new(fraction, 0, 1, 0),
			BackgroundColor3 = Color3.fromRGB(math.round(255 * (1 - fraction)), math.round(215 * fraction), 50),
		}):Play()
	end)
end

-- ─── STATUS HELPERS ──────────────────────────────────────────────────────────

local function setStatus(dummyModel: Model, text: string, textColor: Color3?)
	local head = dummyModel:FindFirstChild("Head") :: BasePart?
	if not head then
		return
	end
	local bb = head:FindFirstChildOfClass("BillboardGui")
	if not bb then
		return
	end
	local label = bb:FindFirstChild("Status") :: TextLabel?
	if not label then
		return
	end
	label.Text = text
	label.TextColor3 = textColor or Color3.new(1, 1, 1)
end

local function flashDummy(dummyModel: Model, flashColor: Color3, duration: number?)
	local origColors: { [BasePart]: Color3 } = {}
	for _, p in ipairs(dummyModel:GetDescendants()) do
		if p:IsA("BasePart") and p.Transparency < 1 then
			origColors[p] = p.Color
			p.Color = flashColor
		end
	end
	task.delay(duration or 0.08, function()
		for part, c in pairs(origColors) do
			if part and part.Parent then
				part.Color = c
			end
		end
	end)
end

-- ─── INJECT BILLBOARDS ───────────────────────────────────────────────────────

for _, def in ipairs(DUMMY_DEFS) do
	injectBillboard(models[def.role], def.color)
end

-- ─── 1. NORMAL DUMMY — INFINITE HP ───────────────────────────────────────────
do
	local normalModel = models.normal
	local humanoid = normalModel:FindFirstChildOfClass("Humanoid") :: Humanoid

	-- Infinite HP: MaxHealth = math.huge, regenerate instantly on any damage.
	humanoid.MaxHealth = math.huge
	humanoid.Health = math.huge

	-- Belt-and-suspenders: if Health ever drops (shouldn't with math.huge MaxHealth),
	-- snap it back immediately so the dummy never dies.
	humanoid.HealthChanged:Connect(function(hp: number)
		if hp < humanoid.MaxHealth then
			humanoid.Health = humanoid.MaxHealth
		end
	end)

	CombatManager.registerNPC(normalModel, {
		onHit = function(damage: number)
			-- Floating damage number hint via status label
			setStatus(normalModel, "-" .. tostring(damage), Color3.fromRGB(255, 100, 100))
			task.delay(0.5, function()
				setStatus(normalModel, "IDLE", Color3.fromRGB(160, 160, 160))
			end)
		end,
	})
	setStatus(normalModel, "IDLE", Color3.fromRGB(160, 160, 160))

	-- Auto-reset health label display every frame (for infinite HP it's always full)
	humanoid.HealthChanged:Connect(function()
		humanoid.Health = math.huge
	end)
end

-- ─── 2. BLOCKING DUMMY ───────────────────────────────────────────────────────
do
	local blockModel = models.block
	local blockingStunned = false

	CombatManager.registerNPC(blockModel, {
		onBlockBroken = function()
			blockingStunned = true
			flashDummy(blockModel, Color3.fromRGB(255, 50, 50), 0.15)
			setStatus(blockModel, "STUNNED!", Color3.fromRGB(255, 80, 80))

			task.delay(CombatConfig.BLOCK_BREAK_STUN, function()
				if not (blockModel and blockModel.Parent) then
					return
				end
				blockingStunned = false
				CombatManager.setNPCBlocking(blockModel, true)
				setStatus(blockModel, "BLOCKING", Color3.fromRGB(80, 160, 255))
				flashDummy(blockModel, Color3.fromRGB(80, 160, 255), 0.12)
			end)
		end,
		onHit = function(_damage: number)
			if not blockingStunned then
				flashDummy(blockModel, Color3.fromRGB(200, 200, 255), 0.06)
			end
		end,
	})

	CombatManager.setNPCBlocking(blockModel, true)
	setStatus(blockModel, "BLOCKING", Color3.fromRGB(80, 160, 255))
end

-- ─── 3. PERFECT PARRY DUMMY ──────────────────────────────────────────────────
do
	local parryModel = models.parry

	CombatManager.registerNPC(parryModel, {
		onParried = function()
			flashDummy(parryModel, Color3.fromRGB(255, 235, 80), 0.20)
			setStatus(parryModel, "PARRIED!", Color3.fromRGB(255, 230, 50))
			task.delay(0.5, function()
				setStatus(parryModel, "PERFECT BLOCK", Color3.fromRGB(230, 185, 30))
			end)
		end,
		onHit = function(_damage: number)
			flashDummy(parryModel, Color3.fromRGB(255, 180, 0), 0.08)
			setStatus(parryModel, "TANKED HEAVY", Color3.fromRGB(255, 150, 0))
			task.delay(0.4, function()
				setStatus(parryModel, "PERFECT BLOCK", Color3.fromRGB(230, 185, 30))
			end)
		end,
	})

	CombatManager.setNPCBlocking(parryModel, true)
	setStatus(parryModel, "PERFECT BLOCK", Color3.fromRGB(230, 185, 30))

	-- Always in parry window: refresh every 0.08s (< BLOCK_PARRY_WINDOW = 0.22s)
	task.spawn(function()
		while parryModel and parryModel.Parent do
			CombatManager.refreshNPCParryWindow(parryModel)
			task.wait(0.08)
		end
	end)
end

-- ─── 4. ATTACKING DUMMY ──────────────────────────────────────────────────────
do
	local attackModel = models.attack
	local comboIdx = 1

	CombatManager.registerNPC(attackModel, {})
	setStatus(attackModel, "HUNTING...", Color3.fromRGB(220, 80, 80))

	task.spawn(function()
		while attackModel and attackModel.Parent do
			task.wait(1.8)

			local dummyHRP = attackModel:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not dummyHRP then
				continue
			end

			-- Find nearest player
			local nearestPlayer: Player? = nil
			local nearestDist = CombatConfig.MAX_REACH_STUDS + 5

			for _, player in ipairs(Players:GetPlayers()) do
				local char = player.Character
				if not char then
					continue
				end
				local pHRP = char:FindFirstChild("HumanoidRootPart") :: BasePart?
				if not pHRP then
					continue
				end
				local dist = (pHRP.Position - dummyHRP.Position).Magnitude
				if dist < nearestDist then
					nearestDist = dist
					nearestPlayer = player
				end
			end

			if not nearestPlayer then
				setStatus(attackModel, "NO TARGET", Color3.fromRGB(180, 80, 80))
				continue
			end

			local targetChar = nearestPlayer.Character
			local targetHRP = targetChar and targetChar:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not targetHRP then
				continue
			end

			-- Face toward target (HRP only; body is R6 so this propagates correctly
			-- if the dummy is unanchored, and is a no-op visually if anchored)
			local lookPos = Vector3.new(targetHRP.Position.X, dummyHRP.Position.Y, targetHRP.Position.Z)
			dummyHRP.CFrame = CFrame.lookAt(dummyHRP.Position, lookPos)

			setStatus(attackModel, "ATTACKING!", Color3.fromRGB(255, 100, 50))
			flashDummy(attackModel, Color3.fromRGB(255, 255, 255), 0.08)

			CombatManager.npcAttack(attackModel, comboIdx)
			comboIdx = (comboIdx % CombatConfig.COMBO_COUNT) + 1

			task.delay(0.6, function()
				if attackModel and attackModel.Parent then
					setStatus(attackModel, "HUNTING...", Color3.fromRGB(220, 80, 80))
				end
			end)
		end
	end)
end

print("[DummySpawner] All 4 R6 dummies wired successfully.")
