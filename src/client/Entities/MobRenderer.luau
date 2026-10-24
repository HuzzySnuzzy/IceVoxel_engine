--!strict
--[[
	Mobs on the client (the server's Mobs messages, server Mobs/Mobs). Cows, sheep, pigs and
	chickens are a couple of plain boxes, as Shared/Entities/MobList draws them: the body in the
	kind's colour (a sheep's in its fleece's) and a head on the side it faces. Zombies are Roblox
	R15 bodies posed in code (Entities/MobRig), dressed in their look (Entities/ZombieLooks):
	full rigs near the player, reduced ones further out, the two boxes beyond
	(Entities/MobRigPool, Config.Mobs.Rig).

	  Parts     anchored Parts that collide with, touch and are queried by nothing (SmoothPlastic;
	            shadows only from a rig's head and torso and from the boxes), kept in pools when
	            mobs go or change tier so new ones reuse them (MobRigPool); all of them move with
	            one BulkMoveTo a frame, after the camera (Entities/MobParts, the same code the
	            Studio probe tools/probes/ZombieRigProbe times).
	  Motion    Entities/MobModel: a glide between the server's updates (10 a second; the move op's
	            deltas add up exactly), the facing turning the short way, the zombies' stride and
	            flag blends; dying, the mob tips over on its side.
	  Looks     a zombie's colours are worked out once at its spawn; the hurt flash reddens every
	            part (a rig once as it starts and once as it ends); a burning mob carries flames (a
	            Fire on its body, its rig's upper torso or reduced torso, BurningView's colours).
	  Voices    zombies groan now and then (Entities/ZombieVoices picks who: the nearest 8 within
	            reach, one at a time every 1.5 s), played here at the zombie through
	            Audio/SoundPlayer (`entity.zombie.ambient`; the server sends no event).
	  Knockback a zombie's hit comes as a `push` the hull adds to its velocity
	            (Player/MovementController.knockback, as an explosion's).
	The server only sends the mobs within Config.Mobs.TrackingDistance (64 blocks) of the player;
	the parts go when it says they left. Its messages are taken from the moment this module loads
	(see `start`), so none is lost while the client boots.

	`mobsNear` and `pick` let other modules (Ui/Waila, Interaction/BlockInteraction) see where the
	mobs are drawn, read only, and `aimPoint` where a turret's gun points at one (Rendering/
	TurretView).

	The floating origin (Shared/World/Origin): mobs stay in world blocks (doubles) and
	are placed every frame at render studs (world studs minus the origin, after the origin's render
	step), so a move of the origin needs nothing here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Ballistics = require(Shared.Weapons.Ballistics)
local MobList = require(Shared.Entities.MobList)
local Protocol = require(Shared.Net.Protocol)
local Origin = require(Shared.World.Origin)
local Sounds = require(Shared.Sounds)

local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local MovementController = require(script.Parent.Parent.Player.MovementController)
local MobModel = require(script.Parent.MobModel)
local MobParts = require(script.Parent.MobParts)
local MobRigPool = require(script.Parent.MobRigPool)
local ZombieVoices = require(script.Parent.ZombieVoices)

-- After the camera, as the items.
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1
-- The zombies' groan, and how far one is worth picking (its event's reach, at most RADIUS).
local AMBIENT = "entity.zombie.ambient"
local ambientEvent = Sounds.get(AMBIENT)
local VOICE_REACH = math.min(ZombieVoices.RADIUS, if ambientEvent then ambientEvent.maxDistance else math.huge)

local MobRenderer = {}

local models: { [number]: MobModel.Mob } = {}
local fires: { [number]: Fire } = {}
local count = 0
-- (Made as the module loads, kept out of the workspace until `start`: mobs the server sends while
-- the client boots are built in it, unseen.)
local folder = Instance.new("Folder")
folder.Name = "IceVoxelMobs"

local pool = MobRigPool.new(MobParts.factory(folder))
local voices = ZombieVoices.new()

local function remove(id: number)
	if models[id] == nil then
		return
	end
	models[id] = nil
	count -= 1
	local fire = fires[id]
	MobRigPool.remove(pool, id)
	if fire then
		fire:Destroy()
		fires[id] = nil
	end
	ZombieVoices.forget(voices, id)
end

local function spawn(op: any, now: number)
	local kind = MobList.get(op.kind)
	if kind == nil then
		return
	end
	remove(op.id)
	local model = MobModel.new(op.id, kind, op.variant, op, now)
	models[op.id] = model
	MobRigPool.add(pool, model)
	count += 1
end

-- Flames on a burning mob's body (BurningView's look), none otherwise; MobRigPool keeps them on
-- the part its current tier burns on (and off any part it lets go).
local function updateFire(model: MobModel.Mob)
	local burning = MobModel.burning(model)
	local fire: Fire? = fires[model.id]
	if burning and fire == nil then
		local flames = MobParts.flames(model.kind.height)
		fires[model.id] = flames
		MobRigPool.setFlames(pool, model.id, flames)
	elseif not burning and fire then
		MobRigPool.setFlames(pool, model.id, nil)
		fire:Destroy()
		fires[model.id] = nil
	end
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
			local model = models[op.id]
			if model then
				updateFire(model)
			end
		elseif op.op == "move" then
			local model = models[op.id]
			if model then
				MobModel.move(model, op.dx, op.dy, op.dz, op.yaw, op.health, op.flags, now)
				updateFire(model)
			end
		elseif op.op == "state" then
			local model = models[op.id]
			if model then
				MobModel.apply(model, op, now)
				updateFire(model)
			end
		elseif op.op == "remove" then
			remove(op.id)
		elseif op.op == "push" then
			MovementController.knockback(op.kx, op.ky, op.kz)
		end
	end
end

local cframes: { CFrame } = {}

local function draw()
	local now = os.clock()
	-- (From where the player hears: the camera kept near the eyes, in blocks.)
	local listener = SoundPlayer.listener()
	if listener == nil then
		return
	end
	MobRigPool.frame(pool, now, listener.X, listener.Y, listener.Z, Origin.x, Origin.z)
	MobParts.move(pool, cframes)
	-- A groan now and then.
	local groan = ZombieVoices.step(voices, now, pool.zombies, pool.zombieIds, pool.zombieDistances, VOICE_REACH)
	local model = if groan then models[groan] else nil
	if model then
		local x, y, z = MobModel.pose(model, now)
		local rig = model.kind.rig
		local pitch = if rig then ZombieVoices.PITCH[rig.gait] or 1 else 1
		SoundPlayer.play(AMBIENT, x, y + model.kind.eye, z, nil, pitch)
	end
end

--[[
	The Mobs messages are taken from the moment this module loads (the boot script requires it
	before anything waits), not from `start`: the server sends a mob's spawn once and then only
	what changed, so a message ClientNet's backlog dropped while the client booted (it keeps 64 a
	kind, about 6 s of a 10 a second stream) would leave mobs invisible, or ghosts, for good.
	What arrives before `start` is applied to the mobs at once; their parts wait out of sight.
]]
ClientNet.on(Protocol.ServerMessage.Mobs, onMessage)

-- Starts drawing the mobs the server sends.
function MobRenderer.start(_world: ClientWorld.ClientWorld)
	folder.Parent = workspace
	RunService:BindToRenderStep("IceVoxelMobs", RENDER_PRIORITY, draw)
end

-- Number of mobs the client knows (for the debug overlay).
function MobRenderer.count(): number
	return count
end

-- Zombies drawn as full and reduced rigs last frame, and the parts moved (for the debug overlay).
function MobRenderer.rigs(): (number, number, number)
	return pool.fullRigs, pool.reducedRigs, pool.count
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

--[[
	Where a turret aims at mob `id` as it is drawn (Rendering/TurretView): the centre of its body
	box, or with `head` its head box (Shared/Weapons/Ballistics.mobBoxes, the server's turrets' aim
	points, at its drawn place and facing), world blocks. nil for a mob the client does not know or
	one dying. Nothing is made (turrets ask every frame).
]]
function MobRenderer.aimPoint(id: number, head: boolean?): (number?, number?, number?)
	local model = models[id]
	if model == nil or model.diedAt ~= nil then
		return nil, nil, nil
	end
	local x, y, z, yaw = MobModel.pose(model, os.clock())
	local boxes = Ballistics.kindBoxes(model.kind)
	if head then
		-- (mobBoxes' head: its centre turned with the facing.)
		local h = boxes.head
		local c, s = math.cos(yaw), math.sin(yaw)
		local lx, lz = (h[1] + h[4]) / 2, (h[3] + h[6]) / 2
		return x + c * lx + s * lz, y + (h[2] + h[5]) / 2, z - s * lx + c * lz
	end
	local b = boxes.body
	return x + (b[1] + b[4]) / 2, y + (b[2] + b[5]) / 2, z + (b[3] + b[6]) / 2
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
