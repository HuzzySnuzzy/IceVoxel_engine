--!strict
--[[
	Minecraft's buckets: the empty Bucket, the Water Bucket and the Lava Bucket (Content/Define's
	`bucket` and `filledBucket`: Minecraft's iron bucket seen from the front). Buckets carry fluids
	(Shared/Fluids) to and from fluid tanks and the world (1000 mB, a source block); an empty one
	stacks to 16 as in Minecraft, a full one does not stack, and each full one leaves the empty
	Bucket when used up (Items.craftingRemainder). A Lava Bucket burns 20 000 ticks in a furnace
	(Crafting/Smelting). The oil and fuel buckets are the Mekanism pack's. Each carries its lore and
	a blank icon; the empty Bucket is the Iron Age's.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

local WATER = { 52, 96, 220 }
local LAVA = { 212, 90, 20 }

return function(define: Define.Context): { Schema.ItemSpec }
	return {
		{
			name = "Bucket",
			maxStack = 16,
			color = define.BUCKET_IRON,
			material = "Metal",
			-- (Its dark inside, seen over the rim.)
			model = define.bucket({ { size = { 10, 0.6, 3.5 }, offset = { 0, 5.1, 0 }, color = { 58, 58, 62 } } }),
			icon = "",
			lore = "Picks up water, lava, oil or fuel from a source.",
			age = "iron",
		},
		{
			name = "WaterBucket",
			maxStack = 1,
			color = WATER,
			material = "Metal",
			-- (Water filling it to the rim, and a band of it showing over the rim's front.)
			model = define.filledBucket(WATER, "SmoothPlastic"),
			icon = "",
			lore = "Pour it out for a water source.",
		},
		{
			name = "LavaBucket",
			maxStack = 1,
			color = LAVA,
			material = "Metal",
			model = define.filledBucket(LAVA, "Neon"),
			icon = "",
			lore = "Pour it out, or burn it: a long-lasting fuel.",
		},
	}
end
