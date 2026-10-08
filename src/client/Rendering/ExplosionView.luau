--!strict
--[[
	Explosions as this player sees and feels them (the server's Explosion messages, Minecraft's
	ClientboundExplodePacket: server World/Explosions through Players/Characters):

	  Look       a Roblox Explosion at the centre, its size from the power (BLAST_SCALE blocks of
	             radius per power, at most MAX_BLAST blocks): BlastPressure 0 and
	             DestroyJointRadiusPercent 0, so it only draws (Minecraft's explosion particles;
	             the blocks come as ordinary edits and the sound, entity.generic.explode, as the
	             server's Sound message).
	  Knockback  added to the hull's velocity (MovementController.knockback; the server worked
	             out how hard this player was hit, nothing for players it didn't reach).
	  Shake      the camera shakes a moment (this game's addition), `shake`: within
	             Config.Explosions.ShakeDistance x power blocks, stronger the closer and the
	             more powerful (full from power 4 up), fading over SHAKE_SECONDS; several add up
	             (at most full). Turned after the camera updates, so it never drifts.
	  Nuke       a blast of Config.Nuke.LookPower or more (`isNuke`: the Nuke's, server
	             World/Nuke) looks the part, all of it anchored, inert parts that fade and go:
	             a white flash over the screen (`flash`: full within a quarter of
	             Config.Nuke.EffectDistance, fading to nothing at it), a larger Roblox Explosion
	             (up to NUKE_BLAST blocks), a fireball swelling to the crater's size, a shock ring
	             racing out along the ground, and a mushroom cloud (a stem and a cap) rising
	             CLOUD_RISE blocks over CLOUD_SECONDS, from fire to smoke, then fading. Six
	             parts and a frame, gone after CLOUD_SECONDS + 5 s. The shake lasts NUKE_SHAKE_SECONDS and turns up to
	             NUKE_SHAKE_DEGREES.

	`shake`, `isNuke` and `flash` are pure (tests/spec/Tnt, Explosions); everything Roblox is set
	up in `start`.

	The floating origin (Shared/World/Origin): the Explosion is put at render studs from the
	message's world blocks (it lasts 3 s and is not a part: a move meanwhile leaves it where it
	was); the shake's distance reads the camera's focus back into world blocks. The Nuke's six parts
	are placed every frame from its world centre and how far along the cloud is (`placeNukes`, a
	render step after the origin's: Sine out, as the tweens it replaced), so a move of the origin
	is never undone by a CFrame tween; only sizes, colours and transparency are tweened.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Protocol = require(Shared.Net.Protocol)
local Origin = require(Shared.World.Origin)

local ExplosionView = {}

-- A Nuke being drawn: its centre (world blocks) and parts, placed every frame.
type Nuke = {
	start: number,
	x: number,
	y: number,
	z: number,
	radius: number,
	folder: Folder,
	ball: Part,
	ring: Part,
	stem: Part,
	caps: { Part },
	-- Each cap's start offset from the centre (studs).
	offsets: { Vector3 },
}

local BLOCK = Config.BlockSize
-- Radius of the drawn blast: blocks per power, and at most.
local BLAST_SCALE = 0.75
local MAX_BLAST = 8
-- How long a shake lasts (s) and how far the camera turns at full strength (degrees).
local SHAKE_SECONDS = 0.45
local MAX_SHAKE_DEGREES = 1.6
-- Power from which a blast shakes fully (TNT's).
local FULL_SHAKE_POWER = 4
-- How fast the shake wobbles (noise per second).
local SHAKE_RATE = 28
-- The Nuke's look: the Roblox Explosion's radius (blocks) at most, the shake, the cloud.
local NUKE_BLAST = 24
local NUKE_SHAKE_SECONDS = 2.5
local NUKE_SHAKE_DEGREES = 4
local CLOUD_RISE = 60
local CLOUD_SECONDS = 9
local FLASH_SECONDS = 1.6

-- Is a blast of `power` the Nuke's (drawn as one)?
function ExplosionView.isNuke(power: number): boolean
	return power >= Config.Nuke.LookPower
end

-- How bright (0..1) the Nuke's flash is for a player `distance` blocks away: full within a
-- quarter of Config.Nuke.EffectDistance, then fading to 0 at it.
function ExplosionView.flash(distance: number): number
	local range = Config.Nuke.EffectDistance
	local full = range / 4
	if not (distance < range) then
		return 0
	elseif distance <= full then
		return 1
	end
	return 1 - (distance - full) / (range - full)
end

--[[
	How hard (0..1) a blast of `power` shakes the camera of a player `distance` blocks from it:
	1 - distance / (ShakeDistance x power), times power / FULL_SHAKE_POWER up to 1; 0 beyond.
]]
function ExplosionView.shake(distance: number, power: number): number
	local reach = Config.Explosions.ShakeDistance * power
	if not (reach > 0) or not (distance < reach) then
		return 0
	end
	return (1 - math.max(distance, 0) / reach) * math.min(1, power / FULL_SHAKE_POWER)
end

function ExplosionView.start()
	local RunService = game:GetService("RunService")
	local Debris = game:GetService("Debris")
	local ClientNet = require(script.Parent.Parent.Net.ClientNet)
	local MovementController = require(script.Parent.Parent.Player.MovementController)

	local TweenService = game:GetService("TweenService")
	local Players = game:GetService("Players")

	-- Shakes going on: when each started, how hard, how long and how far it turns (degrees).
	local shakes: { { start: number, strength: number, seconds: number, degrees: number } } = {}

	-- An anchored, inert part for the Nuke's look.
	local function effectPart(shape: Enum.PartType, colour: Color3, material: Enum.Material): Part
		local part = Instance.new("Part")
		part.Shape = shape
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Locked = true
		part.Material = material
		part.Color = colour
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		return part
	end

	local function tween(instance: Instance, seconds: number, goal: { [string]: any }, style: Enum.EasingStyle?)
		TweenService
			:Create(instance, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal)
			:Play()
	end

	-- Nukes being drawn (placeNukes).
	local nukes: { Nuke } = {}
	local QUARTER_TURN = CFrame.Angles(0, 0, math.pi / 2)

	-- Every Nuke's parts where they are now: from the world centre for the render origin now and
	-- the cloud's progress (Sine out over CLOUD_SECONDS, as the tweens it replaced).
	local function placeNukes()
		local now = os.clock()
		local rise = CLOUD_RISE * BLOCK
		for i = #nukes, 1, -1 do
			local entry = nukes[i]
			local age = now - entry.start
			if entry.folder.Parent == nil or age > CLOUD_SECONDS + 5 then
				table.remove(nukes, i)
				continue
			end
			local alpha = math.sin(math.min(age / CLOUD_SECONDS, 1) * math.pi / 2)
			local origin = Vector3.new(entry.x * BLOCK - Origin.x, entry.y * BLOCK, entry.z * BLOCK - Origin.z)
			local radius = entry.radius
			entry.ball.CFrame = CFrame.new(origin)
			entry.ring.CFrame = CFrame.new(origin) * QUARTER_TURN
			local stemY = radius * 0.25 + (rise / 2 - radius * 0.25) * alpha
			entry.stem.CFrame = CFrame.new(origin + Vector3.new(0, stemY, 0)) * QUARTER_TURN
			for k, cap in entry.caps do
				local offset = entry.offsets[k]
				-- (Out to 1.8 times its offset, up to the top of the rise.)
				local cx, cy = offset.X * (1 + 0.8 * alpha), offset.Y + (rise - offset.Y) * alpha
				cap.CFrame = CFrame.new(origin + Vector3.new(cx, cy, 0))
			end
		end
	end

	-- The Nuke's look at (x, y, z) (world blocks), `distance` blocks from the camera.
	local function nuke(x: number, y: number, z: number, distance: number)
		local origin = Vector3.new(x * BLOCK - Origin.x, y * BLOCK, z * BLOCK - Origin.z)
		local radius = Config.Nuke.Radius * BLOCK
		local folder = Instance.new("Folder")
		folder.Name = "IceVoxelNuke"
		-- Fireball: swells to the crater's size and fades.
		local ball = effectPart(Enum.PartType.Ball, Color3.fromRGB(255, 214, 120), Enum.Material.Neon)
		ball.Size = Vector3.one * 2 * BLOCK
		ball.CFrame = CFrame.new(origin)
		ball.Parent = folder
		tween(ball, 1.2, { Size = Vector3.one * radius * 2, Transparency = 1, Color = Color3.fromRGB(255, 90, 30) })
		-- Shock ring: a flat disc racing out along the ground.
		local ring = effectPart(Enum.PartType.Cylinder, Color3.fromRGB(255, 240, 220), Enum.Material.Neon)
		ring.Size = Vector3.new(0.4 * BLOCK, 2 * BLOCK, 2 * BLOCK)
		ring.CFrame = CFrame.new(origin) * CFrame.Angles(0, 0, math.pi / 2)
		ring.Transparency = 0.3
		ring.Parent = folder
		tween(ring, 2, {
			Size = Vector3.new(0.4 * BLOCK, radius * 6, radius * 6),
			Transparency = 1,
		})
		-- Mushroom cloud: a stem and a cap rising, fire turning to smoke, then fading.
		local rise = CLOUD_RISE * BLOCK
		local stem = effectPart(Enum.PartType.Cylinder, Color3.fromRGB(255, 150, 60), Enum.Material.Neon)
		stem.Size = Vector3.new(radius * 0.5, radius * 0.4, radius * 0.4)
		stem.CFrame = CFrame.new(origin + Vector3.new(0, radius * 0.25, 0)) * CFrame.Angles(0, 0, math.pi / 2)
		stem.Transparency = 0.1
		stem.Parent = folder
		tween(stem, CLOUD_SECONDS, {
			Size = Vector3.new(rise, radius * 0.5, radius * 0.5),
			Color = Color3.fromRGB(96, 88, 84),
		}, Enum.EasingStyle.Sine)
		local caps: { Part } = {}
		local offsets: { Vector3 } = {}
		for i, scale in { 1, 0.7, 1.3 } do
			local cap = effectPart(Enum.PartType.Ball, Color3.fromRGB(255, 170, 70), Enum.Material.Neon)
			local size = radius * scale
			cap.Size = Vector3.one * size
			local offset = Vector3.new((i - 2) * radius * 0.35, radius * 0.6, 0)
			cap.CFrame = CFrame.new(origin + offset)
			cap.Transparency = 0.05
			cap.Parent = folder
			tween(cap, CLOUD_SECONDS, {
				Size = Vector3.new(size * 2.2, size * 1.1, size * 2.2),
				Color = Color3.fromRGB(120, 110, 104),
			}, Enum.EasingStyle.Sine)
			table.insert(caps, cap)
			table.insert(offsets, offset)
		end
		-- (Rising: placed every frame from here on.)
		table.insert(nukes, {
			start = os.clock(),
			x = x,
			y = y,
			z = z,
			radius = radius,
			folder = folder,
			ball = ball,
			ring = ring,
			stem = stem,
			caps = caps,
			offsets = offsets,
		})
		-- Smoke (the cloud's fire burns out after a few seconds), then gone.
		task.delay(CLOUD_SECONDS * 0.4, function()
			stem.Material = Enum.Material.SmoothPlastic
			for _, cap in caps do
				cap.Material = Enum.Material.SmoothPlastic
			end
		end)
		task.delay(CLOUD_SECONDS, function()
			tween(stem, 4, { Transparency = 1 })
			for _, cap in caps do
				tween(cap, 4, { Transparency = 1 })
			end
		end)
		folder.Parent = workspace
		Debris:AddItem(folder, CLOUD_SECONDS + 5)

		-- The flash over the screen.
		local brightness = ExplosionView.flash(distance)
		local player = Players.LocalPlayer
		local gui = if player then player:FindFirstChildOfClass("PlayerGui") else nil
		if brightness > 0 and gui then
			local screen = Instance.new("ScreenGui")
			screen.Name = "IceVoxelNukeFlash"
			screen.IgnoreGuiInset = true
			screen.DisplayOrder = 100
			local frame = Instance.new("Frame")
			frame.Size = UDim2.fromScale(1, 1)
			frame.BorderSizePixel = 0
			frame.BackgroundColor3 = Color3.fromRGB(255, 252, 240)
			frame.BackgroundTransparency = 1 - brightness
			frame.Parent = screen
			screen.Parent = gui
			tween(frame, FLASH_SECONDS, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad)
			Debris:AddItem(screen, FLASH_SECONDS + 0.5)
		end
	end

	ClientNet.on(Protocol.ServerMessage.Explosion, function(payload: buffer)
		local effect = Protocol.decodeExplosion(payload)
		if effect == nil then
			return
		end
		local isNuke = ExplosionView.isNuke(effect.power)
		local blast = Instance.new("Explosion")
		blast.Position = Origin.blocksToRender(effect.x, effect.y, effect.z)
		blast.BlastRadius = math.min(effect.power * BLAST_SCALE, if isNuke then NUKE_BLAST else MAX_BLAST) * BLOCK
		blast.BlastPressure = 0
		blast.DestroyJointRadiusPercent = 0
		blast.ExplosionType = Enum.ExplosionType.NoCraters
		blast.Parent = workspace
		Debris:AddItem(blast, 3)

		MovementController.knockback(effect.kx, effect.ky, effect.kz)

		local camera = workspace.CurrentCamera
		if camera then
			local fx, fy, fz = Origin.renderToBlocks(camera.Focus.Position)
			local dx, dy, dz = fx - effect.x, fy - effect.y, fz - effect.z
			local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
			local strength = ExplosionView.shake(distance, effect.power)
			if strength > 0 then
				table.insert(shakes, {
					start = os.clock(),
					strength = strength,
					seconds = if isNuke then NUKE_SHAKE_SECONDS else SHAKE_SECONDS,
					degrees = if isNuke then NUKE_SHAKE_DEGREES else MAX_SHAKE_DEGREES,
				})
			end
			if isNuke then
				nuke(effect.x, effect.y, effect.z, distance)
			end
		end
	end)

	RunService:BindToRenderStep("IceVoxelExplosionShake", Enum.RenderPriority.Camera.Value + 1, function()
		if #nukes > 0 then
			placeNukes()
		end
		if #shakes == 0 then
			return
		end
		local now = os.clock()
		local total = 0
		local degrees = MAX_SHAKE_DEGREES
		for i = #shakes, 1, -1 do
			local shake = shakes[i]
			local age = now - shake.start
			if age >= shake.seconds then
				table.remove(shakes, i)
			else
				total += shake.strength * (1 - age / shake.seconds)
				degrees = math.max(degrees, shake.degrees)
			end
		end
		local camera = workspace.CurrentCamera
		if total > 0 and camera then
			local angle = math.rad(degrees) * math.min(total, 1)
			local t = now * SHAKE_RATE
			camera.CFrame *= CFrame.Angles(math.noise(t, 0.5) * angle, math.noise(0.5, t) * angle, 0)
		end
	end)
end

return ExplosionView
