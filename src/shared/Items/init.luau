--!strict
--[[
	Item registry: everything a player can hold.

	  * Every placeable block (BlockList `placeable`) is an item whose id is the block's id, so a
	    block item places `block = id`.
	  * Other items (ItemList: crafting materials, tools, armor) have ids from ITEM_BASE up.

	Ids are stable as long as both lists only grow at the end, so they can be sent over the network
	and saved. `Items.list` is the creative inventory's order: blocks in BlockList order, then the
	other items.

	A stack is `{ item = id, count = n, damage = d? }` with 1 <= n <= maxStack; empty slots are nil.
	`damage` is a tool's wear (Minecraft's damage value, 0 / nil = new); the tool breaks when it
	reaches the item's `durability`.
]]

local Blocks = require(script.Parent.Blocks)
local ItemList = require(script.ItemList)

export type ModelBox = ItemList.ModelBox

export type ItemDef = {
	id: number,
	name: string,
	displayName: string,
	-- The block this item places (block items only).
	block: number?,
	maxStack: number,
	-- Armor: worn in armor slot `slot` (1 head, 2 chest, 3 legs, 4 feet).
	armor: { slot: number, defense: number, toughness: number }?,
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

export type Stack = { item: number, count: number, damage: number? }

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
			maxStack = Items.MAX_STACK,
			armor = nil,
			tool = nil,
			durability = nil,
			color = block.color,
			model = nil,
			material = block.material,
			tilt = 0,
		})
	end
end

for index, spec in ItemList do
	assert(not pcall(function()
		return Blocks.id[spec.name]
	end), `Item {spec.name} has the name of a block`)
	local armor = nil
	if spec.armor then
		local slot = ARMOR_SLOT[spec.armor.slot]
		assert(slot, `Item {spec.name} has unknown armor slot {spec.armor.slot}`)
		armor = { slot = slot, defense = spec.armor.defense, toughness = spec.armor.toughness }
	end
	add({
		id = Items.ITEM_BASE + index - 1,
		name = spec.name,
		displayName = spec.displayName or spaced(spec.name),
		block = nil,
		maxStack = if spec.durability then 1 else spec.maxStack or Items.MAX_STACK,
		armor = armor,
		tool = spec.tool,
		durability = spec.durability,
		color = spec.color or { 255, 0, 255 },
		model = spec.model,
		material = spec.material or "SmoothPlastic",
		tilt = spec.tilt or 0,
	})
end

assert(#list < 65535, "Item ids must fit 16 bits")

-- Every item, in creative inventory order.
Items.list = list

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

-- The item of a block, if the block is one.
function Items.ofBlock(block: number): number?
	local def = defs[block]
	if def and def.block == block then
		return block
	end
	return nil
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

-- What breaking `block` with `tool` (nil = bare hands) gives a survival player (nil = nothing).
function Items.drops(block: number, tool: number?): Stack?
	local def = Blocks.get(block)
	if def == nil or def.drops == false or not Items.canHarvest(block, tool) then
		return nil
	end
	local item = if type(def.drops) == "string" then ids[def.drops] else Items.ofBlock(block)
	if item == nil then
		return nil
	end
	return { item = item, count = def.dropCount }
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

return Items
