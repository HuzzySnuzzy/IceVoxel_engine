--!strict
--[[
	Shows a square window of a MapLayer inside a GUI frame, centered on a world position.

	The layer is a ring buffer, so the window can wrap around its edges; up to four ImageLabels
	(all sharing the same image) show the pieces, positioned with Scale coordinates so there are no
	seams at any frame size. Also converts world block coordinates to shares of the frame for
	markers (`toFraction`: placed with UDim2.fromScale, they stay right under a UIScale, where the
	frame's AbsoluteSize is already scaled) and screen pixels back to world blocks for clicks
	(`toWorld`). The image is drawn Pixelated while each image pixel covers at least one screen
	pixel and smoothed below that (`setResample`: the minimap on a phone shows its 192 image pixels
	in about 84 screen pixels).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("IceVoxel").Config)

local MapLayer = require(script.Parent.MapLayer)

export type MapView = {
	frame: GuiObject,
	layer: MapLayer.MapLayer,
	-- Image pixels visible across the frame.
	pixels: number,
	labels: { ImageLabel },
	-- Top-left of the window in world pixels.
	u0: number,
	v0: number,

	setCenter: (self: MapView, centerX: number, centerZ: number) -> (),
	render: (self: MapView, centerX: number, centerZ: number) -> (),
	toFrame: (self: MapView, x: number, z: number) -> Vector2,
	toFraction: (self: MapView, x: number, z: number) -> (number, number),
	toWorld: (self: MapView, position: Vector2) -> (number, number),
	setResample: (self: MapView, screenPixels: number) -> (),
}

local MapView = {}
MapView.__index = MapView

-- `frame` should clip its descendants and be square.
function MapView.new(frame: GuiObject, layer: MapLayer.MapLayer, pixels: number): MapView
	-- A window of `pixels` touches at most (pixels + TileSize) / TileSize tiles; they must all have
	-- their own ring slot.
	assert(pixels + Config.Map.TileSize <= layer.size, "Map window too large for its layer")
	local labels: { ImageLabel } = {}
	for i = 1, 4 do
		local label = Instance.new("ImageLabel")
		label.Name = `Piece{i}`
		label.BackgroundTransparency = 1
		label.ResampleMode = Enum.ResamplerMode.Pixelated
		label.ScaleType = Enum.ScaleType.Stretch
		label.Visible = false
		if layer.content then
			label.ImageContent = layer.content :: Content
		end
		label.Parent = frame
		labels[i] = label
	end
	local self = { frame = frame, layer = layer, pixels = pixels, labels = labels, u0 = 0, v0 = 0 }
	return (setmetatable(self, MapView) :: any) :: MapView
end

-- Splits `length` pixels starting at ring position `start` into at most two runs.
local function split(start: number, length: number, size: number): { { number } }
	local first = math.min(length, size - start)
	if first >= length then
		return { { start, length, 0 } }
	end
	return { { start, first, 0 }, { 0, length - first, first } }
end

-- Moves the window (for toFrame / toWorld) without drawing; render does this too.
function MapView.setCenter(self: MapView, centerX: number, centerZ: number)
	local scale = self.layer.scale
	self.u0 = centerX / scale - self.pixels / 2
	self.v0 = centerZ / scale - self.pixels / 2
end

function MapView.render(self: MapView, centerX: number, centerZ: number)
	local layer = self.layer
	local pixels = self.pixels
	MapView.setCenter(self, centerX, centerZ)
	local u0, v0 = self.u0, self.v0

	local iu, iv = math.floor(u0), math.floor(v0)
	layer:request(iu, iv, iu + pixels + 1, iv + pixels + 1)
	if not layer.available then
		return
	end

	local fu, fv = u0 - iu, v0 - iv
	local size = layer.size
	local width = pixels + 1
	local used = 0
	for _, column in split(iu % size, width, size) do
		for _, row in split(iv % size, width, size) do
			used += 1
			local label = self.labels[used]
			label.ImageRectOffset = Vector2.new(column[1], row[1])
			label.ImageRectSize = Vector2.new(column[2], row[2])
			label.Position = UDim2.fromScale((column[3] - fu) / pixels, (row[3] - fv) / pixels)
			label.Size = UDim2.fromScale(column[2] / pixels, row[2] / pixels)
			label.Visible = true
		end
	end
	for i = used + 1, 4 do
		self.labels[i].Visible = false
	end
end

-- World block position -> screen pixel offset inside the frame (for the current window).
function MapView.toFrame(self: MapView, x: number, z: number): Vector2
	local size = self.frame.AbsoluteSize
	local u, v = MapView.toFraction(self, x, z)
	return Vector2.new(u * size.X, v * size.Y)
end

-- World block position -> its share of the frame across and down (0..1 inside the window).
function MapView.toFraction(self: MapView, x: number, z: number): (number, number)
	local scale = self.layer.scale
	return (x / scale - self.u0) / self.pixels, (z / scale - self.v0) / self.pixels
end

-- Pixelated while an image pixel covers at least one of the `screenPixels` across the frame.
function MapView.setResample(self: MapView, screenPixels: number)
	local mode = if screenPixels >= self.pixels then Enum.ResamplerMode.Pixelated else Enum.ResamplerMode.Default
	if self.labels[1].ResampleMode ~= mode then
		for _, label in self.labels do
			label.ResampleMode = mode
		end
	end
end

-- Screen pixel offset inside the frame -> world block position.
function MapView.toWorld(self: MapView, position: Vector2): (number, number)
	local size = self.frame.AbsoluteSize
	local scale = self.layer.scale
	return (self.u0 + position.X / size.X * self.pixels) * scale, (self.v0 + position.Y / size.Y * self.pixels) * scale
end

return MapView
