--[[
	Where the newer ores generate (Generation/Ores): copper, lead, zinc, sulfur, saltpetre and
	uranium. Their features against Minecraft's, Mekanism's and Create's numbers; what they place
	over all-stone chunks per height band against iron (the numbers in Ores' header); uranium's
	buried cells; saltpetre under dry land only; the sulfur vents on lava lakes' barriers and around
	oil deposits; real chunks of a seed; that no earlier ore moved; and what they cost.
]]

return function(t, shared, require)
	local Config = require(shared.Config)
	local Blocks = require(shared.Blocks)
	local Biomes = require(shared.Biomes)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Hash = require(shared.Util.Hash)
	local Relief = require(shared.Generation.Relief)
	local Ores = require(shared.Generation.Ores)
	local Lava = require(shared.Generation.Lava)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)

	local B = Blocks.id
	local SIZE, P, LAYER = ChunkLayout.SIZE, ChunkLayout.PADDED, ChunkLayout.LAYER
	local AIR, CAVE_AIR = Blocks.AIR, Blocks.CAVE_AIR
	local SEED = 12345
	local gen = TerrainGenerator.new(SEED)
	local NEWER = { B.CopperOre, B.LeadOre, B.ZincOre, B.SulfurOre, B.SaltpetreOre, B.UraniumOre }
	local isNewer: { [number]: boolean } = {}
	for _, block in NEWER do
		isNewer[block] = true
	end

	local function feature(name: string): Ores.Ore
		for _, ore in Ores.FEATURES do
			if ore.name == name then
				return ore
			end
		end
		error(`no ore feature {name}`)
	end
	-- Veins per chunk of a trapezoid or depth feature (the same in every chunk).
	local function perChunk(ore: Ores.Ore): number
		return ore.veins * (ore.maxY - ore.minY) / 128
	end

	-- A chunk `height` cells tall: bedrock at 0, stone above.
	local function stoneChunk(height: number): buffer
		local data = ChunkLayout.create(height)
		for i = 0, LAYER * height - 1 do
			buffer.writeu16(data, i * 2, if i < LAYER then B.Bedrock else B.Stone)
		end
		return data
	end

	-- The padded column index (pz * P + px + 1) of core column (x, z).
	local function column(x: number, z: number): number
		return (z + 1) * P + x + 2
	end

	t.test("ore generation: the newer features follow osmium, with their sources' numbers", function()
		-- (Their order by name, not their places: one random stream runs through the features in
		-- order, so the older ones come first and the newer after them, in this order.)
		local at: { [string]: number } = {}
		for index, ore in Ores.FEATURES do
			at[ore.name] = index
		end
		local order = {
			"diorite",
			"andesite",
			"granite",
			"coal",
			"iron",
			"gold",
			"diamond",
			"emerald",
			"osmium_small",
			"osmium_middle",
			"osmium_upper",
			"copper",
			"lead",
			"zinc",
			"sulfur",
			"saltpetre",
			"uranium_small",
			"uranium_buried",
		}
		for i, name in order do
			t.ok(at[name] ~= nil, `{name} is a feature`)
			if i > 1 and at[name] and at[order[i - 1]] then
				t.ok(at[order[i - 1]] < at[name], `{order[i - 1]} before {name}`)
			end
		end

		-- Minecraft's copper: 16 veins of 10 per chunk on a trapezoid, densest at y 176.
		local copper = feature("copper")
		t.eq(copper.shape, "trapezoid")
		t.eq(perChunk(copper), 16, "copper veins per chunk")
		t.eq(copper.size, 10, "copper vein size")
		t.eq((copper.minY + copper.maxY) / 2, 176, "densest where the low band meets the andesite")
		-- Mekanism's lead: 8 veins of 9, from below the bottom to the top of the low band.
		local lead = feature("lead")
		t.eq(lead.shape, "trapezoid")
		t.near(perChunk(lead), 8, 0.05, "lead veins per chunk")
		t.eq(lead.size, 9, "lead vein size")
		t.eq(lead.maxY, feature("osmium_middle").maxY, "up to the top of the low band")
		t.ok(lead.minY < 0, "its trapezoid starts below the bedrock, as Mekanism's")
		-- Create's zinc veins of 12, at gold's rate (as many walk steps per 128 blocks), uniform
		-- over the low band.
		local zinc, gold = feature("zinc"), feature("gold")
		t.eq(zinc.shape, nil, "uniform, as Create's")
		t.eq(zinc.size, 12, "Create's vein size")
		t.eq(zinc.veins * zinc.size, gold.veins * gold.size, "gold's steps per 128 blocks")
		t.eq(zinc.minY, 5)
		t.eq(zinc.maxY, 197)
		-- Sulfur: 3 veins of 8 per chunk from the bedrock to 22 over the cave lava's surface.
		local sulfur = feature("sulfur")
		t.eq(sulfur.block, B.SulfurOre)
		t.eq(sulfur.maxY, Config.Caves.LavaLevel + 22, "the cave lava's band")
		t.eq(perChunk(sulfur), 3, "sulfur veins per chunk")
		-- Saltpetre: 4 veins of 8 per chunk, 4 .. 36 under dry land.
		local saltpetre = feature("saltpetre")
		t.ok(saltpetre.depth == true and saltpetre.dry == true, "under the surface of dry land")
		t.eq(perChunk(saltpetre), 4, "saltpetre veins per chunk")
		t.eq(`{saltpetre.minY}..{saltpetre.maxY}`, "4..36", "blocks under the top block")
		-- Uranium: a quarter of Mekanism's small (4 of 4) and buried (7 of 9) veins.
		local small, buried = feature("uranium_small"), feature("uranium_buried")
		t.eq(perChunk(small), 4 / 4, "small veins per chunk")
		t.eq(small.size, 4)
		t.eq(perChunk(buried), 7 / 4, "buried veins per chunk")
		t.eq(buried.size, 9)
		t.eq(buried.plateau, 24, "Mekanism's plateau of 16, one and a half blocks a block")
		t.eq(buried.buried, 0.75, "Mekanism's discard chance on air exposure")
		t.ok(small.maxY <= 133 and buried.maxY <= 133, "deep, never in the mountains")
		-- Dry land: the biomes without rain.
		for _, biome in Biomes.list do
			local dry = biome.name == "Desert" or biome.name == "Savanna" or biome.name == "WindsweptSavanna"
			t.eq(Ores.isDry(biome.index), dry, `{biome.name} is dry`)
		end
	end)

	t.test("ore generation: adding the newer ores moved no earlier ore (osmium included)", function()
		-- Checksums of every cell of the older ores in all-stone chunks (as Generation's for the
		-- ores before osmium), taken before the newer ores existed: they only replace stone left
		-- over, so every earlier feature must keep drawing the same numbers.
		local height = 700
		local expected = { "1061:2124375055", "1044:1405127212", "1053:15318503" }
		for i, chunk in { { 0, 0 }, { 3, -2 }, { -57, 1201 } } do
			local data = stoneChunk(height)
			Ores.place(data, 4242, chunk[1], chunk[2], height)
			local sum, n = 0, 0
			for cell = 0, buffer.len(data) // 2 - 1 do
				local id = buffer.readu16(data, cell * 2)
				if id ~= B.Stone and id ~= B.Bedrock and not isNewer[id] then
					sum = (sum * 31 + cell * 7 + id) % 2147483647
					n += 1
				end
			end
			t.eq(`{n}:{sum}`, expected[i], `chunk {chunk[1]}, {chunk[2]}`)
		end
	end)

	-- Ore cells per layer over 48 all-stone chunks 448 tall (the osmium test's chunks; no caves or
	-- terrain in the way): counts[y][block].
	local HEIGHT = 448
	local counts: { { [number]: number } } = {}
	do
		local template = stoneChunk(HEIGHT)
		local data = buffer.create(buffer.len(template))
		for y = 0, HEIGHT - 1 do
			counts[y + 1] = {}
		end
		for chunk = 1, 48 do
			buffer.copy(data, 0, template)
			Ores.place(data, SEED, chunk * 7 - 100, chunk * 13 - 300, HEIGHT)
			for y = 0, HEIGHT - 1 do
				local row = counts[y + 1]
				for i = 0, LAYER - 1 do
					local id = buffer.readu16(data, (y * LAYER + i) * 2)
					if id ~= B.Stone then
						row[id] = (row[id] or 0) + 1
					end
				end
			end
		end
	end
	-- Cells of `block` in layers y0 .. y1.
	local function band(block: number, y0: number, y1: number): number
		local n = 0
		for y = math.max(y0, 0), math.min(y1, HEIGHT - 1) do
			n += counts[y + 1][block] or 0
		end
		return n
	end
	local function ratio(block: number, other: number, y0: number, y1: number): number
		return band(block, y0, y1) / math.max(band(other, y0, y1), 1)
	end

	t.test("ore generation: copper outnumbers iron at middle heights (Minecraft's copper)", function()
		local over = ratio(B.CopperOre, B.IronOre, 48, 304)
		local middle = ratio(B.CopperOre, B.IronOre, 130, 230)
		local low = ratio(B.CopperOre, B.IronOre, 5, 89)
		t.ok(over > 1.3 and over < 1.9, `copper / iron over y 48 .. 304: {over}`)
		t.ok(middle > 2 and middle < 3, `copper / iron around y 130 .. 230: {middle}`)
		t.ok(low < 0.5, `copper / iron below y 90: {low}`)
		-- Veins wander up to their size from their start.
		t.eq(band(B.CopperOre, 0, 48 - 10) + band(B.CopperOre, 304 + 10, HEIGHT), 0, "none outside its range")
		print(
			string.format(
				"    copper / iron: %.2f over y 48 .. 304, %.2f around 130 .. 230, %.2f below 90",
				over,
				middle,
				low
			)
		)
	end)

	t.test("ore generation: lead a little less common than osmium, low to middle heights", function()
		local low = ratio(B.LeadOre, B.IronOre, 5, 196)
		local middle = ratio(B.LeadOre, B.IronOre, 50, 120)
		local osmium = ratio(B.LeadOre, B.OsmiumOre, 5, 196)
		t.ok(low > 0.7 and low < 1, `lead / iron below y 197: {low}`)
		t.ok(middle > 1.2 and middle < 1.8, `lead / iron around y 50 .. 120: {middle}`)
		t.ok(osmium > 0.75 and osmium < 1, `lead / osmium below y 197: {osmium}`)
		t.eq(band(B.LeadOre, 197 + 9, HEIGHT), 0, "none in the mountains")
		print(
			string.format(
				"    lead / iron: %.2f below y 197, %.2f around 50 .. 120; lead / osmium %.2f",
				low,
				middle,
				osmium
			)
		)
	end)

	t.test("ore generation: zinc as common as gold, over the low band", function()
		local gold = ratio(B.ZincOre, B.GoldOre, 48, 196)
		local iron = ratio(B.ZincOre, B.IronOre, 5, 196)
		t.ok(gold > 0.75 and gold < 1.25, `zinc / gold over y 48 .. 196: {gold}`)
		t.ok(iron > 0.25 and iron < 0.45, `zinc / iron below y 197: {iron}`)
		t.ok(band(B.ZincOre, 5, 47) > 0, "below gold's range too (Create's zinc reaches the bottom)")
		t.eq(band(B.ZincOre, 197 + 12, HEIGHT), 0, "none in the mountains")
		print(string.format("    zinc / gold: %.2f over y 48 .. 196; zinc / iron %.2f below 197", gold, iron))
	end)

	t.test("ore generation: uranium rare and deep, densest near bedrock", function()
		local deep = ratio(B.UraniumOre, B.IronOre, 5, 49)
		local low = ratio(B.UraniumOre, B.IronOre, 5, 99)
		t.ok(deep > 0.35 and deep < 0.7, `uranium / iron below y 50: {deep}`)
		t.ok(low > 0.25 and low < 0.55, `uranium / iron below y 100: {low}`)
		-- Per layer: y 5 .. 49 against y 50 .. 133.
		local near, above = band(B.UraniumOre, 5, 49) / 45, band(B.UraniumOre, 50, 133) / 84
		t.ok(near > 2 * above, `uranium per layer below y 50 {near}, above {above}`)
		t.eq(band(B.UraniumOre, 133 + 4, HEIGHT), 0, "never in the mountains")
		local diamond = ratio(B.UraniumOre, B.DiamondOre, 0, HEIGHT)
		t.ok(diamond > 2 and diamond < 6, `uranium / diamonds: {diamond}`)
		print(
			string.format(
				"    uranium / iron: %.2f below y 50, %.2f below 100; %.1f times the diamonds",
				deep,
				low,
				diamond
			)
		)
	end)

	t.test("ore generation: sulfur veins in the cave lava's band, none above it", function()
		local iron = ratio(B.SulfurOre, B.IronOre, 1, 33)
		t.ok(iron > 1.4 and iron < 2.4, `sulfur / iron in y 1 .. 33: {iron}`)
		t.ok(band(B.SulfurOre, 1, Config.Caves.LavaLevel - 1) > 0, "beside the lava's layers")
		t.eq(band(B.SulfurOre, 33 + 8, HEIGHT), 0, "no plain veins above the band")
		-- (No surface heights given: no saltpetre.)
		t.eq(band(B.SaltpetreOre, 0, HEIGHT), 0, "saltpetre needs the columns' surface")
		print(string.format("    sulfur / iron: %.2f in y 1 .. 33", iron))
	end)

	t.test("ore generation: uranium's buried veins keep off the air, other ores don't", function()
		-- A deep chunk riddled with cave air, one cell in five ((x + y + z) % 5 == 0): two in five
		-- stone cells touch it, two in five don't. Ore cells touching air against not.
		local height = 160
		local template = stoneChunk(height)
		for y = 1, height - 1 do
			for pz = 0, P - 1 do
				for px = 0, P - 1 do
					if (px + y + pz) % 5 == 0 then
						buffer.writeu16(template, ((y * P + pz) * P + px) * 2, CAVE_AIR)
					end
				end
			end
		end
		local data = buffer.create(buffer.len(template))
		local open = { [B.UraniumOre] = 0, [B.LeadOre] = 0 }
		local shut = { [B.UraniumOre] = 0, [B.LeadOre] = 0 }
		for chunk = 1, 64 do
			buffer.copy(data, 0, template)
			Ores.place(data, SEED, chunk * 5, -chunk * 3, height)
			for y = 1, height - 2 do
				for z = 0, SIZE - 1 do
					for x = 0, SIZE - 1 do
						local id = ChunkLayout.get(data, x, y, z)
						if open[id] then
							local touches = false
							for _, d in
								{ { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
							do
								local n = ChunkLayout.getPadded(data, x + d[1], y + d[2], z + d[3])
								touches = touches or n == CAVE_AIR
							end
							if touches then
								open[id] += 1
							else
								shut[id] += 1
							end
						end
					end
				end
			end
		end
		local lead = open[B.LeadOre] / shut[B.LeadOre]
		local uranium = open[B.UraniumOre] / shut[B.UraniumOre]
		t.ok(lead > 0.8 and lead < 1.25, `lead cells touching air / not: {lead}`)
		-- The small feature (a fifth of the veins' steps) isn't buried; the buried one keeps a
		-- quarter of its cells by air: about (0.2 + 0.8 * 0.25) / 1.
		t.ok(uranium > 0.25 and uranium < 0.6, `uranium cells touching air / not: {uranium}`)
		t.ok(shut[B.UraniumOre] > 300, `uranium placed: {shut[B.UraniumOre]}`)
		print(string.format("    cells touching air / not: lead %.2f, uranium %.2f", lead, uranium))
	end)

	--[[ Saltpetre: under dry land ]]

	local DESERT = (Biomes.byName("Desert") :: Biomes.Biome).index
	local PLAINS = (Biomes.byName("Plains") :: Biomes.Biome).index

	-- Saltpetre and every other placed cell of `chunks` all-stone chunks 160 tall whose columns'
	-- surface is `top` (first air) and biome `biome(x)` (core x), in chunks (k, 7).
	local function underLand(top: number, biome: (x: number) -> number, chunks: number)
		local height = 160
		local template = stoneChunk(height)
		local surface, biomes = table.create(P * P, top), table.create(P * P, PLAINS)
		for pz = 0, P - 1 do
			for px = 0, P - 1 do
				biomes[pz * P + px + 1] = biome(math.clamp(px - 1, 0, SIZE - 1))
			end
		end
		local data = buffer.create(buffer.len(template))
		local cells: { { number } } = {}
		local others = 0
		for k = 1, chunks do
			buffer.copy(data, 0, template)
			Ores.place(data, SEED, k, 7, height, surface, biomes)
			for y = 0, height - 1 do
				for z = 0, SIZE - 1 do
					for x = 0, SIZE - 1 do
						local id = ChunkLayout.get(data, x, y, z)
						if id == B.SaltpetreOre then
							table.insert(cells, { x, y, z })
						elseif id ~= B.Stone and id ~= B.Bedrock then
							others = (others * 31 + (y * 256 + z * 16 + x) * 7 + id) % 2147483647
						end
					end
				end
			end
		end
		return cells, others
	end

	t.test("ore generation: saltpetre never runs under wet land or the sea at dry land's edge", function()
		-- (Each step of a vein, not only its start, must lie under dry land above the sea: a vein
		-- starting at a desert's edge once ran under the tundra beside it.)
		local rng = Hash.rng(5)
		local dry, other, chunks, tries = 0, 0, 0, 0
		while chunks < 12 and tries < 20000 do
			tries += 1
			local cx, cz = rng:int(-40000, 40000) // SIZE, rng:int(-40000, 40000) // SIZE
			local hasDry, hasOther = false, false
			for dz = 0, SIZE - 1, 3 do
				for dx = 0, SIZE - 1, 3 do
					local h, b = gen.column(cx * SIZE + dx, cz * SIZE + dz)
					if Ores.isDry(b) and h > Config.SeaLevel then
						hasDry = true
					else
						hasOther = true
					end
				end
			end
			if hasDry and hasOther then
				chunks += 1
				local r = gen.generate(0, cx, cz)
				for y = 0, r.height - 1 do
					for lz = 0, SIZE - 1 do
						for lx = 0, SIZE - 1 do
							if ChunkLayout.get(r.data, lx, y, lz) == B.SaltpetreOre then
								local h, b = gen.column(cx * SIZE + lx, cz * SIZE + lz)
								if h > Config.SeaLevel and Ores.isDry(b) then
									dry += 1
								else
									other += 1
								end
							end
						end
					end
				end
			end
		end
		t.eq(chunks, 12, "chunks on dry land's edge found")
		t.ok(dry > 0, `saltpetre under their dry land ({dry})`)
		t.eq(other, 0, "none under the wet land or sea beside it")
	end)

	t.test("ore generation: saltpetre 4 to 36 blocks under dry land, as common as coal there", function()
		local top = 120
		local cells, others = underLand(top, function()
			return DESERT
		end, 48)
		local perChunk = #cells / 48
		t.ok(perChunk > 16 and perChunk < 30, `saltpetre per dry chunk: {perChunk}`)
		local sum = 0
		for _, c in cells do
			local depth = top - 1 - c[2]
			sum += depth
			-- Veins wander up to their size from where they start.
			t.ok(depth >= 4 - 7 and depth <= 36 + 7, `saltpetre {depth} under the top block`)
		end
		t.near(sum / #cells, 20, 3, "centred in its depths")
		-- Coal in the same layers of all-stone chunks (the band counts above): about as many.
		local coal = band(B.CoalOre, top - 1 - 36, top - 1 - 4) / 48
		t.ok(perChunk / coal > 0.6 and perChunk / coal < 1.5, `saltpetre / coal in its layers: {perChunk / coal}`)
		print(
			string.format(
				"    saltpetre: %.1f a dry chunk, %.2f times the coal in its layers",
				perChunk,
				perChunk / coal
			)
		)

		-- Wet land, the sea floor of a desert: none, and every other ore just where it was (the
		-- veins draw the same numbers wherever they place nothing).
		local wet, wetOthers = underLand(top, function()
			return PLAINS
		end, 48)
		t.eq(#wet, 0, "no saltpetre under plains")
		t.eq(wetOthers, others, "the other ores where they were")
		local sea = underLand(Config.SeaLevel, function()
			return DESERT
		end, 12)
		t.eq(#sea, 0, "none under a desert's sea floor")
		-- Half a desert: the veins start in its columns only.
		local half = underLand(top, function(x: number): number
			return if x < 8 then DESERT else PLAINS
		end, 48)
		local inside = 0
		for _, c in half do
			if c[1] < 8 then
				inside += 1
			end
		end
		t.ok(#half > 0 and inside / #half > 0.85, `in the desert half: {inside} of {#half}`)
	end)

	--[[ Sulfur vents ]]

	-- An all-stone chunk 160 tall with sulfur vents of `lakes`, `wells` and `sunk`; its sulfur
	-- cells (world x, y, z).
	local function vented(cx: number, cz: number, lakes: { any }?, wells: { any }?, sunk: any?): { { number } }
		local height = 160
		local data = stoneChunk(height)
		Ores.vents(data, SEED, cx, cz, height, lakes, wells, sunk)
		local cells = {}
		local outside, other = 0, 0
		for i = 0, buffer.len(data) // 2 - 1 do
			local id = buffer.readu16(data, i * 2)
			local y, index = i // LAYER, i % LAYER
			local px, pz = index % P, index // P
			if id == B.SulfurOre then
				if px < 1 or px > SIZE or pz < 1 or pz > SIZE then
					outside += 1
				end
				table.insert(cells, { cx * SIZE + px - 1, y, cz * SIZE + pz - 1 })
			elseif id ~= B.Stone and id ~= B.Bedrock then
				other += 1
			end
		end
		t.eq(outside, 0, "sulfur outside the core")
		t.eq(other, 0, "other blocks than stone and sulfur")
		return cells
	end
	local function key(cells: { { number } }): string
		local list = {}
		for _, c in cells do
			table.insert(list, `{c[1]},{c[2]},{c[3]}`)
		end
		table.sort(list)
		return table.concat(list, ";")
	end

	t.test("ore generation: sulfur vents on a lava lake's barrier, across chunk borders", function()
		local shape = Lava.shapeOf(Hash.rng(3))
		-- A lake straddling chunks (0, 0) and (1, 0).
		local lake = { x = 8, y = 60, z = 0, shape = shape, cells = 1, underground = false }
		local barrier: { { number } } = {}
		for i = 0, buffer.len(shape) - 1 do
			if buffer.readu8(shape, i) == Lava.BARRIER then
				local column = i // Lava.LAYERS
				table.insert(
					barrier,
					{ lake.x + column // Lava.BOX, lake.y + i % Lava.LAYERS, lake.z + column % Lava.BOX }
				)
			end
		end
		local west, east = vented(0, 0, { lake }), vented(1, 0, { lake })
		t.ok(#west > 0 and #east > 0, `sulfur on both sides: {#west}, {#east}`)
		t.ok(#west + #east <= (#barrier // 16) * 6, "a vein of 6 per 16 barrier cells")
		for _, c in table.move(east, 1, #east, #west + 1, table.clone(west)) do
			local near = false
			for _, b in barrier do
				near = near or math.abs(c[1] - b[1]) + math.abs(c[2] - b[2]) + math.abs(c[3] - b[3]) <= 5
			end
			t.ok(near, `sulfur at {c[1]},{c[2]},{c[3]} within 5 steps of the barrier`)
		end
		-- The lake's own stream: the same cells whatever else is near, as the one sunk into a
		-- chunk, and in any order; none from a lake out of reach.
		local far = { x = 400, y = 60, z = 400, shape = shape, cells = 1, underground = false }
		t.eq(key(vented(0, 0, { far, lake })), key(west), "a far lake changes nothing")
		t.eq(key(vented(0, 0, nil, nil, lake)), key(west), "sunk or near, the same veins")
		t.eq(#vented(0, 0, { far }), 0, "no vein reaches from a far lake")
		t.ok(key(vented(0, 0, { { x = 8, y = 61, z = 0, shape = shape } })) ~= key(west), "another lake, other veins")
	end)

	t.test("ore generation: sulfur vents around an oil deposit, one per 64 square blocks", function()
		local well = { x = 20, y = 60, z = 10, radius = 6 }
		local cells = {}
		for cx = 0, 2 do
			for cz = -1, 1 do
				for _, c in vented(cx, cz, nil, { well }) do
					table.insert(cells, c)
				end
			end
		end
		local veins = math.floor(4 * math.pi * 7 * 7 / 64 + 0.5)
		t.ok(#cells > veins * 3 and #cells <= veins * 8, `sulfur cells {#cells} of {veins} veins of 8`)
		for _, c in cells do
			local d = math.sqrt((c[1] - well.x) ^ 2 + (c[2] - well.y) ^ 2 + (c[3] - well.z) ^ 2)
			t.ok(d >= well.radius + 1 - 8 and d <= well.radius + 1 + 8, `sulfur {d} from the deposit's centre`)
		end
		t.eq(#vented(5, 5, nil, { well }), 0, "none beyond its reach")
	end)

	--[[ Real chunks ]]

	local cache: { [string]: any } = {}
	local function chunk(cx: number, cz: number): any
		local k = `{cx},{cz}`
		local r = cache[k]
		if r == nil then
			r = gen.generate(0, cx, cz)
			cache[k] = r
		end
		return r
	end

	t.test("ore generation: real chunks keep every newer ore to its heights, mountains and lowlands", function()
		local relief = Relief.new(SEED)
		local rng = Hash.rng(31)
		local spots = {}
		while #spots < 8 do
			local x, z = rng:int(-40000, 40000), rng:int(-40000, 40000)
			local y = relief.height(x, z, 0)
			if (#spots < 4 and y > 90 and y < 160) or (#spots >= 4 and y > 500 and y < 760) then
				table.insert(spots, { x // SIZE, z // SIZE })
			end
		end
		local found: { [number]: number } = {}
		local LIMIT = {
			[B.CopperOre] = { 48 - 10, 304 + 10 },
			[B.LeadOre] = { 1, 197 + 9 },
			[B.ZincOre] = { 5 - 12, 197 + 12 },
			[B.UraniumOre] = { 1, 133 + 9 },
		}
		for _, spot in spots do
			local r = chunk(spot[1], spot[2])
			local lakes =
				gen.lavaLakes(spot[1] * SIZE - 8, spot[2] * SIZE - 8, spot[1] * SIZE + 23, spot[2] * SIZE + 23)
			local wells =
				gen.oilWells(spot[1] * SIZE - 30, spot[2] * SIZE - 30, spot[1] * SIZE + 45, spot[2] * SIZE + 45)
			-- Lava above the cave lava's level (an underground lake) anywhere in the chunk.
			local sunk = false
			for y = Config.Caves.LavaLevel, r.height - 1 do
				for i = 0, LAYER - 1 do
					sunk = sunk or buffer.readu16(r.data, (y * LAYER + i) * 2) == B.CaveLava
				end
			end
			for y = 0, r.height - 1 do
				for z = 0, SIZE - 1 do
					for x = 0, SIZE - 1 do
						local id = ChunkLayout.get(r.data, x, y, z)
						if not isNewer[id] then
							continue
						end
						found[id] = (found[id] or 0) + 1
						local wx, wz = spot[1] * SIZE + x, spot[2] * SIZE + z
						local surface = gen.column(wx, wz)
						t.ok(y < surface, `{Blocks.get(id).name} below the surface ({y} < {surface})`)
						local limit = LIMIT[id]
						if limit then
							t.ok(y >= limit[1] and y <= limit[2], `{Blocks.get(id).name} at y {y}`)
						elseif id == B.SulfurOre and y > 33 + 8 then
							-- A vent: by a lava lake or an oil deposit.
							local vent = sunk
							for _, lake in lakes do
								vent = vent
									or (
										wx >= lake.x - 6
										and wx < lake.x + Lava.BOX + 6
										and wz >= lake.z - 6
										and wz < lake.z + Lava.BOX + 6
									)
							end
							for _, well in wells do
								vent = vent
									or (wx - well.x) ^ 2 + (y - well.y) ^ 2 + (wz - well.z) ^ 2 <= (well.radius + 9) ^ 2
							end
							t.ok(vent, `sulfur at {wx},{y},{wz}: by lava or oil`)
						end
					end
				end
			end
		end
		for _, block in { B.CopperOre, B.LeadOre, B.ZincOre, B.SulfurOre, B.UraniumOre } do
			t.ok((found[block] or 0) > 0, `{Blocks.get(block).name} found`)
		end
	end)

	t.test("ore generation: real deserts and savannas hold saltpetre, wet land none", function()
		local rng = Hash.rng(41)
		local dry, wet, dryChunks, wetChunks = 0, 0, 0, 0
		local tries = 0
		while (dryChunks < 6 or wetChunks < 6) and tries < 5000 do
			tries += 1
			local x, z = rng:int(-40000, 40000), rng:int(-40000, 40000)
			local h, biome = gen.column(x, z)
			local want = Ores.isDry(biome)
			if h <= Config.SeaLevel or (want and dryChunks >= 6) or (not want and wetChunks >= 6) then
				continue
			end
			local cx, cz = x // SIZE, z // SIZE
			-- Every column of the chunk and around it dry, or none.
			local all, none = true, true
			for dz = -8, SIZE + 7, 4 do
				for dx = -8, SIZE + 7, 4 do
					local ch, b = gen.column(cx * SIZE + dx, cz * SIZE + dz)
					local isDry = Ores.isDry(b) and ch > Config.SeaLevel
					all = all and isDry
					none = none and not isDry
				end
			end
			if h > Config.SeaLevel and ((all and dryChunks < 6) or (none and wetChunks < 6)) then
				local r = chunk(cx, cz)
				local n = 0
				for y = 0, r.height - 1 do
					for i = 0, LAYER - 1 do
						if buffer.readu16(r.data, (y * LAYER + i) * 2) == B.SaltpetreOre then
							n += 1
						end
					end
				end
				if all then
					dry += n
					dryChunks += 1
					t.ok(n > 0, `saltpetre in {Biomes.list[biome].name} chunk {cx}, {cz}`)
				else
					wet += n
					wetChunks += 1
				end
			end
		end
		t.ok(dryChunks == 6 and wetChunks == 6, `chunks found: {dryChunks} dry, {wetChunks} wet`)
		t.ok(dry / dryChunks > 10, `saltpetre per dry chunk: {dry / dryChunks}`)
		t.eq(wet, 0, "none under wet land")
	end)

	t.test("ore generation: sulfur on real lava lakes' barriers and around real oil deposits", function()
		local function sulfurIn(x0: number, y0: number, z0: number, x1: number, y1: number, z1: number): number
			local n = 0
			for cz = z0 // SIZE, z1 // SIZE do
				for cx = x0 // SIZE, x1 // SIZE do
					local r = chunk(cx, cz)
					for z = math.max(z0, cz * SIZE), math.min(z1, cz * SIZE + SIZE - 1) do
						for x = math.max(x0, cx * SIZE), math.min(x1, cx * SIZE + SIZE - 1) do
							for y = math.max(y0, 0), math.min(y1, r.height - 1) do
								if ChunkLayout.get(r.data, x - cx * SIZE, y, z - cz * SIZE) == B.SulfurOre then
									n += 1
								end
							end
						end
					end
				end
			end
			return n
		end
		local lakes = gen.lavaLakes(-6000, -6000, 6000, 6000)
		t.ok(#lakes >= 4, `surface lakes: {#lakes}`)
		local total = 0
		for k = 1, 4 do
			local lake = lakes[k]
			local n = sulfurIn(lake.x - 6, lake.y - 6, lake.z - 6, lake.x + 21, lake.y + 13, lake.z + 21)
			t.ok(n > 3, `surface lake {k}: {n} sulfur`)
			total += n
		end
		local wells = gen.oilWells(-8000, -8000, 8000, 8000)
		t.ok(#wells >= 3, `wells: {#wells}`)
		for k = 1, 3 do
			local well = wells[k]
			local r = well.radius + 9
			local n = sulfurIn(well.x - r, well.y - r, well.z - r, well.x + r, well.y + r, well.z + r)
			t.ok(n > 10, `{well.size} well {k} (radius {well.radius}): {n} sulfur`)
		end
		-- Underground lakes: chunks with lava above the cave lava's level get sulfur up there.
		local rng = Hash.rng(99)
		local withLake, vented = 0, 0
		for _ = 1, 120 do
			local cx, cz = rng:int(-500, 500), rng:int(-500, 500)
			local r = gen.generate(0, cx, cz)
			local lakeY: number? = nil
			for y = Config.Caves.LavaLevel, r.height - 1 do
				for i = 0, LAYER - 1 do
					if buffer.readu16(r.data, (y * LAYER + i) * 2) == B.CaveLava then
						lakeY = y
						break
					end
				end
				if lakeY then
					break
				end
			end
			if lakeY and lakeY > 33 + 12 then
				withLake += 1
				local n = 0
				for y = lakeY - 10, math.min(lakeY + 14, r.height - 1) do
					for i = 0, LAYER - 1 do
						if buffer.readu16(r.data, (y * LAYER + i) * 2) == B.SulfurOre then
							n += 1
						end
					end
				end
				if n > 0 then
					vented += 1
				end
			end
		end
		t.ok(withLake >= 4, `chunks with an underground lake above the sulfur band: {withLake}`)
		t.ok(vented >= withLake * 0.75, `with sulfur by it: {vented} of {withLake}`)
		print(`    {total} sulfur around 4 surface lava lakes; {vented} of {withLake} underground lakes vented`)
	end)

	t.test("ore generation: cost (the newer ores' share of a chunk's ore walk, timed)", function()
		-- Expected walk steps of a 700 tall chunk: every feature's veins times its size.
		local steps, newer = 0, 0
		for i, ore in Ores.FEATURES do
			local top = if ore.shape or ore.depth then ore.maxY else math.min(ore.maxY, 699)
			local n = ore.veins * (top - ore.minY) / 128 * ore.size
			steps += n
			if i >= 12 then
				newer += n
			end
		end
		-- Time Ores.place on that chunk, and Ores.place with the vents against generating real
		-- chunks (their data placed again: the cost is the same).
		local tall = stoneChunk(700)
		local copy = buffer.create(buffer.len(tall))
		local best = math.huge
		for _ = 1, 3 do
			local t0 = os.clock()
			for k = 1, 50 do
				buffer.copy(copy, 0, tall)
				Ores.place(copy, SEED, k, -k, 700)
			end
			best = math.min(best, (os.clock() - t0) / 50)
		end
		local generating, placing = 0, 0
		local rng = Hash.rng(17)
		for _ = 1, 12 do
			local cx, cz = rng:int(-300, 300), rng:int(-300, 300)
			gen.generate(0, cx, cz)
			local t0 = os.clock()
			local r = gen.generate(0, cx, cz)
			generating += os.clock() - t0
			local lakes = gen.lavaLakes(cx * SIZE - 8, cz * SIZE - 8, cx * SIZE + 23, cz * SIZE + 23)
			local wells = gen.oilWells(cx * SIZE - 30, cz * SIZE - 30, cx * SIZE + 45, cz * SIZE + 45)
			local data = buffer.create(buffer.len(r.data))
			buffer.copy(data, 0, r.data)
			t0 = os.clock()
			Ores.place(data, SEED, cx, cz, r.height)
			Ores.vents(data, SEED, cx, cz, r.height, lakes, wells)
			placing += os.clock() - t0
		end
		-- (About 0.25 ms alone; late in the full suite everything runs some four times slower, as
		-- the other cost specs see, so the bound leaves room for that.)
		t.ok(best < 2e-3, `Ores.place on a 700 tall chunk: {best * 1000} ms`)
		t.ok(placing < 0.12 * generating, `ores {placing / 12 * 1000} ms of {generating / 12 * 1000} ms a chunk`)
		print(
			string.format(
				"    walk steps per 700 tall chunk: %d, the newer ores %d (%.0f%%); Ores.place %.3f ms;"
					.. " ores and vents %.3f ms of a real chunk's %.2f ms",
				steps,
				newer,
				newer / steps * 100,
				best * 1000,
				placing / 12 * 1000,
				generating / 12 * 1000
			)
		)
	end)
end
