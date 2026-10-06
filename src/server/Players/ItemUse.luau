--!strict
--[[
	Right clicks on blocks with items that are no block (UseItem messages): Mekanism's Configurator
	on transmitters, Minecraft's buckets on fluid sources, Fluid Tanks and machines' fluid tanks,
	for every fluid pipes carry (Shared/Fluids: water, lava, oil, fuel), and flint and steel. The
	rules are Transmitters/UseRules and Behaviours/Fire (pure, tested); this checks the request
	and plays them out. Clients do
	not predict any of it: the inventory snapshot, the world's edits and the Transmitters / Tanks
	records bring the results.

	  Checks         a living player whose game mode may use items on blocks (survival and
	                 creative: GameModeRules.mayUseItemOn, Minecraft's ItemStack.useOn without
	                 mayBuild; adventure and spectator players use nothing), the block within reach
	                 (Config.Interaction.Reach + 2 blocks, as ServerNet checks edits) and loaded, at
	                 most USES_PER_SECOND uses a second (Minecraft repeats a held right click every 4
	                 ticks), and the item really in their hand. The side comes checked from
	                 Protocol.decodeUseItem. Creative players (instabuild) keep their buckets as
	                 UseRules says.
	  Configurator   on a transmitter: the clicked side's mode goes normal -> push -> pull -> none
	                 (and a transmitter of the same kind beyond that side matches it); sneaking on a
	                 transporter cycles its colour instead. The player gets Mekanism's message
	                 ("Connection type changed to pull", "Colour bumped to: red") and everyone near
	                 hears a click (item.configurator.click).
	  Bucket         on a fluid's source (its cave twin too): takes it (air) and becomes that
	                 fluid's bucket (the fluid's fill sound, item.bucket.fill_lava ..., at the
	                 player); not sneaking, on a Fluid Tank holding a bucket's worth: drains
	                 1000 mB; on a machine with fluid tanks: 1000 mB out of an output tank, else an
	                 input tank, holding that much (Machines.fillBucket; the sound at the block).
	  Full buckets   (Water, Lava, Oil, Fuel) not sneaking, on a Fluid Tank with room for 1000 mB
	                 of that fluid: fills it; on a machine with an input tank taking the fluid and
	                 room for all of it: pours into it (Machines.pourBucket). Elsewhere: places the
	                 fluid's source in the block, or beyond the clicked side (its empty sound where
	                 it goes); a plant it replaces drops (UseRules.pour). Block updates take it from
	                 there (lava meeting water hardens). What a machine's tank gained or lost
	                 reaches its viewers with server/Machines' next step.
	  Flint and      (FlintAndSteelItem.useOn) fire in front of the clicked side where fire may
	  Steel          burn (Behaviours/Fire.light, Fire.canPlaceAt), with item.flintandsteel.use
	                 there; it wears by 1 (64 uses), never in creative. On TNT or a Nuke
	                 (TntBlock.use, whatever the side) it lights it instead (Behaviours/Tnt.prime,
	                 with its hiss) and wears the same.
	Inventory changes go through Players/Inventories (`setHeld`, `give`: what does not fit is
	thrown).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Protocol = require(Shared.Net.Protocol)
local SharedTransmitters = require(Shared.Transmitters)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local Fire = require(script.Parent.Parent.Behaviours.Fire)
local Tnt = require(script.Parent.Parent.Behaviours.Tnt)
local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local Sounds = require(script.Parent.Parent.Audio.Sounds)
local Containers = require(script.Parent.Containers)
local Inventories = require(script.Parent.Inventories)
local TransmitterWorld = require(script.Parent.Parent.Transmitters.TransmitterWorld)
local Transmitters = require(script.Parent.Parent.Transmitters.Transmitters)
local UseRules = require(script.Parent.Parent.Transmitters.UseRules)
local GameModeRules = require(script.Parent.GameModeRules)

type Stack = Items.Stack

local BLOCK = Config.BlockSize
local HEIGHT = Config.WorldHeight
-- Uses a player may make per second (bursts of twice that).
local USES_PER_SECOND = 10
local FLINT_AND_STEEL = Items.id.FlintAndSteel

local ItemUse = {}

local budgets: { [Player]: { tokens: number, last: number } } = {}
local started = false

local function mayUse(player: Player): boolean
	local now = os.clock()
	local budget = budgets[player]
	if budget == nil then
		budget = { tokens = USES_PER_SECOND * 2, last = now }
		budgets[player] = budget
	end
	budget.tokens = math.min(USES_PER_SECOND * 2, budget.tokens + (now - budget.last) * USES_PER_SECOND)
	budget.last = now
	if budget.tokens < 1 then
		return false
	end
	budget.tokens -= 1
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

local function isAlive(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

-- Is block (x, y, z) within the player's reach (as ServerNet checks edits)?
local function inReach(player: Player, x: number, y: number, z: number): boolean
	local root = rootOf(player)
	local center = Vector3.new((x + 0.5) * BLOCK, (y + 0.5) * BLOCK, (z + 0.5) * BLOCK)
	return root ~= nil and (root.Position - center).Magnitude <= (Config.Interaction.Reach + 2) * BLOCK
end

-- The held stack after a use, and what the player is given besides.
local function apply(player: Player, held: Stack?, give: Stack?)
	Inventories.setHeld(player, held)
	if give then
		Inventories.give(player, give)
	end
end

local function play(player: Player, sound: string, x: number, y: number, z: number)
	if Sounds.allow(player) then
		Sounds.play(sound, x, y, z)
	end
end

local function configure(
	net: ServerNet.ServerNet,
	simulation: TransmitterWorld.World,
	player: Player,
	block: number,
	x: number,
	y: number,
	z: number,
	side: number,
	sneaking: boolean
)
	if not SharedTransmitters.isTransmitter(block) then
		return
	end
	local text
	if sneaking then
		local colour = TransmitterWorld.cycleColour(simulation, x, y, z)
		text = if colour then UseRules.colourNotice(colour) else nil
	else
		local mode = TransmitterWorld.cycleMode(simulation, x, y, z, side)
		text = if mode then UseRules.modeNotice(mode) else nil
	end
	if text then
		net.send(player, Protocol.ServerMessage.Notice, Protocol.encodeNotice(text))
		play(player, "item.configurator.click", x + 0.5, y + 0.5, z + 0.5)
	end
end

-- What a bucket use needs from the game, for `player`.
local function bucketEnv(
	world: WorldServer.World,
	simulation: TransmitterWorld.World,
	player: Player
): UseRules.BucketEnv
	return {
		world = world,
		pipes = simulation,
		containers = Containers.default,
		creative = GameMode.instabuildOf(player),
		hasItem = function(item: number): boolean
			return Inventories.hasItem(player, item)
		end,
	}
end

-- Plays out a bucket use: the player's new stacks and the sound.
local function bucketDone(player: Player, done: UseRules.BucketResult?)
	if done == nil then
		return
	end
	apply(player, done.held, done.give)
	if done.sound and Sounds.allow(player) then
		if done.atPlayer then
			Sounds.playAt(player, done.sound)
		else
			Sounds.play(done.sound, done.x, done.y, done.z)
		end
	end
end

-- Flint and steel on side `side` of block (x, y, z): fire in front of it, the strike, the wear.
local function strike(world: WorldServer.World, player: Player, x: number, y: number, z: number, side: number)
	if Tnt.isExplosive(world:peekBlock(x, y, z)) then
		-- (TntBlock.use: lit, with the hiss rather than the strike.)
		if Tnt.prime(world, x, y, z) and not GameMode.instabuildOf(player) then
			Inventories.wearTool(player, 1)
		end
		return
	end
	local dx, dy, dz = SharedTransmitters.offset(side)
	local fx, fy, fz = Fire.light(world, x, y, z, dx, dy, dz)
	if fx == nil or fy == nil or fz == nil then
		return
	end
	play(player, "item.flintandsteel.use", fx + 0.5, fy + 0.5, fz + 0.5)
	if not GameMode.instabuildOf(player) then
		Inventories.wearTool(player, 1)
	end
end

local function onUseItem(net: ServerNet.ServerNet, world: WorldServer.World, player: Player, payload: buffer)
	local x, y, z, side, sneaking = Protocol.decodeUseItem(payload)
	if
		x == nil
		or y >= HEIGHT
		or not GameModeRules.mayUseItemOn(GameMode.of(player))
		or not isAlive(player)
		or not inReach(player, x, y, z)
		or not mayUse(player)
	then
		return
	end
	local simulation = Transmitters.world()
	local held = Inventories.heldStack(player)
	-- (Within reach, so loaded; peek anyway: a request never generates terrain.)
	local block = world:peekBlock(x, y, z)
	if held and block and held.item == FLINT_AND_STEEL then
		strike(world, player, x, y, z, side)
		return
	end
	if simulation == nil or held == nil or block == nil then
		return
	end
	if held.item == UseRules.CONFIGURATOR then
		configure(net, simulation, player, block, x, y, z, side, sneaking)
	elseif held.item == UseRules.BUCKET then
		bucketDone(player, UseRules.fillBucket(bucketEnv(world, simulation, player), held, block, x, y, z, sneaking))
	elseif UseRules.bucketFluid(held.item) ~= 0 then
		bucketDone(
			player,
			UseRules.emptyBucket(bucketEnv(world, simulation, player), held, block, x, y, z, side, sneaking)
		)
	end
end

-- Starts handling UseItem messages. Players/Inventories and Transmitters must have started.
function ItemUse.start(net: ServerNet.ServerNet, world: WorldServer.World)
	assert(not started, "ItemUse.start was already called")
	started = true
	net.on(Protocol.ClientMessage.UseItem, function(player: Player, payload: buffer)
		onUseItem(net, world, player, payload)
	end)
	Players.PlayerRemoving:Connect(function(player)
		budgets[player] = nil
	end)
end

return ItemUse
