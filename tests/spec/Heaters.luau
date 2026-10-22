--[[
	The seasons' heaters, coolers and stoves as machines (Shared/Machines kinds "heater", "cooler",
	"stove", "oilheater"): the fuel-only binding (no energy: cables and networks never see them), the
	frozen data layouts (saved items depend on them), panel buttons (Machines.button, the Inventory
	Action "button" and its codec, data only in the menu), the set point kept in the item, what
	their slots and tanks take, their idle ticks until the rooms land, and their recipes, Ages,
	lore and sounds.
]]

return function(t, shared, require)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Machines = require(shared.Machines)
	local Menu = require(shared.Inventory.Menu)
	local Protocol = require(shared.Net.Protocol)
	local Types = require(shared.Inventory.Types)
	local Fluids = require(shared.Fluids)
	local Crafting = require(shared.Crafting)
	local Progression = require(shared.Progression)
	local Sounds = require(shared.Sounds)
	local LoreList = require(shared.Items.LoreList)
	local HeatStates = require(shared.Seasons.HeatStates)
	local Transmitters = require(shared.Transmitters)

	local B = Blocks.id
	local I = Items.id
	local HEADER = Machines.HEADER

	local function ctx(block: number): any
		return {
			block = block,
			x = 0,
			y = 64,
			z = 0,
			energy = assert(Machines.energyOf(block)),
			tick = 1,
			dayTime = 6000,
			getBlock = function()
				return nil
			end,
		}
	end

	t.test("heaters: five machines; the stove and the oil heater are fuel only", function()
		local expected = {
			WoodStove = "stove",
			OilHeater = "oilheater",
			ElectricHeater = "heater",
			AirConditioner = "cooler",
			ElectricFan = "cooler",
		}
		for name, kind in expected do
			local block = B[name]
			t.ok(Machines.isMachine(block), name)
			t.eq((Machines.kindOf(block) :: any).name, kind, `{name}'s kind`)
			t.eq(Blocks.get(block).decor, name, "drawn with its decor faces")
			t.eq(Blocks.zombieBreak(block), 0, "zombies never break it")
			t.eq(Blocks.insulation(block), 0.05, "a machine's wall face")
			t.ok(LoreList[name] ~= nil, `{name} has lore`)
		end
		for _, name in { "WoodStove", "OilHeater" } do
			local block = B[name]
			t.ok(Machines.isFuelOnly(block), `{name} is fuel only`)
			t.eq((Machines.energyOf(block) :: any).capacity, 0)
			t.eq(Machines.hasEnergy(block), false, "no energy: cables never connect")
			t.eq(Machines.role(block), nil, "no part in an energy network")
			t.eq(Transmitters.isEnergyAcceptor(block), false, "Universal Cables never connect")
			local container = Machines.newContainer(block)
			t.eq(Machines.capacity(container), 0)
			t.eq(Machines.energy(container), 0)
		end
		for _, name in { "ElectricHeater", "AirConditioner", "ElectricFan" } do
			local block = B[name]
			t.eq(Machines.isFuelOnly(block), false)
			t.ok(Machines.hasEnergy(block), `{name} takes power`)
			t.eq(Machines.role(block), "consumer")
		end
		t.eq((Machines.energyOf(B.ElectricHeater) :: any).capacity, 16000)
		t.eq((Machines.energyOf(B.ElectricHeater) :: any).input, 400)
		t.eq((Machines.energyOf(B.AirConditioner) :: any).capacity, 20000)
		t.eq((Machines.energyOf(B.AirConditioner) :: any).input, 500)
		-- A fuel-only kind needs a fuel-only block, and only it may hold none.
		local ok = pcall(Machines.bind, B.DiamondBlock, "heater", { capacity = 0 })
		t.eq(ok, false, "an electric kind needs energy")
		local undo = Machines.bind(B.DiamondBlock, "stove", { capacity = 0 })
		t.ok(Machines.isFuelOnly(B.DiamondBlock))
		undo()
		t.eq(Machines.isMachine(B.DiamondBlock), false)
	end)

	t.test("heaters: the frozen data layouts after the header", function()
		local function layout(block: number, names: { string })
			for i, name in names do
				t.eq(Machines.field(block, name), HEADER + i, `{Blocks.get(block).name} {name}`)
			end
		end
		layout(B.ElectricHeater, { "setPoint", "heat", "state", "activeDelay", "on" })
		layout(B.AirConditioner, { "setPoint", "heat", "state", "activeDelay", "on" })
		layout(B.ElectricFan, { "setPoint", "heat", "state", "activeDelay", "on" })
		layout(B.WoodStove, { "burnTime", "burnTotal", "on", "heat", "state" })
		layout(B.OilHeater, { "setPoint", "heat", "state", "burning", "on", "fuel", "fuelFluid" })
		t.eq(Machines.containerSize(B.WoodStove), 1, "one fuel slot")
		t.eq(Machines.containerSize(B.OilHeater), 0)
		t.eq(Machines.containerSize(B.ElectricHeater), 0)
		local tank = assert(Machines.tank(B.OilHeater, "fuel"))
		t.eq(tank.capacity, 4000)
		t.eq(tank.role, "input")
		t.ok(table.find(tank.fluids, Fluids.OIL) ~= nil and table.find(tank.fluids, Fluids.FUEL) ~= nil)
		-- The state code's field is each kind's `state`.
		for _, name in { "ElectricHeater", "AirConditioner", "WoodStove", "OilHeater" } do
			local block = B[name]
			local kind = Machines.kindOf(block) :: any
			t.eq(kind.state, Machines.field(block, "state"), `{name}'s state field`)
		end
	end)

	t.test("heaters: a fresh one is on at set point 0; until the rooms land it stays idle", function()
		for _, name in { "ElectricHeater", "AirConditioner", "ElectricFan", "WoodStove", "OilHeater" } do
			local block = B[name]
			local container = Machines.newContainer(block)
			t.eq(Machines.get(container, "on"), 1, `{name} starts on`)
			if Machines.field(block, "setPoint") then
				t.eq(Machines.get(container, "setPoint"), 0)
			end
			t.ok(Machines.tick(container, ctx(block)))
			t.eq(Machines.get(container, "heat"), 0, "no heat yet")
			t.eq(Machines.view(container).rate, 0, "no power drawn")
			t.eq(Machines.view(container).active, false)
			t.eq(Machines.state(container), HeatStates.IDLE)
			t.eq(Machines.status(block, Machines.view(container)), "Idle")
			Machines.set(container, "on", 0)
			Machines.tick(container, ctx(block))
			t.eq(Machines.state(container), HeatStates.OFF)
			t.eq(Machines.status(block, Machines.view(container)), "Off")
		end
	end)

	t.test("heaters: panel buttons reach the kind (-, +, Mode), nothing else does", function()
		local block = B.ElectricHeater
		local buttons = Machines.buttons(block)
		t.eq(#buttons, 3)
		t.eq(buttons[1].id, HeatStates.BUTTON_DOWN)
		t.eq(buttons[2].id, HeatStates.BUTTON_UP)
		t.eq(buttons[3].id, HeatStates.BUTTON_MODE)
		for _, button in buttons do
			t.ok(button.x >= 0 and button.x + button.w <= 160, "inside the panel, left of the energy bar")
			t.ok(button.y >= 0 and button.y + button.h <= Machines.PANEL_HEIGHT, "inside the panel")
			t.ok(button.label ~= "")
		end
		local container = Machines.newContainer(block)
		t.ok(Machines.button(container, block, HeatStates.BUTTON_UP))
		t.ok(Machines.button(container, block, HeatStates.BUTTON_UP))
		t.eq(Machines.get(container, "setPoint"), 2)
		for _ = 1, 10 do
			Machines.button(container, block, HeatStates.BUTTON_UP)
		end
		t.eq(Machines.get(container, "setPoint"), 5, "at most +5")
		for _ = 1, 20 do
			Machines.button(container, block, HeatStates.BUTTON_DOWN)
		end
		t.eq(Machines.get(container, "setPoint"), -5, "at least -5")
		t.ok(Machines.button(container, block, HeatStates.BUTTON_MODE))
		t.eq(Machines.get(container, "on"), 0, "Mode switches it off")
		Machines.button(container, block, HeatStates.BUTTON_MODE)
		t.eq(Machines.get(container, "on"), 1, "and on again")
		t.eq(Machines.button(container, block, 7), false, "no such button")
		t.eq(Machines.button(container, B.AirConditioner, 1), false, "another block's")
		t.eq(Machines.button(Machines.newContainer(B.HeatGenerator), B.HeatGenerator, 0), false, "no buttons")
		-- The stove: on and off only (it holds its fuel).
		local stove = Machines.newContainer(B.WoodStove)
		t.eq(#Machines.buttons(B.WoodStove), 1)
		t.eq(Machines.button(stove, B.WoodStove, HeatStates.BUTTON_UP), false)
		t.ok(Machines.button(stove, B.WoodStove, HeatStates.BUTTON_MODE))
		t.eq(Machines.get(stove, "on"), 0)
		-- Other machines' panels have none.
		t.eq(#Machines.buttons(B.HeatGenerator), 0)
		t.eq(#Machines.buttons(B.Stone), 0)
	end)

	t.test("heaters: the set point and the stove's fire are kept in the item", function()
		local heater = Machines.newContainer(B.ElectricHeater)
		Machines.set(heater, "setPoint", 3)
		Machines.set(heater, "heat", 20)
		local saved = assert(Machines.save(heater))
		t.eq(saved.setPoint, 3)
		t.eq(saved.heat, nil, "what it delivers is not kept")
		local placed = Machines.newContainer(B.ElectricHeater)
		t.ok(Machines.restore(placed, saved))
		t.eq(Machines.get(placed, "setPoint"), 3)
		t.eq(Machines.get(placed, "on"), 1)
		t.eq(Machines.save(Machines.newContainer(B.ElectricHeater)), nil, "a fresh one keeps nothing: it stacks")
		local stove = Machines.newContainer(B.WoodStove)
		Machines.set(stove, "burnTime", 400)
		Machines.set(stove, "burnTotal", 6400)
		local kept = assert(Machines.save(stove))
		t.eq(kept.burnTime, 400)
		t.eq(kept.burnTotal, 6400)
		local oil = Machines.newContainer(B.OilHeater)
		Machines.tankInsert(oil, "fuel", Fluids.OIL, 2500)
		Machines.set(oil, "setPoint", -2)
		local oilSaved = assert(Machines.save(oil))
		t.eq(oilSaved.fuel, 2500)
		t.eq(oilSaved.fuelFluid, Fluids.OIL)
		t.eq(oilSaved.setPoint, -2)
	end)

	t.test("heaters: the stove burns furnace fuel; the oil heater's tank takes oil and fuel", function()
		local stove = B.WoodStove
		t.ok(Machines.mayPlace(stove, 1, I.Coal), "coal")
		t.ok(Machines.mayPlace(stove, 1, I.OakLog), "logs")
		t.eq(Machines.mayPlace(stove, 1, I.Stone), false, "not stone")
		t.eq(Machines.mayPlace(stove, 1, I.LavaBucket), false, "not a lava bucket (it leaves the bucket)")
		local oil = Machines.newContainer(B.OilHeater)
		t.ok(Machines.takesFluid(B.OilHeater, Fluids.OIL))
		t.ok(Machines.takesFluid(B.OilHeater, Fluids.FUEL))
		t.eq(Machines.takesFluid(B.OilHeater, Fluids.WATER), false)
		t.eq(Machines.takesFluid(B.OilHeater, Fluids.LAVA), false)
		t.ok(Machines.pourBucket(oil, Fluids.FUEL), "a fuel bucket pours in")
		t.eq(Machines.tankAmount(oil, "fuel"), Fluids.BUCKET)
		t.eq(Machines.insertFluid(oil, Fluids.OIL, 500), 0, "one fluid at a time")
		t.eq(#Machines.gauges(B.OilHeater), 1, "its gauge")
	end)

	t.test("heaters: the button action's codec, and the menu leaves it to the server", function()
		local action: Types.Action = { kind = "button", window = 3, button = 2 }
		local payload = Protocol.encodeInventoryAction(41, action)
		t.eq(buffer.len(payload), 7)
		local seq, decoded = Protocol.decodeInventoryAction(payload)
		t.eq(seq, 41)
		local got = assert(decoded) :: any
		t.eq(got.kind, "button")
		t.eq(got.window, 3)
		t.eq(got.button, 2)
		-- A wrong length is malformed.
		local long = buffer.create(8)
		buffer.copy(long, 0, payload)
		t.eq(select(2, Protocol.decodeInventoryAction(long)), nil)
		t.eq(select(2, Protocol.decodeInventoryAction(buffer.create(6))), nil)
		-- Spectators can't; others may; applying it changes nothing in the window (data only).
		t.eq(Menu.allows(action, "Spectator"), false)
		t.ok(Menu.allows(action, "Survival"))
		local window = Types.newWindow(Types.newInventory())
		local container = Machines.newContainer(B.ElectricHeater)
		window.id = 3
		window.container = container
		local before = Machines.get(container, "setPoint")
		t.eq(#Menu.apply(window, action, false), 0)
		t.eq(Machines.get(container, "setPoint"), before, "the server's to apply")
	end)

	t.test("heaters: recipes in their Ages, and their sounds", function()
		local ages = {
			SnowLayer1 = nil,
			InsulatedPlanks = nil,
			WoodStove = 2,
			InsulatedGlass = 2,
			InsulatedDoor = 2,
			OilHeater = 3,
			ElectricHeater = 4,
			AirConditioner = 4,
			ElectricFan = 4,
		}
		for _, name in
			{
				"SnowLayer1",
				"InsulatedPlanks",
				"WoodStove",
				"InsulatedGlass",
				"InsulatedDoor",
				"OilHeater",
				"ElectricHeater",
				"AirConditioner",
				"ElectricFan",
			}
		do
			local item = I[name]
			local found = false
			for _, recipe in Crafting.recipes do
				found = found or recipe.result == item
			end
			t.ok(found, `{name} has a recipe`)
			local age = Progression.requirement(item)
			t.eq(if age then age.index else nil, ages[name], `{name}'s Age`)
		end
		for _, name in
			{
				"block.electric_heater.hum",
				"block.air_conditioner.hum",
				"block.fan.loop",
				"block.wood_stove.crackle",
				"block.oil_heater.burn",
				"ui.thermostat.click",
				"ambient.season.autumn",
				"ambient.season.winter",
				"ambient.season.spring",
				"ambient.season.summer",
				"ambient.season.heat_wave",
			}
		do
			local event = Sounds.get(name)
			t.ok(event ~= nil, `{name} is in the catalogue`)
			assert(event)
			t.eq(event.side, "client", `{name} is the client's`)
			t.ok(string.find(event.id, "^rbxasset://") ~= nil, `{name} plays a built-in stand-in`)
		end
		t.eq((Sounds.get("ambient.season.winter") :: any).category, "ambient.season")
	end)
end
