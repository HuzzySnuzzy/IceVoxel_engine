--!strict
--[[
	Scheduled block updates ("block ticks").

	When a block changes, the block itself and its six neighbours are notified. Blocks that have a
	behaviour (see Behaviours/) react by scheduling a tick, and on that tick they can change the
	world again (sand falls, water spreads...), which notifies their neighbours, and so on.

	Ticks run at Config.Server.TickRate. At most MaxUpdatesPerTick updates run per tick; the rest
	move to the next tick, so a flood never stalls the server.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Coords = require(Shared.World.Coords)

local WorldServer = require(script.Parent.WorldServer)

type World = WorldServer.World

export type Behaviour = {
	-- Ticks to wait after a neighbour changed (default 1).
	tickDelay: number?,
	-- Called when the block or a neighbour changed. Default: schedule a tick after `tickDelay`.
	onNeighborChanged: ((world: World, ticker: Ticker, x: number, y: number, z: number, block: number) -> ())?,
	-- Called on a scheduled tick.
	onTick: ((world: World, ticker: Ticker, x: number, y: number, z: number, block: number) -> ())?,
}

export type Ticker = {
	world: World,
	behaviours: { [number]: Behaviour },
	tick: number,
	maxPerTick: number,
	queue: { [number]: { number } },
	scheduled: { [number]: number },

	schedule: (self: Ticker, x: number, y: number, z: number, delay: number) -> (),
	blockChanged: (self: Ticker, x: number, y: number, z: number) -> (),
	step: (self: Ticker) -> number,
	pendingCount: (self: Ticker) -> number,
}

local NEIGHBOURS = { { 0, 0, 0 }, { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }

local BlockTicker = {}
BlockTicker.__index = BlockTicker

function BlockTicker.new(world: World, behaviours: { [number]: Behaviour }, maxPerTick: number): Ticker
	local self = {
		world = world,
		behaviours = behaviours,
		tick = 0,
		maxPerTick = maxPerTick,
		queue = {},
		scheduled = {},
	}
	return (setmetatable(self, BlockTicker) :: any) :: Ticker
end

-- Schedules a tick for the block at (x, y, z) in `delay` ticks. Keeps the earlier one if already scheduled.
function BlockTicker.schedule(self: Ticker, x: number, y: number, z: number, delay: number)
	local key = Coords.posKey(x, y, z)
	local due = self.tick + math.max(1, delay)
	local existing = self.scheduled[key]
	if existing and existing <= due then
		return
	end
	self.scheduled[key] = due
	local list = self.queue[due]
	if list == nil then
		list = {}
		self.queue[due] = list
	end
	table.insert(list, key)
end

-- Notifies the block at (x, y, z) and its six neighbours that something changed.
function BlockTicker.blockChanged(self: Ticker, x: number, y: number, z: number)
	local world = self.world
	for _, offset in NEIGHBOURS do
		local nx, ny, nz = x + offset[1], y + offset[2], z + offset[3]
		local block = world:peekBlock(nx, ny, nz)
		if block then
			local behaviour = self.behaviours[block]
			if behaviour then
				if behaviour.onNeighborChanged then
					behaviour.onNeighborChanged(world, self, nx, ny, nz, block)
				else
					BlockTicker.schedule(self, nx, ny, nz, behaviour.tickDelay or 1)
				end
			end
		end
	end
end

-- Advances one tick. Returns the number of updates that ran.
function BlockTicker.step(self: Ticker): number
	self.tick += 1
	local tick = self.tick
	local list = self.queue[tick]
	if list == nil then
		return 0
	end
	self.queue[tick] = nil

	local world = self.world
	local ran = 0
	for i, key in list do
		if self.scheduled[key] == tick then
			if ran >= self.maxPerTick then
				-- Over budget: push everything left to the next tick.
				for j = i, #list do
					local rest = list[j]
					if self.scheduled[rest] == tick then
						self.scheduled[rest] = nil
						local x, y, z = Coords.decodePosKey(rest)
						BlockTicker.schedule(self, x, y, z, 1)
					end
				end
				break
			end
			self.scheduled[key] = nil
			local x, y, z = Coords.decodePosKey(key)
			local block = world:peekBlock(x, y, z)
			if block then
				local behaviour = self.behaviours[block]
				if behaviour and behaviour.onTick then
					behaviour.onTick(world, self, x, y, z, block)
					ran += 1
				end
			end
		end
	end
	return ran
end

function BlockTicker.pendingCount(self: Ticker): number
	local n = 0
	for _ in self.scheduled do
		n += 1
	end
	return n
end

return BlockTicker
