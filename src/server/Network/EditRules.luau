--!strict
--[[
	The game rules ServerNet applies to block edits, kept free of Roblox APIs so the tests can run
	them. (Rate limits, reach and finding the players' hulls stay in ServerNet.)

	  Modes     who may edit at all goes by the game mode's abilities (Shared/GameMode): survival
	            and creative players break and place (`mayEdit`: Abilities.mayBuild), adventure and
	            spectator players never do (Minecraft's Player.blockActionRestricted, and
	            ItemStack.useOn for placing), and only survival mines over time (`minesOverTime`:
	            Mine messages from anyone else are ignored). Spectators never stand in the way of a
	            placement (`blocksPlacing`). Every `creative` parameter below is the instabuild
	            ability (GameMode.instabuild: creative mode).
	  Breaking  any breakable block (hardness >= 0). Creative players break at once. Survival
	            players must have started mining that very block (a Mine message) long enough
	            ago, holding the tool they hold now: Mining.mayBreak, the server side of
	            Minecraft's ServerPlayerGameMode check, which allows for network delay.
	  Operator  creative only blocks (structure blocks, structure voids, jigsaws: Minecraft's
	            GameMasterBlock) are placed and broken only by players allowed to use them
	            (`mayUseCreativeOnly`, Structures/Permission: creative, and
	            Config.Structures.Permission, Config.Gameplay.Admins, the owner or Studio);
	            survival players can't mine them at all (Mining) and they never drop (Items).
	  Placing   a placeable block into a replaceable one (air, water, short grass, ...), never
	            the same block; what it replaces goes without a drop (Minecraft). Variants placed
	            by another block's item (wall torches by the Torch, a hanging lantern by the
	            Lantern: BlockList `item`) count as placeable, but a tall plant's upper half never
	            does: the server sets it itself (`setPlaced`), and neither does a cave twin
	            (generation's CaveGlowLichen*). Blocks that hang on another one
	            (`support`: torches, lanterns) need it to be sturdy, plants their soil, and a tall
	            plant room for its top (`supported`, Blocks.canPlace). Nothing is placed where it
	            would overlap a player (`obstructs`: a solid block's cell, a lantern's outline;
	            Minecraft's BlockItem.canPlace), but torches and plants, which have no collision
	            box, may be. Survival placement also needs the item in hand
	            (Players/Inventories.place, which maps a variant to its item with Items.ofBlock).
	  Plants    a tall plant is two blocks (Minecraft's DoublePlantBlock): placing its lower half
	            also sets its upper half right above (`setPlaced`), and a player breaking either
	            half removes both (`removeBroken`) with one drop, what the lower half gives the
	            player's tool (`harvested`: 2 short grass from tall grass with Shears, the flower
	            of a tall flower), and one sound and one wear (playerWillDestroy and the loot
	            tables' half = lower).
	  Drops     survival breaks drop Items.drops(block, tool): blocks that need a tool (stone,
	            ores) drop nothing without a good enough one, Shears harvest what a block's
	            `shearDrops` names. A container's contents drop in both modes (Minecraft's
	            Containers.dropContents runs whatever the game mode).
	  Wear      a survival break wears the tool in hand (Mining.wear: 1, 2 for swords, nothing on
	            blocks that break at once, but Shears 1 on every block); creative players never
	            wear their tools.
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
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Machines = require(Shared.Machines)
local Mining = require(Shared.Mining)

local WorldServer = require(script.Parent.Parent.World.WorldServer)

type World = WorldServer.World

-- The block a survival player started mining, and when (seconds, os.clock()).
export type Mine = { x: number, y: number, z: number, startedAt: number }

--[[
	One part of the server's sustained data (Transmitters for Fluid Tanks, Machines for energy).
	Both are optional, and each answers for its own blocks only.
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

--[[ Game modes ]]

--[[
	May a player in game mode `mode` break or place blocks at all? Survival and creative players may
	(Abilities.mayBuild). Adventure players may not (Player.blockActionRestricted refuses breaking,
	ItemStack.useOn placing), nor may spectators: ServerNet answers their edits with the real block.
]]
function EditRules.mayEdit(mode: string): boolean
	return GameMode.mayBuild(mode)
end

--[[
	Does a player in `mode` mine blocks over time (a Mine message starts the timer, and a break must
	wait for it: `mayBreak`)? Survival only: creative players break at once (instabuild), adventure
	and spectator players break nothing, so their Mine messages are ignored.
]]
function EditRules.minesOverTime(mode: string): boolean
	return GameMode.mayBuild(mode) and not GameMode.instabuild(mode)
end

--[[
	Does a player in `mode` keep blocks from being placed where they stand (`obstructs`)? Everyone
	but spectators, whom Minecraft's Level.isUnobstructed skips (EntitySelector.NO_SPECTATORS).
]]
function EditRules.blocksPlacing(mode: string): boolean
	return not GameMode.isSpectator(mode)
end

--[[ Breaking and placing ]]

--[[
	May a player break `block` at (x, y, z) at time `now`, having started mining `mine`, holding
	`tool` (an item id, nil = bare hands) now? `creative`: the instabuild ability (breaks at once).
	Players who may not edit at all (`mayEdit`) never get this far.
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
	inventory)? Placeable blocks and the variants their items place, but no tall plant's upper half
	(placing the lower half sets it: `setPlaced`) and no cave twin (CaveGlowLichen*: only generation
	puts them in caves; players place GlowLichen*). Creative only blocks need `mayUseCreativeOnly`
	too.
]]
function EditRules.mayPlace(block: number, current: number): boolean
	local d = def(block)
	if
		d == nil
		or block == current
		or not Blocks.isReplaceable(current)
		or Blocks.plantBottom(block) ~= nil
		or Blocks.isCaveTwin(block)
	then
		return false
	end
	return d.placeable or (d.item ~= nil and Items.ofBlock(block) ~= nil)
end

--[[
	May a player place or break `block`, given whether they may use creative only blocks
	(`operator`: Structures/Permission, Minecraft's canUseGameMasterBlocks: creative, and allowed by
	Config.Structures.Permission or one of Config.Gameplay.Admins, the owner or Studio)? Structure
	blocks, structure voids and jigsaws need it; every other block may. (Survival players can't
	mine creative only blocks anyway: Mining.)
]]
function EditRules.mayUseCreativeOnly(block: number, operator: boolean): boolean
	return operator or not Blocks.isCreativeOnly(block)
end

--[[
	Is what `block` hangs on there, were it at (x, y, z)? Blocks without a `support` always are;
	plants need their soil (or lower half) below, and a tall plant's lower half room for its top
	(Blocks.canPlace). `getBlock` answers nil for blocks that are not loaded, which hold nothing up
	and leave no room.
]]
function EditRules.supported(
	block: number,
	getBlock: (x: number, y: number, z: number) -> number?,
	x: number,
	y: number,
	z: number
): boolean
	return def(block) ~= nil and Blocks.canPlace(block, getBlock, x, y, z)
end

--[[ Tall plants (Minecraft's DoublePlantBlock) ]]

--[[
	The other half of the tall plant whose half `block` is at (x, y, z): its y and block, when it
	is in place (the upper half right above a lower half, the lower half right below an upper
	half). nil for other blocks and for a half standing alone (the Plant behaviour pops those).
]]
function EditRules.pairedHalf(
	block: number,
	getBlock: (x: number, y: number, z: number) -> number?,
	x: number,
	y: number,
	z: number
): (number?, number?)
	local dy = Blocks.otherHalf(block)
	if dy == nil then
		return nil, nil
	end
	local partner = if dy > 0 then Blocks.plantTop(block) else Blocks.plantBottom(block)
	if partner == nil or getBlock(x, y + dy, z) ~= partner then
		return nil, nil
	end
	return y + dy, partner
end

--[[
	The block whose drop a player's break of `block` at (x, y, z) harvests, and its y: a tall
	plant's lower half, whichever half was hit, so it drops once, with the player's tool
	(DoublePlantBlock.playerWillDestroy; the loot tables' half = lower); the block itself
	otherwise. (An upper half alone harvests itself: nothing.)
]]
function EditRules.harvested(
	block: number,
	getBlock: (x: number, y: number, z: number) -> number?,
	x: number,
	y: number,
	z: number
): (number, number)
	if Blocks.plantBottom(block) ~= nil then
		local otherY, lower = EditRules.pairedHalf(block, getBlock, x, y, z)
		if otherY ~= nil and lower ~= nil then
			return lower, otherY
		end
	end
	return block, y
end

--[[
	Takes what a player's break of `block` at (x, y, z) removes out of `world`: the block, and the
	other half of a tall plant with it (no drop and no sound of its own: `harvested` already counts
	the plant's drop). false if the world refused the change (then nothing changed).
]]
function EditRules.removeBroken(world: World, x: number, y: number, z: number, block: number): boolean
	local otherY = EditRules.pairedHalf(block, function(bx: number, by: number, bz: number): number?
		return world:peekBlock(bx, by, bz)
	end, x, y, z)
	if not world:setBlock(x, y, z, Blocks.AIR) then
		return false
	end
	if otherY ~= nil then
		world:setBlock(x, otherY, z, Blocks.AIR)
	end
	return true
end

--[[
	Sets a placement of `block` that passed `mayPlace` and `supported` at (x, y, z) in `world`: the
	block, and a tall plant's upper half right above, over whatever replaceable block is there
	(DoublePlantBlock.setPlacedBy). The room is looked at again first (`supported` checked it
	before the item was used up; nothing should have changed it since): without it nothing is set
	and the result is false, as when the world refuses the block.
]]
function EditRules.setPlaced(world: World, x: number, y: number, z: number, block: number): boolean
	local top = Blocks.plantTop(block)
	if top ~= nil then
		local above = if y + 1 < Config.WorldHeight then world:peekBlock(x, y + 1, z) else nil
		if above == nil or not Blocks.isValid(above) or not Blocks.isReplaceable(above) then
			return false
		end
	end
	if not world:setBlock(x, y, z, block) then
		return false
	end
	if top ~= nil then
		-- (Both halves together: the lower half's Plant behaviour finds its top on its next tick.)
		world:setBlock(x, y + 1, z, top)
	end
	return true
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

-- What breaking `block` with `tool` drops as an item (nil = nothing; creative players, with the
-- instabuild ability, get none).
function EditRules.drops(block: number, creative: boolean, tool: number?): Items.Stack?
	if creative then
		return nil
	end
	return Items.drops(block, tool)
end

-- Wear the held `tool` takes from breaking `block` (0: creative (instabuild), not a tool, or an
-- instant block).
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

-- Does `block` hold items (a chest, a furnace, a machine with slots)? Its contents drop when it
-- is broken.
function EditRules.isContainer(block: number): boolean
	return def(block) ~= nil and Machines.containerSize(block) > 0
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
