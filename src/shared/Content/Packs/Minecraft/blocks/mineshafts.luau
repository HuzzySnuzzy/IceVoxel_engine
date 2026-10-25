--!strict
--[[
	Ladders, rope and the mineshafts' blocks (Minecraft 1.20.1's LadderBlock, RailBlock, WebBlock,
	the lush caves' moss, vines and hanging roots, Mossy Cobblestone, and Supplementaries' rope).
	Generation/Mineshafts builds the mineshafts of them (and of the fences, the pack's
	blocks/fences, and wall torches, blocks/lights). New block sounds: "ladder", "rope", "vine"
	and "moss" (Minecraft's SoundType.LADDER, VINE and MOSS, Supplementaries' rope). Every shape
	box is a Part per block: decorations generation writes by the hundred keep to one or two.

	  * The Ladder (Minecraft's LadderBlock): a 3 pixel panel against a wall, facing away from it
	    (Ladder faces North, on the wall to its south; LadderSouth, LadderWest and LadderEast the
	    other ways: wall torches' naming). The wall must be sturdy (`support`, Attached); placing
	    picks the clicked wall, else the first wall in the look order that holds one
	    (Blocks.placementFor, as LadderBlock.getStateForPlacement). Climbable (Minecraft's
	    #climbable: PlayerPhysics), strength 0.4, mined fastest with an axe, drops itself, never
	    burns (Minecraft's isn't flammable), 300 ticks of furnace fuel, ladder sounds. Not `solid`
	    and no collision box here (the movement hull only knows full cubes; Minecraft's 3 pixel box
	    only keeps you off the wall), and water stops at it (Minecraft waterlogs it; there is no
	    waterlogging here). Drawn as two rails 2 pixels wide and four rungs 4 pixels apart (so
	    stacked ladders keep the spacing), 0 to 1.5 pixels off the wall, after a see-through plate
	    a fifth of a pixel thick 0.8 pixels off the wall: Minecraft's model is one textured quad
	    there, and the texture pack's "ladder" picture goes on that plate (its Front) in place of
	    the boxes (client rendering). Minecraft's outline: the 3 pixel panel.
	  * Rope (Supplementaries' RopeBlock, Minecraft 1.20.1): a rope hanging straight down, a 3 pixel
	    thick strand in the middle of its cell. It hangs under a sturdy block or under another rope
	    (`support` Up and `chain`: RopeBlock.canSurvive's ceiling or rope above; its side
	    attachments and knots are left out), so breaking a rope drops every rope below it, one a
	    tick (Attached). Climbable: hold jump to climb a free hanging rope; sliding down is a free
	    fall that never hurts (Supplementaries' fast-fall rope; PlayerPhysics). Strength 0.25, no
	    tool, drops itself, burns fast (10 / 100), rope sounds, water stops at it. Using Rope on a
	    rope adds one at its bottom (server Players/ItemUse). The overgrown mineshafts' entrances
	    hang one all the way down. Its texture is a sprite (two crossed planes, Minecraft's chain
	    model). Outline: Supplementaries' 4 pixel post.
	  * Rails (Minecraft's RailBlock, straight pieces only: no curves, slopes or minecarts): Rail
	    runs North-South (`axis` Z), RailEastWest East-West; placing picks the one along the
	    player's facing (BaseRailBlock.getStateForPlacement), turning a structure swaps them. They
	    lie on a sturdy block (`support` Down, Attached), have no collision, strength 0.7, a pickaxe
	    mines them fast but anything drops them, metal sounds, never burn; water stops at them.
	    Drawn as a sleeper board (the plate the "rail" picture goes on, its Front) under two iron
	    bars. Minecraft's outline: 2 pixels high.
	  * The Cobweb (Minecraft's WebBlock): moving through one is slowed to a quarter sideways and a
	    twentieth up and down, with every move's speed lost, and stops a fall (`stuck`,
	    makeStuckInBlock). Strength 4: a sword (speed 15, Shared/Mining) or Shears (15) are the
	    tools that get anything: a sword gives a String, Shears the cobweb, a hand nothing. Water
	    washes it away (a String). No recipe (Minecraft 1.20.1 has none), never burns. Wool sounds
	    (1.20.1's cobweb has the default stone ones; later versions give it a soft sound). Drawn as
	    two crossed see-through planes (Minecraft's cross model; the pack's "cobweb" sprite).
	  * Moss (Minecraft 1.20.1's lush caves): the Moss Block, a soft green block (strength 0.1, a
	    hoe mines it fast, moss sounds, never burns) in Minecraft's dirt tag, so plants stand on it
	    (Blocks' "dirt" soil set), and the Moss Carpet, a pixel of it on the floor (support Down:
	    here the block below must be sturdy, where Minecraft's carpet lies on anything; washed away
	    by water). The carpet takes the pack's "moss block" texture, as Minecraft's model does.
	  * Vines (Minecraft's VineBlock, one wall per block here, as glow lichen): Vine covers the wall
	    to its south, VineNorth, VineWest and VineEast the others (`support`, the clicked wall first
	    when placed). A vine holds on to its wall or hangs from the same vine above it (`chain`:
	    VineBlock's hanging vines), so cutting one drops the hanging ones below. Climbable,
	    replaceable, washed away by water, strength 0.2 (an axe), only Shears get it (at 2:
	    ShearsItem), burns (15 / 100), vine sounds. No growth (Minecraft's random spreading is left
	    out). A slightly see-through plate 0.8 pixels off the wall (Minecraft's model), the pack's
	    "vine" picture on it (its Front, tinted with the vine's green). Outline: a pixel thick plate
	    on the wall.
	  * Hanging Roots (Minecraft's HangingRootsBlock): roots hanging under a sturdy ceiling
	    (`support` Up), the top 6 pixels of the cell, two crossed planes (Minecraft's cross model;
	    the pack's "hanging roots" sprite). Replaceable, broken at once, only Shears get them,
	    washed away by water, burn (30 / 60), vine sounds.
	  * Mossy Cobblestone (Minecraft's): cobblestone with moss, strength 2, blast resistance 6, a
	    pickaxe to drop it. The overgrown mineshafts' entrances have a collar of it.
	  * zombieBreak: the moss block 300 ticks, mossy cobblestone 2400, the rest never.
	  * The cave twins of what the mineshafts put in their tunnels (`caveTwin`): rails, cobwebs,
	    moss carpets, vines (`seasonless`: underground they keep their green all year, an
	    appearance of their own) and hanging roots, exactly their twins but cave air while caves
	    are hidden, so a mineshaft's decorations cost nothing until a player reaches it
	    (Generation/Mineshafts: a twin in cave air, the block itself in the open).
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type BlockSpec = Schema.BlockSpec
type ShapeBox = Schema.ShapeBox

return function(define: Define.Context): { BlockSpec }
	local onWall, wallBounds = define.onWall, define.wallBounds
	local list: { BlockSpec } = {}
	-- (The blocks the mineshafts hang their cave twins of, in order.)
	local twinned: { BlockSpec } = {}

	-- Ladders, facing each way.
	local LADDER = { 150, 116, 70 }
	local ladder: { ShapeBox } = {
		{ size = { 16, 16, 0.2 }, offset = { 0, 0, 7.1 }, transparency = 1 },
		{ size = { 2, 16, 1.5 }, offset = { -5, 0, 7.25 } },
		{ size = { 2, 16, 1.5 }, offset = { 5, 0, 7.25 } },
	}
	for _, y in { -6, -2, 2, 6 } do
		table.insert(ladder, { size = { 8, 1.5, 1 }, offset = { 0, y, 6.9 } })
	end
	for _, facing in { "North", "South", "West", "East" } do
		local support = define.OPPOSITE[facing]
		local boxes: { ShapeBox } = {}
		for _, box in ladder do
			table.insert(boxes, onWall(box, support))
		end
		local base = facing == "North"
		table.insert(list, {
			name = if base then "Ladder" else "Ladder" .. facing,
			displayName = "Ladder",
			color = LADDER,
			material = "WoodPlanks",
			sound = "ladder",
			solid = false,
			placeable = base,
			item = if base then nil else "Ladder",
			hardness = 0.4,
			tool = "axe",
			shape = boxes,
			bounds = wallBounds(support, 3),
			support = support,
			behaviour = "Attached",
			climbable = true,
		})
	end

	table.insert(list, {
		name = "Rope",
		color = { 156, 124, 84 },
		material = "Fabric",
		sound = "rope",
		solid = false,
		placeable = true,
		hardness = 0.25,
		shape = { { size = { 3, 16, 3 }, offset = { 0, 0, 0 } } },
		bounds = { min = { 6, 0, 6 }, max = { 10, 16, 10 } },
		support = "Up",
		chain = true,
		behaviour = "Attached",
		climbable = true,
		flammable = { ignite = 10, burn = 100 },
	})

	-- Rails along each axis.
	local SLEEPERS = { 108, 84, 56 }
	local RAIL_IRON = { 150, 150, 158 }
	for _, axis in { "Z", "X" } do
		local northSouth = axis == "Z"
		local function box(across: number, height: number, y: number, x: number): ShapeBox
			return {
				size = if northSouth then { across, height, 16 } else { 16, height, across },
				offset = if northSouth then { x, y, 0 } else { 0, y, x },
			}
		end
		local sleepers = box(14, 1, -7.5, 0)
		sleepers.color, sleepers.material = SLEEPERS, "Wood"
		local shape: { ShapeBox } = { sleepers }
		for _, x in { -4.5, 4.5 } do
			local bar = box(1.5, 1, -6.5, x)
			bar.color = RAIL_IRON
			table.insert(shape, bar)
		end
		local rail: BlockSpec = {
			name = if northSouth then "Rail" else "RailEastWest",
			displayName = "Rail",
			color = RAIL_IRON,
			material = "Metal",
			sound = "metal",
			solid = false,
			placeable = northSouth,
			item = if northSouth then nil else "Rail",
			hardness = 0.7,
			tool = "pickaxe",
			shape = shape,
			bounds = { min = { 0, 0, 0 }, max = { 16, 2, 16 } },
			support = "Down",
			behaviour = "Attached",
			axis = axis,
		}
		table.insert(list, rail)
		table.insert(twinned, rail)
	end

	local cobweb: BlockSpec = {
		name = "Cobweb",
		displayName = "Cobweb",
		color = { 232, 232, 236 },
		material = "SmoothPlastic",
		transparency = 0.45,
		sound = "wool",
		solid = false,
		placeable = true,
		hardness = 4,
		tool = "sword",
		toolLevel = 0,
		drops = "String" :: string,
		shearDrops = true,
		shape = {
			{ size = { 22.6, 16, 0.2 }, offset = { 0, 0, 0 }, rotation = { 0, 45, 0 } },
			{ size = { 22.6, 16, 0.2 }, offset = { 0, 0, 0 }, rotation = { 0, -45, 0 } },
		},
		bounds = { min = { 0, 0, 0 }, max = { 16, 16, 16 } },
		brokenByFluid = true,
		stuck = { 0.25, 0.05, 0.25 },
	}
	table.insert(list, cobweb)
	table.insert(twinned, cobweb)

	local MOSS = { 89, 110, 45 }
	table.insert(list, {
		name = "MossBlock",
		displayName = "Moss Block",
		color = MOSS,
		material = "Grass",
		sound = "moss",
		hardness = 0.1,
		tool = "hoe",
		zombieBreak = 300,
	})
	local carpet: BlockSpec = {
		name = "MossCarpet",
		displayName = "Moss Carpet",
		color = MOSS,
		material = "Grass",
		sound = "moss",
		solid = false,
		placeable = true,
		hardness = 0.1,
		tool = "hoe",
		shape = { { size = { 16, 1, 16 }, offset = { 0, -7.5, 0 } } },
		bounds = { min = { 0, 0, 0 }, max = { 16, 1, 16 } },
		support = "Down",
		brokenByFluid = true,
		behaviour = "Attached",
	}
	table.insert(list, carpet)
	table.insert(twinned, carpet)

	-- Vines on each wall.
	local VINE = { 58, 104, 34 }
	local plate: ShapeBox = { size = { 16, 16, 0.4 }, offset = { 0, 0, 7.2 } }
	for _, support in { "South", "North", "West", "East" } do
		local base = support == "South"
		local vine: BlockSpec = {
			name = if base then "Vine" else "Vine" .. support,
			displayName = "Vines",
			color = VINE,
			material = "LeafyGrass",
			transparency = 0.15,
			sound = "vine",
			solid = false,
			replaceable = true,
			placeable = base,
			item = if base then nil else "Vine",
			hardness = 0.2,
			tool = "axe",
			drops = false,
			shearDrops = true,
			shearSpeed = 2,
			shape = { onWall(plate, support) },
			bounds = wallBounds(support, 1),
			support = support,
			chain = true,
			brokenByFluid = true,
			behaviour = "Attached",
			climbable = true,
			flammable = { ignite = 15, burn = 100 },
		}
		table.insert(list, vine)
		table.insert(twinned, vine)
	end

	local roots: BlockSpec = {
		name = "HangingRoots",
		displayName = "Hanging Roots",
		color = { 160, 118, 92 },
		material = "SmoothPlastic",
		sound = "vine",
		solid = false,
		replaceable = true,
		placeable = true,
		hardness = 0,
		tool = "axe",
		drops = false,
		shearDrops = true,
		shape = {
			{ size = { 16.9, 6, 0.3 }, offset = { 0, 5, 0 }, rotation = { 0, 45, 0 } },
			{ size = { 16.9, 6, 0.3 }, offset = { 0, 5, 0 }, rotation = { 0, -45, 0 } },
		},
		bounds = { min = { 2, 10, 2 }, max = { 14, 16, 14 } },
		support = "Up",
		brokenByFluid = true,
		behaviour = "Attached",
		flammable = { ignite = 30, burn = 60 },
	}
	table.insert(list, roots)
	table.insert(twinned, roots)

	table.insert(list, {
		name = "MossyCobblestone",
		displayName = "Mossy Cobblestone",
		color = { 102, 112, 92 },
		material = "Cobblestone",
		sound = "stone",
		hardness = 2,
		blastResistance = 6,
		tool = "pickaxe",
		toolLevel = 0,
		zombieBreak = 2400,
	})

	-- The cave twins, the vines' seasonless.
	for _, spec in twinned do
		local vine = string.sub(spec.name, 1, 4) == "Vine"
		table.insert(list, define.caveTwin(spec, if vine then { seasonless = true } else nil))
	end
	return list
end
