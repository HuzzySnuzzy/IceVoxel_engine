--!strict
--[[
	Server side of the protocol (see Shared/Net/Protocol).

	  * Answers chunk edit requests (clients ask for the edit list of every full detail chunk they
	    build; terrain itself is generated locally). Right after the edit lists, the `chunksSent`
	    rule sends what else those chunks hold (Mekanism transmitters' and fluid tanks' states:
	    Transmitters/Transmitters), so a client always has a chunk's blocks before their state.
	  * Validates block edit requests: rate limit, reach, breakable / placeable, what an attached
	    block (torch, lantern) hangs on or a plant stands on, room for a tall plant's top, not
	    inside a player (solid blocks and lanterns, not torches or plants: EditRules.obstructs).
	    Creative only blocks (structure blocks, structure voids, jigsaws) are placed and broken
	    only by players the `operator` rule allows (Structures/Permission: creative, and
	    Config.Structures.Permission, Config.Gameplay.Admins, the owner or Studio;
	    EditRules.mayUseCreativeOnly), and nobody places a cave twin (generation's glow lichen).
	    Rejected requests are answered with the real block so the client undoes its prediction.
	  * Tall plants (EditRules): placing the lower half also sets the upper half, and breaking
	    either half removes both, with one drop (the lower half's, with the breaker's tool), one
	    sound and one wear. The client predicts only the half it touched; the other half comes as
	    an ordinary replicated edit.
	  * Applies the game modes' rules to edits (Network/EditRules, Shared/GameMode's abilities):
	      survival   a block breaks only once the player has mined it long enough with the tool in
	                 their hand when the break arrives (Mine messages say when they started;
	                 Mining.mayBreak), drops what that tool harvests (Items.drops: stone by hand
	                 drops nothing) and wears the tool (Mining.wear); placing uses up the held item
	                 (Players/Inventories.place, just before the block is set). A refused placement
	                 is still acknowledged, so the client's predicted use is undone.
	      creative   (instabuild) instant breaking, no drops, nothing used up or worn.
	      adventure  no breaking or placing at all (EditRules.mayEdit: Minecraft's mayBuild): every
	                 edit is answered with the real block, Mine messages are ignored.
	      spectator  the same, and never in the way of a placement (EditRules.blocksPlacing).
	    A broken container drops its contents in every mode, and any block with a window (chest,
	    furnace, crafting table) closes it for everyone using it.
	  * Sustained data (Mekanism): parts of the server that keep blocks' state (Transmitters: a
	    Fluid Tank's water) register hooks with `addBlockData` (EditRules.newBlockData). A
	    survival break that drops the block's own item puts the data `save` read just before the
	    block went on it; a placement hands the stack it came from (as `place` returned it, data
	    intact, before the item was used up) to every `placed` hook right after setBlock.
	  * Knowledge (Players/Progression, through `setRules`): a survival break's `mined` rule says
	    whether the block had been placed (EditRules.placed, read before it goes), and every
	    mining time check takes the player's own speed (`miningFactor`: the perks), as the
	    client's mining does.
	  * Broadcasts all world changes once per frame.
	  * Plays the sounds of players' breaks and placements to everyone near but that player, whose
	    client already played them (Audio/Sounds; Minecraft's levelEvent 2001 and place sound).

	The inventory and item entity sides come in through `setRules` (the server script wires
	Players/Inventories and Entities), so ServerNet requires neither of them. Its `dropBlock` rule
	also goes to Behaviours/Drops, so block updates (a torch losing its wall, a plant its soil,
	water washing one away) drop items the same way.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Protocol = require(Shared.Net.Protocol)
local Remotes = require(Shared.Net.Remotes)
local Rig = require(Shared.Movement.Rig)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local Drops = require(script.Parent.Parent.Behaviours.Drops)
local Sounds = require(script.Parent.Parent.Audio.Sounds)
local EditRules = require(script.Parent.EditRules)
local Mining = require(Shared.Mining)

type World = WorldServer.World

local BLOCK = Config.BlockSize
local HEIGHT = Config.WorldHeight
local EDITS_PER_MESSAGE = 4096
local CHUNK_REQUESTS_PER_SECOND = 1500
-- A break that arrived early is finished within this many seconds or undone.
local DELAY_LIMIT = 1

local ClientMessage = Protocol.ClientMessage
local ServerMessage = Protocol.ServerMessage
local EditAction = Protocol.EditAction

local EMPTY: { [number]: number } = {}

-- Token bucket per player and kind of request.
type Bucket = { tokens: number, last: number }

local function take(bucket: Bucket, rate: number, cost: number): boolean
	local now = os.clock()
	bucket.tokens = math.min(rate * 2, bucket.tokens + (now - bucket.last) * rate)
	bucket.last = now
	if bucket.tokens < cost then
		return false
	end
	bucket.tokens -= cost
	return true
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- Would `block` at (x, y, z) overlap any player's (standing) movement hull (EditRules.obstructs)?
-- Spectators are never in the way (EditRules.blocksPlacing).
local function intersectsCharacter(block: number, x: number, y: number, z: number): boolean
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character and EditRules.blocksPlacing(GameMode.of(player)) then
			local min, max = Rig.hull(character)
			if min and max and EditRules.obstructs(block, x, y, z, min.X, min.Y, min.Z, max.X, max.Y, max.Z) then
				return true
			end
		end
	end
	return false
end

export type Handler = (player: Player, payload: buffer) -> ()

-- The game's side of block edits. All optional: without them edits change no inventory and drop
-- nothing.
export type Rules = {
	-- A placement passed every block check: use up the held item (survival) and acknowledge
	-- inventory action `seq`. false refuses the edit; the second result is the stack the block
	-- came from, before it was used up (data intact), for the `placed` hooks.
	-- (Players/Inventories.place)
	place: ((player: Player, block: number, seq: number) -> (boolean, Items.Stack?))?,
	-- A refused placement: acknowledge `seq` so the client undoes its predicted use.
	-- (Players/Inventories.acknowledge)
	acknowledge: ((player: Player, seq: number) -> ())?,
	-- Drops a survival player's broken block as an item entity (Entities.dropBlock). Block
	-- behaviours use it too (Behaviours/Drops: torches popping off, washed away).
	dropBlock: ((x: number, y: number, z: number, stack: Items.Stack) -> ())?,
	-- A block with a window (chest, furnace, crafting table) was broken: drop its contents and
	-- close it for everyone using it. (Players/Inventories.removeContainer)
	removeContainer: ((x: number, y: number, z: number) -> ())?,
	-- May this player break the container at (x, y, z) now? (Creative players make items from
	-- nothing, so what a chest spills is charged to their budget: Players/Inventories.)
	mayRemoveContainer: ((player: Player, x: number, y: number, z: number) -> boolean)?,
	-- The item in the player's hand (nil = empty): the tool their mining is timed and harvested
	-- with. (Players/Inventories.heldTool)
	heldTool: ((player: Player) -> number?)?,
	-- Wears the tool in the player's hand by `amount` (it breaks at its durability).
	-- (Players/Inventories.wearTool)
	wearTool: ((player: Player, amount: number) -> ())?,
	-- A player who is no instabuilder broke `block` (Tough As Nails' thirst: Minecraft's
	-- EXHAUSTION_MINE). (Players/ToughAsNails.blockBroken)
	broke: ((player: Player, block: number) -> ())?,
	-- A player who is no instabuilder broke `block` at (x, y, z); `placed`: it was put there after
	-- generation (EditRules.placed, read before it went). (Players/Progression.mined: knowledge)
	mined: ((player: Player, block: number, x: number, y: number, z: number, placed: boolean) -> ())?,
	-- The player's own mining speed with `tool` in hand (1 without; Progression's perks:
	-- Players/Progression.miningFactor), for every timing check (Mining's `factor`).
	miningFactor: ((player: Player, tool: number?) -> number)?,
	-- The player was just sent the edit lists of chunks `coords` ({ cx, cz } each): send them the
	-- state those chunks hold beyond their blocks (Transmitters/Transmitters.sendChunks).
	chunksSent: ((player: Player, coords: { { number } }) -> ())?,
	-- May the player place and break creative only blocks (structure blocks, structure voids,
	-- jigsaws; Structures/StructureBlocks.operator: creative, and Config.Structures.Permission,
	-- Config.Gameplay.Admins, the owner or Studio)? Without it: creative (instabuild) players may.
	operator: ((player: Player) -> boolean)?,
}

export type ServerNet = {
	-- Broadcasts the world changes made since the last call (once per frame).
	flush: () -> (),
	-- Registers the handler for a client message type (Protocol.ClientMessage).
	on: (kind: number, handler: Handler) -> (),
	-- Sends a message to one player.
	send: (player: Player, kind: number, payload: buffer) -> (),
	-- Sets the inventory / item entity side of edits (replaces the earlier rules).
	setRules: (rules: Rules) -> (),
	-- Adds a part of the server's sustained data hooks (EditRules.BlockDataHooks: what a block
	-- keeps in its item when broken, and getting it back when placed). Hooks stay for good.
	addBlockData: (hooks: EditRules.BlockDataHooks) -> (),
}

local ServerNet = {}

function ServerNet.start(world: World): ServerNet
	local remote = Remotes.net()
	local editBuckets: { [Player]: Bucket } = {}
	local chunkBuckets: { [Player]: Bucket } = {}
	-- The block each survival player is mining (Mine messages; EditRules.minesOverTime).
	local mining: { [Player]: EditRules.Mine } = {}
	-- A survival break that arrived before its time (network jitter): finished once the time has
	-- passed, like Minecraft's delayed destroy (ServerPlayerGameMode.hasDelayedDestroy). `tool` is
	-- what the player held when the break arrived (its timing and drops).
	type DelayedBreak = {
		x: number,
		y: number,
		z: number,
		block: number,
		startedAt: number,
		expires: number,
		tool: number?,
	}
	local delayed: { [Player]: DelayedBreak } = {}
	local rules: Rules = {}
	local blockData = EditRules.newBlockData()

	-- World reads that never generate terrain (what an attached block would hang on).
	local function peekBlock(x: number, y: number, z: number): number?
		return world:peekBlock(x, y, z)
	end

	local function bucket(map: { [Player]: Bucket }, player: Player, initial: number): Bucket
		local b = map[player]
		if b == nil then
			b = { tokens = initial, last = os.clock() }
			map[player] = b
		end
		return b
	end

	-- Tells a player the real block after rejecting their edit. Never generates chunks: a client
	-- could otherwise make the server generate terrain anywhere by sending bogus edits.
	local function sendBlock(player: Player, x: number, y: number, z: number)
		local block = world:peekBlock(x, y, z)
		if block ~= nil then
			remote:FireClient(player, ServerMessage.Edits, Protocol.encodeEdits({ x, y, z, block }))
		end
	end

	local function handleChunkRequest(player: Player, payload: buffer)
		local coords = Protocol.decodeChunkRequest(payload)
		if coords == nil then
			return
		end
		if not take(bucket(chunkBuckets, player, CHUNK_REQUESTS_PER_SECOND), CHUNK_REQUESTS_PER_SECOND, #coords) then
			return
		end
		local lists: { Protocol.ChunkEditList } = table.create(#coords)
		for i, coord in coords do
			lists[i] = { cx = coord[1], cz = coord[2], edits = world:chunkEdits(coord[1], coord[2]) or EMPTY }
		end
		remote:FireClient(player, ServerMessage.ChunkEdits, Protocol.encodeChunkEdits(lists))
		-- (After the edit lists, on the same ordered remote: the client knows the blocks first.)
		local chunksSent = rules.chunksSent
		if chunksSent then
			chunksSent(player, coords)
		end
	end

	-- The item in the player's hand (nil when empty or without inventories).
	local function heldTool(player: Player): number?
		local rule = rules.heldTool
		return if rule then rule(player) else nil
	end

	-- The player's own mining speed with `tool` (1 without the rule).
	local function miningFactor(player: Player, tool: number?): number
		local rule = rules.miningFactor
		return if rule then rule(player, tool) else 1
	end

	-- Is block (x, y, z) within the player's reach (with some slack for movement and latency)?
	local function inReach(player: Player, x: number, y: number, z: number): boolean
		local root = rootOf(player)
		local center = Vector3.new((x + 0.5) * BLOCK, (y + 0.5) * BLOCK, (z + 0.5) * BLOCK)
		return root ~= nil and (root.Position - center).Magnitude <= (Config.Interaction.Reach + 2) * BLOCK
	end

	-- Mine messages: a survival player started (or stopped) mining a block. A start only counts for
	-- a minable block in reach, so the timer can't be started early from afar, and only from a
	-- player whose game mode mines over time (EditRules.minesOverTime: not creative, adventure or
	-- spectator).
	local function handleMine(player: Player, payload: buffer)
		local started, x, y, z = Protocol.decodeMine(payload)
		if started == nil then
			return
		end
		local mine = mining[player]
		if started then
			-- (Reach first: a block next to the player may be read even if its chunk has to be
			-- generated.)
			if
				y >= HEIGHT
				or math.abs(x) > Protocol.MAX_COORDINATE
				or math.abs(z) > Protocol.MAX_COORDINATE
				or not EditRules.minesOverTime(GameMode.of(player))
				or not inReach(player, x, y, z)
				or Mining.progressPerTick(world:getBlock(x, y, z), true, false, heldTool(player)) <= 0
			then
				mining[player] = nil
				return
			end
			-- One mining timer at a time: while an early break waits for its time, the next block's
			-- timer starts when that one is done.
			local startedAt = os.clock()
			local pending = delayed[player]
			if pending then
				local factor = miningFactor(player, pending.tool)
				local ticks = Mining.ticks(pending.block, true, false, pending.tool, factor)
				local ready = pending.startedAt + (ticks - 1) / Mining.TICK_RATE
				startedAt = math.max(startedAt, ready)
			end
			if mine == nil then
				mining[player] = { x = x, y = y, z = z, startedAt = startedAt }
			else
				mine.x, mine.y, mine.z, mine.startedAt = x, y, z, startedAt
			end
		elseif mine and mine.x == x and mine.y == y and mine.z == z then
			mining[player] = nil
		end
	end

	--[[
		Breaks block (x, y, z), which holds `current`, mined with `tool` by `breaker`: what the tool
		harvests drops (survival; the block's own item with the data it kept, read before it goes),
		a container's contents drop and its window closes, and everyone near but the breaker hears
		it break. `wearer` (a survival player) has the tool in their hand worn. Either half of a tall
		plant takes the other with it, and the plant drops, sounds and wears once, its lower half's
		drop (EditRules.harvested, removeBroken). false if the world refused the change.
	]]
	local function performBreak(
		x: number,
		y: number,
		z: number,
		current: number,
		creative: boolean,
		tool: number?,
		wearer: Player?,
		breaker: Player
	): boolean
		-- (The drop is decided by the tool as it was: one that breaks on this block still harvests
		-- it, as Minecraft copies the stack before hurting it. What the block keeps in its item is
		-- read while it is still there: setBlock tells its keepers it is gone.)
		local harvested, harvestedY = EditRules.harvested(current, peekBlock, x, y, z)
		local drop = EditRules.breakDrop(blockData, x, harvestedY, z, harvested, creative, tool)
		local mined = if creative then nil else rules.mined
		local placed = mined ~= nil and EditRules.placed(world, x, y, z, current)
		if not EditRules.removeBroken(world, x, y, z, current) then
			return false
		end
		Sounds.playBlock(current, "break", x, y, z, breaker)
		local removeContainer = rules.removeContainer
		if removeContainer and EditRules.hasMenu(current) then
			removeContainer(x, y, z)
		end
		local dropBlock = rules.dropBlock
		if drop and dropBlock then
			dropBlock(x, y, z, drop)
		end
		local wear = EditRules.wear(current, creative, tool)
		local wearTool = rules.wearTool
		if wearer and wear > 0 and wearTool then
			wearTool(wearer, wear)
		end
		local broke = rules.broke
		if broke and not creative then
			broke(breaker, current)
		end
		if mined then
			mined(breaker, current, x, y, z, placed)
		end
		return true
	end

	-- Finishes (or gives up) the delayed breaks, every frame. A player whose game mode changed to
	-- one that does not mine over time (creative, adventure, spectator) gets the block back.
	local function updateDelayed()
		local now = os.clock()
		for player, pending in delayed do
			local current = world:peekBlock(pending.x, pending.y, pending.z)
			local alive = player.Parent ~= nil and inReach(player, pending.x, pending.y, pending.z)
			local held = heldTool(player)
			if current ~= pending.block or not alive or not EditRules.minesOverTime(GameMode.of(player)) then
				delayed[player] = nil
				if player.Parent then
					sendBlock(player, pending.x, pending.y, pending.z)
				end
			elseif Mining.mayBreak(pending.block, now - pending.startedAt, 1, held, miningFactor(player, held)) then
				delayed[player] = nil
				-- Like Minecraft's delayed destroy, the item in hand when it completes times, harvests
				-- and wears (switching to a slower one just waits, until `expires` undoes it).
				if
					not performBreak(
						pending.x,
						pending.y,
						pending.z,
						pending.block,
						false,
						heldTool(player),
						player,
						player
					)
				then
					sendBlock(player, pending.x, pending.y, pending.z)
				end
			elseif now > pending.expires then
				delayed[player] = nil
				sendBlock(player, pending.x, pending.y, pending.z)
			end
		end
	end

	local function handleEdit(player: Player, payload: buffer)
		local action, x, y, z, block, seq = Protocol.decodeEdit(payload)
		if action == nil then
			return
		end
		if y >= HEIGHT or math.abs(x) > Protocol.MAX_COORDINATE or math.abs(z) > Protocol.MAX_COORDINATE then
			-- Nothing to restore out there (and no terrain to generate), but a placement's predicted
			-- use of an item still needs its answer.
			local acknowledge = rules.acknowledge
			if action == EditAction.Place and seq > 0 and acknowledge then
				acknowledge(player, seq)
			end
			return
		end

		-- Undoes the client's prediction: the real block and, for a placement, the inventory as it
		-- is (the snapshot acknowledging `seq` brings the predicted used up item back).
		local function reject()
			sendBlock(player, x, y, z)
			local acknowledge = rules.acknowledge
			if action == EditAction.Place and seq > 0 and acknowledge then
				acknowledge(player, seq)
			end
		end

		local rate = Config.Server.EditsPerSecond
		if not take(bucket(editBuckets, player, rate), rate, 1) then
			reject()
			return
		end

		if not inReach(player, x, y, z) then
			reject()
			return
		end

		-- Adventure and spectator players edit nothing (Minecraft's mayBuild).
		local mode = GameMode.of(player)
		if not EditRules.mayEdit(mode) then
			mining[player] = nil
			reject()
			return
		end

		local creative = GameMode.instabuild(mode)
		local current = world:getBlock(x, y, z)
		-- Structure blocks, structure voids and jigsaws: only for players allowed to use them.
		local operatorRule = rules.operator
		local operator = if operatorRule then operatorRule(player) else creative
		if not EditRules.mayUseCreativeOnly(if action == EditAction.Place then block else current, operator) then
			reject()
			return
		end
		if action == EditAction.Break then
			local mine = mining[player]
			local now = os.clock()
			-- Minecraft times (and harvests) a break with the item in hand when it arrives. (Creative
			-- players need it too: they can't break with a sword.)
			local tool = heldTool(player)
			if not EditRules.mayBreak(current, creative, mine, x, y, z, now, tool, miningFactor(player, tool)) then
				if
					not creative
					and mine
					and mine.x == x
					and mine.y == y
					and mine.z == z
					and Mining.progressPerTick(current, true, false, tool) > 0
				then
					-- Mined, but arrived before its time: keep the client's air and finish it when the
					-- time has passed (a second early break replaces the first, which is undone).
					mining[player] = nil
					local previous = delayed[player]
					if previous then
						sendBlock(player, previous.x, previous.y, previous.z)
					end
					delayed[player] = {
						x = x,
						y = y,
						z = z,
						block = current,
						startedAt = mine.startedAt,
						expires = now + DELAY_LIMIT,
						tool = tool,
					}
					return
				end
				reject()
				return
			end
			local mayRemove = rules.mayRemoveContainer
			if mayRemove and EditRules.isContainer(current) and not mayRemove(player, x, y, z) then
				reject()
				return
			end
			mining[player] = nil
			performBreak(x, y, z, current, creative, tool, if creative then nil else player, player)
		elseif action == EditAction.Place then
			if
				not EditRules.mayPlace(block, current)
				or not EditRules.supported(block, peekBlock, x, y, z)
				or intersectsCharacter(block, x, y, z)
			then
				reject()
				return
			end
			-- Last, as it uses up the item: nothing may refuse the edit after it. (It hands back the
			-- stack as it was, data intact.)
			local place = rules.place
			local from: Items.Stack? = nil
			if place then
				local ok, stack = place(player, block, seq)
				if not ok then
					reject()
					return
				end
				from = stack
			end
			-- (A tall plant's top too. Without room for it, which `supported` already ruled out
			-- before the item was used up, nothing is set and the client is answered.)
			if EditRules.setPlaced(world, x, y, z, block) then
				Sounds.playBlock(block, "place", x, y, z, player)
				-- Sustained data back into the fresh block (a Fluid Tank's water).
				blockData:placed(player, x, y, z, block, from)
			else
				reject()
			end
		else
			reject()
		end
	end

	local handlers: { [number]: Handler } = {
		[ClientMessage.RequestChunks] = handleChunkRequest,
		[ClientMessage.Edit] = handleEdit,
		[ClientMessage.Mine] = handleMine,
	}

	remote.OnServerEvent:Connect(function(player: Player, kind: unknown, payload: unknown)
		if typeof(kind) ~= "number" or typeof(payload) ~= "buffer" then
			return
		end
		local handler = handlers[kind]
		if handler then
			handler(player, payload)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		editBuckets[player] = nil
		chunkBuckets[player] = nil
		mining[player] = nil
		delayed[player] = nil
	end)

	local function flush()
		updateDelayed()
		local pending = world:takePending()
		local n = #pending
		local step = EDITS_PER_MESSAGE * 4
		for first = 1, n, step do
			remote:FireAllClients(
				ServerMessage.Edits,
				Protocol.encodeEdits(pending, first, math.min(first + step - 1, n))
			)
		end
	end

	return {
		flush = flush,
		on = function(kind: number, handler: Handler)
			assert(handlers[kind] == nil, `A handler for message {kind} already exists`)
			handlers[kind] = handler
		end,
		send = function(player: Player, kind: number, payload: buffer)
			remote:FireClient(player, kind, payload)
		end,
		setRules = function(newRules: Rules)
			rules = newRules
			Drops.set(newRules.dropBlock)
		end,
		addBlockData = function(hooks: EditRules.BlockDataHooks)
			blockData:add(hooks)
		end,
	}
end

return ServerNet
