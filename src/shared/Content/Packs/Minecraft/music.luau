--!strict
--[[
	The game's music and cave moods (Sounds/MusicList; every track the data sheets brought), each
	track by name in its set:

	  surface  played above ground by day (Minecraft's music.game, client Audio/Music; Audio/
	           MusicRules decides): one at random, never the same twice in a row, the first about
	           five seconds after joining, then one every 10 to 20 minutes (Config.Music).
	  night    played above ground at night instead (the sheet's "Surface NightTime"). Night is the
	           game's own rule (Shared/DayCycle.isDay false: the sky darkened by 4 or more, from a
	           little before sunset to a little after sunrise), read when a track is picked: a
	           track already playing is never cut at dusk or dawn, the next one follows the time
	           then. Empty (or every track failed to load), the surface tracks play at night too.
	  cave     played in caves instead, by day or night. Going underground fades a surface (or
	           night) track out and starts a cave one; coming back up does the same the other way.
	           Surface and night music never play underground, nor cave music above it.
	  mood     the cave mood sounds (client Audio/Ambience, Minecraft's ambient.cave): one at
	           random each time the player's mood fills up, exactly as Minecraft's
	           AmbientMoodSettings (Audio/CaveMood): about five minutes in darkness, sooner in big
	           dark caves, never in daylight. Each becomes the sound event ambient.cave.<name>
	           (Shared/Sounds), which a developer's Sound named "ambient.cave" replaces all at once.

	A track's `title` is what the "Now Playing" toast shows (top right, five seconds); none (or "")
	uses the audio's own name on Roblox. Ids are Audio asset ids, pasted as "rbxassetid://<number>";
	a track that fails to load is skipped with a warning in the output. The sheet's numbers were
	stored in scientific notation (1.13907623876478E14); they are written out in full here. To swap
	a track, change its id (or override it from another pack: { name = "surface3", override =
	true, id = "rbxassetid://..." }); to add one, add a line in any pack's music
	(tests/spec/DataSheet lists the sheets' ids and where each is used).
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

type TrackSpec = Schema.TrackSpec

return {
	{ name = "surface1", id = "rbxassetid://113907623876478", set = "surface" },
	{ name = "surface2", id = "rbxassetid://113269463310886", set = "surface" },
	{ name = "surface3", id = "rbxassetid://113768486498339", set = "surface" },
	{ name = "surface4", id = "rbxassetid://88638648436202", set = "surface" },
	{ name = "surface5", id = "rbxassetid://117523583270123", set = "surface" },
	-- (The sheet lists this one twice; once here, so it is no likelier than the others.)
	{ name = "surface6", id = "rbxassetid://133280331530620", set = "surface" },
	{ name = "surface7", id = "rbxassetid://89662535725069", set = "surface" },
	{ name = "surface8", id = "rbxassetid://123537706443951", set = "surface" },
	{ name = "surface9", id = "rbxassetid://99841996643075", set = "surface" },
	{ name = "surface10", id = "rbxassetid://123776818879153", set = "surface" },
	{ name = "surface11", id = "rbxassetid://129286525761355", set = "surface" },
	{ name = "surface12", id = "rbxassetid://84321425916963", set = "surface" },

	-- The surface at night (the sheet's "Surface NightTime").
	{ name = "night1", id = "rbxassetid://83363159814829", set = "night" },
	{ name = "night2", id = "rbxassetid://110580815646457", set = "night" },
	{ name = "night3", id = "rbxassetid://87554050890182", set = "night" },
	{ name = "night4", id = "rbxassetid://75930652698872", set = "night" },
	{ name = "night5", id = "rbxassetid://88972071265388", set = "night" },
	{ name = "night6", id = "rbxassetid://128714671201955", set = "night" },
	{ name = "night7", id = "rbxassetid://92470995513267", set = "night" },

	{ name = "cave1", id = "rbxassetid://273398061", set = "cave" },
	{ name = "cave2", id = "rbxassetid://126756030478432", set = "cave" },
	{ name = "cave3", id = "rbxassetid://1836908773", set = "cave" },
	{ name = "cave4", id = "rbxassetid://140269757258221", set = "cave" },
	{ name = "cave5", id = "rbxassetid://118738985293021", set = "cave" },
	{ name = "cave6", id = "rbxassetid://106093225151190", set = "cave" },

	{ name = "mood1", id = "rbxassetid://129596504262084", set = "mood" },
	{ name = "mood2", id = "rbxassetid://92671801078579", set = "mood" },
	{ name = "mood3", id = "rbxassetid://140430780061652", set = "mood" },
	{ name = "mood4", id = "rbxassetid://9113731836", set = "mood" },
	{ name = "mood5", id = "rbxassetid://3231980820", set = "mood" },
	{ name = "mood6", id = "rbxassetid://3999390679", set = "mood" },
	{ name = "mood7", id = "rbxassetid://3419187043", set = "mood" },
	{ name = "mood8", id = "rbxassetid://3231984721", set = "mood" },
	{ name = "mood9", id = "rbxassetid://3196341435", set = "mood" },
	{ name = "mood10", id = "rbxassetid://71546148533093", set = "mood" },
} :: { TrackSpec }
