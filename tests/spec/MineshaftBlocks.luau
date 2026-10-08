--[[
	Ladders, rope and the mineshafts' blocks as data and rules (the foundation the climbing and
	the generation build on): the new blocks and their cave twins, what is climbable and what
	slows (cobwebs), placing ladders on walls, rails along the player's facing and rope under a
	ceiling or a rope (Blocks.placementFor), the chain rule (a rope under a rope, a vine under a
	vine: Blocks.canSurvive), turning them with structures, cobweb harvesting (swords and Shears),
	recipes and fuel, sound types, texture pack entries, the Iron Age's rails, fire odds, moss as
	soil, and the server's Attached behaviour bringing a hanging rope down when its ceiling goes.
]]

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Crafting = require(shared.Crafting)
	local Smelting = require(shared.Crafting.Smelting)
	local Mining = require(shared.Mining)
	local Progression = require(shared.Progression)
	local TexturePack = require(shared.TexturePack)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local WorldServer = require(server.World.WorldServer)
	local BlockTicker = require(server.World.BlockTicker)
	local Behaviours = require(server.Behaviours)
	local Drops = require(server.Behaviours.Drops)

	local B, I = Blocks.id, Items.id
	local AIR, STONE = Blocks.AIR, B.Stone

	-- A sparse world for the pure helpers: unset blocks are air, `false` = not loaded.
	local function sparse(blocks: { [string]: number | false })
		return function(x: number, y: number, z: number): number?
			local b = blocks[`{x},{y},{z}`]
			if b == false then
				return nil
			end
			return b or AIR
		end
	end

	-- The crafting result of a 3 x 3 grid ({ [slot] = item id }).
	local function craft(cells: { [number]: number }): Items.Stack?
		local grid = {}
		for slot, item in cells do
			grid[slot] = { item = item, count = 1 }
		end
		return Crafting.match(grid, 3)
	end

	local PLAIN = {
		"Ladder",
		"LadderSouth",
		"LadderWest",
		"LadderEast",
		"Rope",
		"Rail",
		"RailEastWest",
		"OakFence",
		"Cobweb",
		"MossBlock",
		"MossCarpet",
		"Vine",
		"VineNorth",
		"VineWest",
		"VineEast",
		"HangingRoots",
		"MossyCobblestone",
	}
	local TWINS = {
		CaveWallTorchNorth = "WallTorchNorth",
		CaveWallTorchSouth = "WallTorchSouth",
		CaveWallTorchWest = "WallTorchWest",
		CaveWallTorchEast = "WallTorchEast",
		CaveRail = "Rail",
		CaveRailEastWest = "RailEastWest",
		CaveOakFence = "OakFence",
		CaveCobweb = "Cobweb",
		CaveMossCarpet = "MossCarpet",
		CaveVine = "Vine",
		CaveVineNorth = "VineNorth",
		CaveVineWest = "VineWest",
		CaveVineEast = "VineEast",
		CaveHangingRoots = "HangingRoots",
	}

	t.test("mineshaft blocks: appended after White Wool, the twins after them, items and variants", function()
		local last = B.WhiteWool
		t.eq(last, 212, "White Wool was the last block")
		for index, name in PLAIN do
			t.eq(B[name], last + index, `{name} id`)
			t.ok(not Blocks.isCaveTwin(B[name]), `{name} is no twin`)
		end
		t.eq(Blocks.count, 244, "17 blocks and 14 twins")
		for twin, of in TWINS do
			local id = B[twin]
			t.ok(id > B.MossyCobblestone, `{twin} comes after the plain blocks`)
			t.eq(Blocks.caveTwinOf(id), B[of], `{twin} twins {of}`)
			t.eq(Blocks.caveTwinFor(B[of]), id)
			t.eq(Blocks.get(id).appearance, Blocks.get(B[of]).appearance, `{twin} looks like {of}`)
			t.ok(not Blocks.get(id).placeable, `{twin} is never placed`)
			t.eq(Items.ofBlock(id), Items.ofBlock(B[of]), `{twin} is {of}'s item`)
			t.eq(TexturePack.Blocks[twin], nil, `{twin} has no texture entry`)
			t.eq(Blocks.get(id).textures, Blocks.get(B[of]).textures, `{twin} takes {of}'s textures`)
		end
		-- No twin for ladders and rope: generation places rope only in the open shaft.
		for _, name in { "Ladder", "LadderEast", "Rope", "MossBlock", "MossyCobblestone" } do
			t.eq(Blocks.caveTwinFor(B[name]), nil, `{name} has no twin`)
		end
		-- One item each: the ladders, rails and vines are variants of their first block.
		for _, name in { "Ladder", "Rope", "Rail", "OakFence", "Cobweb", "MossBlock", "MossCarpet", "Vine" } do
			t.ok(Blocks.get(B[name]).placeable and Items.get(B[name]) ~= nil, `{name} is an item`)
		end
		t.ok(Items.get(B.HangingRoots) ~= nil and Items.get(B.MossyCobblestone) ~= nil)
		t.eq(#Blocks.variants(B.Ladder), 4, "four ladder facings")
		t.eq(#Blocks.variants(B.Rail), 2, "two rail axes")
		t.eq(#Blocks.variants(B.Vine), 4, "four vine walls")
		for _, name in
			{ "LadderSouth", "LadderWest", "LadderEast", "RailEastWest", "VineNorth", "VineWest", "VineEast" }
		do
			t.ok(not Blocks.get(B[name]).placeable, `{name} is a variant, not an item`)
		end
		t.eq(Items.ofBlock(B.LadderEast), I.Ladder)
		t.eq(Items.ofBlock(B.RailEastWest), I.Rail)
		t.eq(Items.ofBlock(B.CaveVineWest), I.Vine)
		t.eq(Items.ofBlock(B.CaveWallTorchEast), I.Torch)
		-- Names.
		t.eq(Items.displayName(I.OakFence), "Oak Fence")
		t.eq(Items.displayName(I.Vine), "Vines")
		t.eq(Blocks.get(B.CaveWallTorchNorth).displayName, "Wall Torch")
		t.eq(Blocks.get(B.CaveRailEastWest).displayName, "Rail")
		-- The fence is solid (a full block to the movement hull), but holds nothing up.
		t.ok(Blocks.isSolid(B.OakFence) and Blocks.isSolid(B.CaveOakFence))
		t.ok(not Blocks.isSturdy(B.OakFence) and not Blocks.isSturdy(B.Ladder) and not Blocks.isSturdy(B.Rail))
		t.ok(Blocks.isSturdy(B.MossBlock) and Blocks.isOpaque(B.MossyCobblestone))
		-- Twins are cave air while caves are hidden; their light (wall torches) is their twin's.
		t.eq(buffer.readu8(Blocks.cullLutHiddenCaves, B.CaveRail), 1)
		t.eq(buffer.readu8(Blocks.cullLutHiddenCaves, B.Rail), 0)
		t.eq(Blocks.light(B.CaveWallTorchSouth), 14)
	end)

	t.test("mineshaft blocks: climbable (ladders, vines, rope) and stuck (cobwebs)", function()
		local climbable = {}
		for _, name in
			{ "Ladder", "LadderSouth", "LadderWest", "LadderEast", "Rope", "Vine", "VineNorth", "VineWest", "VineEast" }
		do
			climbable[B[name]] = true
			local twin = Blocks.caveTwinFor(B[name])
			if twin then
				climbable[twin] = true
			end
		end
		for id = 0, Blocks.count - 1 do
			t.eq(Blocks.isClimbable(id), climbable[id] == true, `{Blocks.get(id).name} climbable`)
			t.eq(buffer.readu8(Blocks.climbableLut, id), if climbable[id] then 1 else 0)
			local stuck = Blocks.stuckIn(id)
			local web = id == B.Cobweb or id == B.CaveCobweb
			t.eq(stuck ~= nil, web, `{Blocks.get(id).name} stuck`)
			t.eq(buffer.readu8(Blocks.stuckLut, id), if web then 1 else 0)
		end
		local web = Blocks.stuckIn(B.Cobweb) :: { number }
		t.eq(web[1], 0.25)
		t.eq(web[2], 0.05)
		t.eq(web[3], 0.25)
		t.ok(table.isfrozen(web), "read only")
		t.ok(not Blocks.isClimbable(-1) and not Blocks.isClimbable(Blocks.count), "unknown ids")
		t.eq(Blocks.stuckIn(-1), nil)
		-- Nothing climbable or sticky is solid: players stand inside them.
		for id in climbable do
			t.ok(not Blocks.isSolid(id), `{Blocks.get(id).name} is not solid`)
		end
		t.ok(not Blocks.isSolid(B.Cobweb))
	end)

	t.test("mineshaft blocks: ladders go on walls (LadderBlock.getStateForPlacement)", function()
		-- A stone wall south of (0, 10, 0), and another east of it.
		local south = sparse({ ["0,10,1"] = STONE })
		local look = function(lx, lz)
			return lx, 0, lz
		end
		-- Clicking the wall's north face (its normal points north, -Z) faces the ladder north.
		local lx, ly, lz = look(0, 1)
		t.eq(Blocks.placementFor(B.Ladder, 0, 0, -1, lx, ly, lz, south, 0, 10, 0), B.Ladder, "on the south wall")
		t.eq(Blocks.get(B.Ladder).support, "South")
		-- Clicking the floor: the first wall in the look order that holds one.
		local floor = sparse({ ["0,10,1"] = STONE, ["0,9,0"] = STONE, ["1,10,0"] = STONE })
		t.eq(Blocks.placementFor(B.Ladder, 0, 1, 0, 0.1, -0.5, 1, floor, 0, 10, 0), B.Ladder, "looking south")
		t.eq(Blocks.placementFor(B.Ladder, 0, 1, 0, 1, -0.5, 0.1, floor, 0, 10, 0), B.LadderWest, "looking east")
		t.eq(Blocks.get(B.LadderWest).support, "East", "facing west: on the east wall")
		-- No wall: nothing.
		t.eq(Blocks.placementFor(B.Ladder, 0, 1, 0, 0, -1, 0, sparse({ ["0,9,0"] = STONE }), 0, 10, 0), nil)
		-- It needs a sturdy wall: not a fence, not glass leaves... (glass is sturdy, leaves are not).
		t.ok(not Blocks.canSurvive(B.Ladder, sparse({ ["0,10,1"] = B.OakFence }), 0, 10, 0), "not on a fence")
		t.ok(not Blocks.canSurvive(B.Ladder, sparse({ ["0,10,1"] = B.OakLeaves }), 0, 10, 0), "not on leaves")
		t.ok(not Blocks.canSurvive(B.Ladder, sparse({ ["0,10,1"] = false }), 0, 10, 0), "not on what is not loaded")
		-- Outline: Minecraft's 3 pixel panel against the wall.
		local outline = Blocks.outline(B.Ladder) :: { number }
		t.near(outline[3], 13 / 16, 1e-9)
		t.near(outline[6], 1, 1e-9)
		local west = Blocks.outline(B.LadderEast) :: { number }
		t.near(west[1], 0, 1e-9)
		t.near(west[4], 3 / 16, 1e-9, "facing east: on the west wall")
		-- The first box carries the texture (see-through), then rails and rungs.
		t.eq(#(Blocks.get(B.Ladder).shape :: { any }), 7)
		t.eq((Blocks.get(B.Ladder).shape :: { any })[1].transparency, 1)
	end)

	t.test("mineshaft blocks: rope hangs under a ceiling or a rope (the chain rule)", function()
		local ceiling = sparse({ ["0,11,0"] = STONE })
		t.eq(Blocks.placementFor(B.Rope, 0, -1, 0, 0, 1, 0, ceiling, 0, 10, 0), B.Rope, "under a ceiling")
		t.ok(Blocks.canSurvive(B.Rope, ceiling, 0, 10, 0))
		local rope = sparse({ ["0,11,0"] = B.Rope })
		t.eq(Blocks.placementFor(B.Rope, 0, -1, 0, 0, 1, 0, rope, 0, 10, 0), B.Rope, "under a rope")
		t.ok(Blocks.canSurvive(B.Rope, rope, 0, 10, 0))
		-- A wall's side click works only where the cell's ceiling holds it.
		local wall = sparse({ ["1,10,0"] = STONE })
		t.eq(Blocks.placementFor(B.Rope, -1, 0, 0, 1, 0, 0, wall, 0, 10, 0), nil, "not on a wall alone")
		t.eq(Blocks.placementFor(B.Rope, 0, 1, 0, 0, -1, 0, sparse({ ["0,9,0"] = STONE }), 0, 10, 0), nil)
		t.ok(not Blocks.canSurvive(B.Rope, sparse({}), 0, 10, 0), "not in the open")
		t.ok(not Blocks.canSurvive(B.Rope, sparse({ ["0,11,0"] = B.OakFence }), 0, 10, 0), "not under a fence")
		t.ok(not Blocks.canSurvive(B.Rope, sparse({ ["0,11,0"] = B.Vine }), 0, 10, 0), "not under a vine")
		t.ok(not Blocks.canSurvive(B.Rope, sparse({ ["0,11,0"] = false }), 0, 10, 0), "not under the unknown")

		-- Vines: on their wall, or under the same vine (a cave twin counts as its twin), not under
		-- another vine.
		local onWall = sparse({ ["0,10,1"] = STONE })
		t.ok(Blocks.canSurvive(B.Vine, onWall, 0, 10, 0), "on the south wall")
		t.ok(not Blocks.canSurvive(B.VineNorth, onWall, 0, 10, 0), "not on the wrong side")
		t.ok(Blocks.canSurvive(B.Vine, sparse({ ["0,11,0"] = B.Vine }), 0, 10, 0), "under the same vine")
		t.ok(Blocks.canSurvive(B.Vine, sparse({ ["0,11,0"] = B.CaveVine }), 0, 10, 0), "under its twin")
		t.ok(Blocks.canSurvive(B.CaveVine, sparse({ ["0,11,0"] = B.Vine }), 0, 10, 0), "a twin under its twin")
		t.ok(not Blocks.canSurvive(B.Vine, sparse({ ["0,11,0"] = B.VineNorth }), 0, 10, 0), "not under another wall's")
		t.ok(not Blocks.canSurvive(B.Vine, sparse({ ["0,11,0"] = B.Rope }), 0, 10, 0), "not under a rope")
		t.eq(Blocks.placementFor(B.Vine, 0, 0, 1, 0, 0, -1, sparse({ ["0,10,-1"] = STONE }), 0, 10, 0), B.VineNorth)
		-- Ladders are no chain: a ladder under a ladder needs its own wall.
		t.ok(not Blocks.canSurvive(B.Ladder, sparse({ ["0,11,0"] = B.Ladder }), 0, 10, 0))
		t.ok(Blocks.get(B.Rope).chain and Blocks.get(B.Vine).chain and not Blocks.get(B.Ladder).chain)
		-- Hanging roots and moss carpets: their ceiling, their floor.
		t.ok(Blocks.canSurvive(B.HangingRoots, ceiling, 0, 10, 0))
		t.ok(not Blocks.canSurvive(B.HangingRoots, rope, 0, 10, 0))
		t.ok(Blocks.canSurvive(B.MossCarpet, sparse({ ["0,9,0"] = B.Planks }), 0, 10, 0))
	end)

	t.test("mineshaft blocks: rails lie along the player's facing on a sturdy floor", function()
		local floor = sparse({ ["0,9,0"] = STONE })
		t.eq(Blocks.placementFor(B.Rail, 0, 1, 0, 1, -0.5, 0.2, floor, 0, 10, 0), B.RailEastWest, "facing east")
		t.eq(Blocks.placementFor(B.Rail, 0, 1, 0, -1, -0.5, 0.2, floor, 0, 10, 0), B.RailEastWest, "facing west")
		t.eq(Blocks.placementFor(B.Rail, 0, 1, 0, 0.2, -0.5, -1, floor, 0, 10, 0), B.Rail, "facing north")
		t.eq(Blocks.placementFor(B.Rail, 0, 1, 0, 0.2, -0.5, 1, floor, 0, 10, 0), B.Rail, "facing south")
		-- (Clicking a wall's side still lays it on the floor of the cell, along the facing.)
		t.eq(Blocks.placementFor(B.Rail, -1, 0, 0, 1, 0, 0, floor, 0, 10, 0), B.RailEastWest)
		t.eq(Blocks.placementFor(B.Rail, 0, 1, 0, 1, -0.5, 0, sparse({}), 0, 10, 0), nil, "no floor")
		t.eq(
			Blocks.placementFor(B.Rail, 0, 1, 0, 1, -0.5, 0, sparse({ ["0,9,0"] = B.Glass }), 0, 10, 0),
			B.RailEastWest
		)
		t.eq(Blocks.placementFor(B.Rail, 0, 1, 0, 1, -0.5, 0, sparse({ ["0,9,0"] = B.OakLeaves }), 0, 10, 0), nil)
		t.eq(Blocks.axisOf(B.Rail), "Z")
		t.eq(Blocks.axisOf(B.RailEastWest), "X")
		t.eq(Blocks.axisOf(B.CaveRailEastWest), "X")
		t.eq(Blocks.axisOf(STONE), nil)
		t.eq(Blocks.axisVariant(B.Rail, "X"), B.RailEastWest)
		t.eq(Blocks.axisVariant(B.RailEastWest, "Z"), B.Rail)
		t.eq(Blocks.axisVariant(B.Rail, "Y"), nil)
		t.eq(Blocks.axisVariant(STONE, "X"), nil)
		t.eq(Blocks.caveTwinFor(Blocks.axisVariant(B.Rail, "X") :: number), B.CaveRailEastWest)
		-- Minecraft's outline: 2 pixels high.
		local outline = Blocks.outline(B.Rail) :: { number }
		t.near(outline[5], 2 / 16, 1e-9)
	end)

	t.test("mineshaft blocks: turning with a structure (walls turn, rails swap axis, twins stay twins)", function()
		t.eq(Blocks.rotate(B.Rail, 1, "none"), B.RailEastWest)
		t.eq(Blocks.rotate(B.Rail, 2, "none"), B.Rail)
		t.eq(Blocks.rotate(B.RailEastWest, 3, "none"), B.Rail)
		t.eq(Blocks.rotate(B.Rail, 0, "leftRight"), B.Rail, "a mirror keeps the axis")
		t.eq(Blocks.rotate(B.CaveRail, 1, "frontBack"), B.CaveRailEastWest)
		-- Clockwise: the wall to the south ends up to the west, so the ladder faces east.
		t.eq(Blocks.rotate(B.Ladder, 1, "none"), B.LadderEast)
		t.eq(Blocks.rotate(B.Ladder, 0, "leftRight"), B.LadderSouth)
		t.eq(Blocks.rotate(B.Vine, 1, "none"), B.VineWest)
		t.eq(Blocks.rotate(B.CaveVine, 2, "none"), B.CaveVineNorth)
		t.eq(Blocks.rotate(B.CaveWallTorchNorth, 1, "none"), B.CaveWallTorchEast)
		t.eq(Blocks.rotate(B.Rope, 1, "none"), B.Rope)
		t.eq(Blocks.rotate(B.OakFence, 3, "frontBack"), B.OakFence)
	end)

	t.test("mineshaft blocks: cobwebs need a sword or Shears; vines and roots Shears", function()
		local SWORD, SHEARS, PICK = I.IronSword, I.Shears, I.IronPickaxe
		local function drop(block: number, tool: number?): (number?, number?)
			local stack = Items.drops(block, tool)
			return if stack then stack.item else nil, if stack then stack.count else nil
		end
		t.eq(drop(B.Cobweb, SWORD), I.String, "a sword: a string")
		t.eq(drop(B.Cobweb, I.WoodenSword), I.String, "any sword")
		t.eq(drop(B.Cobweb, SHEARS), I.Cobweb, "Shears: the cobweb")
		t.eq(drop(B.Cobweb, nil), nil, "a hand: nothing")
		t.eq(drop(B.Cobweb, PICK), nil, "a pickaxe: nothing")
		t.eq(drop(B.CaveCobweb, SWORD), I.String, "the twin alike")
		t.eq(drop(B.CaveCobweb, SHEARS), I.Cobweb)
		t.eq(Items.blockDrops(B.Cobweb) and (Items.blockDrops(B.Cobweb) :: any).item, I.String, "washed away")
		t.eq(Mining.toolSpeed(B.Cobweb, SWORD), 15, "SwordItem: 15 on a cobweb")
		t.eq(Mining.toolSpeed(B.Cobweb, SHEARS), 15)
		t.eq(Mining.toolSpeed(B.Cobweb, nil), 1)
		t.eq(Mining.toolSpeed(B.OakLeaves, SWORD), 1.5, "leaves unchanged")
		t.eq(Mining.toolSpeed(STONE, SWORD), 1)
		-- By hand: 1 / 4 / 100 a tick (400 ticks, Minecraft's 20 s); a sword: 15 / 4 / 30 (8 ticks).
		t.eq(Mining.ticks(B.Cobweb, true, false, nil), 400)
		t.eq(Mining.ticks(B.Cobweb, true, false, SWORD), 8)
		-- Vines and roots: only Shears; vines at 2 (ShearsItem).
		t.eq(drop(B.VineEast, nil), nil)
		t.eq(drop(B.VineEast, SHEARS), I.Vine)
		t.eq(drop(B.CaveVineNorth, SHEARS), I.Vine)
		t.eq(Mining.toolSpeed(B.Vine, SHEARS), 2)
		t.eq(drop(B.HangingRoots, nil), nil)
		t.eq(drop(B.HangingRoots, SHEARS), I.HangingRoots)
		t.eq(Mining.ticks(B.HangingRoots, true, false, nil), 1, "broken at once")
		-- Everything else drops itself (the variants their item).
		t.eq(drop(B.LadderWest, nil), I.Ladder)
		t.eq(drop(B.RailEastWest, nil), I.Rail, "rails by hand")
		t.eq(drop(B.CaveRail, nil), I.Rail)
		t.eq(drop(B.Rope, nil), I.Rope)
		t.eq(drop(B.CaveOakFence, nil), I.OakFence)
		t.eq(drop(B.MossCarpet, nil), I.MossCarpet)
		t.eq(drop(B.CaveWallTorchWest, nil), I.Torch)
		t.eq(drop(B.MossyCobblestone, nil), nil, "a pickaxe for mossy cobblestone")
		t.eq(drop(B.MossyCobblestone, PICK), I.MossyCobblestone)
	end)

	t.test("mineshaft blocks: recipes, fuel and the Iron Age's rails", function()
		local S, ST, STR, IR, P = I.Stick, I.Straw, I.String, I.IronIngot, I.Planks
		local ladder = craft({ S, nil, S, S, S, S, S, nil, S } :: any)
		t.eq(ladder and ladder.item, I.Ladder, "seven sticks")
		t.eq(ladder and ladder.count, 3)
		local rope = craft({ ST, nil, nil, ST, nil, nil, ST } :: any)
		t.eq(rope and rope.item, I.Rope, "three straw in a column")
		t.eq(rope and rope.count, 3)
		local diagonal = craft({ STR, nil, nil, nil, STR, nil, nil, nil, STR } :: any)
		t.eq(diagonal and diagonal.item, I.Rope, "three string on a diagonal")
		local other = craft({ nil, nil, STR, nil, STR, nil, STR } :: any)
		t.eq(other and other.item, I.Rope, "the other diagonal (mirrored)")
		local rail = craft({ IR, nil, IR, IR, S, IR, IR, nil, IR } :: any)
		t.eq(rail and rail.item, I.Rail, "six iron and a stick")
		t.eq(rail and rail.count, 16)
		local fence = craft({ P, S, P, P, S, P } :: any)
		t.eq(fence and fence.item, I.OakFence)
		t.eq(fence and fence.count, 3)
		t.eq(craft({ I.BirchPlanks, S, I.BirchPlanks, I.BirchPlanks, S, I.BirchPlanks } :: any), nil, "oak planks only")
		local carpet = craft({ I.MossBlock, I.MossBlock } :: any)
		t.eq(carpet and carpet.item, I.MossCarpet)
		t.eq(carpet and carpet.count, 3)
		for _, with in { I.Vine, I.MossBlock } do
			local mossy = craft({ [4] = I.Cobblestone, [9] = with } :: any)
			t.eq(mossy and mossy.item, I.MossyCobblestone, "cobblestone and moss")
			t.eq(mossy and mossy.count, 1)
		end
		t.eq(Smelting.fuel(I.Ladder), 300)
		t.eq(Smelting.fuel(I.OakFence), 300)
		t.eq(Smelting.fuel(I.Rope), 0)
		-- Rails need iron: the Iron Age's; the rest is open from the start.
		local age = Progression.requirement(I.Rail)
		t.eq(age and age.id, "iron")
		for _, name in { "Ladder", "Rope", "OakFence", "MossCarpet", "MossyCobblestone" } do
			t.eq((Progression.requirement(I[name])), nil, `{name}: the Stone Age`)
		end
	end)

	t.test("mineshaft blocks: sounds, fire, blast resistance, moss as soil", function()
		local sounds = {
			Ladder = "ladder",
			LadderEast = "ladder",
			Rope = "rope",
			Rail = "metal",
			CaveRail = "metal",
			OakFence = "wood",
			Cobweb = "wool",
			MossBlock = "moss",
			MossCarpet = "moss",
			Vine = "vine",
			HangingRoots = "vine",
			MossyCobblestone = "stone",
		}
		for name, sound in sounds do
			t.eq(Blocks.soundType(B[name]), sound, `{name} sounds`)
		end
		local fire = {
			Rope = { 10, 100 },
			Vine = { 15, 100 },
			CaveVineWest = { 15, 100 },
			HangingRoots = { 30, 60 },
			OakFence = { 5, 20 },
			CaveOakFence = { 5, 20 },
			Ladder = { 0, 0 },
			Rail = { 0, 0 },
			Cobweb = { 0, 0 },
			MossBlock = { 0, 0 },
			MossCarpet = { 0, 0 },
			MossyCobblestone = { 0, 0 },
		}
		for name, odds in fire do
			t.eq(Blocks.igniteOdds(B[name]), odds[1], `{name} ignite`)
			t.eq(Blocks.burnOdds(B[name]), odds[2], `{name} burn`)
		end
		t.eq(Blocks.get(B.OakFence).blastResistance, 3)
		t.eq(Blocks.get(B.MossyCobblestone).blastResistance, 6)
		t.eq(Blocks.get(B.Ladder).blastResistance, 0.4)
		t.eq(Blocks.get(B.Cobweb).blastResistance, 4)
		-- Water: vines, roots, carpets and cobwebs wash away; ladders, rails and rope stop it.
		for _, name in { "Vine", "HangingRoots", "MossCarpet", "Cobweb" } do
			t.ok(Blocks.get(B[name]).brokenByFluid, `{name} washes away`)
		end
		for _, name in { "Ladder", "Rail", "Rope", "OakFence" } do
			t.ok(not Blocks.get(B[name]).brokenByFluid and not Blocks.isReplaceable(B[name]), `{name} holds`)
		end
		t.ok(Blocks.isReplaceable(B.Vine) and Blocks.isReplaceable(B.HangingRoots))
		-- Minecraft's moss is in the dirt tag: plants grow on it.
		t.ok(Blocks.mayPlaceOn(B.ShortGrass, B.MossBlock), "grass on moss")
		t.ok(Blocks.mayPlaceOn(B.OakSapling, B.MossBlock), "a sapling on moss")
		t.ok(not Blocks.mayPlaceOn(B.ShortGrass, B.MossyCobblestone))
	end)

	t.test("mineshaft blocks: texture pack entries (blank) for every new block", function()
		local function faces(name: string): any
			return Blocks.get(B[name]).textures
		end
		for _, name in { "Ladder", "LadderSouth", "LadderWest", "LadderEast" } do
			t.eq(faces(name).front, "ladder", `{name} front`)
		end
		t.eq(faces("Rope").sprite, "rope")
		t.eq(faces("Rail").front, "rail")
		t.eq(faces("RailEastWest").front, "rail")
		t.eq(faces("OakFence").north, "planks", "the fence post in the planks' texture")
		t.eq(faces("Cobweb").sprite, "cobweb")
		t.eq(faces("MossBlock").top, "moss block")
		t.eq(faces("MossCarpet").top, "moss block")
		t.eq(faces("VineEast").front, "vine")
		t.eq(faces("HangingRoots").sprite, "hanging roots")
		t.eq(faces("MossyCobblestone").north, "mossy cobblestone")
		for _, texture in
			{ "ladder", "rope", "rail", "cobweb", "moss block", "vine", "hanging roots", "mossy cobblestone" }
		do
			t.eq(TexturePack.Textures[texture].Color, "", `{texture} is blank until made`)
		end
		-- Until then each draws its voxel colour.
		t.eq(Blocks.get(B.MossBlock).color[2], 110)
	end)

	--[[ The server: a hanging rope and vines come down when what holds them goes ]]

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

	t.test("attached: a rope hangs from its ceiling rope by rope, and comes down with it", function()
		local world, settle, dropped = newWorld()
		local TOP = FLOOR + 8
		world:setBlock(0, TOP, 0, STONE)
		for y = TOP - 1, FLOOR + 1, -1 do
			world:setBlock(0, y, 0, B.Rope)
		end
		-- A vine on a wall, with two more hanging below the wall's end.
		world:setBlock(4, FLOOR + 5, 1, STONE)
		world:setBlock(4, FLOOR + 5, 0, B.Vine)
		world:setBlock(4, FLOOR + 4, 0, B.Vine)
		world:setBlock(4, FLOOR + 3, 0, B.CaveVine)
		-- A ladder and a rail.
		world:setBlock(8, FLOOR, 1, STONE)
		world:setBlock(8, FLOOR, 0, B.Ladder)
		world:setBlock(10, FLOOR, 0, B.RailEastWest)
		settle()
		for y = FLOOR + 1, TOP - 1 do
			t.eq(world:getBlock(0, y, 0), B.Rope, `rope at {y} holds`)
		end
		t.eq(world:getBlock(4, FLOOR + 3, 0), B.CaveVine, "hanging vines hold")
		t.eq(world:getBlock(8, FLOOR, 0), B.Ladder)
		t.eq(world:getBlock(10, FLOOR, 0), B.RailEastWest)
		t.eq(#dropped, 0)

		-- Cut the rope in the middle: everything below comes down, the top part stays.
		world:setBlock(0, FLOOR + 4, 0, AIR)
		settle()
		for y = FLOOR + 1, FLOOR + 3 do
			t.eq(world:getBlock(0, y, 0), AIR, `rope at {y} fell`)
		end
		for y = FLOOR + 5, TOP - 1 do
			t.eq(world:getBlock(0, y, 0), B.Rope, `rope at {y} still hangs`)
		end
		t.eq(#dropped, 3, "each fallen rope drops itself")
		for _, drop in dropped do
			t.eq(drop.item, I.Rope)
		end

		-- The ceiling goes: the rest of the rope comes down.
		world:setBlock(0, TOP, 0, AIR)
		settle()
		for y = FLOOR + 1, TOP - 1 do
			t.eq(world:getBlock(0, y, 0), AIR)
		end
		t.eq(#dropped, 3 + (TOP - 1 - (FLOOR + 5) + 1))

		-- The wall goes: the vines come down (and drop nothing without Shears).
		world:setBlock(4, FLOOR + 5, 1, AIR)
		settle()
		t.eq(world:getBlock(4, FLOOR + 5, 0), AIR)
		t.eq(world:getBlock(4, FLOOR + 3, 0), AIR, "the hanging ones too")
		local before = #dropped
		-- The ladder's wall and the rail's floor.
		world:setBlock(8, FLOOR, 1, AIR)
		world:setBlock(10, FLOOR - 1, 0, AIR)
		settle()
		t.eq(world:getBlock(8, FLOOR, 0), AIR)
		t.eq(world:getBlock(10, FLOOR, 0), AIR)
		t.eq(#dropped, before + 2, "a ladder and a rail")
		Drops.set(nil)
	end)
end
