--[[
	Snow layers (BlockList SnowLayer1 .. 8, Shared/Seasons/SnowLayers): the ids and their layers, the
	blocks' shapes (bounds, collision one layer lower, layer 1 replaceable and walked through, the
	eighth sturdy), their appearances (one each, never single: they merge), drops, the Snow Layer
	item and its recipe, stacking, what snow lies on, speed factors and where a column's layers are.
	The tile rules (accumulate, melt) come with the snow itself.
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
		t.eq(#SnowLayers.accumulate({}), 0, "the tile rules come with the snow")
		t.eq(#SnowLayers.melt({}), 0)
	end)
end
