--!strict
--[[
	Mobs on the client (the server's Mobs messages, server Mobs/Mobs): each mob is a couple of
	plain boxes, as Shared/Entities/MobList draws it: its body in its kind's colour (a sheep's in
	its fleece's) and a head on the side it faces, so which way it looks reads from afar.

	  Parts     anchored Parts that collide with, touch and are queried by nothing (SmoothPlastic,
	            casting shadows), at most 2 a mob, kept in a pool when mobs go so a new one reuses
	            them; all of them move with one BulkMoveTo a frame, after the camera.
	  Motion    Entities/MobModel: a glide between the server's updates (10 a second), the facing
	            turning the short way; dying, the mob tips over on its side.
	  Looks     the hurt flash reddens every part, a creeper's lit fuse flashes it white (faster as
	            it burns), a burning mob carries flames (a Fire on its body, BurningView's colours,
	            sized to the box). Colours are written only when they change.
	  Arrows    a skeleton's arrow is a thin shaft flying from the bow to where it struck at
	            ARROW_SPEED (Minecraft's 1.6 blocks a tick), then gone; at most MAX_ARROWS fly.
	  Knockback a zombie's or spider's hit (and an arrow's) comes as a `push` the hull adds to its
	            velocity (Player/MovementController.knockback, as an explosion's).
	The server only sends the mobs within Config.Mobs.TrackingDistance (64 blocks) of the player;
	the parts go when it says they left.

	`mobsNear` and `pick` let other modules (Ui/Waila, Interaction/BlockInteraction) see where the
	mobs are drawn, read only.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local MobList = require(Shared.Entities.MobList)
local Protocol = require(Shared.Net.Protocol)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local MovementController = require(script.Parent.Parent.Player.MovementController)
local MobModel = require(script.Parent.MobModel)

local BLOCK = Config.BlockSize
-- After the camera, as the items.
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1
-- Arrows: blocks a second, their shaft (blocks), how many fly at once.
local ARROW_SPEED = 32
local ARROW_LENGTH = 0.5
local ARROW_WIDTH = 0.06
local MAX_ARROWS = 32
local ARROW_COLOUR = Color3.fromRGB(110, 84, 56)
-- Spare parts kept for new mobs.
local MAX_SPARE = 128
-- Flames (BurningView's colours): Fire.Size per block of the box's height.
local FLAME_COLOUR = Color3.fromRGB(255, 140, 30)
local FLAME_GLOW = Color3.fromRGB(255, 220, 90)
local FLAME_SIZE = 3

type Entry = {
	model: MobModel.Mob,
	parts: { BasePart },
	-- The colours last written to each part (packed 0xRRGGBB).
	colours: { number },
	fire: Fire?,
}

type Arrow = { part: BasePart, from: Vector3, to: Vector3, startedAt: number, duration: number }

local MobRenderer = {}

local entries: { [number]: Entry } = {}
local models: { [number]: MobModel.Mob } = {}
local count = 0
local spare: { BasePart } = {}
local arrows: { Arrow } = {}
local folder: Folder? = nil

local function newPart(): BasePart
	local part = table.remove(spare)
	if part then
		return part
	end
	local fresh = Instance.new("Part")
	fresh.Name = "Mob"
	fresh.Anchored = true
	fresh.CanCollide = false
	fresh.CanQuery = false
	fresh.CanTouch = false
	fresh.CastShadow = true
	fresh.Locked = true
	fresh.Material = Enum.Material.SmoothPlastic
	fresh.TopSurface = Enum.SurfaceType.Smooth
	fresh.BottomSurface = Enum.SurfaceType.Smooth
	return fresh
end

local function release(part: BasePart)
	part.Parent = nil
	if #spare < MAX_SPARE then
		table.insert(spare, part)
	else
		part:Destroy()
	end
end

local function remove(id: number)
	local entry = entries[id]
	if entry == nil then
		return
	end
	entries[id] = nil
	models[id] = nil
	count -= 1
	if entry.fire then
		entry.fire:Destroy()
	end
	for _, part in entry.parts do
		release(part)
	end
end

local function spawn(op: any, now: number)
	local kind = MobList.get(op.kind)
	if kind == nil then
		return
	end
	remove(op.id)
	local model = MobModel.new(op.id, kind, op.variant, op, now)
	local parts = {}
	for _, box in kind.parts do
		local part = newPart()
		part.Size = Vector3.new(box.size[1], box.size[2], box.size[3]) * BLOCK
		part.Parent = folder
		table.insert(parts, part)
	end
	entries[op.id] = { model = model, parts = parts, colours = table.create(#parts, -1), fire = nil }
	models[op.id] = model
	count += 1
end

local function packed(r: number, g: number, b: number): number
	return bit32.bor(bit32.lshift(math.round(r), 16), bit32.lshift(math.round(g), 8), math.round(b))
end

-- Flames on a burning mob's body (BurningView's look), none otherwise.
local function updateFire(entry: Entry)
	local burning = MobModel.burning(entry.model)
	local fire = entry.fire
	if burning and fire == nil then
		local flames = Instance.new("Fire")
		flames.Color = FLAME_COLOUR
		flames.SecondaryColor = FLAME_GLOW
		flames.Heat = 9
		flames.Size = math.max(2, entry.model.kind.height * FLAME_SIZE)
		flames.Parent = entry.parts[1]
		entry.fire = flames
	elseif not burning and fire then
		fire:Destroy()
		entry.fire = nil
	end
end

local function shoot(op: any, now: number)
	if #arrows >= MAX_ARROWS then
		local oldest = table.remove(arrows, 1) :: Arrow
		release(oldest.part)
	end
	local from = Vector3.new(op.x, op.y, op.z)
	local to = Vector3.new(op.tx, op.ty, op.tz)
	local part = newPart()
	part.CastShadow = false
	part.Size = Vector3.new(ARROW_WIDTH, ARROW_WIDTH, ARROW_LENGTH) * BLOCK
	part.Color = ARROW_COLOUR
	part.Parent = folder
	table.insert(arrows, {
		part = part,
		from = from,
		to = to,
		startedAt = now,
		duration = math.max((to - from).Magnitude / ARROW_SPEED, 0.05),
	})
end

local function onMessage(payload: buffer)
	local ops = Protocol.decodeMobs(payload, MobList.COUNT)
	if ops == nil then
		return
	end
	local now = os.clock()
	for _, op in ops do
		if op.op == "spawn" then
			spawn(op, now)
		elseif op.op == "state" then
			local entry = entries[op.id]
			if entry then
				MobModel.apply(entry.model, op, now)
				updateFire(entry)
			end
		elseif op.op == "remove" then
			remove(op.id)
		elseif op.op == "arrow" then
			shoot(op, now)
		elseif op.op == "push" then
			MovementController.knockback(op.kx, op.ky, op.kz)
		end
	end
end

local moved: { BasePart } = {}
local cframes: { CFrame } = {}

local function draw()
	local now = os.clock()
	table.clear(moved)
	table.clear(cframes)
	for _, entry in entries do
		local model = entry.model
		local x, y, z, yaw = MobModel.pose(model, now)
		local base = CFrame.new(x * BLOCK, y * BLOCK, z * BLOCK) * CFrame.Angles(0, yaw, 0)
		local tip = MobModel.tip(model, now)
		if tip > 0 then
			-- (On its side: about the facing, around the bottom of its box.)
			local half = model.kind.width / 2 * BLOCK
			base = base * CFrame.new(half, 0, 0) * CFrame.Angles(0, 0, -tip) * CFrame.new(-half, 0, 0)
		end
		for index, part in entry.parts do
			local box = model.kind.parts[index]
			table.insert(moved, part)
			table.insert(
				cframes,
				base * CFrame.new(box.offset[1] * BLOCK, box.offset[2] * BLOCK, box.offset[3] * BLOCK)
			)
			local r, g, b = MobModel.colour(model, index, now)
			local colour = packed(r, g, b)
			if entry.colours[index] ~= colour then
				entry.colours[index] = colour
				part.Color = Color3.fromRGB(r, g, b)
			end
		end
	end
	for i = #arrows, 1, -1 do
		local arrow = arrows[i]
		local alpha = (now - arrow.startedAt) / arrow.duration
		if alpha >= 1 then
			table.remove(arrows, i)
			release(arrow.part)
		else
			local at = arrow.from:Lerp(arrow.to, alpha) * BLOCK
			table.insert(moved, arrow.part)
			table.insert(cframes, CFrame.lookAt(at, arrow.to * BLOCK))
		end
	end
	if #moved > 0 then
		workspace:BulkMoveTo(moved, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- Starts drawing the mobs the server sends.
function MobRenderer.start(_world: ClientWorld.ClientWorld)
	local container = Instance.new("Folder")
	container.Name = "IceVoxelMobs"
	container.Parent = workspace
	folder = container
	ClientNet.on(Protocol.ServerMessage.Mobs, onMessage)
	RunService:BindToRenderStep("IceVoxelMobs", RENDER_PRIORITY, draw)
end

-- Number of mobs the client knows (for the debug overlay).
function MobRenderer.count(): number
	return count
end

-- A mob as other modules see it: id, kind (MobList), where it is drawn (blocks: its feet), its
-- box, health (half hearts) and colour variant.
export type MobView = {
	id: number,
	kind: MobList.Kind,
	variant: number,
	health: number,
	x: number,
	y: number,
	z: number,
}

local function view(model: MobModel.Mob, now: number): MobView
	local x, y, z = MobModel.pose(model, now)
	return { id = model.id, kind = model.kind, variant = model.variant, health = model.health, x = x, y = y, z = z }
end

-- The live mobs within `radius` blocks of (x, y, z) (copies: changing them changes nothing).
function MobRenderer.mobsNear(x: number, y: number, z: number, radius: number): { MobView }
	local now = os.clock()
	local found = {}
	for _, model in models do
		if model.diedAt == nil then
			local mob = view(model, now)
			local dx, dy, dz = mob.x - x, mob.y - y, mob.z - z
			if dx * dx + dy * dy + dz * dz <= radius * radius then
				table.insert(found, mob)
			end
		end
	end
	return found
end

-- The nearest live mob on the ray from `origin` along the unit `direction` (blocks) within
-- `maxDistance`, and how far along the ray it is.
function MobRenderer.pick(origin: Vector3, direction: Vector3, maxDistance: number): (MobView?, number)
	local now = os.clock()
	local model, distance =
		MobModel.pick(models, now, origin.X, origin.Y, origin.Z, direction.X, direction.Y, direction.Z, maxDistance)
	if model == nil then
		return nil, maxDistance
	end
	return view(model, now), distance
end

return MobRenderer
