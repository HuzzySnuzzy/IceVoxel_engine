--!strict
--[[
	Swap units: what goes on and off screen together when the levels of detail change. Pure, tested
	in tests/spec/Streaming.

	The input is every node that may leave the screen now (replaced, and its replacements are
	ready) and every ready node waiting to be shown. A unit is a set of them connected by overlap
	(one is an ancestor of the other in the LOD tree): a coarse node and the finer ones replacing
	it, or fine nodes and the coarse one replacing them. The streamer does a unit whole in one
	frame (clears its leaving nodes, then shows its waiting ones), so two levels are never drawn
	over each other and never leave a gap; units are taken most urgent first (`take`) until
	Render.SwapPartsPerFrame parts going out and in were used, at least one a frame, and the rest
	wait for the next frame. In teleport mode units that only show nodes are not counted.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Coords = require(Shared.World.Coords)
local LodTree = require(Shared.World.LodTree)

local MAX_LEVEL = LodTree.MAX_LEVEL

local SwapUnits = {}

export type Entry = {
	node: any,
	level: number,
	nx: number,
	nz: number,
	-- Leaving the screen (else: waiting to be shown).
	leaving: boolean,
	-- Parts moved in or out of the workspace.
	cost: number,
	-- Lower is sooner.
	priority: number,
}

export type Unit = {
	members: { Entry },
	cost: number,
	priority: number,
}

-- Groups the entries into units, most urgent (lowest priority) first.
function SwapUnits.build(entries: { Entry }): { Unit }
	local index: { [number]: number } = {}
	local parent: { number } = table.create(#entries)
	for i, entry in entries do
		index[Coords.nodeKey(entry.level, entry.nx, entry.nz)] = i
		parent[i] = i
	end
	local function find(i: number): number
		while parent[i] ~= i do
			parent[i] = parent[parent[i]]
			i = parent[i]
		end
		return i
	end
	for i, entry in entries do
		for level = entry.level + 1, MAX_LEVEL do
			local shift = level - entry.level
			local f = bit32.lshift(1, shift)
			local j = index[Coords.nodeKey(level, entry.nx // f, entry.nz // f)]
			if j then
				local a, b = find(i), find(j)
				if a ~= b then
					parent[a] = b
				end
			end
		end
	end
	local byRoot: { [number]: Unit } = {}
	local units: { Unit } = {}
	for i, entry in entries do
		local root = find(i)
		local unit = byRoot[root]
		if unit == nil then
			unit = { members = {}, cost = 0, priority = math.huge }
			byRoot[root] = unit
			table.insert(units, unit)
		end
		local u = unit :: Unit
		table.insert(u.members, entry)
		u.cost += entry.cost
		if entry.priority < u.priority then
			u.priority = entry.priority
		end
	end
	table.sort(units, function(a, b)
		return a.priority < b.priority
	end)
	return units
end

--[[
	The units to do this frame: in order, while they fit in `allowance` parts (the first always
	does); after the first that does not, only units `free` says cost nothing now (teleport mode:
	nodes shown where nothing else is) are still taken.
]]
function SwapUnits.take(units: { Unit }, allowance: number, free: ((Unit) -> boolean)?): { Unit }
	local out: { Unit } = {}
	local used = 0
	local full = false
	for _, unit in units do
		if free and free(unit) then
			table.insert(out, unit)
		elseif not full then
			if #out > 0 and used + unit.cost > allowance then
				full = true
			else
				used += unit.cost
				table.insert(out, unit)
			end
		end
	end
	return out
end

-- Does the unit only show nodes (nothing leaves)?
function SwapUnits.fresh(unit: Unit): boolean
	for _, member in unit.members do
		if member.leaving then
			return false
		end
	end
	return true
end

return SwapUnits
