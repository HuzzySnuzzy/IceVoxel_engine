--!strict
--[[
	The rules of right clicking a block with the Configurator or a bucket (Players/ItemUse plays
	them out), pure so the tests can run them.

	Buckets (Minecraft 1.20.1's BucketItem and ItemUtils, Mekanism's
	FluidUtils.handleTankInteraction for fluid tanks; a bucket is Transmitters.BUCKET = 1000 mB):
	  * An empty bucket on a water source takes it (the source becomes air) and becomes a Water
	    Bucket (ItemUtils.createFilledResult): one bucket of a stack fills, the water bucket goes
	    into the inventory (or is thrown when it is full). Creative players keep their empty bucket
	    and get a water bucket only if they have none.
	  * An empty bucket on a fluid tank holding at least 1000 mB of water takes 1000 mB the same
	    way, except that creative players get nothing (Mekanism fills the bucket only in
	    simulation for them: the tank still loses the water).
	  * A water bucket on a fluid tank with room for 1000 mB empties into it; on any other block it
	    places a water source in that block if it is replaceable (air, water, short grass), else
	    in the block beyond the clicked side if that one is (BucketItem.emptyContents). What the
	    water replaces is destroyed with its drops (a dead bush its stick; `pour`). Survival
	    players are left with an empty bucket, creative players keep the water bucket
	    (getEmptySuccessItem).
	  * Sneaking skips the tank, as Minecraft skips a block's use for a sneaking player with an
	    item in hand: the bucket acts on the world.

	The Configurator's messages are Mekanism's: "Connection type changed to pull", "Colour bumped
	to: red".

	`creative` everywhere here is the instabuild ability (Shared/GameMode.instabuild: creative
	mode). Players whose mode may not use items on blocks (adventure, spectator:
	Players/GameModeRules.mayUseItemOn) never get this far.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local Transmitters = require(Shared.Transmitters)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local Drops = require(script.Parent.Parent.Behaviours.Drops)

type Stack = Items.Stack

local HEIGHT = Config.WorldHeight

local UseRules = {}

UseRules.BUCKET = Items.id.Bucket
UseRules.WATER_BUCKET = Items.id.WaterBucket
UseRules.CONFIGURATOR = Items.id.Configurator
-- A water source block (Blocks.fluidId level 0).
UseRules.WATER_SOURCE = Blocks.fluidId("Water", 0)
UseRules.WATER = Transmitters.FLUIDS.WATER

-- `count` of `stack` (its wear and data kept); nil below 1.
local function copy(stack: Stack, count: number): Stack?
	return Items.withCount(stack, count)
end

--[[
	Minecraft's ItemUtils.createFilledResult: `held` (empty containers) filled into `filled`.
	Returns the new held stack and a stack to give the player (into the inventory, thrown if it
	does not fit; nil: nothing). `preventDuplicates` (BucketItem's) lets creative players keep
	`held` and get `filled` only when they hold none (`hasFilled`).
]]
function UseRules.filledResult(
	held: Stack,
	filled: Stack,
	creative: boolean,
	hasFilled: boolean,
	preventDuplicates: boolean
): (Stack?, Stack?)
	if preventDuplicates and creative then
		return held, if hasFilled then nil else filled
	end
	local left = held.count - (if creative then 0 else 1)
	if left < 1 then
		return filled, nil
	end
	return copy(held, left), filled
end

-- An empty bucket filled from a water source in the world: the new held stack and what to give.
function UseRules.fillFromWorld(held: Stack, creative: boolean, hasWaterBucket: boolean): (Stack?, Stack?)
	return UseRules.filledResult(held, { item = UseRules.WATER_BUCKET, count = 1 }, creative, hasWaterBucket, true)
end

--[[
	An empty bucket filled from a fluid tank (Mekanism's handleTankInteraction): as from the world
	for survival players; creative players' inventories stay as they are.
]]
function UseRules.fillFromTank(held: Stack, creative: boolean): (Stack?, Stack?)
	if creative then
		return held, nil
	end
	return UseRules.filledResult(held, { item = UseRules.WATER_BUCKET, count = 1 }, false, false, false)
end

--[[
	A water bucket emptied (into the world or a tank): survival players are left with an empty
	bucket, creative players keep the water bucket (BucketItem.getEmptySuccessItem). Returns the
	new held stack and what to give (a stack of several water buckets, which never happens in
	play, keeps the rest and gives the empty bucket).
]]
function UseRules.emptied(held: Stack, creative: boolean): (Stack?, Stack?)
	if creative then
		return held, nil
	end
	local bucket = { item = UseRules.BUCKET, count = 1 }
	if held.count <= 1 then
		return bucket, nil
	end
	return copy(held, held.count - 1), bucket
end

-- Is `block` a water source (what an empty bucket picks up)?
function UseRules.isWaterSource(block: number?): boolean
	return block == UseRules.WATER_SOURCE
end

--[[
	Where a water bucket aimed at side `side` of block (x, y, z) pours its water
	(BucketItem.emptyContents): that block if it is replaceable (air, water), else the block beyond
	that side if it is; nil when neither (or outside the world). `getBlock` answers nil for
	unknown blocks, which take nothing.
]]
function UseRules.waterTarget(
	getBlock: (x: number, y: number, z: number) -> number?,
	x: number,
	y: number,
	z: number,
	side: number
): (number?, number, number)
	local function takes(bx: number, by: number, bz: number): boolean
		if by < 0 or by >= HEIGHT then
			return false
		end
		local block = getBlock(bx, by, bz)
		return block ~= nil and Blocks.isValid(block) and Blocks.isReplaceable(block)
	end
	if takes(x, y, z) then
		return x, y, z
	end
	if not Transmitters.isSide(side) then
		return nil, 0, 0
	end
	local dx, dy, dz = Transmitters.offset(side)
	if takes(x + dx, y + dy, z + dz) then
		return x + dx, y + dy, z + dz
	end
	return nil, 0, 0
end

--[[
	Pours a water bucket into (x, y, z) of `world` (where `waterTarget` points): a water source
	takes the block's place, and what flowing water would wash away (short grass, a dead bush)
	drops what it drops by itself (BucketItem.emptyContents: Level.destroyBlock with drops;
	Behaviours/Drops). The Plant behaviour pops a tall plant's other half. Pouring into a water
	source changes nothing but still counts: the bucket empties, as in Minecraft. false when the
	world refused the water (the bucket stays full).
]]
function UseRules.pour(world: WorldServer.World, x: number, y: number, z: number): boolean
	local before = world:peekBlock(x, y, z)
	if before == nil then
		return false
	end
	if not world:setBlock(x, y, z, UseRules.WATER_SOURCE) then
		return before == UseRules.WATER_SOURCE
	end
	local def = if Blocks.isValid(before) then Blocks.get(before) else nil
	if def and def.fluid == nil and def.brokenByFluid then
		Drops.block(x, y, z, before)
	end
	return true
end

-- Mekanism's message after the Configurator changed a side: "Connection type changed to pull".
function UseRules.modeNotice(mode: number): string
	return `Connection type changed to {string.lower(Transmitters.modeName(mode))}`
end

-- Mekanism's message after the Configurator coloured a transporter: "Colour bumped to: red".
function UseRules.colourNotice(colour: number): string
	return `Colour bumped to: {string.lower(Transmitters.colourName(colour))}`
end

return UseRules
