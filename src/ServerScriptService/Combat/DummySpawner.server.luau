--[[
    DummySpawner.server.luau
    ──────────────────────────────────────────────────────────
    Spawns 4 color-coded test dummies and wires their AI.

    ┌─────────────────────────────────────────────────────┐
    │  GRAY   = Normal        │  Takes damage, no reaction │
    │  BLUE   = Blocking      │  Blocks → re-blocks after  │
    │                         │  stun when block breaks    │
    │  GOLD   = PerfectParry  │  Always in parry window    │
    │                         │  → attacker gets stunned   │
    │  RED    = Attacking     │  Attacks nearest player    │
    │                         │  every ~1.8s               │
    └─────────────────────────────────────────────────────┘

    Dummies are ANCHORED — they don't move or receive knockback.
    That's intentional for a stable test environment.
    To make them mobile, unanchor HRP and switch to Welds.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CombatConfig = require(ReplicatedStorage.Shared.CombatConfig)
local CombatManager = require(script.Parent.CombatManager)

-- ─── LAYOUT CONFIG ───────────────────────────────────────────────────────────
-- Centre point of the dummy lineup. Adjust to suit your test place.
local LINEUP_CENTRE = Vector3.new(0, 0.1, -18)
local SPACING = 8 -- studs between each dummy
local FACE_DIRECTION = Vector3.new(0, 0, 1) -- face toward +Z (typical player spawn)

local DUMMY_DEFS: { { name: string, color: Color3, role: string } } = {
	{ name = "NormalDummy", color = Color3.fromRGB(150, 150, 150), role = "normal" },
	{ name = "BlockingDummy", color = Color3.fromRGB(60, 120, 220), role = "block" },
	{ name = "PerfectParryDummy", color = Color3.fromRGB(230, 185, 30), role = "parry" },
	{ name = "AttackingDummy", color = Color3.fromRGB(210, 55, 55), role = "attack" },
}

-- ─── RIG BUILDER ─────────────────────────────────────────────────────────────
--[[
    Builds a minimal humanoid rig sufficient for:
      • HitboxService detection (has BaseParts in workspace)
      • Damage application (Humanoid.TakeDamage)
      • Distance checks (HumanoidRootPart exists)
      • Visual identification (color-coded with name label)

    Parts are anchored individually — no physics needed for test dummies.
    The HumanoidRootPart is transparent (standard Roblox convention).
]]
local function buildDummy(name: string, color: Color3, position: Vector3): Model
	local model = Instance.new("Model")
	model.Name = name

	-- Helper: create an anchored part at a world offset from `position`
	local function part(partName: string, size: Vector3, offset: Vector3, partColor: Color3?): Part
		local p = Instance.new("Part")
		p.Name = partName
		p.Size = size
		p.CFrame = CFrame.new(position + offset)
		p.Color = partColor or color
		p.Material = Enum.Material.SmoothPlastic
		p.Anchored = true
		p.CanCollide = false -- dummies don't block player movement
		p.CastShadow = true
		p.Parent = model
		return p
	end

	-- ── Structural parts (root + body) ───────────────────
	-- HRP sits at the character's centre of mass (~waist height).
	-- All hitbox raycasts use HRP.CFrame as their origin.
	local hrp = part("HumanoidRootPart", Vector3.new(2, 2, 1), Vector3.new(0, 3, 0))
	hrp.Transparency = 1 -- invisible root (Roblox convention)

	-- Torso
	part("LowerTorso", Vector3.new(2.0, 0.4, 1.0), Vector3.new(0, 2.1, 0))
	part("UpperTorso", Vector3.new(2.0, 1.6, 1.0), Vector3.new(0, 3.1, 0))

	-- Head (skin-toned so it's visually distinct from the body)
	local head = part("Head", Vector3.new(1.6, 1.6, 1.6), Vector3.new(0, 4.6, 0), Color3.fromRGB(255, 195, 160))

	-- Arms
	part("LeftUpperArm", Vector3.new(1.0, 1.3, 1.0), Vector3.new(-1.5, 3.3, 0))
	part("RightUpperArm", Vector3.new(1.0, 1.3, 1.0), Vector3.new(1.5, 3.3, 0))
	part("LeftLowerArm", Vector3.new(0.9, 1.1, 0.9), Vector3.new(-1.5, 1.9, 0))
	part("RightLowerArm", Vector3.new(0.9, 1.1, 0.9), Vector3.new(1.5, 1.9, 0))

	-- Legs
	part("LeftUpperLeg", Vector3.new(1.0, 1.5, 1.0), Vector3.new(-0.55, 0.8, 0))
	part("RightUpperLeg", Vector3.new(1.0, 1.5, 1.0), Vector3.new(0.55, 0.8, 0))
	part("LeftLowerLeg", Vector3.new(0.9, 1.3, 0.9), Vector3.new(-0.55, -0.8, 0))
	part("RightLowerLeg", Vector3.new(0.9, 1.3, 0.9), Vector3.new(0.55, -0.8, 0))

	-- ── Humanoid ─────────────────────────────────────────
	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = 100
	humanoid.Health = 100
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.Parent = model

	-- ── Name + HP billboard ──────────────────────────────
	-- Attach to head so it floats above the dummy's head.
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.new(0, 220, 0, 70)
	billboard.StudsOffset = Vector3.new(0, 1.5, 0)
	billboard.AlwaysOnTop = false
	billboard.LightInfluence = 0
	billboard.Parent = head

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.new(1, 0, 0.48, 0)
	nameLabel.BackgroundTransparency = 1
	nameLabel.TextColor3 = Color3.new(1, 1, 1)
	nameLabel.TextStrokeTransparency = 0
	nameLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	nameLabel.Text = name
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextSize = 15
	nameLabel.Parent = billboard

	-- Status label (shows "BLOCKING", "STUNNED", etc.)
	local statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "Status"
	statusLabel.Size = UDim2.new(1, 0, 0.30, 0)
	statusLabel.Position = UDim2.new(0, 0, 0.48, 0)
	statusLabel.BackgroundTransparency = 1
	statusLabel.TextColor3 = color
	statusLabel.TextStrokeTransparency = 0
	statusLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	statusLabel.Text = ""
	statusLabel.Font = Enum.Font.GothamBold
	statusLabel.TextSize = 12
	statusLabel.Parent = billboard

	-- HP bar background
	local hpBacking = Instance.new("Frame")
	hpBacking.Name = "HPBacking"
	hpBacking.Size = UDim2.new(1, 0, 0.20, 0)
	hpBacking.Position = UDim2.new(0, 0, 0.80, 0)
	hpBacking.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	hpBacking.BorderSizePixel = 0
	hpBacking.Parent = billboard

	local hpFill = Instance.new("Frame")
	hpFill.Name = "Fill"
	hpFill.Size = UDim2.new(1, 0, 1, 0)
	hpFill.BackgroundColor3 = Color3.fromRGB(80, 215, 80)
	hpFill.BorderSizePixel = 0
	hpFill.Parent = hpBacking

	-- HP bar updates
	humanoid.HealthChanged:Connect(function(hp: number)
		local fraction = hp / humanoid.MaxHealth
		TweenService:Create(hpFill, TweenInfo.new(0.1, Enum.EasingStyle.Linear), {
			Size = UDim2.new(fraction, 0, 1, 0),
			BackgroundColor3 = Color3.fromRGB(math.round(255 * (1 - fraction)), math.round(215 * fraction), 50),
		}):Play()
	end)

	-- Auto-respawn: reset health 2s after death
	humanoid.Died:Connect(function()
		task.delay(2, function()
			if model and model.Parent then
				humanoid.Health = humanoid.MaxHealth
			end
		end)
	end)

	model.PrimaryPart = hrp
	model.Parent = workspace

	return model
end

-- Helper: update the status text on a dummy's billboard
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

-- Helper: briefly flash a dummy's body color (visual attack/hit feedback)
local function flashDummy(dummyModel: Model, flashColor: Color3, duration: number?)
	local origColors: { [BasePart]: Color3 } = {}
	for _, p in ipairs(dummyModel:GetDescendants()) do
		if p:IsA("BasePart") and p.Transparency < 1 then
			origColors[p] = p.Color
			p.Color = flashColor
		end
	end
	task.delay(duration or 0.08, function()
		for p, c in pairs(origColors) do
			if p and p.Parent then
				p.Color = c
			end
		end
	end)
end

-- ─── SPAWN ALL 4 DUMMIES ─────────────────────────────────────────────────────
-- Evenly spaced around LINEUP_CENTRE.
local totalWidth = SPACING * (#DUMMY_DEFS - 1)
local models: { [string]: Model } = {}

for i, def in ipairs(DUMMY_DEFS) do
	local offset = Vector3.new(-totalWidth / 2 + (i - 1) * SPACING, 0, 0)
	local pos = LINEUP_CENTRE + offset
	models[def.role] = buildDummy(def.name, def.color, pos)
end

-- ─── 1. NORMAL DUMMY ─────────────────────────────────────────────────────────
-- No block, no AI. Purely a damage-application test target.
CombatManager.registerNPC(models.normal, {
	onHit = function(damage: number)
		-- Placeholder: floating damage numbers would hook here.
		setStatus(models.normal, ("-" .. damage), Color3.fromRGB(255, 100, 100))
		task.delay(0.5, function()
			setStatus(models.normal, "")
		end)
	end,
})

setStatus(models.normal, "IDLE", Color3.fromRGB(160, 160, 160))

-- ─── 2. BLOCKING DUMMY ───────────────────────────────────────────────────────
-- Holds block. When block breaks: shows stun visually, then re-blocks.
local blockingModel = models.block
local _blockingStunned = false

CombatManager.registerNPC(blockingModel, {
	onBlockBroken = function()
		_blockingStunned = true
		flashDummy(blockingModel, Color3.fromRGB(255, 50, 50), 0.15)
		setStatus(blockingModel, "STUNNED!", Color3.fromRGB(255, 80, 80))

		task.delay(CombatConfig.BLOCK_BREAK_STUN, function()
			if not (blockingModel and blockingModel.Parent) then
				return
			end
			_blockingStunned = false
			-- Reset and re-engage block
			CombatManager.setNPCBlocking(blockingModel, true)
			setStatus(blockingModel, "BLOCKING", Color3.fromRGB(80, 160, 255))
			flashDummy(blockingModel, Color3.fromRGB(80, 160, 255), 0.12)
		end)
	end,
	onHit = function(_damage: number)
		if not _blockingStunned then
			flashDummy(blockingModel, Color3.fromRGB(200, 200, 255), 0.06)
		end
	end,
})

-- Engage block immediately
CombatManager.setNPCBlocking(blockingModel, true)
setStatus(blockingModel, "BLOCKING", Color3.fromRGB(80, 160, 255))

-- ─── 3. PERFECT PARRY DUMMY ──────────────────────────────────────────────────
-- Constantly refreshes its blockStartTime so it's always inside the parry window.
-- Any non-heavy hit on this dummy will stun the attacker.
local parryModel = models.parry

CombatManager.registerNPC(parryModel, {
	onParried = function()
		-- Attacker has been stunned. Show a golden flash.
		flashDummy(parryModel, Color3.fromRGB(255, 235, 80), 0.20)
		setStatus(parryModel, "PARRIED!", Color3.fromRGB(255, 230, 50))
		task.delay(0.5, function()
			setStatus(parryModel, "PERFECT BLOCK", Color3.fromRGB(230, 185, 30))
		end)
	end,
	onHit = function(_damage: number)
		-- Heavy attacks bypass parry — show a block-hit flash instead.
		flashDummy(parryModel, Color3.fromRGB(255, 180, 0), 0.08)
		setStatus(parryModel, "TANKED HEAVY", Color3.fromRGB(255, 150, 0))
		task.delay(0.4, function()
			setStatus(parryModel, "PERFECT BLOCK", Color3.fromRGB(230, 185, 30))
		end)
	end,
})

CombatManager.setNPCBlocking(parryModel, true)
setStatus(parryModel, "PERFECT BLOCK", Color3.fromRGB(230, 185, 30))

-- Refresh parry window faster than BLOCK_PARRY_WINDOW (0.22s).
-- At 0.08s intervals, the parry window is always fresh.
task.spawn(function()
	while parryModel and parryModel.Parent do
		CombatManager.refreshNPCParryWindow(parryModel)
		task.wait(0.08)
	end
end)

-- ─── 4. ATTACKING DUMMY ──────────────────────────────────────────────────────
-- Finds the nearest player every 1.8s, faces them, and fires a combo attack.
-- Tests the player's block and parry system from the receiving end.
local attackModel = models.attack
local _comboIdx = 1

CombatManager.registerNPC(attackModel, {})
setStatus(attackModel, "HUNTING...", Color3.fromRGB(220, 80, 80))

task.spawn(function()
	while attackModel and attackModel.Parent do
		task.wait(1.8)

		-- ── Find nearest player within attack range ───────
		local nearestPlayer: Player? = nil
		local nearestDist = CombatConfig.MAX_REACH_STUDS + 5 -- slightly wider search

		local dummyHRP = attackModel:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not dummyHRP then
			continue
		end

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

		-- ── Face toward target (rotates HRP only) ─────────
		-- Since other parts are anchored at fixed world positions,
		-- only the HRP's facing direction matters for hitbox projection.
		-- Visual body won't rotate — acceptable for a test dummy.
		local lookPos = Vector3.new(targetHRP.Position.X, dummyHRP.Position.Y, targetHRP.Position.Z)
		dummyHRP.CFrame = CFrame.lookAt(dummyHRP.Position, lookPos)

		-- ── Fire attack ───────────────────────────────────
		setStatus(attackModel, "ATTACKING!", Color3.fromRGB(255, 100, 50))
		flashDummy(attackModel, Color3.fromRGB(255, 255, 255), 0.08)

		CombatManager.npcAttack(attackModel, _comboIdx)

		-- Cycle through all 4 combo hits for variety
		_comboIdx = (_comboIdx % CombatConfig.COMBO_COUNT) + 1

		task.delay(0.6, function()
			if attackModel and attackModel.Parent then
				setStatus(attackModel, "HUNTING...", Color3.fromRGB(220, 80, 80))
			end
		end)
	end
end)

print(("[DummySpawner] 4 dummies spawned at centre %s"):format(tostring(LINEUP_CENTRE)))
