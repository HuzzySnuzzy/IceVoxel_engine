--[[
	Doors (Shared/Blocks/Doors, Minecraft's DoorBlock): collision with a door's 3 pixel panel
	(Shared/Movement/Hull's shapes, Blocks.collision); the blocks (32 halves per wood, the item,
	drops); the panel's place per facing, hinge and open state (DoorBlock.getShape); placement
	(facing, hinge: DoorBlock.getHinge); opening a door and its double door partner (Doors.use);
	the server's rules (both halves placed and broken together, one drop, a lone half popping:
	Behaviours/Door); turning structures; players walking into closed and through open doors.
]]

return function(t, shared, require, server)
	local Hull = require(shared.Movement.Hull)
	local Blocks = require(shared.Blocks)
	local Doors = require(shared.Blocks.Doors)
	local Items = require(shared.Items)
	local Config = require(shared.Config)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local PlayerPhysics = require(shared.Movement.PlayerPhysics)
	local WorldServer = require(server.World.WorldServer)
	local BlockTicker = require(server.World.BlockTicker)
	local Behaviours = require(server.Behaviours)
	local Drops = require(server.Behaviours.Drops)
	local EditRules = require(server.Network.EditRules)

	local B = Blocks.id
	local AIR, STONE = Blocks.AIR, B.Stone
	local WOODS = { "Oak", "Spruce", "Birch", "Jungle", "Acacia" }

	local function near(a: number, b: number, tolerance: number?): boolean
		return math.abs(a - b) <= (tolerance or 1e-9)
	end

	-- A panel 3 pixels thick across cell (0, 1, 0) at its south side (z 13..16 pixels), on a floor.
	local PANEL: Hull.Shape = { { minX = 0, minY = 0, minZ = 13 / 16, maxX = 1, maxY = 1, maxZ = 1 } }
	local function panelWorld(x: number, y: number, z: number): boolean | Hull.Shape
		if y == 0 then
			return true
		elseif x == 0 and z == 0 and (y == 1 or y == 2) then
			return PANEL
		end
		return false
	end

	t.test("hull: a shape's boxes stop a box at their faces, not the cell's", function()
		-- Walking north (-Z) from the south: stops at the panel's south face, z = 1.
		local south = Hull.box(0.5, 1, 1.8, 0.6, 1.8)
		local _, _, dz = Hull.collideBox(panelWorld, south, 0, 0, -2)
		t.ok(near(dz, -(1.5 - 1)), `stopped at the panel after {dz}`)
		-- Walking south (+Z) from inside the cell's north part: up to the panel's north face.
		local north = Hull.box(0.5, 1, 0.3, 0.6, 1.8)
		_, _, dz = Hull.collideBox(panelWorld, north, 0, 0, 2)
		t.ok(near(dz, 13 / 16 - 0.6), `stopped at the panel's inside after {dz}`)
		-- The rest of the cell is open: walking along X inside it is free.
		local dx = Hull.collideBox(panelWorld, north, 3, 0, 0)
		t.ok(near(dx, 3), "beside the panel is free")
		-- Overlapping the panel already does not hold the box.
		local inside = Hull.box(0.5, 1, 0.9, 0.6, 1.8)
		_, _, dz = Hull.collideBox(panelWorld, inside, 0, 0, -1)
		t.ok(near(dz, -1), "a box in the panel gets out")
	end)

	t.test("hull: shapes count for noCollision, and a full block still beyond them", function()
		t.ok(Hull.noCollision(panelWorld, Hull.box(0.5, 1, 0.3, 0.6, 1.8)), "in the cell, clear of the panel")
		t.ok(not Hull.noCollision(panelWorld, Hull.box(0.5, 1, 0.6, 0.6, 1.8)), "into the panel")
		-- Moving east along the panel's row stops at a wall, the panel's cell is no wall.
		local function walled(x: number, y: number, z: number): boolean | Hull.Shape
			if x == 3 and y == 1 then
				return true
			end
			return panelWorld(x, y, z)
		end
		local dx = Hull.collideBox(walled, Hull.box(-1.5, 1, 0.3, 0.6, 1.8), 10, 0, 0)
		t.ok(near(dx, 3 - -1.2), `walked through the open part to the wall: {dx}`)
		-- Falling onto the panel's top lands on it (y = 3), but beside it to the floor.
		local _, dy = Hull.collideBox(panelWorld, Hull.box(0.5, 4, 0.9, 0.6, 1.8), 0, -5, 0)
		t.ok(near(dy, -1), `landed on top of the door: {dy}`)
		_, dy = Hull.collideBox(panelWorld, Hull.box(0.5, 4, 0.3, 0.6, 1.8), 0, -5, 0)
		t.ok(near(dy, -3), `fell beside it to the floor: {dy}`)
	end)

	--[[ The blocks ]]

	t.test("doors: 32 halves per wood, the lower one the item, upper halves drop nothing", function()
		for _, wood in WOODS do
			local base = B[wood .. "Door"]
			t.ok(base ~= nil and Blocks.isDoor(base), `{wood} door`)
			t.eq(Items.ofBlock(base), base, "the base is the item")
			t.eq(#Blocks.variants(base), 32, "every facing, hinge, open state and half")
			local facing, hinge, open, upper = Blocks.doorState(base)
			t.eq(facing, "North")
			t.eq(hinge, "Left")
			t.eq(open, false)
			t.eq(upper, false)
			for _, id in Blocks.variants(base) do
				local def = Blocks.get(id)
				local _, _, isOpen, isUpper = Blocks.doorState(id)
				t.eq(Items.ofBlock(id), base, `{def.name} drops and picks the door`)
				t.ok(not def.solid and def.collides and def.obstructs, `{def.name} collides by its panel`)
				t.eq(def.displayName, wood .. " Door")
				t.eq(def.menu, "Door")
				t.eq(def.behaviour, "Door")
				t.ok(not Blocks.isFlammable(id), "Minecraft's doors never catch fire")
				if isUpper then
					t.eq(Items.blockDrops(id), nil, `{def.name} drops nothing`)
					local lower = Blocks.plantBottom(id) :: number
					t.eq(Blocks.plantTop(lower), id, "its lower half's top")
					t.eq(Blocks.otherHalf(id), -1)
					t.eq(def.support, nil)
				else
					local top = Blocks.plantTop(id) :: number
					t.eq(Blocks.plantBottom(top), id, "its upper half's bottom")
					t.eq(Blocks.otherHalf(id), 1)
					t.eq(def.support, "Down")
					local drop = Items.blockDrops(id)
					t.ok(drop ~= nil and drop.item == base and drop.count == 1, `{def.name} drops one door`)
				end
				local toggled = Blocks.doorToggled(id) :: number
				local f, h, o, u = Blocks.doorState(toggled)
				t.ok(o == not isOpen and f == Blocks.doorState(id) and u == isUpper, "toggling flips open only")
				t.ok(h == select(2, Blocks.doorState(id)), "and keeps the hinge")
				t.eq(Blocks.doorToggled(toggled), id)
			end
		end
		t.ok(not Blocks.isDoor(STONE) and Blocks.doorToggled(STONE) == nil and Blocks.doorState(STONE) == nil)
		t.eq(Blocks.collision(STONE), true, "a solid block: its whole cell")
		t.eq(Blocks.collision(AIR), false)
		t.eq(Blocks.collision(B.Torch), false)
	end)

	t.test("doors: the panel's place (DoorBlock.getShape), its outline and collision", function()
		-- The cell side the panel lies against, in Minecraft's AABBs: NORTH_AABB is the south
		-- three pixels (z 13..16), SOUTH_AABB the north ones, WEST_AABB the east, EAST_AABB the west.
		local AABB = { North = "South", South = "North", West = "East", East = "West" }
		local SHAPES = {
			-- facing, hinge, open -> Minecraft's shape
			{ "East", "Left", false, "East" },
			{ "East", "Right", true, "North" },
			{ "East", "Left", true, "South" },
			{ "South", "Right", false, "South" },
			{ "South", "Right", true, "East" },
			{ "South", "Left", true, "West" },
			{ "West", "Left", false, "West" },
			{ "West", "Right", true, "South" },
			{ "West", "Left", true, "North" },
			{ "North", "Right", false, "North" },
			{ "North", "Right", true, "West" },
			{ "North", "Left", true, "East" },
		}
		local SIDE_BOX = {
			South = { 0, 0, 13 / 16, 1, 1, 1 },
			North = { 0, 0, 0, 1, 1, 3 / 16 },
			East = { 13 / 16, 0, 0, 1, 1, 1 },
			West = { 0, 0, 0, 3 / 16, 1, 1 },
		}
		for _, case in SHAPES do
			local facing, hinge, open, shape = case[1], case[2], case[3], case[4]
			t.eq(Doors.shapeFacing(facing, hinge, open), shape, `{facing} {hinge} {open}`)
			local side = Doors.panelSide(facing, hinge, open)
			t.eq(side, AABB[shape])
			for _, upper in { false, true } do
				local id = Blocks.doorVariant(B.OakDoor, facing, hinge, open, upper) :: number
				local outline = Blocks.outline(id) :: { number }
				local want = SIDE_BOX[side]
				for k = 1, 6 do
					t.near(outline[k], want[k], 1e-9, `{Blocks.get(id).name} outline {k}`)
				end
				local boxes = Blocks.collision(id)
				t.ok(type(boxes) == "table" and #boxes == 1, "one collision box")
				local box = (boxes :: any)[1]
				t.ok(
					box.minX == outline[1]
						and box.minZ == outline[3]
						and box.maxX == outline[4]
						and box.maxZ == outline[6]
				)
			end
		end
		-- Every shape box stays on the panel's side of the cell.
		for _, id in Blocks.variants(B.BirchDoor) do
			local facing, hinge, open = Blocks.doorState(id)
			local side = Doors.panelSide(facing :: string, hinge :: string, open :: boolean)
			local d = Blocks.DIRECTIONS[side]
			for i, box in Blocks.get(id).shape :: { Blocks.ShapeBox } do
				local along = box.offset[1] * d[1] + box.offset[3] * d[3]
				t.near(along, 6.5, 1e-9, `{Blocks.get(id).name} box {i} against its side`)
			end
		end
	end)

	t.test("doors: the design is mirrored for the other hinge (the handle away from the hinge)", function()
		-- A closed North door's panel lies on the south side; its handle is the box made of metal.
		local function handleX(id: number): number
			for _, box in Blocks.get(id).shape :: { Blocks.ShapeBox } do
				if box.material == "Metal" then
					return box.offset[1]
				end
			end
			error("no handle")
		end
		local left = Blocks.doorVariant(B.OakDoor, "North", "Left", false, false) :: number
		local right = Blocks.doorVariant(B.OakDoor, "North", "Right", false, false) :: number
		-- (Facing North, the player's left is West, -X: the hinge there, the handle east.)
		t.ok(handleX(left) > 0, "left hinge: handle to the east")
		t.ok(handleX(right) < 0, "right hinge: handle to the west")
		-- Opened, the left door lies against the west side, hinged at its south end: the handle
		-- is now at the north end.
		local opened = Blocks.doorToggled(left) :: number
		for _, box in Blocks.get(opened).shape :: { Blocks.ShapeBox } do
			if box.material == "Metal" then
				t.ok(box.offset[3] < 0 and box.offset[1] < 0, "the open door's handle at its north end")
			end
		end
	end)

	--[[ Placing ]]

	-- A sparse world for the pure rules: unset blocks are air below y 20 (stone at y 0), `false` =
	-- not loaded.
	local function sparse(blocks: { [string]: number | false })
		return function(x: number, y: number, z: number): number?
			local b = blocks[`{x},{y},{z}`]
			if b == false then
				return nil
			elseif b ~= nil then
				return b
			end
			return if y <= 0 then STONE else AIR
		end
	end

	t.test("doors: placing faces the way the player looks, the hinge by walls, doors and the click", function()
		local getBlock = sparse({})
		local function place(lx: number, lz: number, hx: number?, hz: number?, world: any?): (string?, string?)
			local id = Blocks.placementFor(B.OakDoor, 0, 1, 0, lx, -0.3, lz, world or getBlock, 0, 1, 0, hx, hz)
			if id == nil then
				return nil, nil
			end
			local facing, hinge, open, upper = Blocks.doorState(id)
			t.ok(open == false and upper == false, "a closed lower half")
			return facing, hinge
		end
		t.eq(place(0, -1), "North")
		t.eq(place(1, 0), "East")
		t.eq(place(0, 1), "South")
		t.eq(place(-1, 0), "West")
		-- The click: facing North, the west half of the cell (the player's left) hinges left.
		t.eq(select(2, place(0, -1, 0.2, 0.5)), "Left")
		t.eq(select(2, place(0, -1, 0.8, 0.5)), "Right")
		-- Facing East (+X): the player's left is North (-Z).
		t.eq(select(2, place(1, 0, 0.5, 0.2)), "Left")
		t.eq(select(2, place(1, 0, 0.5, 0.8)), "Right")
		-- Walls beside the door's two cells win over the click: a wall to the right (east).
		local walled = sparse({ ["1,1,0"] = STONE, ["1,2,0"] = STONE })
		t.eq(select(2, place(0, -1, 0.2, 0.5, walled)), "Right", "hinged against the wall")
		-- A door to the left gets a right hinge: a double door.
		local beside = sparse({ ["-1,1,0"] = B.SpruceDoor, ["-1,2,0"] = B.SpruceDoorTop })
		t.eq(select(2, place(0, -1, 0.2, 0.5, beside)), "Right", "the other door's partner")
		local besideRight = sparse({ ["1,1,0"] = B.OakDoor, ["1,2,0"] = B.OakDoorTop })
		t.eq(select(2, place(0, -1, 0.8, 0.5, besideRight)), "Left")
		-- It needs a sturdy block under it and room for its top.
		t.eq(place(0, -1, nil, nil, sparse({ ["0,0,0"] = AIR })), nil, "nothing under it")
		t.eq(place(0, -1, nil, nil, sparse({ ["0,2,0"] = STONE })), nil, "no room above")
		t.eq(place(0, -1, nil, nil, sparse({ ["0,2,0"] = false })), nil, "above not loaded")
		-- The server never takes an upper half from a player.
		t.ok(EditRules.mayPlace(B.OakDoor, AIR))
		t.ok(EditRules.mayPlace(Blocks.doorVariant(B.OakDoor, "East", "Right", false, false) :: number, AIR))
		t.ok(not EditRules.mayPlace(B.OakDoorTop, AIR), "upper halves come with their lower half")
	end)

	--[[ Opening ]]

	-- A whole door of `base` at (x, 1, z): its lower and upper halves.
	local function door(
		blocks: { [string]: number | false },
		base: number,
		x: number,
		z: number,
		facing: string,
		hinge: string,
		open: boolean?
	)
		local lower = Blocks.doorVariant(base, facing, hinge, open == true, false) :: number
		blocks[`{x},1,{z}`] = lower
		blocks[`{x},2,{z}`] = Blocks.plantTop(lower) :: number
	end
	local function apply(blocks: { [string]: number | false }, changes: { Doors.Change })
		for _, c in changes do
			blocks[`{c.x},{c.y},{c.z}`] = c.block
		end
	end
	local function isOpen(blocks: { [string]: number | false }, x: number, y: number, z: number): boolean?
		local _, _, open = Blocks.doorState(blocks[`{x},{y},{z}`] :: number)
		return open
	end

	t.test("doors: using either half opens and closes both", function()
		local blocks = {}
		door(blocks, B.OakDoor, 0, 0, "North", "Left")
		local getBlock = sparse(blocks)
		local changes = Doors.use(blocks["0,1,0"] :: number, getBlock, 0, 1, 0)
		t.eq(#changes, 2, "both halves")
		t.ok(Doors.opens(changes))
		apply(blocks, changes)
		t.ok(isOpen(blocks, 0, 1, 0) and isOpen(blocks, 0, 2, 0), "open")
		-- From the upper half: closes again.
		changes = Doors.use(blocks["0,2,0"] :: number, getBlock, 0, 2, 0)
		t.eq(#changes, 2)
		t.ok(not Doors.opens(changes))
		t.eq(changes[1].y, 1, "the lower half first")
		apply(blocks, changes)
		t.ok(isOpen(blocks, 0, 1, 0) == false and isOpen(blocks, 0, 2, 0) == false, "closed")
		-- A half alone does nothing; nor does a block that is no door.
		local lone = {}
		lone["5,1,5"] = B.OakDoor
		t.eq(#Doors.use(B.OakDoor, sparse(lone), 5, 1, 5), 0, "no upper half")
		t.eq(#Doors.use(STONE, sparse(lone), 5, 1, 5), 0)
	end)

	t.test("doors: a double door opens and closes together, of any woods", function()
		-- Facing North, the left hinged door at x 0, its partner (right hinge) east of it at x 1.
		local blocks = {}
		door(blocks, B.OakDoor, 0, 0, "North", "Left")
		door(blocks, B.BirchDoor, 1, 0, "North", "Right")
		local getBlock = sparse(blocks)
		t.eq(select(1, Doors.partnerAt(blocks["0,1,0"] :: number, 0, 1, 0)), 1, "the partner is east")
		t.eq(select(1, Doors.partnerAt(blocks["1,1,0"] :: number, 1, 1, 0)), 0, "and back")
		local changes = Doors.use(blocks["0,1,0"] :: number, getBlock, 0, 1, 0)
		t.eq(#changes, 4, "both doors' halves")
		apply(blocks, changes)
		for _, cell in { { 0, 1 }, { 0, 2 }, { 1, 1 }, { 1, 2 } } do
			t.ok(isOpen(blocks, cell[1], cell[2], 0), `{cell[1]},{cell[2]} open`)
		end
		t.eq(Blocks.get(blocks["1,1,0"] :: number).displayName, "Birch Door", "each keeps its wood")
		-- Using the partner (its upper half) closes both.
		changes = Doors.use(blocks["1,2,0"] :: number, getBlock, 1, 2, 0)
		t.eq(#changes, 4)
		apply(blocks, changes)
		for _, cell in { { 0, 1 }, { 0, 2 }, { 1, 1 }, { 1, 2 } } do
			t.ok(isOpen(blocks, cell[1], cell[2], 0) == false, `{cell[1]},{cell[2]} closed`)
		end
		-- Open panels swing apart: the left door to the west side, the right one to the east.
		apply(blocks, Doors.use(blocks["0,1,0"] :: number, getBlock, 0, 1, 0))
		t.eq(
			(Blocks.outline(blocks["0,1,0"] :: number) :: { number })[4],
			3 / 16,
			"the left door against its west side"
		)
		t.eq(
			(Blocks.outline(blocks["1,1,0"] :: number) :: { number })[1],
			13 / 16,
			"the right one against its east side"
		)
	end)

	t.test("doors: only a mirrored, matching door beside is a partner", function()
		local function uses(setup: (blocks: { [string]: number | false }) -> ()): number
			local blocks = {}
			door(blocks, B.OakDoor, 0, 0, "North", "Left")
			setup(blocks)
			return #Doors.use(blocks["0,1,0"] :: number, sparse(blocks), 0, 1, 0)
		end
		t.eq(
			uses(function(b)
				door(b, B.OakDoor, 1, 0, "North", "Right")
			end),
			4,
			"the partner"
		)
		t.eq(
			uses(function(b)
				door(b, B.OakDoor, 1, 0, "North", "Left")
			end),
			2,
			"the same hinge: two doors in a row"
		)
		t.eq(
			uses(function(b)
				door(b, B.OakDoor, 1, 0, "South", "Right")
			end),
			2,
			"another facing"
		)
		t.eq(
			uses(function(b)
				door(b, B.OakDoor, 1, 0, "North", "Right", true)
			end),
			2,
			"already open: only the one used moves"
		)
		t.eq(
			uses(function(b)
				door(b, B.OakDoor, -1, 0, "North", "Right")
			end),
			2,
			"on the hinge side: no partner"
		)
		t.eq(
			uses(function(b)
				b["1,1,0"] = Blocks.doorVariant(B.OakDoor, "North", "Right", false, false) :: number
			end),
			2,
			"a partner without its upper half"
		)
		t.eq(
			uses(function(b)
				b["1,1,0"] = false
			end),
			2,
			"not loaded"
		)
	end)

	--[[ The server ]]

	local FLOOR = 10
	local flat = {
		generate = function(level: number, nx: number, nz: number)
			local data = ChunkLayout.create(32)
			for y = 0, FLOOR - 1 do
				for i = 0, ChunkLayout.LAYER - 1 do
					buffer.writeu16(data, (y * ChunkLayout.LAYER + i) * 2, STONE)
				end
			end
			return { data = data, level = level, nx = nx, nz = nz, height = 32, solidBelow = FLOOR, emptyAbove = FLOOR }
		end,
		column = function()
			return FLOOR, 1, 0, STONE
		end,
		findSpawn = function()
			return 0, FLOOR, 0
		end,
	}
	local function newWorld()
		local world = WorldServer.new(flat :: any)
		local ticker = BlockTicker.new(world, Behaviours.byId, 100000)
		world.onChanged = function(x, y, z)
			ticker:blockChanged(x, y, z)
		end
		local dropped: { number } = {}
		Drops.set(function(_x, _y, _z, stack)
			table.insert(dropped, stack.item)
		end)
		local function settle()
			for _ = 1, 2000 do
				ticker:step()
				if ticker:pendingCount() == 0 then
					return
				end
			end
			error("block updates never settled")
		end
		for cx = -1, 1 do
			for cz = -1, 1 do
				world:getChunk(cx, cz)
			end
		end
		return world, settle, dropped
	end

	t.test("doors on the server: placed whole, broken whole with one drop, opened in one step", function()
		local world, settle, dropped = newWorld()
		local function peek(x: number, y: number, z: number): number?
			return world:peekBlock(x, y, z)
		end
		t.ok(EditRules.supported(B.OakDoor, peek, 0, FLOOR, 0))
		t.ok(EditRules.setPlaced(world, 0, FLOOR, 0, B.OakDoor))
		t.eq(world:getBlock(0, FLOOR + 1, 0), B.OakDoorTop, "both halves")
		settle()
		t.eq(world:getBlock(0, FLOOR, 0), B.OakDoor, "it stays")
		-- Opening sets both halves before any block update looks: nothing pops.
		for _, change in Doors.use(B.OakDoor, peek, 0, FLOOR, 0) do
			world:setBlock(change.x, change.y, change.z, change.block)
		end
		settle()
		t.ok(
			Blocks.doorState(world:getBlock(0, FLOOR, 0)) ~= nil
				and select(3, Blocks.doorState(world:getBlock(0, FLOOR + 1, 0)))
		)
		t.eq(#dropped, 0, "nothing dropped")
		-- Breaking the upper half harvests the lower half (one door) and removes both.
		local top = world:getBlock(0, FLOOR + 1, 0)
		local block, y = EditRules.harvested(top, peek, 0, FLOOR + 1, 0)
		t.eq(y, FLOOR)
		t.ok(Blocks.doorState(block) ~= nil and select(4, Blocks.doorState(block)) == false, "the lower half")
		t.ok(EditRules.removeBroken(world, 0, FLOOR + 1, 0, top))
		t.eq(world:getBlock(0, FLOOR, 0), AIR)
		t.eq(world:getBlock(0, FLOOR + 1, 0), AIR)
		settle()
		t.eq(#dropped, 0, "the player's break drops (ServerNet), not the block updates")
	end)

	t.test("doors on the server: a door without its floor, or a lone half, pops once", function()
		local world, settle, dropped = newWorld()
		t.ok(EditRules.setPlaced(world, 0, FLOOR, 0, B.SpruceDoor))
		settle()
		world:setBlock(0, FLOOR - 1, 0, AIR)
		settle()
		t.eq(world:getBlock(0, FLOOR, 0), AIR, "the lower half broke")
		t.eq(world:getBlock(0, FLOOR + 1, 0), AIR, "and the top with it")
		t.eq(#dropped, 1, "one door")
		t.eq(dropped[1], B.SpruceDoor)
		-- An upper half left alone pops with nothing.
		world:setBlock(3, FLOOR, 0, B.SpruceDoorTop)
		settle()
		t.eq(world:getBlock(3, FLOOR, 0), AIR)
		t.eq(#dropped, 1, "an upper half drops nothing")
	end)

	--[[ Structures ]]

	t.test("doors: structures turn a door's facing, and a mirror swaps its hinge", function()
		local id = Blocks.doorVariant(B.JungleDoor, "North", "Left", true, true) :: number
		local turned = Blocks.rotate(id, 1)
		local facing, hinge, open, upper = Blocks.doorState(turned)
		t.ok(facing == "East" and hinge == "Left" and open == true and upper == true, "a quarter turn")
		t.eq(Blocks.rotate(id, 4), id)
		local mirrored = Blocks.rotate(id, 0, "leftRight")
		facing, hinge = Blocks.doorState(mirrored)
		t.ok(facing == "South" and hinge == "Right", "mirrored front to back: South, the other hinge")
		mirrored = Blocks.rotate(id, 0, "frontBack")
		facing, hinge = Blocks.doorState(mirrored)
		t.ok(facing == "North" and hinge == "Right", "mirrored sideways: the other hinge only")
		t.eq(Items.ofBlock(turned), B.JungleDoor)
	end)

	--[[ Walking ]]

	t.test("doors: a player walks into a closed door's panel and through an open one", function()
		-- A North door at (0, 1, 0) on a stone floor: closed, its panel on the cell's south side.
		local blocks = {}
		door(blocks, B.OakDoor, 0, 0, "North", "Left")
		local getBlock = sparse(blocks)
		local world: PlayerPhysics.World = { getBlock = getBlock }
		local north: PlayerPhysics.Input = {
			moveX = 0,
			moveZ = -1,
			forward = 1,
			facingX = 0,
			facingZ = -1,
			lookY = 0,
			jump = false,
			sneak = false,
			sprint = false,
		}
		local function walk(): number
			-- From the south, walking north (-Z) for two seconds.
			local state = PlayerPhysics.new(0.5, 1, 2.5)
			state.onGround = true
			for _ = 1, 40 do
				PlayerPhysics.tick(state, north, world)
			end
			return state.z
		end
		local z = walk()
		t.ok(z >= 1 + 0.3 - 1e-6 and z < 1.4, `stopped at the panel's south face: {z}`)
		apply(blocks, Doors.use(blocks["0,1,0"] :: number, getBlock, 0, 1, 0))
		z = walk()
		t.ok(z < 0, `walked through the open door: {z}`)
	end)
end
