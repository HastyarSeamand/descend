-- ServerStorage.IslandBuilder (edit-time): writes an island's terrain (land, beach, sea, pond) from its layout module.
-- Usage: local L = require(<layout>:Clone()); local B = require(ServerStorage.IslandBuilder:Clone())
--        workspace.Terrain:Clear(); for z = L.Bounds.Z0, L.Bounds.Z1 - 40, 40 do B.chunk(L, z, z + 40); task.wait() end
local B = {}
function B.chunk(L, z0, z1)
	local T = workspace.Terrain
	local M = Enum.Material
	local RES = 4
	local Bd = L.Bounds
	local Y0, Y1 = -32, 120
	local region = Region3.new(Vector3.new(Bd.X0, Y0, z0), Vector3.new(Bd.X1, Y1, z1)):ExpandToGrid(RES)
	local minp = region.CFrame.Position - region.Size / 2
	local nx, ny, nz = region.Size.X / RES, region.Size.Y / RES, region.Size.Z / RES
	local mats, occs = table.create(nx), table.create(nx)
	local P = L.Pond
	for ix = 1, nx do
		local mx, ox = table.create(ny), table.create(ny)
		for iy = 1, ny do mx[iy] = table.create(nz, M.Air); ox[iy] = table.create(nz, 0) end
		mats[ix], occs[ix] = mx, ox
		local x = minp.X + (ix - 0.5) * RES
		for iz = 1, nz do
			local z = minp.Z + (iz - 0.5) * RES
			local h, cliffF, pd, pname, wet, k = L.height(x, z)
			local nn = math.noise(x / 14, z / 14, 2.2)
			local n2 = math.noise(x / 50, z / 50, 9.4)
			local slope = math.abs(L.height(x + 4, z) - h) + math.abs(L.height(x, z + 4) - h)
			local inPond = P and math.sqrt(((x - P.x) / P.rx) ^ 2 + ((z - P.z) / P.rz) ^ 2) < 1.25
			local waterTop = if inPond then L.PondLevel else L.Water
			local mat
			if cliffF > 0.45 or slope > 6 then mat = (n2 > 0 and M.Rock or M.Slate)
			elseif h < 2.2 and not inPond then mat = (if h < -4 then M.Sand else (nn > 0.35 and M.Ground or M.Sand))
			elseif inPond and h < L.PondLevel + 1 then mat = (nn > 0 and M.Mud or M.Ground)
			elseif pd < (if pname == "main" then 5 else 3.5) + 1.4 * nn then mat = M.Ground
			elseif slope > 4 then mat = (nn > 0 and M.Ground or M.Rock)
			else mat = (n2 + 0.4 * nn > 0.2 and M.LeafyGrass or M.Grass) end
			for iy = 1, ny do
				local yc = minp.Y + (iy - 0.5) * RES
				local o = math.clamp((h - (yc - RES / 2)) / RES, 0, 1)
				if o > 0 then
					occs[ix][iy][iz] = o
					mats[ix][iy][iz] = (yc < h - 8) and (if cliffF > 0.3 then M.Rock else M.Ground) or mat
				elseif yc - RES / 2 < waterTop and h < waterTop then
					occs[ix][iy][iz] = math.clamp((waterTop - (yc - RES / 2)) / RES, 0, 1)
					mats[ix][iy][iz] = M.Water
				end
			end
		end
	end
	T:WriteVoxels(region, RES, mats, occs)
end
return B
