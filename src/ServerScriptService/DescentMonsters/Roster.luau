local Roster = {}

-- Every Attack clip uses the same contact beat. Reach and windups are tunable
-- independently from the mesh, which lets us rebalance the encounters.
Roster.Contact = 0.55

Roster.Monsters = {
	Knuckler = {
		name = "Knuckler", health = 155, speed = 17.5, stance = 7, aggro = 28, cooldown = 0.32,
		attack = { duration = 0.94, kind = "Sweep", reach = 7, minDot = 0.26, damage = 16,
			trackUntil = 0.35, travel = 4.8, travelStart = 0.35, travelEnd = 0.61 },
		tell = { "rbxassetid://9118613208", 0.24, 0.82 },
	},
	Hookjaw = {
		name = "Hookjaw", health = 110, speed = 22, stance = 8.5, aggro = 31, cooldown = 0.45,
		attack = { duration = 0.91, kind = "Pounce", reach = 3.45, damage = 17,
			trackUntil = 0.39, lead = 0.20, travel = 12.5, travelStart = 0.42, travelEnd = 0.68, activeEnd = 0.68 },
		tell = { "rbxasset://sounds/swordlunge.wav", 0.35, 1.6 },
	},
	CinderPorter = {
		name = "Cinder Porter", health = 100, speed = 13, stance = 18, aggro = 30, cooldown = 0.92,
		attack = { duration = 1.12, kind = "Throw", reach = 4.1, damage = 10, markAt = 0.24, flightTime = 0.24 },
		tell = { "rbxassetid://9118613208", 0.22, 1.38 },
	},
	Graveplate = {
		name = "Graveplate", health = 170, speed = 15.7, stance = 6.3, aggro = 28, cooldown = 0.42, guard = true,
		attack = { duration = 1.06, kind = "Bash", reach = 5.2, minDot = 0.50, damage = 19,
			trackUntil = 0.37, travel = 5.6, travelStart = 0.41, travelEnd = 0.58 },
		tell = { "rbxassetid://9113449585", 0.45, 0.82 },
	},
	Bellwretch = {
		name = "Bellwretch", health = 105, speed = 12.5, stance = 18, aggro = 30, cooldown = 0.85, interruptible = true,
		attack = { duration = 1.28, kind = "Summon" },
		tell = { "rbxassetid://9113804171", 0.24, 1.33 },
	},
	Needlewing = {
		name = "Needlewing", health = 85, speed = 20, stance = 7.1, aggro = 31, cooldown = 0.32,
		attack = { duration = 0.83, kind = "Dive", reach = 4.8, minDot = 0.49, damage = 13,
			trackUntil = 0.37, travel = 6.2, travelStart = 0.40, travelEnd = 0.59 },
		tell = { "rbxasset://sounds/swordlunge.wav", 0.25, 1.8 },
	},
	Shardling = {
		name = "Shardling", health = 35, speed = 21.5, stance = 4.9, aggro = 30, cooldown = 0.39,
		attack = { duration = 0.66, kind = "Swipe", reach = 4.9, minDot = 0.34, damage = 7,
			trackUntil = 0.30, travel = 3.3, travelStart = 0.35, travelEnd = 0.59 },
		tell = { "rbxassetid://9118613208", 0.19, 1.6 },
	},
	CairnGiant = {
		name = "Cairn Giant", health = 375, speed = 12.5, stance = 9, aggro = 29, cooldown = 0.60,
		attack = { duration = 1.55, kind = "Slam", reach = 6.3, impactOffset = 5, damage = 31,
			trackUntil = 0.39, travel = 4.6, travelStart = 0.40, travelEnd = 0.55 },
		tell = { "rbxassetid://9118613208", 0.42, 0.56 },
	},
}

Roster.Encounters = {
	{ name = "Knuckler", ids = { "Knuckler" } },
	{ name = "Hookjaw", ids = { "Hookjaw" } },
	{ name = "Cinder Porter", ids = { "CinderPorter" } },
	{ name = "Graveplate", ids = { "Graveplate" } },
	{ name = "Bellwretch", ids = { "Bellwretch" } },
	{ name = "Needlewing", ids = { "Needlewing" } },
	{ name = "Shardling", ids = { "Shardling" } },
	{ name = "Cairn Giant", ids = { "CairnGiant" } },
	{ name = "Shardling pack", ids = { "Shardling", "Shardling", "Shardling" } },
	{ name = "Knuckler and Porter", ids = { "Knuckler", "CinderPorter" } },
	{ name = "Graveplate and Hookjaw", ids = { "Graveplate", "Hookjaw" } },
	{ name = "Bellwretch and Shardlings", ids = { "Bellwretch", "Shardling", "Shardling" } },
}

return Roster
