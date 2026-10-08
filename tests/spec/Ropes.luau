--[[
	Using rope on rope (Shared/Rope, after Supplementaries' RopeHelper): the rope column and its
	bottom, where a new rope is let down (under the bottom, into replaceable cells without fluid,
	never below y 1 nor into unloaded ones), which rope an empty hand pulls up (the bottom of a
	column of two or more), what a use does to the hand (one used, none in creative; the pulled
	rope given back, nothing in creative), which clicks the client sends; then the same on the
	server's world (WorldServer, BlockTicker and Behaviours, as Players/ItemUse plays it out): a
	rope let down to the floor holds rope by rope, edits are recorded, and cutting it brings every
	rope below down, each dropping itself.
]]

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Rope = require(shared.Rope)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local WorldServer = require(server.World.WorldServer)
	local BlockTicker = require(server.World.BlockTicker)
	local Behaviours = require(server.Behaviours)
	local Drops = require(server.Behaviours.Drops)

	local B, I = Blocks.id, Items.id
	local AIR, STONE, ROPE = Blocks.AIR, B.Stone, B.Rope
	local WATER = Blocks.fluidId("Water", 0)

	-- A sparse world: unset blocks are air, `false` = not loaded.
	local function sparse(blocks: { [string]: number | false })
		return function(x: number, y: number, z: number): number?
			local b = blocks[`{x},{y},{z}`]
			if b == false then
				return nil
			end
			return b or AIR
		end
	end
	-- A rope from y = top down to y = bottom at (0, 0) under a stone ceiling, plus `extra` cells.
	local function column(top: number, bottom: number, extra: { [string]: number | false }?)
		local blocks: { [string]: number | false } = table.clone(extra or {})
		blocks[`0,{top + 1},0`] = STONE
		for y = bottom, top do
			blocks[`0,{y},0`] = ROPE
		end
		return blocks, sparse(blocks)
	end
	-- An Env over a sparse table (setBlock writes it).
	local function envOf(blocks: { [string]: number | false }): Rope.Env
		return {
			getBlock = sparse(blocks),
			setBlock = function(x: number, y: number, z: number, block: number): boolean
				if blocks[`{x},{y},{z}`] == false then
					return false
				end
				blocks[`{x},{y},{z}`] = block
				return true
			end,
		}
	end

	t.test("rope rules: the column's bottom, and where a new rope goes", function()
		local _, get = column(20, 12)
		t.eq(Rope.bottom(get, 0, 20, 0), 12, "from the top")
		t.eq(Rope.bottom(get, 0, 15, 0), 12, "from the middle")
		t.eq(Rope.bottom(get, 0, 12, 0), 12, "the bottom itself")
		t.eq(Rope.extendTarget(get, 0, 20, 0), 11, "under the bottom, however far down")
		t.eq(Rope.extendTarget(get, 0, 12, 0), 11)
		t.eq(Rope.extendTarget(get, 1, 15, 0), nil, "not a rope")

		local function under(block: number | false): number?
			local _, g = column(20, 12, { ["0,11,0"] = block })
			return Rope.extendTarget(g, 0, 16, 0)
		end
		t.eq(under(B.CaveAir), 11, "into cave air")
		t.eq(under(B.ShortGrass), 11, "into a replaceable plant")
		t.eq(under(B.Vine), 11, "into a vine")
		t.eq(under(STONE), nil, "not into stone")
		t.eq(under(B.Torch), nil, "not into a torch")
		t.eq(under(WATER), nil, "not into water")
		t.eq(under(Blocks.fluidId("Lava", 0)), nil, "not into lava")
		t.eq(under(false), nil, "not into an unloaded cell")
		-- Never below y 1.
		local _, low = column(5, 1)
		t.eq(Rope.extendTarget(low, 0, 5, 0), nil, "the world's bottom layer is never reached")
		local _, twoUp = column(5, 2)
		t.eq(Rope.extendTarget(twoUp, 0, 5, 0), 1)
	end)

	t.test("rope rules: an empty hand pulls the bottom of a column of two or more", function()
		local _, get = column(20, 12)
		t.eq(Rope.pullTarget(get, 0, 20, 0), 12, "clicked at the top")
		t.eq(Rope.pullTarget(get, 0, 12, 0), 12, "clicked at the bottom (rope above it)")
		local _, lone = column(20, 20)
		t.eq(Rope.pullTarget(lone, 0, 20, 0), nil, "a lone rope is only broken")
		t.eq(Rope.pullTarget(get, 0, 21, 0), nil, "not a rope")
		-- Which clicks are the rope's (the client sends them as uses).
		t.ok(Rope.wantsUse(I.Rope, ROPE, false), "Rope on a rope")
		t.ok(Rope.wantsUse(nil, ROPE, false), "an empty hand on a rope")
		t.ok(not Rope.wantsUse(I.Rope, ROPE, true), "sneaking places against the face instead")
		t.ok(not Rope.wantsUse(nil, ROPE, true), "sneaking with an empty hand does nothing")
		t.ok(not Rope.wantsUse(I.Rope, STONE, false), "Rope on stone is placed as usual")
		t.ok(not Rope.wantsUse(I.Stick, ROPE, false), "other items do nothing to it")
		t.eq(I.Rope, ROPE, "the rope is its own item")
	end)

	t.test("rope rules: a use lets one down or pulls one up, using and giving items", function()
		local blocks = column(20, 15)
		local env = envOf(blocks)
		local held = Items.newStack(I.Rope, 5) :: Items.Stack
		local done = Rope.use(env, held, ROPE, 0, 20, 0, false, false)
		t.ok(done ~= nil, "let down")
		local d = done :: Rope.Result
		t.eq(d.y, 14, "under the bottom")
		t.eq(blocks["0,14,0"], ROPE, "placed")
		t.eq((d.held :: Items.Stack).count, 4, "one used")
		t.eq(d.action, "place")
		t.eq(d.pitch, 0.8)
		t.eq(d.give, nil)
		-- The last one in hand.
		local last = Rope.use(env, Items.newStack(I.Rope, 1), ROPE, 0, 20, 0, false, false) :: Rope.Result
		t.eq(last.y, 13)
		t.eq(last.held, nil, "the hand is empty")
		-- Creative: nothing used.
		local creative = Rope.use(env, held, ROPE, 0, 20, 0, false, true) :: Rope.Result
		t.eq(creative.y, 12)
		t.eq(creative.held, held, "creative keeps the stack")
		-- Sneaking, or not a rope: nothing.
		t.eq(Rope.use(env, held, ROPE, 0, 20, 0, true, false), nil, "sneaking")
		t.eq(Rope.use(env, held, STONE, 0, 21, 0, false, false), nil, "on the ceiling")
		t.eq(Rope.use(env, Items.newStack(I.Stick, 3), ROPE, 0, 20, 0, false, false), nil, "a stick")

		-- Pulling: the bottom rope comes back.
		local pulled = Rope.use(env, nil, ROPE, 0, 20, 0, false, false) :: Rope.Result
		t.eq(pulled.y, 12, "the bottom one")
		t.eq(blocks["0,12,0"], AIR, "removed")
		t.eq((pulled.give :: Items.Stack).item, I.Rope, "given back")
		t.eq((pulled.give :: Items.Stack).count, 1)
		t.eq(pulled.action, "break")
		t.eq(pulled.pitch, 0.6)
		local inCreative = Rope.use(env, nil, ROPE, 0, 16, 0, false, true) :: Rope.Result
		t.eq(inCreative.y, 13)
		t.eq(inCreative.give, nil, "nothing given in creative")

		-- Into stone or water: nothing happens, nothing is used.
		local walled = column(20, 15, { ["0,14,0"] = STONE })
		t.eq(Rope.use(envOf(walled), held, ROPE, 0, 20, 0, false, false), nil, "stone in the way")
		t.eq(walled["0,14,0"], STONE)
		local wet = column(20, 15, { ["0,14,0"] = WATER })
		t.eq(Rope.use(envOf(wet), held, ROPE, 0, 20, 0, false, false), nil, "water in the way")
		t.eq(wet["0,14,0"], WATER, "the water keeps its cell")
		-- A world that refuses the edit: nothing used.
		local refusing = envOf(column(20, 15))
		refusing.setBlock = function()
			return false
		end
		t.eq(Rope.use(refusing, held, ROPE, 0, 20, 0, false, false), nil, "refused")
		t.eq(Rope.use(refusing, nil, ROPE, 0, 20, 0, false, false), nil, "refused")
	end)

	--[[ The server's world ]]

	local FLOOR = 10
	local CROP = 32
	local flat = {
		generate = function(level: number, nx: number, nz: number)
			local data = ChunkLayout.create(CROP)
			for y = 0, FLOOR - 1 do
				for i = 0, ChunkLayout.LAYER - 1 do
					buffer.writeu16(data, (y * ChunkLayout.LAYER + i) * 2, STONE)
				end
			end
			return {
				data = data,
				level = level,
				nx = nx,
				nz = nz,
				height = CROP,
				solidBelow = FLOOR,
				emptyAbove = FLOOR,
			}
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
		local dropped = {}
		Drops.set(function(x, y, z, stack)
			table.insert(dropped, { x = x, y = y, z = z, item = stack.item, count = stack.count })
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

	t.test("rope on the server: let down to the floor, pulled up, cut", function()
		local world, settle, dropped = newWorld()
		local env: Rope.Env = {
			getBlock = function(x: number, y: number, z: number): number?
				return world:peekBlock(x, y, z)
			end,
			setBlock = function(x: number, y: number, z: number, block: number): boolean
				return world:setBlock(x, y, z, block)
			end,
		}
		local TOP = FLOOR + 12
		world:setBlock(3, TOP + 1, 3, STONE)
		world:setBlock(3, TOP, 3, ROPE)
		local held: Items.Stack? = Items.newStack(I.Rope, 64)
		local placed = 0
		for _ = 1, 40 do
			local done = Rope.use(env, held, ROPE, 3, TOP, 3, false, false)
			if done == nil then
				break
			end
			held = done.held
			placed += 1
			settle()
		end
		t.eq(placed, TOP - FLOOR, "down to the floor and no further")
		for y = FLOOR, TOP do
			t.eq(world:getBlock(3, y, 3), ROPE, `rope at {y} holds`)
			t.ok(Blocks.canSurvive(ROPE, env.getBlock, 3, y, 3), "hanging from the one above")
		end
		t.eq((held :: Items.Stack).count, 64 - placed, "one used each")
		t.eq(#dropped, 0)
		-- Every rope let down is an edit (saved and replicated as any other).
		local edits = world:chunkEdits(0, 0)
		t.ok(edits ~= nil and edits[ChunkLayout.localIndex(3, FLOOR, 3)] == ROPE, "recorded")

		-- An empty hand pulls three back up, from the top.
		local given = 0
		for _ = 1, 3 do
			local done = Rope.use(env, nil, ROPE, 3, TOP, 3, false, false) :: Rope.Result
			given += (done.give :: Items.Stack).count
			settle()
		end
		t.eq(given, 3)
		t.eq(world:getBlock(3, FLOOR + 2, 3), AIR, "the bottom three are gone")
		t.eq(world:getBlock(3, FLOOR + 3, 3), ROPE)

		-- Cut under the ceiling: every rope below comes down, a block a tick, each dropping itself.
		world:setBlock(3, TOP, 3, AIR)
		settle()
		for y = FLOOR, TOP do
			t.eq(world:getBlock(3, y, 3), AIR, `rope at {y} fell`)
		end
		t.eq(#dropped, TOP - 1 - (FLOOR + 3) + 1, "every rope below the cut")
		for _, drop in dropped do
			t.eq(drop.item, I.Rope)
			t.eq(drop.count, 1)
		end
		Drops.set(nil)
	end)
end
