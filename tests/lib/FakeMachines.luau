--[[
	Test-only machine kinds (Shared/Machines), proving the framework the way later phases use it:
	a kind is `Machines.define(name, spec)`; a block becomes one with `Machines.bind`. The game's
	own kinds live in src/shared/Machines/Kinds; these never leave the tests.

	  test_producer  a generator: makes `power` J a tick while it has room (rate > 0, active)
	  test_consumer  a machine: uses `use` J a tick when it has them (rate < 0, active)
	  test_battery   a battery: no tick of its own, storage by its energy spec (input and output)
	  test_furnace   an electric furnace with slots: input (smeltable), fuel-like slot (fuel only, at
	                 most 16), output; uses `cost` J a tick to make `progress` up to `total`, then
	                 smelts one item (a slot change); a panel with an arrow, a flame and a status line
	  test_broken    a kind whose tick errors (the server must carry on)
	  test_messy     a kind whose tick overfills its energy, writes NaN and then errors (the rules
	                 every machine keeps must still hold)
	  test_bad_rates storage whose `rates` override errors (it moves nothing; the rest go on)
	  test_shuffler  two slots; its tick replaces the whole slots table (still a slot change)

	`define(Machines, Items, Smelting)` defines them once per test run (the module cache is shared
	by every spec) and returns them; `bind(Machines, list, fn)` binds blocks to kinds for the
	length of `fn` and always unbinds them afterwards.
]]

local FakeMachines = {}

function FakeMachines.define(Machines: any, Items: any, Smelting: any)
	local function get(name: string, spec: any)
		return Machines.kind(name) or Machines.define(name, spec)
	end
	local producer = get("test_producer", {
		fields = { "power" },
		keep = { "power" },
		tick = function(container, _ctx)
			local made = Machines.produce(container, Machines.get(container, "power"))
			Machines.set(container, "rate", made)
			Machines.set(container, "active", if made > 0 then 1 else 0)
		end,
	})
	local consumer = get("test_consumer", {
		fields = { "use" },
		tick = function(container, _ctx)
			local use = Machines.get(container, "use")
			local working = use > 0 and Machines.use(container, use)
			Machines.set(container, "rate", if working then -Machines.quantiseUp(use) else 0)
			Machines.set(container, "active", if working then 1 else 0)
		end,
	})
	local battery = get("test_battery", {})
	local furnace = get("test_furnace", {
		slots = {
			{
				x = 56,
				y = 17,
				accepts = function(item: number): boolean
					return Smelting.result(item) ~= nil
				end,
			},
			{
				x = 56,
				y = 53,
				limit = 16,
				accepts = function(item: number): boolean
					return Smelting.fuel(item) > 0
				end,
				insert = { 2, 3, 4, 5 },
			},
			{ x = 116, y = 35, output = true, big = true, extract = { 0 } },
		},
		fields = { "progress", "total", "burn", "burnTotal", "cost" },
		keep = { "progress" },
		panel = {
			title = "Test Furnace",
			progress = { x = 79, y = 34, value = "progress", total = "total" },
			flame = { x = 56, y = 36, value = "burn", total = 100 },
			status = { x = 8, y = 66 },
		},
		status = function(view)
			return if view.active then "Smelting" else "Idle"
		end,
		tick = function(container, _ctx)
			local slots = container.slots
			local input = slots[1]
			local total = Machines.get(container, "total")
			local cost = Machines.get(container, "cost")
			if input == nil or total <= 0 or not Machines.use(container, cost) then
				Machines.set(container, "active", 0)
				Machines.set(container, "rate", 0)
				return
			end
			Machines.set(container, "active", 1)
			Machines.set(container, "rate", -cost)
			local progress = Machines.get(container, "progress") + 1
			if progress >= total then
				progress = 0
				local result = Smelting.result(input.item)
				local output = slots[3]
				slots[1] = Items.withCount(input, input.count - 1)
				slots[3] = Items.newStack(result.item, (if output then output.count else 0) + result.count)
			end
			Machines.set(container, "progress", progress)
		end,
	})
	local broken = get("test_broken", {
		tick = function()
			error("this kind always fails")
		end,
	})
	-- Fails halfway through its tick, leaving its data overfull and NaN.
	local messy = get("test_messy", {
		tick = function(container, _ctx)
			local data = container.data :: { number }
			data[Machines.ENERGY] = Machines.capacity(container) * 2 + 0.3
			data[Machines.RATE] = 0 / 0
			error("this kind fails after making a mess")
		end,
	})
	-- Storage whose rates override always fails.
	local badRates = get("test_bad_rates", {
		rates = function(_container, _energy): (number, number)
			error("no rates")
		end,
	})
	-- Replaces its whole slots table every tick a slot holds something (moves slot 1 to slot 2).
	local shuffler = get("test_shuffler", {
		slots = { { x = 8, y = 8 }, { x = 26, y = 8 } },
		tick = function(container, _ctx)
			local first = container.slots[1]
			if first then
				container.slots = { [2] = first }
			end
		end,
	})
	return {
		producer = producer,
		consumer = consumer,
		battery = battery,
		furnace = furnace,
		broken = broken,
		messy = messy,
		badRates = badRates,
		shuffler = shuffler,
	}
end

-- Binds `list` ({ block, kindName, energy? } each) while `fn` runs, then unbinds, even on error.
function FakeMachines.bind(Machines: any, list: { { any } }, fn: () -> ())
	local undo = {}
	for _, entry in list do
		table.insert(undo, Machines.bind(entry[1], entry[2], entry[3]))
	end
	local ok, err = pcall(fn)
	for i = #undo, 1, -1 do
		undo[i]()
	end
	if not ok then
		error(err, 0)
	end
end

return FakeMachines
