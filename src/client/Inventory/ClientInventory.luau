--!strict
--[[
	The local player's inventory, predicted.

	The server owns the inventory (Players/Inventories) and sends a snapshot after every change
	(ServerMessage.Inventory). What the client shows is that snapshot with the player's own
	actions that the server has not answered yet applied on top (Inventory/Prediction): every
	local action is numbered, applied at once and sent (ClientMessage.Inventory), so clicks feel
	instant and the server's answer quietly wins if it disagrees.

	Placing a block is the one action not sent here: `place` predicts the item being used up and
	returns its number, which travels inside the Edit message (BlockInteraction / ClientWorld), so
	the server applies the placement and the use together.

	The window comes from the snapshots: window 0 is the inventory screen's (the inventory and its
	own 2 x 2 crafting grid, Types.newWindow); when the server opens a block (a chest, a crafting
	table, a furnace) the predicted window becomes that block's window, and actions name it.
	Crafting results are predicted too: Inventory/Menu derives them the same way on both sides.

	Game modes (Shared/GameMode): actions go through Menu.allows first, as on the server, so a
	spectator's clicks, drags, drops and creative actions are neither predicted nor sent (a
	spectator looks into chests read only, only picking hotbar slots and closing windows), and the
	prediction applies Menu's creative rules with the instabuild ability (`isCreative`: creative
	mode). Adventure plays like survival here; its limits are on blocks (BlockInteraction).

	`changed` fires (deferred, once per change) after the prediction changes: a snapshot, a local
	action or a game mode switch.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Menu = require(Shared.Inventory.Menu)
local Types = require(Shared.Inventory.Types)
local Protocol = require(Shared.Net.Protocol)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local Prediction = require(script.Parent.Prediction)

local player = Players.LocalPlayer
local prediction = Prediction.new()
local changedEvent = Instance.new("BindableEvent")
local started = false

local ClientInventory = {}

-- Fires after the predicted state changes (a snapshot, a local action, a game mode change).
ClientInventory.changed = changedEvent.Event

local function mode(): string
	return GameMode.of(player)
end

local function notify()
	changedEvent:Fire()
end

function ClientInventory.start()
	if started then
		return
	end
	started = true
	ClientNet.on(Protocol.ServerMessage.Inventory, function(payload: buffer)
		local ok, snapshot = pcall(Protocol.decodeInventory, payload)
		if not ok or snapshot == nil then
			warn(`[IceVoxel] Bad inventory snapshot: {if ok then "malformed" else snapshot}`)
			return
		end
		prediction:receive(snapshot, mode())
		notify()
	end)
	-- Pending actions replay by the new mode's rules after a game mode change.
	player:GetAttributeChangedSignal(GameMode.ATTRIBUTE):Connect(function()
		prediction:replay(mode())
		notify()
	end)
end

--[[
	Progression's recipe gate for this player (Shared/Progression.allows; nil: everything), as the
	server's window has it: locked crafting results are not predicted.
]]
function ClientInventory.setRecipes(recipes: ((item: number) -> boolean)?)
	prediction:setRecipes(recipes, mode())
	notify()
end

-- The predicted window (the inventory, plus its container: window 0's 2 x 2 grid or a block's).
-- Read only.
function ClientInventory.window(): Types.Window
	return prediction:window()
end

-- The predicted inventory. Read only.
function ClientInventory.inventory(): Types.Inventory
	return prediction:window().inventory
end

-- The local player's game mode (Shared/GameMode).
function ClientInventory.mode(): string
	return mode()
end

--[[
	Does the player have the instabuild ability (creative mode): the item selection screen, creative
	slots, middle-click clones, placing without using items up, creative-only blocks?
]]
function ClientInventory.isCreative(): boolean
	return GameMode.instabuild(mode())
end

-- May the player do `action` at all in their game mode (Menu.allows)?
function ClientInventory.allows(action: Types.Action): boolean
	return Menu.allows(action, mode())
end

-- The selected hotbar slot, 1..9.
function ClientInventory.selected(): number
	return prediction:window().inventory.selected
end

-- The stack in the selected hotbar slot (the item in hand, e.g. the tool mining uses).
function ClientInventory.selectedStack(): Types.Stack?
	local inventory = prediction:window().inventory
	local stack = inventory.slots[inventory.selected]
	if stack == nil or stack.count < 1 then
		return nil
	end
	return stack
end

--[[
	Predicts an action and sends it to the server, if the game mode allows it (else nothing
	happens: the server would refuse it). (`place` goes through ClientInventory.place.)
]]
function ClientInventory.apply(action: Types.Action)
	if action.kind == "place" then
		ClientInventory.place(action.item)
		return
	end
	local current = mode()
	if not Menu.allows(action, current) then
		return
	end
	local seq = prediction:push(action, current)
	ClientNet.send(Protocol.ClientMessage.Inventory, Protocol.encodeInventoryAction(seq, action))
	notify()
end

-- Selects hotbar slot 1..9.
function ClientInventory.select(slot: number)
	if slot >= 1 and slot <= Types.HOTBAR_SIZE and slot ~= ClientInventory.selected() then
		ClientInventory.apply({ kind = "select", slot = slot })
	end
end

-- Throws one of the held item (Q), or the whole stack (Ctrl+Q). True when something was thrown.
function ClientInventory.dropSelected(all: boolean): boolean
	local action: Types.Action = { kind = "drop", all = all }
	if ClientInventory.selectedStack() == nil or not ClientInventory.allows(action) then
		return false
	end
	ClientInventory.apply(action)
	return true
end

--[[
	A block of the held item is being placed: predicts one being used up (survival) and returns the
	action number for Protocol.encodeEdit, which carries it to the server.
]]
function ClientInventory.place(item: number): number
	local seq = prediction:push({ kind = "place", item = item }, mode())
	notify()
	return seq
end

--[[
	Minecraft's pick block (middle click on a block): selects or fetches its item (from nothing only
	with instabuild). Spectators pick nothing (their middle click is the spectator menu's).
]]
function ClientInventory.pickBlock(block: number)
	local item = Items.ofBlock(block)
	if item == nil or not GameMode.canInteract(mode()) then
		return
	end
	for _, action in Menu.pickBlock(ClientInventory.inventory(), item, ClientInventory.isCreative()) do
		ClientInventory.apply(action)
	end
end

return ClientInventory
