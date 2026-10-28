--!strict
--[[
	The player's sounds:

	  * items picked up (at the item, ItemEntity.playerTouch) and a tool wearing out (at its owner);
	  * hurt and death; a landing that hurts: up to 4 half hearts small, more big
	    (LivingEntity.getFallDamageSound, Shared/Sounds.fall);
	  * falling into water and swimming (at most three swim strokes at once: a crowd in a lake);
	  * a hit landing (entity.player.attack.strong, or .weak before the weapon recovered:
	    Player.attack, 1.9's attack strength): the fifth sheet's "Entity Hit"
	    (Content/Define's RECORDINGS.ENTITY_HIT), the landing thud its fallback;
	  * eating: entity.generic.eat every 4 ticks from the 7th of the 32 tick hold, and
	    entity.player.burp at the end (Player.eat; the eater's client plays its own, the server the
	    last one to everyone else). The bites now play only when the eating loop's recording fails
	    to load (entity.generic.eating). Stand-ins: a footstep into a bite, a swim stroke pitched
	    down into a burp;
	  * the eating loop (the fourth sheet's "Main SFX": "loop this during eating"; this game's, as
	    Minecraft clicks entity.generic.eat every 4 ticks instead). While a player holds the use
	    button on a food (not medicine, which keeps its own sound), the recording loops at their
	    mouth and stops the moment the use ends: finished, cancelled, the slot changed, dead or
	    gone (client Audio/UseSounds, by the rules of Audio/UseSoundRules). The user's own client
	    plays theirs at once from its own hold, every other client from the server's player
	    attribute (Inventory/Types.USE_ATTRIBUTE). Only when the recording fails to load
	    (Audio/SoundPlayer.loads) do the old clicks play instead, never both; the burp after a food
	    stays. The id is the recording itself (no stand-in: the clicks are its fallback); swap it
	    here, or give a Sound of the event's name in SoundService.IceVoxelSounds, which loops too.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type SoundSpec = Schema.SoundSpec

return function(define: Define.Context): { SoundSpec }
	local SHIPPED = define.SHIPPED
	local LAND = SHIPPED.LAND
	return {
		{
			name = "entity.item.pickup",
			id = LAND,
			volume = 0.3,
			pitch = 2.2,
			pitchVariance = 0.6,
			source = "players",
			side = "server",
		},
		{
			name = "entity.item.break",
			id = LAND,
			volume = 0.8,
			pitch = 1.9,
			pitchVariance = 0.2,
			source = "players",
			side = "server",
		},
		{
			name = "entity.player.hurt",
			id = SHIPPED.OUCH,
			volume = 0.6,
			pitchVariance = 0.1,
			source = "players",
			side = "server",
		},
		{ name = "entity.player.death", id = SHIPPED.OOF, volume = 0.7, source = "players", side = "server" },
		{ name = "entity.player.small_fall", id = LAND, volume = 0.6, source = "players", side = "predicted" },
		{
			name = "entity.player.big_fall",
			id = LAND,
			volume = 1,
			pitch = 0.7,
			source = "players",
			side = "predicted",
		},
		{
			name = "entity.generic.splash",
			id = SHIPPED.SPLASH,
			volume = 0.5,
			pitchVariance = 0.2,
			source = "players",
			side = "client",
		},
		{
			name = "entity.generic.swim",
			id = SHIPPED.SWIM,
			volume = 0.3,
			pitch = 1.6,
			pitchVariance = 0.2,
			source = "players",
			side = "client",
			limit = 3,
		},
		{
			name = "entity.player.attack.strong",
			category = "entity.player.attack",
			id = define.RECORDINGS.ENTITY_HIT,
			volume = 0.6,
			pitchVariance = 0.08,
			fallback = { id = LAND, pitch = 1.3 },
			source = "players",
			side = "server",
		},
		{
			name = "entity.player.attack.weak",
			category = "entity.player.attack",
			id = define.RECORDINGS.ENTITY_HIT,
			volume = 0.35,
			pitch = 1.15,
			pitchVariance = 0.08,
			fallback = { id = LAND, pitch = 1.8 },
			source = "players",
			side = "server",
		},
		{
			name = "entity.generic.eat",
			id = SHIPPED.STEPS,
			volume = 0.5,
			pitch = 1.8,
			pitchVariance = 0.2,
			duration = 0.15,
			source = "players",
			side = "predicted",
		},
		{
			name = "entity.player.burp",
			id = SHIPPED.SWIM,
			volume = 0.5,
			pitch = 0.7,
			pitchVariance = 0.1,
			duration = 0.4,
			source = "players",
			side = "predicted",
		},
		{
			name = "entity.generic.eating",
			id = "rbxassetid://124005963174357",
			volume = 0.6,
			pitchVariance = 0.05,
			source = "players",
			side = "client",
		},
	}
end
