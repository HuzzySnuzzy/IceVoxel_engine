--[[
	The seasons' heaters, coolers and stoves as machines (Shared/Machines kinds "heater", "cooler",
	"stove", "oilheater"): the fuel-only binding (no energy: cables and networks never see them), the
	frozen data layouts (saved items depend on them), panel buttons (Machines.button, the Inventory
	Action "button" and its codec, data only in the menu), the set point kept in the item, what
	their slots and tanks take; their ticks: the thermostats over a room (Rooms.thermostat with
	the room's heat less their own), energy per HU and the share delivered on too little ("Low
	power"), the space heater outdoors and its standby, the fan's band, the stove's fuel x4 held
	when off, the oil heater's oil and fuel by output, every state and status line; and their
	recipes, Ages, lore and sounds.
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
	local HEAT = require(shared.Config).Seasons.Heat
	local Rooms = require(shared.Seasons.Rooms)

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

	-- A context for `container` with a room (`sample`: a Shared/Seasons/Rooms.Sample, nil outdoors;
	-- its heat, as server RoomWorld sums it for the call, its `others` and the machine's own) and
	-- whether a player is near (nil: no `near` at all).
	local function roomCtx(container: any, sample: any?, near: boolean?): any
		local context = ctx(container.block)
		context.climate = function(): (any, number)
			if sample then
				sample.heat = sample.others + Machines.get(container, "heat")
			end
			return sample, if sample then sample.outside else -6.7
		end
		if near ~= nil then
			context.near = function(_x: number, _y: number, _z: number, radius: number): boolean
				t.eq(radius, HEAT.StandbyRadius, "asked within StandbyRadius")
				return near
			end
		end
		return context
	end

	-- The design's plank house in a winter night (Rooms' worked numbers), `others` HU from other
	-- sources.
	local function house(temperature: number, others: number?): any
		return {
			id = 1,
			temperature = temperature,
			outside = -6.7,
			uaOut = 2.465,
			uaGround = 0.5,
			volume = 75,
			heat = 0,
			others = others or 0,
		}
	end

	local function status(container: any): string?
		return Machines.status(container.block, Machines.view(container))
	end

	local function charge(container: any)
		Machines.set(container, "energy", Machines.capacity(container))
	end

	t.test("heaters: a fresh one is on at set point 0; with no room, power or fuel it says why", function()
		local expected = {
			ElectricHeater = { HeatStates.NO_POWER, "No power" },
			AirConditioner = { HeatStates.NO_ROOM, "No room" },
			ElectricFan = { HeatStates.NO_POWER, "No power" },
			WoodStove = { HeatStates.NO_FUEL, "No fuel" },
			OilHeater = { HeatStates.NO_ROOM, "No room" },
		}
		for name, want in expected do
			local block = B[name]
			local container = Machines.newContainer(block)
			t.eq(Machines.get(container, "on"), 1, `{name} starts on`)
			if Machines.field(block, "setPoint") then
				t.eq(Machines.get(container, "setPoint"), 0)
			end
			t.ok(Machines.tick(container, ctx(block)))
			t.eq(Machines.get(container, "heat"), 0, `{name}: no heat`)
			t.eq(Machines.view(container).rate, 0, "nothing drawn")
			t.eq(Machines.view(container).active, false)
			t.eq(Machines.state(container), want[1], name)
			t.eq(status(container), want[2])
			Machines.set(container, "on", 0)
			Machines.tick(container, ctx(block))
			t.eq(Machines.state(container), HeatStates.OFF)
			t.eq(status(container), "Off")
		end
	end)

	t.test("heaters: the Electric Heater's thermostat, its power and the space heater outdoors", function()
		local block = B.ElectricHeater
		local heater = Machines.newContainer(block)
		Machines.set(heater, "setPoint", 1)
		charge(heater)
		-- Cold air: the need at +1 and the proportional part.
		local cold = house(-5.57)
		local want = Rooms.thermostat(1, -5.57, cold, -6.7, 0, 0, HEAT.ElectricHeater)
		Machines.tick(heater, roomCtx(heater, cold))
		t.near(Machines.get(heater, "heat"), want, 1e-9)
		t.near(-Machines.view(heater).rate, want * HEAT.HeaterJoules, 0.001, "4 J a tick per HU")
		t.near(Machines.energy(heater), 16000 - want * HEAT.HeaterJoules, 0.001, "taken from its store")
		t.eq(Machines.state(heater), HeatStates.HEATING)
		t.eq(status(heater), `Heating {Rooms.huText(want)} HU`)
		t.eq(Machines.view(heater).active, true)
		t.eq(Machines.lines(block, Machines.view(heater))[1], `{Rooms.huText(want)} HU, 156 J/t`)
		-- The room counts its own heat (RoomWorld's sample.heat): the same again, no runaway.
		Machines.tick(heater, roomCtx(heater, cold))
		t.near(cold.heat, want, 1e-9, "its own heat in the room's")
		t.near(Machines.get(heater, "heat"), want, 1e-9, "others = the room's heat less its own")
		-- At its set point: what holding it takes; above: less, then nothing.
		Machines.tick(heater, roomCtx(heater, house(1)))
		t.near(Machines.get(heater, "heat"), 19.48, 0.01)
		t.eq(Machines.state(heater), HeatStates.AT_SET_POINT)
		t.eq(status(heater), "At set point")
		Machines.tick(heater, roomCtx(heater, house(12)))
		t.eq(Machines.get(heater, "heat"), 0)
		t.eq(Machines.view(heater).rate, 0)
		t.eq(Machines.state(heater), HeatStates.AT_SET_POINT)
		-- A campfire beside it (others): it gives what is missing.
		Machines.tick(heater, roomCtx(heater, house(1, 15)))
		t.near(Machines.get(heater, "heat"), 19.48 - 15, 0.01)
		-- Never above its most.
		charge(heater)
		Machines.tick(heater, roomCtx(heater, house(-15)))
		t.eq(Machines.get(heater, "heat"), HEAT.ElectricHeater)
		t.eq(-Machines.view(heater).rate, HEAT.ElectricHeater * HEAT.HeaterJoules)
		-- Too little stored: all of it, for that share.
		Machines.set(heater, "energy", 40)
		Machines.tick(heater, roomCtx(heater, house(-15)))
		t.near(Machines.get(heater, "heat"), HEAT.ElectricHeater * 40 / 160, 1e-9)
		t.eq(Machines.energy(heater), 0)
		t.eq(Machines.state(heater), HeatStates.LOW_POWER)
		t.eq(status(heater), "Low power: 10 HU")
		Machines.tick(heater, roomCtx(heater, house(-15)))
		t.eq(Machines.state(heater), HeatStates.NO_POWER)
		t.eq(Machines.get(heater, "heat"), 0)
		-- Mekanism's deactivation delay: it shows it works a while after it stopped.
		t.eq(Machines.view(heater).active, true, "held on")
		for _ = 1, Machines.DEACTIVATION_DELAY do
			Machines.tick(heater, roomCtx(heater, house(-15)))
		end
		t.eq(Machines.view(heater).active, false, "dark after the delay")
		-- Outdoors: a space heater while a player is near, else it stands by.
		charge(heater)
		Machines.tick(heater, roomCtx(heater, nil, true))
		t.eq(Machines.get(heater, "heat"), HEAT.SpaceHeater)
		t.eq(-Machines.view(heater).rate, HEAT.SpaceHeater * HEAT.HeaterJoules)
		t.eq(status(heater), "Heating 20 HU")
		Machines.tick(heater, roomCtx(heater, nil, false))
		t.eq(Machines.get(heater, "heat"), 0)
		t.eq(Machines.view(heater).rate, 0, "standby draws nothing")
		t.eq(status(heater), "Standby")
		Machines.tick(heater, roomCtx(heater, nil))
		t.eq(Machines.get(heater, "heat"), HEAT.SpaceHeater, "a context without `near`: a player counts as near")
		-- Item data from elsewhere: the set point within its range.
		Machines.set(heater, "setPoint", 99)
		Machines.tick(heater, roomCtx(heater, house(5)))
		t.near(Machines.get(heater, "heat"), Rooms.thermostat(5, 5, house(5), -6.7, 0, 0, 40), 1e-9)
	end)

	t.test("heaters: the Air Conditioner cools rooms only; the fan runs above its set point", function()
		local block = B.AirConditioner
		local ac = Machines.newContainer(block)
		charge(ac)
		local desert = {
			id = 2,
			temperature = 7.85,
			outside = 10.4,
			uaOut = 3.02,
			uaGround = 0.98,
			volume = 147,
			heat = 0,
			others = 0,
		}
		Machines.tick(ac, roomCtx(ac, desert))
		t.eq(Machines.get(ac, "heat"), HEAT.AirConditioner, "its most: -40 HU")
		t.eq(-Machines.view(ac).rate, 40 * HEAT.CoolerJoules, "5 J a tick per HU")
		t.eq(Machines.state(ac), HeatStates.COOLING)
		t.eq(status(ac), "Cooling 40 HU")
		t.eq(Machines.lines(block, Machines.view(ac))[1], "-40 HU, 200 J/t")
		desert.temperature = 0
		Machines.tick(ac, roomCtx(ac, desert))
		t.near(Machines.get(ac, "heat"), -3.02 * 10.4, 1e-9, "holding 0")
		t.eq(Machines.state(ac), HeatStates.AT_SET_POINT)
		Machines.tick(ac, roomCtx(ac, nil))
		t.eq(Machines.get(ac, "heat"), 0)
		t.eq(Machines.state(ac), HeatStates.NO_ROOM)
		t.eq(Machines.view(ac).rate, 0, "nothing drawn outdoors")
		-- The fan: on above its set point (0) by half a step, off below it by half a step.
		local fanBlock = B.ElectricFan
		local fan = Machines.newContainer(fanBlock)
		charge(fan)
		local room = house(5)
		local function run(temperature: number): number
			room.temperature = temperature
			Machines.tick(fan, roomCtx(fan, room))
			return Machines.get(fan, "heat")
		end
		t.eq(run(5), HEAT.ElectricFan)
		t.eq(-Machines.view(fan).rate, HEAT.FanJoules)
		t.eq(status(fan), "Cooling 10 HU")
		t.eq(run(0.3), HEAT.ElectricFan, "running: on down to -0.5")
		t.eq(run(-0.6), 0, "off")
		t.eq(Machines.state(fan), HeatStates.AT_SET_POINT)
		t.eq(run(0.3), 0, "stopped: off up to +0.5")
		t.eq(run(0.6), HEAT.ElectricFan, "on again")
		-- Outdoors it runs while on: a cold source near it (Players/Climate).
		Machines.tick(fan, roomCtx(fan, nil))
		t.eq(Machines.get(fan, "heat"), HEAT.ElectricFan)
		Machines.set(fan, "energy", 15)
		Machines.tick(fan, roomCtx(fan, nil))
		t.near(Machines.get(fan, "heat"), HEAT.ElectricFan / 2, 1e-9, "half its J, half its cooling")
		t.eq(Machines.state(fan), HeatStates.LOW_POWER)
	end)

	t.test("heaters: the Wood Stove burns furnace fuel four times as long, and holds it when off", function()
		local block = B.WoodStove
		local stove = Machines.newContainer(block)
		stove.slots[1] = Items.newStack(I.Coal, 2)
		Machines.tick(stove, ctx(block))
		t.eq(stove.slots[1] and stove.slots[1].count, 1, "one coal lit")
		t.eq(Machines.get(stove, "burnTotal"), 1600 * HEAT.StoveBurnFactor, "320 s")
		t.eq(Machines.get(stove, "burnTime"), 6400 - 1)
		t.eq(Machines.get(stove, "heat"), HEAT.WoodStove)
		t.eq(Machines.view(stove).rate, HEAT.WoodStove, "RATE carries its HU")
		t.eq(Machines.view(stove).active, true)
		t.eq(status(stove), "Heating 30 HU")
		t.eq(Machines.energy(stove), 0, "no energy, ever")
		-- Off: it holds what burns.
		Machines.set(stove, "on", 0)
		for _ = 1, 100 do
			Machines.tick(stove, ctx(block))
		end
		t.eq(Machines.get(stove, "burnTime"), 6399, "held")
		t.eq(Machines.get(stove, "heat"), 0)
		t.eq(Machines.view(stove).active, false)
		Machines.set(stove, "on", 1)
		-- The next coal lights as the last one runs out: no tick without fire.
		Machines.set(stove, "burnTime", 1)
		Machines.tick(stove, ctx(block))
		t.eq(Machines.get(stove, "heat"), HEAT.WoodStove)
		Machines.tick(stove, ctx(block))
		t.eq(Machines.get(stove, "heat"), HEAT.WoodStove, "lit at once")
		t.eq(stove.slots[1], nil, "the second coal")
		Machines.set(stove, "burnTime", 1)
		Machines.tick(stove, ctx(block))
		Machines.tick(stove, ctx(block))
		t.eq(Machines.get(stove, "heat"), 0)
		t.eq(Machines.state(stove), HeatStates.NO_FUEL)
		t.eq(Machines.get(stove, "burnTotal"), 0, "the flame out")
		-- A log: 60 s.
		stove.slots[1] = Items.newStack(I.OakLog, 1)
		Machines.tick(stove, ctx(block))
		t.eq(Machines.get(stove, "burnTotal"), 1200)
		-- Item data from elsewhere: never more than the longest fuel.
		Machines.set(stove, "burnTime", 1e9)
		Machines.tick(stove, ctx(block))
		t.ok(Machines.get(stove, "burnTime") <= Machines.info(block).maxBurn)
	end)

	t.test("heaters: the Oil Heater burns oil and fuel by its output, in rooms only", function()
		local block = B.OilHeater
		local heater = Machines.newContainer(block)
		Machines.tankInsert(heater, "fuel", Fluids.OIL, 1000)
		local freezing = house(-15)
		-- Full output: a mB of oil every OilTicks.
		for _ = 1, 30 * 10 do
			Machines.tick(heater, roomCtx(heater, freezing))
		end
		t.eq(Machines.get(heater, "heat"), HEAT.OilHeater)
		t.eq(Machines.view(heater).rate, HEAT.OilHeater)
		t.eq(status(heater), "Heating 35 HU")
		t.eq(Machines.view(heater).active, true)
		local left = Machines.tankAmount(heater, "fuel")
		t.ok(math.abs(left - 990) <= 1, `oil left {left}`)
		-- Half output: half the oil.
		local half = Machines.newContainer(block)
		Machines.tankInsert(half, "fuel", Fluids.OIL, 1000)
		Machines.set(half, "setPoint", 1)
		local mild = house(1)
		mild.uaOut = 17.5 / 7.7
		mild.uaGround = 0
		for _ = 1, 60 * 10 do
			Machines.tick(half, roomCtx(half, mild))
		end
		t.near(Machines.get(half, "heat"), 17.5, 1e-9)
		t.eq(Machines.state(half), HeatStates.AT_SET_POINT)
		t.ok(math.abs(Machines.tankAmount(half, "fuel") - 990) <= 1, "a mB every 60 ticks")
		-- Fuel lasts twice as long.
		local fuel = Machines.newContainer(block)
		Machines.tankInsert(fuel, "fuel", Fluids.FUEL, 1000)
		for _ = 1, 60 * 10 do
			Machines.tick(fuel, roomCtx(fuel, freezing))
		end
		t.ok(math.abs(Machines.tankAmount(fuel, "fuel") - 990) <= 1, "fuel: a mB every FuelTicks")
		-- Dry: what still burns, then nothing.
		local dry = Machines.newContainer(block)
		Machines.tankInsert(dry, "fuel", Fluids.OIL, 1)
		for _ = 1, 30 do
			Machines.tick(dry, roomCtx(dry, freezing))
		end
		t.ok(Machines.get(dry, "heat") > 0, "the last mB")
		Machines.tick(dry, roomCtx(dry, freezing))
		Machines.tick(dry, roomCtx(dry, freezing))
		t.eq(Machines.get(dry, "heat"), 0)
		t.eq(Machines.state(dry), HeatStates.NO_FUEL)
		t.eq(status(dry), "No fuel")
		-- Outdoors nothing burns.
		local outdoors = Machines.newContainer(block)
		Machines.tankInsert(outdoors, "fuel", Fluids.OIL, 1000)
		for _ = 1, 100 do
			Machines.tick(outdoors, roomCtx(outdoors, nil))
		end
		t.eq(Machines.tankAmount(outdoors, "fuel"), 1000)
		t.eq(Machines.state(outdoors), HeatStates.NO_ROOM)
	end)

	t.test("heaters: heaters never cool and coolers never heat (Climate's heat and cold sources)", function()
		for _, name in { "ElectricHeater", "AirConditioner", "ElectricFan", "WoodStove", "OilHeater" } do
			local container = Machines.newContainer(B[name])
			Machines.tankInsert(container, "fuel", Fluids.OIL, 1000)
			if name == "WoodStove" then
				container.slots[1] = Items.newStack(I.Coal, 1)
			end
			local cooler = name == "AirConditioner" or name == "ElectricFan"
			for _, setPoint in { -5, 0, 5 } do
				if Machines.field(container.block, "setPoint") then
					Machines.set(container, "setPoint", setPoint)
				end
				for temperature = -15, 15, 3 do
					for _, room in { house(temperature), false } do
						charge(container)
						Machines.tick(container, roomCtx(container, if room then room else nil, true))
						local heat = Machines.get(container, "heat")
						if cooler then
							t.ok(heat <= 0, `{name} at {temperature}: {heat}`)
						else
							t.ok(heat >= 0, `{name} at {temperature}: {heat}`)
						end
					end
				end
			end
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
