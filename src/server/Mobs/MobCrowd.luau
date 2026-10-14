--!strict
--!native
--[[
	Zombies keep a little room between them (pure; Mobs/MobWorld runs it every tick): mobs don't
	collide with each other (Shared/Movement/Hull knows only blocks), so without this a crowd
	chasing one player would melt into a single zombie-shaped column. Minecraft pushes entities
	apart (Entity.push, LivingEntity.pushEntities); this is a cheap stand-in for the zombie
	apocalypse's crowds.

	  build   once a tick, before any mob moves: every live, ticking zombie (MobList `zombie`, not
	          dying, not frozen) goes into a spatial hash of CELL (2) block columns, with its
	          position and width as they are at the start of the tick, so the result doesn't depend
	          on the order mobs tick in. Each pair of zombies in the same or neighbouring cells
	          whose horizontal distance d is under (wa + wb) / 2 + `separation`
	          (Config.Apocalypse.Zombies.Separation) is found once (a cell against itself and four
	          of its neighbours), and each of the two is to be pushed away from the other by PUSH x
	          the overlap (blocks a tick; from two in the very same spot, along a direction their
	          ids pick).
	  push    one zombie's push (between its AI and its physics: MobWorld's tickMob) is added to its
	          velocity.
	The cost is O(n) a tick for a crowd of n spread over the cells (a dense blob costs more: each
	pair in neighbouring cells is looked at once).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local MobList = require(Shared.Entities.MobList)

-- What the crowd reads of a mob (Mobs/MobWorld's record).
export type Member = {
	id: number,
	kind: MobList.Kind,
	body: any,
	removed: boolean,
	dead: boolean,
	frozen: boolean,
}

export type Crowd = {
	-- This tick's zombies: position, half width and id by index, and the push each gets.
	xs: { number },
	zs: { number },
	halves: { number },
	ids: { number },
	pushX: { number },
	pushZ: { number },
	pushed: { number },
	count: number,
	-- Mob id -> index this tick.
	index: { [number]: number },
	-- Cell key -> indices in it, only for the cells used this tick (their keys and coordinates
	-- in `used`, `usedX`, `usedZ`); each tick's lists go back to `pool` at the next build and
	-- are taken from it again, so nothing is kept for cells left behind and nothing is made
	-- anew in a steady crowd.
	cells: { [number]: { number } },
	used: { number },
	usedX: { number },
	usedZ: { number },
	pool: { { number } },
}

local MobCrowd = {}

-- Cell size (blocks) of the hash, and how hard an overlap pushes (blocks a tick per block of
-- overlap).
MobCrowd.CELL = 2
MobCrowd.PUSH = 0.05

local floor = math.floor
local sqrt = math.sqrt
local OFFSET = 2 ^ 20
local SPAN = 2 ^ 21
-- The neighbours a cell is paired with (the other four pair with it): +x, +z, +x+z, +x-z.
local NEIGHBOURS = { 1, 0, 0, 1, 1, 1, 1, -1 }

local function key(cx: number, cz: number): number
	return (cx + OFFSET) * SPAN + (cz + OFFSET)
end

function MobCrowd.new(): Crowd
	return {
		xs = {},
		zs = {},
		halves = {},
		ids = {},
		pushX = {},
		pushZ = {},
		pushed = {},
		count = 0,
		index = {},
		cells = {},
		used = {},
		usedX = {},
		usedZ = {},
		pool = {},
	}
end

-- The pushes between zombies i and j (see the header).
local function pair(crowd: Crowd, i: number, j: number, separation: number)
	local xs, zs = crowd.xs, crowd.zs
	local dx, dz = xs[i] - xs[j], zs[i] - zs[j]
	local room = crowd.halves[i] + crowd.halves[j] + separation
	local d2 = dx * dx + dz * dz
	if d2 >= room * room then
		return
	end
	local d = sqrt(d2)
	local overlap = room - d
	if d < 1e-6 then
		-- (The very same spot: apart along a direction their ids pick.)
		local a, b = crowd.ids[i], crowd.ids[j]
		local low, high = math.min(a, b), math.max(a, b)
		local angle = ((low * 7919 + high * 104729) % 360) / 180 * math.pi
		dx, dz, d = math.sin(angle), math.cos(angle), 1
		if a > b then
			dx, dz = -dx, -dz
		end
	end
	local strength = MobCrowd.PUSH * overlap / d
	local px, pz = dx * strength, dz * strength
	local pushX, pushZ, pushed = crowd.pushX, crowd.pushZ, crowd.pushed
	pushX[i] += px
	pushZ[i] += pz
	pushX[j] -= px
	pushZ[j] -= pz
	pushed[i] += 1
	pushed[j] += 1
end

--[[
	Hashes this tick's zombies among `mobs` and works out every push (see the header), with
	`separation` the extra room they keep.
]]
function MobCrowd.build(crowd: Crowd, mobs: { Member }, separation: number)
	local cells, used, usedX, usedZ, pool = crowd.cells, crowd.used, crowd.usedX, crowd.usedZ, crowd.pool
	-- (Last tick's cells go: their lists back to the pool.)
	for _, k in used do
		local list = cells[k]
		cells[k] = nil
		table.clear(list)
		table.insert(pool, list)
	end
	table.clear(used)
	table.clear(usedX)
	table.clear(usedZ)
	table.clear(crowd.index)
	local xs, zs, halves, ids, index = crowd.xs, crowd.zs, crowd.halves, crowd.ids, crowd.index
	local pushX, pushZ, pushed = crowd.pushX, crowd.pushZ, crowd.pushed
	local cell = MobCrowd.CELL
	local n = 0
	for _, mob in mobs do
		if mob.kind.zombie and not mob.removed and not mob.dead and not mob.frozen then
			n += 1
			local body = mob.body
			local x, z = body.x, body.z
			xs[n], zs[n], halves[n], ids[n] = x, z, mob.kind.width / 2, mob.id
			pushX[n], pushZ[n], pushed[n] = 0, 0, 0
			index[mob.id] = n
			local cx, cz = floor(x / cell), floor(z / cell)
			local k = key(cx, cz)
			local list = cells[k]
			if list == nil then
				list = table.remove(pool) or {}
				cells[k] = list
				table.insert(used, k)
				table.insert(usedX, cx)
				table.insert(usedZ, cz)
			end
			table.insert(list, n)
		end
	end
	crowd.count = n
	for c, k in used do
		local list = cells[k]
		local count = #list
		-- Within the cell...
		for a = 1, count - 1 do
			for b = a + 1, count do
				pair(crowd, list[a], list[b], separation)
			end
		end
		-- ... and against four of its neighbours.
		local cx, cz = usedX[c], usedZ[c]
		for s = 1, 7, 2 do
			local other = cells[key(cx + NEIGHBOURS[s], cz + NEIGHBOURS[s + 1])]
			if other then
				for _, i in list do
					for _, j in other do
						pair(crowd, i, j, separation)
					end
				end
			end
		end
	end
end

--[[
	Pushes `mob` (hashed this tick by `build`) away from the zombies crowding it (see the header).
	Returns how many pushed it.
]]
function MobCrowd.push(crowd: Crowd, mob: Member): number
	local i = crowd.index[mob.id]
	if i == nil then
		return 0
	end
	local pushed = crowd.pushed[i]
	if pushed > 0 then
		local body = mob.body
		body.vx += crowd.pushX[i]
		body.vz += crowd.pushZ[i]
	end
	return pushed
end

return MobCrowd
