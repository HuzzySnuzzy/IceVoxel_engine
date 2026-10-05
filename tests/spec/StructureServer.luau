--[[
	Structure blocks and jigsaw blocks on the server: who may use them (Structures/Permission), the
	edit rules for creative only blocks and cave twins (EditRules), glow lichen and its cave twins
	broken with Shears, water kept out of structure voids (Fluid), the settings store and its
	records (StructureStore), generated chests filled once (Players/Containers), LOAD and Generate
	plans and the queue that places them over frames (Placement), and the whole server core
	(StructureServer) end to end on a flat world: SAVE (voids, data markers, jigsaws, containers,
	cave forms), LOAD by name and from pasted data (Minecraft's turn around the pivot, mirrors,
	integrity, the two step "position prepared"), DETECT with corners, mode changes, refused
	names, permission and range, and a jigsaw's Generate from this session's saves.
]]

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Config = require(shared.Config)
	local Mining = require(shared.Mining)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Protocol = require(shared.Net.Protocol)
	local Settings = require(shared.Structures.Settings)
	local Template = require(shared.Structures.Template)
	local Library = require(shared.Structures.Library)
	local WorldServer = require(server.World.WorldServer)
	local BlockTicker = require(server.World.BlockTicker)
	local Behaviours = require(server.Behaviours)
	local EditRules = require(server.Network.EditRules)
	local Containers = require(server.Players.Containers)
	local Permission = require(server.Structures.Permission)
	local StructureStore = require(server.Structures.StructureStore)
	local Placement = require(server.Structures.Placement)
	local StructureServer = require(server.Structures.StructureServer)

	local B, I = Blocks.id, Items.id
	local AIR, STONE, GRASS, DIRT = Blocks.AIR, B.Stone, B.Grass, B.Dirt
	local CHEST = B.Chest
	local SAVE_BLOCK = Blocks.structureBlock("save") :: number
	local LOAD_BLOCK = Blocks.structureBlock("load") :: number
	local CORNER_BLOCK = Blocks.structureBlock("corner") :: number
	local DATA_BLOCK = Blocks.structureBlock("data") :: number
	local VOID = B.StructureVoid
	local WATER = Blocks.fluidId("Water", 0)

	-- Minecraft's StructureTemplate.transform of a local (x, z) around the pivot 0: mirror, then turn.
	local function mcTransform(x: number, z: number, rotation: number, mirror: string): (number, number)
		if mirror == "leftRight" then
			z = -z
		elseif mirror == "frontBack" then
			x = -x
		end
		local r = rotation % 4
		if r == 1 then
			return -z, x
		elseif r == 2 then
			return -x, -z
		elseif r == 3 then
			return z, -x
		end
		return x, z
	end

	--[[ A flat world: stone, grass on top at FLOOR - 1, air from FLOOR up ]]

	local FLOOR = 10
	local CROP = 32
	local flat = {
		generate = function(level: number, nx: number, nz: number)
			local data = ChunkLayout.create(CROP)
			for y = 0, FLOOR - 1 do
				local block = if y == FLOOR - 1 then GRASS else STONE
				for i = 0, ChunkLayout.LAYER - 1 do
					buffer.writeu16(data, (y * ChunkLayout.LAYER + i) * 2, block)
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
			return FLOOR, 1, 0, GRASS
		end,
		findSpawn = function()
			return 0, FLOOR, 0
		end,
	}

	type Fake = {
		world: any,
		store: any,
		containers: any,
		server: any,
		notices: { [any]: { string } },
		opened: { { kind: string, player: any, records: { any }, open: boolean } },
		data: { [any]: { string } },
		stored: { [string]: string },
		changed: number,
		ticker: any,
	}

	-- A server core on a fresh flat world: notices, records sent, texts sent and stored are kept.
	-- Players are tables; one with `far = true` is out of range of everything.
	local function newServer(library: any?): Fake
		local world = WorldServer.new(flat :: any)
		local ticker = BlockTicker.new(world, Behaviours.byId, 100000)
		local store = StructureStore.new()
		local containers = Containers.new()
		local fake: Fake = {
			world = world,
			store = store,
			containers = containers,
			server = nil,
			notices = {},
			opened = {},
			data = {},
			stored = {},
			changed = 0,
			ticker = ticker,
		}
		world.onChanged = function(x, y, z, old, new)
			containers:materialize(x, y, z, old)
			ticker:blockChanged(x, y, z)
			if old ~= new then
				containers:take(x, y, z)
			end
			store:blockChanged(x, y, z, old, new)
		end
		local seeds = 0
		fake.server = StructureServer.new({
			world = world,
			store = store,
			containers = containers,
			library = function()
				return library or Library.new({})
			end,
			notify = function(player, text)
				local list = fake.notices[player] or {}
				fake.notices[player] = list
				table.insert(list, text)
			end,
			sendStructureBlocks = function(player, records, open)
				table.insert(fake.opened, { kind = "structure", player = player, records = records, open = open })
			end,
			sendJigsaws = function(player, records, open)
				table.insert(fake.opened, { kind = "jigsaw", player = player, records = records, open = open })
			end,
			sendData = function(player, text)
				local list = fake.data[player] or {}
				fake.data[player] = list
				table.insert(list, text)
			end,
			stored = function(name, text)
				fake.stored[name] = text
			end,
			forget = function(name)
				fake.stored[name] = nil
			end,
			containerChanged = function()
				fake.changed += 1
			end,
			seed = function()
				seeds += 1
				return 12345 + seeds
			end,
			inRange = function(player, _x, _y, _z, _range)
				return not player.far
			end,
		})
		for cx = -2, 4 do
			for cz = -2, 2 do
				world:getChunk(cx, cz)
			end
		end
		return fake
	end

	local function last(fake: Fake, player: any): string?
		local list = fake.notices[player]
		return if list then list[#list] else nil
	end

	-- Settings for a request: the defaults of `mode` with `fields` over them.
	local function settings(mode: string, fields: { [string]: any }?): any
		local s = Settings.defaultStructure(mode)
		for k, v in fields or {} do
			s[k] = v
		end
		return s
	end

	local function name(world: any, x: number, y: number, z: number): string
		return Blocks.get(world:getBlock(x, y, z)).name
	end

	--[[ Permission and edit rules ]]

	t.test("structure permission: creative, a rule listing nobody by default; owner, admins, Studio", function()
		t.eq(Permission.allowed(1, true, true, false, false), true, "every creative player")
		t.eq(Permission.allowed(1, true, false, false, false), false, "never in survival")
		t.eq(Permission.allowed(1, true, false, true, true), false, "not even the owner in survival")
		t.eq(Permission.allowed(1, false, true, false, false), false, "nobody")
		t.eq(Permission.allowed(1, false, true, true, false), true, "the owner")
		t.eq(Permission.allowed(1, false, true, false, true), true, "Studio")
		t.eq(Permission.allowed(7, { 5, 7 }, true, false, false), true, "a listed user")
		t.eq(Permission.allowed(6, { 5, 7 }, true, false, false), false, "an unlisted one")
		t.eq(Permission.allowed(6, {}, true, false, false, { 6 }), true, "an admin (an operator)")
		t.eq(Permission.allowed(6, {}, false, false, false, { 6 }), false, "but not in survival")
		t.eq(Permission.allowed(8, {}, true, false, false, { 6 }), false, "anyone else")
		-- By default only operators (Minecraft's rule): everyone may enter creative with
		-- /gamemode (Gameplay.GameModeCommand), so true would hand them uploads, 48^3 LOADs and
		-- whole jigsaw structures.
		local rule = Config.Structures.Permission
		t.ok(type(rule) == "table" and #rule == 0, "the default lists nobody")
		t.eq(Permission.allowed(123, rule, true, false, false, Config.Gameplay.Admins), false, "a creative stranger")
		t.eq(Permission.allowed(123, rule, true, true, false, Config.Gameplay.Admins), true, "the owner")
	end)

	t.test("structure edit rules: creative only blocks need an operator, nobody places cave twins", function()
		for _, block in { SAVE_BLOCK, LOAD_BLOCK, VOID, B.Jigsaw, B.JigsawUpNorth } do
			t.eq(EditRules.mayUseCreativeOnly(block, false), false, Blocks.get(block).name)
			t.eq(EditRules.mayUseCreativeOnly(block, true), true, Blocks.get(block).name)
		end
		t.eq(EditRules.mayUseCreativeOnly(STONE, false), true, "everything else")
		-- Survival players can't mine them; creative operators break them at once.
		t.eq(EditRules.mayBreak(SAVE_BLOCK, false, { x = 0, y = 0, z = 0, startedAt = 0 }, 0, 0, 0, 1000, nil), false)
		t.eq(EditRules.mayBreak(SAVE_BLOCK, true, nil, 0, 0, 0, 0, nil), true)
		t.eq(EditRules.drops(SAVE_BLOCK, false, nil), nil, "they never drop")
		-- Placing: structure blocks, voids and jigsaws are placeable; mode variants are their item's.
		t.eq(EditRules.mayPlace(SAVE_BLOCK, AIR), true)
		t.eq(EditRules.mayPlace(LOAD_BLOCK, AIR), true, "a variant of the structure block")
		t.eq(EditRules.mayPlace(VOID, AIR), true)
		t.eq(EditRules.mayPlace(B.JigsawEastUp, AIR), true)
		t.eq(EditRules.mayPlace(STONE, VOID), true, "a structure void is replaceable")
		-- Cave twins only come from generation.
		for _, side in { "", "Up", "North", "South", "West", "East" } do
			t.eq(EditRules.mayPlace(B["GlowLichen" .. side], AIR), true, "glow lichen " .. side)
			t.eq(EditRules.mayPlace(B["CaveGlowLichen" .. side], AIR), false, "cave twin " .. side)
		end
	end)

	t.test("glow lichen and its cave twins: 2 Glow Dust, themselves with Shears", function()
		local shears = I.Shears
		for _, side in { "", "Up", "North", "South", "West", "East" } do
			for _, prefix in { "", "Cave" } do
				local block = B[prefix .. "GlowLichen" .. side]
				local label = Blocks.get(block).name
				local drop = EditRules.drops(block, false, shears)
				t.ok(drop ~= nil and drop.item == I.GlowLichen and drop.count == 1, `{label} with Shears`)
				local byHand, withAxe = EditRules.drops(block, false, nil), EditRules.drops(block, false, I.DiamondAxe)
				for _, dust in { byHand, withAxe } do
					t.ok(dust ~= nil and dust.item == I.GlowDust and dust.count == 2, `{label}: 2 glow dust`)
				end
				t.ok(byHand ~= nil and withAxe ~= nil, `{label}: dust by hand and with an axe`)
				t.eq(EditRules.drops(block, true, shears), nil, `{label} in creative`)
				local popped = Items.blockDrops(block)
				t.ok(popped ~= nil and popped.item == I.GlowDust and popped.count == 2, `{label} popping off`)
				t.eq(Mining.toolSpeed(block, shears), 2, `{label}: Shears mine it at 2`)
				t.eq(Items.ofBlock(block), I.GlowLichen, `{label}'s item`)
				-- 0.2 hardness: with Shears it takes a few ticks; a survival break after them passes.
				local ticks = Mining.ticks(block, true, false, shears)
				t.ok(ticks > 1 and ticks < 20, `{label} takes {ticks} ticks with Shears`)
				local mine = { x = 0, y = 0, z = 0, startedAt = 0 }
				t.eq(EditRules.mayBreak(block, false, mine, 0, 0, 0, ticks / Mining.TICK_RATE, shears), true)
				t.eq(EditRules.wear(block, false, shears), 1, `{label} wears Shears by 1`)
				t.eq(Behaviours.byId[block] ~= nil, true, `{label} pops off without its wall`)
			end
		end
	end)

	t.test("fluids: water never flows into a structure void", function()
		local fake = newServer()
		local world = fake.world
		for x = -3, 3 do
			for z = -3, 3 do
				world:setBlock(x, FLOOR - 1, z, STONE)
			end
		end
		world:setBlock(1, FLOOR, 0, VOID)
		world:setBlock(0, FLOOR, 1, VOID)
		world:setBlock(0, FLOOR, 0, WATER)
		for _ = 1, 400 do
			fake.ticker:step()
			if fake.ticker:pendingCount() == 0 then
				break
			end
		end
		t.eq(world:getBlock(1, FLOOR, 0), VOID, "the void east of the source stays")
		t.eq(world:getBlock(0, FLOOR, 1), VOID, "and the one south of it")
		t.ok(Blocks.get(world:getBlock(-1, FLOOR, 0)).fluid ~= nil, "water flows west")
	end)

	--[[ The settings store ]]

	t.test("structure store: entries follow the blocks, modes swap, records replicate", function()
		local store = StructureStore.new()
		store:blockChanged(3, 5, 7, AIR, LOAD_BLOCK)
		local s = store:structure(3, 5, 7)
		t.ok(s ~= nil and s.mode == "load" and s.size[1] == 5 and s.offset[2] == 1, "defaults in the block's mode")
		local structures, jigsaws = store:takeDirty()
		t.eq(#structures, 1)
		t.eq(#jigsaws, 0)
		t.eq(#({ store:takeDirty() })[1], 0, "taken")

		local named = settings("load", { name = "keep/me", size = { 9, 8, 7 } })
		t.eq(store:setStructure(3, 5, 7, named), true)
		named.name = "changed after"
		t.eq((store:structure(3, 5, 7) :: any).name, "keep/me", "a copy is stored")
		-- A mode change swaps the block: the settings stay with the new mode.
		store:blockChanged(3, 5, 7, LOAD_BLOCK, CORNER_BLOCK)
		local swapped = store:structure(3, 5, 7) :: any
		t.eq(swapped.mode, "corner")
		t.eq(swapped.name, "keep/me")
		t.eq(swapped.size[1], 9)
		-- Unchanged settings make no record; breaking forgets and records the removal.
		store:takeDirty()
		store:setStructure(3, 5, 7, swapped)
		t.eq(#({ store:takeDirty() })[1], 0, "nothing changed")
		store:blockChanged(3, 5, 7, CORNER_BLOCK, AIR)
		t.eq(store:structure(3, 5, 7), nil)
		structures = store:takeDirty()
		t.eq(#structures, 1)
		t.eq(structures[1].settings, nil, "a removal record")
		t.eq(store:setStructure(3, 5, 7, swapped), false, "no block, no settings")

		-- Jigsaws: defaults per front (vertical fronts roll), kept when the jigsaw turns.
		store:blockChanged(0, 0, 0, AIR, B.JigsawUpNorth)
		store:blockChanged(1, 0, 0, AIR, B.Jigsaw)
		t.eq((store:jigsaw(0, 0, 0) :: any).joint, "rollable")
		t.eq((store:jigsaw(1, 0, 0) :: any).joint, "aligned")
		t.eq((store:jigsaw(1, 0, 0) :: any).pool, "empty")
		store:setJigsaw(1, 0, 0, { name = "a", target = "b", pool = "p", finalState = "Stone", joint = "aligned" })
		store:blockChanged(1, 0, 0, B.Jigsaw, B.JigsawEastUp)
		t.eq((store:jigsaw(1, 0, 0) :: any).pool, "p", "turned, the settings stay")
		store:blockChanged(1, 0, 0, B.JigsawEastUp, SAVE_BLOCK)
		t.eq(store:jigsaw(1, 0, 0), nil, "a jigsaw replaced by a structure block")
		t.eq((store:structure(1, 0, 0) :: any).mode, "save")
		local _, jigsawRecords = store:takeDirty()
		t.eq(#jigsawRecords, 2)

		-- Chunk records and corners.
		store:blockChanged(20, 3, 20, AIR, CORNER_BLOCK)
		store:setStructure(20, 3, 20, settings("corner", { name = "box" }))
		store:blockChanged(100, 3, 20, AIR, CORNER_BLOCK)
		store:setStructure(100, 3, 20, settings("corner", { name = "box" }))
		store:blockChanged(21, 3, 20, AIR, CORNER_BLOCK)
		local inChunk = store:chunkRecords(1, 1)
		t.eq(#inChunk, 2, "two corners in chunk (1, 1)")
		local corners = store:corners(0, 0, 80, "box")
		t.eq(#corners, 1, "the one within 80 blocks with that name")
		t.eq(corners[1][1], 20)
		t.eq(#store:corners(0, 0, 80, ""), 1, "the unnamed one")
	end)

	--[[ Generated containers ]]

	t.test("containers: a generated chest gets its contents once, however it is first needed", function()
		local store = Containers.new()
		local asked = 0
		local blocks: { [string]: number } = {}
		store.generated = {
			blockAt = function(x, y, z)
				return blocks[`{x},{y},{z}`]
			end,
			contents = function(x, y, z, block)
				asked += 1
				if y ~= 1 then
					return nil
				end
				return { [1] = { item = I.Stick, count = 5 }, [40] = { item = I.Stick, count = 1 } }
			end,
		}
		-- Opened: filled (slots beyond the chest are left out).
		local chest = store:get(0, 1, 0, CHEST)
		t.ok(chest.slots[1] ~= nil and chest.slots[1].count == 5, "filled when opened")
		t.eq(chest.slots[40], nil)
		-- Taken (broken) and a new chest placed there: empty.
		store:take(0, 1, 0)
		t.eq(next(store:get(0, 1, 0, CHEST).slots), nil, "never again")
		-- Read by a pipe or a save (peek), where the chunk is loaded.
		t.eq(store:peek(5, 1, 5), nil, "not loaded: not guessed")
		blocks["5,1,5"] = CHEST
		local peeked = store:peek(5, 1, 5)
		t.ok(peeked ~= nil and peeked.slots[1].count == 5, "peek materializes it")
		-- Broken unopened: materialized with the old block before anything hears of it.
		store:materialize(9, 1, 9, CHEST)
		local taken = store:take(9, 1, 9)
		t.ok(taken ~= nil and taken.slots[1] ~= nil, "its contents drop")
		-- Emptied and closed: forgotten, and opening it again finds it empty.
		local box = store:get(3, 1, 3, CHEST)
		table.clear(box.slots)
		store:addViewer(3, 1, 3, "p")
		store:removeViewer(3, 1, 3, "p")
		t.eq(store:peek(3, 1, 3), nil, "forgotten")
		t.eq(next(store:get(3, 1, 3, CHEST).slots), nil, "no refill")
		-- Nothing generated there: asked once, nothing kept.
		local before = asked
		t.eq(store:peek(7, 2, 7), nil)
		blocks["7,2,7"] = CHEST
		t.eq(store:peek(7, 2, 7), nil)
		t.eq(store:peek(7, 2, 7), nil)
		t.eq(asked, before + 1, "asked once")
		t.eq(store.count, 3)
	end)

	--[[ Plans and the queue ]]

	-- A template of `size` filled by `fill(x, y, z)` (nil: keep).
	local function build(templateName: string, size: { number }, fill: (number, number, number) -> number?): any
		local tp = Template.new(templateName, size)
		for y = 0, size[2] - 1 do
			for z = 0, size[3] - 1 do
				for x = 0, size[1] - 1 do
					Template.set(tp, x, y, z, fill(x, y, z))
				end
			end
		end
		return tp
	end

	t.test("load plans: Minecraft's turn around the pivot, mirrors, turned blocks, keep cells", function()
		-- Every cell a different block, so each lands where it should.
		local kinds = { STONE, DIRT, B.Cobblestone, B.Sand, B.Gravel, B.Glass, B.OakLog, B.Planks }
		local tp = build("test/cells", { 4, 2, 3 }, function(x, y, z)
			if x == 3 and y == 1 and z == 2 then
				return nil
			end
			return kinds[(x + y * 4 + z * 8) % #kinds + 1]
		end)
		for _, mirror in Settings.MIRRORS do
			for rotation = 0, 3 do
				local plan = Placement.loadPlan(tp, {
					x = 100,
					y = 20,
					z = -50,
					rotation = rotation,
					mirror = mirror,
					integrity = 1,
					seed = 1,
				})
				t.eq(plan.count, 4 * 2 * 3 - 1, "every cell but the keep one")
				local placed: { [string]: number } = {}
				for _, cell in Placement.list(plan) do
					placed[`{cell[1]},{cell[2]},{cell[3]}`] = cell[4]
				end
				for y = 0, 1 do
					for z = 0, 2 do
						for x = 0, 3 do
							local wx, wz = mcTransform(x, z, rotation, mirror)
							local at = `{100 + wx},{20 + y},{-50 + wz}`
							local expected = Template.get(tp, x, y, z)
							t.eq(placed[at], expected, `{mirror} {rotation}: local {x} {y} {z}`)
						end
					end
				end
			end
		end
		-- Wall torches, glow lichen and jigsaws turn; the torch goes after the wall it hangs on.
		local turned = build("test/turned", { 2, 1, 1 }, function(x)
			return if x == 0 then B.WallTorchNorth else STONE
		end)
		local plan =
			Placement.loadPlan(turned, { x = 0, y = 0, z = 0, rotation = 1, mirror = "none", integrity = 1, seed = 1 })
		local list = Placement.list(plan)
		t.eq(list[1][4], STONE, "the solid block first")
		t.eq(list[2][4], B.WallTorchEast, "a north facing torch turned once faces east")
		local mirrored = Placement.loadPlan(
			turned,
			{ x = 0, y = 0, z = 0, rotation = 0, mirror = "leftRight", integrity = 1, seed = 1 }
		)
		t.eq(Placement.list(mirrored)[2][4], B.WallTorchSouth, "left-right flips north and south")
	end)

	t.test("load plans: markers, jigsaws and containers; integrity from the seed", function()
		local tp = build("test/records", { 3, 1, 1 }, function(x)
			return ({ B.Jigsaw, CHEST, AIR })[x + 1]
		end)
		table.insert(tp.jigsaws, {
			x = 0,
			y = 0,
			z = 0,
			front = "North",
			top = "Up",
			name = "door",
			target = "hall",
			pool = "village/halls",
			finalState = "Stone",
			joint = "aligned",
		})
		table.insert(
			tp.containers,
			{ x = 1, y = 0, z = 0, items = { { slot = 2, item = "Stick", count = 4, damage = 0 } } }
		)
		table.insert(tp.markers, { x = 2, y = 0, z = 0, data = "chest_loot" })
		local plan =
			Placement.loadPlan(tp, { x = 0, y = 5, z = 0, rotation = 1, mirror = "none", integrity = 1, seed = 1 })
		local list = Placement.list(plan)
		t.eq(#list, 3)
		local byBlock: { [number]: number } = {}
		for i, cell in list do
			byBlock[cell[4]] = i
		end
		local jigsaw = byBlock[B.JigsawEastUp]
		t.ok(jigsaw ~= nil, "the jigsaw turned with the structure")
		t.eq((plan.extras[jigsaw].jigsaw :: any).pool, "village/halls", "and kept its settings")
		local data = byBlock[DATA_BLOCK]
		t.ok(data ~= nil, "the data marker came back as a DATA structure block")
		t.eq((plan.extras[data].structure :: any).metadata, "chest_loot")
		t.eq((plan.extras[data].structure :: any).mode, "data")
		local chest = byBlock[CHEST]
		t.eq((plan.extras[chest].items :: any)[1].item, "Stick")
		-- A container without a record is emptied.
		local empty = build("test/empty", { 1, 1, 1 }, function()
			return CHEST
		end)
		local emptied =
			Placement.loadPlan(empty, { x = 0, y = 5, z = 0, rotation = 0, mirror = "none", integrity = 1, seed = 1 })
		t.eq(#(emptied.extras[1].items :: any), 0)

		-- Integrity: about that share, the same for the same seed, none at 0.
		local big = build("test/big", { 20, 5, 20 }, function()
			return STONE
		end)
		local function count(integrity: number, seed: number): number
			return Placement.loadPlan(
				big,
				{ x = 0, y = 5, z = 0, rotation = 0, mirror = "none", integrity = integrity, seed = seed }
			).count
		end
		local half = count(0.5, 77)
		t.ok(half > 850 and half < 1150, `about half of 2000 cells: {half}`)
		t.eq(count(0.5, 77), half, "the same seed, the same cells")
		t.ok(count(0.5, 78) ~= half or count(0.5, 79) ~= half, "another seed, other cells")
		t.eq(count(0, 1), 0)
		t.eq(count(1, 1), 2000)
		-- Cells outside the world are left out (layers -3..-1 of five).
		t.eq(
			Placement.loadPlan(big, { x = 0, y = -3, z = 0, rotation = 0, mirror = "none", integrity = 1, seed = 1 }).count,
			800
		)
	end)

	t.test("placing queue: blocks and chunks per step, tall plants never split", function()
		local tp = build("test/garden", { 3, 2, 1 }, function(x, y)
			if y == 0 then
				return if x == 1 then B.Sunflower else B.Dandelion
			end
			return if x == 1 then B.SunflowerTop else nil
		end)
		local plan =
			Placement.loadPlan(tp, { x = 0, y = 0, z = 0, rotation = 0, mirror = "none", integrity = 1, seed = 1 })
		local list = Placement.list(plan)
		t.eq(#list, 4)
		local set: { { number } } = {}
		local loadedChunks: { [number]: boolean } = { [0] = true }
		local env = {
			setBlock = function(x, y, z, block)
				table.insert(set, { x, y, z, block })
			end,
			loaded = function(x)
				return loadedChunks[x // 16] == true
			end,
			load = function(x)
				loadedChunks[x // 16] = true
			end,
			extra = function() end,
		}
		local queue = Placement.newQueue()
		queue:add(plan)
		t.eq(queue:pending(), 4)
		-- Column by column: the dandelion, then the sunflower's lower half with its top.
		t.eq(queue:step(2, 0, env), 3, "the budget ran out on a lower half: its top came along")
		t.eq(set[2][4], B.Sunflower)
		t.eq(set[3][4], B.SunflowerTop)
		t.eq(queue:pending(), 1)
		t.eq(queue:step(10, 0, env), 1)
		t.eq(queue:pending(), 0)
		-- Chunks: a plan reaching an unloaded chunk generates at most `chunks` of them a step.
		local wide = build("test/wide", { 48, 1, 1 }, function()
			return STONE
		end)
		queue:add(
			Placement.loadPlan(wide, { x = 0, y = 0, z = 0, rotation = 0, mirror = "none", integrity = 1, seed = 1 })
		)
		table.clear(set)
		t.eq(queue:step(1000, 0, env), 16, "stops at the first unloaded chunk")
		t.eq(queue:step(1000, 1, env), 16, "one more chunk")
		t.eq(queue:step(1000, 5, env), 16, "the rest")
		t.eq(queue:pending(), 0)
		-- A time budget: the clock is looked at every 64 cells.
		local now = 0
		local timed = table.clone(env) :: any
		timed.clock = function()
			now += 1
			return now
		end
		local long = build("test/long", { 40, 1, 5 }, function()
			return STONE
		end)
		queue:add(
			Placement.loadPlan(long, { x = 0, y = 1, z = 0, rotation = 0, mirror = "none", integrity = 1, seed = 1 })
		)
		t.eq(queue:step(1000, 0, timed, 0.5), 64, "out of time after the first 64")
		t.eq(queue:step(1000, 0, timed, 100), 200 - 64, "the rest with time to spare")
	end)

	t.test("generate plans: streamed in batches; the later piece wins; solid bottom up, then late", function()
		local Jigsaw = require(shared.Structures.Jigsaw)
		local Hash = require(shared.Util.Hash)
		local Transform = require(shared.Structures.Transform)
		local rng = Hash.rng(2024)
		-- Templates mixing solid blocks, blocks set late (torches, water, tall plants), chests,
		-- jigsaws and keep.
		local templates: { [string]: any } = {}
		local names = {}
		for n = 1, 6 do
			local size = { rng:int(1, 7), rng:int(2, 6), rng:int(1, 7) }
			local tp = build(`mix/{n}`, size, function(x, y, z)
				local roll = rng:int(1, 12)
				if roll <= 2 then
					return nil
				elseif roll == 3 then
					return AIR
				elseif roll == 4 then
					return B.Torch
				elseif roll == 5 then
					return WATER
				elseif roll == 6 then
					return B.WallTorchNorth
				end
				return ({ STONE, DIRT, B.Cobblestone, B.Planks, B.Glass, B.OakLog })[roll - 6]
			end)
			-- A sunflower (both halves), a chest with an item and a jigsaw in each.
			Template.set(tp, 0, 0, 0, B.Sunflower)
			Template.set(tp, 0, 1, 0, B.SunflowerTop)
			local cx, cz = size[1] - 1, size[3] - 1
			Template.set(tp, cx, 0, cz, CHEST)
			table.insert(
				tp.containers,
				{ x = cx, y = 0, z = cz, items = { { slot = 2, item = "Stick", count = n, damage = 0 } } }
			)
			if size[1] >= 3 then
				Template.set(tp, 1, 1, cz, B.JigsawEastUp)
				table.insert(tp.jigsaws, {
					x = 1,
					y = 1,
					z = cz,
					front = "East",
					top = "Up",
					name = `j{n}`,
					target = "",
					pool = "empty",
					finalState = if n % 2 == 0 then "Glass" else "Air",
					joint = "aligned",
				})
			end
			templates[tp.name] = tp
			table.insert(names, tp.name)
		end
		local function lookup(name: string): any
			return templates[name]
		end
		local function firstFreeHeight(x: number, z: number): number
			return 6 + (x * 3 + z * 7) % 5
		end
		-- Pieces crowded together (so they overlap), some terrain matching, one partly below y 0.
		local pieces = {}
		for i = 1, 40 do
			local name = names[rng:int(1, #names)]
			local tp = templates[name]
			local rotation = rng:int(0, 3)
			local sx, sy, sz = Transform.size(tp.size[1], tp.size[2], tp.size[3], rotation)
			local x, y, z = rng:int(-12, 12), if i == 7 then -2 else rng:int(0, 8), rng:int(-12, 12)
			table.insert(pieces, {
				template = name,
				x = x,
				y = y,
				z = z,
				rotation = rotation,
				projection = if rng:chance(0.3) then Jigsaw.TERRAIN_MATCHING else Jigsaw.RIGID,
				depth = 0,
				box = { x, y, z, x + sx - 1, y + sy - 1, z + sz - 1 },
			})
		end
		local batch = Placement.BATCH
		for _, keep in { false, true } do
			-- (Small batches the second time: many batch ends, none between a plant's halves.)
			Placement.BATCH = if keep then 5 else batch
			-- What the world must end up with: every piece's cells in order, later ones winning.
			local expected: { [string]: number } = {}
			local expectedFrom: { [string]: any } = {}
			for _, piece in pieces do
				local tp = templates[piece.template]
				for lz = 0, tp.size[3] - 1 do
					for lx = 0, tp.size[1] - 1 do
						local tx, _, tz = Transform.position(lx, 0, lz, tp.size[1], tp.size[3], piece.rotation)
						local x, z = piece.x + tx, piece.z + tz
						local base = Jigsaw.baseY(piece, firstFreeHeight(x, z))
						for ly = 0, tp.size[2] - 1 do
							local block = Jigsaw.cellBlock(piece, tp, lx, ly, lz, keep)
							if block and base + ly >= 0 then
								local key = `{x},{base + ly},{z}`
								expected[key] = block
								expectedFrom[key] = { tp = tp, lx = lx, ly = ly, lz = lz }
							end
						end
					end
				end
			end

			local start = os.clock()
			local plan = Placement.piecesPlan(pieces, lookup, firstFreeHeight, keep)
			t.ok(os.clock() - start < 0.1, "making the plan builds no cells")
			t.eq(plan.count, 0, "nothing gathered up front")
			t.ok(plan.refill ~= nil and (plan.upcoming or 0) == Placement.volume(pieces, lookup), "a stream")
			local set: { { any } } = {}
			local at: { [string]: number } = {}
			local extras: { [string]: any } = {}
			local env = {
				setBlock = function(x, y, z, block)
					local key = `{x},{y},{z}`
					t.eq(at[key], nil, `{key} set once`)
					table.insert(set, { x, y, z, block })
					at[key] = block
				end,
				loaded = function()
					return true
				end,
				load = function() end,
				extra = function(x, y, z, _block, extra)
					extras[`{x},{y},{z}`] = extra
				end,
			}
			local queue = Placement.newQueue()
			queue:add(plan)
			local before = queue:pending()
			local steps = 0
			while queue:pending() > 0 and steps < 10000 do
				local placed = #set
				queue:step(37, 10, env)
				steps += 1
				t.ok(queue:pending() <= before, "pending only goes down")
				t.ok(queue:pending() + #set <= Placement.volume(pieces, lookup), "and stays an upper bound")
				before = queue:pending()
				-- (A step may stop past its budget only for a tall plant's top.)
				t.ok(#set - placed <= 38, "within the step's budget")
				local lastCell = set[#set]
				if lastCell and lastCell[4] == B.Sunflower then
					local above = `{lastCell[1]},{lastCell[2] + 1},{lastCell[3]}`
					t.ok(expected[above] ~= B.SunflowerTop, "a step never ends between a tall plant's halves")
				end
			end
			Placement.BATCH = batch
			t.eq(queue:pending(), 0, "all placed")
			-- The world: exactly what the pieces give, the later ones winning.
			local n = 0
			for key, block in expected do
				n += 1
				t.eq(at[key], block, `{key} (keep jigsaws {keep})`)
			end
			t.eq(#set, n, "nothing else, nothing twice")
			-- Kept jigsaws keep their settings, chests get the winning piece's items.
			for key, from in expectedFrom do
				local block = expected[key]
				if Blocks.isJigsaw(block) then
					t.ok(keep, "jigsaws stay only when kept")
					t.ok(extras[key] and extras[key].jigsaw and extras[key].jigsaw.name ~= "", `{key} jigsaw settings`)
				elseif block == CHEST then
					local items = extras[key] and extras[key].items
					t.ok(items and items[1].count == tonumber(string.match(from.tp.name, "%d+")), `{key} items`)
				end
			end
			-- Order: solid blocks bottom up, then the late ones; a tall plant's halves together.
			local function isLate(block: number): boolean
				local def = Blocks.get(block)
				return def.support ~= nil or def.plant ~= nil or def.fluid ~= nil
			end
			local seenLate, lastY = false, -1
			for i, cell in set do
				if isLate(cell[4]) then
					seenLate = true
				else
					t.ok(not seenLate, "every solid block before any late one")
					t.ok(cell[2] >= lastY, "solid blocks bottom up")
					lastY = cell[2]
				end
				if cell[4] == B.Sunflower and expected[`{cell[1]},{cell[2] + 1},{cell[3]}`] == B.SunflowerTop then
					local after = set[i + 1]
					t.ok(after and after[4] == B.SunflowerTop and after[2] == cell[2] + 1, "the top right after")
				end
			end
			t.ok(seenLate and n > 500, `a real mix ({n} cells)`)
		end
	end)

	--[[ The server core, end to end ]]

	local player = { name = "builder" }
	local far = { name = "far", far = true }

	-- Puts a structure block (in `mode`) at (x, y, z) with settings.
	local function structureBlock(fake: Fake, x: number, y: number, z: number, s: any)
		fake.world:setBlock(x, y, z, Blocks.structureBlock(s.mode) :: number)
		fake.store:setStructure(x, y, z, s)
	end

	local function request(
		fake: Fake,
		who: any,
		x: number,
		y: number,
		z: number,
		op: string,
		s: any?,
		transfer: number?
	)
		fake.server:structureBlock(who, { x = x, y = y, z = z, op = op, settings = s, transfer = transfer or 0 }, true)
	end

	-- A small build at x 1..3, y FLOOR..FLOOR + 2, z 1..3, saved by a block at (0, FLOOR, 0).
	local function buildHut(fake: Fake)
		local world = fake.world
		for x = 1, 3 do
			for z = 1, 3 do
				world:setBlock(x, FLOOR, z, B.Cobblestone)
			end
		end
		world:setBlock(1, FLOOR + 1, 1, B.Jigsaw)
		fake.store:setJigsaw(1, FLOOR + 1, 1, {
			name = "entrance",
			target = "street",
			pool = "town/streets",
			finalState = "Cobblestone",
			joint = "aligned",
		})
		world:setBlock(2, FLOOR + 1, 1, CHEST)
		local chest = fake.containers:get(2, FLOOR + 1, 1, CHEST)
		chest.slots[3] = Items.newStack(I.Stick, 7)
		chest.slots[5] = Items.newStack(I.IronPickaxe, 1, 9)
		structureBlock(fake, 3, FLOOR + 1, 1, settings("data", { metadata = "spawn_point" }))
		world:setBlock(1, FLOOR + 1, 3, VOID)
		world:setBlock(2, FLOOR + 2, 2, B.CaveGlowLichenUp)
		world:setBlock(3, FLOOR + 2, 3, Blocks.CAVE_AIR)
		world:setBlock(3, FLOOR + 1, 3, B.WallTorchNorth)
		structureBlock(
			fake,
			0,
			FLOOR,
			0,
			settings("save", { name = "town/hut", offset = { 1, 0, 1 }, size = { 3, 3, 3 } })
		)
	end

	t.test("structure server: SAVE captures the region and sends its text", function()
		local fake = newServer()
		buildHut(fake)
		local s = settings("save", { name = "town/hut", offset = { 1, 0, 1 }, size = { 3, 3, 3 } })
		request(fake, player, 0, FLOOR, 0, "save", s)
		local message = last(fake, player) or ""
		t.ok(string.find(message, "^Saved structure 'town/hut' %(%d+ blocks, %d+ characters%)$") ~= nil, message)
		local text = fake.data[player][1]
		t.ok(type(text) == "string" and string.sub(text, 1, 5) == "IVS1:", "the text went to the player")
		t.eq(fake.stored["town/hut"], text, "and to ServerStorage")
		t.eq(fake.server.saved["town/hut"].text, text, "and into the session")
		t.ok(string.find(message, ` {#text} characters)`, 1, true) ~= nil, "its length is told")

		local tp, err = Template.decode(text)
		t.ok(tp ~= nil, err)
		local saved = tp :: any
		t.eq(saved.name, "town/hut")
		t.eq(Template.get(saved, 0, 0, 0), B.Cobblestone)
		t.eq(Template.get(saved, 0, 1, 2), nil, "the structure void is keep")
		t.eq(Template.get(saved, 2, 1, 0), AIR, "the DATA block is air...")
		t.eq(#saved.markers, 1, "...and a data marker")
		t.eq(saved.markers[1].data, "spawn_point")
		t.eq(Template.get(saved, 1, 2, 1), B.GlowLichenUp, "a cave twin is saved as its twin")
		t.eq(Template.get(saved, 2, 2, 2), AIR, "cave air as air")
		t.eq(Template.get(saved, 2, 1, 2), B.WallTorchNorth)
		t.eq(#saved.jigsaws, 1)
		t.eq(saved.jigsaws[1].pool, "town/streets")
		t.eq(saved.jigsaws[1].finalState, "Cobblestone")
		t.eq(#saved.containers, 1)
		local items = saved.containers[1].items
		t.eq(#items, 2)
		t.eq(items[1].slot, 3)
		t.eq(items[1].item, "Stick")
		t.eq(items[2].damage, 9, "a tool's wear is kept")
		t.eq(Template.count(saved), 9 + 4)

		-- Refusals: wrong mode, no name, a zero size, a name with spaces.
		request(fake, player, 0, FLOOR, 0, "save", settings("save", { name = "" }))
		t.eq(last(fake, player), "Invalid structure name ''")
		request(fake, player, 0, FLOOR, 0, "save", settings("save", { name = "flat", size = { 4, 0, 4 } }))
		t.ok(string.find(last(fake, player) or "", "Unable to save structure 'flat'", 1, true) ~= nil)
		request(fake, player, 0, FLOOR, 0, "save", settings("save", { name = "bad name" }))
		t.ok(string.find(last(fake, player) or "", "Invalid structure name 'bad name'", 1, true) ~= nil)
		t.eq((fake.store:structure(0, FLOOR, 0) :: any).name, "flat", "a refused name changes nothing")

		-- The session keeps the newest saves; their pool follows.
		local cap = StructureServer.MAX_SAVED
		StructureServer.MAX_SAVED = 2
		for _, n in { "set/one", "set/two", "set/three" } do
			request(
				fake,
				player,
				0,
				FLOOR,
				0,
				"save",
				settings("save", { name = n, offset = { 1, 0, 1 }, size = { 2, 2, 2 } })
			)
		end
		StructureServer.MAX_SAVED = cap
		t.eq(fake.server.saved["town/hut"], nil, "the oldest went")
		t.eq(fake.server.saved["set/one"], nil)
		t.ok(fake.server.saved["set/three"] ~= nil)
		-- ServerStorage keeps only what the session keeps (else every SAVE under a new name
		-- would add up to 200,000 characters there for the server's lifetime).
		t.eq(fake.stored["town/hut"], nil, "its copy in ServerStorage went too")
		t.eq(fake.stored["set/one"], nil)
		t.eq(fake.stored["set/two"], fake.server.saved["set/two"].text)
		t.eq(fake.stored["set/three"], fake.server.saved["set/three"].text)
		local bytesCap = StructureServer.MAX_SAVED_BYTES
		StructureServer.MAX_SAVED_BYTES = 1
		request(
			fake,
			player,
			0,
			FLOOR,
			0,
			"save",
			settings("save", { name = "set/four", offset = { 1, 0, 1 }, size = { 2, 2, 2 } })
		)
		StructureServer.MAX_SAVED_BYTES = bytesCap
		local kept = 0
		for name, text in fake.stored do
			kept += 1
			t.eq(text, fake.server.saved[name].text, `{name} is kept by the session`)
		end
		t.eq(kept, 1, "over the byte cap only the newest stays, in both")
		t.ok(fake.stored["set/four"] ~= nil)
		request(
			fake,
			player,
			0,
			FLOOR,
			0,
			"save",
			settings("save", { name = "set/two", offset = { 1, 0, 1 }, size = { 2, 2, 2 } })
		)
		local pool = fake.server:lookups().pool("set")
		t.eq(pool and #pool.elements, 2, "the pool of the saves kept")
		t.ok(fake.server.savedBytes > 0)
	end)

	t.test("structure server: LOAD by name prepares the size, then places it turned", function()
		local fake = newServer()
		buildHut(fake)
		request(
			fake,
			player,
			0,
			FLOOR,
			0,
			"save",
			settings("save", { name = "town/hut", offset = { 1, 0, 1 }, size = { 3, 3, 3 } })
		)
		local world = fake.world
		-- A LOAD block at (20, FLOOR, 0): the template is 3 x 3 x 3, the block says 5 x 5 x 5.
		local bx, by, bz = 20, FLOOR, 0
		structureBlock(fake, bx, by, bz, settings("load", { name = "town/hut" }))
		local s = settings("load", { name = "town/hut", offset = { 0, 0, 2 }, rotation = 1 })
		request(fake, player, bx, by, bz, "load", s)
		t.eq(last(fake, player), "Structure 'town/hut' position prepared")
		t.eq((fake.store:structure(bx, by, bz) :: any).size[1], 3, "the size is the template's now")
		t.eq(fake.server.queue:pending(), 0, "nothing placed yet")
		-- What a keep cell will leave alone.
		local px, pz = mcTransform(0, 2, 1, "none")
		world:setBlock(bx + px, by + 1, bz + 2 + pz, B.Glass)
		s.size = { 3, 3, 3 }
		request(fake, player, bx, by, bz, "load", s)
		t.eq(last(fake, player), "Structure loaded from 'town/hut'")
		t.ok(fake.server.queue:pending() > 0)
		-- Spread over steps.
		local steps = 0
		while fake.server.queue:pending() > 0 do
			fake.server:place(5, 1)
			steps += 1
		end
		t.ok(steps >= 5, `placed over {steps} steps`)

		local function at(x: number, y: number, z: number): (number, number, number)
			local wx, wz = mcTransform(x, z, 1, "none")
			return bx + wx, by + y, bz + 2 + wz
		end
		local cx, cy, cz = at(0, 0, 0)
		t.eq(world:getBlock(cx, cy, cz), B.Cobblestone)
		t.eq(world:getBlock(at(0, 1, 2)), B.Glass, "the structure void left the world alone")
		t.eq(world:getBlock(at(1, 2, 1)), B.GlowLichenUp, "glow lichen (a ceiling stays a ceiling)")
		t.eq(world:getBlock(at(2, 1, 2)), B.WallTorchEast, "the torch turned with it")
		local jx, jy, jz = at(0, 1, 0)
		t.eq(world:getBlock(jx, jy, jz), B.JigsawEastUp, "the jigsaw turned with it")
		t.eq((fake.store:jigsaw(jx, jy, jz) :: any).pool, "town/streets", "and kept its settings")
		local dx, dy, dz = at(2, 1, 0)
		t.eq(world:getBlock(dx, dy, dz), DATA_BLOCK, "the data marker is a DATA structure block again")
		t.eq((fake.store:structure(dx, dy, dz) :: any).metadata, "spawn_point")
		local kx, ky, kz = at(1, 1, 0)
		local chest = fake.containers:peek(kx, ky, kz)
		t.ok(chest ~= nil and chest.slots[3].count == 7 and chest.slots[5].damage == 9, "the chest got its items")
		t.ok(fake.changed > 0, "its viewers were told")

		-- Unknown names, the wrong mode.
		request(fake, player, bx, by, bz, "load", settings("load", { name = "nowhere", size = { 3, 3, 3 } }))
		t.eq(last(fake, player), "Structure 'nowhere' is not available")
	end)

	t.test("structure server: LOAD from pasted data, uploaded in pieces", function()
		local fake = newServer()
		-- A noisy 30 x 30 x 30 template: more than one 16,000 character piece.
		local kinds = { STONE, DIRT, B.Cobblestone, B.Sand, B.Gravel, B.Glass, B.OakLog, GRASS }
		local seed = 7
		local tp = build("paste/noise", { 30, 30, 30 }, function()
			seed = (seed * 1103515245 + 12345) % 2147483648
			return kinds[seed // 65536 % #kinds + 1]
		end)
		local text = Template.encode(tp)
		local pieces = Protocol.splitStructureData(41, text)
		t.ok(#pieces >= 2, `{#pieces} pieces`)
		-- Not allowed: uploads are ignored.
		fake.server:data(player, pieces[1], false)
		t.eq(fake.server.uploads[player], nil)
		for i = #pieces, 1, -1 do
			fake.server:data(player, pieces[i], true)
		end
		local bx, by, bz = 60, FLOOR, 0
		structureBlock(fake, bx, by, bz, settings("load"))
		request(fake, player, bx, by, bz, "load", settings("load", { offset = { 1, 0, 0 } }), 41)
		t.eq(last(fake, player), "Structure 'paste/noise' position prepared", "the name comes from the data")
		request(fake, player, bx, by, bz, "load", settings("load", { offset = { 1, 0, 0 }, size = { 30, 30, 30 } }), 41)
		t.eq(last(fake, player), "Structure loaded from 'paste/noise'")
		while fake.server.queue:pending() > 0 do
			fake.server:place(100000, 10)
		end
		local same = true
		for _, cell in { { 0, 0, 0 }, { 29, 29, 29 }, { 3, 17, 25 }, { 12, 0, 8 } } do
			if
				fake.world:getBlock(bx + 1 + cell[1], by + cell[2], bz + cell[3])
				~= Template.get(tp, cell[1], cell[2], cell[3])
			then
				same = false
			end
		end
		t.ok(same, "placed as pasted")
		-- A transfer never uploaded, and junk.
		request(fake, player, bx, by, bz, "load", settings("load", { size = { 30, 30, 30 } }), 99)
		t.eq(last(fake, player), StructureServer.Messages.UPLOAD_MISSING)
		for _, piece in Protocol.splitStructureData(42, "IVS1:notreallydata") do
			fake.server:data(player, piece, true)
		end
		request(fake, player, bx, by, bz, "load", settings("load"), 42)
		t.ok(
			string.find(last(fake, player) or "", "Unable to load the pasted structure", 1, true) ~= nil,
			last(fake, player)
		)
	end)

	t.test("structure server: DETECT between corners, as Minecraft's detectSize", function()
		t.eq(StructureServer.detect(-1, 0, -1, { { 0, 0, 0 }, { 10, 5, 10 } }) ~= nil, true)
		local offset, size = StructureServer.detect(-1, 0, -1, { { 0, 0, 0 }, { 10, 5, 10 } })
		t.eq(table.concat(offset :: any, ","), "2,1,2")
		t.eq(table.concat(size :: any, ","), "9,4,9")
		offset, size = StructureServer.detect(0, 0, 0, { { 5, 5, 5 } })
		t.eq(table.concat(offset :: any, ","), "1,1,1", "one corner and the block")
		t.eq(table.concat(size :: any, ","), "4,4,4")
		t.eq(StructureServer.detect(0, 0, 0, { { 1, 5, 5 } }), nil, "a side of 0 inside")
		t.eq(StructureServer.detect(0, 0, 0, {}), nil, "no corners")
		local _, _, problem = StructureServer.detect(0, 0, 0, { { 2, 2, 2 }, { 70, 9, 9 } })
		t.ok(problem ~= nil and string.find(problem, "too far apart", 1, true) ~= nil, "beyond 48")

		local fake = newServer()
		structureBlock(fake, 40, FLOOR, 0, settings("corner", { name = "box" }))
		structureBlock(fake, 46, FLOOR + 4, 6, settings("corner", { name = "box" }))
		structureBlock(fake, 43, FLOOR + 9, 3, settings("corner", { name = "other" }))
		structureBlock(fake, 38, FLOOR, 0, settings("save", { name = "box" }))
		request(fake, player, 38, FLOOR, 0, "detect", settings("save", { name = "box" }))
		t.eq(last(fake, player), "Size successfully detected for 'box'")
		local s = fake.store:structure(38, FLOOR, 0) :: any
		t.eq(table.concat(s.offset, ","), "3,1,1")
		t.eq(table.concat(s.size, ","), "5,3,5")
		-- A corner broken is no corner: one corner and the block are too flat a box.
		fake.world:setBlock(46, FLOOR + 4, 6, AIR)
		request(fake, player, 38, FLOOR, 0, "detect", settings("save", { name = "box" }))
		t.eq(last(fake, player), StructureServer.Messages.SIZE_FAILURE)
		-- (As Minecraft, the screen's fields are stored before the action: the default size.)
		t.eq(table.concat((fake.store:structure(38, FLOOR, 0) :: any).size, ","), "5,5,5")
		-- Only in SAVE mode.
		request(fake, player, 38, FLOOR, 0, "detect", settings("load", { name = "box" }))
		t.eq(last(fake, player), StructureServer.Messages.SIZE_FAILURE)
		request(fake, player, 38, FLOOR, 0, "detect", settings("save", { name = "none" }))
		t.eq(last(fake, player), StructureServer.Messages.SIZE_FAILURE)
	end)

	t.test("structure server: open, mode changes, permission and range", function()
		local fake = newServer()
		structureBlock(fake, 0, FLOOR, 0, settings("save", { name = "keep" }))
		request(fake, player, 0, FLOOR, 0, "open")
		local answer = fake.opened[#fake.opened]
		t.eq(answer.open, true)
		t.eq(answer.kind, "structure")
		t.eq(answer.records[1].settings.name, "keep")
		-- A right click (Use) on it opens it too.
		fake.server:use(player, 0, FLOOR, 0, true)
		t.eq(fake.opened[#fake.opened].open, true)

		-- Not allowed: told on open, everything else ignored.
		local opened = #fake.opened
		fake.server:structureBlock(player, { x = 0, y = FLOOR, z = 0, op = "open", transfer = 0 }, false)
		t.eq(last(fake, player), Permission.DENIED)
		t.eq(#fake.opened, opened, "nothing opened")
		fake.server:structureBlock(
			player,
			{ x = 0, y = FLOOR, z = 0, op = "update", settings = settings("load"), transfer = 0 },
			false
		)
		t.eq(fake.world:getBlock(0, FLOOR, 0), SAVE_BLOCK, "no change")
		-- Out of range, or not a structure block there: ignored.
		request(fake, far, 0, FLOOR, 0, "update", settings("load"))
		t.eq(fake.world:getBlock(0, FLOOR, 0), SAVE_BLOCK)
		request(fake, player, 1, FLOOR, 0, "update", settings("load"))
		t.eq(fake.world:getBlock(1, FLOOR, 0), AIR)

		-- A new mode swaps the block and keeps the rest.
		request(
			fake,
			player,
			0,
			FLOOR,
			0,
			"update",
			settings("load", { name = "keep", rotation = 2, mirror = "frontBack" })
		)
		t.eq(fake.world:getBlock(0, FLOOR, 0), LOAD_BLOCK)
		local s = fake.store:structure(0, FLOOR, 0) :: any
		t.eq(s.mode, "load")
		t.eq(s.rotation, 2)
		t.eq(s.mirror, "frontBack")
		local records = fake.store:takeDirty()
		t.ok(#records >= 1 and records[#records].settings.mode == "load", "replicated")
		-- Bad names are refused, and the player's screen gets the stored settings back.
		request(fake, player, 0, FLOOR, 0, "update", settings("load", { name = "no spaces" }))
		t.eq((fake.store:structure(0, FLOOR, 0) :: any).name, "keep")
		t.eq(fake.opened[#fake.opened].records[1].settings.name, "keep")
		t.eq(fake.opened[#fake.opened].open, false)
		-- Breaking forgets it.
		fake.world:setBlock(0, FLOOR, 0, AIR)
		t.eq(fake.store:structure(0, FLOOR, 0), nil)
		-- One the store never saw (no edit came through it) gets the defaults when used.
		fake.world.onChanged = nil
		fake.world:setBlock(5, FLOOR, 5, CORNER_BLOCK)
		t.eq(fake.store:structure(5, FLOOR, 5), nil)
		request(fake, player, 5, FLOOR, 5, "open")
		t.eq(fake.opened[#fake.opened].records[1].settings.mode, "corner")
	end)

	t.test("structure server: a jigsaw's settings and Generate from this session's saves", function()
		local fake = newServer()
		local world = fake.world
		-- Two rooms in the implicit pool "test/rooms", each with an "entry" jigsaw facing west and
		-- a "door" jigsaw facing east to the next room.
		local function room(roomName: string, wall: number): any
			local tp = build(roomName, { 5, 3, 5 }, function(x, y, z)
				if y == 0 then
					return wall
				elseif (x == 0 or x == 4) and z == 2 and y == 1 then
					return if x == 0 then B.JigsawWestUp else B.JigsawEastUp
				elseif x == 0 or x == 4 or z == 0 or z == 4 then
					return wall
				end
				return AIR
			end)
			table.insert(tp.jigsaws, {
				x = 0,
				y = 1,
				z = 2,
				front = "West",
				top = "Up",
				name = "entry",
				target = "",
				pool = "empty",
				finalState = "Air",
				joint = "aligned",
			})
			table.insert(tp.jigsaws, {
				x = 4,
				y = 1,
				z = 2,
				front = "East",
				top = "Up",
				name = "door",
				target = "entry",
				pool = "test/rooms",
				finalState = "Air",
				joint = "aligned",
			})
			return tp
		end
		for i, tp in { room("test/rooms/a", B.Cobblestone), room("test/rooms/b", B.Planks) } do
			fake.server.saved[tp.name] = { template = tp, text = Template.encode(tp) }
			table.insert(fake.server.savedOrder, tp.name)
			t.ok(i >= 1)
		end
		fake.server.cachedLookups = nil
		local pool = fake.server:lookups().pool("test/rooms")
		t.ok(pool ~= nil and #pool.elements == 2, "saved pieces make the implicit pool")

		-- The jigsaw in the world, facing east.
		world:setBlock(0, FLOOR + 1, 0, B.JigsawEastUp)
		local function jigsawRequest(op: string, s: any, levels: number?, keep: boolean?)
			fake.server:jigsaw(player, {
				x = 0,
				y = FLOOR + 1,
				z = 0,
				op = op,
				settings = s,
				levels = levels or 0,
				keepJigsaws = keep == true,
			}, true)
		end
		jigsawRequest("open")
		t.eq(fake.opened[#fake.opened].kind, "jigsaw")
		t.eq(fake.opened[#fake.opened].open, true)
		-- A final state that is no block is refused.
		jigsawRequest(
			"update",
			{ name = "start", target = "entry", pool = "test/rooms", finalState = "NoSuchBlock", joint = "aligned" }
		)
		t.ok(string.find(last(fake, player) or "", "Unknown block 'NoSuchBlock'", 1, true) ~= nil)
		t.eq((fake.store:jigsaw(0, FLOOR + 1, 0) :: any).pool, "empty")
		-- Generate, 2 levels, jigsaws kept.
		local s = { name = "start", target = "entry", pool = "test/rooms", finalState = "Air", joint = "aligned" }
		jigsawRequest("generate", s, 2, true)
		local message = last(fake, player) or ""
		t.ok(string.find(message, "^Generated %d+ pieces from pool 'test/rooms'$") ~= nil, message)
		t.eq((fake.store:jigsaw(0, FLOOR + 1, 0) :: any).pool, "test/rooms", "the settings were stored first")
		while fake.server.queue:pending() > 0 do
			fake.server:place(1000, 10)
		end
		-- The first room's entry sits right in front of the jigsaw, kept with its settings.
		t.eq(world:getBlock(1, FLOOR + 1, 0), B.JigsawWestUp, "the first room's entry jigsaw")
		t.eq((fake.store:jigsaw(1, FLOOR + 1, 0) :: any).name, "entry")
		t.ok(world:getBlock(3, FLOOR + 1, 0) == AIR, "inside the room")
		local floor = world:getBlock(3, FLOOR, 0)
		t.ok(floor == B.Cobblestone or floor == B.Planks, "the room's floor")
		-- The next room follows its door.
		t.eq(world:getBlock(6, FLOOR + 1, 0), B.JigsawWestUp, "the second room's entry")
		t.eq(world:getBlock(0, FLOOR + 1, 0), B.JigsawEastUp, "the source jigsaw stays")

		-- Without keeping jigsaws they become their final state (air here).
		local other = newServer()
		for _, tp in { room("test/rooms/a", B.Cobblestone) } do
			other.server.saved[tp.name] = { template = tp, text = Template.encode(tp) }
		end
		other.world:setBlock(0, FLOOR + 1, 0, B.JigsawEastUp)
		other.server:jigsaw(
			player,
			{ x = 0, y = FLOOR + 1, z = 0, op = "generate", settings = s, levels = 1, keepJigsaws = false },
			true
		)
		while other.server.queue:pending() > 0 do
			other.server:place(1000, 10)
		end
		t.eq(other.world:getBlock(1, FLOOR + 1, 0), AIR, "the entry became air")
		t.eq(other.store:jigsaw(1, FLOOR + 1, 0), nil)
		-- An empty pool, or nothing that fits: told why.
		other.server:jigsaw(player, {
			x = 0,
			y = FLOOR + 1,
			z = 0,
			op = "generate",
			settings = { name = "a", target = "b", pool = "empty", finalState = "Air", joint = "aligned" },
			levels = 1,
			keepJigsaws = false,
		}, true)
		t.eq(last(other, player), StructureServer.Messages.emptyPool("empty"))
		other.server:jigsaw(player, {
			x = 0,
			y = FLOOR + 1,
			z = 0,
			op = "generate",
			settings = {
				name = "a",
				target = "nothing",
				pool = "test/rooms",
				finalState = "Air",
				joint = "aligned",
			},
			levels = 1,
			keepJigsaws = false,
		}, true)
		t.ok(string.find(last(other, player) or "", "Nothing in pool", 1, true) ~= nil, last(other, player))
	end)

	t.test("structure server: surface heights for Generate, items to and from slots", function()
		local fake = newServer()
		local world = fake.world
		t.eq(StructureServer.surfaceHeight(world, 5, 5), FLOOR, "loaded flat ground")
		world:setBlock(5, FLOOR + 3, 5, B.OakLeaves)
		world:setBlock(5, FLOOR, 5, B.ShortGrass)
		t.eq(StructureServer.surfaceHeight(world, 5, 5), FLOOR, "leaves and plants are no ground")
		world:setBlock(5, FLOOR + 6, 5, STONE)
		t.eq(StructureServer.surfaceHeight(world, 5, 5), FLOOR + 7)
		t.eq(
			StructureServer.surfaceHeight(world, 5000, 5000),
			math.max(FLOOR, Config.SeaLevel),
			"unloaded: the generator, sea level at least"
		)

		local slots = StructureServer.slotsFromItems({
			{ slot = 1, item = "Stick", count = 99, damage = 0 },
			{ slot = 1, item = "Coal", count = 1, damage = 0 },
			{ slot = 2, item = "NoSuchItem", count = 1, damage = 0 },
			{ slot = 30, item = "Coal", count = 1, damage = 0 },
			{ slot = 4, item = "IronPickaxe", count = 1, damage = 12 },
		}, 27)
		t.eq(slots[1].count, 64, "capped at a stack")
		t.eq(slots[2], nil)
		t.eq(slots[30], nil)
		t.eq(slots[4].damage, 12)
		local items = StructureServer.itemsFromSlots({ kind = "chest", block = CHEST, size = 27, slots = slots })
		t.eq(#items, 2)
		t.eq(items[2].item, "IronPickaxe")
	end)
end
