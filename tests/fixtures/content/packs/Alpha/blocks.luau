local shapes = require(script.Parent._shapes)

return function(define)
	local list = {
		{
			name = "AlphaStone",
			color = { 140, 130, 120 },
			material = "Rock",
			hardness = 2,
			tool = "pickaxe",
			toolLevel = 0,
			texture = { All = "alpha stone" },
			lore = "The Luau pack's stone.",
			tags = { "fixture_stones" },
		},
	}
	return define.append(list, define.metal(shapes.FIXIUM).blocks)
end
