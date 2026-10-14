--!strict
--[[
	The game's music and cave moods: every track and mood sound in this one hand-edited module, like
	the texture pack (Shared/TexturePack). Pure data that requires nothing.

	Music (Audio/Music, Minecraft's MusicManager; Audio/MusicRules decides)
	  Surface  played above ground by day (Minecraft's music.game): one at random, never the same
	           twice in a row, the first about five seconds after joining, then one every 10 to 20
	           minutes (Config.Music).
	  Night    played above ground at night instead (the sheet's "Surface NightTime"). Night is the
	           game's own rule (Shared/DayCycle.isDay false: the sky darkened by 4 or more, from a
	           little before sunset to a little after sunrise), read when a track is picked: a
	           track already playing is never cut at dusk or dawn, the next one follows the time
	           then. Empty (or every track failed to load), the Surface tracks play at night too.
	  Cave     played in caves instead, by day or night. Going underground fades a surface (or
	           night) track out and starts a cave one; coming back up does the same the other way.
	           Surface and night music never play underground, nor cave music above it.
	  Each track is { Id = "rbxassetid://<number>", Title = "..." }. Title is what the "Now
	  Playing" toast shows (top right, five seconds); "" uses the audio's own name on Roblox.

	Moods (Audio/Ambience, Minecraft's ambient.cave)
	  The cave mood sounds: one at random each time the player's mood fills up, exactly as
	  Minecraft's AmbientMoodSettings (Audio/CaveMood): about five minutes in darkness, sooner in
	  big dark caves, never in daylight. They become the sound events ambient.cave.mood1,
	  ambient.cave.mood2, ... (Sounds/SoundList), which a developer's Sound named
	  "ambient.cave" replaces all at once.

	Ids are Audio asset ids, pasted as "rbxassetid://<number>"; a track that fails to load is
	skipped with a warning in the output. The sheet's numbers were stored in scientific notation
	(1.13907623876478E14); they are written out in full here. To swap a track, change its id; to
	add one, add a line (tests/spec/DataSheet lists the sheets' ids and where each is used).
]]

export type Track = {
	-- "rbxassetid://<number>"
	Id: string,
	-- Shown by the Now Playing toast; "" uses the audio's name on Roblox.
	Title: string,
}

return table.freeze({
	Surface = table.freeze({
		{ Id = "rbxassetid://113907623876478", Title = "" },
		{ Id = "rbxassetid://113269463310886", Title = "" },
		{ Id = "rbxassetid://113768486498339", Title = "" },
		{ Id = "rbxassetid://88638648436202", Title = "" },
		{ Id = "rbxassetid://117523583270123", Title = "" },
		-- (The sheet lists this one twice; once here, so it is no likelier than the others.)
		{ Id = "rbxassetid://133280331530620", Title = "" },
		{ Id = "rbxassetid://89662535725069", Title = "" },
		{ Id = "rbxassetid://123537706443951", Title = "" },
		{ Id = "rbxassetid://99841996643075", Title = "" },
		{ Id = "rbxassetid://123776818879153", Title = "" },
		{ Id = "rbxassetid://129286525761355", Title = "" },
		{ Id = "rbxassetid://84321425916963", Title = "" },
	}) :: { Track },

	-- The surface at night (the sheet's "Surface NightTime").
	Night = table.freeze({
		{ Id = "rbxassetid://83363159814829", Title = "" },
		{ Id = "rbxassetid://110580815646457", Title = "" },
		{ Id = "rbxassetid://87554050890182", Title = "" },
		{ Id = "rbxassetid://75930652698872", Title = "" },
		{ Id = "rbxassetid://88972071265388", Title = "" },
		{ Id = "rbxassetid://128714671201955", Title = "" },
		{ Id = "rbxassetid://92470995513267", Title = "" },
	}) :: { Track },

	Cave = table.freeze({
		{ Id = "rbxassetid://273398061", Title = "" },
		{ Id = "rbxassetid://126756030478432", Title = "" },
		{ Id = "rbxassetid://1836908773", Title = "" },
		{ Id = "rbxassetid://140269757258221", Title = "" },
		{ Id = "rbxassetid://118738985293021", Title = "" },
		{ Id = "rbxassetid://106093225151190", Title = "" },
	}) :: { Track },

	Moods = table.freeze({
		"rbxassetid://129596504262084",
		"rbxassetid://92671801078579",
		"rbxassetid://140430780061652",
		"rbxassetid://9113731836",
		"rbxassetid://3231980820",
		"rbxassetid://3999390679",
		"rbxassetid://3419187043",
		"rbxassetid://3231984721",
		"rbxassetid://3196341435",
		"rbxassetid://71546148533093",
	}) :: { string },
})
