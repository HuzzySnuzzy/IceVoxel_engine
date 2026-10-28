--!strict
--[[
	The weapons' sounds (Shared/Weapons; client Interaction/Firearms and Rendering/ShotView, server
	Weapons/). Stand-ins on the shipped files: a gun's shot is the explosion's crack, cut short and
	pitched by its class (a pistol high and short, a heavy rifle low and long; every class's fire
	event shares the category item.firearm.fire, so one Sound of that name replaces them all: the
	pack's `_sounds.shot`); a suppressed shot a soft, short crack; far away (beyond
	Config.Weapons.FarSound) a low rolling boom; the crossbow's twang a rustle pitched up. A dry
	trigger and a jam click the volume tick; reloading, chambering and attaching are thuds pitched
	up; a round loaded a tick; unloading a rustle. Bullets hitting a block a high tap, flesh the
	fifth sheet's "Entity Hit" (the dull thud its fallback). The melee rework's swing and heavy
	swing are rustles, a blocked hit a thud.

	  side       client: each client plays them (the shooter at once, the others from the Shots
	             message), never sent; predicted: the player's own client at once, the server to
	             everyone else when it accepts the action (reload, a round, chambering); server:
	             the server to everyone near (a blocked zombie hit).
	The fire event of a gun is item.firearm.<class>.fire (Shared/Weapons' FirearmSpec `sound`,
	which Weapons checks as it loads: every class in Weapons.CLASSES needs one), the crossbow's
	item.crossbow.fire.

	The calibres the fifth sheet recorded (CALIBRES: "9mm gunshot", "5.56 gunshot", ".308
	gunshot", and each "... silenced") have their own shots, last (the pack's
	`_sounds.calibreShots`): item.firearm.<calibre>.fire, which Rendering/ShotRules.fireSound plays
	for a gun of that calibre instead of its class's shot, heard as far as that class's (whose shot
	is its fallback), and item.firearm.<calibre>.suppressed through a working suppressor, instead
	of the generic item.firearm.suppressed (its fallback). Every one is an ordinary event: a Sound
	of its name in SoundService.IceVoxelSounds (or the override folder) replaces it.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)
local Shots = require(script.Parent.Parent._sounds)

type SoundSpec = Schema.SoundSpec

-- Each class's shot: volume, pitch, seconds of the crack, blocks it carries.
local CLASSES: { Shots.ClassShot } = {
	{ class = "pistol", volume = 0.9, pitch = 2.4, duration = 0.25, maxDistance = 128 },
	{ class = "revolver", volume = 1.0, pitch = 2.0, duration = 0.3, maxDistance = 144 },
	{ class = "smg", volume = 0.8, pitch = 2.7, duration = 0.18, maxDistance = 128 },
	{ class = "shotgun", volume = 1.2, pitch = 1.3, duration = 0.45, maxDistance = 160 },
	{ class = "rifle", volume = 1.1, pitch = 1.8, duration = 0.35, maxDistance = 192 },
	{ class = "heavy", volume = 1.3, pitch = 1.25, duration = 0.5, maxDistance = 224 },
	{ class = "small", volume = 0.45, pitch = 3.2, duration = 0.12, maxDistance = 48 },
}

-- The fifth sheet's recorded calibres (the calibre as Weapons/WeaponList names it), and the class
-- whose shot each falls back on.
local CALIBRES: { Shots.CalibreShot } = {
	{
		calibre = "9mm",
		fire = "rbxassetid://138905044369113",
		suppressed = "rbxassetid://89214508659473",
		class = "pistol",
	},
	{
		calibre = "556",
		fire = "rbxassetid://5910000043",
		suppressed = "rbxassetid://94291108433840",
		class = "rifle",
	},
	{
		calibre = "308",
		fire = "rbxassetid://135793582032227",
		suppressed = "rbxassetid://71834414905709",
		class = "heavy",
	},
}

return function(define: Define.Context): { SoundSpec }
	local SHIPPED = define.SHIPPED
	local LAND, TICK, GET_UP, EXPLOSION = SHIPPED.LAND, SHIPPED.TICK, SHIPPED.GET_UP, SHIPPED.EXPLOSION
	local list: { SoundSpec } = {}
	local byClass: { [string]: SoundSpec } = {}
	for _, spec in CLASSES do
		local shot = Shots.shot(spec)
		byClass[spec.class] = shot
		table.insert(list, shot)
	end
	define.append(list, {
		{
			name = "item.crossbow.fire",
			id = GET_UP,
			volume = 0.6,
			pitch = 2.2,
			duration = 0.25,
			maxDistance = 16,
			source = "players",
			side = "client",
		},
		{
			name = "item.firearm.suppressed",
			id = EXPLOSION,
			volume = 0.3,
			pitch = 3.6,
			pitchVariance = 0.1,
			duration = 0.08,
			maxDistance = 32,
			source = "players",
			side = "client",
		},
		{
			name = "item.firearm.far",
			id = EXPLOSION,
			volume = 0.5,
			pitch = 0.7,
			duration = 0.8,
			maxDistance = 256,
			source = "players",
			side = "client",
		},
		{
			name = "item.firearm.dry",
			id = TICK,
			volume = 0.5,
			pitch = 0.6,
			maxDistance = 8,
			source = "players",
			side = "client",
		},
		{
			name = "item.firearm.jam",
			id = TICK,
			volume = 0.7,
			pitch = 0.4,
			maxDistance = 8,
			source = "players",
			side = "client",
		},
		{
			name = "item.firearm.reload",
			id = LAND,
			volume = 0.5,
			pitch = 2.6,
			duration = 0.2,
			maxDistance = 16,
			source = "players",
			side = "predicted",
		},
		{
			name = "item.firearm.load_round",
			id = TICK,
			volume = 0.5,
			pitch = 1.6,
			maxDistance = 12,
			source = "players",
			side = "predicted",
		},
		{
			name = "item.firearm.chamber",
			id = LAND,
			volume = 0.6,
			pitch = 3.2,
			duration = 0.12,
			maxDistance = 16,
			source = "players",
			side = "predicted",
		},
		{
			name = "item.firearm.unload",
			id = GET_UP,
			volume = 0.4,
			pitch = 2.0,
			duration = 0.2,
			maxDistance = 8,
			source = "players",
			side = "client",
		},
		{
			name = "item.firearm.attach",
			id = LAND,
			volume = 0.4,
			pitch = 2.8,
			duration = 0.1,
			maxDistance = 8,
			source = "players",
			side = "client",
		},
		{
			name = "entity.bullet.impact",
			id = LAND,
			volume = 0.35,
			pitch = 2.2,
			pitchVariance = 0.2,
			maxDistance = 24,
			source = "players",
			side = "client",
		},
		{
			name = "entity.bullet.flesh",
			id = define.RECORDINGS.ENTITY_HIT,
			volume = 0.5,
			pitchVariance = 0.08,
			fallback = { id = LAND, pitch = 1.1 },
			maxDistance = 24,
			source = "players",
			side = "client",
		},
		{
			name = "item.melee.swing",
			id = GET_UP,
			volume = 0.4,
			pitch = 1.9,
			duration = 0.15,
			maxDistance = 12,
			source = "players",
			side = "client",
		},
		{
			name = "item.melee.heavy",
			id = GET_UP,
			volume = 0.6,
			pitch = 1.3,
			duration = 0.25,
			maxDistance = 16,
			source = "players",
			side = "client",
		},
		{
			name = "item.melee.block",
			id = LAND,
			volume = 0.8,
			pitch = 1.6,
			maxDistance = 16,
			source = "players",
			side = "server",
		},
	})
	for _, spec in CALIBRES do
		define.append(list, Shots.calibreShots(spec, byClass[spec.class]))
	end
	return list
end
