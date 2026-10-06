--!strict
--[[
	How much sky light should reach the camera (0..1, DayCycle.skyExposure): the target the
	LightingController fades the sky's light (outdoor ambient, sun, sky box) towards.

	Roblox's sky occlusion only reaches so far, so the sky's light fades out with the camera's
	depth under the natural ground (the generator's height of its column), from Start to End
	blocks deep (Config.Lighting.Underground). That depth alone would also darken places open to
	the sky, so the block data around the camera can raise it:

	  up         nothing opaque above the camera (a pit or shaft open to the sky): the full light.
	  sideways   a tunnel dug into a hillside, or the bottom of a quarry under an overhang: the rock
	             above is deep, but the open air is a few blocks away. Rays step from the camera's
	             cell through loaded cells that are not opaque, up to End blocks: the 8 horizontal
	             directions, and the 8 rising at 45 degrees (stairs dug up to the surface). A cell
	             no deeper than Start under its own column's natural ground (where the camera would
	             get the full light itself), or open to the sky, gives 1 - distance / End. So a
	             tunnel darkens with the distance from its mouth, not the depth of the hill above.

	Surface caves (Generation/SurfaceCaves) are air below the natural ground like dug tunnels: a
	cave entrance is lit at its mouth and darkens with the distance from it (half light ~17 blocks
	in, dark from ~30 on a generated one), a ravine's floor is under the open sky (full light), and
	the deep caves beyond stay dark. Cheap enough for the controller's 10 updates a second: the
	rays stop at the first wall, at an unloaded cell and once they can't beat the best so far, and
	the sideways looks up for the sky share a budget.

	`skyLight` estimates Minecraft's sky light at any cell (0..15) the same way, for the cave mood
	(Audio/CaveMood): 0 in an opaque block, 15 under the open sky, else 15 less the steps to the
	nearest cell open to the sky along the same rays, counted as Minecraft's light spreads (one a
	block face, so a diagonal step costs two). Minecraft's leaves and water dim it too; here only
	opaque blocks stop it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local DayCycle = require(Shared.DayCycle)

-- Blocks above the natural ground still searched for a roof over an open pit (player builds).
local ROOF_MARGIN = 64
-- Cells the sideways looks for the sky may read in all (the tall ceilings of a closed cavern
-- would cost the most); the camera's own look up has no limit.
local SKY_BUDGET = 2048
-- The same for `skyLight` (the cave mood asks it once a game tick).
local SKY_LIGHT_BUDGET = 512

-- The sideways rays: { x, y, z step, length of a step }, horizontal and rising.
local RAYS: { { number } } = {}
for dy = 0, 1 do
	for dx = -1, 1 do
		for dz = -1, 1 do
			if dx ~= 0 or dz ~= 0 then
				table.insert(RAYS, { dx, dy, dz, math.sqrt(dx * dx + dy * dy + dz * dz) })
			end
		end
	end
end

-- The block at a cell, nil where it isn't loaded (which counts as rock).
export type GetBlock = (x: number, y: number, z: number) -> number?
-- The natural ground height (first air block) of column (x, z).
export type Ground = (x: number, z: number) -> number
export type Underground = { Start: number, End: number }

local SkyExposure = {}

--[[
	Is nothing opaque above cell (x, y, z), up to `top`? Unknown blocks count as a roof. Reads at
	most `budget` cells (out of budget: false), and returns what is left of it.
]]
local function openToSky(
	getBlock: GetBlock,
	x: number,
	y: number,
	z: number,
	top: number,
	budget: number
): (boolean, number)
	for cell = y, top do
		if budget <= 0 then
			return false, 0
		end
		budget -= 1
		local block = getBlock(x, cell, z)
		if block == nil or Blocks.isOpaque(block) then
			return false, budget
		end
	end
	return true, budget
end

-- The highest cell searched for a roof over column (x, z) whose natural ground is `height`.
local function roofTop(height: number): number
	return math.min(height + ROOF_MARGIN, Config.WorldHeight - 1)
end

--[[
	The best of `best` and the sideways rays from cell (x, y, z) (see the header). Breadth first,
	so near cells are looked at (and spend the sky budget) before far ones.
]]
local function sideways(
	getBlock: GetBlock,
	ground: Ground,
	x: number,
	y: number,
	z: number,
	settings: Underground,
	best: number
): number
	local start, finish = settings.Start, settings.End
	if finish <= 0 then
		return best
	end
	local budget = SKY_BUDGET
	local alive = table.create(#RAYS, true)
	for n = 1, math.floor(finish) do
		local any = false
		for i, ray in RAYS do
			if alive[i] then
				local reach = 1 - n * ray[4] / finish
				local cx, cy, cz = x + ray[1] * n, y + ray[2] * n, z + ray[3] * n
				local block = if reach > best then getBlock(cx, cy, cz) else nil
				if block == nil or Blocks.isOpaque(block) then
					alive[i] = false
				else
					local height = ground(cx, cz)
					local open = height - (cy + 0.5) <= start
					if not open then
						open, budget = openToSky(getBlock, cx, cy, cz, roofTop(height), budget)
					end
					if open then
						best = reach
						alive[i] = false
					else
						any = true
					end
				end
			end
		end
		if not any then
			break
		end
	end
	return best
end

--[[
	The sky light that should reach a camera at (x, y, z) (blocks), 1 outdoors to 0 deep
	underground. Without `getBlock` only the depth counts. `settings` defaults to
	Config.Lighting.Underground.
]]
function SkyExposure.target(
	x: number,
	y: number,
	z: number,
	ground: Ground,
	getBlock: GetBlock?,
	settings: Underground?
): number
	local underground: Underground = settings or Config.Lighting.Underground
	local bx, by, bz = math.floor(x), math.floor(y), math.floor(z)
	local height = ground(bx, bz)
	local target = DayCycle.skyExposure(height - y, underground.Start, underground.End)
	if target >= 1 or getBlock == nil then
		return target
	end
	if openToSky(getBlock, bx, by, bz, roofTop(height), math.huge) then
		return 1
	end
	return sideways(getBlock, ground, bx, by, bz, underground, target)
end

--[[
	Minecraft's sky light (0..15) at cell (x, y, z) (integers), from the blocks (see the header);
	nil where the cell isn't loaded.
]]
function SkyExposure.skyLight(x: number, y: number, z: number, ground: Ground, getBlock: GetBlock): number?
	local block = getBlock(x, y, z)
	if block == nil then
		return nil
	end
	if Blocks.isOpaque(block) then
		return 0
	end
	local top = roofTop(math.max(ground(x, z), y))
	if openToSky(getBlock, x, y, z, top, math.huge) then
		return 15
	end
	-- The nearest cell open to the sky along the rays, by the steps light takes to get here.
	local best = 0
	local budget = SKY_LIGHT_BUDGET
	for _, ray in RAYS do
		local cost = math.abs(ray[1]) + math.abs(ray[2]) + math.abs(ray[3])
		local n = 1
		while 15 - n * cost > best do
			local cx, cy, cz = x + ray[1] * n, y + ray[2] * n, z + ray[3] * n
			local cell = getBlock(cx, cy, cz)
			if cell == nil or Blocks.isOpaque(cell) then
				break
			end
			local open
			open, budget = openToSky(getBlock, cx, cy, cz, roofTop(math.max(ground(cx, cz), cy)), budget)
			if open then
				best = 15 - n * cost
				break
			end
			n += 1
		end
	end
	return best
end

return SkyExposure
