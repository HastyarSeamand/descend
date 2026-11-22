-- The Descent: WORLD MONSTERS (Cursed Woods camps).
-- Same fighting AI as monsters\runtime\MonsterTest.server.luau (windups, lunges, cinders, summons, guard), but
-- instead of one arena with an encounter sign, monsters live in CAMPS spread over the map:
--   * each camp = a home point, a leash radius and a list of monsters (ReplicatedStorage.Descent.WoodsLayout.Camps)
--   * monsters only fight players inside their camp area and walk home when nobody is there
--   * a cleared camp respawns after its timer, but never in front of a player
-- Shared modules (Rig, Motion, Roster, MotionData, Meshes) are the Codex monster files, unchanged.

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Roster = require(script.Parent:WaitForChild("Roster"))
local Rig = require(script.Parent:WaitForChild("Rig"))
local combat = ReplicatedStorage:WaitForChild("Descent")
-- camps come from the island's layout module (IslandLayout on island one; falls back to the old WoodsLayout)
local Layout = require(combat:FindFirstChild("IslandLayout") or combat:WaitForChild("WoodsLayout"))
local remotes = combat:FindFirstChild("Remotes")
local combatFX = remotes and remotes:FindFirstChild("CombatFX")
local weaponConfig = combat:FindFirstChild("WeaponConfig")
local ultimateCharge = if weaponConfig then require(weaponConfig).Gravecleaver.Ultimate.ChargePerKill else 20

local SOULS_PER_KILL = 10
local RETURN_SPEED_MULT = 0.75

local demons = Workspace:FindFirstChild("Demons")
if not demons then
	demons = Instance.new("Folder")
	demons.Name = "Demons"
	demons.Parent = Workspace
end
local effects = Workspace:FindFirstChild("MonsterEffects") or Instance.new("Folder")
effects.Name = "MonsterEffects"
effects.Parent = Workspace

-- monsters walk on the terrain only (so they never end up on a tree or a rock top)
local groundRay = RaycastParams.new()
groundRay.FilterType = Enum.RaycastFilterType.Include
groundRay.FilterDescendantsInstances = { Workspace.Terrain }

local camps = {}
local monsters = {}
local cinders = {}
local targets = {}

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function groundAt(position)
	local from = Vector3.new(position.X, position.Y + 60, position.Z)
	local hit = Workspace:Raycast(from, Vector3.new(0, -(position.Y + 260), 0), groundRay)
	return Vector3.new(position.X, if hit then hit.Position.Y else position.Y, position.Z)
end

local function insideCamp(camp, position)
	local offset = flat(position - camp.center)
	if offset.Magnitude > camp.radius then
		local p = camp.center + offset.Unit * camp.radius
		return Vector3.new(p.X, position.Y, p.Z)
	end
	return position
end

local function facingAt(position, direction)
	return CFrame.lookAt(position, position + direction, Vector3.yAxis)
end

local function refreshTargets()
	table.clear(targets)
	local ignored = { demons, effects }
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if character then
			table.insert(ignored, character)
		end
		if root and humanoid and humanoid.Health > 0 then
			table.insert(targets, { root = root, humanoid = humanoid, character = character, player = player })
		end
	end
end

local function inCampArea(camp, position)
	return flat(position - camp.center).Magnitude <= camp.radius + 12 and math.abs(position.Y - camp.center.Y) <= 30
end

local function nearestTarget(monster, position, range)
	local closest
	for _, target in targets do
		if inCampArea(monster.camp, target.root.Position) then
			local distance = flat(target.root.Position - position).Magnitude
			if distance <= range then
				closest, range = target, distance
			end
		end
	end
	return closest, range
end

local function playerNear(camp, extra)
	for _, target in targets do
		if flat(target.root.Position - camp.center).Magnitude <= camp.radius + extra then
			return true
		end
	end
	return false
end

local function damage(target, amount, source)
	local untilTime = target.character:GetAttribute("IFrameUntil") or target.player:GetAttribute("IFrameUntil")
	if typeof(untilTime) == "number" and Workspace:GetServerTimeNow() < untilTime then
		return
	end
	local before = target.humanoid.Health
	if before > 0 then
		target.humanoid:TakeDamage(amount)
		local lost = before - target.humanoid.Health
		if lost > 0 and combatFX then
			combatFX:FireClient(target.player, "MonsterDamage", target.character, lost, amount, source)
		end
	end
end

local function creditKill(rig)
	local killerId = rig.model:GetAttribute("LastHitBy")
	local killer = if typeof(killerId) == "number" then Players:GetPlayerByUserId(killerId) else nil
	if not killer then
		return
	end
	local leaderstats = killer:FindFirstChild("leaderstats")
	local souls = leaderstats and leaderstats:FindFirstChild("Souls")
	if souls then
		souls.Value += SOULS_PER_KILL
	end
	local curse = (killer:GetAttribute("Curse") or 0) + 0.06
	killer:SetAttribute("Curse", if curse <= 1 then curse else 0)
	if (killer:GetAttribute("UltLockUntil") or 0) < Workspace:GetServerTimeNow() then
		killer:SetAttribute("Ultimate", math.min(100, (killer:GetAttribute("Ultimate") or 0) + ultimateCharge))
	end
	if combatFX then
		combatFX:FireAllClients("Kill", killer.Character, rig.root.Position, SOULS_PER_KILL)
	end
end

local function cue(parent, soundData)
	if not soundData then
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = soundData[1]
	sound.Volume = soundData[2]
	sound.PlaybackSpeed = soundData[3]
	sound.RollOffMaxDistance = 36
	sound.Parent = parent
	sound:Play()
	Debris:AddItem(sound, 3)
end

local function markerPart(name, position)
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.one
	part.Position = position
	return part
end

local function hazardMarker(point, reach)
	local part = markerPart("Cinder warning", point)
	part.Material = Enum.Material.Neon
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(0.08, reach * 2, reach * 2)
	part.CFrame = CFrame.new(point + Vector3.yAxis * 0.06) * CFrame.Angles(0, 0, math.pi / 2)
	part.Color = Color3.fromRGB(137, 192, 186)
	part.Transparency = 0.5
	part.Parent = effects
	return part
end

local function changeState(monster, state, now)
	monster.state = state
	monster.stateTime = now
	monster.rig.model:SetAttribute("MonsterState", state)
	monster.rig.model:SetAttribute("MonsterFrontalGuard", monster.config.guard == true and state ~= "Death")
end

local function spawnMonster(camp, id, at, direction, now)
	local config = Roster.Monsters[id]
	local rig = Rig.spawn(id, facingAt(groundAt(at), direction), demons, config.name)
	rig.model:SetAttribute("DescentTestMonster", true) -- the sword's hit code keys off this attribute
	rig.model:SetAttribute("MonsterId", id)
	rig.model:SetAttribute("Camp", camp.name)
	rig.humanoid.MaxHealth = config.health
	rig.humanoid.Health = config.health
	local monster = { id = id, rig = rig, config = config, health = config.health, nextAttack = now + 0.45, camp = camp, home = at }
	table.insert(monsters, monster)
	table.insert(camp.alive, monster)
	changeState(monster, "Idle", now)
	Rig.pose(rig, "Idle", 0)
	return monster
end

local function spawnCamp(camp)
	camp.spawning = true
	local now = os.clock()
	local ids = camp.ids
	local facing = Vector3.new(math.sin(camp.facing), 0, math.cos(camp.facing))
	local tangent = Vector3.new(-facing.Z, 0, facing.X)
	local ok, err = pcall(function()
		for slot, id in ids do
			local offset = (slot - (#ids + 1) / 2) * 8
			local at = camp.center + tangent * offset
			if (id == "CinderPorter" or id == "Bellwretch") and #ids > 1 then
				at -= facing * 7
			end
			spawnMonster(camp, id, at, facing, now)
		end
	end)
	if not ok then
		warn("[WorldMonsters] camp " .. camp.name .. ": " .. tostring(err))
	end
	camp.spawning = false
	camp.clearedAt = nil
end

local function lungeDistance(attack, distance)
	if attack.kind == "Pounce" then
		local contactFraction = (Roster.Contact - attack.travelStart) / (attack.travelEnd - attack.travelStart)
		return math.min(attack.travel, math.max(0, distance - 1.3) / contactFraction)
	end
	return math.min(attack.travel or 0, math.max(0, distance - 2.1))
end

local function startAttack(monster, target, now)
	local pivot = monster.rig.model:GetPivot()
	local delta = flat(target.root.Position - pivot.Position)
	local facing = if delta.Magnitude > 0.05 then delta.Unit else pivot.LookVector
	monster.origin = pivot.Position
	monster.facing = facing
	monster.target = target
	monster.aim = nil
	monster.released = false
	monster.hitPlayers = {}
	monster.travel = lungeDistance(monster.config.attack, delta.Magnitude)
	changeState(monster, "Attack", now)
	monster.rig.model:PivotTo(facingAt(pivot.Position, facing))
	if monster.id == "Shardling" then
		monster.camp.nextPackAttack = now + 0.36
	end
	cue(monster.rig.root, monster.config.tell)
end

local function trackWindup(monster, dt)
	local target = monster.target
	if not target.root.Parent or target.humanoid.Health <= 0 then
		return
	end
	local attack = monster.config.attack
	local delta = flat(target.root.Position - monster.origin)
	if attack.lead then
		local lead = flat(target.root.AssemblyLinearVelocity) * attack.lead
		delta += if lead.Magnitude > 3.5 then lead.Unit * 3.5 else lead
	end
	local distance = delta.Magnitude
	if distance < 0.05 then
		return
	end
	local desired = delta.Unit
	local facing = monster.facing
	local turn = math.atan2(facing:Cross(desired).Y, facing:Dot(desired))
	local limit = math.rad(360) * dt
	monster.facing = CFrame.fromAxisAngle(Vector3.yAxis, math.clamp(turn, -limit, limit)):VectorToWorldSpace(facing)
	monster.rig.model:PivotTo(facingAt(monster.origin, monster.facing))
	monster.travel = lungeDistance(attack, distance)
end

local function markCinder(monster, phase)
	local attack = monster.config.attack
	local root = monster.target.root
	local destination = monster.origin + monster.facing * monster.config.stance
	if root.Parent and monster.target.humanoid.Health > 0 then
		local timeToImpact = (Roster.Contact - phase) * attack.duration + attack.flightTime
		local lead = flat(root.AssemblyLinearVelocity) * timeToImpact
		if lead.Magnitude > 8 then
			lead = lead.Unit * 8
		end
		destination = root.Position + lead
	end
	monster.aim = groundAt(insideCamp(monster.camp, destination))
	monster.warning = hazardMarker(monster.aim, attack.reach)
end

local function clearWarning(monster)
	if monster.warning then
		monster.warning:Destroy()
		monster.warning = nil
	end
end

local function releaseCinder(monster, now)
	local attack = monster.config.attack
	local ember = markerPart("Thrown cinder", monster.rig.model:GetPivot().Position + Vector3.yAxis * 3.5)
	ember.Material = Enum.Material.Neon
	ember.Shape = Enum.PartType.Ball
	ember.Size = Vector3.one * 0.7
	ember.Color = Color3.fromRGB(233, 125, 64)
	ember.Transparency = 0.1
	ember.Parent = effects
	table.insert(cinders, {
		ember = ember, floor = monster.warning, position = monster.aim, launch = ember.Position,
		at = now, reach = attack.reach, damage = attack.damage, pulses = 0, flightTime = attack.flightTime,
	})
	monster.warning = nil
end

local function summonShardling(monster, now)
	local tangent = Vector3.new(-monster.facing.Z, 0, monster.facing.X)
	local position = insideCamp(monster.camp, monster.origin + tangent * 4 + monster.facing * 3)
	local direction = monster.facing
	monster.summoning = true
	task.spawn(function()
		local ok, shard = pcall(spawnMonster, monster.camp, "Shardling", position, direction, now)
		if ok then
			shard.summoned = true
			monster.shard = shard
		else
			warn("[WorldMonsters] " .. tostring(shard))
		end
		monster.summoning = false
	end)
end

local function strikeHits(attack, monster, target, origin, previousPosition)
	local delta = flat(target.root.Position - origin)
	if math.abs(target.root.Position.Y - origin.Y) > 7.5 then
		return false
	end
	if attack.kind == "Slam" then
		return delta:Dot(monster.facing) >= 0 and (delta - monster.facing * attack.impactOffset).Magnitude <= attack.reach
	end
	if attack.kind == "Pounce" then
		local fromOrigin = flat(target.root.Position - previousPosition)
		local along = fromOrigin:Dot(monster.facing)
		local distance = flat(origin - previousPosition):Dot(monster.facing)
		local point = monster.facing * math.clamp(along, 0, math.max(0, distance))
		return (fromOrigin - point).Magnitude <= attack.reach
	end
	return delta.Magnitude <= attack.reach and (delta.Magnitude < 0.9 or delta.Unit:Dot(monster.facing) >= attack.minDot)
end

local function releaseAttack(monster, now)
	local attack = monster.config.attack
	if attack.kind == "Throw" then
		releaseCinder(monster, now)
	elseif attack.kind == "Summon" then
		cue(monster.rig.root, { "rbxassetid://9113804171", 0.55, 0.85 })
		summonShardling(monster, now)
	elseif attack.kind == "Slam" then
		cue(monster.rig.root, { "rbxassetid://9118613699", 0.7, 0.8 })
	end
end

local function stepAttack(monster, now, dt)
	local attack = monster.config.attack
	local phase = math.clamp((now - monster.stateTime) / attack.duration, 0, 1)
	if attack.trackUntil and phase < attack.trackUntil then
		trackWindup(monster, dt)
	end
	if attack.markAt and phase >= attack.markAt and not monster.aim then
		markCinder(monster, math.min(phase, Roster.Contact))
	end
	local pivot = monster.rig.model:GetPivot()
	local previousPosition = pivot.Position
	if monster.travel and monster.travel > 0 then
		local fraction = math.clamp((phase - attack.travelStart) / (attack.travelEnd - attack.travelStart), 0, 1)
		local at = groundAt(insideCamp(monster.camp, monster.origin + monster.facing * (monster.travel * fraction)))
		monster.rig.model:PivotTo(facingAt(at, monster.facing))
	end
	if monster.config.guard and phase >= 0.36 and monster.rig.model:GetAttribute("MonsterFrontalGuard") then
		monster.rig.model:SetAttribute("MonsterFrontalGuard", false)
	end
	Rig.pose(monster.rig, "Attack", phase)
	if phase >= Roster.Contact then
		local firstContact = not monster.released
		if firstContact then
			monster.released = true
			releaseAttack(monster, now)
		end
		if not attack.markAt and attack.damage and (firstContact or phase <= (attack.activeEnd or 0.64)) then
			local position = monster.rig.model:GetPivot().Position
			for _, target in targets do
				if not monster.hitPlayers[target.player] and strikeHits(attack, monster, target, position, previousPosition) then
					monster.hitPlayers[target.player] = true
					damage(target, attack.damage, position)
				end
			end
		end
	end
	if phase >= 1 then
		monster.nextAttack = now + monster.config.cooldown
		changeState(monster, "Idle", now)
	end
end

local function stepCinders(now)
	for index = #cinders, 1, -1 do
		local cinder = cinders[index]
		local flight = math.clamp((now - cinder.at) / cinder.flightTime, 0, 1)
		if flight < 1 then
			cinder.ember.Position = cinder.launch:Lerp(cinder.position, flight) + Vector3.yAxis * (math.sin(flight * math.pi) * 3)
		else
			if cinder.ember.Parent then
				cinder.ember:Destroy()
				if cinder.floor then
					cinder.floor.Name = "Scorched ground"
					cinder.floor.Color = Color3.fromRGB(196, 88, 40)
					cinder.floor.Transparency = 0.47
				end
			end
			local burnTime = now - cinder.at - cinder.flightTime
			if cinder.pulses < 2 and burnTime >= cinder.pulses * 0.72 then
				cinder.pulses += 1
				for _, target in targets do
					local difference = target.root.Position - cinder.position
					if flat(difference).Magnitude <= cinder.reach and math.abs(difference.Y) <= 5 then
						damage(target, cinder.damage, cinder.position)
					end
				end
			end
			if burnTime >= 1.35 then
				if cinder.floor then
					cinder.floor:Destroy()
				end
				table.remove(cinders, index)
			end
		end
	end
end

local function canAttack(monster, distance, now)
	if distance > monster.config.stance or now < monster.nextAttack then
		return false
	end
	if monster.id == "Shardling" then
		return now >= (monster.camp.nextPackAttack or 0)
	end
	if monster.id == "Bellwretch" then
		return not monster.summoning and (not monster.shard or monster.shard.rig.humanoid.Health <= 0)
	end
	return true
end

local function takeHit(monster, now)
	local rig = monster.rig
	local heavy = rig.model:GetAttribute("MonsterHeavyStagger") == true
	local impulse = rig.model:GetAttribute("MonsterHitImpulse")
	rig.model:SetAttribute("MonsterHeavyStagger", nil)
	rig.model:SetAttribute("MonsterHitImpulse", nil)
	local canInterrupt = monster.config.interruptible and not monster.released
		or heavy and (monster.id ~= "CairnGiant" or monster.released)
	if monster.state == "Attack" and not canInterrupt then
		return
	end
	clearWarning(monster)
	monster.nextAttack = math.max(monster.nextAttack, now + (if heavy then 0.55 else 0.34))
	monster.hurtDuration = if heavy then 0.48 else 0.25
	local weight = if monster.id == "CairnGiant" then 0.38 else 1
	monster.hurtPush = if typeof(impulse) == "Vector3" then flat(impulse) * weight else Vector3.zero
	monster.hurtLift = if typeof(impulse) == "Vector3" then impulse.Y * weight else 0
	changeState(monster, "Hurt", now)
end

local function stepHurt(monster, now, dt)
	local rig = monster.rig
	local elapsed = now - monster.stateTime
	local pivot = rig.model:GetPivot()
	local push = monster.hurtPush * (dt * math.exp(-7.2 * elapsed))
	local ground = groundAt(insideCamp(monster.camp, pivot.Position + push))
	local lift = math.max(0, monster.hurtLift * elapsed - Workspace.Gravity * elapsed ^ 2 / 2)
	rig.model:PivotTo(pivot + (ground + Vector3.yAxis * lift - pivot.Position))
	Rig.pose(rig, "Hurt", elapsed)
	if elapsed >= monster.hurtDuration then
		rig.model:PivotTo(pivot + (ground - pivot.Position))
		changeState(monster, "Idle", now)
	end
end

local function stepMonster(monster, now, dt)
	local rig = monster.rig
	if monster.state == "Death" then
		local elapsed = now - monster.stateTime
		if elapsed > 1.85 then
			rig.model:Destroy()
			return false
		end
		Rig.pose(rig, "Death", elapsed)
		return true
	end
	if rig.humanoid.Health <= 0 then
		clearWarning(monster)
		local pivot = rig.model:GetPivot()
		rig.model:PivotTo(pivot + (groundAt(pivot.Position) - pivot.Position))
		changeState(monster, "Death", now)
		creditKill(rig)
		return true
	end
	if rig.humanoid.Health < monster.health then
		takeHit(monster, now)
	end
	monster.health = rig.humanoid.Health
	if monster.state == "Hurt" then
		stepHurt(monster, now, dt)
		return true
	end
	if monster.state == "Attack" then
		stepAttack(monster, now, dt)
		return true
	end

	local position = rig.model:GetPivot().Position
	local target, distance = nearestTarget(monster, position, monster.config.aggro)
	if target and canAttack(monster, distance, now) then
		startAttack(monster, target, now)
		Rig.pose(rig, "Attack", 0)
		return true
	end

	local movement = Vector3.zero
	local face
	local speed = monster.config.speed
	if target then
		local delta = flat(target.root.Position - position)
		if delta.Magnitude > 0.05 then
			local direction = delta.Unit
			face = direction
			if distance > monster.config.stance * 0.92 then
				movement = direction
			elseif (monster.id == "Bellwretch" or monster.id == "CinderPorter") and distance < 6 then
				movement = -direction * 0.65
			elseif monster.id == "Hookjaw" and distance > 3 then
				movement = Vector3.new(-direction.Z, 0, direction.X) * 0.64
			end
		end
	else
		-- nobody in the camp: walk back home and heal up
		local home = flat(monster.home - position)
		if home.Magnitude > 3 then
			movement = home.Unit
			face = home.Unit
			speed *= RETURN_SPEED_MULT
		elseif rig.humanoid.Health < rig.humanoid.MaxHealth then
			rig.humanoid.Health = math.min(rig.humanoid.MaxHealth, rig.humanoid.Health + rig.humanoid.MaxHealth * 0.25 * dt)
			monster.health = rig.humanoid.Health
		end
	end
	if face then
		local nextPosition = groundAt(insideCamp(monster.camp, position + movement * (speed * dt)))
		rig.model:PivotTo(facingAt(nextPosition, face))
	end

	local moving = movement.Magnitude > 0.05
	local state = if moving then "Walk" else "Idle"
	if monster.state ~= state then
		changeState(monster, state, now)
	end
	local clip = if not moving and monster.config.guard then "Guard" else state
	Rig.pose(rig, clip, now - monster.stateTime, movement.Magnitude)
	return true
end

-- camps from the layout
for _, c in Layout.Camps or {} do
	local center = groundAt(Vector3.new(c.x, 400, c.z))
	local camp = {
		name = c.name, center = center, radius = c.radius or 50, ids = c.ids,
		respawn = c.respawn or 60, facing = math.rad(c.facing or 180), alive = {}, spawning = false,
	}
	table.insert(camps, camp)
end

RunService.Heartbeat:Connect(function(dt)
	refreshTargets()
	local now = os.clock()
	stepCinders(now)
	for index = #monsters, 1, -1 do
		local monster = monsters[index]
		if not monster.rig.model.Parent or not stepMonster(monster, now, math.min(dt, 0.1)) then
			table.remove(monsters, index)
			local list = monster.camp.alive
			local at = table.find(list, monster)
			if at then
				table.remove(list, at)
			end
		end
	end
	for _, camp in camps do
		if not camp.spawning and #camp.alive == 0 then
			if camp.clearedAt == nil then
				camp.clearedAt = now
			elseif now - camp.clearedAt >= camp.respawn and not playerNear(camp, 30) then
				task.spawn(spawnCamp, camp)
			end
		end
	end
end)

-- first wave: every camp starts populated (spawned one at a time so the mesh baking doesn't stall the server)
task.spawn(function()
	for _, camp in camps do
		spawnCamp(camp)
		task.wait(0.2)
	end
end)

-- Studio test hook: script.Parent.TestControl:Invoke("list") or ("respawn", campName)
local testControl = Instance.new("BindableFunction")
testControl.Name = "TestControl"
testControl.OnInvoke = function(cmd, arg)
	if cmd == "list" then
		local out = {}
		for _, camp in camps do
			table.insert(out, string.format("%s @(%d,%d,%d) alive %d", camp.name, camp.center.X, camp.center.Y, camp.center.Z, #camp.alive))
		end
		return table.concat(out, "\n")
	elseif cmd == "respawn" then
		for _, camp in camps do
			if camp.name == arg and #camp.alive == 0 then
				task.spawn(spawnCamp, camp)
				return true
			end
		end
		return false
	end
end
testControl.Parent = script.Parent
