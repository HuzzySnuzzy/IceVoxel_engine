--!strict
--[[
	Server side of the protocol (see Shared/Net/Protocol).

	  * Answers chunk edit requests (clients ask for the edit list of every full detail chunk they
	    build; terrain itself is generated locally).
	  * Validates block edit requests: rate limit, reach, breakable / placeable, not inside a player.
	    Rejected requests are answered with the real block so the client undoes its prediction.
	  * Applies the game modes' rules to edits (Network/EditRules):
	      survival  a block breaks only once the player has mined it long enough (Mine messages
	                say when they started; Mining.mayBreak) and drops its item; placing uses up
	                the held item (Players/Inventories.place, just before the block is set). A
	                refused placement is still acknowledged, so the client's predicted use is
	                undone.
	      creative  instant breaking, no drops, nothing used up.
	    A broken container drops its contents in both modes.
	  * Broadcasts all world changes once per frame.

	The inventory and item entity sides come in through `setRules` (the server script wires
	Players/Inventories and Entities), so ServerNet requires neither of them.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Blocks = require(Shared.Blocks)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Protocol = require(Shared.Net.Protocol)
local Remotes = require(Shared.Net.Remotes)
local Rig = require(Shared.Movement.Rig)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local EditRules = require(script.Parent.EditRules)

type World = WorldServer.World

local BLOCK = Config.BlockSize
local HEIGHT = Config.WorldHeight
local EDITS_PER_MESSAGE = 4096
local CHUNK_REQUESTS_PER_SECOND = 1500

local ClientMessage = Protocol.ClientMessage
local ServerMessage = Protocol.ServerMessage
local EditAction = Protocol.EditAction

local EMPTY: { [number]: number } = {}

-- Token bucket per player and kind of request.
type Bucket = { tokens: number, last: number }

local function take(bucket: Bucket, rate: number, cost: number): boolean
	local now = os.clock()
	bucket.tokens = math.min(rate * 2, bucket.tokens + (now - bucket.last) * rate)
	bucket.last = now
	if bucket.tokens < cost then
		return false
	end
	bucket.tokens -= cost
	return true
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- Does block (x, y, z) overlap any player's (standing) movement hull?
local function intersectsCharacter(x: number, y: number, z: number): boolean
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			local min, max = Rig.hull(character)
			if
				min
				and max
				and max.X > x
				and min.X < x + 1
				and max.Z > z
				and min.Z < z + 1
				and max.Y > y
				and min.Y < y + 1
			then
				return true
			end
		end
	end
	return false
end

export type Handler = (player: Player, payload: buffer) -> ()

-- The game's side of block edits. All optional: without them edits change no inventory and drop
-- nothing.
export type Rules = {
	-- A placement passed every block check: use up the held item (survival) and acknowledge
	-- inventory action `seq`. false refuses the edit. (Players/Inventories.place)
	place: ((player: Player, block: number, seq: number) -> boolean)?,
	-- A refused placement: acknowledge `seq` so the client undoes its predicted use.
	-- (Players/Inventories.acknowledge)
	acknowledge: ((player: Player, seq: number) -> ())?,
	-- Drops a survival player's broken block as an item entity. (Entities.dropBlock)
	dropBlock: ((x: number, y: number, z: number, stack: Items.Stack) -> ())?,
	-- A container block was broken: drop its contents and close it for its viewers.
	-- (Players/Inventories.removeContainer)
	removeContainer: ((x: number, y: number, z: number) -> ())?,
}

export type ServerNet = {
	-- Broadcasts the world changes made since the last call (once per frame).
	flush: () -> (),
	-- Registers the handler for a client message type (Protocol.ClientMessage).
	on: (kind: number, handler: Handler) -> (),
	-- Sends a message to one player.
	send: (player: Player, kind: number, payload: buffer) -> (),
	-- Sets the inventory / item entity side of edits (replaces the earlier rules).
	setRules: (rules: Rules) -> (),
}

local ServerNet = {}

function ServerNet.start(world: World): ServerNet
	local remote = Remotes.net()
	local editBuckets: { [Player]: Bucket } = {}
	local chunkBuckets: { [Player]: Bucket } = {}
	-- The block each survival player is mining (Mine messages).
	local mining: { [Player]: EditRules.Mine } = {}
	local rules: Rules = {}

	local function bucket(map: { [Player]: Bucket }, player: Player, initial: number): Bucket
		local b = map[player]
		if b == nil then
			b = { tokens = initial, last = os.clock() }
			map[player] = b
		end
		return b
	end

	-- Tells a player the real block after rejecting their edit. Never generates chunks: a client
	-- could otherwise make the server generate terrain anywhere by sending bogus edits.
	local function sendBlock(player: Player, x: number, y: number, z: number)
		local block = world:peekBlock(x, y, z)
		if block ~= nil then
			remote:FireClient(player, ServerMessage.Edits, Protocol.encodeEdits({ x, y, z, block }))
		end
	end

	local function handleChunkRequest(player: Player, payload: buffer)
		local coords = Protocol.decodeChunkRequest(payload)
		if coords == nil then
			return
		end
		if not take(bucket(chunkBuckets, player, CHUNK_REQUESTS_PER_SECOND), CHUNK_REQUESTS_PER_SECOND, #coords) then
			return
		end
		local lists: { Protocol.ChunkEditList } = table.create(#coords)
		for i, coord in coords do
			lists[i] = { cx = coord[1], cz = coord[2], edits = world:chunkEdits(coord[1], coord[2]) or EMPTY }
		end
		remote:FireClient(player, ServerMessage.ChunkEdits, Protocol.encodeChunkEdits(lists))
	end

	-- Mine messages: a survival player started (or stopped) mining a block.
	local function handleMine(player: Player, payload: buffer)
		local started, x, y, z = Protocol.decodeMine(payload)
		if started == nil then
			return
		end
		local mine = mining[player]
		if started then
			if mine == nil then
				mining[player] = { x = x, y = y, z = z, startedAt = os.clock() }
			else
				mine.x, mine.y, mine.z, mine.startedAt = x, y, z, os.clock()
			end
		elseif mine and mine.x == x and mine.y == y and mine.z == z then
			mining[player] = nil
		end
	end

	local function handleEdit(player: Player, payload: buffer)
		local action, x, y, z, block, seq = Protocol.decodeEdit(payload)
		if
			action == nil
			or y >= HEIGHT
			or math.abs(x) > Protocol.MAX_COORDINATE
			or math.abs(z) > Protocol.MAX_COORDINATE
		then
			return
		end

		-- Undoes the client's prediction: the real block and, for a placement, the inventory as it
		-- is (the snapshot acknowledging `seq` brings the predicted used up item back).
		local function reject()
			sendBlock(player, x, y, z)
			local acknowledge = rules.acknowledge
			if action == EditAction.Place and seq > 0 and acknowledge then
				acknowledge(player, seq)
			end
		end

		local rate = Config.Server.EditsPerSecond
		if not take(bucket(editBuckets, player, rate), rate, 1) then
			reject()
			return
		end

		local root = rootOf(player)
		local reach = (Config.Interaction.Reach + 2) * BLOCK
		local center = Vector3.new((x + 0.5) * BLOCK, (y + 0.5) * BLOCK, (z + 0.5) * BLOCK)
		if root == nil or (root.Position - center).Magnitude > reach then
			reject()
			return
		end

		local creative = GameMode.isCreative(player)
		local current = world:getBlock(x, y, z)
		if action == EditAction.Break then
			if not EditRules.mayBreak(current, creative, mining[player], x, y, z, os.clock()) then
				reject()
				return
			end
			mining[player] = nil
			if not world:setBlock(x, y, z, Blocks.AIR) then
				return
			end
			local removeContainer = rules.removeContainer
			if removeContainer and EditRules.isContainer(current) then
				removeContainer(x, y, z)
			end
			local drop = EditRules.drops(current, creative)
			local dropBlock = rules.dropBlock
			if drop and dropBlock then
				dropBlock(x, y, z, drop)
			end
		elseif action == EditAction.Place then
			if not EditRules.mayPlace(block, current) or (Blocks.isSolid(block) and intersectsCharacter(x, y, z)) then
				reject()
				return
			end
			-- Last, as it uses up the item: nothing may refuse the edit after it.
			local place = rules.place
			if place and not place(player, block, seq) then
				reject()
				return
			end
			world:setBlock(x, y, z, block)
		else
			reject()
		end
	end

	local handlers: { [number]: Handler } = {
		[ClientMessage.RequestChunks] = handleChunkRequest,
		[ClientMessage.Edit] = handleEdit,
		[ClientMessage.Mine] = handleMine,
	}

	remote.OnServerEvent:Connect(function(player: Player, kind: unknown, payload: unknown)
		if typeof(kind) ~= "number" or typeof(payload) ~= "buffer" then
			return
		end
		local handler = handlers[kind]
		if handler then
			handler(player, payload)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		editBuckets[player] = nil
		chunkBuckets[player] = nil
		mining[player] = nil
	end)

	local function flush()
		local pending = world:takePending()
		local n = #pending
		local step = EDITS_PER_MESSAGE * 4
		for first = 1, n, step do
			remote:FireAllClients(
				ServerMessage.Edits,
				Protocol.encodeEdits(pending, first, math.min(first + step - 1, n))
			)
		end
	end

	return {
		flush = flush,
		on = function(kind: number, handler: Handler)
			assert(handlers[kind] == nil, `A handler for message {kind} already exists`)
			handlers[kind] = handler
		end,
		send = function(player: Player, kind: number, payload: buffer)
			remote:FireClient(player, kind, payload)
		end,
		setRules = function(newRules: Rules)
			rules = newRules
		end,
	}
end

return ServerNet
