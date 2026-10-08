--!strict
--[[
	IceVoxel server: the authority over the world.

	The server never sends terrain. It picks the seed, keeps the list of edits per chunk, validates
	players' edit requests, runs block updates (falling sand, flowing water...) and replicates every
	change. Clients generate and render the terrain themselves from the seed.

	Before the world (at once, on the lobby's net: Network/LobbyNet):
	  operators     -> Minecraft's ops: the first player to join is the operator, /op and /deop,
	                   the permission every operators' command asks (Players/Operators)
	  settings      -> player settings (the Options menu's choices, Players/SettingsStore): the
	                   title screen has the Options menu too
	  saves         -> saved worlds (World/WorldSave): the DataStore looked at once, the title
	                   screen's Load World (Players/WorldMenu), the world saved at shutdown
	  title screen  -> with Config.MainMenu.Enabled, the world waits for its operator to create it
	                   from the title screen (Players/WorldMenu: no characters until then; World/
	                   WorldInfo runs startWorld below with the screen's settings); without it the
	                   world is created at once from Config.World and Config.Seed
	                   (WorldSettings.fromConfig), or the world played last is loaded
	                   (Config.Save.LoadLatest)

	startWorld(settings), once:
	  1. settings   -> into Config (World/WorldInfo.apply, just before: new players' game mode, the
	                   difficulty) and to Players/Operators (Allow Commands)
	  2. world      -> generated chunk cache + edit lists (World/WorldServer), from the world type,
	                   options and seed (Generation/WorldTypes), with a loaded world's edits
	                   (World/WorldSave.attach) and every change marking its region for the next
	                   save (WorldSave.blockChanged); a type's hints: `ticks = false`
	                   (the debug worlds) builds the ticker below without block behaviours,
	                   `mobs = false` turns natural spawning off (World/WorldInfo.apply)
	  3. ticker     -> scheduled block updates (World/BlockTicker, Behaviours/), and random ticks
	                   near players (World/RandomTicker: grass spreading, leaf decay, saplings)
	                   and explosions (World/Explosions: fuel that touches fire or lava blowing
	                   up, lit TNT (Behaviours/Tnt), hurting items and players through Entities
	                   and Characters; World/Nuke: the Nuke's crater, dug a budget a tick)
	  4. network    -> chunk edit requests, edit validation, replication (Network/ServerNet), and
	                   the sounds players should hear (Audio/Sounds)
	  5. clock      -> the day time, published to the clients (World/TimeOfDay), and the weather
	                   (World/WeatherServer: its clock and /weather's overrides, published the same
	                   way; rain on fire, players and the undead; lightning near players, whose
	                   strikes hurt through Players/Characters and Mobs/Mobs once they start; none
	                   in the debug worlds)
	  6. players    -> game modes (/gamemode, the F3 + F4 switcher and F3 + N), the time and the
	                   weather (/time, /weather, /gamerule doDaylightCycle and doWeatherCycle),
	                   cosmetic characters (collision group, teleports,
	                   fall damage, invulnerability, lava and burning), item entities (drops,
	                   burning in lava), inventories, chests,
	                   furnaces and crafting tables, tools (mining speed, drops, wear), safe
	                   spawning, map and spectator teleports, waypoints, keeping chunks around
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
	 13. restored   -> a loaded world's chests, furnaces, machines, pipes, structure blocks, items,
	                   animals, operators and clock (World/WorldSave.restore)
	 14. published  -> last, the world's settings on ReplicatedStorage.IceVoxel (WorldSettings
	                   .publish: name, difficulty, then the world type, options and the "Seed"):
	                   clients start loading once the seed is there, so everything above is ready
	                   to answer them; then saving starts (WorldSave.begin: players' records,
	                   autosave, /save-all, /save-off, /save-on)
	Status effects (Players/Effects: Minecraft's MobEffects, potions, oil and fuel on the skin,
	/effect) start with the players, before the characters that tick them; Tough As Nails
	registers its effects there when it starts. A player's mining speed is their effects' times
	their perks' (Shared/Mining.playerFactor, as the client's).
	Players' positions (Players/PlayerPositions: feet, reach, teleports) start with the players too,
	before everything that reads them; with Config.Players.ServerPositions, Players/PlayerRelay
	sends each player the others they may see, from after the mobs.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
-- With the title screen nobody gets a character before entering the world (Players/WorldMenu):
-- first of all, so a player joining while the modules below load gets none either.
if Config.MainMenu.Enabled then
	Players.CharacterAutoLoads = false
end
local WorldTypes = require(Shared.Generation.WorldTypes)
local WorldSettings = require(Shared.WorldSettings)
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
local WeatherServer = require(Server.World.WeatherServer)
local WorldInfo = require(Server.World.WorldInfo)
local Behaviours = require(Server.Behaviours)
local ServerNet = require(Server.Network.ServerNet)
local LobbyNet = require(Server.Network.LobbyNet)
local Sounds = require(Server.Audio.Sounds)
local PlayerPositions = require(Server.Players.PlayerPositions)
local PlayerRelay = require(Server.Players.PlayerRelay)
local Characters = require(Server.Players.Characters)
local GameModes = require(Server.Players.GameModes)
local Operators = require(Server.Players.Operators)
local WorldMenu = require(Server.Players.WorldMenu)
local TimeCommands = require(Server.Players.TimeCommands)
local WeatherCommands = require(Server.Players.WeatherCommands)
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
local WorldSave = require(Server.World.WorldSave)

--[[
	Creates the world and starts everything that needs it (see the header); World/WorldInfo calls
	it once, with the title screen's settings or Config's, after putting them into Config.
]]
local function startWorld(settings: WorldSettings.Settings)
	print(`[IceVoxel] world "{settings.name}": {settings.worldType}, seed {WorldSettings.seedText(settings.seed)}`)
	Operators.setAllowCommands(settings.allowCommands)

	local world = WorldServer.new(WorldTypes.create(settings.worldType, settings.seed, settings.options))
	-- A loaded world's edits, before any chunk is generated (and a new world's save handle).
	WorldSave.attach(world, settings)
	-- A world type without ticks (the debug worlds) gets no block behaviours: no block updates and
	-- no random ticks, so nothing falls, flows, grows or burns (Minecraft's debug world).
	local worldType = WorldTypes.get(settings.worldType)
	local ticking = worldType == nil or worldType.ticks ~= false
	local ticker = BlockTicker.new(world, if ticking then Behaviours.byId else {}, Config.Server.MaxUpdatesPerTick)
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
		-- Its region is written at the next save.
		WorldSave.blockChanged(x, y, z)
	end

	local net = ServerNet.start(world)
	Sounds.start(net)
	TimeOfDay.start()
	-- (No weather in a world without ticks: the debug worlds.)
	WeatherServer.start(net, world, settings.seed, ticking)
	GameModes.start(net)
	TimeCommands.start(net)
	WeatherCommands.start(net)
	Effects.start(net)
	-- Where players are, for everything after it (Players/PlayerPositions: their characters, or
	-- their clients' checked moves with Config.Players.ServerPositions).
	PlayerPositions.start(net)
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
	-- Other players' poses to those who may see them (Players/PlayerRelay; with
	-- Config.Players.ServerPositions only).
	PlayerRelay.start(net)
	Eating.start(net)
	-- Knowledge, Ages and skills after inventories (the windows' recipe gate) and game modes; the
	-- perks go to the parts that apply them.
	Progression.start(net, world, WorldSettings.savesProgress(settings))
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
	-- Chunks around players generated a slice of each frame, on a generator of their own
	-- (World/Simulation, World/GenQueue), and /genstats.
	Simulation.start(world, net, function()
		return WorldTypes.create(settings.worldType, settings.seed, settings.options)
	end)
	-- What blasts do beyond blocks: items, players (damage, knockback), mobs and the clients' effects.
	Explosions.setHandler(function(x: number, y: number, z: number, power: number, getBlock, range: number?)
		Entities.explode(x, y, z, power)
		Characters.explosion(x, y, z, power, getBlock, range)
		Mobs.explode(x, y, z, power)
	end)
	-- Rain puts burning players out (mobs ask the weather themselves: Mobs/Mobs).
	Characters.setRain(WeatherServer.rainingAt)
	-- What lightning does to the living (players and mobs), and the mobs it may pick to strike.
	WeatherServer.setHandler(function(x: number, y: number, z: number)
		Characters.lightning(x, y, z)
		Mobs.lightning(x, y, z)
	end, function(x: number, y: number, z: number, radius: number)
		local living = {}
		for _, mob in Mobs.near(x, y, z, radius) do
			table.insert(
				living,
				{ x = mob.x, y = mob.y, z = mob.z, width = mob.width, height = mob.height, key = mob.id }
			)
		end
		return living
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

	-- A loaded world's state back in every part, before anyone enters (its sections too: the day
	-- clock and the weather, started above, go on where they were saved).
	WorldSave.restore({
		world = world,
		containers = Containers.default,
		transmitters = Transmitters.world(),
		machines = Machines.world(),
		structures = StructureBlocks.store,
		items = Entities.world(),
		mobs = Mobs.world(),
		ticker = ticker,
	})

	-- Last: clients start loading once the seed is there (the world type and its options, the
	-- name and the difficulty go out before it: Shared/WorldSettings, Generation/WorldTypes).
	WorldSettings.publish(Shared, settings)
	WorldSave.begin()
end

-- Before the world: operators, player settings and the title screen, on the lobby's net.
local lobby = LobbyNet.start()
Operators.start(lobby, GameModes.isOwner, GameModes.ownerKnown)
SettingsStore.start(lobby)
WorldSave.start(lobby)
if Config.MainMenu.Enabled then
	WorldMenu.start(lobby, startWorld, WorldSave)
else
	local ok, problem = WorldInfo.create(
		WorldSave.latest() or WorldSettings.fromConfig(Config.Seed or Random.new():NextInteger(1, 2_147_483_646)),
		startWorld
	)
	if not ok then
		-- (A loaded world that didn't start is given back.)
		WorldSave.abandon()
		error(`[IceVoxel] the world could not be created: {problem}`)
	end
end
