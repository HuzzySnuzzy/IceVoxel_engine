--!strict
--[[
	Fire, TNT, the Nuke and explosions (Minecraft 1.20.1; the Nuke is this game's).

	  * Fire. BaseFireBlock.animateTick: a fire crackles one time in 24 that the client's random
	    display tick picks it (block.fire.ambient, cue volume 1..2, pitch 0.3..1; Audio/Ambience,
	    SoundRules.fireCrackle), each client by itself; a forest fire crackles all around, as in
	    Minecraft, but a few at a time (`limit`). Punching a fire out sounds like level event 1009
	    (block.fire.extinguish, volume 0.5, pitch 2.6 +- 0.8, as lava's fizz): it is the Fire
	    block's break sound (its entry's `sounds`), so the player who breaks it hears it at once and
	    the server sends it to everyone else; its category is block.break, so a developer's
	    block.break Sound replaces it too. Flint and steel striking (item.flintandsteel.use,
	    FlintAndSteelItem.useOn: volume 1, pitch 0.8..1.2), from the server (Players/ItemUse).
	    Stand-ins: the falling wind pitched down into a low roar for the crackle and up into a hiss
	    for the extinguish, the volume slider's tick pitched down for the strike.
	  * Explosions (server World/Explosions: burning fuel, TNT): Minecraft's
	    entity.generic.explode, played at volume 4 (heard 64 blocks away, its attenuation distance
	    16 x 4) and pitch (1 + (r1 - r2) x 0.2) x 0.7: 0.7 +- 0.14, a triangle here flattened to
	    +- 0.1. The built-in boom (impact_explosion_03), whole, at volume 1 like the loudest events;
	    the server plays it with no cue on top.
	  * TNT and the Nuke (server Behaviours/Tnt, World/Nuke). Lighting TNT hisses
	    (entity.tnt.primed: PrimedTnt's constructor plays it at volume 1, pitch 1, from the
	    server): the falling wind pitched up into a fizz, cut short. The Nuke (no Minecraft sound;
	    this game's): every second while it is lit an alarm beeps (entity.nuke.alarm: the volume
	    tick pitched up, loud, heard 64 blocks away), and it goes off with a deep, long boom
	    (entity.nuke.explode: the explosion pitched far down, heard 256 blocks away).
	No asset of Minecraft's: give a Sound of an event's name to use a real one (README, "Sounds").
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type SoundSpec = Schema.SoundSpec

return function(define: Define.Context): { SoundSpec }
	local SHIPPED = define.SHIPPED
	local FALLING, SPLASH, EXPLOSION = SHIPPED.FALLING, SHIPPED.SPLASH, SHIPPED.EXPLOSION
	return {
		{
			name = "block.fire.ambient",
			id = FALLING,
			volume = 0.3,
			pitch = 0.9,
			pitchVariance = 0.1,
			duration = 1.2,
			fallback = { id = SHIPPED.STEPS, volume = 0.6, pitch = 0.5, duration = define.ONE_STEP },
			source = "blocks",
			side = "client",
			limit = 4,
		},
		{
			name = "block.fire.extinguish",
			category = "block.break",
			id = FALLING,
			volume = 0.5,
			pitch = 2.6,
			pitchVariance = 0.3,
			duration = 0.6,
			fallback = { id = SPLASH, pitch = 2.2 },
			source = "blocks",
			side = "predicted",
		},
		{
			name = "item.flintandsteel.use",
			id = SHIPPED.TICK,
			volume = 0.8,
			pitch = 0.7,
			pitchVariance = 0.2,
			duration = 0.25,
			fallback = { id = SHIPPED.LAND, volume = 0.5, pitch = 2.4 },
			source = "blocks",
			side = "server",
		},
		{
			name = "entity.generic.explode",
			id = EXPLOSION,
			volume = 1,
			pitch = 0.7,
			pitchVariance = 0.1,
			maxDistance = 64,
			source = "blocks",
			side = "server",
		},
		{
			name = "entity.tnt.primed",
			id = FALLING,
			volume = 0.7,
			pitch = 2.2,
			duration = 1.5,
			fallback = { id = SPLASH, pitch = 2.6 },
			source = "blocks",
			side = "server",
		},
		{
			name = "entity.nuke.alarm",
			id = SHIPPED.TICK,
			volume = 1,
			pitch = 1.6,
			duration = 0.4,
			fallback = { id = SHIPPED.LAND, pitch = 3 },
			maxDistance = 64,
			source = "blocks",
			side = "server",
		},
		{
			name = "entity.nuke.explode",
			id = EXPLOSION,
			volume = 1,
			pitch = 0.35,
			pitchVariance = 0.05,
			maxDistance = 256,
			source = "blocks",
			side = "server",
		},
	}
end
