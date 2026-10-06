--[[
	Lava, oil and fuel, the foundation: the fluid registry (Shared/Fluids) and its agreement with
	BlockList and ItemList, the fluid blocks and the cave twins of lava and oil (sources of their
	group in every way, cave air while caves are hidden: they cost the mesher nothing), obsidian,
	the buckets and the Lava Bucket as furnace fuel, the protocol's fluid ids and machines' tanks
	(WAILA reads them from the wire), and the server's Fluid behaviour: lava's, oil's and fuel's
	flow rules and lava meeting water (Minecraft 1.20.1's LiquidBlock.shouldSpreadLiquid and
	LavaFluid.spreadTo). Then dropped items floating in every fluid (Entities/ItemPhysics) and the
	burn and extinguish sounds (Players/Burning, Minecraft's numbers played once).
]]

local fs = require("@lune/fs")

return function(t, shared, require, server, client)
	local Blocks = require(shared.Blocks)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Fluids = require(shared.Fluids)
	local GameMode = require(shared.GameMode)
	local GreedyMesher = require(shared.Meshing.GreedyMesher)
	local ItemPhysics = require(shared.Entities.ItemPhysics)
	local Items = require(shared.Items)
	local Machines = require(shared.Machines)
	local Mining = require(shared.Mining)
	local Protocol = require(shared.Net.Protocol)
	local Smelting = require(shared.Crafting.Smelting)
	local Sounds = require(shared.Sounds)
	local Behaviours = require(server.Behaviours)
	local BlockTicker = require(server.World.BlockTicker)
	local Burning = require(server.Players.Burning)
	local Drops = require(server.Behaviours.Drops)
	local EditRules = require(server.Network.EditRules)
	local Fluid = require(server.Behaviours.Fluid)
	local WorldServer = require(server.World.WorldServer)
	local SoundRules = require(client.Audio.SoundRules)
	local WailaInfo = require(client.Ui.WailaInfo)

	local B, I = Blocks.id, Items.id
	local AIR, STONE = Blocks.AIR, B.Stone
	local WATER = Blocks.fluidId("Water", 0)
	local LAVA = Blocks.fluidId("Lava", 0)
	local OIL = Blocks.fluidId("Oil", 0)
	local FUEL = Blocks.fluidId("Fuel", 0)
	local GROUPS = { "Water", "Lava", "Oil", "Fuel" }

	--[[ The registry ]]

	t.test("fluids: ids 0 none, 1 water, 2 lava, 3 oil, 4 fuel, each a BlockList group", function()
		t.eq(Fluids.NONE, 0)
		t.eq(Fluids.WATER, 1)
		t.eq(Fluids.LAVA, 2)
		t.eq(Fluids.OIL, 3)
		t.eq(Fluids.FUEL, 4)
		t.eq(Fluids.COUNT, 4)
		t.eq(#Fluids.list, 4)
		t.eq(Fluids.BUCKET, 1000)
		for id, name in GROUPS do
			local fluid = Fluids.get(id)
			assert(fluid, name)
			t.eq(fluid.id, id)
			t.eq(fluid.name, name)
			t.eq(fluid.displayName, name)
			t.eq(Fluids.name(id), name)
			t.eq(Fluids.find(name), id)
			t.ok(Fluids.isValid(id))
			t.ok(Fluids.carriable(id), `{name}: pipes and tanks carry it`)
			t.eq(fluid.source, Blocks.fluidId(name, 0), `{name}'s source`)
			t.eq(Fluids.sourceOf(id), fluid.source)
			local block = Blocks.get(fluid.source)
			t.eq(block.color[1], fluid.color[1], `{name}: colour`)
			t.eq(block.color[2], fluid.color[2])
			t.eq(block.color[3], fluid.color[3])
			t.eq(block.light, fluid.light, `{name}: light`)
			t.eq(Fluids.bucketOf(id), I[`{name}Bucket`], `{name}'s bucket`)
			t.eq(Fluids.ofBucket(I[`{name}Bucket`]), id)
			t.ok(table.isfrozen(fluid), "records are read only")
		end
		for _, bad in { 0, 5, -1, 1.5, 0 / 0, math.huge } do
			t.ok(not Fluids.isValid(bad), `{bad} is no fluid`)
			t.eq(Fluids.get(bad), nil)
			t.eq(Fluids.name(bad), "Empty")
			t.eq(Fluids.bucketOf(bad), nil)
			t.eq(Fluids.sourceOf(bad), nil)
			t.ok(not Fluids.carriable(bad))
		end
		t.eq(Fluids.find("Milk"), nil)
		t.eq(Fluids.ofBucket(I.Bucket), 0, "the empty bucket holds nothing")
		t.eq(Fluids.ofBucket(I.Stone), 0)
		t.eq(Fluids.ofBucket(nil), 0)
	end)

	t.test("fluids: every block knows its fluid; sources and cave twins are what buckets take", function()
		t.eq(buffer.len(Fluids.blockLut), Blocks.count)
		local perFluid = {}
		for block = 0, Blocks.count - 1 do
			local def = Blocks.get(block)
			local id = Fluids.ofBlock(block)
			t.eq(buffer.readu8(Fluids.blockLut, block), id)
			if def.fluid then
				t.eq(Fluids.name(id), def.fluid.group, `{def.name}'s fluid`)
				t.eq(Fluids.isSource(block), def.fluid.level == 0, `{def.name}: a source?`)
				perFluid[id] = (perFluid[id] or 0) + 1
			else
				t.eq(id, 0, `{def.name} is no fluid`)
				t.ok(not Fluids.isSource(block))
			end
		end
		-- Nine levels each, and the cave twins of lava and oil.
		t.eq(perFluid[Fluids.WATER], 9)
		t.eq(perFluid[Fluids.LAVA], 10)
		t.eq(perFluid[Fluids.OIL], 10)
		t.eq(perFluid[Fluids.FUEL], 9)
		t.eq(Fluids.ofBlock(B.CaveLava), Fluids.LAVA)
		t.eq(Fluids.ofBlock(B.CaveOil), Fluids.OIL)
		t.ok(Fluids.isSource(B.CaveLava) and Fluids.isSource(B.CaveOil))
		t.eq(Fluids.caveSourceOf(Fluids.LAVA), B.CaveLava)
		t.eq(Fluids.caveSourceOf(Fluids.OIL), B.CaveOil)
		t.eq(Fluids.caveSourceOf(Fluids.WATER), nil, "water has no twin")
		t.eq(Fluids.caveSourceOf(Fluids.FUEL), nil)
		for _, bad in { -1, Blocks.count, 0.5, 0 / 0 } do
			t.eq(Fluids.ofBlock(bad), 0, `unknown block {bad}`)
			t.ok(not Fluids.isSource(bad))
		end
	end)

	t.test("fluids: Minecraft's lava, BuildCraft's oil and fuel", function()
		local water, lava, oil, fuel =
			Fluids.get(Fluids.WATER), Fluids.get(Fluids.LAVA), Fluids.get(Fluids.OIL), Fluids.get(Fluids.FUEL)
		assert(water and lava and oil and fuel)
		-- Lava: light 15, 4 every 10 ticks, burning 15 s, a 20 000 tick furnace fuel, LivingEntity's
		-- lava branch (drag 0.5) and Entity's overworld lava push; FogRenderer's fog.
		t.eq(lava.light, 15)
		t.eq(lava.damage, 4)
		t.eq(lava.damageInterval, 10)
		t.eq(lava.burnSeconds, 15)
		t.eq(lava.furnaceFuel, 20000)
		t.eq(lava.physics, "lava")
		t.eq(lava.drag, 0.5)
		t.near(lava.push, 0.0023333333333333335, 1e-12)
		t.ok(not lava.swim and not lava.extinguishes)
		t.eq(lava.fogStart, 0.25)
		t.eq(lava.fogEnd, 1)
		t.eq(lava.fillSound, "item.bucket.fill_lava")
		-- Water: Minecraft's water, which puts burning out.
		t.eq(water.physics, "water")
		t.eq(water.drag, 0.8)
		t.eq(water.push, 0.014)
		t.ok(water.swim and water.extinguishes)
		t.eq(water.damage, 0)
		t.eq(water.furnaceFuel, 0)
		-- Oil moves like lava but hurts nobody; fuel like water. Neither burns in a furnace.
		t.eq(oil.physics, "lava")
		t.eq(oil.drag, lava.drag)
		t.eq(oil.damage, 0)
		t.eq(oil.burnSeconds, 0)
		t.eq(oil.furnaceFuel, 0)
		t.eq(fuel.physics, "water")
		t.eq(fuel.drag, water.drag)
		t.ok(fuel.swim)
		t.eq(fuel.furnaceFuel, 0)
		t.eq(Fluids.BURN_DAMAGE, 1)
		t.eq(Fluids.BURN_INTERVAL, 20)
	end)

	--[[ Blocks ]]

	t.test("blocks: lava, oil and fuel levels, like water's", function()
		for group, delay in { Water = 5, Lava = 30, Oil = 20, Fuel = 5 } do
			local source = Blocks.fluidId(group, 0)
			for level = 0, 8 do
				local block = Blocks.fluidId(group, level)
				local def = Blocks.get(block)
				local fluid = def.fluid
				assert(fluid, def.name)
				t.eq(fluid.group, group)
				t.eq(fluid.level, level)
				t.eq(fluid.tickDelay, delay, `{def.name}'s tick delay`)
				t.eq(def.kind, Blocks.KIND_FLUID)
				t.eq(def.appearance, Blocks.get(source).appearance, "one look per fluid")
				t.ok(not def.solid and def.replaceable and def.drops == false)
				t.eq(def.placeable, level == 0, "only the source is an item")
				t.eq(def.behaviour, "Fluid")
				t.eq(Behaviours.byId[block], Fluid, `{def.name} runs the Fluid behaviour`)
				t.eq(Blocks.light(block), if group == "Lava" then 15 else 0, `{def.name}'s light`)
				t.eq(
					buffer.readu8(Blocks.fluidHeightLut, block),
					if level == 0 then 8 elseif level == 8 then 9 else 8 - level
				)
			end
			t.eq(Items.ofBlock(source), source, `the {group} item`)
		end
		t.eq(Blocks.get(LAVA).material, "Neon")
		t.eq(Blocks.get(LAVA).name, "Lava")
		t.eq(Blocks.get(OIL).material, "Glass")
		t.ok(Blocks.get(OIL).transparency < 0.2, "oil barely shows through")
		t.ok(Blocks.get(FUEL).transparency > 0.2, "fuel is translucent")
		t.eq(Blocks.get(Blocks.fluidId("Lava", 3)).name, "LavaFlow3")
		t.eq(Blocks.get(Blocks.fluidId("Oil", 8)).name, "OilFalling")
		-- Lava seas merge into big boxes: a lit fluid is never meshed one box per block.
		t.eq(buffer.readu8(Blocks.singleLut, Blocks.get(LAVA).appearance), 0, "lava merges")
		t.eq(buffer.readu8(Blocks.singleLut, Blocks.get(B.Torch).appearance), 1, "a torch does not")
		t.ok(not Blocks.isTargetable(LAVA) and not Blocks.isOpaque(LAVA))
	end)

	t.test("cave twins: CaveLava and CaveOil are their sources, cave air for hidden caves", function()
		for _, pair in { { B.CaveLava, LAVA, "Lava" }, { B.CaveOil, OIL, "Oil" } } do
			local twin, source, group = pair[1], pair[2], pair[3]
			local def, sourceDef = Blocks.get(twin), Blocks.get(source)
			local fluid = def.fluid
			assert(fluid, def.name)
			t.eq(Blocks.caveTwinOf(twin), source)
			t.eq(Blocks.caveTwinFor(source), twin)
			t.ok(Blocks.isCaveTwin(twin))
			t.eq(fluid.group, group, "a source of its group")
			t.eq(fluid.level, 0)
			t.eq(fluid.tickDelay, (sourceDef.fluid :: any).tickDelay)
			t.eq(Blocks.fluidId(group, 0), source, "fluidId never answers the twin")
			t.eq(def.appearance, sourceDef.appearance, "the same look")
			t.eq(def.light, sourceDef.light)
			t.eq(buffer.readu8(Blocks.fluidHeightLut, twin), 8)
			t.eq(def.behaviour, "Fluid")
			t.eq(Behaviours.byId[twin], Fluid)
			t.ok(not def.placeable, "no item of its own")
			t.eq(Items.ofBlock(twin), source, "its item is the source's")
			t.eq(Items.get(source).displayName, group)
			t.eq(def.displayName, group)
			t.eq(Blocks.surfaceForm(twin), source, "saved structures keep the source")
			t.eq(Blocks.rotate(twin, 1, "none"), twin)
			t.eq(buffer.readu8(Blocks.caveTwinLut, twin), 1)
			t.eq(buffer.readu8(Blocks.cullLutHiddenCaves, twin), 1, "rock while caves are hidden")
			t.eq(buffer.readu8(Blocks.cullLut, twin), 0)
			t.eq(buffer.readu8(GreedyMesher.caveCellLut, twin), 1, "a hidden cave cell")
			t.eq(buffer.readu8(GreedyMesher.caveCellLut, source), 0)
			t.ok(not EditRules.mayPlace(twin, AIR), "players never place one")
			t.ok(EditRules.mayPlace(source, AIR), "the source they may")
			t.ok(Blocks.isReplaceable(twin), "blocks may be placed into it")
		end
	end)

	t.test("cave twins: a hidden cave's lava sea costs the mesher nothing", function()
		-- A chunk column of stone with a cave from y 20 to 39, lava (or air) filling it to y 27, and
		-- the whole range meshed as one section.
		local SIZE, H = ChunkLayout.SIZE, 64
		local function column(sea: number): buffer
			local data = buffer.create(ChunkLayout.LAYER * H * 2)
			for y = 0, H - 1 do
				for pz = 0, ChunkLayout.PADDED - 1 do
					for px = 0, ChunkLayout.PADDED - 1 do
						local block = STONE
						local inside = px >= 3 and px <= SIZE - 2 and pz >= 3 and pz <= SIZE - 2
						if inside and y >= 20 and y < 40 then
							block = if y < 28 then sea else Blocks.CAVE_AIR
						end
						buffer.writeu16(data, ChunkLayout.index(px, y, pz) * 2, block)
					end
				end
			end
			return data
		end
		local function boxes(sea: number, hide: boolean): (number, string)
			local mesh, count = GreedyMesher.mesh(column(sea), H, 0, H, hide)
			return count, buffer.tostring(mesh)
		end
		local airCount, airMesh = boxes(Blocks.CAVE_AIR, true)
		local twinCount, twinMesh = boxes(B.CaveLava, true)
		local lavaCount = boxes(LAVA, true)
		t.eq(twinCount, airCount, "hidden: the twin's sea is cave air, as if it were not there")
		t.eq(twinMesh, airMesh)
		t.eq(boxes(B.CaveOil, true), airCount, "oil deposits too")
		t.ok(lavaCount > airCount, `ordinary lava is drawn anyway ({lavaCount} boxes, {airCount} without)`)
		-- Revealed, the twin's sea is drawn exactly as ordinary lava.
		local shownTwin, shownTwinMesh = boxes(B.CaveLava, false)
		local shownLava, shownLavaMesh = boxes(LAVA, false)
		t.eq(shownTwin, shownLava, "revealed: drawn like lava")
		t.eq(shownTwinMesh, shownLavaMesh)
		-- (Meshed without sparse lights, as far nodes are: a lit cell would split the sheet.)
		local lavaApp = Blocks.get(LAVA).appearance
		local mesh, meshCount = GreedyMesher.mesh(column(B.CaveLava), H, 0, H, false, nil, nil, true)
		local surfaces = 0
		for b = 0, meshCount - 1 do
			local app = GreedyMesher.decodeKey(buffer.readu16(mesh, b * GreedyMesher.BOX_BYTES + 12))
			if app == lavaApp then
				surfaces += 1
			end
		end
		t.eq(surfaces, 1, "one merged box for the lava sea's surface")
	end)

	t.test("obsidian: hardness 50, a diamond pickaxe or nothing, drops itself", function()
		local def = Blocks.get(B.Obsidian)
		t.eq(def.hardness, 50)
		t.eq(def.tool, "pickaxe")
		t.eq(def.toolLevel, 3)
		t.ok(def.solid and Blocks.isOpaque(B.Obsidian) and def.placeable)
		t.eq(Blocks.soundType(B.Obsidian), "stone")
		-- Minecraft: 9.4 s with a diamond pickaxe, 250 s by hand.
		t.eq(Mining.ticks(B.Obsidian, true, false, I.DiamondPickaxe), 188)
		t.eq(Mining.ticks(B.Obsidian, true, false, nil), 5000)
		local drop = Items.drops(B.Obsidian, I.DiamondPickaxe)
		t.eq(drop and drop.item, I.Obsidian)
		t.eq(Items.drops(B.Obsidian, I.IronPickaxe), nil, "iron is not enough")
		t.eq(Items.drops(B.Obsidian, nil), nil)
	end)

	--[[ Buckets and furnaces ]]

	t.test("buckets: lava, oil and fuel; each leaves the empty bucket", function()
		for _, name in { "WaterBucket", "LavaBucket", "OilBucket", "FuelBucket" } do
			local item = I[name]
			t.ok(item >= Items.ITEM_BASE, `{name} is an item`)
			t.eq(Items.maxStack(item), 1, "full buckets don't stack")
			t.eq(Items.craftingRemainder(item), I.Bucket, `{name} leaves a Bucket`)
			local def = Items.get(item)
			t.ok(def and def.model and #def.model > 7, `{name} has a model with the fluid in it`)
		end
		t.eq(Items.get(I.LavaBucket).displayName, "Lava Bucket")
		t.eq(Items.craftingRemainder(I.Bucket), nil)
		t.eq(Items.craftingRemainder(I.Coal), nil)
		t.eq(Items.craftingRemainder(nil), nil)
		t.eq(Items.FLUID_NAMES[Fluids.OIL], "Oil")
	end)

	t.test("smelting: a Lava Bucket burns 20 000 ticks and leaves its bucket in the fuel slot", function()
		t.eq(Smelting.fuel(I.LavaBucket), 20000)
		t.eq(Smelting.fuel(I.WaterBucket), 0)
		t.eq(Smelting.fuel(I.OilBucket), 0, "furnaces burn solid fuels only")
		t.eq(Smelting.fuel(I.FuelBucket), 0)
		t.eq(Smelting.fuel(I.Bucket), 0)
		local listed = false
		for _, fuel in Smelting.fuels() do
			if fuel.item == I.LavaBucket then
				listed = fuel.ticks == 20000
			end
		end
		t.ok(listed, "JEI lists it")
		local furnace = {
			slots = { [1] = { item = I.RawIron, count = 3 }, [2] = { item = I.LavaBucket, count = 1 } },
			data = Smelting.newData(),
		}
		t.ok(Smelting.active(furnace))
		Smelting.tick(furnace)
		local data = furnace.data :: { number }
		t.eq(data[2], 20000, "lit for 20 000 ticks")
		t.eq(data[1], 20000)
		local fuel = furnace.slots[2]
		t.eq(fuel and fuel.item, I.Bucket, "the empty bucket stays")
		t.eq(fuel and fuel.count, 1)
		for _ = 1, 600 do
			Smelting.tick(furnace)
		end
		local out = furnace.slots[3]
		t.eq(out and out.count, 3, "it cooked")
		t.eq(furnace.slots[1], nil)
		-- Coal leaves nothing; an empty bucket in the fuel slot burns nothing.
		local coal = {
			slots = { [1] = { item = I.RawIron, count = 1 }, [2] = { item = I.Coal, count = 1 } },
			data = Smelting.newData(),
		}
		Smelting.tick(coal)
		t.eq(coal.slots[2], nil)
		local idle = {
			slots = { [1] = { item = I.RawIron, count = 1 }, [2] = { item = I.Bucket, count = 1 } },
			data = Smelting.newData(),
		}
		t.ok(not Smelting.active(idle), "nothing to burn: not worth ticking")
		Smelting.tick(idle)
		t.eq((idle.data :: { number })[1], 0, "and nothing lights")
		t.eq(idle.slots[2] and idle.slots[2].item, I.Bucket)
	end)

	--[[ The protocol ]]

	t.test("protocol: Tanks and Transmitters carry fluid ids; unknown ones are malformed", function()
		local tanks = {}
		for id = 0, Fluids.COUNT do
			table.insert(tanks, { x = id, y = 5, z = -id, fluid = id, amount = 1000 * id })
		end
		local decoded = Protocol.decodeTanks(Protocol.encodeTanks(tanks))
		assert(decoded)
		for i, record in tanks do
			t.eq(decoded[i].fluid, record.fluid, `tank fluid {record.fluid}`)
			t.eq(decoded[i].amount, record.amount)
		end
		-- The encoder writes unknown fluids as none; a raw unknown id is malformed.
		local written = Protocol.decodeTanks(Protocol.encodeTanks({ { x = 0, y = 0, z = 0, fluid = 9, amount = 5 } }))
		t.eq(written and written[1].fluid, 0)
		local raw = Protocol.encodeTanks({ { x = 0, y = 0, z = 0, fluid = 1, amount = 5 } })
		buffer.writeu8(raw, 4 + 10, Fluids.COUNT + 1)
		t.eq(Protocol.decodeTanks(raw), nil, "fluid 5")

		t.eq(Protocol.TRANSMITTER_BYTES, 15)
		local records = {
			{ x = 1, y = 2, z = 3, modes = 0, colour = 0, fluid = 255, fluidId = Fluids.LAVA },
			{ x = -1, y = 2, z = 3, modes = 4095, colour = 16, fluid = 7, fluidId = Fluids.FUEL },
			{ x = 0, y = 0, z = 0, modes = 0, colour = 3, fluid = 0 },
		}
		local pipes = Protocol.decodeTransmitters(Protocol.encodeTransmitters(records))
		assert(pipes)
		t.eq(pipes[1].fluidId, Fluids.LAVA)
		t.eq(pipes[1].fluid, 255, "the fill is unchanged")
		t.eq(pipes[2].fluidId, Fluids.FUEL)
		t.eq(pipes[3].fluidId, 0, "no fluid id: none")
		t.eq(pipes[3].colour, 3)
		local unknown = Protocol.decodeTransmitters(
			Protocol.encodeTransmitters({ { x = 0, y = 0, z = 0, modes = 0, colour = 0, fluid = 1, fluidId = 77 } })
		)
		t.eq(unknown and unknown[1].fluidId, 0, "written as none")
		local bad = Protocol.encodeTransmitters({ records[1] })
		buffer.writeu8(bad, 4 + 14, Fluids.COUNT + 1)
		t.eq(Protocol.decodeTransmitters(bad), nil, "fluid id 5")
	end)

	t.test("protocol: Machines records carry their tanks, and WAILA shows them from the wire", function()
		local refinery = Machines.newContainer(B.OilRefinery)
		Machines.tankInsert(refinery, "oil", Fluids.OIL, 3000)
		Machines.tankInsert(refinery, "fuel", Fluids.FUEL, 250)
		local function record(x: number, tanks: { Protocol.MachineTank }?): Protocol.MachineRecord
			return {
				x = x,
				y = 64,
				z = -x,
				energy = 1500,
				capacity = 40000,
				input = 0,
				output = 0,
				rate = -200,
				active = true,
				state = 0,
				tanks = tanks,
			}
		end
		local records = {
			record(1, Machines.tankContents(refinery) :: any),
			record(2, nil),
			record(3, { { fluid = Fluids.LAVA, amount = 24000, capacity = 24000 } }),
		}
		local decoded = Protocol.decodeMachines(Protocol.encodeMachines(records))
		assert(decoded)
		t.eq(#decoded, 3)
		local oil = decoded[1].tanks
		assert(oil, "the refinery's tanks came across")
		t.eq(#oil, 2)
		t.eq(oil[1].fluid, Fluids.OIL)
		t.eq(oil[1].amount, 3000)
		t.eq(oil[1].capacity, 10000)
		t.eq(oil[2].fluid, Fluids.FUEL)
		t.eq(oil[2].amount, 250)
		t.eq(decoded[1].rate, -200, "the fixed part is as before")
		t.eq(decoded[1].x, 1)
		t.eq(decoded[2].tanks, nil, "a kind without tanks has none")
		t.eq(decoded[2].x, 2, "records after a tank list read right")
		local lava = decoded[3].tanks
		t.eq(lava and lava[1].fluid, Fluids.LAVA)
		t.eq(lava and lava[1].amount, 24000)
		t.eq(decoded[3].z, -3)
		-- An empty list sends none; unknown fluids go as empty.
		local empty = Protocol.decodeMachines(Protocol.encodeMachines({ record(0, {}) }))
		t.eq(empty and empty[1].tanks, nil)
		local unknown = Protocol.decodeMachines(
			Protocol.encodeMachines({ record(0, { { fluid = 77, amount = 5, capacity = 10 } }) })
		)
		t.eq(unknown and (unknown[1].tanks :: any)[1].fluid, 0, "written as none")
		-- Malformed: an unknown raw fluid id, a tank count beyond the bytes, bytes left over.
		local raw = Protocol.encodeMachines({ records[3] })
		local bad = buffer.fromstring(buffer.tostring(raw))
		buffer.writeu8(bad, 4 + Protocol.MACHINE_BYTES + 1, Fluids.COUNT + 1)
		t.eq(Protocol.decodeMachines(bad), nil, "fluid id 5")
		local short = buffer.fromstring(buffer.tostring(raw))
		buffer.writeu8(short, 4 + Protocol.MACHINE_BYTES, 2)
		t.eq(Protocol.decodeMachines(short), nil, "two tanks said, one sent")
		t.eq(Protocol.decodeMachines(buffer.fromstring(buffer.tostring(raw) .. "x")), nil, "a byte too many")
		local huge = buffer.create(4)
		buffer.writeu32(huge, 0, 4294967295)
		t.eq(Protocol.decodeMachines(huge), nil, "a count that can't fit")

		-- WAILA's lines from the decoded record: energy, status, then one per tank.
		local sent = decoded[1]
		local facts: WailaInfo.MachineFacts = {
			energy = sent.energy,
			capacity = sent.capacity,
			input = sent.input,
			output = sent.output,
			rate = sent.rate,
			active = sent.active,
			state = sent.state,
			tanks = sent.tanks :: any,
		}
		local texts = {}
		for _, line in WailaInfo.machineLines(B.OilRefinery, facts) do
			table.insert(texts, WailaInfo.text(line))
		end
		t.ok(table.find(texts, "Oil: 3,000 / 10,000 mB") ~= nil, `oil line in {table.concat(texts, " | ")}`)
		t.ok(table.find(texts, "Fuel: 250 / 10,000 mB") ~= nil, "fuel line")
	end)

	--[[ The server's Fluid behaviour ]]

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
		for cz = -1, 0 do
			for cx = -1, 0 do
				world:getChunk(cx, cz)
			end
		end
		local function step(n: number)
			for _ = 1, n do
				ticker:step()
			end
		end
		local function settle(): number
			for i = 1, 5000 do
				ticker:step()
				if ticker:pendingCount() == 0 then
					return i
				end
			end
			error("block updates never settled")
		end
		return world, step, settle
	end

	-- The fluid's levels on the floor around (0, FLOOR, 0), by distance: { [distance] = level }.
	local function spread(world: any, group: string): ({ [number]: { number } }, number)
		local levels: { [number]: { number } } = {}
		local count = 0
		for dz = -9, 9 do
			for dx = -9, 9 do
				local fluid = Blocks.get(world:getBlock(dx, FLOOR, dz)).fluid
				if fluid and fluid.group == group then
					count += 1
					local d = math.abs(dx) + math.abs(dz)
					levels[d] = levels[d] or {}
					table.insert(levels[d], fluid.level)
				end
			end
		end
		return levels, count
	end

	t.test("flow: lava flows 3 blocks (drop off 2), every 30 ticks, and makes no sources", function()
		local world, step, settle = newWorld()
		world:setBlock(0, FLOOR, 0, LAVA)
		step(29)
		t.eq(world:getBlock(1, FLOOR, 0), AIR, "nothing before its 30 ticks")
		step(1)
		t.eq(world:getBlock(1, FLOOR, 0), Blocks.fluidId("Lava", 2), "level 2 after 30 ticks")
		step(29)
		t.eq(world:getBlock(2, FLOOR, 0), AIR)
		step(1)
		t.eq(world:getBlock(2, FLOOR, 0), Blocks.fluidId("Lava", 4))
		settle()
		local levels, count = spread(world, "Lava")
		t.eq(count, 25, "a diamond of radius 3")
		for d, list in levels do
			for _, level in list do
				t.eq(level, 2 * d, `level at distance {d}`)
			end
		end
		-- Two sources with a gap make no third (canConvertToSource is false).
		world:setBlock(2, FLOOR, 0, LAVA)
		world:setBlock(0, FLOOR, 0, AIR)
		world:setBlock(0, FLOOR, 0, LAVA)
		settle()
		t.eq(world:getBlock(1, FLOOR, 0), Blocks.fluidId("Lava", 2), "the gap stays flowing")
		-- Taken away, its flow dries up.
		world:setBlock(0, FLOOR, 0, AIR)
		world:setBlock(2, FLOOR, 0, AIR)
		settle()
		local _, left = spread(world, "Lava")
		t.eq(left, 0, "all lava gone")
	end)

	t.test("flow: oil flows 7 slowly and looks only 2 blocks for a way down; fuel is thin", function()
		local world, step, settle = newWorld()
		world:setBlock(0, FLOOR, 0, OIL)
		step(19)
		t.eq(world:getBlock(1, FLOOR, 0), AIR, "oil waits 20 ticks")
		step(1)
		t.eq(world:getBlock(1, FLOOR, 0), Blocks.fluidId("Oil", 1))
		settle()
		local _, count = spread(world, "Oil")
		t.eq(count, 113, "a diamond of radius 7, like water")
		-- A hole 3 blocks beyond the neighbour: water (slope 4) heads only for it, oil (slope 2)
		-- doesn't see it and spreads every way.
		for _, case in { { WATER, "Water", false }, { OIL, "Oil", true } } do
			local w, _, done = newWorld()
			w:setBlock(4, FLOOR - 1, 0, AIR)
			w:setBlock(4, FLOOR - 2, 0, STONE)
			w:setBlock(0, FLOOR, 0, case[1])
			step(0)
			done()
			local back = Blocks.get(w:getBlock(-1, FLOOR, 0)).fluid
			t.eq(back ~= nil, case[3], `{case[2]} spreads away from the hole`)
		end
		-- Fuel: water's pace and reach, but two sources make no third.
		local f, fstep, fsettle = newWorld()
		f:setBlock(0, FLOOR, 0, FUEL)
		fstep(5)
		t.eq(f:getBlock(1, FLOOR, 0), Blocks.fluidId("Fuel", 1), "fuel every 5 ticks")
		f:setBlock(2, FLOOR, 0, FUEL)
		fsettle()
		t.eq(f:getBlock(1, FLOOR, 0), Blocks.fluidId("Fuel", 1), "no infinite fuel")
		local _, fuelCount = spread(f, "Fuel")
		t.ok(fuelCount > 100, "fuel spreads 7")
	end)

	t.test("flow: different fluids never flow into each other", function()
		local world, _, settle = newWorld()
		world:setBlock(-2, FLOOR, 0, OIL)
		world:setBlock(2, FLOOR, 0, FUEL)
		settle()
		t.eq(world:getBlock(-2, FLOOR, 0), OIL)
		t.eq(world:getBlock(2, FLOOR, 0), FUEL)
		for dz = -9, 9 do
			for dx = -9, 9 do
				local block = world:getBlock(dx, FLOOR, dz)
				t.ok(block == AIR or Blocks.get(block).fluid ~= nil, "nothing but fluid made")
			end
		end
	end)

	t.test("cave twins flow as their group and make ordinary fluid", function()
		local world, step, settle = newWorld()
		world:setBlock(0, FLOOR, 0, B.CaveLava)
		step(30)
		t.eq(world:getBlock(1, FLOOR, 0), Blocks.fluidId("Lava", 2), "ordinary flowing lava")
		settle()
		t.eq(world:getBlock(0, FLOOR, 0), B.CaveLava, "the twin stays")
		local _, count = spread(world, "Lava")
		t.eq(count, 25, "flows like lava")
		local oil, ostep, osettle = newWorld()
		oil:setBlock(0, FLOOR, 0, B.CaveOil)
		ostep(20)
		t.eq(oil:getBlock(0, FLOOR, 1), Blocks.fluidId("Oil", 1))
		osettle()
		local _, oilCount = spread(oil, "Oil")
		t.eq(oilCount, 113)
		-- A flowing cell beside a twin counts it as a source.
		t.eq(oil:getBlock(1, FLOOR, 0), Blocks.fluidId("Oil", 1))
	end)

	t.test("lava and water: obsidian, cobblestone and stone, as Minecraft's", function()
		-- Water beside a source: obsidian on the next tick.
		local world, step = newWorld()
		world:setBlock(0, FLOOR, 0, LAVA)
		world:setBlock(1, FLOOR, 0, WATER)
		step(1)
		t.eq(world:getBlock(0, FLOOR, 0), B.Obsidian, "a source beside water")
		-- Water above a source: obsidian.
		world, step = newWorld()
		world:setBlock(0, FLOOR, 0, LAVA)
		world:setBlock(0, FLOOR + 1, 0, WATER)
		step(1)
		t.eq(world:getBlock(0, FLOOR, 0), B.Obsidian, "a source under water")
		-- Flowing and falling lava beside water: cobblestone.
		for _, level in { 2, 4, 6, 8 } do
			world, step = newWorld()
			world:setBlock(0, FLOOR, 0, Blocks.fluidId("Lava", level))
			world:setBlock(0, FLOOR, 1, Blocks.fluidId("Water", 3))
			step(1)
			t.eq(world:getBlock(0, FLOOR, 0), B.Cobblestone, `lava level {level} beside water`)
		end
		-- A cave twin hardens like its source.
		world, step = newWorld()
		world:setBlock(0, FLOOR, 0, B.CaveLava)
		world:setBlock(-1, FLOOR, 0, WATER)
		step(1)
		t.eq(world:getBlock(0, FLOOR, 0), B.Obsidian, "CaveLava")
		-- Water below doesn't harden lava: the lava pours into it on its tick, making stone.
		world, step = newWorld()
		world:setBlock(0, FLOOR - 1, 0, WATER)
		world:setBlock(0, FLOOR, 0, LAVA)
		step(29)
		t.eq(world:getBlock(0, FLOOR - 1, 0), WATER, "not yet")
		t.eq(world:getBlock(0, FLOOR, 0), LAVA, "lava over water stays lava")
		step(1)
		t.eq(world:getBlock(0, FLOOR - 1, 0), STONE, "lava flowing down into water makes stone")
		t.eq(world:getBlock(0, FLOOR, 0), LAVA)
		-- Lava pouring off a ledge onto flowing water: stone where it lands. (A pit two wide, a water
		-- source in one half flowing into the other; lava 2 blocks above that half falls at 30
		-- ticks and lands at 60.)
		world, step = newWorld()
		world:setBlock(0, FLOOR - 1, 0, AIR)
		world:setBlock(1, FLOOR - 1, 0, AIR)
		world:setBlock(1, FLOOR - 1, 0, WATER)
		world:setBlock(0, FLOOR + 1, 0, LAVA)
		step(59)
		t.eq(world:getBlock(0, FLOOR - 1, 0), Blocks.fluidId("Water", 1), "flowing water")
		t.eq(world:getBlock(0, FLOOR, 0), Blocks.fluidId("Lava", 8), "lava falling onto it")
		step(1)
		t.eq(world:getBlock(0, FLOOR - 1, 0), STONE, "falling lava on flowing water")
		-- Oil and fuel leave water alone.
		world, step = newWorld()
		world:setBlock(0, FLOOR, 0, OIL)
		world:setBlock(1, FLOOR, 0, WATER)
		world:setBlock(5, FLOOR - 1, 5, WATER)
		world:setBlock(5, FLOOR, 5, FUEL)
		step(40)
		t.eq(world:getBlock(0, FLOOR, 0), OIL)
		t.eq(world:getBlock(5, FLOOR - 1, 5), WATER)
		t.eq(world:getBlock(5, FLOOR, 5), FUEL)
	end)

	t.test("lava and water: water reaching lava's flow makes cobblestone; the source stays", function()
		-- A 1-wide trench from x 0 to 5: lava flows from x 0 to x 3, then water poured at x 5 flows
		-- to x 4, beside the lava's tip, which hardens into cobblestone. The sources stay.
		local function trench()
			local world, step, settle = newWorld()
			for x = -1, 6 do
				world:setBlock(x, FLOOR, -1, STONE)
				world:setBlock(x, FLOOR, 1, STONE)
			end
			world:setBlock(-1, FLOOR, 0, STONE)
			world:setBlock(6, FLOOR, 0, STONE)
			return world, step, settle
		end
		local world, step, settle = trench()
		world:setBlock(0, FLOOR, 0, LAVA)
		settle()
		t.eq(world:getBlock(3, FLOOR, 0), Blocks.fluidId("Lava", 6), "lava's tip")
		t.eq(world:getBlock(4, FLOOR, 0), AIR)
		world:setBlock(5, FLOOR, 0, WATER)
		step(5)
		t.eq(world:getBlock(4, FLOOR, 0), Blocks.fluidId("Water", 1), "water flows beside it")
		step(1)
		t.eq(world:getBlock(3, FLOOR, 0), B.Cobblestone, "the next tick: cobblestone")
		settle()
		t.eq(world:getBlock(0, FLOOR, 0), LAVA, "the lava source stays")
		t.eq(world:getBlock(1, FLOOR, 0), Blocks.fluidId("Lava", 2))
		t.eq(world:getBlock(2, FLOOR, 0), Blocks.fluidId("Lava", 4))
		t.eq(world:getBlock(3, FLOOR, 0), B.Cobblestone)
		t.eq(world:getBlock(5, FLOOR, 0), WATER, "the water source stays")
		-- Water poured at x 2, into the lava's flow: the flow on both sides hardens at once, so the
		-- water never reaches the source.
		world, step, settle = trench()
		world:setBlock(0, FLOOR, 0, LAVA)
		settle()
		world:setBlock(2, FLOOR, 0, WATER)
		settle()
		t.eq(world:getBlock(2, FLOOR, 0), WATER)
		t.eq(world:getBlock(1, FLOOR, 0), B.Cobblestone, "flowing lava beside the water source")
		t.eq(world:getBlock(3, FLOOR, 0), B.Cobblestone, "on both sides")
		t.eq(world:getBlock(0, FLOOR, 0), LAVA, "the source, shut in by cobblestone, stays")
	end)

	t.test("lava burns what it washes away; water drops it", function()
		local dropped = {}
		Drops.set(function(_x, _y, _z, stack)
			table.insert(dropped, stack.item)
		end)
		local world, _, settle = newWorld()
		world:setBlock(1, FLOOR, 0, B.Torch)
		world:setBlock(0, FLOOR, 0, LAVA)
		settle()
		t.eq(world:getBlock(1, FLOOR, 0), Blocks.fluidId("Lava", 2), "the torch is gone")
		t.eq(#dropped, 0, "burnt: no drop")
		world, _, settle = newWorld()
		world:setBlock(1, FLOOR, 0, B.Torch)
		world:setBlock(0, FLOOR, 0, OIL)
		settle()
		t.eq(dropped[1], I.Torch, "oil washes it away like water")
		Drops.set(nil)
	end)

	--[[ Dropped items in every fluid ]]

	-- A pool of `block` 3 deep (y 10..12) over stone, everywhere: still, so no current.
	local function pool(block: number): (x: number, y: number, z: number) -> number?
		return function(_x: number, y: number, _z: number): number?
			if y < 10 then
				return STONE
			end
			return if y < 13 then block else AIR
		end
	end

	t.test("items: float in water, fuel, oil and lava, cave twins too (Minecraft's float)", function()
		for _, name in { "Water", "Fuel", "Oil", "Lava", "CaveOil", "CaveLava" } do
			local block = Blocks.find(name) :: number
			local body = ItemPhysics.new(0.5, 12.5, 0.5)
			for _ = 1, 200 do
				ItemPhysics.tick(body, 1, pool(block))
			end
			t.ok(body.y > 12.5 and body.y < 13, `{name}: bobbing at the surface (y {body.y})`)
		end
		-- Dropped deep, an item rises.
		local deep = ItemPhysics.new(0.5, 10, 0.5)
		for _ = 1, 400 do
			ItemPhysics.tick(deep, 1, pool(OIL))
		end
		t.ok(deep.y > 12.5, `it rises through oil (y {deep.y})`)
	end)

	t.test("items: lava and oil hold them back (x 0.95), water and fuel less (x 0.99)", function()
		local function slowed(block: number): number
			local body = ItemPhysics.new(0.5, 10.2, 0.5, 0.1, 0, 0)
			ItemPhysics.tick(body, 1, pool(block))
			-- (Then the air drag, 0.98, as every moving item.)
			return body.vx / 0.1 / 0.98
		end
		t.near(slowed(WATER), 0.99, 1e-6, "water: setUnderwaterMovement")
		t.near(slowed(FUEL), 0.99, 1e-6, "fuel: like water (Forge's FluidType.setItemMovement)")
		t.near(slowed(OIL), 0.95, 1e-6, "oil: like lava")
		t.near(slowed(LAVA), 0.95, 1e-6, "lava: setUnderLavaMovement")
		t.near(slowed(Blocks.find("CaveOil") :: number), 0.95, 1e-6, "a cave twin as its source")
	end)

	t.test("items: currents of every fluid carry them, fuel's as water's, oil's slower", function()
		-- A channel 1 wide (z 0) of `name` flowing towards +x (level 1 at x 0 .. 7 at x 6).
		local function channel(name: string): (x: number, y: number, z: number) -> number?
			return function(x: number, y: number, z: number): number?
				if y < 10 or z ~= 0 then
					return STONE
				end
				if y == 10 and x >= 0 and x <= 6 then
					return Blocks.fluidId(name, x + 1)
				end
				return AIR
			end
		end
		local function carried(name: string, ticks: number): ItemPhysics.Body
			local body = ItemPhysics.new(2.5, 10, 0.5)
			body.onGround = true
			for i = 1, ticks do
				ItemPhysics.tick(body, i, channel(name))
			end
			return body
		end
		local water, fuel, oil = carried("Water", 1), carried("Fuel", 1), carried("Oil", 1)
		t.ok(water.vx > 0.01, `water pushes (vx {water.vx})`)
		t.near(fuel.vx, water.vx, 1e-12, "fuel pushes as water does (0.014)")
		-- (A still item gets at least 0.0045: Entity.updateFluidHeightAndDoFluidPushing.)
		t.ok(oil.vx > 0.004 and oil.vx < fuel.vx, `oil pushes less (vx {oil.vx})`)
		t.ok(carried("Oil", 20).x > 3, "an oil stream carries items along")
		t.near(carried("Lava", 1).vx, oil.vx, 1e-12, "lava as oil")
	end)

	--[[ Burning sounds ]]

	t.test("burning: each lava hurt that lands on a player sizzles (Entity.lavaHurt)", function()
		local LAVA_MASK = bit32.lshift(1, Fluids.LAVA)
		local state = Burning.newPlayer()
		local sizzles = {}
		for tick = 1, 21 do
			local _, _, hurt = Burning.tickPlayer(state, GameMode.SURVIVAL, LAVA_MASK)
			if hurt then
				table.insert(sizzles, tick)
			end
		end
		t.eq(table.concat(sizzles, " "), "1 11 21", "every 10 ticks, with the hurt")
		-- Armor softens the hurt; it still lands and sizzles.
		local armored = Burning.newPlayer()
		local damage, _, hurt = Burning.tickPlayer(armored, GameMode.SURVIVAL, LAVA_MASK, 20, 8)
		t.ok(damage > 0 and damage < 4, `softened to {damage}`)
		t.ok(hurt, "armor or not")
		-- Burning after leaving the lava hurts without the lava's sizzle.
		local burnt = 0
		for _ = 1, 40 do
			local taken, _, again = Burning.tickPlayer(state, GameMode.SURVIVAL, 0)
			burnt += taken
			t.ok(not again, "no sizzle out of the lava")
		end
		t.ok(burnt > 0, "it burnt")
		-- Creative players are never hurt, so never sizzle.
		local creative = Burning.newPlayer()
		local _, _, never = Burning.tickPlayer(creative, GameMode.CREATIVE, LAVA_MASK)
		t.ok(not never)
	end)

	t.test("sounds: the burn and the extinguish hiss play at Minecraft's numbers, once", function()
		-- The server plays them with no cue: the events carry Minecraft's volume and pitch, and a
		-- cue would multiply them again (SoundRules.playback: volume x cue, pitch x cue).
		local calls: { [string]: { string } } = {}
		for _, file in { "src/server/Entities/Entities.luau", "src/server/Players/Characters.luau" } do
			for call in string.gmatch(fs.readFile(file), "Sounds%.play(%b())") do
				local event = string.match(call, "^%((%u+),")
				if event == "BURN" or event == "EXTINGUISH" then
					local args = string.gsub(string.sub(call, 2, -2), "%b()", "")
					local _, commas = string.gsub(args, ",", "")
					t.eq(commas, 3, `{file}: Sounds.play{call} takes the sound and where only`)
					calls[event] = calls[event] or {}
					table.insert(calls[event], file)
				end
			end
		end
		t.eq(calls.BURN and #calls.BURN, 2, "items and players sizzle")
		t.eq(calls.EXTINGUISH and #calls.EXTINGUISH, 1, "water puts players out")
		local settings = { Volume = 1, Sources = {} }
		local burn = Sounds.get("entity.generic.burn") :: any
		local low = SoundRules.playback(burn, nil, nil, 1, 1, 0, settings)
		local high = SoundRules.playback(burn, nil, nil, 1, 1, 0.999999, settings)
		t.near(low.volume, 0.4, 1e-9, "entity.generic.burn: volume 0.4")
		t.near(low.pitch, 2.0, 1e-6, "pitch 2 ..")
		t.near(high.pitch, 2.4, 1e-5, ".. 2.4 (2 + nextFloat x 0.4)")
		local hiss =
			SoundRules.playback(Sounds.get("entity.generic.extinguish_fire") :: any, nil, nil, 1, 1, 0.5, settings)
		t.near(hiss.volume, 0.7, 1e-9, "entity.generic.extinguish_fire: volume 0.7")
		t.near(hiss.pitch, 1.6, 1e-9, "pitch 1.6 in the middle")
	end)
end
