--!strict
--[[
	Food and medicine (pure; client Interaction/Eating holds it, server Players/Eating uses it): the
	meat mobs drop (Shared/Entities/MobList), the zombie apocalypse's tinned food and its medical
	supplies, used with Minecraft's hold of the use button (Item.getUseDuration: 32 ticks for
	food, a drink's hold as Shared/ToughAsNails/Drinks does it; an item may name its own
	`useTicks`). The game has no hunger bar (Tough As Nails' thirst stands where it would be), so
	a food heals what its hunger would have brought back, about half of Minecraft's nutrition:

	  Food              heals   ticks  effect                           Minecraft (nutrition, effect)
	  Steak             4       32     -                                8
	  Cooked Porkchop   4       32     -                                8
	  Cooked Mutton     3       32     -                                6
	  Cooked Chicken    3       32     -                                6
	  Raw Beef          2       32     -                                3
	  Raw Porkchop      2       32     -                                3
	  Raw Mutton        1       32     -                                2
	  Raw Chicken       1       32     30%: Thirst effect for 30 s      2, 30% Hunger 30 s
	  Rotten Flesh      2       32     80%: Thirst effect for 30 s      4, 80% Hunger 30 s
	  Canned Beans      6       32     -                                (the ruins' tins)
	  Canned Peaches    4       32     -
	  Crackers          2       24     30%: Thirst effect for 30 s      (dry: you want water after)
	  Chocolate Bar     3       24     Speed for 10 s; eaten any time   (golden apple's rule)
	  Military Ration   8       48     -

	(half hearts, of 20). Minecraft's Hunger effect drains the food bar; Tough As Nails' Thirst
	effect (Shared/ToughAsNails/Thirst: extra exhaustion of the thirst bar, the droplets turn
	green) is this game's nearest, so raw chicken, rotten flesh and crackers give that, rolled once
	a food (nothing at all with thirst off). Cooking is the furnace's (Crafting/Recipes); a mob that
	dies burning drops its meat cooked (`COOKED`, Minecraft's furnace_smelt loot function).

	The medical supplies (the zombie apocalypse, server Apocalypse/Infection and /Survival) are
	used the same way, with their own sound (`sound`: the user's client plays it as the use
	starts, the server to everyone else as it finishes) and no burp (`burp` false):

	  Item              heals   ticks  cures       effects                  used when
	  Bandage           2       40     Bleeding    -                        hurt or bleeding
	  Medkit            8       80     Bleeding    Regeneration for 10 s    hurt or bleeding
	  Antibiotics       0       32     Infection   Weakness for a minute    infected
	                                               after a cure from stage
	                                               III on (`aftermath`)
	  Herbal Poultice   0       40     -           an infection goes back   infected
	                                               a stage (`setback`)
	  Painkillers       2       24     -           Regeneration for 8 s     hurt

	Who may use one (`canUse`): never a spectator; anyone whose game mode can't be hurt (creative
	eats whenever, as Minecraft's invulnerable players); else a player who has an effect it cures
	(a bandage on a bleeding player at full health), a player who is hurt and it heals, a player
	with an infection for an item that sets one back, and a food with effects at any time (the
	chocolate bar, as Minecraft's canAlwaysEat). `canEat` is that rule for a plain food (hurt, or
	creative). A food is one item used up (not in creative, Minecraft's instabuild keeps it).

	What finishing one does (`finish`, the server's, through its hooks so the tests run it): it
	heals, cures (Shared/Effects names: an external effect such as the Infection goes to its owner),
	sets an infection back, gives its effects (Shared/Effects ids) and its `aftermath` (an effect
	given after curing an infection that had reached its `stage`, read before the cure through
	`infectionStage`: Antibiotics' Weakness, Shared/Apocalypse/Infection.AFTERMATH_*), then rolls
	its old-style risk (`effect`: the Thirst effect).

	The table is data: a new food is an entry in ITEMS (`heal`, optional `effect = { kind, chance,
	ticks }` with `kind` "thirst", `useTicks`, `cures`, `effects`, `aftermath`, `setback`, `sound`,
	`burp`),
	checked as this loads (effects and cures must be real effects, sounds real events are the
	Sounds spec's to check).
]]

local Effects = require(script.Parent.Parent.Effects)
local GameMode = require(script.Parent.Parent.GameMode)
local Infection = require(script.Parent.Parent.Apocalypse.Infection)
local Items = require(script.Parent)

-- An old-style risk: `kind` "thirst" (Tough As Nails' Thirst effect), its chance and ticks.
export type Effect = { kind: string, chance: number, ticks: number }
-- A status effect a food gives: a Shared/Effects id, its ticks and amplifier (as a drink's).
export type Given = { effect: number, ticks: number, amplifier: number }
-- A status effect given after curing an infection that had reached `stage` (Antibiotics').
export type Aftermath = { effect: number, ticks: number, amplifier: number, stage: number }
export type Food = {
	-- Half hearts it heals at once.
	heal: number,
	-- The old-style risk (see Effect).
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
	-- 0..1: rolls the old-style risk.
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

local I = Items.id

-- Rotten flesh's, raw chicken's and the crackers' chance of Minecraft's Hunger, as TAN's Thirst
-- effect.
local THIRST_RISK = table.freeze({ kind = "thirst", chance = 0.8, ticks = 600 }) :: Effect
local CHICKEN_RISK = table.freeze({ kind = "thirst", chance = 0.3, ticks = 600 }) :: Effect

-- A status effect a food gives, by its Shared/Effects name.
local function given(name: string, ticks: number, amplifier: number): Given
	local id = Effects.id[name]
	assert(id, `Foods: no effect {name}`)
	return table.freeze({ effect = id, ticks = ticks, amplifier = amplifier })
end

-- Item id -> what eating it does.
Foods.ITEMS = table.freeze({
	[I.CookedBeef] = table.freeze({ heal = 4 }),
	[I.CookedPorkchop] = table.freeze({ heal = 4 }),
	[I.CookedMutton] = table.freeze({ heal = 3 }),
	[I.CookedChicken] = table.freeze({ heal = 3 }),
	[I.RawBeef] = table.freeze({ heal = 2 }),
	[I.RawPorkchop] = table.freeze({ heal = 2 }),
	[I.RawMutton] = table.freeze({ heal = 1 }),
	[I.RawChicken] = table.freeze({ heal = 1, effect = CHICKEN_RISK }),
	[I.RottenFlesh] = table.freeze({ heal = 2, effect = THIRST_RISK }),
	-- The ruins' food (Generation/ScavengeLoot).
	[I.CannedBeans] = table.freeze({ heal = 6, useTicks = 32 }),
	[I.CannedPeaches] = table.freeze({ heal = 4, useTicks = 32 }),
	[I.Crackers] = table.freeze({ heal = 2, useTicks = 24, effect = CHICKEN_RISK }),
	[I.ChocolateBar] = table.freeze({
		heal = 3,
		useTicks = 24,
		effects = table.freeze({ given("Speed", 200, 0) }),
	}),
	[I.MilitaryRation] = table.freeze({ heal = 8, useTicks = 48 }),
	-- The medical supplies (see the header).
	[I.Bandage] = table.freeze({
		heal = 2,
		useTicks = 40,
		cures = table.freeze({ "Bleeding" }),
		sound = "item.bandage.apply",
		burp = false,
	}),
	[I.Medkit] = table.freeze({
		heal = 8,
		useTicks = 80,
		cures = table.freeze({ "Bleeding" }),
		effects = table.freeze({ given("Regeneration", 200, 0) }),
		sound = "item.medkit.use",
		burp = false,
	}),
	[I.Antibiotics] = table.freeze({
		heal = 0,
		useTicks = 32,
		cures = table.freeze({ "Infection" }),
		aftermath = table.freeze({
			effect = Effects.id.Weakness,
			ticks = Infection.AFTERMATH_TICKS,
			amplifier = 0,
			stage = Infection.AFTERMATH_STAGE,
		}),
		sound = "item.pills.swallow",
		burp = false,
	}),
	[I.HerbalPoultice] = table.freeze({
		heal = 0,
		useTicks = 40,
		setback = true,
		sound = "item.bandage.apply",
		burp = false,
	}),
	[I.Painkillers] = table.freeze({
		heal = 2,
		useTicks = 24,
		effects = table.freeze({ given("Regeneration", 160, 0) }),
		sound = "item.pills.swallow",
		burp = false,
	}),
} :: { [number]: Food })

-- Raw meat -> its cooked twin (a burning mob's drop; the furnace has the same pairs).
Foods.COOKED = table.freeze({
	[I.RawBeef] = I.CookedBeef,
	[I.RawPorkchop] = I.CookedPorkchop,
	[I.RawMutton] = I.CookedMutton,
	[I.RawChicken] = I.CookedChicken,
} :: { [number]: number })

-- (Mistakes in the table would only show as foods that do nothing: catch them at load.)
for item, food in Foods.ITEMS do
	assert(Items.get(item), `Foods.ITEMS has an unknown item {item}`)
	assert(food.heal >= 0, `Food {item} heals a negative amount`)
	local ticks = food.useTicks
	assert(ticks == nil or (ticks >= 1 and ticks == math.floor(ticks)), `Food {item} has bad useTicks`)
	for _, name in food.cures or NO_NAMES do
		assert(Effects.id[name], `Food {item} cures an unknown effect {name}`)
	end
	local aftermath = food.aftermath
	assert(aftermath == nil or Effects.get(aftermath.effect), `Food {item} has an unknown aftermath`)
	assert(
		aftermath == nil or table.find(food.cures or NO_NAMES, "Infection") ~= nil,
		`Food {item}'s aftermath needs an infection cure`
	)
end

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
	`has(name)` says whether the player has the effect of that Shared/Effects name.
]]
function Foods.canUse(
	food: Food,
	health: number,
	maxHealth: number,
	mode: string,
	has: (name: string) -> boolean
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
	if food.heal > 0 and health < maxHealth then
		return true
	end
	-- (A treat with effects is eaten any time; medicine with effects only for what it treats.)
	return food.effects ~= nil and #food.effects > 0 and not Foods.isMedical(food)
end

-- A plain food (heals, nothing else).
local PLAIN: Food = table.freeze({ heal = 1 })
local function none(_name: string): boolean
	return false
end

--[[
	May a player in game `mode` with `health` of `maxHealth` eat now? Not at full health (unless
	the mode can't be hurt: creative eats whenever), never a spectator (`canUse` of a plain food).
]]
function Foods.canEat(health: number, maxHealth: number, mode: string): boolean
	return Foods.canUse(PLAIN, health, maxHealth, mode, none)
end

--[[
	Eating `food`: the half hearts it heals and the ticks of the old-style effect it gives (0:
	none), `random()` rolling the effect's chance (0..1).
]]
function Foods.eat(food: Food, random: () -> number): (number, number)
	local effect = food.effect
	local ticks = if effect and random() < effect.chance then effect.ticks else 0
	return food.heal, ticks
end

--[[
	Finishes using `food` through `hooks` (see the header): heals, cures, sets an infection back,
	gives its effects and its aftermath, then rolls the old-style risk.
]]
function Foods.finish(food: Food, hooks: Hooks)
	local aftermath = food.aftermath
	-- (The stage the cure ends, read before it.)
	local stage = if aftermath then hooks.infectionStage() else 0
	if food.heal > 0 then
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
	local effect = food.effect
	if ticks > 0 and effect and effect.kind == "thirst" then
		hooks.thirst(ticks)
	end
end

return Foods
