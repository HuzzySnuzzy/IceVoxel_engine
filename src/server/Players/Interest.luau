--!strict
--[[
	Who may learn what about whom (Config.Players.ServerPositions; Config.Interest): the pure rules
	of "fake coords". Characters stand parked on the server, so nothing a client reads from Roblox
	says where anyone is; true positions reach a client only through what the server decides to
	send it, and these rules decide (Players/PlayerRelay, Network/ServerNet, the records senders).

	  players    `sees(viewer, target, wasVisible)`: Minecraft's tracked-entity rule
	             (ChunkMap.TrackedEntity.updatePlayer, ServerPlayer.broadcastToPlayer): never
	             oneself; both with a position; a spectator only by spectators (the client's
	             Player/SpectatorRules.sees, copied: the server requires no client module);
	             always the player the viewer spectates; never one leaving the game; else within PlayerDistance (256) blocks
	             horizontally to start being seen and PlayerDistance + PlayerHysteresis (272) to
	             stay seen (Minecraft: min(512, (view distance - 1) x 16), 144 at its default).
	             Dead players stay seen until their character goes (the clients play the death
	             tilt). `update` turns a viewer's set into tracks and untracks, `due` picks the
	             poses to send: changed since last sent, or older than KeepAliveSeconds.
	  chunks     `chunkAllowed`: a chunk's edit list (and the records sent with it) only within
	             EditChunkRadius (24, Chebyshev) chunks of the player's chunk (a spectator's is
	             their target's: Players/PositionStore.follow); `newDeferred` keeps the others
	             (at most DeferredChunkRequests, oldest dropped) until the player comes near:
	             the client asks for a list once and waits for it, so refusing would leave that
	             chunk without its edits for good.
	  edits      `routeEdits`: each player gets the frame's edits within EditSendRadius (26)
	             chunks of theirs, none without a position. The client keeps edit lists only
	             for the chunks near its viewer (about 8-10 chunks), so 26 leaves room for
	             latency and spectating jumps; farther lists are forgotten and asked for again.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Coords = require(Shared.World.Coords)

local PositionStore = require(script.Parent.PositionStore)

type Record = PositionStore.Record

local CHUNK = Config.ChunkSize

local Interest = {}

-- What a viewer was last sent of a player it sees (PlayerRelay): the slot it knows them by, the
-- record's version then, and when (server seconds).
export type Seen = { slot: number, version: number, at: number }

-- A player edits are routed to: their chunk.
export type EditViewer = { key: any, cx: number, cz: number }

-- Does a player in `viewer` mode see one in `target` mode at all? (Player/SpectatorRules.sees.)
function Interest.seesMode(viewer: string, target: string): boolean
	return not GameMode.isSpectator(target) or GameMode.isSpectator(viewer)
end

-- Is `target` visible to `viewer` (see the header)? `wasVisible`: it was (the hysteresis).
function Interest.sees(viewer: Record, target: Record, wasVisible: boolean): boolean
	if viewer.key == target.key or not viewer.known or not target.known or viewer.gone or target.gone then
		return false
	elseif not Interest.seesMode(viewer.mode, target.mode) then
		return false
	elseif viewer.spectating ~= nil and viewer.spectating == target.key then
		return true
	end
	local settings = Config.Interest
	local limit = settings.PlayerDistance + (if wasVisible then settings.PlayerHysteresis else 0)
	local dx, dz = target.x - viewer.x, target.z - viewer.z
	return dx * dx + dz * dz <= limit * limit
end

--[[
	Brings `seen` (who `viewer` sees: key -> Seen) up to date with `records` at `now`: those no
	longer seen leave it, their slots appended to `untracks`; those now seen join it (as sent at
	`now`: the track carries their whole pose), their records appended to `tracks`. A player
	whose slot changed (left and came back) is untracked and tracked again.
]]
function Interest.update(
	records: { [any]: Record },
	viewer: Record,
	seen: { [any]: Seen },
	now: number,
	tracks: { Record },
	untracks: { number }
)
	for key, entry in seen do
		local target = records[key]
		if target == nil or target.slot ~= entry.slot or not Interest.sees(viewer, target, true) then
			seen[key] = nil
			table.insert(untracks, entry.slot)
		end
	end
	for key, target in records do
		if seen[key] == nil and Interest.sees(viewer, target, false) then
			seen[key] = { slot = target.slot, version = target.version, at = now }
			table.insert(tracks, target)
		end
	end
end

--[[
	The players in `seen` whose pose is due at `now` (changed since last sent, or sent
	Config.Interest.KeepAliveSeconds ago or more), written into out[1 .. n] and marked as sent.
	Returns n.
]]
function Interest.due(records: { [any]: Record }, seen: { [any]: Seen }, now: number, out: { Record }): number
	local keepAlive = Config.Interest.KeepAliveSeconds
	local n = 0
	for key, entry in seen do
		local target = records[key]
		if target and (target.version ~= entry.version or now - entry.at >= keepAlive) then
			entry.version, entry.at = target.version, now
			n += 1
			out[n] = target
		end
	end
	for i = n + 1, #out do
		out[i] = nil
	end
	return n
end

-- The chunk a block coordinate is in.
function Interest.chunkOf(blocks: number): number
	return math.floor(blocks / CHUNK)
end

--[[
	May the player of `record` (nil: none) have chunk (cx, cz)'s edit list now: do they have a
	position within `radius` (default Config.Interest.EditChunkRadius) chunks of it (Chebyshev)?
]]
function Interest.chunkAllowed(record: Record?, cx: number, cz: number, radius: number?): boolean
	if record == nil or not record.known then
		return false
	end
	local limit = radius or Config.Interest.EditChunkRadius
	return math.abs(Interest.chunkOf(record.x) - cx) <= limit and math.abs(Interest.chunkOf(record.z) - cz) <= limit
end

--[[
	The frame's edits (`pending`: x, y, z, block flat, World/WorldServer.takePending) by player:
	`true` for a player within `radius` (default Config.Interest.EditSendRadius) chunks of every
	edited chunk (they share one message), else the flat list of the edits near them (players
	near none are left out). `viewers` are the players with a position.
]]
function Interest.routeEdits(
	pending: { number },
	viewers: { EditViewer },
	radius: number?
): { [any]: { number } | boolean }
	local out: { [any]: { number } | boolean } = {}
	local n = #pending
	if n == 0 then
		return out
	end
	local limit = radius or Config.Interest.EditSendRadius
	-- (The edited chunks' bounds: most frames edit one chunk, and most players see all or none.)
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for i = 1, n, 4 do
		local cx, cz = pending[i] // CHUNK, pending[i + 2] // CHUNK
		minX, maxX = math.min(minX, cx), math.max(maxX, cx)
		minZ, maxZ = math.min(minZ, cz), math.max(maxZ, cz)
	end
	for _, viewer in viewers do
		local vx, vz = viewer.cx, viewer.cz
		if vx - limit <= minX and maxX <= vx + limit and vz - limit <= minZ and maxZ <= vz + limit then
			out[viewer.key] = true
		elseif vx + limit >= minX and vx - limit <= maxX and vz + limit >= minZ and vz - limit <= maxZ then
			local list: { number } = {}
			for i = 1, n, 4 do
				local x, z = pending[i], pending[i + 2]
				if math.abs(x // CHUNK - vx) <= limit and math.abs(z // CHUNK - vz) <= limit then
					table.insert(list, x)
					table.insert(list, pending[i + 1])
					table.insert(list, z)
					table.insert(list, pending[i + 3])
				end
			end
			if #list > 0 then
				out[viewer.key] = list
			end
		end
	end
	return out
end

--[[ Deferred chunk requests (one queue per player) ]]

export type Deferred = {
	limit: number,
	-- Chunk keys (Shared/World/Coords.chunkKey), oldest first, and the same as a set.
	order: { number },
	set: { [number]: boolean },
	-- Keeps chunk (cx, cz) for later (once); the oldest goes when `limit` are kept.
	add: (self: Deferred, cx: number, cz: number) -> (),
	-- The kept chunks `allowed` now accepts ({ cx, cz } each, oldest first), no longer kept.
	take: (self: Deferred, allowed: (cx: number, cz: number) -> boolean) -> { { number } },
	count: (self: Deferred) -> number,
}

local DeferredMethods = {}
DeferredMethods.__index = DeferredMethods

function DeferredMethods.add(self: Deferred, cx: number, cz: number)
	local key = Coords.chunkKey(cx, cz)
	if self.set[key] then
		return
	end
	while #self.order >= self.limit and #self.order > 0 do
		self.set[table.remove(self.order, 1) :: number] = nil
	end
	if self.limit > 0 then
		table.insert(self.order, key)
		self.set[key] = true
	end
end

function DeferredMethods.take(self: Deferred, allowed: (cx: number, cz: number) -> boolean): { { number } }
	local out: { { number } } = {}
	if #self.order == 0 then
		return out
	end
	local kept: { number } = {}
	for _, key in self.order do
		local cx, cz = Coords.decodeChunkKey(key)
		if allowed(cx, cz) then
			self.set[key] = nil
			table.insert(out, { cx, cz })
		else
			table.insert(kept, key)
		end
	end
	self.order = kept
	return out
end

function DeferredMethods.count(self: Deferred): number
	return #self.order
end

-- An empty queue keeping at most `limit` chunks (default Config.Interest.DeferredChunkRequests).
function Interest.newDeferred(limit: number?): Deferred
	return (
		setmetatable(
			{ limit = limit or Config.Interest.DeferredChunkRequests, order = {}, set = {} },
			DeferredMethods
		) :: any
	) :: Deferred
end

return Interest
