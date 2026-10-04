--!strict
--[[
	Server side of the protocol (see Shared/Net/Protocol).

	  * Answers chunk edit requests (clients ask for the edit list of every full detail chunk they
	    build; terrain itself is generated locally).
	  * Validates block edit requests: rate limit, reach, breakable / placeable, not inside a player.
	    Rejected requests are answered with the real block so the client undoes its prediction.
	  * Broadcasts all world changes once per frame.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Blocks = require(Shared.Blocks)
local Protocol = require(Shared.Net.Protocol)
local Remotes = require(Shared.Net.Remotes)

local WorldServer = require(script.Parent.Parent.World.WorldServer)

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

-- Does block (x, y, z) overlap any character? Uses a box around the root part.
local function intersectsCharacter(x: number, y: number, z: number): boolean
	local minX, minY, minZ = x * BLOCK, y * BLOCK, z * BLOCK
	local maxX, maxY, maxZ = minX + BLOCK, minY + BLOCK, minZ + BLOCK
	for _, player in Players:GetPlayers() do
		local root = rootOf(player)
		if root then
			local p = root.Position
			if
				p.X + 0.9 > minX
				and p.X - 0.9 < maxX
				and p.Z + 0.9 > minZ
				and p.Z - 0.9 < maxZ
				and p.Y + 2.2 > minY
				and p.Y - 2.9 < maxY
			then
				return true
			end
		end
	end
	return false
end

export type Handler = (player: Player, payload: buffer) -> ()

export type ServerNet = {
	-- Broadcasts the world changes made since the last call (once per frame).
	flush: () -> (),
	-- Registers the handler for a client message type (Protocol.ClientMessage).
	on: (kind: number, handler: Handler) -> (),
	-- Sends a message to one player.
	send: (player: Player, kind: number, payload: buffer) -> (),
}

local ServerNet = {}

function ServerNet.start(world: World): ServerNet
	local remote = Remotes.net()
	local editBuckets: { [Player]: Bucket } = {}
	local chunkBuckets: { [Player]: Bucket } = {}

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

	local function handleEdit(player: Player, payload: buffer)
		local action, x, y, z, block = Protocol.decodeEdit(payload)
		if
			action == nil
			or y >= HEIGHT
			or math.abs(x) > Protocol.MAX_COORDINATE
			or math.abs(z) > Protocol.MAX_COORDINATE
		then
			return
		end
		local rate = Config.Server.EditsPerSecond
		if not take(bucket(editBuckets, player, rate), rate, 1) then
			sendBlock(player, x, y, z)
			return
		end

		local root = rootOf(player)
		local reach = (Config.Interaction.Reach + 2) * BLOCK
		local center = Vector3.new((x + 0.5) * BLOCK, (y + 0.5) * BLOCK, (z + 0.5) * BLOCK)
		if root == nil or (root.Position - center).Magnitude > reach then
			sendBlock(player, x, y, z)
			return
		end

		local current = world:getBlock(x, y, z)
		if action == EditAction.Break then
			if not Blocks.get(current).breakable then
				sendBlock(player, x, y, z)
				return
			end
			world:setBlock(x, y, z, Blocks.AIR)
		elseif action == EditAction.Place then
			local valid = Blocks.isValid(block) and Blocks.get(block).placeable and Blocks.isReplaceable(current)
			if not valid or (Blocks.isSolid(block) and intersectsCharacter(x, y, z)) then
				sendBlock(player, x, y, z)
				return
			end
			world:setBlock(x, y, z, block)
		end
	end

	local handlers: { [number]: Handler } = {
		[ClientMessage.RequestChunks] = handleChunkRequest,
		[ClientMessage.Edit] = handleEdit,
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
	}
end

return ServerNet
