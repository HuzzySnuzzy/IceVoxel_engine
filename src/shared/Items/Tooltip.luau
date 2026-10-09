--!strict
--[[
	Every line of an item's tooltip, pure (no Roblox APIs, so the tests run it): the one source the
	inventory, the creative screen, the hotbar's slots and JEI read (client Ui/Screens draws them).
	`lines(item, stack?, options?)` gives { text, colour } lines, `colour` a name the client maps
	to its palette (Ui/Style.Colour): Minecraft's tooltip colours.

	  Order     name (white); the stack's item data (Items.describe: a tank's fluid, stored energy,
	            a generator's fuel; gray); the lore (Items/LoreList, Minecraft's dark purple lore);
	            what the item is (a tool's harvest level and mining speed, a block's tool, light,
	            falling, climbing, storage, heat, energy and pipe numbers; gray); then the stat
	            blocks, each after an empty line under a gray heading, as Minecraft's attribute
	            blocks are: "When in Main Hand:" (dark green " 6 Attack Damage", " 1.6 Attack
	            Speed": Shared/Entities/Combat's numbers, the hand's 1 included, as Minecraft writes
	            them) with the wear under it ("Durability: 200 / 250", Minecraft's advanced
	            tooltip line, a stack's `damage`), "When on Head:" (blue "+2 Armor", "+2 Armor
	            Toughness", and Tough As Nails' insulation "+1 Warmth", "+1 Cooling", "Keeps you
	            from freezing"), "When eaten:" (Items/Foods: "Heals 2 hearts", a risk in red),
	            "When drunk:" (ToughAsNails/Drinks: thirst and hydration, the Thirst risk of dirty
	            water in red, a tea's Internal Warmth or Chill, a potion's effects through
	            Shared/Effects.tooltip, red when harmful) with a canteen's "Sips: 2 / 3" under it,
	            "As fuel:" (Crafting/Smelting's burn time and the items it smelts, what a Heat
	            Generator or Combustion Generator makes of it: Shared/Machines' info), an
	            accessory's "When worn:" (Items/Accessories.tooltip) and a mana item's lines
	            (Shared/Mana.tooltip); last, with `options.gate` (the player's Progression state
	            while the recipe gate applies), what making it needs in red ("Crafting requires
	            the Iron Age", Shared/Progression.lockText).
	  Tools     a pickaxe (any kind with blocks that need more than its lowest tier) names its
	            harvest level (Wood, Stone, Iron, Diamond: gold is wood's) and the best blocks it
	            harvests (ores first); every tool but swords its mining speed (Shared/Mining).
	  Blocks    the tool that mines it ("Needs a Stone Pickaxe or better", "Best tool: Axe"),
	            "Light: 14", "Falls" (Gravity), "Climbable", "Slippery", a chest's slots,
	            "Flammable", heat and cold for Tough As Nails (Config.ToughAsNails Heating /
	            CoolingBlocks), "Creative only", an energy block's store, a tank's capacity and a
	            transmitter's tier numbers (Transmitters/Tiers, Mekanism's own tooltips).

	Every LoreList key must be an item (checked as this loads); every item having lore is
	tests/spec/Tooltips' to check, so a missing line never breaks a running game.
]]

local Blocks = require(script.Parent.Parent.Blocks)
local Combat = require(script.Parent.Parent.Entities.Combat)
local Config = require(script.Parent.Parent.Config)
local Effects = require(script.Parent.Parent.Effects)
local Items = require(script.Parent)
local Accessories = require(script.Parent.Accessories)
local Foods = require(script.Parent.Foods)
local LoreList = require(script.Parent.LoreList)
local Machines = require(script.Parent.Parent.Machines)
local Mana = require(script.Parent.Parent.Mana)
local Progression = require(script.Parent.Parent.Progression)
local Smelting = require(script.Parent.Parent.Crafting.Smelting)
local Drinks = require(script.Parent.Parent.ToughAsNails.Drinks)
local Tiers = require(script.Parent.Parent.Transmitters.Tiers)
local Fluids = require(script.Parent.Parent.Fluids)

type Stack = Items.Stack

-- Minecraft's tooltip colours by name (the client's Style.Colour): white the name, gray info and
-- headings, blue a good modifier, red a harmful one or a lock, darkGreen a weapon's base numbers,
-- lore the lore's dark purple.
export type Colour = "white" | "gray" | "blue" | "red" | "darkGreen" | "lore"
export type Line = { text: string, colour: Colour }

--[[
	`gate`: the state the recipe gate judges the player by (client Player/ProgressionState.gate;
	nil: no lock line).
]]
export type Options = { gate: Progression.State? }

local Tooltip = {}

-- Harvest levels' names (Minecraft's tiers: 0 wood and gold, 1 stone, 2 iron, 3 diamond).
Tooltip.LEVELS = table.freeze({ [0] = "Wood", [1] = "Stone", [2] = "Iron", [3] = "Diamond" } :: { [number]: string })
-- The most blocks a tool's harvest line names.
Tooltip.HARVEST_NAMES = 3

for name in LoreList do
	assert(rawget(Items.id :: any, name) ~= nil, `LoreList names unknown item {name}`)
end

-- A number as Minecraft's tooltips write it (ItemStack.ATTRIBUTE_MODIFIER_FORMAT, "#.##"): 4,
-- 1.6, 2.5, 0.33.
function Tooltip.number(value: number): string
	local text = string.format("%.2f", value)
	text = string.gsub(text, "0+$", "")
	text = string.gsub(text, "%.$", "")
	return if text == "-0" then "0" else text
end

-- "pickaxe" -> "Pickaxe".
local function capital(text: string): string
	return string.upper(string.sub(text, 1, 1)) .. string.sub(text, 2)
end

-- Half hearts as hearts: 4 -> "2 hearts", 3 -> "1.5 hearts", 2 -> "1 heart", 1 -> "half a heart".
function Tooltip.hearts(halfHearts: number): string
	if halfHearts == 1 then
		return "half a heart"
	end
	local hearts = halfHearts / 2
	return `{Tooltip.number(hearts)} {if hearts == 1 then "heart" else "hearts"}`
end

-- Seconds of ticks, with thousands separators: 1600 -> "80 s".
local function seconds(ticks: number): string
	local value = ticks / 20
	return `{if value == math.floor(value) then Items.thousands(value) else Tooltip.number(value)} s`
end

-- The item's lore line (nil: none yet).
function Tooltip.lore(item: number): string?
	local def = Items.get(item)
	return if def then LoreList[def.name] else nil
end

--[[ Blocks the tools harvest ]]

-- Per tool kind: the highest `toolLevel` any block of that kind needs, and the blocks by level,
-- ores first then in BlockList order (their items' names).
local maxLevel: { [string]: number } = {}
local byLevel: { [string]: { [number]: { string } } } = {}
do
	local ores: { [string]: { [number]: { string } } } = {}
	for id = 0, Blocks.count - 1 do
		local def = Blocks.get(id)
		local kind, level = def.tool, def.toolLevel
		if kind and level and def.placeable and not def.creativeOnly then
			maxLevel[kind] = math.max(maxLevel[kind] or 0, level)
			local isOre = string.sub(def.name, -3) == "Ore"
			local into = if isOre then ores else byLevel
			into[kind] = into[kind] or {}
			into[kind][level] = into[kind][level] or {}
			table.insert(into[kind][level], Items.displayName(id))
		end
	end
	for kind, levels in ores do
		byLevel[kind] = byLevel[kind] or {}
		for level, names in levels do
			local rest = byLevel[kind][level] or {}
			table.move(rest, 1, #rest, #names + 1, names)
			byLevel[kind][level] = names
		end
	end
end

-- What a tool says about mining (see the header).
local function toolLines(lines: { Line }, tool: { kind: string, speed: number, level: number })
	if tool.kind == "sword" then
		return
	end
	local top = maxLevel[tool.kind]
	if top and top > 0 then
		table.insert(
			lines,
			{ text = `Harvest level: {Tooltip.LEVELS[tool.level] or tostring(tool.level)}`, colour = "gray" }
		)
		-- (The best blocks it harvests: those of its own tier, or the highest below it.)
		local levels = byLevel[tool.kind] or {}
		for level = math.min(tool.level, top), 0, -1 do
			local names = levels[level]
			if names and #names > 0 then
				local shown = table.move(names, 1, math.min(#names, Tooltip.HARVEST_NAMES), 1, {})
				table.insert(lines, { text = `Harvests up to: {table.concat(shown, ", ")}`, colour = "gray" })
				break
			end
		end
	end
	table.insert(lines, { text = `Mining speed: {Tooltip.number(tool.speed)}x`, colour = "gray" })
end

--[[ Blocks ]]

local heating: { [number]: boolean } = {}
local cooling: { [number]: boolean } = {}
do
	local settings = Config.ToughAsNails :: any
	for _, pair in { { settings.HeatingBlocks, heating }, { settings.CoolingBlocks, cooling } } do
		for _, name in (pair[1] or {}) :: { string } do
			local id = Blocks.find(name)
			if id then
				pair[2][id] = true
			end
		end
	end
end

-- "Needs a Stone Pickaxe or better", "Needs a Pickaxe", "Needs a Sword or Shears", "Best tool:
-- Axe".
local function toolNeeded(def: Blocks.BlockDef): string?
	local kind = def.tool
	if kind == nil then
		return nil
	end
	local name = capital(kind)
	local level = def.toolLevel
	if level == nil then
		return `Best tool: {name}`
	end
	local tool = if level > 0 then `{Tooltip.LEVELS[level] or tostring(level)} {name} or better` else name
	local article = if string.find(tool, "^[AEIOU]") then "an" else "a"
	return `Needs {article} {tool}{if def.shearDrops ~= nil then " or Shears" else ""}`
end

-- What a block item says about its block (see the header).
local function blockLines(lines: { Line }, block: number)
	local def = Blocks.get(block)
	local function add(text: string)
		table.insert(lines, { text = text, colour = "gray" })
	end
	if def.creativeOnly then
		add("Creative only")
	elseif def.breakable and def.hardness >= 0 and not def.fluid then
		local needed = toolNeeded(def)
		if needed then
			add(needed)
		end
	end
	local light = Blocks.light(block)
	if light > 0 then
		add(`Light: {light}`)
	end
	if def.behaviour == "Gravity" then
		add("Falls when nothing holds it up")
	end
	if Blocks.isClimbable(block) then
		add("Climbable")
	end
	if def.friction > 0.6 then
		add("Slippery")
	end
	if def.menu == "Chest" and def.container > 0 then
		add(`Storage: {def.container} slots`)
	end
	if Blocks.isFlammable(block) then
		add("Flammable")
	end
	if heating[block] then
		add("Warms you when you are close")
	elseif cooling[block] then
		add("Cools you when you are close")
	end
	local energy = Machines.energyOf(block)
	if energy then
		add(if energy.capacity == math.huge then "Energy: Infinite" else `Stores {Items.formatEnergy(energy.capacity)}`)
	end
	local tank = def.tank
	if tank then
		add(`Capacity: {Items.formatFluid(tank.capacity)}`)
	end
	local transmitter = def.transmitter
	local tier = if transmitter then Tiers.TIERS[transmitter.tier] else nil
	if transmitter and tier then
		if transmitter.kind == "item" then
			local speed = tier.transporterSpeed * Tiers.TICK_RATE / Tiers.BLOCK_PROGRESS
			add(`Speed: {Tooltip.number(speed)} {if speed == 1 then "block" else "blocks"}/s`)
			add(`Pulls {tier.transporterPull} {if tier.transporterPull == 1 then "item" else "items"} at a time`)
		elseif transmitter.kind == "fluid" then
			add(`Capacity: {Items.formatFluid(tier.pipeCapacity)}`)
			add(`Pulls {Items.formatFluid(tier.pipePull)}/t`)
		elseif transmitter.kind == "energy" then
			add(`Capacity: {Items.formatEnergy(tier.cableCapacity)}/t`)
		end
	end
end

--[[ Stat blocks ]]

-- An empty line and a gray heading, then the block's own lines.
local function section(lines: { Line }, heading: string, body: { Line })
	if #body == 0 then
		return
	end
	table.insert(lines, { text = "", colour = "white" })
	table.insert(lines, { text = heading, colour = "gray" })
	table.move(body, 1, #body, #lines + 1, lines)
end

-- Status effects as Shared/Effects.tooltip writes them, blue or red.
local function effectLines(
	into: { Line },
	given: { { effect: number, ticks: number, amplifier: number } },
	prefix: string?
)
	for _, line in Effects.tooltip(given) do
		table.insert(into, { text = (prefix or "") .. line.text, colour = if line.harmful then "red" else "blue" })
	end
end

-- "When in Main Hand:": a weapon's or tool's attack (Shared/Entities/Combat).
local function mainHand(lines: { Line }, def: Items.ItemDef)
	if def.attack == nil then
		return
	end
	local damage, speed = Combat.attackOf(def.id)
	section(lines, "When in Main Hand:", {
		{ text = ` {Tooltip.number(damage)} Attack Damage`, colour = "darkGreen" },
		{ text = ` {Tooltip.number(speed)} Attack Speed`, colour = "darkGreen" },
	})
end

-- "When on Head:": armor points, toughness and Tough As Nails insulation.
local function armorLines(lines: { Line }, def: Items.ItemDef)
	local armor = def.armor
	if armor == nil then
		return
	end
	local body: { Line } = { { text = `+{armor.defense} Armor`, colour = "blue" } }
	if armor.toughness > 0 then
		table.insert(body, { text = `+{armor.toughness} Armor Toughness`, colour = "blue" })
	end
	local tan = def.tan
	if tan then
		if tan.warmth > 0 then
			table.insert(body, { text = `+{Tooltip.number(tan.warmth)} Warmth`, colour = "blue" })
		end
		if tan.cooling > 0 then
			table.insert(body, { text = `+{Tooltip.number(tan.cooling)} Cooling`, colour = "blue" })
		end
		if tan.freezeImmune then
			table.insert(body, { text = "Keeps you from freezing", colour = "blue" })
		end
	end
	section(lines, `When on {Items.ARMOR_SLOTS[armor.slot]}:`, body)
end

-- Food effects' kinds (Items/Foods) -> Shared/Effects ids.
local FOOD_EFFECTS: { [string]: number } = { thirst = Effects.id.Thirst }

-- "When eaten:" (Items/Foods).
local function foodLines(lines: { Line }, item: number)
	local food = Foods.of(item)
	if food == nil then
		return
	end
	local body: { Line } = { { text = `Heals {Tooltip.hearts(food.heal)}`, colour = "blue" } }
	local effect = food.effect
	local id = if effect then FOOD_EFFECTS[effect.kind] else nil
	if effect and id then
		effectLines(
			body,
			{ { effect = id, ticks = effect.ticks, amplifier = 0 } },
			`{Tooltip.number(effect.chance * 100)}% chance: `
		)
	end
	section(lines, "When eaten:", body)
end

-- "When drunk:" (ToughAsNails/Drinks; a mana potion's mana is Shared/Mana.tooltip's).
local function drinkLines(lines: { Line }, item: number)
	local drink = Drinks.of(item)
	if drink == nil then
		return
	end
	local body: { Line } = {}
	if drink.thirst > 0 then
		table.insert(body, { text = `Restores {Tooltip.number(drink.thirst)} thirst`, colour = "blue" })
		local hydration = drink.thirst * drink.hydration * 2
		if hydration > 0 then
			table.insert(body, { text = `+{Tooltip.number(hydration)} Hydration`, colour = "blue" })
		end
	end
	if drink.chance > 0 and drink.effectTicks > 0 then
		effectLines(
			body,
			{ { effect = Effects.id.Thirst, ticks = drink.effectTicks, amplifier = 0 } },
			`{Tooltip.number(drink.chance * 100)}% chance: `
		)
	end
	local tempers: { { effect: number, ticks: number, amplifier: number } } = {}
	if (drink.warmth or 0) > 0 then
		table.insert(tempers, { effect = Effects.id.InternalWarmth, ticks = drink.warmth :: number, amplifier = 0 })
	end
	if (drink.chill or 0) > 0 then
		table.insert(tempers, { effect = Effects.id.InternalChill, ticks = drink.chill :: number, amplifier = 0 })
	end
	effectLines(body, tempers)
	if drink.effects then
		effectLines(body, drink.effects)
	end
	section(lines, "When drunk:", body)
end

-- "As fuel:" (Crafting/Smelting, the Heat and Combustion Generators' info).
local function fuelLines(lines: { Line }, item: number)
	local body: { Line } = {}
	local ticks = Smelting.fuel(item)
	if ticks > 0 then
		local smelts = ticks / Smelting.COOK_TIME
		table.insert(body, {
			text = `Burns for {seconds(ticks)}, smelts {Tooltip.number(smelts)} {if smelts == 1
				then "item"
				else "items"}`,
			colour = "gray",
		})
		local heat = Machines.info(Blocks.id.HeatGenerator)
		local perTick = heat.heatGeneration
		if perTick then
			-- (Solid fuel burns in its slot; a Lava Bucket goes into its lava tank, which burns the
			-- same time: Machines/Kinds/Generator.)
			local burns = Items.craftingRemainder(item) == nil or Fluids.ofBucket(item) == Fluids.LAVA
			if burns then
				table.insert(body, { text = `Heat Generator: {Items.formatEnergy(ticks * perTick)}`, colour = "gray" })
			end
		end
	end
	if Fluids.ofBucket(item) == Fluids.FUEL then
		local perMb = Machines.info(Blocks.id.CombustionGenerator).energyPerMb
		if perMb then
			table.insert(body, {
				text = `Combustion Generator: {Items.formatEnergy(Tiers.BUCKET * perMb)}`,
				colour = "gray",
			})
		end
	end
	section(lines, "As fuel:", body)
end

-- Lines of another module (Items/Accessories, Shared/Mana): the first a gray heading after an
-- empty line, the rest blue; a lone line stays gray.
local function moduleLines(lines: { Line }, more: { string })
	if #more == 0 then
		return
	end
	table.insert(lines, { text = "", colour = "white" })
	for index, text in more do
		table.insert(lines, { text = text, colour = if index == 1 then "gray" else "blue" })
	end
end

-- "Durability: 200 / 250" (or "Sips: 2 / 3") of an item that wears, `stack`'s wear when given.
local function wearLine(lines: { Line }, def: Items.ItemDef, stack: Stack?, label: string)
	local durability = def.durability
	if durability == nil then
		return
	end
	local damage = if stack and stack.item == def.id then Items.cleanDamage(stack.damage) or 0 else 0
	table.insert(lines, { text = `{label}: {math.max(0, durability - damage)} / {durability}`, colour = "gray" })
end

--[[ The tooltip ]]

--[[
	The tooltip lines of `item` (see the header), of `stack` when there is one (its data, its
	wear), with `options`. Unknown items give their "?" name only.
]]
function Tooltip.lines(item: number, stack: Stack?, options: Options?): { Line }
	local lines: { Line } = { { text = Items.displayName(item), colour = "white" } }
	local def = Items.get(item)
	if def == nil then
		return lines
	end
	if stack and stack.item == item then
		for _, text in Items.describe(stack) do
			table.insert(lines, { text = text, colour = "gray" })
		end
	end
	local lore = LoreList[def.name]
	if lore then
		table.insert(lines, { text = lore, colour = "lore" })
	end
	if def.tool then
		toolLines(lines, def.tool)
	end
	if def.block and def.id == def.block then
		blockLines(lines, def.block)
	end
	mainHand(lines, def)
	-- Wear right under what the item does with it (Minecraft's advanced tooltip line): a tool's
	-- or weapon's durability, a canteen's sips under its drink.
	local entry = Drinks.entry(item)
	local sips = entry ~= nil and entry.sips == true
	if not sips then
		wearLine(lines, def, stack, "Durability")
	end
	armorLines(lines, def)
	foodLines(lines, item)
	drinkLines(lines, item)
	if sips then
		wearLine(lines, def, stack, "Sips")
	end
	fuelLines(lines, item)
	moduleLines(lines, Accessories.tooltip(item))
	moduleLines(lines, Mana.tooltip(item))
	local gate = if options then options.gate else nil
	if gate then
		local lock = Progression.lockText(gate, item)
		if lock then
			local text = if string.sub(lock, 1, 9) == "Requires "
				then "Crafting requires " .. string.sub(lock, 10)
				else lock
			table.insert(lines, { text = text, colour = "red" })
		end
	end
	return lines
end

-- The lines' texts alone (tests and logs).
function Tooltip.texts(item: number, stack: Stack?, options: Options?): { string }
	local texts = {}
	for _, line in Tooltip.lines(item, stack, options) do
		table.insert(texts, line.text)
	end
	return texts
end

return Tooltip
