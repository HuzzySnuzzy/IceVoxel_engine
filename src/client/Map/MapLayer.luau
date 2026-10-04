--!strict
--[[
	One map image: an EditableImage used as a ring buffer of painted tiles.

	World pixel (u, v) at `scale` blocks per pixel shows block column (u * scale, v * scale). Tile
	(tx, tz) covers world pixels [tx * TILE, tx * TILE + TILE) on each axis and is stored at ring slot
	(tx mod SLOTS, tz mod SLOTS). When the view moves, tiles entering it take over the slots of tiles
	that left it; their pixels are painted by the worker actors (Map/MapPainter) closest-first and
	written into the slot. Only one displayed EditableImage is re-uploaded per frame by Roblox, so
	one big image per map beats one image per tile.

	EditableImage is optional: creation throws when the API is not enabled for the experience and
	returns nil when the device memory budget is used up. `available` is false then, and the map UI
	only shows markers.
]]

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Coords = require(Shared.World.Coords)

local WorkerPool = require(script.Parent.Parent.Streaming.WorkerPool)

local TILE = Config.Map.TileSize
local MAX_IN_FLIGHT = 2
local BACKGROUND = 24 + 28 * 256 + 34 * 65536 + 255 * 16777216 -- RGBA (24, 28, 34, 255)

export type MapLayer = {
	available: boolean,
	image: EditableImage?,
	content: Content?,
	size: number,
	slots: number,
	scale: number,
	generation: number,
	-- Ring slot -> key of the tile assigned to it.
	assigned: { [number]: number },
	-- Slots waiting to be painted.
	pending: { [number]: boolean },
	inFlight: number,
	centerU: number,
	centerV: number,

	setScale: (self: MapLayer, scale: number) -> (),
	request: (self: MapLayer, u0: number, v0: number, u1: number, v1: number) -> (),
	step: (self: MapLayer, pool: WorkerPool.WorkerPool) -> (),
	destroy: (self: MapLayer) -> (),
}

local MapLayer = {}
MapLayer.__index = MapLayer

local blank = buffer.create(TILE * TILE * 4)
for i = 0, TILE * TILE - 1 do
	buffer.writeu32(blank, i * 4, BACKGROUND)
end

-- Creates an EditableImage, or nil when the API is unavailable or out of memory.
local function createImage(size: number): EditableImage?
	local ok, result = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(size, size) })
	end)
	if not ok then
		warn(`[IceVoxel] map disabled, EditableImage is not available: {result}`)
		return nil
	end
	if result == nil then
		warn("[IceVoxel] map disabled, the EditableImage memory budget is used up")
	end
	return result
end

-- `size` must be a multiple of Config.Map.TileSize.
function MapLayer.new(size: number, scale: number): MapLayer
	assert(size % TILE == 0, "Map image size must be a multiple of the tile size")
	local image = createImage(size)
	local self = {
		available = image ~= nil,
		image = image,
		content = if image then Content.fromObject(image) else nil,
		size = size,
		slots = size // TILE,
		scale = scale,
		generation = 0,
		assigned = {},
		pending = {},
		inFlight = 0,
		centerU = 0,
		centerV = 0,
	}
	if image then
		local fill = buffer.create(size * size * 4)
		for i = 0, size * size - 1 do
			buffer.writeu32(fill, i * 4, BACKGROUND)
		end
		image:WritePixelsBuffer(Vector2.zero, Vector2.new(size, size), fill)
	end
	return (setmetatable(self, MapLayer) :: any) :: MapLayer
end

-- Changes blocks per pixel; everything gets repainted.
function MapLayer.setScale(self: MapLayer, scale: number)
	if scale == self.scale then
		return
	end
	self.scale = scale
	self.generation += 1
	self.assigned = {}
	self.pending = {}
end

-- Makes sure every tile overlapping world pixels [u0, u1) x [v0, v1) is (being) painted.
function MapLayer.request(self: MapLayer, u0: number, v0: number, u1: number, v1: number)
	local image = self.image
	if image == nil then
		return
	end
	self.centerU, self.centerV = (u0 + u1) / 2, (v0 + v1) / 2
	local slots = self.slots
	for tz = v0 // TILE, (v1 - 1) // TILE do
		for tx = u0 // TILE, (u1 - 1) // TILE do
			local slot = (tz % slots) * slots + (tx % slots) + 1
			local key = Coords.chunkKey(tx, tz)
			if self.assigned[slot] ~= key then
				self.assigned[slot] = key
				self.pending[slot] = true
				image:WritePixelsBuffer(
					Vector2.new((tx % slots) * TILE, (tz % slots) * TILE),
					Vector2.new(TILE, TILE),
					blank
				)
			end
		end
	end
end

-- Sends the most central pending tiles to the workers and writes finished ones.
function MapLayer.step(self: MapLayer, pool: WorkerPool.WorkerPool)
	while self.inFlight < MAX_IN_FLIGHT do
		local best, bestDistance = nil, math.huge
		for slot in self.pending do
			local tx, tz = Coords.decodeChunkKey(self.assigned[slot])
			local du = (tx + 0.5) * TILE - self.centerU
			local dv = (tz + 0.5) * TILE - self.centerV
			local distance = du * du + dv * dv
			if distance < bestDistance then
				best, bestDistance = slot, distance
			end
		end
		if best == nil then
			return
		end

		local slot = best :: number
		local key = self.assigned[slot]
		local tx, tz = Coords.decodeChunkKey(key)
		local generation = self.generation
		local scale = self.scale
		local job = { kind = "map", x = tx * TILE * scale, z = tz * TILE * scale, scale = scale, size = TILE }
		local submitted = pool:submit(job, function(result)
			self.inFlight -= 1
			local image = self.image
			if image == nil or result.pixels == nil or generation ~= self.generation or self.assigned[slot] ~= key then
				return
			end
			local slots = self.slots
			image:WritePixelsBuffer(
				Vector2.new((tx % slots) * TILE, (tz % slots) * TILE),
				Vector2.new(TILE, TILE),
				result.pixels
			)
		end, true)
		if not submitted then
			return
		end
		self.pending[slot] = nil
		self.inFlight += 1
	end
end

function MapLayer.destroy(self: MapLayer)
	local image = self.image
	self.image = nil
	self.content = nil
	self.available = false
	if image then
		image:Destroy()
	end
end

return MapLayer
