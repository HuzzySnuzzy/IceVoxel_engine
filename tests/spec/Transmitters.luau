--[[
	Mekanism pipes, the shared foundation: the tier numbers, the transmitter and tank blocks, the
	Configurator and buckets, sides, connection modes and their packing, colours, the connection
	rule both sides use (Transmitters.connects / connections), the furnace's and chest's sided
	slots (Minecraft's AbstractFurnaceBlockEntity), the insert / extract maths, the recipes, the
	sounds and the UseItem / Transmitters / Tanks / Transport messages.
]]

return function(t, shared, require, _server, client)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Crafting = require(shared.Crafting)
	local Machines = require(shared.Machines)
	local Menu = require(shared.Inventory.Menu)
	local Protocol = require(shared.Net.Protocol)
	local Sounds = require(shared.Sounds)
	local Transmitters = require(shared.Transmitters)
	local JeiData = require(client.Ui.Jei.JeiData)

	local B = Blocks.id
	local I = Items.id
	local M = Transmitters.MODES
	local NORMAL, PUSH, PULL, NONE = M.NORMAL, M.PUSH, M.PULL, M.NONE
	local DOWN, UP, NORTH, SOUTH, WEST, EAST = 0, 1, 2, 3, 4, 5
	local TIER_NAMES = { "Basic", "Advanced", "Elite", "Ultimate" }

	local function S(item: number, count: number, damage: number?)
		return { item = item, count = count, damage = damage }
	end

	-- Every transmitter and tank, by name.
	local TRANSPORTERS, PIPES, TANKS = {}, {}, {}
	for tier, name in TIER_NAMES do
		TRANSPORTERS[tier] = B[`{name}LogisticalTransporter`]
		PIPES[tier] = B[`{name}MechanicalPipe`]
		TANKS[tier] = B[`{name}FluidTank`]
	end
	local RESTRICTIVE = B.RestrictiveTransporter
	local BASIC_T, BASIC_P = TRANSPORTERS[1], PIPES[1]
	local CHEST, FURNACE = B.Chest, B.Furnace

	--[[ Tiers and blocks ]]

	t.test("transmitters: Mekanism's tier numbers (TransporterTier, PipeTier, FluidTankTier)", function()
		local expected = {
			{ 1, 5, 2000, 250, 32000, 1000 },
			{ 16, 10, 8000, 1000, 64000, 4000 },
			{ 32, 20, 32000, 8000, 128000, 16000 },
			{ 64, 50, 128000, 32000, 256000, 64000 },
		}
		t.eq(#Transmitters.TIERS, 4, "four tiers")
		for tier, row in expected do
			local entry = Transmitters.TIERS[tier]
			t.eq(entry.name, TIER_NAMES[tier], "name")
			t.eq(entry.transporterPull, row[1], `{entry.name} transporter pull`)
			t.eq(entry.transporterSpeed, row[2], `{entry.name} transporter speed`)
			t.eq(entry.pipeCapacity, row[3], `{entry.name} pipe capacity`)
			t.eq(entry.pipePull, row[4], `{entry.name} pipe pull`)
			t.eq(entry.tankCapacity, row[5], `{entry.name} tank capacity`)
			t.eq(entry.tankOutput, row[6], `{entry.name} tank output`)
			-- The block helpers read the same numbers.
			t.eq(Transmitters.pullAmount(TRANSPORTERS[tier]), row[1], "pullAmount (items)")
			t.eq(Transmitters.speed(TRANSPORTERS[tier]), row[2], "speed")
			t.eq(Transmitters.pipeCapacity(PIPES[tier]), row[3], "pipeCapacity")
			t.eq(Transmitters.pullAmount(PIPES[tier]), row[4], "pullAmount (mB)")
			t.eq(Transmitters.tankCapacity(TANKS[tier]), row[5], "tankCapacity")
			t.eq(Transmitters.tankOutput(TANKS[tier]), row[6], "tankOutput")
			t.eq(Blocks.get(TANKS[tier]).tank.capacity, row[5], "BlockList tank capacity")
			t.eq(Transmitters.tierOf(TRANSPORTERS[tier]), tier, "transporter tier")
			t.eq(Transmitters.tierOf(PIPES[tier]), tier, "pipe tier")
			t.eq(Transmitters.tierOf(TANKS[tier]), tier, "tank tier")
			t.eq(Transmitters.tier(PIPES[tier]), entry, "tier entry")
		end
		t.ok(not pcall(function()
			(Transmitters.TIERS :: any)[1].pipePull = 1
		end), "frozen")
		t.eq(Transmitters.BUCKET, 1000, "a bucket is 1000 mB")
		t.eq(Transmitters.PULL_DELAY, 10, "pull every 10 ticks")
		t.eq(Transmitters.BLOCK_PROGRESS, 100, "100 progress a block")
		-- Restrictive: a basic transporter that costs 1000 to pass.
		t.eq(Transmitters.tierOf(RESTRICTIVE), 1)
		t.eq(Transmitters.speed(RESTRICTIVE), 5)
		t.eq(Transmitters.pullAmount(RESTRICTIVE), 1)
		t.ok(Transmitters.isRestrictive(RESTRICTIVE) and not Transmitters.isRestrictive(BASIC_T), "restrictive")
		t.eq(Transmitters.pathCost(RESTRICTIVE), 1000)
		-- Mekanism's getCost: the Ultimate speed over the tier's (TransporterPathfinder's weights).
		for tier, cost in { 10, 5, 2.5, 1 } do
			t.eq(Transmitters.pathCost(TRANSPORTERS[tier]), cost, `{TIER_NAMES[tier]} path cost`)
		end
		t.eq(Transmitters.pathCost(TRANSPORTERS[4]), Transmitters.TRANSPORTER_COST, "the cheapest")
		t.eq(Transmitters.pathCost(BASIC_P), math.huge, "pipes carry no items")
		t.eq(Transmitters.pathCost(CHEST), math.huge)
		-- Nothing for other blocks.
		for _, block in { B.Stone, CHEST, B.Air } do
			t.eq(Transmitters.kindOf(block), nil)
			t.eq(Transmitters.tierOf(block), nil)
			t.eq(Transmitters.pullAmount(block), 0)
			t.eq(Transmitters.speed(block), 0)
			t.eq(Transmitters.pipeCapacity(block), 0)
			t.eq(Transmitters.tankCapacity(block), 0)
			t.eq(Transmitters.tankOutput(block), 0)
		end
		t.eq(Transmitters.speed(BASIC_P), 0, "pipes have no item speed")
		t.eq(Transmitters.pipeCapacity(BASIC_T), 0, "transporters hold no water")
	end)

	t.test("transmitters: the blocks are shaped, not solid, aimed at whole, and drop themselves", function()
		local names = {
			[BASIC_T] = "Basic Logistical Transporter",
			[TRANSPORTERS[4]] = "Ultimate Logistical Transporter",
			[RESTRICTIVE] = "Restrictive Transporter",
			[PIPES[3]] = "Elite Mechanical Pipe",
			[TANKS[2]] = "Advanced Fluid Tank",
		}
		for block, name in names do
			t.eq(Items.displayName(block), name, "display name")
		end
		local all = { RESTRICTIVE }
		for tier = 1, 4 do
			table.insert(all, TRANSPORTERS[tier])
			table.insert(all, PIPES[tier])
		end
		for _, block in all do
			local def = Blocks.get(block)
			local what = def.name
			t.ok(Transmitters.isTransmitter(block), `{what} is a transmitter`)
			t.eq(Transmitters.kindOf(block), if string.find(what, "Pipe") then "fluid" else "item", `{what} kind`)
			t.ok(not def.solid and not Blocks.isSolid(block), `{what} is not solid`)
			t.ok(not Blocks.isOpaque(block), `{what} hides nothing`)
			t.eq(def.kind, Blocks.KIND_TRANSPARENT, `{what} renders like glass`)
			t.ok(Blocks.isTargetable(block), `{what} can be aimed at`)
			t.eq(Blocks.outline(block), nil, `{what}: the whole cell is aimed at`)
			local obstruction = Blocks.obstruction(block)
			t.ok(obstruction ~= nil and obstruction[4] == 1 and obstruction[5] == 1, `{what} obstructs its cell`)
			t.eq(Blocks.soundType(block), "metal", `{what} sounds like metal`)
			t.eq(def.hardness, 1, `{what} hardness`)
			t.eq(def.tool, "pickaxe", `{what} tool`)
			t.ok(not Blocks.isSturdy(block), `{what} holds no torch`)
			t.ok(def.placeable and Items.get(block) ~= nil, `{what} is an item`)
			t.eq(Items.drops(block).item, block, `{what} drops itself by hand`)
			t.eq(Items.drops(block, I.IronPickaxe).item, block, `{what} drops itself`)
			t.ok(def.shape ~= nil and #def.shape <= Blocks.MAX_SHAPE_BOXES, `{what} shape`)
			-- The core fits in Mekanism's 8 pixels; the icon adds arms after the core's boxes.
			for i, box in def.shape :: { any } do
				for k = 1, 3 do
					t.ok(math.abs(box.offset[k]) + box.size[k] / 2 <= 4, `{what} box {i} inside the core`)
				end
			end
			local icon = def.icon
			assert(icon, `{what} has an icon`)
			t.ok(#icon > #(def.shape :: { any }), `{what} icon adds arms`)
			for i, box in def.shape :: { any } do
				t.eq(icon[i], box, `{what} icon starts with the shape`)
			end
			-- Glass is see-through, the frame is not.
			t.ok((def.shape :: { any })[1].transparency > 0, "glass")
			t.eq((def.shape :: { any })[2].transparency, 0, "frame")
			t.eq(Transmitters.isTank(block), false)
		end
		for tier, block in TANKS do
			local def = Blocks.get(block)
			t.ok(Transmitters.isTank(block), "a tank")
			t.ok(Transmitters.isFluidAcceptor(block), "pipes fill it")
			t.eq(Transmitters.kindOf(block), nil, "no transmitter")
			t.ok(def.solid and Blocks.isSolid(block), "tanks are solid")
			t.ok(Blocks.isSturdy(block), "a torch hangs on a tank")
			t.ok(not Blocks.isOpaque(block), "the water inside shows")
			t.eq(Blocks.outline(block), nil, "a whole cell")
			t.eq(def.hardness, 2)
			t.eq(def.tool, "pickaxe")
			t.eq(def.tank.tier, tier)
			t.eq(Items.drops(block).item, block, "drops itself")
		end
		-- Stone and torches keep their old rules.
		t.ok(Blocks.isSturdy(B.Stone), "stone is sturdy")
		t.ok(not Blocks.isSturdy(B.Torch), "torches are not")
		t.ok(Blocks.outline(B.Torch) ~= nil, "torches keep their outline")
	end)

	t.test("transmitters: the Configurator and buckets", function()
		t.eq(Items.maxStack(I.Configurator), 1)
		t.eq(Items.maxStack(I.Bucket), 16)
		t.eq(Items.maxStack(I.WaterBucket), 1)
		t.eq(Items.displayName(I.WaterBucket), "Water Bucket")
		for _, item in { I.Configurator, I.Bucket, I.WaterBucket } do
			local def = Items.get(item)
			t.ok(def.block == nil and def.model ~= nil and #def.model > 0, `{def.name} is drawn from boxes`)
			t.eq(Items.tool(item), nil, `{def.name} mines like a hand`)
		end
		t.eq(Items.get(I.Configurator).tilt, -45, "lies like a tool")
		t.ok(Items.search("bucket")[1] ~= nil, "found by search")
	end)

	--[[ Sides, modes and colours ]]

	t.test("transmitters: sides are Minecraft's Direction order, with offsets and opposites", function()
		t.eq(#Transmitters.SIDES, 6)
		for side = 0, 5 do
			local name = Transmitters.SIDES[side + 1]
			local d = Blocks.DIRECTIONS[name]
			local dx, dy, dz = Transmitters.offset(side)
			t.eq(dx, d[1], `{name} x`)
			t.eq(dy, d[2], `{name} y`)
			t.eq(dz, d[3], `{name} z`)
			t.eq(Transmitters.sideOf(dx, dy, dz), side, `{name} back`)
			t.eq(Transmitters.sideNamed(name), side, `{name} by name`)
			t.eq(Transmitters.sideName(side), name)
			local opposite = Transmitters.opposite(side)
			local ox, oy, oz = Transmitters.offset(opposite)
			t.ok(ox == -dx and oy == -dy and oz == -dz, `{name} opposite`)
			t.eq(Transmitters.opposite(opposite), side)
		end
		t.eq(Transmitters.SIDES[1], "Down")
		t.eq(Transmitters.SIDES[3], "North")
		local _, _, nz = Transmitters.offset(NORTH)
		t.eq(nz, -1, "north is -Z")
		local ex = Transmitters.offset(EAST)
		t.eq(ex, 1, "east is +X")
		t.eq(Transmitters.sideOf(1, 1, 0), nil)
		t.eq(Transmitters.sideNamed("Nope"), nil)
		t.ok(not pcall(Transmitters.offset, 6), "bad side")
		t.ok(not pcall(Transmitters.opposite, -1), "bad side")
	end)

	t.test("transmitters: modes cycle NORMAL, PUSH, PULL, NONE and pack 2 bits a side", function()
		t.eq(Transmitters.nextMode(NORMAL), PUSH)
		t.eq(Transmitters.nextMode(PUSH), PULL)
		t.eq(Transmitters.nextMode(PULL), NONE)
		t.eq(Transmitters.nextMode(NONE), NORMAL)
		t.eq(Transmitters.nextMode(7), NORMAL, "junk starts over")
		t.eq(Transmitters.modeName(PULL), "Pull")
		t.ok(Transmitters.outputs(NORMAL) and Transmitters.outputs(PUSH), "normal and push give")
		t.ok(not Transmitters.outputs(PULL) and not Transmitters.outputs(NONE), "pull and none don't")
		t.ok(Transmitters.pulls(PULL) and not Transmitters.pulls(NORMAL) and not Transmitters.pulls(PUSH))
		t.eq(Transmitters.DEFAULT_MODES, 0)
		t.eq(Transmitters.packModes({}), 0, "missing sides are NORMAL")
		-- Side 0 in the low bits.
		t.eq(Transmitters.packModes({ NONE }), 3)
		t.eq(Transmitters.packModes({ NORMAL, PULL }), 8)
		t.eq(Transmitters.packModes({ 0, 0, 0, 0, 0, NONE }), 3 * 1024)
		t.eq(Transmitters.packModes({ NONE, NONE, NONE, NONE, NONE, NONE }), 4095)
		-- Every combination round trips.
		for packed = 0, 4095 do
			local modes = Transmitters.unpackModes(packed)
			t.eq(#modes, 6)
			if Transmitters.packModes(modes) ~= packed then
				error(`{packed} does not round trip`)
			end
			for side = 0, 5 do
				if Transmitters.modeOf(packed, side) ~= modes[side + 1] then
					error(`{packed} side {side}`)
				end
			end
		end
		local packed = Transmitters.withMode(0, WEST, PULL)
		t.eq(Transmitters.modeOf(packed, WEST), PULL)
		t.eq(Transmitters.modeOf(packed, EAST), NORMAL)
		packed = Transmitters.withMode(packed, WEST, NORMAL)
		t.eq(packed, 0, "set back")
		t.ok(not pcall(Transmitters.packModes, { 4 }), "bad mode")
		t.ok(not pcall(Transmitters.withMode, 0, 6, 0), "bad side")
	end)

	t.test("transmitters: Minecraft's 16 dye colours, cycled none -> white -> ... -> black -> none", function()
		t.eq(#Transmitters.COLOURS, 16)
		t.eq(Transmitters.COLOURS[1].name, "white")
		t.eq(Transmitters.COLOURS[15].name, "red")
		t.eq(Transmitters.COLOURS[16].name, "black")
		t.eq(Transmitters.colourName(4), "Light Blue")
		t.eq(Transmitters.colourName(8), "Grey", "British spelling")
		t.eq(Transmitters.colourName(0), "None")
		t.eq(Transmitters.colourName(99), "None")
		local red = Transmitters.colourRgb(15)
		assert(red)
		t.ok(red[1] == 176 and red[2] == 46 and red[3] == 38, "DyeColor.RED's 0xB02E26")
		t.eq(Transmitters.colourRgb(0), nil)
		local colour, seen = 0, 0
		repeat
			colour = Transmitters.nextColour(colour)
			seen += 1
		until colour == 0 or seen > 20
		t.eq(seen, 17, "16 colours, then none")
		t.eq(Transmitters.nextColour(16), 0)
		t.eq(Transmitters.nextColour(-3), 0, "junk")
		t.ok(Transmitters.coloursMatch(0, 5) and Transmitters.coloursMatch(5, 0) and Transmitters.coloursMatch(5, 5))
		t.ok(not Transmitters.coloursMatch(5, 6))
		for _, entry in Transmitters.COLOURS do
			for k = 1, 3 do
				t.ok(entry.rgb[k] >= 0 and entry.rgb[k] <= 255, "rgb")
			end
		end
	end)

	--[[ Connections ]]

	t.test("transmitters: connects: kinds, tiers, NONE and colours between transmitters", function()
		local c = Transmitters.connects
		t.eq(c(BASIC_T, NORMAL, 0, BASIC_T, NORMAL, 0), "transmitter")
		t.eq(c(BASIC_T, NORMAL, 0, TRANSPORTERS[4]), "transmitter", "tiers mix")
		t.eq(c(BASIC_T, NORMAL, 0, RESTRICTIVE), "transmitter", "restrictive joins")
		t.eq(c(BASIC_P, NORMAL, 0, PIPES[3], NORMAL, 0), "transmitter", "pipes")
		t.eq(c(BASIC_T, NORMAL, 0, BASIC_P), nil, "transporters and pipes never join")
		t.eq(c(BASIC_P, NORMAL, 0, BASIC_T), nil)
		-- NONE on either side cuts it; PUSH and PULL still join transmitters.
		t.eq(c(BASIC_T, NONE, 0, BASIC_T, NORMAL, 0), nil, "own side none")
		t.eq(c(BASIC_T, NORMAL, 0, BASIC_T, NONE, 0), nil, "their side none")
		t.eq(c(BASIC_T, PUSH, 0, BASIC_T, PULL, 0), "transmitter", "push / pull")
		-- Colours: either uncoloured, or the same.
		t.eq(c(BASIC_T, NORMAL, 3, BASIC_T, NORMAL, 0), "transmitter")
		t.eq(c(BASIC_T, NORMAL, 0, BASIC_T, NORMAL, 3), "transmitter")
		t.eq(c(BASIC_T, NORMAL, 3, BASIC_T, NORMAL, 3), "transmitter")
		t.eq(c(BASIC_T, NORMAL, 3, BASIC_T, NORMAL, 4), nil, "different colours")
		t.eq(c(BASIC_T, NORMAL, 3, BASIC_T), "transmitter", "no state: uncoloured, normal")
		-- Mekanism's pipes have no colour: a stray one never cuts them apart.
		t.eq(c(BASIC_P, NORMAL, 3, PIPES[2], NORMAL, 4), "transmitter", "pipes ignore colours")
		t.eq(c(BASIC_P, NONE, 3, PIPES[2], NORMAL, 3), nil, "but not NONE")
		-- Items in transit (TransporterStack.canInsertToTransporter): one way, unlike connecting.
		t.ok(Transmitters.carries(0, 0) and Transmitters.carries(0, 5), "uncoloured transporters take all")
		t.ok(Transmitters.carries(5, 5), "a coloured one its own colour")
		t.ok(not Transmitters.carries(5, 0), "but no uncoloured items, though the two connect")
		t.ok(not Transmitters.carries(5, 6), "nor other colours")
		-- Not a transmitter: nothing.
		t.eq(c(B.Stone, NORMAL, 0, BASIC_T), nil)
		t.eq(c(CHEST, NORMAL, 0, BASIC_T), nil, "a chest connects to nothing itself")
		t.eq(c(TANKS[1], NORMAL, 0, BASIC_P), nil)
	end)

	t.test("transmitters: connects: acceptors of the transmitter's kind", function()
		local c = Transmitters.connects
		t.eq(c(BASIC_T, NORMAL, 0, CHEST), "acceptor", "chest")
		t.eq(c(BASIC_T, PULL, 0, FURNACE), "acceptor", "furnace")
		t.eq(c(BASIC_T, PUSH, 7, CHEST), "acceptor", "colours don't matter to acceptors")
		t.eq(c(BASIC_T, NONE, 0, CHEST), nil, "none")
		t.eq(c(BASIC_T, NORMAL, 0, B.CraftingTable), nil, "a crafting table keeps nothing")
		t.eq(c(BASIC_T, NORMAL, 0, TANKS[1]), nil, "items don't go into tanks")
		t.eq(c(BASIC_P, NORMAL, 0, TANKS[4]), "acceptor", "tank")
		t.eq(c(BASIC_P, NONE, 0, TANKS[4]), nil)
		t.eq(c(BASIC_P, NORMAL, 0, CHEST), nil, "water doesn't go into chests")
		t.eq(c(BASIC_P, NORMAL, 0, B.Air), nil)
		t.eq(c(BASIC_P, NORMAL, 0, Blocks.fluidId("Water", 0)), nil, "nor into the world")
		t.ok(Transmitters.isItemAcceptor(CHEST) and Transmitters.isItemAcceptor(FURNACE))
		t.ok(not Transmitters.isItemAcceptor(B.CraftingTable) and not Transmitters.isItemAcceptor(B.Stone))
		t.ok(Transmitters.isAcceptor("fluid", TANKS[3]) and not Transmitters.isAcceptor("item", TANKS[3]))
		-- Every block with slots is an item acceptor (a machine's slots are its kind's), unless
		-- transporters reach none of them (a Solar Panel's upgrade slots).
		local function reached(block: number): boolean
			for face = 0, 5 do
				if #Machines.insertSlots(block, face) > 0 or #Machines.extractSlots(block, face) > 0 then
					return true
				end
			end
			return not Machines.isMachine(block)
		end
		for block = 0, Blocks.count - 1 do
			t.eq(
				Transmitters.isItemAcceptor(block),
				Machines.containerSize(block) > 0 and reached(block),
				Blocks.get(block).name
			)
		end
		t.ok(not Transmitters.isItemAcceptor(B.SolarPanel), "only upgrade slots: no transporter connects")
	end)

	t.test("transmitters: connections gives the six sides as masks, from both sides' state", function()
		-- A transporter at the origin: a transporter east, a chest above, a pipe west, a coloured
		-- transporter south, a transporter north whose facing side is NONE, nothing loaded below.
		local world: { [string]: number } = {
			["1,0,0"] = BASIC_T,
			["0,1,0"] = CHEST,
			["-1,0,0"] = BASIC_P,
			["0,0,1"] = TRANSPORTERS[2],
			["0,0,-1"] = TRANSPORTERS[3],
		}
		local states: { [string]: { number } } = {
			["0,0,1"] = { 0, 5 },
			-- North of the origin: its south side (3) faces back.
			["0,0,-1"] = { Transmitters.withMode(0, SOUTH, NONE), 0 },
		}
		local function getBlock(x: number, y: number, z: number): number?
			if y < 0 then
				return nil
			end
			return world[`{x},{y},{z}`] or B.Air
		end
		local function getState(x: number, y: number, z: number): (number, number)
			local state = states[`{x},{y},{z}`]
			if state then
				return state[1], state[2]
			end
			return 0, 0
		end
		local function bit(side: number): number
			return bit32.lshift(1, side)
		end
		local tr, ac = Transmitters.connections(BASIC_T, 0, 0, 0, 0, 0, getBlock, getState)
		t.eq(tr, bit(EAST) + bit(SOUTH), "east and the coloured south (we are uncoloured)")
		t.eq(ac, bit(UP), "the chest")
		-- Coloured differently from the south one: it drops out.
		tr = Transmitters.connections(BASIC_T, 0, 6, 0, 0, 0, getBlock, getState)
		t.eq(tr, bit(EAST), "colour 6 vs 5")
		-- Our own NONE side to the chest.
		local modes = Transmitters.withMode(0, UP, NONE)
		tr, ac = Transmitters.connections(BASIC_T, modes, 0, 0, 0, 0, getBlock, getState)
		t.eq(ac, 0, "none to the chest")
		t.eq(tr, bit(EAST) + bit(SOUTH))
		-- Not a transmitter: no sides.
		tr, ac = Transmitters.connections(B.Stone, 0, 0, 0, 0, 0, getBlock, getState)
		t.eq(tr + ac, 0)
		-- Each pair agrees both ways (the east one sees us on its west side).
		local back = Transmitters.connections(BASIC_T, 0, 0, 1, 0, 0, function(x, y, z)
			return if x == 0 and y == 0 and z == 0 then BASIC_T else getBlock(x, y, z)
		end, getState)
		t.ok(bit32.btest(back, bit(WEST)), "mutual")
		t.eq(DOWN, 0)
	end)

	--[[ Sided inventories ]]

	t.test("inventories: the furnace's sides, as Minecraft's AbstractFurnaceBlockEntity", function()
		local function same(a: { number }, b: { number }, what: string)
			t.eq(#a, #b, `{what}: count`)
			for i = 1, #b do
				t.eq(a[i], b[i], `{what}: [{i}]`)
			end
		end
		-- getSlotsForFace: UP the input, DOWN the output then the fuel, the sides the fuel.
		same(Transmitters.insertSlots(FURNACE, UP), { 1 }, "up")
		same(Transmitters.insertSlots(FURNACE, DOWN), { 3, 2 }, "down")
		for _, side in { NORTH, SOUTH, WEST, EAST } do
			same(Transmitters.insertSlots(FURNACE, side), { 2 }, `side {side}`)
			same(Transmitters.extractSlots(FURNACE, side), { 2 }, `side {side} out`)
		end
		same(Transmitters.extractSlots(FURNACE, DOWN), { 3, 2 }, "down out")
		-- canPlaceItem: the input anything, the fuel only fuel, the output nothing.
		t.ok(Transmitters.canInsert(FURNACE, UP, 1, I.RawIron), "ore on top")
		t.ok(Transmitters.canInsert(FURNACE, UP, 1, I.Coal), "anything on top")
		t.ok(not Transmitters.canInsert(FURNACE, UP, 2, I.Coal), "the top reaches only the input")
		t.ok(Transmitters.canInsert(FURNACE, NORTH, 2, I.Coal), "coal in the side")
		t.ok(Transmitters.canInsert(FURNACE, EAST, 2, I.Planks), "planks burn")
		t.ok(not Transmitters.canInsert(FURNACE, NORTH, 2, I.Cobblestone), "cobblestone doesn't burn")
		t.ok(not Transmitters.canInsert(FURNACE, NORTH, 2, I.Bucket), "no lava here: buckets aren't fuel")
		t.ok(not Transmitters.canInsert(FURNACE, DOWN, 3, I.Coal), "never into the output")
		t.ok(Transmitters.canInsert(FURNACE, DOWN, 2, I.Coal), "the bottom feeds the fuel")
		t.ok(not Transmitters.canInsert(FURNACE, UP, 1, 65000), "unknown items")
		-- canTakeItemThroughFace: anything, but the fuel through the bottom only as buckets.
		t.ok(Transmitters.canExtract(FURNACE, DOWN, 3, I.IronIngot), "output from below")
		t.ok(not Transmitters.canExtract(FURNACE, DOWN, 2, I.Coal), "fuel stays")
		t.ok(Transmitters.canExtract(FURNACE, DOWN, 2, I.Bucket), "buckets come out")
		t.ok(Transmitters.canExtract(FURNACE, DOWN, 2, I.WaterBucket), "buckets come out")
		t.ok(Transmitters.canExtract(FURNACE, WEST, 2, I.Coal), "fuel from the side")
		t.ok(Transmitters.canExtract(FURNACE, UP, 1, I.RawIron), "input from the top")
		t.ok(not Transmitters.canExtract(FURNACE, UP, 3, I.IronIngot), "the top doesn't reach the output")
		-- Chests: every slot, every face, anything; blocks without slots: nothing.
		for side = 0, 5 do
			local slots = Transmitters.insertSlots(CHEST, side)
			t.eq(#slots, 27, "27 slots")
			t.eq(slots[27], 27)
			t.ok(Transmitters.canInsert(CHEST, side, 14, I.Dirt) and Transmitters.canExtract(CHEST, side, 14, I.Dirt))
		end
		t.ok(not Transmitters.canInsert(CHEST, UP, 28, I.Dirt), "no slot 28")
		t.eq(#Transmitters.insertSlots(B.CraftingTable, UP), 0, "crafting tables keep nothing")
		t.eq(#Transmitters.insertSlots(B.Stone, UP), 0)
		t.eq(#Transmitters.insertSlots(CHEST, 6), 0, "bad face")
	end)

	t.test("inventories: insert tops up stacks first, then empty slots, within the max stack", function()
		local slots = { [1] = S(I.Dirt, 60), [3] = S(I.Stone, 10), [5] = S(I.Dirt, 63) }
		local before = slots[1]
		local after, left = Transmitters.insert(CHEST, UP, slots, S(I.Dirt, 10))
		t.eq(left, nil, "all in")
		t.eq(after[1].count, 64, "slot 1 topped up")
		t.eq(after[5].count, 64, "then slot 5, before any empty slot")
		t.eq(after[2].count, 5, "the rest in the first empty slot")
		t.eq(after[2].item, I.Dirt)
		t.eq(after[3].count, 10, "other items untouched")
		-- Pure.
		t.eq(slots[1], before, "the input keeps its tables")
		t.eq(slots[1].count, 60, "and counts")
		t.eq(slots[2], nil)
		t.ok(after[1] ~= before, "changed slots get new tables")
		-- Wear must match; tools only go into empty slots, one per slot.
		local worn = { [1] = S(I.IronPickaxe, 1, 5) }
		local tools, toolsLeft = Transmitters.insert(CHEST, UP, worn, S(I.IronPickaxe, 1, 5))
		t.eq(toolsLeft, nil)
		t.eq(tools[1].count, 1, "tools don't stack")
		t.eq(tools[2].damage, 5, "wear travels")
		local swords = { [1] = S(I.Snowball, 10, nil) }
		local snow = Transmitters.insert(CHEST, UP, swords, S(I.Snowball, 10))
		t.eq(snow[1].count, 16, "snowballs stop at 16")
		t.eq(snow[2].count, 4)
		-- A full chest leaves the rest over.
		local full = {}
		for slot = 1, 27 do
			full[slot] = S(I.Stone, 64)
		end
		full[27] = S(I.Dirt, 50)
		local _, rest = Transmitters.insert(CHEST, EAST, full, S(I.Dirt, 20))
		t.ok(rest ~= nil and rest.item == I.Dirt and rest.count == 6, "14 fit, 6 left")
		t.eq(Transmitters.room(CHEST, EAST, full, S(I.Dirt, 20)), 14, "room agrees")
		-- Nothing fits: all left, a copy.
		local stone = S(I.Stone, 3)
		local same, all = Transmitters.insert(CHEST, EAST, full, stone)
		t.ok(all ~= nil and all.count == 3 and all ~= stone, "all left, as a new stack")
		t.eq(same[1], full[1])
		-- Unknown items go nowhere.
		local _, unknown = Transmitters.insert(CHEST, UP, {}, S(65000, 2))
		t.ok(unknown ~= nil and unknown.count == 2, "unknown item left over")
	end)

	t.test("inventories: insert into a furnace follows its sides", function()
		local empty = {}
		local top = Transmitters.insert(FURNACE, UP, empty, S(I.RawIron, 5))
		t.eq(top[1].count, 5, "the top fills the input")
		local _, cobble = Transmitters.insert(FURNACE, NORTH, empty, S(I.Cobblestone, 5))
		t.ok(cobble ~= nil and cobble.count == 5, "no cobblestone in the fuel")
		t.eq(Transmitters.room(FURNACE, NORTH, empty, S(I.Cobblestone, 5)), 0)
		local side = Transmitters.insert(FURNACE, NORTH, empty, S(I.Coal, 5))
		t.eq(side[2].count, 5, "coal into the fuel")
		local bottom, left = Transmitters.insert(FURNACE, DOWN, { [3] = S(I.IronIngot, 1) }, S(I.Coal, 70))
		t.eq(bottom[3].count, 1, "never into the output")
		t.eq(bottom[3].item, I.IronIngot)
		t.eq(bottom[2].count, 64, "the fuel fills")
		t.ok(left ~= nil and left.count == 6)
		t.eq(Transmitters.room(FURNACE, DOWN, {}, S(I.Coal, 70)), 64)
	end)

	t.test("inventories: available and extract (Mekanism's TransitRequest)", function()
		local slots = {
			[2] = S(I.Dirt, 10),
			[4] = S(I.Stone, 5),
			[6] = S(I.Dirt, 30),
			[7] = S(I.IronPickaxe, 1, 3),
			[8] = S(I.IronPickaxe, 1),
		}
		local types = Transmitters.available(CHEST, UP, slots)
		t.eq(#types, 4, "dirt, stone, two kinds of pickaxe")
		t.eq(types[1].item, I.Dirt)
		t.eq(types[1].count, 40, "totals over slots")
		t.eq(types[2].item, I.Stone)
		t.eq(types[3].damage, 3, "worn apart from new")
		t.eq(types[4].damage, nil)
		-- The first type, up to 16, gathered over its slots in order.
		local after, taken = Transmitters.extract(CHEST, UP, slots, 16)
		assert(taken)
		t.eq(taken.item, I.Dirt)
		t.eq(taken.count, 16)
		t.eq(after[2], nil, "slot 2 emptied")
		t.eq(after[6].count, 24, "6 more from slot 6")
		t.eq(slots[2].count, 10, "the input is untouched")
		-- One type asked for.
		local _, stone = Transmitters.extract(CHEST, UP, slots, 64, S(I.Stone, 1))
		t.ok(stone ~= nil and stone.count == 5, "all the stone")
		-- At most one stack: tools one at a time, and the wear asked for.
		local _, pick = Transmitters.extract(CHEST, UP, slots, 64, S(I.IronPickaxe, 1, 3))
		t.ok(pick ~= nil and pick.count == 1 and pick.damage == 3, "the worn pickaxe")
		local many = { [1] = S(I.Dirt, 64), [2] = S(I.Dirt, 64) }
		local _, capped = Transmitters.extract(CHEST, UP, many, 100)
		t.eq(capped and capped.count, 64, "a stack at most")
		-- Nothing to take.
		local _, none = Transmitters.extract(CHEST, UP, {}, 5)
		t.eq(none, nil)
		local _, zero = Transmitters.extract(CHEST, UP, slots, 0)
		t.eq(zero, nil)
		local nanSlots, nan = Transmitters.extract(CHEST, UP, slots, 0 / 0)
		t.eq(nan, nil, "NaN takes nothing")
		t.eq(nanSlots[2], slots[2], "and leaves the slots alone")
		-- Furnaces: the bottom gives the output, never fuel; the side gives fuel; the top input.
		local furnace = { [1] = S(I.RawIron, 3), [2] = S(I.Coal, 7), [3] = S(I.IronIngot, 2) }
		local below = Transmitters.available(FURNACE, DOWN, furnace)
		t.eq(#below, 1, "only the output")
		t.eq(below[1].item, I.IronIngot)
		local _, ingots = Transmitters.extract(FURNACE, DOWN, furnace, 64)
		t.eq(ingots and ingots.count, 2)
		local _, coal = Transmitters.extract(FURNACE, DOWN, furnace, 64, S(I.Coal, 1))
		t.eq(coal, nil, "no fuel through the bottom")
		local _, sideCoal = Transmitters.extract(FURNACE, SOUTH, furnace, 64)
		t.eq(sideCoal and sideCoal.item, I.Coal, "fuel from the side")
		local _, input = Transmitters.extract(FURNACE, UP, furnace, 1)
		t.eq(input and input.item, I.RawIron, "input from the top")
		t.eq(input and input.count, 1)
		local bucketFuel = { [2] = S(I.Bucket, 1) }
		local _, bucket = Transmitters.extract(FURNACE, DOWN, bucketFuel, 1)
		t.eq(bucket and bucket.item, I.Bucket, "an empty bucket leaves through the bottom")
	end)

	t.test("inventories: random inserts and extracts conserve items and respect stacks", function()
		local seed = 4242
		local function random(n: number): number
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed % n + 1
		end
		local pool = { I.Dirt, I.Stone, I.Coal, I.Snowball, I.IronPickaxe, I.RawIron, I.Planks, I.IronIngot }
		local function total(slots): { [string]: number }
			local out = {}
			for _, stack in slots do
				local key = `{stack.item}:{stack.damage or 0}`
				out[key] = (out[key] or 0) + stack.count
			end
			return out
		end
		for _ = 1, 300 do
			local block = if random(2) == 1 then CHEST else FURNACE
			local size = Blocks.get(block).container
			local slots = {}
			for slot = 1, size do
				if random(3) == 1 then
					local item = pool[random(#pool)]
					local damage = if item == I.IronPickaxe and random(2) == 1 then random(5) else nil
					slots[slot] = S(item, random(Items.maxStack(item)), damage)
				end
			end
			local face = random(6) - 1
			local item = pool[random(#pool)]
			local stack = S(item, random(64), nil)
			local before = total(slots)
			local after, left = Transmitters.insert(block, face, slots, stack)
			local inserted = stack.count - (if left then left.count else 0)
			t.eq(Transmitters.room(block, face, slots, stack), inserted, "room agrees with insert")
			local now = total(after)
			local key = `{item}:0`
			t.eq((now[key] or 0) - (before[key] or 0), inserted, "inserted items arrive")
			for slot, s in after do
				t.ok(s.count >= 1 and s.count <= math.min(Items.maxStack(s.item), 64), "within the max stack")
				if slots[slot] ~= s then
					t.ok(Transmitters.canInsert(block, face, slot, s.item), "only into allowed slots")
				end
			end
			-- Extract it again: never more than was there, and the slots lose exactly that.
			local wanted = Transmitters.available(block, face, after)[1]
			local again, taken = Transmitters.extract(block, face, after, random(80))
			if wanted == nil then
				t.eq(taken, nil)
			else
				assert(taken)
				t.ok(Menu.stacksMatch(taken, wanted), "the first available type")
				t.ok(taken.count <= wanted.count and taken.count <= Items.maxStack(taken.item), "bounded")
				local k = `{taken.item}:{taken.damage or 0}`
				t.eq((total(after)[k] or 0) - (total(again)[k] or 0), taken.count, "taken items leave")
			end
		end
	end)

	--[[ Fill levels ]]

	t.test("transmitters: fill bytes", function()
		t.eq(Transmitters.fillLevel(0, 2000), 0)
		t.eq(Transmitters.fillLevel(1, 128000), 1, "a drop shows")
		t.eq(Transmitters.fillLevel(2000, 2000), 255)
		t.eq(Transmitters.fillLevel(5000, 2000), 255, "clamped")
		t.eq(Transmitters.fillLevel(0 / 0, 2000), 0, "NaN")
		t.eq(Transmitters.fillLevel(10, 0), 0, "no capacity")
		t.eq(Transmitters.fillLevel(10, 0 / 0), 0, "NaN capacity")
		t.eq(Transmitters.fillLevel(math.huge, math.huge), 255, "full, however big")
		t.eq(Transmitters.fillLevel(1, math.huge), 1, "a drop in a bottomless tank")
		t.eq(Transmitters.fillAmount(255, 8000), 8000)
		t.near(Transmitters.fillAmount(Transmitters.fillLevel(4000, 8000), 8000), 4000, 8000 / 255)
		t.eq(Transmitters.fluidName(Transmitters.FLUIDS.WATER), "Water")
		t.eq(Transmitters.fluidName(Transmitters.FLUIDS.NONE), "Empty")
	end)

	--[[ Recipes, JEI, sounds ]]

	t.test("transmitters: recipes make every transmitter, tank, the Configurator and buckets", function()
		local function grid(rows: { string }, key: { [string]: number }): { [number]: any }
			local cells = {}
			for y, row in rows do
				for x = 1, #row do
					local char = string.sub(row, x, x)
					if char ~= " " then
						cells[(y - 1) * 3 + x] = S(key[char], 1)
					end
				end
			end
			return cells
		end
		local function makes(rows, key, item: number, count: number, what: string)
			local result = Crafting.match(grid(rows, key), 3)
			t.ok(result ~= nil and result.item == item, `{what}: made`)
			t.eq(result and result.count, count, `{what}: count`)
		end
		makes({ "I I", " I " }, { I = I.IronIngot }, I.Bucket, 1, "bucket")
		makes({ "IGI" }, { I = I.IronIngot, G = I.Glass }, BASIC_T, 8, "basic transporter")
		makes({ "IBI" }, { I = I.IronIngot, B = I.Bucket }, BASIC_P, 8, "basic pipe")
		makes({ "ITI" }, { I = I.IronIngot, T = BASIC_T }, RESTRICTIVE, 2, "restrictive")
		makes({ "IGI", "G G", "IGI" }, { I = I.IronIngot, G = I.Glass }, TANKS[1], 1, "basic tank")
		makes(
			{ " G ", "ISI", " S " },
			{ G = I.GlowstoneDust, I = I.IronIngot, S = I.Stick },
			I.Configurator,
			1,
			"configurator"
		)
		local alloys = { I.GoldIngot, I.Diamond, I.Emerald }
		for tier = 2, 4 do
			local alloy = alloys[tier - 1]
			makes(
				{ "TTT", "TAT", "TTT" },
				{ T = TRANSPORTERS[tier - 1], A = alloy },
				TRANSPORTERS[tier],
				8,
				`transporter {tier}`
			)
			makes({ "TTT", "TAT", "TTT" }, { T = PIPES[tier - 1], A = alloy }, PIPES[tier], 8, `pipe {tier}`)
			makes({ " A ", "ATA", " A " }, { T = TANKS[tier - 1], A = alloy }, TANKS[tier], 1, `tank {tier}`)
		end
		-- The wrong alloy makes nothing.
		t.eq(Crafting.match(grid({ "TTT", "TAT", "TTT" }, { T = BASIC_T, A = I.Diamond }), 3), nil, "wrong alloy")
		-- Every new item has a recipe, and JEI lists it.
		local new = { I.Bucket, I.Configurator, RESTRICTIVE }
		for tier = 1, 4 do
			table.insert(new, TRANSPORTERS[tier])
			table.insert(new, PIPES[tier])
			table.insert(new, TANKS[tier])
		end
		for _, item in new do
			t.ok(JeiData.has("recipes", item), `{Items.displayName(item)} has a recipe in JEI`)
		end
		t.ok(JeiData.has("uses", I.Bucket), "a bucket makes pipes")
		t.ok(not JeiData.has("recipes", I.WaterBucket), "water buckets are filled, not crafted")
	end)

	t.test("transmitters: bucket and Configurator sounds are the server's", function()
		for _, name in { "item.bucket.fill", "item.bucket.empty", "item.configurator.click" } do
			local event = Sounds.get(name)
			assert(event, `{name} exists`)
			t.eq(event.side, "server", `{name} side`)
			t.ok(not event.ui, `{name} plays in the world`)
		end
		t.eq(Sounds.get("item.bucket.fill").source, "players", "Minecraft: the player fills")
		t.eq(Sounds.get("item.bucket.empty").source, "blocks", "Minecraft: the block empties")
	end)

	--[[ Protocol ]]

	t.test("protocol: UseItem round trips and refuses junk", function()
		local b = Protocol.encodeUseItem(-123456, 700, 98765, EAST, true)
		local x, y, z, side, sneaking = Protocol.decodeUseItem(b)
		t.eq(x, -123456)
		t.eq(y, 700)
		t.eq(z, 98765)
		t.eq(side, EAST)
		t.eq(sneaking, true)
		local _, _, _, side2, sneaking2 = Protocol.decodeUseItem(Protocol.encodeUseItem(0, 0, 0, DOWN, false))
		t.eq(side2, DOWN)
		t.eq(sneaking2, false)
		t.eq(Protocol.ClientMessage.UseItem, 9)
		-- Malformed: length, side, flags, coordinates.
		t.eq((Protocol.decodeUseItem(buffer.create(11))), nil, "short")
		local bad = Protocol.encodeUseItem(0, 0, 0, 0, false)
		buffer.writeu8(bad, 10, 6)
		t.eq((Protocol.decodeUseItem(bad)), nil, "side 6")
		bad = Protocol.encodeUseItem(0, 0, 0, 0, false)
		buffer.writeu8(bad, 11, 2)
		t.eq((Protocol.decodeUseItem(bad)), nil, "unknown flag")
		t.eq((Protocol.decodeUseItem(Protocol.encodeUseItem(Protocol.MAX_COORDINATE + 1, 0, 0, 0, false))), nil, "far")
	end)

	t.test("protocol: Transmitters and Tanks records round trip", function()
		local records = {
			{
				x = -5,
				y = 1023,
				z = 70000,
				modes = Transmitters.packModes({ PULL, NONE, PUSH }),
				colour = 16,
				fluid = 255,
			},
			{ x = 2147483647, y = 0, z = -2147483648, modes = 4095, colour = 0, fluid = 1 },
		}
		local decoded = Protocol.decodeTransmitters(Protocol.encodeTransmitters(records))
		assert(decoded)
		t.eq(#decoded, 2)
		for i, record in records do
			for _, field in { "x", "y", "z", "modes", "colour", "fluid" } do
				t.eq(decoded[i][field], record[field], `transmitter {i} {field}`)
			end
		end
		t.eq(#(Protocol.decodeTransmitters(Protocol.encodeTransmitters({})) :: any), 0, "empty")
		t.eq(Protocol.decodeTransmitters(buffer.create(5)), nil, "malformed")
		-- Out of range: modes beyond the six sides' 12 bits, colours beyond the 16 dyes.
		local one = Protocol.encodeTransmitters({ records[1] })
		local badModes = buffer.create(buffer.len(one))
		buffer.copy(badModes, 0, one)
		buffer.writeu16(badModes, 4 + 10, 4096)
		t.eq(Protocol.decodeTransmitters(badModes), nil, "modes 4096")
		local badColour = buffer.create(buffer.len(one))
		buffer.copy(badColour, 0, one)
		buffer.writeu8(badColour, 4 + 12, 17)
		t.eq(Protocol.decodeTransmitters(badColour), nil, "colour 17")
		-- The encoder clamps into range, so it never writes what the decoder refuses.
		local clamped = Protocol.decodeTransmitters(
			Protocol.encodeTransmitters({ { x = 0, y = 0, z = 0, modes = 70000, colour = 40, fluid = 300 } })
		)
		assert(clamped, "clamped records decode")
		t.eq(clamped[1].modes, 4095)
		t.eq(clamped[1].colour, 16)
		t.eq(clamped[1].fluid, 255)
		local tanks = {
			{ x = 1, y = 2, z = 3, fluid = Transmitters.FLUIDS.WATER, amount = 256000 },
			{ x = -1, y = 900, z = -3, fluid = 0, amount = 0 },
		}
		local decodedTanks = Protocol.decodeTanks(Protocol.encodeTanks(tanks))
		assert(decodedTanks)
		t.eq(#decodedTanks, 2)
		for i, record in tanks do
			for _, field in { "x", "y", "z", "fluid", "amount" } do
				t.eq(decodedTanks[i][field], record[field], `tank {i} {field}`)
			end
		end
		t.eq(Protocol.decodeTanks(buffer.create(3)), nil, "malformed")
		local short = Protocol.encodeTanks(tanks)
		local cut = buffer.create(buffer.len(short) - 1)
		buffer.copy(cut, 0, short, 0, buffer.len(cut))
		t.eq(Protocol.decodeTanks(cut), nil, "cut short")
		t.eq(Protocol.ServerMessage.Transmitters, 8)
		t.eq(Protocol.ServerMessage.Tanks, 9)
		t.eq(Protocol.ServerMessage.Transport, 10)
	end)

	t.test("protocol: Transport adds and removes round trip", function()
		local long = {}
		for i = 1, 300 do
			long[i] = (i - 1) % 6
		end
		local ops = {
			{
				op = "add",
				id = 4000000000,
				item = I.IronPickaxe,
				count = 64,
				x = -100,
				y = 64,
				z = 2500,
				progress = 35,
				speed = 50,
				startTime = 1234567.890625,
				path = { EAST, EAST, UP, NORTH },
			},
			{ op = "remove", id = 7, reason = Protocol.TransportRemoveReason.Dropped },
			{
				op = "add",
				id = 8,
				item = I.Dirt,
				count = 1,
				x = 0,
				y = 0,
				z = 0,
				progress = 0,
				speed = 5,
				startTime = 0.5,
				path = {},
			},
			{
				op = "add",
				id = 9,
				item = I.Dirt,
				count = 3,
				x = 1,
				y = 2,
				z = 3,
				progress = 100,
				speed = 10,
				startTime = 99,
				path = long,
			},
		}
		local decoded = Protocol.decodeTransport(Protocol.encodeTransport(ops :: any))
		assert(decoded)
		t.eq(#decoded, 4)
		local first = decoded[1] :: any
		for _, field in { "op", "id", "item", "count", "x", "y", "z", "progress", "speed", "startTime" } do
			t.eq(first[field], (ops[1] :: any)[field], `add {field}`)
		end
		t.eq(#first.path, 4)
		for i, side in (ops[1] :: any).path do
			t.eq(first.path[i], side, `path {i}`)
		end
		local removed = decoded[2] :: any
		t.eq(removed.op, "remove")
		t.eq(removed.id, 7)
		t.eq(removed.reason, 1)
		t.eq(#(decoded[3] :: any).path, 0, "an empty path")
		local longPath = (decoded[4] :: any).path
		t.eq(#longPath, Protocol.MAX_PATH, "long paths are cut at 255 sides")
		t.eq(longPath[255], long[255])
		-- Malformed: an unknown op, a side beyond 5, cut short, trailing bytes.
		local good = Protocol.encodeTransport({ ops[1] } :: any)
		local badSide = buffer.create(buffer.len(good))
		buffer.copy(badSide, 0, good)
		buffer.writeu8(badSide, 4 + 29, 9)
		t.eq(Protocol.decodeTransport(badSide), nil, "side 9")
		local badOp = buffer.create(buffer.len(good))
		buffer.copy(badOp, 0, good)
		buffer.writeu8(badOp, 4, 3)
		t.eq(Protocol.decodeTransport(badOp), nil, "op 3")
		local cut = buffer.create(buffer.len(good) - 1)
		buffer.copy(cut, 0, good, 0, buffer.len(cut))
		t.eq(Protocol.decodeTransport(cut), nil, "cut short")
		local trailing = buffer.create(buffer.len(good) + 1)
		buffer.copy(trailing, 0, good)
		t.eq(Protocol.decodeTransport(trailing), nil, "trailing bytes")
		t.eq(#(Protocol.decodeTransport(Protocol.encodeTransport({})) :: any), 0, "empty")
	end)
end
