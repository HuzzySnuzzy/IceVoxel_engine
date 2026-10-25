--!strict
--[[
	The terrain's textures (Shared/TexturePack's header says how to fill one in and what each field
	does; blocks name them per face): the ground, the stones, sand and snow and ice. The made ones
	are the user's sheets; "" ones are not made yet.
]]

local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return {
	["dirt"] = {
		Color = "rbxassetid://124863036266976",
		Normal = "rbxassetid://72051511434165",
		Material = "Ground",
		Tint = "Dirt",
	},
	["grass top"] = {
		Color = "rbxassetid://108277463750403",
		Normal = "rbxassetid://99507506732683",
		Material = "Grass",
		Tint = true,
	},
	-- (Dirt with a green fringe, in its own colours.)
	["grass side"] = {
		Color = "rbxassetid://86851679897399",
		Normal = "rbxassetid://73522726802574",
		Material = "Ground",
		Tint = false,
	},
	["stone"] = {
		Color = "rbxassetid://140181032881606",
		Normal = "rbxassetid://99380706817425",
		Material = "Slate",
	},
	["cobblestone"] = {
		Color = "rbxassetid://75251272775135",
		Normal = "rbxassetid://84237009727338",
		Material = "Cobblestone",
	},
	["sand"] = {
		Color = "rbxassetid://71309589762284",
		Normal = "rbxassetid://128379135184493",
		Material = "Sand",
	},
	["gravel"] = {
		Color = "rbxassetid://80041848472885",
		Normal = "rbxassetid://81186281605960",
		Material = "Pebble",
	},
	["snow"] = {
		Color = "rbxassetid://93188919600084",
		Normal = "rbxassetid://105336294076212",
		Material = "Snow",
	},
	["diorite"] = {
		Color = "rbxassetid://136661436562468",
		Normal = "rbxassetid://125518917530320",
		Material = "Limestone",
	},
	-- (The sheet gives calcite stone's normal map.)
	["calcite"] = {
		Color = "rbxassetid://127261168995224",
		Normal = "rbxassetid://99380706817425",
		Material = "Marble",
	},
	["obsidian"] = {
		Color = "rbxassetid://124134462736797",
		Normal = "rbxassetid://82694772111598",
		Material = "Basalt",
	},
	["ice"] = {
		Color = "rbxassetid://108401137755740",
		Material = "Glacier",
	},
	["packed ice"] = {
		Color = "rbxassetid://95721302530570",
		Material = "Ice",
	},
	--[[
		"Darker dirt" in the sheet: dirt's colour map, tinted with Packed Mud's own colour, which is
		darker than Dirt's in every channel, so it shows darker than dirt (unless the image is darker
		still: a tint only darkens). The sheet's normal map repeated the colour map's id (a typo), so
		this uses dirt's normal map.
	]]
	["packed mud"] = {
		Color = "rbxassetid://124863036266976",
		Normal = "rbxassetid://72051511434165",
		Material = "Mud",
		Tint = true,
	},
	["sandstone side"] = {
		Color = "rbxassetid://100157928191004",
		Normal = "rbxassetid://140637300323961",
		Material = "Sandstone",
	},
	["sandstone top"] = {
		Color = "rbxassetid://127212881957834",
		Normal = "rbxassetid://140637300323961",
		Material = "Sandstone",
	},
	-- (The fourth sheet's andesite: its picture is cracked asphalt's too, the Apocalypse pack's.)
	["andesite"] = {
		Color = "rbxassetid://135061946280047",
		Normal = "rbxassetid://84287333684009",
		Material = "Rock",
	},

	-- Not made yet: fill these in (see the header).
	["bedrock"] = { Color = "", Material = "Basalt" },
	["coarse dirt"] = { Color = "", Material = "Ground" },
	["podzol top"] = { Color = "", Material = "Ground" },
	["podzol side"] = { Color = "", Material = "Ground", Tint = false },
	["mycelium top"] = { Color = "", Material = "Grass" },
	["mycelium side"] = { Color = "", Material = "Ground", Tint = false },
	-- (Dirt with a dry, yellowed fringe, in its own colours: dry grass's sides. Until it is made,
	-- they keep the plain look in Dry Grass's colour, under the tinted grass top.)
	["dry grass side"] = { Color = "", Material = "Ground", Tint = false },
	["granite"] = { Color = "", Material = "Granite" },
	["sandstone bottom"] = { Color = "", Material = "Sandstone" },
} :: { [string]: Schema.Texture }
