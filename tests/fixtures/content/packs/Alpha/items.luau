local shapes = require(script.Parent._shapes)

return function(define)
	local list = define.metal(shapes.FIXIUM).items
	table.insert(list, {
		name = "AlphaWand",
		maxStack = 1,
		color = { 160, 120, 80 },
		material = "Wood",
		model = shapes.WAND,
		lore = "Waves about.",
	})
	return list
end
