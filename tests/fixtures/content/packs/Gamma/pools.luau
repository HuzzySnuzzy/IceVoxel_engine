-- Patches Alpha's pool: its elements replace Alpha's whole (Alpha's own listed again, and one
-- more), its projection stays.
return {
	["alpha/huts"] = {
		override = true,
		elements = {
			{ template = "alpha/huts/hut", weight = 3 },
			{ template = "alpha/huts/shed" },
			{ template = "gamma/hut", weight = 2 },
		},
	},
}
