--[[
	WAILA's content (Ui/WailaInfo): names, icons, the harvest line with its check / cross for the
	held item, the extended (F3) lines, fluids, dropped items, players, and the ray / box test used
	to aim at entities.
]]

return function(t, shared, require, _server, client)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Mining = require(shared.Mining)
	local Biomes = require(shared.Biomes)
	local WailaInfo = require(client.Ui.WailaInfo)

	local B = Blocks.id
	local I = Items.id

	-- Every line's text, joined by " | ".
	local function joined(info): string
		return table.concat(WailaInfo.texts(info), " | ")
	end

	local function has(info, text: string, what: string)
		for _, line in WailaInfo.texts(info) do
			if line == text then
				return
			end
		end
		error(`{what}: no line "{text}" in: {joined(info)}`, 2)
	end

	local function hasNot(info, pattern: string, what: string)
		for _, line in WailaInfo.texts(info) do
			if string.find(line, pattern, 1, true) then
				error(`{what}: unexpected "{line}" in: {joined(info)}`, 2)
			end
		end
	end

	t.test("waila: a block's name, icon and Jade's blue italic mod name last", function()
		local info = WailaInfo.block(B.Stone, nil, 0, 64, 0, false)
		t.eq(WailaInfo.text(info.lines[1]), "Stone", "name")
		t.eq(info.lines[1][1].colour, "white", "name colour")
		local last = info.lines[#info.lines]
		t.eq(WailaInfo.text(last), "IceVoxel", "mod name")
		t.eq(last[1].colour, "blue", "mod name colour")
		t.ok(last[1].italic, "mod name italic")
		t.eq(info.icon and info.icon.item, I.Stone, "icon is the block's item")
		t.eq(info.progress, nil, "no progress")
		-- Names players know: display names, variants by their own name.
		t.eq(
			WailaInfo.text(WailaInfo.block(B.CoalBlock, nil, 0, 0, 0, false).lines[1]),
			"Block of Coal",
			"display name"
		)
		t.eq(WailaInfo.text(WailaInfo.block(B.OakLog, nil, 0, 0, 0, false).lines[1]), "Oak Log", "spaced name")
		local wall = WailaInfo.block(B.WallTorchNorth, nil, 0, 0, 0, false)
		t.eq(WailaInfo.text(wall.lines[1]), "Wall Torch", "wall torch")
		t.eq(wall.icon and wall.icon.item, I.Torch, "a wall torch shows the Torch")
		t.eq(WailaInfo.blockName(B.HangingLantern), "Lantern", "hanging lantern")
	end)

	t.test("waila: containers name their size; menus show nothing more", function()
		local chest = WailaInfo.block(B.Chest, nil, 0, 0, 0, false)
		t.eq(WailaInfo.text(chest.lines[1]), "Chest (27 slots)", "chest")
		t.eq(chest.lines[1][2].colour, "gray", "slots in gray")
		t.eq(WailaInfo.text(WailaInfo.block(B.Furnace, nil, 0, 0, 0, false).lines[1]), "Furnace", "furnace")
		t.eq(
			WailaInfo.text(WailaInfo.block(B.CraftingTable, nil, 0, 0, 0, false).lines[1]),
			"Crafting Table",
			"crafting table"
		)
	end)

	t.test("waila: the harvest line checks the held item's tool and tier", function()
		local C, X = WailaInfo.CHECK, WailaInfo.CROSS
		-- Stone needs any pickaxe.
		has(WailaInfo.block(B.Stone, nil, 0, 0, 0, false), `{X} Requires Wooden Pickaxe`, "stone by hand")
		has(WailaInfo.block(B.Stone, I.WoodenPickaxe, 0, 0, 0, false), `{C} Requires Wooden Pickaxe`, "stone, wood")
		has(WailaInfo.block(B.Stone, I.GoldenPickaxe, 0, 0, 0, false), `{C} Requires Wooden Pickaxe`, "stone, gold")
		has(WailaInfo.block(B.Stone, I.WoodenShovel, 0, 0, 0, false), `{X} Requires Wooden Pickaxe`, "stone, shovel")
		-- Iron ore a stone one, diamonds an iron one.
		has(WailaInfo.block(B.IronOre, I.WoodenPickaxe, 0, 0, 0, false), `{X} Requires Stone Pickaxe`, "iron, wood")
		has(WailaInfo.block(B.IronOre, I.StonePickaxe, 0, 0, 0, false), `{C} Requires Stone Pickaxe`, "iron, stone")
		has(WailaInfo.block(B.DiamondOre, I.StonePickaxe, 0, 0, 0, false), `{X} Requires Iron Pickaxe`, "diamond")
		has(WailaInfo.block(B.DiamondOre, I.DiamondPickaxe, 0, 0, 0, false), `{C} Requires Iron Pickaxe`, "diamond+")
		-- The mark's colour is drawn by the panel; the line carries the result.
		local line = WailaInfo.harvest(B.DiamondOre, nil)
		t.ok(line ~= nil and line[1].mark == false, "cross")
		-- Any hand harvests dirt and logs; the tool only mines faster.
		has(WailaInfo.block(B.Dirt, nil, 0, 0, 0, false), `{C} Tool: Shovel`, "dirt")
		has(WailaInfo.block(B.OakLog, nil, 0, 0, 0, false), `{C} Tool: Axe`, "log")
		-- No tool matters for glass or a torch; bedrock can't be broken.
		t.eq(WailaInfo.harvest(B.Glass, nil), nil, "glass")
		t.eq(WailaInfo.harvest(B.Torch, nil), nil, "torch")
		has(WailaInfo.block(B.Bedrock, nil, 0, 0, 0, false), "Unbreakable", "bedrock")
		-- Fluids have no harvest line.
		t.eq(WailaInfo.harvest(B.Water, nil), nil, "water")
		t.eq(WailaInfo.toolName("pickaxe", 3), "Diamond Pickaxe", "tool names")
	end)

	t.test("waila: the normal view keeps the F3 details out", function()
		local info = WailaInfo.block(B.Stone, I.WoodenPickaxe, 12, 64, -5, false)
		t.eq(#info.lines, 3, "name, harvest, mod name")
		hasNot(info, "#", "no ids")
		hasNot(info, "Position", "no position")
		hasNot(info, "Hardness", "no hardness")
	end)

	t.test("waila: F3 adds id, position, chunk, biome, hardness, tool, drops, time, light, render", function()
		local info = WailaInfo.block(B.Stone, I.WoodenPickaxe, 12, 64, -5, true, { biome = "Plains" })
		has(info, `Stone #{B.Stone}`, "name and id")
		has(info, "Position 12, 64, -5", "position")
		-- Chunks are floored: z = -5 is in chunk -1, at 11.
		has(info, "Chunk 0, -1 (local 12, 11)", "chunk")
		has(info, "Biome Plains", "biome")
		has(info, "Hardness 1.5", "hardness")
		has(info, "Tool pickaxe, level 0", "tool")
		has(info, "Drops with Wooden Pickaxe: Cobblestone", "drops held")
		has(info, "Drops by hand: nothing", "drops by hand")
		-- Stone with a wooden pickaxe: 1.5 hardness, speed 2 -> 23 ticks.
		local ticks = Mining.ticks(B.Stone, true, false, I.WoodenPickaxe)
		t.eq(ticks, 23, "ticks")
		has(info, "Breaks in 1.15 s (23 ticks)", "break time")
		has(info, "Light 0", "light")
		has(info, "Render Opaque, solid, friction 0.6", "render")
		t.eq(WailaInfo.text(info.lines[1]), "Stone", "still named first")
		t.eq(WailaInfo.text(info.lines[#info.lines]), "IceVoxel", "mod name still last")
		-- By hand only one drops line, and stone takes 150 ticks (it needs a pickaxe: / 100).
		local hand = WailaInfo.block(B.Stone, nil, -1, 0, -17, true)
		has(hand, "Drops by hand: nothing", "by hand")
		hasNot(hand, "Drops with", "no held drops line")
		has(hand, "Breaks in 7.5 s (150 ticks)", "by hand time")
		-- At the player's own speed (Mining.playerFactor: Haste, Mining Fatigue, the perks).
		local hasted = WailaInfo.block(B.Stone, I.WoodenPickaxe, 0, 0, 0, true, { miningFactor = 2 })
		local fast = Mining.ticks(B.Stone, true, false, I.WoodenPickaxe, 2)
		t.ok(fast < ticks, "faster")
		has(hasted, `Breaks in {fast / 20} s ({fast} ticks)`, "with the player's mining factor")
		has(hand, "Chunk -1, -2 (local 15, 15)", "negative chunk")
		hasNot(hand, "Biome", "no biome without one")
	end)

	t.test("waila: F3 details of lights, drops counts, menus and unbreakable blocks", function()
		local torch = WailaInfo.block(B.Torch, nil, 0, 0, 0, true)
		has(torch, "Light 14", "torch light")
		has(torch, "Breaks at once", "hardness 0")
		has(torch, "Drops by hand: Torch", "torch drops")
		has(torch, "Render Transparent, not solid, friction 0.6", "torch render")
		has(torch, "Tool none", "no tool")
		has(WailaInfo.block(B.GlowBlock, nil, 0, 0, 0, true), "Drops by hand: Glow Dust x4", "glowstone")
		has(WailaInfo.block(B.GlowBlock, nil, 0, 0, 0, true), "Light 15", "glowstone light")
		has(WailaInfo.block(B.Chest, nil, 0, 0, 0, true), "Menu Chest, 27 slots", "chest menu")
		has(WailaInfo.block(B.CraftingTable, nil, 0, 0, 0, true), "Menu Crafting", "crafting menu")
		has(WailaInfo.block(B.Dirt, nil, 0, 0, 0, true), "Tool shovel, any level", "tool without a tier")
		has(WailaInfo.block(B.Ice, nil, 0, 0, 0, true), "Render Opaque, solid, friction 0.98", "ice friction")
		local bedrock = WailaInfo.block(B.Bedrock, nil, 0, 0, 0, true)
		has(bedrock, "Hardness unbreakable", "bedrock hardness")
		hasNot(bedrock, "Drops", "bedrock drops nothing to say")
		hasNot(bedrock, "Breaks", "bedrock never breaks")
		-- Bedrock is no item: its icon is a box in its colour.
		local icon = bedrock.icon
		t.ok(icon ~= nil and icon.item == nil and icon.colour ~= nil, "colour icon")
	end)

	t.test("waila: F3 drops of plants; a tall plant's top shows what breaking it harvests", function()
		-- Breaking either half harvests the lower half once (server EditRules.harvested).
		local top = WailaInfo.block(B.SunflowerTop, nil, 0, 11, 0, true)
		t.eq(WailaInfo.text(top.lines[1]), "Sunflower", "named as the plant")
		has(top, "Drops by hand: Sunflower", "a sunflower's top")
		local grass = WailaInfo.block(B.TallGrassTop, I.Shears, 0, 11, 0, true)
		has(grass, "Drops with Shears: Short Grass x2", "tall grass's top with Shears")
		has(grass, "Drops by hand: nothing", "tall grass's top by hand")
		has(WailaInfo.block(B.TallGrass, I.Shears, 0, 10, 0, true), "Drops with Shears: Short Grass x2", "lower half")
		has(WailaInfo.block(B.LargeFernTop, I.Shears, 0, 11, 0, true), "Drops with Shears: Fern x2", "large fern")
		has(WailaInfo.block(B.ShortGrass, nil, 0, 10, 0, true), "Drops by hand: nothing", "short grass by hand")
		has(WailaInfo.block(B.DeadBush, nil, 0, 10, 0, true), "Drops by hand: Stick", "dead bush by hand")
		has(WailaInfo.block(B.OakLeaves, I.Shears, 0, 10, 0, true), "Drops with Shears: Oak Leaves", "leaves")
	end)

	t.test("waila: fluids are named by their group and show their level with F3", function()
		local source = WailaInfo.block(B.Water, nil, 3, 60, 4, false)
		t.eq(WailaInfo.text(source.lines[1]), "Water", "source")
		t.eq(#source.lines, 2, "name and mod name")
		t.eq(source.icon and source.icon.item, I.Water, "water's icon")
		local flowing = Blocks.fluidId("Water", 3)
		local falling = Blocks.fluidId("Water", 8)
		t.eq(WailaInfo.text(WailaInfo.block(flowing, nil, 0, 0, 0, false).lines[1]), "Water", "flowing name")
		t.eq(WailaInfo.block(flowing, nil, 0, 0, 0, false).icon.item, I.Water, "flowing icon")
		has(WailaInfo.block(B.Water, nil, 0, 0, 0, true), "Fluid Water, source", "source level")
		has(WailaInfo.block(flowing, nil, 0, 0, 0, true), "Fluid Water, flowing 3", "flowing level")
		has(WailaInfo.block(falling, nil, 0, 0, 0, true), "Fluid Water, falling", "falling")
		local extended = WailaInfo.block(flowing, nil, 0, 0, 0, true)
		hasNot(extended, "Hardness", "no hardness for fluids")
		hasNot(extended, "Drops", "no drops for fluids")
		has(extended, "Render Fluid, not solid, friction 0.6", "fluid render")
		t.eq(WailaInfo.fluidState(B.Stone), nil, "not a fluid")
	end)

	t.test("waila: mining progress travels with the block's info", function()
		local info = WailaInfo.block(B.Stone, nil, 0, 0, 0, false, { progress = 0.45 })
		t.eq(info.progress, 0.45, "progress")
		t.eq(#info.lines, 3, "no extra text line")
	end)

	t.test("waila: every block builds in both views, held or not", function()
		for id = 0, Blocks.count - 1 do
			-- (0 = bare hands: a nil in a list would be skipped.)
			for _, item in { 0, I.DiamondPickaxe, I.Stick } do
				local held = if item == 0 then nil else item
				for _, extended in { false, true } do
					local info = WailaInfo.block(id, held, -7, 12, 300, extended, { biome = "Plains" })
					t.ok(#info.lines >= 2, `block {id} has lines`)
					t.ok(info.icon ~= nil, `block {id} has an icon`)
					t.eq(WailaInfo.text(info.lines[#info.lines]), "IceVoxel", `block {id} mod name`)
					for _, line in info.lines do
						for _, segment in line do
							t.ok(type(segment.text) == "string", `block {id} text`)
						end
					end
				end
			end
		end
	end)

	t.test("waila: dropped items and players", function()
		local single = WailaInfo.item(I.Stick, 1, false)
		t.eq(joined(single), "Stick | IceVoxel", "one stick")
		t.eq(single.icon and single.icon.item, I.Stick, "item icon")
		local stack = WailaInfo.item(I.Cobblestone, 12, true, 7, 1.25, 64, -3.5)
		t.eq(WailaInfo.text(stack.lines[1]), "Cobblestone x12", "stack")
		has(stack, `Cobblestone #{I.Cobblestone}`, "item id")
		has(stack, "Item entity 7", "entity id")
		has(stack, "Position 1.25, 64.00, -3.50", "position")

		local facts = {
			displayName = "Steve",
			name = "steve_1",
			userId = 42,
			health = 75,
			maxHealth = 100,
			gameMode = "Survival",
			x = 10.7,
			y = 64,
			z = -0.2,
		}
		local info = WailaInfo.player(facts, false)
		t.eq(joined(info), "Steve @steve_1 | Health 15 / 20 | Survival | IceVoxel", "player")
		t.eq(info.icon and info.icon.userId, 42, "head icon")
		local extended = WailaInfo.player(facts, true)
		has(extended, "User 42", "user id")
		has(extended, "Position 10, 64, -1", "feet block")
		-- Health rounds up like the HUD's hearts.
		t.eq(WailaInfo.healthPoints(0.1, 100), 1, "a sliver is half a heart")
		t.eq(WailaInfo.healthPoints(0, 100), 0, "dead")
		t.eq(WailaInfo.healthPoints(5, 0), 0, "no max")
		facts.name = "Steve"
		t.eq(WailaInfo.text(WailaInfo.player(facts, false).lines[1]), "Steve", "same names once")
	end)

	t.test("waila: rays enter boxes at the right distance", function()
		-- Straight along +X into a box from 2 to 3.
		t.near(WailaInfo.rayBox(0, 0.5, 0.5, 1, 0, 0, 2, 0, 0, 3, 1, 1) :: number, 2, 1e-9, "along x")
		-- Direction length does not matter.
		t.near(WailaInfo.rayBox(0, 0.5, 0.5, 5, 0, 0, 2, 0, 0, 3, 1, 1) :: number, 2, 1e-9, "scaled")
		-- Diagonal: enters the box (1..2)^3 from the origin at sqrt(3).
		t.near(WailaInfo.rayBox(0, 0, 0, 1, 1, 1, 1, 1, 1, 2, 2, 2) :: number, math.sqrt(3), 1e-9, "diagonal")
		t.eq(WailaInfo.rayBox(0, 0.5, 0.5, -1, 0, 0, 2, 0, 0, 3, 1, 1), nil, "behind")
		t.eq(WailaInfo.rayBox(0, 2, 0.5, 1, 0, 0, 2, 0, 0, 3, 1, 1), nil, "above")
		t.eq(WailaInfo.rayBox(0, 0.5, 0.5, 1, 0.6, 0, 2, 0, 0, 3, 1, 1), nil, "rises past it")
		t.eq(WailaInfo.rayBox(2.5, 0.5, 0.5, 0, 1, 0, 2, 0, 0, 3, 1, 1), 0, "inside")
		t.eq(WailaInfo.rayBox(0, 0, 0, 0, 0, 0, 2, 0, 0, 3, 1, 1), nil, "no direction")
	end)

	t.test("waila: an entity wins only in front of the block and not behind any block", function()
		local choose = WailaInfo.choose
		-- Nothing on the aim.
		t.eq(choose(nil, false, nil, nil, false), nil, "nothing")
		-- A block in reach; an item in front of it wins, one behind it doesn't.
		t.eq(choose(3, false, nil, 3, false), "block", "block")
		t.eq(choose(3, false, 2, 3, false), "entity", "item in front")
		t.eq(choose(3, false, 4, 3, false), "block", "item behind")
		t.eq(choose(3, false, 3, 3, false), "block", "a tie goes to the block")
		-- While mining, the mined block stays even with an item in front of it.
		t.eq(choose(3, true, 2, 3, false), "block", "mining")
		-- No block in reach: the entity shows, unless a block too far to target hides it.
		t.eq(choose(nil, false, 5, nil, false), "entity", "open air")
		t.eq(choose(nil, false, 5, 6, false), "entity", "the wall is behind")
		t.eq(choose(nil, false, 5, 4.5, false), nil, "behind an out-of-reach wall")
		-- Water only without a block in reach; an entity in front of it wins.
		t.eq(choose(nil, false, nil, nil, true), "fluid", "water")
		t.eq(choose(3, false, nil, 3, true), "block", "block over water")
		t.eq(choose(nil, false, 2, nil, true), "entity", "item over water")
		t.eq(choose(nil, false, 5, 4.5, true), "fluid", "a hidden item leaves the water")
	end)

	t.test("waila: the panel stays centred, out of the minimap and right of the F3 text", function()
		local function screen(width: number, scale: number, avoid: number?, touch: boolean?)
			return {
				width = width,
				height = 1000,
				scale = scale,
				touch = touch == true,
				top = 4,
				margin = 8,
				rightReserve = 216,
				avoidLeft = avoid,
			}
		end
		-- 230 x 36 at scale 3 is 690 pixels: centred on a 1920 pixel screen.
		local scale, shift = WailaInfo.placement(screen(1920, 3), 230, 36)
		t.eq(scale, 3, "HUD scale")
		t.eq(shift, 0, "centred")
		-- A small phone: centred it would cover the minimap (right edge 506 > 667 - 216), so it
		-- moves left until it clears it.
		scale, shift = WailaInfo.placement(screen(667, 1.5, nil, true), 230, 36)
		t.eq(scale, 1.5, "touch scale kept")
		local left = (667 - 345) / 2 + shift
		t.near(left + 345, 667 - 216, 0.5, "clear of the minimap")
		t.ok(left >= 8, "on screen")
		-- F3 open: right of the debug text on a wide screen (centred left 330 < 400) ...
		scale, shift = WailaInfo.placement(screen(1600, 3, 400), 310, 156)
		t.eq(scale, 3, "F3 scale")
		t.eq(shift, 400 - (1600 - 930) / 2, "right of the F3 text")
		-- ... but never into the minimap: 1366 has 1150 pixels left of it, the panel is 930.
		scale, shift = WailaInfo.placement(screen(1366, 3, 400), 310, 156)
		t.eq((1366 - 930) / 2 + shift + 930, 1366 - 216, "the minimap first")
		-- Too wide for the room left of the minimap: drawn smaller, a whole scale on desktops ...
		scale, shift = WailaInfo.placement(screen(800, 2, 400), 310, 156)
		t.eq(scale, 1, "whole scale")
		t.ok((800 - 310) / 2 + shift >= 8, "on screen")
		t.ok((800 - 310) / 2 + shift + 310 <= 800 - 216, "clear of the minimap")
		-- ... eighths on touch screens, at least half size.
		scale = WailaInfo.placement(screen(500, 2, nil, true), 230, 36)
		t.eq(scale, math.floor((500 - 216 - 8) / 230 * 8) / 8, "eighths")
		scale = WailaInfo.placement(screen(100, 2, nil, true), 230, 36)
		t.eq(scale, 0.5, "half size at least")
		-- A phone held upright has 174 - 8 pixels left of the minimap: 0.625 would be too small to
		-- read, so the panel keeps its scale and goes over the minimap's corner, at the left edge.
		scale, shift = WailaInfo.placement(screen(390, 1.125, nil, true), 230, 36)
		t.eq(scale, 1.125, "readable scale kept")
		t.near((390 - 230 * 1.125) / 2 + shift, 8, 0.5, "at the left edge")
		-- Too tall: 1000 - 4 - 8 = 988 pixels for 400 GUI pixels -> 2.
		local tall = screen(4000, 3)
		scale = WailaInfo.placement(tall, 230, 400)
		t.eq(scale, 2, "fits the height")
		-- Without a minimap only the margin is kept; an empty panel keeps the scale.
		local open = screen(700, 3)
		open.rightReserve = 0
		scale, shift = WailaInfo.placement(open, 228, 36)
		t.eq(scale, 3, "684 pixels fit in 700 - 16")
		t.eq(shift, 0, "centred")
		t.eq((WailaInfo.placement(open, 0, 0)), 3, "empty panel")
	end)

	t.test("waila: italics shear whole pixels, right at the top and left at the bottom", function()
		local shifts = WailaInfo.italicShifts(5)
		t.eq(#shifts, 5, "strips")
		t.eq(table.concat(shifts, " "), "1 0 0 -1 -1", "shifts")
		for _, shift in shifts do
			t.eq(shift, math.floor(shift), "whole pixels")
		end
	end)

	t.test("waila: the light level where a mob would stand, coloured for spawning", function()
		local function text(line): string
			local parts = {}
			for _, segment in line do
				table.insert(parts, segment.text)
			end
			return table.concat(parts)
		end
		local dark = WailaInfo.lightLine({ block = 0, sky = 0 }, false)
		t.eq(text(dark), "Light level 0")
		t.eq(dark[1].colour, "red", "monsters may spawn at any time")
		local open = WailaInfo.lightLine({ block = 0, sky = 15 }, false)
		t.eq(text(open), "Light level 15")
		t.eq(open[1].colour, "yellow", "at night")
		local torch = WailaInfo.lightLine({ block = 12, sky = 3 }, true)
		t.eq(text(torch), "Light level 12 (block 12, sky 3)")
		t.eq(torch[1].colour, "green")
		-- In the panel after the harvest line; none without the facts (an unloaded cell).
		local function has(info, wanted: string): boolean
			for _, line in info.lines do
				if text(line) == wanted then
					return true
				end
			end
			return false
		end
		t.ok(has(WailaInfo.block(B.Stone, nil, 0, 5, 0, false, { light = { block = 7, sky = 0 } }), "Light level 7"))
		t.ok(not has(WailaInfo.block(B.Stone, nil, 0, 5, 0, false), "Light level 0"))
	end)

	t.test("waila: biome names", function()
		for index, biome in Biomes.list do
			t.ok(not string.find(WailaInfo.biomeName(index), "%l%u"), `{biome.name} spaced`)
		end
		local birch = table.find(
			(function()
				local names = {}
				for _, biome in Biomes.list do
					table.insert(names, biome.name)
				end
				return names
			end)(),
			"BirchForest"
		)
		t.ok(birch ~= nil, "a birch forest exists")
		t.eq(WailaInfo.biomeName(birch :: number), "Birch Forest", "spaced")
		t.eq(WailaInfo.biomeName(10000), "?", "unknown")
	end)
end
