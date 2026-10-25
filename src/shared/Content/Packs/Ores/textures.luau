--!strict
--[[
	The new ores' textures, blank until made: stone with each ore's specks (Granite's material,
	Saltpetre Ore's Limestone), the metal blocks and the raw blocks, each in its own colours (no
	tint).
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)
local metals = require(script.Parent._metals)

return function(define: Define.Context): { [string]: Schema.Texture }
	local textures: { [string]: Schema.Texture } = {
		["sulfur ore"] = { Color = "", Material = "Granite", Tint = false },
		["saltpetre ore"] = { Color = "", Material = "Limestone", Tint = false },
	}
	for _, metal in metals do
		for name, texture in define.metal(metal).textures do
			textures[name] = texture
		end
	end
	return textures
end
