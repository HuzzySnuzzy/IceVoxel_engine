--!strict
--[[
	The template pools of the example outpost (the structures feature; its pieces are
	templates/outpost, built by tests/build_structures, and its entry is in structures). Its start
	pool "outpost/centres" needs no entry: it is every template named "outpost/centres/...".
	Content/Schema has a pool's fields.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	-- Paths follow the ground; at the last level (and where nothing else fits) they end in a lamp
	-- post or fade out.
	["outpost/paths"] = {
		projection = "terrain_matching",
		fallback = "outpost/path_ends",
		elements = {
			{ template = "outpost/paths/straight", weight = 5 },
			{ template = "outpost/paths/crossing", weight = 1 },
			{ template = "outpost/paths/turn_east", weight = 1 },
			{ template = "outpost/paths/turn_west", weight = 1 },
		},
	},
	["outpost/path_ends"] = {
		projection = "terrain_matching",
		elements = {
			{ template = "outpost/path_ends/lamp", weight = 2 },
			{ template = "outpost/path_ends/fade", weight = 1 },
		},
	},
	-- What stands along the paths: some plots stay empty.
	["outpost/houses"] = {
		elements = {
			{ template = "outpost/houses/hut", weight = 3 },
			{ template = "outpost/houses/storehouse", weight = 2 },
			{ template = "outpost/houses/forge", weight = 2 },
			{ template = "outpost/houses/woodpile", weight = 1 },
			{ empty = true, weight = 2 },
		},
	},
} :: { [string]: Schema.TemplatePool }
