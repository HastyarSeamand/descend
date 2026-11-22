-- The Descent: no cursor icon in shift lock.
-- Hide the mouse icon only while the pointer is locked to the centre.
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

RunService.RenderStepped:Connect(function()
	local locked = UIS.MouseBehavior == Enum.MouseBehavior.LockCenter
	if UIS.MouseIconEnabled == locked then
		UIS.MouseIconEnabled = not locked
	end
end)
