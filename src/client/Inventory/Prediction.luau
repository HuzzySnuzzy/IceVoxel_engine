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
	Menu, the same way on both sides.

	Progression's recipe gate (`setRecipes`: Shared/Progression.allows for this player, as the
	server's window has it) goes on every window the prediction makes, so a locked crafting result
	is never predicted (the screens draw it greyed from Crafting.match themselves).

	Every action goes through the game mode's rules as on the server: an action the mode does not
	allow (Menu.allows: a spectator only selects hotbar slots and closes windows) changes nothing,
	and Menu.apply gets the mode's instabuild ability (creative slots, middle-click clones, placing
	without using items up). Replays use the game mode the client has now; modes change rarely.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)
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
	-- The recipe gate every window here gets (Types.Window `recipes`; nil: none).
	recipes: ((item: number) -> boolean)?,

	receive: (self: Prediction, snapshot: Types.Snapshot, mode: string) -> (),
	push: (self: Prediction, action: Action, mode: string) -> number,
	replay: (self: Prediction, mode: string) -> (),
	setRecipes: (self: Prediction, recipes: ((item: number) -> boolean)?, mode: string) -> (),
	window: (self: Prediction) -> Window,
}

local Prediction = {}
Prediction.__index = Prediction

--[[
	Applies an action the way the server does for a player in game `mode`: nothing when the mode
	does not allow it, and a close of a block's window resets the window.
]]
local function applyLocal(window: Window, action: Action, mode: string)
	if not Menu.allows(action, mode) then
		return
	end
	local closes = action.kind == "close" and action.window == window.id
	Menu.apply(window, action, GameMode.instabuild(mode))
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
function Prediction.receive(self: Prediction, snapshot: Types.Snapshot, mode: string)
	self.base = {
		id = snapshot.window,
		inventory = snapshot.inventory,
		container = snapshot.container,
		recipes = self.recipes,
	}
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
	self:replay(mode)
end

--[[
	A local action of a player in game `mode`: numbers it, keeps it until acknowledged and applies it
	to the prediction (an action the mode does not allow is numbered but changes nothing; callers
	need not send it: Menu.allows).
]]
function Prediction.push(self: Prediction, action: Action, mode: string): number
	local seq = self.nextSeq
	self.nextSeq += 1
	table.insert(self.pending, { seq = seq, action = action })
	if #self.pending > MAX_PENDING then
		-- Long lost: forget the oldest and rebuild from the snapshot.
		table.remove(self.pending, 1)
		self:replay(mode)
	else
		applyLocal(self.predicted, action, mode)
	end
	return seq
end

-- Rebuilds the prediction: a copy of the snapshot with every pending action applied again.
function Prediction.replay(self: Prediction, mode: string)
	local window = Menu.copyWindow(self.base)
	for _, entry in self.pending do
		applyLocal(window, entry.action, mode)
	end
	self.predicted = window
end

--[[
	Sets the recipe gate (nil: none) and rebuilds the prediction with it. The snapshot's own
	crafting result was the server's, gated by the same rule.
]]
function Prediction.setRecipes(self: Prediction, recipes: ((item: number) -> boolean)?, mode: string)
	self.recipes = recipes
	local base = Menu.copyWindow(self.base)
	base.recipes = recipes
	self.base = base
	self:replay(mode)
end

-- The predicted window. Read only: it is replaced (not updated) by snapshots.
function Prediction.window(self: Prediction): Window
	return self.predicted
end

return Prediction
