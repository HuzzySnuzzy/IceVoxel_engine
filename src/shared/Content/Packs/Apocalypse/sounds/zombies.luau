--!strict
--[[
	The zombies' sounds (server Mobs/, Apocalypse/; client Entities/ZombieVoices, Ui/SurvivorHud).

	  * Their voices (Shared/Entities/MobList; Content/Define's `mobVoice`): the zombie's (which
	    most zombie kinds use) and the runner's, brute's and screamer's own hurt and death, from
	    the server to everyone near. Stand-ins told apart by pitch, the ouch and the oof: low for
	    the brute, high for the screamer. Their real voices (the fourth data sheet's "Mob SFX": a
	    growl for every hurt, two deaths) ship as Sounds named like these events in
	    SoundService.IceVoxelSounds (src/sounds/Zombies.model.json), which play instead of the
	    stand-ins; the stand-ins stay, for a game without that folder (or a recording that fails to
	    load: Audio/SoundPlayer then plays the event's own sound again). Each voice has its own
	    Sounds, named by the event, never by the category: entity.mob.hurt would make the cows growl
	    too. A replacement plays at its own PlaybackSpeed varied by the event's variance as a share
	    of its pitch (Audio/SoundRules.playback): when hurt about +-13% for the zombie, +-10% the
	    runner, +-22% the brute and +-6% the screamer, half that or less dying. So the model pitches
	    the kinds 1, 1.3, 0.65 and 1.6, in the stand-ins' order and, as theirs, with no two kinds'
	    spreads overlapping (tests/spec/ZombieVoices checks it).
	  * The rest, stand-ins:
	      entity.zombie.ambient              a zombie's groan: the oof pitched down. Each client
	                                         plays it from the zombies it tracks (no server event),
	                                         at the gait's pitch (ZombieVoices.PITCH). The game
	                                         ships the sheet's three groans in
	                                         SoundService.IceVoxelSounds
	                                         (src/sounds/Zombies.model.json): one of them plays.
	      entity.zombie.attack_wooden_door   a zombie bashing the block it breaks: a heavy thud
	      entity.zombie.break_wooden_door    the block giving way: the explosion's crack pitched up
	      entity.zombie_screamer.scream      a screamer's shriek: the falling wind pitched far up
	      ambient.blood_moon.rise            a blood moon rising: a long, deep boom, flat
	Every one is an ordinary event, so a Sound of its name in SoundService.IceVoxelSounds (or the
	override folder) replaces it.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type SoundSpec = Schema.SoundSpec

return function(define: Define.Context): { SoundSpec }
	local SHIPPED = define.SHIPPED
	local list: { SoundSpec } = {}
	for _, voice in
		{
			{ kind = "zombie", hurt = 0.75, death = 0.7 },
			{ kind = "zombie_runner", hurt = 1.05, death = 1.0 },
			{ kind = "zombie_brute", hurt = 0.45, death = 0.4 },
			{ kind = "zombie_screamer", hurt = 1.55, death = 1.5 },
		} :: { Define.MobVoice }
	do
		define.append(list, define.mobVoice(voice))
	end
	define.append(list, {
		{
			name = "entity.zombie.ambient",
			id = SHIPPED.OOF,
			volume = 0.35,
			pitch = 0.45,
			pitchVariance = 0.12,
			maxDistance = 16,
			source = "players",
			side = "client",
		},
		{
			name = "entity.zombie.attack_wooden_door",
			id = SHIPPED.LAND,
			volume = 0.9,
			pitch = 0.7,
			pitchVariance = 0.1,
			maxDistance = 24,
			source = "players",
			side = "server",
		},
		{
			name = "entity.zombie.break_wooden_door",
			id = SHIPPED.EXPLOSION,
			volume = 0.45,
			pitch = 1.8,
			duration = 0.5,
			maxDistance = 32,
			source = "players",
			side = "server",
		},
		{
			name = "entity.zombie_screamer.scream",
			id = SHIPPED.FALLING,
			volume = 1.0,
			pitch = 2.4,
			duration = 1.6,
			maxDistance = 64,
			source = "players",
			side = "server",
		},
		{
			name = "ambient.blood_moon.rise",
			id = SHIPPED.EXPLOSION,
			volume = 0.7,
			pitch = 0.3,
			duration = 3.0,
			ui = true,
			source = "ambient",
			side = "client",
		},
	})
	return list
end
