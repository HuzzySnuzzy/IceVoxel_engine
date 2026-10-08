--!strict
--[[
	The server's own record of where every player is (Config.Players.ServerPositions): pure, keyed
	by anything (Players in the game, strings in the tests), driven by Players/PlayerPositions
	(the glue: characters, the Moves remote, the Teleport message) and read by Players/PlayerRelay
	(who sees whom). Positions are feet in world blocks, Luau doubles; nothing here is a Vector3.

	Record per player:
	  x, y, z, known    the feet, and whether there is a position at all (none before the first
	                    teleport of a character, nor once it is gone): always the last ACCEPTED
	                    place, so a correction sends the player back there.
	  yaw .. climb      the pose of the last move (Net/PlayerSync's tail: yaw as
	                    CFrame.Angles(0, yaw, 0), look pitch, tilt, flags, speed, climb), except
	                    the flags' Dead bit, which is the server's (`setAlive`: the Humanoid).
	  slot              a u16 the relay names the player by, given at `add` in increasing order
	                    (wrapping after 65,536 joins), never one in use.
	  life              the character counter (u16): +1 for each new character (`spawned`), sent
	                    in every Teleport and set on the character (the IceVoxelLife attribute), so
	                    the client knows which Teleport placed its new character.
	  epoch             the teleport counter (u16): +1 for each teleport; moves carrying another
	                    epoch are from before it and are dropped, until the client has snapped and
	                    sends the new one (Minecraft's awaitingPositionFromClient).
	  lastSeq           the newest move's u16 sequence number (wrap-aware, PlayerSync.newer):
	                    older and repeated moves are dropped (the Moves remote is unordered).
	  spectating        whom the player spectates (Spectate messages, spectators only): their
	                    position follows that player's (`follow`, every relay tick, chains
	                    resolved, as Minecraft's camera entity) and their own moves are ignored.
	  check             Players/MoveCheck's buckets.
	  version           +1 at every change of position or pose: what the relay compares to send
	                    only what changed.
	  gone              the player is leaving the game (`leaving`): nobody sees them any more,
	                    but their position stays readable (their save) until `remove`.

	A move (`move`) is taken when it decodes (PlayerSync), the player has a position, its epoch is
	the record's, its seq is newer, the player spectates nobody and MoveCheck allows it. When
	MoveCheck refuses, `policy` (Config.Players.MoveCheck) decides:
	  "correct"  the player goes back to the last accepted place: a Teleport (reason correction)
	             with a new epoch, so the moves already on their way are dropped, at most one
	             every CORRECTION_INTERVAL seconds (until then refused moves are just dropped);
	  "log"      the move is taken and the result says to warn (at most every WARN_INTERVAL s);
	  "off"      the move is taken.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local PlayerSync = require(Shared.Net.PlayerSync)

local MoveCheck = require(script.Parent.MoveCheck)

local PositionStore = {}

-- Seconds between two corrections of one player, and between two "log" warnings.
PositionStore.CORRECTION_INTERVAL = 0.5
PositionStore.WARN_INTERVAL = 10
-- Spectators following spectators: links followed at most (a cycle keeps its places).
local MAX_CHAIN = 8

export type Record = {
	key: any,
	slot: number,
	x: number,
	y: number,
	z: number,
	known: boolean,
	yaw: number,
	pitch: number,
	tilt: number,
	flags: number,
	speed: number,
	climb: number,
	mode: string,
	alive: boolean,
	life: number,
	epoch: number,
	lastSeq: number?,
	spectating: any?,
	-- The next teleport places a new character (reason spawn).
	spawning: boolean,
	check: MoveCheck.Bucket,
	version: number,
	gone: boolean,
	correctedAt: number,
	warnedAt: number,
}

--[[
	What became of a move:
	  accepted    taken (the record moved)
	  logged      taken, over the limits under "log": warn
	  corrected   refused under "correct": send the Teleport returned
	  refused     refused, no correction now (one was sent less than CORRECTION_INTERVAL ago),
	              or under "correct" with nothing to go back to
	  stale       from before the latest teleport (another epoch)
	  old         not newer than the last one taken
	  spectating  the player spectates someone: their place follows the target
	  unknown     no such player, or they have no position yet
	  invalid     out of bounds
]]
export type MoveResult =
	"accepted"
	| "logged"
	| "corrected"
	| "refused"
	| "stale"
	| "old"
	| "spectating"
	| "unknown"
	| "invalid"

export type Policy = "correct" | "log" | "off"

export type Store = {
	records: { [any]: Record },
	nextSlot: number,
	-- Slots in use (u16 -> key).
	slots: { [number]: any },

	add: (self: Store, key: any, mode: string, now: number) -> Record,
	remove: (self: Store, key: any) -> (),
	get: (self: Store, key: any) -> Record?,
	spawned: (self: Store, key: any) -> number,
	left: (self: Store, key: any) -> (),
	leaving: (self: Store, key: any) -> (),
	teleport: (
		self: Store,
		key: any,
		x: number,
		y: number,
		z: number,
		yaw: number?,
		now: number
	) -> PlayerSync.Teleport?,
	move: (
		self: Store,
		key: any,
		move: PlayerSync.Move,
		now: number,
		policy: Policy?
	) -> (MoveResult, PlayerSync.Teleport?),
	setMode: (self: Store, key: any, mode: string, now: number) -> (),
	setAlive: (self: Store, key: any, alive: boolean) -> (),
	grant: (self: Store, key: any, blocks: number, now: number) -> (),
	spectate: (self: Store, key: any, target: any?, now: number) -> boolean,
	follow: (self: Store) -> (),
}

local Store = {}
Store.__index = Store

function Store.get(self: Store, key: any): Record?
	return self.records[key]
end

-- A new player (in `mode`, with no position yet). Adding one already there gives their record.
function Store.add(self: Store, key: any, mode: string, now: number): Record
	local existing = self.records[key]
	if existing then
		return existing
	end
	local slot = self.nextSlot
	while self.slots[slot] ~= nil do
		slot = PlayerSync.nextU16(slot)
	end
	self.nextSlot = PlayerSync.nextU16(slot)
	self.slots[slot] = key
	local record: Record = {
		key = key,
		slot = slot,
		x = 0,
		y = 0,
		z = 0,
		known = false,
		yaw = 0,
		pitch = 0,
		tilt = 0,
		flags = 0,
		speed = 0,
		climb = 0,
		mode = mode,
		alive = true,
		life = 0,
		epoch = 0,
		lastSeq = nil,
		spectating = nil,
		spawning = false,
		check = MoveCheck.new(mode, now),
		version = 0,
		gone = false,
		correctedAt = -math.huge,
		warnedAt = -math.huge,
	}
	self.records[key] = record
	return record
end

-- The player left: their record and slot go, and nobody spectates them any more.
function Store.remove(self: Store, key: any)
	local record = self.records[key]
	if record == nil then
		return
	end
	self.records[key] = nil
	if self.slots[record.slot] == key then
		self.slots[record.slot] = nil
	end
	for _, other in self.records do
		if other.spectating == key then
			other.spectating = nil
		end
	end
end

--[[
	The player has a new character: life + 1 (returned, for its IceVoxelLife attribute), no
	position until its first teleport (which is the spawn's), spectating nobody.
]]
function Store.spawned(self: Store, key: any): number
	local record = self.records[key]
	if record == nil then
		return 0
	end
	record.life = PlayerSync.nextU16(record.life)
	record.known = false
	record.spawning = true
	record.spectating = nil
	record.alive = true
	record.flags = 0
	record.version += 1
	return record.life
end

-- The player's character is gone (no position until the next one is placed).
function Store.left(self: Store, key: any)
	local record = self.records[key]
	if record == nil then
		return
	end
	record.known = false
	record.spectating = nil
	record.version += 1
end

-- The player is leaving the game: nobody sees or spectates them, their place stays until `remove`.
function Store.leaving(self: Store, key: any)
	local record = self.records[key]
	if record == nil then
		return
	end
	record.gone = true
	record.spectating = nil
	record.version += 1
	for _, other in self.records do
		if other.spectating == key then
			other.spectating = nil
		end
	end
end

--[[
	The server puts the player's feet at (x, y, z) (blocks), facing `yaw` when given: a new epoch,
	full MoveCheck buckets, spectating nobody (Minecraft's teleport ends it too). Returns the
	Teleport message for the player alone (reason spawn for a new character's first, else
	teleport), or nil for an unknown player or a place out of bounds.
]]
function Store.teleport(
	self: Store,
	key: any,
	x: number,
	y: number,
	z: number,
	yaw: number?,
	now: number
): PlayerSync.Teleport?
	local record = self.records[key]
	if record == nil or not MoveCheck.inBounds(x, y, z) then
		return nil
	end
	local reason = if record.spawning then PlayerSync.TeleportReason.Spawn else PlayerSync.TeleportReason.Teleport
	record.spawning = false
	record.x, record.y, record.z = x, y, z
	record.known = true
	if yaw and yaw == yaw and yaw ~= math.huge and yaw ~= -math.huge then
		record.yaw = yaw
	else
		yaw = nil
	end
	record.epoch = PlayerSync.nextU16(record.epoch)
	record.lastSeq = nil
	record.spectating = nil
	record.version += 1
	MoveCheck.reset(record.check, now)
	return { epoch = record.epoch, life = record.life, x = x, y = y, z = z, yaw = yaw, reason = reason }
end

local DEAD = PlayerSync.Flag.Dead

-- Takes move `move` into the record (position and pose; the Dead flag stays the server's).
local function take(record: Record, move: PlayerSync.Move)
	record.x, record.y, record.z = move.x, move.y, move.z
	record.yaw, record.pitch, record.tilt = move.yaw, move.pitch, move.tilt
	record.flags = bit32.bor(bit32.band(move.flags, bit32.bnot(DEAD)), if record.alive then 0 else DEAD)
	record.speed, record.climb = move.speed, move.climb
	record.lastSeq = move.seq
	record.version += 1
end

-- A client's Move (see the header). The Teleport returned (a correction) goes to the player.
function Store.move(
	self: Store,
	key: any,
	move: PlayerSync.Move,
	now: number,
	policy: Policy?
): (MoveResult, PlayerSync.Teleport?)
	local record = self.records[key]
	if record == nil or not record.known then
		return "unknown", nil
	elseif move.epoch ~= record.epoch then
		return "stale", nil
	end
	local last = record.lastSeq
	if last ~= nil and not PlayerSync.newer(move.seq, last) then
		return "old", nil
	elseif record.spectating ~= nil then
		return "spectating", nil
	elseif not MoveCheck.inBounds(move.x, move.y, move.z) then
		return "invalid", nil
	end
	local rule: Policy = policy or (Config.Players.MoveCheck :: Policy)
	if rule == "off" or MoveCheck.check(record.check, move.x - record.x, move.y - record.y, move.z - record.z, now) then
		take(record, move)
		return "accepted", nil
	elseif rule == "log" then
		take(record, move)
		if now - record.warnedAt >= PositionStore.WARN_INTERVAL then
			record.warnedAt = now
			return "logged", nil
		end
		return "accepted", nil
	end
	-- "correct": back to the last accepted place (its own epoch drops what is on its way).
	if now - record.correctedAt < PositionStore.CORRECTION_INTERVAL then
		return "refused", nil
	end
	record.correctedAt = now
	local correction = self:teleport(key, record.x, record.y, record.z, nil, now)
	if correction == nil then
		return "refused", nil
	end
	correction.reason = PlayerSync.TeleportReason.Correction
	return "corrected", correction
end

-- The player's game mode is now `mode` (MoveCheck's grace; leaving spectator ends spectating).
function Store.setMode(self: Store, key: any, mode: string, now: number)
	local record = self.records[key]
	if record == nil or record.mode == mode then
		return
	end
	record.mode = mode
	MoveCheck.setMode(record.check, mode, now)
	if not GameMode.isSpectator(mode) and record.spectating ~= nil then
		record.spectating = nil
		MoveCheck.reset(record.check, now)
	end
	record.version += 1
end

-- Whether the player's character lives (the flags' Dead bit: clients play the death tilt).
function Store.setAlive(self: Store, key: any, alive: boolean)
	local record = self.records[key]
	if record == nil or record.alive == alive then
		return
	end
	record.alive = alive
	record.flags = bit32.bor(bit32.band(record.flags, bit32.bnot(DEAD)), if alive then 0 else DEAD)
	record.version += 1
end

-- Knockback the server gave the player (`blocks` of movement beyond the limits).
function Store.grant(self: Store, key: any, blocks: number, now: number)
	local record = self.records[key]
	if record then
		MoveCheck.grant(record.check, blocks, now)
	end
end

--[[
	The player spectates `target` (a key; nil: nobody). Spectating needs spectator mode, another
	player with a position and no loop back to the spectator; their place jumps to the target's
	at once. false when refused (the player then spectates nobody).
]]
function Store.spectate(self: Store, key: any, target: any?, now: number): boolean
	local record = self.records[key]
	if record == nil then
		return false
	end
	local wanted = if target ~= nil then self.records[target] else nil
	local allowed = wanted ~= nil and target ~= key and wanted.known and GameMode.isSpectator(record.mode)
	if allowed and wanted then
		-- (No loop: the target doesn't spectate, through others, the spectator.)
		local link: Record? = wanted
		for _ = 1, MAX_CHAIN do
			if link == nil then
				break
			elseif link.spectating == key then
				allowed = false
				break
			end
			link = if link.spectating ~= nil then self.records[link.spectating] else nil
		end
	end
	local was = record.spectating
	record.spectating = if allowed then target else nil
	if record.spectating ~= was then
		-- (The client's hull leaves from wherever it followed the target.)
		MoveCheck.reset(record.check, now)
	end
	if allowed then
		self:follow()
	end
	return allowed
end

--[[
	Every spectator's place becomes their target's (through chains of spectators, at most
	MAX_CHAIN links; a target without a position leaves theirs as it was). Once every relay tick.
]]
function Store.follow(self: Store)
	local records = self.records
	for _, record in records do
		local target = record.spectating
		if target == nil then
			continue
		end
		local root = records[target]
		for _ = 1, MAX_CHAIN do
			if root == nil or root.spectating == nil then
				break
			end
			root = records[root.spectating]
		end
		if root and root ~= record and root.known and root.spectating == nil then
			if record.x ~= root.x or record.y ~= root.y or record.z ~= root.z or not record.known then
				record.x, record.y, record.z = root.x, root.y, root.z
				record.known = true
				record.version += 1
			end
		end
	end
end

function PositionStore.new(): Store
	return (setmetatable({ records = {}, nextSlot = 0, slots = {} }, Store) :: any) :: Store
end

return PositionStore
