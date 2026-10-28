--!strict
--[[
	Buckets (BucketItem): filling one at the player (a players sound in Minecraft), emptying one
	where the fluid goes (a blocks sound); with a fluid tank, at the tank. Both are splashes, a
	light high one in, a heavier low one out. A bucket filled with lava or oil, or emptied, sounds
	thicker than water (item.bucket.fill_lava, item.bucket.empty_lava; Fluids `fillSound`,
	`emptySound`), in the plain bucket sounds' categories: the splash pitched down.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type SoundSpec = Schema.SoundSpec

return function(define: Define.Context): { SoundSpec }
	local SPLASH = define.SHIPPED.SPLASH
	return {
		{
			name = "item.bucket.fill",
			id = SPLASH,
			volume = 0.5,
			pitch = 1.35,
			pitchVariance = 0.1,
			source = "players",
			side = "server",
		},
		{
			name = "item.bucket.empty",
			id = SPLASH,
			volume = 0.6,
			pitch = 0.8,
			pitchVariance = 0.1,
			source = "blocks",
			side = "server",
		},
		{
			name = "item.bucket.fill_lava",
			category = "item.bucket.fill",
			id = SPLASH,
			volume = 0.5,
			pitch = 0.7,
			pitchVariance = 0.1,
			source = "players",
			side = "server",
		},
		{
			name = "item.bucket.empty_lava",
			category = "item.bucket.empty",
			id = SPLASH,
			volume = 0.6,
			pitch = 0.5,
			pitchVariance = 0.1,
			source = "blocks",
			side = "server",
		},
	}
end
