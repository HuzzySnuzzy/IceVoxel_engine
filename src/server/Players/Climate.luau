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
	  wet, sprinting, burning
	                    the player's own (Players/ToughAsNails: water touching the standing box,
	                    the client's sprint flag, burning)
	  armorWarmth, armorCooling
	                    the insulation of the armor worn (`insulation`: ItemList `tan` summed over
	                    the four armor slots; Players/ToughAsNails passes it in the Body)
	  heated, nearHeat, cooled
	                    a heating block in the cube Config.ToughAsNails.ProximityRadius blocks out
	                    each way around the feet, one within Temperature.NEAR (2) of them, a
	                    cooling block in the cube (TAN's proximity modifier; `sources` gives the
	                    nearest of each, in blocks along the farthest axis)

	Heat and cold sources (TAN's heating_blocks and cooling_blocks tags): Config.ToughAsNails
	.HeatingBlocks and .CoolingBlocks, by fluid name (every level of the fluid and its cave twin:
	"Lava") or block name ("Fire", "Campfire", "Ice"). A name no block or fluid has is skipped with
	a warning, so a block can be named before it exists (it warms from the moment BlockList has
	one). Blocks that warm only in some state register a check (`addHeatSource(block, check)`: a
	furnace while lit, a generator while working; Players/ToughAsNails registers those), and
	anything else may add its own the same way, e.g. a brazier that is lit only sometimes:
	`Climate.addHeatSource("Brazier", isLit)`. A check runs only for a block of its kind within
	range, once a second per player, and never for one farther than the nearest source found so
	far. (Within Temperature.NEAR of a heat source, the cold sources around no longer cool.)
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
	-- Steps of insulation of the armor worn (`insulation`).
	armorWarmth: number,
	armorCooling: number,
}

-- A check for a heat source that warms only in some state (true: it warms now).
export type Check = (x: number, y: number, z: number, block: number) -> boolean

local Climate = {}

-- Eye height of a standing player (blocks above the feet): where the roof is looked for.
local EYES = 1.62

-- Per block id: heating (true, or a check) and cooling.
local heating: { [number]: true | Check } = {}
local cooling: { [number]: boolean } = {}

-- The block ids a name means: a fluid's every block, else the block of that name (none: a
-- warning, see the header).
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
	local id = Blocks.find(name)
	if id == nil then
		warn(`Tough As Nails: no block named {name} to warm or cool; skipped`)
		return {}
	end
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
	while `check` says so. Returns how many block ids it covers (0: an unknown name, skipped).
]]
function Climate.addHeatSource(block: number | string, check: Check?): number
	local ids = blocksOf(block)
	for _, id in ids do
		heating[id] = check or true
	end
	return #ids
end

-- Makes `block` (an id or a name) a cold source. Returns how many block ids it covers.
function Climate.addColdSource(block: number | string): number
	local ids = blocksOf(block)
	for _, id in ids do
		cooling[id] = true
	end
	return #ids
end

-- Does `block` heat (true for a source with a check: it might)? Does it cool?
function Climate.isHeating(block: number): boolean
	return heating[block] ~= nil
end

function Climate.isCooling(block: number): boolean
	return cooling[block] == true
end

--[[
	The Tough As Nails insulation of `armor` (Inventory armor slots): the steps of warmth and of
	cooling of the pieces worn (ItemList `tan`), and whether one is freeze immune.
]]
function Climate.insulation(armor: { [number]: Items.Stack? }): (number, number, boolean)
	local warmth, coolness, immune = 0, 0, false
	for slot = 1, 4 do
		local stack = armor[slot]
		local def = if stack then Items.get(stack.item) else nil
		local tan = if def then def.tan else nil
		if tan then
			warmth += tan.warmth
			coolness += tan.cooling
			immune = immune or tan.freezeImmune
		end
	end
	return warmth, coolness, immune
end

--[[
	The nearest heating block and cooling block within `radius` blocks of cell (x, y, z) (a cube),
	as their distance along the farthest axis (0: the feet's own cell), nil when there is none.
	Unknown cells are neither. A heat source's check runs only when it would be the nearest.
]]
function Climate.sources(view: View, x: number, y: number, z: number, radius: number): (number?, number?)
	local heat: number?, cold: number? = nil, nil
	local getBlock = view.getBlock
	for dy = -radius, radius do
		for dx = -radius, radius do
			for dz = -radius, radius do
				local block = getBlock(x + dx, y + dy, z + dz)
				if block then
					local distance = math.max(math.abs(dx), math.abs(dy), math.abs(dz))
					local source = heating[block]
					if source and (heat == nil or distance < heat) then
						if source == true or (source :: Check)(x + dx, y + dy, z + dz, block) then
							heat = distance
						end
					end
					if cooling[block] and (cold == nil or distance < cold) then
						cold = distance
					end
				end
			end
		end
	end
	return heat, cold
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
	local heat, cold = Climate.sources(view, cx, cy, cz, Config.ToughAsNails.ProximityRadius)
	return {
		climate = if biome then biome.temperature else 0,
		y = y,
		surface = surface,
		skyOpen = view.skyOpen(cx, math.floor(y + EYES), cz),
		night = not DayCycle.isDay(dayTime),
		wet = body.wet,
		sprinting = body.sprinting,
		heated = heat ~= nil,
		nearHeat = heat ~= nil and heat <= Temperature.NEAR,
		cooled = cold ~= nil,
		burning = body.burning,
		armorWarmth = body.armorWarmth,
		armorCooling = body.armorCooling,
	}
end

return Climate
