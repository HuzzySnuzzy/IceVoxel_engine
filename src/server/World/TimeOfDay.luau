--!strict
--[[
	The world's clock (Minecraft's day time, see Shared/DayCycle). The server is the authority.

	  Publishing  the clock is a base day time at a server time plus a speed, published as the
	              workspace attributes DayCycle.ATTRIBUTE_TIME, _SYNC and _RATE. Clients compute the
	              time from them with workspace:GetServerTimeNow(), so nothing is sent while it
	              runs. They change only when the time is set (/time, `set`, `add`) or the cycle is
	              turned on or off (/gamerule doDaylightCycle, `setCycle`). Every RESYNC_SECONDS the
	              same values are written again, which only restores them if another script changed
	              them. The clock is never re-based on a timer: server and clients compute the same
	              closed form from the same numbers, so there is no drift to correct, and a re-base
	              changes all three attributes at once, which a client could see half applied (the
	              sun jumping back for a frame).
	  Speed       Config.Time.DayLength real seconds a day (24000 ticks); 0 while
	              Config.Time.Cycle (doDaylightCycle) is off.
	  Game time   ticks since the server started, at 20 a second whatever the day length
	              (/time query gametime).

	Lighting.ClockTime is set by each client (Rendering/LightingController), not here: a server value
	would replicate and fight the clients' smooth one. Server scripts read the time with `get`.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local DayCycle = require(Shared.DayCycle)

-- Seconds between writing the (unchanged) clock attributes again.
local RESYNC_SECONDS = 60

local TimeOfDay = {}

local changedEvent = Instance.new("BindableEvent")
-- Fires (dayTime: number, cycle: boolean) after the time was set or the cycle turned on or off.
TimeOfDay.changed = changedEvent.Event

local started = false
-- The day time at server time `syncedAt`, advancing at `rate()` ticks a second.
local base = Config.Time.StartTime
local syncedAt = 0
local cycle = Config.Time.Cycle
local startedAt = 0

local function rate(): number
	return if cycle then DayCycle.rate() else 0
end

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local function publish()
	workspace:SetAttribute(DayCycle.ATTRIBUTE_SYNC, syncedAt)
	workspace:SetAttribute(DayCycle.ATTRIBUTE_RATE, rate())
	workspace:SetAttribute(DayCycle.ATTRIBUTE_TIME, base)
end

-- Moves the base to now (same time, fresh numbers), before the speed changes.
local function rebase()
	if started then
		local now = serverNow()
		base = DayCycle.now(base, syncedAt, now, rate())
		syncedAt = now
	end
end

-- The day time now, in ticks (counting past 24000: day 1, 2 ...).
function TimeOfDay.get(): number
	if not started then
		return base
	end
	return DayCycle.now(base, syncedAt, serverNow(), rate())
end

-- Is the day cycle running (Minecraft's doDaylightCycle)?
function TimeOfDay.cycle(): boolean
	return cycle
end

-- Ticks since the server started (Minecraft's game time).
function TimeOfDay.gameTime(): number
	if not started then
		return 0
	end
	return math.floor((serverNow() - startedAt) * DayCycle.TICKS_PER_SECOND)
end

-- Sets the day time (ticks; 1000 is "day", 6000 noon, 13000 night, 18000 midnight).
function TimeOfDay.set(dayTime: number)
	assert(dayTime == dayTime and math.abs(dayTime) ~= math.huge, "TimeOfDay.set needs a finite number")
	base = dayTime
	syncedAt = if started then serverNow() else 0
	if started then
		publish()
	end
	changedEvent:Fire(base, cycle)
end

-- Moves the time forward by `ticks`.
function TimeOfDay.add(ticks: number)
	TimeOfDay.set(TimeOfDay.get() + ticks)
end

-- Starts or stops the day cycle (Minecraft's doDaylightCycle); the time stays where it is.
function TimeOfDay.setCycle(on: boolean)
	if on == cycle then
		return
	end
	rebase()
	cycle = on
	if started then
		publish()
	end
	changedEvent:Fire(base, cycle)
end

function TimeOfDay.start()
	assert(not started, "TimeOfDay.start was already called")
	started = true
	startedAt = serverNow()
	syncedAt = startedAt
	publish()
	task.spawn(function()
		while true do
			task.wait(RESYNC_SECONDS)
			publish()
		end
	end)
end

return TimeOfDay
