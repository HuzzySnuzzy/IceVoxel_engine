-- An explicit pool in place of the templates named under it (Gamma patches it).
return {
	["alpha/huts"] = {
		projection = "terrain_matching",
		elements = {
			{ template = "alpha/huts/hut", weight = 3 },
			{ template = "alpha/huts/shed" },
			{ empty = true, weight = 2 },
		},
	},
}
