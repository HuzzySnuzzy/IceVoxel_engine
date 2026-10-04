--!strict
--[[
	Finds (client) or creates (server) the remote instances IceVoxel uses.
]]

local RunService = game:GetService("RunService")

local Remotes = {}

local NET_NAME = "Net"

function Remotes.net(): RemoteEvent
	local folder = script.Parent
	if RunService:IsServer() then
		local existing = folder:FindFirstChild(NET_NAME)
		if existing and existing:IsA("RemoteEvent") then
			return existing
		end
		local remote = Instance.new("RemoteEvent")
		remote.Name = NET_NAME
		remote.Parent = folder
		return remote
	end
	return folder:WaitForChild(NET_NAME) :: RemoteEvent
end

return Remotes
