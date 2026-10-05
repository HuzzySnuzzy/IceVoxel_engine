--!strict
--[[
	Mekanism's machines, the parts the server, the client and its prediction share: machine kinds,
	their container (slots and data), slot rules, shift-click routing, sided slots for
	transporters, panels, energy maths and sustained data. Pure: no Roblox APIs.

	Require Shared/Machines (init), which loads this, every kind in Machines/Kinds and binds the
	BlockList blocks to their kinds. Kind modules require this one (Core) to define themselves.

	Blocks. A machine is a BlockList block with `machine = { kind = "<name>" }` and `energy =
	{ capacity = J, input = J/t?, output = J/t? }`. The energy spec decides its part in an energy
	network (`role`): output only a producer, input only a consumer, both storage (batteries: they
	take the surplus and cover a shortfall, the backup). Every machine has energy, and every energy
	block is a machine.

	Containers. A machine's contents are a container (Inventory/Types) of kind "machine" that the
	server keeps per position (Players/Containers): `newContainer(block)`. Its slots are its kind's
	(`slots`, 0 or more), and its `data` (f64, at most Types.MAX_CONTAINER_DATA = 16) starts with a
	header every machine shares, then the kind's own `fields`:

	    1 ENERGY    J stored (a multiple of QUANTUM; math.huge for the creative cube)
	    2 CAPACITY  J it can hold now (the block's capacity unless the kind changes it: upgrades)
	    3 INPUT     J the energy network put in during the last tick
	    4 OUTPUT    J the network took out during the last tick
	    5 RATE      J/t the machine itself made (+, generators) or used (-, machines) last tick
	    6 ACTIVE    1 while it works (burning, smelting, producing), else 0: what the block shows (a
	                kind may hold it on through short stops, as Mekanism's blockDeactivationDelay
	                does: the Electric Furnace; RATE says whether it works this tick)
	    7..         the kind's fields, in the order it lists them (`index[name]`, `get`, `set`)

	Kinds (`define(name, spec)`): what a machine of a kind is, all optional:
	  slots     { SlotSpec }: the container's slots in order, with their panel position, the rule
	            of what they take (`accepts`), whether they are an output, a limit, the faces
	            transporters use (default: inputs take items through every face, outputs give
	            them through every face) and an outline shown while empty (`ghost`; upgrade
	            slots: Machines/Upgrades.slots). A machine pushes what its outputs hold out on
	            its own into the transporters and chests around it (Mekanism's ejector: server
	            Transmitters/Transport and Eject)
	  fields    data names after the header (letters, digits, "_": they double as item data keys)
	  keep      fields kept in the item when the machine is broken (energy always is)
	  panel     PanelSpec: title, height, the energy bar, a progress arrow, a flame, a status line
	  tick      tick(container, ctx): one server tick (20 a second), before the energy networks
	            move energy. Change data in place; replace slot stacks (Items.withCount ...),
	            never change a stack table (viewers and prediction compare tables). Use
	            `produce` / `use` for energy (they keep it a multiple of QUANTUM). `ctx`
	            (TickContext: the block, its energy spec, the day time, blocks around, whether
	            a cell sees the sky) is lent for the call only.
	  status    status(view) -> line: WAILA's and the panel's "Producing 200 J/t" (default from
	            RATE: "Producing x/t", "Using x/t"; storage "Charging" / "Discharging")
	  lines     lines(view) -> { line }: more lines of text for its panel, under the status line
	            (`panel.lines` says where; at most MAX_LINES): a battery's input and output
	  state     the name of one of its fields holding a state code, a whole number 0..MAX_STATE
	            the kind sets in its tick to say why it is not working (Mekanism's recipe errors:
	            the Electric Furnace's "No power"). It travels in Machines records with the header,
	            so WAILA knows it without the window, and `status` gets it as `view.state` (0 for
	            kinds without one)
	  rates     rates(container, energy) -> (input, output): J/t the network may put in / take
	            out now (default the block's `energy.input` / `output`)
	  quickMove quickMove(item) -> { slot }: shift-click targets from the inventory (default the
	            kind's non-output slots that accept the item, in order)
	  creative  infinite energy (the Creative Energy Cube): never drains, keeps nothing

	Energy is kept in multiples of QUANTUM (1/1024 J), so the networks' sums and differences are
	exact (doubles hold every such value below 2^43 J): energy is never made or lost by rounding.
	`share` is Mekanism's even split, in whole quanta.

	A tick's order on the server (server/Machines/MachineWorld): every machine's `tick`, then the
	energy networks (server/Machines/EnergyNet) move energy between machines through Universal
	Cables and between directly adjacent machines.

	The API, by use:
	  kinds and blocks  define, kind, bind (tests bind test-only kinds to spare blocks), bindBlocks,
	                    isMachine, kindOf, energyOf, hasEnergy, role, containerSize
	  containers, data  newContainer, newData, isContainer, field, get, set, energy, capacity, room,
	                    state, MAX_STATE
	  energy maths      QUANTUM, quantise, quantiseUp, produce, use, rates, share, tick
	  slots             isOutput, mayPlace, slotLimit, quickMoveTargets (Inventory/Menu),
	                    insertSlots, extractSlots, outputSlots (Transmitters/Inventories:
	                    transporters and the ejector)
	  what players see  view, status, lines, MAX_LINES, panel (Ui/MenuLayout, Ui/WailaInfo),
	                    ENERGY_BAR, PANEL_HEIGHT, energyColour (the energy bar's colour, also on
	                    items and batteries' gauges)
	  sustained data    save, restore (server MachineWorld.blockDataHooks)
]]

local Blocks = require(script.Parent.Parent.Blocks)
local Items = require(script.Parent.Parent.Items)
local Types = require(script.Parent.Parent.Inventory.Types)

type Container = Types.Container
export type EnergySpec = Blocks.EnergySpec

-- One slot of a kind (see the header).
export type SlotSpec = {
	-- Where the panel draws it: the item's top left in GUI pixels (MenuLayout slots).
	x: number,
	y: number,
	-- Only taken from (a result): nothing is put in by hand, shift-click or transporter.
	output: boolean?,
	-- What may be put in (Minecraft's Slot.mayPlace); nil: anything (outputs: nothing).
	accepts: ((item: number) -> boolean)?,
	-- The most items it holds (nil: the item's max stack, at most 64).
	limit: number?,
	-- Minecraft's 26 x 26 result frame around it.
	big: boolean?,
	-- Faces (sides 0..5) transporters put items in / take items out through. nil: inputs take
	-- them through every face and give none; outputs give through every face.
	insert: { number }?,
	extract: { number }?,
	-- A faint outline drawn in the slot while it is empty (Minecraft's empty armor slots): 16 rows
	-- of 16 characters, "G" a pixel of it, "." none (Upgrades.SPEED_GHOST ...).
	ghost: { string }?,
}

-- A gauge filled from data: `value` over `total` (field names, or a number for a fixed total).
export type Gauge = { x: number, y: number, value: string, total: string | number }

-- The panel above the player's inventory (client Ui/MenuLayout draws it, 176 GUI pixels wide).
export type PanelSpec = {
	-- Default: the block's name. Always centred.
	title: string?,
	-- Default 78 (a furnace's).
	height: number?,
	-- The vertical energy bar's top left (6 x 52; default Mekanism's GuiVerticalPowerBar (164, 15)).
	energy: { x: number, y: number }?,
	-- Minecraft's progress arrow (24 x 16, filling left to right) and furnace flame (14 x 14).
	progress: Gauge?,
	flame: Gauge?,
	-- Where the status line goes (nil: none in the panel; WAILA always shows it).
	status: { x: number, y: number }?,
	-- Where the kind's `lines` go: the first at (x, y), each next one 12 pixels lower
	-- (Ui/MenuLayout.LINE_HEIGHT); nil: none.
	lines: { x: number, y: number }?,
}

-- What `status` and WAILA see of a machine: its data header (or a server Machines record).
export type View = {
	block: number,
	energy: number,
	capacity: number,
	input: number,
	output: number,
	rate: number,
	active: boolean,
	-- Its kind's state code (KindSpec `state`; 0 without one).
	state: number,
}

-- What a kind's tick gets besides its container (lent for the call: don't keep it).
export type TickContext = {
	block: number,
	x: number,
	y: number,
	z: number,
	-- The block's BlockList energy (capacity, input, output).
	energy: EnergySpec,
	-- Ticks the server's machines have run.
	tick: number,
	-- Minecraft's day time (0..24000, noon 6000; Shared/DayCycle).
	dayTime: number,
	-- Blocks around (nil: unknown); never generates terrain.
	getBlock: (x: number, y: number, z: number) -> number?,
	-- Is cell (x, y, z) open to the sky: nothing opaque (Blocks.isOpaque) in any cell straight
	-- above it, Minecraft's canSeeSky as Mekanism's solar generators check it? The server caches
	-- it per cell, looks again when a block above changes and never generates terrain for it
	-- (server Machines/SkyCheck). nil (a test's context): treat the sky as open.
	sky: ((x: number, y: number, z: number) -> boolean)?,
}

-- What `define` takes (see the header).
export type KindSpec = {
	slots: { SlotSpec }?,
	fields: { string }?,
	keep: { string }?,
	panel: PanelSpec?,
	tick: ((container: Container, ctx: TickContext) -> ())?,
	status: ((view: View) -> string?)?,
	lines: ((view: View) -> { string })?,
	rates: ((container: Container, energy: EnergySpec) -> (number, number))?,
	quickMove: ((item: number) -> { number })?,
	creative: boolean?,
	state: string?,
}

-- A defined kind (read only).
export type Kind = {
	name: string,
	slots: { SlotSpec },
	fields: { string },
	keep: { string },
	panel: PanelSpec,
	-- Data index of every header name and field.
	index: { [string]: number },
	-- Numbers in its data (header and fields).
	size: number,
	tick: ((container: Container, ctx: TickContext) -> ())?,
	status: ((view: View) -> string?)?,
	lines: ((view: View) -> { string })?,
	rates: ((container: Container, energy: EnergySpec) -> (number, number))?,
	quickMove: ((item: number) -> { number })?,
	creative: boolean,
	-- The data index of its state code field (nil: none).
	state: number?,
	-- Slots transporters reach per face (0..5): insert / extract.
	insertFaces: { [number]: { number } },
	extractFaces: { [number]: { number } },
	-- Its output slots, in order: what it pushes out on its own (Mekanism's ejector).
	outputs: { number },
}

export type Role = "producer" | "consumer" | "storage"

local Machines = {}

--[[ Data layout ]]

Machines.ENERGY = 1
Machines.CAPACITY = 2
Machines.INPUT = 3
Machines.OUTPUT = 4
Machines.RATE = 5
Machines.ACTIVE = 6
-- Header size: a kind's first field is HEADER + 1.
Machines.HEADER = 6
local HEADER_NAMES = { "energy", "capacity", "input", "output", "rate", "active" }
Machines.HEADER_NAMES = table.freeze(table.clone(HEADER_NAMES))
local ENERGY, CAPACITY, INPUT, OUTPUT, RATE, ACTIVE = 1, 2, 3, 4, 5, 6

-- The container kind of every machine (Types.KINDS).
Machines.CONTAINER_KIND = "machine"
assert(table.find(Types.KINDS, Machines.CONTAINER_KIND), "Types.KINDS must list machines")

-- The largest state code (KindSpec `state`): one byte in Machines records.
Machines.MAX_STATE = 255

-- Mekanism's GuiVerticalPowerBar and the furnace panel's height (GUI pixels).
Machines.ENERGY_BAR = table.freeze({ x = 164, y = 15, w = 6, h = 52 })
Machines.PANEL_HEIGHT = 78
-- The most lines a kind's `lines` gives its panel.
Machines.MAX_LINES = 4

--[[ Energy maths ]]

-- Energy is kept in multiples of this (J): sums and differences of such values are exact.
Machines.QUANTUM = 1 / 1024
local SCALE = 1024
-- The most joules `share` handles at once (2^52 quanta: integer maths stays exact).
local MAX_SHARE = 2 ^ 52 / SCALE

-- `joules` down to a multiple of QUANTUM (0 for NaN and anything below it; math.huge stays).
function Machines.quantise(joules: number): number
	if joules ~= joules or joules <= 0 then
		return 0
	elseif joules == math.huge then
		return joules
	end
	return math.floor(joules * SCALE) / SCALE
end

-- `joules` up to a multiple of QUANTUM (what using that much takes).
function Machines.quantiseUp(joules: number): number
	if joules ~= joules or joules <= 0 then
		return 0
	elseif joules == math.huge then
		return joules
	end
	return math.ceil(joules * SCALE) / SCALE
end

--[[
	Mekanism's even split: `amount` J shared out over recipients that take at most `limits[i]` J
	each. Every one gets the same share, those that take less than it get all they take and the
	rest is shared again among the others (smallest limits first; ties in list order). Works in
	whole quanta, so the result sums to exactly min(amount, sum of limits), quantised down, and
	each is at most its limit; recipients may differ by one quantum (the ones with larger limits,
	then later ones, get it). Pure and deterministic.
]]
function Machines.share(amount: number, limits: { number }): { number }
	local n = #limits
	local gives = table.create(n, 0)
	if n == 0 or amount ~= amount or amount <= 0 then
		return gives
	end
	local units: { number } = table.create(n, 0)
	local order: { number } = table.create(n, 0)
	for i = 1, n do
		local limit = limits[i]
		order[i] = i
		units[i] = if limit ~= limit or limit <= 0 then 0 else math.floor(math.min(limit, MAX_SHARE) * SCALE)
	end
	table.sort(order, function(a: number, b: number): boolean
		if units[a] ~= units[b] then
			return units[a] < units[b]
		end
		return a < b
	end)
	local remaining = math.floor(math.min(amount, MAX_SHARE) * SCALE)
	local left = n
	for _, i in order do
		local give = math.min(units[i], remaining // left)
		gives[i] = give / SCALE
		remaining -= give
		left -= 1
	end
	return gives
end

--[[ Kinds and blocks ]]

local kinds: { [string]: Kind } = {}
type Binding = { kind: Kind, energy: EnergySpec }
local bindings: { [number]: Binding } = {}
local SIDES = 6

local function isFace(face: any): boolean
	return face == 0 or face == 1 or face == 2 or face == 3 or face == 4 or face == 5
end

-- A slot spec's faces (`list` or every face when nil), checked.
local function faceSet(list: { number }?, default: boolean): { [number]: boolean }
	local set: { [number]: boolean } = {}
	if list == nil then
		if default then
			for face = 0, SIDES - 1 do
				set[face] = true
			end
		end
		return set
	end
	for _, face in list do
		assert(isFace(face), "bad face")
		set[face] = true
	end
	return set
end

--[[
	Defines the machine kind `name` from `spec` (see the header) and returns it. Names are unique;
	BlockList's `machine.kind` names one. Errors on a bad spec: too many slots or fields, a field
	that is no data key or repeats a header name, a kept field that is no field.
]]
function Machines.define(name: string, spec: KindSpec): Kind
	assert(type(name) == "string" and name ~= "", "a kind needs a name")
	assert(kinds[name] == nil, `Machine kind {name} is defined twice`)
	local slots: { SlotSpec } = spec.slots or {}
	local fields: { string } = spec.fields or {}
	local keep: { string } = spec.keep or {}
	assert(#slots <= Types.MAX_CONTAINER, `Machine kind {name} has too many slots`)
	assert(Machines.HEADER + #fields <= Types.MAX_CONTAINER_DATA, `Machine kind {name} has too many fields`)
	local index: { [string]: number } = {}
	for i, header in HEADER_NAMES do
		index[header] = i
	end
	for i, field in fields do
		assert(Items.validDataKey(field), `Machine kind {name}: bad field {field}`)
		assert(index[field] == nil, `Machine kind {name}: field {field} is taken`)
		index[field] = Machines.HEADER + i
	end
	for _, field in keep do
		assert(table.find(fields, field), `Machine kind {name} keeps {field}, which is no field`)
	end
	local stateField = spec.state
	assert(
		stateField == nil or table.find(fields, stateField),
		`Machine kind {name}: its state {stateField} is no field`
	)
	local insertFaces: { [number]: { number } } = {}
	local extractFaces: { [number]: { number } } = {}
	local outputs: { number } = {}
	for face = 0, SIDES - 1 do
		insertFaces[face] = {}
		extractFaces[face] = {}
	end
	for slot, slotSpec in slots do
		assert(
			type(slotSpec.x) == "number" and type(slotSpec.y) == "number",
			`Machine kind {name}: slot {slot} has no position`
		)
		local ghost = slotSpec.ghost
		if ghost then
			assert(#ghost <= 16, `Machine kind {name}: slot {slot}'s ghost is over 16 rows`)
			for _, row in ghost do
				assert(type(row) == "string" and #row <= 16, `Machine kind {name}: slot {slot}'s ghost is too wide`)
			end
		end
		local output = slotSpec.output == true
		if output then
			table.insert(outputs, slot)
		end
		local ins = faceSet(slotSpec.insert, not output)
		local outs = faceSet(slotSpec.extract, output)
		for face = 0, SIDES - 1 do
			if ins[face] and not output then
				table.insert(insertFaces[face], slot)
			end
			if outs[face] then
				table.insert(extractFaces[face], slot)
			end
		end
	end
	for face = 0, SIDES - 1 do
		table.freeze(insertFaces[face])
		table.freeze(extractFaces[face])
	end
	local panel: PanelSpec = spec.panel or {}
	local kind: Kind = {
		name = name,
		slots = table.freeze(table.clone(slots)),
		fields = table.freeze(table.clone(fields)),
		keep = table.freeze(table.clone(keep)),
		panel = table.freeze(table.clone(panel)),
		index = table.freeze(index),
		size = Machines.HEADER + #fields,
		tick = spec.tick,
		status = spec.status,
		lines = spec.lines,
		rates = spec.rates,
		quickMove = spec.quickMove,
		creative = spec.creative == true,
		state = if stateField then index[stateField] else nil,
		insertFaces = table.freeze(insertFaces),
		extractFaces = table.freeze(extractFaces),
		outputs = table.freeze(outputs),
	}
	kinds[name] = table.freeze(kind)
	return kind
end

-- The kind named `name`, if defined.
function Machines.kind(name: string): Kind?
	return kinds[name]
end

--[[
	Makes `block` a machine of kind `kindName` with `energy` (default its BlockList `energy`).
	Shared/Machines binds every BlockList block with `machine` when it loads; tests bind test-only
	kinds to spare blocks. Returns a function that undoes it (the block's previous binding, if any,
	comes back).
]]
function Machines.bind(block: number, kindName: string, energy: EnergySpec?): () -> ()
	assert(Blocks.isValid(block), `No block {block}`)
	local kind = kinds[kindName]
	assert(kind, `Unknown machine kind {kindName} (define it in Machines/Kinds)`)
	local spec = energy or Blocks.get(block).energy
	assert(spec and spec.capacity > 0, `Machine {Blocks.get(block).name} needs energy`)
	local previous = bindings[block]
	bindings[block] = { kind = kind, energy = spec }
	return function()
		bindings[block] = previous
	end
end

-- Binds every BlockList block with `machine` (Shared/Machines does, once every kind is loaded).
function Machines.bindBlocks()
	for id = 0, Blocks.count - 1 do
		local def = Blocks.get(id)
		local machine = def.machine
		assert(def.energy == nil or machine ~= nil, `Block {def.name} has energy but is no machine`)
		if machine then
			Machines.bind(id, machine.kind)
		end
	end
end

-- Is `block` a machine?
function Machines.isMachine(block: number): boolean
	return bindings[block] ~= nil
end

-- The kind of the machine `block`, nil for other blocks.
function Machines.kindOf(block: number): Kind?
	local binding = bindings[block]
	return if binding then binding.kind else nil
end

-- The energy of the machine `block` (capacity, input, output), nil for other blocks.
function Machines.energyOf(block: number): EnergySpec?
	local binding = bindings[block]
	return if binding then binding.energy else nil
end

-- Does `block` hold energy (Universal Cables connect to it, energy blocks next to it share)?
function Machines.hasEnergy(block: number): boolean
	return bindings[block] ~= nil
end

--[[
	The part `block` plays in an energy network: "producer" (gives out only: generators, solar
	panels, the creative cube), "consumer" (takes only: machines) or "storage" (both: batteries);
	nil when it moves no energy (or is no machine).
]]
function Machines.role(block: number): Role?
	local binding = bindings[block]
	if binding == nil then
		return nil
	end
	local energy = binding.energy
	local input, output = energy.input or 0, energy.output or 0
	if input > 0 and output > 0 then
		return "storage"
	elseif output > 0 then
		return "producer"
	elseif input > 0 then
		return "consumer"
	end
	return nil
end

--[[
	Item slots `block` keeps: a machine's kind's, else its BlockList `container` (chests 27,
	furnaces 3), 0 for other blocks.
]]
function Machines.containerSize(block: number): number
	local binding = bindings[block]
	if binding then
		return #binding.kind.slots
	end
	return if Blocks.isValid(block) then Blocks.get(block).container else 0
end

--[[ Containers and data ]]

-- A fresh machine's data: the header (its capacity; a creative cube's infinite energy) and zeros.
function Machines.newData(block: number): { number }
	local binding = bindings[block]
	assert(binding, `Block {block} is no machine`)
	local data = table.create(binding.kind.size, 0)
	data[CAPACITY] = binding.energy.capacity
	if binding.kind.creative then
		data[ENERGY] = math.huge
	end
	return data
end

-- A fresh, empty container for the machine `block` (kind "machine", its kind's slots).
function Machines.newContainer(block: number): Container
	local binding = bindings[block]
	assert(binding, `Block {block} is no machine`)
	return {
		kind = Machines.CONTAINER_KIND,
		block = block,
		size = #binding.kind.slots,
		slots = {},
		data = Machines.newData(block),
	}
end

-- Is `container` a machine's (kind "machine" of a machine block)?
function Machines.isContainer(container: Container?): boolean
	return container ~= nil and container.kind == Machines.CONTAINER_KIND and bindings[container.block] ~= nil
end

local function dataOf(container: Container): { number }
	local data = container.data
	if data == nil then
		local fresh = if bindings[container.block]
			then Machines.newData(container.block)
			else table.create(Machines.HEADER, 0)
		container.data = fresh
		return fresh
	end
	return data
end

local function number(value: number?): number
	return if type(value) == "number" and value == value then value else 0
end

-- The data index of `name` (a header name or a field) in the machine `block`'s data, else nil.
function Machines.field(block: number, name: string): number?
	local binding = bindings[block]
	return if binding then binding.kind.index[name] else nil
end

-- A data value of a machine's container by name (0 when missing).
function Machines.get(container: Container, name: string): number
	local index = Machines.field(container.block, name)
	assert(index, `Machine {container.block} has no field {name}`)
	return number(dataOf(container)[index])
end

-- Sets a data value of a machine's container by name.
function Machines.set(container: Container, name: string, value: number)
	local index = Machines.field(container.block, name)
	assert(index, `Machine {container.block} has no field {name}`)
	dataOf(container)[index] = value
end

-- J stored.
function Machines.energy(container: Container): number
	return number(dataOf(container)[ENERGY])
end

-- J it can hold now.
function Machines.capacity(container: Container): number
	return number(dataOf(container)[CAPACITY])
end

-- J it has room for.
function Machines.room(container: Container): number
	local data = dataOf(container)
	local capacity, energy = number(data[CAPACITY]), number(data[ENERGY])
	if capacity == math.huge then
		return if energy == math.huge then 0 else math.huge
	end
	return math.max(0, capacity - energy)
end

--[[
	The kind's state code of a machine's container (KindSpec `state`): a whole number
	0..MAX_STATE, 0 for kinds without one (and for anything else in the field). Only reads (a
	client's window may have no data yet).
]]
function Machines.state(container: Container): number
	local binding = bindings[container.block]
	local index = if binding then binding.kind.state else nil
	local data = container.data
	if index == nil or data == nil then
		return 0
	end
	local value = number(data[index])
	if value < 0 or value > Machines.MAX_STATE or value ~= math.floor(value) then
		return 0
	end
	return value
end

--[[
	Adds up to `amount` J the machine makes itself (a generator burning, a solar panel in the sun),
	quantised down and within its room. Returns how much went in.
]]
function Machines.produce(container: Container, amount: number): number
	local data = dataOf(container)
	local added = Machines.quantise(math.min(amount, Machines.room(container)))
	if added > 0 and added < math.huge then
		data[ENERGY] = number(data[ENERGY]) + added
	end
	return added
end

--[[
	Uses `amount` J (quantised up) if all of it is there (a machine working one tick): true when it
	was taken, false (nothing taken) otherwise. A creative cube always has it.
]]
function Machines.use(container: Container, amount: number): boolean
	local data = dataOf(container)
	local need = Machines.quantiseUp(amount)
	local energy = number(data[ENERGY])
	if energy < need then
		return false
	end
	if energy ~= math.huge then
		data[ENERGY] = energy - need
	end
	return true
end

--[[
	J per tick the energy network may put into / take out of the machine now: its kind's `rates`,
	else its block's `energy.input` / `output` (0 when missing); quantised down.
]]
function Machines.rates(container: Container): (number, number)
	local binding = bindings[container.block]
	if binding == nil then
		return 0, 0
	end
	local input, output = binding.energy.input or 0, binding.energy.output or 0
	local rates = binding.kind.rates
	if rates then
		-- (A kind's override that errors moves nothing rather than stopping every network.)
		local ok, kindInput, kindOutput = pcall(rates, container, binding.energy)
		if not ok or type(kindInput) ~= "number" or type(kindOutput) ~= "number" then
			return 0, 0
		end
		input, output = kindInput, kindOutput
	end
	return Machines.quantise(input), Machines.quantise(output)
end

--[[
	One server tick of a machine: its kind's `tick`, then the rules every machine keeps: capacity
	a positive number, energy within 0..capacity and a multiple of QUANTUM (rounded down: never
	made from nothing). A creative cube stays full. false when `container` is no machine's. A kind
	tick that errors still gets those rules applied (so no NaN or overfull energy reaches the
	energy networks), then its error is raised again for the caller to report.
]]
function Machines.tick(container: Container, ctx: TickContext): boolean
	local binding = bindings[container.block]
	if binding == nil then
		return false
	end
	local kind = binding.kind
	local data = dataOf(container)
	if kind.creative then
		data[ENERGY], data[CAPACITY] = math.huge, math.huge
		return true
	end
	local tick = kind.tick
	local ok, err = true, nil
	if tick then
		ok, err = pcall(tick, container, ctx)
		-- (The kind may have replaced the data table.)
		data = dataOf(container)
	end
	-- (No NaN anywhere: viewers, records and change checks compare these.)
	for i = 1, kind.size do
		local value = data[i]
		if value ~= value or type(value) ~= "number" then
			data[i] = 0
		end
	end
	local capacity = number(data[CAPACITY])
	if capacity <= 0 then
		capacity = binding.energy.capacity
		data[CAPACITY] = capacity
	end
	data[ENERGY] = Machines.quantise(math.min(number(data[ENERGY]), capacity))
	if not ok then
		error(err, 0)
	end
	return true
end

--[[ Slots ]]

local function slotOf(block: number, slot: number): SlotSpec?
	local binding = bindings[block]
	return if binding then binding.kind.slots[slot] else nil
end

-- Is `slot` of the machine `block` an output (only taken from)?
function Machines.isOutput(block: number, slot: number): boolean
	local spec = slotOf(block, slot)
	return spec ~= nil and spec.output == true
end

-- May `item` be put into `slot` of the machine `block` (Slot.mayPlace)? Never into an output.
function Machines.mayPlace(block: number, slot: number, item: number): boolean
	local spec = slotOf(block, slot)
	if spec == nil or spec.output == true or not Items.isValid(item) then
		return false
	end
	local accepts = spec.accepts
	return accepts == nil or accepts(item) == true
end

-- The most of `item` `slot` of the machine `block` holds (its limit, the item's max stack, 64).
function Machines.slotLimit(block: number, slot: number, item: number?): number
	local spec = slotOf(block, slot)
	local max = if item then math.min(Items.maxStack(item), Items.MAX_STACK) else Items.MAX_STACK
	if spec and spec.limit then
		return math.max(0, math.min(max, spec.limit))
	end
	return max
end

--[[
	The slots a shift-click from the inventory tries for `item`, in order: the kind's
	`quickMove`, else its non-output slots that accept it. Empty: the stack moves between the
	inventory and the hotbar instead (Mekanism's MekanismContainer.quickMoveStack).
]]
function Machines.quickMoveTargets(block: number, item: number): { number }
	local binding = bindings[block]
	if binding == nil then
		return {}
	end
	local kind = binding.kind
	local custom = kind.quickMove
	local targets: { number } = {}
	if custom then
		for _, slot in custom(item) do
			if Machines.mayPlace(block, slot, item) then
				table.insert(targets, slot)
			end
		end
		return targets
	end
	for slot in kind.slots do
		if Machines.mayPlace(block, slot, item) then
			table.insert(targets, slot)
		end
	end
	return targets
end

local NO_SLOTS: { number } = table.freeze({})

-- The slots transporters may put items into through `face` (in order; outputs never).
function Machines.insertSlots(block: number, face: number): { number }
	local binding = bindings[block]
	if binding == nil or not isFace(face) then
		return NO_SLOTS
	end
	return binding.kind.insertFaces[face]
end

-- The slots transporters may take items out of through `face` (in order).
function Machines.extractSlots(block: number, face: number): { number }
	local binding = bindings[block]
	if binding == nil or not isFace(face) then
		return NO_SLOTS
	end
	return binding.kind.extractFaces[face]
end

--[[
	The output slots of the machine `block`, in order (empty for other blocks): the results it
	pushes out on its own into the transporters and chests around it (Mekanism's ejector,
	Transmitters/Inventories `ejectSlots`).
]]
function Machines.outputSlots(block: number): { number }
	local binding = bindings[block]
	return if binding then binding.kind.outputs else NO_SLOTS
end

--[[ What players see ]]

-- The header of a machine's container as a View.
function Machines.view(container: Container): View
	local data = dataOf(container)
	return {
		block = container.block,
		energy = number(data[ENERGY]),
		capacity = number(data[CAPACITY]),
		input = number(data[INPUT]),
		output = number(data[OUTPUT]),
		rate = number(data[RATE]),
		active = number(data[ACTIVE]) ~= 0,
		state = Machines.state(container),
	}
end

--[[
	The status line of a machine (WAILA, the panel): its kind's `status`, else from the view:
	"Producing 200 J/t", "Using 50 J/t", storage "Charging 1 kJ/t" / "Discharging 1 kJ/t"; nil
	when there is nothing to say.
]]
function Machines.status(block: number, view: View): string?
	local binding = bindings[block]
	if binding == nil then
		return nil
	end
	local status = binding.kind.status
	if status then
		local ok, line = pcall(status, view)
		return if ok and type(line) == "string" and line ~= "" then line else nil
	end
	if view.rate > 0 then
		return `Producing {Items.formatEnergy(view.rate)}/t`
	elseif view.rate < 0 then
		return `Using {Items.formatEnergy(-view.rate)}/t`
	elseif Machines.role(block) == "storage" then
		local net = view.input - view.output
		if net > 0 then
			return `Charging {Items.formatEnergy(net)}/t`
		elseif net < 0 then
			return `Discharging {Items.formatEnergy(-net)}/t`
		end
	end
	return nil
end

--[[
	The panel's lines of a machine under its status line (its kind's `lines`: a battery's input and
	output): at most MAX_LINES non-empty strings, none for kinds without them (or whose `lines`
	fails).
]]
function Machines.lines(block: number, view: View): { string }
	local binding = bindings[block]
	local lines = if binding then binding.kind.lines else nil
	local shown: { string } = {}
	if lines == nil then
		return shown
	end
	local ok, result = pcall(lines, view)
	if not ok or type(result) ~= "table" then
		return shown
	end
	for _, line in result do
		if type(line) == "string" and line ~= "" and #shown < Machines.MAX_LINES then
			table.insert(shown, line)
		end
	end
	return shown
end

--[[
	The colour of stored energy at a fill of `fraction` (0..1), Mekanism's energy bar as drawn here:
	red when empty, through yellow, to green when full ({ r, g, b }, 0..255). The panels' energy
	bar (Ui/MenuLayout), the bar on items that hold energy and a battery's gauges
	(Rendering/TransmitterModel) all use it.
]]
function Machines.energyColour(fraction: number): { number }
	local f = math.clamp(if fraction == fraction then fraction else 0, 0, 1)
	if f < 0.5 then
		return { 255, math.floor(f * 2 * 255 + 0.5), 0 }
	end
	return { math.floor((1 - f) * 2 * 255 + 0.5), 255, 0 }
end

-- The panel of the machine `block` (its kind's, nil for other blocks).
function Machines.panel(block: number): PanelSpec?
	local binding = bindings[block]
	return if binding then binding.kind.panel else nil
end

--[[ Sustained data (Mekanism keeps a machine's energy in its item) ]]

--[[
	The item data a broken machine keeps: `energy` (J, while it holds any) and its kind's `keep`
	fields that are not 0. nil when there is nothing (its item stacks with new ones), for the
	creative cube and for containers that are no machine's.
]]
function Machines.save(container: Container): Items.Data?
	local binding = bindings[container.block]
	if binding == nil or binding.kind.creative then
		return nil
	end
	local data = dataOf(container)
	local kept: Items.Data = {}
	local energy = number(data[ENERGY])
	if energy > 0 and energy < math.huge then
		kept.energy = energy
	end
	for _, field in binding.kind.keep do
		local value = number(data[binding.kind.index[field]])
		if value ~= 0 and value > -math.huge and value < math.huge then
			kept[field] = value
		end
	end
	return Items.cleanData(kept)
end

--[[
	Puts a machine item's data (`save`) back into the freshly placed machine's container: the
	energy (at most its capacity, quantised down) and its kind's kept fields. Returns whether
	anything was taken (false: no data of this machine's, a creative cube, no machine).
]]
function Machines.restore(container: Container, data: Items.Data?): boolean
	local binding = bindings[container.block]
	if binding == nil or binding.kind.creative or data == nil then
		return false
	end
	local values = dataOf(container)
	local restored = false
	local energy = Items.dataNumber(data, "energy")
	if energy and energy > 0 and energy < math.huge then
		values[ENERGY] = Machines.quantise(math.min(energy, number(values[CAPACITY])))
		restored = true
	end
	for _, field in binding.kind.keep do
		local value = Items.dataNumber(data, field)
		if value then
			values[binding.kind.index[field]] = value
			restored = true
		end
	end
	return restored
end

return Machines
