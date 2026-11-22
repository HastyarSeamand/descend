-- The Descent: PHONE CONTROLS (v2, 2026-11-20)
-- Shown on touch screens. Right-thumb cluster round one big STRIKE button:
--   STRIKE  light combo (tap per hit; hold to keep chaining). Sheathed: draws the sword. In the air: ground slam.
--   HEAVY   heavy attack        DODGE  dodge (tap again right after a back-dodge = backflip)
--   JUMP    replaces Roblox's jump button so everything sits under one thumb (tap = jump, hold = keep hopping)
--   ULT     fills with kills, burns when ready      RUN  sprint toggle      DRAW / SHEATHE  the sword
--   GRASP   "Grave Grasp" (G on keyboard): HOLD to keep the rocks up, let go to throw
--   VERDICT "Divine Verdict" (Z on keyboard)
-- Roblox's own thumbstick stays on the left. Every action goes through CombatClient (Player.DescentInput), the same
-- code as keyboard and gamepad, so phones play by exactly the same rules (manual combat, no auto-attack).
-- Testing on PC: Studio's device emulator, or set the player attribute ForceTouchUI = true.
--
-- v2: forged-iron look (dark glassy face, iron rim, inner crimson ring, glow halo, serif labels, countdown numbers
-- on cooldowns, a flash when an ability is ready again). FIX: a finger that is already on the screen (turning the
-- camera) and slides onto a button no longer presses it: only a touch that STARTS on a button presses it. A press
-- is held until that same finger lifts, even if it slides off.

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local pg = player:WaitForChild("PlayerGui")
local input: BindableFunction = player:WaitForChild("DescentInput")
local cfg = require(game:GetService("ReplicatedStorage"):WaitForChild("Descent"):WaitForChild("WeaponConfig")).Gravecleaver
local TOOL = "Gravecleaver"
local HOLD_REPEAT = 0.3 -- holding STRIKE sends the next hit this often (the server buffers it into the combo)

local C = {
	face = Color3.fromRGB(12, 9, 10),
	face2 = Color3.fromRGB(40, 24, 23),
	iron = Color3.fromRGB(70, 56, 52),
	ironHot = Color3.fromRGB(150, 110, 96),
	rim = Color3.fromRGB(150, 30, 22),
	rimHot = Color3.fromRGB(255, 84, 52),
	glow = Color3.fromRGB(220, 36, 20),
	text = Color3.fromRGB(238, 226, 218),
	dim = Color3.fromRGB(105, 94, 90),
	cool = Color3.fromRGB(205, 190, 182), -- cooldown seconds: readable on the dark shutter
	ult = Color3.fromRGB(170, 10, 6),
	gold = Color3.fromRGB(226, 186, 104),
	shutter = Color3.fromRGB(0, 0, 0),
}
local LABEL_FONT = Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.Bold)

local function make(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do
		o[k] = v
	end
	o.Parent = parent
	return o
end

local gui = make("ScreenGui", { Name = "DescentMobileControls", ResetOnSpawn = false, DisplayOrder = 5, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets, Enabled = false }, pg)
local area = make("Frame", { Name = "Area", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, gui)

local buttons = {}
local order = {}
-- a forged button: a soft crimson halo behind, a dark glassy face, an iron rim, an inner crimson ring, a serif label.
-- Pressed: it sinks, the ring and halo flare.
local function button(name: string, label: string)
	local holder = make("Frame", { Name = name, BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5) }, area)
	local halo = make("Frame", { Name = "Halo", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1.22, 1.22), BackgroundColor3 = C.glow, BackgroundTransparency = 1, BorderSizePixel = 0 }, holder)
	make("UICorner", { CornerRadius = UDim.new(1, 0) }, halo)
	make("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(0.55, 0.55), NumberSequenceKeypoint.new(1, 1) }), Rotation = 90 }, halo)
	local b = make("TextButton", { Name = "Face", AutoButtonColor = false, Text = "", BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.22, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), Active = true, Selectable = false }, holder)
	make("UICorner", { CornerRadius = UDim.new(1, 0) }, b)
	make("UIGradient", { Color = ColorSequence.new(C.face2, C.face), Rotation = 90 }, b)
	local stroke = make("UIStroke", { Color = C.iron, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, b)
	local scale = make("UIScale", {}, holder)
	-- cooldown shutter / ULT charge: a fill that rises inside the face, clipped to the circle
	local clip = make("CanvasGroup", { Name = "Fill", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 2 }, b)
	make("UICorner", { CornerRadius = UDim.new(1, 0) }, clip)
	local fill = make("Frame", { BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.fromScale(1, 0), BackgroundColor3 = C.ult, BackgroundTransparency = 0.3 }, clip)
	-- inner crimson ring
	local ringF = make("Frame", { Name = "Ring", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.82, 0.82), BackgroundTransparency = 1, ZIndex = 3 }, b)
	make("UICorner", { CornerRadius = UDim.new(1, 0) }, ringF)
	local ring = make("UIStroke", { Color = C.rim, Thickness = 1.5, Transparency = 0.3 }, ringF)
	local t = make("TextLabel", { Name = "Label", BackgroundTransparency = 1, Size = UDim2.fromScale(0.74, 0.22), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), FontFace = LABEL_FONT, TextScaled = true, Text = label, TextColor3 = C.text, ZIndex = 5 }, b)
	make("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = 1.2, Transparency = 0.25 }, t)
	local o = { name = name, holder = holder, b = b, halo = halo, stroke = stroke, ring = ring, scale = scale, fill = fill, label = t, text = label, down = false, d = 0, wasCooling = false, flashUntil = 0 }
	buttons[name] = o
	table.insert(order, o)
	return o
end

local strike = button("Strike", "STRIKE")
local heavy = button("Heavy", "HEAVY")
local dodge = button("Dodge", "DODGE")
local jump = button("Jump", "JUMP")
local ult = button("Ult", "ULT")
local run = button("Run", "RUN")
local draw = button("Draw", "DRAW")
local grasp = button("Grasp", "GRASP")
local verdict = button("Verdict", "VERDICT")
for _, o in ipairs({ dodge, grasp, verdict }) do
	o.fill.BackgroundColor3 = C.shutter
	o.fill.BackgroundTransparency = 0.3
end
-- STRIKE gets a blade-slash emblem behind its label
local slash = make("Frame", { Name = "Slash", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.78, 0.045), Rotation = -38, BackgroundColor3 = C.gold, BorderSizePixel = 0, ZIndex = 4 }, strike.b)
make("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.35), NumberSequenceKeypoint.new(1, 1) }) }, slash)
make("UICorner", { CornerRadius = UDim.new(1, 0) }, slash)
strike.label.Size = UDim2.fromScale(0.7, 0.2)

-- LAYOUT: everything scales with the short side of the screen. STRIKE sits in the bottom-right corner, the rest
-- on an arc round it (angles: 0 = right, 90 = up), RUN, DRAW and the abilities a little further out.
-- the ring buttons are 34+ degrees apart on a 0.275 ring, so neighbours never touch (chord 0.16+ > diameter 0.15)
local LAYOUT = {
	-- name = { angle, distance, diameter }   (distance and diameter in units of the screen's short side)
	Strike = { 0, 0, 0.25 },
	Jump = { 188, 0.28, 0.15 },
	Dodge = { 146, 0.28, 0.15 },
	Heavy = { 104, 0.28, 0.15 },
	Ult = { 70, 0.28, 0.15 },
	Run = { 168, 0.475, 0.11 },
	Draw = { 98, 0.475, 0.11 },
	Grasp = { 132, 0.475, 0.13 }, -- Grave Grasp (G on keyboard)
	Verdict = { 114, 0.665, 0.125 }, -- Divine Verdict (Z on keyboard)
}
local function layout()
	local size = area.AbsoluteSize
	local u = math.min(size.X, size.Y)
	local cx, cy = size.X - u * 0.21, size.Y - u * 0.2
	for name, L in pairs(LAYOUT) do
		local o = buttons[name]
		local a = math.rad(L[1])
		local d = L[3] * u
		o.d = d
		o.holder.Position = UDim2.fromOffset(cx + math.cos(a) * L[2] * u, cy - math.sin(a) * L[2] * u)
		o.holder.Size = UDim2.fromOffset(d, d)
		o.stroke.Thickness = math.max(2, d * 0.04)
		o.ring.Thickness = math.max(1, d * 0.016)
	end
end
area:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
layout()

local function setPressed(o, on: boolean)
	o.down = on
	TweenService:Create(o.scale, TweenInfo.new(if on then 0.05 else 0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = if on then 0.88 else 1 }):Play()
	TweenService:Create(o.halo, TweenInfo.new(if on then 0.05 else 0.25), { BackgroundTransparency = if on then 0.35 else 1 }):Play()
	o.ring.Color = if on then C.rimHot else C.rim
	o.ring.Transparency = if on then 0 else 0.3
	o.stroke.Color = if on then C.ironHot else C.iron
end

-- PRESSES. Only a touch that STARTS on a button presses it: a finger already on the screen (turning the camera)
-- that slides onto a button is ignored (Roblox reports that slide-in as an InputBegan on the button too, which
-- made it fire by accident). The press is held until that same finger lifts, even if it slides off the button.
local touchStart: { [InputObject]: number } = {}
UIS.InputBegan:Connect(function(io)
	if io.UserInputType == Enum.UserInputType.Touch then
		touchStart[io] = os.clock()
	end
end)
local held: { [InputObject]: any } = {} -- touch -> button it is holding
local handlers = {}
local function hook(o, onDown, onUp)
	handlers[o] = { down = onDown, up = onUp }
	o.b.InputBegan:Connect(function(io)
		local t = io.UserInputType
		if t == Enum.UserInputType.Touch then
			if io.UserInputState ~= Enum.UserInputState.Begin then
				return
			end
			local started = touchStart[io]
			if started and os.clock() - started > 0.12 then
				return -- this finger was already down somewhere else and slid in
			end
		elseif t ~= Enum.UserInputType.MouseButton1 then
			return
		end
		if held[io] then
			return
		end
		held[io] = o
		setPressed(o, true)
		onDown()
	end)
end
local function releaseInput(io)
	local o = held[io]
	if o then
		held[io] = nil
		local stillHeld = false
		for _, other in pairs(held) do
			if other == o then
				stillHeld = true
			end
		end
		if not stillHeld then
			setPressed(o, false)
			local h = handlers[o]
			if h and h.up then
				h.up()
			end
		end
	end
	touchStart[io] = nil
end
UIS.InputEnded:Connect(releaseInput)
local function releaseAll()
	for io in pairs(held) do
		releaseInput(io)
	end
end

local function humanoid(): Humanoid?
	local ch = player.Character
	return ch and ch:FindFirstChildOfClass("Humanoid")
end
local function state()
	local ok, s = pcall(function()
		return input:Invoke("State")
	end)
	return if ok and type(s) == "table" then s else { drawn = false, sprint = false, dodgeLeft = 0 }
end
local function toggleSword()
	local hum = humanoid()
	if not hum then
		return
	end
	local ch = player.Character
	if ch:FindFirstChildOfClass("Tool") then
		hum:UnequipTools()
	else
		local bp = player:FindFirstChildOfClass("Backpack")
		local tool = bp and bp:FindFirstChild(TOOL)
		if tool then
			hum:EquipTool(tool)
		end
	end
end

local strikeHeldSince = nil
local lastRepeat = 0
hook(strike, function()
	if state().drawn then
		input:Invoke("Light")
	else
		toggleSword() -- first tap with the sword away draws it
	end
	strikeHeldSince = os.clock()
	lastRepeat = os.clock()
end, function()
	strikeHeldSince = nil
end)
hook(heavy, function()
	input:Invoke("Heavy")
end)
hook(dodge, function()
	input:Invoke("Dodge")
end)
-- JUMP: Roblox's ControlModule rewrites Humanoid.Jump every frame from its own touch input, so a one-off
-- "hum.Jump = true" was wiped before the character could jump. A held flag is re-asserted right AFTER the
-- ControlModule (Input priority + 1), like Roblox's own jump button: tap = jump, hold = keep hopping.
local jumpHeld = false
hook(jump, function()
	jumpHeld = true
	local hum = humanoid()
	if hum then
		hum.Jump = true
	end
end, function()
	jumpHeld = false
end)
RunService:BindToRenderStep("DescentMobileJump", Enum.RenderPriority.Input.Value + 1, function()
	if jumpHeld then
		local hum = humanoid()
		if hum and hum.Health > 0 then
			hum.Jump = true
		end
	end
end)
hook(ult, function()
	input:Invoke("Ult")
end)
hook(run, function()
	input:Invoke("Sprint", not state().sprint)
end)
hook(draw, toggleSword)
hook(grasp, function()
	input:Invoke("Telekinesis")
end, function()
	input:Invoke("TelekinesisRelease")
end)
hook(verdict, function()
	input:Invoke("Verdict")
end)

-- only on touch screens without a keyboard (phones, tablets); a touchscreen laptop keeps mouse + keys
local function touchMode(): boolean
	return (UIS.TouchEnabled and not UIS.KeyboardEnabled) or player:GetAttribute("ForceTouchUI") == true
end

-- Roblox's jump button would sit under STRIKE: hide it (ours replaces it)
local function hideDefaultJump()
	local tg = pg:FindFirstChild("TouchGui")
	local jb = tg and tg:FindFirstChild("JumpButton", true)
	if jb and jb:IsA("GuiObject") and jb.Visible then
		jb.Visible = false
	end
end

-- tapping the world must NOT swing on a phone (that's how the camera is turned): STRIKE does it instead
local function manualTools(container: Instance?)
	if not container then
		return
	end
	for _, t in ipairs(container:GetChildren()) do
		if t:IsA("Tool") and t.Name == TOOL and not t.ManualActivationOnly then
			t.ManualActivationOnly = true
		end
	end
end

-- a cooldown: dark shutter falls away, the seconds left replace the label, a flash when it's ready again
local function cooldown(o, left: number, total: number, t: number)
	local cooling = left > 0.05
	o.fill.Size = UDim2.fromScale(1, math.clamp(left / total, 0, 1))
	if cooling then
		o.label.Text = tostring(math.ceil(left))
		o.label.TextColor3 = C.cool
	else
		o.label.Text = o.text
		if o.wasCooling then
			o.flashUntil = t + 0.35
		end
	end
	o.wasCooling = cooling
	if not o.down then
		local f = math.clamp((o.flashUntil - t) / 0.35, 0, 1)
		o.halo.BackgroundTransparency = 1 - 0.6 * f
		o.ring.Color = C.rim:Lerp(C.rimHot, f)
	end
	return cooling
end

RunService.RenderStepped:Connect(function()
	local on = touchMode()
	local hum = humanoid()
	gui.Enabled = on and hum ~= nil and hum.Health > 0
	if not gui.Enabled then
		releaseAll()
		jumpHeld = false
		return
	end
	hideDefaultJump()
	manualTools(player.Character)
	manualTools(player:FindFirstChildOfClass("Backpack"))
	local s = state()
	local t = os.clock()

	-- hold STRIKE to keep chaining the combo
	if strikeHeldSince and s.drawn and t - lastRepeat >= HOLD_REPEAT then
		lastRepeat = t
		input:Invoke("Light")
	end

	-- sword away: attacks greyed out (STRIKE still draws it on the first tap)
	draw.text = if s.drawn then "SHEATHE" else "DRAW"
	draw.label.Text = draw.text
	heavy.label.TextColor3 = if s.drawn then C.text else C.dim
	heavy.b.BackgroundTransparency = if s.drawn then 0.22 else 0.45
	strike.label.TextColor3 = if s.drawn then C.text else C.gold

	-- cooldowns: seconds left on the button, flash when ready
	if not cooldown(dodge, s.dodgeLeft or 0, cfg.Dodge.Cooldown, t) then
		dodge.label.TextColor3 = C.text
	end
	if not cooldown(grasp, s.tkLeft or 0, cfg.Telekinesis.Cooldown, t) then
		grasp.label.TextColor3 = C.text
	end
	if not cooldown(verdict, s.verdictLeft or 0, cfg.Verdict.Cooldown, t) then
		verdict.label.TextColor3 = C.text
	end

	-- RUN: gold while sprinting
	run.ring.Color = if s.sprint then C.gold elseif run.down then C.rimHot else C.rim
	run.label.TextColor3 = if s.sprint then C.gold else C.text

	-- ULT: fills with kills; when full it burns (pulsing halo and ring) and the label turns gold
	local charge = math.clamp((player:GetAttribute("Ultimate") or 0) / 100, 0, 1)
	ult.fill.Size = UDim2.fromScale(1, charge)
	if charge >= 1 and s.drawn then
		local p = 0.5 + 0.5 * math.sin(t * 8)
		ult.ring.Color = C.rim:Lerp(C.gold, p)
		ult.ring.Transparency = 0
		ult.stroke.Color = C.iron:Lerp(C.rimHot, p)
		if not ult.down then
			ult.halo.BackgroundTransparency = 0.75 - 0.35 * p
		end
		ult.fill.BackgroundTransparency = 0.15 + 0.15 * p
		ult.label.TextColor3 = C.gold
	else
		if not ult.down then
			ult.ring.Color = C.rim
			ult.ring.Transparency = 0.3
			ult.stroke.Color = C.iron
			ult.halo.BackgroundTransparency = 1
		end
		ult.fill.BackgroundTransparency = 0.4
		ult.label.TextColor3 = if s.drawn then C.text else C.dim
	end
end)
