--!strict
--[[
	Weather (client Weather/PrecipitationView, Weather/LightningView, Weather/StormView and
	Weather/WindSound, each client by itself, as Minecraft's sound source WEATHER, which here is the
	ambient volume). Stand-ins; give a Sound of an event's name to use a real one (README,
	"Sounds": the game ships its own in SoundService.IceVoxelSounds, src/sounds).

	  * Minecraft 1.20.1. LevelRenderer.tickRain: rain landing near the player (weather.rain,
	    volume 0.2, pitch 1) or on a roof over them (weather.rain.above, 0.1, 0.5), a sound every
	    2-3 ticks while it rains, louder with the precipitation here (Shared/Weather.rainSound:
	    those volumes are the cue's); a few at once make the downpour (`limit`). LightningBolt.tick:
	    thunder (entity.lightning_bolt.thunder, Minecraft's volume 10000, heard everywhere, pitch
	    0.8..1) and the strike's crack (entity.lightning_bolt.impact, volume 2, pitch 0.5..0.7),
	    the thunder later the farther the bolt (Shared/Weather.thunderDelay). The falling wind
	    pitched up into a hiss for rain (down and muffled on a roof), the explosion pitched far
	    down into a rumble for thunder and half down for the crack.
	  * Distant storms (not Minecraft's, which has no weather far off): thunder from a strike or a
	    flash in the clouds far away (entity.lightning_bolt.thunder.far: the thunder's stand-in
	    pitched lower still; its category is the thunder, so a developer's Sound named
	    entity.lightning_bolt.thunder plays here too unless one of this name is given), played
	    muffled, lower and longer the farther it is (Weather/DistantStorms), on voices of its own
	    (SoundPlayer.playDistant); and the hiss of rain falling nearby but not here
	    (weather.rain.far: the rain's stand-in, lower, looped and muffled while it lasts, one bed).
	  * Wind (not Minecraft's, which has none): a loop around the player outdoors (weather.wind),
	    louder in a stronger wind, in a storm and high up, quieter and duller under a roof, silent
	    underground. The falling wind pitched down.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type SoundSpec = Schema.SoundSpec

return function(define: Define.Context): { SoundSpec }
	local SHIPPED = define.SHIPPED
	local FALLING, EXPLOSION = SHIPPED.FALLING, SHIPPED.EXPLOSION
	return {
		{
			name = "weather.rain",
			id = FALLING,
			volume = 0.9,
			pitch = 1.9,
			pitchVariance = 0.1,
			duration = 1.6,
			source = "ambient",
			side = "client",
			limit = 4,
		},
		{
			name = "weather.rain.above",
			id = FALLING,
			volume = 1,
			pitch = 1.1,
			pitchVariance = 0.08,
			duration = 1.6,
			source = "ambient",
			side = "client",
			limit = 3,
		},
		{
			name = "entity.lightning_bolt.thunder",
			id = EXPLOSION,
			volume = 1,
			pitch = 0.32,
			pitchVariance = 0.05,
			maxDistance = 48,
			source = "ambient",
			side = "client",
			limit = 3,
		},
		{
			name = "entity.lightning_bolt.impact",
			id = EXPLOSION,
			volume = 0.8,
			pitch = 0.6,
			pitchVariance = 0.1,
			maxDistance = 32,
			source = "ambient",
			side = "client",
			limit = 2,
		},
		{
			name = "entity.lightning_bolt.thunder.far",
			category = "entity.lightning_bolt.thunder",
			id = EXPLOSION,
			volume = 1,
			pitch = 0.27,
			pitchVariance = 0.06,
			maxDistance = 48,
			source = "ambient",
			side = "client",
		},
		{
			name = "weather.rain.far",
			id = FALLING,
			volume = 0.7,
			pitch = 1.45,
			pitchVariance = 0,
			source = "ambient",
			side = "client",
			limit = 1,
		},
		{
			name = "weather.wind",
			id = FALLING,
			volume = 0.5,
			pitch = 0.6,
			pitchVariance = 0,
			source = "ambient",
			side = "client",
		},
	}
end
