--!strict
--[[
	Hidden bunkers (the zombie apocalypse's safe havens): concrete rooms of cave air under a steel
	hatch over a ladder shaft, in the wild (a candidate per Config.Bunkers.Grid cell, decided from
	the raw terrain: Generation/TerrainGenerator hands over the raw height, biome and river) and
	under the cities' sheds (Generation/Cities `bunkerSpots`). Their lamps and cobwebs are cave
	twins, so a hidden bunker costs nothing to draw until a player finds it; their loot is
	Generation/ScavengeLoot's.

	  plans       every bunker whose bounds touch a rectangle (`yield` while plans are built)
	  keepOut     x0, z0, x1, z1: the hatch collars, which trees and surface caves keep out of at
	              every level
	  boxes       x0, y0, z0, x1, y1, z1: what underground lava lakes keep clear of
	  write       the plans into a padded full detail chunk after the mineshafts: the lowest cell
	              written (huge: none), the first empty cell above, and the cave lattice
	  container   a bunker container's loot, nil: none there
	  poiBlocks   the containers and hatches in a rectangle whose blocks `lut` marks
	  locateKind  /locate structure bunker's kind (Generation/Locate)

	`new` builds them; `none` is what a world without ruins uses. (For now `new` returns `none`:
	the bunkers themselves come with their own work, behind this interface.)
]]

local Config = require(script.Parent.Parent.Config)
local Caves = require(script.Parent.Caves)
local Cities = require(script.Parent.Cities)
local Locate = require(script.Parent.Locate)
local StructureGen = require(script.Parent.StructureGen)

-- A room of a bunker: its kind ("airlock", "corridor", "bunks", "storage", "medical",
-- "generator", "armory", "mess") and its outer box (x0, y0, z0, x1, y1, z1, the shell included).
export type Room = { kind: string, box: { number } }
export type Plan = {
	cellX: number,
	cellZ: number,
	x: number,
	y: number,
	z: number,
	salt: number,
	rooms: { Room },
	bounds: { number },
	hatch: { number },
	lit: boolean,
	overrun: boolean,
}
export type Bunkers = {
	plans: (minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?) -> { Plan },
	keepOut: (minX: number, minZ: number, maxX: number, maxZ: number) -> { number },
	boxes: (minX: number, minZ: number, maxX: number, maxZ: number) -> { number },
	write: (
		plans: { Plan },
		data: buffer,
		originX: number,
		originZ: number,
		cells: number,
		heights: { number },
		carved: Caves.Carved?
	) -> (number, number, Caves.Carved?),
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
}

-- The raw terrain (Generation/TerrainGenerator's: the raw relief's height, biome and river), what
-- wild bunkers keep out of (`blocked`: x0, z0, x1, z1 boxes: library pieces, wells, lakes,
-- puddles, mineshafts and the cities' blocked area), the spawn, where surface caves open, and
-- the cities (their sheds' spots).
export type Terrain = {
	height: (x: number, z: number) -> number,
	biome: (x: number, z: number) -> number,
	river: (x: number, z: number) -> number,
	blocked: (minX: number, minZ: number, maxX: number, maxZ: number, yield: (() -> ())?) -> { number },
	spawn: () -> (number, number),
	carvesTop: (x: number, z: number) -> boolean,
	cities: Cities.Cities,
}

local Bunkers = {}

-- /locate structure bunker's kind with no bunker anywhere: every probe answers nothing.
local function noKind(): Locate.Kind
	local grid = Config.Bunkers.Grid
	return {
		id = "bunker",
		grid = grid,
		slack = 0,
		rings = math.ceil(Config.Locate.Radius.bunker / grid),
		showY = true,
		probe = function(_gx: number, _gz: number): (number?, number, number)
			return nil, 0, 0
		end,
	}
end

-- No bunkers (see the header).
function Bunkers.none(): Bunkers
	return {
		plans = function(_minX: number, _minZ: number, _maxX: number, _maxZ: number, _yield: (() -> ())?): { Plan }
			return {}
		end,
		keepOut = function(_minX: number, _minZ: number, _maxX: number, _maxZ: number): { number }
			return {}
		end,
		boxes = function(_minX: number, _minZ: number, _maxX: number, _maxZ: number): { number }
			return {}
		end,
		write = function(
			_plans: { Plan },
			_data: buffer,
			_originX: number,
			_originZ: number,
			_cells: number,
			_heights: { number },
			carved: Caves.Carved?
		): (number, number, Caves.Carved?)
			return math.huge, 0, carved
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
	}
end

-- The bunkers of world `seed` over the raw `terrain` (see the header).
function Bunkers.new(_seed: number, _terrain: Terrain): Bunkers
	return Bunkers.none()
end

return Bunkers
