--!strict
--[[
	Lightning on this client (Roblox glue over Weather/LightningBolt and Weather/DistantStorms): the
	server's strikes (its Lightning message, Protocol.decodeLightning: the struck cell's bottom
	centre, the shape's seed, 1 to 3 flashes) and the distant storms' flashes (Weather/StormView,
	`distant`: bolts to the ground and flashes in the cloud, made on this client from the weather
	field). Strikes within Config.Weather.Distant.Near blocks are near ones, the rest are drawn and
	heard as distant ones.

	  Bolt      (near) Minecraft's bolt (LightningBolt.segments: 128 blocks of zigzag and two
	            branches), each segment two Neon parts: a core and a wider see-through glow
	            (Config.Weather.Bolt Color and Glow), redrawn in each flash's new shape and gone
	            when the bolt's life ends (LightningBolt.timeline, 20 ticks a second). Parts are
	            pooled; a few bolts can show at once.
	  Far bolt  (farther, within the view distance) the same shape from the ground up to the
	            cloud's base (Weather/CloudView.base; DistantStorms.boltScale), one Beam a segment
	            (FaceCamera, so it faces the eye from anywhere; LightEmission 1, LightInfluence 0)
	            DistantStorms.boltWidth wide, about two pixels at any distance, and
	            DistantStorms.brightness bright (Beam.Brightness: what the Atmosphere's haze at that
	            distance takes, Rendering/AtmosphereModel, is given back, so a bolt at the view
	            distance is not washed out). Beams and their two Attachments (on one anchored
	            invisible part) are pooled; at most Distant.Bolts (FastBolts on Fast clouds) at
	            once, and Distant.Glows distant flashes of any kind.
	  Clouds    every strike and flash lights the clouds over it while the sky flashes
	            (CloudView.glow / light: a few cloud parts turned towards the bolt's colour by
	            Distant.Glow, Neon): an in-cloud flash shows only there and in the sky.
	  Flash     while the sky flashes (life >= 0), a ColorCorrectionEffect ("IceVoxelLightning" in
	            Lighting) brightens the picture by Bolt.Flash times DistantStorms.skyFlash (less the
	            farther the strike, half at 512 blocks, and the farther the less by day; less again
	            inside the cloud), indoors (the sky exposure, Rendering/LightingController) and
	            blind (Rendering/EffectView.blindness: none at all through Blindness's black fog, as
	            Minecraft's flash only lights the sky the fog hides), and a PointLight at the
	            struck point lights the ground around a near one (Bolt.LightRange).
	  Sound     a strike's crack (entity.lightning_bolt.impact) at once where it struck (heard
	            within 32 blocks). Thunder for every strike and flash within the hearing
	            (DistantStorms.settings: Distant.Hearing), Weather.thunderDelay(distance) seconds
	            later (343 blocks a second), DistantStorms.thunderCue loud: a near strike's
	            (entity.lightning_bolt.thunder) THUNDER_OFFSET blocks from the listener towards it,
	            as Minecraft's (volume 10000: heard everywhere it is sent); a distant one's
	            (entity.lightning_bolt.thunder.far) on Audio/SoundPlayer's distant voices
	            (playDistant: the same, following the listener, at most Distant.Voices at once, the
	            quietest giving way), lower and longer (thunderPitch), muffled (muffle: an
	            equalizer) and from Echo.From on rolling on in an echo.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local DayCycle = require(Shared.DayCycle)
local Protocol = require(Shared.Net.Protocol)
local Sounds = require(Shared.Sounds)
local Weather = require(Shared.Weather)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local AtmosphereModel = require(script.Parent.Parent.Rendering.AtmosphereModel)
local EffectView = require(script.Parent.Parent.Rendering.EffectView)
local LightingController = require(script.Parent.Parent.Rendering.LightingController)
local ViewSettings = require(script.Parent.Parent.Rendering.ViewSettings)
local SoundRules = require(script.Parent.Parent.Audio.SoundRules)
local CloudView = require(script.Parent.CloudView)
local DistantStorms = require(script.Parent.DistantStorms)
local LightningBolt = require(script.Parent.LightningBolt)
local WeatherState = require(script.Parent.WeatherState)

local BLOCK = Config.BlockSize
-- Bolts drawn at once at most (older ones give way).
local MAX_BOLTS = 3
-- How far from the listener a near strike's thunder plays (blocks), towards the strike.
local THUNDER_OFFSET = DistantStorms.THUNDER_OFFSET
-- How far the near thunder's voice is heard (blocks: SoundPlayer's range at a cue of 1 or less).
local NEAR_RANGE = SoundRules.range(Sounds.get(Sounds.id["entity.lightning_bolt.thunder"]) :: Sounds.Event, 1)
-- The struck point's light while the sky flashes (PointLight brightness).
local FLASH_LIGHT = 6
-- A far bolt's branches are this much thinner than its main bolt.
local BRANCH_WIDTH = 0.7

type Bolt = {
	x: number,
	y: number,
	z: number,
	phases: { LightningBolt.Phase },
	finish: number,
	started: number,
	-- The phase drawn now (its seed) and the parts drawing it.
	drawn: number?,
	parts: { Part },
	light: PointLight,
	anchor: Part,
	falloff: number,
	-- The clouds it lights (CloudView.glow).
	glow: number?,
}

-- One segment of a far bolt: a Beam between two Attachments.
type Strand = { beam: Beam, from: Attachment, to: Attachment }

-- A distant flash: a far bolt (`ground`) or one in the cloud.
type Far = {
	x: number,
	y: number,
	z: number,
	-- How much taller than Minecraft's the bolt is drawn (DistantStorms.boltScale).
	scale: number,
	ground: boolean,
	phases: { LightningBolt.Phase },
	finish: number,
	started: number,
	drawn: number?,
	strands: { Strand },
	-- The bolt's width (blocks) and Beam.Brightness, whether it is drawn at all.
	width: number,
	brightness: number,
	bolt: boolean,
	glow: number?,
	falloff: number,
}

local LightningView = {}

local bolts: { Bolt } = {}
local pool: { Part } = {}
local fars: { Far } = {}
local strandPool: { Strand } = {}
local folder: Folder? = nil
local farAnchor: Part? = nil
local correction: ColorCorrectionEffect? = nil
local flashWritten = 0
local viewDistance: () -> number = function()
	return Config.Lod.ViewDistance
end

local function boltColour(): Color3
	local colour = Config.Weather.Bolt.Color
	return Color3.fromRGB(colour[1], colour[2], colour[3])
end

-- The distant storms' settings now (the Clouds setting, the view, the device).
local function distantSettings(): DistantStorms.Settings
	return DistantStorms.settings(CloudView.mode(), viewDistance(), ViewSettings.isMobile())
end

local function boltPart(): Part
	local part = table.remove(pool)
	if part then
		return part
	end
	local fresh = Instance.new("Part")
	fresh.Name = "Bolt"
	fresh.Anchored = true
	fresh.CanCollide = false
	fresh.CanQuery = false
	fresh.CanTouch = false
	fresh.CastShadow = false
	fresh.Material = Enum.Material.Neon
	pcall(function()
		(fresh :: any).AudioCanCollide = false
	end)
	return fresh
end

local function releaseParts(bolt: Bolt)
	for _, part in bolt.parts do
		part.Parent = nil
		table.insert(pool, part)
	end
	table.clear(bolt.parts)
end

-- Draws `bolt` in the shape of `seed`.
local function draw(bolt: Bolt, seed: number)
	releaseParts(bolt)
	local settings = Config.Weather.Bolt
	local colour = boltColour()
	local root = folder :: Folder
	for _, segment in LightningBolt.segments(seed) do
		local a = Vector3.new(bolt.x + segment.x0, bolt.y + segment.y0, bolt.z + segment.z0) * BLOCK
		local b = Vector3.new(bolt.x + segment.x1, bolt.y + segment.y1, bolt.z + segment.z1) * BLOCK
		local length = (b - a).Magnitude
		local frame = CFrame.lookAt((a + b) / 2, b)
		for layer = 1, 2 do
			local part = boltPart()
			local width = segment.width * BLOCK * (if layer == 1 then 0.35 else 1)
			part.Size = Vector3.new(width, width, length + width)
			part.CFrame = frame
			part.Color = colour
			part.Transparency = if layer == 1 then 0 else settings.Glow
			part.Parent = root
			table.insert(bolt.parts, part)
		end
	end
	bolt.drawn = seed
end

local function remove(index: number)
	local bolt = bolts[index]
	releaseParts(bolt)
	bolt.anchor:Destroy()
	if bolt.glow then
		CloudView.unglow(bolt.glow)
	end
	table.remove(bolts, index)
end

--[[ Far bolts ]]

local function newStrand(): Strand
	local reused = table.remove(strandPool)
	if reused then
		return reused
	end
	local anchor = farAnchor :: Part
	local from = Instance.new("Attachment")
	from.Name = "From"
	from.Parent = anchor
	local to = Instance.new("Attachment")
	to.Name = "To"
	to.Parent = anchor
	local beam = Instance.new("Beam")
	beam.Name = "Bolt"
	beam.Attachment0 = from
	beam.Attachment1 = to
	beam.FaceCamera = true
	beam.Segments = 1
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Color = ColorSequence.new(boltColour())
	beam.Transparency = NumberSequence.new(0)
	beam.Enabled = false
	beam.Parent = anchor
	return { beam = beam, from = from, to = to }
end

local function releaseStrands(far: Far)
	for _, strand in far.strands do
		strand.beam.Enabled = false
		table.insert(strandPool, strand)
	end
	table.clear(far.strands)
end

-- Draws far bolt `far` in the shape of `seed`.
local function drawFar(far: Far, seed: number)
	releaseStrands(far)
	far.drawn = seed
	if not far.bolt then
		return
	end
	local k = far.scale
	for _, segment in LightningBolt.segments(seed) do
		local strand = newStrand()
		strand.from.Position = Vector3.new(far.x + segment.x0 * k, far.y + segment.y0 * k, far.z + segment.z0 * k)
			* BLOCK
		strand.to.Position = Vector3.new(far.x + segment.x1 * k, far.y + segment.y1 * k, far.z + segment.z1 * k) * BLOCK
		local width = far.width * BLOCK * (if segment.branch then BRANCH_WIDTH else 1)
		local beam = strand.beam
		beam.Width0 = width
		beam.Width1 = width
		beam.Brightness = far.brightness
		beam.Enabled = true
		table.insert(far.strands, strand)
	end
end

local function removeFar(index: number)
	local far = fars[index]
	releaseStrands(far)
	if far.glow then
		CloudView.unglow(far.glow)
	end
	table.remove(fars, index)
end

-- The share of a thing's light the haze lets through `distance` blocks away (1 without haze).
local function transmittance(distance: number): number
	local atmosphere = ViewSettings.atmosphere()
	if atmosphere == nil or atmosphere.Parent ~= Lighting then
		return 1
	end
	return 1 - AtmosphereModel.haze(distance * BLOCK, atmosphere.Density)
end

--[[ Thunder ]]

-- Thunder from (x, y, z), `distance` blocks off, when it gets here (cue volume x `scale`).
local function thunder(
	x: number,
	y: number,
	z: number,
	distance: number,
	settings: DistantStorms.Settings,
	scale: number
)
	local hearing = settings.hearing
	local volume = DistantStorms.thunderCue(distance, hearing, NEAR_RANGE) * scale
	if volume <= 0.01 then
		return
	end
	local delay = Weather.thunderDelay(distance)
	if distance <= Config.Weather.Distant.Near then
		task.delay(delay, function()
			local hear = SoundPlayer.listener()
			if hear == nil then
				return
			end
			local direction = Vector3.new(x, y, z) - hear
			local offset = if direction.Magnitude > THUNDER_OFFSET then direction.Unit * THUNDER_OFFSET else direction
			local at = hear + offset
			SoundPlayer.play("entity.lightning_bolt.thunder", at.X, at.Y, at.Z, volume)
		end)
		return
	end
	local pitch = DistantStorms.thunderPitch(distance, hearing)
	local low, mid, high = DistantStorms.muffle(distance)
	local voices = settings.voices
	task.delay(delay, function()
		SoundPlayer.playDistant("entity.lightning_bolt.thunder.far", x, y, z, volume, pitch, voices, low, mid, high)
	end)
	if DistantStorms.echoes(distance) > 0 then
		-- (The rumble rolls on: once more, fainter, lower and duller.)
		local echo = Config.Weather.Distant.Echo
		local after = echo.Delay[1] + (echo.Delay[2] - echo.Delay[1]) * math.random()
		task.delay(delay + after, function()
			SoundPlayer.playDistant(
				"entity.lightning_bolt.thunder.far",
				x,
				y,
				z,
				volume * echo.Volume,
				pitch * echo.Pitch,
				voices,
				low,
				mid - 3,
				high - 6
			)
		end)
	end
end

--[[ Strikes and flashes ]]

--[[
	A distant flash at (x, z): a bolt to the ground at height `y` (`ground`), else in the cloud
	over it, in shape `seed` with `flashes` flashes: heard within the hearing, seen within the
	view distance (the bolt, the clouds lit) and in the sky's flash within the reach.
]]
local function showFar(x: number, y: number, z: number, ground: boolean, seed: number, flashes: number)
	local root = folder
	if root == nil then
		return
	end
	local settings = distantSettings()
	local listener = SoundPlayer.listener()
		or Vector3.new(WeatherState.cameraX, WeatherState.cameraY, WeatherState.cameraZ)
	local top = CloudView.base(x, z) or Config.Weather.Clouds.Altitude
	local at = if ground then Vector3.new(x, y, z) else Vector3.new(x, top, z)
	local distance = (at - listener).Magnitude
	local dx, dz = x - listener.X, z - listener.Z
	local across = math.sqrt(dx * dx + dz * dz)
	if distance <= settings.hearing then
		thunder(at.X, at.Y, at.Z, distance, settings, if ground then 1 else Config.Weather.Distant.InCloudVolume)
	end
	if across > settings.reach then
		return
	end
	local seen = across <= settings.view
	if #fars >= settings.glows then
		removeFar(1)
	end
	local drawn = 0
	for _, far in fars do
		if far.bolt then
			drawn += 1
		end
	end
	local daylight = DayCycle.skyBrightness(LightingController.dayTime())
	local phases, finish = LightningBolt.timeline(seed, flashes)
	table.insert(fars, {
		x = x,
		y = y,
		z = z,
		scale = DistantStorms.boltScale(y, top),
		ground = ground,
		phases = phases,
		finish = finish,
		started = os.clock(),
		drawn = nil,
		strands = {},
		width = DistantStorms.boltWidth(distance),
		brightness = DistantStorms.brightness(transmittance(distance)),
		bolt = ground and seen and drawn < settings.bolts,
		glow = if seen then CloudView.glow(x, z) else nil,
		falloff = DistantStorms.skyFlash(distance, ground, daylight),
	})
end

local function strike(message: Protocol.LightningBolt)
	local root = folder
	if root == nil then
		return
	end
	local settings = Config.Weather.Bolt
	-- (The bolt's foot: the bottom centre of the struck cell.)
	local x, y, z = message.x, message.y, message.z
	local listener = SoundPlayer.listener()
	local distance = if listener then (Vector3.new(x, y, z) - listener).Magnitude else 0
	-- The crack where it struck, at once (only heard near).
	SoundPlayer.play("entity.lightning_bolt.impact", x, y + 0.5, z)
	if distance > Config.Weather.Distant.Near then
		showFar(x, y, z, true, message.seed, message.flashes)
		return
	end
	if #bolts >= MAX_BOLTS then
		remove(1)
	end
	local phases, finish = LightningBolt.timeline(message.seed, message.flashes)
	local anchor = Instance.new("Part")
	anchor.Name = "Strike"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one
	anchor.CFrame = CFrame.new(Vector3.new(x, y + 1, z) * BLOCK)
	local light = Instance.new("PointLight")
	light.Range = settings.LightRange
	light.Brightness = 0
	light.Shadows = false
	light.Color = boltColour()
	light.Parent = anchor
	anchor.Parent = root
	table.insert(bolts, {
		x = x,
		y = y,
		z = z,
		phases = phases,
		finish = finish,
		started = os.clock(),
		drawn = nil,
		parts = {},
		light = light,
		anchor = anchor,
		falloff = DistantStorms.skyFlash(distance, true, DayCycle.skyBrightness(LightingController.dayTime())),
		glow = CloudView.glow(x, z),
	})
	-- The thunder when it gets here.
	thunder(x, y, z, distance, distantSettings(), 1)
end

local function step()
	local flash = 0
	local now = os.clock()
	local glow = Config.Weather.Distant.Glow
	local index = 1
	while index <= #bolts do
		local bolt = bolts[index]
		local tick = math.floor((now - bolt.started) * 20)
		local phase, flashing = LightningBolt.at(bolt.phases, bolt.finish, tick)
		if phase == nil then
			remove(index)
			continue
		end
		if bolt.drawn ~= phase.seed then
			draw(bolt, phase.seed)
		end
		local brightness = if flashing then FLASH_LIGHT else 0
		if bolt.light.Brightness ~= brightness then
			bolt.light.Brightness = brightness
		end
		if bolt.glow then
			CloudView.light(bolt.glow, if flashing then glow else 0)
		end
		if flashing then
			flash = math.max(flash, bolt.falloff)
		end
		index += 1
	end
	index = 1
	while index <= #fars do
		local far = fars[index]
		local tick = math.floor((now - far.started) * 20)
		local phase, flashing = LightningBolt.at(far.phases, far.finish, tick)
		if phase == nil then
			removeFar(index)
			continue
		end
		if far.drawn ~= phase.seed then
			drawFar(far, phase.seed)
		end
		if far.glow then
			CloudView.light(far.glow, if flashing then glow else 0)
		end
		if flashing then
			flash = math.max(flash, far.falloff)
		end
		index += 1
	end
	local effect = correction
	if effect then
		local value = flash
			* Config.Weather.Bolt.Flash
			* LightingController.skyExposure()
			* (1 - EffectView.blindness())
		if math.abs(value - flashWritten) > 0.005 then
			flashWritten = value
			effect.Brightness = value
			effect.Enabled = value > 0
		end
	end
end

--[[
	A distant storm's flash (Weather/StormView; DistantStorms.Event): a bolt to the ground at the
	column's natural height (the generator's, its sea's surface over water: DistantStorms
	.groundAt), else a flash in the cloud.
]]
function LightningView.distant(event: DistantStorms.Event)
	local y = WeatherState.seaLevel()
	if event.ground then
		local _, ground = WeatherState.temperatureAt(event.x, event.z)
		y = DistantStorms.groundAt(ground, y)
	end
	showFar(event.x, y, event.z, event.ground, event.seed, event.flashes)
end

-- Near bolts showing now, and distant flashes (bolts or in the cloud) (F3).
function LightningView.count(): (number, number)
	return #bolts, #fars
end

-- Starts drawing the server's lightning and the distant storms', `distance()` the view distance.
function LightningView.start(distance: () -> number)
	viewDistance = distance
	local root = Instance.new("Folder")
	root.Name = "IceVoxelLightning"
	root.Parent = workspace
	folder = root
	local anchor = Instance.new("Part")
	anchor.Name = "FarBolts"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one
	anchor.CFrame = CFrame.identity
	pcall(function()
		(anchor :: any).AudioCanCollide = false
	end)
	anchor.Parent = root
	farAnchor = anchor
	local effect = Instance.new("ColorCorrectionEffect")
	effect.Name = "IceVoxelLightning"
	effect.Brightness = 0
	effect.Enabled = false
	effect.Parent = Lighting
	correction = effect
	ClientNet.on(Protocol.ServerMessage.Lightning, function(payload: buffer)
		local bolt = Protocol.decodeLightning(payload)
		if bolt then
			strike(bolt)
		end
	end)
	RunService.Heartbeat:Connect(step)
end

return LightningView
