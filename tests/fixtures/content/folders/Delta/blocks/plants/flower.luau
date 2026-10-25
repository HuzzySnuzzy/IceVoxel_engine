local colours = require(script.Parent.Parent.Parent._colours)

return function(define)
	return {
		{
			name = "DeltaFlower",
			color = define.shade(colours.FLOWER, 1),
			material = "SmoothPlastic",
			texture = { Sprite = "delta flower" },
		},
	}
end
