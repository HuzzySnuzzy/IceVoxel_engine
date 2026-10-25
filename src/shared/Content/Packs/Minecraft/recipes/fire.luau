--!strict
--[[
	Fire and explosives: Flint and Steel, an iron ingot and flint in any slots (Minecraft's).
	Gunpowder has no creeper to drop it here, and ruins hide some (Generation/ScavengeLoot): the old
	field mix, a coal or charcoal and a flint, makes two (black powder from saltpetre and sulfur,
	and the Nuke's uranium core, are the Ores pack's). TNT is Minecraft's: gunpowder in an X with
	sand between (5 gunpowder, 4 sand).
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return function(define: Define.Context): { Schema.Recipe }
	local shaped, shapeless = define.shaped, define.shapeless
	return {
		shapeless({ "IronIngot", "Flint" }, "FlintAndSteel"),
		shapeless({ "#coals", "Flint" }, "Gunpowder", 2),
		shaped({ "X#X", "#X#", "X#X" }, { X = "Gunpowder", ["#"] = "Sand" }, "Tnt"),
	}
end
