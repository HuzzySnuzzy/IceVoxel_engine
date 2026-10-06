--[[
	The client side of lava, oil and fuel, its pure parts:
	  * meshing: lava's sparse lights (one per FLUID_LIGHT_BOX box of its drawn cells, FLUID_LIT on
	    the height in the key), cave twins of fluids compared as their source, hidden cave twins,
	    far nodes without lights;
	  * the view from inside a fluid (Rendering/FluidFog): which fluid, Minecraft's fog distances
	    and colours, water vision, no garbage per frame;
	  * pipes and tanks in their fluid's colour, the new machines' glowing windows
	    (Rendering/TransmitterModel);
	  * the machines' tank gauges (Ui/MenuLayout), WAILA's fluid, pipe and machine lines;
	  * buckets on machines: only a bucket that fills or empties a tank skips the screen
	    (Interaction/TankUse);
	  * JEI's refining and generator categories with fluid stacks;
	  * the new sound events, lava's pops and bubbles (Audio/SoundRules), swimming sounds only in
	    fluids one swims in, and burning players (Player/BurningView).
]]

return function(t, shared, require, _server, client)
	local Blocks = require(shared.Blocks)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Fluids = require(shared.Fluids)
	local GreedyMesher = require(shared.Meshing.GreedyMesher)
	local Items = require(shared.Items)
	local Machines = require(shared.Machines)
	local Sounds = require(shared.Sounds)
	local SoundList = require(shared.Sounds.SoundList)
	local FluidFog = require(client.Rendering.FluidFog)
	local TransmitterModel = require(client.Rendering.TransmitterModel)
	local MenuLayout = require(client.Ui.MenuLayout)
	local WailaInfo = require(client.Ui.WailaInfo)
	local JeiData = require(client.Ui.Jei.JeiData)
	local JeiLayout = require(client.Ui.Jei.JeiLayout)
	local SoundRules = require(client.Audio.SoundRules)
	local BurningView = require(client.Player.BurningView)
	local TankUse = require(client.Interaction.TankUse)

	local B = Blocks.id
	local SIZE = ChunkLayout.SIZE
	local STRIDE = GreedyMesher.KEY_STRIDE
	local LAVA = Blocks.fluidId("Lava", 0)
	local LAVA_APP = Blocks.get(LAVA).appearance

	-- A chunk column `height` cells tall: stone up to y 3, then `fill(x, y, z)` (nil: air).
	local function column(height: number, fill: (x: number, y: number, z: number) -> number?): buffer
		local data = ChunkLayout.create(height)
		for y = 0, height - 1 do
			for z = -1, SIZE do
				for x = -1, SIZE do
					local block = if y <= 3 then B.Stone else (fill(x, y, z) or Blocks.AIR)
					ChunkLayout.setPadded(data, x, y, z, block)
				end
			end
		end
		return data
	end

	-- The boxes of a mesh as { x, y, z, sx, sy, sz, appearance, surface }.
	local function boxesOf(mesh: buffer, count: number): { { number } }
		local list = {}
		for b = 0, count - 1 do
			local o = b * GreedyMesher.BOX_BYTES
			local app, surface = GreedyMesher.decodeKey(buffer.readu16(mesh, o + 12))
			table.insert(list, {
				buffer.readu16(mesh, o),
				buffer.readu16(mesh, o + 2),
				buffer.readu16(mesh, o + 4),
				buffer.readu16(mesh, o + 6),
				buffer.readu16(mesh, o + 8),
				buffer.readu16(mesh, o + 10),
				app,
				surface,
			})
		end
		return list
	end

	local function texts(info: WailaInfo.Info): { string }
		return WailaInfo.texts(info)
	end
	local function has(lines: { string }, text: string, message: string?)
		t.ok(table.find(lines, text) ~= nil, `{message or text}: missing "{text}" in {table.concat(lines, " | ")}`)
	end

	--[[ Meshing ]]

	t.test("lava lights: one per 16-block box of drawn lava, FLUID_LIT on its height", function()
		t.eq(buffer.readu8(GreedyMesher.sparseLightLut, LAVA_APP), 1, "lava is a sparse light")
		t.eq(buffer.readu8(GreedyMesher.sparseBoxLut, LAVA_APP), GreedyMesher.FLUID_LIGHT_BOX)
		t.eq(GreedyMesher.FLUID_LIGHT_BOX, 16)
		t.eq(buffer.readu8(Blocks.singleLut, LAVA_APP), 0, "never one box per cell")
		for _, name in { "Water", "Oil", "Fuel" } do
			t.eq(buffer.readu8(GreedyMesher.sparseLightLut, Blocks.get(B[name]).appearance), 0, `{name} gives no light`)
		end
		local lichen = Blocks.get(B.GlowLichen).appearance
		t.eq(buffer.readu8(GreedyMesher.sparseBoxLut, lichen), GreedyMesher.LIGHT_BOX, "lichen keeps its 8")
		local height, lit = GreedyMesher.fluidSurface(8 + GreedyMesher.FLUID_LIT)
		t.eq(height, 8)
		t.ok(lit, "lit")
		t.eq(GreedyMesher.fluidSurface(5), 5)
		t.ok(not select(2, GreedyMesher.fluidSurface(0)), "full height, unlit")

		-- A lava pool over the whole chunk at y 4 (sources: 8 / 9 high), meshed as one section.
		local data = column(16, function(_x, y, _z)
			return if y == 4 then LAVA else nil
		end)
		local mesh, count = GreedyMesher.mesh(data, 16, 0, 16, false)
		local lights, cells, unlit = 0, 0, 0
		for _, b in boxesOf(mesh, count) do
			if b[7] == LAVA_APP then
				cells += b[4] * b[5] * b[6]
				local surface, carries = GreedyMesher.fluidSurface(b[8])
				t.eq(surface, 8, "a source's surface")
				if carries then
					lights += 1
					t.eq(b[4] * b[5] * b[6], 1, "the light's cell is a box of its own")
					-- (Nearest the box's centre: cell 7 on a tie, the lowest / northmost / westmost.)
					t.eq(b[1], 7)
					t.eq(b[3], 7)
				else
					unlit += 1
				end
			end
		end
		t.eq(cells, SIZE * SIZE, "every cell drawn once")
		t.eq(lights, 1, "one light for the chunk's 16 x 16 surface")
		t.ok(unlit <= 4, `the sheet around it splits into a few boxes ({unlit})`)
		-- Far nodes: no light, one sheet.
		local far, farCount = GreedyMesher.mesh(data, 16, 0, 16, false, nil, nil, true)
		local farLava = 0
		for _, b in boxesOf(far, farCount) do
			if b[7] == LAVA_APP then
				farLava += 1
				t.ok(not select(2, GreedyMesher.fluidSurface(b[8])), "no light far away")
			end
		end
		t.eq(farLava, 1, "far away the lake is one box")
		-- The same blocks light the same cell every time.
		local again = GreedyMesher.mesh(data, 16, 0, 16, false)
		t.eq(buffer.tostring(again), buffer.tostring(mesh), "steady")
	end)

	t.test("lava lights: lava and glow lichen choose apart; flowing lava keeps its height", function()
		-- Lava at y 4 in the west half, lichen on the floor of the east half's cave air.
		local data = column(16, function(x, y, _z)
			if y == 4 and x < 8 then
				return Blocks.fluidId("Lava", 3)
			elseif y == 4 then
				return B.GlowLichen
			end
			return nil
		end)
		local mesh, count = GreedyMesher.mesh(data, 16, 0, 16, false)
		local lavaLights, lichenLights = 0, 0
		for _, b in boxesOf(mesh, count) do
			if b[7] == LAVA_APP then
				local surface, carries = GreedyMesher.fluidSurface(b[8])
				t.eq(surface, 5, "flowing level 3 stands 5 / 9 high")
				if carries then
					lavaLights += 1
				end
			elseif buffer.readu8(GreedyMesher.sparseLightLut, b[7]) == 1 and b[8] == 1 then
				lichenLights += 1
			end
		end
		t.eq(lavaLights, 1, "one for the lava")
		t.eq(lichenLights, 2, "lichen still one per 8 x 8 box (two in the east half)")
	end)

	t.test("cave twins of fluids: CaveLava is lava to its neighbours, cave air while hidden", function()
		-- A lava sea half CaveLava, half Lava: the same boxes as all Lava (no wall between them).
		local function sea(west: number, east: number): buffer
			return column(16, function(x, y, _z)
				if y >= 4 and y <= 6 then
					return if x < 8 then west else east
				end
				return nil
			end)
		end
		local mixed, mixedCount = GreedyMesher.mesh(sea(B.CaveLava, LAVA), 16, 0, 16, false)
		local plain, plainCount = GreedyMesher.mesh(sea(LAVA, LAVA), 16, 0, 16, false)
		t.eq(mixedCount, plainCount, "no wall between twin and lava")
		t.eq(buffer.tostring(mixed), buffer.tostring(plain), "the same mesh")
		t.eq(buffer.readu16(GreedyMesher.fluidFormLut, B.CaveLava * 2), LAVA, "a twin compares as its source")
		t.eq(buffer.readu16(GreedyMesher.fluidFormLut, B.CaveOil * 2), Blocks.fluidId("Oil", 0))
		t.eq(buffer.readu16(GreedyMesher.fluidFormLut, B.Stone * 2), B.Stone)
		-- Different fluids still meet in a wall.
		local _, twoCount = GreedyMesher.mesh(sea(Blocks.fluidId("Oil", 0), LAVA), 16, 0, 16, false)
		t.ok(twoCount > plainCount, "oil against lava is drawn")
		-- Hidden caves: a cave of twins under rock is nothing to draw, lights included.
		local buried = column(24, function(_x, y, _z)
			if y >= 5 and y <= 8 then
				return B.CaveLava
			elseif y >= 9 and y <= 12 then
				return Blocks.CAVE_AIR
			end
			return if y <= 20 then B.Stone else nil
		end)
		local hidden, hiddenCount = GreedyMesher.mesh(buried, 24, 0, 24, true)
		for _, b in boxesOf(hidden, hiddenCount) do
			t.ok(b[7] ~= LAVA_APP, "no lava drawn while caves are hidden")
		end
		local shown, shownCount = GreedyMesher.mesh(buried, 24, 0, 24, false)
		local lit = 0
		for _, b in boxesOf(shown, shownCount) do
			if b[7] == LAVA_APP and select(2, GreedyMesher.fluidSurface(b[8])) then
				lit += 1
			end
		end
		t.eq(lit, 1, "revealed, the cave's lava lights its box")
	end)

	--[[ The view from inside a fluid ]]

	t.test("fluid view: the fluid at the camera, below its surface", function()
		local WATER = Blocks.fluidId("Water", 0)
		local blocks: { [string]: number } = {
			["0,5,0"] = LAVA,
			["0,6,0"] = LAVA,
			["1,5,0"] = Blocks.fluidId("Lava", 7),
			["2,5,0"] = B.CaveOil,
			["3,5,0"] = WATER,
			["4,5,0"] = B.Stone,
		}
		local function getBlock(x: number, y: number, z: number): number?
			return blocks[`{x},{y},{z}`] or Blocks.AIR
		end
		t.eq(FluidFog.cameraFluid(getBlock, 0.5, 5.95, 0.5), Fluids.LAVA, "lava above: the whole block")
		t.eq(FluidFog.cameraFluid(getBlock, 0.5, 6.85, 0.5), Fluids.LAVA, "a source's 8 / 9")
		t.eq(FluidFog.cameraFluid(getBlock, 0.5, 6.95, 0.5), 0, "above its surface")
		t.eq(FluidFog.cameraFluid(getBlock, 1.5, 5.05, 0.5), Fluids.LAVA, "flowing level 7: 1 / 9")
		t.eq(FluidFog.cameraFluid(getBlock, 1.5, 5.2, 0.5), 0, "above it")
		t.eq(FluidFog.cameraFluid(getBlock, 2.5, 5.5, 0.5), Fluids.OIL, "a cave twin is its fluid")
		t.eq(FluidFog.cameraFluid(getBlock, 3.5, 5.5, 0.5), Fluids.WATER)
		t.eq(FluidFog.cameraFluid(getBlock, 4.5, 5.5, 0.5), 0, "stone")
		t.eq(
			FluidFog.cameraFluid(function()
				return nil
			end, 0, 0, 0),
			0,
			"nothing loaded"
		)
	end)

	t.test("fluid view: Minecraft's fog distances, colours and water vision", function()
		-- Lava: 0.25 .. 1 block; spectators see half the view distance.
		local start, finish = FluidFog.fog(Fluids.LAVA, false, 0, 256)
		t.eq(start, 0.25)
		t.eq(finish, 1)
		start, finish = FluidFog.fog(Fluids.LAVA, true, 0, 256)
		t.eq(start, 0, "Roblox's fog starts at 0 at the nearest")
		t.eq(finish, 128)
		-- Oil 0 .. 2, fuel 0 .. 32.
		t.eq(select(2, FluidFog.fog(Fluids.OIL, false, 0, 256)), 2)
		t.eq(select(2, FluidFog.fog(Fluids.FUEL, false, 0, 256)), 32)
		-- Water: 96 times the vision, at least a quarter; never past the view distance.
		t.eq(select(2, FluidFog.fog(Fluids.WATER, false, 0, 256)), 24)
		t.eq(select(2, FluidFog.fog(Fluids.WATER, false, 1, 256)), 96)
		t.eq(select(2, FluidFog.fog(Fluids.WATER, false, 1, 64)), 64)
		t.eq(FluidFog.fog(0, false, 1, 64), nil, "no fluid, no fog")
		-- LocalPlayer.getWaterVision: 60% after 100 ticks, all after 600.
		t.eq(FluidFog.vision(0), 0)
		t.ok(math.abs(FluidFog.vision(100) - 0.6) < 1e-6, "100 ticks")
		t.eq(FluidFog.vision(600), 1)
		local ticks = 0
		for _ = 1, 700 do
			ticks = FluidFog.stepVision(ticks, true, false)
		end
		t.eq(ticks, FluidFog.VISION_TICKS, "capped")
		t.eq(FluidFog.stepVision(5, false, false), 0, "out of water it drops 10 a tick")
		t.eq(FluidFog.stepVision(0, true, true), 10, "spectators: 10 a tick")
		-- Colours: lava Minecraft's 0.6, 0.1, 0 whatever the light; water brightens with vision and
		-- darkens with the light.
		local lava = FluidFog.colour(Fluids.LAVA, 0, 0) :: { number }
		t.eq(lava[1], 153)
		t.eq(lava[2], 26)
		t.eq(lava[3], 0)
		local dim = FluidFog.colour(Fluids.WATER, 0, 1) :: { number }
		local clear = FluidFog.colour(Fluids.WATER, 1, 1) :: { number }
		t.eq(clear[3], 255, "full vision: its brightest blue")
		t.ok(dim[3] < clear[3], "dimmer before the eyes get used to it")
		local night = FluidFog.colour(Fluids.WATER, 1, 0.2) :: { number }
		t.ok(night[3] < clear[3], "darker with less light")
		t.eq(FluidFog.colour(0, 1, 1), nil)
		-- The tint goes towards the fluid's colour, white without one.
		local tint = FluidFog.tint(Fluids.LAVA)
		t.ok(tint[1] > tint[3], "lava tints orange")
		local none = FluidFog.tint(0)
		t.ok(none[1] == 255 and none[2] == 255 and none[3] == 255, "no tint")
		t.ok(FluidFog.light(6000, 1) > FluidFog.light(18000, 1), "day is brighter than night")
		t.eq(FluidFog.light(6000, 0), 0, "deep underground")
	end)

	t.test("fluid view: a frame in an unchanging fluid works in numbers and makes no garbage", function()
		-- `rgb` is `colour` as three numbers; each fluid's tint is worked out once.
		for _, fluid in { Fluids.WATER, Fluids.LAVA, Fluids.OIL, Fluids.FUEL } do
			local list = FluidFog.colour(fluid, 0.5, 0.6) :: { number }
			local r, g, b = FluidFog.rgb(fluid, 0.5, 0.6)
			t.ok(r == list[1] and g == list[2] and b == list[3], Fluids.name(fluid))
			t.ok(FluidFog.tint(fluid) == FluidFog.tint(fluid), `{Fluids.name(fluid)}: one tint`)
			t.ok(table.isfrozen(FluidFog.tint(fluid)), "shared, so frozen")
		end
		t.eq(select("#", FluidFog.rgb(0, 1, 1)), 3)
		t.ok(FluidFog.tint(0) == FluidFog.tint(0), "no tint, one table")
		-- What `start` works out each frame: no heap growth over many frames (the old frame made a
		-- colour and a tint table, a closure and a key string every frame: about 70 KB per
		-- thousand).
		local function frame(fluid: number): number
			local vision = FluidFog.vision(600)
			local start, finish = FluidFog.fog(fluid, false, vision, 256)
			local r, g, b = FluidFog.rgb(fluid, vision, 0.8)
			local tint = FluidFog.tint(fluid)
			return (start or 0) + (finish or 0) + r + g + b + tint[1]
		end
		for _, fluid in { Fluids.WATER, Fluids.LAVA, Fluids.OIL, Fluids.FUEL } do
			frame(fluid)
			local before = gcinfo()
			local peak = before
			for _ = 1, 5000 do
				frame(fluid)
				peak = math.max(peak, gcinfo())
			end
			t.ok(peak - before < 4, `{Fluids.name(fluid)}: the heap grew by {peak - before} KB`)
		end
	end)

	--[[ Pipes, tanks and machines ]]

	t.test("pipes and tanks: each fluid in its colour, lava glowing", function()
		for id, fluid in Fluids.list do
			local colour = TransmitterModel.fluidColour(id)
			t.ok(
				colour[1] == fluid.color[1] and colour[2] == fluid.color[2] and colour[3] == fluid.color[3],
				fluid.name
			)
			t.eq(TransmitterModel.fluidKind(id), if fluid.light > 0 then "molten" else "water", fluid.name)
		end
		t.ok(TransmitterModel.fluidColour(0) == TransmitterModel.WATER_COLOUR, "unknown: water")
		local tank = TransmitterModel.tankBoxes(B.BasicFluidTank, Fluids.LAVA, 16000)
		t.eq(#tank, 1)
		t.eq(tank[1].kind, "molten")
		t.eq(tank[1].colour[1], Fluids.list[Fluids.LAVA].color[1])
		local oil = TransmitterModel.tankBoxes(B.BasicFluidTank, Fluids.OIL, 16000)
		t.eq(oil[1].kind, "water", "oil: translucent")
		local pipe = TransmitterModel.transmitterBoxes(B.BasicMechanicalPipe, 0, 0, 255, 0, 1, Fluids.FUEL)
		local fuel = 0
		for _, box in pipe do
			if box.kind == "water" then
				fuel += 1
				t.eq(box.colour[2], Fluids.list[Fluids.FUEL].color[2], "fuel's amber")
			end
		end
		t.ok(fuel >= 2, "the core and the arm down")
		-- The Oil Refinery's heater and the Combustion Generator's chamber light while they work.
		for _, name in { "OilRefinery", "CombustionGenerator" } do
			local block = B[name]
			t.ok(TransmitterModel.hasMachineBoxes(block), name)
			local idle = TransmitterModel.machineBoxes(block, { active = false, energy = 0, capacity = 1 })
			local working = TransmitterModel.machineBoxes(block, { active = true, energy = 0, capacity = 1 })
			t.eq(#idle, 0, `{name}: dark when idle`)
			t.eq(#working, 4, `{name}: four lit sides`)
		end
	end)

	t.test("machine panels: a gauge per tank, filled in its fluid's colour", function()
		local function panelOf(name: string): (MenuLayout.Panel, any)
			local block = B[name]
			local container = Machines.newContainer(block)
			return MenuLayout.panel(container), container
		end
		local heat, heatContainer = panelOf("HeatGenerator")
		t.eq(#heat.tanks, 1, "the Heat Generator's lava")
		t.eq(heat.tanks[1].frame.w, 18)
		t.eq(heat.tanks[1].frame.h, 60, "Mekanism's standard gauge")
		t.eq(heat.tanks[1].inner.h, 58)
		local refinery = panelOf("OilRefinery")
		t.eq(#refinery.tanks, 2, "oil and fuel")
		t.ok(refinery.progress ~= nil, "the refinery's arrow")
		local combustion = panelOf("CombustionGenerator")
		t.eq(#combustion.tanks, 1, "fuel")
		-- Gauges, slots, the arrow and the energy bar never overlap.
		for _, panel in { heat, refinery, combustion } do
			local rects = {}
			for _, tank in panel.tanks do
				table.insert(rects, tank.frame)
			end
			for _, spot in panel.slots do
				table.insert(rects, { x = spot.x - 1, y = spot.y - 1, w = 18, h = 18 })
			end
			for _, r in { panel.progress, panel.flame, panel.energy } do
				if r then
					table.insert(rects, r)
				end
			end
			for i, a in rects do
				t.ok(a.x >= 0 and a.y >= 0 and a.x + a.w <= panel.width and a.y + a.h <= panel.height, "inside")
				for j = i + 1, #rects do
					local b = rects[j]
					t.ok(
						a.x + a.w <= b.x or b.x + b.w <= a.x or a.y + a.h <= b.y or b.y + b.h <= a.y,
						`{panel.title}: parts {i} and {j} overlap`
					)
				end
			end
		end
		-- Rows: Mekanism's rounding, from the window's data.
		local spot = heat.tanks[1]
		local data = table.clone(heatContainer.data)
		data[spot.amount] = 12000
		t.eq(MenuLayout.tankFluid(data, spot), Fluids.LAVA)
		t.eq(MenuLayout.tankRows(data, spot), 29, "half of 58")
		data[spot.amount] = 24000
		t.eq(MenuLayout.tankRows(data, spot), 58, "full")
		data[spot.amount] = 0
		t.eq(MenuLayout.tankRows(data, spot), 0, "empty")
		t.eq(MenuLayout.tankRows(nil, spot), 0, "no data")
		data[spot.amount] = 5000
		local tooltip = MenuLayout.tankTooltip(data, spot)
		t.eq(tooltip[1], "Lava: 5,000 mB")
		t.eq(tooltip[2], "Capacity: 24,000 mB")
		t.eq(MenuLayout.tankTooltip(nil, spot)[1], "Empty")
		local colour = MenuLayout.tankColour(Fluids.OIL)
		t.eq(colour[1], Fluids.list[Fluids.OIL].color[1])
	end)

	t.test("buckets on machines: only a bucket that fills or empties a tank skips the screen", function()
		local I = Items.id
		local HEAT, COMBUSTION, REFINERY = B.HeatGenerator, B.CombustionGenerator, B.OilRefinery
		local BUCKETS = { I.Bucket, I.WaterBucket, I.LavaBucket, I.OilBucket, I.FuelBucket }
		-- A Machines record of `container`'s tanks (Machines.tankContents, as the server sends them).
		local function recordOf(container: any): any
			local tanks = {}
			for i, tank in Machines.tankContents(container) do
				tanks[i] = { fluid = tank.fluid, amount = tank.amount, capacity = tank.capacity }
			end
			local record = { x = 0, y = 0, z = 0, energy = 0, capacity = 0, input = 0, output = 0, rate = 0 }
			record.active, record.state, record.tanks = false, 0, tanks
			return record
		end
		-- What the server does with the bucket (UseRules: Machines.pourBucket / fillBucket).
		local function serverActs(container: any, item: number): boolean
			if item == I.Bucket then
				return Machines.fillBucket(container, true) ~= 0
			end
			return Machines.pourBucket(container, Fluids.ofBucket(item), true)
		end
		-- The examples: nothing would happen, so the screen opens.
		t.ok(not TankUse.acts(COMBUSTION, I.WaterBucket, nil), "water into a Combustion Generator")
		t.ok(not TankUse.acts(COMBUSTION, I.LavaBucket, nil), "lava into a Combustion Generator")
		t.ok(not TankUse.acts(HEAT, I.OilBucket, nil), "oil into a Heat Generator")
		t.ok(not TankUse.acts(REFINERY, I.Bucket, nil), "an empty bucket on a refinery with nothing")
		t.ok(TankUse.acts(COMBUSTION, I.FuelBucket, nil), "fuel into an empty Combustion Generator")
		local full = Machines.newContainer(COMBUSTION)
		Machines.tankInsert(full, "fuel", Fluids.FUEL, 9500)
		t.ok(not TankUse.acts(COMBUSTION, I.FuelBucket, recordOf(full)), "no room for a whole bucket")
		t.ok(not TankUse.acts(COMBUSTION, I.Bucket, recordOf(Machines.newContainer(COMBUSTION))), "empty")
		t.ok(TankUse.acts(COMBUSTION, I.Bucket, recordOf(full)), "its fuel back")
		-- Always what the server does, from its record's tanks (or none: every tank empty).
		local amounts = { 0, 500, 999, 1000, 9000, 9001, 24000 }
		for _, block in { HEAT, COMBUSTION, REFINERY } do
			local specs = Machines.tanks(block)
			local function each(i: number, container: any)
				if i > #specs then
					for _, item in BUCKETS do
						local name = `{Blocks.get(block).name}, {Items.get(item).name}`
						t.eq(TankUse.acts(block, item, recordOf(container)), serverActs(container, item), name)
					end
					return
				end
				for _, amount in amounts do
					local copy = Machines.newContainer(block)
					copy.data = table.clone(container.data)
					Machines.tankInsert(copy, i, specs[i].fluids[1], amount)
					each(i + 1, copy)
				end
			end
			each(1, Machines.newContainer(block))
			for _, item in BUCKETS do
				local empty = Machines.newContainer(block)
				t.eq(TankUse.acts(block, item, nil), serverActs(empty, item), "no record: empty tanks")
			end
		end
		-- A record without tanks (a server sending none): a tank taking the fluid, or an output.
		local bare = recordOf(Machines.newContainer(REFINERY))
		bare.tanks = nil
		t.ok(TankUse.acts(REFINERY, I.Bucket, bare), "an output tank may give")
		t.ok(TankUse.acts(REFINERY, I.OilBucket, bare))
		t.ok(not TankUse.acts(REFINERY, I.FuelBucket, bare), "fuel is its output")
		local bareHeat = recordOf(Machines.newContainer(HEAT))
		bareHeat.tanks = nil
		t.ok(not TankUse.acts(HEAT, I.Bucket, bareHeat), "input tanks only")
		-- Other items and blocks never skip a screen.
		t.ok(not TankUse.acts(COMBUSTION, I.Stone, nil))
		t.ok(not TankUse.acts(B.ElectricFurnace, I.LavaBucket, nil), "no tanks")
	end)

	--[[ WAILA ]]

	t.test("waila: fluids by name and light, pipes' fluid, machines' tanks", function()
		for _, block in { LAVA, Blocks.fluidId("Lava", 4), B.CaveLava } do
			local info = WailaInfo.block(block, nil, 0, 5, 0, false)
			local lines = texts(info)
			t.eq(lines[1], "Lava", Blocks.get(block).name)
			has(lines, "Light 15", "lava's light")
			t.eq(info.icon and info.icon.item, Items.id.Lava, "lava's icon")
		end
		has(texts(WailaInfo.block(LAVA, nil, 0, 5, 0, true)), "Light 15", "F3 says it too")
		t.eq(texts(WailaInfo.block(B.CaveOil, nil, 0, 5, 0, false))[1], "Oil")
		t.eq(WailaInfo.fluidLight(Blocks.fluidId("Fuel", 0)), nil, "fuel gives no light")
		t.eq(WailaInfo.fluidLight(B.Stone), nil)
		-- A pipe holding lava.
		local pipe = texts(WailaInfo.block(B.BasicMechanicalPipe, nil, 0, 64, 0, false, {
			transmitter = {
				modes = 0,
				colour = 0,
				fluid = 255,
				fluidId = Fluids.LAVA,
				items = 0,
				stacks = 0,
				transmitters = 0,
				acceptors = 0,
				networkSize = 1,
				networkCapacity = 2000,
				networkComplete = true,
			},
		}))
		has(pipe, "Lava: 2,000 / 2,000 mB")
		-- A tank of oil.
		has(
			texts(
				WailaInfo.block(
					B.BasicFluidTank,
					nil,
					0,
					64,
					0,
					false,
					{ tank = { fluid = Fluids.OIL, amount = 3000 } }
				)
			),
			"Oil: 3,000 / 32,000 mB"
		)
		-- A refinery's record with its tanks.
		local facts = WailaInfo.machineDefaults(B.OilRefinery)
		facts.tanks = {
			{ name = "oil", fluid = Fluids.OIL, amount = 3000, capacity = 10000 },
			{ name = "fuel", fluid = 0, amount = 0, capacity = 10000 },
		}
		local lines = texts(WailaInfo.block(B.OilRefinery, nil, 0, 64, 0, false, { machine = facts }))
		has(lines, "Oil: 3,000 / 10,000 mB")
		has(lines, "Empty: 0 / 10,000 mB")
		-- The Combustion Generator burning.
		local burning = WailaInfo.machineDefaults(B.CombustionGenerator)
		burning.rate = 2500
		burning.active = true
		has(
			texts(WailaInfo.block(B.CombustionGenerator, nil, 0, 64, 0, false, { machine = burning })),
			"Producing 2.5 kJ/t"
		)
	end)

	--[[ JEI ]]

	t.test("jei: refining and the generators' fluids, fluid stacks standing for their buckets", function()
		local function only(groups: { JeiData.Group }, category: string): JeiData.Entry?
			for _, group in groups do
				if group.category == category then
					return group.entries[1]
				end
			end
			return nil
		end
		local refining = only(JeiData.uses(Items.id.OilBucket), "refining")
		t.ok(refining ~= nil, "an Oil Bucket is refined")
		local entry = refining :: JeiData.Entry
		t.eq((entry.fluidInputs :: any)[1].fluid, Fluids.OIL)
		t.eq((entry.fluidInputs :: any)[1].amount, 1000)
		t.eq((entry.fluidOutput :: any).fluid, Fluids.FUEL)
		t.eq(entry.ticks, 100, "5 s a bucket")
		t.eq(entry.energy, 20000, "20 kJ")
		local texts1 = JeiData.fluidTexts(entry)
		t.eq(texts1[1], "5 s, 20 kJ")
		t.eq(texts1[2], "200 J/t")
		t.ok(only(JeiData.uses(Items.id.Oil), "refining") == entry, "oil's block too")
		t.ok(only(JeiData.recipes(Items.id.FuelBucket), "refining") == entry, "fuel comes from refining")
		t.ok(only(JeiData.uses(Items.id.OilRefinery), "refining") == entry, "the refinery is the catalyst")
		-- The generators.
		local heat = only(JeiData.uses(Items.id.LavaBucket), "heating") :: JeiData.Entry
		t.eq(heat.ticks, 20000, "a Lava Bucket's furnace burn time")
		t.eq(heat.energy, 4000000)
		t.eq(JeiData.fluidTexts(heat)[1], "Makes 4 MJ")
		t.eq(JeiData.fluidTexts(heat)[2], "200 J/t for 1000 s")
		local combustion = only(JeiData.uses(Items.id.FuelBucket), "combustion") :: JeiData.Entry
		t.eq(combustion.ticks, 4000)
		t.eq(combustion.energy, 10000000, "10 MJ a bucket")
		t.eq(JeiData.fluidTexts(combustion)[1], "Makes 10 MJ")
		t.eq(JeiData.fluidTexts(combustion)[2], "2.5 kJ/t for 200 s")
		t.ok(only(JeiData.uses(Items.id.CombustionGenerator), "combustion") == combustion, "its catalyst")
		-- Fluid stacks: the bucket, then the block.
		local items = JeiData.fluidItems(Fluids.LAVA)
		t.eq(items[1], Items.id.LavaBucket)
		t.eq(items[2], Items.id.Lava)
		t.eq(#JeiData.fluidItems(0), 0)
		t.eq(JeiData.fluidAmount({ fluid = Fluids.LAVA, amount = 1000 }), "1,000 mB")
		-- Their layouts have room for the fluid stacks.
		for _, category in { "refining", "heating", "combustion" } do
			local layout = JeiLayout.entry(category)
			t.ok(#layout.fluidInputs >= 1, `{category}: a fluid stack in`)
			t.eq(JeiData.TITLES[category] ~= nil, true)
		end
		t.ok(JeiLayout.entry("refining").fluidOutput ~= nil, "refining: a fluid stack out")
	end)

	--[[ Sounds and burning ]]

	t.test("sounds: lava's events, pops and bubbles; swimming only where one swims", function()
		for _, name in
			{
				"block.lava.pop",
				"block.lava.ambient",
				"block.lava.extinguish",
				"item.bucket.fill_lava",
				"item.bucket.empty_lava",
				"entity.generic.burn",
				"entity.generic.extinguish_fire",
			}
		do
			t.ok(Sounds.find(name) ~= nil, name)
		end
		t.eq((Sounds.get("block.lava.pop") :: any).side, "client", "each client pops its own lava")
		t.eq((Sounds.get("block.lava.extinguish") :: any).side, "server", "the server fizzes")
		for _, fluid in Fluids.list do
			t.ok(Sounds.find(fluid.fillSound) ~= nil and Sounds.find(fluid.emptySound) ~= nil, `{fluid.name}'s buckets`)
		end
		t.eq(SoundList.EVENTS[#SoundList.EVENTS].name, "entity.generic.extinguish_fire", "appended at the end")

		-- A lava sea at y 10 under air, and a random that always rolls 0: every sample lands on the
		-- listener's block, so the sea pops and bubbles at the odds' first roll.
		local function getBlock(_x: number, y: number, _z: number): number?
			return if y <= 10 then LAVA elseif y == 11 then Blocks.AIR else Blocks.AIR
		end
		local sounds = SoundRules.lavaTick(getBlock, 0, 10, 0, function()
			return 0
		end)
		t.eq(#sounds, 2 * SoundRules.LAVA_SAMPLES * 2, "every sample pops and bubbles at roll 0")
		t.eq(sounds[1].sound, "block.lava.pop")
		t.eq(sounds[1].y, 11, "on top of the lava")
		t.ok(sounds[1].volume >= 0.2 and sounds[1].volume <= 0.4, "Minecraft's volume")
		-- Under rock, or rolling high: nothing.
		local covered = SoundRules.lavaTick(
			function(_x, y, _z)
				return if y <= 10 then LAVA else B.Stone
			end,
			0,
			10,
			0,
			function()
				return 0
			end
		)
		t.eq(#covered, 0, "no air above: silent")
		local unlucky = SoundRules.lavaTick(getBlock, 0, 10, 0, function()
			return 0.999
		end)
		t.eq(#unlucky, 0, "high rolls: silent")
		-- On average the odds match Minecraft's 667 tries at 1 in 100 / 200.
		t.ok(math.abs(SoundRules.LAVA_POP * SoundRules.LAVA_SAMPLES - 6.67) < 1e-9, "pop odds")
		t.ok(math.abs(SoundRules.LAVA_AMBIENT * SoundRules.LAVA_SAMPLES - 3.335) < 1e-9, "ambient odds")

		-- Another character standing in lava makes no swim sound; in fuel it does.
		local function standing(fluid: number): boolean
			local _, inWater = SoundRules.observe(function(_x, y, _z)
				return if y == 0 then B.Stone elseif y == 1 then fluid else Blocks.AIR
			end, 0.5, 1, 0.5)
			return inWater
		end
		t.ok(not standing(LAVA), "lava: no swimming sounds")
		t.ok(not standing(Blocks.fluidId("Oil", 0)), "oil neither")
		t.ok(standing(Blocks.fluidId("Fuel", 0)), "fuel swims like water")
		t.ok(standing(Blocks.fluidId("Water", 0)), "water")
		t.ok(SoundRules.crackles(B.CombustionGenerator), "the Combustion Generator crackles while it burns")
	end)

	t.test("burning: the server's attribute shows flames", function()
		t.eq(BurningView.ON_FIRE, "IceVoxelOnFire", "server Players/Characters.ON_FIRE")
		t.ok(BurningView.onFire(true))
		t.ok(not BurningView.onFire(nil))
		t.ok(not BurningView.onFire(false))
	end)
end
