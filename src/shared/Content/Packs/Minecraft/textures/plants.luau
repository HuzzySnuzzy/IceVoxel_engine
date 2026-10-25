--!strict
--[[
	The plants' textures: the cactus's, and the plant sprites (drawn as two crossed images once
	filled in). Grass and ferns take their soil's foliage colour (Tint = true); flowers, dead bushes
	and mushrooms keep the picture's colours; one black and white picture serves every sapling,
	tinted with each one's colour.
]]

local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return {
	["cactus side"] = {
		Color = "rbxassetid://108038569607208",
		Material = "Grass",
		Tint = true,
	},
	["cactus top"] = {
		Color = "rbxassetid://107644713378212",
		Material = "Grass",
		Tint = true,
	},
	["short grass"] = {
		Color = "rbxassetid://113127329313443",
		Material = "SmoothPlastic",
		Tint = true,
	},
	["tall grass bottom"] = {
		Color = "rbxassetid://100266742601250",
		Material = "SmoothPlastic",
		Tint = true,
	},
	["tall grass top"] = {
		Color = "rbxassetid://104285260856645",
		Material = "SmoothPlastic",
		Tint = true,
	},
	["sapling"] = {
		Color = "rbxassetid://127390623075923",
		Material = "SmoothPlastic",
		Tint = true,
	},

	-- Not made yet (Shared/TexturePack's header says how to fill one in).
	["fern"] = { Color = "", Material = "SmoothPlastic", Tint = true },
	["large fern bottom"] = { Color = "", Material = "SmoothPlastic", Tint = true },
	["large fern top"] = { Color = "", Material = "SmoothPlastic", Tint = true },
	["dead bush"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["dandelion"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["poppy"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["blue orchid"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["allium"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["azure bluet"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["red tulip"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["orange tulip"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["white tulip"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["pink tulip"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["oxeye daisy"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["cornflower"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["lily of the valley"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["sunflower bottom"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["sunflower top"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["lilac bottom"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["lilac top"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["rose bush bottom"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["rose bush top"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["peony bottom"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["peony top"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["brown mushroom"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["red mushroom"] = { Color = "", Material = "SmoothPlastic", Tint = false },
} :: { [string]: Schema.Texture }
