--!strict
--[[
	The game rules ServerNet applies to block edits, kept free of Roblox APIs so the tests can run
	them. (Rate limits, reach and the player overlap check stay in ServerNet.)

	  Breaking  any breakable block (hardness >= 0). Creative players break at once. Survival
	            players must have started mining that very block (a Mine message) long enough
	            ago, holding the tool they hold now: Mining.mayBreak, the server side of
	            Minecraft's ServerPlayerGameMode check, which allows for network delay.
	  Placing   a placeable block into a replaceable one (air, water, ...), never the same block.
	            Variants placed by another block's item (wall torches by the Torch, a hanging
	            lantern by the Lantern: BlockList `item`) count as placeable. Blocks that hang on
	            another one (`support`: torches, lanterns) need it to be sturdy (`supported`,
	            Blocks.canSurvive). Survival placement also needs the item in hand
	            (Players/Inventories.place, which maps a variant to its item with Items.ofBlock).
	  Drops     survival breaks drop Items.drops(block, tool): blocks that need a tool (stone,
	            ores) drop nothing without a good enough one. A container's contents drop in both
	            modes (Minecraft's Containers.dropContents runs whatever the game mode).
	  Wear      a survival break wears the tool in hand (Mining.wear: 1, 2 for swords, nothing on
	            blocks that break at once); creative players never wear their tools.
	  Menus     blocks that open a window (chests, furnaces, crafting tables) close it for everyone
	            using them when they go; only containers (chests, furnaces) hold items to drop.
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

--[[
	May a player break `block` at (x, y, z) at time `now`, having started mining `mine`, holding
	`tool` (an item id, nil = bare hands) now?
]]
function EditRules.mayBreak(
	block: number,
	creative: boolean,
	mine: Mine?,
	x: number,
	y: number,
	z: number,
	now: number,
	tool: number?
): boolean
	local d = def(block)
	if d == nil or not d.breakable or d.hardness < 0 then
		return false
	end
	if creative then
		-- Minecraft's SwordItem.canAttackBlock: creative players can't break blocks with a sword.
		local held = Items.tool(tool)
		return held == nil or held.kind ~= "sword"
	end
	if mine == nil or mine.x ~= x or mine.y ~= y or mine.z ~= z then
		return false
	end
	return Mining.mayBreak(block, now - mine.startedAt, nil, tool)
end

--[[
	May `block` be placed where `current` is (ignoring what it hangs on, players in the way and the
	inventory)? Placeable blocks and the variants their items place.
]]
function EditRules.mayPlace(block: number, current: number): boolean
	local d = def(block)
	if d == nil or block == current or not Blocks.isReplaceable(current) then
		return false
	end
	return d.placeable or (d.item ~= nil and Items.ofBlock(block) ~= nil)
end

--[[
	Is what `block` hangs on there, were it at (x, y, z)? Blocks without a `support` always are.
	`getBlock` answers nil for blocks that are not loaded, which hold nothing up.
]]
function EditRules.supported(
	block: number,
	getBlock: (x: number, y: number, z: number) -> number?,
	x: number,
	y: number,
	z: number
): boolean
	return def(block) ~= nil and Blocks.canSurvive(block, getBlock, x, y, z)
end

-- What breaking `block` with `tool` drops as an item (nil = nothing; creative players get none).
function EditRules.drops(block: number, creative: boolean, tool: number?): Items.Stack?
	if creative then
		return nil
	end
	return Items.drops(block, tool)
end

-- Wear the held `tool` takes from breaking `block` (0: creative, not a tool, or an instant block).
function EditRules.wear(block: number, creative: boolean, tool: number?): number
	if creative or def(block) == nil then
		return 0
	end
	return Mining.wear(block, tool)
end

-- Does `block` open a window when used (a chest, furnace or crafting table)? When it goes, the
-- window closes for everyone who has it open.
function EditRules.hasMenu(block: number): boolean
	local d = def(block)
	return d ~= nil and d.menu ~= nil
end

-- Does `block` hold items (a chest or a furnace)? Its contents drop when it is broken.
function EditRules.isContainer(block: number): boolean
	local d = def(block)
	return d ~= nil and d.container > 0
end

return EditRules
