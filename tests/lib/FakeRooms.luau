--[[
	A small world for the rooms' specs (tests/spec/Rooms, RoomWorld, Heaters): flat ground (Grass
	at y GROUND - 1 over Dirt), air above, edited block by block, loaded only within LOADED blocks
	of the origin (sideways), and the views the rooms read of it (Shared/Seasons/Rooms.View: blocks,
	the sky's height per column, which blocks are room sources).

	`house(x0, z0, w, d, h, wall)` builds Minecraft's simplest shelter: an interior w x d x h from
	(x0, GROUND, z0) on the ground, walled and roofed with `wall` (the roof over the walls too, so a
	door's cells are under it); it returns where the front wall is (z0 - 1, the cells a door or a
	window goes in).
]]

local FakeRooms = {}

FakeRooms.GROUND = 64
FakeRooms.LOADED = 200
FakeRooms.TOP = 160

function FakeRooms.new(Blocks: any, Rooms: any): any
	local B = Blocks.id
	local GROUND, LOADED, TOP = FakeRooms.GROUND, FakeRooms.LOADED, FakeRooms.TOP
	local edits: { [string]: number } = {}
	local world = {}
	world.reads = 0

	local function key(x: number, y: number, z: number): string
		return `{x},{y},{z}`
	end

	function world.getBlock(x: number, y: number, z: number): number?
		world.reads += 1
		if math.abs(x) > LOADED or math.abs(z) > LOADED then
			return nil
		end
		local edited = edits[key(x, y, z)]
		if edited then
			return edited
		elseif y >= GROUND then
			return B.Air
		elseif y == GROUND - 1 then
			return B.Grass
		end
		return B.Dirt
	end

	function world.skyAbove(x: number, z: number): number
		if math.abs(x) > LOADED or math.abs(z) > LOADED then
			return math.huge
		end
		for y = TOP, 0, -1 do
			local block = world.getBlock(x, y, z) :: number
			if not Rooms.passable(block) then
				return y + 1
			end
		end
		return 0
	end

	function world.set(x: number, y: number, z: number, block: number)
		edits[key(x, y, z)] = block
	end

	function world.get(x: number, y: number, z: number): number
		return world.getBlock(x, y, z) :: number
	end

	-- Fills the box (x0..x1, y0..y1, z0..z1) with `block`.
	function world.fill(x0: number, y0: number, z0: number, x1: number, y1: number, z1: number, block: number)
		for x = x0, x1 do
			for y = y0, y1 do
				for z = z0, z1 do
					edits[key(x, y, z)] = block
				end
			end
		end
	end

	-- A walled, roofed interior w x d x h from (x0, GROUND, z0) (see the header).
	function world.house(x0: number, z0: number, w: number, d: number, h: number, wall: number): number
		world.fill(x0 - 1, GROUND, z0 - 1, x0 + w, GROUND + h - 1, z0 + d, wall)
		world.fill(x0, GROUND, z0, x0 + w - 1, GROUND + h - 1, z0 + d - 1, B.Air)
		world.fill(x0 - 1, GROUND + h, z0 - 1, x0 + w, GROUND + h, z0 + d, wall)
		return z0 - 1
	end

	-- The view a fill reads (`source`: the blocks that give heat, nil: none).
	function world.view(source: ((block: number) -> boolean)?): any
		return { getBlock = world.getBlock, skyAbove = world.skyAbove, source = source }
	end

	return world
end

return FakeRooms
