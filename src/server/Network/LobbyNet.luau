--!strict
--[[
	The network before the world exists: what starts with the server, ahead of the world (the title
	screen's Players/WorldMenu, Players/Operators, Players/SettingsStore), talks through this.

	It is ServerNet's `on` and `send` on the same single remote (Net/Remotes), with handlers of its
	own: a message type belongs either to this net or to the world's ServerNet (which starts with
	the world). Both listen on the remote and each ignores the types it doesn't know, so every
	message is handled once, and sends of both stay in one ordered stream (Shared/Net/Protocol).
	`flush` does nothing (there are no edits without a world); `setRules` and `addBlockData` belong
	to the world's net and fail here.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Remotes = require(Shared.Net.Remotes)

local ServerNet = require(script.Parent.ServerNet)

local LobbyNet = {}

local started: ServerNet.ServerNet? = nil

-- The lobby's net (made on the first call).
function LobbyNet.start(): ServerNet.ServerNet
	local existing = started
	if existing then
		return existing
	end
	local remote = Remotes.net()
	local handlers: { [number]: ServerNet.Handler } = {}
	remote.OnServerEvent:Connect(function(player: Player, kind: unknown, payload: unknown)
		if typeof(kind) ~= "number" or typeof(payload) ~= "buffer" then
			return
		end
		local handler = handlers[kind :: number]
		if handler and player.Parent == Players then
			handler(player, payload :: buffer)
		end
	end)
	local net: ServerNet.ServerNet = {
		flush = function() end,
		on = function(kind: number, handler: ServerNet.Handler)
			assert(handlers[kind] == nil, `A handler for message {kind} already exists`)
			handlers[kind] = handler
		end,
		send = function(player: Player, kind: number, payload: buffer)
			remote:FireClient(player, kind, payload)
		end,
		setRules = function()
			error("LobbyNet: the world's ServerNet takes the rules")
		end,
		addBlockData = function()
			error("LobbyNet: the world's ServerNet takes block data hooks")
		end,
	}
	started = net
	return net
end

return LobbyNet
