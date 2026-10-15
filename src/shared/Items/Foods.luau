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
	game before the food bar):

	  Food              nutrition  saturation  heals  ticks  effect                      Minecraft
	  Steak             8          0.8 (12.8)  4      32     -                           8 / 0.8
	  Cooked Porkchop   8          0.8 (12.8)  4      32     -                           8 / 0.8
	  Cooked Mutton     6          0.8 (9.6)   3      32     -                           6 / 0.8
	  Cooked Chicken    6          0.6 (7.2)   3      32     -                           6 / 0.6
	  Raw Beef          3          0.3 (1.8)   2      32     -                           3 / 0.3
	  Raw Porkchop      3          0.3 (1.8)   2      32     -                           3 / 0.3
	  Raw Mutton        2          0.3 (1.2)   1      32     -                           2 / 0.3
	  Raw Chicken       2          0.3 (1.2)   1      32     30%: Hunger for 30 s        2 / 0.3
	  Rotten Flesh      4          0.1 (0.8)   2      32     80%: Hunger for 30 s        4 / 0.1
	  Canned Beans      6          0.6 (7.2)   6      32     -                           (baked potato)
	  Canned Peaches    4          0.3 (2.4)   4      32     -                           (apple)
	  Crackers          2          0.1 (0.4)   2      24     30%: Thirst for 30 s        (cookie)
	  Chocolate Bar     3          0.3 (1.8)   3      24     Speed for 10 s; any time    (golden apple's rule)
	  Military Ration   8          0.8 (12.8)  8      48     -                           (steak's worth)

	(nutrition in points of the 20, saturation the modifier and in brackets what it adds; heals in
	half hearts, with hunger off.) Minecraft's Hunger effect (Shared/Effects: the food bar drains
	faster; the HUD's FOOD icon shows falling arrows and a Hunger badge) is what raw chicken and
	rotten flesh may bring, as in Minecraft; with hunger off they bring Tough As Nails' Thirst
	effect instead (Shared/ToughAsNails/Thirst: extra exhaustion of the thirst bar, the THIRST
	icon's arrows fall and a Thirst badge shows; nothing at all with thirst off too), as before the
	food bar. Crackers are dry: their risk is the Thirst effect either way.
	Rolled once a food (`effect`, LivingEntity.addEatEffect). Cooking is the furnace's
	(Crafting/Recipes); a mob that dies burning drops its meat cooked (`COOKED`, Minecraft's
	furnace_smelt loot function).

	The medical supplies (the zombie apocalypse, server Apocalypse/Infection and /Survival) are
	used the same way, with their own sound (`sound`: the user's client plays it as the use
	starts, the server to everyone else as it finishes) and no burp (`burp` false). They heal
	health whether hunger is on or not (no nutrition):

	  Item              heals   ticks  cures       effects                  used when
	  Bandage           2       40     Bleeding    -                        hurt or bleeding
	  Medkit            8       80     Bleeding    Regeneration for 10 s    hurt or bleeding
	  Antibiotics       0       32     Infection   Weakness for a minute    infected
	                                               after a cure from stage
	                                               III on (`aftermath`)
	  Herbal Poultice   0       40     -           an infection goes back   infected
	                                               a stage (`setback`)
	  Painkillers       2       24     -           Regeneration for 8 s     hurt

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

	The table is data: a new food is an entry in ITEMS (`heal`, `nutrition` and `saturation`,
	optional `effect = { kind, chance, ticks }` with `kind` "hunger" or "thirst", `useTicks`,
	`cures`, `effects`, `aftermath`, `setback`, `sound`, `burp`), checked as this loads (effects
	and cures must be real effects, sounds real events are the Sounds spec's to check).
]]

local Effects = require(script.Parent.Parent.Effects)
local GameMode = require(script.Parent.Parent.GameMode)
local Hunger = require(script.Parent.Parent.Hunger)
local Infection = require(script.Parent.Parent.Apocalypse.Infection)
local Items = require(script.Parent)

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

local I = Items.id

-- Rotten flesh's and raw chicken's chance of Minecraft's Hunger (FoodProperties' effect, 30 s),
-- and the dry crackers' of Tough As Nails' Thirst.
local FLESH_RISK = table.freeze({ kind = "hunger", chance = 0.8, ticks = 600 }) :: Effect
local CHICKEN_RISK = table.freeze({ kind = "hunger", chance = 0.3, ticks = 600 }) :: Effect
local DRY_RISK = table.freeze({ kind = "thirst", chance = 0.3, ticks = 600 }) :: Effect
local RISKS: { [string]: boolean } = { hunger = true, thirst = true }

-- A status effect a food gives, by its Shared/Effects name.
local function given(name: string, ticks: number, amplifier: number): Given
	local id = Effects.id[name]
	assert(id, `Foods: no effect {name}`)
	return table.freeze({ effect = id, ticks = ticks, amplifier = amplifier })
end

-- Item id -> what eating it does.
Foods.ITEMS = table.freeze({
	[I.CookedBeef] = table.freeze({ heal = 4, nutrition = 8, saturation = 0.8 }),
	[I.CookedPorkchop] = table.freeze({ heal = 4, nutrition = 8, saturation = 0.8 }),
	[I.CookedMutton] = table.freeze({ heal = 3, nutrition = 6, saturation = 0.8 }),
	[I.CookedChicken] = table.freeze({ heal = 3, nutrition = 6, saturation = 0.6 }),
	[I.RawBeef] = table.freeze({ heal = 2, nutrition = 3, saturation = 0.3 }),
	[I.RawPorkchop] = table.freeze({ heal = 2, nutrition = 3, saturation = 0.3 }),
	[I.RawMutton] = table.freeze({ heal = 1, nutrition = 2, saturation = 0.3 }),
	[I.RawChicken] = table.freeze({ heal = 1, nutrition = 2, saturation = 0.3, effect = CHICKEN_RISK }),
	[I.RottenFlesh] = table.freeze({ heal = 2, nutrition = 4, saturation = 0.1, effect = FLESH_RISK }),
	-- The ruins' food (Generation/ScavengeLoot).
	[I.CannedBeans] = table.freeze({ heal = 6, nutrition = 6, saturation = 0.6, useTicks = 32 }),
	[I.CannedPeaches] = table.freeze({ heal = 4, nutrition = 4, saturation = 0.3, useTicks = 32 }),
	[I.Crackers] = table.freeze({ heal = 2, nutrition = 2, saturation = 0.1, useTicks = 24, effect = DRY_RISK }),
	[I.ChocolateBar] = table.freeze({
		heal = 3,
		nutrition = 3,
		saturation = 0.3,
		useTicks = 24,
		effects = table.freeze({ given("Speed", 200, 0) }),
	}),
	[I.MilitaryRation] = table.freeze({ heal = 8, nutrition = 8, saturation = 0.8, useTicks = 48 }),
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
	local nutrition, saturation = food.nutrition, food.saturation
	assert((nutrition == nil) == (saturation == nil), `Food {item} needs both nutrition and saturation`)
	assert(
		nutrition == nil or (nutrition >= 1 and nutrition == math.floor(nutrition) and nutrition <= Hunger.MAX),
		`Food {item} has bad nutrition`
	)
	assert(saturation == nil or saturation >= 0, `Food {item} has a negative saturation`)
	assert(nutrition == nil or food.burp ~= false, `Food {item} is medicine with nutrition`)
	assert(food.effect == nil or RISKS[food.effect.kind], `Food {item} has an unknown risk`)
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
