--[[
	Snow layers (BlockList SnowLayer1 .. 8, Shared/Seasons/SnowLayers): the ids and their layers, the
	blocks' shapes (bounds, collision one layer lower, layer 1 replaceable and walked through, the
	eighth sturdy), their appearances (one each, never single: they merge), drops, the Snow Layer
	item and its recipe, stacking, what snow lies on, speed factors and where a column's layers are,
	and the tile rules server Seasons/SnowWorld visits with: snowfall raising a tile evenly to its
	caps (never into plants, torches or water, never past a column's cap, a capped column holding
	nobody back) and the thaw taking a layer off its deepest columns, back to air.
]]

return function(t, shared, require)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Crafting = require(shared.Crafting)
	local Weather = require(shared.Weather)
	local SnowLayers = require(shared.Seasons.SnowLayers)

	t.test("snow layers: ids and layers, eight blocks after everything before them", function()
		t.eq(SnowLayers.MAX, 8)
		local previous = nil
		for n = 1, 8 do
			local id = assert(SnowLayers.block(n))
			t.eq(Blocks.get(id).name, `SnowLayer{n}`)
			t.eq(SnowLayers.layers(id), n)
			t.eq(Blocks.layer(id), n)
			t.ok(SnowLayers.isLayer(id))
			if previous then
				t.eq(id, previous + 1, "consecutive ids")
			end
			previous = id
		end
		t.eq(SnowLayers.block(0), nil)
		t.eq(SnowLayers.block(9), nil)
		t.eq(SnowLayers.layers(Blocks.id.Snow), 0, "the snow block is no layer")
		t.eq(SnowLayers.layers(Blocks.AIR), 0)
		t.eq(SnowLayers.ITEM, Blocks.id.SnowLayer1)
	end)

	t.test("snow layers: 2 pixels a layer, colliding one layer lower; layer 1 walked through", function()
		for n = 1, 8 do
			local id = assert(SnowLayers.block(n))
			local def = Blocks.get(id)
			t.eq(def.render, "Transparent")
			t.eq(def.shape, nil, "no shape: boxes merge")
			t.eq(def.material, "Snow")
			t.eq(def.sound, "snow")
			t.eq(def.bounds.max[2], 2 * n, "bounds")
			local outline = Blocks.outline(id)
			if n < 8 then
				t.near(assert(outline)[5], n / 8, 1e-9, "the outline's top")
			else
				t.eq(outline, nil, "a full layer is aimed at as a whole block")
			end
			local collision = Blocks.collision(id)
			if n == 1 then
				t.eq(collision, false, "layer 1 has no collision box")
				t.ok(Blocks.isReplaceable(id), "and is replaceable")
				t.eq(Blocks.obstruction(id), nil)
				t.eq(Weather.blocksRain(id), false, "rain lands in it")
			else
				t.ok(type(collision) == "table", "a box")
				local box = (collision :: any)[1]
				t.near(box.maxY, (n - 1) / 8, 1e-9, "one layer lower than it looks")
				t.eq(box.minY, 0)
				t.eq(Blocks.isReplaceable(id), false)
				t.ok(Weather.blocksRain(id), "stops rain")
			end
			t.eq(Blocks.isSturdy(id), n == 8, "only the eighth is sturdy")
			t.eq(Blocks.isOpaque(id), false, "hides nothing")
			t.eq(Blocks.zombieBreak(id), 0)
		end
	end)

	t.test("snow layers: one appearance each, meshed with the rest, lowered by layerLut", function()
		local seen: { [number]: boolean } = {}
		for n = 1, 8 do
			local id = assert(SnowLayers.block(n))
			local appearance = Blocks.get(id).appearance
			t.ok(appearance > 0, "drawn")
			t.ok(not seen[appearance], "an appearance of its own")
			seen[appearance] = true
			t.eq(buffer.readu8(Blocks.layerLut, appearance), n)
			t.eq(buffer.readu8(Blocks.singleLut, appearance), 0, "merged like glass, not one part a cell")
			t.eq(buffer.readu8(Blocks.kindLut, appearance), Blocks.KIND_TRANSPARENT)
		end
		t.eq(buffer.readu8(Blocks.layerLut, Blocks.get(Blocks.id.Snow).appearance), 0)
	end)

	t.test("snow layers: the item, drops, recipe and textures", function()
		local item = Items.ofBlock(Blocks.id.SnowLayer1)
		t.ok(item ~= nil, "Snow Layer is an item")
		t.eq(Items.displayName(item :: number), "Snow Layer")
		for n = 2, 8 do
			local id = assert(SnowLayers.block(n))
			t.eq(Blocks.get(id).placeable, false)
			t.eq(Items.ofBlock(id), item, "places and drops as the Snow Layer")
		end
		for n = 1, 8 do
			local def = Blocks.get(assert(SnowLayers.block(n)))
			t.eq(def.drops, "Snowball")
			t.eq(def.dropCount, n, "a Snowball a layer")
			t.eq(def.tool, "shovel")
			t.eq(def.hardness, 0.1)
			t.ok(def.textures ~= nil and def.textures.top == "snow", "the snow texture")
		end
		local found = false
		for _, recipe in Crafting.recipes do
			if recipe.result == item and recipe.count == 6 then
				found = true
			end
		end
		t.ok(found, "three Snow blocks make six")
	end)

	t.test("snow layers: stacking, support and speed", function()
		for n = 1, 7 do
			t.eq(SnowLayers.stackOnto(assert(SnowLayers.block(n))), SnowLayers.block(n + 1))
		end
		t.eq(SnowLayers.stackOnto(assert(SnowLayers.block(8))), nil, "a full layer takes no more")
		t.eq(SnowLayers.stackOnto(Blocks.id.Stone), nil)
		t.eq(SnowLayers.stackOnto(Blocks.AIR), nil)
		t.ok(SnowLayers.supports(Blocks.id.Stone))
		t.ok(SnowLayers.supports(Blocks.id.Grass))
		t.ok(SnowLayers.supports(Blocks.id.Snow))
		t.ok(SnowLayers.supports(Blocks.id.OakLeaves), "leaves hold snow")
		t.ok(SnowLayers.supports(Blocks.id.Planks))
		t.ok(SnowLayers.supports(assert(SnowLayers.block(8))), "a full layer")
		for n = 1, 7 do
			t.eq(SnowLayers.supports(assert(SnowLayers.block(n))), false)
		end
		t.eq(SnowLayers.supports(Blocks.id.Ice), false, "never ice")
		t.eq(SnowLayers.supports(Blocks.id.PackedIce), false)
		t.eq(SnowLayers.supports(Blocks.AIR), false)
		t.eq(SnowLayers.supports(Blocks.id.Water), false)
		t.eq(SnowLayers.supports(Blocks.id.Torch), false)
		t.eq(SnowLayers.supports(Blocks.id.OakFence), false)
		local speeds = { 1, 1, 0.9, 0.9, 0.8, 0.8, 0.75, 0.75 }
		for n = 1, 8 do
			t.eq(SnowLayers.speedFactor(assert(SnowLayers.block(n))), speeds[n], `{n} layers`)
		end
		t.eq(SnowLayers.speedFactor(Blocks.id.Stone), 1)
		t.eq(Blocks.insulation(assert(SnowLayers.block(8))), 0.02, "a full layer is a wall")
		for n = 1, 7 do
			t.eq(Blocks.insulation(assert(SnowLayers.block(n))), nil, "a room's air passes")
		end
	end)

	t.test("snow layers: where a column's layers are, from its top cell", function()
		local AIR = Blocks.AIR
		t.eq(select(1, SnowLayers.layersAt(AIR, Blocks.id.Grass)), 0)
		local n, dy = SnowLayers.layersAt(assert(SnowLayers.block(1)), Blocks.id.Grass)
		t.eq(n, 1)
		t.eq(dy, 0, "a single layer stops no rain: it is in the top cell")
		for layers = 2, 8 do
			n, dy = SnowLayers.layersAt(AIR, assert(SnowLayers.block(layers)))
			t.eq(n, layers)
			t.eq(dy, -1, "deeper snow stops rain: it is just below the top cell")
		end
		t.eq(#SnowLayers.accumulate({}), 0, "no columns, nothing")
		t.eq(#SnowLayers.melt({}), 0)
	end)

	local AIR, GRASS = Blocks.AIR, Blocks.id.Grass
	local FLOOR = 10

	--[[
		A tile's columns from per-column layers (0..8; "plant", "torch", "water", "ice" or "none":
		unloaded) over grass with its top at FLOOR, each with `cap` (or caps[i]).
	]]
	local function tile(layers: { any }, cap: number | { number }): { SnowLayers.Column }
		local columns = {}
		for i, n in layers do
			local x, z = (i - 1) % 4, (i - 1) // 4
			local c = if type(cap) == "table" then cap[i] else cap
			local column: SnowLayers.Column
			if n == "none" then
				column = { x = x, z = z, top = nil, atTop = AIR, below = AIR, cap = c }
			elseif n == "plant" or n == "torch" then
				local block = if n == "plant" then Blocks.id.Poppy else Blocks.id.Torch
				column = { x = x, z = z, top = FLOOR, atTop = block, below = GRASS, cap = c }
			elseif n == "water" or n == "ice" then
				local block = if n == "water" then Blocks.fluidId("Water", 0) else Blocks.id.Ice
				column = { x = x, z = z, top = FLOOR, atTop = AIR, below = block, cap = c }
			elseif n == 0 then
				column = { x = x, z = z, top = FLOOR, atTop = AIR, below = GRASS, cap = c }
			elseif n == 1 then
				column = { x = x, z = z, top = FLOOR, atTop = assert(SnowLayers.block(1)), below = GRASS, cap = c }
			else
				-- (Layers 2+ stop rain: the top cell is the one above them.)
				column = { x = x, z = z, top = FLOOR + 1, atTop = AIR, below = assert(SnowLayers.block(n)), cap = c }
			end
			table.insert(columns, column)
		end
		return columns
	end
	-- Applies `changes` to the columns as SnowWorld's writes would, and returns each one's layers.
	local function apply(columns: { SnowLayers.Column }, changes: { SnowLayers.Change }): { number }
		for _, change in changes do
			for _, column in columns do
				if column.x == change.x and column.z == change.z then
					local n = SnowLayers.layers(change.block)
					t.eq(change.y, FLOOR, "the layers stay in the floor's top cell")
					if n >= 2 then
						column.top, column.atTop, column.below = FLOOR + 1, AIR, change.block
					else
						column.top, column.atTop, column.below = FLOOR, change.block, GRASS
					end
				end
			end
		end
		local out = {}
		for i, column in columns do
			out[i] = (SnowLayers.column(column))
		end
		return out
	end
	t.test("snow layers: a column's snow, and a layer less", function()
		local columns = tile({ 0, 1, 5, "plant", "torch", "water", "ice", "none" }, 3)
		local function info(i: number): string
			local n, y, takes = SnowLayers.column(columns[i])
			return `{n} {y} {takes}`
		end
		t.eq(info(1), `0 {FLOOR} true`, "bare grass takes a first layer in its top cell")
		t.eq(info(2), `1 {FLOOR} true`, "a single layer is in the top cell")
		t.eq(info(3), `5 {FLOOR} true`, "five layers just below the top cell")
		t.eq(info(4), `0 {FLOOR} false`, "a plant takes no snow")
		t.eq(info(5), `0 {FLOOR} false`, "nor does a torch")
		t.eq(info(6), `0 {FLOOR} false`, "nor water")
		t.eq(info(7), `0 {FLOOR} false`, "nor ice")
		t.eq(info(8), "0 0 false", "an unloaded column has none")
		t.eq(SnowLayers.lessOne(assert(SnowLayers.block(1))), AIR)
		for n = 2, 8 do
			t.eq(SnowLayers.lessOne(assert(SnowLayers.block(n))), SnowLayers.block(n - 1))
		end
		t.eq(SnowLayers.lessOne(Blocks.id.Snow), nil, "the snow block is no layer")
		t.eq(SnowLayers.lessOne(AIR), nil)
	end)

	t.test("snow layers: snowfall raises a tile evenly to its caps, never into plants", function()
		local columns = tile({ 0, 0, 0, 0, 0, "plant", 0, 0, 0, "water", 0, 0, 0, 0, "torch", 0 }, 3)
		local visits = 0
		local layers: { number } = {}
		repeat
			local changes = SnowLayers.accumulate(columns)
			visits += 1
			for _, change in changes do
				t.ok(SnowLayers.isLayer(change.block), "only snow layers are set")
			end
			layers = apply(columns, changes)
			-- (Every column that takes snow has the same layers after every visit.)
			local first = layers[1]
			for i, n in layers do
				if i ~= 6 and i ~= 10 and i ~= 15 then
					t.eq(n, first, `column {i} rises with the rest`)
				end
			end
		until #changes == 0 or visits > 20
		t.eq(visits, 4, "three visits to the cap of 3, then nothing")
		t.eq(layers[1], 3)
		t.eq(layers[6], 0, "the plant's column")
		t.eq(columns[6].atTop, Blocks.id.Poppy, "the plant is still there")
		t.eq(layers[10], 0, "water")
		t.eq(layers[15], 0, "the torch's")
		t.eq(#SnowLayers.accumulate(tile({ 0, 0 }, 0)), 0, "a cap of 0 (dry biomes): none")
	end)

	t.test("snow layers: the least column rises first; a capped column holds nobody back", function()
		-- A drift: caps 2..4; a column already at 3 waits for the others.
		local columns = tile({ 0, 1, 3, 0 }, { 4, 4, 4, 2 })
		local history = {}
		for _ = 1, 8 do
			table.insert(history, table.concat(apply(columns, SnowLayers.accumulate(columns)), ","))
		end
		t.eq(history[1], "1,1,3,1", "the bare ones first")
		t.eq(history[2], "2,2,3,2")
		t.eq(history[3], "3,3,3,2", "the column capped at 2 stops")
		t.eq(history[4], "4,4,4,2", "and holds the rest back no longer")
		t.eq(history[5], "4,4,4,2", "every cap reached")
		-- Never past 8, whatever the cap.
		local deep = tile({ 7, 8 }, { 8, 8 })
		local changes = SnowLayers.accumulate(deep)
		t.eq(#changes, 1)
		t.eq(changes[1].block, SnowLayers.block(8))
		t.eq(#SnowLayers.accumulate(tile({ 8 }, { 8 })), 0)
	end)

	t.test("snow layers: the thaw takes a layer off the deepest columns, down to air", function()
		local columns = tile({ 3, 1, 2, 0, "plant" }, 8)
		local seen = {}
		for _ = 1, 6 do
			table.insert(seen, table.concat(apply(columns, SnowLayers.melt(columns)), ","))
		end
		t.eq(seen[1], "2,1,2,0,0", "only the deepest loses one")
		t.eq(seen[2], "1,1,1,0,0")
		t.eq(seen[3], "0,0,0,0,0", "single layers go back to air")
		t.eq(seen[4], "0,0,0,0,0", "nothing left to melt")
		local melted = SnowLayers.melt(tile({ 1 }, 3))
		t.eq(melted[1].block, AIR, "one layer melts to air")
		t.eq(melted[1].y, FLOOR, "in its own cell")
		local one = SnowLayers.meltColumn(tile({ 5 }, 3)[1])
		t.ok(one ~= nil and one.block == SnowLayers.block(4) and one.y == FLOOR, "one column alone")
		t.eq(SnowLayers.meltColumn(tile({ 0 }, 3)[1]), nil)
	end)
end
