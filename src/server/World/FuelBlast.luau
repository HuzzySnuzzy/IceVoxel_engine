--!strict
--[[
	Burning fuel, pure (no Roblox APIs, so the tests run it): what happens when BuildCraft's fuel
	(petrol: a block is 1 000 litres, a cubic metre) meets fire or something hot, as real petrol
	behaves. World/Explosions runs the plans.

	Real petrol does not detonate. Its liquid only burns at its surface, where it evaporates: a
	flame touching it lights the vapour layer over the pool, a flame front runs across the surface
	at a few metres a second and the pool burns on as a pool fire (a cubic metre would take hours;
	here the flames eat a block in about a minute: BlockList's `flammable` odds for fuel and
	Behaviours/Fire). Petrol explodes only as vapour mixed with air (1.4-7.6 % by volume), and only
	builds real pressure where that mix is closed in: a garage, a cellar, a sealed tank room, a
	cave pocket. Then it goes off as a gas explosion: its energy is the mix's (about 3.5 MJ a cubic
	metre), a fifth of it blast, and the pressure throws out the walls that can't hold it. Out in
	the open the vapour drifts off and there is no blast, only fire. (The energy in the liquid,
	34 GJ a block, seven tonnes of TNT, never comes out as a blast: it burns.)

	  Catching  `exposed`: a fuel cell (any level, falling too) with Fire or lava (any level, the
	            cave twin too) on one of its six sides. Behaviours/Fluid asks whenever the fuel
	            or a neighbour changes, so fuel catches when fire or lava comes next to it and when
	            it flows next to them. (Crude oil does not: it is far less volatile.)
	  Measuring `measure`: a flood fill through the six sides from the cell that caught, over
	            every connected fuel cell, at most Config.Explosions.MaxCells (4096), never into
	            cells left out (`skip`) or chunks that are not loaded. Each cell keeps its distance
	            (steps through the fuel) from where it caught.
	  Surface   `surface`: the body's cells with open air above them (air, cave air or a cell that
	            is not solid and no fluid: a plant, a torch, fire): where it evaporates and where
	            its flames stand.
	  Space     `pocket`: the air over the surface, flood filled through cells that are not solid
	            and hold no fluid, at most PocketCells (4096). It is closed (`sealed`) when the
	            fill ends before that, without meeting an unloaded chunk or the world's top; its
	            walls are the solid cells around it.
	  Vapour    `vapour(surface, volume)`: a closed space fills with an explosive mix up to
	            VapourPerSurface (16) m3 for each square metre of surface (an hour and a half of
	            evaporation), at most the space itself. Its blast: MixEnergy (3.5 MJ/m3) x Yield
	            (0.2) / TntEnergy (4.6 MJ/kg) = 0.15 kg of TNT a cubic metre of mix, and Minecraft's
	            power from that: 4 x (kg / MinecraftTnt)^(1/3) x Scale (Minecraft's TNT taken as
	            250 kg of real TNT, by its crater; a blast's reach grows with the cube root of its
	            charge), at most MaxPower. A 4 x 4 x 3 room full of vapour (48 m3, 7 kg) is power
	            1.2; a 16 x 16 x 16 hall (4096 m3, 620 kg) 5.4, a strong TNT blast.
	  Plan      `plan`: flames over every surface cell, each when the flame front (FlameSpeed,
	            0.15 blocks a tick: 3 m/s) reaches it through the fuel; and, when the space over
	            it is closed and holds vapour, one blast at the space's centre a tick after
	            catching (a deflagration fills a room in a fraction of a second), which also
	            throws out every wall of the space whose blast resistance is at most WallStrength
	            (3) x the share of the space the vapour fills: glass, dirt, sand, logs and planks
	            give, stone holds. The fuel itself is not used up by the blast: it burns on.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local Coords = require(Shared.World.Coords)
local Fluids = require(Shared.Fluids)

export type GetBlock = (x: number, y: number, z: number) -> number?

-- A connected body of fuel: its cells (Coords.posKey, flood fill order: the first caught) and
-- each one's distance (steps through the fuel) from the first.
export type Body = {
	cells: { number },
	distances: { number },
}

-- The air over a body: its cells, whether it is closed, and the solid cells around it.
export type Pocket = {
	cells: { number },
	sealed: boolean,
	walls: { number },
}

-- A closed space's vapour blast: where (blocks), its power, the TNT it is worth (kg), the share
-- of the space the vapour fills, the walls it throws out and the space's cells.
export type Blast = {
	x: number,
	y: number,
	z: number,
	power: number,
	tnt: number,
	fill: number,
	walls: { number },
	pocket: { number },
}

-- What a body that caught does: flames on its surface (the air cells over it, Coords.posKey,
-- each `delay` ticks after catching), and the blast of its closed space's vapour, if any.
export type Plan = {
	flames: { { key: number, delay: number } },
	blast: Blast?,
}

local Settings = Config.Explosions

local FuelBlast = {}

local FUEL = Fluids.FUEL
local LAVA = Fluids.LAVA
local FLUID_LUT = Fluids.blockLut
local FIRE = Blocks.find("Fire")
local TOP = Config.WorldHeight - 1
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

-- Does `block` set fuel off: Fire, or lava of any level (the cave twin too)?
function FuelBlast.isHot(block: number?): boolean
	return block ~= nil and (block == FIRE or fluidOf(block) == LAVA)
end

-- Can vapour pass `block` (not solid, no fluid: air, plants, torches, fire)?
function FuelBlast.isOpen(block: number): boolean
	return not Blocks.isSolid(block) and fluidOf(block) == 0
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

--[[
	The fuel connected to (x, y, z) (see the header), leaving out `skip` cells (Coords.posKey);
	at most `maxCells` (default Config.Explosions.MaxCells). Empty when (x, y, z) is no fuel or
	is skipped.
]]
function FuelBlast.measure(
	getBlock: GetBlock,
	x: number,
	y: number,
	z: number,
	skip: { [number]: any }?,
	maxCells: number?
): Body
	local limit = maxCells or Settings.MaxCells
	local body: Body = { cells = {}, distances = {} }
	local start = Coords.posKey(x, y, z)
	if not FuelBlast.isFuel(getBlock(x, y, z)) or (skip and skip[start]) or limit < 1 then
		return body
	end
	local visited: { [number]: boolean } = { [start] = true }
	local queueX, queueY, queueZ = { x }, { y }, { z }
	local cells, distances = body.cells, body.distances
	cells[1], distances[1] = start, 0
	local head = 1
	while head <= #cells do
		local cx, cy, cz, distance = queueX[head], queueY[head], queueZ[head], distances[head]
		head += 1
		for _, side in SIDES do
			if #cells >= limit then
				break
			end
			local nx, ny, nz = cx + side[1], cy + side[2], cz + side[3]
			if ny < 0 or ny > TOP then
				continue
			end
			local key = Coords.posKey(nx, ny, nz)
			if not visited[key] then
				visited[key] = true
				if FuelBlast.isFuel(getBlock(nx, ny, nz)) and not (skip and skip[key]) then
					local n = #cells + 1
					cells[n], distances[n] = key, distance + 1
					queueX[n], queueY[n], queueZ[n] = nx, ny, nz
				end
			end
		end
	end
	return body
end

--[[
	The open air cells over `body`'s surface (Coords.posKey; see the header), each with the
	distance of the fuel cell under it, in the body's order.
]]
function FuelBlast.surface(getBlock: GetBlock, body: Body): ({ number }, { number })
	local above, distances = {}, {}
	for i, key in body.cells do
		local x, y, z = Coords.decodePosKey(key)
		if y < TOP then
			local block = getBlock(x, y + 1, z)
			if block ~= nil and FuelBlast.isOpen(block) then
				table.insert(above, Coords.posKey(x, y + 1, z))
				table.insert(distances, body.distances[i])
			end
		end
	end
	return above, distances
end

--[[
	The air connected to `starts` (Coords.posKey of open cells) through open cells (see the
	header), at most `maxCells` (default Config.Explosions.PocketCells): its cells, whether it is
	closed, and the solid cells around it (only when closed).
]]
function FuelBlast.pocket(getBlock: GetBlock, starts: { number }, maxCells: number?): Pocket
	local limit = maxCells or Settings.PocketCells
	local pocket: Pocket = { cells = {}, sealed = false, walls = {} }
	local cells = pocket.cells
	local seen: { [number]: boolean } = {}
	local walls: { number } = {}
	for _, key in starts do
		if not seen[key] then
			seen[key] = true
			table.insert(cells, key)
		end
	end
	if #cells == 0 or #cells > limit then
		return pocket
	end
	local head = 1
	while head <= #cells do
		local cx, cy, cz = Coords.decodePosKey(cells[head])
		head += 1
		for _, side in SIDES do
			local nx, ny, nz = cx + side[1], cy + side[2], cz + side[3]
			if ny < 0 or ny > TOP then
				-- (Out of the world: the vapour has room to go.)
				return pocket
			end
			local key = Coords.posKey(nx, ny, nz)
			if not seen[key] then
				seen[key] = true
				local block = getBlock(nx, ny, nz)
				if block == nil then
					-- (Unloaded: unknown, so not closed.)
					return pocket
				elseif FuelBlast.isOpen(block) then
					if #cells >= limit then
						return pocket
					end
					table.insert(cells, key)
				elseif Blocks.isSolid(block) then
					table.insert(walls, key)
				end
			end
		end
	end
	pocket.sealed = true
	pocket.walls = walls
	return pocket
end

--[[
	The vapour a closed space of `volume` cells fills over `surface` square metres of fuel (m3),
	and its blast: Minecraft's power, the kilos of TNT it is worth, and the share of the space it
	fills (see the header).
]]
function FuelBlast.vapour(surface: number, volume: number): (number, number, number, number)
	if not (surface > 0 and volume > 0) then
		return 0, 0, 0, 0
	end
	local mix = math.min(volume, surface * Settings.VapourPerSurface)
	local tnt = mix * Settings.MixEnergy * Settings.Yield / Settings.TntEnergy
	local power = math.min(Settings.MaxPower, 4 * (tnt / Settings.MinecraftTnt) ^ (1 / 3) * Settings.Scale)
	return mix, power, tnt, mix / volume
end

--[[
	What a body of fuel does once it caught (see the header): flames on its surface as the front
	reaches them, and the blast of its closed space's vapour, unless `burning` (the space already
	holds fire: the vapour burns off as it rises).
]]
function FuelBlast.plan(getBlock: GetBlock, body: Body, burning: boolean?): Plan
	local speed = math.max(Settings.FlameSpeed, 1e-3)
	local above, distances = FuelBlast.surface(getBlock, body)
	local plan: Plan = { flames = {} }
	for i, key in above do
		table.insert(plan.flames, { key = key, delay = math.floor(distances[i] / speed) })
	end
	if burning or #above == 0 then
		return plan
	end
	local pocket = FuelBlast.pocket(getBlock, above)
	if not pocket.sealed then
		return plan
	end
	local _, power, tnt, fill = FuelBlast.vapour(#above, #pocket.cells)
	if power <= 0 then
		return plan
	end
	-- The space's centre, and the walls its pressure throws out.
	local sx, sy, sz = 0, 0, 0
	for _, key in pocket.cells do
		local x, y, z = Coords.decodePosKey(key)
		sx += x + 0.5
		sy += y + 0.5
		sz += z + 0.5
	end
	local n = #pocket.cells
	local strength = Settings.WallStrength * fill
	local walls = {}
	for _, key in pocket.walls do
		local x, y, z = Coords.decodePosKey(key)
		local block = getBlock(x, y, z)
		if block ~= nil and Blocks.get(block).blastResistance <= strength then
			table.insert(walls, key)
		end
	end
	plan.blast = {
		x = sx / n,
		y = sy / n,
		z = sz / n,
		power = power,
		tnt = tnt,
		fill = fill,
		walls = walls,
		pocket = pocket.cells,
	}
	return plan
end

return FuelBlast
