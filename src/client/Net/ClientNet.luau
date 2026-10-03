--!strict
--[[
	Client side of the single IceVoxel remote.

	Everything the server sends arrives through one RemoteEvent (see Shared/Net/Protocol), and
	Roblox hands queued messages to whichever listener connects first. So exactly one listener
	lives here and routes messages by type; messages for a type nobody handles yet are kept and
	delivered once a handler registers (e.g. the waypoint list sent while the client boots).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Remotes = require(Shared.Net.Remotes)

export type Handler = (payload: buffer) -> ()

local MAX_BACKLOG = 64

local remote = Remotes.net()
local handlers: { [number]: Handler } = {}
local backlog: { [number]: { buffer } } = {}

remote.OnClientEvent:Connect(function(kind: unknown, payload: unknown)
	if type(kind) ~= "number" or typeof(payload) ~= "buffer" then
		return
	end
	local handler = handlers[kind]
	if handler then
		handler(payload)
		return
	end
	local queue = backlog[kind]
	if queue == nil then
		queue = {}
		backlog[kind] = queue
	end
	if #queue < MAX_BACKLOG then
		table.insert(queue, payload)
	end
end)

local ClientNet = {}

-- Routes messages of one Protocol.ServerMessage type to `handler` (one handler per type).
function ClientNet.on(kind: number, handler: Handler)
	assert(handlers[kind] == nil, `A handler for message {kind} already exists`)
	handlers[kind] = handler
	local queued = backlog[kind]
	if queued then
		backlog[kind] = nil
		for _, payload in queued do
			handler(payload)
		end
	end
end

function ClientNet.send(kind: number, payload: buffer)
	remote:FireServer(kind, payload)
end

return ClientNet
