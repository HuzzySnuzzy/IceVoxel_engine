--!strict
--[[
	The /locate chat command (parsed, searched and answered by Players/LocateCommand) on the
	server: who may, the searches' queue, the answers.

	  Command   a TextChatCommand made here (the message is shown to no one; Triggered fires on
	            the server with the sender's TextSource), or Player.Chatted with the legacy chat.
	            It carries the operators' permission (WorldSettings.COMMAND_PERMITTED: the chat
	            suggests it to those who may) and its arguments
	            (WorldSettings.COMMAND_ARGUMENTS_ATTRIBUTE: the three kinds, then every id and tag
	            of each, for the chat's completion and suggestions).
	  Searches  one at a time, a slice of each Heartbeat (Config.Locate.BudgetMs, 3 ms: `step`,
	            which World/Simulation runs before the generation preload's slice), in the
	            order typed, at most Config.Locate.Queue waiting ("Too many locates are running"
	            past that); a player's new /locate replaces their earlier one, leaving cancels
	            it, and one still running after Config.Locate.TimeoutSeconds answers not found.
	            They run on a generator of their own (`start`'s `newGenerator`, made at the first
	            search): a search stops in the middle of a plan or a chunk when its slice is spent,
	            which the world's generator, busy with the chunks around players, must never do.
	            Its caches are its own too, so a search over thousands of cells evicts nothing the
	            chunks need. The world is read for its edits only (/locate poi).
	  Position  where the player stands (Players/PlayerPositions.feet: true world coordinates,
	            with or without server positions), and the answer is in the same coordinates.
	  Answers   Notice messages; a success carries its coordinates' link (Protocol.NoticeLink:
	            "/tp @s x y z", which /tp, Players/TeleportCommands, carries out). The server log
	            gets "[IceVoxel] locating ... took N ms (P probes, V checked)".
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Protocol = require(Shared.Net.Protocol)
local TerrainGenerator = require(Shared.Generation.TerrainGenerator)
local Library = require(Shared.Structures.Library)
local Locate = require(Shared.Generation.Locate)
local WorldSettings = require(Shared.WorldSettings)

local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local WorldServer = require(script.Parent.Parent.World.WorldServer)
local Operators = require(script.Parent.Operators)
local PlayerPositions = require(script.Parent.PlayerPositions)
local LocateCommand = require(script.Parent.LocateCommand)

local LocateCommands = {}

local net: ServerNet.ServerNet? = nil
local world: WorldServer.World? = nil
local makeGenerator: (() -> TerrainGenerator.Generator)? = nil
local generator: TerrainGenerator.Generator? = nil
local registries: LocateCommand.Registries? = nil
local queue: LocateCommand.Queue? = nil

local function notify(player: Player, text: string, link: Protocol.NoticeLink?)
	if net and player.Parent then
		net.send(player, Protocol.ServerMessage.Notice, Protocol.encodeNotice(text, link))
	end
end

-- The searches' generator, made at the first search.
local function searchGenerator(): TerrainGenerator.Generator
	local made = generator
	if made == nil then
		local make = makeGenerator
		made = if make then make() else (world :: WorldServer.World).generator
		generator = made
	end
	return made :: TerrainGenerator.Generator
end

-- Runs a chat message as /locate (ignores anything else).
local function run(player: Player, text: string)
	local jobs, known = queue, registries
	if jobs == nil or known == nil or not LocateCommand.matches(text) or player.Parent == nil then
		return
	end
	local result = LocateCommand.run(text, { mayUse = Operators.permitted(player), registries = known })
	if result == nil then
		return
	end
	for _, message in result.feedback do
		notify(player, message)
	end
	local request = result.request
	if request == nil then
		return
	end
	local x, y, z = PlayerPositions.feet(player)
	if x == nil then
		notify(player, LocateCommand.notFound(request))
		return
	end
	local typed = os.clock()
	local job: LocateCommand.Job = {
		key = player,
		run = function(yield: () -> ())
			local stats = { probes = 0, verified = 0 }
			local found = LocateCommand.search(request, searchGenerator(), world, x, y, z, yield, stats)
			print(LocateCommand.logLine(request, (os.clock() - typed) * 1000, stats))
			if found then
				local answer, link = LocateCommand.success(request, found)
				notify(player, answer, link)
			else
				notify(player, LocateCommand.notFound(request))
			end
		end,
		timedOut = function()
			warn(`[IceVoxel] locating {request.type} {request.resolved.label} ran out of time`)
			notify(player, LocateCommand.notFound(request))
		end,
		failed = function(message: string)
			warn(`[IceVoxel] locating {request.type} {request.resolved.label} failed: {message}`)
			notify(player, LocateCommand.FAILED)
		end,
	}
	if not LocateCommand.submit(jobs, job) then
		notify(player, LocateCommand.BUSY)
	end
end

--[[
	The searches' slice of this frame (at most Config.Locate.BudgetMs): World/Simulation runs it on
	Heartbeat just before sizing the generation preload's slice, which so takes what is left of
	the frame (Config.Server.FrameBudgetMs).
]]
function LocateCommands.step()
	local jobs = queue
	if jobs and LocateCommand.pending(jobs) > 0 then
		LocateCommand.step(jobs)
	end
end

--[[
	Starts /locate on `serverWorld` (its edits: /locate poi). `newGenerator` makes the searches'
	generator (the world's type and seed, as the world's own: Generation/WorldTypes.create).
]]
function LocateCommands.start(
	serverNet: ServerNet.ServerNet,
	serverWorld: WorldServer.World,
	newGenerator: (() -> TerrainGenerator.Generator)?
)
	assert(net == nil, "LocateCommands.start was already called")
	net = serverNet
	world = serverWorld
	makeGenerator = newGenerator
	local names: { string } = {}
	for _, structure in Library.load().structures do
		table.insert(names, structure.name)
		-- (The built-in kind of the same id wins: Generation/Locate's registry.)
		if table.find(Locate.STRUCTURES, Locate.snake(structure.name)) then
			warn(`[IceVoxel] /locate: the library's structure '{structure.name}' has a built-in kind's id`)
		end
	end
	local known = LocateCommand.registries(names)
	registries = known
	local cfg = Config.Locate
	local jobs = LocateCommand.newQueue(cfg.BudgetMs / 1000, cfg.TimeoutSeconds, cfg.Queue, os.clock)
	queue = jobs

	Players.PlayerRemoving:Connect(function(player: Player)
		LocateCommand.cancel(jobs, player)
	end)

	if TextChatService.ChatVersion == Enum.ChatVersion.LegacyChatService then
		local function onPlayer(player: Player)
			player.Chatted:Connect(function(message: string)
				run(player, message)
			end)
		end
		Players.PlayerAdded:Connect(onPlayer)
		for _, player in Players:GetPlayers() do
			onPlayer(player)
		end
		return
	end
	local command = Instance.new("TextChatCommand")
	command.Name = "IceVoxelLocate"
	command.PrimaryAlias = LocateCommand.ALIASES[1]
	-- (The operators' permission: the chat suggests it to those who have it; its arguments.)
	command:SetAttribute(WorldSettings.COMMAND_ATTRIBUTE, WorldSettings.COMMAND_PERMITTED)
	command:SetAttribute(WorldSettings.COMMAND_ARGUMENTS_ATTRIBUTE, LocateCommand.arguments(known))
	command.Triggered:Connect(function(source: TextSource, text: string)
		local player = Players:GetPlayerByUserId(source.UserId)
		if player then
			run(player, text)
		end
	end)
	command.Parent = TextChatService
end

return LocateCommands
