--!strict
--[[
	Lava (Minecraft 1.20.1). LavaFluid.animateTick: lava open to the air above pops now and then
	(block.lava.pop, cue volume 0.2..0.4, pitch 0.9..1.05), each client by itself (Audio/Ambience);
	its bubbling is the fifth data sheet's "Lava Ambient" (block.lava.ambient, 1:14 looped, bubbling
	included; the old wind its fallback), looped at the nearest lava open to the air the client has
	found (Audio/Ambience, SoundRules.lavaLoop) instead of Minecraft's one bubble in 200.
	LiquidBlock.fizz: lava hardening against water and lava turning water to stone hiss
	(block.lava.extinguish, volume 0.5, pitch 2.6 +- 0.8; server Behaviours/Fluid). Burning: a hurt
	by lava sizzles (entity.generic.burn, volume 0.4, pitch 2..2.4: Entity.lavaHurt, a player's or
	an item's), water putting a burning player out hisses (entity.generic.extinguish_fire, volume
	0.7, pitch 1.6 +- 0.4, a triangle here flattened to +- 0.25). These carry Minecraft's numbers
	themselves: the server plays them with no cue volume or pitch on top. Stand-ins: the splash
	pitched up for the pop, the falling wind pitched up into a hiss or down into a rumble. (Lava's
	and oil's buckets are with the buckets.)
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type SoundSpec = Schema.SoundSpec

return function(define: Define.Context): { SoundSpec }
	local SHIPPED = define.SHIPPED
	local FALLING, SPLASH = SHIPPED.FALLING, SHIPPED.SPLASH
	return {
		{
			name = "block.lava.pop",
			id = SPLASH,
			volume = 0.7,
			pitch = 2.2,
			pitchVariance = 0.08,
			duration = 0.2,
			source = "blocks",
			side = "client",
		},
		{
			name = "block.lava.ambient",
			-- (The fifth sheet's "Lava Ambient".)
			id = "rbxassetid://318794788",
			volume = 0.6,
			fallback = { id = FALLING, pitch = 0.45, duration = 1.5 },
			source = "blocks",
			side = "client",
		},
		{
			name = "block.lava.extinguish",
			id = FALLING,
			volume = 0.5,
			pitch = 2.6,
			pitchVariance = 0.3,
			duration = 0.6,
			fallback = { id = SPLASH, pitch = 2.2 },
			source = "blocks",
			side = "server",
		},
		{
			name = "entity.generic.burn",
			id = FALLING,
			volume = 0.4,
			pitch = 2.2,
			pitchVariance = 0.2,
			duration = 0.35,
			fallback = { id = SPLASH, pitch = 2.5 },
			source = "players",
			side = "server",
		},
		{
			name = "entity.generic.extinguish_fire",
			id = FALLING,
			volume = 0.7,
			pitch = 1.6,
			pitchVariance = 0.25,
			duration = 0.5,
			fallback = { id = SPLASH, pitch = 1.8 },
			source = "players",
			side = "server",
		},
	}
end
