--!strict
--[[
	Rooms: enclosed, insulated spaces and their air's temperature, pure over a world view (server
	Seasons/RoomWorld owns them; Shared/Machines kinds use `thermostat`). Config.Seasons.Rooms.

	  Fill      `fill(view, x, y, z, limits)`: a 6-connected flood fill from the seed cell over
	            passable cells (Blocks.insulation nil: air, cave air, plants, torches, open doors,
	            fences, snow layers 1-7). A neighbour with an insulation is a wall face: a floor
	            face (the cell below the room with a solid block under it) adds its U to
	            `uaGround` (the ground's temperature, GROUND, is 0), any other to `uaOut`. A
	            passable cell at or above its column's `skyAbove` (the first height open to the
	            sky) is outside: the face towards it is an opening (OPENING_U, counted in
	            `openings`) and the fill does not enter it. Gives up past `maxVolume` cells,
	            `maxExtent` blocks across or `maxOpenings` openings, and at an unknown cell:
	            nil and "too big", "open" or "unloaded" (then the roof rule holds, Tough As
	            Nails' Temperature). Cell keys are World/Coords.posKey's.
	            So an open door leaks its two faces and a broken window one; under a porch roof
	            the fill runs on to where the sky starts; a seed in a wall, or open to the sky, is
	            "open" at once. A wall or an opening cell next to several of the room's cells is
	            one face for each. `walls` holds the wall and opening cells (what a change at
	            means the room must be filled again), `sources` the cells inside or in the walls
	            whose block the view's `source` says gives heat (Players/Climate's room sources;
	            none without one). `fillCells` is the same fill into a table of the caller's,
	            which on failure holds the passable cells it went through (all of them in the
	            same open, too big or unloaded space: server Seasons/RoomWorld remembers them
	            as no room for a while).
	  Air       a room's heat balance C dT/dt = P - uaOut (T - outside) - uaGround (T - GROUND),
	            C = HEAT_CAPACITY x volume, stepped at 1 Hz: `steady` (where T settles),
	            `step` (the exact exponential over dt, stable for any dt).
	  Control   `thermostat(setPoint, T, room, outside, ground, others, maxHU)`: the HU a
	            thermostat wants to hold the room at `setPoint` (proportional feed-forward:
	            uaOut (S - outside) + uaGround (S - ground) - others + uaTotal (S - T), within
	            0..maxHU; a cooler passes a negative maxHU and gets 0..maxHU the other way). With
	            enough power the room settles on S exactly (the error shrinks by 2a - 1 a step,
	            a = exp(-uaTotal dt / C)), never above maxHU.
	The air maths take any `Air` (a Room, or a RoomWorld Sample: what a machine's TickContext
	.climate gives its kind). `huText` writes heat units the way the machines' status lines do.

	The worked numbers (tests/spec/Rooms): a 5 x 5 x 3 plank house on grass with a closed wood
	door and two glass windows has uaOut 81 x 0.025 + 0.2 + 0.24 = 2.465, uaGround 0.5 and
	C = 150, so tau = C / UA = 50.6 s; with a winter night's -6.7 outside it settles at -5.6
	unheated, +1.2 with a campfire, and an electric heater holds +1 with 19.5 HU (78 J/t).
]]

local Blocks = require(script.Parent.Parent.Blocks)
local Config = require(script.Parent.Parent.Config)

-- What the fill reads of the world.
export type View = {
	-- The block at a cell, nil when unknown (not loaded).
	getBlock: (x: number, y: number, z: number) -> number?,
	-- The first height of column (x, z) open to the sky (cached per column for one fill); a
	-- column not loaded gives math.huge (its cells are then read, and found unknown).
	skyAbove: (x: number, z: number) -> number,
	-- Does `block` give a room heat (Players/Climate's room sources)? nil: nothing does (the
	-- room's `sources` stay empty).
	source: ((block: number) -> boolean)?,
}

-- How far a fill goes (Config.Seasons.Rooms' by default).
export type Limits = { maxVolume: number, maxExtent: number, maxOpenings: number }

-- A filled room.
export type Room = {
	id: number,
	-- Interior cells (Coords.posKey -> true), how many, and their bounds (blocks).
	cells: { [number]: true },
	volume: number,
	minX: number,
	minY: number,
	minZ: number,
	maxX: number,
	maxY: number,
	maxZ: number,
	-- The sums of U of its faces to the outside and to the ground, and its openings.
	uaOut: number,
	uaGround: number,
	openings: number,
	-- Positions (Coords.posKey) of heat sources inside it or in its walls.
	sources: { number },
	-- Wall and opening cells (Coords.posKey -> true).
	walls: { [number]: true },
}

-- A room as server Seasons/RoomWorld reports it (and Shared/Machines' TickContext.climate gives
-- kinds): its id, air temperature and outside value (Temperature's scale), losses, cells and the
-- HU of its sources now.
export type Sample = {
	id: number,
	temperature: number,
	outside: number,
	uaOut: number,
	uaGround: number,
	volume: number,
	heat: number,
}

-- What the air maths read of a room (a Room and a Sample both have it).
export type Air = { volume: number, uaOut: number, uaGround: number }

local Rooms = {}

local settings = Config.Seasons.Rooms

-- U of an opening face, the air's heat capacity per cell, the ground's temperature.
Rooms.OPENING_U = settings.OpeningU
Rooms.HEAT_CAPACITY = settings.HeatCapacity
Rooms.GROUND = 0
-- Why a fill found no room.
Rooms.OPEN = "open"
Rooms.TOO_BIG = "too big"
Rooms.UNLOADED = "unloaded"

-- Coords.posKey's packing (World/Coords): a step along y, z and x.
local OFFSET = 1048576
local SPAN = 2097152
local STEP_Y = 1
local STEP_Z = 1024
local STEP_X = SPAN * 1024

local function posKey(x: number, y: number, z: number): number
	return ((x + OFFSET) * SPAN + (z + OFFSET)) * 1024 + y
end

-- Every block's U (Blocks.insulation, -1 where a room's air passes), by id + 1: the fill's hot loop.
local U: { number } = table.create(Blocks.count, -1)
for id = 0, Blocks.count - 1 do
	U[id + 1] = Blocks.insulation(id) or -1
end
local OPENING_U = Rooms.OPENING_U

-- Config's limits.
function Rooms.limits(): Limits
	return { maxVolume = settings.MaxVolume, maxExtent = settings.MaxExtent, maxOpenings = settings.MaxOpenings }
end

local DEFAULT_LIMITS = Rooms.limits()

-- Does a room's air pass through `block` (no insulation: a cell the fill goes on into)?
function Rooms.passable(block: number): boolean
	return (U[block + 1] or -1) < 0
end

--[[
	The room the cell (x, y, z) is in (see the header), or nil and why not, with its interior cells
	put into `cells` (a table of the caller's, empty; on failure it holds the passable cells the
	fill went through).
]]
function Rooms.fillCells(
	view: View,
	x: number,
	y: number,
	z: number,
	limits: Limits?,
	cells: { [number]: true }
): (Room?, string?)
	local bounds = limits or DEFAULT_LIMITS
	local maxVolume, maxExtent, maxOpenings = bounds.maxVolume, bounds.maxExtent, bounds.maxOpenings
	local getBlock, skyAbove, isSource = view.getBlock, view.skyAbove, view.source
	local seed = getBlock(x, y, z)
	if seed == nil then
		return nil, Rooms.UNLOADED
	end
	-- (A column's sky height, once a fill.)
	local columns: { [number]: number } = {}
	local function sky(cx: number, cz: number): number
		local column = (cx + OFFSET) * SPAN + (cz + OFFSET)
		local top = columns[column]
		if top == nil then
			top = skyAbove(cx, cz)
			columns[column] = top
		end
		return top
	end
	if not Rooms.passable(seed) or y >= sky(x, z) then
		return nil, Rooms.OPEN
	end
	local walls: { [number]: true } = {}
	local sources: { number } = {}
	local sourced: { [number]: boolean } = {}
	local uaOut, uaGround, openings, volume = 0, 0, 0, 1
	local minX, minY, minZ, maxX, maxY, maxZ = x, y, z, x, y, z
	local seedKey = posKey(x, y, z)
	cells[seedKey] = true
	if isSource and isSource(seed) then
		sourced[seedKey] = true
		table.insert(sources, seedKey)
	end
	-- The queue: cell keys and coordinates.
	local qk: { number } = { seedKey }
	local qx: { number } = { x }
	local qy: { number } = { y }
	local qz: { number } = { z }
	local head, tail = 1, 1

	-- One face of a cell towards its neighbour (nx, ny, nz), key `nk`, not in the room yet: false
	-- when the fill gives up (`reason`).
	local reason: string? = nil
	local function face(nk: number, nx: number, ny: number, nz: number, floor: boolean): boolean
		local block = getBlock(nx, ny, nz)
		if block == nil then
			reason = Rooms.UNLOADED
			return false
		end
		local u = U[block + 1] or -1
		if u >= 0 then
			walls[nk] = true
			if floor then
				-- (A floor on anything insulating loses to the ground; one over air, to the outside.)
				local under = getBlock(nx, ny - 1, nz)
				if under ~= nil and (U[under + 1] or -1) >= 0 then
					uaGround += u
				else
					uaOut += u
				end
			else
				uaOut += u
			end
			if isSource and not sourced[nk] then
				sourced[nk] = true
				if isSource(block) then
					table.insert(sources, nk)
				end
			end
			return true
		elseif ny >= sky(nx, nz) then
			-- Outside: an opening, not entered.
			walls[nk] = true
			openings += 1
			uaOut += OPENING_U
			if openings > maxOpenings then
				reason = Rooms.OPEN
				return false
			end
			return true
		end
		cells[nk] = true
		volume += 1
		if volume > maxVolume then
			reason = Rooms.TOO_BIG
			return false
		end
		if nx < minX then
			minX = nx
		elseif nx > maxX then
			maxX = nx
		end
		if ny < minY then
			minY = ny
		elseif ny > maxY then
			maxY = ny
		end
		if nz < minZ then
			minZ = nz
		elseif nz > maxZ then
			maxZ = nz
		end
		if maxX - minX >= maxExtent or maxY - minY >= maxExtent or maxZ - minZ >= maxExtent then
			reason = Rooms.TOO_BIG
			return false
		end
		if isSource and isSource(block) then
			sourced[nk] = true
			table.insert(sources, nk)
		end
		tail += 1
		qk[tail], qx[tail], qy[tail], qz[tail] = nk, nx, ny, nz
		return true
	end

	while head <= tail do
		local k, cx, cy, cz = qk[head], qx[head], qy[head], qz[head]
		head += 1
		-- (Cells already in the room are skipped here: half of all faces, without a call.)
		local nk = k + STEP_Y
		if not cells[nk] and not face(nk, cx, cy + 1, cz, false) then
			return nil, reason
		end
		nk = k - STEP_Y
		if not cells[nk] and not face(nk, cx, cy - 1, cz, true) then
			return nil, reason
		end
		nk = k + STEP_X
		if not cells[nk] and not face(nk, cx + 1, cy, cz, false) then
			return nil, reason
		end
		nk = k - STEP_X
		if not cells[nk] and not face(nk, cx - 1, cy, cz, false) then
			return nil, reason
		end
		nk = k + STEP_Z
		if not cells[nk] and not face(nk, cx, cy, cz + 1, false) then
			return nil, reason
		end
		nk = k - STEP_Z
		if not cells[nk] and not face(nk, cx, cy, cz - 1, false) then
			return nil, reason
		end
	end

	return {
		id = 0,
		cells = cells,
		volume = volume,
		minX = minX,
		minY = minY,
		minZ = minZ,
		maxX = maxX,
		maxY = maxY,
		maxZ = maxZ,
		uaOut = uaOut,
		uaGround = uaGround,
		openings = openings,
		sources = sources,
		walls = walls,
	},
		nil
end

-- The room the cell (x, y, z) is in (see the header), or nil and why not.
function Rooms.fill(view: View, x: number, y: number, z: number, limits: Limits?): (Room?, string?)
	return Rooms.fillCells(view, x, y, z, limits, {})
end

-- Where the room's air settles with `heat` HU (see the header).
function Rooms.steady(room: Air, outside: number, ground: number, heat: number): number
	local ua = room.uaOut + room.uaGround
	if ua <= 0 then
		-- (No losses at all: nothing to settle on; what it holds stays.)
		return if heat > 0 then math.huge elseif heat < 0 then -math.huge else outside
	end
	return (heat + room.uaOut * outside + room.uaGround * ground) / ua
end

--[[
	The room's air `dt` seconds on from `temperature` (see the header): the exact solution of the
	heat balance with the outside, the ground and `heat` held over dt, so any dt is stable.
]]
function Rooms.step(temperature: number, room: Air, outside: number, ground: number, heat: number, dt: number): number
	local ua = room.uaOut + room.uaGround
	local capacity = Rooms.HEAT_CAPACITY * room.volume
	if dt <= 0 then
		return temperature
	elseif capacity <= 0 then
		return Rooms.steady(room, outside, ground, heat)
	elseif ua <= 0 then
		return temperature + heat * dt / capacity
	end
	local settled = (heat + room.uaOut * outside + room.uaGround * ground) / ua
	return settled + (temperature - settled) * math.exp(-ua * dt / capacity)
end

-- The HU a thermostat wants (see the header).
function Rooms.thermostat(
	setPoint: number,
	temperature: number,
	room: Air,
	outside: number,
	ground: number,
	others: number,
	maxHU: number
): number
	local want = room.uaOut * (setPoint - outside)
		+ room.uaGround * (setPoint - ground)
		- others
		+ (room.uaOut + room.uaGround) * (setPoint - temperature)
	if want ~= want then
		return 0
	elseif maxHU >= 0 then
		return math.clamp(want, 0, maxHU)
	end
	return math.clamp(want, maxHU, 0)
end

--[[
	Heat units as the machines' status lines write them, without a sign: whole numbers from 10 up,
	one decimal below ("Heating 32 HU", "9.5 HU", "0.4 HU").
]]
function Rooms.huText(hu: number): string
	local value = math.abs(if hu == hu then hu else 0)
	if value >= 9.95 then
		return string.format("%d", math.floor(value + 0.5))
	end
	local tenths = math.floor(value * 10 + 0.5)
	if tenths % 10 == 0 then
		return string.format("%d", tenths // 10)
	end
	return string.format("%.1f", tenths / 10)
end

return Rooms
