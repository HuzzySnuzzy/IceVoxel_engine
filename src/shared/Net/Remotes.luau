--!strict
--[[
	Finds (client) or creates (server) the remote instances IceVoxel uses.

	  net    the RemoteEvent "Net": every protocol message (Net/Protocol), reliable and ordered
	  moves  the UnreliableRemoteEvent "Moves": players' positions (Net/PlayerSync), clients' Moves
	         up and the server's Poses down. Unreliable: a lost one is replaced by the next (20 a
	         second), and a message over 1000 bytes is dropped.
]]

local RunService = game:GetService("RunService")

local Remotes = {}

local NET_NAME = "Net"
local MOVES_NAME = "Moves"

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

function Remotes.moves(): UnreliableRemoteEvent
	local folder = script.Parent
	if RunService:IsServer() then
		local existing = folder:FindFirstChild(MOVES_NAME)
		if existing and existing:IsA("UnreliableRemoteEvent") then
			return existing
		end
		local remote = Instance.new("UnreliableRemoteEvent")
		remote.Name = MOVES_NAME
		remote.Parent = folder
		return remote
	end
	return folder:WaitForChild(MOVES_NAME) :: UnreliableRemoteEvent
end

return Remotes
