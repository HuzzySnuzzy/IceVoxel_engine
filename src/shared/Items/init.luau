--!strict
--[[
	Item registry: everything a player can hold.

	  * Every placeable block (BlockList `placeable`) is an item whose id is the block's id, so a
	    block item places `block = id`.
	  * Other items (ItemList: crafting materials, tools, armor, the Configurator and buckets)
	    have ids from ITEM_BASE up.
	  * Block variants that are no item of their own (wall torches, the upper halves of tall plants)
	    name the item that places and drops them (BlockList `item`); `ofBlock` answers it. An item
	    of ItemList may place a block that is no item of its own (ItemList `places`, Minecraft's
	    ItemNameBlockItem: Mint Leaves plant Mint); its `block` is that block, and `ofBlock`
	    answers the item for it too. A replaceable block is replaced by what is placed into it,
	    but not by its own item (`isReplacedBy`: Short Grass clicked on short grass goes against
	    the clicked face).
	  * What breaking a block gives: `drops` (by a survival player, with the tool in hand: nothing
	    without a good enough tool; Shears harvest what BlockList's `shearDrops` says, `shearCount`
	    of it: grass, ferns, dead bushes, leaves and glow lichen) and `blockDrops` (breaking by
	    itself, no tool), and now and then something else when a player breaks it (`randomDrop`:
	    gravel's flint; `leafDrop`: leaves' saplings and sticks). Creative only blocks (structure
	    blocks, structure voids, jigsaws; `isCreativeOnly`) never drop.

	Ids are stable as long as both lists only grow at the end, so they can be sent over the network
	and saved. `Items.list` is the creative inventory's order: blocks in BlockList order, then the
	other items.

	A stack is `{ item = id, count = n, damage = d?, data = t? }` with 1 <= n <= maxStack (an item's
	ItemList `maxStack`, a block's BlockList `maxStack`; 64 by default); empty slots are nil.
	`damage` is a tool's wear (Minecraft's damage value, 0 / nil = new); the tool breaks when it
	reaches the item's `durability`.

	Item data (`data`) is Minecraft's item NBT, made small and flat: a table of up to MAX_DATA_KEYS
	string keys (1..32 characters of letters, digits and "_") to finite numbers, strings of at most
	64 bytes or booleans. No data is nil, never an empty table. Mekanism keeps a block's contents in
	its item this way ("sustained data": a Fluid Tank's water is `{ fluid = 1, amount = mB }`).
	  * Data tables are values shared by every copy of a stack: never change one in place, make a
	    new one (`cleanData` / `withData` give frozen copies). `copyStack` and `withCount` keep it.
	  * Two stacks stack together only with the same item, wear and data (`stacksMatch`, Minecraft's
	    isSameItemSameTags; `sameData` compares data alone).
	  * Everything from the network goes through `validData` (Net/Protocol decodes nothing else);
	    `dataNumber` reads a number back (nil when it is missing or not a number).
	  * Crafting results carry no data; whatever keeps a block's contents puts them back on placing
	    (server Network/ServerNet's sustained data hooks).
	  * Tooltips show `describe(stack)`: one line per data key that has a describer, in the order
	    they were added (`addDescriber`; "fluid" and "energy" are built in), with the formatting
	    helpers `formatEnergy` (Mekanism's J / kJ / MJ / GJ) and `formatFluid` (mB).

	What an item leaves behind when a recipe or a furnace uses it up is its `craftingRemainder`
	(Minecraft's Item.getCraftingRemainingItem): a full bucket (Shared/Fluids' buckets) leaves the
	empty Bucket.
]]

local Blocks = require(script.Parent.Blocks)
-- (The fluids' data only: Shared/Fluids requires Items.)
local FluidList = require(script.Parent.Fluids.FluidList)
local ItemList = require(script.ItemList)

export type ModelBox = ItemList.ModelBox

-- A worn piece's Tough As Nails insulation (ItemList `tan`, with the defaults filled in).
export type TanInsulation = { warmth: number, cooling: number, freezeImmune: boolean }

export type ItemDef = {
	id: number,
	name: string,
	displayName: string,
	-- The block this item places (block items, and ItemList items with `places`).
	block: number?,
	maxStack: number,
	-- Armor: worn in armor slot `slot` (1 head, 2 chest, 3 legs, 4 feet).
	armor: { slot: number, defense: number, toughness: number }?,
	-- Tough As Nails insulation of a worn piece (ItemList `tan`): steps of warmth and cooling,
	-- and freeze immunity (Shared/ToughAsNails/Temperature, server Players/Climate).
	tan: TanInsulation?,
	-- Tools: kind ("pickaxe", "axe", "shovel", "hoe", "sword"), mining speed and harvest level.
	tool: { kind: string, speed: number, level: number }?,
	-- Uses before a tool breaks (nil: does not wear).
	durability: number?,
	color: { number },
	-- Non-block items: boxes (pixels, 1/16 block) the item is drawn with, their default look and
	-- how far the whole model is turned about Z (degrees).
	model: { ModelBox }?,
	material: string,
	tilt: number,
}

-- One value of item data, and item data itself (see above; nil = none).
export type DataValue = number | string | boolean
export type Data = { [string]: DataValue }

export type Stack = { item: number, count: number, damage: number?, data: Data? }

-- A tooltip line for a data key (nil: none), from the stack's whole data.
export type Describer = (data: Data, stack: Stack) -> string?

local Items = {}

-- First id of the items that are not blocks.
Items.ITEM_BASE = 4096
-- Names of the armor slots, in slot order.
Items.ARMOR_SLOTS = { "Head", "Chest", "Legs", "Feet" }
Items.MAX_STACK = 64

local ARMOR_SLOT: { [string]: number } = { Head = 1, Chest = 2, Legs = 3, Feet = 4 }

local defs: { [number]: ItemDef } = {}
local ids: { [string]: number } = {}
local list: { ItemDef } = {}

-- "IronHelmet" -> "Iron Helmet".
local function spaced(name: string): string
	return (string.gsub(name, "(%l)(%u)", "%1 %2"))
end

local function add(def: ItemDef)
	assert(ids[def.name] == nil, `Duplicate item name {def.name}`)
	defs[def.id] = def
	ids[def.name] = def.id
	table.insert(list, def)
end

-- (Of a fluid only the source block is placeable: the "Water" item.)
for id = 0, Blocks.count - 1 do
	local block = Blocks.get(id)
	if block.placeable then
		add({
			id = id,
			name = block.name,
			displayName = block.displayName or spaced(block.name),
			block = id,
			-- (64 unless BlockList says less: a Battery's 1, its charge being in each item.)
			maxStack = block.maxStack,
			armor = nil,
			tan = nil,
			tool = nil,
			durability = nil,
			color = block.color,
			model = nil,
			material = block.material,
			tilt = 0,
		})
	end
end

-- Blocks placed by an item of ItemList (`places`, Minecraft's ItemNameBlockItem) -> that item.
local placedBy: { [number]: number } = {}

for index, spec in ItemList do
	assert(not pcall(function()
		return Blocks.id[spec.name]
	end), `Item {spec.name} has the name of a block`)
	local places: number? = nil
	if spec.places then
		places = Blocks.find(spec.places)
		assert(places, `Item {spec.name} places unknown block {spec.places}`)
		local block = Blocks.get(places)
		assert(
			not block.placeable and block.item == nil and placedBy[places] == nil,
			`Item {spec.name} places {spec.places}, which is an item of its own or another's`
		)
		placedBy[places] = Items.ITEM_BASE + index - 1
	end
	local armor = nil
	if spec.armor then
		local slot = ARMOR_SLOT[spec.armor.slot]
		assert(slot, `Item {spec.name} has unknown armor slot {spec.armor.slot}`)
		armor = { slot = slot, defense = spec.armor.defense, toughness = spec.armor.toughness }
	end
	local tan: TanInsulation? = nil
	if spec.tan then
		assert(armor, `Item {spec.name} has Tough As Nails insulation but is no armor`)
		tan = table.freeze({
			warmth = spec.tan.warmth or 0,
			cooling = spec.tan.cooling or 0,
			freezeImmune = spec.tan.freezeImmune == true,
		})
	end
	add({
		id = Items.ITEM_BASE + index - 1,
		name = spec.name,
		displayName = spec.displayName or spaced(spec.name),
		block = places,
		maxStack = if spec.durability then 1 else spec.maxStack or Items.MAX_STACK,
		armor = armor,
		tan = tan,
		tool = spec.tool,
		durability = spec.durability,
		color = spec.color or { 255, 0, 255 },
		model = spec.model,
		material = spec.material or "SmoothPlastic",
		tilt = spec.tilt or 0,
	})
end

assert(#list < 65535, "Item ids must fit 16 bits")

-- What blocks drop and the items placing their variants must exist (`drops` / `item` are looked up
-- without erroring later, so a typo would silently drop nothing).
for id = 0, Blocks.count - 1 do
	local block = Blocks.get(id)
	local drops = block.drops
	assert(type(drops) ~= "string" or ids[drops] ~= nil, `Block {block.name} drops unknown item {drops}`)
	local item = block.item
	assert(
		item == nil or (ids[item] ~= nil and defs[ids[item]].block ~= nil),
		`Block {block.name} is placed by {item}, which is no block item`
	)
	-- (What Shears harvest: an item, or the block's own item.)
	local shear = block.shearDrops
	assert(
		shear == nil
			or (type(shear) == "string" and ids[shear] ~= nil)
			or (shear == true and (block.placeable or item ~= nil)),
		`Block {block.name} gives unknown shear drops`
	)
end

-- Every item, in creative inventory order.
Items.list = list

-- What a full bucket leaves when it is used up (Minecraft's craftRemainder(BUCKET)): the Bucket.
local remainders: { [number]: number } = {}
for _, fluid in FluidList do
	local bucket = ids[fluid.bucket]
	assert(bucket ~= nil and defs[bucket].block == nil, `Fluid {fluid.name}'s bucket {fluid.bucket} is no item`)
	remainders[bucket] = ids.Bucket
end

-- `Items.id.Stone`, `Items.id.IronHelmet`. Unknown names error instead of returning nil.
Items.id = (
	setmetatable(ids, {
		__index = function(_, name)
			error(`Unknown item name '{name}'`, 2)
		end,
	}) :: any
) :: { [string]: number }

function Items.get(id: number): ItemDef?
	return defs[id]
end

-- Items that were renamed: old name -> new name (blocks' items through Blocks.RENAMED too).
Items.RENAMED = table.freeze({
	GlowstoneDust = "GlowDust",
	Glowstone = "GlowBlock",
} :: { [string]: string })

-- The id of the item named `name` (or formerly named, Items.RENAMED), or nil when there is none:
-- for names that come from data (structure containers), where `Items.id` would error.
function Items.find(name: string): number?
	if type(name) ~= "string" then
		return nil
	end
	return rawget(ids :: any, name) or rawget(ids :: any, Items.RENAMED[name] or "")
end

function Items.isValid(id: number): boolean
	return defs[id] ~= nil
end

function Items.maxStack(id: number): number
	local def = defs[id]
	return if def then def.maxStack else Items.MAX_STACK
end

function Items.displayName(id: number): string
	local def = defs[id]
	return if def then def.displayName else "?"
end

--[[
	The item of a block: the block itself when it is an item, else the item its `item` field names
	(a wall torch's is the Torch: what placing uses up, pick block selects and breaking drops), or
	the item of ItemList that places it (`places`: Mint's Mint Leaves). nil when it is none of them.
]]
function Items.ofBlock(block: number): number?
	local def = defs[block]
	if def and def.block == block then
		return block
	end
	local blockDef = if Blocks.isValid(block) then Blocks.get(block) else nil
	local name = blockDef and blockDef.item
	if name then
		return rawget(ids :: any, name)
	end
	return placedBy[block]
end

--[[
	Does placing `item` (nil = nothing in hand) at a cell holding `block` replace that block?
	Replaceable blocks are replaced (air, water, short grass...), but not by their own item: a click
	on short grass with Short Grass, or on either half of tall grass with Tall Grass, places against
	the clicked face instead (Minecraft's BlockBehaviour.canBeReplaced(state, context)).
]]
function Items.isReplacedBy(block: number, item: number?): boolean
	return Blocks.isValid(block) and Blocks.isReplaceable(block) and (item == nil or Items.ofBlock(block) ~= item)
end

--[[
	What is left of `item` when a recipe or a furnace's fuel slot uses one up (Minecraft's
	Item.getCraftingRemainingItem): the empty Bucket for a full bucket (water, lava, oil, fuel), nil
	for everything else.
]]
function Items.craftingRemainder(item: number?): number?
	return if item then remainders[item] else nil
end

-- Armor slot (1 head .. 4 feet) an item is worn in, if it is armor.
function Items.armorSlot(id: number): number?
	local def = defs[id]
	return if def and def.armor then def.armor.slot else nil
end

-- The tool data of an item (nil for anything that is not a tool).
function Items.tool(id: number?): { kind: string, speed: number, level: number }?
	local def = if id then defs[id] else nil
	return if def then def.tool else nil
end

--[[
	Can a player holding `tool` (an item id, nil = bare hands) harvest `block`, i.e. does it drop
	anything? Blocks with a `toolLevel` need a tool of their kind of at least that tier (Minecraft's
	requiresCorrectToolForDrops and harvest levels).
]]
function Items.canHarvest(block: number, tool: number?): boolean
	local def = Blocks.get(block)
	if def == nil or def.toolLevel == nil then
		return true
	end
	local data = Items.tool(tool)
	return data ~= nil and data.kind == def.tool and data.level >= def.toolLevel
end

--[[
	What `block` drops when it breaks by itself (nil = nothing): a torch losing its wall, a lantern
	its ceiling, a torch washed away. No tool is involved, so nothing is held back for want of one
	(Minecraft only asks for the right tool when a player breaks the block).
]]
function Items.blockDrops(block: number): Stack?
	local def = if Blocks.isValid(block) then Blocks.get(block) else nil
	if def == nil or def.drops == false or def.creativeOnly then
		return nil
	end
	local item = if type(def.drops) == "string" then rawget(ids :: any, def.drops) else Items.ofBlock(block)
	if item == nil then
		return nil
	end
	return { item = item, count = def.dropCount }
end

--[[
	Is `item` a creative only block's item (a structure block, structure void or jigsaw; BlockList
	`creativeOnly`)? Only creative players place and use them.
]]
function Items.isCreativeOnly(item: number?): boolean
	local def = if item then defs[item] else nil
	local block = def and def.block
	return block ~= nil and Blocks.isCreativeOnly(block)
end

-- Is `item` Shears (a tool of kind "shears")?
function Items.isShears(item: number?): boolean
	local data = Items.tool(item)
	return data ~= nil and data.kind == "shears"
end

--[[
	What breaking `block` with `tool` (nil = bare hands) gives a survival player (nil = nothing):
	nothing when the tool can't harvest it (`canHarvest`); with Shears, what the block's
	`shearDrops` names, `shearCount` of it (Minecraft's loot tables' `match_tool shears`: tall grass
	gives 2 short grass, leaves themselves); otherwise its `blockDrops`.
]]
function Items.drops(block: number, tool: number?): Stack?
	if not Blocks.isValid(block) or Blocks.isCreativeOnly(block) or not Items.canHarvest(block, tool) then
		return nil
	end
	local def = Blocks.get(block)
	local shear = def.shearDrops
	if shear ~= nil and Items.isShears(tool) then
		local item = if type(shear) == "string" then rawget(ids :: any, shear) else Items.ofBlock(block)
		if item ~= nil then
			return { item = item, count = def.shearCount }
		end
	end
	return Items.blockDrops(block)
end

--[[
	What leaves drop by themselves: when they decay (server Behaviours/Leaves) or a player breaks
	them without Shears. Minecraft's leaves loot table: its sapling one time in 20 (jungle: 40),
	else 1 or 2 sticks one time in 50; nothing otherwise. `random` rolls in [0, 1). nil for
	blocks that aren't leaves with a sapling.
]]
function Items.leafDrop(block: number, random: () -> number): Stack?
	if not Blocks.isValid(block) then
		return nil
	end
	local name = Blocks.get(block).name
	if string.sub(name, -6) ~= "Leaves" then
		return nil
	end
	local sapling = rawget(ids :: any, string.sub(name, 1, -7) .. "Sapling")
	local chance = if name == "JungleLeaves" then 1 / 40 else 1 / 20
	if sapling and random() < chance then
		return { item = sapling, count = 1 }
	end
	if random() < 1 / 50 then
		return { item = ids.Stick, count = if random() < 0.5 then 1 else 2 }
	end
	return nil
end

--[[
	What a block drops now and then in place of its usual drop when a player breaks it (`random`
	rolls in [0, 1)): Gravel gives Flint one time in 10 (Minecraft's gravel loot table without
	Fortune; there is no Silk Touch). nil: the usual drop (Items.drops). Gravel that falls onto a
	torch drops itself, as Minecraft's falling block does.
]]
function Items.randomDrop(block: number, random: () -> number): Stack?
	if block == Blocks.id.Gravel and random() < 0.1 then
		return { item = ids.Flint, count = 1 }
	end
	return nil
end

-- Items whose name or display name contains `query` (any case), in creative order.
function Items.search(query: string): { ItemDef }
	local needle = string.lower((string.gsub(query, "^%s+", ""):gsub("%s+$", "")))
	if needle == "" then
		return list
	end
	local found = {}
	for _, def in list do
		if
			string.find(string.lower(def.displayName), needle, 1, true)
			or string.find(string.lower(def.name), needle, 1, true)
		then
			table.insert(found, def)
		end
	end
	return found
end

-- Minecraft armor points worn (0..20 for full diamond) and toughness.
function Items.armorPoints(armor: { [number]: Stack? }): (number, number)
	local points, toughness = 0, 0
	for slot = 1, #Items.ARMOR_SLOTS do
		local stack = armor[slot]
		local def = stack and defs[stack.item]
		if def and def.armor and def.armor.slot == slot then
			points += def.armor.defense
			toughness += def.armor.toughness
		end
	end
	return points, toughness
end

--[[
	Damage left after armor (Minecraft's CombatRules.getDamageAfterAbsorb): armor blocks 4% per
	point, less against big hits, at most 80%.
]]
function Items.damageAfterArmor(damage: number, points: number, toughness: number): number
	local effective = math.clamp(points - damage / (2 + toughness / 4), points / 5, 20)
	return damage * (1 - effective / 25)
end

--[[ Item data (Minecraft's item NBT, flat) ]]

-- Most keys in one stack's data, key length (bytes) and string value length (bytes).
Items.MAX_DATA_KEYS = 16
Items.MAX_DATA_KEY = 32
Items.MAX_DATA_STRING = 64

-- Is `key` a data key: 1..MAX_DATA_KEY letters, digits and underscores?
function Items.validDataKey(key: any): boolean
	return type(key) == "string" and #key >= 1 and #key <= Items.MAX_DATA_KEY and string.find(key, "^[%w_]+$") ~= nil
end

-- Is `value` a data value: a finite number, a string of at most MAX_DATA_STRING bytes or a boolean?
function Items.validDataValue(value: any): boolean
	local kind = type(value)
	if kind == "number" then
		return value == value and value ~= math.huge and value ~= -math.huge
	elseif kind == "string" then
		return #value <= Items.MAX_DATA_STRING
	end
	return kind == "boolean"
end

--[[
	Is `data` valid item data? nil is (no data); otherwise a table of 1..MAX_DATA_KEYS entries, each
	a `validDataKey` to a `validDataValue`. An empty table is not: no data is nil. Everything a
	client sends (and every stack a snapshot brings) passes through this.
]]
function Items.validData(data: any): boolean
	if data == nil then
		return true
	elseif type(data) ~= "table" then
		return false
	end
	local n = 0
	for key, value in next, data do
		n += 1
		if n > Items.MAX_DATA_KEYS or not Items.validDataKey(key) or not Items.validDataValue(value) then
			return false
		end
	end
	return n > 0
end

--[[
	`data` as a stack keeps it: a frozen copy (so copies of the stack may share it), or nil for no
	data, an empty table, or anything `validData` refuses.
]]
function Items.cleanData(data: any): Data?
	if data == nil or not Items.validData(data) then
		return nil
	end
	if table.isfrozen(data) then
		return data
	end
	return table.freeze(table.clone(data))
end

-- Do `a` and `b` hold the same data (nil and nil alike; keys in any order)?
function Items.sameData(a: Data?, b: Data?): boolean
	if a == b then
		return true
	elseif a == nil or b == nil then
		return false
	end
	local n = 0
	for key, value in next, a do
		if b[key] ~= value then
			return false
		end
		n += 1
	end
	for _ in next, b do
		n -= 1
	end
	return n == 0
end

-- The number `data` keeps under `key` (nil: no data, no such key, or not a number). For reading
-- sustained data back: `Items.dataNumber(stack.data, "energy")`.
function Items.dataNumber(data: Data?, key: string): number?
	local value = if data then data[key] else nil
	return if type(value) == "number" then value else nil
end

--[[
	A string that is the same exactly for equal data ("" for none): keys sorted, each with its value
	and type. For grouping stacks by kind (JEI's transfer) and for logs.
]]
function Items.dataKey(data: Data?): string
	if data == nil then
		return ""
	end
	local keys: { string } = {}
	for key in next, data do
		table.insert(keys, key)
	end
	table.sort(keys)
	local parts = table.create(#keys)
	for i, key in keys do
		local value = data[key]
		-- (-0 and 0 are equal data, as sameData says, so they write alike.)
		local text = if value == 0
			then "0"
			elseif type(value) == "number" then string.format("%.17g", value)
			else tostring(value)
		parts[i] = `{key}={string.sub(type(value), 1, 1)}{#text}:{text}`
	end
	return table.concat(parts, ";")
end

--[[ Stacks ]]

-- A tool's wear as kept in a stack: a positive whole number, or nil when new (0 and junk read as new).
function Items.cleanDamage(damage: any): number?
	if type(damage) == "number" and damage >= 1 and damage == math.floor(damage) and damage < math.huge then
		return damage
	end
	return nil
end

--[[
	A new stack: nil for a count below 1 (Minecraft's empty ItemStack), else `damage` cleaned
	(`cleanDamage`) and `data` kept as it is: it must already be a stack's data (`cleanData`).
]]
function Items.newStack(item: number, count: number, damage: number?, data: Data?): Stack?
	if count < 1 then
		return nil
	end
	return { item = item, count = count, damage = Items.cleanDamage(damage), data = data }
end

-- A copy of `stack` (wear and data kept); nil for nil or a count below 1.
function Items.copyStack(stack: Stack?): Stack?
	if stack == nil or stack.count < 1 then
		return nil
	end
	return { item = stack.item, count = stack.count, damage = Items.cleanDamage(stack.damage), data = stack.data }
end

-- `count` of the same item as `stack`, with its wear and data (nil for a count below 1).
function Items.withCount(stack: Stack, count: number): Stack?
	return Items.newStack(stack.item, count, stack.damage, stack.data)
end

-- A copy of `stack` holding `data` instead (cleaned: nil, empty or invalid data means none).
function Items.withData(stack: Stack, data: any): Stack
	return {
		item = stack.item,
		count = stack.count,
		damage = Items.cleanDamage(stack.damage),
		data = Items.cleanData(data),
	}
end

--[[
	Do two stacks stack together: the same item, the same wear (nil and 0 alike) and the same data
	(Minecraft's ItemStack.isSameItemSameTags)?
]]
function Items.stacksMatch(a: Stack, b: Stack): boolean
	return a.item == b.item
		and (Items.cleanDamage(a.damage) or 0) == (Items.cleanDamage(b.damage) or 0)
		and Items.sameData(a.data, b.data)
end

--[[ Tooltips ]]

-- Fluid names by fluid id (Shared/Fluids: 1 water, 2 lava, 3 oil, 4 fuel).
local FLUID_NAMES: { string } = {}
for id, fluid in FluidList do
	FLUID_NAMES[id] = fluid.displayName or fluid.name
end
-- Energy units (Mekanism's MeasurementUnit prefixes) from the largest.
local ENERGY_UNITS: { { scale: number, suffix: string } } = {
	{ scale = 1e9, suffix = "GJ" },
	{ scale = 1e6, suffix = "MJ" },
	{ scale = 1e3, suffix = "kJ" },
}

-- A whole number with thousands separators, as Mekanism writes amounts: 32000 -> "32,000".
function Items.thousands(value: number): string
	if value ~= value then
		return "0"
	end
	local whole = math.floor(math.abs(value) + 0.5)
	local text = if whole < 1e15 then string.format("%d", whole) else string.format("%.0f", whole)
	local grouped = string.reverse((string.gsub(string.reverse(text), "(%d%d%d)", "%1,")))
	if string.sub(grouped, 1, 1) == "," then
		grouped = string.sub(grouped, 2)
	end
	return if value <= -0.5 then "-" .. grouped else grouped
end

--[[
	Energy as Mekanism shows it (UnitDisplayUtils.getDisplayShort): joules in the largest unit of J,
	kJ, MJ and GJ that keeps the number at least 1, cut (not rounded, so nothing short of full reads
	full) to two decimals without trailing zeros: 400 -> "400 J", 1200 -> "1.2 kJ", 19999 ->
	"19.99 kJ", 4e6 -> "4 MJ". Infinity is "Infinite" (Mekanism's creative cube).
]]
function Items.formatEnergy(joules: number): string
	if joules ~= joules then
		return "0 J"
	elseif joules == math.huge or joules == -math.huge then
		return if joules > 0 then "Infinite" else "-Infinite"
	end
	local size = math.abs(joules)
	local scale, suffix = 1, "J"
	for _, unit in ENERGY_UNITS do
		if size >= unit.scale then
			scale, suffix = unit.scale, unit.suffix
			break
		end
	end
	-- (Hundredths, nudged up so 1.2 MJ, which is 1.19999... in binary, still reads 1.2.)
	local hundredths = math.floor(size / scale * 100 + 1e-6)
	local whole, fraction = hundredths // 100, hundredths % 100
	local text = if whole >= 1e15 then string.format("%.0f", whole) else string.format("%d", whole)
	if fraction > 0 then
		text ..= if fraction % 10 == 0 then `.{fraction // 10}` else string.format(".%02d", fraction)
	end
	local sign = if joules < 0 and hundredths > 0 then "-" else ""
	return `{sign}{text} {suffix}`
end

-- An amount of fluid, as Mekanism writes it: 12000 -> "12,000 mB".
function Items.formatFluid(mB: number): string
	return `{Items.thousands(mB)} mB`
end

-- Data keys with a describer, in the order lines are shown.
local describerOrder: { string } = {}
local describers: { [string]: Describer } = {}

--[[
	Adds the tooltip line of a data key: `describer(data, stack)` returns it (nil: none) for every
	stack whose data has `key`. A key described already gets the new describer in the same place.
	Later phases add theirs at load time (a module the UI requires, or this one's built-ins).
]]
function Items.addDescriber(key: string, describer: Describer)
	assert(Items.validDataKey(key), `Bad data key {key}`)
	if describers[key] == nil then
		table.insert(describerOrder, key)
	end
	describers[key] = describer
end

--[[
	The tooltip lines of a stack's data (Mekanism's item tooltips): one per data key that has a
	describer, in the order they were added. Keys without one show nothing (as Minecraft hides NBT).
]]
function Items.describe(stack: Stack?): { string }
	local lines: { string } = {}
	local data = if stack then stack.data else nil
	if stack == nil or data == nil then
		return lines
	end
	for _, key in describerOrder do
		if data[key] ~= nil then
			local ok, line = pcall(describers[key], data, stack)
			if ok and type(line) == "string" and line ~= "" then
				table.insert(lines, line)
			end
		end
	end
	return lines
end

-- A Fluid Tank's contents (`fluid` id, Shared/Fluids; `amount` mB): "Lava: 12,000 mB".
Items.addDescriber("fluid", function(data: Data): string?
	local fluid, amount = Items.dataNumber(data, "fluid"), Items.dataNumber(data, "amount")
	local name = if fluid then FLUID_NAMES[fluid] else nil
	if name == nil or amount == nil or amount <= 0 then
		return nil
	end
	return `{name}: {Items.formatFluid(amount)}`
end)

-- Stored energy (`energy`, joules): "Energy: 1.2 MJ".
Items.addDescriber("energy", function(data: Data): string?
	local energy = Items.dataNumber(data, "energy")
	if energy == nil then
		return nil
	end
	return `Energy: {Items.formatEnergy(energy)}`
end)

-- The fluid names `describe` uses, by fluid id (Shared/Fluids; read only).
Items.FLUID_NAMES = table.freeze(table.clone(FLUID_NAMES))

return Items
