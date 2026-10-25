local shapes = require(script.Parent._shapes)

return function(define)
	local textures = define.metal(shapes.FIXIUM).textures
	textures["alpha stone"] = { Color = "", Material = "Rock", Tint = "AlphaStone" }
	return textures
end
