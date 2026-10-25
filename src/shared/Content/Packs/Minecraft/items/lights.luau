--!strict
--[[
	Glow Dust: what glow lichen (2) and the Glow Block (4, which make a block again) drop, the
	game's blue glowing dust in place of Minecraft's glowstone dust (and of redstone in Mekanism's
	recipes): a small heap with bright specks. It was named "GlowstoneDust" (Items.RENAMED). Its
	entry carries its lore and a blank icon.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

local GLOW_DUST = { 92, 150, 238 }
local SPARK = { 196, 228, 255 }

return function(define: Define.Context): { Schema.ItemSpec }
	local shade = define.shade
	return {
		{
			name = "GlowDust",
			displayName = "Glow Dust",
			color = GLOW_DUST,
			material = "Sand",
			model = {
				{ size = { 11, 3, 4 }, offset = { 0, -3.5, 0 } },
				{ size = { 7, 3, 4 }, offset = { 0.5, -0.5, 0 }, color = shade(GLOW_DUST, 1.08) },
				{ size = { 3.5, 2.5, 3.5 }, offset = { -0.25, 2.25, 0 }, color = shade(GLOW_DUST, 1.15) },
				{ size = { 1.5, 1.5, 0.5 }, offset = { -3, -3, 2.1 }, color = SPARK, material = "Neon" },
				{ size = { 1, 1, 0.5 }, offset = { 2, -0.5, 2.1 }, color = SPARK, material = "Neon" },
				{ size = { 1, 1, 0.5 }, offset = { -0.5, 2.5, 1.85 }, color = SPARK, material = "Neon" },
				{ size = { 1, 1, 0.5 }, offset = { 3.5, -3.5, -2.1 }, color = SPARK, material = "Neon" },
			},
			icon = "",
			lore = "Glowing powder for lights, cables, potions and mana.",
		},
	}
end
