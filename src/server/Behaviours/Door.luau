--!strict
--[[
	Doors (BlockList's doors, Minecraft's DoorBlock.updateShape and canSurvive), kept up as tall
	plants are (Behaviours/Plant: Blocks pairs a door's halves like a tall plant's): when a
	neighbour changes, next tick a lower half needs a sturdy block under it and its own upper half
	above, an upper half its own lower half below. If not, the half breaks: air, its break sound,
	and its drop (the lower half's door; an upper half drops nothing), so a door pops once.

	Opening a door changes both halves within one step (Players/DoorUse), and the check waits for
	the next tick, so a door being opened never sees a half that does not match. A player breaking
	either half removes both at once with a single drop (Network/EditRules).
]]

local Plant = require(script.Parent.Plant)

local Door = {}

Door.tickDelay = 1

function Door.onTick(world: any, ticker: any, x: number, y: number, z: number, block: number)
	Plant.onTick(world, ticker, x, y, z, block)
end

return Door
