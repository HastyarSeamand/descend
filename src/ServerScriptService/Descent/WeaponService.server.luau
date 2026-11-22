-- The Descent: WeaponService (server) v5
-- * Gravecleaver sheathed on the back; the "Gravecleaver" Tool draws/sheathes it (Motor6D re-pointed).
-- * Player-triggered attacks only (SwingRequest "Light" / "Heavy"). Airborne = Ground Slam.
--     Light : 4-hit combo. Hits 1-2 = cleaves (sector in front), hit 3 = spin (circle), hit 4 = slam (circle on the floor ahead, knockback).
--     Heavy : slow two-handed sweep, wide sector hitbox, knockback.
--     Slam  : attacking in the air = overhead ground slam; damage + knockback around the impact when you land.
-- * Sprint + stamina live here too (SprintRequest); walk speed = base x (attack slow-down OR sprint).
-- * Telekinesis "Grave Grasp" (TelekinesisRequest, G): rocks hurled at the aim point, area hit + knockback.
-- * Hitboxes are only live during the strike frames; each demon is hit once per attack.
-- * Dodge + backflip: client moves itself; server checks timing, grants i-frames, cancels unlanded attacks.
-- * The server never writes HumanoidRootPart.CFrame (the client owns its character's physics).

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Descent = RS:WaitForChild("Descent")
local Config = require(Descent:WaitForChild("WeaponConfig"))
local Remotes = Descent:WaitForChild("Remotes")
local CombatFX: RemoteEvent = Remotes:WaitForChild("CombatFX")
local SwingRequest: RemoteEvent = Remotes:WaitForChild("SwingRequest")
local DodgeRequest: RemoteEvent = Remotes:WaitForChild("DodgeRequest")
local SprintRequest: RemoteEvent = Remotes:WaitForChild("SprintRequest")
local SlowWalkRequest: RemoteEvent = Remotes:WaitForChild("SlowWalkRequest")
local UltimateRequest: RemoteEvent = Remotes:WaitForChild("UltimateRequest")
local WeaponsFolder = Descent:WaitForChild("Weapons")
local DEMONS = workspace:WaitForChild("Demons")

local WEAPON = "Gravecleaver"
local cfg = Config[WEAPON]
local FLAT = Vector3.new(1, 0, 1)

local state = {}

local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Include
overlap.FilterDescendantsInstances = { DEMONS }

local function now()
	return workspace:GetServerTimeNow()
end

local function demonFromPart(part: Instance): Model?
	local m = part
	while m and m.Parent ~= DEMONS do
		m = m.Parent
	end
	return m
end

local function flashingDemonNear(pos: Vector3): Model?
	for _, m in ipairs(DEMONS:GetChildren()) do
		local hum = m:FindFirstChildOfClass("Humanoid")
		local root = m:FindFirstChild("HumanoidRootPart")
		if hum and root and hum.Health > 0 and (m:GetAttribute("CritReadyUntil") or 0) > now() then
			if ((root.Position - pos) * FLAT).Magnitude <= cfg.CritRange then
				return m
			end
		end
	end
	return nil
end

local function isEquipped(character: Model)
	return character:GetAttribute("SwordEquipped") == true
end

---------------------------------------------------------------- walk speed: base x (attack slow-down or sprint)
local function applySpeed(player: Player, character: Model)
	local hum = character and character:FindFirstChildOfClass("Humanoid")
	local st = state[player]
	if not hum then
		return
	end
	local base = if isEquipped(character) then cfg.WalkSpeedDrawn else 16
	local speed = base
	if st and st.attackMult then
		speed = base * st.attackMult
	elseif st and st.sprinting then
		speed = base * cfg.Sprint.SpeedMult
	elseif st and st.slowWalk and cfg.SlowWalk then
		speed = base * cfg.SlowWalk.SpeedMult
	end
	hum:SetAttribute("BaseWalkSpeed", base)
	hum.WalkSpeed = speed
end

---------------------------------------------------------------- sword: sheathed <-> in hand
local function getMotor(character: Model): Motor6D?
	local sword = character:FindFirstChild(WEAPON)
	local grip = sword and sword:IsA("Model") and sword:FindFirstChild("Grip")
	return grip and grip:FindFirstChild("SwordGrip")
end

local function setEquipped(player: Player, character: Model, on: boolean)
	local motor = getMotor(character)
	if not motor then
		return
	end
	if on then
		motor.Part0 = character:FindFirstChild("RightHand")
		motor.C0 = Config.gripC0(cfg.GripTilt)
	else
		motor.Part0 = character:FindFirstChild("UpperTorso")
		motor.C0 = cfg.SheathC0
		local st = state[player]
		if st then
			st.queued = false
		end
	end
	character:SetAttribute("SwordEquipped", on)
	applySpeed(player, character)
end

local function attachWeapon(player: Player, character: Model)
	local hand = character:WaitForChild("RightHand", 10)
	local torso = character:WaitForChild("UpperTorso", 10)
	if not (hand and torso) then
		warn("[WeaponService] R15 character needed (RightHand / UpperTorso)")
		return
	end
	local old = character:FindFirstChild(WEAPON)
	if old and old:IsA("Model") then
		old:Destroy()
	end
	local sword = WeaponsFolder[WEAPON]:Clone()
	sword:PivotTo(torso.CFrame)
	sword.Parent = character
	local motor = Instance.new("Motor6D")
	motor.Name = "SwordGrip"
	motor.Part0 = torso
	motor.Part1 = sword.PrimaryPart
	motor.C0 = cfg.SheathC0
	motor.C1 = cfg.GripC1
	motor.Parent = sword.PrimaryPart
	character:SetAttribute("SwordEquipped", false)

	character.ChildAdded:Connect(function(c)
		if c:IsA("Tool") and c.Name == WEAPON then
			setEquipped(player, character, true)
		end
	end)
	character.ChildRemoved:Connect(function(c)
		if c:IsA("Tool") and c.Name == WEAPON and character.Parent then
			setEquipped(player, character, false)
		end
	end)
	local tool = character:FindFirstChild(WEAPON)
	if tool and tool:IsA("Tool") then
		setEquipped(player, character, true)
	end
end

---------------------------------------------------------------- hits
local function hitDemon(player: Player, m: Model, dmg: number, knock)
	local hum = m:FindFirstChildOfClass("Humanoid")
	local root = m:FindFirstChild("HumanoidRootPart")
	if not hum or hum.Health <= 0 then
		return nil
	end
	m:SetAttribute("LastHitBy", player.UserId)
	hum:TakeDamage(dmg)
	if knock and root and hum.Health > 0 then
		if m:GetAttribute("DescentTestMonster") then
			m:SetAttribute("MonsterHitImpulse", knock.dir * knock.speed + Vector3.new(0, knock.lift, 0))
			m:SetAttribute("MonsterHeavyStagger", not knock.soft)
		elseif knock.soft then
			-- stagger: the demon stops walking for a moment and gets shoved back
			if not m:GetAttribute("BaseWalk") then
				m:SetAttribute("BaseWalk", hum.WalkSpeed)
			end
			hum.WalkSpeed = 0
			root.AssemblyLinearVelocity = knock.dir * knock.speed + Vector3.new(0, knock.lift, 0)
			local tok = (m:GetAttribute("StaggerTok") or 0) + 1
			m:SetAttribute("StaggerTok", tok)
			task.delay(0.35, function()
				if hum.Parent and m:GetAttribute("StaggerTok") == tok then
					hum.WalkSpeed = m:GetAttribute("BaseWalk") or 7
				end
			end)
		else
			hum.PlatformStand = true
			root.AssemblyLinearVelocity = knock.dir * knock.speed + Vector3.new(0, knock.lift, 0)
			task.delay(0.5, function()
				if hum.Parent then
					hum.PlatformStand = false
				end
			end)
		end
	end
	return { pos = (root and root.Position) or m:GetPivot().Position, dmg = dmg, model = m }
end

local function rollCritWindow(hitModels)
	if #hitModels == 0 or math.random() >= cfg.CritChance then
		return
	end
	for _, m in ipairs(DEMONS:GetChildren()) do
		if (m:GetAttribute("CritReadyUntil") or 0) > now() then
			return
		end
	end
	local pick = hitModels[math.random(1, #hitModels)]
	local hum = pick:FindFirstChildOfClass("Humanoid")
	if pick.Parent == DEMONS and hum and hum.Health > 0 then
		pick:SetAttribute("CritReadyUntil", now() + cfg.CritWindow)
	end
end

local function cleanAim(aim): Vector3?
	if typeof(aim) ~= "Vector3" then
		return nil
	end
	local flat = aim * FLAT
	local mag = flat.Magnitude
	if mag < 0.1 or mag ~= mag or mag == math.huge then
		return nil
	end
	return flat / mag
end

local function facing(root: BasePart, aimDir: Vector3?): CFrame
	local dir = aimDir
	if not dir then
		local look = root.CFrame.LookVector * FLAT
		dir = if look.Magnitude > 0.01 then look.Unit else Vector3.new(0, 0, -1)
	end
	return CFrame.lookAt(root.Position, root.Position + dir)
end

-- height of the root above the ground, minus normal standing height (0 = standing)
local function heightAboveGround(character: Model): number
	local root = character:FindFirstChild("HumanoidRootPart")
	local hum = character:FindFirstChildOfClass("Humanoid")
	if not (root and hum) then
		return 0
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character, DEMONS }
	params.RespectCanCollide = true
	local hit = workspace:Raycast(root.Position, Vector3.new(0, -60, 0), params)
	local dist = if hit then root.Position.Y - hit.Position.Y else 60
	return dist - (hum.HipHeight + root.Size.Y / 2)
end

local function sectorDemons(origin: CFrame, radius: number, arcDeg: number)
	local out, seen = {}, {}
	local look = origin.LookVector * FLAT
	look = if look.Magnitude > 0.01 then look.Unit else Vector3.new(0, 0, -1)
	local cosHalf = math.cos(math.rad(math.min(arcDeg, 360) / 2))
	for _, part in ipairs(workspace:GetPartBoundsInRadius(origin.Position, radius, overlap)) do
		local m = demonFromPart(part)
		if m and not seen[m] then
			seen[m] = true
			local mr = m:FindFirstChild("HumanoidRootPart")
			local to = mr and ((mr.Position - origin.Position) * FLAT)
			if arcDeg >= 360 or (to and (to.Magnitude < 1.5 or to.Unit:Dot(look) >= cosHalf)) then
				table.insert(out, m)
			end
		end
	end
	return out
end

local function boxDemons(cf: CFrame, size: Vector3)
	local out, seen = {}, {}
	for _, part in ipairs(workspace:GetPartBoundsInBox(cf, size, overlap)) do
		local m = demonFromPart(part)
		if m and not seen[m] then
			seen[m] = true
			table.insert(out, m)
		end
	end
	return out
end

---------------------------------------------------------------- attacks
local function doAttack(player: Player, character: Model, mode: string)
	local st = state[player]
	local hum = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not (hum and root) or hum.Health <= 0 or not isEquipped(character) then
		return
	end
	local aimDir = st.aim
	st.aim = nil

	-- the client knows when it's airborne (the server's copy of the character lags ~0.15s behind).
	local airborne = st.air == true
	st.air = false
	local flashing = flashingDemonNear(root.Position)
	local crit = flashing ~= nil
	if flashing then
		flashing:SetAttribute("CritReadyUntil", nil)
	end

	local start = os.clock()
	local kind, step, timing
	if airborne then
		kind, step, timing = "Slam", 0, cfg.Slam
	elseif mode == "Heavy" then
		kind, step, timing = "Heavy", 0, cfg.Heavy
	else
		if start - st.lastSwingEnd > cfg.ComboResetTime then
			st.combo = 1
		end
		kind, step, timing = "Light", st.combo, cfg.Light[st.combo]
	end
	local dmg = cfg.Damage * timing.Mult * (if crit then cfg.CritMultiplier else 1)

	st.swingToken += 1
	local token = st.swingToken
	local function cancelled()
		return st.swingToken ~= token
	end
	st.attackMult = if kind == "Heavy" then cfg.HeavyMoveSpeedMult elseif kind == "Slam" then 1 else cfg.SwingMoveSpeedMult
	applySpeed(player, character)
	local function finish()
		st.lastSwingEnd = os.clock()
		st.attackMult = nil
		applySpeed(player, character)
	end

	CombatFX:FireAllClients("Swing", character, kind, step, timing.Windup, timing.Strike, timing.Recover)

	if kind == "Slam" then
		-- wait for the landing (the client drives the fall). Damage only if the server saw the warrior up in the air.
		st.busyUntil = math.huge
		task.wait(timing.Windup)
		local t0 = os.clock()
		local wasUp = false
		while os.clock() - t0 < timing.MaxFall and character.Parent and hum.Health > 0 and not cancelled() do
			local h = heightAboveGround(character)
			if h > 1 then
				wasUp = true
			elseif wasUp and h < 0.9 then
				break
			end
			RunService.Heartbeat:Wait()
		end
		if wasUp and not cancelled() and character.Parent and hum.Health > 0 and isEquipped(character) then
			local fwd = facing(root, aimDir).LookVector
			local impact = root.Position - Vector3.new(0, hum.HipHeight + root.Size.Y / 2, 0) + fwd * timing.Forward
			local report = {}
			for _, m in ipairs(sectorDemons(CFrame.new(impact), timing.Radius, 360)) do
				local mr = m:FindFirstChild("HumanoidRootPart")
				local away = if mr then (mr.Position - impact) * FLAT else Vector3.zero
				away = if away.Magnitude > 0.1 then away.Unit else fwd
				local r = hitDemon(player, m, dmg, { dir = away, speed = timing.Knockback, lift = timing.Lift })
				if r then
					table.insert(report, r)
				end
			end
			CombatFX:FireAllClients("Hit", character, kind, step, impact, report, crit)
		end
		st.busyUntil = os.clock() + timing.Recover * cfg.ChainAt
	else
		st.busyUntil = start + timing.Windup + timing.Strike + timing.Recover * cfg.ChainAt
		task.wait(timing.Windup)
		if cancelled() then
			st.busyUntil = os.clock()
			finish()
			return
		end
		local hitThis, hitModels = {}, {}
		local activeUntil = os.clock() + timing.Strike + cfg.ActiveGrace
		while os.clock() < activeUntil and character.Parent and hum.Health > 0 and isEquipped(character) and not cancelled() do
			local origin = facing(root, aimDir)
			local candidates
			if kind == "Heavy" or kind == "Aerial" then
				candidates = sectorDemons(origin, timing.Radius, timing.Arc)
			elseif timing.Shape == "Circle" then
				candidates = sectorDemons(origin, timing.Radius, 360)
			elseif timing.Shape == "Sector" then
				candidates = sectorDemons(origin, timing.Radius, timing.Arc)
			elseif timing.Shape == "Slam" then
				candidates = sectorDemons(origin * CFrame.new(0, 0, -timing.Forward), timing.Radius, 360)
			else
				candidates = boxDemons(origin * CFrame.new(0, cfg.HitboxOffsetY, -cfg.HitboxSize.Z / 2), cfg.HitboxSize)
			end
			local report = {}
			for _, m in ipairs(candidates) do
				if not hitThis[m] then
					hitThis[m] = true
					local knock = nil
					local mr = m:FindFirstChild("HumanoidRootPart")
					local away = mr and ((mr.Position - root.Position) * FLAT)
					if away and away.Magnitude > 0.1 then
						if kind == "Heavy" or timing.Knockback then
							knock = { dir = away.Unit, speed = timing.Knockback, lift = timing.Lift }
						else
							knock = { dir = away.Unit, speed = 14, lift = 4, soft = true } -- light hits stagger
						end
					end
					local guarded = m:GetAttribute("MonsterFrontalGuard") and away
						and away.Magnitude > 0.1 and (-away).Unit:Dot(m:GetPivot().LookVector) > 0.45
					if guarded then
						local shield = m:FindFirstChild("Shield")
						local blockSound = shield and shield:FindFirstChild("BlockSound")
						if blockSound then
							blockSound:Play()
						end
						continue
					end
					local r = hitDemon(player, m, dmg, knock)
					if r then
						table.insert(report, r)
						table.insert(hitModels, m)
					end
				end
			end
			if #report > 0 then
				CombatFX:FireAllClients("Hit", character, kind, step, root.Position, report, crit)
			end
			RunService.Heartbeat:Wait()
		end
		if kind == "Light" then
			st.combo = st.combo % #cfg.Light + 1
			rollCritWindow(hitModels)
		end
	end

	while os.clock() < st.busyUntil and not cancelled() do
		task.wait(0.03)
	end
	finish()
end

local function attackLoop(player: Player, character: Model)
	local st = state[player]
	while st and st.queued and character.Parent and isEquipped(character) do
		local mode = st.queued
		st.queued = false
		doAttack(player, character, mode)
	end
	if st then
		st.swinging = false
		st.queued = false
	end
end

SwingRequest.OnServerEvent:Connect(function(player: Player, mode, aim, air)
	if typeof(mode) == "Vector3" then
		aim, mode = mode, "Light"
	end
	mode = if mode == "Heavy" then "Heavy" else "Light"
	local st = state[player]
	local character = player.Character
	if not st or not character or not isEquipped(character) then
		return
	end
	if os.clock() < st.ultUntil then
		return
	end
	local t = os.clock()
	if t - st.lastRequest < cfg.MinClickInterval then
		return
	end
	st.lastRequest = t
	st.aim = cleanAim(aim)
	st.air = air == true
	if st.swinging then
		local root = character:FindFirstChild("HumanoidRootPart")
		local flashing = root and flashingDemonNear(root.Position)
		if st.busyUntil - t <= cfg.BufferWindow or flashing then
			st.queued = mode
		end
		return
	end
	st.queued = mode
	st.swinging = true
	task.spawn(attackLoop, player, character)
end)

---------------------------------------------------------------- dodge + backflip
DodgeRequest.OnServerEvent:Connect(function(player: Player, dir, isFlip)
	local st = state[player]
	local character = player.Character
	local hum = character and character:FindFirstChildOfClass("Humanoid")
	if not st or not hum or hum.Health <= 0 or os.clock() < st.ultUntil then
		return
	end
	local t = os.clock()
	if isFlip == true then
		-- only as the second press right after a dodge
		if t - st.lastDodge > cfg.Backflip.Window + 0.3 or t - st.lastFlip < cfg.Backflip.Cooldown * 0.85 then
			return
		end
		st.lastFlip = t
		st.lastDodge = t
		st.queued = false
		st.swingToken += 1
		character:SetAttribute("IFrameUntil", now() + cfg.Backflip.IFrames)
		CombatFX:FireAllClients("Backflip", character, cleanAim(dir))
		return
	end
	if t - st.lastDodge < cfg.Dodge.Cooldown * 0.85 then
		return
	end
	st.lastDodge = t
	st.queued = false
	st.swingToken += 1
	character:SetAttribute("IFrameUntil", now() + cfg.Dodge.IFrames)
	CombatFX:FireAllClients("Dodge", character, cleanAim(dir))
end)

---------------------------------------------------------------- ultimate
-- Kills fill the player's "Ultimate" attribute (TestDemonSpawner). At 100 the client can request it: the
-- server locks the warrior in place, makes them invulnerable, tells every client to play the cutscene, and
-- deals the slam damage at the impact moment.
UltimateRequest.OnServerEvent:Connect(function(player: Player)
	local st = state[player]
	local ch = player.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	local root = ch and ch:FindFirstChild("HumanoidRootPart")
	if not (st and hum and root) or hum.Health <= 0 or not isEquipped(ch) then
		return
	end
	if (player:GetAttribute("Ultimate") or 0) < 100 or os.clock() < st.ultUntil then
		return
	end
	local U = cfg.Ultimate
	player:SetAttribute("Ultimate", 0)
	st.ultUntil = os.clock() + U.Duration
	player:SetAttribute("UltLockUntil", now() + U.Duration) -- kills from the ultimate don't recharge it
	st.queued = false
	st.swingToken += 1
	st.attackMult = 0
	applySpeed(player, ch)
	ch:SetAttribute("IFrameUntil", now() + U.Duration)
	CombatFX:FireAllClients("Ultimate", ch)
	task.delay(U.Impact, function()
		if not ch.Parent or hum.Health <= 0 then
			return
		end
		local fwd = root.CFrame.LookVector * FLAT
		fwd = if fwd.Magnitude > 0.01 then fwd.Unit else Vector3.new(0, 0, -1)
		local impact = root.Position - Vector3.new(0, hum.HipHeight + root.Size.Y / 2, 0) + fwd * 3
		local report = {}
		for _, m in ipairs(sectorDemons(CFrame.new(impact), U.Radius, 360)) do
			local mr = m:FindFirstChild("HumanoidRootPart")
			local away = if mr then (mr.Position - impact) * FLAT else Vector3.zero
			away = if away.Magnitude > 0.1 then away.Unit else fwd
			local r = hitDemon(player, m, cfg.Damage * U.Mult, { dir = away, speed = U.Knockback, lift = U.Lift })
			if r then
				table.insert(report, r)
			end
		end
		CombatFX:FireAllClients("Hit", ch, "Ultimate", 0, impact, report, false)
	end)
	task.delay(U.Duration, function()
		if state[player] then
			st.attackMult = nil
			if ch.Parent then
				applySpeed(player, ch)
			end
		end
	end)
end)

---------------------------------------------------------------- telekinesis "Grave Grasp" (G)
-- The client sends where it's aiming (mouse point on the floor, or nothing = straight ahead). The server picks the
-- landing point (clamped to MinDistance..Range), tells every client to play it, and at the Hit moment damages
-- everything within Radius of that point with knockback away from it.
local TelekinesisRequest: RemoteEvent = Remotes:WaitForChild("TelekinesisRequest")
-- G down = "grab": the rocks rise and are HELD. G up = "throw" with the aim point at that moment: the landing point is
-- clamped to MinDistance..Range, snapped to the ground THERE, and every demon within Radius of it (flat distance, so
-- slopes don't make it miss) is hit when the rocks land. Cooldown starts at the throw.
local function tkGround(p: Vector3, ch: Model): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ex = { ch }
	local dm = workspace:FindFirstChild("Demons")
	if dm then
		table.insert(ex, dm)
	end
	params.FilterDescendantsInstances = ex
	local hit = workspace:Raycast(p + Vector3.new(0, 25, 0), Vector3.new(0, -60, 0), params)
	return if hit then hit.Position else p
end
local function tkDemons(target: Vector3, radius: number)
	local out, seen = {}, {}
	local box = CFrame.new(target + Vector3.new(0, 4, 0))
	for _, part in ipairs(workspace:GetPartBoundsInBox(box, Vector3.new(radius * 2 + 4, 16, radius * 2 + 4), overlap)) do
		local m = demonFromPart(part)
		if m and not seen[m] then
			seen[m] = true
			local mr = m:FindFirstChild("HumanoidRootPart")
			local pos = if mr then mr.Position else part.Position
			if ((pos - target) * FLAT).Magnitude <= radius + 1.5 then
				table.insert(out, m)
			end
		end
	end
	return out
end
local function tkThrow(player: Player, st, ch: Model, hum: Humanoid, root: BasePart, aimPoint)
	local T = cfg.Telekinesis
	st.tkHold = nil
	st.tkReady = os.clock() + T.Cooldown * 0.95
	local fwd = root.CFrame.LookVector * FLAT
	fwd = if fwd.Magnitude > 0.01 then fwd.Unit else Vector3.new(0, 0, -1)
	local floor = root.Position - Vector3.new(0, hum.HipHeight + root.Size.Y / 2, 0)
	local target = floor + fwd * T.DefaultDistance
	if typeof(aimPoint) == "Vector3" and aimPoint == aimPoint and aimPoint.Magnitude < 1e6 then
		local d = (aimPoint - floor) * FLAT
		if d.Magnitude > 0.5 then
			target = floor + d.Unit * math.clamp(d.Magnitude, T.MinDistance, T.Range)
		end
	end
	target = tkGround(target, ch)
	CombatFX:FireAllClients("TelekinesisThrow", ch, target)
	task.delay(T.Hit - T.HoldAt, function()
		if not ch.Parent or hum.Health <= 0 then
			return
		end
		local report = {}
		for _, m in ipairs(tkDemons(target, T.Radius)) do
			local mr = m:FindFirstChild("HumanoidRootPart")
			local away = if mr then (mr.Position - target) * FLAT else Vector3.zero
			away = if away.Magnitude > 0.1 then away.Unit else fwd
			local r = hitDemon(player, m, cfg.Damage * T.Mult, { dir = away, speed = T.Knockback, lift = T.Lift })
			if r then
				table.insert(report, r)
			end
		end
		CombatFX:FireAllClients("Hit", ch, "Telekinesis", 0, target, report, false)
	end)
	task.delay(T.Duration - T.HoldAt, function()
		if state[player] == st and st.attackMult == T.MoveSpeedMult and not st.tkHold then
			st.attackMult = nil
			if ch.Parent then
				applySpeed(player, ch)
			end
		end
	end)
end
TelekinesisRequest.OnServerEvent:Connect(function(player: Player, phase, aimPoint)
	local st = state[player]
	local ch = player.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	local root = ch and ch:FindFirstChild("HumanoidRootPart")
	if not (st and hum and root) or hum.Health <= 0 then
		return
	end
	local T = cfg.Telekinesis
	if phase == "grab" then
		if os.clock() < st.ultUntil or os.clock() < (st.tkReady or 0) or st.tkHold then
			return
		end
		local token = {}
		st.tkHold = token
		st.tkGrabbedAt = os.clock()
		st.queued = false
		st.swingToken += 1
		st.attackMult = T.MoveSpeedMult
		applySpeed(player, ch)
		CombatFX:FireAllClients("Telekinesis", ch)
		-- never stuck holding: throw straight ahead if the release never comes
		task.delay(T.HoldAt + T.MaxHold + 2, function()
			if st.tkHold == token then
				if ch.Parent and hum.Health > 0 then
					tkThrow(player, st, ch, hum, root, nil)
				else
					st.tkHold = nil
				end
			end
		end)
	elseif phase == "throw" then
		local token = st.tkHold
		if not token then
			return
		end
		-- the rocks can't be thrown before they're gathered
		local early = (st.tkGrabbedAt or 0) + T.HoldAt - 0.3 - os.clock()
		if early > 0 then
			task.delay(early, function()
				if st.tkHold == token and ch.Parent and hum.Health > 0 then
					tkThrow(player, st, ch, hum, root, aimPoint)
				end
			end)
		else
			tkThrow(player, st, ch, hum, root, aimPoint)
		end
	end
end)

---------------------------------------------------------------- Divine Verdict (Z)
-- Same aiming as Grave Grasp. At the Impact moment the blade of light lands: everything within Radius of the
-- landing point takes Mult x damage and is blown away from it.
local VerdictRequest: RemoteEvent = Remotes:WaitForChild("VerdictRequest")
VerdictRequest.OnServerEvent:Connect(function(player: Player, aimPoint)
	local st = state[player]
	local ch = player.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	local root = ch and ch:FindFirstChild("HumanoidRootPart")
	if not (st and hum and root) or hum.Health <= 0 or os.clock() < st.ultUntil then
		return
	end
	local T = cfg.Verdict
	if os.clock() < (st.verdictReady or 0) then
		return
	end
	st.verdictReady = os.clock() + T.Cooldown * 0.95
	st.queued = false
	st.swingToken += 1
	st.attackMult = T.MoveSpeedMult
	applySpeed(player, ch)
	local fwd = root.CFrame.LookVector * FLAT
	fwd = if fwd.Magnitude > 0.01 then fwd.Unit else Vector3.new(0, 0, -1)
	local floor = root.Position - Vector3.new(0, hum.HipHeight + root.Size.Y / 2, 0)
	local target = floor + fwd * T.DefaultDistance
	if typeof(aimPoint) == "Vector3" and aimPoint == aimPoint and aimPoint.Magnitude < 1e6 then
		local d = (aimPoint - floor) * FLAT
		if d.Magnitude > 0.5 then
			target = floor + d.Unit * math.clamp(d.Magnitude, T.MinDistance, T.Range)
		end
	end
	CombatFX:FireAllClients("Verdict", ch, target)
	task.delay(T.Impact, function()
		if not ch.Parent or hum.Health <= 0 then
			return
		end
		local report = {}
		for _, m in ipairs(sectorDemons(CFrame.new(target), T.Radius, 360)) do
			local mr = m:FindFirstChild("HumanoidRootPart")
			local away = if mr then (mr.Position - target) * FLAT else Vector3.zero
			away = if away.Magnitude > 0.1 then away.Unit else fwd
			local r = hitDemon(player, m, cfg.Damage * T.Mult, { dir = away, speed = T.Knockback, lift = T.Lift })
			if r then
				table.insert(report, r)
			end
		end
		CombatFX:FireAllClients("Hit", ch, "Verdict", 0, target, report, false)
	end)
	task.delay(T.Duration, function()
		if state[player] and st.attackMult == T.MoveSpeedMult then
			st.attackMult = nil
			if ch.Parent then
				applySpeed(player, ch)
			end
		end
	end)
end)

---------------------------------------------------------------- sprint + stamina (player attributes Stamina / MaxStamina / Sprinting / StaminaExhausted feed the HUD)
SprintRequest.OnServerEvent:Connect(function(player: Player, on)
	local st = state[player]
	if st then
		st.wantSprint = on == true
	end
end)

-- slow walk (Alt toggle): just a speed state; sprint and attack slow-downs take priority in applySpeed
SlowWalkRequest.OnServerEvent:Connect(function(player: Player, on)
	local st = state[player]
	if st and typeof(on) == "boolean" and st.slowWalk ~= on then
		st.slowWalk = on
		player:SetAttribute("SlowWalk", on)
		applySpeed(player, player.Character)
	end
end)

RunService.Heartbeat:Connect(function(dt)
	local S = cfg.Sprint
	for player, st in pairs(state) do
		local ch = player.Character
		local hum = ch and ch:FindFirstChildOfClass("Humanoid")
		local root = ch and ch:FindFirstChild("HumanoidRootPart")
		if hum and root and hum.Health > 0 then
			local moving = hum.MoveDirection.Magnitude > 0.1 or (root.AssemblyLinearVelocity * FLAT).Magnitude > 2
			local was = st.sprinting
			if st.wantSprint and moving and not st.exhausted and st.stamina > 0 then
				st.sprinting = true
				st.stamina = math.max(0, st.stamina - S.Drain * dt)
				st.lastDrain = os.clock()
				if st.stamina <= 0 then
					st.exhausted = true
					st.sprinting = false
				end
			else
				st.sprinting = false
				if os.clock() - st.lastDrain > S.RegenDelay then
					st.stamina = math.min(S.Max, st.stamina + S.Regen * dt)
				end
				if st.exhausted and st.stamina >= S.RestartAt then
					st.exhausted = false
				end
			end
			if st.sprinting ~= was then
				applySpeed(player, ch)
			end
			local shown = player:GetAttribute("Stamina") or -1
			if math.abs(shown - st.stamina) >= 0.5 or (st.stamina == S.Max and shown ~= S.Max) or (st.stamina == 0 and shown ~= 0) then
				player:SetAttribute("Stamina", math.floor(st.stamina * 10 + 0.5) / 10)
			end
			if player:GetAttribute("Sprinting") ~= st.sprinting then
				player:SetAttribute("Sprinting", st.sprinting)
			end
			if player:GetAttribute("StaminaExhausted") ~= st.exhausted then
				player:SetAttribute("StaminaExhausted", st.exhausted)
			end
		end
	end
end)

---------------------------------------------------------------- players
local function onPlayer(player: Player)
	local ls = Instance.new("Folder")
	ls.Name = "leaderstats"
	local souls = Instance.new("IntValue")
	souls.Name = "Souls"
	souls.Parent = ls
	ls.Parent = player
	player:SetAttribute("Curse", 0)
	player:SetAttribute("MaxStamina", cfg.Sprint.Max)
	player:SetAttribute("Ultimate", 0)
	player:SetAttribute("Stamina", cfg.Sprint.Max)
	state[player] = {
		swinging = false,
		queued = false,
		aim = nil,
		busyUntil = 0,
		lastSwingEnd = 0,
		lastRequest = 0,
		combo = 1,
		lastDodge = 0,
		lastFlip = 0,
		swingToken = 0,
		air = false,
		attackMult = nil,
		wantSprint = false,
		slowWalk = false,
		sprinting = false,
		exhausted = false,
		stamina = cfg.Sprint.Max,
		lastDrain = 0,
		ultUntil = 0,
	}
	local function onCharacter(character: Model)
		local st = state[player]
		if st then
			st.swinging, st.queued, st.combo = false, false, 1
		end
		attachWeapon(player, character)
	end
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
end

Players.PlayerAdded:Connect(onPlayer)
for _, p in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayer, p)
end
Players.PlayerRemoving:Connect(function(p)
	state[p] = nil
end)
