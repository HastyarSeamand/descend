-- The Descent: weapon stats + grip setup. Shared by server (combat) and client (animation/VFX).
local rad = math.rad

local Config = {}

-- Grip orientation for the R15 RightHand -> Grip Motor6D.
-- Hand frame: +Y toward the wrist, -Y toward the fingers, -Z = the way the character faces.
-- Sword frame: +Y toward the tip, +X = cutting edge.
function Config.gripC0(tiltDeg: number): CFrame
	local t = rad(tiltDeg)
	return CFrame.fromMatrix(
		Vector3.new(0, -0.15, 0),
		Vector3.new(0, -math.cos(t), -math.sin(t)), -- sword +X (edge)
		Vector3.new(0, math.sin(t), -math.cos(t)), -- sword +Y (blade)
		Vector3.new(1, 0, 0) -- sword +Z (flat of the blade faces sideways)
	)
end

Config.Weapons = {
	Gravecleaver = {
		DisplayName = "Gravecleaver",
		Type = "Greatsword",
		Rarity = "Common",

		Damage = 40, -- base; each attack multiplies it
		CritMultiplier = 2, -- attacking while a demon flashes gold

		-- LIGHT combo: left click / tap STRIKE / gamepad R2. Four two-handed hits that flow into each other, ~2.5 s.
		-- Shape: Box = in front, Sector = an arc in front (Arc degrees), Circle = all round,
		-- Slam = a circle on the floor Forward studs ahead (with knockback)
		Light = {
			[1] = { Windup = 0.2, Strike = 0.12, Recover = 0.42, Mult = 1, Shape = "Sector", Radius = 10, Arc = 220 }, -- cleaving step: flat cleave right -> left
			[2] = { Windup = 0.14, Strike = 0.14, Recover = 0.42, Mult = 1.1, Shape = "Sector", Radius = 10, Arc = 200 }, -- overhead wheel: diagonal high left -> low right
			[3] = { Windup = 0.14, Strike = 0.26, Recover = 0.4, Mult = 1.3, Shape = "Circle", Radius = 10 }, -- iron wheel: full two-handed turn
			[4] = { Windup = 0.3, Strike = 0.08, Recover = 0.62, Mult = 2, Shape = "Slam", Radius = 9, Forward = 4, Knockback = 34, Lift = 24 }, -- grave slam: hop + crater
		},
		-- HEAVY: E / gamepad Y / mobile Heavy button. Two-handed low drag into a huge sweep, knockback.
		Heavy = { Windup = 0.55, Strike = 0.12, Recover = 0.7, Mult = 2.5, Radius = 11, Arc = 200, Knockback = 45, Lift = 22 },
		-- AIR: any attack while airborne = overhead GROUND SLAM. You hang for the windup, drop, and the blade
		-- slams the floor in front as you land: area damage + knockback around the impact point.
		Slam = { Windup = 0.2, Strike = 0.08, Recover = 0.6, MaxFall = 1.6, Mult = 2.25, Radius = 9, Forward = 3, Knockback = 38, Lift = 26, FallSpeed = 70 },

		-- light-attack box hitbox (server), live only during the strike frames
		HitboxSize = Vector3.new(9, 7, 9), -- width, height, reach forward
		HitboxOffsetY = 0,
		ActiveGrace = 0.1,

		ChainAt = 0.35, -- next attack can start after this fraction of the recovery
		BufferWindow = 0.35, -- a click this close to the end of an attack is queued
		ComboResetTime = 0.8,
		MinClickInterval = 0.08,
		SwingMoveSpeedMult = 0.5,
		HeavyMoveSpeedMult = 0.25,
		WalkSpeedDrawn = 14, -- heavier walk while the sword is out (16 sheathed)
		-- walk / run / jump / fall animations while drawn: a Roblox-made pack (see MOVE_PACKS in CombatClient:
		-- Knight, Werewolf, Vampire, Elder, Mage, Rthro, Superhero, Stylish). nil = our old coded walk.
		MovementPack = "Knight",

		-- sprint: hold Shift (gamepad L3 / mobile Sprint button toggle). Drains stamina, regenerates after a pause.
		Sprint = { SpeedMult = 1.7, Max = 100, Drain = 20, Regen = 16, RegenDelay = 0.8, RestartAt = 20 },
		-- slow walk: Alt toggles a slow, heavy walk (sprint cancels it; attack slow-downs still win). Phone/gamepad: push the stick partway.
		SlowWalk = { SpeedMult = 0.45 },

		-- ULTIMATE: R / gamepad X / mobile ULT button when the bar is full. Kills charge it.
		-- Cutscene: roar -> crouch -> leap -> hang at the top -> slam. Invulnerable for the whole thing.
		Ultimate = { ChargePerKill = 20, Duration = 2.3, Impact = 1.38, Radius = 16, Mult = 8, Knockback = 70, Lift = 45 },

		-- TELEKINESIS "Grave Grasp": G / gamepad DPadUp / mobile GRASP button. The free left hand tears rocks out of
		-- the floor with the curse, holds them in orbit, then hurls them where you aim (mouse) or straight ahead.
		-- Works with the sword drawn or away. Times are seconds from the key press.
		-- HOLD G to keep the rocks up (HoldAt = when they're gathered, up to MaxHold s); let go = throw. Cooldown starts at the throw. MinDistance 2.5 (was 7: ghouls chase you to 1-4 studs, so the rocks landed behind them).
		Telekinesis = { Cooldown = 8, Duration = 1.85, HoldAt = 1.15, MaxHold = 6, Launch = 1.3, Hit = 1.52, Range = 26, MinDistance = 2.5, DefaultDistance = 16, Radius = 8.5, Mult = 3, Knockback = 42, Lift = 22, MoveSpeedMult = 0.35 },

		-- DIVINE VERDICT: Z / gamepad DPadLeft / mobile VERDICT button. A god's judgment: a sigil draws itself in the
		-- sky over the aim point, a colossal spectral Gravecleaver of light drops out of it and impales the ground.
		-- Like the ultimate in size, but on a cooldown instead of kill charge. Times are seconds from the key press.
		Verdict = { Cooldown = 15, Duration = 2.3, Impact = 1.17, Range = 30, MinDistance = 6, DefaultDistance = 14, Radius = 14, Mult = 6, Knockback = 55, Lift = 35, MoveSpeedMult = 0.2 },

		-- dodge: Q / gamepad B / mobile Dodge button
		Dodge = { Speed = 52, Duration = 0.24, IFrames = 0.3, Cooldown = 0.7 },
		-- backflip: a backward dodge (S + Q, or Q standing still), then Q again within Window
		Backflip = { Window = 0.4, Up = 44, Back = 20, IFrames = 0.5, Cooldown = 1.0 },

		-- crit: a demon you just hit may flash gold; attack while it flashes = x CritMultiplier
		CritChance = 0.35,
		CritWindow = 1.2,
		CritRange = 13,

		GripC1 = CFrame.new(0, 0.35, 0), -- hand holds the upper grip, near the guard
		GripTilt = -10,
		SheathC0 = CFrame.fromMatrix(
			Vector3.new(0.85, 1.35, 0.8),
			Vector3.new(-0.766, 0.643, 0),
			Vector3.new(-0.643, -0.766, 0),
			Vector3.new(0, 0, 1)
		),
	},
}

for name, w in pairs(Config.Weapons) do
	Config[name] = w
end

return Config
