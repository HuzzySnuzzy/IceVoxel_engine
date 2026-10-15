--!strict
--[[
	Shots seen and heard (the server's Shots messages, Net/WeaponSync): muzzle flashes, tracers,
	impacts and the fire sounds of every shot near the player, and the authoritative end of the
	player's own (a refused one stops automatic fire). The client builder owns it; this is
	FOUNDATION's stub: it takes the Shots messages (so they don't pile up unhandled) and draws
	nothing. The client boot script calls `start(world)` after BlockInteraction.start.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Protocol = require(Shared.Net.Protocol)
local WeaponSync = require(Shared.Net.WeaponSync)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local ClientWorld = require(script.Parent.Parent.World.ClientWorld)

local ShotView = {}

local started = false

-- Starts listening for shots (the stub: decoded and dropped).
function ShotView.start(_world: ClientWorld.ClientWorld)
	if started then
		return
	end
	started = true
	ClientNet.on(Protocol.ServerMessage.Shots, function(payload: buffer)
		local ok, shots = pcall(WeaponSync.decodeShots, payload)
		if not ok or shots == nil then
			warn("[IceVoxel] Bad Shots message")
		end
	end)
end

return ShotView
