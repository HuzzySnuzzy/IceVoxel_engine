--!strict
--[[
	Lightning on this client (Roblox glue over Weather/LightningBolt; the server's Lightning
	message, Protocol.decodeLightning: the struck cell's bottom centre, the shape's seed, 1 to 3
	flashes).

	  Bolt      Minecraft's bolt (LightningBolt.segments: 128 blocks of zigzag and two branches),
	            each segment two Neon parts: a core and a wider see-through glow
	            (Config.Weather.Bolt Color and Glow), redrawn in each flash's new shape and gone
	            when the bolt's life ends (LightningBolt.timeline, 20 ticks a second). Parts are
	            pooled; a few bolts can show at once.
	  Flash     while the sky flashes (life >= 0), a ColorCorrectionEffect ("IceVoxelLightning" in
	            Lighting) brightens the picture by Bolt.Flash, less the farther the strike (half at
	            512 blocks) and indoors (the sky exposure, Rendering/LightingController), and a
	            PointLight at the struck point lights the ground around it (Bolt.LightRange).
	  Sound     the strike's crack (entity.lightning_bolt.impact) at once where it struck (heard
	            within 32 blocks), the thunder (entity.lightning_bolt.thunder) after
	            Weather.thunderDelay(distance) seconds (343 blocks a second), played a few blocks
	            from the listener towards the strike so it is heard everywhere within the
	            message's 1024 blocks, as Minecraft's (volume 10000), fainter the farther it is.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Protocol = require(Shared.Net.Protocol)
local Weather = require(Shared.Weather)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local LightingController = require(script.Parent.Parent.Rendering.LightingController)
local LightningBolt = require(script.Parent.LightningBolt)

local BLOCK = Config.BlockSize
-- Bolts drawn at once at most (older ones give way).
local MAX_BOLTS = 3
-- How far from the listener the thunder plays (blocks), towards the strike.
local THUNDER_OFFSET = 8
-- The struck point's light while the sky flashes (PointLight brightness).
local FLASH_LIGHT = 6

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
}

local LightningView = {}

local bolts: { Bolt } = {}
local pool: { Part } = {}
local folder: Folder? = nil
local correction: ColorCorrectionEffect? = nil
local flashWritten = 0

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
	local colour = Color3.fromRGB(settings.Color[1], settings.Color[2], settings.Color[3])
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
	table.remove(bolts, index)
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
	light.Color = Color3.fromRGB(settings.Color[1], settings.Color[2], settings.Color[3])
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
		falloff = 1 / (1 + distance / 512),
	})
	-- The crack where it struck, at once; the thunder when it gets here.
	SoundPlayer.play("entity.lightning_bolt.impact", x, y + 0.5, z)
	local delay = Weather.thunderDelay(distance)
	local volume = math.clamp(1.2 - distance / Config.Weather.Lightning.Distance, 0.35, 1)
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
end

local function step()
	local flash = 0
	local now = os.clock()
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
		if flashing then
			flash = math.max(flash, bolt.falloff)
		end
		index += 1
	end
	local effect = correction
	if effect then
		local value = flash * Config.Weather.Bolt.Flash * LightingController.skyExposure()
		if math.abs(value - flashWritten) > 0.005 then
			flashWritten = value
			effect.Brightness = value
			effect.Enabled = value > 0
		end
	end
end

-- Bolts showing now (F3).
function LightningView.count(): number
	return #bolts
end

-- Starts drawing the server's lightning.
function LightningView.start()
	local root = Instance.new("Folder")
	root.Name = "IceVoxelLightning"
	root.Parent = workspace
	folder = root
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
