--[[
	Saves keep names, not ids (server Save/SaveCodec's palettes), so content can be added, removed,
	renamed or reordered between versions without breaking a world, a player or a character: the
	palette itself (numbered as first written, 0 none, names to today's ids, RENAMED followed,
	damage refused), regions (Save/RegionCodec version 3: edits, containers, pipes, tanks, items,
	mobs, the seasons' maps), players (Save/PlayerCodec version 6) and characters (Save/
	CharacterCodec version 5), machine data (Shared/Machines `types`, `idFields`: the Metal Miner's
	ore, whose state no longer packs its place in MinerRules.ORES, the Electric Furnace's item, a
	tank's fluid; Crafting/Smelting's cooking item), item data (Items/ItemData's id keys: a gun's
	rounds and parts, a Fluid Tank's fluid, a machine's tank) and effects, each read back through a
	palette whose names were changed (tests/lib/SaveNames: content another version had in another
	order, under an older name, or not at all; content added since is names the save never
	held); and older versions refused cleanly, never misread.
]]

local SaveNames = require("../lib/SaveNames")

return function(t, shared, require, server, _client)
	local Appearance = require(shared.Characters.Appearance)
	local Blocks = require(shared.Blocks)
	local Characters = require(shared.Characters)
	local Coords = require(shared.World.Coords)
	local Effects = require(shared.Effects)
	local Fluids = require(shared.Fluids)
	local ItemData = require(shared.Items.ItemData)
	local Items = require(shared.Items)
	local Machines = require(shared.Machines)
	local MinerRules = require(shared.Machines.MinerRules)
	local MobList = require(shared.Entities.MobList)
	local Smelting = require(shared.Crafting.Smelting)
	local CharacterCodec = require(server.Save.CharacterCodec)
	local PlayerCodec = require(server.Save.PlayerCodec)
	local RegionCodec = require(server.Save.RegionCodec)
	local SaveCodec = require(server.Save.SaveCodec)

	local B, I = Blocks.id, Items.id
	local AIR = Blocks.AIR
	local KEY = Coords.chunkKey(0, 0)
	local COW, PIG = MobList.find("Cow") :: number, MobList.find("Pig") :: number
	local WATER, LAVA = Fluids.find("Water") :: number, Fluids.find("Lava") :: number
	local OIL, FUEL = Fluids.find("Oil") :: number, Fluids.find("Fuel") :: number

	-- A rename that swaps names pairwise and maps the rest through `map` (kind -> name -> name).
	local function renames(map: { [string]: { [string]: string } }): (string, string) -> string
		return function(kind: string, name: string): string
			local of = map[kind]
			return if of and of[name] then of[name] else name
		end
	end

	-- `pairs` both ways: { a = b } swaps a and b.
	local function swaps(pairs: { [string]: string }): { [string]: string }
		local out: { [string]: string } = {}
		for a, b in pairs do
			out[a], out[b] = b, a
		end
		return out
	end

	-- A palette numbering every block, item, fluid and mob kind backwards from today's last id:
	-- a version whose content came in another order (and with all of today's: none added since).
	local function backwards(): SaveCodec.Palette
		local palette = SaveCodec.palette()
		for id = Blocks.count - 1, 1, -1 do
			SaveCodec.indexOf(palette, "block", id)
		end
		for i = #Items.list, 1, -1 do
			SaveCodec.indexOf(palette, "item", Items.list[i].id)
		end
		for id = Fluids.COUNT, 1, -1 do
			SaveCodec.indexOf(palette, "fluid", id)
		end
		for id = MobList.COUNT, 1, -1 do
			SaveCodec.indexOf(palette, "mob", id)
		end
		for id = Effects.COUNT, 1, -1 do
			SaveCodec.indexOf(palette, "effect", id)
		end
		return palette
	end

	local function sameStack(a: any, b: any): boolean
		if a == nil or b == nil then
			return a == b
		end
		return a.item == b.item
			and a.count == b.count
			and (a.damage or 0) == (b.damage or 0)
			and Items.sameData(a.data, b.data)
	end

	local function blockName(id: number?): string
		return if id == nil then "nil" else Blocks.get(id).name
	end

	--[[ The palette ]]

	t.test("save names: a palette numbers each name once as first written; 0 is none", function()
		local palette = SaveCodec.palette()
		t.eq(SaveCodec.indexOf(palette, "block", B.Stone), 1, "the first block written")
		t.eq(SaveCodec.indexOf(palette, "block", B.Glass), 2)
		t.eq(SaveCodec.indexOf(palette, "block", B.Stone), 1, "each once")
		t.eq(SaveCodec.indexOf(palette, "block", AIR), 0, "Air is 0 in every version")
		t.eq(SaveCodec.indexOf(palette, "item", 0), 0, "no item")
		t.eq(SaveCodec.indexOf(palette, "fluid", 0), 0, "no fluid")
		t.eq(SaveCodec.indexOf(palette, "item", I.Stick), 1, "each kind numbers its own")
		t.eq(SaveCodec.indexOf(palette, "block", Blocks.count + 7), 0, "no such block: nothing written")
		t.eq(SaveCodec.indexOf(palette, "effect", Effects.id.Speed), 1)
		t.eq(SaveCodec.indexOf(palette, "mob", COW), 1)
		t.eq(SaveCodec.indexOf(palette, "fluid", LAVA), 1)
		t.eq(table.concat(palette.names.block, ","), "Stone,Glass", "names, not ids")
		local w = SaveCodec.writer()
		SaveCodec.writePalette(w, palette)
		local back = SaveCodec.readPalette(SaveCodec.reader(SaveCodec.finish(w)))
		t.eq(SaveCodec.idOf(back, "block", 1), B.Stone)
		t.eq(SaveCodec.idOf(back, "block", 2), B.Glass)
		t.eq(SaveCodec.idOf(back, "block", 0), AIR)
		t.eq(SaveCodec.idOf(back, "item", 1), I.Stick)
		t.eq(SaveCodec.idOf(back, "effect", 1), Effects.id.Speed)
		t.eq(SaveCodec.idOf(back, "mob", 1), COW)
		t.eq(SaveCodec.idOf(back, "fluid", 1), LAVA)
		t.ok(not pcall(SaveCodec.idOf, back, "block", 3), "an index past the palette is damage")
		-- An empty palette is its writer's place version and five counts (a byte each, place
		-- versions below 128).
		local empty = SaveCodec.writer()
		SaveCodec.writePalette(empty, SaveCodec.palette(42))
		t.eq(empty.n, 1 + #SaveCodec.PALETTE_KINDS)
		t.eq(SaveCodec.readPalette(SaveCodec.reader(SaveCodec.finish(empty))).place, 42, "the writer's place version")
		t.eq(back.place, 0, "none given: 0, unknown")
	end)

	t.test("save names: names are today's ids, renamed ones followed, unknown ones none", function()
		local palette = SaveCodec.palette()
		-- An older version's names (Blocks.RENAMED, Items.RENAMED) and names this one never had.
		palette.names.block = { "Glowstone", "Stone", "SomeBlockOfAnotherVersion" }
		palette.names.item = { "GlowstoneDust", "SomeItemOfAnotherVersion" }
		palette.names.fluid = { "Lava", "SomeFluid" }
		palette.names.mob = { "Pig", "SomeMob" }
		palette.names.effect = { "Slowness", "SomeEffect" }
		local w = SaveCodec.writer()
		SaveCodec.writePalette(w, palette)
		local back = SaveCodec.readPalette(SaveCodec.reader(SaveCodec.finish(w)))
		t.eq(SaveCodec.idOf(back, "block", 1), B.GlowBlock, "Glowstone, renamed GlowBlock")
		t.eq(SaveCodec.idOf(back, "block", 2), B.Stone)
		t.eq(SaveCodec.idOf(back, "block", 3), nil, "a block this version doesn't know")
		t.eq(SaveCodec.idOf(back, "item", 1), I.GlowDust, "GlowstoneDust, renamed GlowDust")
		t.eq(SaveCodec.idOf(back, "item", 2), nil)
		t.eq(SaveCodec.idOf(back, "fluid", 1), LAVA)
		t.eq(SaveCodec.idOf(back, "fluid", 2), nil)
		t.eq(SaveCodec.idOf(back, "mob", 1), PIG)
		t.eq(SaveCodec.idOf(back, "mob", 2), nil)
		t.eq(SaveCodec.idOf(back, "effect", 1), Effects.id.Slowness)
		t.eq(SaveCodec.idOf(back, "effect", 2), nil)
	end)

	t.test("save names: the writer's place version tells content since removed from a newer one's", function()
		-- (Nothing left out: always written back.)
		t.eq(SaveCodec.newerNames(0, 9, 7), false)
		-- Left out by this place version, or an older one: content since removed (saved).
		t.eq(SaveCodec.newerNames(3, 7, 7), false, "this version's")
		t.eq(SaveCodec.newerNames(3, 6, 7), false, "an older version's")
		-- A newer one's (an old server during an update), or either unknown (0, nil: Studio):
		-- perhaps content this version lacks (never written back).
		t.eq(SaveCodec.newerNames(3, 8, 7), true, "a newer version's")
		t.eq(SaveCodec.newerNames(3, 0, 7), true, "written in Studio")
		t.eq(SaveCodec.newerNames(3, 7, 0), true, "read in Studio")
		t.eq(SaveCodec.newerNames(3, 7, nil), true, "read with no place version")
		t.eq(SaveCodec.newerNames(3, 0, 0), true, "Studio and Studio: still unknown")
		-- The server's notice: the most first, at most NOTICE_NAMES names.
		t.eq(
			SaveCodec.removedNotice(`world "Island"`, { OldItem = 3, OldBlock = 12 }),
			`[IceVoxel] removed content left out of world "Island": 12 OldBlock, 3 OldItem`
		)
		t.eq(SaveCodec.countList({ B = 2, A = 2, C = 5 }), "5 C, 2 A, 2 B", "ties by name")
		local many: { [string]: number } = {}
		for i = 1, SaveCodec.NOTICE_NAMES + 3 do
			many[`Gone{string.format("%02d", i)}`] = 1
		end
		t.eq(select(2, string.gsub(SaveCodec.countList(many), ",", ",")), SaveCodec.NOTICE_NAMES, "and 3 more")
		t.ok(string.find(SaveCodec.countList(many), "and 3 more$") ~= nil)
		-- Every record keeps its writer's place version and counts what it left out by name.
		local region = RegionCodec.new(0, 0)
		region.chunks[KEY] = { [0] = B.Stone, [1] = B.Glass, [2] = B.Glass, [3] = B.Glass }
		local gone = function(kind: string, name: string): string
			return if name == "Glass" then "OldGlass" elseif name == "Stick" then "OldStick" else name
		end
		local back = RegionCodec.decode(SaveNames.region(SaveCodec, RegionCodec.encode(region, 41), gone), 0, 0)
		t.eq(back.placeVersion, 41)
		t.eq(back.unknown.OldGlass, 3, "cell by cell")
		t.eq(back.dropped, 3)
		local player = PlayerCodec.new()
		player.slots[1] = Items.newStack(I.Stick, 4)
		player.slots[2] = Items.newStack(I.Stick, 1)
		local read = PlayerCodec.decode(SaveNames.record(SaveCodec, PlayerCodec.encode(player, 42), gone)) :: any
		t.eq(read.placeVersion, 42)
		t.eq(read.unknown.OldStick, 2, "a stack each")
		local character = CharacterCodec.new(1, "Ada", Characters.DEFAULT_DIFFICULTY, Appearance.default(), 0)
		character.slots[1] = Items.newStack(I.Stick, 4)
		local loaded =
			CharacterCodec.decode(SaveNames.record(SaveCodec, CharacterCodec.encode(character, 43), gone)) :: any
		t.eq(loaded.placeVersion, 43)
		t.eq(loaded.unknown.OldStick, 1)
		t.eq((CharacterCodec.decode(CharacterCodec.encode(character)) :: any).placeVersion, 0, "none given: unknown")
	end)

	--[[ Regions ]]

	-- A region holding a bit of everything that names content.
	local function sample(): any
		local region = RegionCodec.new(0, 0)
		local edits = {}
		for i = 0, 15 do
			edits[i] = B.Stone
		end
		edits[100] = B.Glass
		edits[101] = B.GlowBlock
		edits[102] = AIR
		region.chunks[KEY] = edits
		region.natural[KEY] = { [200] = B.Glass, [201] = AIR }
		region.thaw[KEY] = { [300] = B.Stone }
		table.insert(region.containers, {
			x = 1,
			y = 10,
			z = 1,
			container = {
				kind = "chest",
				block = B.Chest,
				size = 27,
				slots = {
					[1] = Items.newStack(B.Stone, 64),
					[2] = Items.newStack(I.GlowDust, 5),
					[3] = Items.newStack(I.IronIngot, 2),
				},
			},
		})
		table.insert(region.pipes, { x = 2, y = 10, z = 2, modes = 0, colour = 0, fluid = WATER, amount = 500 })
		table.insert(region.tanks, { x = 3, y = 10, z = 3, fluid = LAVA, amount = 9000 })
		table.insert(
			region.transport,
			{ x = 4, y = 10, z = 4, colour = 0, stack = Items.newStack(I.IronIngot, 1) :: any }
		)
		table.insert(region.items, {
			x = 5.5,
			y = 10,
			z = 5.5,
			stack = Items.newStack(I.Stick, 3) :: any,
			age = 10,
			pickupDelay = 0,
		})
		table.insert(region.mobs, { kind = COW, variant = 0, x = 6.5, y = 10, z = 6.5, yaw = 0, health = 10 })
		return region
	end

	t.test("save names: a region reads back by name, whatever order its version's content had", function()
		local region = sample()
		local plain = RegionCodec.encode(region)
		local names = SaveNames.regionNames(SaveCodec, plain)
		t.eq(table.concat(names.block, ","), "Stone,Glass,GlowBlock,Chest", "only what it holds, as first written")
		t.eq(table.concat(names.mob, ","), "Cow")
		-- (Content added since is names this save never held: nothing to read for it.)
		local seeded = RegionCodec.encode(region, nil, backwards())
		local seededNames = SaveNames.regionNames(SaveCodec, seeded)
		t.eq(seededNames.block[1], Blocks.get(Blocks.count - 1).name, "numbered in another order than today's ids")
		t.ok(seededNames.block[B.Stone] ~= "Stone" or B.Stone * 2 == Blocks.count, "Stone's index is not its id")
		for _, bytes in { plain, seeded } do
			local back = RegionCodec.decode(bytes, 0, 0)
			t.eq(back.dropped, 0)
			for index, block in region.chunks[KEY] do
				t.eq(blockName(back.chunks[KEY][index]), blockName(block), `edit {index}`)
			end
			t.eq(back.natural[KEY][200], B.Glass)
			t.eq(back.natural[KEY][201], AIR)
			t.eq(back.thaw[KEY][300], B.Stone)
			local chest = back.containers[1].container
			t.eq(chest.block, B.Chest)
			for slot = 1, 3 do
				t.ok(sameStack(chest.slots[slot], region.containers[1].container.slots[slot]), `chest slot {slot}`)
			end
			t.eq(back.pipes[1].fluid, WATER)
			t.eq(back.pipes[1].amount, 500)
			t.eq(back.tanks[1].fluid, LAVA)
			t.eq(back.transport[1].stack.item, I.IronIngot)
			t.eq(back.items[1].stack.item, I.Stick)
			t.eq(back.mobs[1].kind, COW)
		end
	end)

	t.test("save names: a region's content swapped, renamed or gone between versions", function()
		local bytes = RegionCodec.encode(sample())
		-- Reordered: what was saved as Stone is read as today's Glass and the other way round
		-- (each name's id is today's, wherever content put it); renamed: saved by a version that
		-- called GlowBlock Glowstone and GlowDust GlowstoneDust.
		local moved = RegionCodec.decode(
			SaveNames.region(
				SaveCodec,
				bytes,
				renames({
					block = { Stone = "Glass", Glass = "Stone", GlowBlock = "Glowstone" },
					-- (A block's item is in the item palette, by its own name.)
					item = { Stone = "Glass", GlowDust = "GlowstoneDust", IronIngot = "GoldIngot" },
					fluid = swaps({ Water = "Lava" }),
					mob = { Cow = "Pig" },
				})
			),
			0,
			0
		)
		t.eq(moved.dropped, 0, "nothing lost")
		t.eq(moved.chunks[KEY][0], B.Glass, "the run of Stone, read as Glass")
		t.eq(moved.chunks[KEY][15], B.Glass)
		t.eq(moved.chunks[KEY][100], B.Stone)
		t.eq(moved.chunks[KEY][101], B.GlowBlock, "an older name finds its block (RENAMED)")
		t.eq(moved.chunks[KEY][102], AIR)
		t.eq(moved.natural[KEY][200], B.Stone)
		local chest = moved.containers[1].container
		t.eq(chest.slots[1].item, B.Glass, "the stack of the block's item too")
		t.eq(chest.slots[2].item, I.GlowDust, "an older item name")
		t.eq(chest.slots[3].item, I.GoldIngot)
		t.eq(moved.pipes[1].fluid, LAVA)
		t.eq(moved.tanks[1].fluid, WATER)
		t.eq(moved.mobs[1].kind, PIG)
		-- Removed: names this version doesn't know, each left out and counted, never the region.
		local gone = RegionCodec.decode(
			SaveNames.region(
				SaveCodec,
				bytes,
				renames({
					block = { Glass = "GoneBlock" },
					item = { IronIngot = "GoneItem" },
					fluid = { Lava = "GoneFluid" },
					mob = { Cow = "GoneMob" },
				})
			),
			0,
			0
		)
		t.eq(gone.chunks[KEY][0], B.Stone, "the rest as it was")
		t.eq(gone.chunks[KEY][100], AIR, "an edit of a block it doesn't know is Air")
		t.eq(gone.natural[KEY][200], nil, "a natural entry is left out")
		t.eq(gone.natural[KEY][201], AIR)
		t.eq(gone.containers[1].container.slots[3], nil, "the stack is dropped")
		t.ok(sameStack(gone.containers[1].container.slots[1], Items.newStack(B.Stone, 64)))
		t.eq(#gone.transport, 0, "and the one in the transporter")
		t.eq(gone.tanks[1].fluid, 0, "the tank's fluid is gone")
		t.eq(gone.tanks[1].amount, 0, "with what it held")
		t.eq(gone.pipes[1].fluid, WATER)
		t.eq(#gone.mobs, 0)
		-- (1 edit, 1 natural entry, 2 stacks, 1 fluid, 1 mob.)
		t.eq(gone.dropped, 6, "each counted: such a world is played, not saved")
		-- A gone container block takes its container.
		local noChest =
			RegionCodec.decode(SaveNames.region(SaveCodec, bytes, renames({ block = { Chest = "GoneChest" } })), 0, 0)
		t.eq(#noChest.containers, 0)
		t.ok(noChest.dropped >= 1)
	end)

	--[[ Machine data ]]

	local MINER, SMELTER, HEATER = B.MetalMiner, B.ElectricFurnace, B.OilHeater

	t.test("save names: machine data keeps its ids by name (an ore, an item, a tank's fluid)", function()
		local miner = Machines.kind("miner") :: any
		t.eq(Machines.idFields(MINER)[miner.index.mining], "block", "the miner's ore")
		t.eq(Machines.idFields(SMELTER)[(Machines.kind("smelter") :: any).index.smelting], "item")
		local heater = Machines.kind("oilheater") :: any
		t.eq(Machines.idFields(HEATER)[heater.index.fuelFluid], "fluid", "a tank of two fluids")
		t.eq(next(Machines.idFields(B.Stone)), nil, "no machine")
		t.eq(Smelting.ID_FIELDS[5], "item", "a furnace's cooking item")
		t.ok(not pcall(Machines.define, "test_bad_type", { fields = { "x" }, types = { x = "colour" } }))
		t.ok(not pcall(Machines.define, "test_no_field", { fields = { "x" }, types = { y = "block" } }))

		local region = RegionCodec.new(0, 0)
		local function add(x: number, container: any)
			table.insert(region.containers, { x = x, y = 10, z = 0, container = container })
		end
		local mining = Machines.newContainer(MINER)
		Machines.set(mining, "mining", B.DiamondOre)
		Machines.set(mining, "progress", 40)
		add(0, mining)
		local smelting = Machines.newContainer(SMELTER)
		Machines.set(smelting, "smelting", I.IronIngot)
		add(1, smelting)
		local burning = Machines.newContainer(HEATER)
		Machines.set(burning, "fuel", 1200)
		Machines.set(burning, "fuelFluid", FUEL)
		add(2, burning)
		add(3, {
			kind = "furnace",
			block = B.Furnace,
			size = 3,
			slots = {},
			data = { 120, 1600, 33, 200, I.Stick },
		})
		local bytes = RegionCodec.encode(region, nil, backwards())
		local back = RegionCodec.decode(bytes, 0, 0)
		t.eq(back.dropped, 0)
		t.eq(Machines.get(back.containers[1].container, "mining"), B.DiamondOre, "today's id of its name")
		t.eq(Machines.get(back.containers[1].container, "progress"), 40, "the rest as numbers")
		t.eq(Machines.get(back.containers[2].container, "smelting"), I.IronIngot)
		t.eq(Machines.get(back.containers[3].container, "fuelFluid"), FUEL)
		t.eq(Machines.get(back.containers[3].container, "fuel"), 1200)
		t.eq((back.containers[4].container.data :: any)[5], I.Stick)
		t.eq((back.containers[4].container.data :: any)[3], 33, "its progress")
		-- Another version's names: the ore and the fuel read as today's of those names; an item
		-- this version doesn't know is nothing (what the furnace cooks starts over), counted.
		local moved = RegionCodec.decode(
			SaveNames.region(
				SaveCodec,
				bytes,
				renames({
					block = { DiamondOre = "GoldOre" },
					fluid = { Fuel = "Oil" },
					item = { Stick = "GoneItem" },
				})
			),
			0,
			0
		)
		t.eq(Machines.get(moved.containers[1].container, "mining"), B.GoldOre)
		t.eq(Machines.get(moved.containers[3].container, "fuelFluid"), OIL)
		t.eq((moved.containers[4].container.data :: any)[5], 0)
		t.eq(moved.dropped, 1)
	end)

	t.test("save names: the miner's state keeps its code alone; the ore comes from its `mining`", function()
		local STATE = MinerRules.STATE
		local container = Machines.newContainer(MINER)
		local index = (Machines.kind("miner") :: any).index
		container.data[Machines.ENERGY] = 100000
		Machines.tick(container, {
			block = MINER,
			x = 0,
			y = 64,
			z = 0,
			energy = assert(Machines.energyOf(MINER)),
			tick = 1,
			dayTime = 6000,
			getBlock = function(): number?
				return B.DiamondOre
			end,
		})
		local diamond = (MinerRules.ore(B.DiamondOre) :: MinerRules.Ore).index
		t.eq(container.data[index.state], STATE.MINING, "the field holds the code: no place in ORES is saved")
		t.eq(Machines.state(container), MinerRules.packState(STATE.MINING, diamond), "views and records add the ore")
		t.eq(Machines.status(MINER, Machines.view(container)), "Mining Diamond Ore")
		-- Saved and read by a version that names the ore it mines Gold Ore: it says so at once.
		local region = RegionCodec.new(0, 0)
		table.insert(region.containers, { x = 0, y = 10, z = 0, container = container })
		local back = RegionCodec.decode(
			SaveNames.region(SaveCodec, RegionCodec.encode(region), renames({ block = { DiamondOre = "GoldOre" } })),
			0,
			0
		)
		local loaded = back.containers[1].container
		local gold = (MinerRules.ore(B.GoldOre) :: MinerRules.Ore).index
		t.eq(Machines.state(loaded), MinerRules.packState(STATE.MINING, gold))
		t.eq(Machines.status(MINER, Machines.view(loaded)), "Mining Gold Ore")
		-- No ore, switched off, or a code that is none: no ore named.
		loaded.data[index.state] = STATE.NO_ORE
		t.eq(Machines.state(loaded), MinerRules.packState(STATE.NO_ORE, 0))
		loaded.data[index.state] = STATE.IDLE
		t.eq(Machines.status(MINER, Machines.view(loaded)), "Idle")
		loaded.data[index.state] = 99
		t.eq(Machines.state(loaded), 0)
	end)

	--[[ Item data ]]

	-- A pistol with all it holds, a Fluid Tank's item with lava, an Oil Heater's with fuel.
	local function heldStacks(): { any }
		local gun = Items.newStack(
			I.Pistol,
			1,
			12,
			Items.cleanData({
				ch = I.Rounds9mm,
				n = 7,
				ammo = I.Rounds9mm,
				mag = I.PistolMagazine,
				magD = 3,
				optic = I.RedDotSight,
				muzzle = I.Suppressor,
				light = I.WeaponFlashlight,
				lit = true,
			})
		)
		local tank = Items.newStack(B.BasicFluidTank, 1, nil, Items.cleanData({ fluid = LAVA, amount = 4000 }))
		local heater = Items.newStack(HEATER, 1, nil, Items.cleanData({ fuel = 500, fuelFluid = FUEL, setPoint = 3 }))
		return { gun, tank, heater }
	end

	t.test("save names: item data keeps its ids by name (a gun's rounds and parts, tanks' fluids)", function()
		for key, kind in { ch = "item", ammo = "item", mag = "item", optic = "item", muzzle = "item", light = "item" } do
			t.eq(ItemData.ID_KEYS[key], kind, `{key}: an item`)
		end
		t.eq(ItemData.idKind("fluid"), "fluid", "a Fluid Tank's")
		t.eq(ItemData.idKind("fuelFluid"), "fluid", "a machine's tank of two fluids (Shared/Machines adds it)")
		t.eq(ItemData.idKind("amount"), nil, "a plain number")
		t.eq(ItemData.idKind("n"), nil)
		t.ok(not pcall(ItemData.addIdKey, "ch", "fluid"), "a key holds one kind of id")
		local record = PlayerCodec.new()
		for i, stack in heldStacks() do
			record.slots[i] = stack
		end
		local bytes = PlayerCodec.encode(record, nil, backwards())
		local back = PlayerCodec.decode(bytes) :: PlayerCodec.Record
		t.eq(back.dropped, 0)
		for i, stack in heldStacks() do
			t.ok(sameStack(back.slots[i], stack), `stack {i} as it was`)
		end
		-- Another version's: its rounds are today's Rounds357 (renamed), its tanks' fluids swapped.
		local moved = PlayerCodec.decode(
			SaveNames.record(
				SaveCodec,
				bytes,
				renames({ item = { Rounds9mm = "Rounds357" }, fluid = swaps({ Lava = "Water", Fuel = "Oil" }) })
			)
		) :: PlayerCodec.Record
		local gun = (moved.slots[1] :: any).data
		t.eq(gun.ch, I.Rounds357)
		t.eq(gun.ammo, I.Rounds357)
		t.eq(gun.mag, I.PistolMagazine)
		t.eq(gun.n, 7, "plain numbers as they were")
		t.eq(gun.lit, true)
		t.eq((moved.slots[2] :: any).data.fluid, WATER)
		t.eq((moved.slots[2] :: any).data.amount, 4000)
		t.eq((moved.slots[3] :: any).data.fuelFluid, OIL)
		t.eq(moved.dropped, 0)
		-- Gone: the key is left out and the stack counts as lost (kept, but the record is not
		-- written back this session).
		local gone = PlayerCodec.decode(
			SaveNames.record(SaveCodec, bytes, renames({ item = { RedDotSight = "GoneSight" } }))
		) :: PlayerCodec.Record
		local kept = (gone.slots[1] :: any).data
		t.eq(kept.optic, nil, "the sight it doesn't know")
		t.eq(kept.muzzle, I.Suppressor, "the rest of the gun")
		t.eq(gone.slots[1].item, I.Pistol)
		t.eq(gone.dropped, 1)
		-- A key whose number is no id is written without it.
		record.slots = { Items.newStack(I.Pistol, 1, nil, Items.cleanData({ ch = 0.5, n = 1 })) }
		local junk = (PlayerCodec.decode(PlayerCodec.encode(record)) :: any).slots[1].data
		t.eq(junk.ch, nil)
		t.eq(junk.n, 1)
	end)

	--[[ Players and characters ]]

	t.test("save names: a player's and a character's items and effects by name; unknown effects skipped", function()
		local function fill(record: any)
			record.slots[1] = Items.newStack(B.Stone, 10)
			record.slots[2] = Items.newStack(I.IronIngot, 4)
			record.armor[1] = Items.newStack(I.IronHelmet, 1, 5)
			record.effects = {
				{ effect = Effects.id.Speed, amplifier = 1, ticks = 600, ambient = false },
				{ effect = Effects.id.Slowness, amplifier = 0, ticks = -1, ambient = true },
			}
		end
		local player = PlayerCodec.new()
		fill(player)
		local character = CharacterCodec.new(3, "Ada", Characters.DEFAULT_DIFFICULTY, Appearance.default(), 100)
		fill(character)
		for _, case in
			{
				{ "player", PlayerCodec.encode(player), PlayerCodec.decode },
				{ "character", CharacterCodec.encode(character), CharacterCodec.decode },
			}
		do
			local what, bytes, decode = case[1], case[2], case[3]
			local names = SaveNames.recordNames(SaveCodec, bytes)
			t.eq(table.concat(names.item, ","), "Stone,IronIngot,IronHelmet", `{what}: its items by name`)
			t.eq(table.concat(names.effect, ","), "Speed,Slowness", `{what}: its effects`)
			local back = decode(bytes) :: any
			t.eq(back.slots[2].item, I.IronIngot)
			t.eq(back.armor[1].damage, 5)
			t.eq(back.effects[1].effect, Effects.id.Speed)
			-- Swapped between versions; then gone (the effect skipped, never counted; the item
			-- counted).
			local moved = decode(
				SaveNames.record(
					SaveCodec,
					bytes,
					renames({ effect = swaps({ Speed = "Slowness" }), item = { IronIngot = "GoldIngot" } })
				)
			) :: any
			t.eq(moved.effects[1].effect, Effects.id.Slowness, `{what}: read as today's of its name`)
			t.eq(moved.effects[1].ticks, 600)
			t.eq(moved.effects[2].effect, Effects.id.Speed)
			t.eq(moved.slots[2].item, I.GoldIngot)
			local gone = decode(
				SaveNames.record(
					SaveCodec,
					bytes,
					renames({ effect = { Speed = "GoneEffect" }, item = { IronIngot = "GoneItem" } })
				)
			) :: any
			t.ok(gone ~= nil, `{what}: never refused for a name`)
			t.eq(#gone.effects, 1, `{what}: the effect it doesn't know skipped`)
			t.eq(gone.effects[1].effect, Effects.id.Slowness)
			t.eq(gone.slots[2], nil)
			t.eq(gone.slots[1].item, B.Stone)
			t.eq(gone.dropped, 1, `{what}: only the item counts`)
		end
	end)

	--[[ Older versions ]]

	t.test("save names: records of older versions are refused cleanly, never misread", function()
		-- A region: version 1 and 2 (before palettes) say so; a newer one too.
		local bytes = RegionCodec.encode(sample())
		t.eq(RegionCodec.VERSION, 3, "3 since palettes")
		for _, version in { 1, 2 } do
			local old = buffer.create(buffer.len(bytes))
			buffer.copy(old, 0, bytes)
			buffer.writeu8(old, 0, version)
			local region, why = RegionCodec.tryDecode(old, 0, 0)
			t.eq(region, nil, `a version {version} region is never read`)
			t.eq(why, SaveCodec.OLDER)
		end
		local newer = buffer.create(buffer.len(bytes))
		buffer.copy(newer, 0, bytes)
		buffer.writeu8(newer, 0, RegionCodec.VERSION + 1)
		t.eq(select(2, RegionCodec.tryDecode(newer, 0, 0)), SaveCodec.NEWER)
		-- Damage: a record before the palette, or two palettes.
		local r = SaveCodec.reader(bytes)
		SaveCodec.readU8(r)
		SaveCodec.readZigzag(r)
		SaveCodec.readZigzag(r)
		SaveCodec.readVarint(r)
		local headEnd = r.o
		SaveCodec.readU8(r)
		local paletteLength = SaveCodec.readVarint(r)
		local afterPalette = r.o + paletteLength
		local function spliced(...: { number }): buffer
			local w = SaveCodec.writer()
			for _, range in { ... } do
				local piece = buffer.create(range[2] - range[1])
				buffer.copy(piece, 0, bytes, range[1], range[2] - range[1])
				SaveCodec.bytes(w, piece)
			end
			return SaveCodec.finish(w)
		end
		local noPalette = spliced({ 0, headEnd }, { afterPalette, buffer.len(bytes) })
		t.ok(string.find(select(2, RegionCodec.tryDecode(noPalette, 0, 0)) or "", "before the palette", 1, true) ~= nil)
		local twice = spliced({ 0, afterPalette }, { headEnd, buffer.len(bytes) })
		t.eq(select(2, RegionCodec.tryDecode(twice, 0, 0)), "a second palette in save")

		-- A player record of versions 1 to 5.
		t.eq(PlayerCodec.VERSION, 6, "6 since palettes")
		local record = PlayerCodec.new()
		record.slots[1] = Items.newStack(B.Stone, 3)
		local playerBytes = PlayerCodec.encode(record)
		for version = 1, PlayerCodec.VERSION - 1 do
			local old = buffer.create(buffer.len(playerBytes))
			buffer.copy(old, 0, playerBytes)
			buffer.writeu8(old, 0, version)
			local none, why = PlayerCodec.decode(old)
			t.eq(none, nil, `a version {version} player record is never read`)
			t.eq(why, SaveCodec.OLDER)
		end
		buffer.writeu8(playerBytes, 0, PlayerCodec.VERSION + 1)
		t.eq(select(2, PlayerCodec.decode(playerBytes)), SaveCodec.NEWER)

		-- A character of versions 1 to 4: its head (who it is) as every version wrote it, then
		-- its things in that version's ids, never read.
		t.eq(CharacterCodec.VERSION, 5, "5 since palettes")
		local look = Appearance.default()
		look.colors[1] = 0x336699
		local lookText = buffer.tostring(Appearance.encode(look))
		for version = 1, CharacterCodec.VERSION - 1 do
			local w = SaveCodec.writer()
			SaveCodec.u8(w, version)
			SaveCodec.u8(w, 4 + 8 + 1) -- dead, legacy, and a thirst the rest would have held
			SaveCodec.u32(w, 7)
			SaveCodec.text(w, "Old Timer")
			SaveCodec.u8(w, Characters.Difficulty.Hardcore)
			SaveCodec.f64(w, 1000)
			SaveCodec.f64(w, 2000)
			SaveCodec.f64(w, 3600)
			SaveCodec.u32(w, 12)
			local lookBytes = Appearance.encode(look)
			SaveCodec.u16(w, buffer.len(lookBytes))
			SaveCodec.bytes(w, lookBytes)
			-- (What followed: health, mana, then stacks as u16 ids of that version.)
			for _ = 1, 40 do
				SaveCodec.u8(w, 0xAB)
			end
			local old = CharacterCodec.decode(SaveCodec.finish(w))
			t.ok(old ~= nil, `a version {version} character comes back as who it is`)
			if old then
				t.eq(old.outdated, true, "said to be from an older version")
				t.eq(old.id, 7)
				t.eq(old.name, "Old Timer")
				t.eq(old.difficulty, Characters.Difficulty.Hardcore)
				t.eq(old.dead, true)
				t.eq(old.legacy, true)
				t.eq(old.created, 1000)
				t.eq(old.lastPlayed, 2000)
				t.eq(old.played, 3600)
				t.eq(old.deaths, 12)
				t.eq(buffer.tostring(Appearance.encode(old.appearance)), lookText, "its look")
				t.eq(next(old.slots), nil, "its things start afresh")
				t.eq(old.thirst, nil, "nothing past the head is read")
				t.eq(#old.effects, 0)
				t.eq(old.dropped, 0, "so it is saved: whole, this version's")
				local again = CharacterCodec.decode(CharacterCodec.encode(old)) :: any
				t.eq(again.outdated, false)
				t.eq(again.name, "Old Timer")
			end
		end
		local fresh = CharacterCodec.new(1, "New", Characters.DEFAULT_DIFFICULTY, Appearance.default(), 0)
		t.eq(fresh.outdated, false)
		local newerCharacter = CharacterCodec.encode(fresh)
		buffer.writeu8(newerCharacter, 0, CharacterCodec.VERSION + 1)
		t.eq(select(2, CharacterCodec.decode(newerCharacter)), SaveCodec.NEWER)
		-- Through its DataStore value: the record, its progress beside it as it was (names).
		local value = { v = CharacterCodec.VALUE_VERSION, data = "", progress = { points = 5 } }
		local w = SaveCodec.writer()
		SaveCodec.u8(w, 4)
		SaveCodec.u8(w, 0)
		SaveCodec.u32(w, 2)
		SaveCodec.text(w, "Bea")
		SaveCodec.u8(w, Characters.DEFAULT_DIFFICULTY)
		for _ = 1, 3 do
			SaveCodec.f64(w, 0)
		end
		SaveCodec.u32(w, 0)
		local defaultLook = Appearance.encode(Appearance.default())
		SaveCodec.u16(w, buffer.len(defaultLook))
		SaveCodec.bytes(w, defaultLook)
		value.data = SaveCodec.toText(SaveCodec.finish(w))
		local read, progress, _, why = CharacterCodec.readValue(value)
		t.eq(why, nil, "an older character is no damage")
		t.eq((read :: any).outdated, true)
		t.eq((progress :: any).points, 5)
	end)
end
