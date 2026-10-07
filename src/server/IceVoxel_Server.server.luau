--!strict
--[[
	IceVoxel server: the authority over the world.

	The server never sends terrain. It picks the seed, keeps the list of edits per chunk, validates
	players' edit requests, runs block updates (falling sand, flowing water...) and replicates every
	change. Clients generate and render the terrain themselves from the seed.

	Boot order:
	  1. seed       -> published as an attribute on ReplicatedStorage.IceVoxel
	  2. world      -> generated chunk cache + edit lists (World/WorldServer)
	  3. ticker     -> scheduled block updates (World/BlockTicker, Behaviours/), and random ticks
	                   near players (World/RandomTicker: grass spreading, leaf decay, saplings)
	                   and explosions (World/Explosions: fuel that touches fire or lava blowing
	                   up, lit TNT (Behaviours/Tnt), hurting items and players through Entities
	                   and Characters; World/Nuke: the Nuke's crater, dug a budget a tick)
	  4. network    -> chunk edit requests, edit validation, replication (Network/ServerNet), and
	                   the sounds players should hear (Audio/Sounds)
	  5. clock      -> the day time, published to the clients (World/TimeOfDay)
	  6. players    -> game modes (/gamemode, the F3 + F4 switcher and F3 + N), the time (/time,
	                   /gamerule doDaylightCycle), cosmetic characters (collision group, teleports,
	                   fall damage, invulnerability, lava and burning), item entities (drops,
	                   burning in lava), inventories, chests,
	                   furnaces and crafting tables, tools (mining speed, drops, wear), safe
	                   spawning, map and spectator teleports, waypoints, player settings (the
	                   Options menu's choices, Players/SettingsStore), keeping chunks around
	                   players generated
	  7. pipes      -> Mekanism's transmitters and fluid tanks (Transmitters/Transmitters: items in
	                   transporters, fluids in pipes, Fluid Tanks and machines' tanks, replication),
	                   and the Configurator and buckets (Players/ItemUse)
	  8. machines   -> Mekanism's machines and energy (Machines/Machines: machine ticks, energy
	                   networks through Universal Cables, energy kept in items, replication)
	  9. structures -> structure blocks and jigsaw blocks (Structures/StructureBlocks: their
	                   settings and replication, SAVE / LOAD / DETECT, a jigsaw's Generate, who may
	                   use them), and generated structures' chests filled on first use
	 10. survival   -> Tough As Nails' thirst and body temperature (Players/ToughAsNails:
	                   drinking, dehydration, hypothermia and hyperthermia, the HUD's state)
	 11. mobs       -> cows, sheep, pigs, chickens, zombies, skeletons, creepers and spiders
	                   (Mobs/Mobs: their ticks, spawning, players' attacks, replication, /summon,
	                   blasts hurting them), and eating what they drop (Players/Eating)
	 12. progress   -> knowledge, the Ages and the skill tree (Players/Progression: what players
	                   earn mining, crafting, smelting, exploring and killing mobs, the recipe gate
	                   on their windows, the perks the parts above ask for, saving, /knowledge and
	                   /age)
	Status effects (Players/Effects: Minecraft's MobEffects, potions, oil and fuel on the skin,
	/effect) start with the players, before the characters that tick them; Tough As Nails
	registers its effects there when it starts. A player's mining speed is their effects' times
	their perks' (Shared/Mining.playerFactor, as the client's).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local TerrainGenerator = require(Shared.Generation.TerrainGenerator)
local Mining = require(Shared.Mining)

local Server = script.Parent
local Api = require(Server.Api)
local WorldServer = require(Server.World.WorldServer)
local BlockTicker = require(Server.World.BlockTicker)
local Simulation = require(Server.World.Simulation)
local RandomTicker = require(Server.World.RandomTicker)
local Explosions = require(Server.World.Explosions)
local Nuke = require(Server.World.Nuke)
local TimeOfDay = require(Server.World.TimeOfDay)
local Behaviours = require(Server.Behaviours)
local ServerNet = require(Server.Network.ServerNet)
local Sounds = require(Server.Audio.Sounds)
local Characters = require(Server.Players.Characters)
local GameModes = require(Server.Players.GameModes)
local TimeCommands = require(Server.Players.TimeCommands)
local Inventories = require(Server.Players.Inventories)
local Entities = require(Server.Entities.Entities)
local Spawning = require(Server.Players.Spawning)
local Teleport = require(Server.Players.Teleport)
local WaypointStore = require(Server.Players.WaypointStore)
local SettingsStore = require(Server.Players.SettingsStore)
local Transmitters = require(Server.Transmitters.Transmitters)
local Machines = require(Server.Machines.Machines)
local ItemUse = require(Server.Players.ItemUse)
local Containers = require(Server.Players.Containers)
local StructureBlocks = require(Server.Structures.StructureBlocks)
local ToughAsNails = require(Server.Players.ToughAsNails)
local Mobs = require(Server.Mobs.Mobs)
local Eating = require(Server.Players.Eating)
local Effects = require(Server.Players.Effects)
local Progression = require(Server.Players.Progression)

local seed = Config.Seed or Random.new():NextInteger(1, 2_147_483_646)
Shared:SetAttribute("Seed", seed)
print(`[IceVoxel] world seed {seed}`)

local world = WorldServer.new(TerrainGenerator.new(seed))
local ticker = BlockTicker.new(world, Behaviours.byId, Config.Server.MaxUpdatesPerTick)
world.onChanged = function(x, y, z, old, new)
	-- A generated structure's chest gets its contents before anything hears it change, so one
	-- broken or replaced unopened still drops them.
	Containers.materialize(x, y, z, old)
	ticker:blockChanged(x, y, z)
	-- A chest or furnace replaced by anything (breaking, the Api, block updates) drops what it
	-- holds, and any block with a window closes it for its users.
	Inventories.blockChanged(x, y, z, old, new)
	-- Transmitters and fluid tanks come and go (a transporter's items drop), and pipes notice the
	-- chests, furnaces, tanks and energy blocks around them.
	Transmitters.blockChanged(x, y, z, old, new)
	-- Machines come and go, and energy networks are worked out again around them.
	Machines.blockChanged(x, y, z, old, new)
	-- Structure blocks and jigsaws keep their settings while they stand.
	StructureBlocks.blockChanged(x, y, z, old, new)
end

local net = ServerNet.start(world)
Sounds.start(net)
TimeOfDay.start()
GameModes.start(net)
TimeCommands.start(net)
Effects.start(net)
Characters.start(net, world)
-- Items must exist before anything can drop them.
Entities.start(net, world)
Inventories.start(net, world)
net.setRules({
	place = Inventories.place,
	acknowledge = Inventories.acknowledge,
	dropBlock = Entities.dropBlock,
	removeContainer = Inventories.removeContainer,
	mayRemoveContainer = Inventories.mayRemoveContainer,
	heldTool = Inventories.heldTool,
	wearTool = Inventories.wearTool,
	broke = ToughAsNails.blockBroken,
	mined = Progression.mined,
	-- (Haste and Mining Fatigue times the mining perks: the client predicts with the same.)
	miningFactor = function(player: Player, tool: number?): number
		return Mining.playerFactor(Effects.levels(player), Progression.state(player), tool)
	end,
	chunksSent = function(player: Player, coords: { { number } })
		Transmitters.sendChunks(player, coords)
		Machines.sendChunks(player, coords)
		StructureBlocks.sendChunks(player, coords)
	end,
	operator = StructureBlocks.operator,
	-- (Mobs start later; until then nothing is in the way.)
	occupied = Mobs.occupied,
})
-- Pipes after inventories and items (they fill chests and drop items); item use after the pipes;
-- machines after the pipes (their cables are the pipes' nodes).
Transmitters.start(net, world)
ItemUse.start(net, world)
Machines.start(net, world)
-- Structure blocks after inventories (containers, the Use hook).
StructureBlocks.start(net, world)
-- Thirst and temperature after inventories (drinks, armor) and machines (warm generators).
ToughAsNails.start(net, world)
-- Mobs after items (their loot), characters (their hits) and inventories (attacks, eating).
Mobs.start(net, world)
Eating.start(net)
-- Knowledge, Ages and skills after inventories (the windows' recipe gate) and game modes; the
-- perks go to the parts that apply them.
Progression.start(net, world)
Inventories.setWearFilter(Progression.wear)
-- (Results a furnace pushes into a chest, or a pipe pulls out, are smelted by its last user.)
Inventories.setResultsHandler(Progression.smelted)
ToughAsNails.setPerks({ thirstRate = Progression.thirstRate, insulation = Progression.insulation })
ItemUse.setBoilSpeed(Progression.boilSpeed)
-- A mob a player killed is knowledge: the first of its kind a discovery, then Knowledge.MOBS.
Mobs.died:Connect(function(killer: Player?, kind: string)
	if killer then
		Progression.killed(killer, kind)
	end
end)
Spawning.start(world)
Teleport.start(world, net)
WaypointStore.start(net)
SettingsStore.start(net)
Simulation.start(world)
-- What blasts do beyond blocks: items, players (damage, knockback), mobs and the clients' effects.
Explosions.setHandler(function(x: number, y: number, z: number, power: number, getBlock, range: number?)
	Entities.explode(x, y, z, power)
	Characters.explosion(x, y, z, power, getBlock, range)
	Mobs.explode(x, y, z, power)
end)
Api._ready(world, ticker)

-- Fixed rate block updates, then the frame's share of structures being placed, then one
-- replication message per frame, then the pipes, machines and structure blocks.
local randomTicker = RandomTicker.new(world, ticker)
local tickLength = 1 / Config.Server.TickRate
local accumulator = 0
RunService.Heartbeat:Connect(function(dt)
	accumulator = math.min(accumulator + dt, tickLength * 4)
	while accumulator >= tickLength do
		accumulator -= tickLength
		ticker:step()
		Explosions.step(world)
		Nuke.step(world)
		RandomTicker.step(randomTicker, Simulation.activeChunks(world), Config.Server.RandomTickSpeed, math.random)
	end
	StructureBlocks.place()
	net.flush()
	-- The pipes after the edits: a client knows a transmitter's block before its state.
	Transmitters.update(dt)
	Machines.update(dt)
	StructureBlocks.update(dt)
end)
