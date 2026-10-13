--!strict
--[[
	Overgrown cities and the roads between them (the zombie apocalypse's ruins), decided from the
	raw terrain only: the raw Relief (`raw`), the raw biome (`rawBiome`), the seed and Util/Hash,
	never the generator's `column` or `sample` (which read the wrapped relief this module makes:
	that would recurse).

	  relief       the wrapped Relief: cities level their footprint (cut and fill to the
	               plateau's height, blended over Margin) and roads grade their corridor; `u` and
	               `s` stay raw, so biomes never shift. Untouched ground is a raw pass-through.
	  prepare      warms every cache `relief`, `surface` and the rest may need in a rectangle,
	               calling `yield` as it goes (Generation/TerrainGenerator's `generate` prepares
	               its padded chunk; the map and the spawn search prepare first too).
	  surface      the top block override of a column (asphalt, road lines, sidewalks, grass and
	               moss patches, potholes) and its filler, or nil for natural ground; overridden
	               columns skip the generator's steep rule.
	  blocked      x0, z0, x1, z1 boxes whose union covers every city footprint + Margin and every
	               candidate road corridor in a rectangle: where the wrapper or the surface may
	               differ from the raw terrain. Cheap and conservative (existence tests only, never
	               a road plan). Every planner (lakes, wells, lava, mineshafts, outposts, surface
	               caves, bunkers) keeps out of it, so whatever they accept stands on ground the
	               wrapper leaves alone.
	  protects     exactly: a footprint + Margin, or a built road + Blend (no surface cave there).
	  treeAllowed  trees grow here (not on asphalt, sidewalks or building lots).
	  top          the first air above the highest building block a chunk's level-`level` node
	               at (originX, originZ) holds (the generator's `needed`), nil: none.
	  write        the buildings, streets' decay, overgrowth, cars and loot containers into a
	               padded chunk (levels 0..Config.Cities.LodLevels): the lowest cell written (huge:
	               none) and the first empty cell above.
	  container    a generated container's loot (Generation/ScavengeLoot), nil: none there.
	  poiBlocks    the containers in a rectangle whose blocks `lut` marks (x, y, z, block each).
	  locateKind   /locate structure city's kind (Generation/Locate).
	  cityAt       1 inside a city, 0 outside, between in its margin.
	  sites, roads every city site and road segment in a rectangle (the map's overlay).
	  bunkerSpots  x, y (the ground: first air), z of each bunker shed's hatch (Generation/Bunkers).
	  spawnShift   findSpawn's last step: from the raw spawn (x, z), a spawn 150-400 blocks
	               outside the margin of the nearest site within 3 km whose column passes `ok`;
	               (x, z) itself when there is no site or no candidate passes.

	`new` builds them from the seed (Config.Cities); `none` is what a world without ruins uses: the
	raw relief, no override, nothing blocked. (For now `new` returns `none` too: the cities
	themselves come with their own work, behind this interface.)
]]

local Config = require(script.Parent.Parent.Config)
local Relief = require(script.Parent.Relief)
local Locate = require(script.Parent.Locate)
local StructureGen = require(script.Parent.StructureGen)

export type Site = { gx: number, gz: number, x: number, z: number, radius: number, y: number, salt: number }
export type Segment = { x0: number, z0: number, x1: number, z1: number, y0: number, y1: number, link: number }
export type WriteArgs = {
	data: buffer,
	cells: number,
	level: number,
	originX: number,
	originZ: number,
	heights: { number },
	topCells: { number },
	biomes: { number },
}
export type Cities = {
	-- The wrapped relief (cut and fill).
	relief: Relief.Relief,
	prepare: (minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?) -> (),
	surface: (x: number, z: number, h: number, level: number) -> (number?, number?),
	blocked: (minX: number, minZ: number, maxX: number, maxZ: number) -> { number },
	protects: (x: number, z: number) -> boolean,
	treeAllowed: (x: number, z: number) -> boolean,
	top: (level: number, originX: number, originZ: number) -> number?,
	write: (args: WriteArgs, yield: (() -> ())?) -> (number, number),
	container: (x: number, y: number, z: number) -> { StructureGen.ContainerItem }?,
	poiBlocks: (
		minX: number,
		minZ: number,
		maxX: number,
		maxZ: number,
		lut: buffer,
		out: { number },
		yield: (() -> ())?
	) -> (),
	locateKind: () -> Locate.Kind,
	cityAt: (x: number, z: number) -> number,
	sites: (minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?) -> { Site },
	roads: (minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?) -> { Segment },
	bunkerSpots: (minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?) -> { number },
	spawnShift: (
		x: number,
		z: number,
		ok: (x: number, z: number) -> boolean,
		yield: (() -> ())?
	) -> (number, number),
}

-- What `new` needs besides the raw relief: the raw biome of a column and the sea's surface.
export type Options = { rawBiome: (x: number, z: number) -> number, seaLevel: number }

local Cities = {}

-- /locate structure city's kind with no city anywhere: every probe answers nothing.
local function noKind(): Locate.Kind
	local grid = Config.Cities.Grid
	return {
		id = "city",
		grid = grid,
		slack = 0,
		rings = math.ceil(Config.Locate.Radius.city / grid),
		showY = false,
		probe = function(_gx: number, _gz: number): (number?, number, number)
			return nil, 0, 0
		end,
	}
end

-- No cities: the raw relief, natural ground everywhere, nothing blocked (see the header).
function Cities.none(raw: Relief.Relief): Cities
	return {
		relief = raw,
		prepare = function(_minX: number, _minZ: number, _maxX: number, _maxZ: number, _yield: (() -> ())?) end,
		surface = function(_x: number, _z: number, _h: number, _level: number): (number?, number?)
			return nil, nil
		end,
		blocked = function(_minX: number, _minZ: number, _maxX: number, _maxZ: number): { number }
			return {}
		end,
		protects = function(_x: number, _z: number): boolean
			return false
		end,
		treeAllowed = function(_x: number, _z: number): boolean
			return true
		end,
		top = function(_level: number, _originX: number, _originZ: number): number?
			return nil
		end,
		write = function(_args: WriteArgs, _yield: (() -> ())?): (number, number)
			return math.huge, 0
		end,
		container = function(_x: number, _y: number, _z: number): { StructureGen.ContainerItem }?
			return nil
		end,
		poiBlocks = function(
			_minX: number,
			_minZ: number,
			_maxX: number,
			_maxZ: number,
			_lut: buffer,
			_out: { number },
			_yield: (() -> ())?
		)
		end,
		locateKind = noKind,
		cityAt = function(_x: number, _z: number): number
			return 0
		end,
		sites = function(_minX: number, _minZ: number, _maxX: number, _maxZ: number, _yield: (() -> ())?): { Site }
			return {}
		end,
		roads = function(_minX: number, _minZ: number, _maxX: number, _maxZ: number, _yield: (() -> ())?): { Segment }
			return {}
		end,
		bunkerSpots = function(
			_minX: number,
			_minZ: number,
			_maxX: number,
			_maxZ: number,
			_yield: (() -> ())?
		): { number }
			return {}
		end,
		spawnShift = function(
			x: number,
			z: number,
			_ok: (x: number, z: number) -> boolean,
			_yield: (() -> ())?
		): (number, number)
			return x, z
		end,
	}
end

-- The cities of world `seed` over the raw relief `raw` (see the header).
function Cities.new(_seed: number, raw: Relief.Relief, _options: Options): Cities
	return Cities.none(raw)
end

return Cities
