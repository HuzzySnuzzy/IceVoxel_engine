local shapes = require(script.Parent._shapes)

return function(define)
	local list = define.metal(shapes.FIXIUM).recipes
	table.insert(list, define.shaped({ "G", "S" }, { G = "BetaGem", S = "#fixture_stones" }, "AlphaWand"))
	return list
end
