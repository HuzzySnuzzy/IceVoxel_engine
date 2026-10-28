--!strict
--[[
	The block sound types (Minecraft's SoundType; a block names its type, `sound`): each type's
	five events, block.<type>.break, .place, .hit, .step and .fall, from its clips by Content/
	Define's `blockSounds`, which scales them per action as Minecraft does and gives breaking and
	placing the fourth data sheet's recordings.

	With one break, one place and one footstep recording for everything, the pitch tells the
	materials apart, each type a step above the last when broken or placed: wool 0.6, gravel 0.72,
	stone 0.8, sand 0.88, wood 0.96, grass 1.08, ringing metal 1.2 (Minecraft's metal is its stone
	sounds at pitch 1.5), snow 1.32. Glass is placed, walked on and hit like stone, as in
	Minecraft, and shatters when broken; water uses the splash and swimming sounds. Breaking and
	placing play the sheet's recordings at each type's `dig` volume, pitch and variance, so every
	type keeps its own; `dig`, the thud, is their fallback should a recording fail to load. A
	developer's Sound named block.<type>.break (or block.break) still replaces them.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type SoundSpec = Schema.SoundSpec

return function(define: Define.Context): { SoundSpec }
	local SHIPPED = define.SHIPPED
	local LAND, STEPS = SHIPPED.LAND, SHIPPED.STEPS
	local ONE_STEP = define.ONE_STEP
	local list: { SoundSpec } = {}
	for _, soundType in
		{
			{
				name = "stone",
				volume = 1,
				pitch = 1,
				dig = { id = LAND, volume = 0.8, pitchVariance = 0.05 },
				step = { id = STEPS, volume = 1.6, pitch = 0.9, pitchVariance = 0.05, duration = ONE_STEP },
			},
			{
				name = "wood",
				volume = 1,
				pitch = 1.2,
				dig = { id = LAND, volume = 0.8, pitchVariance = 0.05 },
				step = { id = STEPS, volume = 1.6, pitchVariance = 0.05, duration = ONE_STEP },
			},
			{
				name = "gravel",
				volume = 1,
				pitch = 0.9,
				dig = { id = LAND, volume = 0.85, pitchVariance = 0.1 },
				step = { id = STEPS, volume = 1.6, pitch = 0.85, pitchVariance = 0.1, duration = ONE_STEP },
			},
			{
				name = "grass",
				volume = 0.8,
				pitch = 1.35,
				dig = { id = LAND, volume = 0.8, pitchVariance = 0.08 },
				step = { id = STEPS, volume = 1.6, pitchVariance = 0.08, duration = ONE_STEP },
			},
			{
				name = "sand",
				volume = 0.8,
				pitch = 1.2,
				dig = { id = LAND, volume = 0.8, pitch = 0.92, pitchVariance = 0.08 },
				step = { id = STEPS, volume = 1.6, pitch = 0.9, pitchVariance = 0.08, duration = ONE_STEP },
			},
			{
				name = "glass",
				volume = 1,
				pitch = 1,
				dig = { id = LAND, volume = 0.8, pitchVariance = 0.05 },
				step = { id = STEPS, volume = 1.6, pitch = 0.9, pitchVariance = 0.05, duration = ONE_STEP },
				actions = {
					-- The crack of an explosion, sped up and cut short: a shatter.
					["break"] = {
						id = SHIPPED.EXPLOSION,
						volume = 0.25,
						pitch = 2.5,
						pitchVariance = 0.2,
						duration = 0.4,
						fallback = { id = LAND, volume = 0.8, pitch = 2.2 },
					},
				},
			},
			{
				name = "snow",
				volume = 0.8,
				pitch = 1.65,
				dig = { id = LAND, volume = 0.7, pitchVariance = 0.08 },
				step = { id = STEPS, volume = 1.4, pitchVariance = 0.08, duration = ONE_STEP },
			},
			{
				name = "metal",
				volume = 1,
				pitch = 1.5,
				dig = { id = LAND, volume = 0.8, pitchVariance = 0.05 },
				step = { id = STEPS, volume = 1.6, pitchVariance = 0.05, duration = ONE_STEP },
			},
			{
				name = "wool",
				volume = 0.8,
				pitch = 0.75,
				dig = { id = LAND, volume = 0.5, pitchVariance = 0.05 },
				step = { id = STEPS, volume = 1.2, pitch = 0.85, pitchVariance = 0.05, duration = ONE_STEP },
			},
			{
				name = "water",
				volume = 1,
				pitch = 1,
				-- (Placing water is Minecraft's bucket emptying: a splash, for breaking too, not the
				-- recordings.)
				dig = { id = SHIPPED.SPLASH, volume = 0.5, pitch = 1.25, pitchVariance = 0.1 },
				step = { id = SHIPPED.SWIM, volume = 1.6, pitch = 1.6, pitchVariance = 0.1, duration = 0.5 },
				recorded = false,
			},
			--[[
				Ladders, rope, vines (and hanging roots) and moss (Minecraft's SoundType.LADDER, VINE
				and MOSS / MOSS_CARPET, Supplementaries' rope): a ladder a woody step just under
				wood's (a climber hears it every metre and a half), rope a dull low one, vines a light
				rustle above grass, moss a soft step between wood and grass. Every step pitch stays
				apart from the others'.
			]]
			{
				name = "ladder",
				volume = 1,
				pitch = 1,
				dig = { id = LAND, volume = 0.8, pitch = 1.05, pitchVariance = 0.05 },
				step = { id = STEPS, volume = 1.6, pitchVariance = 0.05, duration = ONE_STEP },
			},
			{
				name = "rope",
				volume = 0.8,
				pitch = 0.85,
				dig = { id = LAND, volume = 0.6, pitchVariance = 0.05 },
				step = { id = STEPS, volume = 1.2, pitch = 0.85, pitchVariance = 0.05, duration = ONE_STEP },
			},
			{
				name = "vine",
				volume = 1,
				pitch = 1.45,
				dig = { id = LAND, volume = 0.7, pitchVariance = 0.08 },
				step = { id = STEPS, volume = 1.4, pitchVariance = 0.08, duration = ONE_STEP },
			},
			{
				name = "moss",
				volume = 1,
				pitch = 1.25,
				dig = { id = LAND, volume = 0.7, pitch = 0.95, pitchVariance = 0.08 },
				step = { id = STEPS, volume = 1.4, pitchVariance = 0.08, duration = ONE_STEP },
			},
		} :: { Define.BlockSoundType }
	do
		define.append(list, define.blockSounds(soundType))
	end
	return list
end
