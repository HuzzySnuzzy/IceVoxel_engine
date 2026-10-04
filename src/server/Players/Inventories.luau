--!strict
--[[
	Players' inventories on the server: the authority. The rules live in Players/InventoryState
	(pure) and Inventory/Menu; this module connects them to the game.

	  Actions    Inventory messages (numbered by the client) run in arrival order; what they throw
	             out (Q, clicks outside the screen) flies off in front of the player as item
	             entities (Entities.throwFromPlayer). Creative players conjure items, so their
	             throws are rate limited (the extra ones vanish).
	  Chests     a Use message on a container block within reach opens it in a new window (one at a
	             time; opening another closes the first). It closes when the player walks away
	             (more than Config.Interaction.Reach + 2 blocks, checked a few times a second), when
	             the block stops being that container, when they die and when they leave. When the
	             block goes, its contents drop (Entities.dropContents) and every viewer's window
	             closes (`removeContainer`, called by ServerNet when a player breaks it).
	  Placing    ServerNet asks `place` before putting a block down: survival players use up the held
	             item; refused edits are still acknowledged so the client's prediction is undone.
	  Pickups    item entities that touch a player go into the inventory (Entities' pickup handler).
	  Death      everything drops where the player died (scattered), unless
	             Config.Gameplay.KeepInventory.
	  Snapshots  a player whose inventory changed (their own actions, pickups, a viewer of the same
	             chest clicking, opening, closing) gets one snapshot per frame at most, and one on
	             joining and respawning.

	Inventories last for the session: nothing is saved.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Blocks = require(Shared.Blocks)
local GameMode = require(Shared.GameMode)
local Protocol = require(Shared.Net.Protocol)
local Types = require(Shared.Inventory.Types)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local Entities = require(script.Parent.Parent.Entities.Entities)
local Containers = require(script.Parent.Containers)
local InventoryState = require(script.Parent.InventoryState)

type Stack = Types.Stack

local BLOCK = Config.BlockSize
local HEIGHT = Config.WorldHeight
-- Seconds between the checks that close chests players walked away from.
local CHECK_INTERVAL = 0.25
-- Creative throws per second (and burst), like Minecraft's creative drop spam limit.
local CREATIVE_THROWS_PER_SECOND = 10

local Inventories = {}

local state = InventoryState.new(Containers.default)
local started = false
-- Creative throw budget per player.
local throwBudget: { [Player]: { tokens: number, last: number } } = {}

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function isAlive(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

-- Is block (x, y, z) within reach of the player (as ServerNet checks edits)?
local function withinReach(player: Player, x: number, y: number, z: number): boolean
	local root = rootOf(player)
	if root == nil then
		return false
	end
	local center = Vector3.new((x + 0.5) * BLOCK, (y + 0.5) * BLOCK, (z + 0.5) * BLOCK)
	return (root.Position - center).Magnitude <= (Config.Interaction.Reach + 2) * BLOCK
end

local function mayThrow(player: Player): boolean
	if not GameMode.isCreative(player) then
		-- Survival players only throw what they have.
		return true
	end
	local now = os.clock()
	local budget = throwBudget[player]
	if budget == nil then
		budget = { tokens = CREATIVE_THROWS_PER_SECOND, last = now }
		throwBudget[player] = budget
	end
	local rate = CREATIVE_THROWS_PER_SECOND
	budget.tokens = math.min(rate, budget.tokens + (now - budget.last) * rate)
	budget.last = now
	if budget.tokens < 1 then
		return false
	end
	budget.tokens -= 1
	return true
end

-- Stacks leaving a player: thrown forwards, or scattered (death).
local function throw(player: Player, stacks: { Stack }, scatter: boolean)
	for _, stack in stacks do
		if scatter or mayThrow(player) then
			Entities.throwFromPlayer(player, stack, scatter)
		end
	end
end

-- The player's window (read only; nil before they joined).
function Inventories.get(player: Player): Types.Window?
	return state:window(player)
end

--[[
	A player places `block` (their inventory action `seq`, from the Edit message), after every
	other check passed. Survival: the held stack must be the block's item; one is used up.
	Creative: nothing is used. Returns false to refuse the edit. Acknowledges `seq` either way.
]]
function Inventories.place(player: Player, block: number, seq: number): boolean
	return state:place(player, block, seq, GameMode.isCreative(player))
end

-- Acknowledges inventory action `seq` (a refused placement), so the client undoes its prediction.
function Inventories.acknowledge(player: Player, seq: number)
	state:acknowledge(player, seq)
end

-- Sends the player a snapshot this frame.
function Inventories.markDirty(player: Player)
	state:markDirty(player)
end

--[[
	The container block at (x, y, z) is gone (broken or replaced): its contents drop there and
	every viewer's window closes. Safe to call for any block and more than once.
]]
function Inventories.removeContainer(x: number, y: number, z: number)
	local contents, leftovers = state:removeContainer(x, y, z)
	for _, stack in contents do
		Entities.dropContents(x, y, z, stack)
	end
	for _, entry in leftovers do
		throw(entry.key :: Player, entry.stacks, false)
	end
end

--[[
	For WorldServer.onChanged: a container block replaced by anything (by players, block updates
	or the Api) drops its contents.
]]
function Inventories.blockChanged(x: number, y: number, z: number, old: number, new: number)
	if old ~= new and Blocks.isValid(old) and Blocks.get(old).container > 0 then
		Inventories.removeContainer(x, y, z)
	end
end

-- Closes the player's open container (or screen), returning the cursor to the inventory.
local function closeFor(player: Player)
	throw(player, state:close(player), false)
end

-- Closes chests their viewers walked away from (or died near), and chests whose block changed.
local function checkOpenContainers(world: WorldServer.World)
	for _, player in Players:GetPlayers() do
		local x, y, z = state:openPosition(player)
		if x ~= nil then
			local window = state:window(player)
			local container = window and window.container
			local block = world:peekBlock(x, y, z)
			if container and block ~= nil and block ~= container.block then
				Inventories.removeContainer(x, y, z)
			elseif not isAlive(player) or not withinReach(player, x, y, z) then
				closeFor(player)
			end
		end
	end
end

local function onUse(world: WorldServer.World, player: Player, payload: buffer)
	local x, y, z = Protocol.decodeUse(payload)
	if
		x == nil
		or y >= HEIGHT
		or math.abs(x) > Protocol.MAX_COORDINATE
		or math.abs(z) > Protocol.MAX_COORDINATE
		or not isAlive(player)
		or not withinReach(player, x, y, z)
	then
		return
	end
	-- Within reach, so the chunk is around the player already.
	local block = world:getBlock(x, y, z)
	if not Blocks.isValid(block) or Blocks.get(block).container <= 0 then
		return
	end
	throw(player, state:open(player, x, y, z, block), false)
end

local function onInventory(player: Player, payload: buffer)
	local seq, action = Protocol.decodeInventoryAction(payload)
	if seq == nil or action == nil then
		return
	end
	throw(player, state:apply(player, seq, action, GameMode.isCreative(player)), false)
end

local function onCharacter(player: Player, character: Model)
	-- A respawned player's client gets the state again (its screens closed with the old body).
	state:markDirty(player)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.Died:Connect(function()
			throw(player, state:die(player, Config.Gameplay.KeepInventory), true)
		end)
	end
end

local function onPlayer(player: Player)
	state:join(player)
	player.CharacterAdded:Connect(function(character)
		onCharacter(player, character)
	end)
	if player.Character then
		task.spawn(onCharacter, player, player.Character)
	end
end

-- Starts handling inventories. Entities.start must have run (drops and pickups).
function Inventories.start(net: ServerNet.ServerNet, world: WorldServer.World)
	assert(not started, "Inventories.start was already called")
	started = true

	net.on(Protocol.ClientMessage.Inventory, onInventory)
	net.on(Protocol.ClientMessage.Use, function(player: Player, payload: buffer)
		onUse(world, player, payload)
	end)
	Entities.setPickupHandler(function(player: Player, stack: Stack): number
		return state:pickup(player, stack)
	end)

	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		state:leave(player)
		throwBudget[player] = nil
	end)

	local sinceCheck = 0
	RunService.Heartbeat:Connect(function(dt)
		sinceCheck += dt
		if sinceCheck >= CHECK_INTERVAL then
			sinceCheck = 0
			checkOpenContainers(world)
		end
		for _, key in state:takeDirty() do
			local player = key :: Player
			local snapshot = state:snapshot(player)
			if snapshot and player.Parent then
				net.send(player, Protocol.ServerMessage.Inventory, Protocol.encodeInventory(snapshot))
				-- What is in the player's hand, for every client to draw (Player/HeldItems).
				local inventory = snapshot.inventory
				local held = inventory.slots[inventory.selected]
				local item = if held then held.item else 0
				if player:GetAttribute(Types.HELD_ATTRIBUTE) ~= item then
					player:SetAttribute(Types.HELD_ATTRIBUTE, item)
				end
			end
		end
	end)
end

return Inventories
