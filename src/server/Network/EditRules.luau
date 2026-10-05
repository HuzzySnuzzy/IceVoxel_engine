--!strict
--[[
	The game rules ServerNet applies to block edits, kept free of Roblox APIs so the tests can run
	them. (Rate limits, reach and finding the players' hulls stay in ServerNet.)

	  Breaking  any breakable block (hardness >= 0). Creative players break at once. Survival
	            players must have started mining that very block (a Mine message) long enough
	            ago, holding the tool they hold now: Mining.mayBreak, the server side of
	            Minecraft's ServerPlayerGameMode check, which allows for network delay.
	  Placing   a placeable block into a replaceable one (air, water, ...), never the same block.
	            Variants placed by another block's item (wall torches by the Torch, a hanging
	            lantern by the Lantern: BlockList `item`) count as placeable. Blocks that hang on
	            another one (`support`: torches, lanterns) need it to be sturdy (`supported`,
	            Blocks.canSurvive). Nothing is placed where it would overlap a player (`obstructs`:
	            a solid block's cell, a lantern's outline; Minecraft's BlockItem.canPlace), but
	            torches, which have no collision box, may be. Survival placement also needs the
	            item in hand (Players/Inventories.place, which maps a variant to its item with
	            Items.ofBlock).
	  Drops     survival breaks drop Items.drops(block, tool): blocks that need a tool (stone,
	            ores) drop nothing without a good enough one. A container's contents drop in both
	            modes (Minecraft's Containers.dropContents runs whatever the game mode).
	  Wear      a survival break wears the tool in hand (Mining.wear: 1, 2 for swords, nothing on
	            blocks that break at once); creative players never wear their tools.
	  Menus     blocks that open a window (chests, furnaces, crafting tables) close it for everyone
	            using them when they go; only containers (chests, furnaces) hold items to drop.
	  Data      Mekanism's sustained data: a block whose state some part of the server keeps (a
	            Fluid Tank's water) keeps it in its item. `newBlockData` is the registry of those
	            parts' hooks (ServerNet's `addBlockData`): `save` reads a block's data just before a
	            survival break removes it (every part's keys merged), and `dropWithData` puts it on
	            the drop when that is the block's own item; `placed` hands a placement's stack (its
	            data intact) to every hook right after the block is set, so they put the contents
	            back. A hook that errors is reported and skipped.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Items = require(Shared.Items)
local Mining = require(Shared.Mining)

-- The block a survival player started mining, and when (seconds, os.clock()).
export type Mine = { x: number, y: number, z: number, startedAt: number }

--[[
	One part of the server's sustained data (Transmitters for Fluid Tanks; machines later). Both
	are optional, and each answers for its own blocks only.
]]
export type BlockDataHooks = {
	-- The item data `block` at (x, y, z) keeps when a survival player breaks it (read just before
	-- it goes; nil: none of this part's business, or nothing to keep).
	save: ((x: number, y: number, z: number, block: number) -> Items.Data?)?,
	-- `player` placed `block` at (x, y, z) from `stack`: the stack as it was before placing used
	-- one up, data intact (nil when the hand held something else, e.g. creative). Called right
	-- after the block is set (its state is fresh, the default one).
	placed: ((player: any, x: number, y: number, z: number, block: number, stack: Items.Stack?) -> ())?,
}

-- The hooks of every part, in the order they were added (`EditRules.newBlockData`).
export type BlockData = {
	hooks: { BlockDataHooks },
	-- Adds a part's hooks.
	add: (self: BlockData, hooks: BlockDataHooks) -> (),
	-- The data `block` at (x, y, z) keeps: every hook's merged (an earlier hook wins a key both
	-- keep, at most Items.MAX_DATA_KEYS keys), frozen; nil when none keeps anything. A hook that
	-- errors counts as keeping nothing.
	save: (self: BlockData, x: number, y: number, z: number, block: number) -> Items.Data?,
	-- A placement: every hook's `placed`, in order (one that errors does not stop the others).
	placed: (
		self: BlockData,
		player: any,
		x: number,
		y: number,
		z: number,
		block: number,
		stack: Items.Stack?
	) -> (),
}

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

--[[
	Would `block` placed at (x, y, z) overlap a player's hull, the box (minX, minY, minZ) to (maxX,
	maxY, maxZ)? Its Blocks.obstruction counts: a solid block's cell, a lantern's outline, nothing
	for a torch. Boxes that only touch don't overlap.
]]
function EditRules.obstructs(
	block: number,
	x: number,
	y: number,
	z: number,
	minX: number,
	minY: number,
	minZ: number,
	maxX: number,
	maxY: number,
	maxZ: number
): boolean
	local box = Blocks.obstruction(block)
	return box ~= nil
		and maxX > x + box[1]
		and minX < x + box[4]
		and maxY > y + box[2]
		and minY < y + box[5]
		and maxZ > z + box[3]
		and minZ < z + box[6]
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

--[[ Sustained data ]]

local BlockData = {}
BlockData.__index = BlockData

function BlockData.add(self: BlockData, hooks: BlockDataHooks)
	table.insert(self.hooks, hooks)
end

-- A part's hook that errored is reported and skipped: it never stops a break or a placement.
local function failed(err: any)
	warn(`[IceVoxel] a sustained data hook failed: {err}`)
end

function BlockData.save(self: BlockData, x: number, y: number, z: number, block: number): Items.Data?
	local merged: Items.Data? = nil
	local keys = 0
	for _, hooks in self.hooks do
		local save = hooks.save
		local clean: Items.Data? = nil
		if save then
			local ok, data = xpcall(save, failed, x, y, z, block)
			if ok then
				clean = Items.cleanData(data)
			end
		end
		if clean then
			-- Every part adds its keys; a key two parts both keep stays the earlier one's.
			local into: Items.Data = merged or {}
			for key, value in next, clean do
				if into[key] == nil and keys < Items.MAX_DATA_KEYS then
					into[key] = value
					keys += 1
				end
			end
			merged = into
		end
	end
	return Items.cleanData(merged)
end

function BlockData.placed(
	self: BlockData,
	player: any,
	x: number,
	y: number,
	z: number,
	block: number,
	stack: Items.Stack?
)
	for _, hooks in self.hooks do
		local placed = hooks.placed
		if placed then
			xpcall(placed, failed, player, x, y, z, block, stack)
		end
	end
end

-- An empty registry of sustained data hooks.
function EditRules.newBlockData(): BlockData
	return (setmetatable({ hooks = {} }, BlockData) :: any) :: BlockData
end

--[[
	What a break of `block` at (x, y, z) drops (`drops`: nothing in creative or without the right
	tool), carrying the data the block keeps (`blockData:save`) when it drops its own item. Call it
	while the block is still there: its keepers forget it once it goes. (ServerNet's breaks.)
]]
function EditRules.breakDrop(
	blockData: BlockData,
	x: number,
	y: number,
	z: number,
	block: number,
	creative: boolean,
	tool: number?
): Items.Stack?
	local drop = EditRules.drops(block, creative, tool)
	if drop == nil or drop.item ~= Items.ofBlock(block) then
		return drop
	end
	return EditRules.dropWithData(drop, block, blockData:save(x, y, z, block))
end

--[[
	A broken block's drop with the data the block kept (`BlockData.save`): on its own item only
	(Items.ofBlock), as Mekanism's sustained data; a block dropping something else (an ore its raw
	ore) drops that plain. nil stays nil.
]]
function EditRules.dropWithData(drop: Items.Stack?, block: number, data: Items.Data?): Items.Stack?
	if drop == nil or data == nil or drop.item ~= Items.ofBlock(block) then
		return drop
	end
	return Items.withData(drop, data)
end

return EditRules
