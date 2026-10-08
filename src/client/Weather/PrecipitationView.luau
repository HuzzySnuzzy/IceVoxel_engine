--!strict
--[[
	Rain and snow around the camera, and the rain's sound (Roblox glue over Weather/Precipitation's
	rules: Minecraft's renderSnowAndRain and tickRain).

	  Strips    one Beam a block column within the Weather setting's radius (Fast 5: 69 beams,
	            Fancy 10: 305; Off: none), each between two Attachments of one invisible anchored
	            part ("IceVoxelWeather" in workspace) that sits at the camera's cell. A beam faces
	            the camera (FaceCamera: Minecraft turns its rain quads towards the camera too) and
	            spans the column's Precipitation.span, a little off the column's centre (a fixed
	            hash), its image (Config.Weather.Precipitation Rain / Snow: Texture tiled every
	            Length blocks, scrolling Speed tiles a second; Width, Color) for the column's form
	            (rain or snow by its biome and landing height; nothing in dry biomes), its
	            transparency the alpha step of the intensity at the camera times Minecraft's edge
	            fade (one NumberSequence per form and step, made once; fading in at the top).
	  Updates   the anchor moves when the camera enters another cell; then, and when a column's
	            roof is learned or changes, every strip is laid out again, writing only what
	            differs from its last values (so a still camera in steady rain writes nothing).
	            Roofs (Precipitation.floorOf) are scanned from the loaded chunk data, at most
	            Config.Weather.Precipitation.ScansPerFrame columns a frame, nearest first; an
	            unknown column shows nothing until scanned. Edits and chunk loads keep the cache
	            right (ClientWorld's onBlockChanged / onChunkLoaded).
	  Sound     20 times a second, Precipitation.rainSound (Minecraft's tickRain: weather.rain or
	            weather.rain.above where rain lands within 10 blocks, every 2-3 ticks) through
	            Audio/SoundPlayer, its volume and pitch from Shared/Weather.rainSound (a cue of
	            Minecraft's 0.2 is played at RAIN_GAIN x that). It plays whatever the Weather
	            setting (Minecraft's sounds don't depend on the graphics; Fast halves the level it
	            tries columns with, as Minecraft's does): the columns it tries are queued for a
	            roof scan as the strips' are, so Off (no strips) and Fast (5 blocks of them) still
	            hear rain landing anywhere within 10. `roofed` tells Weather/StormView whether the
	            camera is under a roof (the distant rain's hiss is quieter and duller there).

	Cost: on a cell change ~300 strips are checked (Fancy), with property writes only where a
	strip changed; the roofs' scans run once per column until an edit, and only while something
	falls at the camera (in clear weather the strips are hidden and nothing is looked up).
	Nothing is allocated per frame but the scan queue's entries.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Coords = require(Shared.World.Coords)
local Hash = require(Shared.Util.Hash)
local Weather = require(Shared.Weather)

local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local Precipitation = require(script.Parent.Precipitation)
local WeatherState = require(script.Parent.WeatherState)

local BLOCK = Config.BlockSize
local SIZE = Config.ChunkSize
local LEVELS = Precipitation.LEVELS
-- The cue volume for Minecraft's volume 0.2 (weather.rain at full rain): half a full sound.
local RAIN_GAIN = 0.5 / 0.2
local TICK = 1 / 20
-- Kinds of strip.
local NONE, RAIN, SNOW = 0, 1, 2

type Strip = {
	beam: Beam,
	top: Attachment,
	bottom: Attachment,
	-- What it shows now (to write only changes).
	kind: number,
	level: number,
	low: number,
	high: number,
	x: number,
	z: number,
}

local PrecipitationView = {}

local mode = Precipitation.FANCY
local world: ClientWorld.ClientWorld? = nil
local cache = Precipitation.newCache()
local strips: { Strip } = {}
local columns: { Precipitation.Column } = {}
local anchor: Part? = nil
-- The camera's cell the strips are laid out for, and whether they must be laid out again.
local cellX, cellY, cellZ = math.huge, math.huge, math.huge
local layoutDirty = true
-- Columns waiting for a roof scan (keys), in the order asked.
local queue: { number } = {}
local queued: { [number]: boolean } = {}
-- Transparency sequences by kind and alpha step.
local sequences: { [number]: { NumberSequence } } = {}
-- The intensity's alpha step at the last layout.
local lastStep = -1
local sound = Precipitation.newSound()
local random = Random.new()
local soundClock = 0
local lut: buffer? = nil

local function nextInt(n: number): number
	return random:NextInteger(0, n - 1)
end

local function look(kind: number)
	local settings = Config.Weather.Precipitation
	return if kind == SNOW then settings.Snow else settings.Rain
end

-- The beam's transparency along it (top to bottom) for `kind` at alpha step `level`.
local function sequence(kind: number, level: number): NumberSequence
	local list = sequences[kind]
	if list == nil then
		list = table.create(LEVELS)
		local base = look(kind).Transparency
		for step = 1, LEVELS do
			local opaque = (1 - base) * step / LEVELS
			list[step] = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.15, 1 - opaque),
				NumberSequenceKeypoint.new(1, 1 - opaque),
			})
		end
		sequences[kind] = list
	end
	return (list :: { NumberSequence })[level]
end

local function newStrip(parent: Part): Strip
	local top = Instance.new("Attachment")
	top.Name = "Top"
	top.Parent = parent
	local bottom = Instance.new("Attachment")
	bottom.Name = "Bottom"
	bottom.Parent = parent
	local beam = Instance.new("Beam")
	beam.Attachment0 = top
	beam.Attachment1 = bottom
	beam.FaceCamera = true
	beam.Segments = 1
	beam.LightInfluence = 1
	beam.LightEmission = 0
	beam.TextureMode = Enum.TextureMode.Wrap
	beam.Enabled = false
	beam.Parent = parent
	return { beam = beam, top = top, bottom = bottom, kind = NONE, level = 0, low = 0, high = 0, x = 0, z = 0 }
end

local function setKind(strip: Strip, kind: number)
	local settings = look(kind)
	local beam = strip.beam
	beam.Texture = settings.Texture
	beam.TextureLength = settings.Length * BLOCK
	beam.TextureSpeed = settings.Speed
	beam.Width0 = settings.Width * BLOCK
	beam.Width1 = settings.Width * BLOCK
	beam.Color = ColorSequence.new(Color3.fromRGB(settings.Color[1], settings.Color[2], settings.Color[3]))
	strip.kind = kind
	strip.level = -1
end

local function hide(strip: Strip)
	if strip.beam.Enabled then
		strip.beam.Enabled = false
	end
	strip.level = 0
end

-- The rain floor and temperature of column (x, z) when known (scanning it is queued otherwise).
local function entryOf(x: number, z: number): Precipitation.Entry?
	local entry = Precipitation.cached(cache, x, z)
	if entry == nil then
		local key = Precipitation.key(x, z)
		if not queued[key] then
			queued[key] = true
			table.insert(queue, key)
		end
	end
	return entry
end

-- Scans up to the frame's budget of queued columns. Returns whether any was learned.
local function scan(): boolean
	local blocks = world
	if blocks == nil or #queue == 0 then
		return false
	end
	local stops = lut :: buffer
	local budget = Config.Weather.Precipitation.ScansPerFrame
	local learned = false
	local index = 1
	while index <= #queue and budget > 0 do
		local key = queue[index]
		local x, z = Precipitation.unkey(key)
		local cx, cz = x // SIZE, z // SIZE
		local chunk = blocks.chunks[Coords.chunkKey(cx, cz)]
		-- Columns of chunks not loaded stay queued (until a chunk loads; see `start`).
		if chunk then
			budget -= 1
			local floor = Precipitation.floorOf(chunk.data, chunk.height, x - cx * SIZE, z - cz * SIZE, stops)
			local temperature = WeatherState.temperatureAt(x, z)
			Precipitation.store(cache, x, z, floor, temperature)
			queued[key] = nil
			queue[index] = queue[#queue]
			queue[#queue] = nil
			learned = true
		else
			index += 1
		end
	end
	return learned
end

-- Lays every strip out for the camera's cell (writing only what changed).
local function layout(intensity: number)
	local part = anchor :: Part
	local radius = Config.Weather.Precipitation.Radius[mode] or 0
	-- (Nothing falls here: no strip, and no roof is looked up.)
	local count = if Precipitation.level(intensity, 1) == 0 then 0 else #columns
	for i = 1, #strips do
		local strip = strips[i]
		if i > count then
			hide(strip)
			continue
		end
		local column = columns[i]
		local x, z = cellX + column.dx, cellZ + column.dz
		local entry = entryOf(x, z)
		if entry == nil then
			hide(strip)
			continue
		end
		local low, high = Precipitation.span(entry.floor, cellY, radius)
		local form = Weather.formAt(entry.temperature, x, entry.floor, z)
		local kind = if form == Weather.SNOW then SNOW elseif form == Weather.RAIN then RAIN else NONE
		local level = Precipitation.level(intensity, column.edge)
		if low == nil or kind == NONE or level == 0 then
			hide(strip)
			continue
		end
		if strip.kind ~= kind then
			setKind(strip, kind)
		end
		if strip.low ~= low or strip.high ~= high or strip.x ~= x or strip.z ~= z then
			-- (A fixed offset in the column, so the streaks don't stand in rows.)
			local jitter = Hash.hash2(7, x, z)
			local ox = 0.2 + (jitter % 1024) / 1024 * 0.6
			local oz = 0.2 + (jitter // 1024 % 1024) / 1024 * 0.6
			strip.top.Position =
				Vector3.new((column.dx + ox) * BLOCK, ((high :: number) - cellY) * BLOCK, (column.dz + oz) * BLOCK)
			strip.bottom.Position =
				Vector3.new((column.dx + ox) * BLOCK, (low - cellY) * BLOCK, (column.dz + oz) * BLOCK)
			strip.low, strip.high, strip.x, strip.z = low, high :: number, x, z
		end
		if strip.level ~= level then
			strip.beam.Transparency = sequence(kind, level)
			strip.level = level
		end
		if not strip.beam.Enabled then
			strip.beam.Enabled = true
		end
	end
	part.CFrame = CFrame.new(cellX * BLOCK, cellY * BLOCK, cellZ * BLOCK)
end

-- The rain floor of column (x, z) and whether rain falls there (for the sound; nil: unknown, its
-- scan queued: the sound's 10 blocks are learned whatever the Weather setting draws).
local function landing(x: number, z: number): (number?, boolean)
	local entry = entryOf(x, z)
	if entry == nil then
		return nil, false
	end
	return entry.floor, Weather.formAt(entry.temperature, x, entry.floor, z) == Weather.RAIN
end

local function tickSound()
	local intensity = WeatherState.intensity
	if intensity <= 0 or not SoundPlayer.isEnabled() then
		return
	end
	local x, y, z = WeatherState.cameraX, WeatherState.cameraY, WeatherState.cameraZ
	local own = Precipitation.cached(cache, x, z)
	local level = if mode == Precipitation.FANCY then intensity else intensity / 2
	local name, hx, hy, hz =
		Precipitation.rainSound(sound, x, y, z, if own then own.floor else 0, level, landing, nextInt)
	if name then
		local volume, pitch = Weather.rainSound(WeatherState.precipitation, name == "weather.rain.above")
		if volume > 0 then
			SoundPlayer.play(name, hx + 0.5, hy + 1, hz + 0.5, volume * RAIN_GAIN, pitch)
		end
	end
end

local function step(dt: number)
	local part = anchor
	if part == nil then
		return
	end
	local learned = scan()
	local intensity = if WeatherState.enabled() then WeatherState.intensity else 0
	local x, y, z = WeatherState.cameraX, WeatherState.cameraY, WeatherState.cameraZ
	if x ~= cellX or y ~= cellY or z ~= cellZ then
		cellX, cellY, cellZ = x, y, z
		layoutDirty = true
		-- (Columns far behind are of no use any more: ask for the new disc's, nearest first.)
		table.clear(queue)
		table.clear(queued)
	end
	if learned then
		layoutDirty = true
	end
	-- The alpha steps only change when the intensity crosses one.
	local stepNow = math.floor(intensity * LEVELS + 0.5)
	if stepNow ~= lastStep then
		lastStep = stepNow
		layoutDirty = true
	end
	if layoutDirty then
		layoutDirty = false
		layout(intensity)
	end
	soundClock += dt
	if soundClock >= TICK then
		soundClock = math.min(soundClock - TICK, TICK)
		tickSound()
	end
end

-- The Weather setting (Precipitation.OFF / FAST / FANCY): how many strips.
function PrecipitationView.setMode(value: number)
	mode = math.clamp(math.floor(value), Precipitation.OFF, Precipitation.FANCY)
	local radius = Config.Weather.Precipitation.Radius[mode]
	columns = if radius then Precipitation.columns(radius) else {}
	local part = anchor
	if part then
		while #strips < #columns do
			table.insert(strips, newStrip(part))
		end
	end
	layoutDirty = true
end

--[[
	Whether a block that stops rain is over the camera: its column's rain floor is above the
	camera's cell (as tickRain's weather.rain.above asks). False while that column is not known
	(its scan is queued, and learned within a frame or two).
]]
function PrecipitationView.roofed(): boolean
	if world == nil then
		return false
	end
	local entry = entryOf(WeatherState.cameraX, WeatherState.cameraZ)
	return entry ~= nil and entry.floor > WeatherState.cameraY
end

-- Strips drawn now and in all (F3).
function PrecipitationView.stats(): (number, number)
	local shown = 0
	for i = 1, #columns do
		local strip = strips[i]
		if strip and strip.beam.Enabled then
			shown += 1
		end
	end
	return shown, #columns
end

-- Starts drawing rain and snow from `blocks`' loaded chunk data.
function PrecipitationView.start(blocks: ClientWorld.ClientWorld)
	world = blocks
	lut = Precipitation.stops()
	local folder = Instance.new("Folder")
	folder.Name = "IceVoxelWeather"
	local part = Instance.new("Part")
	part.Name = "Precipitation"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.one
	part.Parent = folder
	pcall(function()
		(part :: any).AudioCanCollide = false
	end)
	folder.Parent = workspace
	anchor = part
	PrecipitationView.setMode(mode)
	blocks:onBlockChanged(function(x: number, y: number, z: number, block: number)
		if Precipitation.edited(cache, x, y, z, block) then
			layoutDirty = true
		end
	end)
	blocks:onChunkLoaded(function(cx: number, cz: number)
		Precipitation.dropChunk(cache, cx, cz)
		layoutDirty = true
	end)
	RunService.Heartbeat:Connect(step)
end

return PrecipitationView
