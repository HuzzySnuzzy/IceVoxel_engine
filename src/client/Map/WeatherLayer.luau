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
	            changed (an override), at most every REPAINT seconds.
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

-- Seconds between two paintings of one layer at least (dragging the world map).
local REPAINT = 0.15
-- Cells to spare around the view: panning that far keeps the picture.
local MARGIN = 4

export type Layer = {
	view: MapView.MapView,
	maxCells: number,
	image: EditableImage?,
	label: ImageLabel,
	cache: WeatherMap.Cache,
	-- The picture in the image now, and when the last was painted.
	shown: WeatherMap.Entry?,
	paintedAt: number,
	moment: Weather.Moment?,
	samples: buffer?,
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

-- Paints step `index`'s picture for the view now (or reuses a fresh one); nil when it can't.
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
	local key = WeatherMap.key(x0, z0, cell, count, count)
	local settings = Config.Weather.Map
	local fresh = WeatherMap.fresh(self.cache, step, key, now, settings.RefreshSeconds)
	if fresh or now - self.paintedAt < REPAINT then
		return fresh or self.shown
	end
	self.paintedAt = now
	local moment = WeatherState.momentIn(WeatherMap.STEPS[step], self.moment)
	self.moment = moment
	local samples = field:grid(moment, x0 + cell / 2, z0 + cell / 2, cell, count, count, self.samples)
	self.samples = samples
	local budget = settings.LookupsPerFrame
	local guessed = false
	local function formAt(x: number, z: number): string
		if WeatherState.knows(x, z) then
			return WeatherState.formAt(x, nil, z)
		elseif budget > 0 then
			budget -= 1
			return WeatherState.formAt(x, nil, z)
		end
		guessed = true
		return Weather.RAIN
	end
	-- (A buffer of its own a step, of the exact length WritePixelsBuffer wants.)
	local size = count * count * 4
	local old = self.cache.entries[step]
	local pixels = if old and buffer.len(old.pixels) == size then old.pixels else buffer.create(size)
	WeatherMap.paint(samples, x0, z0, cell, count, count, formAt, pixels)
	local entry: WeatherMap.Entry = {
		key = key,
		-- (Painted with guesses: again soon, with more columns known.)
		time = if guessed then now - settings.RefreshSeconds + 0.3 else now,
		pixels = pixels,
		x0 = x0,
		z0 = z0,
		cell = cell,
		cols = count,
		rows = count,
	}
	WeatherMap.put(self.cache, step, entry)
	self.shown = nil
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
		paintedAt = -math.huge,
		moment = nil,
		samples = nil,
	}
	local layer = (setmetatable(self, Layer) :: any) :: Layer
	-- An override or doWeatherCycle changes what is coming: paint again.
	WeatherState.changed:Connect(function()
		WeatherMap.clear(layer.cache)
		layer.paintedAt = -math.huge
	end)
	changedEvent.Event:Connect(function()
		layer.paintedAt = -math.huge
	end)
	return layer
end

return WeatherLayer
