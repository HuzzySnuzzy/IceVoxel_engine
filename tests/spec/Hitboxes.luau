--[[
	Hitboxes (Shared/Blocks/Shapes, Blocks.collision, Shared/Movement/Hull): fences connect to
	fences and sturdy blocks beside them (16 variants: placing, server Behaviours/Fence, turning)
	and collide with their post and arms 1.5 blocks high, so nothing walks between posts or jumps
	over; Mekanism transmitters collide with their core and connected arms; mobs' line of sight
	and explosions' exposure stop at what collides, by its boxes (a closed door hides a player).
]]

return function(t, shared, require, server)
	local Hull = require(shared.Movement.Hull)
	local Blocks = require(shared.Blocks)
	local Doors = require(shared.Blocks.Doors)
	local Shapes = require(shared.Blocks.Shapes)
	local Items = require(shared.Items)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Explosion = require(shared.World.Explosion)
	local PlayerPhysics = require(shared.Movement.PlayerPhysics)
	local WorldServer = require(server.World.WorldServer)
	local BlockTicker = require(server.World.BlockTicker)
	local Behaviours = require(server.Behaviours)
	local EditRules = require(server.Network.EditRules)
	local MobAI = require(server.Mobs.MobAI)

	local B = Blocks.id
	local AIR, STONE = Blocks.AIR, B.Stone
	local FENCE = B.OakFence
	local N, S, W, E = 1, 2, 4, 8

	local function near(a: number, b: number, tolerance: number?): boolean
		return math.abs(a - b) <= (tolerance or 1e-6)
	end

	-- A sparse world: stone at y <= 0, air above, `blocks` over that ("x,y,z" -> id; false: not
	-- loaded).
	local function sparse(blocks: { [string]: number | false }): (x: number, y: number, z: number) -> number?
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
	local function solidAt(getBlock: (x: number, y: number, z: number) -> number?): Hull.SolidAt
		return function(x: number, y: number, z: number): boolean | Hull.Shape
			local block = getBlock(x, y, z)
			return block == nil or Shapes.collisionAt(getBlock, x, y, z, block)
		end
	end
	local function physicsWorld(getBlock: (x: number, y: number, z: number) -> number?): PlayerPhysics.World
		return { getBlock = getBlock }
	end
	local function input(moveX: number, moveZ: number, jump: boolean?): PlayerPhysics.Input
		local length = math.sqrt(moveX * moveX + moveZ * moveZ)
		return {
			moveX = moveX,
			moveZ = moveZ,
			forward = length,
			facingX = if length > 0 then moveX / length else 0,
			facingZ = if length > 0 then moveZ / length else 1,
			lookY = 0,
			jump = jump == true,
			sneak = false,
			sprint = false,
		}
	end
	-- A player walking (and jumping) from (x, 1, z) along (mx, mz) for `ticks`.
	local function walk(
		world: PlayerPhysics.World,
		x: number,
		z: number,
		mx: number,
		mz: number,
		ticks: number,
		jump: boolean?
	)
		local state = PlayerPhysics.new(x, 1, z)
		state.onGround = true
		for _ = 1, ticks do
			PlayerPhysics.tick(state, input(mx, mz, jump), world)
		end
		return state
	end

	--[[ Fences ]]

	t.test("fences: a variant per set of arms, all the Oak Fence's item", function()
		t.ok(Blocks.isFence(FENCE) and Blocks.fenceArms(FENCE) == 0, "the lone post is the item")
		t.eq(#Blocks.variants(FENCE), 16)
		for mask = 0, 15 do
			local id = Blocks.fenceVariant(FENCE, mask) :: number
			t.eq(Blocks.fenceArms(id), mask)
			t.eq(Items.ofBlock(id), FENCE, "drops and picks the fence")
			t.eq(Blocks.get(id).displayName, "Oak Fence")
			t.ok(Blocks.isFlammable(id), "burns like planks")
			local boxes = Blocks.collision(id)
			t.ok(type(boxes) == "table", "collides by its boxes, though solid")
			local arms = 0
			for bit = 0, 3 do
				arms += bit32.extract(mask, bit)
			end
			t.eq(#(boxes :: any), 1 + arms, "the post and an arm per side")
			for _, box in boxes :: any do
				t.near(box.maxY, 1.5, 1e-9, "1.5 blocks high")
			end
			t.eq(#(Blocks.get(id).shape :: { any }), 1 + 2 * arms, "a post and two rails per arm")
		end
		-- The cave twin is a lone post too, the fence's.
		t.eq(Blocks.fenceArms(B.CaveOakFence), 0)
		t.eq(Blocks.fenceVariant(B.CaveOakFence, N + S), B.OakFenceNorthSouth)
		-- Placing into a player goes by the post and arms, not the cell.
		local post = Blocks.obstruction(FENCE) :: { number }
		t.ok(near(post[1], 6 / 16) and near(post[4], 10 / 16), "the post's outline")
	end)

	t.test("fences: placing joins fences and sturdy blocks beside it", function()
		local function placed(blocks: { [string]: number | false }): number?
			return Blocks.placementFor(FENCE, 0, 1, 0, 0, -0.5, -1, sparse(blocks), 0, 1, 0)
		end
		t.eq(placed({}), FENCE, "alone: a post")
		t.eq(placed({ ["0,1,-1"] = FENCE }), Blocks.fenceVariant(FENCE, N), "to a fence north")
		t.eq(placed({ ["1,1,0"] = STONE, ["-1,1,0"] = B.OakFenceEast }), Blocks.fenceVariant(FENCE, E + W))
		t.eq(placed({ ["0,1,1"] = B.OakLeaves or B.Leaves or AIR }), FENCE, "not to leaves (not sturdy)")
		t.eq(placed({ ["0,1,1"] = B.Torch }), FENCE, "not to a torch")
		t.eq(placed({ ["0,1,1"] = B.CaveOakFence }), Blocks.fenceVariant(FENCE, S), "to a cave fence")
		t.eq(placed({ ["0,1,1"] = false }), FENCE, "not to what is not loaded")
	end)

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
		return world, settle
	end

	t.test("fences on the server: neighbours changing grow and drop arms", function()
		local world, settle = newWorld()
		t.ok(EditRules.setPlaced(world, 0, FLOOR, 0, FENCE))
		t.ok(EditRules.setPlaced(world, 1, FLOOR, 0, FENCE), "a post placed beside it (its own arms are the placer's)")
		settle()
		t.eq(Blocks.fenceArms(world:getBlock(0, FLOOR, 0)), E, "the first one reaches east")
		t.eq(Blocks.fenceArms(world:getBlock(1, FLOOR, 0)), W, "the second one west")
		world:setBlock(0, FLOOR, -1, STONE)
		settle()
		t.eq(Blocks.fenceArms(world:getBlock(0, FLOOR, 0)), E + N, "and to a wall")
		world:setBlock(1, FLOOR, 0, AIR)
		world:setBlock(0, FLOOR, -1, AIR)
		settle()
		t.eq(world:getBlock(0, FLOOR, 0), FENCE, "alone again: a post")
		-- A cave post stays one until it gains an arm, then is the ordinary fence.
		world:setBlock(5, FLOOR, 5, B.CaveOakFence)
		world:setBlock(5, FLOOR + 1, 5, STONE)
		settle()
		t.eq(world:getBlock(5, FLOOR, 5), B.CaveOakFence)
		world:setBlock(6, FLOOR, 5, STONE)
		settle()
		t.eq(world:getBlock(5, FLOOR, 5), Blocks.fenceVariant(FENCE, E))
	end)

	t.test("fences: structures turn their arms", function()
		local id = Blocks.fenceVariant(FENCE, N + W) :: number
		t.eq(Blocks.fenceArms(Blocks.rotate(id, 1)), E + N, "a quarter turn clockwise")
		t.eq(Blocks.fenceArms(Blocks.rotate(id, 2)), S + E)
		t.eq(Blocks.fenceArms(Blocks.rotate(id, 0, "leftRight")), S + W, "north and south swap")
		t.eq(Blocks.fenceArms(Blocks.rotate(id, 0, "frontBack")), N + E, "west and east swap")
		t.eq(Blocks.rotate(B.CaveOakFence, 1), B.CaveOakFence, "a cave post stays a cave post")
	end)

	t.test("fences: a line of posts stops a player, a lone post only where it stands", function()
		-- A fence line along X at z = 0 (each post joined to its neighbours).
		local line = {}
		for x = -3, 3 do
			line[`{x},1,0`] = Blocks.fenceVariant(FENCE, (if x > -3 then W else 0) + (if x < 3 then E else 0)) :: number
		end
		local world = physicsWorld(sparse(line))
		-- Walking north at the gap between two posts (x = 0.5 is a post; 1.0 between): stopped.
		local state = walk(world, 1.0, 2.5, 0, -1, 40)
		t.ok(near(state.z, 10 / 16 + 0.3, 1e-3), `stopped by the arms between the posts: {state.z}`)
		-- Jumping does not clear 1.5 blocks.
		state = walk(world, 1.0, 2.5, 0, -1, 60, true)
		t.ok(state.z > 0.9, `can't jump the fence: {state.z}`)
		-- A lone post: walking past it a little to its side is free.
		local lone = physicsWorld(sparse({ ["0,1,0"] = FENCE }))
		state = walk(lone, 0.05, 2.5, 0, -1, 40)
		t.ok(state.z < -1, `walked past the post: {state.z}`)
		-- Against it: stopped at its side, 6 pixels in.
		state = walk(lone, 0.5, 2.5, 0, -1, 40)
		t.ok(near(state.z, 10 / 16 + 0.3, 1e-3), `stopped at the post: {state.z}`)
	end)

	t.test("hull: a fence's top half over its cell stops what moves sideways and lands on it", function()
		-- A post in the floor row (y = 1 with the floor at 0): its collision reaches y = 2.5.
		local getBlock = sparse({ ["0,1,0"] = FENCE, ["1,1,0"] = STONE, ["1,1,1"] = STONE })
		local solid = solidAt(getBlock)
		-- Standing on the stone at (1, 2, 0), walking west into the post's top half: stopped.
		local box = Hull.box(1.5, 2, 0.5, 0.6, 1.8)
		local dx = Hull.collideBox(solid, box, -1, 0, 0)
		t.ok(near(dx, 10 / 16 - 1.2), `stopped by the post's top half: {dx}`)
		-- Higher (feet at 2.5): free.
		dx = Hull.collideBox(solid, Hull.box(1.5, 2.5, 0.5, 0.6, 1.8), -1, 0, 0)
		t.ok(near(dx, -1), "over the top")
		-- Falling onto it: lands at 2.5 (a carpet-low box beside it doesn't win).
		local _, dy = Hull.collideBox(solid, Hull.box(0.5, 4, 0.5, 0.2, 1.8), 0, -5, 0)
		t.ok(near(dy, 2.5 - 4), `landed on the post: {dy}`)
		t.ok(not Hull.noCollision(solid, Hull.box(0.5, 2.2, 0.5, 0.2, 1.8)), "inside the top half")
		t.ok(Hull.noCollision(solid, Hull.box(0.5, 2.5, 0.5, 0.2, 1.8)), "on top of it")
	end)

	--[[ Transmitters ]]

	t.test("transmitters: they collide with their core and the arms they join", function()
		local pipe = B.BasicMechanicalPipe
		local transporter = B.BasicLogisticalTransporter
		local cable = B.BasicUniversalCable
		local alone = Shapes.collisionAt(sparse({}), 0, 1, 0, pipe)
		t.ok(type(alone) == "table" and #(alone :: any) == 1, "a lone pipe: its core")
		local core = (alone :: any)[1]
		t.ok(near(core.minX, 0.25) and near(core.maxX, 0.75) and near(core.maxY, 0.75), "8 pixels")
		local run = sparse({
			["-1,1,0"] = transporter,
			["1,1,0"] = transporter,
			["0,1,1"] = cable,
			["0,1,-1"] = pipe,
			["0,2,0"] = B.Chest,
		})
		local shape = Shapes.collisionAt(run, 0, 1, 0, transporter) :: any
		t.eq(#shape, 4, "core, two arms to transporters and one into the chest above (not the cable or pipe)")
		local reach = { minX = math.huge, maxX = -math.huge, maxY = -math.huge }
		for _, box in shape do
			reach.minX = math.min(reach.minX, box.minX)
			reach.maxX = math.max(reach.maxX, box.maxX)
			reach.maxY = math.max(reach.maxY, box.maxY)
		end
		t.ok(reach.minX == 0 and reach.maxX == 1 and reach.maxY == 1, "out to the faces")
		local small = Shapes.collisionAt(sparse({}), 0, 1, 0, cable) :: any
		t.ok(near(small[1].maxX - small[1].minX, 6 / 16), "a cable's 6 pixel core")
		t.ok(Shapes.isDynamic(pipe) and not Shapes.isDynamic(STONE))
		-- A player walking into a pipe lying on the floor: stopped (0.75 is over the step height).
		local world = physicsWorld(sparse({ ["0,1,0"] = pipe, ["-1,1,0"] = pipe, ["1,1,0"] = pipe }))
		local state = walk(world, 0.5, 2.5, 0, -1, 40)
		t.ok(state.z > 0.75 + 0.3 - 1e-3 and state.z < 1.3, `stopped by the pipe: {state.z}`)
	end)

	--[[ Line of sight ]]

	t.test("sight: a closed door hides a player from mobs and explosions, an open one doesn't", function()
		-- A door at (0, 1, 0) facing North: closed, its panel across the cell's south side.
		local blocks = {}
		local lower = Blocks.doorVariant(B.OakDoor, "North", "Left", false, false) :: number
		blocks["0,1,0"] = lower
		blocks["0,2,0"] = Blocks.plantTop(lower) :: number
		local getBlock = sparse(blocks)
		-- A mob north of the door, a player south of it.
		t.ok(not MobAI.canSee(getBlock, 0.5, 2.6, -2.5, 0.5, 2.6, 2.5), "the closed door hides the player")
		t.ok(MobAI.canSee(getBlock, 3.5, 2.6, -2.5, 3.5, 2.6, 2.5), "beside the door: seen")
		local seen = Explosion.seenPercent(getBlock, 0.5, 1.5, -2.5, 0.2, 1, 2.2, 0.8, 2.8, 2.8)
		t.eq(seen, 0, "an explosion behind the door doesn't reach")
		for _, change in Doors.use(lower, getBlock, 0, 1, 0) do
			blocks[`{change.x},{change.y},{change.z}`] = change.block
		end
		t.ok(MobAI.canSee(getBlock, 0.5, 2.6, -2.5, 0.5, 2.6, 2.5), "through the open doorway")
		t.ok(Explosion.seenPercent(getBlock, 0.5, 1.5, -2.5, 0.2, 1, 2.2, 0.8, 2.8, 2.8) > 0.5, "nor an explosion")
		-- Air, torches and the like never hide anything; stone does.
		local torch = sparse({ ["0,2,0"] = B.Torch })
		t.ok(MobAI.canSee(torch, 0.5, 2.5, -2.5, 0.5, 2.5, 2.5))
		local wall = sparse({ ["0,2,0"] = STONE })
		t.ok(not MobAI.canSee(wall, 0.5, 2.5, -2.5, 0.5, 2.5, 2.5))
	end)
end
