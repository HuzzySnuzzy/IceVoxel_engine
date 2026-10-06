--!strict
--[[
	What a player's surroundings say about their body temperature (Shared/ToughAsNails/Temperature's
	Environment), pure over a world view so the tests give their own (Players/ToughAsNails gives
	the server's: loaded blocks only, never generating terrain):

	  climate, surface  the column's surface biome (its BiomeList temperature) and terrain height,
	                    from the generator's column (TerrainGenerator.column: what the world was
	                    generated with, edits aside)
	  skyOpen           nothing opaque above the head (Machines/SkyCheck: a roof of glass, leaves
	                    or torches is no roof)
	  night             not DayCycle.isDay at the server's clock
	  wet, sprinting, leather, burning
	                    the player's own (Players/ToughAsNails: water touching the standing box,
	                    the client's sprint flag, the armor worn, burning)
	  heated, cooled    a heating or cooling block in the cube Config.ToughAsNails.ProximityRadius
	                    blocks out each way around the feet (TAN's proximity modifier; burning
	                    counts as heated)

	Heat and cold sources (TAN's heating_blocks and cooling_blocks tags): Config.ToughAsNails
	.HeatingBlocks and .CoolingBlocks, by fluid name (every level of the fluid and its cave twin:
	"Lava") or block name ("Fire", "Ice"). Blocks that warm only in some state register a check
	(`addHeatSource(block, check)`: a furnace while lit, a generator while working;
	Players/ToughAsNails registers those), and anything else may add its own the same way, e.g. a
	campfire: `Climate.addHeatSource(Blocks.id.Campfire)`. A check runs only for a block of its kind
	within range, once a second per player.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Biomes = require(Shared.Biomes)
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local DayCycle = require(Shared.DayCycle)
local Fluids = require(Shared.Fluids)
local Items = require(Shared.Items)
local Temperature = require(Shared.ToughAsNails.Temperature)

-- What Climate reads of the world.
export type View = {
	-- The block at a cell, nil when unknown (not loaded).
	getBlock: (x: number, y: number, z: number) -> number?,
	-- The column's terrain height (first air block) and surface biome (Biomes index).
	column: (x: number, z: number) -> (number, number),
	-- Nothing opaque above cell (x, y, z)?
	skyOpen: (x: number, y: number, z: number) -> boolean,
}

-- The player's own part of the environment.
export type Body = {
	wet: boolean,
	sprinting: boolean,
	burning: boolean,
	-- Leather armor pieces worn.
	leather: number,
}

-- A check for a heat source that warms only in some state (true: it warms now).
export type Check = (x: number, y: number, z: number, block: number) -> boolean

local Climate = {}

-- Eye height of a standing player (blocks above the feet): where the roof is looked for.
local EYES = 1.62

-- Per block id: heating (true, or a check) and cooling.
local heating: { [number]: true | Check } = {}
local cooling: { [number]: boolean } = {}

-- The block ids a Config name means: a fluid's every block, else the block of that name.
local function idsOf(name: string): { number }
	local fluid = Fluids.find(name)
	if fluid then
		local ids = {}
		for id = 0, Blocks.count - 1 do
			if Fluids.ofBlock(id) == fluid then
				table.insert(ids, id)
			end
		end
		return ids
	end
	local id = Blocks.id[name]
	assert(id, `Config.ToughAsNails names unknown block {name}`)
	return { id }
end

for _, name in Config.ToughAsNails.HeatingBlocks do
	for _, id in idsOf(name) do
		heating[id] = true
	end
end
for _, name in Config.ToughAsNails.CoolingBlocks do
	for _, id in idsOf(name) do
		cooling[id] = true
	end
end

-- The block ids an id or a name means.
local function blocksOf(block: number | string): { number }
	if type(block) == "string" then
		return idsOf(block)
	end
	return { block :: number }
end

--[[
	Makes `block` (an id or a name; a fluid name means all its blocks) a heat source: always, or
	while `check` says so.
]]
function Climate.addHeatSource(block: number | string, check: Check?)
	local ids = blocksOf(block)
	for _, id in ids do
		heating[id] = check or true
	end
end

-- Makes `block` (an id or a name) a cold source.
function Climate.addColdSource(block: number | string)
	local ids = blocksOf(block)
	for _, id in ids do
		cooling[id] = true
	end
end

-- Does `block` heat (true for a source with a check: it might)? Does it cool?
function Climate.isHeating(block: number): boolean
	return heating[block] ~= nil
end

function Climate.isCooling(block: number): boolean
	return cooling[block] == true
end

-- Leather armor pieces in `armor` (Inventory armor slots).
local LEATHER: { [number]: boolean } = {}
for _, piece in { "Helmet", "Chestplate", "Leggings", "Boots" } do
	LEATHER[Items.id["Leather" .. piece]] = true
end
function Climate.leatherPieces(armor: { [number]: Items.Stack? }): number
	local count = 0
	for slot = 1, 4 do
		local stack = armor[slot]
		if stack and LEATHER[stack.item] then
			count += 1
		end
	end
	return count
end

--[[
	Is there a heating block, a cooling block, within `radius` blocks of cell (x, y, z) (a cube)?
	Unknown cells are neither.
]]
function Climate.sources(view: View, x: number, y: number, z: number, radius: number): (boolean, boolean)
	local heated, cooled = false, false
	local getBlock = view.getBlock
	for dy = -radius, radius do
		for dx = -radius, radius do
			for dz = -radius, radius do
				local block = getBlock(x + dx, y + dy, z + dz)
				if block then
					local heat = heating[block]
					if heat and not heated then
						heated = heat == true or (heat :: Check)(x + dx, y + dy, z + dz, block)
					end
					if cooling[block] then
						cooled = true
					end
					if heated and cooled then
						return true, true
					end
				end
			end
		end
	end
	return heated, cooled
end

--[[
	The environment of a player with feet at (x, y, z) (blocks) at day time `dayTime`, with their
	own `body` (see the header).
]]
function Climate.environment(
	view: View,
	x: number,
	y: number,
	z: number,
	dayTime: number,
	body: Body
): Temperature.Environment
	local cx, cy, cz = math.floor(x), math.floor(y), math.floor(z)
	local surface, biomeIndex = view.column(cx, cz)
	local biome = Biomes.get(biomeIndex)
	local heated, cooled = Climate.sources(view, cx, cy, cz, Config.ToughAsNails.ProximityRadius)
	return {
		climate = if biome then biome.temperature else 0,
		y = y,
		surface = surface,
		skyOpen = view.skyOpen(cx, math.floor(y + EYES), cz),
		night = not DayCycle.isDay(dayTime),
		wet = body.wet,
		sprinting = body.sprinting,
		heated = heated or body.burning,
		cooled = cooled,
		leather = body.leather,
	}
end

return Climate
