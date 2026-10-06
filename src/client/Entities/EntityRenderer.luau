--!strict
--[[
	Dropped items on the client, drawn the way Minecraft draws them (ItemEntityRenderer).

	  Simulation  The server only sends where an item is now and then (Entities), so every item runs
	              the same physics as on the server (Shared/Entities/ItemPhysics) at 20 ticks per
	              second against the client's blocks. Server syncs replace the state; the visible
	              jump that would cause is kept as an offset that halves every tick (or snapped
	              when it is more than SNAP_DISTANCE blocks). Items are drawn interpolated between
	              the last two ticks.
	  Look        a block item is a small cube (0.25 blocks), other items are 0.5 blocks. The
	              model floats 0.25 blocks above the item's position, bobs
	              sin(age / 10 + bobOffset) * 0.1 + 0.1 blocks and spins age / 20 + bobOffset
	              radians (bobOffset is random per item). Stacks show more copies: 2 for more than
	              1 item, 3 above 16, 4 above 32, 5 above 48. Copies of a block are scattered by
	              up to 0.15 blocks (the same way for every stack of that item); flat items stack
	              up front to back.
	  Pickup      a collected item flies to the collector's waist (halfway up to the eyes) over 3
	              ticks, accelerating (ItemPickupParticle), then disappears. Removed items that
	              nobody collected (despawned, merged, out of range) disappear at once.

	The models (ItemModels: anchored, nothing collides, touches or is queried) live in a Folder in
	the workspace and are moved together with one BulkMoveTo per frame, after the camera. When item
	looks change (ItemModels.generation: the Textures setting, texture averages measured) items
	build their copies again, LOOK_REBUILDS_PER_FRAME items a frame.
	`itemsNear` lists the items around a point, read only (WAILA aims at them, Ui/Waila).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Protocol = require(Shared.Net.Protocol)
local Rig = require(Shared.Movement.Rig)
local ItemPhysics = require(Shared.Entities.ItemPhysics)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local ItemModels = require(script.Parent.Parent.Rendering.ItemModels)

local BLOCK = Config.BlockSize
local TICK = 1 / ItemPhysics.TICK_RATE
-- Ticks run at most per frame (a long hitch does not fast-forward the items).
local MAX_TICKS_PER_FRAME = 5
-- After the camera, so a collected item flies to where the character is drawn this frame.
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1

-- Corrections from the server bigger than this (blocks) jump instead of easing.
local SNAP_DISTANCE = 4
-- Share of the correction offset left after each tick.
local CORRECTION_DECAY = 0.5
-- Model sizes (blocks) and how high the model's centre floats above the item's position.
local BLOCK_ITEM_SIZE = 0.25
local FLAT_ITEM_SIZE = 0.5
local FLOAT_HEIGHT = 0.25
-- Scatter of a block stack's extra copies, and the step and jitter of flat items' copies (blocks).
local BLOCK_SCATTER = 0.15
local FLAT_STEP = 0.09375 * 0.5
local FLAT_JITTER = 0.15 * 0.5
-- Items whose copies are built again per frame after a change of item looks.
local LOOK_REBUILDS_PER_FRAME = 16
-- The pickup flight: ticks, and where it ends above the collector's feet (blocks).
local PICKUP_TICKS = 3
local PICKUP_HEIGHT = 1.62 / 2

type Copy = {
	model: Model,
	-- Offset of this copy from the item's centre, and of each part from the copy's pivot.
	offset: CFrame,
	parts: { BasePart },
	partOffsets: { CFrame },
}

type Item = {
	id: number,
	item: number,
	count: number,
	body: ItemPhysics.Body,
	-- Position at the previous tick and the correction offsets now and at the previous tick (blocks).
	prevX: number,
	prevY: number,
	prevZ: number,
	errX: number,
	errY: number,
	errZ: number,
	prevErrX: number,
	prevErrY: number,
	prevErrZ: number,
	-- Ticks lived as far as the animation is concerned (it keeps going while the physics is frozen).
	age: number,
	bobOffset: number,
	model: Model,
	copies: { Copy },
	-- The item look generation its copies were built with (ItemModels.generation).
	look: number,
}

-- What a spawn op carries (Protocol.EntityOp).
type SpawnOp = {
	id: number,
	item: number,
	count: number,
	x: number,
	y: number,
	z: number,
	vx: number,
	vy: number,
	vz: number,
	age: number,
}

type Flight = {
	item: Item,
	-- Where the item was (blocks) and the model's offset from there (studs, bob and spin frozen).
	from: Vector3,
	pose: CFrame,
	character: Model,
	life: number,
}

local EntityRenderer = {}

local items: { [number]: Item } = {}
local itemCount = 0
local flights: { Flight } = {}
local folder: Folder? = nil
local random = Random.new()

-- Copies drawn for a stack of `count` (ItemEntityRenderer.getRenderAmount).
local function renderAmount(count: number): number
	if count > 48 then
		return 5
	elseif count > 32 then
		return 4
	elseif count > 16 then
		return 3
	elseif count > 1 then
		return 2
	end
	return 1
end

-- Offsets (studs) of an item's copies from its centre. The scatter is seeded by the item, as in
-- Minecraft, so every stack of an item looks the same.
local function copyOffsets(item: number, amount: number): { CFrame }
	local seeded = Random.new(item)
	local offsets = table.create(amount)
	if ItemModels.isBlock(item) then
		for k = 1, amount do
			if k == 1 then
				offsets[k] = CFrame.identity
			else
				local x = seeded:NextNumber(-1, 1) * BLOCK_SCATTER
				local y = seeded:NextNumber(-1, 1) * BLOCK_SCATTER
				local z = seeded:NextNumber(-1, 1) * BLOCK_SCATTER
				offsets[k] = CFrame.new(x * BLOCK, y * BLOCK, z * BLOCK)
			end
		end
	else
		local z = -FLAT_STEP * (amount - 1) / 2
		for k = 1, amount do
			local x, y = 0, 0
			if k > 1 then
				x = seeded:NextNumber(-1, 1) * FLAT_JITTER
				y = seeded:NextNumber(-1, 1) * FLAT_JITTER
			end
			offsets[k] = CFrame.new(x * BLOCK, y * BLOCK, z * BLOCK)
			z += FLAT_STEP
		end
	end
	return offsets
end

local function buildCopies(entity: Item)
	for _, copy in entity.copies do
		copy.model:Destroy()
	end
	entity.look = ItemModels.generation()
	local amount = renderAmount(entity.count)
	local size = (if ItemModels.isBlock(entity.item) then BLOCK_ITEM_SIZE else FLAT_ITEM_SIZE) * BLOCK
	local copies = table.create(amount)
	for k, offset in copyOffsets(entity.item, amount) do
		local model = ItemModels.build(entity.item, size)
		local parts, partOffsets = {}, {}
		-- Built around CFrame.identity, so each part's CFrame is its offset from the pivot.
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then
				table.insert(parts, part)
				table.insert(partOffsets, part.CFrame)
			end
		end
		model.Name = `Copy{k}`
		model.Parent = entity.model
		copies[k] = { model = model, offset = offset, parts = parts, partOffsets = partOffsets }
	end
	entity.copies = copies
end

local function destroy(entity: Item)
	entity.model:Destroy()
end

local function spawn(op: SpawnOp)
	local old = items[op.id]
	if old then
		destroy(old)
		itemCount -= 1
	end
	local model = Instance.new("Model")
	model.Name = `Item{op.id}`
	local body = ItemPhysics.new(op.x, op.y, op.z, op.vx, op.vy, op.vz)
	body.age = op.age
	local entity: Item = {
		id = op.id,
		item = op.item,
		count = op.count,
		body = body,
		prevX = op.x,
		prevY = op.y,
		prevZ = op.z,
		errX = 0,
		errY = 0,
		errZ = 0,
		prevErrX = 0,
		prevErrY = 0,
		prevErrZ = 0,
		age = op.age,
		bobOffset = random:NextNumber() * math.pi * 2,
		model = model,
		copies = {},
		look = 0,
	}
	buildCopies(entity)
	model.Parent = folder
	items[op.id] = entity
	itemCount += 1
end

-- The server's state replaces ours; the jump is eased away (or snapped when it is far).
local function sync(entity: Item, x: number, y: number, z: number, vx: number, vy: number, vz: number)
	local body = entity.body
	local dx, dy, dz = body.x - x, body.y - y, body.z - z
	if dx * dx + dy * dy + dz * dz > SNAP_DISTANCE * SNAP_DISTANCE then
		entity.errX, entity.errY, entity.errZ = 0, 0, 0
		entity.prevErrX, entity.prevErrY, entity.prevErrZ = 0, 0, 0
		entity.prevX, entity.prevY, entity.prevZ = x, y, z
	else
		entity.errX += dx
		entity.errY += dy
		entity.errZ += dz
		entity.prevErrX += dx
		entity.prevErrY += dy
		entity.prevErrZ += dz
		entity.prevX -= dx
		entity.prevY -= dy
		entity.prevZ -= dz
	end
	body.x, body.y, body.z = x, y, z
	body.vx, body.vy, body.vz = vx, vy, vz
	-- Let the next tick find the ground again (a stale "on the ground" would hold it still).
	body.onGround = false
end

-- Model pose (studs) of an item `alpha` of the way from its last tick to the next.
local function pose(entity: Item, alpha: number): (Vector3, CFrame)
	local body = entity.body
	local x = entity.prevX + entity.prevErrX + (body.x + entity.errX - entity.prevX - entity.prevErrX) * alpha
	local y = entity.prevY + entity.prevErrY + (body.y + entity.errY - entity.prevY - entity.prevErrY) * alpha
	local z = entity.prevZ + entity.prevErrZ + (body.z + entity.errZ - entity.prevZ - entity.prevErrZ) * alpha
	local age = entity.age + alpha
	local bob = math.sin(age / 10 + entity.bobOffset) * 0.1 + 0.1
	local spin = age / 20 + entity.bobOffset
	return Vector3.new(x, y, z), CFrame.new(0, (FLOAT_HEIGHT + bob) * BLOCK, 0) * CFrame.Angles(0, spin, 0)
end

local function remove(entity: Item, collector: number, alpha: number)
	items[entity.id] = nil
	itemCount -= 1
	local player = if collector ~= 0 then Players:GetPlayerByUserId(collector) else nil
	local character = player and player.Character
	if character then
		local from, offset = pose(entity, alpha)
		table.insert(flights, { item = entity, from = from, pose = offset, character = character, life = 0 })
	else
		destroy(entity)
	end
end

-- A partial pickup: `count` of the item fly to the collector while the rest stays.
local function take(entity: Item, count: number, collector: number, alpha: number)
	local player = if collector ~= 0 then Players:GetPlayerByUserId(collector) else nil
	local character = player and player.Character
	if character == nil then
		return
	end
	local from, offset = pose(entity, alpha)
	local taken: Item = table.clone(entity)
	taken.count = count
	taken.model = Instance.new("Model")
	taken.model.Name = `Taken{entity.id}`
	taken.copies = {}
	buildCopies(taken)
	taken.model.Parent = folder
	table.insert(flights, { item = taken, from = from, pose = offset, character = character, life = 0 })
end

local function tick(getBlock: ItemPhysics.GetBlock)
	for _, entity in items do
		local body = entity.body
		entity.prevX, entity.prevY, entity.prevZ = body.x, body.y, body.z
		entity.prevErrX, entity.prevErrY, entity.prevErrZ = entity.errX, entity.errY, entity.errZ
		entity.errX *= CORRECTION_DECAY
		entity.errY *= CORRECTION_DECAY
		entity.errZ *= CORRECTION_DECAY
		entity.age += 1
		ItemPhysics.tick(body, entity.id, getBlock)
	end
	for i = #flights, 1, -1 do
		local flight = flights[i]
		flight.life += 1
		if flight.life >= PICKUP_TICKS then
			destroy(flight.item)
			table.remove(flights, i)
		end
	end
end

-- Builds again the copies of up to LOOK_REBUILDS_PER_FRAME items of an older item look (flights
-- end within a few ticks and keep theirs).
local function refreshLooks()
	local look = ItemModels.generation()
	local budget = LOOK_REBUILDS_PER_FRAME
	for _, entity in items do
		if entity.look ~= look then
			if budget == 0 then
				return
			end
			budget -= 1
			buildCopies(entity)
		end
	end
end

local parts: { BasePart } = {}
local cframes: { CFrame } = {}

local function place(entity: Item, base: CFrame)
	for _, copy in entity.copies do
		local at = base * copy.offset
		for i, part in copy.parts do
			table.insert(parts, part)
			table.insert(cframes, at * copy.partOffsets[i])
		end
	end
end

local function draw(alpha: number)
	table.clear(parts)
	table.clear(cframes)
	for _, entity in items do
		local position, offset = pose(entity, alpha)
		place(entity, CFrame.new(position * BLOCK) * offset)
	end
	for _, flight in flights do
		local f = math.min((flight.life + alpha) / PICKUP_TICKS, 1)
		f *= f
		local target = flight.from
		local feet = Rig.feet(flight.character)
		if feet then
			target = feet + Vector3.new(0, PICKUP_HEIGHT, 0)
		end
		local position = flight.from:Lerp(target, f)
		place(flight.item, CFrame.new(position * BLOCK) * flight.pose)
	end
	if #parts > 0 then
		workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- Starts drawing the items the server sends, simulated against `world`'s blocks.
function EntityRenderer.start(world: ClientWorld.ClientWorld)
	local container = Instance.new("Folder")
	container.Name = "IceVoxelItems"
	container.Parent = workspace
	folder = container

	local function getBlock(x: number, y: number, z: number): number?
		return world:getBlock(x, y, z)
	end

	local accumulator = 0
	ClientNet.on(Protocol.ServerMessage.Entities, function(payload)
		local alpha = accumulator / TICK
		for _, op in Protocol.decodeEntities(payload) do
			if op.op == "spawn" then
				spawn(op)
			elseif op.op == "sync" then
				local entity = items[op.id]
				if entity then
					sync(entity, op.x, op.y, op.z, op.vx, op.vy, op.vz)
				end
			elseif op.op == "count" then
				local entity = items[op.id]
				if entity and entity.count ~= op.count then
					local rebuild = renderAmount(entity.count) ~= renderAmount(op.count)
					entity.count = op.count
					if rebuild then
						buildCopies(entity)
					end
				end
			elseif op.op == "remove" then
				local entity = items[op.id]
				if entity then
					remove(entity, op.collector, alpha)
				end
			elseif op.op == "take" then
				local entity = items[op.id]
				if entity then
					take(entity, op.count, op.collector, alpha)
				end
			end
		end
	end)

	RunService:BindToRenderStep("IceVoxelItems", RENDER_PRIORITY, function(dt: number)
		accumulator += dt
		local ticks = 0
		while accumulator >= TICK do
			accumulator -= TICK
			ticks += 1
			if ticks <= MAX_TICKS_PER_FRAME then
				tick(getBlock)
			end
		end
		refreshLooks()
		draw(accumulator / TICK)
	end)
end

-- Number of dropped items the client knows (for the debug overlay).
function EntityRenderer.count(): number
	return itemCount
end

-- A dropped item as other modules see it: its entity id, stack and where it is drawn (blocks,
-- the bottom centre of its box, without the bobbing).
export type ItemView = { id: number, item: number, count: number, x: number, y: number, z: number }

--[[
	The dropped items within `radius` blocks of (x, y, z) (blocks), e.g. for WAILA (Ui/Waila). A new
	list of copies each call: changing it changes nothing. Items flying to a collector are left out.
]]
function EntityRenderer.itemsNear(x: number, y: number, z: number, radius: number): { ItemView }
	local found: { ItemView } = {}
	local limit = radius * radius
	for _, entity in items do
		local body = entity.body
		local ix, iy, iz = body.x + entity.errX, body.y + entity.errY, body.z + entity.errZ
		local dx, dy, dz = ix - x, iy - y, iz - z
		if dx * dx + dy * dy + dz * dz <= limit then
			table.insert(found, { id = entity.id, item = entity.item, count = entity.count, x = ix, y = iy, z = iz })
		end
	end
	return found
end

return EntityRenderer
