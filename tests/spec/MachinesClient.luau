--[[
	The client side of Mekanism's machines and Universal Cables, beyond tests/spec/Machines and
	Energy: the energy bar only looks full when it is (Mekanism's rounding down), a panel's status
	line reads the window's data without changing it, WAILA tells a cable side set to push or pull
	that it acts as normal, and F3's menu line counts a machine's slots (its kind's). The seasons'
	heaters, coolers and stoves: their panels' buttons (where, what they say, the action a click
	sends), the set point's text, no energy bar for the fuel-only ones; WAILA's status lines, no
	energy line at capacity 0, the viewer's room line and the Thermometer's reading; their decor,
	windows glowing in their colours, the stove's light, their loops; the stove in JEI.
]]

local FakeMachines = require("../lib/FakeMachines")

return function(t, shared, require, _server, client)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Machines = require(shared.Machines)
	local Smelting = require(shared.Crafting.Smelting)
	local Transmitters = require(shared.Transmitters)
	local MenuLayout = require(client.Ui.MenuLayout)
	local WailaInfo = require(client.Ui.WailaInfo)

	local B = Blocks.id
	local M = Transmitters.MODES
	local WEST, EAST = 4, 5
	local CABLE = B.BasicUniversalCable
	local PIPE = B.BasicMechanicalPipe
	local FURNACE_BLOCK = B.DiamondBlock
	FakeMachines.define(Machines, Items, Smelting)

	local function bit(side: number): number
		return bit32.lshift(1, side)
	end

	t.test("energy bar: full only when full, a sliver while it holds any", function()
		local function rows(energy: number, capacity: number): number
			return MenuLayout.energyRows({ energy, capacity, 0, 0, 0, 0 }, 52)
		end
		t.eq(rows(999, 1000), 51, "99.9 %: not full yet")
		t.eq(rows(1000, 1000), 52, "full")
		t.eq(rows(1, 52), 1, "one row's worth")
		t.eq(rows(1, 53), 1, "less than a row: still a sliver")
		t.eq(rows(26, 52), 26)
		t.eq(rows(0, 1000), 0, "empty")
		t.eq(rows(2000, 1000), 52, "over capacity: full")
		t.eq(rows(math.huge, math.huge), 52, "creative: full")
	end)

	t.test("panels: the status line reads the window's data and never writes it", function()
		FakeMachines.bind(
			Machines,
			{ { FURNACE_BLOCK, "test_furnace", { capacity = 20000, input = 20000 } } },
			function()
				-- (A window as the client holds it: read only, possibly without data.)
				local bare = { kind = "machine", block = FURNACE_BLOCK, size = 3, slots = {}, data = nil }
				t.eq(MenuLayout.statusText(bare :: any), "Idle")
				t.eq(bare.data, nil, "no data written into the client's window")
				local data = Machines.newData(FURNACE_BLOCK)
				local copy = table.clone(data)
				local container = { kind = "machine", block = FURNACE_BLOCK, size = 3, slots = {}, data = data }
				t.eq(MenuLayout.statusText(container :: any), "Idle")
				t.ok(container.data == data, "the same table")
				for i, v in copy do
					t.eq(data[i], v, `data[{i}] unchanged`)
				end
			end
		)
		-- The creative cube's own status line.
		local cube = { kind = "machine", block = B.CreativeEnergyCube, size = 0, slots = {}, data = nil }
		t.eq(MenuLayout.statusText(cube :: any), "Infinite energy")
		t.eq(cube.data, nil)
	end)

	t.test("waila: a cable's push and pull sides say they act as normal", function()
		local function sideText(block: number, mode: number): string?
			local facts = {
				modes = Transmitters.withMode(0, EAST, mode),
				colour = 0,
				fluid = 0,
				side = EAST,
				items = 0,
				stacks = 0,
				transmitters = bit(WEST),
				acceptors = 0,
				networkSize = 1,
				networkCapacity = 0,
				networkComplete = true,
			}
			for _, text in WailaInfo.texts(WailaInfo.block(block, nil, 0, 64, 0, false, { transmitter = facts })) do
				if string.sub(text, 1, 6) == "Side: " then
					return text
				end
			end
			return nil
		end
		t.eq(sideText(CABLE, M.PUSH), "Side: Push (as Normal)")
		t.eq(sideText(CABLE, M.PULL), "Side: Pull (as Normal)")
		t.eq(sideText(CABLE, M.NORMAL), "Side: Normal")
		t.eq(sideText(CABLE, M.NONE), "Side: None", "NONE cuts a cable as it does a pipe")
		t.eq(sideText(PIPE, M.PUSH), "Side: Push", "pipes push")
	end)

	t.test("waila: F3's menu line counts a machine's slots (its kind's)", function()
		local function menuLine(block: number): string?
			for _, text in WailaInfo.texts(WailaInfo.block(block, nil, 0, 64, 0, true, nil)) do
				if string.sub(text, 1, 5) == "Menu " then
					return text
				end
			end
			return nil
		end
		-- (The count is Machines.containerSize: a kind's slots, else BlockList's `container`. The
		-- only machine block so far, the creative cube, has none; later phases' machines do.)
		t.eq(menuLine(B.CreativeEnergyCube), "Menu Machine", "no slots")
		t.eq(menuLine(B.Chest), "Menu Chest, 27 slots", "chests unchanged")
		t.eq(menuLine(B.Furnace), "Menu Furnace, 3 slots", "furnaces unchanged")
		t.eq(menuLine(B.Stone), nil, "no menu")
	end)

	--[[ The seasons' heaters, coolers and stoves ]]

	local HeatStates = require(shared.Seasons.HeatStates)
	local Rooms = require(shared.Seasons.Rooms)
	local Config = require(shared.Config)
	local BlockDecor = require(client.Rendering.BlockDecor)
	local TransmitterModel = require(client.Rendering.TransmitterModel)
	local JeiData = require(client.Ui.Jei.JeiData)
	local I = Items.id
	local HEAT_MACHINES = { "WoodStove", "OilHeater", "ElectricHeater", "AirConditioner", "ElectricFan" }

	local function window(block: number): any
		local container = Machines.newContainer(block)
		return { id = 7, container = container }, container
	end

	t.test("panels: thermostats' buttons, the set point between - and +, no energy bar without energy", function()
		for _, name in HEAT_MACHINES do
			local block = B[name]
			local _, container = window(block)
			local panel = MenuLayout.panel(container)
			t.eq(panel.kind, "machine")
			t.eq(#panel.buttons, #Machines.buttons(block), `{name}'s buttons`)
			for i, button in panel.buttons do
				local spec = Machines.buttons(block)[i]
				t.eq(button.id, spec.id)
				t.ok(button.x >= 0 and button.x + button.w <= MenuLayout.WIDTH, "inside the panel")
				t.ok(button.y >= 0 and button.y + button.h <= panel.height, "inside the panel")
				-- Nothing else drawn over a button.
				for _, line in panel.lines do
					local clear = line.y + MenuLayout.LINE_TEXT <= button.y
						or line.y >= button.y + button.h
						or line.x >= button.x + button.w
					t.ok(clear, `{name}: a line clear of button {button.label}`)
				end
				for _, slot in panel.slots do
					local clear = slot.x + 16 <= button.x
						or slot.x >= button.x + button.w
						or slot.y + 16 <= button.y
						or slot.y >= button.y + button.h
					t.ok(clear, `{name}: slot {slot.slot} clear of button {button.label}`)
				end
				t.eq(MenuLayout.buttonAt(panel, button.x, button.y), button, "its top left")
				t.eq(MenuLayout.buttonAt(panel, button.x + button.w - 1, button.y + button.h - 1), button)
			end
			t.eq(MenuLayout.buttonAt(panel, 0, 0), nil, "the title")
			if Machines.isFuelOnly(block) then
				t.eq(panel.energy, nil, `{name}: no energy bar`)
			else
				t.ok(panel.energy ~= nil, `{name}: the energy bar`)
				local bar = panel.energy :: any
				for _, button in panel.buttons do
					t.ok(button.x + button.w <= bar.x, "buttons left of the energy bar")
				end
			end
			if Machines.field(block, "setPoint") then
				local rect = assert(panel.setPoint, `{name}: a set point`)
				t.ok(rect.w >= 30, "room for its text")
			else
				t.eq(panel.setPoint, nil)
			end
		end
		-- Other machines' panels have none and keep their bar; the bar's maths never divide by 0.
		local generator = MenuLayout.panel(Machines.newContainer(B.HeatGenerator))
		t.eq(#generator.buttons, 0)
		t.ok(generator.energy ~= nil)
		t.eq(MenuLayout.energyRows({ 0, 0, 0, 0, 0, 0 }, 52), 0, "capacity 0: empty, no NaN")
		t.eq(MenuLayout.energyFraction({ 5, 0, 0, 0, 0, 0 }), 0)
	end)

	t.test("panels: the set point's text, the on / off label and the click's action", function()
		local win, heater = window(B.ElectricHeater)
		t.eq(MenuLayout.setPointText(heater), "Set 0")
		Machines.set(heater, "setPoint", 3)
		t.eq(MenuLayout.setPointText(heater), "Set +3")
		Machines.set(heater, "setPoint", -2)
		t.eq(MenuLayout.setPointText(heater), "Set -2")
		local panel = MenuLayout.panel(heater)
		local mode = panel.buttons[3]
		t.eq(mode.id, HeatStates.BUTTON_MODE)
		t.eq(MenuLayout.buttonLabel(heater, mode), "On")
		Machines.set(heater, "on", 0)
		t.eq(MenuLayout.buttonLabel(heater, mode), "Off")
		t.eq(MenuLayout.buttonLabel(heater, panel.buttons[1]), "-")
		local bare = { kind = "machine", block = B.ElectricHeater, size = 0, slots = {}, data = nil }
		t.eq(MenuLayout.buttonLabel(bare :: any, mode), "Mode", "no data yet")
		t.eq(MenuLayout.setPointText(bare :: any), "Set 0")
		t.eq(bare.data, nil, "nothing written")
		local action = MenuLayout.buttonAction(win, panel.buttons[2]) :: any
		t.eq(action.kind, "button")
		t.eq(action.window, 7)
		t.eq(action.button, HeatStates.BUTTON_UP)
		t.eq(MenuLayout.BUTTON_SOUND, "ui.thermostat.click")
		-- The stove: one button, its fire's flame, no set point.
		local _, stove = window(B.WoodStove)
		local stovePanel = MenuLayout.panel(stove)
		t.eq(#stovePanel.buttons, 1)
		t.eq(MenuLayout.buttonLabel(stove, stovePanel.buttons[1]), "On")
		t.ok(stovePanel.flame ~= nil and stovePanel.flameSource ~= nil, "the flame")
		Machines.set(stove, "burnTime", 3200)
		Machines.set(stove, "burnTotal", 6400)
		t.eq(MenuLayout.machineFlameRows(stove.data, stovePanel.flameSource), 7, "half burnt")
		t.eq(MenuLayout.setPointText(stove), "")
		-- The status and lines from the window's data alone.
		local _, ac = window(B.AirConditioner)
		Machines.set(ac, "state", HeatStates.COOLING)
		Machines.set(ac, "rate", -160)
		t.eq(MenuLayout.statusText(ac), "Cooling 32 HU")
		t.eq(MenuLayout.lineTexts(ac)[1], "-32 HU, 160 J/t")
		t.eq(#MenuLayout.panel(ac).lines, 1, "one line above the buttons")
	end)

	t.test("waila: heaters say what they do, fuel-only ones no energy, and the viewer's room", function()
		local function texts(block: number, facts: any, room: any?): { string }
			return WailaInfo.texts(WailaInfo.block(block, nil, 0, 64, 0, false, { machine = facts, room = room }))
		end
		local stove = WailaInfo.machineDefaults(B.WoodStove)
		t.eq(stove.capacity, 0)
		local lines = texts(B.WoodStove, stove)
		for _, text in lines do
			t.ok(string.find(text, "Energy", 1, true) == nil, `no energy line: {text}`)
		end
		stove.state, stove.rate, stove.active = HeatStates.HEATING, 30, true
		t.ok(table.find(texts(B.WoodStove, stove), "Heating 30 HU") ~= nil)
		stove.state, stove.rate = HeatStates.NO_FUEL, 0
		t.ok(table.find(texts(B.WoodStove, stove), "No fuel") ~= nil)
		local oil = WailaInfo.machineDefaults(B.OilHeater)
		oil.state = HeatStates.NO_ROOM
		local oilLines = texts(B.OilHeater, oil)
		t.ok(table.find(oilLines, "No room") ~= nil)
		t.ok(table.find(oilLines, "Empty: 0 / 4,000 mB") ~= nil, "its tank")
		-- An electric one keeps its energy line, then its status.
		local heater = WailaInfo.machineDefaults(B.ElectricHeater)
		heater.state, heater.rate, heater.energy = HeatStates.HEATING, -128, 8000
		local heaterLines = texts(B.ElectricHeater, heater)
		t.ok(table.find(heaterLines, "Energy: 8 kJ / 16 kJ") ~= nil)
		t.ok(table.find(heaterLines, "Heating 32 HU") ~= nil)
		heater.state, heater.rate = HeatStates.NO_POWER, 0
		t.ok(table.find(texts(B.ElectricHeater, heater), "No power") ~= nil)
		heater.state = HeatStates.AT_SET_POINT
		t.ok(table.find(texts(B.ElectricHeater, heater), "At set point") ~= nil)
		-- The viewer's room, while they stand in one.
		local inRoom = texts(B.ElectricHeater, heater, { room = 1.2, outside = -9.4 })
		t.ok(table.find(inRoom, "Room +1 (out -9)") ~= nil, "Room +1 (out -9)")
		local outdoors = texts(B.ElectricHeater, heater, { room = nil, outside = -9 })
		for _, text in outdoors do
			t.ok(string.sub(text, 1, 5) ~= "Room ", "none outdoors")
		end
		-- Not on other machines.
		local generator = WailaInfo.machineDefaults(B.HeatGenerator)
		for _, text in texts(B.HeatGenerator, generator, { room = 1, outside = -9 }) do
			t.ok(string.sub(text, 1, 5) ~= "Room ", "a generator says no room")
		end
		t.eq(WailaInfo.isHeatMachine(B.ElectricFan), true)
		t.eq(WailaInfo.isHeatMachine(B.HeatGenerator), false)
		-- F3: a fuel-only machine's heat, not energy numbers.
		local details = WailaInfo.texts(WailaInfo.block(B.WoodStove, nil, 0, 64, 0, true, { machine = stove }))
		local found = false
		for _, text in details do
			t.ok(string.find(text, "Holds", 1, true) == nil, "no store")
			found = found or string.sub(text, 1, 9) == "Fuel only"
		end
		t.ok(found, "its heat")
		-- The Thermometer's reading.
		t.eq(WailaInfo.roomReading(1.4, -8.6), "Room +1 · Out -9")
		t.eq(WailaInfo.roomReading(0.2, 3), "Room 0 · Out +3")
		t.eq(WailaInfo.roomReading(nil, -9), "Out -9")
		t.eq(WailaInfo.roomReading(nil, nil), "")
		t.eq(WailaInfo.text(assert(WailaInfo.roomLine(-0.6, 4.5))), "Room -1 (out +5)")
		t.eq(WailaInfo.roomLine(nil, 3), nil)
	end)

	t.test("decor: the heaters' faces, their windows' glow and light, their loops", function()
		local windows = {
			WoodStove = BlockDecor.STOVE_WINDOW,
			OilHeater = BlockDecor.OIL_HEATER_WINDOW,
			ElectricHeater = BlockDecor.ELECTRIC_HEATER_WINDOW,
			AirConditioner = BlockDecor.AIR_CONDITIONER_WINDOW,
		}
		for _, name in HEAT_MACHINES do
			local block = B[name]
			local faces = BlockDecor.faces(name) :: any
			t.ok(faces ~= nil, name)
			local parts = BlockDecor.partCount(name)
			t.ok(parts > 0 and parts < 40, `{name} item model slabs: {parts}`)
			-- (Item model tops look the same however they are turned.)
			for _, face in { "Top", "Bottom" } do
				local cells = {}
				for _, r in faces[face] do
					if not r.surfaceOnly then
						for y = r.y, r.y + r.h - 1 do
							for x = r.x, r.x + r.w - 1 do
								cells[y * 16 + x] = table.concat(r.colour, ",")
							end
						end
					end
				end
				for y = 0, 15 do
					for x = 0, 15 do
						t.eq(cells[y * 16 + x], cells[x * 16 + (15 - y)], `{name} {face} at {x},{y}`)
					end
				end
			end
			local window = windows[name]
			local idle = TransmitterModel.machineBoxes(block, nil)
			local working = { active = true, energy = 0, capacity = 0 }
			local lit = TransmitterModel.machineBoxes(block, working)
			t.eq(#idle, 0, `{name}: dark while idle`)
			t.ok(TransmitterModel.hasMachineBoxes(block) == (window ~= nil), `{name}: a cell for its window`)
			if window then
				for _, face in { "Front", "Back", "Left", "Right" } do
					local found = false
					for _, r in faces[face] do
						found = found or (r.x == window.x and r.y == window.y and r.w == window.w and r.h == window.h)
					end
					t.ok(found, `{name} {face}: its window`)
				end
				t.eq(#lit, 4, `{name}: a pane on each side`)
				local colour = lit[1].colour
				t.eq(colour, TransmitterModel.glowColour(block))
			else
				t.eq(#lit, 0, "the fan has no window")
			end
			t.ok(TransmitterModel.machineLoop(block) ~= nil, `{name} plays a loop`)
		end
		t.eq(TransmitterModel.glowColour(B.WoodStove), TransmitterModel.GLOW_COLOUR, "the stove's fire")
		t.ok(TransmitterModel.glowColour(B.ElectricHeater)[1] > 200, "the element red")
		t.ok(TransmitterModel.glowColour(B.AirConditioner)[3] > 200, "the cold strip cyan")
		-- A warm light while the stove and the oil heater burn (their entries' `workLight`, 10).
		local burning = { active = true, energy = 0, capacity = 0 }
		local light = assert(TransmitterModel.machineLight(B.WoodStove, burning))
		t.near(light.range, 10 * 0.9, 1e-9)
		t.ok(light.brightness > 0)
		t.ok(TransmitterModel.machineLight(B.OilHeater, burning) ~= nil)
		t.eq(TransmitterModel.machineLight(B.WoodStove, nil), nil, "out")
		t.eq(TransmitterModel.machineLight(B.WoodStove, { active = false, energy = 0, capacity = 0 }), nil)
		t.eq(TransmitterModel.machineLight(B.ElectricHeater, burning), nil, "convective: no light")
		t.eq(TransmitterModel.machineLoop(B.HeatGenerator), nil)
		t.eq(TransmitterModel.machineLoop(B.WoodStove), "block.wood_stove.crackle")
	end)

	t.test("jei: the Wood Stove burns the fuels its slot takes; the heaters' info", function()
		local uses = JeiData.uses(I.WoodStove)
		local fuel = nil
		for _, group in uses do
			if group.category == "fuel" then
				fuel = group
			end
		end
		assert(fuel, "the stove lists fuels")
		local coal, lava = false, false
		for _, entry in fuel.entries do
			for _, item in entry.inputs[1] do
				coal = coal or item == I.Coal
				lava = lava or item == I.LavaBucket
			end
		end
		t.ok(coal, "coal")
		t.eq(lava, false, "not a lava bucket")
		t.ok(table.find(JeiData.CATALYSTS.fuel, "WoodStove") ~= nil)
		local heat = Config.Seasons.Heat
		for _, name in HEAT_MACHINES do
			local lines = JeiData.heaterLines(I[name])
			t.ok(#lines >= 2, `{name}'s info`)
		end
		t.eq(JeiData.heaterLines(I.WoodStove)[1], `{heat.WoodStove} HU while it burns`)
		t.eq(#JeiData.heaterLines(I.Stone), 0)
		t.eq(Rooms.huText(heat.ElectricHeater), "40")
	end)
end
