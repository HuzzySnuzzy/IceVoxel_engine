--!strict
--[[
	Firearms on the server, in the manner of DayZ (Shared/Weapons): the authority over every shot
	(Fire messages: the checks, the jam roll, Players/Inventories.fire, Shared/Weapons/Ballistics'
	flight, damage to mobs through Mobs/Mobs.weaponDamage and to players, noise through
	Apocalypse/NoiseBus, the Shots message to everyone near), raising and guarding (Weapon
	messages: Inventory/Types.AIM_ATTRIBUTE), and the timing of the inventory's weapon actions
	(Players/Inventories.setWeaponHooks: reload and jam locks, their sounds for the others). The
	server builder owns it; this is FOUNDATION's stub: every Fire is acknowledged (so the client's
	predicted round comes back with the next snapshot) and nothing is fired; Weapon messages are
	dropped. The server script starts it after Mobs/Mobs.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Protocol = require(Shared.Net.Protocol)
local WeaponSync = require(Shared.Net.WeaponSync)

local Inventories = require(script.Parent.Players.Inventories)
local WorldServer = require(script.Parent.World.WorldServer)

-- Only what Weapons uses of ServerNet.ServerNet.
type Net = {
	send: (player: Player, kind: number, payload: buffer) -> (),
	on: (kind: number, handler: (player: Player, payload: buffer) -> ()) -> (),
}

local Weapons = {}

local started = false

-- Starts handling Fire and Weapon messages (see the header).
function Weapons.start(net: Net, _world: WorldServer.World)
	assert(not started, "Weapons.start was already called")
	started = true
	net.on(Protocol.ClientMessage.Fire, function(player: Player, payload: buffer)
		local fire = WeaponSync.decodeFire(payload)
		if fire then
			-- (Nothing fired: the snapshot gives the predicted round back.)
			Inventories.acknowledge(player, fire.seq)
		end
	end)
	net.on(Protocol.ClientMessage.Weapon, function(_player: Player, _payload: buffer) end)
end

return Weapons
