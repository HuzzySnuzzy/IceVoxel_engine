--!strict
--[[
	The game rules ServerNet applies to block edits, kept free of Roblox APIs so the tests can run
	them. (Rate limits, reach and the player overlap check stay in ServerNet.)

	  Breaking  any breakable block (hardness >= 0). Creative players break at once. Survival
	            players must have started mining that very block (a Mine message) long enough
	            ago: Mining.mayBreak, the server side of Minecraft's ServerPlayerGameMode check,
	            which allows for network delay.
	  Placing   a placeable block into a replaceable one (air, water, ...), never the same block.
	            Survival placement also needs the item in hand (Players/Inventories.place).
	  Drops     survival breaks drop Items.drops(block); a container's contents drop in both modes
	            (Minecraft's Containers.dropContents runs whatever the game mode).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Items = require(Shared.Items)
local Mining = require(Shared.Mining)

-- The block a survival player started mining, and when (seconds, os.clock()).
export type Mine = { x: number, y: number, z: number, startedAt: number }

local EditRules = {}

local function def(block: number): Blocks.BlockDef?
	return if Blocks.isValid(block) then Blocks.get(block) else nil
end

-- May a player break `block` at (x, y, z) at time `now`, having started mining `mine`?
function EditRules.mayBreak(
	block: number,
	creative: boolean,
	mine: Mine?,
	x: number,
	y: number,
	z: number,
	now: number
): boolean
	local d = def(block)
	if d == nil or not d.breakable or d.hardness < 0 then
		return false
	end
	if creative then
		return true
	end
	if mine == nil or mine.x ~= x or mine.y ~= y or mine.z ~= z then
		return false
	end
	return Mining.mayBreak(block, now - mine.startedAt)
end

-- May `block` be placed where `current` is (ignoring players in the way and the inventory)?
function EditRules.mayPlace(block: number, current: number): boolean
	local d = def(block)
	return d ~= nil and d.placeable and block ~= current and Blocks.isReplaceable(current)
end

-- What breaking `block` drops as an item (nil = nothing; creative players get no drops).
function EditRules.drops(block: number, creative: boolean): Items.Stack?
	if creative then
		return nil
	end
	return Items.drops(block)
end

-- Does `block` hold items (a chest)? Its contents drop when it is broken.
function EditRules.isContainer(block: number): boolean
	local d = def(block)
	return d ~= nil and d.container > 0
end

return EditRules
