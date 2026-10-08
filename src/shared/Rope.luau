--!strict
--[[
	Using rope on rope, after Supplementaries 1.20.1 (AbstractRopeBlock.use, RopeHelper.addRopeDown
	and removeRopeDown). Pure: the server's Players/ItemUse plays the result out (the edit through
	the world, the held stack, the sound), the client's Interaction/BlockInteraction only asks.

	  column   a rope column is the run of Rope blocks straight down from a rope (same x and z);
	           its `bottom` is the lowest of them. Ropes hang from a sturdy ceiling or the rope
	           above (Blocks.canSurvive's chain rule), so a column always hangs from its top.
	  extend   using Rope, not sneaking, on any rope of a column places one Rope in the cell under
	           its bottom (`extendTarget`), however far down that is: the cell must be loaded,
	           inside the world (y >= 1: the bedrock floor is never reached), replaceable (air,
	           cave air, plants, vines: Blocks.isReplaceable) and hold no fluid (Supplementaries'
	           rope would waterlog; here water keeps its cell). One rope is used up (none in
	           creative), and the place sound plays at x 0.8 pitch where it went
	           (RopeHelper.addRopeDown). A block in the way stops it: Supplementaries pushing it
	           down one is left out. Sneaking with Rope places it against the clicked face as any
	           block item does (the client's normal placement).
	  pull     using an empty hand, not sneaking, on a rope with a rope above or below it (a column
	           of two or more: a lone rope is only broken) removes the column's bottom rope
	           (`pullTarget`) and gives it back (nothing in creative), with the rope's break
	           sound at x 0.6 pitch (removeRopeDown; Supplementaries plays the leash knot there).
	           What hangs under the bottom rope is not pulled up with it (nothing here can).
	Adventure and spectator players do neither: the server's GameModeRules.mayUseItemOn refuses
	them first. Breaking a rope brings the column below down one block a tick (server Behaviours/
	Attached), and the climbing is Movement/PlayerPhysics'.
]]

local Blocks = require(script.Parent.Blocks)
local Items = require(script.Parent.Items)

type Stack = Items.Stack

local Rope = {}

-- The rope block, which is also its item.
Rope.ROPE = Blocks.id.Rope
-- Pitches of the sounds (multiplying the rope's place and break sounds).
Rope.EXTEND_PITCH = 0.8
Rope.PULL_PITCH = 0.6
-- No rope goes below this height (the world's bottom layer).
Rope.MIN_Y = 1

local ROPE = Rope.ROPE

export type GetBlock = (x: number, y: number, z: number) -> number?

-- The world a use acts on: its blocks (nil: not loaded) and a way to change one (false: refused).
export type Env = {
	getBlock: GetBlock,
	setBlock: (x: number, y: number, z: number, block: number) -> boolean,
}

-- What a use did: the hand's stack after it (nil: empty), a stack given back, the cell changed and
-- the sound to play there (an action of the rope's block sound, and its pitch).
export type Result = {
	held: Stack?,
	give: Stack?,
	x: number,
	y: number,
	z: number,
	action: string,
	pitch: number,
}

function Rope.isRope(block: number?): boolean
	return block == ROPE
end

-- The height of the lowest rope of the column going down from rope (x, y, z) (y itself when the
-- cell below holds no rope). (x, y, z) must hold a rope.
function Rope.bottom(getBlock: GetBlock, x: number, y: number, z: number): number
	local by = y
	while by > 0 and getBlock(x, by - 1, z) == ROPE do
		by -= 1
	end
	return by
end

-- Is `block` a cell a rope may be let down into (loaded, replaceable, no fluid)?
local function takesRope(block: number?): boolean
	return block ~= nil and Blocks.isValid(block) and Blocks.isReplaceable(block) and Blocks.get(block).fluid == nil
end

--[[
	Where using Rope on rope (x, y, z) puts the new one: the height of the cell under the column's
	bottom, nil when that cell cannot take it (see the header) or (x, y, z) holds no rope.
]]
function Rope.extendTarget(getBlock: GetBlock, x: number, y: number, z: number): number?
	if getBlock(x, y, z) ~= ROPE then
		return nil
	end
	local target = Rope.bottom(getBlock, x, y, z) - 1
	if target < Rope.MIN_Y or not takesRope(getBlock(x, target, z)) then
		return nil
	end
	return target
end

--[[
	Which rope an empty hand on rope (x, y, z) pulls up: the height of its column's bottom, nil when
	(x, y, z) holds no rope or has none above or below it (a lone rope).
]]
function Rope.pullTarget(getBlock: GetBlock, x: number, y: number, z: number): number?
	if getBlock(x, y, z) ~= ROPE then
		return nil
	end
	local below = getBlock(x, y - 1, z) == ROPE
	if not below and getBlock(x, y + 1, z) ~= ROPE then
		return nil
	end
	return if below then Rope.bottom(getBlock, x, y - 1, z) else y
end

--[[
	A player's use of `held` (nil: an empty hand) on `block` at (x, y, z), sneaking or not,
	`creative` meaning items are never used up nor given (GameMode.instabuild): extends the rope
	(held Rope) or pulls it up (empty hand) through `env`. nil when it does nothing, so the use is
	not a rope's (another item, sneaking, not a rope) or there is no room.
]]
function Rope.use(
	env: Env,
	held: Stack?,
	block: number?,
	x: number,
	y: number,
	z: number,
	sneaking: boolean,
	creative: boolean
): Result?
	if block ~= ROPE or sneaking then
		return nil
	end
	if held and held.item == ROPE and held.count >= 1 then
		local target = Rope.extendTarget(env.getBlock, x, y, z)
		if target == nil or not env.setBlock(x, target, z, ROPE) then
			return nil
		end
		local after = if creative then held else Items.newStack(held.item, held.count - 1, held.damage, held.data)
		return { held = after, give = nil, x = x, y = target, z = z, action = "place", pitch = Rope.EXTEND_PITCH }
	elseif held == nil then
		local target = Rope.pullTarget(env.getBlock, x, y, z)
		if target == nil or not env.setBlock(x, target, z, Blocks.AIR) then
			return nil
		end
		local give = if creative then nil else Items.newStack(ROPE, 1)
		return { held = nil, give = give, x = x, y = target, z = z, action = "break", pitch = Rope.PULL_PITCH }
	end
	return nil
end

--[[
	Does a click on `block` with `held` (nil: empty hand), sneaking or not, belong to the rope (the
	client sends it to the server as a use instead of placing or doing nothing)? Holding Rope on a
	rope, or an empty hand on a rope, when not sneaking.
]]
function Rope.wantsUse(held: number?, block: number?, sneaking: boolean): boolean
	return block == ROPE and not sneaking and (held == nil or held == ROPE)
end

return Rope
