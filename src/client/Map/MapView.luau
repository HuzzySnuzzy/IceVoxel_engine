--!strict
--[[
	Shows a square window of a MapLayer inside a GUI frame, centered on a world position.

	The layer is a ring buffer, so the window can wrap around its edges; up to four ImageLabels
	(all sharing the same image) show the pieces, positioned with Scale coordinates so there are no
	seams at any frame size. Also converts between world block coordinates and frame pixels for
	markers and clicks.
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

	render: (self: MapView, centerX: number, centerZ: number) -> (),
	toFrame: (self: MapView, x: number, z: number) -> Vector2,
	toWorld: (self: MapView, position: Vector2) -> (number, number),
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

function MapView.render(self: MapView, centerX: number, centerZ: number)
	local layer = self.layer
	local scale = layer.scale
	local pixels = self.pixels
	local u0 = centerX / scale - pixels / 2
	local v0 = centerZ / scale - pixels / 2
	self.u0, self.v0 = u0, v0

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

-- World block position -> pixel offset inside the frame (as of the last render).
function MapView.toFrame(self: MapView, x: number, z: number): Vector2
	local size = self.frame.AbsoluteSize
	local scale = self.layer.scale
	return Vector2.new((x / scale - self.u0) / self.pixels * size.X, (z / scale - self.v0) / self.pixels * size.Y)
end

-- Pixel offset inside the frame -> world block position.
function MapView.toWorld(self: MapView, position: Vector2): (number, number)
	local size = self.frame.AbsoluteSize
	local scale = self.layer.scale
	return (self.u0 + position.X / size.X * self.pixels) * scale, (self.v0 + position.Y / size.Y * self.pixels) * scale
end

return MapView
