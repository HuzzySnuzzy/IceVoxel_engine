--!strict
--[[
	Players' inventories on the server: the authority. The rules live in Players/InventoryState
	(pure) and Inventory/Menu; this module connects them to the game.

	  Actions    Inventory messages (numbered by the client) run in arrival order; what they throw
	             out (Q, clicks outside the screen) flies off in front of the player as item
	             entities (Entities.throwFromPlayer). Creative players conjure items, so their
	             throws are rate limited (the extra ones vanish).
	  Modes      what a player's game mode allows (InventoryState.applyAs, Menu.allows):
	             spectators only select hotbar slots and close windows (every other action is
	             acknowledged without a change, so the snapshot undoes the client's prediction),
	             the creative actions are creative only, adventure is survival. Spectators pick
	             nothing up, keep everything when they die and are no chest's opener (no lid).
	  Windows    a Use message on a block with a menu (Blocks `menu`: a chest, a furnace, a crafting
	             table) within reach opens it in a new window, in every game mode (spectators read
	             only: Minecraft's ServerPlayerGameMode.useItemOn opens their MenuProvider). One at
	             a time: opening another closes the first. Menus with a handler of their own
	             (`onMenu`: structure blocks and jigsaws, Structures/StructureBlocks, which only
	             creative players may use) go there instead. A window closes when the
	             player walks away (more than Config.Interaction.Reach + 2 blocks, checked a few
	             times a second), when the block stops being that block, when they die and when
	             they leave. When the block goes, a container's contents drop
	             (Entities.dropContents) and every user's window closes (`removeContainer`, called
	             by ServerNet when a player breaks it and by `blockChanged` for any other change);
	             a crafting table's grid goes back into its user's inventory.
	  Furnaces   cook 20 times a second whether anyone looks or not (Containers.tickFurnaces, on a
	             fixed step that catches up at most a few ticks per frame). Any action in a furnace
	             window marks that furnace active. Its viewers get a snapshot at once when its slots
	             change, and every other tick when only the flame or the arrow moved. Every 10 ticks
	             a furnace with results pushes them into the chests next to it (Transmitters/Eject,
	             Mekanism's ejector; blocks read without generating terrain, as the pipes do).
	             Results that leave on their own so (or by a pipe) count as smelted for the player
	             who last used the furnace's window (`resultsTaken`: Progression).
	  Tools      ServerNet times and harvests breaks with `heldTool` and wears the tool with
	             `wearTool` (InventoryState.wearHeld: at its durability it breaks), less with
	             Progression's wear perks (`setWearFilter`).
	  Placing    ServerNet asks `place` before putting a block down: survival players use up the held
	             item; refused edits are still acknowledged so the client's prediction is undone.
	             It hands ServerNet the stack the block came from (data intact), for the sustained
	             data hooks (a Fluid Tank placed from an item with water gets its water back).
	  Pickups    item entities that touch a player go into the inventory (Entities' pickup handler;
	             never a spectator's: GameModeRules.picksUp).
	  Using      Players/ItemUse (buckets) reads the held stack (`heldStack`, `hasItem`), replaces it
	             (`setHeld`) and hands stacks over (`give`: what does not fit is thrown).
	  Pipes      Mekanism's transporters put items into chests and furnaces and take them out
	             (Transmitters/Transport, through Containers), and furnaces and machines push their
	             results into chests (Transmitters/Eject); `containerChanged` then sends the
	             viewers a snapshot and lets a furnace cook.
	  Death      everything drops where the player died (scattered), unless
	             Config.Gameplay.KeepInventory or they were spectating (GameModeRules.keepsInventory).
	  Snapshots  a player whose inventory changed (their own actions, pickups, a viewer of the same
	             chest clicking, a furnace cooking, tool wear, opening, closing) gets one snapshot
	             per frame at most, and one on joining and respawning.
	  Sounds     everyone near hears (Audio/Sounds): a chest's lid open for its first viewer and
	             close after its last (Containers' onOpeners), armor put on by an inventory action
	             (Shared/Sounds.equip, at the player) and a tool wearing out (entity.item.break).
	             Lids and armor that a player's messages cause use up that player's sound budget
	             (Audio/Sounds.allow), so spamming them can't flood the players near.

	Saved      a saved world keeps every player's inventory (World/WorldSave reads it through
	           `get`, and puts a returning player's back with `restore`).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Blocks = require(Shared.Blocks)
local ChunkLayout = require(Shared.World.ChunkLayout)
local Coords = require(Shared.World.Coords)
local GameMode = require(Shared.GameMode)
local Protocol = require(Shared.Net.Protocol)
local SharedSounds = require(Shared.Sounds)
local Types = require(Shared.Inventory.Types)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local Entities = require(script.Parent.Parent.Entities.Entities)
local Containers = require(script.Parent.Containers)
local InventoryState = require(script.Parent.InventoryState)
local Sounds = require(script.Parent.Parent.Audio.Sounds)
local Eject = require(script.Parent.Parent.Transmitters.Eject)
local GameModeRules = require(script.Parent.GameModeRules)
local PlayerPositions = require(script.Parent.PlayerPositions)

type Stack = Types.Stack

local HEIGHT = Config.WorldHeight
-- Seconds between the checks that close chests players walked away from.
local CHECK_INTERVAL = 0.25
-- Furnace ticks per second (Minecraft's), the most run in one frame (a hitch does not
-- fast-forward them), and the ticks between snapshots for a furnace whose slots did not change.
local FURNACE_TICK = 1 / 20
local MAX_FURNACE_TICKS_PER_FRAME = 4
local FURNACE_DATA_INTERVAL = 2
-- Stacks a creative player may put into the world per second (throws, chests they break), like
-- Minecraft's creative drop spam limit, and how many at once (a full chest is 27).
local CREATIVE_STACKS_PER_SECOND = 10
local CREATIVE_STACKS_BURST = 64

local Inventories = {}

local state = InventoryState.new(Containers.default)
local started = false
-- The player whose message is being handled (Use, Inventory), whose sound budget a chest lid it
-- opens or closes uses up (Audio/Sounds.allow); nil for the server's own closes.
local actor: Player? = nil
-- Whether a dying player keeps everything besides the keepInventory rule (`setKeepRule`).
local keepRule: ((player: Player) -> boolean)? = nil
-- Creative throw budget per player.
local throwBudget: { [Player]: { tokens: number, last: number } } = {}

local function isAlive(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

-- Is block (x, y, z) within reach of the player (as ServerNet checks edits: Players/PlayerPositions)?
local function withinReach(player: Player, x: number, y: number, z: number): boolean
	return PlayerPositions.inReach(player, x, y, z)
end

-- Takes `cost` stacks from a creative (instabuild) player's budget (the other modes only drop what
-- they have).
local function mayCreate(player: Player, cost: number): boolean
	if not GameMode.instabuildOf(player) or cost <= 0 then
		return true
	end
	local now = os.clock()
	local budget = throwBudget[player]
	if budget == nil then
		budget = { tokens = CREATIVE_STACKS_BURST, last = now }
		throwBudget[player] = budget
	end
	budget.tokens = math.min(CREATIVE_STACKS_BURST, budget.tokens + (now - budget.last) * CREATIVE_STACKS_PER_SECOND)
	budget.last = now
	if budget.tokens < cost then
		return false
	end
	budget.tokens -= cost
	return true
end

local function mayThrow(player: Player): boolean
	return mayCreate(player, 1)
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
	Creative: nothing is used. Returns false to refuse the edit, and the stack the block came from
	as it was before (data intact; nil when the hand holds something else). Acknowledges `seq`
	either way.
]]
function Inventories.place(player: Player, block: number, seq: number): (boolean, Stack?)
	return state:place(player, block, seq, GameMode.instabuildOf(player))
end

-- Acknowledges inventory action `seq` (a refused placement), so the client undoes its prediction.
function Inventories.acknowledge(player: Player, seq: number)
	state:acknowledge(player, seq)
end

--[[
	A saved player's inventory comes back (World/WorldSave: InventoryState.restore); what did not
	fit is thrown in front of them.
]]
function Inventories.restore(
	player: Player,
	slots: { [number]: Stack? },
	armor: { [number]: Stack? },
	selected: number,
	cursor: Stack?
)
	throw(player, state:restore(player, slots, armor, selected, cursor), false)
end

--[[
	A saved character's equipment comes back (Terraria's accessories, vanity and hidden looks:
	InventoryState.restoreEquipment), beside `restore`'s slots and armor.
]]
function Inventories.restoreEquipment(player: Player, equipment: Types.Equipment)
	state:restoreEquipment(player, equipment)
end

--[[
	Whether a dying player keeps their inventory besides the keepInventory game rule (nil: only the
	rule): server Players/CharacterStore's difficulty (a Classic character keeps everything).
]]
function Inventories.setKeepRule(rule: ((player: Player) -> boolean)?)
	keepRule = rule
end

-- Sends the player a snapshot this frame.
function Inventories.markDirty(player: Player)
	state:markDirty(player)
end

-- The item in the player's hand (nil = empty hand), for ServerNet's mining rules.
function Inventories.heldTool(player: Player): number?
	local held = state:heldStack(player)
	return if held then held.item else nil
end

-- The stack in the player's hand (nil = empty hand). Read only.
function Inventories.heldStack(player: Player): Stack?
	return state:heldStack(player)
end

-- Replaces the stack in the player's hand (nil empties it); the player gets a snapshot.
function Inventories.setHeld(player: Player, stack: Stack?)
	state:setHeld(player, stack)
end

-- Puts `stack` into the player's inventory; what does not fit is thrown in front of them.
function Inventories.give(player: Player, stack: Stack)
	local left = state:give(player, stack)
	if left then
		Entities.throwFromPlayer(player, left, false)
	end
end

-- Does the player have `item` in their inventory or armor (Minecraft's Inventory.contains)?
function Inventories.hasItem(player: Player, item: number): boolean
	return state:has(player, item)
end

--[[
	Something other than a viewer changed the slots of the chest or furnace at (x, y, z) (a
	transporter put items in or took them out): its viewers get a snapshot and a furnace is ticked
	again (it may have something to cook now).
]]
function Inventories.containerChanged(x: number, y: number, z: number)
	for _, viewer in Containers.default:viewers(x, y, z) do
		state:markDirty(viewer)
	end
	Containers.default:markActive(x, y, z)
end

-- Of `amount` wear points on a player's tool, those that land (Progression's Smithing; set by the
-- server script: Players/Progression.wear). nil: all of them.
local wearFilter: ((player: Player, amount: number) -> number)? = nil

function Inventories.setWearFilter(filter: ((player: Player, amount: number) -> number)?)
	wearFilter = filter
end

--[[
	Results that leave a furnace's or machine's output on their own (Transmitters/Eject pushing
	them into a chest, a pipe pulling them: their envs' `resultsTaken`) go to the results handler
	(Progression's smelting knowledge; set by the server script) for the player who last used that
	furnace's window, as if they had taken them out themselves: Minecraft's furnace keeps what it
	smelted for a player even when a hopper empties it. Without it a furnace next to a chest would
	never count as smelting (the Iron Age's "Smelt an Iron Ingot").
]]
local resultsHandler: ((player: Player, stack: Stack) -> ())? = nil
-- The player who last acted in each furnace's or machine's window (weak: gone with the container).
local lastUsers: { [Types.Container]: Player } = setmetatable({}, { __mode = "k" }) :: any

function Inventories.setResultsHandler(handler: ((player: Player, stack: Stack) -> ())?)
	resultsHandler = handler
end

function Inventories.resultsTaken(_x: number, _y: number, _z: number, container: Types.Container, stack: Stack)
	local user = lastUsers[container]
	local handler = resultsHandler
	if user and handler and user.Parent then
		handler(user, stack)
	end
end

-- The tool in the player's hand was used `amount` times (ServerNet's breaks); at its durability it
-- breaks, which everyone near hears (the owner too: clients don't predict wear). The wear
-- filter (perks) may skip some of it.
function Inventories.wearTool(player: Player, amount: number)
	local filter = wearFilter
	if filter then
		amount = filter(player, amount)
	end
	if amount >= 1 and state:wearHeld(player, amount) then
		Sounds.playAt(player, "entity.item.break")
	end
end

--[[
	May `player` break the container at (x, y, z) now? A creative player's break spills items made
	from nothing, so each stack in it costs one from their creative budget (if it is short, the
	chest stays, contents and all).
]]
function Inventories.mayRemoveContainer(player: Player, x: number, y: number, z: number): boolean
	local container = Containers.default:peek(x, y, z)
	if container == nil then
		return true
	end
	local stacks = 0
	for slot = 1, container.size do
		if container.slots[slot] then
			stacks += 1
		end
	end
	return mayCreate(player, stacks)
end

--[[
	The block with a window at (x, y, z) is gone (broken or replaced): a container's contents drop
	there and every user's window closes (their cursors and crafting grids go back into their
	inventories, what does not fit is thrown). Safe to call for any block and more than once.
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
	For WorldServer.onChanged: a block with a window replaced by anything (by players, block updates
	or the Api) drops its contents and closes for its users.
]]
function Inventories.blockChanged(x: number, y: number, z: number, old: number, new: number)
	if old ~= new and Blocks.isValid(old) and Blocks.get(old).menu ~= nil then
		Inventories.removeContainer(x, y, z)
	end
end

-- Closes the player's open container (or screen), returning the cursor to the inventory.
local function closeFor(player: Player)
	throw(player, state:close(player), false)
end

-- Closes windows their users walked away from (or died near), and those whose block changed (a
-- crafting table's grid remembers the table's block id too).
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

-- Screens other parts of the server open (Blocks `menu` -> handler): structure blocks and jigsaws.
local menuHandlers: { [string]: (player: Player, x: number, y: number, z: number, block: number) -> () } = {}

--[[
	A Use on a block whose `menu` is `menu` (one with no window: "StructureBlock", "Jigsaw") goes
	to `handler` instead (Structures/StructureBlocks answers it like an open request).
]]
function Inventories.onMenu(
	menu: string,
	handler: (player: Player, x: number, y: number, z: number, block: number) -> ()
)
	menuHandlers[menu] = handler
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
	if not Blocks.isValid(block) or Blocks.get(block).menu == nil then
		return
	end
	local handler = menuHandlers[Blocks.get(block).menu :: string]
	if handler then
		handler(player, x, y, z, block)
		return
	end
	-- (Spectators look in read only, and open no chest lid.)
	actor = player
	local thrown = state:open(player, x, y, z, block, not GameModeRules.opensContainers(GameMode.of(player)))
	actor = nil
	throw(player, thrown, false)
end

local function onInventory(player: Player, payload: buffer)
	local seq, action = Protocol.decodeInventoryAction(payload)
	if seq == nil or action == nil then
		return
	end
	-- An action in a furnace window may give it something to cook or burn.
	local window = state:window(player)
	local container = window and window.container
	local fx, fy, fz = state:openPosition(player)
	-- (The armor as it was, to hear what the action put on.)
	local armor: { [number]: Stack? } = {}
	if window then
		for slot = 1, Types.ARMOR_SIZE do
			armor[slot] = window.inventory.armor[slot]
		end
	end
	actor = player
	local thrown = state:applyAs(player, seq, action, GameMode.of(player))
	actor = nil
	throw(player, thrown, false)
	if fx ~= nil and container and container.kind == "furnace" then
		Containers.default:markActive(fx, fy, fz)
	end
	if container and (container.kind == "furnace" or container.kind == "machine") then
		lastUsers[container] = player
	end
	if window then
		for slot = 1, Types.ARMOR_SIZE do
			local sound = SharedSounds.equip(armor[slot], window.inventory.armor[slot])
			if sound and Sounds.allow(player) then
				Sounds.playAt(player, sound)
			end
		end
	end
end

-- Marks every viewer of the container at (x, y, z) for a snapshot.
local function markViewers(x: number, y: number, z: number)
	for _, viewer in Containers.default:viewers(x, y, z) do
		state:markDirty(viewer)
	end
end

--[[
	One furnace tick for every active furnace. Viewers see changed slots at once; changes to the
	flame and the arrow alone wait for every FURNACE_DATA_INTERVAL-th tick (`pending` keeps them).
	Every Eject.INTERVAL-th tick the furnaces with results push them into the chests next to them
	(`eject`: their viewers and the chests' get snapshots through containerChanged).
]]
local function tickFurnaces(tick: number, pending: { [string]: Containers.FurnaceChange }, eject: Eject.Env)
	if tick % Eject.INTERVAL == 0 then
		Eject.furnaces(eject)
	end
	for _, change in Containers.default:tickFurnaces() do
		local key = `{change.x},{change.y},{change.z}`
		if change.slots then
			pending[key] = nil
			markViewers(change.x, change.y, change.z)
		else
			pending[key] = change
		end
	end
	if tick % FURNACE_DATA_INTERVAL == 0 then
		for key, change in pending do
			pending[key] = nil
			markViewers(change.x, change.y, change.z)
		end
	end
end

local function onCharacter(player: Player, character: Model)
	-- A respawned player's client gets the state again (its screens closed with the old body).
	state:markDirty(player)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.Died:Connect(function()
			local keep = GameModeRules.keepsInventory(GameMode.of(player), Config.Gameplay.KeepInventory)
				or (keepRule ~= nil and keepRule(player))
			throw(player, state:die(player, keep), true)
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

	-- Chest lids: open for the first viewer, closed after the last (the block's menu decides).
	Containers.default.onOpeners = function(
		x: number,
		y: number,
		z: number,
		container: Types.Container,
		opened: boolean
	)
		local sound = SharedSounds.container(container.block, opened)
		local by = actor
		if sound and (by == nil or Sounds.allow(by)) then
			Sounds.play(sound, x + 0.5, y + 0.5, z + 0.5)
		end
	end

	net.on(Protocol.ClientMessage.Inventory, onInventory)
	net.on(Protocol.ClientMessage.Use, function(player: Player, payload: buffer)
		onUse(world, player, payload)
	end)
	Entities.setPickupHandler(function(player: Player, stack: Stack): number
		if not GameModeRules.picksUp(GameMode.of(player)) then
			return 0
		end
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

	-- Furnaces' results into the chests next to them. Blocks without generating terrain: chests
	-- and furnaces only ever come from edits, so a chunk the server has not generated is read
	-- from its edit list (nil: generated terrain, no chest), as the pipes read it.
	local eject: Eject.Env = {
		getBlock = function(x: number, y: number, z: number): number?
			local block = world:peekBlock(x, y, z)
			if block ~= nil then
				return block
			elseif y < 0 or y >= HEIGHT then
				return nil
			end
			local cx, cz, lx, lz = Coords.blockToChunk(x, z)
			local edits = world:chunkEdits(cx, cz)
			return if edits then edits[ChunkLayout.localIndex(lx, y, lz)] else nil
		end,
		containers = Containers.default,
		inventoryChanged = Inventories.containerChanged,
		resultsTaken = Inventories.resultsTaken,
	}

	local sinceCheck = 0
	local furnaceTime = 0
	local furnaceTicks = 0
	local furnacePending: { [string]: Containers.FurnaceChange } = {}
	RunService.Heartbeat:Connect(function(dt)
		furnaceTime = math.min(furnaceTime + dt, FURNACE_TICK * MAX_FURNACE_TICKS_PER_FRAME)
		while furnaceTime >= FURNACE_TICK do
			furnaceTime -= FURNACE_TICK
			furnaceTicks += 1
			tickFurnaces(furnaceTicks, furnacePending, eject)
		end
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
