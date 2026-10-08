--!strict
--[[
	The maps' weather mode (Roblox glue over Map/WeatherMap): precipitation, snow, thunder and
	clouds drawn over the minimap's and the world map's terrain, the wind, and forecasts.

	  Mode      one switch for both maps (`toggle`: the Weather Map key binding, B by default,
	            the minimap's and the world map's cloud buttons) and one forecast step
	            (`setStep`: WeatherMap.STEPS, now to +20 minutes, the world map's buttons); the
	            minimap shows the chosen step too. `changed` fires when either changes.
	  Picture   each map has a layer (`new`): a small EditableImage (`maxCells` square, Config.
	            Weather.Map MiniCells / WorldCells) shown in an ImageLabel over the map's terrain
	            and under its markers, stretched over the grid it was painted for (smoothed, so
	            the coarse cells read as weather fronts). The weather is sampled with
	            Shared/Weather's grid at the step's moment (Weather/WeatherState.momentIn: the
	            override as it will be then), painted (WeatherMap.paint; snow or rain by each
	            cell's biome and ground height, Weather/WeatherState.formAt, at most
	            Map.LookupsPerFrame new columns a frame, rain until a column is known) and kept
	            per step (WeatherMap's cache): it is painted again when the map panned past the
	            grid's margin, zoomed, after Map.RefreshSeconds, or when the server's weather
	            changed (an override).
	  Spread    a picture is painted a band of rows a frame (at most Map.CellsPerFrame cells, and
	            as many rows as Map.FrameMs holds at what the last band cost a cell: WeatherMap
	            .bandRows; the new columns' lookups stop at that time too), into a buffer of its
	            own, at the moment it started; until it is done the map keeps the last picture
	            (placed on its own grid, so it stays right while the map pans). A picture is always
	            finished, then the next is started for wherever the map is then. With native code
	            (Lune) the world map's 96 x 96 costs ~7 ms in all; run interpreted (a phone) about
	            3 times that, so it takes more frames, never more of a frame.
	  Off       without EditableImage access nothing is drawn; the wind and the step still show.
]]

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Weather = require(Shared.Weather)

local MapView = require(script.Parent.MapView)
local WeatherMap = require(script.Parent.WeatherMap)
local WeatherState = require(script.Parent.Parent.Weather.WeatherState)

-- Cells to spare around the view: panning that far keeps the picture.
local MARGIN = 4

-- A picture being painted, a band of rows a frame.
type Job = {
	step: number,
	key: string,
	x0: number,
	z0: number,
	cell: number,
	count: number,
	moment: Weather.Moment,
	-- Rows painted so far, and whether any cell's form was guessed.
	row: number,
	guessed: boolean,
	pixels: buffer,
}

export type Layer = {
	view: MapView.MapView,
	maxCells: number,
	image: EditableImage?,
	label: ImageLabel,
	cache: WeatherMap.Cache,
	-- The picture in the image now.
	shown: WeatherMap.Entry?,
	job: Job?,
	-- A buffer to paint the next picture into (the one a finished picture replaced).
	spare: buffer?,
	moment: Weather.Moment?,
	band: buffer?,
	-- The grid last asked for and its key (made again only when the grid changes).
	grid: { x0: number, z0: number, cell: number, count: number },
	gridKey: string,
	-- Seconds a cell of the last band took (0: none painted yet).
	perCell: number,
	update: (self: Layer) -> (),
}

local WeatherLayer = {}

local on = false
local step = 1
local changedEvent = Instance.new("BindableEvent")
-- Fires when the mode or the forecast step changes.
WeatherLayer.changed = changedEvent.Event

-- Is the maps' weather mode on?
function WeatherLayer.isOn(): boolean
	return on
end

-- Turns the weather mode on or off on both maps.
function WeatherLayer.toggle()
	on = not on
	changedEvent:Fire()
end

-- The forecast step (index into WeatherMap.STEPS).
function WeatherLayer.step(): number
	return step
end

function WeatherLayer.setStep(index: number)
	index = math.clamp(math.floor(index), 1, #WeatherMap.STEPS)
	if index ~= step then
		step = index
		changedEvent:Fire()
	end
end

local captionMoment: Weather.Moment? = nil

-- The step's label ("Now", "+5 min") and the wind then ("1.3 b/s NE"), with its arrow's turn.
function WeatherLayer.caption(): (string, string, number)
	local moment = WeatherState.momentIn(WeatherMap.STEPS[step], captionMoment)
	captionMoment = moment
	local vx, vz = WeatherState.wind(moment)
	local _, angle = WeatherMap.wind(vx, vz)
	return WeatherMap.LABELS[step], WeatherMap.windText(vx, vz), angle
end

local function createImage(size: number): EditableImage?
	local ok, result = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(size, size) })
	end)
	if not ok then
		warn(`[IceVoxel] weather map disabled, EditableImage is not available: {result}`)
		return nil
	end
	return result
end

local Layer = {}
Layer.__index = Layer

-- Starts painting step `index`'s picture for grid (x0, z0, cell, count) named `key`.
local function begin(self: Layer, index: number, key: string, x0: number, z0: number, cell: number, count: number): Job
	local size = count * count * 4
	local spare = self.spare
	local pixels = if spare and buffer.len(spare) == size then spare else buffer.create(size)
	self.spare = nil
	local moment = WeatherState.momentIn(WeatherMap.STEPS[index], self.moment)
	self.moment = moment
	return {
		step = index,
		key = key,
		x0 = x0,
		z0 = z0,
		cell = cell,
		count = count,
		moment = moment,
		row = 0,
		guessed = false,
		pixels = pixels,
	}
end

-- Paints the next band of `job`'s rows (see Spread). Returns whether it is done.
local function advance(self: Layer, job: Job, field: Weather.Field): boolean
	local settings = Config.Weather.Map
	local started = os.clock()
	local seconds = settings.FrameMs / 1000
	local deadline = started + seconds
	local count, cell = job.count, job.cell
	local rows = WeatherMap.bandRows(count, count - job.row, settings.CellsPerFrame, seconds, self.perCell)
	local z0 = job.z0 + job.row * cell
	local band = field:grid(job.moment, job.x0 + cell / 2, z0 + cell / 2, cell, count, rows, self.band)
	self.band = band
	local budget = settings.LookupsPerFrame
	local function formAt(x: number, z: number): string
		if WeatherState.knows(x, z) then
			return WeatherState.formAt(x, nil, z)
		elseif budget > 0 and os.clock() < deadline then
			budget -= 1
			return WeatherState.formAt(x, nil, z)
		end
		job.guessed = true
		return Weather.RAIN
	end
	WeatherMap.paint(band, job.x0, z0, cell, count, rows, formAt, job.pixels, job.row * count)
	job.row += rows
	self.perCell = (os.clock() - started) / (rows * count)
	return job.row >= count
end

-- Step `step`'s picture for the view now when one is fresh, else the best there is while the next
-- is painted (nil when there is none).
local function picture(self: Layer, now: number): WeatherMap.Entry?
	local field = WeatherState.field()
	if field == nil then
		return nil
	end
	local view = self.view
	local blocks = view.pixels * view.layer.scale
	local centreX = (view.u0 + view.pixels / 2) * view.layer.scale
	local centreZ = (view.v0 + view.pixels / 2) * view.layer.scale
	local cell = WeatherMap.cellFor(blocks, self.maxCells, MARGIN)
	local x0, z0, count = WeatherMap.grid(centreX, centreZ, blocks, cell, MARGIN)
	local grid = self.grid
	if grid.x0 ~= x0 or grid.z0 ~= z0 or grid.cell ~= cell or grid.count ~= count then
		grid.x0, grid.z0, grid.cell, grid.count = x0, z0, cell, count
		self.gridKey = WeatherMap.key(x0, z0, cell, count, count)
	end
	local key = self.gridKey
	local settings = Config.Weather.Map
	local fresh = WeatherMap.fresh(self.cache, step, key, now, settings.RefreshSeconds)
	if fresh then
		self.job = nil
		return fresh
	end
	local job = self.job
	if job == nil or job.step ~= step then
		job = begin(self, step, key, x0, z0, cell, count)
		self.job = job
	end
	local current = job :: Job
	if not advance(self, current, field) then
		return self.cache.entries[step] or self.shown
	end
	self.job = nil
	local entry: WeatherMap.Entry = {
		key = current.key,
		-- (Painted with guesses: again soon, with more columns known.)
		time = if current.guessed then now - settings.RefreshSeconds + 0.3 else now,
		pixels = current.pixels,
		x0 = current.x0,
		z0 = current.z0,
		cell = current.cell,
		cols = current.count,
		rows = current.count,
	}
	local old = self.cache.entries[current.step]
	if old and old ~= self.shown then
		self.spare = old.pixels
	end
	WeatherMap.put(self.cache, current.step, entry)
	return entry
end

function Layer.update(self: Layer)
	local label = self.label
	local image = self.image
	if not on or image == nil or not WeatherState.enabled() then
		label.Visible = false
		return
	end
	local entry = picture(self, os.clock())
	if entry == nil then
		label.Visible = false
		return
	end
	if self.shown ~= entry then
		-- (The picture shown before can be painted over next: the image has its own copy.)
		local before = self.shown
		if before and self.spare == nil and buffer.len(before.pixels) == buffer.len(entry.pixels) then
			local kept = self.cache.entries
			local cached = false
			for _, other in kept do
				if other == before then
					cached = true
				end
			end
			if not cached then
				self.spare = before.pixels
			end
		end
		self.shown = entry
		image:WritePixelsBuffer(Vector2.zero, Vector2.new(entry.cols, entry.rows), entry.pixels)
		label.ImageRectOffset = Vector2.zero
		label.ImageRectSize = Vector2.new(entry.cols, entry.rows)
	end
	local view = self.view
	local p0 = view:toFrame(entry.x0, entry.z0)
	local p1 = view:toFrame(entry.x0 + entry.cols * entry.cell, entry.z0 + entry.rows * entry.cell)
	label.Position = UDim2.fromOffset(p0.X, p0.Y)
	label.Size = UDim2.fromOffset(p1.X - p0.X, p1.Y - p0.Y)
	label.Visible = true
end

--[[
	A weather layer over `view` (its frame clips it), at most `maxCells` cells square, its label at
	`zIndex` (over the terrain's pieces, under the markers).
]]
function WeatherLayer.new(view: MapView.MapView, maxCells: number, zIndex: number): Layer
	local image = createImage(maxCells)
	local label = Instance.new("ImageLabel")
	label.Name = "Weather"
	label.BackgroundTransparency = 1
	label.ScaleType = Enum.ScaleType.Stretch
	label.ResampleMode = Enum.ResamplerMode.Default
	label.ZIndex = zIndex
	label.Visible = false
	if image then
		label.ImageContent = Content.fromObject(image)
	end
	label.Parent = view.frame
	local self = {
		view = view,
		maxCells = maxCells,
		image = image,
		label = label,
		cache = WeatherMap.newCache(),
		shown = nil,
		job = nil,
		spare = nil,
		moment = nil,
		band = nil,
		grid = { x0 = math.huge, z0 = math.huge, cell = 0, count = 0 },
		gridKey = "",
		perCell = 0,
	}
	local layer = (setmetatable(self, Layer) :: any) :: Layer
	-- An override or doWeatherCycle changes what is coming: paint again.
	WeatherState.changed:Connect(function()
		WeatherMap.clear(layer.cache)
		layer.job = nil
	end)
	return layer
end

return WeatherLayer
