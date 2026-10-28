-- The Chorus fixture pack's sounds (tests/spec/Content): a block sound type, three events and an
-- override.
return function(define)
	local SHIPPED = define.SHIPPED
	local list = define.blockSounds({
		name = "chime",
		volume = 1,
		pitch = 1.8,
		dig = { id = SHIPPED.LAND, volume = 0.8, pitchVariance = 0.05 },
		step = { id = SHIPPED.STEPS, volume = 1.6, pitchVariance = 0.05, duration = define.ONE_STEP },
	})
	define.append(list, {
		{
			name = "entity.chorus.sing",
			id = SHIPPED.TICK,
			pitch = 1.5,
			fallback = { id = SHIPPED.LAND, pitch = 2 },
			source = "ambient",
			side = "client",
			limit = 2,
		},
		{
			name = "block.chorus.hum",
			category = "machine.hum",
			id = define.RECORDINGS.ELECTRIC_HUM,
			volume = 0.2,
			maxDistance = 12,
			source = "blocks",
			side = "client",
		},
		{
			name = "item.armor.equip_chorus",
			category = "item.armor.equip",
			id = SHIPPED.GET_UP,
			pitch = 1.7,
			source = "players",
			side = "server",
		},
		{ name = "ui.button.click", override = true, volume = 0.8 },
	})
	return list
end
