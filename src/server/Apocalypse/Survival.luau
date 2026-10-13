--!strict
--[[
	The zombie apocalypse's survival rules on the server: a zombie's bites (infection) and wounds
	(Bleeding) through Mobs/Mobs.playerHit, sprinting's noise (Apocalypse/NoiseBus), and each
	character's survivor record (days alive, zombies killed, blood moons survived: Protocol
	Survivor). The boot script starts it after Players/Eating.

	(For now `start` does nothing: the foundation lays the hooks this module will use,
	Characters.magicHurt, the effect adapters' `amplifier`, Mobs.playerHit, Mobs.spawn's variant
	and NoiseBus.emit, and the rules come with the survival work.)
]]

local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local WorldServer = require(script.Parent.Parent.World.WorldServer)

local Survival = {}

-- Starts the survival rules (see the header). `net` is the ServerNet, `world` the server's world.
function Survival.start(_net: ServerNet.ServerNet, _world: WorldServer.World) end

return Survival
