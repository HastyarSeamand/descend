-- The serialized place stores the model recipe. Each test session bakes it into shared meshes.
local AssetService = game:GetService("AssetService")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")

local Animation = require(script.Parent.Motion)
local meshes = script.Parent.Meshes
local prototypes = {}
local baking = {}

local Rig = {}

local function vector(list)
	return Vector3.new(list[1], list[2], list[3])
end

local function colorKey(rgb)
	return rgb[1] * 65536 + rgb[2] * 256 + rgb[3]
end

local function bakeTexture(joints)
	local palette, indexes = {}, {}
	for _, joint in ipairs(joints) do
		for _, rgb in ipairs(joint.colors) do
			local key = colorKey(rgb)
			if not indexes[key] then
				table.insert(palette, rgb)
				indexes[key] = #palette - 1
			end
		end
	end
	local side = 8
	while side * side < #palette * 128 do
		side *= 2
	end
	local columns = side / 8
	local pixels = buffer.create(side * side * 4)
	buffer.fill(pixels, 0, 255)
	for index, rgb in ipairs(palette) do
		local cell = index - 1
		local left = cell % columns * 8
		local top = math.floor(cell / columns) * 8
		for y = 0, 7 do
			for x = 0, 7 do
				local variation = ((x * 13 + y * 7 + x * y * 3) % 11) - 5
				local offset = 4 * ((top + y) * side + left + x)
				-- Mirror the swatches so both UV Y conventions sample the same paint.
				local reflected = 4 * ((side - 1 - top - y) * side + left + x)
				for channel = 0, 2 do
					local value = math.clamp(rgb[channel + 1] + variation, 0, 255)
					buffer.writeu8(pixels, offset + channel, value)
					buffer.writeu8(pixels, reflected + channel, value)
				end
				buffer.writeu8(pixels, offset + 3, 255)
				buffer.writeu8(pixels, reflected + 3, 255)
			end
		end
	end
	local image = assert(AssetService:CreateEditableImage({Size = Vector2.new(side, side)}))
	image:WritePixelsBuffer(Vector2.zero, image.Size, pixels)
	local status, content = AssetService:CreateDataModelContentAsync(Content.fromObject(image))
	image:Destroy()
	assert(status == Enum.CreateContentResult.Success, tostring(status))
	return {content = content, indexes = indexes, side = side, columns = columns}
end

local function bakePart(joint, texture)
	local mesh = assert(AssetService:CreateEditableMesh(), "Monster mesh memory budget exhausted")
	local points, vertices, colors, uvs = {}, {}, {}, {}
	local low = Vector3.new(math.huge, math.huge, math.huge)
	local high = -low
	for index, value in ipairs(joint.vertices) do
		local point = vector(value)
		points[index] = point
		low = Vector3.new(math.min(low.X, point.X), math.min(low.Y, point.Y), math.min(low.Z, point.Z))
		high = Vector3.new(math.max(high.X, point.X), math.max(high.Y, point.Y), math.max(high.Z, point.Z))
	end
	local center = (low + high) * 0.5
	for index, point in ipairs(points) do
		vertices[index] = mesh:AddVertex(point - center)
	end
	for index, rgb in ipairs(joint.colors) do
		if texture then
			local cell = texture.indexes[colorKey(rgb)]
			local x, y = cell % texture.columns * 8, math.floor(cell / texture.columns) * 8
			local side = texture.side
			uvs[index] = {
				mesh:AddUV(Vector2.new((x + 2) / side, (y + 2) / side)),
				mesh:AddUV(Vector2.new((x + 6) / side, (y + 2) / side)),
				mesh:AddUV(Vector2.new((x + 2) / side, (y + 6) / side)),
			}
		else
			colors[index] = mesh:AddColor(Color3.fromRGB(rgb[1], rgb[2], rgb[3]), 1)
		end
	end
	for _, face in ipairs(joint.faces) do
		local a, b, c, palette = face[1], face[2], face[3], face[4]
		local id = mesh:AddTriangle(vertices[a], vertices[b], vertices[c])
		if texture then
			mesh:SetFaceUVs(id, uvs[palette])
		else
			local color = colors[palette]
			mesh:SetFaceColors(id, {color, color, color})
		end
		local normal = mesh:AddNormal((points[b] - points[a]):Cross(points[c] - points[a]).Unit)
		mesh:SetFaceNormals(id, {normal, normal, normal})
	end
	local status, content = AssetService:CreateDataModelContentAsync(Content.fromObject(mesh))
	assert(status == Enum.CreateContentResult.Success, "Could not bake " .. joint.name .. ": " .. tostring(status))
	mesh:Destroy()
	local part = AssetService:CreateMeshPartAsync(content, {
		CollisionFidelity = Enum.CollisionFidelity.Box,
		RenderFidelity = Enum.RenderFidelity.Precise,
	})
	part.Name = joint.name
	if texture then
		part.TextureContent = texture.content
	end
	part.Color = Color3.new(1, 1, 1)
	part.Material = Enum.Material.SmoothPlastic
	part.CanCollide = false
	part.CanTouch = false
	part.Massless = true
	part.CFrame = CFrame.new(vector(joint.at) + center)
	return part
end

local function bakeMonster(id)
	local data = HttpService:JSONDecode(require(meshes:FindFirstChild(id)))
	local ok, texture = pcall(bakeTexture, data.joints)
	if not ok then
		warn("[MonsterTest] Using face colors for " .. id .. ": " .. tostring(texture))
		texture = nil
	end
	local model = Instance.new("Model")
	model.Name = id
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(1.3, 1.7, 1.05)
	root.CFrame = CFrame.new(0, math.max(0.8, data.joints[1].at[2]), 0)
	root.PivotOffset = CFrame.new(0, -root.Position.Y, 0)
	root.Transparency = 1
	root.CanCollide = false
	root.CanTouch = false
	root.Anchored = true
	root.CastShadow = false
	root.Parent = model
	model.PrimaryPart = root

	local parts = {}
	for _, joint in ipairs(data.joints) do
		local part = bakePart(joint, texture)
		local parent = if joint.parent then assert(parts[joint.parent]) else root
		local pivot = CFrame.new(vector(joint.at))
		local motor = Instance.new("Motor6D")
		motor.Name = joint.name .. "Joint"
		motor.C0 = parent.CFrame:ToObjectSpace(pivot)
		motor.C1 = part.CFrame:ToObjectSpace(pivot)
		motor.Part0 = parent
		motor.Part1 = part
		motor.Parent = part
		part.Parent = model
		parts[joint.name] = part
	end
	if parts.Shield then
		local blockSound = Instance.new("Sound")
		blockSound.Name = "BlockSound"
		blockSound.SoundId = "rbxassetid://9113449585"
		blockSound.Volume = 0.5
		blockSound.RollOffMaxDistance = 48
		blockSound.Parent = parts.Shield
	end

	local humanoid = Instance.new("Humanoid")
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	humanoid.AutoRotate = false
	humanoid.WalkSpeed = 0
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.Parent = model
	return model
end

local function getPrototype(id)
	while baking[id] do
		task.wait()
	end
	if not prototypes[id] then
		baking[id] = true
		local success, result = pcall(bakeMonster, id)
		baking[id] = nil
		if not success then
			error(result, 2)
		end
		prototypes[id] = result
	end
	return prototypes[id]
end

local function addHealthBar(model, humanoid)
	local root = model.PrimaryPart
	local box, size = model:GetBoundingBox()
	local height = box.Position.Y + size.Y * 0.5 - root.Position.Y + 0.5
	local gui = Instance.new("BillboardGui")
	gui.Name = "MonsterHealthBar"
	gui.Adornee = root
	gui.Size = UDim2.fromOffset(76, 22)
	gui.StudsOffsetWorldSpace = Vector3.yAxis * height
	gui.MaxDistance = 38
	gui.AlwaysOnTop = true

	local label = Instance.new("TextLabel")
	label.Name = "MonsterName"
	label.Size = UDim2.new(1, 0, 0, 13)
	label.BackgroundTransparency = 1
	label.Text = model.Name
	label.TextSize = 11
	label.Font = Enum.Font.GothamMedium
	label.TextColor3 = Color3.fromRGB(242, 230, 218)
	label.TextStrokeTransparency = 0.45
	label.Parent = gui

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Position = UDim2.fromOffset(2, 14)
	track.Size = UDim2.fromOffset(72, 7)
	track.BorderSizePixel = 0
	track.BackgroundColor3 = Color3.fromRGB(22, 13, 14)
	track.Parent = gui

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Position = UDim2.fromOffset(1, 1)
	fill.BorderSizePixel = 0
	fill.BackgroundColor3 = Color3.fromRGB(192, 35, 41)
	fill.Parent = track

	local tween
	local function sync(animate)
		local fraction = math.clamp(humanoid.Health / math.max(1, humanoid.MaxHealth), 0, 1)
		local width = UDim2.fromOffset(70 * fraction, 5)
		gui.Enabled = fraction > 0
		if tween then
			tween:Cancel()
			tween = nil
		end
		if animate and gui.Enabled then
			tween = TweenService:Create(fill, TweenInfo.new(0.11, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Size = width})
			tween:Play()
		else
			fill.Size = width
		end
	end
	sync(false)
	humanoid.HealthChanged:Connect(function()
		sync(true)
	end)
	humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(function()
		sync(false)
	end)
	gui.Parent = model
end

function Rig.spawn(id, pivot, parent, displayName)
	local model = getPrototype(id):Clone()
	model.Name = displayName or id
	local joints = {}
	for _, part in ipairs(model:GetChildren()) do
		local joint = part:FindFirstChildOfClass("Motor6D")
		if joint then
			joints[part.Name] = {motor = joint, rest = joint.C0}
		end
	end
	model:PivotTo(pivot)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	addHealthBar(model, humanoid)
	model.Parent = parent
	return {
		id = id,
		model = model,
		root = model.PrimaryPart,
		humanoid = humanoid,
		joints = joints,
	}
end

function Rig.pose(rig, clip, time, moveAlpha)
	local transforms = Animation.sample(rig.id, clip, time, moveAlpha)
	for name, joint in pairs(rig.joints) do
		joint.motor.C0 = joint.rest * (transforms[name] or CFrame.identity)
	end
end

return Rig
