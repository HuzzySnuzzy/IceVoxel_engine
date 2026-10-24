--!strict
--[[
	Turrets seen (Shared/Turrets): the gun on every turret block near the camera, turning and
	firing as the server's Turrets records say (Net/Protocol message Turrets: aim, target,
	flags, rounds), drawn from pooled parts in their models (Rendering/TurretModel), with a Laser
	Sight's beam and the servo's loop. Their shots are Rendering/ShotView's (Shots records with
	no shooter: the flash and tracer start at the record's origin, the muzzle).

	The API (frozen: the client script, WAILA and F3 are built on it):
	  start(world)     once, after Rendering/ShotView: turret positions from the world's edits
	                   (World/ClientWorld), the records, the parts, the frame loop
	  state(x, y, z)   the record the turret at block (x, y, z) last got (nil: none, idle), for
	                   WAILA's turret lines
	  stats()          drawn turrets, records known, tracking, parts in use (F3's turret line)

	STUB (turret builder B implements it: Rendering/TurretModel, the records, the parts, the beam
	and the servo): nothing is drawn or kept yet.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Protocol = require(Shared.Net.Protocol)

local ClientWorld = require(script.Parent.Parent.World.ClientWorld)

-- F3's counts (see the header).
export type Stats = { drawn: number, records: number, tracking: number, parts: number }

local TurretView = {}

local started = false

-- Starts the view over the client's world (see the header). STUB (builder B): nothing yet.
function TurretView.start(_world: ClientWorld.ClientWorld)
	if started then
		return
	end
	started = true
end

-- The last record of the turret at block (x, y, z), nil when none came. STUB (builder B): none.
function TurretView.state(_x: number, _y: number, _z: number): Protocol.TurretRecord?
	return nil
end

-- What the view holds now. STUB (builder B): nothing.
function TurretView.stats(): Stats
	return { drawn = 0, records = 0, tracking = 0, parts = 0 }
end

return TurretView
