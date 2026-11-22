local HttpService = game:GetService("HttpService")
local authored = HttpService:JSONDecode(require(script.Parent.MotionData))

local Motion = {}

-- Attack is already normalized by the AI. Its 0.55 pose is the damage beat.
-- Other non-looping clips receive real seconds from the state controller.
local contact = require(script.Parent.Roster).Contact
local hurtDuration = 0.25
local deathDuration = 1.12
local flier = "Needlewing"

local stridePeriods = {
	Knuckler = 0.65,
	Hookjaw = 0.43,
	CinderPorter = 0.71,
	Graveplate = 0.74,
	Bellwretch = 0.70,
	Needlewing = 0.37,
	Shardling = 0.37,
	CairnGiant = 0.96,
}

local function toCFrame(values)
	return CFrame.new(values[4] or 0, values[5] or 0, values[6] or 0) * CFrame.Angles(
		math.rad(values[1] or 0),
		math.rad(values[2] or 0),
		math.rad(values[3] or 0)
	)
end

local function compileClips(data)
	local compiled = {}
	for id, clips in pairs(data) do
		compiled[id] = {}
		for name, keyedFrames in pairs(clips) do
			local jointNames = {}
			local frames = {}
			for _, keyedFrame in ipairs(keyedFrames) do
				local frame = { time = keyedFrame[1], poses = {} }
				for joint, values in pairs(keyedFrame[2]) do
					jointNames[joint] = true
					frame.poses[joint] = toCFrame(values)
				end
				table.insert(frames, frame)
			end
			compiled[id][name] = { frames = frames, joints = jointNames }
		end
	end
	return compiled
end

local clipsById = compileClips(authored)

local function phaseFor(id, name, elapsed)
	if name == "Attack" then
		return math.clamp(elapsed, 0, 1)
	elseif name == "Hurt" then
		return math.clamp(elapsed / hurtDuration, 0, 1)
	elseif name == "Death" then
		return math.clamp(elapsed / deathDuration, 0, 1)
	elseif name == "Walk" then
		return elapsed / stridePeriods[id] % 1
	elseif name == "Guard" then
		if elapsed < 0.18 then
			return elapsed
		end
		local breath = (1 - math.cos((elapsed - 0.18) * math.pi * 0.8)) * 0.5
		return 0.18 + breath * 0.34
	end
	return elapsed / (if id == flier then 0.56 else 2.35) % 1
end

local function framePair(frames, phase)
	for index = 2, #frames do
		local nextFrame = frames[index]
		if phase <= nextFrame.time then
			return frames[index - 1], nextFrame
		end
	end
	return frames[#frames - 1], frames[#frames]
end

function Motion.sample(id, name, elapsed, moveAlpha)
	local clip = clipsById[id][name]
	local phase = phaseFor(id, name, elapsed)
	local earlier, later = framePair(clip.frames, phase)
	local alpha = (phase - earlier.time) / (later.time - earlier.time)
	if name ~= "Attack" or (later.time ~= contact and earlier.time ~= contact) then
		alpha = alpha * alpha * (3 - 2 * alpha)
	end

	-- A partial stride blends between the rest pose and the full gait.
	local weight = if name == "Walk" and id ~= flier then math.clamp(moveAlpha or 1, 0, 1) else 1
	local sampled = {}
	for joint in pairs(clip.joints) do
		local previous = earlier.poses[joint] or CFrame.identity
		local nextPose = later.poses[joint] or CFrame.identity
		local pose = previous:Lerp(nextPose, alpha)
		sampled[joint] = if weight == 1 then pose else CFrame.identity:Lerp(pose, weight)
	end
	return sampled
end

return Motion
