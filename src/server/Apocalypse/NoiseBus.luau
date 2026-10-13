--!strict
--[[
	The zombie apocalypse's noise bus: what zombies hear this tick (Shared/Apocalypse/NoiseRules
	says which sounds are noises and how far they carry). It needs nothing of Roblox but Shared, so
	the tests run it.

	  emit       a noise of `radius` blocks at (x, y, z) (sprinting: Apocalypse/Survival; a
	             screamer's shriek: Mobs/Mobs). One within Config.Apocalypse.Noise.Merge blocks
	             of a noise already heard this tick merges into it (the louder radius), and at
	             most MaxPerTick are kept a tick, so a crowd's racket costs no more than a few.
	  fromSound  every sound the server plays (Audio/Sounds.play calls it with the event's
	             index before its own checks, so muting the game's audio deafens no zombie, and
	             the player spared hearing it is no less heard): its NoiseRules radius, if any.
	  explosion  a blast of `power` (the boot script's Explosions handler): ExplosionBase +
	             ExplosionPerPower x power blocks, at most ExplosionMax (TNT's 4: 56).
	  take       this tick's noises, cleared (server Mobs/Mobs hands them to the zombies, with
	             the night's and the rain's factors applied there).
	A noise carries no "who": a zombie that hears one looks for a target at once (Mobs/MobAI),
	which needs none. With Config.Apocalypse.Enabled or Noise.Enabled false nothing is heard.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Sounds = require(Shared.Sounds)
local NoiseRules = require(Shared.Apocalypse.NoiseRules)

export type Noise = { x: number, y: number, z: number, radius: number }

local NoiseBus = {}

local pending: { Noise } = {}
-- (Each sound event's radius, built when first needed.)
local radii: buffer? = nil

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

-- Hears a noise of `radius` blocks at (x, y, z) this tick (see the header).
function NoiseBus.emit(x: number, y: number, z: number, radius: number)
	local settings = Config.Apocalypse.Noise
	if
		not Config.Apocalypse.Enabled
		or not settings.Enabled
		or not (radius > 0)
		or not (finite(x) and finite(y) and finite(z) and finite(radius))
	then
		return
	end
	local merge = settings.Merge * settings.Merge
	for _, noise in pending do
		local dx, dy, dz = noise.x - x, noise.y - y, noise.z - z
		if dx * dx + dy * dy + dz * dz <= merge then
			noise.radius = math.max(noise.radius, radius)
			return
		end
	end
	if #pending >= settings.MaxPerTick then
		return
	end
	table.insert(pending, { x = x, y = y, z = z, radius = radius })
end

-- The noise of sound event `index` (Shared/Sounds) played at (x, y, z), if it makes one.
function NoiseBus.fromSound(index: number, x: number, y: number, z: number)
	local lut: buffer
	local made = radii
	if made then
		lut = made
	else
		-- (Sounds.events is {Event}; the rules read only each event's name.)
		lut = NoiseRules.lut(Sounds.events :: any, Config.Apocalypse.Noise)
		radii = lut
	end
	if index >= 1 and index < buffer.len(lut) then
		local radius = buffer.readu8(lut, index)
		if radius > 0 then
			NoiseBus.emit(x, y, z, radius)
		end
	end
end

-- The noise of an explosion of `power` at (x, y, z).
function NoiseBus.explosion(x: number, y: number, z: number, power: number)
	local settings = Config.Apocalypse.Noise
	if not (power > 0) then
		return
	end
	NoiseBus.emit(x, y, z, math.min(settings.ExplosionBase + settings.ExplosionPerPower * power, settings.ExplosionMax))
end

-- This tick's noises (a fresh list each call; the bus starts the next tick empty).
function NoiseBus.take(): { Noise }
	local noises = pending
	pending = {}
	return noises
end

return NoiseBus
