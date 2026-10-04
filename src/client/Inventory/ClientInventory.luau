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

	The window (inventory alone, or with a container) comes from the snapshots: when the server
	opens a chest, the predicted window becomes that chest's window, and actions name it.

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

local function isCreative(): boolean
	return GameMode.isCreative(player)
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
		if not ok then
			warn(`[IceVoxel] Bad inventory snapshot: {snapshot}`)
			return
		end
		prediction:receive(snapshot, isCreative())
		notify()
	end)
	-- Creative-only actions replay differently after a game mode change.
	player:GetAttributeChangedSignal(GameMode.ATTRIBUTE):Connect(function()
		prediction:replay(isCreative())
		notify()
	end)
end

-- The predicted window (the inventory, plus the open container). Read only.
function ClientInventory.window(): Types.Window
	return prediction:window()
end

-- The predicted inventory. Read only.
function ClientInventory.inventory(): Types.Inventory
	return prediction:window().inventory
end

function ClientInventory.isCreative(): boolean
	return isCreative()
end

-- The selected hotbar slot, 1..9.
function ClientInventory.selected(): number
	return prediction:window().inventory.selected
end

-- The stack in the selected hotbar slot (the item in hand).
function ClientInventory.selectedStack(): Types.Stack?
	local inventory = prediction:window().inventory
	local stack = inventory.slots[inventory.selected]
	if stack == nil or stack.count < 1 then
		return nil
	end
	return stack
end

-- Predicts an action and sends it to the server. (`place` goes through ClientInventory.place.)
function ClientInventory.apply(action: Types.Action)
	if action.kind == "place" then
		ClientInventory.place(action.item)
		return
	end
	local seq = prediction:push(action, isCreative())
	ClientNet.send(Protocol.ClientMessage.Inventory, Protocol.encodeInventoryAction(seq, action))
	notify()
end

-- Selects hotbar slot 1..9.
function ClientInventory.select(slot: number)
	if slot >= 1 and slot <= Types.HOTBAR_SIZE and slot ~= ClientInventory.selected() then
		ClientInventory.apply({ kind = "select", slot = slot })
	end
end

-- Throws one of the held item (Q), or the whole stack (Ctrl+Q).
function ClientInventory.dropSelected(all: boolean)
	if ClientInventory.selectedStack() then
		ClientInventory.apply({ kind = "drop", all = all })
	end
end

--[[
	A block of the held item is being placed: predicts one being used up (survival) and returns the
	action number for Protocol.encodeEdit, which carries it to the server.
]]
function ClientInventory.place(item: number): number
	local seq = prediction:push({ kind = "place", item = item }, isCreative())
	notify()
	return seq
end

-- Minecraft's pick block (middle click on a block): selects or fetches its item.
function ClientInventory.pickBlock(block: number)
	local item = Items.ofBlock(block)
	if item == nil then
		return
	end
	for _, action in Menu.pickBlock(ClientInventory.inventory(), item, isCreative()) do
		ClientInventory.apply(action)
	end
end

return ClientInventory
