--!strict
--[[
	Minecraft's light levels estimated from the blocks (pure, shared): the engine keeps no light
	map, so whoever needs a light level works it out from the blocks around. One estimate for
	everyone: the server's mob spawning (Mobs/MobSpawning: monsters in the dark, animals in the
	light), the client's WAILA "Light level" line (Ui/Waila) and its cave mood (Audio/CaveMood).

	  Block light  `blockLight`: a light source's level (Blocks.light: torches 14, lava, glow
	               blocks and lanterns 15, glow lichen 7) less one per block face it travels
	               through open (not opaque) cells, as Minecraft's light spreads: a breadth first
	               search from the cell through open cells, at most BLOCK_BUDGET of them, stopping
	               once nothing farther could be brighter. An opaque cell has its own light only.
	               Unknown (unloaded) cells stop the light.
	  Sky light    `skyLight`: 15 in a cell under the open sky (`open`: the server's
	               World/Skylight.open, nothing opaque above it), else 15 less one per step to the
	               nearest such cell through open cells (Minecraft's sky light creeping into an
	               overhang or a cave mouth), searched over at most SKY_BUDGET cells (0 beyond: a
	               cave). The client's own sky estimate (Rendering/SkyExposure, rays into tunnels)
	               is finer and stays its own; this one is cheap for the server.
	  Monsters     `darkForMonsters` is Minecraft 1.20.1's Monster.isDarkEnoughToSpawn for the
	               overworld: block light at most 0 (monster_spawn_block_light_limit), and the sky
	               light passes two rolls: not above rand(32), then the raw brightness (the sky
	               light less the time of day's darkening, DayCycle.skyDarken: 0 at noon, 11 at
	               night; or the block light if more) at most rand(0..7)
	               (monster_spawn_light_level). So by day only spots out of the sky's reach (sky
	               light 0..7 after both rolls) take monsters, at night half the open ground does.
	  Animals      `brightForAnimals`: Animal.isBrightEnoughToSpawn, raw brightness (sky light
	               not darkened by the night, or block light) above 8.

	Units are blocks.
]]

local Blocks = require(script.Parent.Parent.Blocks)

-- The block at a cell, nil where it isn't loaded.
export type GetBlock = (x: number, y: number, z: number) -> number?
-- Is the cell under the open sky (nil: not loaded)?
export type Open = (x: number, y: number, z: number) -> boolean?
-- A random integer in [0, n).
export type NextInt = (n: number) -> number

local LightEstimate = {}

LightEstimate.MAX = 15
-- Open cells the block light search may visit: a tunnel's light reaches its full 14 blocks, a
-- big cavern's is searched a few blocks around (missing torches farther off). Measured on
-- generated caves (interpreted Luau): ~0.2 ms a search on average.
LightEstimate.BLOCK_BUDGET = 256
-- Cells the sky light search may visit (and ask `open` about) away from the open sky.
LightEstimate.SKY_BUDGET = 48
-- Raw brightness an animal needs above (Animal.isBrightEnoughToSpawn: > 8).
LightEstimate.ANIMAL_LIGHT = 8
-- Monster spawning: the sky light roll (rand(32)) and the brightness roll (0..7).
LightEstimate.SKY_ROLL = 32
LightEstimate.MONSTER_LIGHT = 7

local MAX_LIGHT = LightEstimate.MAX

-- Scratch for the searches, reused by every call: the frontier as flat x, y, z lists and a
-- visited stamp per cell offset from the start (within 32 each way), so a search allocates
-- nothing.
local SPAN = 64
local visited = buffer.create(SPAN * SPAN * SPAN * 2)
local stamp = 0
local frontier: { number } = {}
local nextFrontier: { number } = {}

local function offsetKey(dx: number, dy: number, dz: number): number
	return (((dx + 32) * SPAN + (dy + 32)) * SPAN + (dz + 32)) * 2
end

local function nextStamp()
	stamp += 1
	if stamp > 65535 then
		buffer.fill(visited, 0, 0)
		stamp = 1
	end
end

--[[
	Minecraft's block light (0..15) at cell (x, y, z), from the blocks (see the header). At most
	`budget` open cells are searched (BLOCK_BUDGET).
]]
function LightEstimate.blockLight(getBlock: GetBlock, x: number, y: number, z: number, budget: number?): number
	local start = getBlock(x, y, z)
	if start == nil then
		return 0
	end
	local own = Blocks.light(start)
	if Blocks.isOpaque(start) then
		return own
	end
	local best = own
	local limit = budget or LightEstimate.BLOCK_BUDGET
	nextStamp()
	buffer.writeu16(visited, offsetKey(0, 0, 0), stamp)
	table.clear(frontier)
	frontier[1], frontier[2], frontier[3] = 0, 0, 0
	local count = 1
	local distance = 0
	-- Breadth first: cells at distance d come before d + 1, so once a source found can't be beaten
	-- by anything farther (MAX_LIGHT - (d + 1) <= best) the search stops.
	while #frontier > 0 and MAX_LIGHT - (distance + 1) > best do
		table.clear(nextFrontier)
		for i = 1, #frontier, 3 do
			local cx, cy, cz = frontier[i], frontier[i + 1], frontier[i + 2]
			for side = 1, 6 do
				local dx = if side == 1 then 1 elseif side == 2 then -1 else 0
				local dy = if side == 3 then 1 elseif side == 4 then -1 else 0
				local dz = if side == 5 then 1 elseif side == 6 then -1 else 0
				local nx, ny, nz = cx + dx, cy + dy, cz + dz
				if nx >= -31 and nx <= 31 and ny >= -31 and ny <= 31 and nz >= -31 and nz <= 31 then
					local key = offsetKey(nx, ny, nz)
					if buffer.readu16(visited, key) ~= stamp then
						buffer.writeu16(visited, key, stamp)
						local block = getBlock(x + nx, y + ny, z + nz)
						if block then
							local emits = Blocks.light(block) - (distance + 1)
							if emits > best then
								best = emits
							end
							if count < limit and not Blocks.isOpaque(block) then
								count += 1
								local n = #nextFrontier
								nextFrontier[n + 1], nextFrontier[n + 2], nextFrontier[n + 3] = nx, ny, nz
							end
						end
					end
				end
			end
		end
		frontier, nextFrontier = nextFrontier, frontier
		distance += 1
	end
	return math.max(best, 0)
end

--[[
	Minecraft's sky light (0..15, not darkened by the time of day) at cell (x, y, z): 15 under the
	open sky, less one a step from the nearest open cell (see the header). An opaque or unloaded
	cell has none.
]]
function LightEstimate.skyLight(
	getBlock: GetBlock,
	open: Open,
	x: number,
	y: number,
	z: number,
	budget: number?
): number
	local start = getBlock(x, y, z)
	if start == nil or Blocks.isOpaque(start) then
		return 0
	end
	if open(x, y, z) == true then
		return MAX_LIGHT
	end
	local limit = budget or LightEstimate.SKY_BUDGET
	nextStamp()
	buffer.writeu16(visited, offsetKey(0, 0, 0), stamp)
	table.clear(frontier)
	frontier[1], frontier[2], frontier[3] = 0, 0, 0
	local count = 1
	local distance = 0
	while #frontier > 0 and distance < MAX_LIGHT do
		table.clear(nextFrontier)
		for i = 1, #frontier, 3 do
			local cx, cy, cz = frontier[i], frontier[i + 1], frontier[i + 2]
			for side = 1, 6 do
				local dx = if side == 1 then 1 elseif side == 2 then -1 else 0
				local dy = if side == 3 then 1 elseif side == 4 then -1 else 0
				local dz = if side == 5 then 1 elseif side == 6 then -1 else 0
				local nx, ny, nz = cx + dx, cy + dy, cz + dz
				if nx >= -31 and nx <= 31 and ny >= -31 and ny <= 31 and nz >= -31 and nz <= 31 then
					local key = offsetKey(nx, ny, nz)
					if buffer.readu16(visited, key) ~= stamp then
						buffer.writeu16(visited, key, stamp)
						local block = getBlock(x + nx, y + ny, z + nz)
						if block and not Blocks.isOpaque(block) and count < limit then
							count += 1
							if open(x + nx, y + ny, z + nz) == true then
								return MAX_LIGHT - (distance + 1)
							end
							local n = #nextFrontier
							nextFrontier[n + 1], nextFrontier[n + 2], nextFrontier[n + 3] = nx, ny, nz
						end
					end
				end
			end
		end
		frontier, nextFrontier = nextFrontier, frontier
		distance += 1
	end
	return 0
end

--[[
	Monster.isDarkEnoughToSpawn (see the header): `sky` and `block` light at the cell, the time of
	day's sky darkening (DayCycle.skyDarken: 0..11) and `nextInt` for the rolls.
]]
function LightEstimate.darkForMonsters(sky: number, block: number, skyDarken: number, nextInt: NextInt): boolean
	if block > 0 then
		return false
	end
	if sky > nextInt(LightEstimate.SKY_ROLL) then
		return false
	end
	local raw = math.max(sky - skyDarken, block)
	return raw <= nextInt(LightEstimate.MONSTER_LIGHT + 1)
end

-- Animal.isBrightEnoughToSpawn: raw brightness (sky light or block light) above 8.
function LightEstimate.brightForAnimals(sky: number, block: number): boolean
	return math.max(sky, block) > LightEstimate.ANIMAL_LIGHT
end

return LightEstimate
