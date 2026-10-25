-- The pack's own item: its potions' items come after it.
return function(define)
	return {
		{
			name = "FourLeafClover",
			color = { 60, 160, 60 },
			material = "Grass",
			model = define.nugget({ 60, 160, 60 }),
			lore = "Lucky, they say.",
			icon = "",
		},
	}
end
