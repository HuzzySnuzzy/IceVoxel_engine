--!strict
--[[
	Structure blocks and jigsaw blocks in the game: connects the pure core (Structures/
	StructureServer, which does SAVE, LOAD, DETECT and Generate) to the network, the players, the
	world and ServerStorage.

	  Messages     StructureBlock, Jigsaw and StructureData (Net/Protocol; malformed ones never get
	               past the decoders), rate limited per player: cheap requests (open, update) at
	               REQUESTS_PER_SECOND, the heavy ones (save, load, detect, generate) at
	               HEAVY_PER_SECOND with a small burst, uploaded pieces at a little over
	               Config.Structures.DataPiecesPerSecond. A Use (right click) on these blocks
	               opens them too (Players/Inventories.onMenu).
	  Permission   Structures/Permission: creative (the instabuild ability, as Minecraft's
	               canUseGameMasterBlocks: never adventure or spectator), then
	               Config.Structures.Permission (by default nobody else), with the game's owner
	               (looked up once per player, as /gamemode does), Config.Gameplay.Admins and
	               Studio always allowed. `operator` is ServerNet's rule for placing and breaking
	               these blocks.
	  State        StructureStore follows every block change (`blockChanged`, chained onto
	               WorldServer.onChanged by the server script). A chunk's records go to a player
	               right after its edit list (`sendChunks`, ServerNet's `chunksSent`), and changed
	               ones once per frame (`update`) to every player within RECORD_RANGE blocks
	               sideways (all of them while they have no character yet), as the pipes' records.
	  Placing      LOADs and Generates are queued; `place` (every frame, before ServerNet's flush,
	               so their edits go out the same frame and before the records they make) sets
	               up to Config.Structures.LoadBlocksPerFrame blocks within PLACE_SECONDS and
	               generates at most CHUNKS_PER_FRAME chunks.
	  Saves        each SAVE's text is kept for the session by name, and in a StringValue (named
	               after the structure, at most 100 characters) in ServerStorage.
	               IceVoxelSavedStructures, which a Studio user can copy during a playtest and paste
	               into ReplicatedStorage.IceVoxelStructures to generate it. A save the session
	               drops (StructureServer.MAX_SAVED / MAX_SAVED_BYTES) loses its StringValue too.
	               The text goes to the player in StructureData pieces, at most
	               DataPiecesPerSecond.
	  Containers   generated structures' chests are filled from the generator's
	               `structureContainer` the first time they are needed (Players/Containers'
	               `generated`); LOAD and Generate fill their containers themselves.
	  Labels       structure blocks the generator placed with settings of their own (its
	               `labels`: the debug structures world's name tags, Generation/DebugWorlds) get
	               their records at the start, as if placed and set up, so WAILA names them and
	               F3 outlines their regions; breaking one forgets it like any other.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Library = require(Shared.Structures.Library)
local Machines = require(Shared.Machines)
local Protocol = require(Shared.Net.Protocol)
local Rig = require(Shared.Movement.Rig)
local Settings = require(Shared.Structures.Settings)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local Containers = require(script.Parent.Parent.Players.Containers)
local GameModes = require(script.Parent.Parent.Players.GameModes)
local Inventories = require(script.Parent.Parent.Players.Inventories)
local Permission = require(script.Parent.Permission)
local StructureServer = require(script.Parent.StructureServer)
local StructureStore = require(script.Parent.StructureStore)

-- Only what this uses of ServerNet.ServerNet.
type Net = {
	on: (kind: number, handler: (player: Player, payload: buffer) -> ()) -> (),
	send: (player: Player, kind: number, payload: buffer) -> (),
}

local BLOCK = Config.BlockSize
local ClientMessage = Protocol.ClientMessage
local ServerMessage = Protocol.ServerMessage

-- Requests per second per player (with a burst of the same), and the heavy ones (save, load,
-- detect, generate: each reads or plans up to 48 x 48 x 48 blocks, or a whole village).
local REQUESTS_PER_SECOND = 20
local HEAVY_PER_SECOND = 1
local HEAVY_BURST = 3
-- Uploaded pieces: a little more than clients send, a burst of two whole texts.
local PIECES_PER_SECOND = Config.Structures.DataPiecesPerSecond * 1.5
local PIECES_BURST = Protocol.MAX_STRUCTURE_PIECES * 2
-- Chunks placing may generate per frame (a structure reaching into unloaded terrain), and the
-- time it may take a frame on top of Config.Structures.LoadBlocksPerFrame (each block set runs
-- the world's change hooks and is replicated: a slow server places fewer a frame).
local CHUNKS_PER_FRAME = 2
local PLACE_SECONDS = 0.006
-- Blocks sideways around a player's feet whose records they get as they change.
local RECORD_RANGE = 192
-- Positions players may report (blocks); anything else is ignored.
local LIMIT = Protocol.MAX_COORDINATE + 64
-- Saved structures' folder in ServerStorage, and the longest Instance name.
local SAVED_FOLDER = "IceVoxelSavedStructures"
local MAX_INSTANCE_NAME = 100

local StructureBlocks = {}

-- The settings of every structure block and jigsaw (StructureStore).
StructureBlocks.store = StructureStore.new()

local core: StructureServer.Server? = nil
local net: Net? = nil
local started = false

-- Per player: owner of the game (looked up once), rate buckets, data pieces waiting to go out.
local owners: { [Player]: boolean } = {}
type Bucket = { tokens: number, last: number }
local buckets: { [Player]: { requests: Bucket, heavy: Bucket, pieces: Bucket } } = {}
type Outgoing = { pieces: { buffer }, tokens: number }
local outgoing: { [Player]: Outgoing } = {}
local transfers: { [Player]: number } = {}
local lastFeet: { [Player]: Vector3 } = {}
-- This session's StringValues by structure name.
local savedValues: { [string]: StringValue } = {}

local function take(bucket: Bucket, rate: number, burst: number, cost: number): boolean
	local now = os.clock()
	bucket.tokens = math.min(burst, bucket.tokens + (now - bucket.last) * rate)
	bucket.last = now
	if bucket.tokens < cost then
		return false
	end
	bucket.tokens -= cost
	return true
end

local function bucketsOf(player: Player): { requests: Bucket, heavy: Bucket, pieces: Bucket }
	local b = buckets[player]
	if b == nil then
		local now = os.clock()
		b = {
			requests = { tokens = REQUESTS_PER_SECOND, last = now },
			heavy = { tokens = HEAVY_BURST, last = now },
			pieces = { tokens = PIECES_BURST, last = now },
		}
		buckets[player] = b
	end
	return b
end

--[[
	May the player use structure blocks, structure voids and jigsaws now (Structures/Permission)?
	ServerNet's `operator` rule (placing and breaking them) and every request ask it.
]]
function StructureBlocks.operator(player: Player): boolean
	return Permission.allowed(
		player.UserId,
		Config.Structures.Permission,
		GameMode.instabuildOf(player),
		owners[player] == true,
		RunService:IsStudio(),
		Config.Gameplay.Admins
	)
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function feetOf(player: Player): Vector3?
	local character = player.Character
	local feet = if character then Rig.feet(character) else nil
	if feet and feet.X == feet.X and feet.Z == feet.Z and math.abs(feet.X) <= LIMIT and math.abs(feet.Z) <= LIMIT then
		lastFeet[player] = feet
		return feet
	end
	return lastFeet[player]
end

local function notify(player: Player, text: string)
	local sender = net
	if sender and player.Parent then
		sender.send(player, ServerMessage.Notice, Protocol.encodeNotice(text))
	end
end

local function sendStructureBlocks(player: Player, records: { Protocol.StructureBlockRecord }, open: boolean)
	local sender = net
	if sender and player.Parent and (#records > 0 or open) then
		sender.send(player, ServerMessage.StructureBlocks, Protocol.encodeStructureBlocks(records, open))
	end
end

local function sendJigsaws(player: Player, records: { Protocol.JigsawRecord }, open: boolean)
	local sender = net
	if sender and player.Parent and (#records > 0 or open) then
		sender.send(player, ServerMessage.Jigsaws, Protocol.encodeJigsaws(records, open))
	end
end

-- Queues a SAVE's text for the player, in pieces (sent by `update`).
local function sendData(player: Player, text: string)
	local transfer = (transfers[player] or 0) % 4294967295 + 1
	transfers[player] = transfer
	local queue = outgoing[player]
	if queue == nil then
		queue = { pieces = {}, tokens = Config.Structures.DataPiecesPerSecond }
		outgoing[player] = queue
	end
	for _, piece in Protocol.splitStructureData(transfer, text) do
		table.insert(queue.pieces, Protocol.encodeStructureData(piece))
	end
end

-- Keeps a SAVE's text in ServerStorage.IceVoxelSavedStructures (one StringValue per name).
local function stored(name: string, text: string)
	local ok, err = pcall(function()
		local folder = ServerStorage:FindFirstChild(SAVED_FOLDER)
		if folder == nil then
			local created = Instance.new("Folder")
			created.Name = SAVED_FOLDER
			created.Parent = ServerStorage
			folder = created
		end
		local value: StringValue? = savedValues[name]
		if value == nil or value.Parent ~= folder then
			local created = Instance.new("StringValue")
			created.Name = Settings.cut(name, MAX_INSTANCE_NAME)
			created.Parent = folder
			value = created
			savedValues[name] = created
		end
		(value :: StringValue).Value = text
	end)
	if not ok then
		warn(`[Structures] could not keep '{name}' in ServerStorage: {err}`)
	end
end

-- The session dropped a save (StructureServer's MAX_SAVED / MAX_SAVED_BYTES): so does the
-- folder, which would otherwise grow with every SAVE under a new name for the server's lifetime.
local function forget(name: string)
	local value = savedValues[name]
	savedValues[name] = nil
	if value then
		value:Destroy()
	end
end

local function inRange(player: any, x: number, y: number, z: number, range: number): boolean
	local root = rootOf(player :: Player)
	if root == nil then
		return false
	end
	local center = Vector3.new((x + 0.5) * BLOCK, (y + 0.5) * BLOCK, (z + 0.5) * BLOCK)
	return (root.Position - center).Magnitude <= range * BLOCK
end

local random = Random.new()

--[[
	ServerNet's `chunksSent` part: the player was just sent the edit lists of chunks `coords`, so
	send the structure blocks' and jigsaws' settings there.
]]
function StructureBlocks.sendChunks(player: Player, coords: { { number } })
	if not started then
		return
	end
	local structures: { Protocol.StructureBlockRecord } = {}
	local jigsaws: { Protocol.JigsawRecord } = {}
	for _, coord in coords do
		local s, j = StructureBlocks.store:chunkRecords(coord[1], coord[2])
		table.move(s, 1, #s, #structures + 1, structures)
		table.move(j, 1, #j, #jigsaws + 1, jigsaws)
	end
	sendStructureBlocks(player, structures, false)
	sendJigsaws(player, jigsaws, false)
end

-- For WorldServer.onChanged: structure blocks and jigsaws come, change mode or orientation, go.
function StructureBlocks.blockChanged(x: number, y: number, z: number, old: number, new: number)
	StructureBlocks.store:blockChanged(x, y, z, old, new)
end

--[[
	Places the frame's share of queued LOADs and Generates. The server script calls it every frame
	before ServerNet's flush, so their edits go out this frame, ahead of the records they make.
]]
function StructureBlocks.place()
	local server = core
	if server then
		server:place(Config.Structures.LoadBlocksPerFrame, CHUNKS_PER_FRAME, PLACE_SECONDS)
	end
end

-- Changed records to the players near them.
local function sendRecords(structures: { Protocol.StructureBlockRecord }, jigsaws: { Protocol.JigsawRecord })
	if #structures == 0 and #jigsaws == 0 then
		return
	end
	for _, player in Players:GetPlayers() do
		local feet = feetOf(player)
		if feet == nil then
			sendStructureBlocks(player, structures, false)
			sendJigsaws(player, jigsaws, false)
		else
			local function near<T>(records: { T }): { T }
				local list = {}
				for _, record in records do
					local r = record :: any
					-- (Rig.feet is in blocks.)
					if
						math.abs(r.x + 0.5 - feet.X) <= RECORD_RANGE
						and math.abs(r.z + 0.5 - feet.Z) <= RECORD_RANGE
					then
						table.insert(list, record)
					end
				end
				return list
			end
			sendStructureBlocks(player, near(structures), false)
			sendJigsaws(player, near(jigsaws), false)
		end
	end
end

--[[
	Every frame after ServerNet's flush: the changed records go to the players near them, and the
	saved structures' pieces to their players (DataPiecesPerSecond each).
]]
function StructureBlocks.update(dt: number)
	if not started then
		return
	end
	local structures, jigsaws = StructureBlocks.store:takeDirty()
	sendRecords(structures, jigsaws)
	local sender = net
	if sender == nil then
		return
	end
	local rate = Config.Structures.DataPiecesPerSecond
	for player, queue in outgoing do
		if player.Parent == nil then
			outgoing[player] = nil
			continue
		end
		queue.tokens = math.min(rate, queue.tokens + dt * rate)
		while queue.tokens >= 1 and #queue.pieces > 0 do
			queue.tokens -= 1
			sender.send(player, ServerMessage.StructureData, table.remove(queue.pieces, 1) :: buffer)
		end
		if #queue.pieces == 0 then
			outgoing[player] = nil
		end
	end
end

local HEAVY: { [string]: boolean } = { save = true, load = true, detect = true, generate = true }

--[[
	Starts structure blocks and jigsaws. Players/Inventories must have started (containers, the
	Use hook); the server script chains `blockChanged` onto WorldServer.onChanged and calls `place`
	and `update` every frame.
]]
function StructureBlocks.start(serverNet: Net, world: WorldServer.World)
	assert(not started, "StructureBlocks.start was already called")
	started = true
	net = serverNet

	local server = StructureServer.new({
		world = world,
		store = StructureBlocks.store,
		containers = Containers.default,
		library = function(): Library.Library
			return Library.load()
		end,
		notify = notify,
		sendStructureBlocks = sendStructureBlocks,
		sendJigsaws = sendJigsaws,
		sendData = sendData,
		stored = stored,
		forget = forget,
		containerChanged = Inventories.containerChanged,
		seed = function(): number
			return random:NextInteger(1, 2_147_483_646)
		end,
		inRange = inRange,
	})
	core = server

	-- Generated structure blocks with settings (name tags): their records, as if placed.
	local generator = world.generator
	local labels = (generator :: any).labels
	if type(labels) == "function" then
		local store = StructureBlocks.store
		local save = Blocks.structureBlock("save") :: number
		for _, label in labels() do
			store:blockChanged(label.x, label.y, label.z, Blocks.AIR, save)
			local settings = Settings.defaultStructure("save")
			settings.name = label.name
			settings.offset = table.clone(label.offset)
			settings.size = table.clone(label.size)
			store:setStructure(label.x, label.y, label.z, settings)
		end
	end

	-- Generated structures' chests: what the generator put there, the first time it is needed.
	local lookup = (generator :: any).structureContainer
	if type(lookup) == "function" then
		Containers.default.generated = {
			blockAt = function(x: number, y: number, z: number): number?
				return world:peekBlock(x, y, z)
			end,
			contents = function(x: number, y: number, z: number, block: number)
				local items = lookup(x, y, z)
				if items == nil then
					return nil
				end
				return StructureServer.slotsFromItems(items, Machines.containerSize(block))
			end,
		}
	end

	serverNet.on(ClientMessage.StructureBlock, function(player: Player, payload: buffer)
		local request = Protocol.decodeStructureBlock(payload)
		if request == nil then
			return
		end
		local b = bucketsOf(player)
		if not take(b.requests, REQUESTS_PER_SECOND, REQUESTS_PER_SECOND, 1) then
			return
		end
		if HEAVY[request.op] and not take(b.heavy, HEAVY_PER_SECOND, HEAVY_BURST, 1) then
			notify(player, "Too many structure requests: wait a moment")
			return
		end
		server:structureBlock(player, request, StructureBlocks.operator(player))
	end)
	serverNet.on(ClientMessage.Jigsaw, function(player: Player, payload: buffer)
		local request = Protocol.decodeJigsaw(payload)
		if request == nil then
			return
		end
		local b = bucketsOf(player)
		if not take(b.requests, REQUESTS_PER_SECOND, REQUESTS_PER_SECOND, 1) then
			return
		end
		if HEAVY[request.op] and not take(b.heavy, HEAVY_PER_SECOND, HEAVY_BURST, 1) then
			notify(player, "Too many structure requests: wait a moment")
			return
		end
		server:jigsaw(player, request, StructureBlocks.operator(player))
	end)
	serverNet.on(ClientMessage.StructureData, function(player: Player, payload: buffer)
		local piece = Protocol.decodeStructureData(payload)
		if piece == nil or not take(bucketsOf(player).pieces, PIECES_PER_SECOND, PIECES_BURST, 1) then
			return
		end
		server:data(player, piece, StructureBlocks.operator(player))
	end)
	local function onMenu(player: Player, x: number, y: number, z: number, _block: number)
		if take(bucketsOf(player).requests, REQUESTS_PER_SECOND, REQUESTS_PER_SECOND, 1) then
			server:use(player, x, y, z, StructureBlocks.operator(player))
		end
	end
	Inventories.onMenu("StructureBlock", onMenu)
	Inventories.onMenu("Jigsaw", onMenu)

	local function onPlayer(player: Player)
		-- (May yield: a group game's owner is a web call.)
		local owner = GameModes.isOwner(player)
		if player.Parent then
			owners[player] = owner
		end
	end
	Players.PlayerAdded:Connect(function(player)
		task.spawn(onPlayer, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayer, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		owners[player] = nil
		buckets[player] = nil
		outgoing[player] = nil
		transfers[player] = nil
		lastFeet[player] = nil
		server:leave(player)
	end)
end

-- Unused by the game, for tools: the core (nil before `start`).
function StructureBlocks.core(): StructureServer.Server?
	return core
end

return StructureBlocks
