--!strict
--[[
	Snow on the server (Shared/Seasons/SnowLayers' tile rules, Shared/Seasons/SeasonClimate's caps
	and melting; Config.Seasons.Snow): snow layers pile up where it snows and melt where it is
	warm, still water freezes from its edges in winter and thaws in spring.

	  Visits     every tick (`tick`, with Simulation.activeChunks: the chunks around players) each
	             active chunk is visited with chance TileChance, at most MaxTilesPerTick a tick: one
	             of its 4 x 4 tiles (SnowLayers.TILE), whose columns (WeatherRules.top, the blocks at
	             and below it, SeasonClimate.snowCap) go to SnowLayers.accumulate while it snows
	             there (WeatherServer.snowingAt) and SnowLayers.melt where it melts.
	  Writes     snow and ice made by the weather go through WorldServer.setWeather (the world's
	             natural map: melting back to what the seed made deletes the edit instead of
	             keeping it), at most 16 a visit, sent with the frame's edits.
	  Heat       every HeatMeltSeconds (`step`), each lit or working heat source in an active chunk
	             (Players/Climate.isHeating; kept from `blockChanged`) melts a layer of every snow
	             cell within HeatMeltRadius; a layer in or on a room at RoomMelt or warmer
	             (Seasons/RoomWorld.temperatureAt) melts when visited.
	Stub until the snow lands: nothing is visited, nothing piles or melts. The API is frozen.
]]

local SnowWorld = {}

local started = false

-- Starts the snow in `world` (World/WorldServer).
function SnowWorld.start(_world: any)
	assert(not started, "SnowWorld.start was already called")
	started = true
end

-- WorldServer.onChanged: block (x, y, z) went from `old` to `new` (heat sources come and go).
function SnowWorld.blockChanged(_x: number, _y: number, _z: number, _old: number, _new: number) end

-- One server tick's tile visits over the active `chunks` (Simulation.activeChunks).
function SnowWorld.tick(_chunks: { any }) end

-- A frame's work after the machines (the heat melt every HeatMeltSeconds).
function SnowWorld.step(_dt: number) end

return SnowWorld
