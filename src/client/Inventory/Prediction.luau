--!strict
--[[
	Client prediction of the inventory, by replay (pure: no Roblox APIs, so the tests run it).

	The server is the authority: it applies every inventory action with Inventory/Menu.apply in the
	order it receives them and answers with snapshots that say which action they include (`ack`).
	The client numbers its actions (seq 1, 2, 3, ...) and keeps the ones the server has not
	acknowledged yet. Its view of the inventory is always:

	    the last snapshot  +  every pending action (seq > ack), re-applied in order with Menu.apply

	so a local click shows at once, a snapshot that agrees changes nothing visible, and one that
	disagrees (the server refused something, or another player changed the shared chest) wins
	without the local actions sent after it being lost.

	Actions are applied the same way the server applies them: a `close` that names the open window
	goes through Menu.close (the cursor and a crafting grid go back into the inventory), and a
	block's window then becomes the inventory screen's window again (window 0 with a fresh 2 x 2
	grid, Types.newWindow), as the server does; window 0 keeps its own. Crafting results come from
	Menu, the same way on both sides. Replays use the game mode the client has now; it only
	matters for creative-only actions, and modes change rarely.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Menu = require(Shared.Inventory.Menu)
local Types = require(Shared.Inventory.Types)

type Window = Types.Window
type Action = Types.Action

-- Pending actions kept at most (a server that stopped answering must not grow this forever).
local MAX_PENDING = 1024

export type Pending = { seq: number, action: Action }

export type Prediction = {
	-- The last snapshot as a window (never mutated after it arrives).
	base: Window,
	-- Highest action number the server has answered.
	ack: number,
	-- Number the next action gets.
	nextSeq: number,
	-- Actions sent but not acknowledged yet, in order.
	pending: { Pending },
	-- base + pending: what the player sees.
	predicted: Window,

	receive: (self: Prediction, snapshot: Types.Snapshot, creative: boolean) -> (),
	push: (self: Prediction, action: Action, creative: boolean) -> number,
	replay: (self: Prediction, creative: boolean) -> (),
	window: (self: Prediction) -> Window,
}

local Prediction = {}
Prediction.__index = Prediction

-- Applies an action the way the server does (a close of a block's window resets it).
local function applyLocal(window: Window, action: Action, creative: boolean)
	local closes = action.kind == "close" and action.window == window.id
	Menu.apply(window, action, creative)
	local container = window.container
	if closes and (window.id ~= 0 or container == nil or container.kind ~= "inventory") then
		window.id = 0
		window.container = Types.newCrafting("inventory")
	end
end

function Prediction.new(): Prediction
	local base: Window = Types.newWindow(Types.newInventory())
	return (
		setmetatable({
			base = base,
			ack = 0,
			nextSeq = 1,
			pending = {},
			predicted = Menu.copyWindow(base),
		}, Prediction) :: any
	) :: Prediction
end

-- A server snapshot arrived: it replaces the base, and the actions it includes stop being pending.
function Prediction.receive(self: Prediction, snapshot: Types.Snapshot, creative: boolean)
	self.base = { id = snapshot.window, inventory = snapshot.inventory, container = snapshot.container }
	self.ack = snapshot.ack
	-- (Never reuse a number the server has seen, whatever happened before.)
	if snapshot.ack >= self.nextSeq then
		self.nextSeq = snapshot.ack + 1
	end
	local kept: { Pending } = {}
	for _, entry in self.pending do
		if entry.seq > snapshot.ack then
			table.insert(kept, entry)
		end
	end
	self.pending = kept
	self:replay(creative)
end

-- A local action: numbers it, keeps it until acknowledged and applies it to the prediction.
function Prediction.push(self: Prediction, action: Action, creative: boolean): number
	local seq = self.nextSeq
	self.nextSeq += 1
	table.insert(self.pending, { seq = seq, action = action })
	if #self.pending > MAX_PENDING then
		-- Long lost: forget the oldest and rebuild from the snapshot.
		table.remove(self.pending, 1)
		self:replay(creative)
	else
		applyLocal(self.predicted, action, creative)
	end
	return seq
end

-- Rebuilds the prediction: a copy of the snapshot with every pending action applied again.
function Prediction.replay(self: Prediction, creative: boolean)
	local window = Menu.copyWindow(self.base)
	for _, entry in self.pending do
		applyLocal(window, entry.action, creative)
	end
	self.predicted = window
end

-- The predicted window. Read only: it is replaced (not updated) by snapshots.
function Prediction.window(self: Prediction): Window
	return self.predicted
end

return Prediction
