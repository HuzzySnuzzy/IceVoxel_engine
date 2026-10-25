--!strict
--[[
	The zombie apocalypse's textures (Shared/TexturePack's header says how to fill one in). The
	fourth sheet shares maps on purpose ("Ignore double id's this list is intentional"): cracked
	asphalt is andesite's picture and asphalt polished andesite's (the Minecraft pack's), all on
	one normal map; cracked and mossy bricks take the bricks' maps. Barricades take the Minecraft
	pack's "planks" and the ceiling lamp none (a light).

	  * The roads. Asphalt is drawn in Asphalt's own dark colour wherever it is ("Asphalt", as the
	    dirt under grass is "Dirt"): on asphalt and on the sides and bottoms of the road lines,
	    which stay dark beside the asphalt around them. The lines' tops are not on the sheet: they
	    take asphalt's maps in the line's own colour (Tint true: white, yellow) until a painted line
	    is made. Keep them filled: a blank top shows the sides' texture (TexturePack's header), and
	    the line would vanish into the asphalt. Cracked asphalt takes andesite's picture ("Yes uses
	    andesite textures") in its own colour.
	  * Concrete, and the aged concrete and bricks. Cracked and mossy concrete are not on the sheet:
	    they take concrete's maps, as the sheet itself does for cracked and mossy bricks ("Same
	    texture for now, maybe darker tint", "maybe greener tint"). Each is tinted with its own
	    voxel colour: the cracked ones darker than the plain block in every channel, the mossy ones
	    greener, so one picture reads as four blocks.
	  * The sheet's "crate" and "cabinet": one picture on every face, in its own colours.
	  * Still waiting: the wrecks' rusty steel and the bunker hatch.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	["asphalt"] = {
		Color = "rbxassetid://70532405855463",
		Normal = "rbxassetid://84287333684009",
		Material = "Asphalt",
		Tint = "Asphalt",
	},
	["cracked asphalt"] = {
		Color = "rbxassetid://135061946280047",
		Normal = "rbxassetid://84287333684009",
		Material = "Asphalt",
		Tint = true,
	},
	["road line"] = {
		Color = "rbxassetid://70532405855463",
		Normal = "rbxassetid://84287333684009",
		Material = "Asphalt",
		Tint = true,
	},
	["road line yellow"] = {
		Color = "rbxassetid://70532405855463",
		Normal = "rbxassetid://84287333684009",
		Material = "Asphalt",
		Tint = true,
	},
	["concrete"] = {
		Color = "rbxassetid://83707291495507",
		Normal = "rbxassetid://134665376447341",
		Material = "Concrete",
		Tint = true,
	},
	["cracked concrete"] = {
		Color = "rbxassetid://83707291495507",
		Normal = "rbxassetid://134665376447341",
		Material = "Concrete",
		Tint = true,
	},
	["mossy concrete"] = {
		Color = "rbxassetid://83707291495507",
		Normal = "rbxassetid://134665376447341",
		Material = "Concrete",
		Tint = true,
	},
	["cracked bricks"] = {
		Color = "rbxassetid://78619102429227",
		Normal = "rbxassetid://126476239211015",
		Material = "Brick",
		Tint = true,
	},
	["mossy bricks"] = {
		Color = "rbxassetid://78619102429227",
		Normal = "rbxassetid://126476239211015",
		Material = "Brick",
		Tint = true,
	},
	["supply crate side"] = {
		Color = "rbxassetid://83206835598770",
		Normal = "rbxassetid://98971183237888",
		Material = "WoodPlanks",
		Tint = false,
	},
	["supply crate top"] = {
		Color = "rbxassetid://83206835598770",
		Normal = "rbxassetid://98971183237888",
		Material = "WoodPlanks",
		Tint = false,
	},
	["medicine cabinet side"] = {
		Color = "rbxassetid://125353153474912",
		Normal = "rbxassetid://97000542660093",
		Material = "Metal",
		Tint = false,
	},
	["medicine cabinet top"] = {
		Color = "rbxassetid://125353153474912",
		Normal = "rbxassetid://97000542660093",
		Material = "Metal",
		Tint = false,
	},

	-- Not made yet.
	["rusty metal"] = { Color = "", Material = "CorrodedMetal", Tint = false },
	["bunker hatch"] = { Color = "", Material = "DiamondPlate", Tint = false },
} :: { [string]: Schema.Texture }
