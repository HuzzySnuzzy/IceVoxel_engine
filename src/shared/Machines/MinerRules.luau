--!strict
--[[
	The Metal Miner's rules (Machines/Kinds/Miner, kind "miner"), pure: which blocks it mines, what
	each one gives, and its state code.

	  ORES       every ore block the content packs have (Shared/Content): the side list NAMES
	             first (Coal Ore, Iron Ore, Osmium Ore, Gold Ore, Emerald Ore, Diamond Ore, with
	             Config.Miner.Ores' numbers), then every block entry with `miner = { ticks, joules,
	             floor? }` in id order (the Ores pack's Copper, Lead, Zinc, Sulfur, Saltpetre and
	             Uranium Ore). Any order would do: saves keep a miner's ore by name, never its
	             place here. Each gives its drop (Items.blockDrops: Coal, Raw Iron, Raw Osmium,
	             Raw Gold, an Emerald, a Diamond, Raw Copper, Raw Lead, Raw Zinc, a Sulfur, a
	             Saltpetre, Raw Uranium; one a time), not the ore block (drops are what furnaces
	             and the Electric Furnace take, and an ore block can't be moved: a miner is built
	             on a vein where it lies), at its numbers: ticks an item, J a tick, the least J an
	             item costs (`floor`: coal never makes more energy than it took)
	  ore        the Ore of a block (nil: no ore)
	  STATE      the miner's state codes: MINING, NO_POWER, OUTPUT_FULL, NO_ORE ("No ore below"),
	             IDLE (switched off); its state field holds the code alone
	  packState  the state its views and records carry (Kinds/Miner's `stateOf`, from the code and
	             the ore of its `mining`): code + 8 x the ore's index in ORES (0: none), a place in
	             this version's list, never saved; unpackState reads it back
	  settings   what an ore costs with `speed` Speed and `energy` Energy Upgrades installed
	             (Mekanism's maths, Machines/Upgrades, as the Electric Furnace's): the ticks an
	             item takes (`Upgrades.ticks`: its ticks x 10^(-speed/8), truncated), the J a tick
	             of work uses and the store (`Upgrades.capacity` of the block's capacity). The J a
	             tick is `Upgrades.energyPerTick` (its J x 10^((2 speed - energy)/8)), but never
	             under the ore's floor over its ticks (the floor / ticks, up to a whole QUANTUM),
	             so an item costs at least its floor at every card count: a coal at least 400 kJ,
	             more than the 320 kJ it burns for in a Heat Generator (355.6 kJ a coal in a Block
	             of Coal), so coal is never energy-positive

	Checked as this loads: every ore is a block whose drop is an item, Config.Miner.Ores names each
	of NAMES and nothing else, and no ore is both in NAMES and an entry with `miner`.
]]

local Blocks = require(script.Parent.Parent.Blocks)
local Config = require(script.Parent.Parent.Config)
local Content = require(script.Parent.Parent.Content)
local Items = require(script.Parent.Parent.Items)
local Core = require(script.Parent.Core)
local Upgrades = require(script.Parent.Upgrades)

-- One ore the miner copies (see the header).
export type Ore = {
	-- Its place in ORES (1..), its block and name, its drop (an item), and Config.Miner.Ores'
	-- ticks an item, J a tick and least J an item (0: none).
	index: number,
	name: string,
	block: number,
	drop: number,
	ticks: number,
	joules: number,
	floor: number,
}

local MinerRules = {}

-- The miner's state codes (its state field; the low three bits of a packed state).
MinerRules.STATE = table.freeze({ MINING = 0, NO_POWER = 1, OUTPUT_FULL = 2, NO_ORE = 3, IDLE = 4 })
local MAX_CODE = MinerRules.STATE.IDLE

-- The side list: the ores whose entries carry no `miner` yet, at Config.Miner.Ores' numbers.
local NAMES = {}
-- (Config.Miner.Ores by name.)
local ORE_NUMBERS: { [string]: { ticks: number, joules: number, floor: number? } } = Config.Miner.Ores :: any

-- Every ore and its numbers, in ORES order: the side list's, then the entries' (`miner`).
local listed: { { name: string, numbers: { ticks: number, joules: number, floor: number? }, where: string } } = {}
for _, name in NAMES do
	local numbers = ORE_NUMBERS[name]
	assert(numbers, `MinerRules: Config.Miner.Ores has no {name}`)
	table.insert(listed, { name = name, numbers = numbers, where = name })
end
for name in ORE_NUMBERS do
	assert(table.find(NAMES, name), `MinerRules: Config.Miner.Ores names {name}, which is no ore it mines`)
end
do
	local content = Content.default
	for _, spec in content.blocks do
		local numbers = spec.miner
		if numbers then
			local where = content.where("block", spec.name)
			assert(
				not table.find(NAMES, spec.name),
				`MinerRules: {where} has its miner numbers, and MinerRules' side list names it too`
			)
			table.insert(listed, { name = spec.name, numbers = numbers, where = where })
		end
	end
end

local ores: { Ore } = {}
local byBlock: { [number]: Ore } = {}
for index, entry in listed do
	local name, numbers = entry.name, entry.numbers
	local block = Blocks.id[name]
	local drop = Items.blockDrops(block)
	assert(drop and drop.count == 1, `MinerRules: {entry.where} must drop one item`)
	assert(
		numbers.ticks >= 1 and numbers.ticks == math.floor(numbers.ticks) and numbers.joules > 0,
		`MinerRules: {entry.where} needs whole ticks and J a tick`
	)
	local ore: Ore = table.freeze({
		index = index,
		name = name,
		block = block,
		drop = drop.item,
		ticks = numbers.ticks,
		joules = numbers.joules,
		floor = numbers.floor or 0,
	})
	ores[index] = ore
	byBlock[block] = ore
end

MinerRules.ORES = table.freeze(ores)

-- The Ore of `block` (nil: no ore, or unknown).
function MinerRules.ore(block: number?): Ore?
	return if block then byBlock[block] else nil
end

-- The state views and records carry: `code` (STATE) + 8 x `index` (an ORES index, 0: none).
function MinerRules.packState(code: number, index: number): number
	local c = if code == code then math.clamp(math.floor(code), 0, MAX_CODE) else 0
	local i = if index == index then math.clamp(math.floor(index), 0, #ores) else 0
	return c + 8 * i
end

-- A packed state read back: (code, the ORES index, 0 none). Anything else reads as (MINING, 0).
function MinerRules.unpackState(state: number): (number, number)
	if type(state) ~= "number" or state ~= math.floor(state) or state < 0 then
		return MinerRules.STATE.MINING, 0
	end
	local code, index = state % 8, state // 8
	if code > MAX_CODE or index > #ores then
		return MinerRules.STATE.MINING, 0
	end
	return code, index
end

--[[
	What mining `ore` costs with `speed` Speed and `energy` Energy Upgrades (0..8 each; Upgrades
	clamps them) and a store of `baseCapacity` J before cards: (ticks an item, J a tick of work,
	capacity). ticks x the J a tick is never under the ore's floor: the J a tick is at least the
	floor / ticks rounded up to a whole QUANTUM, so the product is exact and at least the floor
	(Core.use takes a tick's J rounded up the same way).
]]
function MinerRules.settings(ore: Ore, speed: number, energy: number, baseCapacity: number): (number, number, number)
	local ticks = Upgrades.ticks(ore.ticks, speed)
	local energyPerTick = Upgrades.energyPerTick(ore.joules, speed, energy)
	if ore.floor > 0 then
		energyPerTick = math.max(energyPerTick, Core.quantiseUp(ore.floor / ticks))
	end
	return ticks, energyPerTick, Upgrades.capacity(baseCapacity, energy)
end

return MinerRules
