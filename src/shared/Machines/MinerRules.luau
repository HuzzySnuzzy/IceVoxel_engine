--!strict
--[[
	The Metal Miner's rules (Machines/Kinds/Miner, kind "miner"), pure: which blocks it mines, what
	each one gives, and its state code.

	  ORES       every ore block BlockList has, in this order (frozen: the order is packed into the
	             miner's state): Coal Ore, Iron Ore, Osmium Ore, Gold Ore, Emerald Ore, Diamond
	             Ore. Each gives its drop (Items.blockDrops: Coal, Raw Iron, Raw Osmium, Raw Gold,
	             an Emerald, a Diamond; one a time), not the ore block (drops are what furnaces and
	             the Electric Furnace take, and an ore block can't be moved: a miner is built on a
	             vein where it lies), and Config.Miner.Ores' numbers: ticks an item, J a tick, the
	             least J an item costs (`floor`: coal never makes more energy than it took)
	  ore        the Ore of a block (nil: no ore)
	  STATE      the miner's state codes: MINING, NO_POWER, OUTPUT_FULL, NO_ORE ("No ore below")
	  packState  its state field: code + 8 x the ore's index in ORES (0: none), frozen;
	             unpackState reads it back

	Checked as this loads: every ore is a block whose drop is an item, Config.Miner.Ores names each
	of them and nothing else.

	FOUNDATION: ORES, ore, STATE and the packing. Miner builder C adds the rest here (`settings`:
	the ticks, energy a tick and capacity with upgrade cards and the floor) with the kind's tick.
]]

local Blocks = require(script.Parent.Parent.Blocks)
local Config = require(script.Parent.Parent.Config)
local Items = require(script.Parent.Parent.Items)

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

-- The miner's state codes (the low three bits of its state field).
MinerRules.STATE = table.freeze({ MINING = 0, NO_POWER = 1, OUTPUT_FULL = 2, NO_ORE = 3 })
local MAX_CODE = MinerRules.STATE.NO_ORE

local NAMES = { "CoalOre", "IronOre", "OsmiumOre", "GoldOre", "EmeraldOre", "DiamondOre" }
-- (Config.Miner.Ores by name.)
local ORE_NUMBERS: { [string]: { ticks: number, joules: number, floor: number? } } = Config.Miner.Ores :: any

local ores: { Ore } = {}
local byBlock: { [number]: Ore } = {}
for index, name in NAMES do
	local block = Blocks.id[name]
	local drop = Items.blockDrops(block)
	assert(drop and drop.count == 1, `MinerRules: {name} must drop one item`)
	local numbers = ORE_NUMBERS[name]
	assert(numbers, `MinerRules: Config.Miner.Ores has no {name}`)
	assert(
		numbers.ticks >= 1 and numbers.ticks == math.floor(numbers.ticks) and numbers.joules > 0,
		`MinerRules: {name} needs whole ticks and J a tick`
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
for name in ORE_NUMBERS do
	assert(table.find(NAMES, name), `MinerRules: Config.Miner.Ores names {name}, which is no ore it mines`)
end

MinerRules.ORES = table.freeze(ores)

-- The Ore of `block` (nil: no ore, or unknown).
function MinerRules.ore(block: number?): Ore?
	return if block then byBlock[block] else nil
end

-- The state field: `code` (STATE) + 8 x `index` (an ORES index, 0: none).
function MinerRules.packState(code: number, index: number): number
	local c = if code == code then math.clamp(math.floor(code), 0, MAX_CODE) else 0
	local i = if index == index then math.clamp(math.floor(index), 0, #ores) else 0
	return c + 8 * i
end

-- The state field read back: (code, the ORES index, 0 none). Anything else reads as (MINING, 0).
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

return MinerRules
