--!strict
--[[
	Sounds the server plays: it tells the players near a sound which event (Shared/Sounds) to play
	where, like Minecraft's ServerLevel.playSound and PlayerList.broadcast.

	  Who hears  every player whose feet are within the event's maxDistance (scaled up by a volume
	             above 1, as Minecraft does) plus Config.Sounds.BroadcastSlack blocks, except the
	             one given: the player whose own client already played it (a block they broke or
	             placed, their own hurting landing: the events whose `side` is "predicted").
	  Batching   sounds queue up and go out once per frame (Heartbeat), one Protocol `Sound`
	             message per player holding all of theirs, at most Config.Sounds.MaxPerFrame (the
	             rest are dropped).
	  Budget     sounds that a player's own messages cause (armor put on by inventory clicks,
	             chest lids opened and closed) go through `allow`: at most Config.Sounds.PlayerRate
	             a second each, in bursts of twice that, so a client spamming those messages
	             can't stream sounds to everyone near it.
	  Off        before `start` and with Config.Sounds.Enabled false, playing does nothing. Flat
	             (`ui`) events are the local player's alone and are never sent.

	What plays where (the hooks): blocks broken and placed by players (Network/ServerNet), torches
	and lanterns popping off (Behaviours/Attached), chest lids (Players/Inventories through
	Containers' `onOpeners`), armor put on and tools wearing out (Players/Inventories), item pickups
	(Entities/Entities), hurting, dying and hurting landings (Players/Characters).

	From your own server scripts:

	    local Sounds = require(game.ServerScriptService.IceVoxel.Audio.Sounds)
	    Sounds.play("block.glass.break", x + 0.5, y + 0.5, z + 0.5)   -- blocks
	    Sounds.playBlock(block, "place", x, y, z)                      -- a block's own sound
	    Sounds.playAt(player, "entity.player.hurt")                    -- at a player's feet

	The queue, its routing and the budget are pure (`newQueue`, `newLimiter`), so the tests run
	them.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Protocol = require(Shared.Net.Protocol)
local Rig = require(Shared.Movement.Rig)
local SharedSounds = require(Shared.Sounds)

type SoundCue = Protocol.SoundCue

-- Only what Sounds uses of ServerNet.ServerNet (no require, so ServerNet may require this).
type Net = { send: (player: Player, kind: number, payload: buffer) -> () }

-- Someone who may hear sounds: any key (Players in the game) and their feet (blocks).
export type Listener = { key: any, x: number, y: number, z: number }

type Pending = { cue: SoundCue, except: any, range: number }

export type Queue = {
	pending: { Pending },
	-- Queues event `sound` at (x, y, z) (blocks) for everyone near but `except`.
	add: (
		self: Queue,
		sound: number,
		x: number,
		y: number,
		z: number,
		except: any?,
		volume: number?,
		pitch: number?
	) -> (),
	-- Who hears what: the queued cues by listener key (in the order queued, at most `limit` each),
	-- emptying the queue.
	route: (self: Queue, listeners: { Listener }, limit: number?) -> { [any]: { SoundCue } },
}

export type Limiter = {
	rate: number,
	burst: number,
	buckets: { [any]: { tokens: number, last: number } },
	-- Whether `key` may cause one more sound at time `now` (seconds), using it up if so.
	allow: (self: Limiter, key: any, now: number) -> boolean,
}

local Sounds = {}

-- The most a cue's volume or pitch multiplier can be (Protocol `Sound` carries 0..2.55).
local MAX_SCALE = 2.55

local function finite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local Queue = {}
Queue.__index = Queue

function Queue.add(
	self: Queue,
	sound: number,
	x: number,
	y: number,
	z: number,
	except: any?,
	volume: number?,
	pitch: number?
)
	local event = SharedSounds.get(sound)
	if event == nil or event.ui or not (finite(x) and finite(y) and finite(z)) then
		return
	end
	-- (What the wire can carry, so a louder request doesn't carry further than it sounds.)
	local scale = if volume == nil or volume ~= volume then 1 else math.clamp(volume, 0, MAX_SCALE)
	table.insert(self.pending, {
		cue = { sound = sound, x = x, y = y, z = z, volume = scale, pitch = pitch or 1 },
		except = except,
		-- (Minecraft: a sound louder than 1 carries 16 x volume blocks.)
		range = event.maxDistance * math.max(1, scale) + Config.Sounds.BroadcastSlack,
	})
end

function Queue.route(self: Queue, listeners: { Listener }, limit: number?): { [any]: { SoundCue } }
	local out: { [any]: { SoundCue } } = {}
	local max = limit or math.huge
	local pending = self.pending
	self.pending = {}
	for _, entry in pending do
		local cue = entry.cue
		local rangeSq = entry.range * entry.range
		for _, listener in listeners do
			if listener.key ~= entry.except then
				local dx, dy, dz = listener.x - cue.x, listener.y - cue.y, listener.z - cue.z
				if dx * dx + dy * dy + dz * dz <= rangeSq then
					local list = out[listener.key]
					if list == nil then
						list = {}
						out[listener.key] = list
					end
					if #list < max then
						table.insert(list, cue)
					end
				end
			end
		end
	end
	return out
end

-- A new, empty queue (the game uses one of its own; tests make theirs).
function Sounds.newQueue(): Queue
	return (setmetatable({ pending = {} }, Queue) :: any) :: Queue
end

local Limiter = {}
Limiter.__index = Limiter

function Limiter.allow(self: Limiter, key: any, now: number): boolean
	local bucket = self.buckets[key]
	if bucket == nil then
		bucket = { tokens = self.burst, last = now }
		self.buckets[key] = bucket
	end
	bucket.tokens = math.min(self.burst, bucket.tokens + math.max(0, now - bucket.last) * self.rate)
	bucket.last = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

-- A token bucket per key: `rate` sounds a second, at most `burst` at once (weak keys: players who
-- left are forgotten).
function Sounds.newLimiter(rate: number, burst: number): Limiter
	local buckets = setmetatable({}, { __mode = "k" }) :: any
	return (setmetatable({ rate = rate, burst = burst, buckets = buckets }, Limiter) :: any) :: Limiter
end

local queue = Sounds.newQueue()
local limiter = Sounds.newLimiter(Config.Sounds.PlayerRate, Config.Sounds.PlayerRate * 2)
local started = false

--[[
	Whether `player`'s own requests may cause one more sound now (Config.Sounds.PlayerRate a
	second, bursts of twice that). Hooks ask before playing a sound a client's message caused.
]]
function Sounds.allow(player: Player): boolean
	return limiter:allow(player, os.clock())
end

local function resolve(sound: (number | string)?): number?
	if type(sound) == "string" then
		-- (Errors on unknown names: a typo should not just be silent.)
		return SharedSounds.id[sound]
	end
	return sound
end

--[[
	Plays event `sound` (a number or name; nil plays nothing) at (x, y, z) in blocks for every
	player near, except `except`. `volume` and `pitch` multiply the event's own (0..2.55).
]]
function Sounds.play(
	sound: (number | string)?,
	x: number,
	y: number,
	z: number,
	except: Player?,
	volume: number?,
	pitch: number?
)
	local index = resolve(sound)
	if started and index then
		queue:add(index, x, y, z, except, volume, pitch)
	end
end

--[[
	Plays the sound of `block` for `action` ("break", "place", "hit", "step", "fall"; its sound
	type's, Shared/Sounds.block) at the centre of block (x, y, z), except for `except`. Silent
	blocks play nothing.
]]
function Sounds.playBlock(block: number, action: string, x: number, y: number, z: number, except: Player?)
	Sounds.play(SharedSounds.block(block, action), x + 0.5, y + 0.5, z + 0.5, except)
end

-- Plays event `sound` at the feet of `player`'s character (nothing without one), except for
-- `except`.
function Sounds.playAt(player: Player, sound: (number | string)?, except: Player?, volume: number?, pitch: number?)
	if sound == nil or not started then
		return
	end
	local character = player.Character
	local feet = if character then Rig.feet(character) else nil
	if feet then
		Sounds.play(sound, feet.X, feet.Y, feet.Z, except, volume, pitch)
	end
end

-- Starts sending queued sounds to the players near them, once per frame. Does nothing when
-- Config.Sounds.Enabled is false.
function Sounds.start(net: Net)
	if started or not Config.Sounds.Enabled then
		return
	end
	started = true
	RunService.Heartbeat:Connect(function()
		if #queue.pending == 0 then
			return
		end
		local listeners: { Listener } = {}
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local feet = if character then Rig.feet(character) else nil
			if feet then
				table.insert(listeners, { key = player, x = feet.X, y = feet.Y, z = feet.Z })
			end
		end
		for key, cues in queue:route(listeners, Config.Sounds.MaxPerFrame) do
			local player = key :: Player
			if player.Parent then
				net.send(player, Protocol.ServerMessage.Sound, Protocol.encodeSounds(cues))
			end
		end
	end)
end

return Sounds
