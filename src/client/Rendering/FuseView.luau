--!strict
--[[
	Lit TNT and lit Nukes flashing (BlockList LitTnt and LitNuke; lit, falling and going off on the
	server: Behaviours/Tnt). The terrain draws them as blocks that glow (their `light`); this module
	flashes them, as Minecraft's TntRenderer whitens a primed TNT every other 5 ticks
	((fuse / 5) % 2 == 0).

	  Look      a Neon box a little larger than the block (OVERSIZE), white over TNT and red over
	            a Nuke, shown FLASH_TICKS game ticks and hidden as long (`isFlashing`: from the
	            clock, so every lit block flashes in step). Anchored, never collides, takes no
	            queries or touches and casts no shadow: aiming goes by the voxel ray.
	  Which     lit blocks come only from edits: a chunk's are found in its edit list when it
	            loads (World/ClientWorld knownEdits) and followed through block changes (a falling
	            one moves cell by cell). Every REFRESH_INTERVAL the nearest MAX_DRAWN within RADIUS
	            blocks of the camera get a box (from a pool); the rest go without.
	  Origin    boxes are placed at render studs (Shared/World/Origin, from the block's doubles)
	            and move with the floating origin (a Rendering/Rebase mover, "fuses"); the camera
	            is read back into world blocks.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local ChunkLayout = require(Shared.World.ChunkLayout)
local Coords = require(Shared.World.Coords)
local Origin = require(Shared.World.Origin)

local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local Rebase = require(script.Parent.Rebase)

local BLOCK = Config.BlockSize
local SIZE = ChunkLayout.SIZE

--[[ Tunables ]]

-- Blocks from the camera within which lit blocks flash, and the most flashing at once.
local RADIUS = 64
local MAX_DRAWN = 48
-- Seconds between looks at which lit blocks are in range.
local REFRESH_INTERVAL = 0.25
-- Game ticks shown, then hidden (Minecraft's 5).
local FLASH_TICKS = 5
-- The box's size, in blocks, and how see-through it is while shown.
local OVERSIZE = 1.04
local SHOWN = 0.35

local FuseView = {}

-- The flash's colour over each lit block.
local COLOURS: { [number]: Color3 } = {
	[Blocks.id.LitTnt] = Color3.fromRGB(255, 255, 255),
	[Blocks.id.LitNuke] = Color3.fromRGB(255, 40, 30),
}

-- Is `block` a lit block this module flashes?
function FuseView.isLit(block: number?): boolean
	return block ~= nil and (COLOURS :: { [number]: any })[block] ~= nil
end

-- Is the flash shown at `seconds` (os.clock): FLASH_TICKS ticks on, as many off.
function FuseView.isFlashing(seconds: number): boolean
	return math.floor(seconds * 20 / FLASH_TICKS) % 2 == 0
end

type Record = { x: number, y: number, z: number, block: number, part: Part? }

local lit: { [number]: Record } = {}
local spare: { Part } = {}
local drawn: { [Record]: boolean } = {}
local folder: Folder? = nil
local shown = false

local function newPart(): Part
	local part = Instance.new("Part")
	part.Name = "Fuse"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.Material = Enum.Material.Neon
	part.Size = Vector3.one * OVERSIZE * BLOCK
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

local function undraw(record: Record)
	local part = record.part
	if part then
		record.part = nil
		drawn[record] = nil
		part.Parent = nil
		table.insert(spare, part)
	end
end

local function draw(record: Record)
	if record.part then
		return
	end
	local part = table.remove(spare) or newPart()
	part.Color = COLOURS[record.block]
	part.Transparency = if shown then SHOWN else 1
	part.CFrame =
		CFrame.new((record.x + 0.5) * BLOCK - Origin.x, (record.y + 0.5) * BLOCK, (record.z + 0.5) * BLOCK - Origin.z)
	part.Parent = folder
	record.part = part
	drawn[record] = true
end

local function add(x: number, y: number, z: number, block: number)
	local key = Coords.posKey(x, y, z)
	local old = lit[key]
	if old then
		undraw(old)
	end
	lit[key] = { x = x, y = y, z = z, block = block, part = nil }
end

local function remove(key: number)
	local record = lit[key]
	if record then
		undraw(record)
		lit[key] = nil
	end
end

local function onBlockChanged(x: number, y: number, z: number, block: number, previous: number, _predicted: boolean)
	if FuseView.isLit(block) then
		add(x, y, z, block)
		-- (A lit block moving into view flashes at once; a full refresh is a moment away.)
		local camera = workspace.CurrentCamera
		local record = lit[Coords.posKey(x, y, z)]
		if camera and record then
			local ex, ey, ez = Origin.renderToBlocks(camera.CFrame.Position)
			if Vector3.new(x + 0.5 - ex, y + 0.5 - ey, z + 0.5 - ez).Magnitude <= RADIUS then
				draw(record)
			end
		end
	elseif FuseView.isLit(previous) then
		remove(Coords.posKey(x, y, z))
	end
end

local function onChunkLoaded(world: ClientWorld.ClientWorld, cx: number, cz: number, loaded: boolean)
	for key, record in table.clone(lit) do
		if record.x // SIZE == cx and record.z // SIZE == cz then
			remove(key)
		end
	end
	if not loaded then
		return
	end
	local list = world:knownEdits(cx, cz)
	if list then
		for index, block in list do
			if FuseView.isLit(block) then
				local lx, y, lz = ChunkLayout.fromLocalIndex(index)
				local x, z = cx * SIZE + lx, cz * SIZE + lz
				if world:getBlock(x, y, z) == block then
					add(x, y, z, block)
				end
			end
		end
	end
end

-- The nearest MAX_DRAWN lit blocks within RADIUS get boxes, the rest give theirs back.
local function refresh()
	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end
	local ex, ey, ez = Origin.renderToBlocks(camera.CFrame.Position)
	local near: { { record: Record, distance: number } } = {}
	for _, record in lit do
		local d = Vector3.new(record.x + 0.5 - ex, record.y + 0.5 - ey, record.z + 0.5 - ez).Magnitude
		if d <= RADIUS then
			table.insert(near, { record = record, distance = d })
		end
	end
	table.sort(near, function(a, b)
		return a.distance < b.distance
	end)
	local wanted: { [Record]: boolean } = {}
	for i = 1, math.min(#near, MAX_DRAWN) do
		wanted[near[i].record] = true
	end
	for record in table.clone(drawn) do
		if not wanted[record] then
			undraw(record)
		end
	end
	for record in wanted do
		draw(record)
	end
end

-- Lit blocks known and flashing (F3, tests).
function FuseView.stats(): (number, number)
	local known, flashing = 0, 0
	for _ in lit do
		known += 1
	end
	for _ in drawn do
		flashing += 1
	end
	return known, flashing
end

-- Starts flashing `clientWorld`'s lit blocks.
function FuseView.start(clientWorld: ClientWorld.ClientWorld)
	assert(folder == nil, "FuseView.start was already called")
	local container = Instance.new("Folder")
	container.Name = "IceVoxelFuses"
	container.Parent = workspace
	folder = container

	clientWorld:onBlockChanged(onBlockChanged)
	clientWorld:onChunkLoaded(function(cx: number, cz: number, loaded: boolean)
		onChunkLoaded(clientWorld, cx, cz, loaded)
	end)
	for key in clientWorld.chunks do
		local cx, cz = Coords.decodeChunkKey(key)
		onChunkLoaded(clientWorld, cx, cz, true)
	end
	-- Drawn boxes move with the render origin.
	Rebase.register("fuses", function(dx: number, dz: number, parts: { BasePart }, cframes: { CFrame })
		local d = Vector3.new(dx, 0, dz)
		for record in drawn do
			local part = record.part
			if part then
				table.insert(parts, part)
				table.insert(cframes, part.CFrame - d)
			end
		end
	end)

	local nextRefresh = 0
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now >= nextRefresh then
			nextRefresh = now + REFRESH_INTERVAL
			refresh()
		end
		local flashing = FuseView.isFlashing(now)
		if flashing ~= shown then
			shown = flashing
			local transparency = if flashing then SHOWN else 1
			for record in drawn do
				local part = record.part
				if part then
					part.Transparency = transparency
				end
			end
		end
	end)
end

return FuseView
