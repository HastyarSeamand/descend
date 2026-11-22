-- The Descent: CombatClient v5
-- Everything the player SEES of the Gravecleaver: how it's held, swung, walked and dodged with, plus combat VFX.
--
-- ANIMATION: "BLADE-PATH + IK"
--  Attacks are authored as the path the SWORD travels (where the grip is, which way the blade points, which
--  way the edge faces), not as arm angles. Every frame an inverse-kinematics solver works out the shoulder,
--  elbow and wrist that put the hand on that grip. This gives real sweeping arcs (no "both hands up, chop
--  down"), and the blade always leads with its edge.
--  Positions are in the warrior's chest space (relative to the right shoulder), so waist twists and spins
--  carry the whole body while the arm keeps the blade on its path.
-- LAYERS (applied after Roblox's Animator, every PreSimulation):
--  * arm   : right arm IK. Always while the sword is drawn.
--  * walk  : custom greatsword walk while drawn and moving (legs, hips, sway, left-arm swing, sword bounce).
--  * upper : waist / neck / left arm (two-handed grip via left-arm IK). Attacks, dodges, flips.
--  * lower : root dip/lean/spin/flip + hips/knees. Dodges, flips, aerial; attacks when standing still.
-- One keyframed move per character on one clock; hit-stop freezes the clock.
-- INPUT: Light = left click / tap / R2 (the Tool). Heavy = E / gamepad Y / mobile Heavy button.
--        Attacking in the air = overhead ground slam. Sprint = hold Shift. Shift lock = Ctrl. Dodge = Q / gamepad B / mobile Dodge.
--        Backward dodge (S + Q, or Q standing still) then Q again quickly = backflip.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UIS = game:GetService("UserInputService")
local CAS = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Debris = game:GetService("Debris")

local Descent = RS:WaitForChild("Descent")
local Config = require(Descent:WaitForChild("WeaponConfig"))
local cfg = Config.Gravecleaver
local Remotes = Descent:WaitForChild("Remotes")
local CombatFX: RemoteEvent = Remotes:WaitForChild("CombatFX")
local SwingRequest: RemoteEvent = Remotes:WaitForChild("SwingRequest")
local DodgeRequest: RemoteEvent = Remotes:WaitForChild("DodgeRequest")
local DEMONS = workspace:WaitForChild("Demons")
local player = Players.LocalPlayer
local rad = math.rad
local V = Vector3.new
local FLAT = V(1, 0, 1)
local HIT_RED = Color3.fromRGB(220, 20, 20) -- hit markers, hit sparks, small ground rings
local TOOL_NAME = "Gravecleaver"
local GRIP_C0 = Config.gripC0(cfg.GripTilt)
local GRIP_ROT = GRIP_C0 - GRIP_C0.Position

local usingMovePack, applyMovePack -- movement animation packs (defined above the per-frame driver)
local playTelekinesis, tryTelekinesis, tkThrowLocal
local tkHolds = {} -- character -> the Grave Grasp being held (other players' throw targets arrive from the server)
local tkHolding, tkReleaseWanted = false, false
local playVerdict, tryVerdict -- Divine Verdict (defined further down) -- Grave Grasp (defined further down)
local fxFolder = Instance.new("Folder")
fxFolder.Name = "ClientFX"
fxFolder.Parent = workspace

---------------------------------------------------------------- math
local function unit(v: Vector3, fallback: Vector3?): Vector3
	local m = v.Magnitude
	if m > 1e-5 then
		return v / m
	end
	return fallback or V(0, 0, -1)
end

local function perpTo(e: Vector3, b: Vector3): Vector3
	local p = e - b * e:Dot(b)
	if p.Magnitude < 1e-3 then
		p = Vector3.yAxis - b * b.Y
		if p.Magnitude < 1e-3 then
			p = Vector3.xAxis - b * b.X
		end
	end
	return p.Unit
end

local function slerpVec(a: Vector3, b: Vector3, t: number): Vector3
	local ang = math.acos(math.clamp(a:Dot(b), -1, 1))
	local s = math.sin(ang)
	if ang < 1e-3 or s < 1e-3 then
		return unit(a:Lerp(b, t), a)
	end
	return unit(a * (math.sin((1 - t) * ang) / s) + b * (math.sin(t * ang) / s), a)
end

local EASE = {
	linear = function(x)
		return x
	end,
	inQuad = function(x)
		return x * x
	end,
	outQuad = function(x)
		return 1 - (1 - x) ^ 2
	end,
	outCubic = function(x)
		return 1 - (1 - x) ^ 3
	end,
	inOutSine = function(x)
		return -(math.cos(math.pi * x) - 1) / 2
	end,
	outBack = function(x)
		return 1 + 2.4 * (x - 1) ^ 3 + 1.4 * (x - 1) ^ 2
	end,
}

---------------------------------------------------------------- poses
-- grip  : where the sword is held, offset from the RIGHT SHOULDER joint, chest space (x right, y up, -z forward)
-- blade : direction the blade points;  edge : direction the cutting edge faces (auto from the motion if omitted)
-- pole  : which way the right elbow points;  two : 0..1 left hand on the hilt
-- yaw/lean/neck : waist twist (+ left), forward lean, head turn.   spin/flip : whole-body turn / backflip (deg)
-- dip/rfwd/rside : body drop (studs) and whole-body lean.  lhip/lknee/rhip/rknee : legs (+hip fwd, -knee bent)
-- lpitch/lroll/lelbow : free left arm when it's not on the hilt
local NUM = { "two", "yaw", "lean", "wroll", "neck", "npitch", "lspread", "rspread", "spin", "flip", "dip", "rfwd", "rside", "lhip", "lknee", "rhip", "rknee", "lpitch", "lroll", "lelbow" }
local DEFAULT_POLE = V(0.6, -0.5, 0.5)

local function K(t)
	local p = {
		grip = t.grip,
		blade = unit(t.blade),
		edge = if t.edge then unit(t.edge) else nil,
		pole = unit(t.pole or DEFAULT_POLE),
	}
	for _, k in ipairs(NUM) do
		p[k] = t[k] or 0
	end
	return p
end

local function with(p, changes)
	local o = table.clone(p)
	for k, v in pairs(changes) do
		if k == "blade" or k == "edge" or k == "pole" then
			o[k] = unit(v)
		else
			o[k] = v
		end
	end
	if changes.blade and not changes.edge then
		o.edge = nil -- recompute from the motion
	end
	return o
end

local function lerpPose(a, b, x)
	local p = {
		grip = a.grip:Lerp(b.grip, x),
		blade = slerpVec(a.blade, b.blade, x),
		edge = slerpVec(a.edge, b.edge, x),
		pole = unit(a.pole:Lerp(b.pole, x), b.pole),
	}
	for _, k in ipairs(NUM) do
		p[k] = a[k] + (b[k] - a[k]) * x
	end
	return p
end

-- SHOULDER CARRY: hand by the shoulder, the blade laid flat across the upper back, pointing out behind on the
-- left, edge up (the resting look from the reference clip)
local CARRY = K({ grip = V(0.6, 1.1, -0.2), blade = V(-0.74, -0.18, 0.65), edge = V(-0.2, 0.96, 0.05), pole = V(0.8, 0, -0.6) })
-- where the hand grabs the handle on the back (matches the sheath)
local SHEATH = K({ grip = V(-0.25, 0.8, 0.8), blade = V(-0.643, -0.766, 0), edge = V(-0.766, 0.643, 0), pole = V(0.3, 0.9, -0.3) })
-- DRAG GUARD (between attacks): hunched low and wide, the sword hanging from the right hand with the blade trailing
-- out behind, tip just off the floor; the free fist up in front. The fighting stance the combo flows back into.
local GUARD = K({ grip = V(0.35, -1.05, -0.15), blade = V(0.3, -0.48, 0.82), pole = V(0.6, -0.1, 0.8), spin = -12, yaw = 4, lean = 18, dip = 0.42, neck = 8, npitch = 8, lhip = 22, lknee = -42, rhip = -14, rknee = -34, lspread = 10, rspread = 12, lpitch = 55, lroll = -15, lelbow = 85 })

local MOVES = {}

-- edge facing the way a spinning body carries the blade: dir +1 = spinning left (spin increasing), -1 = right
local function sweepEdge(b: Vector3, dir: number): Vector3
	local u = unit(b)
	return unit(V(u.Z, 0, -u.X) * dir, V(-1, 0, 0))
end
-- a pose turned `deg` round on the spot (whole-body spin), with optional overrides
local function spun(base, deg: number, extra)
	local p = K(base)
	p.spin = deg
	for k, v in pairs(extra or {}) do
		p[k] = if k == "blade" or k == "edge" or k == "pole" then unit(v) else v
	end
	return p
end
local function spunGuard(deg: number)
	local p = table.clone(GUARD)
	p.spin += deg
	return p
end
-- a two-handed pose (left hand on the hilt unless the pose says otherwise)
local function H(t)
	t.two = t.two or 1
	return K(t)
end

-- THE FIGHTING STYLE: a huge blade swung with the whole body. Every hit is anticipation (the body coils and
-- holds), the hips fire first, the shoulders whip after them, the blade comes last and drags the body round after
-- it; the feet step in and plant. Hits flow into each other: each one ends where the next one starts, and the
-- combo ends in the drag guard (sword trailing behind, tip off the floor). All moves are SPLINE moves.

-- LIGHT 1, "Cleaving Step": both hands haul the blade off the drag up onto the right shoulder while the body
-- coils back onto the rear leg; then the lead foot steps in, the hips fire, and a flat two-handed cleave whips
-- right -> left across the front. The blade's weight drags the body round after it.
MOVES.L1 = function(w, s, r)
	local load = H({ grip = V(0.85, 0.55, 0.3), blade = V(0.6, 0.25, 0.76), pole = V(0.7, -0.4, 0.6), spin = -40, yaw = -32, lean = 2, dip = 0.3, neck = 35, npitch = 4, rhip = -12, rknee = -32, lhip = 22, lknee = -20, lspread = 10, rspread = 12 })
	local s1 = H({ grip = V(0.95, 0.1, -0.85), blade = V(0.85, 0.05, -0.52), pole = V(0.6, -0.7, 0.3), spin = -14, yaw = -12, lean = 10, dip = 0.36, neck = 20, rhip = -18, rknee = -34, lhip = 30, lknee = -35, lspread = 10, rspread = 12 })
	local s2 = H({ grip = V(0.1, -0.05, -1.5), blade = V(0.05, -0.02, -1), pole = V(0.4, -0.85, 0.2), spin = 16, yaw = 12, lean = 14, dip = 0.42, rhip = -26, rknee = -36, lhip = 38, lknee = -48, lspread = 10, rspread = 12 })
	local hit = H({ grip = V(-0.95, -0.05, -1.0), blade = V(-0.86, -0.05, -0.5), pole = V(0.2, -0.9, -0.3), spin = 42, yaw = 30, lean = 16, dip = 0.46, neck = -20, rhip = -28, rknee = -38, lhip = 40, lknee = -52, lspread = 10, rspread = 12 })
	local drag = H({ grip = V(-1.2, -0.45, -0.15), blade = V(-0.7, -0.38, 0.6), pole = V(0.1, -0.9, -0.4), spin = 62, yaw = 40, lean = 20, dip = 0.52, neck = -30, rhip = -30, rknee = -42, lhip = 42, lknee = -58, lspread = 10, rspread = 12 })
	local gather = H({ grip = V(0.45, 0.25, -0.9), blade = V(0.25, 0.9, -0.3), pole = V(0.7, -0.5, 0.2), two = 0.4, spin = 20, yaw = 8, lean = 10, dip = 0.35, lhip = 25, lknee = -40, rhip = -14, rknee = -32, lspread = 10, rspread = 12 })
	return {
		{ at = w * 0.55, pose = load },
		{ at = w, pose = with(load, { spin = -46, yaw = -36, dip = 0.33 }), stop = true },
		{ at = w + s * 0.35, pose = s1 },
		{ at = w + s * 0.7, pose = s2 },
		{ at = w + s, pose = hit },
		{ at = w + s + r * 0.28, pose = drag },
		{ at = w + s + r * 0.62, pose = gather },
		{ at = w + s + r, pose = GUARD },
	}
end

-- LIGHT 2, "Overhead Wheel": the momentum of the first cleave is carried up the left side and round behind the
-- head (the blade wheels over the top), then it comes down in a diagonal from high left to low right as the
-- rear foot steps through, finishing in the drag guard on the right.
MOVES.L2 = function(w, s, r)
	local rise = H({ grip = V(-0.75, 0.85, -0.35), blade = V(-0.6, 0.72, 0.35), pole = V(0.2, -0.5, -0.8), spin = 38, yaw = 24, lean = 0, dip = 0.26, neck = -10, lhip = 20, lknee = -30, rhip = -10, rknee = -28, lspread = 10, rspread = 12 })
	local top = H({ grip = V(-0.3, 1.5, 0.15), blade = V(-0.45, 0.3, 0.84), pole = V(0.5, 0.3, -0.8), spin = 30, yaw = 20, lean = -8, dip = 0.18, npitch = 10, lhip = 12, lknee = -20, rhip = -6, rknee = -22, lspread = 10, rspread = 12 })
	local s1 = H({ grip = V(-0.5, 1.35, -0.8), blade = V(-0.45, 0.75, -0.48), pole = V(0.6, 0.2, -0.6), spin = 16, yaw = 10, lean = 6, dip = 0.25, lhip = 10, lknee = -25, rhip = 5, rknee = -25, lspread = 10, rspread = 12 })
	local s2 = H({ grip = V(0.2, 0.35, -1.4), blade = V(0.35, -0.2, -0.92), pole = V(0.7, -0.5, 0.3), spin = -10, yaw = -14, lean = 18, dip = 0.42, rhip = 25, rknee = -45, lhip = -10, lknee = -35, lspread = 10, rspread = 12 })
	local hit = H({ grip = V(0.8, -0.5, -0.95), blade = V(0.6, -0.55, -0.58), pole = V(0.8, -0.4, 0.3), spin = -30, yaw = -30, lean = 24, dip = 0.5, neck = 20, rhip = 36, rknee = -56, lhip = -20, lknee = -40, lspread = 10, rspread = 12 })
	local follow = K({ grip = V(0.75, -0.95, -0.25), blade = V(0.45, -0.42, 0.79), pole = V(0.7, -0.2, 0.6), two = 0.5, spin = -38, yaw = -30, lean = 22, dip = 0.5, neck = 15, rhip = 30, rknee = -50, lhip = -16, lknee = -40, lspread = 10, rspread = 12, lpitch = 40, lroll = -15, lelbow = 70 })
	return {
		{ at = w * 0.45, pose = rise },
		{ at = w, pose = top, stop = true },
		{ at = w + s * 0.4, pose = s1 },
		{ at = w + s * 0.75, pose = s2 },
		{ at = w + s, pose = hit },
		{ at = w + s + r * 0.3, pose = follow },
		{ at = w + s + r, pose = GUARD },
	}
end

-- LIGHT 3, "Iron Wheel": from the drag, both hands lock the blade out flat and the warrior pivots through a full
-- turn, stepping round on the balls of the feet; the blade's weight carries the body past the full circle.
MOVES.L3 = function(w, s, r)
	local hb = V(0.6, -0.1, -0.8)
	local held = { grip = V(0.45, -0.35, -1.3), blade = hb, edge = sweepEdge(hb, 1), pole = V(0.6, -0.7, 0.3), two = 1, lean = 14, dip = 0.4, yaw = 10, neck = -10, lhip = 24, lknee = -40, rhip = -14, rknee = -32, lspread = 12, rspread = 12 }
	local wb = V(0.7, -0.3, 0.65)
	local wind = H({ grip = V(0.9, -0.5, 0.0), blade = wb, edge = sweepEdge(wb, 1), pole = V(0.6, -0.6, 0.5), spin = -42, yaw = -35, lean = 12, dip = 0.38, neck = 40, lhip = 16, lknee = -34, rhip = -10, rknee = -30, lspread = 10, rspread = 12 })
	local db = V(0.58, -0.22, -0.78)
	return {
		{ at = w * 0.6, pose = wind },
		{ at = w, pose = with(wind, { spin = -50, yaw = -40, dip = 0.42 }), stop = true },
		{ at = w + s * 0.2, pose = spun(held, 20, { rhip = 20, rknee = -42, lhip = -6, lknee = -30 }) },
		{ at = w + s * 0.45, pose = spun(held, 115) },
		{ at = w + s * 0.7, pose = spun(held, 210, { rhip = 22, rknee = -44, lhip = -8, lknee = -30 }) },
		{ at = w + s, pose = spun(held, 300) },
		{ at = w + s + r * 0.3, pose = spun(held, 345, { grip = V(0.6, -0.5, -1.05), blade = db, edge = sweepEdge(db, 1), dip = 0.46, lean = 18 }) },
		{ at = w + s + r, pose = spunGuard(360) },
	}
end

-- LIGHT 4, "Grave Slam": drop into a crouch hauling the blade up behind, spring up off the floor (a real little
-- hop) rearing back tall, then bring it over the top two-handed and bury it in the floor as you land. Hold it in
-- the crater for a beat, then drag it out round the right side into the guard.
MOVES.L4 = function(w, s, r)
	local crouch = H({ grip = V(0.25, 1.25, 0.2), blade = V(0.1, 0.55, 0.83), pole = V(0.8, 0.4, -0.3), lean = -4, dip = 0.55, npitch = 12, lhip = 50, lknee = -80, rhip = 35, rknee = -68, lspread = 8, rspread = 8 })
	local rear = H({ grip = V(0.05, 1.75, 0.3), blade = V(0.05, 0.12, 0.99), pole = V(0.8, 0.5, -0.2), lean = -16, dip = -0.15, npitch = 16, lhip = 14, lknee = -18, rhip = -4, rknee = -20, lspread = 6, rspread = 6 })
	local top = H({ grip = V(0, 1.65, -0.55), blade = V(0, 0.85, -0.5), pole = V(0.8, 0.3, -0.2), lean = 0, dip = -0.05, lhip = 30, lknee = -40, rknee = -30, lspread = 6, rspread = 6 })
	local mid = H({ grip = V(0, 0.65, -1.45), blade = V(0, 0.05, -1), pole = V(0.8, -0.2, 0.2), lean = 20, dip = 0.3, lhip = 45, lknee = -70, rhip = -15, rknee = -45, lspread = 8, rspread = 8 })
	local impact = H({ grip = V(0, -0.7, -1.5), blade = V(0, -0.68, -0.73), pole = V(0.8, -0.3, 0.4), lean = 38, dip = 0.82, npitch = 6, lhip = 55, lknee = -90, rhip = -30, rknee = -65, lspread = 8, rspread = 8 })
	local pull = K({ grip = V(0.75, -0.8, -0.55), blade = V(0.85, -0.4, -0.25), pole = V(0.8, -0.3, 0.4), two = 0.3, spin = -20, yaw = -15, lean = 24, dip = 0.55, lhip = 30, lknee = -55, rhip = -20, rknee = -45, lspread = 10, rspread = 12, lpitch = 30, lroll = -20, lelbow = 60 })
	return {
		{ at = w * 0.45, pose = crouch },
		{ at = w * 0.85, pose = rear },
		{ at = w, pose = top },
		{ at = w + s * 0.5, pose = mid },
		{ at = w + s, pose = impact, stop = true },
		{ at = w + s + r * 0.35, pose = with(impact, { dip = 0.88, lean = 40 }), stop = true },
		{ at = w + s + r * 0.7, pose = pull },
		{ at = w + s + r, pose = GUARD },
	}
end

-- DIVINE VERDICT: the free LEFT hand is raised to the sky, calling the blade down, held, then slammed down and forward
-- as it lands; the sword stays on the shoulder
MOVES.Verdict = function()
	local call = with(CARRY, { lpitch = 168, lroll = -8, lelbow = 4, lean = -10, npitch = 22, neck = 8, dip = 0.12, yaw = 10, lhip = 10, lknee = -14, rhip = -6, rknee = -14, lspread = 8, rspread = 10 })
	local hold = with(call, { lpitch = 172, lean = -12, npitch = 26 })
	local strike = with(CARRY, { lpitch = 75, lroll = -6, lelbow = 6, lean = 16, dip = 0.36, npitch = 0, yaw = -12, lhip = 30, lknee = -46, rhip = -16, rknee = -32, lspread = 10, rspread = 12 })
	return {
		{ at = 0.3, pose = call },
		{ at = 0.98, pose = hold, stop = true },
		{ at = 1.17, pose = strike },
		{ at = 1.5, pose = with(strike, { dip = 0.4 }), stop = true },
		{ at = 2.1, pose = CARRY },
	}
end

-- TELEKINESIS: the free LEFT hand reaches out and up, lifts and holds, draws back, then thrusts forward; the sword
-- stays on the shoulder (the right arm never leaves the carry)
MOVES.Telekinesis = function()
	local reach = with(CARRY, { lpitch = 120, lroll = -12, lelbow = 14, yaw = 20, lean = -5, npitch = 12, neck = 12, dip = 0.18, lhip = 12, lknee = -20, rhip = -8, rknee = -16, lspread = 8, rspread = 10 })
	local hold = with(reach, { lpitch = 132, lelbow = 8, lean = -9, npitch = 15 })
	local pull = with(CARRY, { lpitch = 70, lroll = -35, lelbow = 105, yaw = 38, lean = 2, dip = 0.3, spin = -14, neck = 25, lhip = 18, lknee = -30, rhip = -16, rknee = -32, lspread = 10, rspread = 12 })
	local thrust = with(CARRY, { lpitch = 92, lroll = -4, lelbow = 2, yaw = -28, lean = 18, dip = 0.38, spin = 12, neck = -10, npitch = 4, lhip = 34, lknee = -50, rhip = -18, rknee = -34, lspread = 10, rspread = 12 })
	return {
		{ at = 0.28, pose = reach },
		{ at = 0.95, pose = hold },
		{ at = 1.15, pose = pull, stop = true },
		{ at = 1.3, pose = thrust },
		{ at = 1.55, pose = with(thrust, { dip = 0.42, lean = 20 }), stop = true },
		{ at = 1.85, pose = CARRY },
	}
end

-- REST: out of the guard, the blade swings up and lays back onto the shoulder
MOVES.Rest = function()
	local lift = K({ grip = V(0.6, 0.3, -0.7), blade = V(0.25, 0.9, 0.35), pole = V(0.8, -0.3, -0.2), lean = 8, dip = 0.25 })
	return {
		{ at = 0.2, pose = lift },
		{ at = 0.45, pose = CARRY },
	}
end

-- HEAVY, "Reaver Cleave": lift the sword off the shoulder and coil the whole body back onto the rear leg,
-- a beat of stillness at the top, then a huge two-handed diagonal cleave from high right to low left as the
-- body unwinds and lunges forward, heavy follow-through, and the sword is heaved back up onto the shoulder
MOVES.Heavy = function(w, s, r)
	local lift = K({ grip = V(0.7, 1.2, 0.5), blade = V(0.35, 0.35, 0.87), pole = V(0.7, -0.2, 0.6), two = 0.7, spin = -25, yaw = -30, lean = -4, dip = 0.2, neck = 35, npitch = 6, rhip = -18, rknee = -30, lhip = 20, lknee = -20, lspread = 6, rspread = 8 })
	local coil = with(lift, { grip = V(0.8, 1.4, 0.7), blade = V(0.45, 0.45, 0.77), spin = -35, yaw = -38, dip = 0.28, lean = -6, neck = 42 })
	local top = K({ grip = V(0.4, 1.0, -1.0), blade = V(0.45, 0.75, -0.5), pole = V(0.7, -0.4, 0.4), two = 1, spin = -10, yaw = -5, lean = 8, dip = 0.3, neck = 10, lhip = 30, lknee = -35, rhip = -15, rknee = -30, lspread = 6, rspread = 6 })
	local impact = K({ grip = V(-0.9, -0.5, -1.3), blade = V(-0.5, -0.6, -0.62), pole = V(0.6, -0.6, 0.4), two = 1, spin = 15, yaw = 25, lean = 26, dip = 0.55, rfwd = 6, neck = -20, npitch = 4, lhip = 45, lknee = -60, rhip = -30, rknee = -45, lspread = 8, rspread = 6 })
	local follow = with(impact, { grip = V(-1.4, -0.7, -0.7), blade = V(-0.85, -0.45, -0.25), spin = 25, yaw = 35, lean = 30, dip = 0.6 })
	local heave = K({ grip = V(-0.3, 0.6, -1.1), blade = V(0, 0.9, -0.4), pole = V(0.7, -0.3, 0.2), two = 0.4, spin = 10, yaw = 10, lean = 10, dip = 0.3 })
	return {
		{ at = w * 0.45, pose = lift, ease = "outCubic" },
		{ at = w * 0.85, pose = coil, ease = "inOutSine" },
		{ at = w, pose = with(coil, { spin = -38, dip = 0.3 }), ease = "inOutSine" },
		{ at = w + s * 0.4, pose = top, ease = "inQuad" },
		{ at = w + s, pose = impact, ease = "linear" },
		{ at = w + s + r * 0.2, pose = follow, ease = "outQuad" },
		{ at = w + s + r * 0.5, pose = heave, ease = "inOutSine" },
		{ at = w + s + r, pose = CARRY, ease = "inOutSine" },
	}
end

-- AIR, "Ground Slam": both hands haul the sword up overhead while you hang for a beat, then you drop and the
-- blade comes down over the top and slams the floor in front the moment you land. No freeze on landing.
local SLAM_RAISE = K({ grip = V(-0.6, 1.9, 0.1), blade = V(0.05, 0.2, 0.98), pole = V(0.7, 0.4, -0.3), two = 1, lean = -10, npitch = 10, lhip = 50, lknee = -80, rhip = 35, rknee = -70 })
local SLAM_TOP = K({ grip = V(-0.6, 1.8, -0.4), blade = V(0, 0.95, 0.3), pole = V(0.7, 0.3, -0.3), two = 1, lean = -4, npitch = 8, lhip = 25, lknee = -40, rhip = 15, rknee = -35 })
MOVES.Slam = function(w)
	return {
		{ at = w * 0.6, pose = SLAM_RAISE, ease = "outCubic" },
		{ at = w, pose = with(SLAM_RAISE, { lean = -12 }), ease = "inOutSine" },
		{ at = w + 0.18, pose = SLAM_TOP, ease = "inOutSine" },
	}
end
-- ULTIMATE: roar with the sword dragged out to the side, drop into a deep crouch, leap, hang at the top with the
-- body arched and the blade far back, then come down over the top into a crater-making slam
MOVES.Ultimate = function()
	local roar = K({ grip = V(0.9, 0.3, 0.3), blade = V(0.55, -0.55, 0.62), pole = V(0.8, -0.3, 0.4), lean = -14, npitch = 25, dip = 0.25, lpitch = 70, lroll = -60, lelbow = 20, lhip = 10, lknee = -25, rhip = -8, rknee = -22, lspread = 12, rspread = 12 })
	local crouch = K({ grip = V(0.6, -0.4, 0.7), blade = V(0.4, -0.6, 0.7), pole = V(0.6, -0.6, 0.5), two = 0.8, lean = 24, npitch = 10, dip = 0.75, lhip = 55, lknee = -95, rhip = 40, rknee = -85, lspread = 8, rspread = 8 })
	local rise = with(SLAM_RAISE, { lean = -14, npitch = 14 })
	local apex = with(SLAM_RAISE, { lean = -16, npitch = 16, grip = V(-0.6, 2.0, 0.2), blade = V(0.05, -0.1, 1) })
	local overhead = K({ grip = V(-0.6, 1.8, -0.6), blade = V(0, 0.9, -0.43), pole = V(0.7, 0.2, -0.2), two = 1, lean = 6, dip = 0.1, lhip = 30, lknee = -50, rhip = 10, rknee = -40 })
	local impact = K({ grip = V(-0.5, -0.5, -1.5), blade = V(0, -0.6, -0.8), pole = V(0.7, -0.4, 0.4), two = 1, lean = 34, npitch = 8, dip = 0.8, lhip = 45, lknee = -85, rhip = -25, rknee = -65, lspread = 8, rspread = 8 })
	local lift = K({ grip = V(0, 0.7, -1.0), blade = V(0, 0.9, -0.4), pole = V(0.7, -0.3, 0.2), two = 0.3, lean = 10, dip = 0.3 })
	return {
		{ at = 0.3, pose = roar, ease = "outCubic" },
		{ at = 0.55, pose = crouch, ease = "inQuad" },
		{ at = 0.85, pose = rise, ease = "outQuad" },
		{ at = 1.22, pose = apex, ease = "inOutSine" },
		{ at = 1.3, pose = overhead, ease = "inQuad" },
		{ at = 1.38, pose = impact, ease = "linear" },
		{ at = 1.75, pose = with(impact, { dip = 0.75 }), ease = "outQuad" },
		{ at = 2.0, pose = lift, ease = "inOutSine" },
		{ at = 2.3, pose = CARRY, ease = "inOutSine" },
	}
end

MOVES.SlamLand = function()
	local impact = K({ grip = V(-0.5, -0.4, -1.4), blade = V(0, -0.55, -0.83), pole = V(0.7, -0.4, 0.4), two = 1, lean = 30, npitch = 6, dip = 0.6, lhip = 40, lknee = -75, rhip = -20, rknee = -55, lspread = 6, rspread = 6 })
	local lift = K({ grip = V(0, 0.7, -1.0), blade = V(0, 0.9, -0.4), pole = V(0.7, -0.3, 0.2), two = 0.3, lean = 10, dip = 0.25 })
	-- always pass straight overhead first, so the blade comes DOWN in front even if you land before the
	-- windup finished (a direct blend from "blade behind the back" would swing it under, through the floor)
	local overhead = K({ grip = V(-0.6, 1.8, -0.6), blade = V(0, 0.9, -0.43), pole = V(0.7, 0.2, -0.2), two = 1, lean = 6, dip = 0.2, lhip = 30, lknee = -50, rhip = 10, rknee = -40 })
	return {
		{ at = 0.035, pose = overhead, ease = "inQuad" },
		{ at = 0.085, pose = impact, ease = "linear" },
		{ at = 0.24, pose = with(impact, { dip = 0.65, lean = 32 }), ease = "outQuad" },
		{ at = 0.5, pose = lift, ease = "inOutSine" },
		{ at = 0.85, pose = CARRY, ease = "inOutSine" },
	}
end

-- BACKFLIP: tuck, full backward rotation, sword stays on the shoulder; then land into a low two-handed guard
MOVES.Backflip = function()
	local function f(deg, extra)
		local p = with(CARRY, { lean = 10, lhip = 75, lknee = -115, rhip = 75, rknee = -115, lpitch = 60, lroll = 10, lelbow = 95 })
		p.flip = deg
		for k, v in pairs(extra or {}) do
			p[k] = v
		end
		return p
	end
	return {
		{ at = 0.07, pose = f(25), ease = "outQuad" },
		{ at = 0.17, pose = f(130), ease = "linear" },
		{ at = 0.28, pose = f(245), ease = "linear" },
		{ at = 0.4, pose = f(345), ease = "linear" },
		{ at = 0.47, pose = f(360, { lhip = 25, lknee = -35, rhip = 25, rknee = -35, lpitch = 20, lelbow = 40 }), ease = "outQuad" },
	}
end
MOVES.FlipLand = function()
	local absorb = with(CARRY, { dip = 0.6, lean = 12, lhip = 40, lknee = -70, rhip = 30, rknee = -60, lpitch = 25, lroll = -15, lelbow = 35 })
	return {
		{ at = 0.08, pose = absorb, ease = "outQuad" },
		{ at = 0.2, pose = with(absorb, { dip = 0.5 }), ease = "linear" },
		{ at = 0.5, pose = CARRY, ease = "inOutSine" },
	}
end

MOVES.Draw = function()
	local mid = K({ grip = V(0.3, 1.5, 0.2), blade = V(-0.5, -0.4, 0.75), pole = V(0.4, 0.8, -0.4) })
	return {
		{ at = 0.1, pose = SHEATH, ease = "linear" },
		{ at = 0.32, pose = mid, ease = "outQuad" },
		{ at = 0.55, pose = CARRY, ease = "outBack" },
	}
end

MOVES.Dodge = function(fwd, side, dur)
	local p = with(CARRY, { lpitch = -35, lroll = 10, lelbow = 50, lean = 12, dip = 0.75, rfwd = 24 * fwd, rside = 24 * side, lhip = 60, lknee = -90, rhip = 30, rknee = -70 })
	return {
		{ at = 0.05, pose = p, ease = "outQuad" },
		{ at = dur, pose = p, ease = "linear" },
		{ at = dur + 0.2, pose = CARRY, ease = "inOutSine" },
	}
end

-- how each kind of move takes over the body
local LAYERS = {
	Light = { blendIn = 0.05, lower = "standing" },
	LightFull = { blendIn = 0.04, lower = "full" }, -- the light combo: steps, spins and the slam own the whole body
	Guard = { blendIn = 0, lower = "standing" }, -- the fighting guard between attacks (and Rest, back to the carry)
	Telekinesis = { blendIn = 0.08, lower = "standing" }, -- legs keep walking while you move
	Heavy = { blendIn = 0.06, lower = "heavy" },
	Slam = { blendIn = 0.04, lower = "full" },
	SlamLand = { blendIn = 0.01, lower = "full" },
	Ultimate = { blendIn = 0.06, lower = "full" },
	Backflip = { blendIn = 0.03, lower = "full" },
	FlipLand = { blendIn = 0.02, lower = "full" },
	Dodge = { blendIn = 0.04, lower = "full" },
	Draw = { blendIn = 0, lower = "none", armOnly = true },
}

local function wrap180(a: number): number
	a = a % 360
	if a > 180 then
		a -= 360
	end
	return a
end

local VECS = { "grip", "blade", "edge", "pole" }
local function hermite(p0, p1, m0, m1, x: number)
	local x2, x3 = x * x, x * x * x
	return p0 * (2 * x3 - 3 * x2 + 1) + m0 * (x3 - 2 * x2 + x) + p1 * (3 * x2 - 2 * x3) + m1 * (x3 - x2)
end

local function buildMove(start, keys, meta)
	start = table.clone(start)
	start.spin = wrap180(start.spin)
	start.flip = wrap180(start.flip)
	local frames = { { t = 0, pose = start } }
	for _, k in ipairs(keys) do
		table.insert(frames, { t = k.at, pose = k.pose, ease = EASE[k.ease or "inOutSine"], stop = k.stop })
	end
	-- edges that weren't given face the direction the blade is travelling
	for i, f in ipairs(frames) do
		if not f.pose.edge then
			local prev = frames[math.max(1, i - 1)].pose
			local nxt = frames[math.min(#frames, i + 1)].pose
			local dv = nxt.blade - prev.blade
			local p = table.clone(f.pose)
			if dv.Magnitude > 0.05 then
				p.edge = perpTo(dv, p.blade)
			else
				p.edge = perpTo(if prev.edge then prev.edge else Vector3.yAxis, p.blade)
			end
			f.pose = p
		end
	end
	local m = meta or {}
	m.frames = frames
	-- SPLINE moves: every key gets a tangent (Catmull-Rom over time), so the body flows THROUGH the keys instead
	-- of easing to a dead stop at each one. stop = true keys (anticipation holds, impacts) keep zero speed, and a
	-- number that turns round at a key gets a flat tangent so it never overshoots.
	if m.spline then
		for i, f in ipairs(frames) do
			local tg = {}
			local prev, nxt = frames[i - 1], frames[i + 1]
			if prev and nxt and not f.stop and nxt.t - prev.t > 1e-4 then
				local dt = nxt.t - prev.t
				for _, k in ipairs(VECS) do
					tg[k] = (nxt.pose[k] - prev.pose[k]) / dt
				end
				for _, k in ipairs(NUM) do
					local p0, p1, p2 = prev.pose[k], f.pose[k], nxt.pose[k]
					tg[k] = if (p1 - p0) * (p2 - p1) <= 0 then 0 else (p2 - p0) / dt
				end
			end
			f.tan = tg
		end
	end
	m.t = 0
	m.length = frames[#frames].t
	m.layer = LAYERS[m.layerName or m.kind] or LAYERS.Light
	return m
end

local function sample(m)
	local f = m.frames
	local t = math.min(m.t, m.length)
	for i = 1, #f - 1 do
		local a, b = f[i], f[i + 1]
		if t <= b.t then
			local span = b.t - a.t
			if m.spline and span > 0 then
				local x = math.clamp((t - a.t) / span, 0, 1)
				local ta, tb = a.tan or {}, b.tan or {}
				local p = {}
				for _, k in ipairs(VECS) do
					p[k] = hermite(a.pose[k], b.pose[k], (ta[k] or Vector3.zero) * span, (tb[k] or Vector3.zero) * span, x)
				end
				p.blade = if p.blade.Magnitude > 0.35 then p.blade.Unit else slerpVec(a.pose.blade, b.pose.blade, x)
				p.edge = if p.edge.Magnitude > 0.35 then p.edge.Unit else slerpVec(a.pose.edge, b.pose.edge, x)
				p.pole = unit(p.pole, b.pose.pole)
				for _, k in ipairs(NUM) do
					p[k] = hermite(a.pose[k], b.pose[k], (ta[k] or 0) * span, (tb[k] or 0) * span, x)
				end
				p.two = math.clamp(p.two, 0, 1)
				return p
			end
			local x = if span > 0 then math.clamp((t - a.t) / span, 0, 1) else 1
			return lerpPose(a.pose, b.pose, (b.ease or EASE.inOutSine)(x))
		end
	end
	return f[#f].pose
end

local function moveWeight(m)
	local L = m.layer
	if L.armOnly then
		return 0
	end
	local w = if L.blendIn > 0 then math.clamp(m.t / L.blendIn, 0, 1) else 1
	if m.blendOutFrom and not m.hold and m.t > m.blendOutFrom then
		w = math.min(w, 1 - math.clamp((m.t - m.blendOutFrom) / math.max(m.length - m.blendOutFrom, 0.01), 0, 1))
	end
	return w
end

-- BERSERKER STANCE (drawn, standing still): low wide stance, body turned side-on, hunched forward with the
-- head up watching, free fist hanging tense, heavy breathing through the shoulders, slow weight sway
local function stanceNumbers(t)
	local b = math.sin(t * 1.7)
	local sway = math.sin(t * 0.6)
	return {
		dip = 0.28 + 0.025 * b,
		rfwd = 0,
		rside = 1.5 * sway,
		spin = -18,
		flip = 0,
		yaw = 8,
		lean = 12 + 2 * b,
		wroll = 0,
		neck = 10,
		npitch = 8 - 1.5 * b,
		lhip = 14,
		lknee = -28,
		rhip = -12,
		rknee = -22,
		lspread = 8,
		rspread = 10,
		lpitch = 18 + 3 * b,
		lroll = -14,
		lelbow = 40 + 4 * b,
		bounce = 0.02 * b,
		sway = 0,
	}
end

-- GREATSWORD WALK -> RUN (runF 0..1 from speed): hunched and heavy, knees never locked, body drops onto each
-- step, pelvis turns with the lead leg while the shoulders counter-twist, free arm swings (pumps when running),
-- the sword bobs and sways on the shoulder with every step
local function walkNumbers(phi, runF)
	local s, c = math.sin(phi), math.cos(phi)
	local plant = 0.5 - 0.5 * math.cos(2 * phi)
	local function mix(a, b)
		return a + (b - a) * runF
	end
	return {
		lhip = mix(34, 50) * s,
		rhip = -mix(34, 50) * s,
		lknee = -(mix(16, 22) + mix(58, 80) * math.max(0, c)),
		rknee = -(mix(16, 22) + mix(58, 80) * math.max(0, -c)),
		dip = mix(0.18, 0.24) + mix(0.12, 0.16) * plant,
		rfwd = mix(5, 10),
		rside = mix(2.5, 3) * s,
		spin = -mix(7, 9) * s,
		flip = 0,
		yaw = mix(10, 14) * s,
		lean = mix(14, 22),
		wroll = -mix(4, 5) * s,
		neck = -mix(3, 5) * s,
		npitch = mix(10, 16),
		lspread = 3,
		rspread = 3,
		lpitch = -mix(30, 55) * s,
		lroll = mix(10, 6),
		lelbow = mix(30, 75) + mix(15, 20) * math.max(0, s),
		bounce = 0.03 - mix(0.09, 0.13) * plant,
		sway = mix(0.05, 0.07) * s,
	}
end

---------------------------------------------------------------- rig + IK
local function jointFrames(j)
	if j:IsA("Motor6D") then
		return j.C0, j.C1
	end
	return j.Attachment0.CFrame, j.Attachment1.CFrame
end
local function rotOf(cf: CFrame)
	return cf - cf.Position
end

local function armData(character: Model, side: string)
	local ua = character:FindFirstChild(side .. "UpperArm")
	local la = character:FindFirstChild(side .. "LowerArm")
	local hand = character:FindFirstChild(side .. "Hand")
	local sh = ua and ua:FindFirstChild(side .. "Shoulder")
	local el = la and la:FindFirstChild(side .. "Elbow")
	local wr = hand and hand:FindFirstChild(side .. "Wrist")
	if not (sh and el and wr) then
		return nil
	end
	local ok, d = pcall(function()
		local sA0, sA1 = jointFrames(sh)
		local eA0, eA1 = jointFrames(el)
		local wA0, wA1 = jointFrames(wr)
		return {
			sh = sh,
			el = el,
			wr = wr,
			S = sA0.Position,
			L1 = (eA0.Position - sA1.Position).Magnitude,
			L2 = (wA0.Position - eA1.Position).Magnitude,
			vecH = GRIP_C0.Position - wA1.Position,
			sh0 = rotOf(sA0),
			sh1 = rotOf(sA1),
			el0 = rotOf(eA0),
			el1 = rotOf(eA1),
			wr0 = rotOf(wA0),
			wr1 = rotOf(wA1),
		}
	end)
	return if ok then d else nil
end

-- two-bone IK: put the hand (with the sword frame Rs) on grip point G. Everything in UpperTorso space.
local function solveArm(d, G: Vector3, Rs: CFrame, pole: Vector3)
	local Rh = Rs * GRIP_ROT:Inverse()
	local W = G - Rh * d.vecH
	local S, L1, L2 = d.S, d.L1, d.L2
	local dv = W - S
	local dist = math.clamp(dv.Magnitude, math.abs(L1 - L2) + 0.02, L1 + L2 - 0.002)
	local u = unit(dv, V(0, -1, 0))
	local cosA = math.clamp((L1 * L1 + dist * dist - L2 * L2) / (2 * L1 * dist), -1, 1)
	local sinA = math.sqrt(math.max(0, 1 - cosA * cosA))
	local pv = pole - u * pole:Dot(u)
	pv = if pv.Magnitude > 1e-3 then pv.Unit else perpTo(V(0, -1, 0), u)
	local elbow = S + (u * cosA + pv * sinA) * L1
	local wristP = S + u * dist
	local ua = unit(elbow - S, u)
	local fa = unit(wristP - elbow, u)
	local Y = -ua
	local perp = fa - ua * fa:Dot(ua)
	local Z = if perp.Magnitude > 1e-3 then -perp.Unit else -pv
	local X = Y:Cross(Z)
	local Rua = CFrame.fromMatrix(Vector3.zero, X, Y, Z)
	local bend = math.acos(math.clamp(ua:Dot(fa), -1, 1))
	local Rla = Rua * CFrame.Angles(bend, 0, 0)
	return d.sh0:Inverse() * Rua * d.sh1, d.el0:Inverse() * CFrame.Angles(bend, 0, 0) * d.el1, d.wr0:Inverse() * Rla:Inverse() * Rh * d.wr1
end

local rigs = {}

local function findRig(character: Model)
	local r = rigs[character]
	if r and r.grip.Parent and r.waist.Parent then
		return r
	end
	local function joint(partName, jointName)
		local p = character:FindFirstChild(partName)
		return p and p:FindFirstChild(jointName)
	end
	local sword = character:FindFirstChild("Gravecleaver")
	local gripPart = sword and sword:IsA("Model") and sword:FindFirstChild("Grip")
	local grip = gripPart and gripPart:FindFirstChild("SwordGrip")
	local hum = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	local j = {
		waist = joint("UpperTorso", "Waist"),
		neck = joint("Head", "Neck"),
		root = joint("LowerTorso", "Root"),
		lhip = joint("LeftUpperLeg", "LeftHip"),
		lknee = joint("LeftLowerLeg", "LeftKnee"),
		rhip = joint("RightUpperLeg", "RightHip"),
		rknee = joint("RightLowerLeg", "RightKnee"),
	}
	for _, v in pairs(j) do
		if not v then
			return nil
		end
	end
	local R, L = armData(character, "Right"), armData(character, "Left")
	if not (grip and hum and root and R and L) then
		return nil
	end
	local _, wA1 = jointFrames(j.waist)
	local blade = sword:FindFirstChild("Blade")
	r = j
	r.character = character
	r.hum = hum
	r.hroot = root
	r.hand = character:FindFirstChild("RightHand")
	r.grip = grip
	r.sword = sword
	r.R, r.L = R, L
	r.wA1 = wA1
	r.trails = { blade and blade:FindFirstChild("SwingTrail"), blade and blade:FindFirstChild("EmberTrail"), blade and blade:FindFirstChild("CrescentTrail"), blade and blade:FindFirstChild("CrescentCore") }
	r.embers = sword:FindFirstChild("CurseEmbers", true)
	r.light = sword:FindFirstChild("CurseLight", true)
	r.move = nil
	r.freeze = 0
	r.equipped = false
	r.pose = CARRY
	r.moveF = 0
	r.walkPhase = 0
	r.chargeUntil = 0
	rigs[character] = r
	character.Destroying:Once(function()
		rigs[character] = nil
	end)
	return r
end

local function setTrails(r, on)
	for _, t in ipairs(r.trails) do
		if t then
			t.Enabled = on
		end
	end
end

local function emberBurst(r, n)
	if r.embers then
		r.embers:Emit(n)
	end
end

local function blendJoint(j, cf: CFrame, w: number)
	if w >= 0.999 then
		j.Transform = cf
	elseif w > 0.001 then
		j.Transform = j.Transform:Lerp(cf, w)
	end
end

local function rootCF(n)
	return CFrame.new(0, -n.dip, 0) * CFrame.Angles(0, rad(n.spin), 0) * CFrame.Angles(rad(n.flip), 0, 0) * CFrame.Angles(rad(-n.rfwd), 0, rad(-n.rside))
end
local function lowerLayer(r, n, w)
	if w <= 0.001 then
		return
	end
	blendJoint(r.root, rootCF(n), w)
	blendJoint(r.lhip, CFrame.Angles(0, 0, rad(-(n.lspread or 0))) * CFrame.Angles(rad(n.lhip), 0, 0), w)
	blendJoint(r.lknee, CFrame.Angles(rad(n.lknee), 0, 0), w)
	blendJoint(r.rhip, CFrame.Angles(0, 0, rad(n.rspread or 0)) * CFrame.Angles(rad(n.rhip), 0, 0), w)
	blendJoint(r.rknee, CFrame.Angles(rad(n.rknee), 0, 0), w)
end
local function freeLeft(n)
	return CFrame.Angles(0, 0, rad(n.lroll)) * CFrame.Angles(rad(n.lpitch), 0, 0), CFrame.Angles(rad(n.lelbow), 0, 0), CFrame.identity
end
local function upperLayer(r, n, w)
	if w <= 0.001 then
		return
	end
	blendJoint(r.waist, CFrame.Angles(0, rad(n.yaw), 0) * CFrame.Angles(rad(-n.lean), 0, 0) * CFrame.Angles(0, 0, rad(n.wroll or 0)), w)
	blendJoint(r.neck, CFrame.Angles(0, rad(n.neck), 0) * CFrame.Angles(rad(n.npitch or 0), 0, 0), w)
end

---------------------------------------------------------------- sounds + local physics
-- Loudest moment of each recording (Sound.PlaybackLoudness at Volume 1), measured in a playtest on 2026-11-19
-- (audio\measured_2026-11-19.txt). sound() scales each of these to the same reference loudness, so a volume number
-- means the same thing for every recording. Recordings not in this list play at their raw level.
local SOUND_PEAK = {
	[9119698838] = 197, [9119698634] = 203, [9119698772] = 182, [9119698495] = 163, [9119749145] = 328, [9119698625] = 139,
	[9120742716] = 378, [9120742729] = 177, [9120629501] = 156, [9120742710] = 158,
	[9119076917] = 402, [9119076918] = 353,
	[9116482517] = 290, [9116484667] = 221, [9116481214] = 250, [9116481550] = 258, [9116484105] = 264, [9116483131] = 231,
	[9119028728] = 337, [9119028721] = 591, [9113484955] = 290, [9113484933] = 250, [9113514932] = 243,
	[9119748927] = 161, [9116485127] = 360, [9116485130] = 388,
	[9118613699] = 569, [9118613208] = 542, [9118598729] = 329, [9118598469] = 284, [9118598722] = 277,
	[9125484367] = 389, [9116477065] = 351, [9116384485] = 488, [9114224721] = 381, [9126069487] = 161,
	[9113804171] = 77, [9125626870] = 180, [9125989548] = 185, [9114221428] = 144, [9118598018] = 129,
}
local SOUND_REF = 250
-- parent nil = a flat 2D sound (always heard at full level: your own hits and big impacts)
local function sound(parent: Instance?, id: string, speed: number, volume: number, life: number?): Sound
	local s = Instance.new("Sound")
	s.SoundId = id
	s.PlaybackSpeed = speed
	local n = tonumber(string.match(id, "%d+$"))
	local peak = n and SOUND_PEAK[n]
	s.Volume = volume * (if peak then math.clamp(SOUND_REF / peak, 0.4, 3) else 1)
	s.Parent = parent or game:GetService("SoundService")
	s:Play()
	Debris:AddItem(s, life or 3)
	return s
end

local function pushAtt(root: BasePart)
	local att = root:FindFirstChild("DescentPush")
	if not att then
		att = Instance.new("Attachment")
		att.Name = "DescentPush"
		att.Parent = root
	end
	return att
end

-- horizontal push on our own character (the client owns its physics); keeps jumping/falling intact
local function pushRoot(root: BasePart, dir: Vector3, speed: number, dur: number)
	local old = root:FindFirstChild("DescentPushVel")
	if old then
		old:Destroy()
	end
	local lv = Instance.new("LinearVelocity")
	lv.Name = "DescentPushVel"
	lv.Attachment0 = pushAtt(root)
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	lv.MaxAxesForce = V(1e6, 0, 1e6)
	lv.VectorVelocity = dir * speed
	lv.Parent = root
	Debris:AddItem(lv, dur)
end

-- aerial: hold altitude for the swing (horizontal movement stays free), then fall normally
local function hang(root: BasePart, dur: number)
	local old = root:FindFirstChild("DescentHangVel")
	if old then
		old:Destroy()
	end
	local lv = Instance.new("LinearVelocity")
	lv.Name = "DescentHangVel"
	lv.Attachment0 = pushAtt(root)
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	lv.MaxAxesForce = V(0, 1e6, 0)
	lv.VectorVelocity = Vector3.zero
	lv.Parent = root
	Debris:AddItem(lv, dur)
end

-- slam: hang for the windup, then one hard downward kick (gravity does the rest, nothing pushes into the floor)
local function startSlamFall(root: BasePart, windup: number)
	hang(root, windup)
	task.delay(windup, function()
		if root.Parent then
			local v = root.AssemblyLinearVelocity
			local look = unit(root.CFrame.LookVector * FLAT)
			root.AssemblyLinearVelocity = V(v.X * 0.3, -cfg.Slam.FallSpeed, v.Z * 0.3) + look * 6
		end
	end)
end

local rotateToken = 0
local function lockRotate(hum: Humanoid, dur: number)
	rotateToken += 1
	local tok = rotateToken
	hum.AutoRotate = false
	task.delay(dur, function()
		if tok == rotateToken and hum.Parent then
			hum.AutoRotate = true
		end
	end)
end

---------------------------------------------------------------- VFX helpers
local function fxAnchor(pos: Vector3)
	local p = Instance.new("Part")
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
	p.Transparency = 1
	p.Size = V(0.2, 0.2, 0.2)
	p.CFrame = CFrame.new(pos)
	p.Parent = fxFolder
	return p
end

local function burst(pos: Vector3, props, count: number, life: number?)
	local p = fxAnchor(pos)
	local e = Instance.new("ParticleEmitter")
	e.Enabled = false
	for k, v in pairs(props) do
		e[k] = v
	end
	e.Parent = p
	e:Emit(count)
	Debris:AddItem(p, life or 2)
end

local SPARKS = {
	Texture = "rbxasset://textures/particles/sparkles_main.dds",
	Color = ColorSequence.new(Color3.fromRGB(255, 210, 130), Color3.fromRGB(255, 60, 20)),
	LightEmission = 1,
	Size = NumberSequence.new(0.6, 0),
	Lifetime = NumberRange.new(0.2, 0.45),
	Speed = NumberRange.new(14, 26),
	SpreadAngle = Vector2.new(80, 80),
	Drag = 4,
	Acceleration = V(0, -30, 0),
}
local EMBERS = {
	Texture = "rbxasset://textures/particles/fire_main.dds",
	Color = ColorSequence.new(Color3.fromRGB(255, 90, 30)),
	LightEmission = 1,
	Size = NumberSequence.new(0.35, 0),
	Lifetime = NumberRange.new(0.5, 1.1),
	Speed = NumberRange.new(4, 10),
	SpreadAngle = Vector2.new(180, 180),
	Acceleration = V(0, 6, 0),
	Drag = 2,
}
local DUST = {
	Texture = "rbxasset://textures/particles/smoke_main.dds",
	Color = ColorSequence.new(Color3.fromRGB(110, 100, 92)),
	Transparency = NumberSequence.new(0.35, 1),
	Size = NumberSequence.new(1.5, 4.5),
	Lifetime = NumberRange.new(0.6, 1.2),
	Speed = NumberRange.new(7, 12),
	SpreadAngle = Vector2.new(90, 90),
	Drag = 5,
	RotSpeed = NumberRange.new(-60, 60),
}
local DASH_DUST = {
	Texture = "rbxasset://textures/particles/smoke_main.dds",
	Color = ColorSequence.new(Color3.fromRGB(90, 82, 78)),
	Transparency = NumberSequence.new(0.5, 1),
	Size = NumberSequence.new(0.8, 2.6),
	Lifetime = NumberRange.new(0.35, 0.7),
	Speed = NumberRange.new(4, 8),
	SpreadAngle = Vector2.new(70, 10),
	Drag = 6,
	RotSpeed = NumberRange.new(-80, 80),
}

local function groundBelow(pos: Vector3)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { fxFolder, DEMONS, player.Character }
	local hit = workspace:Raycast(pos + V(0, 4, 0), V(0, -16, 0), params)
	return if hit then hit.Position else pos - V(0, 3, 0)
end

---------------------------------------------------------------- curved-beam VFX: rings, crescents, speed lines, bolts, cracks
local beamHost = fxAnchor(Vector3.zero)
beamHost.Name = "BeamHost"

-- a CFrame whose RightVector is a and LookVector is b (unit, perpendicular): the plane an arc is drawn in
local function planeCF(pos: Vector3, a: Vector3, b: Vector3): CFrame
	return CFrame.fromMatrix(pos, a, a:Cross(b), -b)
end

-- run step(x) every frame for `dur` seconds (x 0..1), then done()
local function animate(dur: number, step: (number) -> (), done: (() -> ())?)
	local t0 = os.clock()
	step(0)
	local conn
	conn = RunService.Heartbeat:Connect(function()
		local x = math.min(1, (os.clock() - t0) / dur)
		step(x)
		if x >= 1 then
			conn:Disconnect()
			if done then
				done()
			end
		end
	end)
end

local function newAtt(): Attachment
	local a = Instance.new("Attachment")
	a.Parent = beamHost
	return a
end

local function newBeam(a0: Attachment, a1: Attachment, color: Color3, lightE: number, faceCam: boolean): Beam
	local b = Instance.new("Beam")
	b.Attachment0, b.Attachment1 = a0, a1
	b.FaceCamera = faceCam
	b.Color = ColorSequence.new(color)
	b.LightEmission = lightE
	b.LightInfluence = 0
	b.Segments = 1
	b.Parent = beamHost
	return b
end

-- an arc of curved Beams round arc.c (c.RightVector = angle 0, c.LookVector = +90 deg), from a0 to a1 (radians).
-- flat: the ribbon lies in the arc's plane (ground rings, crescents); otherwise it turns to face the camera.
local function makeArc(c: CFrame, a0: number, a1: number, color: Color3, lightE: number, flat: boolean)
	local n = math.max(3, math.ceil(math.abs(a1 - a0) / (math.pi / 3)))
	local segs = {}
	for i = 1, n do
		local A0, A1 = newAtt(), newAtt()
		local b = newBeam(A0, A1, color, lightE, not flat)
		b.Segments = 14
		segs[i] = { A0, A1, b }
	end
	local arc = { c = c }
	function arc.set(R: number, widthFn: (number) -> number, tr: number)
		local step = (a1 - a0) / n
		local k = 4 / 3 * math.tan(math.abs(step) / 4) * R
		local sgn = if step < 0 then -1 else 1
		local cc = arc.c
		local u, v = cc.RightVector, cc.LookVector
		local function at(a: number): CFrame
			local rd = u * math.cos(a) + v * math.sin(a)
			local tg = (v * math.cos(a) - u * math.sin(a)) * sgn
			return CFrame.fromMatrix(cc.Position + rd * R, tg, rd)
		end
		local trs = NumberSequence.new(math.clamp(tr, 0, 1))
		for i, sg in ipairs(segs) do
			sg[1].WorldCFrame = at(a0 + step * (i - 1))
			sg[2].WorldCFrame = at(a0 + step * i)
			sg[3].CurveSize0, sg[3].CurveSize1 = k, k
			sg[3].Width0 = widthFn((i - 1) / n)
			sg[3].Width1 = widthFn(i / n)
			sg[3].Transparency = trs
		end
	end
	function arc.destroy()
		for _, sg in ipairs(segs) do
			sg[3]:Destroy()
			sg[1]:Destroy()
			sg[2]:Destroy()
		end
	end
	return arc
end

-- a flat ring that races out across the ground and thins as it goes
local function groundRing(pos: Vector3, r0: number, r1: number, dur: number, width: number, color: Color3, lightE: number?)
	local arc = makeArc(CFrame.new(pos), 0, math.pi * 2, color, lightE or 1, true)
	animate(dur, function(x)
		local wd = width * (1 - 0.75 * x)
		arc.set(r0 + (r1 - r0) * EASE.outCubic(x), function()
			return wd
		end, x ^ 1.6)
	end, arc.destroy)
end

-- a crescent: thick in the middle, sharp at both ends; it flares a little wider and burns out
local function crescent(c: CFrame, R: number, a0: number, a1: number, width: number, color: Color3, dur: number, flat: boolean)
	local arc = makeArc(c, a0, a1, color, 1, flat)
	animate(dur, function(x)
		local wd = width * (1 - 0.6 * x)
		arc.set(R * (1 + 0.1 * x), function(f)
			return wd * math.max(0.04, math.sin(math.pi * f)) ^ 0.7
		end, x ^ 1.3)
	end, arc.destroy)
end

-- speed lines: thin white streaks shooting out from a point
local function radialBurst(pos: Vector3, count: number, r0: number, r1: number, dur: number, color: Color3, width: number, rising: boolean?)
	for i = 1, count do
		local a = (i / count) * math.pi * 2 + math.random() * 0.35
		local dir = unit(V(math.cos(a), if rising then 0.15 + math.random() * 0.8 else 0.04 + math.random() * 0.12, math.sin(a)))
		local A0, A1 = newAtt(), newAtt()
		local b = newBeam(A0, A1, color, 1, true)
		b.Width0 = width * (0.6 + math.random() * 0.8)
		b.Width1 = 0
		local len = (r1 - r0) * (0.45 + math.random() * 0.45)
		animate(dur * (0.7 + math.random() * 0.5), function(x)
			local inner = r0 + (r1 - r0) * EASE.outCubic(x) * 0.85
			A0.WorldPosition = pos + dir * inner
			A1.WorldPosition = pos + dir * (inner + len * (1 - 0.5 * x))
			b.Transparency = NumberSequence.new(x * x)
		end, function()
			b:Destroy()
			A0:Destroy()
			A1:Destroy()
		end)
	end
end

-- a lightning bolt: a jagged white-hot core inside a crimson glow, gone in a few frames
local BOLT_CORE = Color3.fromRGB(255, 236, 230)
local function bolt(p0: Vector3, p1: Vector3, color: Color3, width: number, life: number)
	local d = p1 - p0
	local len = d.Magnitude
	if len < 0.1 then
		return
	end
	local n = math.clamp(math.floor(len / 1.4), 3, 14)
	local s1 = perpTo(V(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5), d.Unit)
	local s2 = d.Unit:Cross(s1)
	local made, atts = {}, {}
	for i = 0, n do
		local j = if i == 0 or i == n then 0 else len * 0.11
		local a = newAtt()
		a.WorldPosition = p0 + d * (i / n) + s1 * (math.random() - 0.5) * 2 * j + s2 * (math.random() - 0.5) * 2 * j
		atts[i] = a
		table.insert(made, a)
	end
	for i = 1, n do
		local glow = newBeam(atts[i - 1], atts[i], color, 1, true)
		glow.Width0, glow.Width1 = width * 3.2, width * 3.2
		glow.Transparency = NumberSequence.new(0.45)
		local core = newBeam(atts[i - 1], atts[i], BOLT_CORE, 1, true)
		core.Width0, core.Width1 = width, width
		table.insert(made, glow)
		table.insert(made, core)
	end
	task.delay(life, function()
		for _, x in ipairs(made) do
			x:Destroy()
		end
	end)
end

-- glowing cracks that wander out from a point and branch, each over a darker scorch line, then cool off
local function cracks(center: Vector3, count: number, len: number, color: Color3, life: number)
	local beams, atts = {}, {}
	local function seg(a: Vector3, b: Vector3, w0: number, w1: number)
		local fwd = unit((b - a) * FLAT, V(1, 0, 0))
		local side = fwd:Cross(Vector3.yAxis)
		for layer = 1, 2 do
			local drop = if layer == 1 then V(0, -0.012, 0) else Vector3.zero
			local A0, A1 = newAtt(), newAtt()
			A0.WorldCFrame = CFrame.fromMatrix(a + drop, fwd, side)
			A1.WorldCFrame = CFrame.fromMatrix(b + drop, fwd, side)
			local dark = layer == 1
			local bm = newBeam(A0, A1, if dark then Color3.fromRGB(18, 10, 10) else color, if dark then 0 else 1, false)
			bm.Width0 = if dark then w0 * 2.4 else w0
			bm.Width1 = if dark then w1 * 2.4 else w1
			table.insert(beams, bm)
			table.insert(atts, A0)
			table.insert(atts, A1)
		end
	end
	for i = 1, count do
		local heading = (i / count) * math.pi * 2 + math.random() * 0.5
		local p = center + V(math.cos(heading), 0, math.sin(heading)) * 0.3
		local wd = 0.32 + 0.1 * math.random()
		for k = 1, 4 do
			heading += (math.random() - 0.5) * 0.9
			local l = len / 4 * (0.7 + math.random() * 0.6)
			local q = p + V(math.cos(heading), 0, math.sin(heading)) * l
			seg(p, q, wd, wd * 0.62)
			if k == 2 and math.random() < 0.65 then
				local bh = heading + (if math.random() < 0.5 then 0.75 else -0.75)
				seg(q, q + V(math.cos(bh), 0, math.sin(bh)) * l * 0.8, wd * 0.62, 0.02)
			end
			wd *= 0.62
			p = q
		end
	end
	animate(life, function(x)
		local tr = NumberSequence.new(math.clamp((x - 0.45) / 0.55, 0, 1))
		for _, bm in ipairs(beams) do
			bm.Transparency = tr
		end
	end, function()
		for _, bm in ipairs(beams) do
			bm:Destroy()
		end
		for _, a in ipairs(atts) do
			a:Destroy()
		end
	end)
end

-- a shockwave: a coloured ring and a thinner white one racing out across the floor, plus dust
local function shockwave(center: Vector3, radius: number, color: Color3)
	local ground = groundBelow(center)
	groundRing(ground + V(0, 0.14, 0), radius * 0.12, radius, 0.34, math.max(0.35, radius * 0.13), color, 1)
	groundRing(ground + V(0, 0.18, 0), radius * 0.08, radius * 0.8, 0.24, math.max(0.18, radius * 0.05), Color3.fromRGB(255, 245, 240), 1)
	burst(ground + V(0, 0.3, 0), DUST, 12, 1.6)
end

local DEBRIS = {
	Texture = "rbxasset://textures/particles/sparkles_main.dds",
	Color = ColorSequence.new(Color3.fromRGB(60, 50, 46)),
	LightEmission = 0,
	Size = NumberSequence.new(0.35, 0.15),
	Lifetime = NumberRange.new(0.5, 0.9),
	Speed = NumberRange.new(18, 30),
	SpreadAngle = Vector2.new(35, 35),
	Acceleration = V(0, -60, 0),
	Drag = 1,
}

local HIT_SPARKS = {
	Texture = "rbxasset://textures/particles/sparkles_main.dds",
	Color = ColorSequence.new(Color3.fromRGB(255, 90, 80), HIT_RED),
	LightEmission = 1,
	Size = NumberSequence.new(0.3, 0),
	Lifetime = NumberRange.new(0.12, 0.28),
	Speed = NumberRange.new(10, 18),
	SpreadAngle = Vector2.new(70, 70),
	Drag = 5,
	Acceleration = V(0, -25, 0),
}

local function damageNumber(pos: Vector3, dmg: number, crit: boolean, big: boolean)
	local p = fxAnchor(pos + V(math.random() - 0.5, 2.6, math.random() - 0.5))
	local bb = Instance.new("BillboardGui")
	bb.Size = if big or crit then UDim2.fromOffset(110, 38) else UDim2.fromOffset(80, 28)
	bb.AlwaysOnTop = true
	bb.Parent = p
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.GothamBlack
	t.TextScaled = true
	t.Text = tostring(math.floor(dmg)) .. (if crit then "!" else "")
	t.TextColor3 = if crit then HIT_RED else Color3.fromRGB(245, 240, 240)
	t.TextStrokeColor3 = if crit then Color3.fromRGB(40, 0, 0) else Color3.fromRGB(120, 10, 10)
	t.TextStrokeTransparency = 0.1
	t.Parent = bb
	TweenService:Create(p, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = p.CFrame + V(0, 1.8, 0) }):Play()
	TweenService:Create(t, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	Debris:AddItem(p, 0.7)
end

local function shake(intensity: number, duration: number)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	local t0 = os.clock()
	local conn
	conn = RunService.RenderStepped:Connect(function()
		local e = os.clock() - t0
		if e > duration then
			hum.CameraOffset = Vector3.zero
			conn:Disconnect()
			return
		end
		local k = intensity * (1 - e / duration)
		hum.CameraOffset = V((math.random() - 0.5) * k, (math.random() - 0.5) * k, 0)
	end)
end

local flash = Instance.new("ColorCorrectionEffect")
flash.Name = "DescentCritFlash"
flash.Parent = Lighting
local function critFlash()
	flash.TintColor = Color3.fromRGB(255, 225, 150)
	flash.Brightness = 0.25
	flash.Contrast = 0.15
	TweenService:Create(flash, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		TintColor = Color3.new(1, 1, 1),
		Brightness = 0,
		Contrast = 0,
	}):Play()
end

-- the floor breaks: a scorched patch, glowing cracks that branch outward, grit and embers thrown up
local function floorCrack(pos: Vector3, scale: number?)
	local sc = scale or 1
	local ground = groundBelow(pos)
	for i = 1, 3 do
		local d = (3.2 + math.random() * 1.6) * sc
		local disc = Instance.new("Part")
		disc.Shape = Enum.PartType.Cylinder
		disc.Anchored, disc.CanCollide, disc.CanQuery, disc.CanTouch, disc.CastShadow = true, false, false, false, false
		disc.Size = V(0.06, d, d)
		local off = if i == 1 then Vector3.zero else V(math.random() - 0.5, 0, math.random() - 0.5) * 2 * sc
		disc.CFrame = CFrame.new(ground + off + V(0, 0.03 + i * 0.005, 0)) * CFrame.Angles(0, 0, rad(90))
		disc.Material = Enum.Material.Slate
		disc.Color = Color3.fromRGB(24, 18, 18)
		disc.Transparency = 0.1 + i * 0.12
		disc.Parent = fxFolder
		TweenService:Create(disc, TweenInfo.new(2.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Transparency = 1 }):Play()
		Debris:AddItem(disc, 2.7)
	end
	cracks(ground + V(0, 0.07, 0), math.floor(7 + 2 * sc), 3.6 * sc, Color3.fromRGB(255, 90, 35), 2.2)
	burst(ground + V(0, 0.4, 0), DEBRIS, math.floor(22 * sc), 1.2)
	burst(ground + V(0, 0.5, 0), EMBERS, math.floor(30 * sc), 2)
end

local function soulWisps(fromPos: Vector3, character: Model?)
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	for i = 1, 5 do
		local w = Instance.new("Part")
		w.Shape = Enum.PartType.Ball
		w.Size = V(0.35, 0.35, 0.35)
		w.Material = Enum.Material.Neon
		w.Color = Color3.fromRGB(110, 200, 255)
		w.Anchored, w.CanCollide, w.CanQuery, w.CanTouch = true, false, false, false
		w.Position = fromPos
		w.Parent = fxFolder
		local l = Instance.new("PointLight")
		l.Color = w.Color
		l.Range = 5
		l.Brightness = 2
		l.Parent = w
		local ctrl = fromPos + V((math.random() - 0.5) * 8, 5 + math.random() * 4, (math.random() - 0.5) * 8)
		local t0, dur = os.clock(), 0.55 + i * 0.06
		task.spawn(function()
			while root.Parent do
				local e = (os.clock() - t0) / dur
				if e >= 1 then
					break
				end
				w.Position = fromPos:Lerp(ctrl, e):Lerp(ctrl:Lerp(root.Position, e), e)
				RunService.RenderStepped:Wait()
			end
			w:Destroy()
		end)
	end
end

local function afterimage(character: Model, alpha: number)
	local g = Instance.new("Model")
	g.Name = "Afterimage"
	for _, p in ipairs(character:GetDescendants()) do
		if p:IsA("BasePart") and p.Name ~= "HumanoidRootPart" and p.Transparency < 0.9 then
			local ok, c = pcall(function()
				return p:Clone()
			end)
			if ok and c then
				c:ClearAllChildren()
				c.Anchored, c.CanCollide, c.CanQuery, c.CanTouch, c.CastShadow = true, false, false, false, false
				c.Material = Enum.Material.Neon
				c.Color = Color3.fromRGB(150, 22, 16)
				c.Transparency = alpha
				if c:IsA("MeshPart") then
					c.TextureID = ""
				end
				c.CFrame = p.CFrame
				c.Parent = g
				TweenService:Create(c, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Transparency = 1 }):Play()
			end
		end
	end
	g.Parent = fxFolder
	Debris:AddItem(g, 0.4)
end

local function afterimages(character: Model, count: number, gap: number)
	task.spawn(function()
		for i = 1, count do
			if not character.Parent then
				break
			end
			afterimage(character, 0.45 + i * 0.08)
			task.wait(gap)
		end
	end)
end

local camera = workspace.CurrentCamera
local baseFov = camera.FieldOfView
local function fovKick(amount: number)
	camera.FieldOfView = baseFov
	local up = TweenService:Create(camera, TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { FieldOfView = baseFov + amount })
	up:Play()
	up.Completed:Once(function()
		TweenService:Create(camera, TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), { FieldOfView = baseFov }):Play()
	end)
end

local RED = Color3.fromRGB(255, 70, 30)
-- Pro Sound Effects library sounds (licensed for Roblox, free on the Creator Store)
local SFX = {
	Whoosh = "rbxassetid://9120972444", -- "Wood Whoosh Slicing Air Quick Swings 1"
	BladeRing = "rbxassetid://9113449585", -- "Blade Hits Metal Rod On Knife Impacts 10"
	Thud = "rbxassetid://9113484814", -- "Body Hit 5": pick blade hits gut
	-- REAL recorded sword sounds (2026-11-19), all from the same licensed Pro Sound Effects library. Lists = a random
	-- pick each time so repeated swings never sound identical.
	-- v2 (2026-11-19 evening): all re-picked and measured. v1's flesh layer was nearly silent (loudness 48, 0.36 s
	-- late) and its "sword hit" was a sword slicing WOOD, so hits sounded like another swing.
	SwordSwish = { "rbxassetid://9119698838", "rbxassetid://9119698634", "rbxassetid://9119698772", "rbxassetid://9119698495", "rbxassetid://9119749145", "rbxassetid://9119698625" }, -- "Swish High End Thin Sharp Thick" (swords) + "Sword Swish 102" metal shing
	HeavyWhoosh = { "rbxassetid://9120742716", "rbxassetid://9120742729", "rbxassetid://9120629501", "rbxassetid://9120742710" }, -- thick quick whooshes + "Web Whoosh Fast Heavy"
	SteelShing = { "rbxassetid://9119076917", "rbxassetid://9119076918" }, -- "Shing Ringy": large ringing blade, under heavy swings
	BodyChop = { "rbxassetid://9116482517", "rbxassetid://9116484667", "rbxassetid://9116481214", "rbxassetid://9116481550", "rbxassetid://9116484105", "rbxassetid://9116483131" }, -- "Meat Chop Big Meaty Impacts" (an axe through meat): the hit you FEEL
	BladeCut = { "rbxassetid://9119028728", "rbxassetid://9119028721", "rbxassetid://9113484955", "rbxassetid://9113484933", "rbxassetid://9113514932" }, -- "Sever Metal Hit" (sword cuts off a limb), blade into gut, metal on flesh
	WetStab = "rbxassetid://9119748927", -- "Sword Stab 1", juicy
	MeatHack = { "rbxassetid://9116485127", "rbxassetid://9116485130" }, -- "Meat Hack": huge chops with a large sword, heavy hits only
	RockImpact = { "rbxassetid://9118613699", "rbxassetid://9118613208" }, -- huge crunchy rock hits
	DirtHit = { "rbxassetid://9118598729", "rbxassetid://9118598469", "rbxassetid://9118598722" }, -- deep thunk into dirt
	Boom = { "rbxassetid://9125484367", "rbxassetid://9116477065" }, -- deep reverberant boom / massive footstep
	MagicBurst = "rbxassetid://9116384485", -- big beefy impact with a glowing tone
	Quake = "rbxassetid://9114224721", -- earthquake explosion, rock and debris
	LightningCrack = "rbxassetid://9126069487",
	HolyBell = "rbxassetid://9113804171", -- church bell, single hit
	LightSuck = "rbxassetid://9125626870", -- reverse-cymbal build, loudest at 2.47 s
	SpiritWhoosh = "rbxassetid://9125989548", -- low airy growl going by: a demon's soul leaving
	EarthRumble = "rbxassetid://9114221428",
	Footstep = "rbxassetid://9118598018", -- dirt thunk
	SwordClang = { "rbxassetid://9119072660", "rbxassetid://9119072674" },
}
local function pick(v)
	return if type(v) == "table" then v[math.random(1, #v)] else v
end
task.spawn(function()
	local list = {}
	for _, v in pairs(SFX) do
		for _, id in ipairs(if type(v) == "table" then v else { v }) do
			local snd = Instance.new("Sound")
			snd.SoundId = id
			table.insert(list, snd)
		end
	end
	pcall(function()
		game:GetService("ContentProvider"):PreloadAsync(list)
	end)
end)
local GOLD = Color3.fromRGB(255, 205, 90)
local ORANGE = Color3.fromRGB(255, 150, 70)

---------------------------------------------------------------- move events
local function flatLook(root: BasePart)
	return unit(root.CFrame.LookVector * FLAT)
end

-- the tall crescent the blade carves coming down over the top (stands in the swing plane, faces the camera)
local function slamArc(r, scale: number?)
	local sc = scale or 1
	local root = r.hroot
	local fwd = flatLook(root)
	local c = planeCF(root.Position + V(0, 1.3 * sc, 0) + fwd * 0.6, fwd, Vector3.yAxis)
	crescent(c, 5.4 * sc, math.pi * 0.85, -0.5, 1.3 * sc, HIT_RED, 0.4, false)
	crescent(c, 5.0 * sc, math.pi * 0.8, -0.45, 0.45 * sc, Color3.fromRGB(255, 240, 235), 0.24, false)
end

-- the Grave Slam (and any big blow into the floor): cracks, scorch, rings, speed lines, grit, a heavy thud
local function craterSlam(p: Vector3, scale: number, mine: boolean)
	floorCrack(p, scale)
	shockwave(p, 9 * scale, HIT_RED)
	local g = groundBelow(p)
	radialBurst(g + V(0, 0.3, 0), 16, 1.2, 8 * scale, 0.26, Color3.fromRGB(255, 250, 245), 0.45, true)
	burst(g + V(0, 0.5, 0), DUST, math.floor(22 * scale), 2)
	local a = fxAnchor(p)
	Debris:AddItem(a, 3)
	sound(a, pick(SFX.RockImpact), 0.9 + math.random() * 0.1, 1.5)
	sound(a, pick(SFX.DirtHit), 0.75, 1.3)
	sound(a, pick(SFX.Boom), 0.9, 1.1)
	sound(a, pick(SFX.SwordClang), 0.8 + math.random() * 0.08, 0.6)
	if mine then
		shake(1.1, 0.3)
		fovKick(6)
	end
end

local function onStrike(r, m)
	local root = r.hroot
	local mine = r.character == player.Character
	local step = if m.kind == "Light" then m.step else 0
	local swPitch = if m.kind == "Heavy" then 0.78 elseif step == 4 then 0.74 elseif step == 3 then 0.84 else 0.88 + math.random() * 0.1
	local bigSwing = m.kind == "Heavy" or step == 4
	sound(root, pick(SFX.SwordSwish), swPitch, 0.9)
	sound(root, pick(SFX.HeavyWhoosh), swPitch * 0.8, if bigSwing then 0.85 else 0.55)
	if bigSwing then
		sound(root, pick(SFX.SteelShing), swPitch * 0.85, 0.4)
	end
	emberBurst(r, if m.kind == "Heavy" or step == 4 then 20 else 8)
	local g = groundBelow(root.Position)
	if m.kind == "Heavy" then
		shockwave(root.Position + flatLook(root) * 2, 5, HIT_RED)
		if mine then
			shake(0.9, 0.25)
		end
	elseif step == 1 or step == 2 then
		-- the lead foot stamps in: dust off the step and a thin ring of air
		burst(g + flatLook(root) * 1.5 + V(0, 0.4, 0), DASH_DUST, 14, 1)
		groundRing(g + V(0, 0.15, 0), 1, 5, 0.26, 0.32, Color3.fromRGB(255, 255, 255), 0.45)
	elseif step == 3 then
		-- the wheel throws a ring of air and dust off the floor round the feet
		groundRing(g + V(0, 0.15, 0), 1.5, 7.5, 0.34, 0.55, Color3.fromRGB(255, 255, 255), 0.55)
		task.delay(0.1, function()
			groundRing(g + V(0, 0.12, 0), 1, 5.5, 0.3, 0.35, Color3.fromRGB(255, 255, 255), 0.4)
		end)
		burst(g + V(0, 0.4, 0), DASH_DUST, 18, 1)
	elseif step == 4 then
		slamArc(r)
	end
	-- step into the swing (own character, on the ground, not running)
	if mine and r.hum.FloorMaterial ~= Enum.Material.Air and r.moveF < 0.5 then
		pushRoot(root, flatLook(root), if m.kind == "Heavy" then 20 elseif step == 4 then 14 elseif step == 3 then 5 else 12, 0.1)
	end
end

-- the frame the blade meets the floor (Grave Slam)
local function onImpact(r, m)
	local root = r.hroot
	craterSlam(groundBelow(root.Position + flatLook(root) * cfg.Light[4].Forward), 1, r.character == player.Character)
end

local function land(r)
	local root = r.hroot
	r.freeze = 0
	r.move = buildMove(r.pose, MOVES.FlipLand(), { kind = "FlipLand", blendOutFrom = 0.2 })
	burst(groundBelow(root.Position) + V(0, 0.3, 0), DASH_DUST, 14, 1)
	emberBurst(r, 8)
	shockwave(root.Position, 3.5, HIT_RED)
	if r.character == player.Character then
		shake(0.35, 0.12)
		r.hum.AutoRotate = true
	end
end

local function slamImpactFX(pos: Vector3)
	floorCrack(pos)
	shockwave(pos, 7, HIT_RED)
	burst(groundBelow(pos) + V(0, 0.5, 0), DUST, 26, 2)
end

local function slamLand(r, mine: boolean)
	local root = r.hroot
	local hv = root:FindFirstChild("DescentHangVel")
	if hv then
		hv:Destroy()
	end
	r.freeze = 0
	r.move = buildMove(r.pose, MOVES.SlamLand(), { kind = "SlamLand", trailFrom = 0, trailTo = 0.1, blendOutFrom = 0.5 })
	emberBurst(r, 16)
	if mine then
		local impact = groundBelow(root.Position) + flatLook(root) * cfg.Slam.Forward
		slamImpactFX(impact)
		shake(1.2, 0.3)
		local p = fxAnchor(impact)
		Debris:AddItem(p, 3)
		sound(p, pick(SFX.RockImpact), 0.9 + math.random() * 0.1, 1.5)
		sound(p, pick(SFX.DirtHit), 0.75, 1.3)
		sound(p, pick(SFX.Boom), 0.9, 1.1)
		sound(p, pick(SFX.SwordClang), 0.8, 0.6)
	end
end

---------------------------------------------------------------- hit feel: the blade touching a demon
local contactParams = OverlapParams.new()
contactParams.FilterType = Enum.RaycastFilterType.Include
contactParams.FilterDescendantsInstances = { DEMONS }

local function demonOf(part: Instance): Model?
	local x = part
	while x and x.Parent ~= DEMONS do
		x = x.Parent
	end
	return x
end

local SLASH_SPARKS = {
	Texture = "rbxasset://textures/particles/sparkles_main.dds",
	Color = ColorSequence.new(Color3.fromRGB(255, 120, 100), HIT_RED),
	LightEmission = 1,
	Size = NumberSequence.new(0.45, 0),
	Lifetime = NumberRange.new(0.12, 0.3),
	Speed = NumberRange.new(20, 34),
	SpreadAngle = Vector2.new(28, 28),
	Drag = 6,
	Acceleration = V(0, -20, 0),
	EmissionDirection = Enum.NormalId.Front,
}

-- sparks spray along the swing, a thin crimson slash streak, a small white-hot flash with a red rim
local function contactFX(p: Vector3, motion: Vector3, heavy: boolean)
	local dir = if motion.Magnitude > 0.01 then motion.Unit else V(0, 1, 0)
	local cf = CFrame.lookAt(p, p + dir)
	local a = fxAnchor(p)
	a.CFrame = cf
	local e = Instance.new("ParticleEmitter")
	e.Enabled = false
	for k, v in pairs(SLASH_SPARKS) do
		e[k] = v
	end
	e.Parent = a
	e:Emit(if heavy then 26 else 16)
	Debris:AddItem(a, 0.5)
	local streak = Instance.new("Part")
	streak.Anchored, streak.CanCollide, streak.CanQuery, streak.CanTouch, streak.CastShadow = true, false, false, false, false
	streak.Material = Enum.Material.Neon
	streak.Color = HIT_RED
	streak.Size = V(0.06, 0.06, if heavy then 1.2 else 0.8)
	streak.CFrame = cf
	streak.Parent = fxFolder
	TweenService:Create(streak, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = V(0.02, 0.02, if heavy then 4 else 2.6), Transparency = 1 }):Play()
	Debris:AddItem(streak, 0.15)
	for _, spec in ipairs({ { Color3.fromRGB(255, 245, 240), 0.9, 0.07 }, { HIT_RED, if heavy then 2.2 else 1.5, 0.11 } }) do
		local b = Instance.new("Part")
		b.Shape = Enum.PartType.Ball
		b.Material = Enum.Material.Neon
		b.Color = spec[1]
		b.Anchored, b.CanCollide, b.CanQuery, b.CanTouch, b.CastShadow = true, false, false, false, false
		b.Size = Vector3.one * 0.3
		b.CFrame = CFrame.new(p)
		b.Transparency = 0.15
		b.Parent = fxFolder
		TweenService:Create(b, TweenInfo.new(spec[3], Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.one * spec[2], Transparency = 1 }):Play()
		Debris:AddItem(b, spec[3] + 0.03)
	end
end

-- the demon flashes white then fades through red
local function enemyFlash(d: Model)
	local h = Instance.new("Highlight")
	h.FillColor = Color3.new(1, 1, 1)
	h.OutlineColor = HIT_RED
	h.FillTransparency = 0.15
	h.OutlineTransparency = 0
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.Parent = d
	TweenService:Create(h, TweenInfo.new(0.18), { FillTransparency = 1, OutlineTransparency = 1, FillColor = HIT_RED }):Play()
	Debris:AddItem(h, 0.2)
end

local lastHitSound = 0
local function hitSounds(p: Vector3, heavy: boolean, mine: boolean?)
	-- one clean set per strike: several demons hit in the same instant would stack into a wall of noise
	local now = os.clock()
	local since = now - lastHitSound
	if since < 0.08 then
		return
	end
	lastHitSound = now
	-- more demons cut by the same swing only add another chop, so a sweep through a crowd stays clean
	local followUp = since < 0.3
	-- your own hits play flat (2D) so they always cut through the swing, whatever the camera distance;
	-- other players' hits come from where they happen
	local sp: Instance? = nil
	if not mine then
		sp = fxAnchor(p)
		Debris:AddItem(sp, 3)
	end
	if followUp then
		sound(sp, pick(SFX.BodyChop), 0.9 + math.random() * 0.12, if heavy then 1.3 else 1.1)
		return
	end
	-- the chop you feel (pitched down: a huge blade) + the blade cutting + a wet layer
	sound(sp, pick(SFX.BodyChop), if heavy then 0.78 + math.random() * 0.08 else 0.86 + math.random() * 0.12, if heavy then 1.9 else 1.6)
	sound(sp, pick(SFX.BladeCut), 0.85 + math.random() * 0.15, if heavy then 1.4 else 1.15)
	sound(sp, SFX.WetStab, 0.9 + math.random() * 0.15, 0.7)
	if heavy then
		sound(sp, pick(SFX.MeatHack), 0.82 + math.random() * 0.08, 1.2)
		sound(sp, pick(SFX.DirtHit), 0.7, 0.8)
	end
end

-- the exact frame the blade bites: freeze the swing, burst at the contact point, flash the demon, punch the camera
local function onContact(r, d: Model, p: Vector3, motion: Vector3)
	local heavy = r.move ~= nil and (r.move.kind == "Heavy" or (r.move.kind == "Light" and r.move.step == 4))
	r.freeze = math.max(r.freeze, if heavy then 0.09 else 0.06)
	r.recentContacts = r.recentContacts or {}
	r.recentContacts[d] = os.clock()
	contactFX(p, motion, heavy)
	enemyFlash(d)
	hitSounds(p, heavy, r.character == player.Character)
	shake(if heavy then 0.7 else 0.4, 0.12)
	fovKick(if heavy then 5 else 3)
end

-- sample points along the blade each frame of the strike; first touch per demon per swing = contact
local function checkContact(r, m)
	local blade = r.sword:FindFirstChild("Blade")
	local tipAtt = blade and blade:FindFirstChild("TrailTip")
	if not (blade and tipAtt) then
		return
	end
	local p0 = (blade.CFrame * CFrame.new(0, -blade.Size.Y * 0.4, 0)).Position
	local p1 = tipAtt.WorldPosition
	local motion = if m.lastTip then p1 - m.lastTip else Vector3.zero
	m.lastTip = p1
	m.contacted = m.contacted or {}
	for i = 0, 5 do
		local p = p0:Lerp(p1, i / 5)
		for _, part in ipairs(workspace:GetPartBoundsInRadius(p, 1.4, contactParams)) do
			local d = demonOf(part)
			local hum = d and d:FindFirstChildOfClass("Humanoid")
			if d and hum and hum.Health > 0 and not m.contacted[d] then
				m.contacted[d] = true
				local guarded = false
				if m.kind ~= "Slam" and d:GetAttribute("MonsterFrontalGuard") then
					local targetRoot = d:FindFirstChild("HumanoidRootPart")
					local attackerRoot = r.character:FindFirstChild("HumanoidRootPart")
					if targetRoot and attackerRoot then
						local toward = (attackerRoot.Position - targetRoot.Position) * Vector3.new(1, 0, 1)
						guarded = toward.Magnitude > 0.1 and toward.Unit:Dot(d:GetPivot().LookVector) > 0.45
					end
				end
				if not guarded then
					onContact(r, d, p, motion)
				end
			end
		end
	end
end

local function footPlant(r)
	local g = groundBelow(r.hroot.Position)
	burst(g + V(0, 0.3, 0), DASH_DUST, 8, 0.8)
	sound(r.hroot, SFX.Footstep, 0.8 + math.random() * 0.1, 0.5)
end

---------------------------------------------------------------- movement animations while the sword is drawn
-- Walking, running, jumping and falling use a Roblox-made animation pack (Roblox's own packs are free to use in
-- any experience). It's swapped into the character's Animate script when the sword is drawn and the avatar's own
-- animations come back when it's put away. Our coded walk layer is off while a pack is in use; the sword arm,
-- the standing stance, attacks, dodges and the guard are still ours. Pack = WeaponConfig MovementPack.
-- (Testing other packs: set the player attribute MovePackTest to a pack name, then draw the sword again.)
local MOVE_PACKS = {
	Knight = { walk = 657552124, run = 657564596, jump = 658409194, fall = 657600338 },
	Werewolf = { walk = 1083178339, run = 1083216690, jump = 1083218792, fall = 1083189019 },
	Vampire = { walk = 1083473930, run = 1083462077, jump = 1083455352, fall = 1083443587 },
	Elder = { walk = 845403856, run = 845386501, jump = 845398858, fall = 845396048 },
	Mage = { walk = 707897309, run = 707861613, jump = 707853694, fall = 707829716 },
	Rthro = { walk = 2510202577, run = 2510198475, jump = 2510197830, fall = 2510195892 },
	Superhero = { walk = 616122287, run = 616117076, jump = 616115533, fall = 616108001 },
	Stylish = { walk = 616146177, run = 616140816, jump = 616139451, fall = 616134815 },
}
local MOVE_SLOTS = { "walk", "run", "jump", "fall" }
local function movePackName(): string?
	local n = player:GetAttribute("MovePackTest") or cfg.MovementPack
	return if n and MOVE_PACKS[n] then n else nil
end
usingMovePack = function(): boolean
	return movePackName() ~= nil
end
local savedAnims = setmetatable({}, { __mode = "k" })
applyMovePack = function(character: Model, drawn: boolean)
	local animate = character:FindFirstChild("Animate")
	if not animate then
		return
	end
	local name = movePackName()
	local pack = name and MOVE_PACKS[name]
	local saved = savedAnims[character]
	if not saved then
		saved = {}
		savedAnims[character] = saved
	end
	for _, slot in ipairs(MOVE_SLOTS) do
		local folder = animate:FindFirstChild(slot)
		if folder then
			for _, anim in ipairs(folder:GetChildren()) do
				if anim:IsA("Animation") then
					if saved[anim] == nil then
						saved[anim] = anim.AnimationId -- the avatar's own animation, put back on sheathe
					end
					local want = if drawn and pack then "rbxassetid://" .. pack[slot] else saved[anim]
					if anim.AnimationId ~= want then
						anim.AnimationId = want
					end
				end
			end
		end
	end
end

---------------------------------------------------------------- per-frame driver
local function stepRig(r, dt: number)
	local equipped = r.character:GetAttribute("SwordEquipped") == true and r.grip.Part0 == r.hand
	if equipped ~= r.equipped then
		r.equipped = equipped
		if r.character == player.Character then
			applyMovePack(r.character, equipped)
		end
		setTrails(r, false)
		if equipped then
			r.move = buildMove(SHEATH, MOVES.Draw(), { kind = "Draw" })
			emberBurst(r, 18)
		elseif r.move and not (r.move.kind == "Dodge" or r.move.kind == "Backflip" or r.move.kind == "FlipLand") then
			r.move = nil
		end
		r.pose = CARRY
	end

	local root = r.hroot
	local vel = root.AssemblyLinearVelocity
	local speed = (vel * FLAT).Magnitude
	local grounded = math.abs(vel.Y) < 4
	local target = if r.hum.MoveDirection.Magnitude > 0.1 or speed > 3 then 1 else 0
	r.moveF += (target - r.moveF) * math.min(1, dt * 10)

	local m = r.move
	local pose = CARRY
	local mw, lw = 0, 0
	-- the fighting guard after an attack relaxes back to the shoulder carry once you stop attacking or start running
	if m and m.kind == "Guard" and (os.clock() > (r.guardUntil or 0) or speed > 19) then
		r.move = buildMove(r.pose, MOVES.Rest(), { kind = "Rest", layerName = "Guard", spline = true, blendOutFrom = 0.32 })
		m = r.move
	end
	if m then
		if r.freeze > 0 then
			r.freeze -= dt
		else
			m.t += dt
		end
		if m.strikeAt and not m.fired and m.t >= m.strikeAt then
			m.fired = true
			onStrike(r, m)
		end
		if m.plantAt and not m.planted and m.t >= m.plantAt then
			m.planted = true
			footPlant(r)
		end
		if m.hopAt and not m.hopped and m.t >= m.hopAt then
			m.hopped = true
			if r.character == player.Character and r.hum.FloorMaterial ~= Enum.Material.Air then
				local v = r.hroot.AssemblyLinearVelocity
				r.hroot.AssemblyLinearVelocity = V(v.X, 20, v.Z)
			end
		end
		if m.impactAt and not m.impacted and m.t >= m.impactAt then
			m.impacted = true
			onImpact(r, m)
		end
		if r.character == player.Character and (m.kind == "Light" or m.kind == "Heavy") and m.trailFrom and m.t >= m.trailFrom and m.t <= (m.trailTo or 0) + 0.03 then
			checkContact(r, m)
		end
		-- landings
		local mine = r.character == player.Character
		if m.kind == "Slam" and m.t > (m.fallFrom or 0) + 0.04 then
			if (mine and r.hum.FloorMaterial ~= Enum.Material.Air) or m.t > (m.fallFrom or 0) + cfg.Slam.MaxFall then
				slamLand(r, mine)
				m = r.move
			end
		elseif m.kind == "Backflip" and m.t > 0.2 then
			if (mine and r.hum.FloorMaterial ~= Enum.Material.Air) or (not mine and m.t > 0.55) or m.t > 1.6 then
				land(r)
				m = r.move
			end
		end
		pose = sample(m)
		if m.kind == "Guard" then
			-- breathing hard in the guard: shoulders heave, the hanging blade rises and falls
			local b = math.sin(os.clock() * 2.2)
			pose = table.clone(pose)
			pose.dip += 0.03 * b
			pose.lean += 2 * b
			pose.grip = pose.grip + V(0, 0.04 * b, 0)
		end
		mw = moveWeight(m)
		local L = m.layer
		lw = if L.lower == "full" then mw elseif L.lower == "heavy" then mw * math.max(0.6, 1 - r.moveF) elseif L.lower == "standing" then mw * (1 - r.moveF) else 0
		setTrails(r, equipped and m.trailFrom ~= nil and m.t >= m.trailFrom and m.t <= (m.trailTo or 0))
		if not m.hold and m.t >= m.length then
			setTrails(r, false)
			if m.toGuard and equipped then
				-- the combo flows straight back onto the shoulder
				r.move = buildMove(pose, MOVES.Rest(), { kind = "Rest", layerName = "Guard", spline = true, blendOutFrom = 0.32 })
			else
				r.move = nil
			end
		end
	elseif not equipped then
		r.pose = CARRY
		return
	end
	r.pose = pose

	-- BASE layers while drawn: berserker stance (standing) and greatsword walk/run (moving)
	local walkW, stanceW = 0, 0
	local wn, sn = nil, nil
	if equipped then
		if r.debugWalk or (grounded and r.moveF > 0.02 and not usingMovePack()) then
			local runF = if r.debugRun then r.debugRun else math.clamp((speed - 16) / 6, 0, 1)
			local stride = 7.5 + 2.5 * runF
			r.walkPhase = r.debugWalk or (r.walkPhase + dt * 2 * math.pi * math.max(speed, 4) / stride)
			wn = walkNumbers(r.walkPhase, runF)
			walkW = (if r.debugWalk then 1 else r.moveF) * (1 - lw)
		end
		if not r.debugWalk and grounded then
			sn = stanceNumbers(os.clock())
			stanceW = (1 - r.moveF) * (1 - lw)
		end
		if sn then
			lowerLayer(r, sn, stanceW)
			upperLayer(r, sn, stanceW * (1 - mw))
		end
		if wn then
			lowerLayer(r, wn, walkW)
			upperLayer(r, wn, walkW * (1 - mw))
		end
	end

	-- move layers
	lowerLayer(r, pose, lw)
	upperLayer(r, pose, mw)

	-- left arm: free pose (stance / walk swing / move pose) or on the hilt
	local ls, le, lwr = r.L.sh, r.L.el, r.L.wr
	for _, layer in ipairs({ { n = sn, w = stanceW }, { n = wn, w = walkW } }) do
		if layer.n and layer.w > 0 then
			local a, b, c = freeLeft(layer.n)
			blendJoint(ls, a, layer.w * (1 - mw))
			blendJoint(le, b, layer.w * (1 - mw))
			blendJoint(lwr, c, layer.w * (1 - mw))
		end
	end

	-- RIGHT ARM IK (+ left hand on the hilt), solved in the UpperTorso's actual frame this frame
	if equipped then
		local M = r.wA1 * r.waist.Transform:Inverse() * r.wA1:Inverse()
		local Mr = rotOf(M)
		local bounce = ((if wn then wn.bounce * walkW else 0) + (if sn then sn.bounce * stanceW else 0)) * (1 - mw)
		local sway = (if wn then wn.sway * walkW else 0) * (1 - mw)
		local B = unit(Mr * pose.blade)
		local E = perpTo(Mr * pose.edge, B)
		local Rs = CFrame.fromMatrix(Vector3.zero, E, B, E:Cross(B))
		local G = M * (r.R.S + pose.grip + V(sway, bounce, 0))
		local s1, e1, w1 = solveArm(r.R, G, Rs, Mr * pose.pole)
		r.R.sh.Transform = s1
		r.R.el.Transform = e1
		r.R.wr.Transform = w1
		if mw > 0.001 then
			local fa, fb, fc = freeLeft(pose)
			if pose.two > 0.01 then
				local s2, e2, w2 = solveArm(r.L, G - B * 0.55, Rs, Mr * V(-0.7, -0.4, 0.3))
				fa, fb, fc = fa:Lerp(s2, pose.two), fb:Lerp(e2, pose.two), fc:Lerp(w2, pose.two)
			end
			blendJoint(ls, fa, mw)
			blendJoint(le, fb, mw)
			blendJoint(lwr, fc, mw)
		end
	elseif mw > 0.001 then
		local fa, fb, fc = freeLeft(pose)
		blendJoint(ls, fa, mw)
		blendJoint(le, fb, mw)
		blendJoint(lwr, fc, mw)
	end
end

do -- head look: its locals stay inside this block (CombatClient is near the 200-local limit)
-- StarterPlayer.StarterPlayerScripts.Descent.CombatClient  (LocalScript)  -- map v4 change
-- This block REPLACES the old PreSimulation loop (the one that only called stepRig for every player).
-- In v3 that loop sat right before "---------------------------------------------------------------- playing moves".
-- Uses names already defined earlier in CombatClient: Players, RunService, Remotes, player, rigs, findRig, stepRig.

---------------------------------------------------------------- HEAD LOOK: the head turns toward where the camera looks
-- Local player: straight from the camera. Other players: from the character attributes HeadYaw / HeadPitch that
-- the server sets (HeadLook script + HeadLookRequest, ~10 per second). Applied on the Neck only, AFTER Roblox's
-- Animator and the sword layers, so it works sword drawn or sheathed. Toned down while a move plays; eases back
-- to centre when the camera swings round to the face; off in first person.
local HeadLookRequest: RemoteEvent = Remotes:WaitForChild("HeadLookRequest")
local HEAD = { MaxYaw = 70, MaxUp = 40, MaxDown = 35, FadeFrom = 110, FadeTo = 150, Speed = 10, MoveWeight = 0.35 }
local headState = {} -- [character] = { yaw, pitch, base, written }
local headSent = { t = 0, yaw = 999, pitch = 999 }
local headWarned = false
local function headTarget(ch: Model, root: BasePart): (number, number)
	if ch ~= player.Character then
		return ch:GetAttribute("HeadYaw") or 0, ch:GetAttribute("HeadPitch") or 0
	end
	local cam = workspace.CurrentCamera
	local head = ch:FindFirstChild("Head")
	local yaw, pitch = 0, 0
	if cam and head and (cam.CFrame.Position - head.Position).Magnitude > 1.5 then
		local d = root.CFrame:VectorToObjectSpace(cam.CFrame.LookVector)
		yaw = math.deg(math.atan2(-d.X, -d.Z))
		pitch = math.deg(math.asin(math.clamp(d.Y, -1, 1)))
		local fade = 1 - math.clamp((math.abs(yaw) - HEAD.FadeFrom) / (HEAD.FadeTo - HEAD.FadeFrom), 0, 1)
		yaw = math.clamp(yaw, -HEAD.MaxYaw, HEAD.MaxYaw) * fade
		pitch = math.clamp(pitch, -HEAD.MaxDown, HEAD.MaxUp) * fade
	end
	local t = os.clock()
	if t - headSent.t > 0.1 and (math.abs(yaw - headSent.yaw) > 2 or math.abs(pitch - headSent.pitch) > 2) then
		headSent.t, headSent.yaw, headSent.pitch = t, yaw, pitch
		HeadLookRequest:FireServer(math.floor(yaw + 0.5), math.floor(pitch + 0.5))
	end
	return yaw, pitch
end
local function headLook(ch: Model, dt: number)
	local root = ch:FindFirstChild("HumanoidRootPart")
	local head = ch:FindFirstChild("Head")
	local neck = head and head:FindFirstChild("Neck")
	local hum = ch:FindFirstChildOfClass("Humanoid")
	if not (root and neck and hum) or hum.Health <= 0 then
		headState[ch] = nil
		return
	end
	local s = headState[ch]
	if not s then
		s = { yaw = 0, pitch = 0 }
		headState[ch] = s
	end
	local ty, tp = headTarget(ch, root)
	local r = rigs[ch]
	if r and r.move then
		ty, tp = ty * HEAD.MoveWeight, tp * HEAD.MoveWeight
	end
	local a = 1 - math.exp(-HEAD.Speed * dt)
	s.yaw += (ty - s.yaw) * a
	s.pitch += (tp - s.pitch) * a
	-- if nothing else wrote the neck this frame, start again from last frame's base so the turn never stacks up
	local cur = neck.Transform
	local base = if s.written and cur == s.written then s.base else cur
	local out = CFrame.Angles(0, math.rad(s.yaw), 0) * CFrame.Angles(math.rad(s.pitch), 0, 0) * base
	neck.Transform = out
	s.base, s.written = base, out
end

RunService.PreSimulation:Connect(function(dt)
	for _, plr in ipairs(Players:GetPlayers()) do
		local ch = plr.Character
		local r = ch and findRig(ch)
		if r then
			local ok, err = pcall(stepRig, r, dt)
			if not ok then
				warn("[CombatClient] " .. tostring(err))
			end
		end
		if ch then
			local ok, err = pcall(headLook, ch, dt)
			if not ok and not headWarned then
				headWarned = true
				warn("[CombatClient] head look: " .. tostring(err))
			end
		end
	end
	for ch in pairs(headState) do
		if not ch.Parent then
			headState[ch] = nil
		end
	end
end)

end

---------------------------------------------------------------- playing moves
local function playAttack(character: Model, kind: string, step: number, w: number, s: number, rcv: number)
	local r = findRig(character)
	if not r or not r.equipped then
		return
	end
	local keys, meta
	if kind == "Light" then
		local fn = MOVES["L" .. tostring(step)]
		if not fn then
			return
		end
		keys = fn(w, s, rcv)
		meta = { kind = "Light", step = step, layerName = "LightFull", spline = true, toGuard = true, strikeAt = w, trailFrom = w - 0.02, trailTo = w + s + 0.08, plantAt = w + s + rcv * 0.3, impactAt = if step == 4 then w + s else nil, hopAt = if step == 4 then w * 0.55 else nil }
	elseif kind == "Heavy" then
		keys = MOVES.Heavy(w, s, rcv)
		meta = { kind = "Heavy", strikeAt = w, trailFrom = w - 0.02, trailTo = w + s + 0.1, blendOutFrom = w + s + rcv * 0.55, plantAt = w + s + rcv * 0.2 }
		r.chargeUntil = os.clock() + w
		emberBurst(r, 25)
	elseif kind == "Slam" then
		keys = MOVES.Slam(w)
		meta = { kind = "Slam", hold = true, fallFrom = w }
		if character == player.Character then
			startSlamFall(r.hroot, w)
		end
		emberBurst(r, 12)
		task.delay(w, function()
			sound(r.hroot, pick(SFX.SwordSwish), 0.72, 1.1)
			sound(r.hroot, pick(SFX.HeavyWhoosh), 0.6, 0.9)
		end)
	else
		return
	end
	r.freeze = 0
	r.move = buildMove(r.pose, keys, meta)
end

local function hitStop(character: Model, dur: number)
	local r = rigs[character]
	if r and r.move then
		r.freeze = math.max(r.freeze, dur)
	end
end

local function playDodge(character: Model, dir: Vector3?, isLocal: boolean)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	dir = dir or -flatLook(root)
	local r = findRig(character)
	if r then
		local d = root.CFrame:VectorToObjectSpace(dir)
		r.freeze = 0
		setTrails(r, false)
		r.move = buildMove(r.pose, MOVES.Dodge(-d.Z, d.X, cfg.Dodge.Duration), { kind = "Dodge", blendOutFrom = cfg.Dodge.Duration })
		if r.equipped then
			emberBurst(r, 6)
		end
	end
	sound(root, "rbxasset://sounds/swordlunge.wav", 1.35, 0.6) -- the original dodge sound
	burst(groundBelow(root.Position) + V(0, 0.4, 0), DASH_DUST, 14, 1)
	afterimages(character, 4, 0.055)
	if isLocal then
		fovKick(8)
	end
end

local function playBackflip(character: Model, isLocal: boolean)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local r = findRig(character)
	if r then
		r.freeze = 0
		setTrails(r, false)
		r.move = buildMove(r.pose, MOVES.Backflip(), { kind = "Backflip", hold = true })
		if r.equipped then
			emberBurst(r, 10)
		end
	end
	sound(root, "rbxasset://sounds/swordlunge.wav", 1.1, 0.7) -- the original dodge sound
	burst(groundBelow(root.Position) + V(0, 0.4, 0), DASH_DUST, 18, 1)
	afterimages(character, 5, 0.07)
	if isLocal then
		fovKick(10)
	end
end

---------------------------------------------------------------- ULTIMATE
local function ultAura(character: Model, dur: number)
	local torso = character:FindFirstChild("UpperTorso")
	local h = Instance.new("Highlight")
	h.FillColor = Color3.fromRGB(90, 0, 0)
	h.FillTransparency = 0.72
	h.OutlineColor = Color3.fromRGB(255, 40, 30)
	h.OutlineTransparency = 0.1
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.Parent = character
	Debris:AddItem(h, dur)
	if torso then
		local smoke = Instance.new("ParticleEmitter")
		smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
		smoke.Color = ColorSequence.new(Color3.fromRGB(120, 0, 0), Color3.fromRGB(10, 0, 0))
		smoke.Transparency = NumberSequence.new(0.35, 1)
		smoke.Size = NumberSequence.new(1.6, 4.2)
		smoke.Lifetime = NumberRange.new(0.6, 1.1)
		smoke.Rate = 45
		smoke.Speed = NumberRange.new(2, 5)
		smoke.SpreadAngle = Vector2.new(180, 180)
		smoke.Acceleration = V(0, 8, 0)
		smoke.LightEmission = 0.25
		smoke.RotSpeed = NumberRange.new(-90, 90)
		smoke.Parent = torso
		local flame = Instance.new("ParticleEmitter")
		flame.Texture = "rbxasset://textures/particles/fire_main.dds"
		flame.Color = ColorSequence.new(Color3.fromRGB(255, 60, 30), Color3.fromRGB(120, 0, 0))
		flame.LightEmission = 1
		flame.Size = NumberSequence.new(1.1, 0)
		flame.Lifetime = NumberRange.new(0.3, 0.6)
		flame.Rate = 35
		flame.Speed = NumberRange.new(3, 6)
		flame.SpreadAngle = Vector2.new(180, 180)
		flame.Acceleration = V(0, 10, 0)
		flame.Parent = torso
		task.delay(dur, function()
			smoke.Enabled = false
			flame.Enabled = false
			Debris:AddItem(smoke, 1.2)
			Debris:AddItem(flame, 1)
		end)
	end
end

local CRIMSON = Color3.fromRGB(205, 12, 10)
local HOT_WHITE = Color3.fromRGB(255, 240, 235)

-- impact frame: one blown-out white frame, one black-and-crimson frame, then the world bleeds back in
local impactCC = Instance.new("ColorCorrectionEffect")
impactCC.Name = "DescentImpactFrame"
impactCC.Enabled = false
impactCC.Parent = Lighting
local function impactFrame()
	impactCC.Enabled = true
	impactCC.TintColor = Color3.fromRGB(255, 228, 228)
	impactCC.Brightness = 0.55
	impactCC.Contrast = 1.2
	impactCC.Saturation = -1
	task.delay(0.05, function()
		impactCC.TintColor = Color3.fromRGB(255, 45, 35)
		impactCC.Brightness = -0.25
		impactCC.Contrast = 3
		impactCC.Saturation = -1
	end)
	task.delay(0.11, function()
		impactCC.TintColor = Color3.fromRGB(255, 160, 150)
		impactCC.Brightness = 0.08
		impactCC.Contrast = 0.4
		impactCC.Saturation = -0.3
		TweenService:Create(impactCC, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { TintColor = Color3.new(1, 1, 1), Brightness = 0, Contrast = 0, Saturation = 0 }):Play()
	end)
	task.delay(0.75, function()
		impactCC.Enabled = false
	end)
end

-- the world goes dark and blood-tinted while the ultimate builds (own screen only)
local ultDark = Instance.new("ColorCorrectionEffect")
ultDark.Name = "DescentUltDark"
ultDark.Parent = Lighting
local function ultDarken(dur: number)
	TweenService:Create(ultDark, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { TintColor = Color3.fromRGB(255, 175, 168), Brightness = -0.07, Contrast = 0.22 }):Play()
	task.delay(dur, function()
		TweenService:Create(ultDark, TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), { TintColor = Color3.new(1, 1, 1), Brightness = 0, Contrast = 0 }):Play()
	end)
end

-- cinema bars + manga focus lines (own screen only)
local function ultOverlay()
	local pg = player:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "DescentUltOverlay"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 50
	gui.Parent = pg
	for _, top in ipairs({ true, false }) do
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.BackgroundColor3 = Color3.new(0, 0, 0)
		f.AnchorPoint = Vector2.new(0, if top then 0 else 1)
		f.Position = UDim2.fromScale(0, if top then 0 else 1)
		f.Size = UDim2.fromScale(1, 0)
		f.Parent = gui
		TweenService:Create(f, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.fromScale(1, 0.11) }):Play()
		task.delay(2.05, function()
			TweenService:Create(f, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Size = UDim2.fromScale(1, 0) }):Play()
		end)
	end
	local lines = {}
	for i = 1, 48 do
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Visible = false
		f.Parent = gui
		lines[i] = f
	end
	local t0 = os.clock()
	local lastDraw = 0
	local conn
	conn = RunService.RenderStepped:Connect(function()
		local t = os.clock() - t0
		if t > 2.45 then
			conn:Disconnect()
			gui:Destroy()
			return
		end
		if not (t > 0.8 and t < 1.8) then
			for _, f in ipairs(lines) do
				f.Visible = false
			end
			return
		end
		if t - lastDraw < 0.045 then
			return
		end
		lastDraw = t
		local vs = workspace.CurrentCamera.ViewportSize
		local cx, cy = vs.X / 2, vs.Y / 2
		local half = math.sqrt(cx * cx + cy * cy)
		for _, f in ipairs(lines) do
			local a = math.random() * math.pi * 2
			local len = half * (0.3 + math.random() * 0.4)
			local mid = half * (0.45 + math.random() * 0.2) + len / 2
			f.Visible = true
			f.Position = UDim2.fromOffset(cx + math.cos(a) * mid, cy + math.sin(a) * mid)
			f.Size = UDim2.fromOffset(len, 2 + math.random() * 4)
			f.Rotation = math.deg(a)
			f.BackgroundColor3 = if t > 1.38 then Color3.fromRGB(255, 60, 50) else Color3.new(1, 1, 1)
			f.BackgroundTransparency = 0.15 + math.random() * 0.5
		end
	end)
end

-- everything round the warrior from the roar to the top of the leap (every viewer sees it)
local function ultSpectacle(r, isLocal: boolean)
	local root = r.hroot
	local ch = r.character
	local function alive()
		return ch.Parent ~= nil and root.Parent ~= nil
	end
	local function torso(): Vector3
		local t = ch:FindFirstChild("UpperTorso")
		return if t then t.Position else root.Position
	end
	-- 1) the roar: crimson lightning crackles off the body, pulses of force roll off the floor
	task.spawn(function()
		local t0 = os.clock()
		while alive() and os.clock() - t0 < 0.6 do
			local c = torso()
			local a = unit(V(math.random() - 0.5, math.random() - 0.25, math.random() - 0.5))
			bolt(c + a * 1.1, c + a * (3.5 + math.random() * 3), CRIMSON, 0.11, 0.07)
			task.wait(0.04)
		end
	end)
	for i = 0, 4 do
		task.delay(i * 0.11, function()
			if alive() then
				groundRing(groundBelow(root.Position) + V(0, 0.15, 0), 1, 6 + i * 1.5, 0.38, 0.5, CRIMSON, 1)
			end
		end)
	end
	-- 2) the leap: the floor cracks and a blast ring goes out under the feet
	task.delay(0.55, function()
		if not alive() then
			return
		end
		local g = groundBelow(root.Position)
		groundRing(g + V(0, 0.18, 0), 1, 12, 0.4, 1.0, HOT_WHITE, 1)
		groundRing(g + V(0, 0.14, 0), 1, 16, 0.6, 1.8, CRIMSON, 1)
		radialBurst(g + V(0, 0.3, 0), 16, 1, 10, 0.32, HOT_WHITE, 0.5, true)
		cracks(g + V(0, 0.07, 0), 7, 4, Color3.fromRGB(255, 90, 35), 1.8)
		burst(g + V(0, 0.4, 0), DUST, 30, 2)
		afterimages(ch, 6, 0.05)
		if r.sword then
			local hl = Instance.new("Highlight")
			hl.FillColor = CRIMSON
			hl.FillTransparency = 0.3
			hl.OutlineColor = HOT_WHITE
			hl.OutlineTransparency = 0
			hl.DepthMode = Enum.HighlightDepthMode.Occluded
			hl.Adornee = r.sword
			hl.Parent = r.sword
			Debris:AddItem(hl, 1.15)
		end
		if isLocal then
			shake(0.8, 0.2)
		end
	end)
	-- 3) hanging at the top: a burning halo behind the warrior, crescents spiralling round, lightning hits the blade
	task.delay(0.8, function()
		if not alive() then
			return
		end
		local halo = makeArc(CFrame.new(), 0, math.pi * 2, CRIMSON, 1, true)
		local haloCore = makeArc(CFrame.new(), 0, math.pi * 2, HOT_WHITE, 1, true)
		local spirals = {}
		for i = 1, 3 do
			spirals[i] = makeArc(CFrame.new(), 0, math.pi * 1.25, if i == 2 then HOT_WHITE else CRIMSON, 1, true)
		end
		local t0 = os.clock()
		local lastBolt = 0
		local conn
		conn = RunService.Heartbeat:Connect(function()
			local t = os.clock() - t0
			if t > 0.62 or not alive() then
				conn:Disconnect()
				halo.destroy()
				haloCore.destroy()
				for _, sp in ipairs(spirals) do
					sp.destroy()
				end
				return
			end
			local c = torso()
			local toCam = unit(workspace.CurrentCamera.CFrame.Position - c, V(0, 0, 1))
			local right = unit(toCam:Cross(Vector3.yAxis), V(1, 0, 0))
			local up = right:Cross(toCam)
			local grow = math.min(1, t / 0.12)
			local pulse = 1 + 0.07 * math.sin(t * 45)
			halo.c = planeCF(c - toCam * 1.6, right, up)
			haloCore.c = halo.c
			halo.set(4.4 * grow * pulse, function()
				return 1.1
			end, 0.05 + 0.4 * t / 0.62)
			haloCore.set(4.4 * grow * pulse, function()
				return 0.35
			end, 0.1 * t / 0.62)
			for i, sp in ipairs(spirals) do
				sp.c = CFrame.new(c + V(0, -1.6 + i * 1.1, 0)) * CFrame.Angles(0, t * 16 + i * 2.1, 0)
				sp.set(3.3 - i * 0.35, function(f)
					return 0.6 * math.max(0.05, math.sin(math.pi * f)) ^ 0.7
				end, 0.1)
			end
			if t - lastBolt > 0.07 then
				lastBolt = t
				local blade = r.sword and r.sword:FindFirstChild("Blade")
				local tip = blade and blade:FindFirstChild("TrailTip")
				local p = if tip then tip.WorldPosition else c + V(0, 3, 0)
				bolt(p, p + V((math.random() - 0.5) * 10, 16 + math.random() * 8, (math.random() - 0.5) * 10), CRIMSON, 0.14, 0.07)
			end
		end)
	end)
	-- 4) coming down: a huge crescent carved by the blade
	task.delay(cfg.Ultimate.Impact - 0.1, function()
		if alive() then
			slamArc(r, 1.8)
		end
	end)
end

local function ultImpactFX(r, mine: boolean)
	local root = r.hroot
	local impact = groundBelow(root.Position) + flatLook(root) * 3
	if mine then
		impactFrame()
		r.freeze = math.max(r.freeze, 0.15)
	end
	floorCrack(impact, 3)
	cracks(impact + V(0, 0.08, 0), 12, 13, Color3.fromRGB(255, 80, 30), 3)
	-- rings: white-hot first, then crimson, a late wide one, and a dark haze under them all
	groundRing(impact + V(0, 0.22, 0), 1, 20, 0.45, 2.2, HOT_WHITE, 1)
	groundRing(impact + V(0, 0.18, 0), 1, 26, 0.7, 3.4, CRIMSON, 1)
	task.delay(0.12, function()
		groundRing(impact + V(0, 0.16, 0), 1, 34, 0.9, 2.6, Color3.fromRGB(140, 0, 0), 1)
	end)
	task.delay(0.04, function()
		groundRing(impact + V(0, 0.1, 0), 1, 22, 1.3, 5, Color3.fromRGB(22, 8, 8), 0)
	end)
	-- shock rings climbing the blast
	for i = 1, 3 do
		task.delay(i * 0.06, function()
			groundRing(impact + V(0, 1.5 + i * 2.2, 0), 1, 9 + i * 3, 0.45, 0.7, if i == 2 then HOT_WHITE else CRIMSON, 1)
		end)
	end
	radialBurst(impact + V(0, 0.5, 0), 34, 2, 24, 0.42, HOT_WHITE, 0.9, true)
	-- energy dome: a saturated crimson ForceField shell round a smaller neon core that burns out first
	for _, spec in ipairs({ { Enum.Material.Neon, Color3.fromRGB(230, 20, 15), 14, 0.24 }, { Enum.Material.ForceField, Color3.fromRGB(235, 0, 0), 28, 0.65 } }) do
		local b = Instance.new("Part")
		b.Shape = Enum.PartType.Ball
		b.Material = spec[1]
		b.Color = spec[2]
		b.Anchored, b.CanCollide, b.CanQuery, b.CanTouch, b.CastShadow = true, false, false, false, false
		b.Size = Vector3.one * 2
		b.CFrame = CFrame.new(impact + V(0, 1, 0))
		b.Transparency = 0.1
		b.Parent = fxFolder
		TweenService:Create(b, TweenInfo.new(spec[4], Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.one * spec[3], Transparency = 1 }):Play()
		Debris:AddItem(b, spec[4] + 0.05)
	end
	-- a pillar of crimson light punched into the sky
	do
		local A0, A1 = newAtt(), newAtt()
		A0.WorldPosition = impact
		A1.WorldPosition = impact + V(0, 80, 0)
		local glow = newBeam(A0, A1, CRIMSON, 1, true)
		local core = newBeam(A0, A1, HOT_WHITE, 1, true)
		animate(0.6, function(x)
			local e = 1 - EASE.outCubic(x)
			glow.Width0, glow.Width1 = 9 * e, 5 * e
			core.Width0, core.Width1 = 3 * e, 1.5 * e
			glow.Transparency = NumberSequence.new(0.1 + 0.6 * x)
		end, function()
			glow:Destroy()
			core:Destroy()
			A0:Destroy()
			A1:Destroy()
		end)
	end
	-- lightning crawling over the crater for a second
	task.spawn(function()
		for _ = 1, 24 do
			local a = math.random() * math.pi * 2
			local R = 4 + math.random() * 15
			bolt(impact + V(0, 0.4, 0), impact + V(math.cos(a) * R, 0.3 + math.random() * 3, math.sin(a) * R), CRIMSON, 0.14, 0.06)
			task.wait(0.045)
		end
	end)
	local la = fxAnchor(impact + V(0, 3, 0))
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 40, 20)
	light.Brightness = 4
	light.Range = 40
	light.Parent = la
	TweenService:Create(light, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Brightness = 0 }):Play()
	Debris:AddItem(la, 3)
	burst(impact + V(0, 0.5, 0), DEBRIS, 80, 1.6)
	burst(impact + V(0, 0.5, 0), DUST, 60, 2.4)
	burst(impact + V(0, 0.8, 0), EMBERS, 70, 2.2)
	-- a column of dark smoke rolling up out of the crater (no glow on the black)
	burst(impact + V(0, 1, 0), {
		Texture = "rbxasset://textures/particles/smoke_main.dds",
		Color = ColorSequence.new(Color3.fromRGB(45, 22, 20), Color3.fromRGB(20, 12, 12)),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 1) }),
		Size = NumberSequence.new(3, 10),
		Lifetime = NumberRange.new(1.2, 2.2),
		Speed = NumberRange.new(10, 24),
		SpreadAngle = Vector2.new(22, 22),
		EmissionDirection = Enum.NormalId.Top,
		Drag = 1.6,
		LightEmission = 0,
		RotSpeed = NumberRange.new(-50, 50),
	}, 36, 3)
	sound(la, "rbxasset://sounds/impact_explosion_03.mp3", 0.8, 1.3)
	sound(la, pick(SFX.RockImpact), 0.75, 2)
	sound(la, pick(SFX.SwordClang), 0.65, 1)
	sound(if mine then nil else la, pick(SFX.Boom), 0.8, 1.6, 5)
	sound(if mine then nil else la, SFX.Quake, 0.9, 1.1, 5)
	sound(if mine then nil else la, SFX.MagicBurst, 0.75, 1, 4)
	emberBurst(r, 40)
end

-- your own body during the ultimate: crouch, leap, hang at the top, hammer down
local function ultPhysics(r)
	local root, hum = r.hroot, r.hum
	lockRotate(hum, cfg.Ultimate.Duration + 0.1)
	task.delay(0.55, function()
		hum:ChangeState(Enum.HumanoidStateType.Jumping)
		root.AssemblyLinearVelocity = V(0, 55, 0)
	end)
	task.delay(0.83, function()
		hang(root, 0.4)
	end)
	task.delay(1.23, function()
		local hv = root:FindFirstChild("DescentHangVel")
		if hv then
			hv:Destroy()
		end
		root.AssemblyLinearVelocity = V(0, -120, 0)
	end)
end

-- the cinematic camera: face close-up -> low angle -> rising orbit (slowed, desaturated) -> overhead dive ->
-- wide impact shot with heavy shake -> glide back to the normal camera
local ultBlur = Instance.new("BlurEffect")
ultBlur.Size = 0
ultBlur.Parent = Lighting
local ultGrade = Instance.new("ColorCorrectionEffect")
ultGrade.Name = "DescentUltGrade"
ultGrade.Parent = Lighting

local function ultCamera(r)
	local cam = workspace.CurrentCamera
	local root = r.hroot
	local base = CFrame.lookAt(root.Position, root.Position + flatLook(root))
	local function rel(x, y, z)
		return (base * CFrame.new(x, y, z)).Position
	end
	local function headPos()
		local h = r.character:FindFirstChild("Head")
		return if h then h.Position else root.Position
	end
	local shots = {
		{ 0.0, 0.4, rel(1.2, 1.4, -4.2), rel(1.6, 1.0, -3.4), headPos, 55, 45 },
		{ 0.4, 0.62, rel(5, -0.6, -2.5), rel(4.5, -0.4, -2.2), function() return root.Position + V(0, 1, 0) end, 62, 60 },
		{ 0.62, 1.25, rel(7, 1.5, 3), rel(5, 9, 7), function() return root.Position end, 58, 50 },
		{ 1.25, 1.4, rel(0.5, 13, 9), rel(0.5, 11, 8), function() return rel(0, -2.5, -3) end, 75, 80 },
		{ 1.4, 2.0, rel(10, 4.5, -9), rel(12, 5.5, -11), function() return rel(0, -1.5, -3) end, 85, 70 },
	}
	local prevType, prevFov = cam.CameraType, cam.FieldOfView
	local t0 = os.clock()
	local finalCF
	cam.CameraType = Enum.CameraType.Scriptable
	RunService:BindToRenderStep("DescentUltCam", Enum.RenderPriority.Camera.Value + 1, function()
		local t = os.clock() - t0
		local cf, fov
		for _, sh in ipairs(shots) do
			if t >= sh[1] and t < sh[2] then
				local x = EASE.inOutSine((t - sh[1]) / (sh[2] - sh[1]))
				cf = CFrame.lookAt(sh[3]:Lerp(sh[4], x), sh[5]())
				fov = sh[6] + (sh[7] - sh[6]) * x
			end
		end
		if not cf then
			-- glide back behind the shoulder, then hand the camera back
			finalCF = finalCF or cam.CFrame
			local x = math.clamp((t - 2.0) / 0.35, 0, 1)
			local back = CFrame.lookAt(root.Position - flatLook(root) * 11 + V(0, 5, 0), root.Position + V(0, 1.5, 0))
			cf = finalCF:Lerp(back, EASE.inOutSine(x))
			fov = 70 + (prevFov - 70) * x
			if x >= 1 then
				RunService:UnbindFromRenderStep("DescentUltCam")
				cam.CameraType = prevType
				cam.FieldOfView = prevFov
				return
			end
		end
		-- impact shake
		if t > 1.38 and t < 2.0 then
			local k = 1.6 * (1 - (t - 1.38) / 0.62)
			cf = cf * CFrame.new((math.random() - 0.5) * k, (math.random() - 0.5) * k, 0)
		end
		cam.CFrame = cf
		cam.FieldOfView = fov
		-- slow-motion grade while hanging at the top
		local slow = if t > 0.8 and t < 1.3 then 1 else 0
		ultBlur.Size += (slow * 6 - ultBlur.Size) * 0.25
		ultGrade.Saturation += (slow * -0.6 - ultGrade.Saturation) * 0.25
		ultGrade.TintColor = Color3.new(1, 1 - slow * 0.15, 1 - slow * 0.15)
	end)
end

local function playUltimate(character: Model, isLocal: boolean)
	local r = findRig(character)
	if not r then
		return
	end
	r.freeze = 0
	setTrails(r, false)
	r.move = buildMove(r.pose, MOVES.Ultimate(), { kind = "Ultimate", blendOutFrom = 1.95, trailFrom = 0.85, trailTo = 1.5 })
	r.chargeUntil = os.clock() + cfg.Ultimate.Duration
	ultAura(character, cfg.Ultimate.Duration)
	ultSpectacle(r, isLocal)
	sound(r.hroot, pick(SFX.HeavyWhoosh), 0.45, 1)
	task.delay(0.55, function()
		sound(r.hroot, "rbxasset://sounds/swordlunge.wav", 0.7, 0.9)
	end)
	local ultBuild = sound(if isLocal then nil else r.hroot, SFX.LightSuck, 1, 0.9, 3)
	ultBuild.TimePosition = math.max(0, 2.47 - cfg.Ultimate.Impact)
	if isLocal then
		ultPhysics(r)
		ultCamera(r)
		ultOverlay()
		ultDarken(1.9)
	end
	task.delay(cfg.Ultimate.Impact - 0.02, function()
		ultImpactFX(r, isLocal)
	end)
end

---------------------------------------------------------------- TELEKINESIS "Grave Grasp" (G)
-- From the Blender demo (the descend\telekinesis-demo), cut down from 6.5 s to ~1.9 s for play. The free LEFT hand
-- rises, broken rune rings open on the floor, real rock meshes (ReplicatedStorage.Descent.VFX.Rocks) tear up out of
-- it and orbit in front with crimson motes and a tendril to the hand; the cluster tightens, the hand draws back and
-- thrusts, the rocks are hurled at the target and it craters. The sword stays on the shoulder throughout.
local TKC = cfg.Telekinesis
local ROCK_TEMPLATES = Descent:FindFirstChild("VFX") and Descent.VFX:FindFirstChild("Rocks")
local function smooth01(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end
local function tkRock(i: number): BasePart
	local list = if ROCK_TEMPLATES then ROCK_TEMPLATES:GetChildren() else {}
	local p
	if #list > 0 then
		p = list[(i - 1) % #list + 1]:Clone()
	else
		p = Instance.new("Part")
		p.Shape = Enum.PartType.Ball
		p.Material = Enum.Material.Basalt
		p.Color = Color3.fromRGB(46, 40, 42)
		p.Size = V(1.2, 1.2, 1.2)
	end
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
	p.Size = p.Size * (0.8 + math.random() * 0.7)
	return p
end
local function glowBall(size: number, color: Color3): Part
	local b = Instance.new("Part")
	b.Shape = Enum.PartType.Ball
	b.Material = Enum.Material.Neon
	b.Color = color
	b.Anchored, b.CanCollide, b.CanQuery, b.CanTouch, b.CastShadow = true, false, false, false, false
	b.Size = Vector3.one * size
	return b
end

playTelekinesis = function(character: Model, isLocal: boolean)
	local hold = { target = nil }
	tkHolds[character] = hold
	local target = Vector3.zero -- where the rocks land: decided at the throw
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local r = findRig(character)
	if r then
		r.freeze = 0
		setTrails(r, false)
		r.move = buildMove(r.pose, MOVES.Telekinesis(), { kind = "Telekinesis", spline = true, blendOutFrom = 1.6 })
	end
	local function alive()
		return character.Parent ~= nil and root.Parent ~= nil
	end
	local lhand = character:FindFirstChild("LeftHand") or character:FindFirstChild("Left Arm") or root
	-- the cluster hangs in front of the warrior at chest height and moves with them
	local function center(): Vector3
		return root.Position + flatLook(root) * 3.4 + V(0, 1.1, 0)
	end
	local floorY = groundBelow(center()).Y
	local model = Instance.new("Model")
	model.Name = "GraveGrasp"
	model.Parent = fxFolder
	-- the curse burns in the cracks: one crimson rim light over all the rocks
	local hl = Instance.new("Highlight")
	hl.FillColor = Color3.fromRGB(150, 10, 6)
	hl.FillTransparency = 0.8
	hl.OutlineColor = Color3.fromRGB(255, 60, 35)
	hl.OutlineTransparency = 0.15
	hl.DepthMode = Enum.HighlightDepthMode.Occluded
	hl.Parent = model

	local c0 = center()
	local rocks = {}
	local N = 7
	for i = 1, N do
		local p = tkRock(i)
		local a = (i / N) * math.pi * 2 + (math.random() - 0.5) * 0.6
		local dist = 1.2 + math.random() * 1.1
		local start = V(c0.X + math.cos(a) * dist, floorY + p.Size.Y * 0.35, c0.Z + math.sin(a) * dist)
		p.CFrame = CFrame.new(start - V(0, p.Size.Y, 0))
		p.Parent = model
		local a0 = Instance.new("Attachment")
		a0.Position = V(0, p.Size.Y * 0.3, 0)
		a0.Parent = p
		local a1 = Instance.new("Attachment")
		a1.Position = V(0, -p.Size.Y * 0.3, 0)
		a1.Parent = p
		local tr = Instance.new("Trail")
		tr.Attachment0, tr.Attachment1 = a0, a1
		tr.Color = ColorSequence.new(Color3.fromRGB(255, 90, 50), Color3.fromRGB(140, 0, 0))
		tr.LightEmission = 1
		tr.LightInfluence = 0
		tr.Lifetime = 0.18
		tr.FaceCamera = true
		tr.Transparency = NumberSequence.new(0.15, 1)
		tr.WidthScale = NumberSequence.new(1, 0)
		tr.Enabled = false
		tr.Parent = p
		rocks[i] = {
			p = p, a = a, start = start, d = (i - 1) * 0.045, trail = tr,
			r = 1.3 + math.random() * 0.9, w = 1.7 + math.random() * 1.1, h = -0.7 + math.random() * 1.5,
			spin = V(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 7,
			off = V((math.random() - 0.5) * 4, 0.4 + math.random() * 1.4, (math.random() - 0.5) * 4),
		}
	end
	-- motes orbiting the cluster
	local motes = {}
	for i = 1, 14 do
		local m = glowBall(0.16, if i % 3 == 0 then Color3.fromRGB(255, 150, 90) else Color3.fromRGB(255, 50, 30))
		m.Parent = model
		motes[i] = { p = m, a = math.random() * math.pi * 2, r = 0.6 + math.random() * 2, w = (2.5 + math.random() * 2) * (if math.random() < 0.5 then -1 else 1), h = -0.9 + math.random() * 2, ph = math.random() * 6 }
	end
	-- broken rune rings on the floor under the cluster, turning opposite ways
	local rings = {}
	for n, R in ipairs({ 2.8, 2.15, 1.45 }) do
		for k = 0, 2 do
			local a0 = k * (2 * math.pi / 3)
			table.insert(rings, { arc = makeArc(CFrame.new(c0), a0, a0 + math.pi * 0.52, HIT_RED, 1, true), R = R, n = n })
		end
	end
	-- tendril hand -> cluster, a glowing orb in the hand, light in the cluster
	local handAtt = Instance.new("Attachment")
	handAtt.Parent = lhand
	local cAtt = newAtt()
	local tendril = newBeam(handAtt, cAtt, Color3.fromRGB(255, 70, 40), 1, true)
	tendril.Segments = 12
	tendril.CurveSize0, tendril.CurveSize1 = 0.8, -0.6
	local orb = glowBall(0.1, Color3.fromRGB(255, 130, 90))
	orb.Parent = model
	local orbLight = Instance.new("PointLight")
	orbLight.Color = Color3.fromRGB(255, 50, 30)
	orbLight.Range = 8
	orbLight.Brightness = 2
	orbLight.Parent = orb
	local clusterLight = Instance.new("PointLight")
	clusterLight.Color = Color3.fromRGB(255, 50, 30)
	clusterLight.Range = 14
	clusterLight.Brightness = 0
	local lightAnchor = fxAnchor(c0)
	clusterLight.Parent = lightAnchor

	sound(root, SFX.EarthRumble, 0.9, 1.1, 4) -- the floor groans as it gives up the rocks
	sound(root, pick(SFX.DirtHit), 0.6, 0.9)
	local t0 = os.clock()
	local lastT = 0
	local launched, impacted, cleaned = false, false, false
	local conn
	local function cleanup()
		if cleaned then
			return
		end
		cleaned = true
		conn:Disconnect()
		if tkHolds[character] == hold then
			tkHolds[character] = nil
		end
		if isLocal and not launched then
			tkHolding = false
		end
		for _, rg in ipairs(rings) do
			rg.arc.destroy()
		end
		tendril:Destroy()
		cAtt:Destroy()
		handAtt:Destroy()
		lightAnchor:Destroy()
		model:Destroy()
	end
	local decidedAt = nil
	local function decide(tg: Vector3)
		decidedAt = os.clock()
		target = tg
		for _, rk in ipairs(rocks) do
			rk.landing = tg + rk.off
		end
		if tkHolds[character] == hold then
			tkHolds[character] = nil
		end
	end
	conn = RunService.Heartbeat:Connect(function()
		local real = os.clock() - t0
		-- HOLD: the timeline waits at HoldAt (rocks gathered tight, arm coiled) until the throw. The local player
		-- throws on letting go of G (or when MaxHold runs out); everyone else gets the throw from the server.
		if not decidedAt and real >= TKC.HoldAt then
			if isLocal then
				if tkReleaseWanted or real >= TKC.HoldAt + TKC.MaxHold then
					decide(tkThrowLocal(character))
				end
			elseif hold.target then
				decide(hold.target)
			elseif real > TKC.HoldAt + TKC.MaxHold + 3 then
				cleanup()
				return
			end
		end
		if not decidedAt and r and r.move and r.move.kind == "Telekinesis" and r.move.t > TKC.HoldAt then
			r.move.t = TKC.HoldAt -- the body stays coiled while the rocks are held
		end
		local t = if decidedAt then TKC.HoldAt + (os.clock() - decidedAt) else math.min(real, TKC.HoldAt)
		local ta = real -- free-running clock: orbits, spins and pulses keep going while held
		local dt = real - lastT
		lastT = real
		if not alive() or t > 2.9 then
			cleanup()
			return
		end
		local c = center()
		local f = flatLook(root)
		local right = f:Cross(Vector3.yAxis)
		local held = smooth01((t - 0.35) / 0.25) * (1 - smooth01((t - TKC.Launch + 0.05) / 0.12))
		-- rune rings
		for _, rg in ipairs(rings) do
			local on = smooth01((t - 0.05 - rg.n * 0.07) / 0.3) * (1 - smooth01((t - TKC.Launch) / 0.2))
			rg.arc.c = CFrame.new(V(c.X, floorY + 0.12, c.Z)) * CFrame.Angles(0, ta * (if rg.n % 2 == 1 then 1.6 else -2.1), 0)
			rg.arc.set(math.max(0.05, rg.R * on), function()
				return 0.14
			end, 1 - 0.9 * on)
		end
		-- rocks: emerge -> lift -> orbit (tightening) -> hurled -> scatter and fade
		for _, rk in ipairs(rocks) do
			local p
			if t < TKC.Launch then
				local tight = smooth01((t - 0.95) / 0.25)
				local ang = rk.a + rk.w * ta
				local rad = rk.r * (1 - 0.6 * tight)
				local orbit = c + right * math.cos(ang) * rad + f * math.sin(ang) * rad * 0.8 + V(0, rk.h * (1 - 0.5 * tight) + 0.12 * math.sin(ta * 9 + rk.a * 3), 0)
				local emerge = smooth01((t - rk.d) / 0.15)
				local lift = smooth01((t - 0.15 - rk.d) / 0.5)
				local ground = rk.start - V(0, rk.p.Size.Y * (1 - emerge), 0)
				if not rk.torn and t > 0.12 + rk.d then
					rk.torn = true
					burst(V(rk.start.X, floorY + 0.3, rk.start.Z), DASH_DUST, 6, 0.8)
					burst(V(rk.start.X, floorY + 0.3, rk.start.Z), DEBRIS, 5, 0.8)
				end
				p = ground:Lerp(orbit, lift)
				if lift > 0 and lift < 1 then
					p += V(math.random() - 0.5, 0, math.random() - 0.5) * 0.12 * (1 - lift)
				end
				rk.p0 = p
			elseif t < TKC.Hit then
				rk.trail.Enabled = true
				local x = (t - TKC.Launch) / (TKC.Hit - TKC.Launch)
				p = rk.p0:Lerp(rk.landing, x * x * (1.6 - 0.6 * x))
			else
				if not rk.vel then
					rk.vel = V((math.random() - 0.5) * 18, 10 + math.random() * 14, (math.random() - 0.5) * 18)
					rk.pos = rk.landing
				end
				if t > TKC.Hit + 0.12 then
					rk.trail.Enabled = false
				end
				rk.vel += V(0, -80 * dt, 0)
				rk.pos += rk.vel * dt
				local gy = target.Y + rk.p.Size.Y * 0.4
				if rk.pos.Y < gy then
					rk.pos = V(rk.pos.X, gy, rk.pos.Z)
					rk.vel = rk.vel * V(0.45, -0.3, 0.45)
				end
				p = rk.pos
				rk.p.Transparency = smooth01((t - 2.15) / 0.6)
			end
			rk.p.CFrame = CFrame.new(p) * CFrame.fromEulerAnglesXYZ(rk.spin.X * ta, rk.spin.Y * ta, rk.spin.Z * ta)
		end
		-- motes
		for _, m in ipairs(motes) do
			local on = smooth01((t - 0.4) / 0.25) * (1 - smooth01((t - TKC.Launch + 0.05) / 0.12))
			local ang = m.a + m.w * ta
			local rad = m.r * (1 - 0.5 * smooth01((t - 0.95) / 0.25))
			m.p.CFrame = CFrame.new(c + right * math.cos(ang) * rad + f * math.sin(ang) * rad * 0.8 + V(0, m.h + 0.2 * math.sin(ta * 7 + m.ph), 0))
			m.p.Size = Vector3.one * math.max(0.02, 0.16 * on * (0.7 + 0.5 * math.sin(ta * 13 + m.ph)))
			m.p.Transparency = 1 - on
		end
		-- tendril, hand orb, cluster light
		cAtt.WorldPosition = c
		local flick = 0.7 + 0.5 * math.abs(math.sin(t * 40))
		tendril.Width0 = 0.22 * held * flick
		tendril.Width1 = 0.1 * held * flick
		tendril.Transparency = NumberSequence.new(1 - held * 0.85)
		local orbOn = smooth01((t - 0.25) / 0.15) * (1 - smooth01((t - 1.6) / 0.25))
		local swell = if math.abs(t - TKC.Launch) < 0.1 then 1.7 else 1
		orb.CFrame = CFrame.new(handAtt.WorldPosition)
		orb.Size = Vector3.one * math.max(0.02, 0.55 * orbOn * swell * (0.85 + 0.2 * math.sin(ta * 20)))
		orb.Transparency = 1 - orbOn
		orbLight.Brightness = 2 * orbOn
		lightAnchor.CFrame = CFrame.new(c)
		clusterLight.Brightness = 2.5 * held
		-- the throw
		if not launched and t >= TKC.Launch then
			launched = true
			sound(root, pick(SFX.HeavyWhoosh), 0.6, 1)
			sound(root, pick(SFX.SwordSwish), 0.7, 0.6)
			radialBurst(handAtt.WorldPosition, 10, 0.3, 3, 0.18, HOT_WHITE, 0.25, false)
			if isLocal then
				fovKick(10)
				shake(0.4, 0.15)
			end
		end
		-- the landing
		if not impacted and t >= TKC.Hit then
			impacted = true
			local g = groundBelow(target + V(0, 2, 0))
			craterSlam(g, 1.15, isLocal)
			groundRing(g + V(0, 0.2, 0), 1, 12, 0.4, 1.1, HOT_WHITE, 1)
			local fl = glowBall(1, HOT_WHITE)
			fl.CFrame = CFrame.new(g + V(0, 1.2, 0))
			fl.Parent = fxFolder
			TweenService:Create(fl, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.one * 7, Transparency = 1, Color = CRIMSON }):Play()
			Debris:AddItem(fl, 0.25)
			local flA = fxAnchor(g)
			Debris:AddItem(flA, 3)
			sound(flA, "rbxasset://sounds/impact_explosion_03.mp3", 1.15, 0.8)
		end
	end)
end

---------------------------------------------------------------- DIVINE VERDICT (Z)
-- From the Blender study (the descend\vfx\divine_verdict), cut to ~3 s for play. A god's judgment strike: a sigil draws
-- itself in the sky over the target and a matching one on the floor, curtains of golden light fall between them, and a
-- colossal spectral Gravecleaver of light (the real sword mesh, scaled up and made of light) slides out of the sky sigil
-- and drops, impaling the ground. Then: flash, pillar of light, star glare, golden shockwaves, standing halos blown
-- outward, a flash dome, ember-gold cracks, flying slabs, feathers of light, and gyroscope halos orbiting the buried
-- blade. Gold / white-hot palette, ember-red only at the cracks.
local VC = cfg.Verdict
local GOLD_LIGHT = Color3.fromRGB(255, 214, 140)
local GOLD_HOT = Color3.fromRGB(255, 244, 222)
local verdictCC = Instance.new("ColorCorrectionEffect")
verdictCC.Name = "DescentVerdictGrade"
verdictCC.Parent = Lighting
-- the Blender look: the world goes dark round the cast so the gold blazes, with bloom on the hottest light
local verdictBloom = Instance.new("BloomEffect")
verdictBloom.Name = "DescentVerdictBloom"
verdictBloom.Intensity = 0
verdictBloom.Size = 36
verdictBloom.Threshold = 0.9
verdictBloom.Parent = Lighting

-- a straight line lying flat (sigil strokes); reveal(x) draws it from a toward b
local function flatLine(a: Vector3, b: Vector3, w: number, color: Color3)
	local d = b - a
	local fwd = unit(d * FLAT, V(1, 0, 0))
	local side = unit(fwd:Cross(Vector3.yAxis), V(0, 0, 1))
	local A0, A1 = newAtt(), newAtt()
	A0.WorldCFrame = CFrame.fromMatrix(a, fwd, side)
	A1.WorldCFrame = CFrame.fromMatrix(a, fwd, side)
	local bm = newBeam(A0, A1, color, 1, false)
	bm.Width0, bm.Width1 = 0, 0
	local L = {}
	function L.reveal(x: number, alpha: number)
		A1.WorldCFrame = CFrame.fromMatrix(a + d * math.max(x, 0.001), fwd, side)
		local wd = if x > 0 then w else 0
		bm.Width0, bm.Width1 = wd, wd
		bm.Transparency = NumberSequence.new(math.clamp(1 - alpha, 0, 1))
	end
	function L.destroy()
		bm:Destroy()
		A0:Destroy()
		A1:Destroy()
	end
	return L
end

-- a sigil: three rings that draw themselves round, an 8-point star, 12 spokes and a band of glyph dashes
local function makeSigil(center: Vector3, R: number, color: Color3, w: number)
	local rings, lines = {}, {}
	for ri, rr in ipairs({ 1.0, 0.82, 0.34 }) do
		for k = 0, 5 do
			local a0 = k * math.pi / 3
			table.insert(rings, { arc = makeArc(CFrame.new(center), a0, a0 + math.pi / 3, color, 1, true), R = R * rr, order = k / 6, ri = ri, w = if ri == 1 then w * 1.5 else w })
		end
	end
	local function P(r, ang)
		return center + V(math.cos(ang) * r, 0, math.sin(ang) * r)
	end
	for k = 0, 7 do
		local a = k * math.pi / 4
		table.insert(lines, { l = flatLine(P(R * 0.82, a), P(R * 0.82, a + 3 * math.pi / 4), w, color), order = 0.25 + k / 8 * 0.4 })
	end
	for k = 0, 11 do
		local a = k * math.pi / 6 + math.pi / 12
		table.insert(lines, { l = flatLine(P(R * 0.34, a), P(R * 0.82, a), w * 0.6, color), order = 0.35 + k / 12 * 0.35 })
	end
	for k = 0, 23 do
		local a = k * math.pi / 12
		local r1 = R * (0.87 + 0.05 * (k % 3) / 2)
		table.insert(lines, { l = flatLine(P(r1, a), P(r1, a + 0.13), w * 1.6, color), order = 0.5 + k / 24 * 0.3 })
	end
	local S = {}
	function S.set(reveal: number, alpha: number)
		for _, rg in ipairs(rings) do
			local x = math.clamp((reveal - rg.order * 0.6 - (rg.ri - 1) * 0.08) / 0.2, 0, 1)
			local wd = if x > 0 then rg.w else 0
			rg.arc.set(rg.R, function()
				return wd
			end, 1 - alpha * x)
		end
		for _, ln in ipairs(lines) do
			ln.l.reveal(math.clamp((reveal - ln.order) / 0.2, 0, 1), alpha)
		end
	end
	function S.destroy()
		for _, rg in ipairs(rings) do
			rg.arc.destroy()
		end
		for _, ln in ipairs(lines) do
			ln.l.destroy()
		end
	end
	return S
end

-- the colossal blade of light. Prefers the Blender Divine Verdict blade (mesh "VerdictBlade" in
-- ReplicatedStorage.Descent.VFX, tip at its bottom), else a Gravecleaver of light. Returns the model and whether it
-- must be flipped to point down (the Gravecleaver's tip is +Y).
local VERDICT_BLADE_LENGTH = 11
local function lightUp(p: BasePart)
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
	p.Material = Enum.Material.Neon
	p.Color = GOLD_LIGHT
	if p:IsA("MeshPart") then
		p.TextureID = ""
	end
	for _, c in ipairs(p:GetChildren()) do
		if c:IsA("SurfaceAppearance") or c:IsA("Decal") or c:IsA("Texture") then
			c:Destroy()
		end
	end
end
local function spectralBlade(scale: number): (Model?, boolean)
	local vf = Descent:FindFirstChild("VFX")
	local custom = vf and vf:FindFirstChild("VerdictBlade")
	local mesh = custom and (if custom:IsA("BasePart") then custom else custom:FindFirstChildWhichIsA("BasePart", true))
	if mesh then
		local m = Instance.new("Model")
		local p = mesh:Clone()
		p.Parent = m
		m.PrimaryPart = p
		local s = p.Size
		p.Size = s * (VERDICT_BLADE_LENGTH / math.max(s.X, s.Y, s.Z))
		lightUp(p)
		return m, false
	end
	local w = Descent:FindFirstChild("Weapons")
	local tpl = w and w:FindFirstChild("Gravecleaver")
	if not (tpl and tpl:IsA("Model")) then
		return nil, false
	end
	local m = tpl:Clone()
	for _, d in ipairs(m:GetDescendants()) do
		if d.Parent == nil then
			continue
		end
		if d:IsA("BasePart") then
			d.Anchored, d.CanCollide, d.CanQuery, d.CanTouch, d.CastShadow = true, false, false, false, false
			d.Material = Enum.Material.Neon
			d.Color = GOLD_LIGHT
			if d:IsA("MeshPart") then
				d.TextureID = ""
			end
		elseif d:IsA("SurfaceAppearance") or d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Light") or d:IsA("BaseScript") or d:IsA("Sound") or d:IsA("Decal") then
			d:Destroy()
		end
	end
	m:ScaleTo(m:GetScale() * scale) -- relative: the template already carries its own scale
	return m, true
end

playVerdict = function(character: Model, target: Vector3, isLocal: boolean)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local r = findRig(character)
	if r then
		r.freeze = 0
		setTrails(r, false)
		r.move = buildMove(r.pose, MOVES.Verdict(), { kind = "Verdict", layerName = "Telekinesis", spline = true, blendOutFrom = 1.9 })
	end
	local g = groundBelow(target + V(0, 3, 0))
	local skyY = g.Y + 20
	local skyC = V(g.X, skyY, g.Z)
	local floorC = g + V(0, 0.14, 0)
	local sky = makeSigil(skyC, 15, GOLD_LIGHT, 0.45)
	local floorS = makeSigil(floorC, 13, GOLD_LIGHT, 0.4)
	local skyA = fxAnchor(skyC)
	-- the sky sigil's blazing core and star glints (Blender's bloom + streak flares)
	local core = glowBall(0.1, GOLD_HOT)
	core.CFrame = CFrame.new(skyC)
	core.Parent = fxFolder
	local coreLight = Instance.new("PointLight")
	coreLight.Color = Color3.fromRGB(255, 200, 120)
	coreLight.Range = 40
	coreLight.Brightness = 0
	coreLight.Parent = core
	local glintHost = fxAnchor(skyC)
	glintHost.Size = V(26, 0.5, 26)
	local glints = Instance.new("ParticleEmitter")
	glints.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	glints.Color = ColorSequence.new(GOLD_HOT)
	glints.LightEmission = 1
	glints.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.3, 1.6), NumberSequenceKeypoint.new(1, 0) })
	glints.Lifetime = NumberRange.new(0.35, 0.7)
	glints.Speed = NumberRange.new(0, 0.5)
	glints.Rotation = NumberRange.new(0, 90)
	glints.Rate = 0
	glints.Parent = glintHost
	local curtains = {}
	for i = 1, 44 do
		local a = (i / 44) * math.pi * 2 + math.random() * 0.15
		local rr = 9 + math.random() * 2.6
		local A0, A1 = newAtt(), newAtt()
		A0.WorldPosition = skyC + V(math.cos(a) * rr, -0.5, math.sin(a) * rr)
		A1.WorldPosition = floorC + V(math.cos(a) * rr * 0.8, 0.2, math.sin(a) * rr * 0.8)
		local b = newBeam(A0, A1, Color3.fromRGB(255, 168, 60), 1, true)
		local wd = 0.6 + math.random() * 1.6
		b.Width0, b.Width1 = wd, wd * 0.7
		b.Transparency = NumberSequence.new(1)
		table.insert(curtains, { b = b, A0 = A0, A1 = A1, ph = math.random() * 6 })
	end
	local moteHost = fxAnchor(floorC + V(0, 0.4, 0))
	moteHost.Size = V(22, 0.2, 22)
	local motes = Instance.new("ParticleEmitter")
	motes.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	motes.Color = ColorSequence.new(GOLD_HOT, GOLD_LIGHT)
	motes.LightEmission = 1
	motes.Size = NumberSequence.new(0.45, 0)
	motes.Lifetime = NumberRange.new(1.2, 2.2)
	motes.Speed = NumberRange.new(3, 7)
	motes.EmissionDirection = Enum.NormalId.Top
	motes.SpreadAngle = Vector2.new(10, 10)
	motes.Rate = 0
	motes.Parent = moteHost
	local blade, flipBlade = spectralBlade(1.5)
	local bladeParts, offset, bladeH = {}, 0, 30
	local toward = unit((root.Position - g) * FLAT, V(0, 0, 1))
	local rot = CFrame.lookAt(Vector3.zero, toward) * (if flipBlade then CFrame.Angles(math.pi, 0, 0) else CFrame.identity)
	if blade then
		blade:PivotTo(CFrame.new(g.X, skyY + 60, g.Z) * rot)
		local cf, size = blade:GetBoundingBox()
		offset = (skyY + 60) - (cf.Position.Y - size.Y / 2)
		bladeH = size.Y
		for _, p in ipairs(blade:GetDescendants()) do
			if p:IsA("BasePart") then
				p.Transparency = 1
				table.insert(bladeParts, p)
			end
		end
		local hl = Instance.new("Highlight")
		hl.FillColor = GOLD_HOT
		hl.FillTransparency = 0.55
		hl.OutlineColor = GOLD_LIGHT
		hl.OutlineTransparency = 0
		hl.DepthMode = Enum.HighlightDepthMode.Occluded
		hl.Parent = blade
		blade.Parent = fxFolder
	end
	local function setBlade(bottomY: number, tr: number)
		if blade then
			blade:PivotTo(CFrame.new(g.X, bottomY + offset, g.Z) * rot)
			for _, p in ipairs(bladeParts) do
				p.Transparency = tr
			end
		end
	end
	local buried = g.Y - 1.6
	local gyros = {}
	if isLocal then
		TweenService:Create(verdictBloom, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Intensity = 0.9 }):Play()
	end
	sound(root, pick(SFX.HeavyWhoosh), 0.4, 1)
	sound(root, SFX.HolyBell, 0.75, 1.3, 4)
	local verdictBuild = sound(if isLocal then nil else root, SFX.LightSuck, 1, 0.8, 3)
	verdictBuild.TimePosition = math.max(0, 2.47 - cfg.Verdict.Impact)
	local t0 = os.clock()
	local flags = {}
	local cleaned = false
	local conn
	local function cleanup()
		if cleaned then
			return
		end
		cleaned = true
		conn:Disconnect()
		sky.destroy()
		floorS.destroy()
		for _, c in ipairs(curtains) do
			c.b:Destroy()
			c.A0:Destroy()
			c.A1:Destroy()
		end
		for _, arc in ipairs(gyros) do
			arc.destroy()
		end
		moteHost:Destroy()
		skyA:Destroy()
		core:Destroy()
		glintHost:Destroy()
		if blade then
			blade:Destroy()
		end
		if isLocal then
			TweenService:Create(verdictCC, TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), { TintColor = Color3.new(1, 1, 1), Brightness = 0, Contrast = 0, Saturation = 0 }):Play()
			TweenService:Create(verdictBloom, TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), { Intensity = 0 }):Play()
		end
	end
	conn = RunService.Heartbeat:Connect(function()
		local t = os.clock() - t0
		if t > 3.1 or not character.Parent then
			cleanup()
			return
		end
		local fade = 1 - smooth01((t - 1.75) / 0.6)
		sky.set(smooth01(t / 0.75), fade)
		floorS.set(smooth01((t - 0.12) / 0.75), fade)
		local cOn = smooth01((t - 0.3) / 0.5) * (1 - smooth01((t - 1.35) / 0.35))
		for _, c in ipairs(curtains) do
			local fl = 0.75 + 0.25 * math.sin(t * 7 + c.ph)
			c.b.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.15, 1 - 0.8 * cOn * fl),
				NumberSequenceKeypoint.new(0.85, 1 - 0.7 * cOn * fl),
				NumberSequenceKeypoint.new(1, 1),
			})
		end
		motes.Rate = if t > 0.3 and t < 1.15 then 70 else 0
		glints.Rate = if t > 0.3 and t < 1.6 then 22 else 0
		local coreOn = smooth01((t - 0.2) / 0.4) * (1 - smooth01((t - 1.7) / 0.5))
		core.Size = Vector3.one * math.max(0.05, 3.6 * coreOn * (1 + 0.12 * math.sin(t * 18)))
		core.Transparency = 1 - coreOn
		coreLight.Brightness = 3 * coreOn
		if t < 0.7 then
			setBlade(skyY + 60, 1)
		elseif t < 1.02 then
			local x = EASE.outCubic((t - 0.7) / 0.32)
			setBlade(skyY + 2 - 10 * x, 0.6 - 0.4 * x)
		elseif t < VC.Impact then
			local x = (t - 1.02) / (VC.Impact - 1.02)
			setBlade((skyY - 8) + (buried - (skyY - 8)) * x * x, 0.15)
		else
			setBlade(buried, math.max(0.15 + 0.1 * math.sin(t * 14), smooth01((t - 2.2) / 0.6)))
		end
		if t >= 0.7 and not flags.emerge then
			flags.emerge = true
			sound(skyA, pick(SFX.SwordClang), 0.45, 0.9)
			sound(skyA, pick(SFX.SteelShing), 0.6, 0.8)
			burst(skyC - V(0, 1, 0), { Texture = "rbxasset://textures/particles/sparkles_main.dds", Color = ColorSequence.new(GOLD_HOT), LightEmission = 1, Size = NumberSequence.new(0.6, 0), Lifetime = NumberRange.new(0.4, 0.9), Speed = NumberRange.new(8, 16), SpreadAngle = Vector2.new(180, 180), Drag = 3 }, 30, 1.2)
		end
		if t >= 1.02 and not flags.drop then
			flags.drop = true
			sound(skyA, pick(SFX.HeavyWhoosh), 0.55, 1.1)
		end
		if t >= VC.Impact and not flags.impact then
			flags.impact = true
			local hitP = g + V(0, 1.5, 0)
			local fl = glowBall(2, GOLD_HOT)
			fl.CFrame = CFrame.new(hitP)
			fl.Parent = fxFolder
			TweenService:Create(fl, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.one * 16, Transparency = 1 }):Play()
			Debris:AddItem(fl, 0.3)
			do
				local PA0, PA1 = newAtt(), newAtt()
				PA0.WorldPosition = g
				PA1.WorldPosition = skyC
				local pg = newBeam(PA0, PA1, GOLD_LIGHT, 1, true)
				local pc = newBeam(PA0, PA1, GOLD_HOT, 1, true)
				animate(0.7, function(x)
					local e = 1 - EASE.outCubic(x)
					pg.Width0, pg.Width1 = 8 * e, 8 * e
					pc.Width0, pc.Width1 = 3 * e, 3 * e
					pg.Transparency = NumberSequence.new(0.1 + 0.6 * x)
				end, function()
					pg:Destroy()
					pc:Destroy()
					PA0:Destroy()
					PA1:Destroy()
				end)
			end
			radialBurst(hitP, 22, 2, 24, 0.38, GOLD_HOT, 0.8, true)
			radialBurst(hitP, 8, 1, 22, 0.25, Color3.new(1, 1, 1), 1.2, false)
			for i, rr in ipairs({ 30, 38, 48 }) do
				task.delay((i - 1) * 0.08, function()
					groundRing(g + V(0, 0.2 + i * 0.02, 0), 1, rr, 0.6 + i * 0.12, 2.4 - i * 0.4, if i == 1 then GOLD_HOT else GOLD_LIGHT, 1)
				end)
			end
			for i = 1, 3 do
				task.delay((i - 1) * 0.07, function()
					local camPos = workspace.CurrentCamera.CFrame.Position
					local toCam = unit((camPos - hitP) * FLAT, V(0, 0, 1))
					local right = unit(toCam:Cross(Vector3.yAxis), V(1, 0, 0))
					local up = right:Cross(toCam)
					local base = hitP + V(0, 2 + i * 1.5, 0)
					local arc = makeArc(planeCF(base, right, up), 0, math.pi * 2, GOLD_LIGHT, 1, true)
					animate(0.6, function(x)
						arc.c = planeCF(base + toCam * (8 * x), right, up)
						local wd = 0.8 * (1 - x)
						arc.set(3 + 12 * EASE.outCubic(x), function()
							return wd
						end, x)
					end, arc.destroy)
				end)
			end
			for _, spec in ipairs({ { Enum.Material.Neon, GOLD_HOT, 12, 0.22 }, { Enum.Material.ForceField, Color3.fromRGB(255, 176, 30), 34, 0.6 } }) do
				local bb = Instance.new("Part")
				bb.Shape = Enum.PartType.Ball
				bb.Material = spec[1]
				bb.Color = spec[2]
				bb.Anchored, bb.CanCollide, bb.CanQuery, bb.CanTouch, bb.CastShadow = true, false, false, false, false
				bb.Size = Vector3.one * 2
				bb.CFrame = CFrame.new(hitP)
				bb.Transparency = 0.1
				bb.Parent = fxFolder
				TweenService:Create(bb, TweenInfo.new(spec[4], Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.one * spec[3], Transparency = 1 }):Play()
				Debris:AddItem(bb, spec[4] + 0.05)
			end
			cracks(g + V(0, 0.08, 0), 18, 18, Color3.fromRGB(255, 150, 50), 3)
			burst(g + V(0, 0.5, 0), DUST, 40, 2.4)
			burst(g + V(0, 0.5, 0), DEBRIS, 50, 1.6)
			for i = 1, 6 do
				local slab = tkRock(i + 1)
				local a = (i / 6) * math.pi * 2 + math.random() * 0.5
				local p0 = g + V(math.cos(a) * 4, 0.6, math.sin(a) * 4)
				local v0 = V(math.cos(a) * (10 + math.random() * 10), 18 + math.random() * 16, math.sin(a) * (10 + math.random() * 10))
				local spin = V(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 9
				slab.CFrame = CFrame.new(p0)
				slab.Parent = fxFolder
				animate(1.7, function(x)
					local tt = x * 1.7
					local p = p0 + v0 * tt + V(0, -0.5 * 70 * tt * tt, 0)
					if p.Y < g.Y + slab.Size.Y * 0.4 then
						p = V(p.X, g.Y + slab.Size.Y * 0.4, p.Z)
					end
					slab.CFrame = CFrame.new(p) * CFrame.fromEulerAnglesXYZ(spin.X * tt, spin.Y * tt, spin.Z * tt)
					slab.Transparency = smooth01((x - 0.7) / 0.3)
				end, function()
					slab:Destroy()
				end)
			end
			burst(hitP + V(0, 2, 0), {
				Texture = "rbxasset://textures/particles/sparkles_main.dds",
				Color = ColorSequence.new(GOLD_HOT, GOLD_LIGHT),
				LightEmission = 1,
				Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 0.2) }),
				Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.8, 0.2), NumberSequenceKeypoint.new(1, 1) }),
				Lifetime = NumberRange.new(2.2, 3.6),
				Speed = NumberRange.new(18, 34),
				SpreadAngle = Vector2.new(70, 70),
				EmissionDirection = Enum.NormalId.Top,
				Acceleration = V(0, -7, 0),
				Drag = 2.6,
				Rotation = NumberRange.new(0, 360),
				RotSpeed = NumberRange.new(-220, 220),
			}, 90, 4)
			local la = fxAnchor(hitP + V(0, 3, 0))
			local light = Instance.new("PointLight")
			light.Color = Color3.fromRGB(255, 200, 110)
			light.Brightness = 4
			light.Range = 45
			light.Parent = la
			TweenService:Create(light, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Brightness = 0 }):Play()
			Debris:AddItem(la, 3)
			sound(la, pick(SFX.RockImpact), 0.8, 1.7)
			sound(la, pick(SFX.SwordClang), 0.55, 1.3)
			sound(la, "rbxasset://sounds/impact_explosion_03.mp3", 1.0, 1)
			sound(if isLocal then nil else la, pick(SFX.Boom), 0.85, 1.5, 5)
			sound(if isLocal then nil else la, SFX.MagicBurst, 0.9, 1.1, 4)
			sound(if isLocal then nil else la, SFX.LightningCrack, 0.8, 0.9, 4)
			if isLocal then
				shake(1.4, 0.4)
				fovKick(12)
				verdictCC.TintColor = Color3.fromRGB(255, 246, 228)
				verdictCC.Brightness = 0.35
				verdictCC.Contrast = 0.5
				verdictCC.Saturation = -0.4
				TweenService:Create(verdictCC, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { TintColor = Color3.new(1, 1, 1), Brightness = 0, Contrast = 0, Saturation = 0 }):Play()
			end
			for i = 1, 3 do
				gyros[i] = makeArc(CFrame.new(hitP), 0, math.pi * 2, GOLD_LIGHT, 1, true)
			end
		end
		if flags.impact then
			local ga = (1 - smooth01((t - 2.1) / 0.6)) * smooth01((t - VC.Impact) / 0.15)
			local guard = V(g.X, buried + bladeH * 0.69, g.Z)
			for i, arc in ipairs(gyros) do
				arc.c = CFrame.new(guard) * CFrame.Angles(t * (1.3 + i * 0.4), t * (0.9 - i * 0.5), i * 1.05)
				arc.set(1.5 + i * 0.4, function()
					return 0.18
				end, 1 - 0.85 * ga)
			end
		end
	end)
end

---------------------------------------------------------------- crit-ready markers
local marked = {}

local function clearMark(model)
	local m = marked[model]
	if m then
		m.h:Destroy()
		if m.bb then
			m.bb:Destroy()
		end
		marked[model] = nil
	end
end

local function updateMark(model: Model)
	local untilT = model:GetAttribute("CritReadyUntil")
	local active = untilT and untilT > workspace:GetServerTimeNow()
	if active and not marked[model] then
		local h = Instance.new("Highlight")
		h.FillColor = Color3.fromRGB(255, 200, 60)
		h.OutlineColor = Color3.fromRGB(255, 240, 180)
		h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		h.Parent = model
		local head = model:FindFirstChild("Head")
		local bb
		if head then
			bb = Instance.new("BillboardGui")
			bb.Size = UDim2.fromOffset(90, 50)
			bb.StudsOffset = V(0, 2.5, 0)
			bb.AlwaysOnTop = true
			local t = Instance.new("TextLabel")
			t.Size = UDim2.fromScale(1, 1)
			t.BackgroundTransparency = 1
			t.Text = "CRIT!"
			t.Font = Enum.Font.GothamBlack
			t.TextScaled = true
			t.TextColor3 = Color3.fromRGB(255, 215, 80)
			t.TextStrokeTransparency = 0
			t.Parent = bb
			bb.Parent = head
		end
		marked[model] = { h = h, bb = bb }
	elseif not active then
		clearMark(model)
	end
end

local function watchDemon(model: Instance)
	if model:IsA("Model") then
		model:GetAttributeChangedSignal("CritReadyUntil"):Connect(function()
			updateMark(model)
		end)
		updateMark(model)
	end
end
DEMONS.ChildAdded:Connect(watchDemon)
DEMONS.ChildRemoved:Connect(clearMark)
for _, m in ipairs(DEMONS:GetChildren()) do
	watchDemon(m)
end

---------------------------------------------------------------- per-frame: crit pulse, Curse glow, heavy charge
RunService.RenderStepped:Connect(function()
	local t = os.clock()
	for model, m in pairs(marked) do
		updateMark(model)
		if marked[model] then
			m.h.FillTransparency = 0.35 + 0.3 * math.sin(t * 18)
		end
	end
	for _, plr in ipairs(Players:GetPlayers()) do
		local ch = plr.Character
		local sword = ch and ch:FindFirstChild("Gravecleaver")
		local crack = sword and sword:IsA("Model") and sword:FindFirstChild("CurseCrack", true)
		if crack then
			local c = plr:GetAttribute("Curse") or 0
			local r = rigs[ch]
			local charging = r and t < r.chargeUntil
			local pulse = 0.5 + 0.5 * math.sin(t * (if charging then 30 else 2 + c * 6))
			local k = if charging then 1 else math.clamp(0.2 + c * 0.8 * (0.75 + 0.25 * pulse), 0, 1)
			crack.Color = Color3.fromRGB(110, 15, 8):Lerp(Color3.fromRGB(255, 95, 30), k)
			local light = crack:FindFirstChild("CurseLight")
			if light then
				light.Brightness = if charging then 3 + 2 * pulse else 0.3 + c * 1.6 * (0.7 + 0.3 * pulse)
				light.Range = if charging then 9 else 3 + c * 3
			end
			local em = crack:FindFirstChild("CurseEmbers")
			if em then
				em.Rate = if charging then 45 else 3 + c * 14
			end
		end
	end
end)

---------------------------------------------------------------- input
local function mouseAim(): Vector3?
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end
	local m = UIS:GetMouseLocation()
	local ray = workspace.CurrentCamera:ViewportPointToRay(m.X, m.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character, fxFolder }
	local hit = workspace:Raycast(ray.Origin, ray.Direction * 500, params)
	if not hit then
		return nil
	end
	local flat = (hit.Position - root.Position) * FLAT
	if flat.Magnitude < 1 then
		return nil
	end
	return flat.Unit
end

local function requestAttack(mode: string)
	local aim = nil
	local last = UIS:GetLastInputType()
	if last == Enum.UserInputType.MouseButton1 or last == Enum.UserInputType.Keyboard then
		aim = mouseAim()
	end
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if aim and root then
		root.CFrame = CFrame.lookAt(root.Position, root.Position + aim)
	end
	local airborne = hum ~= nil and hum.FloorMaterial == Enum.Material.Air
	SwingRequest:FireServer(mode, aim, airborne)
end

local hooked = setmetatable({}, { __mode = "k" })
local function hookTool(tool: Instance)
	if not tool:IsA("Tool") or tool.Name ~= TOOL_NAME or hooked[tool] then
		return
	end
	hooked[tool] = true
	tool.Activated:Connect(function()
		requestAttack("Light")
	end)
end
local function watchContainer(c: Instance)
	c.ChildAdded:Connect(hookTool)
	for _, x in ipairs(c:GetChildren()) do
		hookTool(x)
	end
end
player.ChildAdded:Connect(function(c)
	if c:IsA("Backpack") then
		watchContainer(c)
	end
end)
local bp = player:FindFirstChildOfClass("Backpack")
if bp then
	watchContainer(bp)
end
-- no climbing: crowds of demons count as "climbable" and would block jumps (nothing to climb in the dungeon)
local function noClimb(c: Model)
	local hum = c:WaitForChild("Humanoid", 10)
	if hum then
		hum:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
	end
end
player.CharacterAdded:Connect(function(c)
	watchContainer(c)
	noClimb(c)
end)
if player.Character then
	watchContainer(player.Character)
	task.spawn(noClimb, player.Character)
end

-- a ProximityPrompt (hub stations, doors...) on screen gets its key (E / gamepad X) instead of the sword
local promptsShown = 0
do
	local PPS = game:GetService("ProximityPromptService")
	PPS.PromptShown:Connect(function()
		promptsShown += 1
	end)
	PPS.PromptHidden:Connect(function()
		promptsShown = math.max(0, promptsShown - 1)
	end)
end
local function promptWants(io: InputObject?): boolean
	return promptsShown > 0 and io ~= nil and (io.KeyCode == Enum.KeyCode.E or io.KeyCode == Enum.KeyCode.ButtonX)
end

-- Heavy: E / gamepad Y / on-screen Heavy button (only with the sword drawn)
CAS:BindAction("DescentHeavy", function(_, inputState, io)
	local r = player.Character and rigs[player.Character]
	if not (r and r.equipped) or promptWants(io) then
		return Enum.ContextActionResult.Pass
	end
	if inputState == Enum.UserInputState.Begin then
		requestAttack("Heavy")
	end
	return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.E, Enum.KeyCode.ButtonY)
CAS:SetTitle("DescentHeavy", "Heavy")

-- Dodge + backflip chain
local lastDodge, lastBackDodge, lastFlip = -10, -10, -10
local lastBackDir = V(0, 0, 1)

local function doBackflip(ch: Model, hum: Humanoid, root: BasePart)
	lastFlip = os.clock()
	lastBackDodge = -10
	local dir = lastBackDir
	root.CFrame = CFrame.lookAt(root.Position, root.Position - dir) -- face away from where we flip to
	lockRotate(hum, 1.6)
	hum:ChangeState(Enum.HumanoidStateType.Jumping)
	root.AssemblyLinearVelocity = dir * cfg.Backflip.Back + V(0, cfg.Backflip.Up, 0)
	pushRoot(root, dir, cfg.Backflip.Back, 0.3)
	playBackflip(ch, true)
	DodgeRequest:FireServer(dir, true)
end

local function tryDodge()
	local ch = player.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	local root = ch and ch:FindFirstChild("HumanoidRootPart")
	if not (hum and root) or hum.Health <= 0 then
		return
	end
	local t = os.clock()
	-- second press right after a backward dodge = backflip
	if t - lastBackDodge <= cfg.Backflip.Window and t - lastFlip >= cfg.Backflip.Cooldown then
		doBackflip(ch, hum, root)
		return
	end
	if t - lastDodge < cfg.Dodge.Cooldown then
		return
	end
	lastDodge = t
	local md = hum.MoveDirection * FLAT
	local camLook = unit(workspace.CurrentCamera.CFrame.LookVector * FLAT)
	local dir, back
	if md.Magnitude > 0.1 then
		dir = md.Unit
		back = dir:Dot(camLook) < -0.6 -- holding S (toward the camera)
		if back then
			root.CFrame = CFrame.lookAt(root.Position, root.Position + camLook) -- back-step, don't turn around
		end
	else
		dir = -flatLook(root) -- standing still = back-step
		back = true
	end
	if back then
		lastBackDodge = t
		lastBackDir = dir
		lockRotate(hum, cfg.Dodge.Duration + cfg.Backflip.Window)
	end
	pushRoot(root, dir, cfg.Dodge.Speed, cfg.Dodge.Duration)
	playDodge(ch, dir, true)
	DodgeRequest:FireServer(dir, false)
end

CAS:BindAction("DescentDodge", function(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		tryDodge()
	end
	return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.Q, Enum.KeyCode.ButtonB)
CAS:SetTitle("DescentDodge", "Dodge")

-- Sprint: hold Shift (gamepad L3 / mobile Sprint button toggle). The server owns speed + stamina.
local SprintRequest: RemoteEvent = Remotes:WaitForChild("SprintRequest")
local wantSprint = false
-- Slow walk: Alt toggles it (server owns the speed). Sprinting turns it off. One table = one local (CombatClient is
-- near Luau's 200 top-level locals).
local SlowWalk = { want = false, remote = Remotes:WaitForChild("SlowWalkRequest") :: RemoteEvent }
function SlowWalk.set(on: boolean)
	if on ~= SlowWalk.want then
		SlowWalk.want = on
		SlowWalk.remote:FireServer(on)
	end
end
local function setSprint(on: boolean)
	if on ~= wantSprint then
		wantSprint = on
		SprintRequest:FireServer(on)
	end
	if on then
		SlowWalk.set(false)
	end
end
CAS:BindAction("DescentSlowWalk", function(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		SlowWalk.set(not SlowWalk.want)
	end
	return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.LeftAlt, Enum.KeyCode.RightAlt)
CAS:SetTitle("DescentSlowWalk", "Walk")
CAS:BindAction("DescentSprint", function(_, inputState, input)
	local toggle = input.KeyCode == Enum.KeyCode.ButtonL3 or input.UserInputType == Enum.UserInputType.Touch
	if toggle then
		if inputState == Enum.UserInputState.Begin then
			setSprint(not wantSprint)
		end
	elseif inputState == Enum.UserInputState.Begin then
		setSprint(true)
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		setSprint(false)
	end
	return Enum.ContextActionResult.Pass
end, false, Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonL3)
CAS:SetTitle("DescentSprint", "Sprint")
player.CharacterAdded:Connect(function()
	wantSprint = false
	SprintRequest:FireServer(false)
	SlowWalk.want = false
	SlowWalk.remote:FireServer(false)
end)

-- Shift lock on Ctrl (Shift is sprint). Roblox now runs shift lock through the input-action system:
-- StarterPlayer.PlayerModule (created at runtime) > InputContexts > CameraContext > MouseLockSwitchAction.
-- We re-point its two keyboard bindings from Shift to Ctrl on this client.
task.spawn(function()
	local pm = game:GetService("StarterPlayer"):WaitForChild("PlayerModule", 30)
	local ctx = pm and pm:WaitForChild("InputContexts", 10)
	local camCtx = ctx and ctx:WaitForChild("CameraContext", 10)
	local action = camCtx and camCtx:WaitForChild("MouseLockSwitchAction", 10)
	if not action then
		warn("[CombatClient] shift lock action not found; it stays on Shift")
		return
	end
	local primary = action:WaitForChild("KeyboardPrimaryBinding", 5)
	local secondary = action:WaitForChild("KeyboardSecondaryBinding", 5)
	if primary then
		primary.KeyCode = Enum.KeyCode.LeftControl
	end
	if secondary then
		secondary.KeyCode = Enum.KeyCode.RightControl
	end
end)

-- Ultimate: R / gamepad X / on-screen ULT button, only when drawn and the bar is full
local UltimateRequest: RemoteEvent = Remotes:WaitForChild("UltimateRequest")
CAS:BindAction("DescentUltimate", function(_, inputState, io)
	if promptWants(io) then
		return Enum.ContextActionResult.Pass
	end
	local r = player.Character and rigs[player.Character]
	if not (r and r.equipped) or (player:GetAttribute("Ultimate") or 0) < 100 then
		return Enum.ContextActionResult.Pass
	end
	if inputState == Enum.UserInputState.Begin then
		UltimateRequest:FireServer()
	end
	return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.R, Enum.KeyCode.ButtonX)
CAS:SetTitle("DescentUltimate", "ULT")

-- Telekinesis "Grave Grasp": G / gamepad DPadUp / phone GRASP button. With a mouse, the rocks go where the cursor
-- points (the server clamps the distance); otherwise straight ahead.
local TelekinesisRequest: RemoteEvent = Remotes:WaitForChild("TelekinesisRequest")
local lastTK = -100
-- where the mouse points: skips invisible and see-through parts (barriers, trigger zones) so the aim lands on the
-- ground or the demon you're actually pointing at
local function mousePoint(): Vector3?
	local m = UIS:GetMouseLocation()
	local ray = workspace.CurrentCamera:ViewportPointToRay(m.X, m.Y)
	local ignore = { player.Character, fxFolder }
	for _ = 1, 8 do
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = ignore
		local hit = workspace:Raycast(ray.Origin, ray.Direction * 500, params)
		if not hit then
			return nil
		end
		local inst = hit.Instance
		if inst:IsA("BasePart") and not inst:IsA("Terrain") and (inst.Transparency >= 0.9 or not inst.CanCollide) and not inst:IsDescendantOf(DEMONS) then
			table.insert(ignore, inst)
		else
			return hit.Position
		end
	end
	return nil
end
local function aimPoint(): Vector3?
	local last = UIS:GetLastInputType()
	if last == Enum.UserInputType.MouseButton1 or last == Enum.UserInputType.MouseButton2 or last == Enum.UserInputType.Keyboard or last == Enum.UserInputType.MouseMovement or last == Enum.UserInputType.MouseWheel then
		return mousePoint()
	end
	return nil
end
-- same landing rule as the server: MinDistance..Range from the feet (straight ahead without a mouse), on the ground there
local function tkTargetFrom(root: BasePart, hum: Humanoid, point: Vector3?): Vector3
	local T = cfg.Telekinesis
	local floor = root.Position - V(0, hum.HipHeight + root.Size.Y / 2, 0)
	local target = floor + flatLook(root) * T.DefaultDistance
	if point then
		local d = (point - floor) * FLAT
		if d.Magnitude > 0.5 then
			target = floor + d.Unit * math.clamp(d.Magnitude, T.MinDistance, T.Range)
		end
	end
	return groundBelow(target + V(0, 3, 0))
end
-- G down: the rocks rise and are held
tryTelekinesis = function()
	local ch = player.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	local root = ch and ch:FindFirstChild("HumanoidRootPart")
	if tkHolding or not (hum and root) or hum.Health <= 0 or os.clock() - lastTK < cfg.Telekinesis.Cooldown then
		return
	end
	tkHolding = true
	tkReleaseWanted = false
	TelekinesisRequest:FireServer("grab")
	task.delay(1.5, function()
		-- the server said no (e.g. during the ultimate): free the key again
		if tkHolding and not tkHolds[ch] then
			tkHolding = false
		end
	end)
end
-- G up: thrown as soon as the rocks are gathered (a quick tap throws at the normal moment)
local function releaseTelekinesisKey()
	tkReleaseWanted = true
end
-- the throw happens: aim NOW, turn to face it, tell the server, return where the rocks will land
tkThrowLocal = function(character: Model): Vector3
	tkHolding = false
	lastTK = os.clock()
	local hum = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	local point = aimPoint()
	if point and root then
		local flat = (point - root.Position) * FLAT
		if flat.Magnitude > 1 then
			root.CFrame = CFrame.lookAt(root.Position, root.Position + flat.Unit)
		end
	end
	TelekinesisRequest:FireServer("throw", point)
	return if root and hum then tkTargetFrom(root, hum, point) else Vector3.zero
end
CAS:BindAction("DescentTelekinesis", function(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		tryTelekinesis()
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		releaseTelekinesisKey()
	end
	return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.G, Enum.KeyCode.DPadUp)
-- Divine Verdict: Z / gamepad DPadLeft / phone VERDICT button. Aims like Grave Grasp (mouse point, else straight ahead).
local VerdictRequest: RemoteEvent = Remotes:WaitForChild("VerdictRequest")
local lastVerdict = -100
tryVerdict = function()
	local ch = player.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	local root = ch and ch:FindFirstChild("HumanoidRootPart")
	if not (hum and root) or hum.Health <= 0 or os.clock() - lastVerdict < cfg.Verdict.Cooldown then
		return
	end
	lastVerdict = os.clock()
	local point = nil
	local last = UIS:GetLastInputType()
	if last == Enum.UserInputType.MouseButton1 or last == Enum.UserInputType.Keyboard or last == Enum.UserInputType.MouseMovement then
		point = mousePoint()
	end
	if point then
		local flat = (point - root.Position) * FLAT
		if flat.Magnitude > 1 then
			root.CFrame = CFrame.lookAt(root.Position, root.Position + flat.Unit)
		end
	end
	VerdictRequest:FireServer(point)
end
CAS:BindAction("DescentVerdict", function(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		tryVerdict()
	end
	return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.Z, Enum.KeyCode.DPadLeft)

-- PHONE CONTROLS (StarterPlayerScripts.Descent.MobileControls) call in here
-- exact same code as the keyboard and gamepad. Roblox's default ContextActionService touch buttons are off.
local inputFn = Instance.new("BindableFunction")
inputFn.Name = "DescentInput"
inputFn.OnInvoke = function(action: string, arg)
	local r = player.Character and rigs[player.Character]
	local drawn = r ~= nil and r.equipped
	if action == "Light" or action == "Heavy" then
		if drawn then
			requestAttack(action)
		end
	elseif action == "Telekinesis" then
		tryTelekinesis()
	elseif action == "TelekinesisRelease" then
		releaseTelekinesisKey()
	elseif action == "Verdict" then
		tryVerdict()
	elseif action == "Dodge" then
		tryDodge()
	elseif action == "Sprint" then
		setSprint(arg == true)
	elseif action == "Ult" then
		if drawn and (player:GetAttribute("Ultimate") or 0) >= 100 then
			UltimateRequest:FireServer()
		end
	elseif action == "State" then
		return { drawn = drawn, sprint = wantSprint, dodgeLeft = math.max(0, cfg.Dodge.Cooldown - (os.clock() - lastDodge)), tkLeft = math.max(0, cfg.Telekinesis.Cooldown - (os.clock() - lastTK)), verdictLeft = math.max(0, cfg.Verdict.Cooldown - (os.clock() - lastVerdict)) }
	end
	return true
end
inputFn.Parent = player

---------------------------------------------------------------- server events
local lastSoulSound = 0
local function monsterImpact(character: Model, amount: number, force: number, from: Vector3)
	if character ~= player.Character then
		return
	end

	local strength = math.clamp(force / 31, 0.22, 1)
	local thud = sound(nil, SFX.Thud, 1.12 - strength * 0.28, 0.95 + strength * 0.35, 1.4)
	thud.Name = "MonsterImpactThud"
	if strength >= 0.75 then
		sound(nil, pick(SFX.RockImpact), 0.86, 0.52, 1.4)
	end
	shake(0.50 + strength * 0.73, 0.16 + strength * 0.08)

	local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("HumanoidRootPart")
	if torso and amount > 0 then
		local strike = Instance.new("Highlight")
		strike.Name = "MonsterImpactFlash"
		strike.FillColor = Color3.fromRGB(237, 79, 61)
		strike.FillTransparency = 0.52
		strike.OutlineTransparency = 1
		strike.DepthMode = Enum.HighlightDepthMode.Occluded
		strike.Parent = character
		TweenService:Create(strike, TweenInfo.new(0.17), { FillTransparency = 1 }):Play()
		Debris:AddItem(strike, 0.21)
	end

	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return
	end
	local gui = playerGui:FindFirstChild("DescentMonsterImpact")
	if not gui then
		gui = Instance.new("ScreenGui")
		gui.Name = "DescentMonsterImpact"
		gui.IgnoreGuiInset = true
		gui.ResetOnSpawn = true
		gui.DisplayOrder = 4
		for _, spec in ipairs({
			{ "Left", 0, 0, 0.17, 1, 0 },
			{ "Right", 0.83, 0, 0.17, 1, 180 },
			{ "Top", 0, 0, 1, 0.14, 90 },
			{ "Bottom", 0, 0.86, 1, 0.14, 270 },
		}) do
			local edge = Instance.new("Frame")
			edge.Name = spec[1]
			edge.Position = UDim2.fromScale(spec[2], spec[3])
			edge.Size = UDim2.fromScale(spec[4], spec[5])
			edge.BorderSizePixel = 0
			edge.BackgroundTransparency = 1
			edge.BackgroundColor3 = Color3.fromRGB(177, 23, 26)
			local gradient = Instance.new("UIGradient")
			gradient.Rotation = spec[6]
			gradient.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(0.35, 0.64),
				NumberSequenceKeypoint.new(1, 1),
			})
			gradient.Parent = edge
			edge.Parent = gui
		end
		gui.Parent = playerGui
	end
	local toward = if torso then from - torso.Position else Vector3.zero
	local side = if toward.Magnitude > 0.001 then camera.CFrame.RightVector:Dot(toward.Unit) else 0
	for _, edge in gui:GetChildren() do
		local bias = if edge.Name == "Left" then math.max(-side, 0) elseif edge.Name == "Right" then math.max(side, 0) else 0
		local opacity = (0.32 + 0.30 * strength) * (0.77 + 0.23 * bias)
		edge.BackgroundTransparency = 1 - opacity
		TweenService:Create(edge, TweenInfo.new(0.34, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundTransparency = 1,
		}):Play()
	end
end

CombatFX.OnClientEvent:Connect(function(kind: string, ...)
	if kind == "MonsterDamage" then
		monsterImpact(...)
	elseif kind == "Swing" then
		playAttack(...)
	elseif kind == "Hit" then
		local character, swingKind, _step, impact, report, crit = ...
		local heavy = swingKind == "Heavy" or swingKind == "Slam" or swingKind == "Telekinesis" or swingKind == "Verdict" or (swingKind == "Light" and _step == 4)
		if swingKind == "Slam" and character ~= player.Character then
			local r = rigs[character]
			if r and r.move and r.move.kind == "Slam" then
				slamLand(r, false)
			end
			if impact then
				slamImpactFX(impact)
			end
		end
		local mine = character == player.Character
		local r = rigs[character]
		local big = heavy or swingKind == "Ultimate"
		local fresh = {}
		for _, h in ipairs(report) do
			damageNumber(h.pos, h.dmg, crit == true, big)
			local seen = mine and r and h.model and r.recentContacts and r.recentContacts[h.model] and os.clock() - r.recentContacts[h.model] < 0.8
			if not seen and swingKind ~= "Ultimate" then
				table.insert(fresh, h)
				contactFX(h.pos, Vector3.zero, heavy)
				if h.model then
					enemyFlash(h.model)
				end
			end
		end
		if fresh[1] then
			-- hits the blade-contact check didn't catch (other players, or the server's wider hit area)
			hitSounds(fresh[1].pos, heavy, mine)
			if swingKind ~= "Slam" then
				hitStop(character, if heavy then 0.09 else 0.05)
			end
			if mine and swingKind ~= "Slam" then
				shake(if heavy then 0.6 else 0.35, if heavy then 0.18 else 0.1)
				fovKick(if heavy then 5 else 3)
			end
		end
		if mine and crit then
			critFlash()
		end
	elseif kind == "Kill" then
		local character, pos = ...
		soulWisps(pos, character)
		if typeof(pos) == "Vector3" and os.clock() - lastSoulSound > 0.2 then
			lastSoulSound = os.clock() -- five demons dying together = one soul sound, not five
			local ka = fxAnchor(pos)
			Debris:AddItem(ka, 3)
			sound(ka, SFX.SpiritWhoosh, 0.85 + math.random() * 0.1, 0.6)
		end
	elseif kind == "Dodge" then
		local character, dir = ...
		if character ~= player.Character then
			playDodge(character, dir, false)
		end
	elseif kind == "Backflip" then
		local character = ...
		if character ~= player.Character then
			playBackflip(character, false)
		end
	elseif kind == "Verdict" then
		local character, target = ...
		if typeof(target) == "Vector3" then
			playVerdict(character, target, character == player.Character)
		end
	elseif kind == "Telekinesis" then
		local character = ...
		playTelekinesis(character, character == player.Character)
	elseif kind == "TelekinesisThrow" then
		local character, target = ...
		local h = tkHolds[character]
		if h and character ~= player.Character and typeof(target) == "Vector3" then
			h.target = target
		end
	elseif kind == "Ultimate" then
		local character = ...
		playUltimate(character, character == player.Character)
	end
end)

---------------------------------------------------------------- dev-only test hook (Studio playtests; remove before launch)
-- Invoke("freeze", name, t)  name = L1 L2 L3 Heavy Slam SlamLand Backflip FlipLand Dodge Draw Carry
-- Invoke("walk", phase, runF)  runF 0 = walk, 1 = sprint
-- Invoke("walk", phase) / Invoke("dodge") / Invoke("flip") / Invoke("release")
local debugFn = Instance.new("BindableFunction")
debugFn.Name = "DescentCombatDebug"
debugFn.OnInvoke = function(cmd, a, b)
	local ch = player.Character
	local r = ch and findRig(ch)
	if not r then
		return "no rig"
	end
	if cmd == "freeze" then
		local keys, meta
		if a == "L1" or a == "L2" or a == "L3" or a == "L4" then
			local step = tonumber(string.sub(a, 2))
			local tm = cfg.Light[step]
			keys = MOVES[a](tm.Windup, tm.Strike, tm.Recover)
			meta = { kind = "Light", step = step, layerName = "LightFull", spline = true }
		elseif a == "Guard" then
			keys, meta = { { at = 0.1, pose = GUARD } }, { kind = "Guard", layerName = "Guard", spline = true }
		elseif a == "Heavy" then
			keys = MOVES.Heavy(cfg.Heavy.Windup, cfg.Heavy.Strike, cfg.Heavy.Recover)
			meta = { kind = "Heavy" }
		elseif a == "Ultimate" then
			keys, meta = MOVES.Ultimate(), { kind = "Ultimate" }
		elseif a == "Slam" then
			keys, meta = MOVES.Slam(cfg.Slam.Windup), { kind = "Slam" }
		elseif a == "SlamLand" then
			keys, meta = MOVES.SlamLand(), { kind = "SlamLand" }
		elseif a == "Backflip" then
			keys, meta = MOVES.Backflip(), { kind = "Backflip" }
		elseif a == "FlipLand" then
			keys, meta = MOVES.FlipLand(), { kind = "FlipLand" }
		elseif a == "Dodge" then
			keys, meta = MOVES.Dodge(1, 0, cfg.Dodge.Duration), { kind = "Dodge" }
		elseif a == "Draw" then
			keys, meta = MOVES.Draw(), { kind = "Draw" }
		else
			r.move = nil
			r.freeze = 0
			return "carry"
		end
		r.move = buildMove(CARRY, keys, meta)
		r.move.t = b or 0
		r.move.hold = true
		r.freeze = 1e9
		r.guardUntil = os.clock() + 1e6
	elseif cmd == "walk" then
		r.debugWalk = a
		r.debugRun = b
	elseif cmd == "dodge" then
		lastDodge = -10
		tryDodge()
	elseif cmd == "flip" then
		local hum, root = r.hum, r.hroot
		lastBackDodge = os.clock()
		lastBackDir = -flatLook(root)
		lastFlip = -10
		doBackflip(ch, hum, root)
	elseif cmd == "release" then
		r.freeze = 0
		r.move = nil
		r.debugWalk = nil
		r.debugRun = nil
	end
	return "ok"
end
debugFn.Parent = player
