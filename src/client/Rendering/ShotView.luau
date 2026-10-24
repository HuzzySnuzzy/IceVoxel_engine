--!strict
--[[
	Shots seen and heard, in the manner of DayZ: every shot near the player (the server's Shots
	messages, Net/WeaponSync; within Config.Weapons.ShotBroadcast of the shooter) and the player's
	own, drawn at once when fired (`ownShot`, Interaction/Firearms). What each shot shows and plays
	is Rendering/ShotRules':

	  Flash     at the muzzle (Player/HeldItems.muzzle: the drawn gun's barrel end; a turret's shot,
	            shooter ShotRules.TURRET, at its drawn barrel's end: Rendering/TurretView
	            .muzzleNear, given by `setTurretMuzzle`; else where the shot was fired from) a
	            small Neon ball with a PointLight for FLASH_SECONDS; none when suppressed.
	  Tracers   a thin bar from the muzzle to where each pellet's flight ended (the player's own:
	            to what the aim pointed at, the predicted end), for Config.Weapons.TracerSeconds,
	            Neon unless the muzzle device takes the glow away (the suppressor; a turret's
	            record says it itself: `plain`), when Config.Weapons.Tracers is on.
	  Impacts   where each pellet ended: a block (or the air next to it) throws dust in the block's
	            colour, a mob or a player dark red blood (ParticleEmitter:Emit on pooled
	            emitters), with entity.bullet.impact or entity.bullet.flesh there; glass shows
	            nothing (the server's edit shatters it with its own sound).
	  Sounds    the fire sound at the shooter (the class shot, the suppressed one, or the far
	            rolling one beyond Config.Weapons.FarSound from the listener: Audio/SoundPlayer),
	            and a pump's or a bolt's rack (item.firearm.chamber) ShotRules.cycleDelay later.
	  Own shot  the server's record of the player's own shot (the same shooter) adds only its
	            authoritative impacts; its `refused` or `jammed` flag goes to Interaction/Firearms
	            (`onOwnShot`), which stops automatic fire (and clicks a jam).

	Flashes and tracers keep world blocks and are placed in render studs every frame (Shared/World/
	Origin), so a move of the render origin needs nothing; particles are emitted where they belong
	and live too briefly to follow it. Everything comes from pools made at `start` (FLASHES flashes,
	TRACERS tracers, DUST_EMITTERS dust emitters taken in turn, one for blood); the oldest gives way
	when all are busy. Nothing is created per frame or per shot.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local Origin = require(Shared.World.Origin)
local Protocol = require(Shared.Net.Protocol)
local Types = require(Shared.Inventory.Types)
local WeaponSync = require(Shared.Net.WeaponSync)
local Weapons = require(Shared.Weapons)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local HeldItems = require(script.Parent.Parent.Player.HeldItems)
local ShotRules = require(script.Parent.ShotRules)

-- After the camera, as the items and mobs.
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1
-- Pools.
local FLASHES = 8
local TRACERS = 48
local DUST_EMITTERS = 12
local CYCLES = 16
-- A flash: seconds, size (studs), its light's range (studs) and brightness.
local FLASH_SECONDS = 0.05
local FLASH_SIZE = 0.35
local FLASH_RANGE = 12
local FLASH_BRIGHTNESS = 4
local FLASH_COLOUR = Color3.fromRGB(255, 214, 140)
-- A tracer's thickness (studs) and colours (glowing, plain).
local TRACER_WIDTH = 0.04
local TRACER_GLOW = Color3.fromRGB(255, 226, 160)
local TRACER_PLAIN = Color3.fromRGB(150, 150, 150)
-- Particles a pellet's impact throws, and the blood's colour.
local PUFF = 6
local BLOOD = Color3.fromRGB(110, 10, 10)
-- How far into the block a pellet's end is looked at for its colour (blocks).
local INTO = 0.05

type Flash = { part: Part, light: PointLight, ends: number, x: number, y: number, z: number }
type Tracer = {
	part: Part,
	ends: number,
	ax: number,
	ay: number,
	az: number,
	bx: number,
	by: number,
	bz: number,
}
type Cycle = { at: number, pending: boolean, x: number, y: number, z: number }

local ShotView = {}

local started = false

local flashes: { Flash } = {}
local tracers: { Tracer } = {}
local nextFlash = 1
local nextTracer = 1
local dust: { { part: Part, emitter: ParticleEmitter } } = {}
local nextDust = 1
local bloodPart: Part? = nil
local bloodEmitter: ParticleEmitter? = nil
local cycles: { Cycle } = {}
local nextCycle = 1
local effects = ShotRules.newEffects()
local ownHandler: ((shot: WeaponSync.Shot) -> ())? = nil
-- Where a turret's shot that started at (ox, oy, oz) leaves its drawn barrel (nil: not drawn).
type TurretMuzzle = (ox: number, oy: number, oz: number) -> (number?, number?, number?)
local turretMuzzle: TurretMuzzle? = nil
local getBlock: (x: number, y: number, z: number) -> number? = function()
	return nil
end

local function inert(part: Part)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
end

local function newEmitter(parent: Part, colour: Color3): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Enabled = false
	emitter.Color = ColorSequence.new(colour)
	emitter.LightEmission = 0
	emitter.Lifetime = NumberRange.new(0.3, 0.6)
	emitter.Speed = NumberRange.new(4, 11)
	emitter.SpreadAngle = Vector2.new(55, 55)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Acceleration = Vector3.new(0, -28, 0)
	emitter.Drag = 3
	emitter.Size = NumberSequence.new(0.22, 0.05)
	emitter.Parent = parent
	return emitter
end

local function newAnchor(name: string, parent: Instance): Part
	local part = Instance.new("Part")
	inert(part)
	part.Name = name
	part.Transparency = 1
	part.Size = Vector3.one * 0.1
	part.Parent = parent
	return part
end

-- Blocks (world) -> render studs.
local function render(x: number, y: number, z: number): Vector3
	return Origin.blocksToRender(x, y, z)
end

--[[ Effects ]]

-- A muzzle flash at (x, y, z) (world blocks).
local function flashAt(x: number, y: number, z: number, now: number)
	local flash = flashes[nextFlash]
	nextFlash = nextFlash % FLASHES + 1
	flash.x, flash.y, flash.z = x, y, z
	flash.ends = now + FLASH_SECONDS
	flash.part.CFrame = CFrame.new(render(x, y, z))
	flash.part.Transparency = 0
	flash.light.Enabled = true
end

-- A tracer from (ax, ay, az) to (bx, by, bz) (world blocks).
local function tracerTo(
	ax: number,
	ay: number,
	az: number,
	bx: number,
	by: number,
	bz: number,
	glow: boolean,
	now: number
)
	local tracer = tracers[nextTracer]
	nextTracer = nextTracer % TRACERS + 1
	tracer.ax, tracer.ay, tracer.az = ax, ay, az
	tracer.bx, tracer.by, tracer.bz = bx, by, bz
	tracer.ends = now + Config.Weapons.TracerSeconds
	local part = tracer.part
	part.Material = if glow then Enum.Material.Neon else Enum.Material.SmoothPlastic
	part.Color = if glow then TRACER_GLOW else TRACER_PLAIN
	part.Transparency = 0
end

-- Dust in the colour of the block a pellet ended on, or blood, at (x, y, z) (world blocks), thrown
-- back towards (fx, fy, fz) where the shot came from.
local function impactAt(kind: ShotRules.Impact, x: number, y: number, z: number, fx: number, fy: number, fz: number)
	local dx, dy, dz = fx - x, fy - y, fz - z
	local length = math.sqrt(dx * dx + dy * dy + dz * dz)
	local back = if length > 1e-6 then Vector3.new(dx / length, dy / length, dz / length) else Vector3.yAxis
	-- (The emitters throw along their Top, their up vector: towards the shooter.)
	local side = back:Cross(if math.abs(back.X) < 0.9 then Vector3.xAxis else Vector3.zAxis).Unit
	local frame = CFrame.fromMatrix(render(x, y, z), side, back)
	if kind == "blood" then
		local part, emitter = bloodPart, bloodEmitter
		if part and emitter then
			part.CFrame = frame
			emitter:Emit(PUFF)
		end
		return
	end
	-- The block a little past the end (the end lies on its face).
	local bx = math.floor(x - back.X * INTO)
	local by = math.floor(y - back.Y * INTO)
	local bz = math.floor(z - back.Z * INTO)
	local block = getBlock(bx, by, bz)
	if block == nil or block == 0 or not Blocks.isValid(block) then
		return
	end
	local c = Blocks.get(block).color
	local slot = dust[nextDust]
	nextDust = nextDust % DUST_EMITTERS + 1
	slot.part.CFrame = frame
	slot.emitter.Color = ColorSequence.new(Color3.fromRGB(c[1], c[2], c[3]))
	slot.emitter:Emit(PUFF)
end

-- A pump's or a bolt's rack at (x, y, z) `delay` seconds from now.
local function queueCycle(delay: number, x: number, y: number, z: number, now: number)
	local cycle = cycles[nextCycle]
	nextCycle = nextCycle % CYCLES + 1
	cycle.at = now + delay
	cycle.pending = true
	cycle.x, cycle.y, cycle.z = x, y, z
end

-- The muzzle of `player`'s drawn gun (world blocks), else (ox, oy, oz).
local function muzzleOf(player: Player?, ox: number, oy: number, oz: number): (number, number, number)
	local point = if player then HeldItems.muzzle(player) else nil
	if point then
		return Origin.renderToBlocks(point)
	end
	return ox, oy, oz
end

-- The drawn barrel's end of the turret whose shot started at (ox, oy, oz), else that origin.
local function turretMuzzleOf(ox: number, oy: number, oz: number): (number, number, number)
	local finder = turretMuzzle
	if finder then
		local x, y, z = finder(ox, oy, oz)
		if x and y and z then
			return x, y, z
		end
	end
	return ox, oy, oz
end

--[[ Shots ]]

local function onShot(shot: WeaponSync.Shot, now: number, listener: Vector3?)
	local shooter = Players:GetPlayerByUserId(shot.shooter)
	local distance = if listener
		then math.sqrt((listener.X - shot.ox) ^ 2 + (listener.Y - shot.oy) ^ 2 + (listener.Z - shot.oz) ^ 2)
		else 0
	-- A suppressed shot's tracers glow as the shooter's muzzle device says (their held look); a
	-- turret's as its record says (`plain`: ShotRules.effects).
	local glow = true
	if shooter and shot.suppressed then
		local key = shooter:GetAttribute(Types.HELD_LOOK_ATTRIBUTE)
		local _, _, muzzle = ShotRules.lookParts(if type(key) == "string" then key else nil)
		glow = ShotRules.glow(if muzzle ~= 0 then muzzle else nil, 1)
	end
	local localPlayer = Players.LocalPlayer
	ShotRules.effects(shot, localPlayer.UserId, distance, glow, effects)
	if effects.own then
		local handler = ownHandler
		if handler and effects.stop then
			handler(shot)
		end
	end
	local mx, my, mz = shot.ox, shot.oy, shot.oz
	if effects.flash or effects.tracer then
		if shooter == nil and ShotRules.isTurret(shot) then
			mx, my, mz = turretMuzzleOf(shot.ox, shot.oy, shot.oz)
		else
			mx, my, mz = muzzleOf(shooter, shot.ox, shot.oy, shot.oz)
		end
	end
	if effects.flash then
		flashAt(mx, my, mz, now)
	end
	local sound = effects.sound
	if sound then
		SoundPlayer.play(sound, shot.ox, shot.oy, shot.oz)
	end
	local spec = Weapons.firearm(shot.item)
	if spec and not effects.own and not shot.refused then
		local delay = ShotRules.cycleDelay(spec, 1)
		if delay and distance <= Config.Weapons.FarSound then
			queueCycle(delay, shot.ox, shot.oy, shot.oz, now)
		end
	end
	for _, pellet in shot.pellets do
		if effects.tracer then
			tracerTo(mx, my, mz, pellet.x, pellet.y, pellet.z, effects.glow, now)
		end
		if effects.impacts then
			local kind: ShotRules.Impact? = ShotRules.impact(pellet.hit)
			if kind then
				impactAt(kind, pellet.x, pellet.y, pellet.z, shot.ox, shot.oy, shot.oz)
			end
			local impactSound = ShotRules.impactSound(pellet.hit)
			if impactSound then
				SoundPlayer.play(impactSound, pellet.x, pellet.y, pellet.z)
			end
		end
	end
end

--[[ Every frame ]]

local function draw()
	local now = os.clock()
	for _, flash in flashes do
		if flash.ends > 0 then
			if now >= flash.ends then
				flash.ends = 0
				flash.part.Transparency = 1
				flash.light.Enabled = false
			else
				flash.part.CFrame = CFrame.new(render(flash.x, flash.y, flash.z))
			end
		end
	end
	for _, tracer in tracers do
		if tracer.ends > 0 then
			if now >= tracer.ends then
				tracer.ends = 0
				tracer.part.Transparency = 1
				tracer.part.CFrame = CFrame.identity
			else
				local a = render(tracer.ax, tracer.ay, tracer.az)
				local b = render(tracer.bx, tracer.by, tracer.bz)
				local length = (b - a).Magnitude
				if length > 1e-3 then
					tracer.part.Size = Vector3.new(TRACER_WIDTH, TRACER_WIDTH, length)
					tracer.part.CFrame = CFrame.lookAt((a + b) / 2, b)
				end
			end
		end
	end
	for _, cycle in cycles do
		if cycle.pending and now >= cycle.at then
			cycle.pending = false
			SoundPlayer.play(ShotRules.CHAMBER, cycle.x, cycle.y, cycle.z)
		end
	end
end

--[[ API ]]

-- Starts drawing the shots near the player (Shots messages).
function ShotView.start(world: ClientWorld.ClientWorld)
	if started then
		return
	end
	started = true
	getBlock = function(x: number, y: number, z: number): number?
		return world:getBlock(x, y, z)
	end
	local container = Instance.new("Folder")
	container.Name = "IceVoxelShots"
	container.Parent = workspace

	for _ = 1, FLASHES do
		local part = Instance.new("Part")
		inert(part)
		part.Name = "Flash"
		part.Shape = Enum.PartType.Ball
		part.Material = Enum.Material.Neon
		part.Color = FLASH_COLOUR
		part.Size = Vector3.one * FLASH_SIZE
		part.Transparency = 1
		local light = Instance.new("PointLight")
		light.Range = FLASH_RANGE
		light.Brightness = FLASH_BRIGHTNESS
		light.Color = FLASH_COLOUR
		light.Shadows = false
		light.Enabled = false
		light.Parent = part
		part.Parent = container
		table.insert(flashes, { part = part, light = light, ends = 0, x = 0, y = 0, z = 0 })
	end
	for _ = 1, TRACERS do
		local part = Instance.new("Part")
		inert(part)
		part.Name = "Tracer"
		part.Material = Enum.Material.Neon
		part.Color = TRACER_GLOW
		part.Size = Vector3.new(TRACER_WIDTH, TRACER_WIDTH, 1)
		part.Transparency = 1
		part.Parent = container
		table.insert(tracers, { part = part, ends = 0, ax = 0, ay = 0, az = 0, bx = 0, by = 0, bz = 0 })
	end
	for i = 1, DUST_EMITTERS do
		local part = newAnchor(`Dust{i}`, container)
		table.insert(dust, { part = part, emitter = newEmitter(part, Color3.new(0.5, 0.5, 0.5)) })
	end
	local blood = newAnchor("Blood", container)
	bloodPart, bloodEmitter = blood, newEmitter(blood, BLOOD)
	for _ = 1, CYCLES do
		table.insert(cycles, { at = 0, pending = false, x = 0, y = 0, z = 0 })
	end
	ClientNet.on(Protocol.ServerMessage.Shots, function(payload: buffer)
		local ok, shots = pcall(WeaponSync.decodeShots, payload)
		if not ok or shots == nil then
			warn("[IceVoxel] Bad Shots message")
			return
		end
		local now = os.clock()
		local listener = SoundPlayer.listener()
		for _, shot in shots do
			onShot(shot, now, listener)
		end
	end)
	RunService:BindToRenderStep("IceVoxelShots", RENDER_PRIORITY, draw)
end

-- Calls `handler` with the server's record of each of the player's own shots that stops automatic
-- fire (refused, or the gun jammed): Interaction/Firearms.
function ShotView.onOwnShot(handler: (shot: WeaponSync.Shot) -> ())
	ownHandler = handler
end

-- Gives where a turret's shot leaves its drawn barrel (Rendering/TurretView.muzzleNear: from the
-- record's origin, world blocks; nil: not drawn, the origin it is); nil: none, the origins.
function ShotView.setTurretMuzzle(finder: TurretMuzzle?)
	turretMuzzle = finder
end

--[[
	The player's own shot, drawn at once when fired (Interaction/Firearms): the fire sound (`sound`,
	ShotRules) at the eyes (ex, ey, ez), the flash (unless `suppressed`) and a tracer (`glow` or
	not) from the drawn gun's muzzle to (tx, ty, tz), where the aim pointed (world blocks), and a
	pump's or a bolt's rack `cycle` seconds later (nil: none).
]]
function ShotView.ownShot(
	sound: string?,
	suppressed: boolean,
	glow: boolean,
	ex: number,
	ey: number,
	ez: number,
	tx: number,
	ty: number,
	tz: number,
	cycle: number?
)
	if not started then
		return
	end
	local now = os.clock()
	local mx, my, mz = muzzleOf(Players.LocalPlayer, ex, ey, ez)
	if ShotRules.flash(suppressed) then
		flashAt(mx, my, mz, now)
	end
	if Config.Weapons.Tracers then
		tracerTo(mx, my, mz, tx, ty, tz, glow, now)
	end
	if sound then
		SoundPlayer.play(sound, ex, ey, ez)
	end
	if cycle then
		queueCycle(cycle, ex, ey, ez, now)
	end
end

return ShotView
