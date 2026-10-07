--!strict
--[[
	Food (pure; client Interaction/Eating holds it, server Players/Eating eats it): the meat mobs
	drop (Shared/Entities/MobList), eaten with Minecraft's 32 tick hold (Item.getUseDuration of
	food, the use button held down as for a drink, Shared/ToughAsNails/Drinks) for health at once.
	The game has no hunger bar (Tough As Nails' thirst stands where it would be), so a food heals
	what its hunger would have brought back, about half of Minecraft's nutrition:

	  Food              heals   effect                           Minecraft (nutrition, effect)
	  Steak             4       -                                8
	  Cooked Porkchop   4       -                                8
	  Cooked Mutton     3       -                                6
	  Cooked Chicken    3       -                                6
	  Raw Beef          2       -                                3
	  Raw Porkchop      2       -                                3
	  Raw Mutton        1       -                                2
	  Raw Chicken       1       30%: Thirst effect for 30 s      2, 30% Hunger 30 s
	  Rotten Flesh      2       80%: Thirst effect for 30 s      4, 80% Hunger 30 s

	(half hearts, of 20). Minecraft's Hunger effect drains the food bar; Tough As Nails' Thirst
	effect (Shared/ToughAsNails/Thirst: extra exhaustion of the thirst bar, the droplets turn
	green) is this game's nearest, so raw chicken and rotten flesh give that, rolled once a food
	(nothing at all with thirst off). Cooking is the furnace's (Crafting/Recipes); a mob that dies
	burning drops its meat cooked (`COOKED`, Minecraft's furnace_smelt loot function).

	Who may eat (`canEat`): a living player who is not at full health, or one whose game mode
	can't be hurt (creative eats whenever, as Minecraft's invulnerable players); never a
	spectator. A food is one item used up (not in creative, Minecraft's instabuild keeps it).

	The table is data: a new food is an entry in ITEMS (`heal`, optional `effect = { kind,
	chance, ticks }`; `kind` "thirst" is the one effect so far), so a status effect system can
	turn `heal` into Regeneration or add effects without touching the eating code.
]]

local GameMode = require(script.Parent.Parent.GameMode)
local Items = require(script.Parent)

export type Effect = { kind: string, chance: number, ticks: number }
export type Food = { heal: number, effect: Effect? }

local Foods = {}

-- Minecraft's eating time (ticks the use button is held), and its sounds: a bite every 4 ticks
-- from the 7th (LivingEntity.triggerItemUseEffects), a burp at the end.
Foods.USE_TICKS = 32
Foods.EAT = "entity.generic.eat"
Foods.BURP = "entity.player.burp"

local I = Items.id

-- Rotten flesh's and raw chicken's chance of Minecraft's Hunger, as TAN's Thirst effect.
local THIRST_RISK = table.freeze({ kind = "thirst", chance = 0.8, ticks = 600 }) :: Effect
local CHICKEN_RISK = table.freeze({ kind = "thirst", chance = 0.3, ticks = 600 }) :: Effect

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
} :: { [number]: Food })

-- Raw meat -> its cooked twin (a burning mob's drop; the furnace has the same pairs).
Foods.COOKED = table.freeze({
	[I.RawBeef] = I.CookedBeef,
	[I.RawPorkchop] = I.CookedPorkchop,
	[I.RawMutton] = I.CookedMutton,
	[I.RawChicken] = I.CookedChicken,
} :: { [number]: number })

-- What eating `item` does (nil: not food).
function Foods.of(item: number?): Food?
	return if item then Foods.ITEMS[item] else nil
end

function Foods.isFood(item: number?): boolean
	return Foods.of(item) ~= nil
end

--[[
	May a player in game `mode` with `health` of `maxHealth` eat now? Not at full health (unless
	the mode can't be hurt: creative eats whenever), never a spectator.
]]
function Foods.canEat(health: number, maxHealth: number, mode: string): boolean
	if GameMode.isSpectator(mode) then
		return false
	end
	return GameMode.invulnerable(mode) or health < maxHealth
end

--[[
	Eating `food`: the half hearts it heals and the ticks of the effect it gives (0: none),
	`random()` rolling the effect's chance (0..1).
]]
function Foods.eat(food: Food, random: () -> number): (number, number)
	local effect = food.effect
	local ticks = if effect and random() < effect.chance then effect.ticks else 0
	return food.heal, ticks
end

return Foods
