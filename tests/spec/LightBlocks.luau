--[[
	Light sources: torches, wall torches, lanterns and glowstone. Their light values and shapes,
	which variant a click places (Minecraft's TorchBlock / WallTorchBlock / LanternBlock and
	StandingAndWallBlockItem), what holds them up (Blocks.canSurvive, EditRules.supported), the
	server's attached-block behaviour and water washing torches away (with their drops), recipes,
	items and aiming at their outlines (VoxelRaycast).
]]

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Crafting = require(shared.Crafting)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local VoxelRaycast = require(shared.World.VoxelRaycast)
	local WorldServer = require(server.World.WorldServer)
	local BlockTicker = require(server.World.BlockTicker)
	local Behaviours = require(server.Behaviours)
	local Drops = require(server.Behaviours.Drops)
	local EditRules = require(server.Network.EditRules)
	local InventoryState = require(server.Players.InventoryState)

	local id = Blocks.id
	local AIR, STONE = Blocks.AIR, id.Stone
	local TORCH, LANTERN, HANGING, GLOWSTONE = id.Torch, id.Lantern, id.HangingLantern, id.Glowstone
	local NORTH, SOUTH, WEST, EAST = id.WallTorchNorth, id.WallTorchSouth, id.WallTorchWest, id.WallTorchEast
	local WATER = Blocks.fluidId("Water", 0)

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

	t.test("light: Minecraft's luminance per block, in the lookup table and the appearances", function()
		local expected = {
			Torch = 14,
			WallTorchNorth = 14,
			WallTorchSouth = 14,
			WallTorchWest = 14,
			WallTorchEast = 14,
			Lantern = 15,
			HangingLantern = 15,
			Glowstone = 15,
			Stone = 0,
			Glass = 0,
			Air = 0,
		}
		for name, light in expected do
			t.eq(buffer.readu8(Blocks.lightLut, id[name]), light, name)
			t.eq(Blocks.light(id[name]), light, name)
			t.eq(Blocks.get(id[name]).light, light, name)
			local appearance = Blocks.get(id[name]).appearance
			if appearance ~= 0 then
				t.eq(Blocks.appearances[appearance].light, light, `{name} appearance`)
			end
		end
		t.eq(Blocks.light(-1), 0)
		t.eq(Blocks.light(Blocks.count), 0, "unknown ids give no light")
		-- Lit blocks are meshed one box per block (one light each), shaped ones too.
		for _, name in { "Torch", "WallTorchEast", "Lantern", "HangingLantern", "Glowstone" } do
			t.eq(buffer.readu8(Blocks.singleLut, Blocks.get(id[name]).appearance), 1, `{name} is single`)
		end
		t.eq(buffer.readu8(Blocks.singleLut, Blocks.get(STONE).appearance), 0)
	end)

	t.test("light: torches and lanterns are shaped, see-through, walk-through and instant or iron-hard", function()
		for _, block in { TORCH, NORTH, SOUTH, WEST, EAST, LANTERN, HANGING } do
			local def = Blocks.get(block)
			t.ok(def.shape ~= nil, `{def.name} has a shape`)
			t.eq(def.kind, Blocks.KIND_TRANSPARENT, `{def.name} renders like glass`)
			t.ok(not Blocks.isOpaque(block), `{def.name} hides nothing`)
			t.ok(not Blocks.isSolid(block), `{def.name} does not collide`)
			t.ok(not Blocks.isReplaceable(block), `{def.name} can't be built over`)
			t.ok(Blocks.isTargetable(block), `{def.name} can be aimed at`)
			t.ok(not Blocks.isSturdy(block), `{def.name} holds nothing up`)
			t.ok(Blocks.outline(block) ~= nil, `{def.name} has an outline`)
			-- One glowing box carries the light.
			local glowing = 0
			for _, box in def.shape :: { Blocks.ShapeBox } do
				if box.glow then
					glowing += 1
				end
			end
			t.eq(glowing, 1, `{def.name} glowing boxes`)
		end
		t.eq(Blocks.get(TORCH).hardness, 0)
		t.eq(Blocks.get(NORTH).hardness, 0)
		t.eq(Blocks.get(LANTERN).hardness, 3.5)
		t.eq(Blocks.get(LANTERN).tool, "pickaxe")
		t.eq(Blocks.get(GLOWSTONE).hardness, 0.3)
		t.ok(Blocks.isOpaque(GLOWSTONE) and Blocks.isSturdy(GLOWSTONE), "glowstone is a full block")
		t.eq(Blocks.outline(GLOWSTONE), nil)
		t.eq(Blocks.outline(STONE), nil)
		-- Minecraft's outlines: torch 6..10 x 0..10, wall torch 5 deep against the wall.
		local torch = Blocks.outline(TORCH) :: { number }
		t.near(torch[1], 6 / 16, 1e-9)
		t.near(torch[2], 0, 1e-9)
		t.near(torch[5], 10 / 16, 1e-9)
		local east = Blocks.outline(EAST) :: { number }
		t.near(east[1], 0, 1e-9, "east-facing wall torch against the west side")
		t.near(east[4], 5 / 16, 1e-9)
		local north = Blocks.outline(NORTH) :: { number }
		t.near(north[3], 11 / 16, 1e-9, "north-facing wall torch against the south side")
		t.near(north[6], 1, 1e-9)
		-- Wall torches are torches: placed by and dropping the Torch, named "Wall Torch".
		t.eq(Items.displayName(Items.ofBlock(EAST) :: number), "Torch")
		t.eq(Blocks.get(EAST).displayName, "Wall Torch")
	end)

	t.test("light: every shape box stays in its cell; wall torches lean out from their foot", function()
		-- CFrame.Angles(rx, ry, rz) * v = Rx (Ry (Rz v)).
		local function turn(v: { number }, r: { number }): { number }
			local ax, ay, az = math.rad(r[1]), math.rad(r[2]), math.rad(r[3])
			local x, y, z = v[1], v[2], v[3]
			x, y = x * math.cos(az) - y * math.sin(az), x * math.sin(az) + y * math.cos(az)
			x, z = x * math.cos(ay) + z * math.sin(ay), -x * math.sin(ay) + z * math.cos(ay)
			y, z = y * math.cos(ax) - z * math.sin(ax), y * math.sin(ax) + z * math.cos(ax)
			return { x, y, z }
		end
		for block = 0, Blocks.count - 1 do
			local def = Blocks.get(block)
			for i, box in def.shape or {} do
				for _, sx in { -1, 1 } do
					for _, sy in { -1, 1 } do
						for _, sz in { -1, 1 } do
							local c = turn(
								{ box.size[1] / 2 * sx, box.size[2] / 2 * sy, box.size[3] / 2 * sz },
								box.rotation or { 0, 0, 0 }
							)
							for k = 1, 3 do
								-- (A wall torch's foot dips a pixel into its wall, like Minecraft's.)
								t.ok(math.abs(c[k] + box.offset[k]) <= 9, `{def.name} box {i} leaves its cell`)
							end
						end
					end
				end
			end
		end
		-- The stick's foot is in the middle of the wall face, 3.5 pixels up; the flame is further out.
		for name, wall in
			{
				WallTorchEast = { -8, 0 },
				WallTorchWest = { 8, 0 },
				WallTorchSouth = { 0, -8 },
				WallTorchNorth = { 0, 8 },
			}
		do
			local shape = Blocks.get(id[name]).shape :: { Blocks.ShapeBox }
			local stick, flame = shape[1], shape[2]
			local foot = turn({ 0, -stick.size[2] / 2, 0 }, stick.rotation :: { number })
			t.near(foot[1] + stick.offset[1], wall[1], 1e-9, `{name} foot x`)
			t.near(foot[2] + stick.offset[2], -4.5, 1e-9, `{name} foot height`)
			t.near(foot[3] + stick.offset[3], wall[2], 1e-9, `{name} foot z`)
			-- Out of the wall (towards the cell's centre, where the torch faces), not into it.
			local out = (flame.offset[1] - wall[1]) * -math.sign(wall[1])
				+ (flame.offset[3] - wall[2]) * -math.sign(wall[2])
			t.near(out, 9 * math.sin(math.rad(22.5)), 1e-9, `{name} leans 22.5 degrees out`)
			-- And the stick's top too: every box leans the same way.
			local top = turn({ 0, stick.size[2] / 2, 0 }, stick.rotation :: { number })
			local topOut = (top[1] + stick.offset[1] - wall[1]) * -math.sign(wall[1])
				+ (top[3] + stick.offset[3] - wall[2]) * -math.sign(wall[2])
			t.near(topOut, 8 * math.sin(math.rad(22.5)), 1e-9, `{name} stick leans out`)
			t.ok(flame.glow, `{name} flame glows`)
		end
	end)

	t.test("placement: the clicked face picks the torch (Blocks.torchFor)", function()
		t.eq(Blocks.torchFor(0, 1, 0), TORCH, "top face: standing")
		t.eq(Blocks.torchFor(1, 0, 0), EAST, "the +X side of a block: facing east")
		t.eq(Blocks.torchFor(-1, 0, 0), WEST)
		t.eq(Blocks.torchFor(0, 0, 1), SOUTH)
		t.eq(Blocks.torchFor(0, 0, -1), NORTH)
		t.eq(Blocks.torchFor(0, -1, 0), nil, "no torches on ceilings")
		t.eq(Blocks.variantFor(LANTERN, 0, -1, 0), HANGING, "a lantern under a block hangs")
		t.eq(Blocks.variantFor(LANTERN, 0, 1, 0), LANTERN)
		t.eq(Blocks.variantFor(LANTERN, 1, 0, 0), nil, "lanterns don't go on walls")
		t.eq(Blocks.variantFor(STONE, 1, 0, 0), STONE, "plain blocks place as they are")
		-- Variants share the item's block.
		local torches = Blocks.variants(TORCH)
		t.eq(torches[1], TORCH)
		t.eq(#torches, 5)
		t.eq(Blocks.variants(NORTH), torches)
		t.eq(#Blocks.variants(LANTERN), 2)
		t.eq(#Blocks.variants(STONE), 1)
		local dx, dy, dz = Blocks.supportOffset(EAST)
		t.ok(dx == -1 and dy == 0 and dz == 0, "an east-facing torch hangs on the block west of it")
		dx, dy, dz = Blocks.supportOffset(HANGING)
		t.ok(dx == 0 and dy == 1 and dz == 0, "a hanging lantern on the one above")
		t.eq(Blocks.supportOffset(STONE), nil)
	end)

	t.test("placement: Minecraft's look order (Direction.orderedByNearest)", function()
		local function order(x: number, y: number, z: number): string
			return table.concat(Blocks.lookOrder(x, y, z), " ")
		end
		t.eq(order(0, -0.3, -1), "North Down West East Up South")
		t.eq(order(0.2, -1, 0.1), "Down East South North West Up")
		t.eq(order(1, 0.5, -0.2), "East Up North South Down West")
		t.eq(order(-0.6, 0.2, 0.5), "West South Up Down North East")
	end)

	t.test("placement: support rules (Blocks.canSurvive, EditRules.supported)", function()
		-- A torch at (0, 1, 0) over different floors.
		for name, ok in
			{
				Stone = true,
				Glass = true,
				OakLeaves = true,
				Glowstone = true,
				Chest = true,
				Air = false,
				Torch = false,
				Lantern = false,
			}
		do
			local world = sparse({ ["0,0,0"] = id[name] })
			t.eq(Blocks.canSurvive(TORCH, world, 0, 1, 0), ok, `torch on {name}`)
			t.eq(EditRules.supported(TORCH, world, 0, 1, 0), ok, `server: torch on {name}`)
		end
		t.ok(not Blocks.canSurvive(TORCH, sparse({ ["0,0,0"] = WATER }), 0, 1, 0), "not on water")
		t.ok(not Blocks.canSurvive(TORCH, sparse({ ["0,0,0"] = false }), 0, 1, 0), "unloaded holds nothing")
		-- Wall torches need the block behind them.
		local wall = sparse({ ["-1,1,0"] = STONE })
		t.ok(Blocks.canSurvive(EAST, wall, 0, 1, 0))
		t.ok(not Blocks.canSurvive(WEST, wall, 0, 1, 0))
		t.ok(not Blocks.canSurvive(NORTH, wall, 0, 1, 0))
		t.ok(not Blocks.canSurvive(TORCH, wall, 0, 1, 0), "nothing below")
		-- Lanterns stand on a block or hang under one.
		local ceiling = sparse({ ["0,3,0"] = STONE })
		t.ok(Blocks.canSurvive(HANGING, ceiling, 0, 2, 0))
		t.ok(not Blocks.canSurvive(LANTERN, ceiling, 0, 2, 0))
		t.ok(Blocks.canSurvive(STONE, ceiling, 5, 5, 5), "plain blocks need nothing")
		t.ok(EditRules.supported(STONE, sparse({}), 5, 5, 5))
		t.ok(not EditRules.supported(9999, sparse({}), 0, 0, 0), "unknown block")
	end)

	t.test("placement: placementFor tries the clicked face, then where the player looks", function()
		local look = { 0, -0.3, -1 } -- north, a little down
		local function place(block: number, world, normal: { number }, at: { number }): number?
			return Blocks.placementFor(
				block,
				normal[1],
				normal[2],
				normal[3],
				look[1],
				look[2],
				look[3],
				world,
				at[1],
				at[2],
				at[3]
			)
		end
		-- Clicking the top of stone: a standing torch.
		local floor = sparse({ ["0,0,0"] = STONE })
		t.eq(place(TORCH, floor, { 0, 1, 0 }, { 0, 1, 0 }), TORCH)
		-- Clicking the east side of a stone block: a wall torch facing east.
		local side = sparse({ ["0,1,0"] = STONE })
		t.eq(place(TORCH, side, { 1, 0, 0 }, { 1, 1, 0 }), EAST)
		-- Clicking a ceiling (the bottom face) with a wall to the north of the spot: on that wall,
		-- facing south (the looking order's first side that holds it).
		local corner = sparse({ ["0,3,0"] = STONE, ["0,2,-1"] = STONE })
		t.eq(place(TORCH, corner, { 0, -1, 0 }, { 0, 2, 0 }), SOUTH)
		-- With a floor under the spot and no wall: on the floor (Down comes after North in the look).
		local gap = sparse({ ["0,3,0"] = STONE, ["0,1,0"] = STONE })
		t.eq(place(TORCH, gap, { 0, -1, 0 }, { 0, 2, 0 }), TORCH)
		-- Nothing around: nowhere.
		t.eq(place(TORCH, sparse({ ["0,3,0"] = STONE }), { 0, -1, 0 }, { 0, 2, 0 }), nil)
		-- The clicked side can't hold a torch (glass is fine, a torch is not): the floor does.
		local weak = sparse({ ["-1,1,0"] = TORCH, ["0,0,0"] = STONE })
		t.eq(place(TORCH, weak, { 1, 0, 0 }, { 0, 1, 0 }), TORCH)
		-- Lanterns: under a block they hang, on top they stand; a side click asks the looking order
		-- (down first: standing, if there is a floor).
		local both = sparse({ ["0,3,0"] = STONE, ["0,1,0"] = STONE })
		t.eq(place(LANTERN, both, { 0, -1, 0 }, { 0, 2, 0 }), HANGING)
		t.eq(place(LANTERN, both, { 0, 1, 0 }, { 0, 2, 0 }), LANTERN)
		t.eq(place(LANTERN, both, { 1, 0, 0 }, { 0, 2, 0 }), LANTERN)
		t.eq(place(LANTERN, sparse({ ["0,3,0"] = STONE }), { 1, 0, 0 }, { 0, 2, 0 }), HANGING, "else hanging")
		t.eq(place(STONE, sparse({}), { 1, 0, 0 }, { 0, 2, 0 }), STONE, "plain blocks need nothing")
	end)

	t.test(
		"placement: a side before the floor in the order picks any wall that holds (StandingAndWallBlockItem)",
		function()
			-- A spot with a floor, a wall to the east, a torch to the south and a ceiling.
			local world = sparse({
				["0,0,0"] = STONE,
				["1,1,0"] = STONE,
				["0,1,1"] = TORCH,
				["0,2,0"] = STONE,
			})
			local function place(normal: { number }, look: { number }): number?
				return Blocks.placementFor(
					TORCH,
					normal[1],
					normal[2],
					normal[3],
					look[1],
					look[2],
					look[3],
					world,
					0,
					1,
					0
				)
			end
			-- Clicking the torch's north side: South (the torch, which holds nothing) comes first, then
			-- Down, East... Minecraft asks the wall torch at the first side, and it takes the first side
			-- that holds it (East), though the floor comes earlier.
			t.eq(table.concat(Blocks.lookOrder(0.3, -0.9, -0.2), " "), "Down East North South West Up")
			t.eq(place({ 0, 0, -1 }, { 0.3, -0.9, -0.2 }), WEST, "on the east wall, facing west")
			-- Clicking the ceiling while looking down: Down comes before every side, so it stands.
			t.eq(place({ 0, -1, 0 }, { 0.3, -0.9, -0.2 }), TORCH)
			-- Looking east, a little down: East first, so the wall.
			t.eq(place({ 0, -1, 0 }, { 0.9, -0.3, -0.2 }), WEST)
			-- The top of the floor is always a standing torch.
			t.eq(place({ 0, 1, 0 }, { 0.9, -0.3, -0.2 }), TORCH)
			-- Lanterns only ever look up and down.
			t.eq(
				Blocks.placementFor(LANTERN, 0, 0, -1, 0.9, -0.3, -0.2, world, 0, 1, 0),
				LANTERN,
				"standing: Down comes before Up"
			)
		end
	)

	t.test("edits: variants are placeable, but not over a torch; items map back to the torch", function()
		t.ok(EditRules.mayPlace(TORCH, AIR))
		for _, block in { NORTH, SOUTH, WEST, EAST, HANGING } do
			t.ok(EditRules.mayPlace(block, AIR), Blocks.get(block).name)
			t.ok(EditRules.mayPlace(block, WATER), `{Blocks.get(block).name} into water`)
		end
		t.ok(EditRules.mayPlace(LANTERN, AIR))
		t.ok(EditRules.mayPlace(GLOWSTONE, AIR))
		t.ok(not EditRules.mayPlace(STONE, TORCH), "a torch is not replaceable")
		t.ok(not EditRules.mayPlace(TORCH, NORTH))

		-- Survival: placing a wall torch uses up a torch in hand, and only a torch.
		local state = InventoryState.new()
		state:join("a")
		local inventory = state:window("a").inventory
		inventory.slots[1] = { item = Items.id.Torch, count = 2 }
		t.ok(state:place("a", NORTH, 1, false))
		t.eq(inventory.slots[1].count, 1)
		t.ok(state:place("a", TORCH, 2, false))
		t.eq(inventory.slots[1], nil)
		inventory.slots[1] = { item = Items.id.Torch, count = 5 }
		t.ok(not state:place("a", HANGING, 3, false), "a torch is no lantern")
		inventory.slots[1] = { item = Items.id.Lantern, count = 1 }
		t.ok(state:place("a", HANGING, 4, false))
		t.eq(inventory.slots[1], nil)
	end)

	t.test("items: torches, lanterns, glowstone and dust; drops by hand and tool", function()
		t.eq(Items.ofBlock(TORCH), Items.id.Torch)
		t.eq(Items.id.Torch, TORCH, "the torch is a block item")
		for _, block in { NORTH, SOUTH, WEST, EAST } do
			t.eq(Items.ofBlock(block), Items.id.Torch, Blocks.get(block).name)
			t.eq(Items.get(block), nil, "wall torches are no items")
			local drop = Items.drops(block)
			t.eq(drop and drop.item, Items.id.Torch)
			t.eq(drop and drop.count, 1)
		end
		t.eq(Items.ofBlock(HANGING), Items.id.Lantern)
		t.eq(Items.get(HANGING), nil)
		t.eq(Items.drops(LANTERN), nil, "lanterns need a pickaxe")
		t.eq(Items.drops(HANGING, Items.id.WoodenPickaxe).item, Items.id.Lantern)
		t.eq(Items.drops(LANTERN, Items.id.WoodenPickaxe).item, Items.id.Lantern)
		t.eq(Items.blockDrops(HANGING).item, Items.id.Lantern, "falling off needs no tool")
		local dust = Items.drops(GLOWSTONE)
		t.eq(dust and dust.item, Items.id.GlowstoneDust)
		t.eq(dust and dust.count, 4)
		t.eq(Items.blockDrops(STONE).item, Items.id.Cobblestone)
		t.eq(Items.blockDrops(Blocks.id.Glass), nil)
		t.eq(Items.blockDrops(9999), nil)
		-- The creative list has the torch, lantern and glowstone, never the variants.
		local listed = {}
		for _, def in Items.list do
			listed[def.name] = true
		end
		t.ok(listed.Torch and listed.Lantern and listed.Glowstone and listed.GlowstoneDust)
		t.ok(not listed.WallTorchNorth and not listed.HangingLantern)
	end)

	t.test("recipes: torches from coal or charcoal, lanterns, glowstone (Minecraft's)", function()
		local item = Items.id
		local function craft(cells: { [number]: number }, width: number)
			local grid = {}
			for slot, cell in cells do
				grid[slot] = { item = cell, count = 1 }
			end
			return Crafting.match(grid, width)
		end
		for _, fuel in { item.Coal, item.Charcoal } do
			local torches = craft({ [1] = fuel, [3] = item.Stick }, 2)
			t.eq(torches and torches.item, item.Torch)
			t.eq(torches and torches.count, 4)
		end
		t.eq(craft({ [1] = item.Stick, [3] = item.Coal }, 2), nil, "the stick goes under")
		local n = item.IronNugget
		local lantern = craft({ n, n, n, n, item.Torch, n, n, n, n }, 3)
		t.eq(lantern and lantern.item, item.Lantern)
		t.eq(craft({ n, n, n, n, item.Stick, n, n, n, n }, 3), nil)
		local d = item.GlowstoneDust
		local glowstone = craft({ d, d, d, d }, 2)
		t.eq(glowstone and glowstone.item, item.Glowstone)
		t.eq(glowstone and glowstone.count, 1)
	end)

	t.test("aiming: rays pass beside a torch to the wall, and hit its outline", function()
		local world = sparse({ ["-1,0,0"] = STONE, ["0,0,0"] = EAST })
		-- Above the torch's outline (3..13 pixels up): the wall behind.
		local over = VoxelRaycast.cast(2.5, 0.9, 0.5, -1, 0, 0, 10, world, Blocks.isTargetable, Blocks.outline)
		assert(over)
		t.eq(over.x, -1, "the wall")
		t.eq(over.nx, 1)
		-- Through the middle: the torch, at its outline's face (5 pixels from the wall).
		local hit = VoxelRaycast.cast(2.5, 0.5, 0.5, -1, 0, 0, 10, world, Blocks.isTargetable, Blocks.outline)
		assert(hit)
		t.eq(hit.block, EAST)
		t.eq(hit.nx, 1)
		t.near(hit.distance, 2.5 - 5 / 16, 1e-9)
		-- From above, straight down onto the outline's top.
		local down = VoxelRaycast.cast(0.15, 3, 0.5, 0, -1, 0, 10, world, Blocks.isTargetable, Blocks.outline)
		assert(down)
		t.eq(down.block, EAST)
		t.eq(down.ny, 1)
		t.near(down.distance, 3 - 13 / 16, 1e-9)
		-- Without outlines every target is a whole cell (the old behaviour).
		local cell = VoxelRaycast.cast(2.5, 0.9, 0.5, -1, 0, 0, 10, world, Blocks.isTargetable)
		assert(cell)
		t.eq(cell.x, 0)
		-- A ray that would only reach the outline beyond its range misses.
		t.eq(VoxelRaycast.cast(2.5, 0.5, 0.5, -1, 0, 0, 2.1, world, Blocks.isTargetable, Blocks.outline), nil)
		-- Parallel to the outline's bottom, just under it (3 pixels up): beside it, to the wall.
		local under = VoxelRaycast.cast(2.5, 0.1, 0.5, -1, 0, 0, 10, world, Blocks.isTargetable, Blocks.outline)
		assert(under)
		t.eq(under.x, -1, "under the torch: the wall")
		-- Parallel to it and beside it (z outside 5.5..10.5 pixels): the wall too.
		local beside = VoxelRaycast.cast(2.5, 0.5, 0.2, -1, 0, 0, 10, world, Blocks.isTargetable, Blocks.outline)
		assert(beside)
		t.eq(beside.x, -1, "beside the torch: the wall")
		-- Starting inside the outline: the torch at once.
		local inside = VoxelRaycast.cast(0.15, 0.5, 0.5, -1, 0, 0, 10, world, Blocks.isTargetable, Blocks.outline)
		assert(inside)
		t.eq(inside.block, EAST)
		t.eq(inside.distance, 0)
		-- A slanted ray onto the outline's top face, from the side of the cell.
		local slanted = VoxelRaycast.cast(0.6, 1.5, 0.5, -1, -2, 0, 10, world, Blocks.isTargetable, Blocks.outline)
		assert(slanted)
		t.eq(slanted.block, EAST)
		t.eq(slanted.ny, 1, "lands on the top")
		t.near(slanted.distance, (1.5 - 13 / 16) * math.sqrt(5) / 2, 1e-9)
	end)

	t.test("items: every drop and every variant's item exists (checked when the registries load)", function()
		for block = 0, Blocks.count - 1 do
			local def = Blocks.get(block)
			if type(def.drops) == "string" then
				t.ok(Items.blockDrops(block) ~= nil, `{def.name} drops {def.drops}`)
			end
			if def.item then
				local item = Items.ofBlock(block)
				t.ok(item ~= nil and Items.get(item :: number).block ~= nil, `{def.name} is placed by {def.item}`)
				t.ok(table.find(Blocks.variants(Items.get(item :: number).block :: number), block) ~= nil)
			end
		end
	end)

	--[[ The server: attached blocks and water ]]

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

	-- A flat stone world with block updates; drops are collected in `dropped`.
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
		-- Loads the chunks around the origin.
		for cx = -1, 1 do
			for cz = -1, 1 do
				world:getChunk(cx, cz)
			end
		end
		return world, settle, dropped, ticker
	end

	t.test("attached: torches and lanterns break and drop when what holds them goes", function()
		local world, settle, dropped = newWorld()
		world:setBlock(0, FLOOR, 0, TORCH)
		world:setBlock(3, FLOOR, 0, STONE)
		world:setBlock(4, FLOOR, 0, EAST)
		world:setBlock(6, FLOOR + 3, 0, STONE)
		world:setBlock(6, FLOOR + 2, 0, HANGING)
		world:setBlock(8, FLOOR, 0, LANTERN)
		settle()
		t.eq(world:getBlock(0, FLOOR, 0), TORCH, "supported torches stay")
		t.eq(world:getBlock(4, FLOOR, 0), EAST)
		t.eq(world:getBlock(6, FLOOR + 2, 0), HANGING)
		t.eq(#dropped, 0)

		-- A neighbour that is not the support changes nothing.
		world:setBlock(1, FLOOR, 0, STONE)
		world:setBlock(4, FLOOR, 1, STONE)
		settle()
		t.eq(world:getBlock(0, FLOOR, 0), TORCH)
		t.eq(world:getBlock(4, FLOOR, 0), EAST)

		world:setBlock(0, FLOOR - 1, 0, AIR)
		world:setBlock(3, FLOOR, 0, AIR)
		world:setBlock(6, FLOOR + 3, 0, AIR)
		world:setBlock(8, FLOOR - 1, 0, Blocks.id.Glass)
		settle()
		t.eq(world:getBlock(0, FLOOR, 0), AIR, "the floor went")
		t.eq(world:getBlock(4, FLOOR, 0), AIR, "the wall went")
		t.eq(world:getBlock(6, FLOOR + 2, 0), AIR, "the ceiling went")
		t.eq(world:getBlock(8, FLOOR, 0), LANTERN, "glass holds a lantern")
		t.eq(#dropped, 3)
		local items = {}
		for _, drop in dropped do
			items[`{drop.x},{drop.y},{drop.z}`] = drop.item
		end
		t.eq(items[`0,{FLOOR},0`], Items.id.Torch)
		t.eq(items[`4,{FLOOR},0`], Items.id.Torch, "a wall torch drops a torch")
		t.eq(items[`6,{FLOOR + 2},0`], Items.id.Lantern, "a lantern drops without a pickaxe")

		-- Replacing the floor with water (not sturdy) also pops it.
		world:setBlock(8, FLOOR - 1, 0, WATER)
		settle()
		t.eq(world:getBlock(8, FLOOR, 0), AIR)
		Drops.set(nil)
	end)

	t.test("attached: a torch with an unloaded support waits instead of breaking", function()
		local world, _, dropped, ticker = newWorld()
		-- (Edge of the loaded area: x = 47 is the last loaded column, its east neighbour is not.)
		world:setBlock(47, FLOOR, 0, WEST)
		for _ = 1, 100 do
			ticker:step()
		end
		t.ok(ticker:pendingCount() > 0, "it keeps checking")
		t.eq(world:peekBlock(48, FLOOR, 0), nil, "the support's chunk is not loaded")
		t.eq(world:getBlock(47, FLOOR, 0), WEST, "kept while unknown")
		t.eq(#dropped, 0)
		Drops.set(nil)
	end)

	t.test("water: flowing water washes torches away and they drop; lanterns hold it back", function()
		local world, settle, dropped = newWorld()
		world:setBlock(1, FLOOR, 0, TORCH)
		world:setBlock(0, FLOOR, 2, LANTERN)
		-- A torch under where the water will pour down.
		world:setBlock(5, FLOOR + 3, 5, STONE)
		world:setBlock(5, FLOOR, 5, TORCH)
		settle()
		world:setBlock(0, FLOOR, 0, WATER)
		world:setBlock(5, FLOOR + 3, 5, WATER)
		settle()
		local washed = world:getBlock(1, FLOOR, 0)
		t.ok(Blocks.get(washed).fluid ~= nil, "water took the torch's place")
		t.eq(world:getBlock(0, FLOOR, 2), LANTERN, "the lantern stays")
		t.ok(Blocks.get(world:getBlock(5, FLOOR, 5)).fluid ~= nil, "falling water washed the other one")
		local torches = 0
		for _, drop in dropped do
			if drop.item == Items.id.Torch then
				torches += 1
			end
		end
		t.eq(torches, 2, "both torches dropped")
		Drops.set(nil)
	end)
end
