--!strict
--[[
	Survival's sounds: Tough As Nails' drinking and boiling, and the seasons'.

	  * Drinking (Shared/ToughAsNails). Drinking from a bottle or a canteen is Minecraft's 32 tick
	    use: entity.generic.drink (volume 0.5, pitch 0.9..1.0, LivingEntity.triggerItemUseEffects)
	    every 4 ticks from the 7th and once more at the end, which the drinker's client plays
	    itself while the server plays the last one to everyone else; a sip from a water source with
	    an empty hand (TAN's hand drinking) plays it once. The gulps every 4 ticks now play only
	    when the drinking loop's recording fails to load (entity.generic.drinking); the last one
	    and the sip always. A Glass Bottle or a canteen filled at water: item.bottle.fill
	    (BottleItem, volume 1). Stand-ins: a short swim stroke pitched up into a gulp, and the
	    splash pitched high.
	  * The drinking loop (the fourth data sheet's "Main SFX": "loop this during drinking"; this
	    game's): played while a player holds the use button on a drink, as the Minecraft pack's
	    eating loop is on a food (client Audio/UseSounds, by the rules of Audio/UseSoundRules); its
	    clicks are its fallback, the last gulp stays. Swap its id here, or give a Sound of its name
	    in SoundService.IceVoxelSounds, which loops too.
	  * The campfire (blocks/campfire, Shared/ToughAsNails/Boiling): dirty water held over it boils
	    clean with a bubbling hiss (block.campfire.boil, this game's: Minecraft's campfire cooks
	    food, it boils nothing), from the server (Players/ItemUse) at the campfire. The campfire's
	    crackle is fire's (block.fire.ambient, Audio/Ambience). Stand-in: the splash pitched up and
	    cut short.
	  * The seasons (Shared/Seasons), each replaced by a Sound of its name in
	    SoundService.IceVoxelSounds (or the override folder):
	      block.electric_heater.hum      a working Electric Heater: the fifth sheet's "Electric
	                                     Hum" (category machine.hum; the wind pitched down its
	                                     fallback)
	      block.air_conditioner.hum      a working Air Conditioner: the same, a little lower
	      block.fan.loop                 a running Electric Fan: the wind pitched up
	      block.wood_stove.crackle       a burning Wood Stove: the furnace's crackle, deeper
	      block.oil_heater.burn          a burning Oil Heater: the wind pitched far down, a roar
	      ui.thermostat.click            a thermostat's button: the volume tick
	      ambient.season.autumn | winter | spring | summer   a season's turn: a long low boom,
	                                     flat (category ambient.season)
	      ambient.season.heat_wave       a heat wave's dawn
	    The machines' loops play at the machine while it works (client Audio/Ambience, from the
	    machines' records and their blocks' `workSound`); the turns' stingers with their toasts
	    (Ui/SeasonLine).
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)

type SoundSpec = Schema.SoundSpec

return function(define: Define.Context): { SoundSpec }
	local SHIPPED = define.SHIPPED
	local FALLING, SPLASH, EXPLOSION = SHIPPED.FALLING, SHIPPED.SPLASH, SHIPPED.EXPLOSION
	local ELECTRIC_HUM = define.RECORDINGS.ELECTRIC_HUM
	return {
		{
			name = "entity.generic.drink",
			id = SHIPPED.SWIM,
			volume = 0.5,
			pitch = 1.5,
			pitchVariance = 0.05,
			duration = 0.25,
			source = "players",
			side = "predicted",
		},
		{
			name = "item.bottle.fill",
			id = SPLASH,
			volume = 0.6,
			pitch = 1.7,
			pitchVariance = 0.05,
			duration = 0.5,
			source = "players",
			side = "server",
		},
		{
			name = "block.campfire.boil",
			id = SPLASH,
			volume = 0.5,
			pitch = 1.3,
			pitchVariance = 0.1,
			duration = 0.6,
			fallback = { id = FALLING, pitch = 2.4 },
			source = "blocks",
			side = "server",
		},
		{
			name = "entity.generic.drinking",
			id = "rbxassetid://79766888063175",
			volume = 0.6,
			pitchVariance = 0.03,
			source = "players",
			side = "client",
		},
		{
			name = "block.electric_heater.hum",
			category = "machine.hum",
			id = ELECTRIC_HUM,
			volume = 0.25,
			fallback = { id = FALLING, pitch = 0.45 },
			maxDistance = 12,
			source = "blocks",
			side = "client",
		},
		{
			name = "block.air_conditioner.hum",
			category = "machine.hum",
			id = ELECTRIC_HUM,
			volume = 0.25,
			pitch = 0.92,
			fallback = { id = FALLING, pitch = 0.6 },
			maxDistance = 12,
			source = "blocks",
			side = "client",
		},
		{
			name = "block.fan.loop",
			id = FALLING,
			volume = 0.2,
			pitch = 1.4,
			maxDistance = 10,
			source = "blocks",
			side = "client",
		},
		{
			name = "block.wood_stove.crackle",
			id = SHIPPED.STEPS,
			volume = 0.35,
			pitch = 1.8,
			pitchVariance = 0.3,
			duration = 0.1,
			maxDistance = 12,
			source = "blocks",
			side = "client",
		},
		{
			name = "block.oil_heater.burn",
			id = FALLING,
			volume = 0.3,
			pitch = 0.3,
			maxDistance = 12,
			source = "blocks",
			side = "client",
		},
		{
			name = "ui.thermostat.click",
			id = SHIPPED.TICK,
			volume = 0.5,
			pitch = 1.3,
			ui = true,
			source = "ui",
			side = "client",
		},
		{
			name = "ambient.season.autumn",
			category = "ambient.season",
			id = EXPLOSION,
			volume = 0.5,
			pitch = 0.4,
			duration = 3.0,
			ui = true,
			source = "ambient",
			side = "client",
		},
		{
			name = "ambient.season.winter",
			category = "ambient.season",
			id = EXPLOSION,
			volume = 0.5,
			pitch = 0.32,
			duration = 3.0,
			ui = true,
			source = "ambient",
			side = "client",
		},
		{
			name = "ambient.season.spring",
			category = "ambient.season",
			id = EXPLOSION,
			volume = 0.5,
			pitch = 0.5,
			duration = 3.0,
			ui = true,
			source = "ambient",
			side = "client",
		},
		{
			name = "ambient.season.summer",
			category = "ambient.season",
			id = EXPLOSION,
			volume = 0.5,
			pitch = 0.45,
			duration = 3.0,
			ui = true,
			source = "ambient",
			side = "client",
		},
		{
			name = "ambient.season.heat_wave",
			category = "ambient.season",
			id = FALLING,
			volume = 0.5,
			pitch = 0.5,
			duration = 3.0,
			ui = true,
			source = "ambient",
			side = "client",
		},
	}
end
