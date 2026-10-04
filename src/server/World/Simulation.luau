--!strict
--[[
	Keeps the chunks around every player generated on the server (so block updates can run there and
	edit requests validate instantly) and evicts chunks nobody is near anymore.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Coords = require(Shared.World.Coords)

local WorldServer = require(script.Parent.WorldServer)

local CHUNK_STUDS = Config.ChunkSize * Config.BlockSize
local SCAN_INTERVAL = 0.5

local Simulation = {}

function Simulation.start(world: WorldServer.World)
	local radius = Config.Server.SimulationRadius
	local wanted: { [number]: boolean } = {}
	local queue: { { number } } = {}

	local function scan()
		wanted = {}
		queue = {}
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				local pcx = math.floor(root.Position.X / CHUNK_STUDS)
				local pcz = math.floor(root.Position.Z / CHUNK_STUDS)
				for dz = -radius - 1, radius + 1 do
					for dx = -radius - 1, radius + 1 do
						local cx, cz = pcx + dx, pcz + dz
						wanted[Coords.chunkKey(cx, cz)] = true
						if math.abs(dx) <= radius and math.abs(dz) <= radius and not world:peekChunk(cx, cz) then
							table.insert(queue, { cx, cz, dx * dx + dz * dz })
						end
					end
				end
			end
		end
		-- Closest first; pop from the end.
		table.sort(queue, function(a, b)
			return a[3] > b[3]
		end)
		world:evict(function(cx, cz)
			return wanted[Coords.chunkKey(cx, cz)] == true
		end, Config.Server.CacheSize)
	end

	local elapsed = SCAN_INTERVAL
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed >= SCAN_INTERVAL then
			elapsed = 0
			scan()
		end
		for _ = 1, Config.Server.GenerationsPerFrame do
			local entry = table.remove(queue)
			if entry == nil then
				break
			end
			world:getChunk(entry[1], entry[2])
		end
	end)
end

return Simulation
