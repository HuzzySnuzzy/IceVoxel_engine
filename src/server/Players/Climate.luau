--!strict
--[[
	What a player's surroundings say about their body temperature (Shared/ToughAsNails/Temperature's
	Environment), pure over a world view so the tests give their own (Players/ToughAsNails gives
	the server's: loaded blocks only, never generating terrain):

	  climate, surface  the column's surface biome (its Biomes temperature) and terrain height,
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

	Heat and cold sources (TAN's heating_blocks and cooling_blocks tags): Temperature.HEATING_BLOCKS
	and .COOLING_BLOCKS (the content packs' blocks with `heats` / `cools`), by fluid name (every
	level of the fluid and its cave twin: "Lava") or block name ("Fire", "Campfire", "Ice"). Blocks
	that warm only in some state register a check (`addHeatSource(block, check)`: a furnace while
	lit, a generator while working; Players/ToughAsNails registers those), and anything else may
	add its own the same way, e.g. a brazier that is lit only sometimes:
	`Climate.addHeatSource("Brazier", isLit)` (a name no block or fluid has is skipped with a
	warning, so a block can be named before it exists). A check runs only for a block of its kind within
	range, once a second per player, and never for one farther than the nearest source found so
	far. A source may have a reach of its own, at most the proximity radius (`radius`: the
	Electric Heater's Config.Seasons.Heat.SpaceHeaterRadius, the Electric Fan's FanRadius). (Within
	Temperature.NEAR of a heat source, the cold sources around no longer cool.) The season's own
	ice (View `seasonal`: what the weather froze, World/WorldServer.thawAt) is no cold source: the
	season's climate already carries that cold; placed and generated ice is.

	Seasons (Config.Seasons; Players/ToughAsNails passes them only while the calendar is on):
	  season            the season's sample (Shared/Seasons/SeasonClimate, for the column's
	                    biome class): its shift and night drop (Temperature's `seasonShift`,
	                    `nightDrop`)
	  room              the room the feet are in (View `room`: server Seasons/RoomWorld.sample),
	                    its air temperature (Temperature's `room`); in a room the proximity
	                    modifiers give way to `radiant`: a radiant heat source (fire, lava, a
	                    campfire, the stoves: `addHeatSource`'s `radiant`) within NEAR
	  snowedOn          snow falling at the feet or the head (View `snowing`:
	                    World/WeatherServer.snowingAt, open to the sky)
	Room sources (`addRoomSource(block, output, limit)`): what a block in a room or its walls
	gives the room's air, in HU a second (Config.Seasons.Heat; server Seasons/RoomWorld reads
	them through `roomSource`, so it never requires the machines): a Campfire 20, each Fire 15
	(at most 3 counted), each Lava block 10 (at most 6) here; Players/ToughAsNails registers the
	machines' (a lit Furnace 8, a working Heat or Combustion Generator 10, the heaters, coolers
	and stoves their `heat` field). Each player in a room gives PLAYER_HU.
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
local Rooms = require(Shared.Seasons.Rooms)
local SeasonClimate = require(Shared.Seasons.SeasonClimate)

-- What Climate reads of the world.
export type View = {
	-- The block at a cell, nil when unknown (not loaded).
	getBlock: (x: number, y: number, z: number) -> number?,
	-- The column's terrain height (first air block) and surface biome (Biomes index).
	column: (x: number, z: number) -> (number, number),
	-- Nothing opaque above cell (x, y, z)?
	skyOpen: (x: number, y: number, z: number) -> boolean,
	-- Seasons (see the header; nil: none): the room of the cell at the feet, and whether snow
	-- falls on a cell.
	room: ((x: number, y: number, z: number) -> Rooms.Sample?)?,
	snowing: ((x: number, y: number, z: number) -> boolean)?,
	-- Is the block at a cell the season's weather's (its ice; nil: none is)? No cold source.
	seasonal: ((x: number, y: number, z: number) -> boolean)?,
}

-- What a room source gives a room's air now (HU a second; negative cools).
export type RoomOutput = (x: number, y: number, z: number, block: number) -> number

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

-- Per block id: heating (true, or a check), radiant heating (a room's +2) and cooling (true,
-- or a check).
local heating: { [number]: true | Check } = {}
local radiant: { [number]: boolean } = {}
local cooling: { [number]: true | Check } = {}
-- Per block id: how far it warms or cools (nil: the proximity radius).
local reach: { [number]: number? } = {}
-- Per block id: what it gives a room's air, and the most of them counted in one room.
local roomSources: { [number]: RoomOutput } = {}
local roomLimits: { [number]: number? } = {}

-- HU each player in a room gives its air.
Climate.PLAYER_HU = Config.Seasons.Heat.Player

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

for _, name in Temperature.HEATING_BLOCKS do
	for _, id in idsOf(name) do
		heating[id] = true
		-- (Lava, fire and campfires warm by radiance: in a room too.)
		radiant[id] = true
	end
end
for _, name in Temperature.COOLING_BLOCKS do
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
	while `check` says so; `isRadiant`: it warms by radiance (fire, a stove), so it still warms in
	a room (see the header; nil keeps what it was); `radius`: it warms only that far (blocks
	along the farthest axis; nil: the whole proximity radius). Returns how many block ids it
	covers (0: an unknown name, skipped).
]]
function Climate.addHeatSource(block: number | string, check: Check?, isRadiant: boolean?, radius: number?): number
	local ids = blocksOf(block)
	for _, id in ids do
		heating[id] = check or true
		reach[id] = radius
		-- (Registering again without saying keeps whether it is radiant.)
		if isRadiant ~= nil then
			radiant[id] = isRadiant
		end
	end
	return #ids
end

-- Makes `block` (an id or a name) a cold source: always, or while `check` says so, within
-- `radius` (nil: the proximity radius). Returns how many block ids it covers.
function Climate.addColdSource(block: number | string, check: Check?, radius: number?): number
	local ids = blocksOf(block)
	for _, id in ids do
		cooling[id] = check or true
		reach[id] = radius
	end
	return #ids
end

--[[
	Makes `block` (an id or a name; a fluid name means all its blocks) a room source (see the
	header): `output` HU a second (a number, or what a function says now), at most `limit` of them
	counted in one room (nil: every one). Returns how many block ids it covers.
]]
function Climate.addRoomSource(block: number | string, output: number | RoomOutput, limit: number?): number
	local ids = blocksOf(block)
	local give: RoomOutput
	if type(output) == "number" then
		local value = output
		give = function(): number
			return value
		end
	else
		give = output
	end
	for _, id in ids do
		roomSources[id] = give
		roomLimits[id] = limit
	end
	return #ids
end

-- What `block` gives a room's air (its output function) and how many count in one room (nil:
-- every one); nil for a block that is no room source.
function Climate.roomSource(block: number): (RoomOutput?, number?)
	return roomSources[block], roomLimits[block]
end

-- Is `block` a radiant heat source?
function Climate.isRadiant(block: number): boolean
	return radiant[block] == true
end

do
	local heat = Config.Seasons.Heat
	Climate.addRoomSource("Campfire", heat.Campfire)
	Climate.addRoomSource("Fire", heat.Fire, heat.FireMax)
	Climate.addRoomSource("Lava", heat.Lava, heat.LavaMax)
end

-- Does `block` heat (true for a source with a check: it might)? Does it cool?
function Climate.isHeating(block: number): boolean
	return heating[block] ~= nil
end

function Climate.isCooling(block: number): boolean
	return cooling[block] ~= nil
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
	as their distance along the farthest axis (0: the feet's own cell), nil when there is none,
	and the nearest radiant heating block's. Unknown cells are neither, nor a source farther than
	its own radius. A source's check runs only when it would be the nearest.
]]
function Climate.sources(view: View, x: number, y: number, z: number, radius: number): (number?, number?, number?)
	local heat: number?, cold: number?, glow: number? = nil, nil, nil
	local getBlock = view.getBlock
	local seasonal = view.seasonal
	for dy = -radius, radius do
		for dx = -radius, radius do
			for dz = -radius, radius do
				local block = getBlock(x + dx, y + dy, z + dz)
				if block then
					local distance = math.max(math.abs(dx), math.abs(dy), math.abs(dz))
					local source = heating[block]
					if
						source
						and distance <= (reach[block] or radius)
						and (heat == nil or distance < heat or (radiant[block] and (glow == nil or distance < glow)))
					then
						if source == true or (source :: Check)(x + dx, y + dy, z + dz, block) then
							if heat == nil or distance < heat then
								heat = distance
							end
							if radiant[block] and (glow == nil or distance < glow) then
								glow = distance
							end
						end
					end
					local chill = cooling[block]
					if
						chill
						and distance <= (reach[block] or radius)
						and (cold == nil or distance < cold)
						and not (seasonal ~= nil and seasonal(x + dx, y + dy, z + dz))
					then
						if chill == true or (chill :: Check)(x + dx, y + dy, z + dz, block) then
							cold = distance
						end
					end
				end
			end
		end
	end
	return heat, cold, glow
end

--[[
	The environment of a player with feet at (x, y, z) (blocks) at day time `dayTime`, with their
	own `body` (see the header), and with the seasons' `season` (nil: none; then the view's room
	and snow are not looked at either).
]]
function Climate.environment(
	view: View,
	x: number,
	y: number,
	z: number,
	dayTime: number,
	body: Body,
	season: SeasonClimate.Sample?
): Temperature.Environment
	local cx, cy, cz = math.floor(x), math.floor(y), math.floor(z)
	local surface, biomeIndex = view.column(cx, cz)
	local biome = Biomes.get(biomeIndex)
	local heat, cold, glow = Climate.sources(view, cx, cy, cz, Config.ToughAsNails.ProximityRadius)
	local head = math.floor(y + EYES)
	local env: Temperature.Environment = {
		climate = if biome then biome.temperature else 0,
		y = y,
		surface = surface,
		skyOpen = view.skyOpen(cx, head, cz),
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
	if season then
		env.seasonShift = season.shift
		env.nightDrop = season.nightDrop
		local room = if view.room then view.room(cx, cy, cz) else nil
		if room then
			env.room = room.temperature
			env.radiant = glow ~= nil and glow <= Temperature.NEAR
		end
		local snowing = view.snowing
		env.snowedOn = snowing ~= nil and (snowing(cx, cy, cz) or snowing(cx, head, cz))
	end
	return env
end

return Climate
