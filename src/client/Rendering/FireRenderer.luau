--!strict
--[[
	Fire's flames (BlockList Fire; the shared rules and shapes in Shared/Fire). The terrain draws
	each fire as an invisible speck carrying its sparse light (ChunkRenderer, GreedyMesher: one
	PointLight per 8 x 8 x 8 blocks for fire and glow lichen together); this module draws the
	flames, which depend on the neighbours, within RADIUS blocks of the camera.

	  Shapes     Minecraft's (Fire.planes of Fire.sides: worked out from the client's blocks, as
	             Minecraft's getStateForPlacement would): on the floor, template_fire_floor's four
	             leaning planes, seen from both sides, and one box of the cell's size carrying the
	             flames of template_fire_side on its four outer faces; clinging to flammable walls
	             (and a ceiling), a plane on each, facing into the cell. 5 parts and 12 images a
	             fire on the floor, 1 part and 1 image a side clinging. Parts are thin (THICKNESS),
	             see-through (Transparency 1), never collide, never take queries, touches or audio
	             collisions and cast no shadow: aiming goes by the voxel ray (Fire.outlineAt).
	  Images     each face a SurfaceGui with one ImageLabel of the user's sheet (Fire.TEXTURE, 8
	             frames of 256 x 256 stacked vertically): ImageRectSize one frame, ImageRectOffset the
	             frame shown, Pixelated like Minecraft's 16 x 16 texture stretched over the plane. The
	             SurfaceGuis ignore the lighting (LightInfluence 0, Brightness BRIGHTNESS): fire
	             glows by night as by day, as Minecraft's fire is drawn at full brightness. Beyond
	             RADIUS blocks they stop drawing (MaxDistance) and the parts go back to the pool.
	  Animation  one shared step: every frame the frame index comes from the clock (Fire.frameAt,
	             FRAME_TICKS game ticks a frame); when it changes, one loop writes the new
	             ImageRectOffset into every live label (a dense list; no loop per fire, no tween).
	             About 10 steps a second; 100 fires on the floor are 1 200 writes a step.
	  Pooling    one template per kind of plane ("double", "front", "box"), its SurfaceGuis inside,
	             cloned once and reused: a fire going out returns its parts (at most MAX_SPARE
	             spare), a new one only resizes and moves them.
	  Which      fires come only from edits (never generated): a chunk's are found in its edit list
	             when its data is loaded (World/ClientWorld onChunkLoaded, knownEdits) and followed
	             through block changes (onBlockChanged), which also mark the fires next to a changed
	             block for a new look (a log burnt away under a fire). Every REFRESH_INTERVAL the
	             nearest MAX_FIRES within RADIUS whose chunk is shown (the streamer's) are drawn,
	             at most BUILDS_PER_FRAME (re)built a frame.

	Read-only queries: `firesNear` (Audio/Ambience's crackle) and `stats` (drawn fires, parts).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local ChunkLayout = require(Shared.World.ChunkLayout)
local Coords = require(Shared.World.Coords)
local Fire = require(Shared.Fire)

local ClientWorld = require(script.Parent.Parent.World.ClientWorld)

local BLOCK = Config.BlockSize
local PIXEL = BLOCK / 16
local SIZE = ChunkLayout.SIZE
local FIRE = Fire.BLOCK

--[[ Tunables ]]

-- Blocks from the camera within which flames are drawn, and the most fires drawn at once.
local RADIUS = 48
local MAX_FIRES = 192
-- Seconds between looks at which fires are in range.
local REFRESH_INTERVAL = 0.25
-- Fires (re)built per frame at most.
local BUILDS_PER_FRAME = 24
-- Spare parts kept for new fires.
local MAX_SPARE = 600
-- Plane thickness (studs), SurfaceGui resolution and brightness.
local THICKNESS = 0.05
local PIXELS_PER_STUD = 16
local BRIGHTNESS = 1.4
-- Faces carrying flames, by kind of plane (Shared/Fire `faces`).
local FACES: { [string]: { Enum.NormalId } } = {
	double = { Enum.NormalId.Front, Enum.NormalId.Back },
	front = { Enum.NormalId.Front },
	box = { Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right },
}

type Record = {
	x: number,
	y: number,
	z: number,
	key: number,
	chunk: number,
	-- Its parts while drawn, and the sides they show (nil: not drawn).
	parts: { BasePart }?,
	sides: number,
	-- Its neighbours changed since it was built.
	dirty: boolean,
	-- Drawn after the last refresh.
	wanted: boolean,
	distance: number,
}

local FireRenderer = {}

local world: ClientWorld.ClientWorld? = nil
local isShown: (cx: number, cz: number) -> boolean = function()
	return true
end
local folder: Folder? = nil

local fires: { [number]: Record } = {}
local byChunk: { [number]: { [number]: Record } } = {}
-- Fires waiting to be (re)built.
local queue: { Record } = {}
local queued: { [Record]: boolean } = {}
local drawn = 0

-- Every live label (a dense list, for the animation step) and where each is in it.
local labels: { ImageLabel } = {}
local labelIndex: { [ImageLabel]: number } = {}
local labelsOf: { [BasePart]: { ImageLabel } } = setmetatable({}, { __mode = "k" }) :: any
local kindOf: { [BasePart]: string } = setmetatable({}, { __mode = "k" }) :: any
local templates: { [string]: BasePart } = {}
local spare: { [string]: { BasePart } } = { double = {}, front = {}, box = {} }
local spareCount = 0
local partCount = 0
local frame = 0
local offset = Vector2.zero

--[[ Parts ]]

local function template(kind: string): BasePart
	local existing = templates[kind]
	if existing then
		return existing
	end
	local part = Instance.new("Part")
	part.Name = "Fire"
	part.Anchored = true
	part.Locked = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	pcall(function()
		part.AudioCanCollide = false
	end)
	for _, face in FACES[kind] do
		local gui = Instance.new("SurfaceGui")
		gui.Name = face.Name
		gui.Face = face
		gui.LightInfluence = 0
		gui.Brightness = BRIGHTNESS
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = PIXELS_PER_STUD
		gui.MaxDistance = RADIUS * BLOCK
		gui.ClipsDescendants = true
		local image = Instance.new("ImageLabel")
		image.Name = "Flames"
		image.BackgroundTransparency = 1
		image.BorderSizePixel = 0
		image.Size = UDim2.fromScale(1, 1)
		image.Image = Fire.TEXTURE
		image.ImageRectSize = Vector2.new(Fire.FRAME_PIXELS, Fire.FRAME_PIXELS)
		image.ScaleType = Enum.ScaleType.Stretch
		image.ResampleMode = Enum.ResamplerMode.Pixelated
		image.Parent = gui
		gui.Parent = part
	end
	templates[kind] = part
	return part
end

local function acquire(kind: string): BasePart
	local list = spare[kind]
	local part: BasePart
	if #list > 0 then
		part = table.remove(list) :: BasePart
		spareCount -= 1
	else
		part = template(kind):Clone()
		local found: { ImageLabel } = {}
		for _, child in part:GetDescendants() do
			if child:IsA("ImageLabel") then
				table.insert(found, child)
			end
		end
		labelsOf[part] = found
		kindOf[part] = kind
	end
	for _, label in labelsOf[part] do
		label.ImageRectOffset = offset
		table.insert(labels, label)
		labelIndex[label] = #labels
	end
	partCount += 1
	return part
end

local function release(part: BasePart)
	for _, label in labelsOf[part] do
		local index = labelIndex[label]
		if index then
			local last = labels[#labels]
			labels[index] = last
			labelIndex[last] = index
			labels[#labels] = nil
			labelIndex[label] = nil
		end
	end
	partCount -= 1
	part.Parent = nil
	if spareCount < MAX_SPARE then
		table.insert(spare[kindOf[part]], part)
		spareCount += 1
	else
		part:Destroy()
	end
end

local function undraw(record: Record)
	local parts = record.parts
	if parts then
		for _, part in parts do
			release(part)
		end
		record.parts = nil
		drawn -= 1
	end
end

local function getBlock(x: number, y: number, z: number): number?
	local w = world
	return if w then w:getBlock(x, y, z) else nil
end

-- (Re)draws a fire's flames from its sides now.
local function build(record: Record)
	local sides = Fire.sides(getBlock, record.x, record.y, record.z)
	record.dirty = false
	if record.parts and record.sides == sides then
		return
	end
	undraw(record)
	record.sides = sides
	local centre = Vector3.new(record.x + 0.5, record.y + 0.5, record.z + 0.5) * BLOCK
	local parts: { BasePart } = {}
	for _, plane in Fire.planes(sides) do
		local part = acquire(plane.faces)
		local depth = if plane.faces == "box" then plane.size[3] * PIXEL else THICKNESS
		part.Size = Vector3.new(plane.size[1] * PIXEL, plane.size[2] * PIXEL, depth)
		local o = plane.orientation
		part.CFrame = CFrame.new(centre + Vector3.new(plane.offset[1], plane.offset[2], plane.offset[3]) * PIXEL)
			* CFrame.fromOrientation(math.rad(o[1]), math.rad(o[2]), math.rad(o[3]))
		part.Parent = folder
		table.insert(parts, part)
	end
	record.parts = parts
	drawn += 1
end

local function enqueue(record: Record)
	if not queued[record] then
		queued[record] = true
		table.insert(queue, record)
	end
end

--[[ Following the world ]]

local function add(x: number, y: number, z: number)
	local key = Coords.posKey(x, y, z)
	local record = fires[key]
	if record then
		record.dirty = true
		if record.parts then
			enqueue(record)
		end
		return
	end
	local cx, cz = x // SIZE, z // SIZE
	local chunk = Coords.chunkKey(cx, cz)
	local new: Record = {
		x = x,
		y = y,
		z = z,
		key = key,
		chunk = chunk,
		parts = nil,
		sides = 0,
		dirty = true,
		wanted = false,
		distance = math.huge,
	}
	fires[key] = new
	local set = byChunk[chunk]
	if set == nil then
		set = {}
		byChunk[chunk] = set
	end
	set[key] = new
	-- (Drawn at once when the camera is near: a fire lit in front of the player shows.)
	local camera = workspace.CurrentCamera
	if camera then
		local eye = camera.CFrame.Position / BLOCK
		local d = (Vector3.new(x + 0.5, y + 0.5, z + 0.5) - eye).Magnitude
		if d <= RADIUS and drawn < MAX_FIRES and isShown(cx, cz) then
			new.wanted = true
			new.distance = d
			enqueue(new)
		end
	end
end

local function remove(key: number)
	local record = fires[key]
	if record == nil then
		return
	end
	undraw(record)
	fires[key] = nil
	queued[record] = nil
	local set = byChunk[record.chunk]
	if set then
		set[key] = nil
		if next(set) == nil then
			byChunk[record.chunk] = nil
		end
	end
end

-- The fires around (x, y, z) may look different now.
local function touch(x: number, y: number, z: number)
	for _, d in Fire.NEIGHBOURS do
		local record = fires[Coords.posKey(x + d[1], y + d[2], z + d[3])]
		if record then
			record.dirty = true
			if record.parts then
				enqueue(record)
			end
		end
	end
end

local function onBlockChanged(x: number, y: number, z: number, block: number, previous: number, _predicted: boolean)
	if block == FIRE then
		add(x, y, z)
	elseif previous == FIRE then
		remove(Coords.posKey(x, y, z))
	end
	touch(x, y, z)
end

local function onChunkLoaded(cx: number, cz: number, loaded: boolean)
	local chunk = Coords.chunkKey(cx, cz)
	local set = byChunk[chunk]
	if set then
		for key in table.clone(set) do
			remove(key)
		end
	end
	local w = world
	if loaded and w then
		local list = w:knownEdits(cx, cz)
		if list then
			for index, block in list do
				if block == FIRE then
					local lx, y, lz = ChunkLayout.fromLocalIndex(index)
					local x, z = cx * SIZE + lx, cz * SIZE + lz
					if w:getBlock(x, y, z) == FIRE then
						add(x, y, z)
					end
				end
			end
		end
	end
	-- (Fires on the border see other neighbours now.)
	for dx = -1, 1 do
		for dz = -1, 1 do
			local around = byChunk[Coords.chunkKey(cx + dx, cz + dz)]
			if around then
				for _, record in around do
					record.dirty = true
				end
			end
		end
	end
end

--[[ Every frame ]]

local function refresh()
	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end
	local eye = camera.CFrame.Position / BLOCK
	local near: { Record } = {}
	for _, record in fires do
		local d = (Vector3.new(record.x + 0.5, record.y + 0.5, record.z + 0.5) - eye).Magnitude
		record.distance = d
		record.wanted = false
		if d <= RADIUS and isShown(record.x // SIZE, record.z // SIZE) then
			table.insert(near, record)
		end
	end
	if #near > MAX_FIRES then
		table.sort(near, function(a, b)
			return a.distance < b.distance
		end)
	end
	for i = 1, math.min(#near, MAX_FIRES) do
		local record = near[i]
		record.wanted = true
		if record.parts == nil or record.dirty then
			enqueue(record)
		end
	end
	for _, record in fires do
		if not record.wanted and record.parts then
			undraw(record)
		end
	end
end

local function buildQueued()
	local built = 0
	while #queue > 0 and built < BUILDS_PER_FRAME do
		local record: Record = table.remove(queue, 1) :: any
		queued[record] = nil
		if fires[record.key] == record and record.wanted then
			build(record)
			built += 1
		end
	end
end

-- The animation step: every label to the frame of now, when it changed.
local function animate()
	local now = Fire.frameAt(os.clock())
	if now == frame then
		return
	end
	frame = now
	local _, y = Fire.rectOffset(now)
	offset = Vector2.new(0, y)
	local value = offset
	for i = 1, #labels do
		labels[i].ImageRectOffset = value
	end
end

--[[ Queries ]]

local nearList: { Record } = {}

--[[
	The fires the client knows within `range` blocks of (x, y, z) (blocks), drawn or not. The list
	is reused by the next call: read it at once, don't keep it.
]]
function FireRenderer.firesNear(x: number, y: number, z: number, range: number): { { x: number, y: number, z: number } }
	table.clear(nearList)
	local r2 = range * range
	for _, record in fires do
		local dx, dy, dz = record.x + 0.5 - x, record.y + 0.5 - y, record.z + 0.5 - z
		if dx * dx + dy * dy + dz * dz <= r2 then
			table.insert(nearList, record)
		end
	end
	return nearList :: any
end

-- Fires known, drawn, their parts and animated labels (F3, tests).
function FireRenderer.stats(): (number, number, number, number)
	local known = 0
	for _ in fires do
		known += 1
	end
	return known, drawn, partCount, #labels
end

--[[
	Starts drawing the flames of `clientWorld`'s fires. `shown(cx, cz)` (the streamer's): is the
	chunk on screen at full detail (flames never float over coarse terrain still being built).
]]
function FireRenderer.start(clientWorld: ClientWorld.ClientWorld, shown: ((cx: number, cz: number) -> boolean)?)
	assert(world == nil, "FireRenderer.start was already called")
	world = clientWorld
	if shown then
		isShown = shown
	end
	local container = Instance.new("Folder")
	container.Name = "IceVoxelFire"
	container.Parent = workspace
	folder = container

	clientWorld:onBlockChanged(onBlockChanged)
	clientWorld:onChunkLoaded(onChunkLoaded)
	for key in clientWorld.chunks do
		local cx, cz = Coords.decodeChunkKey(key)
		onChunkLoaded(cx, cz, true)
	end

	local nextRefresh = 0
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now >= nextRefresh then
			nextRefresh = now + REFRESH_INTERVAL
			refresh()
		end
		buildQueued()
		animate()
	end)
end

return FireRenderer
