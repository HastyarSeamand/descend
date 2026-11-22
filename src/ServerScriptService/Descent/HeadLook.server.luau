-- ServerScriptService.Descent.HeadLook  (Script)   -- new in map v4 / "map testing" Roblox version 8
-- Needs a RemoteEvent ReplicatedStorage.Descent.Remotes.HeadLookRequest

-- The Descent: HEAD LOOK replication.
-- Each client sends where its camera looks (yaw / pitch in degrees, about 10 times a second, only when it changes).
-- The server clamps it and stores it on the character as attributes HeadYaw / HeadPitch, so every other client
-- can turn that player's head too (CombatClient applies it on the Neck, on top of the animations).

local Players = game:GetService("Players")
local Remotes = game:GetService("ReplicatedStorage"):WaitForChild("Descent"):WaitForChild("Remotes")
local HeadLookRequest: RemoteEvent = Remotes:WaitForChild("HeadLookRequest")

local MAX_YAW, MAX_UP, MAX_DOWN = 70, 40, 35
local MIN_GAP = 0.05 -- ignore anything faster than 20 per second
local last = {}

HeadLookRequest.OnServerEvent:Connect(function(player: Player, yaw, pitch)
	if typeof(yaw) ~= "number" or typeof(pitch) ~= "number" or yaw ~= yaw or pitch ~= pitch then
		return
	end
	local t = os.clock()
	if t - (last[player] or 0) < MIN_GAP then
		return
	end
	last[player] = t
	local ch = player.Character
	if not ch then
		return
	end
	ch:SetAttribute("HeadYaw", math.clamp(math.floor(yaw + 0.5), -MAX_YAW, MAX_YAW))
	ch:SetAttribute("HeadPitch", math.clamp(math.floor(pitch + 0.5), -MAX_DOWN, MAX_UP))
end)

Players.PlayerRemoving:Connect(function(p)
	last[p] = nil
end)
