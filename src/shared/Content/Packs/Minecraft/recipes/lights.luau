--!strict
--[[
	Minecraft's light recipes: four torches from a coal or charcoal ("#coals", Core's tag) over a
	stick, the lantern from a torch in iron nuggets, and the Glow Block from four Glow Dust (the
	game's glowstone).
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return function(define: Define.Context): { Schema.Recipe }
	local shaped = define.shaped
	return {
		shaped({ "X", "#" }, { X = "#coals", ["#"] = "Stick" }, "Torch", 4),
		shaped({ "XXX", "X#X", "XXX" }, { X = "IronNugget", ["#"] = "Torch" }, "Lantern"),
		shaped({ "##", "##" }, { ["#"] = "GlowDust" }, "GlowBlock"),
	}
end
