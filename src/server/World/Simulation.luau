--!strict
--[[
	Keeps the chunks around every player generated on the server (so block updates can run there and
	edit requests validate instantly) and evicts chunks nobody is near anymore. `activeChunks` lists
	the loaded ones within SimulationRadius of a player, where random ticks run (World/RandomTicker).

	  Where      every SCAN_INTERVAL (and at the next frame after a teleport) the players' feet
	             (Players/PlayerPositions: true world positions, whatever the characters replicate)
	             give their chunks to World/GenQueue: the near and kept windows, the queue (closest
	             first). Eviction (World/WorldServer.evict) then keeps the kept windows plus at most
	             Config.Server.CacheSize other chunks, least recently used dropped first.
	  Generating on a generator of its own (built once from the world's settings: the world's
	             generator stays with getChunk's callers, which generate inline), a slice of each
	             Heartbeat (GenQueue.budget): Config.Server.GenerationBudgetMs,
	             UrgentGenerationBudgetMs while a player's own chunk or one around it is missing
	             (just joined or teleported) or more than UrgentBacklog chunks wait (joins,
	             teleports, fast flyers); never past FrameBudgetMs of the frame's work so far
	             (measured from PreSimulation, the frame's first script step: physics and whatever
	             ran before, /locate's slice included: `start`'s `before`), but always
	             MinGenerationBudgetMs, so the backlog keeps moving. A slice overshoots by the
	             generator's longest stretch between two yields (~5 ms at most, see GenQueue).
	  /genstats  operators (WorldSettings.COMMAND_PERMITTED, so the chat suggests it to them only):
	             the background generation of the last 10 s (chunks/s, ms/s, the worst frame), the
	             backlog, and the chunks generated inline (getChunk: edits, spawns, map teleports,
	             structures) since the start; feedback as Notice messages.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Protocol = require(Shared.Net.Protocol)
local TerrainGenerator = require(Shared.Generation.TerrainGenerator)
local WorldSettings = require(Shared.WorldSettings)

local WorldServer = require(script.Parent.WorldServer)
local GenQueue = require(script.Parent.GenQueue)
local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local PlayerPositions = require(script.Parent.Parent.Players.PlayerPositions)
local Operators = require(script.Parent.Parent.Players.Operators)

local CHUNK = Config.ChunkSize
local SCAN_INTERVAL = 0.5
local ALIAS = "/genstats"
local DENIED = "Only operators can see the chunk generation stats"

local Simulation = {}

local queue: GenQueue.Queue? = nil

-- The loaded chunks within SimulationRadius of a player.
function Simulation.activeChunks(world: WorldServer.World): { WorldServer.Chunk }
	local chunks = {}
	if queue then
		for _, key in queue.active do
			local chunk = world.chunks[key]
			if chunk then
				table.insert(chunks, chunk)
			end
		end
	end
	return chunks
end

-- /genstats' lines (nil before the world).
function Simulation.describe(world: WorldServer.World): { string }?
	if queue == nil then
		return nil
	end
	local lines = queue:describe()
	table.insert(
		lines,
		string.format(
			"Generated inline (edits, spawns, teleports, structures): %d chunks, %.0f ms in all",
			world.inlineChunks,
			world.inlineMs
		)
	)
	return lines
end

-- /genstats from `player`'s chat (anything else is ignored).
local function command(net: ServerNet.ServerNet, world: WorldServer.World, player: Player, text: string)
	local word = string.match(text, "^%s*(%S+)")
	if word == nil or string.lower(word) ~= ALIAS or player.Parent == nil then
		return
	end
	local lines: { string } = if Operators.permitted(player) then Simulation.describe(world) or {} else { DENIED }
	for _, line in lines do
		net.send(player, Protocol.ServerMessage.Notice, Protocol.encodeNotice(line))
	end
end

--[[
	Starts preloading around players (once, with the world). `newGenerator` builds the background
	generator: the world's type, seed and options, as its own generator was built. `before` (nil:
	none) runs every Heartbeat just before the generation slice is sized, so its time counts in
	the frame's work (/locate's search slice: Players/LocateCommands.step); two Heartbeat
	handlers run in no set order, so a slice of its own could land after this one's and on top
	of FrameBudgetMs.
]]
function Simulation.start(
	world: WorldServer.World,
	net: ServerNet.ServerNet,
	newGenerator: () -> TerrainGenerator.Generator,
	before: (() -> ())?
)
	assert(queue == nil, "Simulation.start was already called")
	local cfg = Config.Server
	local background = newGenerator()
	local q = GenQueue.new({
		radius = cfg.SimulationRadius,
		generate = function(cx: number, cz: number, yield: () -> ()): (buffer, number)
			local result = background.generate(0, cx, cz, yield)
			return result.data, result.height
		end,
		install = function(cx: number, cz: number, data: buffer, height: number): boolean
			local _, fresh = world:install(cx, cz, data, height)
			return fresh
		end,
		loaded = function(cx: number, cz: number): boolean
			return world:peekChunk(cx, cz) ~= nil
		end,
		warn = function(message: string)
			warn(`[IceVoxel] {message}`)
		end,
	})
	queue = q

	local centers: { number } = {}
	local function keep(cx: number, cz: number): boolean
		return q:keeps(cx, cz)
	end
	local function scan()
		table.clear(centers)
		for _, x, _, z in PlayerPositions.each() do
			table.insert(centers, math.floor(x / CHUNK))
			table.insert(centers, math.floor(z / CHUNK))
		end
		q:update(centers)
		world:evict(keep, cfg.CacheSize)
	end

	local limits: GenQueue.Limits = {
		normal = cfg.GenerationBudgetMs,
		urgent = cfg.UrgentGenerationBudgetMs,
		backlog = cfg.UrgentBacklog,
		frame = cfg.FrameBudgetMs,
		least = cfg.MinGenerationBudgetMs,
	}
	local elapsed = SCAN_INTERVAL
	-- A teleport's destination is queued at the next frame, not the next scan.
	PlayerPositions.teleported:Connect(function()
		elapsed = SCAN_INTERVAL
	end)
	local frameStart = os.clock()
	RunService.PreSimulation:Connect(function()
		frameStart = os.clock()
	end)
	RunService.Heartbeat:Connect(function(dt: number)
		elapsed += dt
		if elapsed >= SCAN_INTERVAL then
			elapsed = 0
			scan()
		end
		if before then
			before()
		end
		q:step(q:budget(limits, (os.clock() - frameStart) * 1000) / 1000)
	end)

	if TextChatService.ChatVersion == Enum.ChatVersion.LegacyChatService then
		local function onPlayer(player: Player)
			player.Chatted:Connect(function(message: string)
				command(net, world, player, message)
			end)
		end
		Players.PlayerAdded:Connect(onPlayer)
		for _, player in Players:GetPlayers() do
			onPlayer(player)
		end
	else
		local instance = Instance.new("TextChatCommand")
		instance.Name = "IceVoxelGenStats"
		instance.PrimaryAlias = ALIAS
		-- (The operators' permission: the chat suggests it only to those who have it.)
		instance:SetAttribute(WorldSettings.COMMAND_ATTRIBUTE, WorldSettings.COMMAND_PERMITTED)
		instance.Triggered:Connect(function(source: TextSource, text: string)
			local player = Players:GetPlayerByUserId(source.UserId)
			if player then
				command(net, world, player, text)
			end
		end)
		-- Commands work when parented to TextChatService (replicated, so clients sink the message).
		instance.Parent = TextChatService
	end
end

return Simulation
