--!strict
--[[
	Rooms: enclosed, insulated spaces and their air's temperature, pure over a world view (server
	Seasons/RoomWorld owns them; Shared/Machines kinds use `thermostat`). Config.Seasons.Rooms.

	  Fill      `fill(view, x, y, z, limits)`: a 6-connected flood fill from the seed cell over
	            passable cells (Blocks.insulation nil: air, cave air, plants, torches, open doors,
	            fences, snow layers 1-7). A neighbour with an insulation is a wall face: a floor
	            face (the cell below the room with a solid block under it) adds its U to
	            `uaGround` (the ground's temperature, GROUND, is 0), any other to `uaOut`. A
	            passable cell at or above its column's `skyAbove` (the first height open to the
	            sky) is outside: the face towards it is an opening (OPENING_U, counted in
	            `openings`) and the fill does not enter it. Gives up past `maxVolume` cells,
	            `maxExtent` blocks across or `maxOpenings` openings, and at an unknown cell:
	            nil and "too big", "open" or "unloaded" (then the roof rule holds, Tough As
	            Nails' Temperature). Cell keys are World/Coords.posKey's.
	  Air       a room's heat balance C dT/dt = P - uaOut (T - outside) - uaGround (T - GROUND),
	            C = HEAT_CAPACITY x volume, stepped at 1 Hz: `steady` (where T settles),
	            `step` (the exact exponential over dt, stable for any dt).
	  Control   `thermostat(setPoint, T, room, outside, ground, others, maxHU)`: the HU a
	            thermostat wants to hold the room at `setPoint` (proportional feed-forward:
	            uaOut (S - outside) + uaGround (S - ground) - others + uaTotal (S - T), within
	            0..maxHU; a cooler passes a negative maxHU and gets 0..maxHU the other way).
	The air maths take any `Air` (a Room, or a RoomWorld Sample: what a machine's TickContext
	.climate gives its kind).
	Stubs until the rooms land: `fill` finds none ("open"), `steady` gives the outside, `step`
	keeps T, `thermostat` wants nothing. The types and signatures are frozen.
]]

local Config = require(script.Parent.Parent.Config)

-- What the fill reads of the world.
export type View = {
	-- The block at a cell, nil when unknown (not loaded).
	getBlock: (x: number, y: number, z: number) -> number?,
	-- The first height of column (x, z) open to the sky (cached per column for one fill).
	skyAbove: (x: number, z: number) -> number,
}

-- How far a fill goes (Config.Seasons.Rooms' by default).
export type Limits = { maxVolume: number, maxExtent: number, maxOpenings: number }

-- A filled room.
export type Room = {
	id: number,
	-- Interior cells (Coords.posKey -> true), how many, and their bounds (blocks).
	cells: { [number]: true },
	volume: number,
	minX: number,
	minY: number,
	minZ: number,
	maxX: number,
	maxY: number,
	maxZ: number,
	-- The sums of U of its faces to the outside and to the ground, and its openings.
	uaOut: number,
	uaGround: number,
	openings: number,
	-- Positions (Coords.posKey) of heat sources inside it or in its walls.
	sources: { number },
	-- Wall and opening cells (Coords.posKey -> true).
	walls: { [number]: true },
}

-- A room as server Seasons/RoomWorld reports it (and Shared/Machines' TickContext.climate gives
-- kinds): its id, air temperature and outside value (Temperature's scale), losses, cells and the
-- HU of its sources now.
export type Sample = {
	id: number,
	temperature: number,
	outside: number,
	uaOut: number,
	uaGround: number,
	volume: number,
	heat: number,
}

-- What the air maths read of a room (a Room and a Sample both have it).
export type Air = { volume: number, uaOut: number, uaGround: number }

local Rooms = {}

local settings = Config.Seasons.Rooms

-- U of an opening face, the air's heat capacity per cell, the ground's temperature.
Rooms.OPENING_U = settings.OpeningU
Rooms.HEAT_CAPACITY = settings.HeatCapacity
Rooms.GROUND = 0
-- Why a fill found no room.
Rooms.OPEN = "open"
Rooms.TOO_BIG = "too big"
Rooms.UNLOADED = "unloaded"

-- Config's limits.
function Rooms.limits(): Limits
	return { maxVolume = settings.MaxVolume, maxExtent = settings.MaxExtent, maxOpenings = settings.MaxOpenings }
end

-- The room the cell (x, y, z) is in (see the header), or nil and why not. Stub: never one.
function Rooms.fill(_view: View, _x: number, _y: number, _z: number, _limits: Limits?): (Room?, string?)
	return nil, Rooms.OPEN
end

-- Where the room's air settles with `heat` HU (see the header). Stub: the outside.
function Rooms.steady(_room: Air, outside: number, _ground: number, _heat: number): number
	return outside
end

-- The room's air `dt` seconds on from `temperature` (see the header). Stub: unchanged.
function Rooms.step(
	temperature: number,
	_room: Air,
	_outside: number,
	_ground: number,
	_heat: number,
	_dt: number
): number
	return temperature
end

-- The HU a thermostat wants (see the header). Stub: none.
function Rooms.thermostat(
	_setPoint: number,
	_temperature: number,
	_room: Air,
	_outside: number,
	_ground: number,
	_others: number,
	_maxHU: number
): number
	return 0
end

return Rooms
