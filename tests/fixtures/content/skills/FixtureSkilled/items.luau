return function(define)
	return {
		-- (Its recipe stays locked until Fixture Blasting is unlocked, besides the Electric Age.)
		{
			name = "FixtureBlastCharge",
			color = { 200, 60, 40 },
			material = "Metal",
			model = define.nugget({ 200, 60, 40 }),
			lore = "TNT packed tight.",
			icon = "",
			age = "electric",
			skill = "fixture_blasting",
		},
	}
end
