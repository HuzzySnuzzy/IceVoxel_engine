--!strict
--[[
	Herbs (Tough As Nails' water and teas, Shared/ToughAsNails/Drinks). Mint Leaves, what a Mint
	plant drops: a sprig of three bright leaves on a pale stem; they cure dirty water in a crafting
	grid and brew Mint Tea. Ginger Root, what Wild Ginger drops: a knobbly tan root with a pink bud;
	it brews Ginger Tea. Each plants its herb back on dirt or grass (`places`, the pack's Mint and
	WildGinger blocks).
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

local MINT = { 92, 176, 84 }
local MINT_DARK = { 62, 140, 62 }
local MINT_LIGHT = { 150, 210, 128 }
local GINGER = { 206, 168, 112 }

return function(define: Define.Context): { Schema.ItemSpec }
	local shade = define.shade
	return {
		{
			name = "MintLeaves",
			color = MINT,
			material = "SmoothPlastic",
			places = "Mint",
			model = {
				{ size = { 1, 9, 1 }, offset = { 0.5, -3.5, -0.2 }, rotation = -10, color = { 84, 124, 60 } },
				{ size = { 5.5, 3, 1 }, offset = { -2.6, 0.5, 0 }, rotation = 28, color = MINT_DARK },
				{ size = { 5.5, 3, 1 }, offset = { 3, 2, 0 }, rotation = -28 },
				{ size = { 3, 5, 1 }, offset = { 0, 4.8, 0.2 }, rotation = -8, color = MINT_LIGHT },
				{
					size = { 3.8, 0.4, 0.3 },
					offset = { -2.6, 0.5, 0.6 },
					rotation = 28,
					color = shade(MINT_DARK, 1.35),
				},
				{ size = { 3.8, 0.4, 0.3 }, offset = { 3, 2, 0.6 }, rotation = -28, color = MINT_LIGHT },
			},
		},
		{
			name = "GingerRoot",
			color = GINGER,
			material = "SmoothPlastic",
			places = "WildGinger",
			model = {
				{ size = { 9, 3.5, 3.5 }, offset = { -0.5, -1, 0 }, rotation = 12 },
				{ size = { 3, 4, 3 }, offset = { 2.4, 2, 0 }, rotation = -18 },
				{ size = { 3.5, 3, 3 }, offset = { -4.6, 1.2, 0 }, rotation = 30 },
				{ size = { 2.5, 2, 2.5 }, offset = { 4.6, -2.4, 0 }, color = shade(GINGER, 0.85) },
				{ size = { 0.5, 3, 0.4 }, offset = { -1.5, -1.3, 1.9 }, rotation = 12, color = shade(GINGER, 0.7) },
				{ size = { 0.5, 2.6, 0.4 }, offset = { 1.2, -0.6, 1.9 }, rotation = 12, color = shade(GINGER, 0.7) },
				{ size = { 1.6, 1.6, 1.6 }, offset = { 3, 4.4, 0 }, color = { 214, 140, 120 } },
			},
		},
	}
end
