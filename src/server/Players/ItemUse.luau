--!strict
--[[
	Right clicks on blocks with items that are no block (UseItem messages): Mekanism's Configurator
	on transmitters and Minecraft's buckets on water and fluid tanks. The rules are
	Transmitters/UseRules (pure, tested); this checks the request and plays them out. Clients do
	not predict any of it: the inventory snapshot, the world's edits and the Transmitters / Tanks
	records bring the results.

	  Checks         a living player, the block within reach (Config.Interaction.Reach + 2 blocks,
	                 as ServerNet checks edits) and loaded, at most USES_PER_SECOND uses a second
	                 (Minecraft repeats a held right click every 4 ticks), and the item really in
	                 their hand. The side comes checked from Protocol.decodeUseItem.
	  Configurator   on a transmitter: the clicked side's mode goes normal -> push -> pull -> none
	                 (and a transmitter of the same kind beyond that side matches it); sneaking on a
	                 transporter cycles its colour instead. The player gets Mekanism's message
	                 ("Connection type changed to pull", "Colour bumped to: red") and everyone near
	                 hears a click (item.configurator.click).
	  Bucket         on a water source: takes it (air) and fills (item.bucket.fill at the player);
	                 on a fluid tank holding a bucket's worth of water, not sneaking: drains 1000 mB
	                 (the sound at the tank).
	  Water Bucket   on a fluid tank with room for 1000 mB, not sneaking: fills it; elsewhere:
	                 places a water source in the block, or beyond the clicked side
	                 (item.bucket.empty where the water goes); a plant it replaces drops
	                 (UseRules.pour). Block updates take it from there.
	Inventory changes go through Players/Inventories (`setHeld`, `give`: what does not fit is
	thrown).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Protocol = require(Shared.Net.Protocol)
local SharedTransmitters = require(Shared.Transmitters)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local Sounds = require(script.Parent.Parent.Audio.Sounds)
local Inventories = require(script.Parent.Inventories)
local TransmitterWorld = require(script.Parent.Parent.Transmitters.TransmitterWorld)
local Transmitters = require(script.Parent.Parent.Transmitters.Transmitters)
local UseRules = require(script.Parent.Parent.Transmitters.UseRules)

type Stack = Items.Stack

local BLOCK = Config.BlockSize
local HEIGHT = Config.WorldHeight
local BUCKET = SharedTransmitters.BUCKET
local WATER = SharedTransmitters.FLUIDS.WATER
-- Uses a player may make per second (bursts of twice that).
local USES_PER_SECOND = 10

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

-- An empty bucket on (x, y, z): a fluid tank's water or a water source.
local function fill(
	world: WorldServer.World,
	simulation: TransmitterWorld.World,
	player: Player,
	held: Stack,
	block: number,
	x: number,
	y: number,
	z: number,
	sneaking: boolean
)
	local creative = GameMode.isCreative(player)
	if not sneaking and SharedTransmitters.isTank(block) then
		local amount, fluid = TransmitterWorld.drainTank(simulation, x, y, z, BUCKET, true)
		if amount < BUCKET or fluid ~= WATER then
			return
		end
		TransmitterWorld.drainTank(simulation, x, y, z, BUCKET)
		apply(player, UseRules.fillFromTank(held, creative))
		play(player, "item.bucket.fill", x + 0.5, y + 0.5, z + 0.5)
	elseif UseRules.isWaterSource(block) then
		if not world:setBlock(x, y, z, Blocks.AIR) then
			return
		end
		apply(player, UseRules.fillFromWorld(held, creative, Inventories.hasItem(player, UseRules.WATER_BUCKET)))
		-- (At the player, as Minecraft's Player.playSound.)
		if Sounds.allow(player) then
			Sounds.playAt(player, "item.bucket.fill")
		end
	end
end

-- A water bucket on (x, y, z): into a fluid tank, or a water source into the world.
local function empty(
	world: WorldServer.World,
	simulation: TransmitterWorld.World,
	player: Player,
	held: Stack,
	block: number,
	x: number,
	y: number,
	z: number,
	side: number,
	sneaking: boolean
)
	local creative = GameMode.isCreative(player)
	if not sneaking and SharedTransmitters.isTank(block) then
		-- (A bucket empties whole or not at all; a tank without room for it takes nothing.)
		if TransmitterWorld.fillTank(simulation, x, y, z, WATER, BUCKET, true) < BUCKET then
			return
		end
		TransmitterWorld.fillTank(simulation, x, y, z, WATER, BUCKET)
		apply(player, UseRules.emptied(held, creative))
		play(player, "item.bucket.empty", x + 0.5, y + 0.5, z + 0.5)
		return
	end
	local tx, ty, tz = UseRules.waterTarget(function(bx: number, by: number, bz: number): number?
		return world:peekBlock(bx, by, bz)
	end, x, y, z, side)
	if tx == nil then
		return
	end
	-- (Pouring into a water source changes nothing but still empties the bucket, as in Minecraft;
	-- a plant there drops.)
	if not UseRules.pour(world, tx, ty, tz) then
		return
	end
	apply(player, UseRules.emptied(held, creative))
	play(player, "item.bucket.empty", tx + 0.5, ty + 0.5, tz + 0.5)
end

local function onUseItem(net: ServerNet.ServerNet, world: WorldServer.World, player: Player, payload: buffer)
	local x, y, z, side, sneaking = Protocol.decodeUseItem(payload)
	if x == nil or y >= HEIGHT or not isAlive(player) or not inReach(player, x, y, z) or not mayUse(player) then
		return
	end
	local simulation = Transmitters.world()
	local held = Inventories.heldStack(player)
	-- (Within reach, so loaded; peek anyway: a request never generates terrain.)
	local block = world:peekBlock(x, y, z)
	if simulation == nil or held == nil or block == nil then
		return
	end
	if held.item == UseRules.CONFIGURATOR then
		configure(net, simulation, player, block, x, y, z, side, sneaking)
	elseif held.item == UseRules.BUCKET then
		fill(world, simulation, player, held, block, x, y, z, sneaking)
	elseif held.item == UseRules.WATER_BUCKET then
		empty(world, simulation, player, held, block, x, y, z, side, sneaking)
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
