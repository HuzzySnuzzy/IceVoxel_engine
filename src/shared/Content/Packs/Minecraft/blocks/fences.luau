--!strict
--[[
	The Oak Fence (Minecraft's oak_fence), all 16 variants (Content/Define's `fence`: a 4 x 4 pixel
	post, and two rails out to every side it connects to: fences beside it and sturdy blocks,
	FenceBlock.connectsTo). OakFence is the lone post and the item; placing one, or a neighbour
	changing, picks the variant (Blocks.fenceConnections, server Behaviours/Fence). Solid, but it
	collides only with its post and arms, 1.5 blocks high, as Minecraft's: players and mobs can't
	jump over a fence (a pen holds its animals), and walk past a lone post. Not sturdy (nothing
	hangs on it). Strength 2, blast resistance 3, an axe mines it fast, wood sounds, burns like
	planks (5 / 20), 300 ticks of fuel; a zombie breaks it as it breaks dirt (300 ticks). Three
	from four oak planks and two sticks. Drawn in the planks' texture (the pack's "planks").

	The mineshafts put fence posts in their tunnels: CaveOakFence is the lone post's cave twin
	(blocks/mineshafts says what twins are).
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return function(define: Define.Context): { Schema.BlockSpec }
	local fence = define.fence({
		name = "OakFence",
		displayName = "Oak Fence",
		color = { 170, 134, 84 },
		material = "WoodPlanks",
		sound = "wood",
		hardness = 2,
		blastResistance = 3,
		tool = "axe",
		flammable = { ignite = 5, burn = 20 },
		zombieBreak = 300,
		-- (The lone post's, the item: its picture covers every variant and the twin.)
		texture = { All = "planks" },
		lore = "A wooden fence post.",
		fuel = 300,
	})
	table.insert(fence, define.caveTwin(fence[1]))
	return fence
end
