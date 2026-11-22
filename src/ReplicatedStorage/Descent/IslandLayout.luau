-- ISLAND ONE: the Cursed Woods island (2026-11-22). Island world: 15 islands around the Pit, travel by boat + fast travel.
-- Compact for phones (~760 x 920 studs of land, ~50 s walk dock -> boss). One main road, places a few seconds apart,
-- monsters right beside the road, few but BIG props. Terrain, props, camps and spawn all read this module.
-- +Z = north (toward the Pit side of the island, where the cliffs and the boss are).
local L = {}
L.Version = 3
L.Name = "Cursed Woods"
L.Water = 0 -- sea level
L.Center = { x = 0, z = 400 }
L.Radius = { x = 380, z = 460 } -- coast ellipse before the noise
L.Bounds = { X0 = -640, X1 = 640, Z0 = -260, Z1 = 1060 } -- terrain written inside this box (land + a ring of sea)
L.Spawn = { x = 0, z = -10 }

L.Areas = {
	{ name = "Dock", x = 0, z = -20, r = 38, beach = true },
	{ name = "Wayfarer Camp", x = -40, z = 170, r = 58 },
	{ name = "Grave Crossroads", x = 60, z = 340, r = 50 },
	{ name = "Hanged Oak Hill", x = -160, z = 470, r = 62 },
	{ name = "Old Watchtower", x = 255, z = 520, r = 44 },
	{ name = "Crypt Mouth", x = -225, z = 690, r = 40 },
	{ name = "Gravekeeper's Hollow", x = 40, z = 765, r = 78 },
}
L.Hills = { -- { x, z, height, radius }
	{ -160, 470, 26, 120 }, -- Hanged Oak Hill
	{ 255, 520, 24, 95 }, -- the watchtower knoll
	{ 180, 180, 12, 140 },
	{ -260, 120, 10, 120 },
}
L.Pond = { x = -255, z = 285, rx = 55, rz = 42, depth = 6 }

L.Paths = {
	main = { { 0, -40 }, { 5, 60 }, { -40, 170 }, { 25, 260 }, { 60, 340 }, { 25, 450 }, { 45, 600 }, { 40, 765 } },
	oak = { { 60, 340 }, { -50, 400 }, { -160, 470 }, { -205, 590 }, { -225, 690 } },
	tower = { { 60, 340 }, { 160, 420 }, { 255, 520 } },
	pond = { { -40, 170 }, { -150, 230 }, { -235, 270 } },
}

-- monster camps, right beside the road (respawn in seconds)
L.Camps = {
	{ name = "Shore Shardlings", x = 70, z = 110, radius = 34, ids = { "Shardling", "Shardling", "Shardling" }, respawn = 40 },
	{ name = "Roadside Brutes", x = 105, z = 245, radius = 38, ids = { "Knuckler", "CinderPorter" }, respawn = 55 },
	{ name = "Mire Stalker", x = -250, z = 300, radius = 36, ids = { "Hookjaw" }, respawn = 50 },
	{ name = "Crossroads Wardens", x = 140, z = 375, radius = 38, ids = { "Graveplate", "Hookjaw" }, respawn = 65 },
	{ name = "Oak Needlewings", x = -150, z = 500, radius = 42, ids = { "Needlewing", "Needlewing" }, respawn = 55 },
	{ name = "Watchtower Watch", x = 240, z = 545, radius = 38, ids = { "Knuckler", "Needlewing" }, respawn = 65 },
	{ name = "Crypt Bellwretch", x = -215, z = 655, radius = 42, ids = { "Bellwretch", "Shardling", "Shardling" }, respawn = 80 },
	{ name = "Gravekeeper's Hollow", x = 40, z = 780, radius = 60, ids = { "CairnGiant" }, respawn = 150 },
}

local function ss(a, b, x)
	local t = math.clamp((x - a) / (b - a), 0, 1)
	return t * t * (3 - 2 * t)
end
L.ss = ss

-- smoothed, gently wandering paths
local function smoothPath(pts)
	local out, n = {}, #pts
	for i = 1, n - 1 do
		local p0, p1, p2, p3 = pts[math.max(1, i - 1)], pts[i], pts[i + 1], pts[math.min(n, i + 2)]
		local steps = math.max(4, math.floor(math.sqrt((p2[1] - p1[1]) ^ 2 + (p2[2] - p1[2]) ^ 2) / 10))
		for s = 0, steps - 1 do
			local t = s / steps
			local t2, t3 = t * t, t * t * t
			local x = 0.5 * ((2 * p1[1]) + (-p0[1] + p2[1]) * t + (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2 + (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3)
			local z = 0.5 * ((2 * p1[2]) + (-p0[2] + p2[2]) * t + (2 * p0[2] - 5 * p1[2] + 4 * p2[2] - p3[2]) * t2 + (-p0[2] + 3 * p1[2] - 3 * p2[2] + p3[2]) * t3)
			local fade = math.clamp(math.min(i - 1 + t, n - 1 - (i - 1 + t)), 0, 1)
			x += fade * 6 * math.noise(x / 50, z / 50, 12.5)
			table.insert(out, { x, z })
		end
	end
	table.insert(out, pts[n])
	return out
end
for name, pts in L.Paths do
	L.Paths[name] = smoothPath(pts)
end
local segs = {}
for name, pts in L.Paths do
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		table.insert(segs, { a[1], a[2], b[1], b[2], math.min(a[1], b[1]) - 30, math.max(a[1], b[1]) + 30, math.min(a[2], b[2]) - 30, math.max(a[2], b[2]) + 30, name })
	end
end
function L.pathDist(x, z)
	local best, which = 1e9, nil
	for _, s in segs do
		if x >= s[5] and x <= s[6] and z >= s[7] and z <= s[8] then
			local ax, az, bx, bz = s[1], s[2], s[3], s[4]
			local dx, dz = bx - ax, bz - az
			local t = math.clamp(((x - ax) * dx + (z - az) * dz) / (dx * dx + dz * dz), 0, 1)
			local px, pz = ax + dx * t - x, az + dz * t - z
			local d = math.sqrt(px * px + pz * pz)
			if d < best then
				best, which = d, s[9]
			end
		end
	end
	return best, which
end

-- how far inland a point is: < 0 = sea, 0 = coastline, 1 = island centre
function L.inland(x, z)
	local dx, dz = (x - L.Center.x) / L.Radius.x, (z - L.Center.z) / L.Radius.z
	local ang = math.atan2(dz, dx)
	local wob = 1 + 0.13 * math.noise(math.cos(ang) * 1.6, math.sin(ang) * 1.6, 4.4) + 0.05 * math.noise(math.cos(ang) * 5, math.sin(ang) * 5, 9.1)
	return 1 - math.sqrt(dx * dx + dz * dz) / wob
end

-- returns ground height, cliff factor (0..1), path distance, path name, wet (pond/sea)
function L.height(x, z)
	local k = L.inland(x, z)
	-- inland ground: gentle rolling + hills
	local land = 7 + 4 * math.noise(x / 140, z / 140, 1.7) + 1.2 * math.noise(x / 35, z / 35, 8.9)
	for _, hl in L.Hills do
		local dx, dz = x - hl[1], z - hl[2]
		land += hl[3] * math.exp(-(dx * dx + dz * dz) / (hl[4] * hl[4]))
	end
	-- north cliffs: a high rock wall along the north coast (the soft border + the Pit side)
	local north = ss(560, 720, z) * ss(0.02, 0.18, k)
	local ridge = 1 - math.abs(math.noise(x / 70, z / 70, 3.3))
	local cliff = north * (38 + 40 * ridge * ridge + 10 * math.noise(x / 25, z / 25, 5.1))
	-- keep the boss hollow open in front of the cliffs
	local bdx, bdz = x - 40, z - 765
	cliff *= ss(60, 110, math.sqrt(bdx * bdx + bdz * bdz)) * 0.85 + 0.15 * ss(780, 840, z)
	land += cliff
	local h
	if k > 0 then
		-- beach: the last stretch before the coast slopes down to just under the sea
		local beach = ss(0.0, 0.16, k)
		h = -1.5 + (land + 1.5) * beach
	else
		-- sea bed falls away from the coast
		h = -1.5 + k * 70
		h = math.max(h, -26 + 2 * math.noise(x / 40, z / 40, 7.2))
	end
	-- flatten clearings toward their own level
	for _, a in L.Areas do
		local dx, dz = x - a.x, z - a.z
		local d = math.sqrt(dx * dx + dz * dz)
		if d < a.r + 30 and a.level then
			h += (a.level - h) * ss(a.r + 30, a.r, d) * 0.9
		end
	end
	local pd, pname = L.pathDist(x, z)
	-- pond
	local p = L.Pond
	local q = math.sqrt(((x - p.x) / p.rx) ^ 2 + ((z - p.z) / p.rz) ^ 2)
	local wet = h < L.Water
	if q < 1.4 then
		local bed = L.Water + 3.5 - p.depth * math.clamp(1 - q, 0, 1) -- the pond surface sits above the sea (fed by springs)
		h += (math.min(h, bed) - h) * ss(1.4, 0.95, q)
		wet = wet or q < 1
	end
	return h, math.clamp(cliff / 50, 0, 1), pd, pname, wet, k
end
L.PondLevel = L.Water + 2.8

-- clearing levels (computed once, from the raw ground at each centre)
for _, a in L.Areas do
	if a.beach then
		a.level = 1.2
	else
		a.level = (L.height(a.x, a.z))
	end
end

-- how thick the forest is here (0..1): few but big props, clear paths and clearings
function L.forest(x, z)
	local h, cliffF, pd, _, wet, k = L.height(x, z)
	if wet or k < 0.12 or h < 1 then
		return 0
	end
	local f = 0.5 + 0.5 * math.noise(x / 110, z / 110, 6.1)
	f *= ss(8, 20, pd)
	for _, a in L.Areas do
		local dx, dz = x - a.x, z - a.z
		f *= ss(a.r * 0.8, a.r + 18, math.sqrt(dx * dx + dz * dz))
	end
	if cliffF > 0.5 then
		f *= 0.3
	end
	return math.clamp(f, 0, 1)
end

return L
