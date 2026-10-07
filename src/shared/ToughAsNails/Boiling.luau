--!strict
--[[
	Boiling dirty water clean on a campfire (Tough As Nails), pure (no Roblox APIs, so the tests
	run it). TAN purifies water in a furnace (Crafting/Recipes' smelting) and, in its 1.12 days,
	by its own campfire; here a right click with dirty water on the Campfire (BlockList, always
	lit) does it at once, one container a click: whatever Drinks names as dirty (`Drinks.isDirty`:
	a Dirty Water Bottle, a Dirty Water Canteen, and any container added to Drinks.PURIFIED_OF
	later) becomes its purified twin (`Drinks.purifiedOf`). The campfire burns no fuel and moves
	with its owner (it drops itself), so the time the water takes is the price: one container
	every INTERVAL ticks (60: 3 s) per player, as Minecraft's campfire cooks free but slowly
	(600 ticks for food, where a furnace burns fuel). Mint stays the quick cure, a stack at a
	time in any crafting grid for a leaf each (Crafting/Recipes), the furnace the unattended one.

	  Who      the campfire's own use (Minecraft's CampfireBlock.use, which places food on it):
	           survival, adventure and creative players, not spectators, and not while sneaking
	           with something in hand (Minecraft's secondary use skips a block's use; `applies`).
	           It comes before drinking: a dirty bottle aimed at a campfire boils, elsewhere it
	           is drunk (client Interaction/BlockInteraction, then Interaction/Drinking).
	  When     `ready`: INTERVAL ticks after the player's last boil, the server allowing LEEWAY
	           (4) ticks short (the client's clock and the network's jitter). The client counts
	           too: a click too soon sends nothing, and held through the wait it boils the next
	           container as soon as the water is ready (BlockInteraction repeats a held use).
	  What     `boil` is ItemUtils.createFilledResult, as filling at water (Drinks.fill): one
	           dirty container is used up and the purified one replaces the stack when it was the
	           last, else goes into the inventory (Players/Inventories.give: thrown when there is
	           no room); a canteen keeps its sips (its wear), so boiling one half drunk gives a
	           half drunk purified one. Creative players keep the dirty one and get a purified one
	           only when they have none.
	  Where    the server (Players/ItemUse, from a UseItem message on the campfire within reach)
	           checks it all again and plays SOUND at the campfire for everyone near; the client
	           predicts nothing (the inventory snapshot brings the result), as every item use on
	           a block.
]]

local Blocks = require(script.Parent.Parent.Blocks)
local GameMode = require(script.Parent.Parent.GameMode)
local Items = require(script.Parent.Parent.Items)
local Drinks = require(script.Parent.Drinks)

type Stack = Items.Stack

local Boiling = {}

-- The block that boils water, and the sound it makes (Sounds/SoundList).
Boiling.CAMPFIRE = Blocks.id.Campfire
Boiling.SOUND = "block.campfire.boil"
-- Ticks between two boils by one player, and the ticks short of them the server allows.
Boiling.INTERVAL = 60
Boiling.LEEWAY = 4

--[[
	Has the water had time to boil `elapsed` seconds after the player's last boil (nil: none yet),
	`leeway` ticks short of INTERVAL allowed (see the header)? `speed`: how many times as fast the
	player boils (default 1; Progression's Firekeeper 2: INTERVAL / 2), the same on the client's
	wait and the server's check.
]]
function Boiling.ready(elapsed: number?, leeway: number?, speed: number?): boolean
	local interval = Boiling.INTERVAL / (if speed and speed > 0 then speed else 1)
	return elapsed == nil or elapsed >= (interval - (leeway or 0)) / 20
end

-- Does `stack` boil clean (dirty water, `Drinks.isDirty`)?
function Boiling.boils(stack: Stack?): boolean
	return stack ~= nil and Drinks.isDirty(stack.item)
end

--[[
	Does a right click on `block` holding `stack`, in game `mode`, sneaking or not, boil it (see
	the header: a campfire, dirty water, not a spectator, not sneaking)?
]]
function Boiling.applies(block: number?, stack: Stack?, mode: string, sneaking: boolean): boolean
	return block == Boiling.CAMPFIRE and Boiling.boils(stack) and not GameMode.isSpectator(mode) and not sneaking
end

--[[
	Boils the held `stack` (see the header): the new held stack (nil: the slot empties) and a
	stack to give besides (nil: none). `hasItem` says whether the player holds an item anywhere
	(creative's rule). A stack that doesn't boil comes back as it was.
]]
function Boiling.boil(stack: Stack, creative: boolean, hasItem: (item: number) -> boolean): (Stack?, Stack?)
	local purified = Drinks.purifiedOf(stack.item)
	if purified == nil then
		return stack, nil
	end
	-- (A canteen's wear is its sips drunk: they stay drunk.)
	local def = Items.get(purified)
	local damage = if def and def.durability then Items.cleanDamage(stack.damage) else nil
	local clean: Stack = { item = purified, count = 1, damage = damage }
	if creative then
		return stack, if hasItem(purified) then nil else clean
	end
	if stack.count <= 1 then
		return clean, nil
	end
	return Items.withCount(stack, stack.count - 1), clean
end

return Boiling
