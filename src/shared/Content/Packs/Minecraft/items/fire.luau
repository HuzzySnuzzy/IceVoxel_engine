--!strict
--[[
	Fire and explosives (Shared/Fire, server Behaviours/Fire and Behaviours/Tnt):

	  * Flint: Minecraft's, which gravel drops one time in 10 (Items.randomDrop): a dark chipped
	    shard with a pale glint.
	  * Flint and Steel: Minecraft's (shapeless: an iron ingot and flint), 64 uses, each lighting a
	    fire in front of the clicked face where fire can burn (Players/ItemUse); a steel striker's
	    ring at the bottom left, the flint at the top right, as its inventory icon.
	  * Gunpowder (Minecraft's, which creepers drop: this game has no creepers; the ruins' and
	    bunkers' crates and soldier zombies have some). Black powder is charcoal and saltpetre;
	    here a coal or charcoal and a flint make two (the pack's recipes; the Ores pack's
	    saltpetre and sulfur make it too), and five of them with four sand make TNT. A dark grey
	    heap of grains with a few lighter specks, as Minecraft's icon.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

local FLINT = { 62, 62, 68 }
local STEEL = { 168, 170, 176 }
local GUNPOWDER = { 78, 78, 80 }

return function(define: Define.Context): { Schema.ItemSpec }
	local shade = define.shade
	return {
		{
			name = "Flint",
			color = FLINT,
			material = "Slate",
			model = {
				{ size = { 6, 8, 3 }, offset = { 0, -0.5, 0 } },
				{ size = { 4, 3, 2.6 }, offset = { -1, 4.5, 0 }, rotation = 20 },
				{ size = { 3.5, 3, 2.6 }, offset = { 1.2, -5.2, 0 }, rotation = -15 },
				{ size = { 2, 2.5, 0.4 }, offset = { -1, 1.5, 1.6 }, color = shade(FLINT, 1.9) },
				{ size = { 1.5, 3, 0.4 }, offset = { 1.5, -2, 1.6 }, color = shade(FLINT, 0.7) },
			},
		},
		{
			name = "FlintAndSteel",
			displayName = "Flint and Steel",
			durability = 64,
			color = STEEL,
			material = "Metal",
			model = {
				-- (The ring opens to the right: its bottom, back and shorter top bar.)
				{ size = { 7, 1.6, 1.5 }, offset = { -2.5, -6.2, 0 } },
				{ size = { 1.6, 6, 1.5 }, offset = { -6, -4, 0 } },
				{ size = { 5, 1.6, 1.5 }, offset = { -3.5, -1.8, 0 }, color = shade(STEEL, 1.15) },
				{ size = { 5, 6, 2.5 }, offset = { 3, 3.5, 0 }, rotation = 25, color = FLINT, material = "Slate" },
				{ size = { 1.8, 2.2, 0.4 }, offset = { 2.4, 4.4, 1.4 }, rotation = 25, color = shade(FLINT, 1.9) },
			},
		},
		{
			name = "Gunpowder",
			color = GUNPOWDER,
			material = "Sand",
			model = {
				{ size = { 12, 3, 4 }, offset = { 0, -4.5, 0 } },
				{ size = { 9, 3, 4 }, offset = { -0.5, -1.5, 0 } },
				{ size = { 5, 3, 4 }, offset = { 0.5, 1.5, 0 } },
				{ size = { 2, 2, 4 }, offset = { 0, 4, 0 } },
				{ size = { 1.5, 1.5, 0.4 }, offset = { -3, -3.5, 2.1 }, color = shade(GUNPOWDER, 1.8) },
				{ size = { 1.5, 1.5, 0.4 }, offset = { 2.5, -1, 2.1 }, color = shade(GUNPOWDER, 1.6) },
				{ size = { 1.5, 1.5, 0.4 }, offset = { 3.5, -4.5, 2.1 }, color = shade(GUNPOWDER, 0.6) },
				{ size = { 1.5, 1.5, 0.4 }, offset = { -0.5, 2, 2.1 }, color = shade(GUNPOWDER, 0.6) },
			},
		},
	}
end
