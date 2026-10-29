--!strict
--[[
	Food and medicine (pure; client Interaction/Eating holds it, server Players/Eating uses it): the
	meat mobs drop (Shared/Entities/MobList), the zombie apocalypse's tinned food and its medical
	supplies, used with Minecraft's hold of the use button (Item.getUseDuration: 32 ticks for
	food, a drink's hold as Shared/ToughAsNails/Drinks does it; an item may name its own
	`useTicks`). With Minecraft's hunger on (Config.Hunger, Shared/Hunger) a food fills the food bar
	with Minecraft's nutrition and saturation modifier (FoodProperties: FoodData.eat adds the
	nutrition to the food bar and nutrition x modifier x 2 to its saturation); with hunger off it
	heals at once what its hunger would have brought back (`heal`, about half the nutrition: the
	game before the food bar). Each item says what it does on its content pack entry, its `food`
	(Content/Schema; Minecraft 1.20.5 made food a component of the item the same way): the
	Minecraft pack's meat (items/mobs: Minecraft's numbers) and the Apocalypse pack's tins and
	medical supplies (items/supplies), each file's header with a table of them. `nutrition` is in
	points of the 20 and `saturation` the modifier (FoodData.eat adds nutrition x modifier x 2);
	`heal` is in half hearts, with hunger off.

	Minecraft's Hunger effect (Shared/Effects: the food bar drains faster; the HUD's FOOD icon
	shows falling arrows and a Hunger badge) is what raw chicken and rotten flesh may bring, as in
	Minecraft; with hunger off they bring Tough As Nails' Thirst effect instead
	(Shared/ToughAsNails/Thirst: extra exhaustion of the thirst bar, the THIRST icon's arrows fall
	and a Thirst badge shows; nothing at all with thirst off too), as before the food bar. Crackers
	are dry: their risk is the Thirst effect either way. Rolled once a food (`effect`,
	LivingEntity.addEatEffect). Cooking is the furnace's (Crafting/Recipes); a mob that dies
	burning drops its meat cooked (`COOKED`, Minecraft's furnace_smelt loot function: what the
	furnace makes of it).

	The medical supplies (the zombie apocalypse, server Apocalypse/Infection and /Survival) are
	used the same way, with their own sound (`sound`: the user's client plays it as the use
	starts, the server to everyone else as it finishes) and no burp (`burp` false). They heal
	health whether hunger is on or not (no nutrition), and may cure effects (`cures`), give some
	(`effects`), give one after curing an infection that had reached a stage (`aftermath`:
	Antibiotics' Weakness) or set an infection back a stage (`setback`: the Herbal Poultice).

	Who may use one (`canUse`, with the player's food level `foodLevel` while hunger is on, nil
	while it is off): never a spectator; anyone whose game mode can't be hurt (creative eats
	whenever, as Minecraft's invulnerable players); else a player who has an effect it cures (a
	bandage on a bleeding player at full health), a player with an infection for an item that sets
	one back, a food with nutrition while the food bar isn't full (Player.canEat: food below 20,
	whatever the health), with hunger off a player who is hurt and it heals (medicine always goes
	by that), and a food with effects at any time (the chocolate bar, as Minecraft's
	canAlwaysEat). `canEat` is that rule for a plain food. A food is one item used up (not in
	creative, Minecraft's instabuild keeps it).

	What finishing one does (`finish`, the server's, through its hooks so the tests run it): it
	feeds (`feed`, given while hunger is on: Hunger.eat) a food with nutrition, else heals; cures
	(Shared/Effects names: an external effect such as the Infection goes to its owner), sets an
	infection back, gives its effects (Shared/Effects ids) and its `aftermath` (an effect given
	after curing an infection that had reached its `stage`, read before the cure through
	`infectionStage`: Antibiotics' Weakness, Shared/Apocalypse/Infection.AFTERMATH_*), then rolls
	its risk (`effect`: Minecraft's Hunger with hunger on, else the Thirst effect, for kind
	"hunger"; the Thirst effect for kind "thirst").

	ITEMS (item id -> Food) is made from the entries' `food` as this loads, their effects' and
	aftermaths' names turned into Shared/Effects ids, and checked, each message naming the pack and
	the entry (a mistake would only show as a food that does nothing): an unknown effect or cure,
	a negative heal, nutrition without saturation or out of 1..20, bad `useTicks`, medicine with
	nutrition, an aftermath without an Infection cure, and a food that does nothing at all. A new
	food is a `food` on its item's entry: `food = { heal = 4, nutrition = 8, saturation = 0.8 }`,
	with optional `effect = { kind, chance, ticks }` (kind "hunger" or "thirst"), `useTicks`,
	`cures` (effect names), `effects` ({ effect = name, ticks, amplifier? }), `aftermath` ({
	effect = name, ticks, amplifier?, stage }), `setback`, `sound` and `burp` (`sound` is any of the
	packs' sound events: Shared/Content checks its name as the packs load, naming the pack, and the
	client plays it as it is).
]]

local Content = require(script.Parent.Parent.Content)
local Smelting = require(script.Parent.Parent.Crafting.Smelting)
local Effects = require(script.Parent.Parent.Effects)
local GameMode = require(script.Parent.Parent.GameMode)
local Hunger = require(script.Parent.Parent.Hunger)
local Items = require(script.Parent)
local Schema = require(script.Parent.Parent.Content.Schema)

-- A risk rolled once a food: `kind` "hunger" (Minecraft's Hunger effect; Tough As Nails' Thirst
-- effect with hunger off) or "thirst" (the Thirst effect), its chance and ticks.
export type Effect = { kind: string, chance: number, ticks: number }
-- A status effect a food gives: a Shared/Effects id, its ticks and amplifier (as a drink's).
export type Given = { effect: number, ticks: number, amplifier: number }
-- A status effect given after curing an infection that had reached `stage` (Antibiotics').
export type Aftermath = { effect: number, ticks: number, amplifier: number, stage: number }
export type Food = {
	-- Half hearts it heals at once (a food with nutrition: only with hunger off).
	heal: number,
	-- Minecraft's FoodProperties: food points it gives and its saturation modifier (nil: none,
	-- medicine).
	nutrition: number?,
	saturation: number?,
	-- The risk rolled after eating (see Effect).
	effect: Effect?,
	-- Ticks of holding the use button (nil: USE_TICKS).
	useTicks: number?,
	-- Shared/Effects names of the effects it takes away ("Bleeding", "Infection").
	cures: { string }?,
	-- Status effects it gives.
	effects: { Given }?,
	-- A status effect it gives after curing a late infection (see Aftermath).
	aftermath: Aftermath?,
	-- Sets an infection back a stage (the Herbal Poultice).
	setback: boolean?,
	-- The sound of using it (nil: the bites and the burp).
	sound: string?,
	-- false: no burp at the end (medicine).
	burp: boolean?,
}

-- What finishing a food does to the player (server Players/Eating, or the tests' fakes).
export type Hooks = {
	-- Heal `halfHearts`.
	heal: (halfHearts: number) -> (),
	-- With hunger on: fill the food bar (Hunger.eat). nil: hunger is off, foods heal instead.
	feed: ((nutrition: number, saturationModifier: number) -> ())?,
	-- Take effect `name` away (Shared/Effects' name).
	cure: (name: string) -> (),
	-- Set the player's infection back a stage.
	setBack: () -> (),
	-- The player's infection stage (0: healthy; Shared/Apocalypse/Infection.stage).
	infectionStage: () -> number,
	-- Give a status effect.
	give: (effect: number, ticks: number, amplifier: number) -> (),
	-- Give Tough As Nails' Thirst effect for `ticks`.
	thirst: (ticks: number) -> (),
	-- 0..1: rolls the risk.
	random: () -> number,
}

local Foods = {}

-- (Empty lists for foods without cures or effects.)
local NO_NAMES: { string } = table.freeze({})
local NO_EFFECTS: { Given } = table.freeze({})

-- Minecraft's eating time (ticks the use button is held), and its sounds: a bite every 4 ticks
-- from the 7th (LivingEntity.triggerItemUseEffects), a burp at the end.
Foods.USE_TICKS = 32
Foods.EAT = "entity.generic.eat"
Foods.BURP = "entity.player.burp"

-- The kinds of risk (`riskEffect` says which effect each brings).
local RISKS: { [string]: boolean } = { hunger = true, thirst = true }

-- The effect named `name` (Shared/Effects), or a load error naming `where`'s entry.
local function effectId(name: string, where: string): number
	local id = Effects.id[name]
	assert(id, `Foods: {where} gives an unknown effect {name}`)
	return id
end

-- `where`'s `food` (an entry's, Content/Schema) as a Food: effect names become ids, lists frozen.
local function fromEntry(spec: Schema.FoodSpec, where: string): Food
	local food: Food = {
		heal = spec.heal,
		nutrition = spec.nutrition,
		saturation = spec.saturation,
		useTicks = spec.useTicks,
		setback = spec.setback,
		sound = spec.sound,
		burp = spec.burp,
	}
	local risk = spec.effect
	if risk then
		food.effect = table.freeze({ kind = risk.kind, chance = risk.chance, ticks = risk.ticks })
	end
	if spec.cures then
		for _, name in spec.cures do
			assert(Effects.id[name], `Foods: {where} cures an unknown effect {name}`)
		end
		food.cures = table.freeze(table.clone(spec.cures))
	end
	if spec.effects then
		local effects: { Given } = {}
		for _, given in spec.effects do
			table.insert(
				effects,
				table.freeze({
					effect = effectId(given.effect, where),
					ticks = given.ticks,
					amplifier = given.amplifier or 0,
				})
			)
		end
		food.effects = table.freeze(effects)
	end
	local aftermath = spec.aftermath
	if aftermath then
		food.aftermath = table.freeze({
			effect = effectId(aftermath.effect, where),
			ticks = aftermath.ticks,
			amplifier = aftermath.amplifier or 0,
			stage = aftermath.stage,
		})
	end
	return table.freeze(food)
end

-- (Mistakes would only show as foods that do nothing: catch them at load.)
local function check(food: Food, where: string)
	assert(food.heal >= 0, `Foods: {where} heals a negative amount`)
	local nutrition, saturation = food.nutrition, food.saturation
	assert((nutrition == nil) == (saturation == nil), `Foods: {where} needs both nutrition and saturation`)
	assert(
		nutrition == nil or (nutrition >= 1 and nutrition == math.floor(nutrition) and nutrition <= Hunger.MAX),
		`Foods: {where} has bad nutrition`
	)
	assert(saturation == nil or saturation >= 0, `Foods: {where} has a negative saturation`)
	assert(nutrition == nil or food.burp ~= false, `Foods: {where} is medicine with nutrition`)
	assert(food.effect == nil or RISKS[food.effect.kind], `Foods: {where} has an unknown risk`)
	local ticks = food.useTicks
	assert(ticks == nil or (ticks >= 1 and ticks == math.floor(ticks)), `Foods: {where} has bad useTicks`)
	local aftermath = food.aftermath
	assert(
		aftermath == nil or table.find(food.cures or NO_NAMES, "Infection") ~= nil,
		`Foods: {where}'s aftermath needs an infection cure`
	)
	assert(
		nutrition ~= nil
			or food.heal > 0
			or #(food.cures or NO_NAMES) > 0
			or #(food.effects or NO_EFFECTS) > 0
			or food.setback == true,
		`Foods: {where} does nothing (no nutrition, heal, cures, effects or setback)`
	)
end

-- Item id -> what eating it does: every content pack item's `food`.
local content = Content.default
local ITEMS: { [number]: Food } = {}
for _, spec in content.items do
	if spec.food then
		local where = content.where("item", spec.name)
		local food = fromEntry(spec.food, where)
		check(food, where)
		ITEMS[Items.id[spec.name]] = food
	end
end
Foods.ITEMS = table.freeze(ITEMS)

--[[
	Raw meat -> its cooked twin (a burning mob's drop): every food a furnace makes into another
	food (Crafting/Smelting: the packs' smelting recipes, Minecraft's furnace_smelt), so a new raw
	food and its smelting recipe are all a pack writes.
]]
local COOKED: { [number]: number } = {}
for raw in ITEMS do
	local smelted = Smelting.result(raw)
	if smelted and ITEMS[smelted.item] then
		COOKED[raw] = smelted.item
	end
end
Foods.COOKED = table.freeze(COOKED)

-- What eating `item` does (nil: not food).
function Foods.of(item: number?): Food?
	return if item then Foods.ITEMS[item] else nil
end

function Foods.isFood(item: number?): boolean
	return Foods.of(item) ~= nil
end

-- Ticks of holding the use button to eat `food`.
function Foods.useTicks(food: Food): number
	return food.useTicks or Foods.USE_TICKS
end

-- Is `food` medicine (no burp: the bites and the burp give way to its own sound)?
function Foods.isMedical(food: Food): boolean
	return food.burp == false
end

-- Does `food` fill the food bar (nutrition) rather than heal, with hunger on?
function Foods.nourishes(food: Food): boolean
	return (food.nutrition or 0) > 0
end

-- The effect `food`'s risk gives now (its Shared/Effects id; nil: none): Minecraft's Hunger for
-- kind "hunger" while `hunger` is on (Config.Hunger), else Tough As Nails' Thirst.
function Foods.riskEffect(food: Food, hunger: boolean): number?
	local effect = food.effect
	if effect == nil then
		return nil
	end
	if effect.kind == "hunger" and hunger then
		return Effects.id.Hunger
	end
	return Effects.id.Thirst
end

-- Does `food` cure the effect `name`?
function Foods.cures(food: Food, name: string): boolean
	for _, cured in food.cures or NO_NAMES do
		if cured == name then
			return true
		end
	end
	return false
end

--[[
	May a player in game `mode` with `health` of `maxHealth` use `food` now (see the header)?
	`has(name)` says whether the player has the effect of that Shared/Effects name; `foodLevel` is
	their food bar while hunger is on (nil: hunger off).
]]
function Foods.canUse(
	food: Food,
	health: number,
	maxHealth: number,
	mode: string,
	has: (name: string) -> boolean,
	foodLevel: number?
): boolean
	if GameMode.isSpectator(mode) then
		return false
	end
	if GameMode.invulnerable(mode) then
		return true
	end
	for _, name in food.cures or NO_NAMES do
		if has(name) then
			return true
		end
	end
	if food.setback and has("Infection") then
		return true
	end
	if foodLevel ~= nil and Foods.nourishes(food) then
		-- (Player.canEat: the food bar, not the health.)
		if Hunger.canEat(foodLevel, mode) then
			return true
		end
	elseif food.heal > 0 and health < maxHealth then
		return true
	end
	-- (A treat with effects is eaten any time; medicine with effects only for what it treats.)
	return food.effects ~= nil and #food.effects > 0 and not Foods.isMedical(food)
end

-- A plain food (feeds or heals, nothing else).
local PLAIN: Food = table.freeze({ heal = 1, nutrition = 1, saturation = 0 })
local function none(_name: string): boolean
	return false
end

--[[
	May a player in game `mode` with `health` of `maxHealth` (and `foodLevel` while hunger is on)
	eat now? With hunger on, not with a full food bar; with it off, not at full health; creative
	eats whenever, a spectator never (`canUse` of a plain food).
]]
function Foods.canEat(health: number, maxHealth: number, mode: string, foodLevel: number?): boolean
	return Foods.canUse(PLAIN, health, maxHealth, mode, none, foodLevel)
end

--[[
	Eating `food`: the half hearts it heals (with hunger off) and the ticks of its risk's effect
	(0: none), `random()` rolling the effect's chance (0..1).
]]
function Foods.eat(food: Food, random: () -> number): (number, number)
	local effect = food.effect
	local ticks = if effect and random() < effect.chance then effect.ticks else 0
	return food.heal, ticks
end

--[[
	Finishes using `food` through `hooks` (see the header): heals, cures, sets an infection back,
	gives its effects and its aftermath, then rolls its risk.
]]
function Foods.finish(food: Food, hooks: Hooks)
	local aftermath = food.aftermath
	-- (The stage the cure ends, read before it.)
	local stage = if aftermath then hooks.infectionStage() else 0
	local feed = hooks.feed
	if feed and Foods.nourishes(food) then
		feed(food.nutrition or 0, food.saturation or 0)
	elseif food.heal > 0 then
		hooks.heal(food.heal)
	end
	for _, name in food.cures or NO_NAMES do
		hooks.cure(name)
	end
	if food.setback then
		hooks.setBack()
	end
	for _, effect in food.effects or NO_EFFECTS do
		hooks.give(effect.effect, effect.ticks, effect.amplifier)
	end
	if aftermath and stage >= aftermath.stage then
		hooks.give(aftermath.effect, aftermath.ticks, aftermath.amplifier)
	end
	local _, ticks = Foods.eat(food, hooks.random)
	local risk = Foods.riskEffect(food, feed ~= nil)
	if ticks > 0 and risk ~= nil and risk == Effects.id.Hunger then
		hooks.give(risk, ticks, 0)
	elseif ticks > 0 and risk == Effects.id.Thirst then
		hooks.thirst(ticks)
	end
end

return Foods
