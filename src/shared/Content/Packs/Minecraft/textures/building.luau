--!strict
--[[
	The building blocks' textures: bricks, stone bricks, smooth stone, the polished stones, cut
	sandstone, blue ice and glass. The fourth sheet shares maps on purpose ("Ignore double id's this
	list is intentional"): polished andesite's picture is asphalt's too (the Apocalypse pack's), on
	andesite's normal map; the bricks' maps serve the cracked and mossy bricks too.
]]

local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return {
	["bricks"] = {
		Color = "rbxassetid://78619102429227",
		Normal = "rbxassetid://126476239211015",
		Material = "Brick",
	},
	["cracked stone bricks"] = {
		Color = "rbxassetid://102677558753560",
		Normal = "rbxassetid://121416480343872",
		Material = "Brick",
	},
	["polished andesite"] = {
		Color = "rbxassetid://70532405855463",
		Normal = "rbxassetid://84287333684009",
		Material = "Concrete",
	},
	["smooth stone"] = {
		Color = "rbxassetid://126386401149504",
		Normal = "rbxassetid://92601327159349",
		Material = "Concrete",
	},
	["stone bricks"] = {
		Color = "rbxassetid://95612339340500",
		Normal = "rbxassetid://114812382647958",
		Material = "Brick",
	},

	-- Not made yet: fill these in (Shared/TexturePack's header).
	["polished diorite"] = { Color = "", Material = "Marble" },
	["polished granite"] = { Color = "", Material = "Concrete" },
	["blue ice"] = { Color = "", Material = "Ice" },
	["cut sandstone"] = { Color = "", Material = "Sandstone" },
	-- (Glass cannot take a MaterialVariant: textured glass is SmoothPlastic, as see-through as the
	-- block.)
	["glass"] = { Color = "", Material = "SmoothPlastic" },
} :: { [string]: Schema.Texture }
