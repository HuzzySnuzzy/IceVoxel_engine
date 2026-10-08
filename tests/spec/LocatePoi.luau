--[[
	/locate poi (World/PoiSearch, Shared/Poi): placed blocks found through the world's edits within
	Minecraft's 256 blocks (3D) and not beyond, types and tags (a battery tier is a battery, an
	electric furnace a machine and a workstation), generated points from the generator's plans
	(a layout's blocks, an outpost's chests, a mineshaft's) checked against the block really there
	(a broken chest is skipped for the next, a claimed block that isn't there is dropped), and
	Config.Locate.PoiGeneratedNear's loaded chunks only.
]]

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Biomes = require(shared.Biomes)
	local Poi = require(shared.Poi)
	local LayeredGenerator = require(shared.Generation.LayeredGenerator)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local WorldTypes = require(shared.Generation.WorldTypes)
	local WorldServer = require(server.World.WorldServer)
	local PoiSearch = require(server.World.PoiSearch)

	local id = Blocks.id
	local CHEST = id.Chest
	local AIR = Blocks.AIR

	local function wanted(...: string): { [number]: boolean }
		return PoiSearch.wanted({ ... })
	end

	t.test("poi: types and tags cover their blocks' variants", function()
		t.eq(Poi.of(CHEST), "chest")
		t.eq(Poi.of(id.AdvancedBattery), "battery", "a battery tier")
		t.eq(Poi.of(id.EliteFluidTank), "fluid_tank")
		t.eq(Poi.of(id.LitTnt), "tnt", "lit TNT is TNT")
		t.eq(Poi.of(id.StructureBlockLoad), "structure_block", "every mode")
		t.eq(Poi.of(id.JigsawDownEast), "jigsaw", "every facing")
		t.eq(Poi.of(id.Stone), nil)
		local tags = Poi.tags()
		t.ok(table.find(tags.machine, "electric_furnace") ~= nil and table.find(tags.machine, "battery") ~= nil)
		t.ok(table.find(tags.machine, "chest") == nil, "only machines")
		t.ok(table.find(tags.workstation, "electric_furnace") ~= nil)
		for _, poiType in Poi.types do
			t.ok(#poiType.blocks > 0, poiType.id)
		end
	end)

	t.test("poi: placed blocks within 256 blocks (3D), types and tags", function()
		local world = WorldServer.new(WorldTypes.create("superflat", 1, {}))
		local ground = (world.generator.column(0, 0))
		world:setBlock(100, ground, 0, CHEST)
		world:setBlock(300, ground, 0, CHEST)
		local found = PoiSearch.nearest(world, nil, wanted("chest"), 0, ground, 0, 256) :: any
		t.ok(found ~= nil and found.x == 100 and found.id == "chest", "the chest at 100")
		t.eq(math.floor(found.distance), 100)
		world:setBlock(100, ground, 0, AIR)
		t.eq(PoiSearch.nearest(world, nil, wanted("chest"), 0, ground, 0, 256), nil, "the one at 300 is too far")
		-- 3D: 200 up and 200 across is 283 away.
		world:setBlock(0, ground + 200, 200, CHEST)
		t.eq(PoiSearch.nearest(world, nil, wanted("chest"), 0, ground, 0, 256), nil, "too far in 3D")
		t.ok(
			PoiSearch.nearest(world, nil, wanted("chest"), 0, ground + 150, 0, 256) ~= nil,
			"near enough from higher up"
		)

		world:setBlock(5, ground, 5, id.ElectricFurnace)
		world:setBlock(-30, ground, 0, id.UltimateBattery)
		local machine = PoiSearch.nearest(world, nil, PoiSearch.wanted(Poi.tags().machine), 0, ground, 0, 256) :: any
		t.eq(machine.id, "electric_furnace", "#machine")
		local station = PoiSearch.nearest(world, nil, PoiSearch.wanted(Poi.TAGS.workstation), 0, ground, 0, 256) :: any
		t.eq(station.id, "electric_furnace", "#workstation")
		local battery = PoiSearch.nearest(world, nil, wanted("battery"), 0, ground, 0, 256) :: any
		t.ok(battery.x == -30 and battery.id == "battery", "a battery tier")
		t.eq(PoiSearch.nearest(world, nil, wanted("nuke"), 0, ground, 0, 256), nil, "none of a type")
	end)

	t.test("poi: generated points are checked against the block really there", function()
		local plains = (Biomes.byName("Plains") :: any).index
		local stack = LayeredGenerator.stack({
			{ block = id.Bedrock, count = 1 },
			{ block = id.Dirt, count = 2 },
			{ block = id.Grass, count = 1 },
		})
		local layered = LayeredGenerator.new({ seed = 1, stack = stack, biome = plains, blocks = { 20, 4, 0, CHEST } })
		local gen = table.clone(layered)
		local listed = layered.poiBlocks :: any
		-- A chest the plans claim inside the ground (a later piece wrote over it, say).
		gen.poiBlocks = function(minX: number, minZ: number, maxX: number, maxZ: number, lut: buffer): { number }
			local out = listed(minX, minZ, maxX, maxZ, lut)
			table.insert(out, 3)
			table.insert(out, 1)
			table.insert(out, 3)
			table.insert(out, CHEST)
			return out
		end
		local world = WorldServer.new(gen)
		local stats = { probes = 0, verified = 0 }
		local found = PoiSearch.nearest(world, nil, wanted("chest"), 0, 4, 0, 256, { stats = stats }) :: any
		t.ok(found ~= nil and found.x == 20, "the claimed one is dropped, the laid out one found")
		t.eq(stats.verified, 2, "both checked")
		t.eq(world:peekChunk(1, 0), nil, "without loading the world's chunk")
		t.eq(PoiSearch.nearest(world, nil, wanted("chest"), 0, 4, 0, 256, { generatedNear = true }), nil, "loaded only")
		world:getChunk(1, 0)
		t.ok(
			PoiSearch.nearest(world, nil, wanted("chest"), 0, 4, 0, 256, { generatedNear = true }) ~= nil,
			"now loaded"
		)
		world:setBlock(20, 4, 0, AIR)
		t.eq(PoiSearch.nearest(world, nil, wanted("chest"), 0, 4, 0, 256), nil, "a broken one is gone")
	end)

	t.test("poi: an outpost's and a mineshaft's chests, from their plans", function()
		local gen = TerrainGenerator.new(12345)
		local world = WorldServer.new(gen)
		-- The outpost nearest the origin (Generation/Locate: at 1142, 582 on this seed).
		local start = gen.structures(1142, 582, 1142, 582)[1]
		t.ok(start ~= nil and start.name == "outpost", "an outpost there")
		local list = (gen.poiBlocks :: any)(1142 - 60, 582 - 60, 1142 + 60, 582 + 60, Poi.lut)
		local chests = 0
		for i = 1, #list, 4 do
			if list[i + 3] == CHEST then
				chests += 1
			end
		end
		t.ok(chests > 0, "its plans hold chests")
		local surface = (gen.column(1142, 582))
		local first = PoiSearch.nearest(world, nil, wanted("chest"), 1142, surface, 582, 256) :: any
		t.ok(first ~= nil, "a chest")
		t.eq(world:getBlock(first.x, first.y, first.z), CHEST, "really there")
		t.ok(gen.structureContainer(first.x, first.y, first.z) ~= nil, "a generated chest (its loot)")
		world:setBlock(first.x, first.y, first.z, AIR)
		local second = PoiSearch.nearest(world, nil, wanted("chest"), 1142, surface, 582, 256) :: any
		if second then
			t.ok(second.x ~= first.x or second.y ~= first.y or second.z ~= first.z, "the next one")
			t.eq(world:getBlock(second.x, second.y, second.z), CHEST)
			t.ok(gen.structureContainer(second.x, second.y, second.z) ~= nil)
			t.ok(second.distance >= first.distance, "farther")
		end

		-- A mineshaft's chest: from where it stands, it is the nearest.
		local found = nil
		for _, plan in gen.mineshafts(2800, -2200, 3200, -1800) do
			for _, piece in plan.pieces do
				if #piece.chests > 0 and found == nil then
					found = { piece.chests[1], piece.chests[2], piece.chests[3] }
				end
			end
		end
		t.ok(found ~= nil, "a mineshaft with a chest")
		local c = found :: any
		local at = PoiSearch.nearest(world, nil, wanted("chest"), c[1], c[2], c[3], 256) :: any
		t.ok(at ~= nil and at.distance <= 1, "found where the plan put it")
		t.eq(world:getBlock(at.x, at.y, at.z), CHEST)
		t.ok(gen.structureContainer(at.x, at.y, at.z) ~= nil, "a mineshaft's loot")
	end)
end
