--!strict
--[[
	The rules of right clicking a block with the Configurator or a bucket (Players/ItemUse plays
	them out), pure so the tests can run them.

	Buckets (Minecraft 1.20.1's BucketItem and ItemUtils, Mekanism's
	FluidUtils.handleTankInteraction for Fluid Tanks and machines' fluid tanks; a bucket is
	Fluids.BUCKET = 1000 mB), for every fluid pipes carry (Shared/Fluids: water, lava, oil, fuel;
	each has its full bucket, Fluids.bucketOf):
	  * An empty bucket on a fluid's source (any carriable fluid, the cave twins CaveLava and CaveOil
	    too: Fluids.isSource, Minecraft's ClipContext.Fluid.SOURCE_ONLY) takes it (the source
	    becomes air) and becomes that fluid's bucket (ItemUtils.createFilledResult): one bucket of
	    a stack fills, the full bucket goes into the inventory (or is thrown when it is full).
	    Creative players keep their empty bucket and get a full one only if they have none of that
	    fluid's.
	  * An empty bucket on a Fluid Tank holding at least 1000 mB takes 1000 mB of its fluid the same
	    way; on a machine with fluid tanks it takes 1000 mB from its first output tank holding that
	    much, else from an input tank that does (Machines.fillBucket). Creative players get nothing
	    there (Mekanism fills the bucket only in simulation for them: the tank still loses it).
	  * A full bucket on a Fluid Tank with room for its 1000 mB (empty or holding that fluid)
	    empties into it; on a machine with fluid tanks into the first input tank taking the fluid
	    with room for all of it (Machines.pourBucket). Anywhere else it places the fluid's source
	    (never a cave twin) in that block if it is replaceable (air, any fluid, short grass), else
	    in the block beyond the clicked side if that one is (BucketItem.emptyContents). What the
	    fluid replaces is destroyed with its drops (a dead bush its stick, lava too: `pour`). A
	    tank or machine that cannot take all of it takes nothing, and the bucket stays full.
	    Survival players are left with an empty bucket, creative players keep the full one
	    (getEmptySuccessItem).
	  * Sneaking skips tanks and machines, as Minecraft skips a block's use for a sneaking player
	    with an item in hand: the bucket acts on the world.
	`fillBucket` and `emptyBucket` work a use out against a BucketEnv (the world, the pipes' tanks,
	the machines' containers) and say what the player holds and gets, and which sound plays where;
	ItemUse applies that.

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
local Fluids = require(Shared.Fluids)
local Items = require(Shared.Items)
local Machines = require(Shared.Machines)
local SharedSounds = require(Shared.Sounds)
local Transmitters = require(Shared.Transmitters)
local InventoryTypes = require(Shared.Inventory.Types)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local Drops = require(script.Parent.Parent.Behaviours.Drops)
local Containers = require(script.Parent.Parent.Players.Containers)
local TransmitterWorld = require(script.Parent.TransmitterWorld)

type Stack = Items.Stack

-- What a bucket use needs from the game.
export type BucketEnv = {
	-- Blocks (peekBlock, setBlock): never generates terrain.
	world: WorldServer.World,
	-- Fluid Tanks (nil: none).
	pipes: TransmitterWorld.World?,
	-- Machines' containers, where their tanks are (nil: none).
	containers: Containers.Store?,
	-- The instabuild ability (creative).
	creative: boolean,
	-- Does the player hold any of `item` (creative players get a full bucket only without one)?
	hasItem: (item: number) -> boolean,
}

--[[
	What a bucket use did: the stack now held and one to give besides (nil: nothing), and the sound
	event to play (nil: none) at (x, y, z) (blocks), or at the player's feet when `atPlayer`
	(Minecraft plays a pickup at the player).
]]
export type BucketResult = {
	held: Stack?,
	give: Stack?,
	sound: number?,
	x: number,
	y: number,
	z: number,
	atPlayer: boolean,
}

local HEIGHT = Config.WorldHeight
local BUCKET = Fluids.BUCKET

local UseRules = {}

UseRules.BUCKET = Items.id.Bucket
UseRules.WATER_BUCKET = Items.id.WaterBucket
UseRules.CONFIGURATOR = Items.id.Configurator
-- A water source block (Blocks.fluidId level 0).
UseRules.WATER_SOURCE = Blocks.fluidId("Water", 0)
UseRules.WATER = Fluids.WATER

-- `count` of `stack` (its wear and data kept); nil below 1.
local function copy(stack: Stack, count: number): Stack?
	return Items.withCount(stack, count)
end

-- The fluid a full bucket holds (a carriable fluid's bucket), 0 for any other item.
function UseRules.bucketFluid(item: number?): number
	local fluid = Fluids.ofBucket(item)
	return if Fluids.carriable(fluid) then fluid else 0
end

-- The fluid an empty bucket takes from `block`: a carriable fluid's source or cave twin, else 0.
function UseRules.pickup(block: number?): number
	if block == nil or not Fluids.isSource(block) then
		return 0
	end
	local fluid = Fluids.ofBlock(block)
	return if Fluids.carriable(fluid) then fluid else 0
end

-- A full bucket of `fluid` (water by default).
local function bucketStack(fluid: number?): Stack
	return { item = Fluids.bucketOf(fluid or Fluids.WATER) or UseRules.WATER_BUCKET, count = 1 }
end

--[[
	The sound event of a bucket taking (`fill`) or pouring `fluid`: the fluid's own
	(item.bucket.fill_lava ...) while Shared/Sounds has it, else Minecraft's plain bucket sounds.
]]
function UseRules.bucketSound(fluid: number, fill: boolean): number?
	local record = Fluids.get(fluid)
	local own = if record then SharedSounds.find(if fill then record.fillSound else record.emptySound) else nil
	return own or SharedSounds.find(if fill then "item.bucket.fill" else "item.bucket.empty")
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

--[[
	An empty bucket filled from a source in the world: the new held stack and what to give.
	`hasFilled`: the player holds a bucket of that fluid already. `fluid` defaults to water.
]]
function UseRules.fillFromWorld(held: Stack, creative: boolean, hasFilled: boolean, fluid: number?): (Stack?, Stack?)
	return UseRules.filledResult(held, bucketStack(fluid), creative, hasFilled, true)
end

--[[
	An empty bucket filled from a Fluid Tank or a machine (Mekanism's handleTankInteraction): as
	from the world for survival players; creative players' inventories stay as they are. `fluid`
	defaults to water.
]]
function UseRules.fillFromTank(held: Stack, creative: boolean, fluid: number?): (Stack?, Stack?)
	if creative then
		return held, nil
	end
	return UseRules.filledResult(held, bucketStack(fluid), false, false, false)
end

--[[
	A full bucket emptied (into the world, a tank or a machine): survival players are left with an
	empty bucket, creative players keep the full bucket (BucketItem.getEmptySuccessItem). Returns
	the new held stack and what to give (a stack of several full buckets, which never happens in
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

-- Is `block` a water source (what an empty bucket picks up as water)?
function UseRules.isWaterSource(block: number?): boolean
	return block == UseRules.WATER_SOURCE
end

--[[
	Where a full bucket aimed at side `side` of block (x, y, z) pours its fluid
	(BucketItem.emptyContents): that block if it is replaceable (air, any fluid), else the block
	beyond that side if it is; nil when neither (or outside the world). `getBlock` answers nil for
	unknown blocks, which take nothing.
]]
function UseRules.fluidTarget(
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

-- (The name it had while buckets held only water.)
UseRules.waterTarget = UseRules.fluidTarget

--[[
	Pours a bucket of `fluid` (water by default) into (x, y, z) of `world` (where `fluidTarget`
	points): the fluid's source (never its cave twin) takes the block's place, and what flowing
	fluid would wash away (short grass, a dead bush) drops what it drops by itself, lava too
	(BucketItem.emptyContents: Level.destroyBlock with drops; Behaviours/Drops). The Plant
	behaviour pops a tall plant's other half; Behaviours/Fluid takes it from there (lava poured
	next to water hardens). Pouring into the same source changes nothing but still counts: the
	bucket empties, as in Minecraft. false when the world refused it (the bucket stays full).
]]
function UseRules.pour(world: WorldServer.World, x: number, y: number, z: number, fluid: number?): boolean
	local source = Fluids.sourceOf(fluid or Fluids.WATER)
	local before = world:peekBlock(x, y, z)
	if before == nil or source == nil then
		return false
	end
	if not world:setBlock(x, y, z, source) then
		return before == source
	end
	local def = if Blocks.isValid(before) then Blocks.get(before) else nil
	if def and def.fluid == nil and def.brokenByFluid then
		Drops.block(x, y, z, before)
	end
	return true
end

-- The container of the machine with fluid tanks `block` at (x, y, z), nil for anything else.
local function machineAt(env: BucketEnv, block: number, x: number, y: number, z: number): InventoryTypes.Container?
	local containers = env.containers
	if containers == nil or not Machines.hasTanks(block) then
		return nil
	end
	local container = containers:peek(x, y, z)
	if container and container.block == block and container.kind == Machines.CONTAINER_KIND then
		return container
	end
	return nil
end

local function result(held: Stack?, give: Stack?, sound: number?, x: number, y: number, z: number): BucketResult
	return { held = held, give = give, sound = sound, x = x, y = y, z = z, atPlayer = false }
end

--[[
	An empty bucket (`held`) used on `block` at (x, y, z): a Fluid Tank's or a machine's fluid (not
	when sneaking), else a fluid's source in the world (it becomes air). nil when nothing happens.
]]
function UseRules.fillBucket(
	env: BucketEnv,
	held: Stack,
	block: number,
	x: number,
	y: number,
	z: number,
	sneaking: boolean
): BucketResult?
	local cx, cy, cz = x + 0.5, y + 0.5, z + 0.5
	if not sneaking then
		local pipes = env.pipes
		if Transmitters.isTank(block) then
			if pipes == nil then
				return nil
			end
			local amount, fluid = TransmitterWorld.drainTank(pipes, x, y, z, BUCKET, true)
			if amount < BUCKET or not Fluids.carriable(fluid) then
				return nil
			end
			TransmitterWorld.drainTank(pipes, x, y, z, BUCKET)
			local newHeld, give = UseRules.fillFromTank(held, env.creative, fluid)
			return result(newHeld, give, UseRules.bucketSound(fluid, true), cx, cy, cz)
		end
		if Machines.hasTanks(block) then
			local container = machineAt(env, block, x, y, z)
			local fluid = if container then Machines.fillBucket(container, true) else 0
			if container == nil or fluid == 0 then
				return nil
			end
			Machines.fillBucket(container)
			local newHeld, give = UseRules.fillFromTank(held, env.creative, fluid)
			return result(newHeld, give, UseRules.bucketSound(fluid, true), cx, cy, cz)
		end
	end
	local fluid = UseRules.pickup(block)
	if fluid == 0 or not env.world:setBlock(x, y, z, Blocks.AIR) then
		return nil
	end
	local filled = Fluids.bucketOf(fluid) :: number
	local newHeld, give = UseRules.fillFromWorld(held, env.creative, env.hasItem(filled), fluid)
	local done = result(newHeld, give, UseRules.bucketSound(fluid, true), cx, cy, cz)
	-- (At the player, as Minecraft's Player.playSound.)
	done.atPlayer = true
	return done
end

--[[
	A full bucket (`held`, of a carriable fluid) used on side `side` of `block` at (x, y, z): into
	a Fluid Tank or a machine (not when sneaking; all of it or nothing), else its source into the
	world (`fluidTarget`, `pour`). nil when nothing happens.
]]
function UseRules.emptyBucket(
	env: BucketEnv,
	held: Stack,
	block: number,
	x: number,
	y: number,
	z: number,
	side: number,
	sneaking: boolean
): BucketResult?
	local fluid = UseRules.bucketFluid(held.item)
	if fluid == 0 then
		return nil
	end
	local sound = UseRules.bucketSound(fluid, false)
	if not sneaking then
		local pipes = env.pipes
		if Transmitters.isTank(block) then
			-- (A bucket empties whole or not at all; a tank without room for it takes nothing.)
			if pipes == nil or TransmitterWorld.fillTank(pipes, x, y, z, fluid, BUCKET, true) < BUCKET then
				return nil
			end
			TransmitterWorld.fillTank(pipes, x, y, z, fluid, BUCKET)
			local newHeld, give = UseRules.emptied(held, env.creative)
			return result(newHeld, give, sound, x + 0.5, y + 0.5, z + 0.5)
		end
		if Machines.hasTanks(block) then
			local container = machineAt(env, block, x, y, z)
			if container == nil or not Machines.pourBucket(container, fluid) then
				return nil
			end
			local newHeld, give = UseRules.emptied(held, env.creative)
			return result(newHeld, give, sound, x + 0.5, y + 0.5, z + 0.5)
		end
	end
	local world = env.world
	local tx, ty, tz = UseRules.fluidTarget(function(bx: number, by: number, bz: number): number?
		return world:peekBlock(bx, by, bz)
	end, x, y, z, side)
	-- (Pouring into the same source changes nothing but still empties the bucket, as in Minecraft;
	-- a plant there drops.)
	if tx == nil or not UseRules.pour(world, tx, ty, tz, fluid) then
		return nil
	end
	local newHeld, give = UseRules.emptied(held, env.creative)
	return result(newHeld, give, sound, tx + 0.5, ty + 0.5, tz + 0.5)
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
