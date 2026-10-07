--!strict
--[[
	This player's status effects as the server last sent them (Protocol Effects, server
	Players/Effects), counted down here between messages (Shared/Effects.remaining, from when each
	message arrived; a `paused` one keeps its time): what the movement (Player/MovementController:
	speed, Jump Boost, Blindness), mining (Interaction/BlockInteraction: Haste, Mining Fatigue), the
	view (Rendering/EffectView: Night Vision, Blindness, Nausea), the HUD (Ui/EffectHud) and F3
	(Debug/DebugOverlay) read.

	An effect stays, at 0, until the server says it is gone (as Minecraft's client keeps it until
	the remove packet), so one refreshed every tick in a fluid never blinks out. `levels` is kept
	in a table of its own, rebuilt only when a message comes, so the per-tick readers make no
	garbage.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Effects = require(Shared.Effects)
local Protocol = require(Shared.Net.Protocol)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)

local EffectState = {}

local entries: { Effects.Entry } = {}
-- os.clock() when `entries` came.
local receivedAt = 0
local levels: Effects.Levels = {}
-- The modifiers of `levels`, worked out when they change.
local speedFactor, jumpBoost, fallReduction, miningFactor, noSprint = 1, 0, 0, 1, false
local changedEvent = Instance.new("BindableEvent")
-- Fires when the server sends the effects.
EffectState.changed = changedEvent.Event

-- Ticks since the last message.
local function elapsed(now: number?): number
	return math.floor(((now or os.clock()) - receivedAt) * Effects.TICKS_PER_SECOND)
end

-- The effects as of now (ticks left counted down; new entries, so callers may keep them).
function EffectState.list(now: number?): { Effects.Entry }
	local passed = elapsed(now)
	local list = table.create(#entries)
	for i, entry in entries do
		list[i] = {
			effect = entry.effect,
			amplifier = entry.amplifier,
			ticks = Effects.remaining(entry.ticks, passed, entry.paused),
			ambient = entry.ambient,
			paused = entry.paused,
		}
	end
	return list
end

-- How many effects the player has.
function EffectState.count(): number
	return #entries
end

-- The levels in force (read only).
function EffectState.levels(): Effects.Levels
	return levels
end

-- The amplifier of effect `effect` (nil: not running) and its ticks left.
function EffectState.get(effect: number): (number?, number)
	for _, entry in entries do
		if entry.effect == effect then
			return entry.amplifier, Effects.remaining(entry.ticks, elapsed(), entry.paused)
		end
	end
	return nil, 0
end

-- The ground speed's multiplier (Shared/Effects.speedFactor).
function EffectState.speedFactor(): number
	return speedFactor
end

-- Jump Boost: the jump velocity added and the blocks of fall taken off.
function EffectState.jumpBoost(): (number, number)
	return jumpBoost, fallReduction
end

-- The mining speed's multiplier (Haste, Mining Fatigue).
function EffectState.miningFactor(): number
	return miningFactor
end

-- May sprinting not start (Blindness)?
function EffectState.noSprint(): boolean
	return noSprint
end

function EffectState.start()
	ClientNet.on(Protocol.ServerMessage.Effects, function(payload: buffer)
		local list = Protocol.decodeEffects(payload)
		if list == nil then
			return
		end
		entries = list
		receivedAt = os.clock()
		Effects.levelsOf(list, levels)
		-- (The external effects, Tough As Nails', change no modifier.)
		speedFactor = Effects.speedFactor(levels)
		jumpBoost, fallReduction = Effects.jumpBoost(levels)
		miningFactor = Effects.miningFactor(levels)
		noSprint = Effects.noSprint(levels)
		changedEvent:Fire()
	end)
end

return EffectState
