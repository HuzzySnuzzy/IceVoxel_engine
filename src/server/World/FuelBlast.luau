--!strict
--[[
	Burning fuel, pure (no Roblox APIs, so the tests run it): when BuildCraft's fuel meets fire or
	something hot it goes off, and how a body of it explodes. World/Explosions runs the plans.

	  Catching  `exposed`: a fuel cell (any level, falling too) with Fire or lava (any level, the
	            cave twin too) on one of its six sides. Behaviours/Fluid asks whenever the fuel
	            or a neighbour changes, so fuel catches when fire or lava comes next to it and when
	            it flows next to them. (Crude oil does not: it is not explosive.)
	  Measuring `measure`: a flood fill through the six sides from the cell that caught, over
	            every connected fuel cell, at most Config.Explosions.MaxCells (4096), never into
	            cells another plan already holds (`claimed`) or chunks that are not loaded. A
	            source counts a bucket; a flowing cell its fill ((8 - level) / 8, falling fuel
	            8 / 8) times FlowingShare (1/16): flowing fluid is a thin sheet Minecraft makes
	            out of nothing, so a puddle spread from one bucket (a source and 112 flowing
	            cells) counts about 3.6 buckets instead of 43. Each cell keeps its distance
	            (steps through the fuel) from where it caught.
	  Power     `power(v)`: BucketPower (4) x cube root of v buckets, between MinPower (1) and
	            MaxPower (12). A blast's reach grows with the cube root of its charge (the
	            Hopkinson-Cranz scaling of explosives), and Minecraft's power is its reach (an
	            entity is hit within 2 x power, a ray runs out after 1.73 x power blocks of air).
	            So a bucket is TNT (4), a 2 x 2 puddle of sources (4 buckets) is a charged creeper
	            (6.3), 8 buckets 8, 27 buckets (a 3 x 3 x 3 tank's worth) 12.
	  Chaining  `plan`: the body is cut into cubes ClusterSize (4) wide (centred on the cell that
	            caught), and each cube goes off as its own blast: the power of the fuel in it, at
	            the fuel's centre (weighted by what each cell counts), when the flame front
	            reaches its nearest cell (ChainBlocksPerTick: 1.5 blocks a tick, so the near end
	            of a 16 block pool goes at once and the far end about half a second later).
	            Cubes with less than MinBlastVolume (half a bucket: the thin edge of a puddle)
	            flash into fire instead (power 0). So one bucket on the ground is one TNT
	            blast with a ring of fire around it, and a 16 x 16 x 4 refinery pool of 1024
	            buckets is a few dozen blasts of power 6 to 12 rippling across it over a second
	            or two (World/Explosions spreads them over ticks to bound the cost). All of them
	            are fiery, and each consumes the fuel of its cube.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local Coords = require(Shared.World.Coords)
local Fluids = require(Shared.Fluids)

export type GetBlock = (x: number, y: number, z: number) -> number?

-- A connected body of fuel: its cells (Coords.posKey, flood fill order: the first caught), the
-- buckets each counts and its distance (steps) from the first, and the buckets in all.
export type Body = {
	cells: { number },
	weights: { number },
	distances: { number },
	volume: number,
}

-- One blast of a plan (`power` 0: a flash into fire): where, when (ticks after catching), the
-- fuel cells it consumes and the buckets they count.
export type Blast = {
	x: number,
	y: number,
	z: number,
	power: number,
	volume: number,
	delay: number,
	cells: { number },
}

local Settings = Config.Explosions

local FuelBlast = {}

local FUEL = Fluids.FUEL
local LAVA = Fluids.LAVA
local FLUID_LUT = Fluids.blockLut
local FIRE = Blocks.find("Fire")
local FALLING = 8
local SIDES = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }

local function fluidOf(block: number): number
	if block < 0 or block >= Blocks.count then
		return 0
	end
	return buffer.readu8(FLUID_LUT, block)
end

-- Is `block` fuel (any level)?
function FuelBlast.isFuel(block: number?): boolean
	return block ~= nil and fluidOf(block) == FUEL
end

-- Is `block` a fuel source (level 0)? Only sources explode; flowing fuel burns like a fuse.
function FuelBlast.isSource(block: number?): boolean
	if not FuelBlast.isFuel(block) then
		return false
	end
	local fluid = Blocks.get(block :: number).fluid
	return fluid ~= nil and fluid.level == 0
end

-- Does `block` set fuel off: Fire, or lava of any level (the cave twin too)?
function FuelBlast.isHot(block: number?): boolean
	return block ~= nil and (block == FIRE or fluidOf(block) == LAVA)
end

-- Is the fuel at (x, y, z) touching something hot on one of its six sides?
function FuelBlast.exposed(getBlock: GetBlock, x: number, y: number, z: number): boolean
	for _, side in SIDES do
		if FuelBlast.isHot(getBlock(x + side[1], y + side[2], z + side[3])) then
			return true
		end
	end
	return false
end

-- Buckets a fuel block counts (see the header); 0 for anything else.
function FuelBlast.weight(block: number): number
	if not FuelBlast.isFuel(block) then
		return 0
	end
	local fluid = Blocks.get(block).fluid
	local level = if fluid then fluid.level else 0
	if level == 0 then
		return 1
	end
	local fill = if level == FALLING then 1 else (8 - level) / 8
	return fill * Settings.FlowingShare
end

-- The power of a blast of `volume` buckets of fuel (see the header).
function FuelBlast.power(volume: number): number
	if not (volume > 0) then
		return 0
	end
	return math.clamp(Settings.BucketPower * volume ^ (1 / 3), Settings.MinPower, Settings.MaxPower)
end

--[[
	The fuel connected to (x, y, z) (see the header), leaving out `claimed` cells (Coords.posKey);
	at most `maxCells` (default Config.Explosions.MaxCells). Empty when (x, y, z) is no fuel or
	is claimed.
]]
function FuelBlast.measure(
	getBlock: GetBlock,
	x: number,
	y: number,
	z: number,
	claimed: { [number]: any }?,
	maxCells: number?
): Body
	local limit = maxCells or Settings.MaxCells
	local body: Body = { cells = {}, weights = {}, distances = {}, volume = 0 }
	local start = Coords.posKey(x, y, z)
	local block = getBlock(x, y, z)
	if not FuelBlast.isFuel(block) or (claimed and claimed[start]) or limit < 1 then
		return body
	end
	local visited: { [number]: boolean } = { [start] = true }
	local queueX, queueY, queueZ = { x }, { y }, { z }
	local cells, weights, distances = body.cells, body.weights, body.distances
	cells[1], weights[1], distances[1] = start, FuelBlast.weight(block :: number), 0
	local head = 1
	while head <= #cells do
		local cx, cy, cz, distance = queueX[head], queueY[head], queueZ[head], distances[head]
		head += 1
		for _, side in SIDES do
			if #cells >= limit then
				break
			end
			local nx, ny, nz = cx + side[1], cy + side[2], cz + side[3]
			local key = Coords.posKey(nx, ny, nz)
			if not visited[key] then
				visited[key] = true
				local neighbour = getBlock(nx, ny, nz)
				if FuelBlast.isFuel(neighbour) and not (claimed and claimed[key]) then
					local n = #cells + 1
					cells[n], weights[n], distances[n] = key, FuelBlast.weight(neighbour :: number), distance + 1
					queueX[n], queueY[n], queueZ[n] = nx, ny, nz
				end
			end
		end
	end
	local volume = 0
	for _, weight in weights do
		volume += weight
	end
	body.volume = volume
	return body
end

--[[
	The blasts a body of fuel that caught at (x, y, z) goes off as (see the header), in the order
	they go (delay, then the flood fill's order). Every cell of `body` is in exactly one of them.
]]
function FuelBlast.plan(body: Body, x: number, y: number, z: number): { Blast }
	local size = math.max(1, math.floor(Settings.ClusterSize))
	local half = size // 2
	local speed = math.max(Settings.ChainBlocksPerTick, 1e-3)
	type Cluster = {
		first: number,
		near: number,
		volume: number,
		sx: number,
		sy: number,
		sz: number,
		mx: number,
		my: number,
		mz: number,
		cells: { number },
	}
	local byCube: { [number]: Cluster } = {}
	local clusters: { Cluster } = {}
	for i, key in body.cells do
		local cx, cy, cz = Coords.decodePosKey(key)
		local cube = Coords.posKey((cx - x + half) // size, (cy - y + half) // size + 512, (cz - z + half) // size)
		local cluster = byCube[cube]
		if cluster == nil then
			cluster = {
				first = i,
				near = body.distances[i],
				volume = 0,
				sx = 0,
				sy = 0,
				sz = 0,
				mx = 0,
				my = 0,
				mz = 0,
				cells = {},
			}
			byCube[cube] = cluster
			table.insert(clusters, cluster)
		end
		local weight = body.weights[i]
		local px, py, pz = cx + 0.5, cy + 0.5, cz + 0.5
		cluster.volume += weight
		cluster.sx += px * weight
		cluster.sy += py * weight
		cluster.sz += pz * weight
		cluster.mx += px
		cluster.my += py
		cluster.mz += pz
		cluster.near = math.min(cluster.near, body.distances[i])
		table.insert(cluster.cells, key)
	end
	local blasts: { Blast } = {}
	local order: { [Blast]: number } = {}
	for _, cluster in clusters do
		local n = #cluster.cells
		local bx, by, bz
		if cluster.volume > 0 then
			bx, by, bz = cluster.sx / cluster.volume, cluster.sy / cluster.volume, cluster.sz / cluster.volume
		else
			bx, by, bz = cluster.mx / n, cluster.my / n, cluster.mz / n
		end
		local blast: Blast = {
			x = bx,
			y = by,
			z = bz,
			power = if cluster.volume >= Settings.MinBlastVolume then FuelBlast.power(cluster.volume) else 0,
			volume = cluster.volume,
			delay = math.floor(cluster.near / speed),
			cells = cluster.cells,
		}
		order[blast] = cluster.first
		table.insert(blasts, blast)
	end
	table.sort(blasts, function(a, b)
		if a.delay ~= b.delay then
			return a.delay < b.delay
		end
		return order[a] < order[b]
	end)
	return blasts
end

return FuelBlast
