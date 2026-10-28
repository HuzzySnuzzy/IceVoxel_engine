return function(define)
	return {
		-- (Its recipe stays locked until Blasting is unlocked, besides the Electric Age.)
		{
			name = "BlastCharge",
			color = { 200, 60, 40 },
			material = "Metal",
			model = define.nugget({ 200, 60, 40 }),
			lore = "TNT packed tight.",
			icon = "",
			age = "electric",
			skill = "blasting",
		},
	}
end
