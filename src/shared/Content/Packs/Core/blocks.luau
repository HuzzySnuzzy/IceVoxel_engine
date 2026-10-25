--!strict
--[[
	Air (id 0: freshly created chunk buffers are zero-filled, i.e. all air) and Cave Air (id 1), the
	first two blocks of the game: Core loads first (order 0), so nothing comes before them.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	{ name = "Air", render = "None", solid = false, replaceable = true, breakable = false },
	-- Air produced by cave carving. Behaves exactly like air, but the mesher can treat it as solid
	-- rock so cave walls far from the camera are not drawn.
	{ name = "CaveAir", render = "None", solid = false, replaceable = true, breakable = false },
} :: { Schema.BlockSpec }
