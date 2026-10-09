--!strict
--[[
	Magic projectiles on the client (Shared/Magic/Projectiles; the server's Projectiles messages,
	server Players/Magic): every client flies each projectile itself with the same pure step the
	server uses, so the server sends only where one starts, where it went after a bounce and where
	it ended.

	  Flight     20 ticks a second (catching up at most MAX_TICKS_PER_FRAME), against this client's
	             blocks (ClientWorld) and the mobs as they are drawn (Entities/MobRenderer.mobsNear):
	             a projectile that ends here (a block, a mob, its life) disappears with a small
	             burst at once; the server's end op is the authority for anything still flying
	             (it flies on to where the server ended it, END_LAG 4 ticks at most, as a client
	             draws it a little behind the server, and ends there), and a sync op (after a
	             bounce) puts it where the server has it, unless it bounced at that very spot here
	             too (the same path, already a tick or two further: SAME_BOUNCE), so nothing is
	             pulled back.
	  Casting    this player's own casts fly at once (`predict`, Interaction/Casting) with the
	             cast's HeldUse seq; the server's spawn op for that seq (owner = this player) is
	             adopted instead of drawing a second one. A cast the server refused for want of
	             mana (Player/ManaState.refused) takes the newest prediction not yet adopted away;
	             one never adopted flies out its life.
	  Looks      a Neon ball in the kind's colour and size (Projectiles.KINDS) with a PointLight
	             (its `light` range) and a short Trail, from a pool of parts; drawn every frame
	             between the last two ticks at Origin.blocksToRender (world blocks to render
	             studs: no Rendering/Rebase mover needed; trails are cleared when the origin
	             moves, so none streaks across the jump). At most MAX_SHOTS fly at once (the
	             oldest go first).
	  Burst      where one ends: a few sparks of its colour (ParticleEmitter:Emit on a pooled
	             attachment), no sound (the server sends entity.magic.hit).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local MagicSync = require(Shared.Net.MagicSync)
local Projectiles = require(Shared.Magic.Projectiles)
local Protocol = require(Shared.Net.Protocol)
local Origin = require(Shared.World.Origin)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local MobRenderer = require(script.Parent.Parent.Entities.MobRenderer)
local ManaState = require(script.Parent.Parent.Player.ManaState)

local BLOCK = Config.BlockSize
local TICK = 1 / 20
local MAX_TICKS_PER_FRAME = 4
local MAX_SHOTS = 64
-- After the camera, as the items and mobs.
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1
-- Mobs looked for around a projectile: its tick's travel plus the largest box.
local NEAR_EXTRA = 3
-- Sparks of a burst.
local BURST = 8
-- A sync op this close (blocks) to where a projectile bounced here is the same bounce.
local SAME_BOUNCE = 0.05
-- Ticks at most a projectile flies on to the server's end of it.
local END_LAG = 4

type Shot = {
	projectile: Projectiles.Projectile,
	-- The server's id (nil: a prediction not adopted yet) and this player's seq (predictions).
	id: number?,
	seq: number?,
	-- Where it was at the last tick (world blocks), to draw between ticks.
	prevX: number,
	prevY: number,
	prevZ: number,
	-- Where it last bounced here (nil: never), to tell a sync op it already follows.
	bounceX: number?,
	bounceY: number,
	bounceZ: number,
	-- The server's end, when it came while this one still flies towards it: ticks left until it
	-- ends there (nil: none yet), where, and why.
	endIn: number?,
	endX: number,
	endY: number,
	endZ: number,
	endReason: number,
	part: BasePart,
	trail: Trail,
}

local ProjectileView = {}

local shots: { Shot } = {}
local byId: { [number]: Shot } = {}
local spare: { BasePart } = {}
local folder: Folder? = nil
local burstPart: BasePart? = nil
local burstEmitter: ParticleEmitter? = nil
local getBlock: (x: number, y: number, z: number) -> number? = function()
	return nil
end
local accumulator = 0
-- Mob boxes for the step, rebuilt each tick a projectile flies (Projectiles.Target).
local targets: { Projectiles.Target } = {}
-- Predictions that ended here before the server's spawn came (seq -> os.clock()): that spawn
-- then draws nothing (the shot already flew and ended).
local endedSeqs: { [number]: number } = {}
local endedCount = 0
-- Seconds an ended prediction waits for its spawn.
local ENDED_WAIT = 3

local function newPart(): BasePart
	local part = Instance.new("Part")
	part.Name = "Projectile"
	part.Shape = Enum.PartType.Ball
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	local light = Instance.new("PointLight")
	light.Brightness = 2
	light.Shadows = false
	light.Parent = part
	local a0 = Instance.new("Attachment")
	a0.Name = "TrailTop"
	a0.Parent = part
	local a1 = Instance.new("Attachment")
	a1.Name = "TrailBottom"
	a1.Parent = part
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = 0.15
	trail.FaceCamera = true
	trail.LightEmission = 1
	trail.Transparency = NumberSequence.new(0.2, 1)
	trail.Parent = part
	return part
end

-- A part dressed for `kind` (from the pool when one is spare).
local function dress(kind: Projectiles.Kind): (BasePart, Trail)
	local part = table.remove(spare) or newPart()
	local colour = Color3.fromRGB(kind.color[1], kind.color[2], kind.color[3])
	local size = kind.size * BLOCK
	part.Color = colour
	part.Size = Vector3.one * size
	local light = part:FindFirstChildOfClass("PointLight") :: PointLight
	light.Color = colour
	light.Range = math.min(kind.light * BLOCK, 60)
	local trail = part:FindFirstChildOfClass("Trail") :: Trail
	trail.Color = ColorSequence.new(colour)
	local top = part:FindFirstChild("TrailTop") :: Attachment
	local bottom = part:FindFirstChild("TrailBottom") :: Attachment
	top.Position = Vector3.new(0, size / 2, 0)
	bottom.Position = Vector3.new(0, -size / 2, 0)
	trail.Enabled = true
	return part, trail
end

-- A burst of sparks in `kind`'s colour at (x, y, z) (world blocks).
local function burst(kind: Projectiles.Kind, x: number, y: number, z: number)
	local part, emitter = burstPart, burstEmitter
	if part == nil or emitter == nil then
		return
	end
	part.CFrame = CFrame.new(Origin.blocksToRender(x, y, z))
	emitter.Color = ColorSequence.new(Color3.fromRGB(kind.color[1], kind.color[2], kind.color[3]))
	emitter:Emit(BURST)
end

local function add(projectile: Projectiles.Projectile, id: number?, seq: number?): Shot
	while #shots >= MAX_SHOTS do
		local oldest = table.remove(shots, 1) :: Shot
		local oldId = oldest.id
		if oldId then
			byId[oldId] = nil
		end
		oldest.trail.Enabled = false
		oldest.part.Parent = nil
		table.insert(spare, oldest.part)
	end
	local kind = Projectiles.get(projectile.kind) :: Projectiles.Kind
	local part, trail = dress(kind)
	local shot: Shot = {
		projectile = projectile,
		id = id,
		seq = seq,
		prevX = projectile.x,
		prevY = projectile.y,
		prevZ = projectile.z,
		bounceX = nil,
		bounceY = 0,
		bounceZ = 0,
		endIn = nil,
		endX = 0,
		endY = 0,
		endZ = 0,
		endReason = 0,
		part = part,
		trail = trail,
	}
	part.CFrame = CFrame.new(Origin.blocksToRender(projectile.x, projectile.y, projectile.z))
	trail:Clear()
	part.Parent = folder
	table.insert(shots, shot)
	if id then
		byId[id] = shot
	end
	return shot
end

-- Takes shot `index` away (with a burst unless it just expired).
local function removeAt(index: number, showBurst: boolean)
	local shot = table.remove(shots, index) :: Shot
	local id = shot.id
	local seq = shot.seq
	if id then
		byId[id] = nil
	elseif seq then
		-- (A prediction gone before its spawn came: that spawn draws nothing.)
		local now = os.clock()
		if endedCount > 64 then
			for old, at in endedSeqs do
				if now - at > ENDED_WAIT then
					endedSeqs[old] = nil
					endedCount -= 1
				end
			end
		end
		if endedSeqs[seq] == nil then
			endedCount += 1
		end
		endedSeqs[seq] = now
	end
	local p = shot.projectile
	if showBurst then
		burst(Projectiles.get(p.kind) :: Projectiles.Kind, p.x, p.y, p.z)
	end
	shot.trail.Enabled = false
	shot.part.Parent = nil
	table.insert(spare, shot.part)
end

local function remove(shot: Shot, showBurst: boolean)
	local index = table.find(shots, shot)
	if index then
		removeAt(index, showBurst)
	end
end

--[[ The server's ops ]]

local function onOps(payload: buffer)
	local ops = MagicSync.decodeProjectiles(payload, Projectiles.COUNT)
	if ops == nil then
		return
	end
	local me = Players.LocalPlayer.UserId
	for _, op in ops do
		if op.op == "spawn" then
			local adopted: Shot? = nil
			local ended = false
			if op.owner == me then
				for _, shot in shots do
					if shot.id == nil and shot.seq == op.seq then
						adopted = shot
						break
					end
				end
				local seq = op.seq :: number
				local at = endedSeqs[seq]
				if adopted == nil and at then
					endedSeqs[seq] = nil
					endedCount -= 1
					ended = os.clock() - at <= ENDED_WAIT
				end
			end
			if ended then
				-- (Ours, already flown and ended here.)
				continue
			elseif adopted then
				-- (Ours, already flying: it takes the server's id.)
				adopted.id = op.id
				byId[op.id] = adopted
			elseif byId[op.id] == nil then
				local p = Projectiles.new(
					op.kind :: number,
					op.x,
					op.y,
					op.z,
					op.vx :: number,
					op.vy :: number,
					op.vz :: number
				)
				add(p, op.id, nil)
			end
		elseif op.op == "sync" then
			local shot = byId[op.id]
			-- (Unless it bounced there here too: the same path, already a tick or two on.)
			local bx = if shot then shot.bounceX else nil
			local same = shot ~= nil
				and bx ~= nil
				and (bx - op.x) ^ 2 + (shot.bounceY - op.y) ^ 2 + (shot.bounceZ - op.z) ^ 2 < SAME_BOUNCE ^ 2
			if shot and not same then
				Projectiles.place(shot.projectile, op.x, op.y, op.z, op.vx :: number, op.vy :: number, op.vz :: number)
				shot.bounceX, shot.bounceY, shot.bounceZ = op.x, op.y, op.z
			end
		else
			local shot = byId[op.id]
			if shot then
				-- (It flies on to where the server ended it, if that is ahead, at most END_LAG ticks:
				-- a client draws a projectile a little behind the server.)
				local p = shot.projectile
				local dx, dy, dz = op.x - p.x, op.y - p.y, op.z - p.z
				local speed = math.sqrt(p.vx * p.vx + p.vy * p.vy + p.vz * p.vz)
				local ahead = dx * p.vx + dy * p.vy + dz * p.vz > 0
				local ticks = if ahead and speed > 1e-6
					then math.min(math.ceil(math.sqrt(dx * dx + dy * dy + dz * dz) / speed), END_LAG)
					else 0
				local reason = op.reason :: number
				if ticks <= 0 then
					p.x, p.y, p.z = op.x, op.y, op.z
					remove(shot, reason ~= MagicSync.Reason.Expired)
				else
					shot.endIn, shot.endX, shot.endY, shot.endZ, shot.endReason = ticks, op.x, op.y, op.z, reason
				end
			end
		end
	end
end

--[[ Ticks and frames ]]

-- The mobs near (x, y, z) as the step wants them (into `targets`).
local function gatherTargets(x: number, y: number, z: number, radius: number)
	table.clear(targets)
	for _, mob in MobRenderer.mobsNear(x, y, z, radius) do
		table.insert(
			targets,
			{ id = mob.id, x = mob.x, y = mob.y, z = mob.z, width = mob.kind.width, height = mob.kind.height }
		)
	end
end

local function tick()
	local i = 1
	while i <= #shots do
		local shot = shots[i]
		local p = shot.projectile
		shot.prevX, shot.prevY, shot.prevZ = p.x, p.y, p.z
		local kind = Projectiles.get(p.kind) :: Projectiles.Kind
		gatherTargets(p.x, p.y, p.z, kind.speed + NEAR_EXTRA)
		if Projectiles.step(p, getBlock, targets) == "bounce" then
			shot.bounceX, shot.bounceY, shot.bounceZ = p.x, p.y, p.z
		end
		local endIn = shot.endIn
		if not p.dead and endIn then
			endIn -= 1
			shot.endIn = endIn
			if endIn <= 0 then
				p.x, p.y, p.z = shot.endX, shot.endY, shot.endZ
				p.dead, p.reason = true, shot.endReason
			end
		end
		if p.dead then
			removeAt(i, p.reason ~= MagicSync.Reason.Expired)
		else
			i += 1
		end
	end
end

local function draw(dt: number)
	if #shots == 0 then
		accumulator = 0
		return
	end
	accumulator = math.min(accumulator + dt, TICK * MAX_TICKS_PER_FRAME)
	while accumulator >= TICK do
		accumulator -= TICK
		tick()
	end
	local alpha = accumulator / TICK
	for _, shot in shots do
		local p = shot.projectile
		shot.part.CFrame = CFrame.new(
			Origin.blocksToRender(
				shot.prevX + (p.x - shot.prevX) * alpha,
				shot.prevY + (p.y - shot.prevY) * alpha,
				shot.prevZ + (p.z - shot.prevZ) * alpha
			)
		)
	end
end

--[[ API ]]

--[[
	This player's own cast (Interaction/Casting): a projectile of `kind` from (x, y, z) towards
	(dx, dy, dz) (world blocks), numbered by the HeldUse's `seq`, flying at once.
]]
function ProjectileView.predict(
	kind: number,
	seq: number,
	x: number,
	y: number,
	z: number,
	dx: number,
	dy: number,
	dz: number
)
	if folder == nil or Projectiles.get(kind) == nil then
		return
	end
	add(Projectiles.launch(kind, x, y, z, dx, dy, dz), nil, seq % 65536)
end

-- Projectiles drawn (for a debug line: F3 may show it).
function ProjectileView.count(): number
	return #shots
end

function ProjectileView.start(world: ClientWorld.ClientWorld)
	getBlock = function(x: number, y: number, z: number): number?
		return world:getBlock(x, y, z)
	end
	local container = Instance.new("Folder")
	container.Name = "IceVoxelProjectiles"
	container.Parent = workspace
	folder = container
	local anchor = Instance.new("Part")
	anchor.Name = "Burst"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one * 0.2
	anchor.Parent = container
	local emitter = Instance.new("ParticleEmitter")
	emitter.Enabled = false
	emitter.LightEmission = 1
	emitter.Lifetime = NumberRange.new(0.2, 0.45)
	emitter.Speed = NumberRange.new(4, 10)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Size = NumberSequence.new(0.35, 0)
	emitter.Drag = 4
	emitter.Parent = anchor
	burstPart, burstEmitter = anchor, emitter
	ClientNet.on(Protocol.ServerMessage.Projectiles, onOps)
	-- A refused cast: the newest prediction not yet adopted didn't happen.
	ManaState.refused:Connect(function()
		for index = #shots, 1, -1 do
			if shots[index].id == nil then
				removeAt(index, false)
				break
			end
		end
	end)
	-- (Trails are in render studs: cleared when the origin jumps, so none streaks across.)
	Origin.onRebase(function()
		for _, shot in shots do
			shot.trail:Clear()
		end
	end)
	RunService:BindToRenderStep("IceVoxelProjectiles", RENDER_PRIORITY, draw)
end

return ProjectileView
