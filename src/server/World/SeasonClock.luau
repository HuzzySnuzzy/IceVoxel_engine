--!strict
--[[
	The seasons' calendar on the server (Shared/Seasons/Calendar): the one authoritative state
	(the offset added to the day count, the lock while doSeasonCycle is off, the lengths), set as
	the calendar's module state (so the server's sun, Shared/DayCycle.solarTime, follows it) and
	published for the clients.

	  Publishing  Calendar.writeAttributes: workspace attributes Calendar.ATTRIBUTE_ENABLED,
	              _OFFSET, _LOCK and _LENGTHS, written when something changes and again every
	              RESYNC_SECONDS (which only restores them if another script changed them), as
	              World/TimeOfDay does. Clients read them (Rendering/LightingController) and work
	              everything else out themselves: nothing derived from the calendar is sent.
	  Off         Config.Seasons.Enabled false, or a world type without ticks (the debug worlds:
	              `start(false)`, as the weather): published disabled, every rule the identity.
	  Changes     `setSeason(season, day)` (/season set: only the offset moves, the time of day
	              and the blood moons stay), `setLocked(on)` (/gamerule doSeasonCycle false locks
	              the calendar day it is; true runs on from it), `keepCalendar(old, new)` (/time
	              set: the offset takes the day count's jump back). `changed` fires after each with
	              the new state.
	  Saving      World/WorldSave's "seasons" section: `encode()` (Calendar.encode: { v = 1,
	              offset, lock, lengths, day }) and `decode(value)` (re-anchored when Config's
	              lengths changed). A world with no section (a new world, or one saved before the
	              seasons) gets `fresh()` once its sections are back: Autumn's first day at that
	              moment (Calendar.fresh), so every world has the same 8 mild days before its
	              first winter.
	Starts before World/WeatherServer (the weather's season Moment reads the calendar).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Calendar = require(Shared.Seasons.Calendar)

local TimeOfDay = require(script.Parent.TimeOfDay)

-- Seconds between writing the (unchanged) attributes again.
local RESYNC_SECONDS = 60

local SeasonClock = {}

local changedEvent = Instance.new("BindableEvent")
-- Fires (state: Calendar.State) after the calendar changed (a season set, the lock, /time set, a
-- save read back).
SeasonClock.changed = changedEvent.Event

local started = false
-- Whether this world has seasons at all (`start`'s and Config's).
local allowed = Config.Seasons.Enabled == true
local state: Calendar.State = Calendar.newState()
state.enabled = false

local function publish()
	Calendar.setState(state)
	if started then
		Calendar.writeAttributes(state, function(name: string, value: any)
			workspace:SetAttribute(name, value)
		end)
	end
end

local function changed()
	publish()
	changedEvent:Fire(state)
end

-- A copy of `s` with this world's switch (so a save never turns the seasons on or off).
local function adopt(s: Calendar.State)
	s.enabled = allowed
	state = s
	changed()
end

-- The calendar's state (read only: change it with the functions below).
function SeasonClock.state(): Calendar.State
	return state
end

-- The calendar's position now (Calendar.Position).
function SeasonClock.position(): Calendar.Position
	return Calendar.position(TimeOfDay.get(), state)
end

-- Does this world have seasons?
function SeasonClock.enabled(): boolean
	return state.enabled
end

--[[
	Sets the season (Calendar.AUTUMN .. SUMMER) and its day (1-based, as /season set takes it;
	default 1, within the season's length) at the time of day it is, in the year it is in: only
	the offset moves (and the lock, while locked).
]]
function SeasonClock.setSeason(season: number, day: number?)
	local offset, calendarDay = Calendar.offsetFor(season, (day or 1) - 1, TimeOfDay.get(), state)
	local s = table.clone(state)
	s.offset = offset
	if s.lock ~= nil then
		s.lock = calendarDay
	end
	adopt(s)
end

-- Locks the calendar on the day it is (doSeasonCycle false), or runs it on from the locked day.
function SeasonClock.setLocked(on: boolean)
	local now = TimeOfDay.get()
	local s = table.clone(state)
	if on and s.lock == nil then
		s.lock = Calendar.day(now, state)
	elseif not on and s.lock ~= nil then
		-- (On from the locked day: no jump.)
		s.offset = (s.lock :: number) - math.floor(now / Calendar.TICKS_PER_DAY)
		s.lock = nil
	else
		return
	end
	adopt(s)
end

-- Is the calendar running (doSeasonCycle)?
function SeasonClock.cycle(): boolean
	return state.lock == nil
end

-- The day time jumps from `oldDayTime` to `newDayTime` (/time set): the calendar day stays.
function SeasonClock.keepCalendar(oldDayTime: number, newDayTime: number)
	local s = table.clone(state)
	s.offset = Calendar.keep(oldDayTime, newDayTime, state)
	adopt(s)
end

-- A world without a saved calendar: Autumn's first day now (see the header).
function SeasonClock.fresh()
	adopt(Calendar.fresh(TimeOfDay.get()))
end

-- The calendar for the world's save (World/WorldSave's "seasons" section).
function SeasonClock.encode(): any
	return Calendar.encode(state, TimeOfDay.get())
end

-- Puts a saved calendar back (re-anchored to Config's lengths). false when it can't be read.
function SeasonClock.decode(value: any): boolean
	local s = Calendar.decode(value, Calendar.newState())
	if s == nil then
		return false
	end
	adopt(s)
	return true
end

--[[
	Starts publishing; `enabled` false (a world type without ticks: the debug worlds) publishes the
	seasons off whatever Config says.
]]
function SeasonClock.start(enabled: boolean?)
	assert(not started, "SeasonClock.start was already called")
	started = true
	allowed = enabled ~= false and Config.Seasons.Enabled == true
	state.enabled = allowed
	publish()
	task.spawn(function()
		while true do
			task.wait(RESYNC_SECONDS)
			publish()
		end
	end)
end

return SeasonClock
