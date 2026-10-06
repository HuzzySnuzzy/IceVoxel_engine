--!strict
--[[
	Teleport mode: the streamer drops the old area at once instead of keeping it until the new one
	is ready (which froze the player for seconds and then swapped tens of thousands of parts in one
	frame). Pure, tested in tests/spec/Streaming.

	  * `isJump`: the viewer moved further than Streaming.TeleportDistance between two refreshes
	    (MovementController's teleport handler says so earlier, with the destination).
	  * `plan`: the order the old nodes leave. Every old node is trashed (ChunkRenderer.trashNode)
	    with its distance to the destination; those within `near` blocks of it leave the workspace
	    at once, the rest nearest first within Render.UnparentPartsPerFrame.
	  * A `Mode` stays active until the 3x3 chunks under the player are shown and at most `settle`
	    nodes and builds are left, or `timeout` seconds passed. Far meshes and map tiles wait
	    meanwhile.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local LodTree = require(Shared.World.LodTree)

local TeleportMode = {}

-- Did the viewer jump from (x0, z0) to (x1, z1) (blocks) rather than move?
function TeleportMode.isJump(x0: number, z0: number, x1: number, z1: number, distance: number): boolean
	local dx, dz = x1 - x0, z1 - z0
	return dx * dx + dz * dz > distance * distance
end

export type Leaving = { node: any, distance: number, immediate: boolean }

--[[
	How the old nodes (tables with level, nx, nz) leave for a destination (x, z): each with its
	distance to it (LodTree.distance), and whether it is within `near` blocks (leaves at once).
	Nearest first.
]]
function TeleportMode.plan(nodes: { any }, x: number, z: number, near: number): { Leaving }
	local out: { Leaving } = table.create(#nodes)
	for _, node in nodes do
		local distance = LodTree.distance(node.level, node.nx, node.nz, x, z)
		table.insert(out, { node = node, distance = distance, immediate = distance < near })
	end
	table.sort(out, function(a, b)
		return a.distance < b.distance
	end)
	return out
end

export type Mode = {
	active: boolean,
	since: number,
	timeout: number,
	settle: number,

	enter: (self: Mode, now: number) -> (),
	-- `ready`: the 3x3 under the player is shown; `backlog`: nodes waiting, queued or being
	-- generated plus builds pending. Returns true when the mode ended now.
	update: (self: Mode, now: number, ready: boolean, backlog: number) -> boolean,
}

local Mode = {}
Mode.__index = Mode

function TeleportMode.new(timeout: number, settle: number): Mode
	local self = { active = false, since = -math.huge, timeout = timeout, settle = settle }
	return (setmetatable(self, Mode) :: any) :: Mode
end

function Mode.enter(self: Mode, now: number)
	self.active = true
	self.since = now
end

function Mode.update(self: Mode, now: number, ready: boolean, backlog: number): boolean
	if not self.active then
		return false
	end
	if (ready and backlog <= self.settle) or now - self.since > self.timeout then
		self.active = false
		return true
	end
	return false
end

return TeleportMode
