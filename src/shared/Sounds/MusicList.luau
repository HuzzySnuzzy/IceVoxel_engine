--!strict
--[[
	The game's music and cave moods: the content packs' `music` (Shared/Content; Content/Schema's
	MUSIC_FIELDS), merged by name, each track in its set, as the client's music and the sound
	catalogue read them. The tracks themselves are the packs' (the Minecraft pack's music lists
	every track the data sheets brought, and its header says how each set plays); a pack adds a
	track to a set with a line of its own, or patches one by name (`override = true`).

	  Surface, Night, Cave   the tracks of the sets "surface", "night" and "cave", in load order,
	                         as { Id, Title } (client Audio/Music; Audio/MusicRules decides which)
	  Moods                  the cave moods' ids (set "mood"), in load order; MOOD_NAMES their
	                         tracks' names: Shared/Sounds makes each the event
	                         ambient.cave.<name>
	  tracks                 every track's entry, in load order (Schema's TrackSpec)
]]

local Content = require(script.Parent.Parent.Content)
local Schema = require(script.Parent.Parent.Content.Schema)

export type Track = {
	-- "rbxassetid://<number>"
	Id: string,
	-- Shown by the Now Playing toast; "" uses the audio's name on Roblox.
	Title: string,
}

local tracks: { Schema.TrackSpec } = Content.default.music
local sets: { [string]: { Track } } = { surface = {}, night = {}, cave = {} }
local moods: { string } = {}
local moodNames: { string } = {}
for _, spec in tracks do
	if spec.set == "mood" then
		table.insert(moods, spec.id)
		table.insert(moodNames, spec.name)
	else
		table.insert(sets[spec.set], table.freeze({ Id = spec.id, Title = spec.title or "" }))
	end
end

return table.freeze({
	Surface = table.freeze(sets.surface),
	Night = table.freeze(sets.night),
	Cave = table.freeze(sets.cave),
	Moods = table.freeze(moods),
	MOOD_NAMES = table.freeze(moodNames),
	tracks = tracks,
})
