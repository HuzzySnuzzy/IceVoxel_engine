--!strict
--[[
	Leaves (all five kinds), Minecraft's LeavesBlock with fast decay:

	  Support  a leaf stays while a log (any *Log) is within 6 blocks of it through leaves
	           (Minecraft's distance 1..6; a log next to it is 1). Leaves of any kind carry it, as
	           in Minecraft. A block in a chunk that isn't loaded counts as a log, so trees at the
	           edge of the loaded world never decay half-seen.
	  Decay    when a neighbour changes (a log chopped, a leaf gone), the leaf checks after a random
	           Config.Server.LeafDecay.MinDelay..MaxDelay ticks (a fraction of a second, where
	           Minecraft waits for a random tick: minutes) and, cut off, turns to air and drops what
	           leaves drop by themselves (Items.leafDrop: a sapling now and then, sometimes
	           sticks). Its neighbours then check in turn, so a felled tree's canopy falls apart
	           within a few seconds. A random tick (World/RandomTicker) checks too, for leaves cut
	           off while their chunk wasn't loaded.
	  Placed   leaves a player placed never decay (Minecraft's persistent): the server's edit list
	           records them, generated leaves aren't in it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local ChunkLayout = require(Shared.World.ChunkLayout)
local Config = require(Shared.Config)
local Items = require(Shared.Items)

local Drops = require(script.Parent.Drops)

local SIZE = ChunkLayout.SIZE
-- Minecraft's DECAY_DISTANCE: a log farther than this (through leaves) doesn't hold a leaf.
local REACH = 6

local LEAVES: { [number]: boolean } = {}
local LOGS: { [number]: boolean } = {}
for id, def in Blocks.defs do
	if string.sub(def.name, -6) == "Leaves" then
		LEAVES[id] = true
	elseif string.sub(def.name, -3) == "Log" then
		LOGS[id] = true
	end
end

local NEIGHBOURS = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }

local Leaves = {}

Leaves.LEAVES = LEAVES
Leaves.LOGS = LOGS

-- Did a player place the leaf at (x, y, z) (the edit list holds it)?
function Leaves.placed(world: any, x: number, y: number, z: number, block: number): boolean
	local edits = world:chunkEdits(x // SIZE, z // SIZE)
	if edits == nil then
		return false
	end
	local cx, cz = x // SIZE, z // SIZE
	return edits[ChunkLayout.localIndex(x - cx * SIZE, y, z - cz * SIZE)] == block
end

--[[
	Is the leaf at (x, y, z) held by a log within REACH through leaves? Unknown (unloaded) blocks
	count as logs.
]]
function Leaves.supported(
	getBlock: (x: number, y: number, z: number) -> number?,
	x: number,
	y: number,
	z: number
): boolean
	local seen: { [string]: boolean } = { [`{x},{y},{z}`] = true }
	local frontier = { { x, y, z } }
	-- A leaf at d steps holds the start when a log is next to it and d + 1 <= REACH.
	for distance = 0, REACH - 1 do
		local nextFrontier = {}
		for _, cell in frontier do
			for _, step in NEIGHBOURS do
				local nx, ny, nz = cell[1] + step[1], cell[2] + step[2], cell[3] + step[3]
				local key = `{nx},{ny},{nz}`
				if not seen[key] then
					seen[key] = true
					local block = getBlock(nx, ny, nz)
					if block == nil or LOGS[block] then
						return true
					elseif LEAVES[block] and distance + 1 < REACH then
						table.insert(nextFrontier, { nx, ny, nz })
					end
				end
			end
		end
		frontier = nextFrontier
		if #frontier == 0 then
			break
		end
	end
	return false
end

-- The leaf at (x, y, z) decays if nothing holds it.
local function check(world: any, x: number, y: number, z: number, block: number, random: () -> number)
	if Leaves.placed(world, x, y, z, block) then
		return
	end
	local supported = Leaves.supported(function(bx: number, by: number, bz: number): number?
		return world:peekBlock(bx, by, bz)
	end, x, y, z)
	if not supported and world:setBlock(x, y, z, Blocks.AIR) then
		local stack = Items.leafDrop(block, random)
		if stack then
			Drops.stack(x, y, z, stack)
		end
	end
end

function Leaves.onNeighborChanged(world: any, ticker: any, x: number, y: number, z: number, _block: number)
	local decay = Config.Server.LeafDecay
	ticker:schedule(x, y, z, math.random(decay.MinDelay, decay.MaxDelay))
end

function Leaves.onTick(world: any, _ticker: any, x: number, y: number, z: number, block: number)
	check(world, x, y, z, block, math.random)
end

function Leaves.onRandomTick(
	world: any,
	_ticker: any,
	x: number,
	y: number,
	z: number,
	block: number,
	random: () -> number
)
	check(world, x, y, z, block, random)
end

return Leaves
