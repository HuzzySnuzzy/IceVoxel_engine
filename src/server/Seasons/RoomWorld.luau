--!strict
--[[
	Rooms on the server (Shared/Seasons/Rooms; Config.Seasons.Rooms): which cells are enclosed,
	insulated spaces, and their air's temperature, for the players in them (Players/ToughAsNails,
	once a second), the machines next to them (Shared/Machines' TickContext.climate, through
	Machines/Machines' env) and the snow on and in them (Seasons/SnowWorld). Rooms are entirely
	the server's; players learn of theirs through the Survival message (room and outside).

	  Cache      `roomOf[cellKey]` maps interior cells and `wallsOf[cellKey]` wall and opening
	             cells (World/Coords pos keys); a change at a room's cell or wall (`blockChanged`,
	             from WorldServer.onChanged: door toggles and every edit) marks it dirty and it is
	             filled again from its seed, the new room's air the volume-weighted mean of the old
	             rooms it overlaps.
	  Seeds      each player's feet (once a second, with ToughAsNails' sample: `sample`) and each
	             room-source machine (every MachineSeedSeconds) within Range of a player; a room
	             unvisited for ForgetSeconds with no live source is forgotten, a failed seed is not
	             tried again for NotRoomSeconds.
	  Budget     at most FillsPerFrame fills and FillMs a frame (`step`); the air steps at 1 Hz
	             (Rooms.step), its heat the room sources' (Players/Climate.roomSource: what each
	             block in the room or its walls gives, machines their `heat` field).
	Stub until the rooms land: no cell is in a room (`sample`, `climateAt` and `temperatureAt`
	find none), so Tough As Nails keeps its roof rule. The API is frozen.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Rooms = require(Shared.Seasons.Rooms)

-- A room as reported (Shared/Seasons/Rooms.Sample): id, air temperature and outside value
-- (Temperature's scale), losses, volume and the HU of its sources now.
export type Sample = Rooms.Sample

local RoomWorld = {}

local started = false

-- Starts following rooms in `world` (World/WorldServer).
function RoomWorld.start(_world: any)
	assert(not started, "RoomWorld.start was already called")
	started = true
end

-- WorldServer.onChanged: block (x, y, z) went from `old` to `new` (a room there or walled by it
-- is filled again).
function RoomWorld.blockChanged(_x: number, _y: number, _z: number, _old: number, _new: number) end

-- A frame's work after the machines (World boot: after Machines.update): fills within the budget,
-- the air at 1 Hz.
function RoomWorld.step(_dt: number) end

-- The room of the cell at the player's feet (x, y, z) (seeding it), nil when none.
function RoomWorld.sample(_x: number, _y: number, _z: number): Sample?
	return nil
end

--[[
	The room next to a machine at (x, y, z) (the cell itself or a neighbour's; nil outdoors) and the
	outdoor value there (Temperature's scale, the sheltered value a room loses to).
]]
function RoomWorld.climateAt(_x: number, _y: number, _z: number): (Sample?, number)
	return nil, 0
end

-- The air temperature of the room holding or walled by cell (x, y, z) (nil: none): snow melts in
-- and on a warm room (Seasons/SnowWorld).
function RoomWorld.temperatureAt(_x: number, _y: number, _z: number): number?
	return nil
end

return RoomWorld
