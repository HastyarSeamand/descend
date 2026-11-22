-- The Descent: HUD (health + stamina)
-- Dark, minimal bars in the bottom-left. Health follows the Humanoid; stamina follows the player attributes
-- Stamina / MaxStamina / StaminaExhausted that WeaponService updates while you sprint (hold Shift).
-- Health has a pale "recent damage" bar that drains slowly behind the red one.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local StarterGui = game:GetService("StarterGui")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

-- our bar replaces Roblox's default health bar
task.spawn(function()
	for _ = 1, 10 do
		if pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
		end) then
			break
		end
		task.wait(0.5)
	end
end)

local COLORS = {
	panel = Color3.fromRGB(12, 9, 11),
	stroke = Color3.fromRGB(70, 34, 30),
	track = Color3.fromRGB(28, 20, 22),
	hpTop = Color3.fromRGB(196, 28, 28),
	hpBottom = Color3.fromRGB(110, 10, 14),
	hpLag = Color3.fromRGB(235, 205, 200),
	stTop = Color3.fromRGB(214, 178, 96),
	stBottom = Color3.fromRGB(140, 104, 44),
	stTired = Color3.fromRGB(120, 60, 40),
	text = Color3.fromRGB(236, 224, 220),
}

local function make(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do
		o[k] = v
	end
	o.Parent = parent
	return o
end

local gui = make("ScreenGui", { Name = "DescentHUD", ResetOnSpawn = false, IgnoreGuiInset = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, player:WaitForChild("PlayerGui"))
local scale = make("UIScale", {}, gui)
local function rescale()
	local vp = workspace.CurrentCamera.ViewportSize
	scale.Scale = math.clamp(vp.X / 1280, 0.72, 1.15)
end
rescale()
workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)

local panel = make("Frame", {
	Name = "Vitals",
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 20, 1, -20),
	Size = UDim2.fromOffset(300, 64),
	BackgroundColor3 = COLORS.panel,
	BackgroundTransparency = 0.25,
}, gui)
make("UICorner", { CornerRadius = UDim.new(0, 4) }, panel)
make("UIStroke", { Color = COLORS.stroke, Thickness = 1, Transparency = 0.15 }, panel)
make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingTop = UDim.new(0, 7), PaddingBottom = UDim.new(0, 7) }, panel)

-- on a phone the bottom-left is the thumbstick, so the bars move to the top-left
local UIS = game:GetService("UserInputService")
local function placePanel()
	-- same place on every device: bottom-left, like on PC
	panel.AnchorPoint = Vector2.new(0, 1)
	panel.Position = UDim2.new(0, 20, 1, -20)
end
placePanel()
player:GetAttributeChangedSignal("ForceTouchUI"):Connect(placePanel)

local function bar(name, y, height)
	local track = make("Frame", {
		Name = name,
		Position = UDim2.fromOffset(0, y),
		Size = UDim2.new(1, 0, 0, height),
		BackgroundColor3 = COLORS.track,
		BorderSizePixel = 0,
		ClipsDescendants = true,
	}, panel)
	make("UICorner", { CornerRadius = UDim.new(0, 2) }, track)
	make("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = 1, Transparency = 0.4 }, track)
	return track
end

-- HEALTH
local hpTrack = bar("Health", 0, 16)
local hpLag = make("Frame", { Name = "Lag", Size = UDim2.fromScale(1, 1), BackgroundColor3 = COLORS.hpLag, BackgroundTransparency = 0.35, BorderSizePixel = 0 }, hpTrack)
make("UICorner", { CornerRadius = UDim.new(0, 2) }, hpLag)
local hpFill = make("Frame", { Name = "Fill", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0 }, hpTrack)
make("UICorner", { CornerRadius = UDim.new(0, 2) }, hpFill)
make("UIGradient", { Rotation = 90, Color = ColorSequence.new(COLORS.hpTop, COLORS.hpBottom) }, hpFill)
local hpText = make("TextLabel", {
	Name = "Value",
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	TextSize = 11,
	TextColor3 = COLORS.text,
	TextStrokeTransparency = 0.5,
	Text = "100 / 100",
	ZIndex = 3,
}, hpTrack)

-- STAMINA
local stTrack = bar("Stamina", 22, 8)
local stFill = make("Frame", { Name = "Fill", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0 }, stTrack)
make("UICorner", { CornerRadius = UDim.new(0, 2) }, stFill)
local stGrad = make("UIGradient", { Rotation = 90, Color = ColorSequence.new(COLORS.stTop, COLORS.stBottom) }, stFill)

-- ULTIMATE: crimson charge bar, fills with kills; at 100% it ignites (pulsing glow + "[R] UNLEASH")
local ultTrack = bar("Ultimate", 36, 10)
local ultFill = make("Frame", { Name = "Fill", Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0 }, ultTrack)
make("UICorner", { CornerRadius = UDim.new(0, 2) }, ultFill)
local ultGrad = make("UIGradient", { Rotation = 0, Color = ColorSequence.new(Color3.fromRGB(70, 0, 22), Color3.fromRGB(170, 14, 40)) }, ultFill)
local ultStroke = ultTrack:FindFirstChildOfClass("UIStroke")
local ultLabel = make("TextLabel", {
	Name = "UltLabel",
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 0, 0, -6),
	Size = UDim2.new(1, 0, 0, 16),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBlack,
	TextSize = 13,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextColor3 = Color3.fromRGB(255, 70, 50),
	TextStrokeTransparency = 0.3,
	Text = "[R] UNLEASH",
	Visible = false,
}, panel)

---------------------------------------------------------------- health binding
local hpTween, lagTween
local lastHp = nil
local function setHealth(hum: Humanoid)
	local max = math.max(hum.MaxHealth, 1)
	local frac = math.clamp(hum.Health / max, 0, 1)
	hpText.Text = string.format("%d / %d", math.ceil(hum.Health), math.floor(max))
	if hpTween then
		hpTween:Cancel()
	end
	hpTween = TweenService:Create(hpFill, TweenInfo.new(0.12, Enum.EasingStyle.Quad), { Size = UDim2.fromScale(frac, 1) })
	hpTween:Play()
	if lastHp and hum.Health < lastHp then
		-- took damage: the pale bar waits a moment, then drains down to the new value
		if lagTween then
			lagTween:Cancel()
		end
		lagTween = TweenService:Create(hpLag, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, 0.35), { Size = UDim2.fromScale(frac, 1) })
		lagTween:Play()
	else
		hpLag.Size = UDim2.fromScale(frac, 1)
	end
	lastHp = hum.Health
end

local function onCharacter(ch: Model)
	local hum = ch:WaitForChild("Humanoid", 10)
	if not hum then
		return
	end
	lastHp = nil
	setHealth(hum)
	hum.HealthChanged:Connect(function()
		setHealth(hum)
	end)
	hum:GetPropertyChangedSignal("MaxHealth"):Connect(function()
		setHealth(hum)
	end)
end
player.CharacterAdded:Connect(onCharacter)
if player.Character then
	task.spawn(onCharacter, player.Character)
end

---------------------------------------------------------------- stamina binding
local shown = 1
RunService.RenderStepped:Connect(function(dt)
	local max = player:GetAttribute("MaxStamina") or 100
	local target = math.clamp((player:GetAttribute("Stamina") or max) / max, 0, 1)
	shown += (target - shown) * math.min(1, dt * 14)
	stFill.Size = UDim2.fromScale(shown, 1)
	local tired = player:GetAttribute("StaminaExhausted") == true
	if tired then
		-- exhausted: dull red, pulsing until it refills enough to sprint again
		local p = 0.5 + 0.5 * math.sin(os.clock() * 8)
		stGrad.Color = ColorSequence.new(COLORS.stTired:Lerp(COLORS.stTop, p * 0.25), COLORS.stTired)
	else
		stGrad.Color = ColorSequence.new(COLORS.stTop, COLORS.stBottom)
	end
	-- ultimate charge
	local ult = math.clamp((player:GetAttribute("Ultimate") or 0) / 100, 0, 1)
	ultFill.Size = UDim2.fromScale(ultFill.Size.X.Scale + (ult - ultFill.Size.X.Scale) * math.min(1, dt * 10), 1)
	if ult >= 1 then
		local p = 0.5 + 0.5 * math.sin(os.clock() * 6)
		ultGrad.Color = ColorSequence.new(Color3.fromRGB(150, 0, 20):Lerp(Color3.fromRGB(255, 60, 40), p), Color3.fromRGB(255, 90, 50))
		if ultStroke then
			ultStroke.Color = Color3.fromRGB(255, 60, 40)
			ultStroke.Thickness = 1 + p * 1.5
			ultStroke.Transparency = 0
		end
		ultLabel.Visible = true
		ultLabel.TextTransparency = 0.15 * (1 - p)
		local keyboard = game:GetService("UserInputService").KeyboardEnabled
		ultLabel.Text = if keyboard then "[R] UNLEASH" else "ULT READY"
	else
		ultGrad.Color = ColorSequence.new(Color3.fromRGB(70, 0, 22), Color3.fromRGB(170, 14, 40))
		if ultStroke then
			ultStroke.Color = Color3.new(0, 0, 0)
			ultStroke.Thickness = 1
			ultStroke.Transparency = 0.4
		end
		ultLabel.Visible = false
	end
	-- the stamina bar only draws attention while it's being used
	stTrack.BackgroundTransparency = if target < 0.999 then 0 else 0.3
end)
