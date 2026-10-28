--!strict
--[[
	Terraria's sounds (not Minecraft's; Config.Accessories, Mana): a Cloud in a Bottle's jump in the
	air (entity.player.double_jump: Terraria's puff; the jumper's client plays it at once and the
	others' clients when they see the air jump), a Mana Crystal used (item.mana_crystal.use:
	Terraria's crystal chime, from the server), a magic weapon cast (item.magic.cast: predicted,
	like an attack) and its projectile hitting something (entity.magic.hit, from the server), a
	Fallen Star falling (entity.fallen_star.fall: Terraria's whoosh, from the server near it), and
	mana full again after it was spent (entity.player.mana_full: Terraria's soft chime, the player's
	own client, flat). Stand-ins: the rustle pitched up into a puff, the menu's tick as chimes, the
	splash pitched up into a fizz, the falling wind pitched up. Give a Sound of an event's name to
	use a real one (README, "Sounds").
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)

type SoundSpec = Schema.SoundSpec

return function(define: Define.Context): { SoundSpec }
	local SHIPPED = define.SHIPPED
	return {
		{
			name = "entity.player.double_jump",
			id = SHIPPED.GET_UP,
			volume = 0.5,
			pitch = 1.5,
			pitchVariance = 0.05,
			source = "players",
			side = "client",
		},
		{
			name = "item.mana_crystal.use",
			id = SHIPPED.TICK,
			volume = 0.8,
			pitch = 1.4,
			duration = 0.8,
			source = "players",
			side = "server",
		},
		{
			name = "item.magic.cast",
			id = SHIPPED.SPLASH,
			volume = 0.35,
			pitch = 2.2,
			pitchVariance = 0.1,
			duration = 0.3,
			source = "players",
			side = "predicted",
		},
		{
			name = "entity.magic.hit",
			id = SHIPPED.SPLASH,
			volume = 0.4,
			pitch = 1.7,
			pitchVariance = 0.15,
			duration = 0.4,
			source = "players",
			side = "server",
		},
		{
			name = "entity.fallen_star.fall",
			id = SHIPPED.FALLING,
			volume = 0.6,
			pitch = 1.8,
			pitchVariance = 0.1,
			duration = 1.5,
			maxDistance = 48,
			source = "ambient",
			side = "server",
		},
		{
			name = "entity.player.mana_full",
			id = SHIPPED.TICK,
			volume = 0.4,
			pitch = 2,
			duration = 0.4,
			ui = true,
			source = "ui",
			side = "client",
		},
	}
end
