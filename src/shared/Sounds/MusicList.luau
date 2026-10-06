--!strict
--[[
	The game's music and cave moods: every track and mood sound in this one hand-edited module, like
	the texture pack (Shared/TexturePack). Pure data that requires nothing.

	Music (Audio/Music, Minecraft's MusicManager)
	  Surface  played above ground (Minecraft's music.game): one at random, never the same twice
	           in a row, the first about five seconds after joining, then one every 10 to 20
	           minutes (Config.Music).
	  Cave     played in caves instead. Going underground fades a surface track out and starts a
	           cave one; coming back up does the same the other way. Surface music never plays
	           underground, nor cave music above it.
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
	(1.13907623876478E14); they are written out in full here.
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

	Cave = table.freeze({
		{ Id = "rbxassetid://273398061", Title = "" },
		{ Id = "rbxassetid://126756030478432", Title = "" },
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
