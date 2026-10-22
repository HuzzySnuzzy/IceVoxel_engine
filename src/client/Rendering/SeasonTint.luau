--!strict
--[[
	Foliage colours by season (Shared/Seasons/Foliage, Config.Seasons.Foliage): drives
	Rendering/ChunkRenderer's budgeted sweep that recolours the live seasonal parts in place (the
	colours from Rendering/TextureLooks), a step at a time while the palette moves, and marks far
	meshes stale when theirs moved far enough. Stub until the colours land: `start` does nothing,
	so foliage keeps its authored colours.
]]

local SeasonTint = {}

local started = false

-- Starts following the calendar (the client boot, after the renderer and the lighting).
function SeasonTint.start(_renderer: any)
	assert(not started, "SeasonTint.start was already called")
	started = true
end

return SeasonTint
