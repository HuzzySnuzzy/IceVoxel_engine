--!strict
--!native
--[[
	Rain and snow around the camera, as pure rules (Weather/PrecipitationView draws them and plays
	their sounds; tests/spec/WeatherVisuals checks them). Minecraft's LevelRenderer.renderSnowAndRain
	and tickRain, column by column:

	  Columns   every block column within RADIUS of the camera's (Minecraft's 5 on Fast graphics,
	            10 on Fancy; Config.Weather.Precipitation.Radius), as one strip facing the camera
	            (`columns`, nearest first). A column at horizontal distance d draws at
	            ((1 - d^2 / r^2) x 0.5 + 0.5) of the intensity (Minecraft's alpha), so the edge of
	            the drawn disc fades out; columns at d >= r are left out (alpha 0 there).
	  Span      rain lands on the first block from the top that stops it (Weather.blocksRain:
	            Minecraft's MOTION_BLOCKING heightmap; `floor` is the cell above it). A column
	            draws from max(cameraY - r, floor) up to max(cameraY + r, floor) (Minecraft's
	            k2 / l2), nothing when those meet: rain stops at roofs and never falls indoors or
	            in caves, and a column whose roof is above the camera draws nothing at all.
	  Form      rain or snow by the column's biome and the height it lands at (Weather.formAt;
	            nothing in deserts and savannas), so the snow line cuts through the disc.
	  Intensity the precipitation at the camera (Shared/Weather: 0..1, smoothed in time by
	            Weather/WeatherState), Minecraft's rain level: it is drawn from VISIBLE on (a faint
	            drizzle at a storm's edge, as Minecraft draws a rain level fading in), in
	            LEVELS steps of alpha (`level`), so the strips are only rewritten when a step
	            changes.
	  Sounds    Minecraft's tickRain (`rainSound`): each client tick, 100 x level^2 random columns
	            within 10 blocks (level halved on Fast graphics) are tried, and the last where rain
	            (not snow) lands within 10 blocks of the camera's height is the sound's place; a
	            sound plays there when nextInt(3) < the ticks since the last one (about every 2.4
	            ticks): weather.rain.above (volume 0.1, pitch 0.5) when it lands more than a block
	            above the camera and the camera's own column is roofed, else weather.rain (0.2, 1),
	            louder with the precipitation (Weather.rainSound).

	Column tops come from the loaded chunk data (`floorOf`: a scan down one column of a chunk's
	buffer, Shared/World/ChunkLayout, against a lookup table of the blocks that stop rain), kept per
	column by `ColumnCache` and corrected by edits (`edited`): a new blocking block above the floor
	raises it, the floor's own block going away drops the column for a new scan.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local ChunkLayout = require(Shared.World.ChunkLayout)
local Weather = require(Shared.Weather)

local P = ChunkLayout.PADDED
local LAYER = ChunkLayout.LAYER
local SIZE = ChunkLayout.SIZE

local readu16 = buffer.readu16
local readu8 = buffer.readu8

export type Column = {
	dx: number,
	dz: number,
	-- Minecraft's distance alpha at this column (0.5 .. 1).
	edge: number,
}

-- A column's cached rain floor and Minecraft temperature (nil: nothing falls there).
export type Entry = { floor: number, temperature: number? }

export type ColumnCache = {
	entries: { [number]: Entry },
	count: number,
	limit: number,
}

export type SoundState = { time: number }

local Precipitation = {}

-- The Weather setting's values (Options > Weather...).
Precipitation.OFF = 0
Precipitation.FAST = 1
Precipitation.FANCY = 2

-- Below this precipitation nothing is drawn (alpha steps of 1 / LEVELS).
Precipitation.VISIBLE = 0.02
Precipitation.LEVELS = 16

-- Minecraft's tickRain: columns within 10 blocks, landings within 10 blocks of the camera's height.
Precipitation.SOUND_REACH = 10

-- Column keys: x * COLUMN_SPAN + z (|z| < 2^25).
local COLUMN_SPAN = 67108864
Precipitation.COLUMN_SPAN = COLUMN_SPAN

function Precipitation.key(x: number, z: number): number
	return x * COLUMN_SPAN + z
end

-- The column (x, z) of a `key`.
function Precipitation.unkey(key: number): (number, number)
	local z = (key + COLUMN_SPAN / 2) % COLUMN_SPAN - COLUMN_SPAN / 2
	return (key - z) // COLUMN_SPAN, z
end

--[[ Columns ]]

-- The columns within `radius` of the camera's (d < radius), nearest first.
function Precipitation.columns(radius: number): { Column }
	local list: { Column } = {}
	local r = math.floor(radius)
	for dx = -r, r do
		for dz = -r, r do
			local d2 = dx * dx + dz * dz
			if d2 < radius * radius then
				table.insert(list, { dx = dx, dz = dz, edge = (1 - d2 / (radius * radius)) * 0.5 + 0.5 })
			end
		end
	end
	table.sort(list, function(a: Column, b: Column): boolean
		local da, db = a.dx * a.dx + a.dz * a.dz, b.dx * b.dx + b.dz * b.dz
		if da ~= db then
			return da < db
		end
		return if a.dx ~= b.dx then a.dx < b.dx else a.dz < b.dz
	end)
	return list
end

--[[
	The span a column draws (cells, bottom inclusive to top exclusive) with its rain floor at
	`floor` and the camera's cell at `cameraY`: nil when there is nothing (Minecraft's k2 == l2).
]]
function Precipitation.span(floor: number, cameraY: number, radius: number): (number?, number?)
	local bottom, top = cameraY - radius, cameraY + radius
	if bottom < floor then
		bottom = floor
	end
	if top < floor then
		top = floor
	end
	if top <= bottom then
		return nil, nil
	end
	return bottom, top
end

-- The alpha step (0 .. LEVELS) of a column at `edge` with intensity `intensity` (0..1).
function Precipitation.level(intensity: number, edge: number): number
	if intensity < Precipitation.VISIBLE then
		return 0
	end
	return math.clamp(math.floor(intensity * edge * Precipitation.LEVELS + 0.5), 0, Precipitation.LEVELS)
end

--[[ Column tops ]]

-- 1 for every block that stops rain (Weather.blocksRain), indexed by block id.
local stops: buffer? = nil
function Precipitation.stops(): buffer
	local lut = stops
	if lut == nil then
		local built = buffer.create(Blocks.count)
		for id = 0, Blocks.count - 1 do
			if Weather.blocksRain(id) then
				buffer.writeu8(built, id, 1)
			end
		end
		stops = built
		lut = built
	end
	return lut :: buffer
end

--[[
	The rain floor of core column (lx, lz) (0 .. SIZE - 1) in chunk data `data` cropped at
	`height` (ChunkLayout): the cell above the highest block that stops rain, 0 when none does.
]]
function Precipitation.floorOf(data: buffer, height: number, lx: number, lz: number, lut: buffer): number
	local index = ((height - 1) * P + lz + 1) * P + lx + 1
	for y = height - 1, 0, -1 do
		if readu8(lut, readu16(data, index * 2)) == 1 then
			return y + 1
		end
		index -= LAYER
	end
	return 0
end

function Precipitation.newCache(limit: number?): ColumnCache
	return { entries = {}, count = 0, limit = limit or 8192 }
end

-- The cached entry of column (x, z), nil when it must be scanned.
function Precipitation.cached(cache: ColumnCache, x: number, z: number): Entry?
	return cache.entries[x * COLUMN_SPAN + z]
end

-- Keeps column (x, z)'s floor and temperature (starting over when the cache is full).
function Precipitation.store(cache: ColumnCache, x: number, z: number, floor: number, temperature: number?): Entry
	if cache.count >= cache.limit then
		table.clear(cache.entries)
		cache.count = 0
	end
	local key = x * COLUMN_SPAN + z
	local entry = cache.entries[key]
	if entry == nil then
		entry = { floor = floor, temperature = temperature }
		cache.entries[key] = entry
		cache.count += 1
	else
		entry.floor, entry.temperature = floor, temperature
	end
	return entry :: Entry
end

--[[
	Block (x, y, z) became `block`: a block that stops rain above the floor raises it; the floor's
	own block giving way drops the column (scanned again). Returns whether the column changed.
]]
function Precipitation.edited(cache: ColumnCache, x: number, y: number, z: number, block: number): boolean
	local key = x * COLUMN_SPAN + z
	local entry = cache.entries[key]
	if entry == nil then
		return false
	end
	local blocking = readu8(Precipitation.stops(), block) == 1
	if blocking and y + 1 > entry.floor then
		entry.floor = y + 1
		return true
	elseif not blocking and y + 1 == entry.floor then
		cache.entries[key] = nil
		cache.count -= 1
		return true
	end
	return false
end

-- Drops every column of chunk (cx, cz) (its data was attached again or detached).
function Precipitation.dropChunk(cache: ColumnCache, cx: number, cz: number)
	local entries = cache.entries
	for lx = 0, SIZE - 1 do
		local x = cx * SIZE + lx
		for lz = 0, SIZE - 1 do
			local key = x * COLUMN_SPAN + cz * SIZE + lz
			if entries[key] ~= nil then
				entries[key] = nil
				cache.count -= 1
			end
		end
	end
end

--[[ Sound ]]

function Precipitation.newSound(): SoundState
	return { time = 0 }
end

--[[
	One client tick of Minecraft's tickRain sound (see the header) for a camera in cell (cx, cy,
	cz) whose column's rain floor is `cameraFloor`, at rain level `level` (0..1, already halved on
	Fast). `landing(x, z)` gives a column's rain floor and whether rain (not snow, not nothing)
	falls there (nil: unknown, skipped); `nextInt(n)` a random integer in [0, n). Returns the
	sound's event name and the cell it plays at, or nil.
]]
function Precipitation.rainSound(
	state: SoundState,
	cx: number,
	cy: number,
	cz: number,
	cameraFloor: number,
	level: number,
	landing: (x: number, z: number) -> (number?, boolean),
	nextInt: (n: number) -> number
): (string?, number, number, number)
	if level <= 0 then
		return nil, 0, 0, 0
	end
	local reach = Precipitation.SOUND_REACH
	local span = reach * 2 + 1
	local tries = math.floor(100 * level * level)
	local found = false
	local hx, hy, hz = 0, 0, 0
	for _ = 1, tries do
		local x, z = cx + nextInt(span) - reach, cz + nextInt(span) - reach
		local floor, rain = landing(x, z)
		if floor and rain and floor > 0 and floor <= cy + reach and floor >= cy - reach then
			-- (Minecraft's blockpos1: the block the drop lands on.)
			found, hx, hy, hz = true, x, floor - 1, z
		end
	end
	if not found then
		return nil, 0, 0, 0
	end
	-- (Minecraft: random.nextInt(3) < this.rainSoundTime++.)
	local time = state.time
	state.time = time + 1
	if nextInt(3) >= time then
		return nil, 0, 0, 0
	end
	state.time = 0
	if hy > cy + 1 and cameraFloor > cy then
		return "weather.rain.above", hx, hy, hz
	end
	return "weather.rain", hx, hy, hz
end

return Precipitation
