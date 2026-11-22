-- The Descent: DAY / NIGHT cycle (server; Lighting replicates to every client).
-- TEST timing (2026-11-22): the time flips every 3 minutes: 3 min of day, then 3 min of night,
-- with a short sunset / sunrise blend in between.
-- Each island sets its own look in its layout module (IslandLayout.Day / IslandLayout.Night).
-- Island one (Cursed Woods): clear by day, thick teal-green FOG only at night (the first Woods version's mood).
-- Studio test: ServerScriptService.Descent.DayNight.Control:Invoke("night" | "day" | "dusk" | "status")
-- Tune live: workspace attribute DayNightHalf = seconds per half (default 180).

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local descent = ReplicatedStorage:WaitForChild("Descent")
local layoutModule = descent:FindFirstChild("IslandLayout")
local layout = layoutModule and require(layoutModule) or {}

local DEFAULT_HALF = 180 -- seconds of day, then the same of night
local BLEND = 18 -- seconds of sunset / sunrise

-- the island's looks (falls back to a clear day and a foggy cursed night)
local DAY = layout.Day or {
	Brightness = 2.4, Exposure = 0, Ambient = Color3.fromRGB(70, 74, 78), Outdoor = Color3.fromRGB(128, 134, 138),
	ShiftTop = Color3.fromRGB(255, 244, 226),
	FogDensity = 0.3, FogOffset = 0.05, FogHaze = 1.2, FogGlare = 0.2,
	FogColor = Color3.fromRGB(196, 210, 214), FogDecay = Color3.fromRGB(112, 122, 132),
	Saturation = -0.05, Contrast = 0.08, Tint = Color3.fromRGB(255, 250, 244), GradeBrightness = 0,
	Bloom = 0.5, BloomThreshold = 2,
}
local NIGHT = layout.Night or {
	Brightness = 1.4, Exposure = 0.7, Ambient = Color3.fromRGB(44, 54, 58), Outdoor = Color3.fromRGB(92, 112, 118),
	ShiftTop = Color3.fromRGB(150, 175, 200),
	FogDensity = 0.47, FogOffset = 0.2, FogHaze = 2.6, FogGlare = 0,
	FogColor = Color3.fromRGB(100, 130, 124), FogDecay = Color3.fromRGB(48, 66, 66),
	Saturation = -0.2, Contrast = 0.12, Tint = Color3.fromRGB(214, 236, 230), GradeBrightness = 0.02,
	Bloom = 0.8, BloomThreshold = 1.4,
}

local function get(class, name)
	local found = Lighting:FindFirstChildOfClass(class)
	if not found then
		found = Instance.new(class)
		found.Name = name
		found.Parent = Lighting
	end
	return found
end
local atmosphere = get("Atmosphere", "Atmosphere")
local grade = Lighting:FindFirstChild("WoodsGrade") or get("ColorCorrectionEffect", "WoodsGrade")
local bloom = get("BloomEffect", "Bloom")

local function lerp(a, b, t)
	return a + (b - a) * t
end
local function smooth(a, b, x)
	local t = math.clamp((x - a) / (b - a), 0, 1)
	return t * t * (3 - 2 * t)
end

-- w = 0 day .. 1 night
local function apply(w, clock)
	Lighting.ClockTime = clock % 24
	Lighting.Brightness = lerp(DAY.Brightness, NIGHT.Brightness, w)
	Lighting.ExposureCompensation = lerp(DAY.Exposure, NIGHT.Exposure, w)
	Lighting.Ambient = DAY.Ambient:Lerp(NIGHT.Ambient, w)
	Lighting.OutdoorAmbient = DAY.Outdoor:Lerp(NIGHT.Outdoor, w)
	Lighting.ColorShift_Top = DAY.ShiftTop:Lerp(NIGHT.ShiftTop, w)
	-- the fog comes in late in the sunset and leaves early in the sunrise (w^1.5), so dusk still has a view
	local f = w ^ 1.5
	atmosphere.Density = lerp(DAY.FogDensity, NIGHT.FogDensity, f)
	atmosphere.Offset = lerp(DAY.FogOffset, NIGHT.FogOffset, f)
	atmosphere.Haze = lerp(DAY.FogHaze, NIGHT.FogHaze, f)
	atmosphere.Glare = lerp(DAY.FogGlare, NIGHT.FogGlare, f)
	atmosphere.Color = DAY.FogColor:Lerp(NIGHT.FogColor, f)
	atmosphere.Decay = DAY.FogDecay:Lerp(NIGHT.FogDecay, f)
	grade.Saturation = lerp(DAY.Saturation, NIGHT.Saturation, w)
	grade.Contrast = lerp(DAY.Contrast, NIGHT.Contrast, w)
	grade.TintColor = DAY.Tint:Lerp(NIGHT.Tint, w)
	grade.Brightness = lerp(DAY.GradeBrightness, NIGHT.GradeBrightness, w)
	bloom.Intensity = lerp(DAY.Bloom, NIGHT.Bloom, w)
	bloom.Threshold = lerp(DAY.BloomThreshold, NIGHT.BloomThreshold, w)
	Lighting:SetAttribute("NightAmount", math.floor(w * 100 + 0.5) / 100)
	Lighting:SetAttribute("IsNight", w > 0.5)
end

-- time line over one full cycle (2 halves): day 7:00 -> 17:00, then night 17:00 -> 7:00 next morning
local start = os.clock()
local function half()
	local h = workspace:GetAttribute("DayNightHalf")
	return if typeof(h) == "number" and h >= 10 then h else DEFAULT_HALF
end
local function sample(t)
	local H = half()
	local T = 2 * H
	t %= T
	local clock, w
	if t < H then
		clock = 7 + 10 * (t / H)
		w = math.max(1 - smooth(0, BLEND, t), smooth(H - BLEND, H + BLEND * 0.2, t)) -- sunrise fades out, sunset fades in
	else
		local n = (t - H) / H
		clock = 17 + 14 * n
		w = 1 - smooth(T - BLEND * 0.2, T + BLEND, t)
		w = math.max(w, smooth(H - BLEND, H + BLEND * 0.2, t))
	end
	return math.clamp(w, 0, 1), clock
end

local accum = 0
RunService.Heartbeat:Connect(function(dt)
	accum += dt
	if accum < 0.2 then
		return
	end
	accum = 0
	local w, clock = sample(os.clock() - start)
	apply(w, clock)
end)

-- Studio test hook: jump to a time of the cycle
local control = Instance.new("BindableFunction")
control.Name = "Control"
control.OnInvoke = function(cmd)
	local H = half()
	if cmd == "day" then
		start = os.clock() - H * 0.5
	elseif cmd == "dusk" then
		start = os.clock() - (H - 4)
	elseif cmd == "night" then
		start = os.clock() - H * 1.5
	end
	local w, clock = sample(os.clock() - start)
	apply(w, clock)
	return string.format("clock %.1f, night %.2f, fog density %.2f", clock % 24, w, atmosphere.Density)
end
control.Parent = script
