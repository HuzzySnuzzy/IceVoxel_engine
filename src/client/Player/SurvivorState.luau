--!strict
--[[
	This character's survivor record as the server last sent it (Protocol Survivor, server
	Apocalypse/Survival: on joining, respawning, a restore, a kill or a blood moon survived, and
	every Config.Apocalypse.Survivor.SyncTicks): its alive ticks since it last died, its zombie
	kills and the blood moons it survived. The day counter (Ui/SurvivorHud) reads it. Between
	messages the alive ticks are counted on here at 20 a second (never more than two sync
	intervals past the last message, should one be lost), so the counter turns over on time.
	`moonsRaised` fires when a message counts more blood moons survived than the one before it
	(the server counted one, or a saved record came back: Ui/SurvivorLine.confirmSet tells them
	apart by the moon setting). Nothing comes with Config.Apocalypse.Enabled off: `alive` stays
	nil.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Protocol = require(Shared.Net.Protocol)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)

local SurvivorState = {}

local TICKS_PER_SECOND = 20

local last: Protocol.Survivor? = nil
-- os.clock() when `last` came.
local receivedAt = 0
local started = false
local changedEvent = Instance.new("BindableEvent")
local moonsEvent = Instance.new("BindableEvent")
-- Fires when a Survivor message changes the record.
SurvivorState.changed = changedEvent.Event
-- Fires when a Survivor message raises the blood moons survived (see the header).
SurvivorState.moonsRaised = moonsEvent.Event

-- Alive ticks now (counted on since the last message; nil before the first).
function SurvivorState.alive(now: number?): number?
	local record = last
	if record == nil then
		return nil
	end
	local limit = 2 * Config.Apocalypse.Survivor.SyncTicks
	local passed = math.clamp(((now or os.clock()) - receivedAt) * TICKS_PER_SECOND, 0, limit)
	return record.alive + math.floor(passed)
end

-- Zombies killed and blood moons survived (0, 0 before the first message).
function SurvivorState.counts(): (number, number)
	local record = last
	if record == nil then
		return 0, 0
	end
	return record.kills, record.moons
end

function SurvivorState.start()
	if started then
		return
	end
	started = true
	ClientNet.on(Protocol.ServerMessage.Survivor, function(payload: buffer)
		local record = Protocol.decodeSurvivor(payload)
		if record == nil then
			return
		end
		local before = last
		last = record
		receivedAt = os.clock()
		changedEvent:Fire()
		if before and record.moons > before.moons then
			moonsEvent:Fire()
		end
	end)
end

return SurvivorState
