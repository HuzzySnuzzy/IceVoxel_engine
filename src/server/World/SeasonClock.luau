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
	              and the blood moons stay), `setLocked(on)` (/gamerule doSeasonCycle false holds
	              the calendar at the exact time it is, so nothing moves; true runs on from the held
	              day: Calendar.hold), `keepCalendar(old, new)` (/time set: the offset takes the day
	              count's jump back). `changed` fires after each with the new state.
	  Saving      World/WorldSave's "seasons" section: `encode()` (Calendar.encode: { v, offset,
	              lock, lengths, day }, version 1 unless held at another time of day than a day's
	              middle; a world without seasons keeps the section it was read with, or saves
	              none, so neither the days played without them nor a hold set then are kept) and
	              `decode(value)` (re-anchored when Config's lengths changed). `restored()`, once
	              every section is back (the day clock's too), puts a calendar read back on the day
	              it was saved on at the restored time (so one carried through a world played
	              without seasons for a while comes back on its day, not as many days on), and
	              gives a world whose calendar was not read back (a new world, one saved before the
	              seasons or only ever without them, or a section that can't be read) `fresh()`:
	              Autumn's first day at that moment (Calendar.fresh), so every world has the same 8
	              mild days before its first winter.
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
-- The "seasons" section World/WorldSave gave back (saved again unchanged while the world has no
-- seasons), and whether it could be read.
local saved: any = nil
local read = false

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
	the offset moves (and the held day, while held).
]]
function SeasonClock.setSeason(season: number, day: number?)
	local offset, calendarDay = Calendar.offsetFor(season, (day or 1) - 1, TimeOfDay.get(), state)
	local s = table.clone(state)
	s.offset = offset
	local lock = s.lock
	if lock ~= nil then
		-- (Held: the held day moves, its time of day stays.)
		s.lock = calendarDay + (lock - math.floor(lock))
	end
	adopt(s)
end

-- Holds the calendar at the time it is (doSeasonCycle false), or runs it on from the held day.
function SeasonClock.setLocked(on: boolean)
	local s = Calendar.hold(state, on, TimeOfDay.get())
	if s ~= state then
		adopt(s)
	end
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

-- The calendar for the world's save (World/WorldSave's "seasons" section; see the header).
function SeasonClock.encode(): any
	return Calendar.encode(state, TimeOfDay.get(), saved)
end

-- Puts a saved calendar back (re-anchored to Config's lengths). false when it can't be read.
function SeasonClock.decode(value: any): boolean
	saved = value
	local s = Calendar.decode(value, Calendar.newState())
	if s == nil then
		return false
	end
	read = true
	adopt(s)
	return true
end

--[[
	World/WorldSave once every section is back, the day clock's too: a calendar read back is put on
	the day it was saved on at the restored time, a world whose calendar was not read back gets
	`fresh()` then (see the header).
]]
function SeasonClock.restored()
	if not read then
		SeasonClock.fresh()
		return
	end
	local s = Calendar.decode(saved, Calendar.newState(), TimeOfDay.get())
	if s then
		adopt(s)
	end
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
