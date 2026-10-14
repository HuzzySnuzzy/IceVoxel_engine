--[[
	The zombie apocalypse's streams working together, which none of them could test alone: the
	zombies' server (Mobs/Mobs, Mobs/MobWorld, Mobs/ZombieDirector), their client rigs' model
	(client Entities/MobModel), survival (Apocalypse/Survival, Apocalypse/Infection, Players/Eating,
	Players/Effects), the cities and roads (Generation/Cities, CityLayout) and the bunkers
	(Generation/Bunkers), all real, on the real generator of seed 99 around the small town at
	-393, -1376 (R 35) and its shed's bunker. Only what needs Roblox is faked: the services
	(Players, RunService, TextChatService), Instance, Random, task, the clock, and the server modules
	that are Roblox glue themselves (Characters' Humanoids, Inventories, PlayerPositions, Tough As
	Nails' Health script, ServerNet, TimeOfDay, the weather, World/Simulation's chunk list, item
	drops). The world is a real World/WorldServer over the generator's own chunks, so the zombies
	stand on, break and climb what Generation/Cities and Generation/Bunkers wrote, and the server's
	`world.generator.cityAt` is Generation/Cities'.

	   1  the generator the server world runs on: cityAt (1 in the town, 0 far away, the margin
	      between) is what the glue's spawning context reads; a player's monster cap in the town
	      is the city's (12 by day, 35 at night, 49 in the first blood moon) and outside it the
	      wild's (7, 20, 28); the city's kind weights pick police and firefighters only in the town
	   2  a blood moon at a /time set on day 3's night (Players/TimeCommand): the world's limits
	      (360), a wave of 8 hunters on the town's open floors, the client's sky and day line agree
	      with the server; /time set day: 320 again, the hunt over, the sky clear; in seed 99's big
	      city (-1627, -1513) three waves land all 24 on its streets and lots, none on a roof (the
	      glue hands the director the generator's ground: ZombieDirector.WAVE_ABOVE), and its
	      natural spawns, night and day, never land more than 3 above its ground either
	      (MobSpawning.GROUND_ABOVE)
	   3  a horde zombie (a hunter of the blood moon) breaks into the town's shed through its Oak
	      Door unseen (both halves, nothing dropped, its noise), its Breaking flag on the client, and
	      crosses the shut hatch (Entities/MobPhysics: a floor plate is ground) to hit the player
	      inside; another through the shed's plank wall
	   4  the Brute walks through a ruined house's generated doorway breaking nothing, and climbs
	      the 12 rungs of the shed's bunker shaft to the open hatch to hit the player beside it
	   5  the hatch opened by a right click (Players/ToggleUse): its sound and a noise the zombies
	      hear; a player climbs out of the bunker under the shed; shut, it holds
	   6  zombies round a player sealed in that bunker leave at dawn, down to the town's day cap
	   7  a bite through Mobs.playerHit starts the infection (Apocalypse/Survival, Infection,
	      Players/Effects: the stage as the effect's amplifier in the Effects message) and a wound;
	      /effect takes it on; a Herbal Poultice and Antibiotics through Players/Eating set it back
	      and cure it (Weakness after a late cure); a zombie killed counts on the Survivor record;
	      an infected player's death raises a zombie where they fell, in their shirt's look
	   8  a sprint (Survival's) is a noise the director hears (louder at night) and a zombie goes to
	      look
	   9  op 6 through the client's decoding (Entities/MobModel): every client baseline equals the
	      server's quantised position exactly, sync after sync, and the flags arrive
	  10  /summon zombie_brute through Mobs' chat command; /locate structure city, bunker and #ruins
	      through Players/LocateCommand and Generation/Locate
	  11  an old world (a saved meta without `ruins`) generates no cities, roads or bunkers, its
	      cities' caps are gone, /locate finds none; Config.Cities.OldWorlds brings them back
	  12  the blood moon's schedule is one: the server's waves and limits, the client's sky, the day
	      line's notice and the survivor's count agree tick by tick over ten days
	  13  every new block, item and sound is reachable: generated in the town or its bunker (the
	      white Road Line in the streets' crosswalks), made, toggled or turned (blocks); made, found
	      or dropped (items); played by name or as a mob's voice (sounds); every sound an ordinary
	      SoundList event (so SoundService.IceVoxelSounds overrides it), every new texture and icon
	      a blank TexturePack entry
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")

-- A module's source with `globals` declared as locals taken from the chunk's arguments.
local function withHeader(source: string, globals: string): string
	local lines = string.split(source, "\n")
	local i = 1
	while lines[i] and string.sub(lines[i], 1, 3) == "--!" do
		i += 1
	end
	lines[i] = `local {globals} = ...; ` .. (lines[i] or "")
	return table.concat(lines, "\n")
end

local function fakeSignal(): any
	local handlers = {}
	return {
		Connect = function(_, fn)
			table.insert(handlers, fn)
			return { Disconnect = function() end }
		end,
		fire = function(...)
			for _, fn in handlers do
				fn(...)
			end
		end,
	}
end

-- A deterministic random in [0, 1) (a small LCG).
local function lcg(seed: number): () -> number
	local state = seed
	return function(): number
		state = (state * 1103515245 + 12345) % 2147483648
		return state / 2147483648
	end
end

-- Every .luau file under `dir`.
local function sources(dir: string, out: { string }): { string }
	for _, entry in fs.readDir(dir) do
		local path = `{dir}/{entry}`
		if fs.isDir(path) then
			sources(path, out)
		elseif string.sub(entry, -5) == ".luau" then
			table.insert(out, path)
		end
	end
	return out
end

return function(t, shared, require, server, client)
	local Blocks = require(shared.Blocks)
	local Config = require(shared.Config)
	local DayCycle = require(shared.DayCycle)
	local GameMode = require(shared.GameMode)
	local Items = require(shared.Items)
	local SharedSounds = require(shared.Sounds)
	local TexturePack = require(shared.TexturePack)
	local Effects = require(shared.Effects)
	local Foods = require(shared.Items.Foods)
	local InfectionRules = require(shared.Apocalypse.Infection)
	local Crafting = require(shared.Crafting)
	local Smelting = require(shared.Crafting.Smelting)
	local MobList = require(shared.Entities.MobList)
	local Protocol = require(shared.Net.Protocol)
	local BloodMoon = require(shared.Apocalypse.BloodMoon)
	local Toggles = require(shared.Blocks.Toggles)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Types = require(shared.Inventory.Types)
	local PlayerPhysics = require(shared.Movement.PlayerPhysics)
	local MobPhysics = require(shared.Entities.MobPhysics)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local Cities = require(shared.Generation.Cities)
	local CityLayout = require(shared.Generation.CityLayout)
	local ScavengeLoot = require(shared.Generation.ScavengeLoot)
	local WorldTypes = require(shared.Generation.WorldTypes)
	local WorldServer = require(server.World.WorldServer)
	local Skylight = require(server.World.Skylight)
	local WorldMeta = require(server.Save.WorldMeta)
	local RealSpawning = require(server.Mobs.MobSpawning)
	local MobAI = require(server.Mobs.MobAI)
	local MobTracking = require(server.Mobs.MobTracking)
	local ZombieDirector = require(server.Mobs.ZombieDirector)
	local SurvivalRules = require(server.Apocalypse.SurvivalRules)
	local TimeCommand = require(server.Players.TimeCommand)
	local LocateCommand = require(server.Players.LocateCommand)
	local MobModel = require(client.Entities.MobModel)
	local BloodMoonSky = require(client.Rendering.BloodMoonSky)
	local SurvivorLine = require(client.Ui.SurvivorLine)

	local B, I = Blocks.id, Items.id
	local AIR = Blocks.AIR
	local SIZE = ChunkLayout.SIZE
	local DAY = DayCycle.TICKS_PER_DAY
	local NOON, MIDNIGHT = 6000, 18000
	local Apoc = Config.Apocalypse
	local Moon = Apoc.BloodMoon
	local SURVIVAL, CREATIVE = GameMode.SURVIVAL, GameMode.CREATIVE
	-- Midnight of the first blood moon (night 3: day 2, zero-based).
	local MOON1 = 2 * DAY + MIDNIGHT
	local FLAGS = Protocol.MobFlag
	local soundName: { [number]: string } = {}
	for name, index in SharedSounds.id do
		soundName[index] = name
	end

	--[[ The town, its shed and the shed's bunker (seed 99) ]]

	local SEED = 99
	local made: any = nil
	local originalNew = Cities.new
	Cities.new = function(...)
		local c = originalNew(...)
		made = c
		return c
	end
	local gen: any = TerrainGenerator.new(SEED)
	local cities = made
	Cities.new = originalNew
	local town = gen.cities(-400, -1380, -390, -1370)[1]
	assert(town and town.radius < 64, "seed 99's town at -393, -1376")
	local plan = cities.planAt(town.x, town.z)
	local H = plan.y
	local shed: any, gapHouse: any = nil, nil
	for pv = 0, plan.n - 1 do
		for pu = 0, plan.n - 1 do
			for _, b in CityLayout.lot(plan, pu, pv).buildings do
				if b.kind == "shed" then
					shed = b
				end
			end
		end
	end
	assert(shed, "the town's shed")
	local HX, HZ = shed.hatchX :: number, shed.hatchZ :: number
	-- The ruined house with a doorway (no door) nearest the shed.
	local best = math.huge
	for pv = 0, plan.n - 1 do
		for pu = 0, plan.n - 1 do
			for _, b in CityLayout.lot(plan, pu, pv).buildings do
				if b.kind == "house" and not b.door then
					local d = math.max(math.abs((b.x0 + b.x1) / 2 - HX), math.abs((b.z0 + b.z1) / 2 - HZ))
					if d < best then
						best, gapHouse = d, b
					end
				end
			end
		end
	end
	assert(gapHouse, "a house with a doorway")
	local bunker: any = nil
	for _, p in gen.bunkers(HX, HZ, HX, HZ) do
		if p.city and p.x == HX and p.z == HZ then
			bunker = p
		end
	end
	assert(bunker, "the bunker under the shed")

	-- A building's door cell (its lower half's x, z) and the way out (dx, dz).
	local SIDE_OUT = { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }
	local function doorOf(b: any): (number, number, number, number)
		local side, along = b.doorSide, b.doorAlong
		local x = if side == 1 or side == 3 then b.x0 + along elseif side == 2 then b.x1 else b.x0
		local z = if side == 2 or side == 4 then b.z0 + along elseif side == 3 then b.z1 else b.z0
		local out = SIDE_OUT[side]
		return x, z, out[1], out[2]
	end

	-- The chunks within RADIUS of block column (x, z)'s chunk, generated once (each world gets its
	-- own copies), and the list of them World/Simulation would tick.
	local RADIUS = 3
	local function area(x: number, z: number): any
		local terrain: { { any } } = {}
		local active: { { cx: number, cz: number } } = {}
		for cz = z // SIZE - RADIUS, z // SIZE + RADIUS do
			for cx = x // SIZE - RADIUS, x // SIZE + RADIUS do
				local r = gen.generate(0, cx, cz)
				table.insert(terrain, { cx, cz, r.data, r.height })
				table.insert(active, { cx = cx, cz = cz })
			end
		end
		return { terrain = terrain, active = active }
	end
	local CX, CZ = HX // SIZE, HZ // SIZE
	local TOWN = area(HX, HZ)
	local terrain = TOWN.terrain
	-- A server world over `place`'s chunks (the town's by default) on `generator` (none of its
	-- chunks when another generator is given).
	local function newWorld(generator: any?, place: any?): any
		local world = WorldServer.new(generator or gen)
		if generator == nil then
			for _, c in (place or TOWN).terrain do
				local copy = buffer.create(buffer.len(c[3]))
				buffer.copy(copy, 0, c[3])
				world:install(c[1], c[2], copy, c[4])
			end
		end
		return world
	end

	-- Sets Config table `tbl`'s `key` to `value` for `fn`, whatever happens.
	local function with(tbl: any, key: string, value: any, fn: () -> ())
		local before = tbl[key]
		tbl[key] = value
		local ok, err = pcall(fn)
		tbl[key] = before
		if not ok then
			error(err, 0)
		end
	end

	--[[ The glue with fakes of Roblox ]]

	local GLOBALS = "script, require, game, Instance, Random, Enum, typeof, task, os, Color3"

	--[[
		The server's apocalypse glue over `world` (a WorldServer; `place` the area whose chunks tick,
		the town's by default): Audio/Sounds, Players/Effects, Players/ToggleUse, Mobs/Mobs,
		Players/Eating and Apocalypse/Survival started as the boot script starts them. `h.tick(n)`
		runs n server ticks (the time flows with `h.flow`), `h.join(x, y, z, mode)` adds a player,
		`h.view(player)` brings that player's client (an Entities/MobModel per mob) up to date with
		the Mobs messages sent to them.
	]]
	local function glue(world: any, place: any?): any
		local active = (place or TOWN).active
		local h: any = {
			time = MIDNIGHT,
			flow = false,
			clock = 0,
			world = world,
			players = {},
			sent = {},
			sounds = {},
			hits = {},
			drops = {},
			delayed = {},
			commands = {},
			menus = {},
			handlers = {},
			windows = {},
			held = {},
			biteRolls = {},
			sprinting = false,
			contexts = 0,
			views = {},
		}
		local heartbeat = fakeSignal()
		local playersService: any = {
			PlayerAdded = fakeSignal(),
			PlayerRemoving = fakeSignal(),
			GetPlayers = function(_self)
				return h.players
			end,
			GetPlayerByUserId = function(_self, id: number)
				for _, p in h.players do
					if p.UserId == id then
						return p
					end
				end
				return nil
			end,
		}
		local services = {
			Players = playersService,
			ReplicatedStorage = shared.Parent,
			RunService = { Heartbeat = heartbeat },
			TextChatService = { ChatVersion = "TextChatService" },
		}
		local fakeGame = {
			GetService = function(_, name: string)
				return assert(services[name], `no fake {name}`)
			end,
		}
		local fakeInstance = {
			new = function(class: string): any
				if class == "BindableEvent" then
					local signal = fakeSignal()
					return {
						Event = signal,
						Fire = function(_, ...)
							signal.fire(...)
						end,
					}
				elseif class == "TextChatCommand" then
					local command = { Triggered = fakeSignal(), SetAttribute = function() end }
					table.insert(h.commands, command)
					return command
				end
				error(`no fake {class}`)
			end,
		}
		local fakeEnum = { ChatVersion = { LegacyChatService = "LegacyChatService" } }
		local function fakeTypeof(value: any): string
			if type(value) == "table" and (rawget(value, "__player") or rawget(value, "__instance")) then
				return "Instance"
			end
			return type(value)
		end
		local fakeTask = {
			delay = function(seconds: number, fn: (...any) -> (), ...)
				table.insert(h.delayed, { at = h.clock + seconds, fn = fn, args = table.pack(...) })
			end,
			defer = function(fn: (...any) -> (), ...)
				table.insert(h.delayed, { at = h.clock, fn = fn, args = table.pack(...) })
			end,
			spawn = function(fn: (...any) -> (), ...)
				fn(...)
			end,
		}
		local fakeOs = setmetatable({
			clock = function(): number
				return h.clock
			end,
		}, { __index = os })
		local fakeColor3 = {
			new = function(r: number, g: number, b: number)
				return { R = r, G = g, B = b }
			end,
		}
		-- Random.new for module `name`: Survival's rolls come from `h.biteRolls` while it holds any.
		local function randomFor(name: string): any
			return {
				new = function()
					local roll = lcg(#name * 7919 + 17)
					return {
						NextNumber = function(_)
							if name == "Survival" and #h.biteRolls > 0 then
								return table.remove(h.biteRolls, 1)
							end
							return roll()
						end,
						NextInteger = function(_, a: number, b: number)
							return a + math.floor(roll() * (b - a + 1))
						end,
					}
				end,
			}
		end

		-- The fakes of the server modules that are Roblox glue themselves.
		local characters = {
			hurt = function(player: any, amount: number)
				table.insert(h.hits, { player = player, amount = amount })
				return amount, true
			end,
			knockbackShare = function()
				return 1
			end,
			knockedBack = function() end,
			magicHurt = function(player: any, amount: number, lethal: boolean): number
				local humanoid = player.humanoid
				local before = humanoid.Health
				local after = if lethal
					then math.max(0, before - amount)
					else math.max(math.min(1, before), before - amount)
				humanoid.Health = after
				if after <= 0 and before > 0 then
					humanoid.Died.fire()
				end
				return before - after
			end,
		}
		local inventories = {
			heldTool = function()
				return nil
			end,
			accessories = function()
				return { attackSpeed = 0 }
			end,
			wearTool = function() end,
			get = function(player: any)
				return h.windows[player]
			end,
			heldStack = function(player: any)
				return h.held[player]
			end,
			setHeld = function(player: any, stack: any)
				h.held[player] = stack
			end,
			onMenu = function(name: string, handler: any)
				h.menus[name] = handler
			end,
		}
		local positions = {
			feet = function(player: any)
				if player.Parent == nil then
					return nil, 0, 0
				end
				return player.x, player.y, player.z
			end,
		}
		local toughAsNails = {
			sprinting = function()
				return h.sprinting
			end,
			pauseRegeneration = function() end,
			setRegenBlock = function(fn: any)
				h.regenBlock = fn
			end,
			state = function()
				return nil
			end,
		}
		-- MobSpawning as it is, keeping each tick's context (the glue's: cityAt, the caps, noises).
		local spawning = setmetatable({
			step = function(mobs: any, state: any, context: any, settings: any)
				h.context = context
				h.contexts += 1
				if h.onContext then
					h.onContext(context)
				end
				return RealSpawning.step(mobs, state, context, settings)
			end,
		}, { __index = RealSpawning })

		local root: any = {}
		local function folder(name: string): any
			local f = { Name = name, Parent = root }
			root[name] = f
			return f
		end
		local function stub(value: any): any
			return { __stub = value }
		end
		local function glueNode(parent: any, name: string, path: string)
			parent[name] = { __glue = path, __name = name, __script = { Name = name, Parent = parent } }
		end
		local worldFolder, audio, entities = folder("World"), folder("Audio"), folder("Entities")
		local players, network, apocalypse, mobs =
			folder("Players"), folder("Network"), folder("Apocalypse"), folder("Mobs")
		worldFolder.WorldServer = server.World.WorldServer
		worldFolder.Skylight = server.World.Skylight
		worldFolder.Simulation = stub({
			activeChunks = function()
				return active
			end,
		})
		worldFolder.TimeOfDay = stub({
			get = function()
				return h.time
			end,
		})
		worldFolder.WeatherServer = stub({
			rainingAt = function()
				return false
			end,
			isDayAt = function(_x: number, _z: number, dayTime: number)
				return DayCycle.isDay(dayTime)
			end,
		})
		glueNode(audio, "Sounds", "src/server/Audio/Sounds.luau")
		entities.Entities = stub({
			spawnItem = function(stack: any)
				table.insert(h.drops, stack)
			end,
		})
		players.Characters = stub(characters)
		players.Operators = stub({
			permitted = function()
				return true
			end,
		})
		players.Inventories = stub(inventories)
		players.PlayerPositions = stub(positions)
		players.ToughAsNails = stub(toughAsNails)
		players.GameModeRules = server.Players.GameModeRules
		players.EffectCommand = server.Players.EffectCommand
		players.EffectRules = server.Players.EffectRules
		-- (Eating names the player's use for every client to hear: the module as it is, not
		-- started, so nothing expires.)
		players.UseState = server.Players.UseState
		glueNode(players, "Effects", "src/server/Players/Effects.luau")
		glueNode(players, "Eating", "src/server/Players/Eating.luau")
		glueNode(players, "ToggleUse", "src/server/Players/ToggleUse.luau")
		network.ServerNet = stub({})
		glueNode(apocalypse, "NoiseBus", "src/server/Apocalypse/NoiseBus.luau")
		glueNode(apocalypse, "Infection", "src/server/Apocalypse/Infection.luau")
		glueNode(apocalypse, "Survival", "src/server/Apocalypse/Survival.luau")
		apocalypse.SurvivalRules = server.Apocalypse.SurvivalRules
		mobs.MobWorld = server.Mobs.MobWorld
		mobs.MobSpawning = stub(spawning)
		mobs.MobTracking = server.Mobs.MobTracking
		mobs.SummonCommand = server.Mobs.SummonCommand
		mobs.ZombieDirector = server.Mobs.ZombieDirector
		glueNode(mobs, "Mobs", "src/server/Mobs/Mobs.luau")

		local loaded: { [any]: any } = {}
		local function glueRequire(node: any): any
			if type(node) == "table" then
				local stubbed = rawget(node, "__stub")
				if stubbed ~= nil then
					return stubbed
				end
				local path = rawget(node, "__glue")
				if path then
					if loaded[node] == nil then
						local chunk = luau.load(withHeader(fs.readFile(path), GLOBALS), { debugName = path })
						loaded[node] = chunk(
							rawget(node, "__script"),
							glueRequire,
							fakeGame,
							fakeInstance,
							randomFor(rawget(node, "__name")),
							fakeEnum,
							fakeTypeof,
							fakeTask,
							fakeOs,
							fakeColor3
						)
					end
					return loaded[node]
				end
			end
			return require(node)
		end

		local net = {
			send = function(to: any, kind: number, payload: buffer)
				table.insert(h.sent, { player = to, kind = kind, payload = payload })
			end,
			on = function(kind: number, handler: any)
				h.handlers[kind] = handler
			end,
		}
		h.net = net
		-- (Every sound the server plays, by name.)
		local Sounds = glueRequire(audio.Sounds)
		local play = Sounds.play
		Sounds.play = function(sound: any, x: number, y: number, z: number, except: any, ...)
			local name = if type(sound) == "number" then soundName[sound] else sound
			table.insert(h.sounds, { name = name, x = x, y = y, z = z, except = except })
			return play(sound, x, y, z, except, ...)
		end
		h.NoiseBus = glueRequire(apocalypse.NoiseBus)
		h.Effects = glueRequire(players.Effects)
		h.Effects.start(net)
		glueRequire(players.ToggleUse).start(net, world)
		h.Mobs = glueRequire(mobs.Mobs)
		h.Mobs.start(net, world)
		h.died = {}
		h.Mobs.died:Connect(function(killer: any, kind: string, x: number, y: number, z: number, id: number)
			table.insert(h.died, { killer = killer, kind = kind, x = x, y = y, z = z, id = id })
		end)
		h.bites = {}
		h.Mobs.playerHit:Connect(function(player: any, kind: string, damage: number, fresh: boolean, id: number)
			table.insert(h.bites, { player = player, kind = kind, damage = damage, fresh = fresh, id = id })
		end)
		glueRequire(players.Eating).start(net)
		h.Infection = glueRequire(apocalypse.Infection)
		h.Survival = glueRequire(apocalypse.Survival)
		h.Survival.start(net, world)

		function h.tick(n: number?)
			for _ = 1, n or 1 do
				h.clock += 1 / 20
				if h.flow then
					h.time += 1
				end
				if h.each then
					h.each()
				end
				heartbeat.fire(1 / 20)
				local due = h.delayed
				h.delayed = {}
				for _, task in due do
					if task.at <= h.clock + 1e-9 then
						task.fn(table.unpack(task.args, 1, task.args.n))
					else
						table.insert(h.delayed, task)
					end
				end
			end
		end
		function h.join(x: number, y: number, z: number, mode: string?): any
			local humanoid = {
				__instance = true,
				Health = 20,
				MaxHealth = 20,
				Died = fakeSignal(),
				IsA = function(_, class: string)
					return class == "Humanoid"
				end,
			}
			-- (A blue shirt: a zombie risen from them wears the blue tee.)
			local torso = {
				__instance = true,
				Color = { R = 60 / 255, G = 110 / 255, B = 170 / 255 },
				IsA = function(_, class: string)
					return class == "BasePart"
				end,
			}
			local character = {
				__instance = true,
				FindFirstChildOfClass = function(_, class: string)
					return if class == "Humanoid" then humanoid else nil
				end,
				WaitForChild = function(_, name: string)
					return if name == "Humanoid" then humanoid else nil
				end,
				FindFirstChild = function(_, name: string)
					return if name == "UpperTorso" then torso else nil
				end,
			}
			local attributes = { [GameMode.ATTRIBUTE] = mode or SURVIVAL }
			local n = #h.players + 1
			local p = {
				__player = true,
				Name = `player{n}`,
				DisplayName = `Player{n}`,
				UserId = 1000 + n,
				Parent = playersService,
				x = x,
				y = y,
				z = z,
				Character = character,
				CharacterAdded = fakeSignal(),
				humanoid = humanoid,
				IsA = function(_, class: string)
					return class == "Player" or class == "Instance"
				end,
				GetAttribute = function(_, name: string)
					return attributes[name]
				end,
				SetAttribute = function(_, name: string, value: any)
					attributes[name] = value
				end,
			}
			h.windows[p] = Types.newWindow(Types.newInventory())
			table.insert(h.players, p)
			playersService.PlayerAdded.fire(p)
			return p
		end
		-- The player's view as the glue's last context holds it.
		function h.viewOf(player: any): any
			for _, view in h.context.players do
				if view.key == player then
					return view
				end
			end
			return nil
		end
		-- Messages of `kind` sent to `player` from index `from` on.
		function h.messages(player: any, kind: number, from: number?): { buffer }
			local list = {}
			for i = from or 1, #h.sent do
				local message = h.sent[i]
				if message.player == player and message.kind == kind then
					table.insert(list, message.payload)
				end
			end
			return list
		end
		-- The notices sent to `player`.
		function h.notices(player: any): { string }
			local list = {}
			for _, payload in h.messages(player, Protocol.ServerMessage.Notice) do
				table.insert(list, (Protocol.decodeNotice(payload)))
			end
			return list
		end
		--[[
			Brings `player`'s client up to date: each Mobs message decoded (Protocol.decodeMobs) and
			played onto Entities/MobModel as Entities/MobRenderer does. Returns the client's mobs.
		]]
		function h.view(player: any): { [number]: any }
			local view = h.views[player]
			if view == nil then
				view = { models = {}, read = 0, flags = {} }
				h.views[player] = view
			end
			for i = view.read + 1, #h.sent do
				local message = h.sent[i]
				if message.player == player and message.kind == Protocol.ServerMessage.Mobs then
					local ops = Protocol.decodeMobs(message.payload, MobList.COUNT)
					assert(ops, "a well formed Mobs message")
					for _, op: any in ops do
						if op.op == "spawn" then
							local kind = MobList.get(op.kind) :: MobList.Kind
							view.models[op.id] = MobModel.new(op.id, kind, op.variant, op, h.clock)
						elseif op.op == "move" then
							local model = view.models[op.id]
							if model then
								MobModel.move(model, op.dx, op.dy, op.dz, op.yaw, op.health, op.flags, h.clock)
							end
						elseif op.op == "state" then
							local model = view.models[op.id]
							if model then
								MobModel.apply(model, op, h.clock)
							end
						elseif op.op == "remove" then
							view.models[op.id] = nil
						end
						if op.flags then
							view.flags[op.id] = bit32.bor(view.flags[op.id] or 0, op.flags)
						end
					end
				end
			end
			view.read = #h.sent
			return view.models
		end
		return h
	end

	-- Mob `id` of the glue's world.
	local function mobOf(h: any, id: number): any
		return (h.Mobs.world() :: any):get(id)
	end

	-- The zombies of the glue's world.
	local function zombies(h: any): { any }
		local list = {}
		for _, mob in (h.Mobs.world() :: any):each() do
			if mob.kind.zombie and not mob.dead then
				table.insert(list, mob)
			end
		end
		return list
	end

	-- The feet's y of a mob standing outdoors on column (x, z) near the town's plateau (ground at y -
	-- 1, two cells of air above, the open sky), nil when there is none.
	local function standing(world: any, x: number, z: number): number?
		for y = H + 2, H - 2, -1 do
			local below = world:peekBlock(x, y - 1, z)
			if
				below ~= nil
				and Blocks.isSolid(below)
				and world:peekBlock(x, y, z) == AIR
				and world:peekBlock(x, y + 1, z) == AIR
				and Skylight.open(world, x, y, z) == true
			then
				return y
			end
		end
		return nil
	end

	--[[ 1. The generator the server world runs on ]]

	t.test(
		"glue: the server spawns by Generation/Cities' cityAt: city caps x1.75; police and firefighters only in town",
		function()
			local world = newWorld()
			t.eq(world.generator.cityAt, gen.cityAt, "the server world's generator is the town's")
			local h = glue(world)
			local inTown = h.join(HX + 0.5, H, HZ + 1.5)
			-- (Far from any city: the glue reads only cityAt there, no chunk.)
			local wx, wz = town.x + 3000.5, town.z + 0.5
			t.eq(gen.cityAt(wx, wz), 0, "3 km off: no city")
			local wild = h.join(wx, 90, wz)
			h.time = NOON
			h.tick(1)
			local context = h.context
			t.ok(context ~= nil, "the glue's spawning context")
			t.eq(context.cityAt(HX, HZ), 1, "the shed stands in the town")
			t.eq(context.cityAt(wx, wz), 0)
			for _, p in
				{
					{ town.x, town.z },
					{ HX, HZ },
					{ town.x + town.radius + 9, town.z },
					{ town.x + town.radius + 40, town.z - 7 },
				}
			do
				t.eq(context.cityAt(p[1], p[2]), gen.cityAt(p[1], p[2]), `cityAt({p[1]}, {p[2]}) is the generator's`)
			end
			local margin = gen.cityAt(town.x + town.radius + 9, town.z)
			t.ok(margin > 0 and margin < 1, `the margin is between ({margin})`)
			local capIn, capOut = context.hostileCap(h.viewOf(inTown)), context.hostileCap(h.viewOf(wild))
			t.eq(capIn, 12, "by day in the town: 7 x 1.75")
			t.eq(capOut, 7, "by day in the wild")
			h.time = MIDNIGHT
			h.tick(1)
			t.eq(h.context.hostileCap(h.viewOf(inTown)), 35, "at night in the town")
			t.eq(h.context.hostileCap(h.viewOf(wild)), 20, "at night in the wild")
			with(Config.Mobs, "Spawning", false, function()
				h.time = MOON1
				h.tick(1)
				t.eq(h.context.hostileCap(h.viewOf(inTown)), 49, "the first blood moon in the town: 28 x 1.75")
				t.eq(h.context.hostileCap(h.viewOf(wild)), 28, "and in the wild")
			end)
			t.eq(
				ZombieDirector.cap(Config.Mobs, Apoc, true, gen.cityAt(HX, HZ), 1),
				49,
				"what the director works out from the town's cityAt"
			)

			-- The kind of each natural pack, and how much its centre stands in the town (the context's
			-- cityAt there: what the weights went by). The zombies are cleared every 100 ticks, so packs
			-- keep coming.
			local fresh = newWorld()
			local n = glue(fresh)
			n.time = MIDNIGHT
			n.join(HX + 0.5, H, HZ + 1.5)
			local packs: { { kind: string, city: number } } = {}
			local spawnPack = RealSpawning.spawnPack
			RealSpawning.spawnPack = function(w: any, context: any, kind: any, cx: number, cy: number, cz: number, ...)
				if kind.zombie then
					table.insert(packs, { kind = kind.name, city = context.cityAt(cx + 0.5, cz + 0.5) })
				end
				return spawnPack(w, context, kind, cx, cy, cz, ...)
			end
			local ok, err = pcall(function()
				for round = 1, 30 do
					n.tick(100)
					for _, mob in zombies(n) do
						(n.Mobs.world() :: any):remove(mob.id)
					end
					if round >= 12 and #packs >= 60 then
						break
					end
				end
			end)
			RealSpawning.spawnPack = spawnPack
			if not ok then
				error(err, 0)
			end
			local townPacks, wildPacks, townOnly, wildTownOnly = 0, 0, 0, 0
			for _, pack in packs do
				local onlyTown = pack.kind == "ZombiePolice" or pack.kind == "ZombieFirefighter"
				if pack.city >= 0.5 then
					townPacks += 1
					townOnly += if onlyTown then 1 else 0
				else
					wildPacks += 1
					wildTownOnly += if onlyTown then 1 else 0
				end
			end
			print(
				`    {#packs} natural packs at night: {townPacks} in the town ({townOnly} police or firefighters), {wildPacks} outside it ({wildTownOnly})`
			)
			t.ok(townPacks >= 20, `packs in the town ({townPacks})`)
			t.ok(townOnly >= 1, `the town's police and firefighters come ({townOnly} of {townPacks})`)
			t.eq(wildTownOnly, 0, "never outside a city")
		end
	)

	--[[ 2. A blood moon at /time set ]]

	t.test(
		"glue: a blood moon at /time set on day 3's night: 360, a wave of hunters, the sky; /time set day: 320",
		function()
			local h = glue(newWorld())
			h.time = 2 * DAY + 1000
			local p = h.join(HX + 0.5, H, HZ + 1.5)
			h.tick(1)
			local world = h.Mobs.world() :: any
			t.eq(world.options.maxMobs, Config.Mobs.MaxMobs, "the morning of day 3: 320")
			local line, notice = SurvivorLine.text(h.time, 0, true, Moon)
			t.eq(line, "Day 3 · Survived 0 days", "the day line")
			t.eq(notice, "Blood Moon tonight", "and its warning")
			local function timeCommand(text: string): number
				local result =
					TimeCommand.run(text, { mayUse = true, dayTime = h.time, gameTime = 0, cycle = true }) :: any
				t.ok(result and result.dayTime, `{text} sets the time`)
				return result.dayTime
			end
			h.time = timeCommand("/time set 61000")
			t.eq(DayCycle.day(h.time), 2, "day 3 (zero-based 2)")
			t.ok(DayCycle.timeInDay(h.time) > Moon.Start, "its night")
			h.tick(1)
			t.eq(world.options.maxMobs, Moon.MaxMobs, "a blood moon: 360")
			t.ok(BloodMoonSky.intensity(h.time) > 0, "the client's sky reddens")
			t.eq(select(2, SurvivorLine.text(h.time, 0, true, Moon)), "Blood Moon", "the day line says so")
			local wave = zombies(h)
			t.eq(#wave, Moon.WaveBase + Moon.WavePerMoon, "a wave of 8 at once (k = 1)")
			for _, mob in wave do
				local body = mob.body
				t.eq(mob.ai.hunt, p, "each hunts the player")
				t.ok(mob.persistent, "and stays")
				local d = math.sqrt((body.x - p.x) ^ 2 + (body.z - p.z) ^ 2)
				t.ok(d >= ZombieDirector.WAVE_NEAR - 4 and d <= ZombieDirector.WAVE_FAR + 5, `28-44 blocks out ({d})`)
			end
			for _, mob in wave do
				local x, y, z = math.floor(mob.body.x), math.floor(mob.body.y), math.floor(mob.body.z)
				t.ok(Skylight.open(h.world, x, y, z) == true, `a wave zombie at {x}, {y}, {z} under the open sky`)
			end
			-- On the player's client: the wave spawned, hunting (the Aggressive flag).
			h.tick(2)
			local models = h.view(p)
			local seen = 0
			for _, mob in wave do
				local model = models[mob.id]
				if model then
					seen += 1
					t.ok(bit32.btest(model.flags, FLAGS.Aggressive), "a hunter shows aggressive")
				end
			end
			t.eq(seen, #wave, "every wave zombie on the client")
			-- /time set day: the moon is over.
			h.time = timeCommand("/time set day")
			h.tick(1)
			t.eq(world.options.maxMobs, Config.Mobs.MaxMobs, "/time set day: 320 again at once")
			t.eq(BloodMoonSky.intensity(h.time), 0, "the sky clear")
			for _, mob in zombies(h) do
				t.eq(mob.ai.hunt, nil, "no more hunt")
				t.ok(not mob.persistent, "nor persistence")
			end
			h.time = timeCommand("/time set 61000")
			h.tick(1)
			t.eq(world.options.maxMobs, Moon.MaxMobs, "/time set into the moon: raised again")
		end
	)

	-- Seed 99's big city at -1627, -1513, a street's centre line through the middle of its
	-- downtown (px, pz) and the chunks round it (generated once, on first use).
	local downtownCache: any = nil
	local function downtownOf(): (any, number, number, any)
		if downtownCache == nil then
			local big: any = nil
			for _, site in gen.cities(-1700, -1600, -1550, -1450) do
				if site.radius >= 160 then
					big = site
				end
			end
			assert(big, "seed 99's city at -1627, -1513")
			local px, pz = big.x + 0.5, big.z + 9.5
			downtownCache = { big = big, px = px, pz = pz, area = area(math.floor(px), math.floor(pz)) }
		end
		local d = downtownCache
		return d.big, d.px, d.pz, d.area
	end

	t.test("glue: a blood moon's waves in a downtown land on its streets and lots, never on a roof", function()
		local big, px, pz, downtown = downtownOf()
		local h = glue(newWorld(nil, downtown), downtown)
		h.time = MOON1
		local p = h.join(px, big.y, pz)
		local landed, high = 0, 0
		local seen: { [number]: boolean } = {}
		for _ = 1, 2 * Moon.WaveInterval + 1 do
			h.tick(1)
			for _, mob in zombies(h) do
				if not seen[mob.id] then
					seen[mob.id] = true
					landed += 1
					local ground = gen.column(math.floor(mob.body.x), math.floor(mob.body.z))
					if mob.body.y > ground + MobAI.MAX_FALL then
						high += 1
					end
					t.eq(mob.ai.hunt, p, "a hunter")
				end
			end
		end
		print(`    {landed} wave zombies in the downtown, {high} more than 3 blocks above its ground`)
		t.eq(landed, 3 * (Moon.WaveBase + Moon.WavePerMoon), "three waves of 8, every one delivered")
		t.eq(high, 0, "none on a roof, where it could never come down")
	end)

	t.test("glue: natural spawns in a downtown, night and day, never land higher than 3 above its ground", function()
		-- (The upper floors and roofs: a zombie there could never come down, MobAI.MAX_FALL, and
		-- would fill the city's cap for good. Each zombie is taken away once seen, so packs keep
		-- coming.)
		local big, px, pz, downtown = downtownOf()
		for _, case in { { MIDNIGHT, "midnight" }, { NOON, "noon" } } do
			local h = glue(newWorld(nil, downtown), downtown)
			h.time = case[1]
			h.join(px, big.y, pz)
			local world = h.Mobs.world() :: any
			local landed, high, inside = 0, 0, 0
			for _ = 1, 600 do
				h.tick(1)
				for _, mob in zombies(h) do
					local x, z = math.floor(mob.body.x), math.floor(mob.body.z)
					local above = mob.body.y - gen.column(x, z)
					landed += 1
					if above > MobAI.MAX_FALL then
						high += 1
					end
					if Skylight.open(h.world, x, math.floor(mob.body.y), z) ~= true then
						inside += 1
					end
					world:remove(mob.id)
				end
			end
			print(
				`    {case[2]}: {landed} natural zombies in the downtown ({inside} under a roof), {high} more than 3 blocks above its ground`
			)
			t.ok(landed >= 20, `{case[2]}: they come ({landed})`)
			t.eq(high, 0, `{case[2]}: none on an upper floor or a roof`)
		end
	end)

	--[[ 3. Breaking into the shed ]]

	--[[
		A hunting zombie of the first blood moon outside the shed `steps` blocks out from cell (x,
		z) of its wall (`dx`, `dz` the way out), the player inside at the cell 3 in, the waves off:
		ticks until `done()` or `limit`. Returns the glue, the zombie, the player and the ticks it
		took.
	]]
	local function breakIn(x: number, z: number, dx: number, dz: number, done: (h: any) -> boolean, limit: number)
		local result: any = nil
		with(Config.Mobs, "Spawning", false, function()
			local world = newWorld()
			local h = glue(world)
			h.time = MOON1
			local p = h.join(x - 3 * dx + 0.5, H, z - 3 * dz + 0.5)
			local id = h.Mobs.spawn("Zombie", x + 4 * dx + 0.5, H, z + 4 * dz + 0.5)
			local mob = mobOf(h, id)
			local seenBefore, ticks = false, nil
			local broke = false
			for tick = 1, limit do
				h.tick(1)
				broke = broke or #h.world.pending > 0
				if not broke then
					seenBefore = seenBefore or mob.ai.visible
				end
				if done(h) then
					ticks = tick
					break
				end
			end
			result = { h = h, mob = mob, player = p, ticks = ticks, seen = seenBefore }
		end)
		return result
	end

	t.test("glue: a horde zombie breaks into the town's shed through its Oak Door, unseen, and bites", function()
		local dxCell, dzCell, ox, oz = doorOf(shed)
		local world = newWorld()
		local lower, upper = world:getBlock(dxCell, H, dzCell), world:getBlock(dxCell, H + 1, dzCell)
		t.ok(Blocks.isDoor(lower) and string.find(Blocks.get(lower).name, "OakDoor") ~= nil, "the shed's Oak Door")
		local _, _, open, isUpper = Blocks.doorState(lower)
		t.ok(not open and not isUpper, "shut, its lower half")
		t.ok(Blocks.isDoor(upper), "and its upper half")
		local r = breakIn(dxCell, dzCell, ox, oz, function(h: any): boolean
			return #h.bites > 0
		end, 900)
		local h, mob, p = r.h, r.mob, r.player
		t.ok(r.ticks ~= nil, "it broke in and hit the player")
		t.eq(mob.ai.hunt, p, "a blood moon's hunter")
		t.ok(not r.seen, "never seeing the player behind the door")
		t.eq(h.world:getBlock(dxCell, H, dzCell), AIR, "the door's lower half gone")
		t.eq(h.world:getBlock(dxCell, H + 1, dzCell), AIR, "and its upper half")
		t.eq(#h.drops, 0, "nothing dropped")
		local crash, thuds = 0, 0
		for _, cue in h.sounds do
			if cue.name == "entity.zombie.break_wooden_door" then
				crash += 1
			elseif cue.name == "entity.zombie.attack_wooden_door" then
				thuds += 1
			end
		end
		t.eq(crash, 1, "the door's crash once")
		t.ok(thuds >= 240 / Apoc.Breaking.HitInterval - 2, `a thud every 20 ticks ({thuds})`)
		local bite = h.bites[1]
		t.eq(bite.player, p, "the player inside")
		t.eq(bite.kind, "Zombie")
		t.eq(bite.id, mob.id, "by the zombie that broke in")
		-- The player's client saw it hunting, breaking and swinging (a sync or two on).
		h.tick(4)
		h.view(p)
		local flags = h.views[p].flags
		t.ok(bit32.btest(flags[mob.id] or 0, FLAGS.Breaking), "the Breaking flag reached the client")
		t.ok(bit32.btest(flags[mob.id] or 0, FLAGS.Aggressive), "and Aggressive")
		t.ok(bit32.btest(flags[mob.id] or 0, FLAGS.Attack), "and the attack")
		print(`    the shed's door broken and the player bitten in {r.ticks} ticks`)
	end)

	t.test("glue: a horde zombie breaks through the shed's plank wall (600 ticks a plank)", function()
		local dxCell, dzCell, ox, oz = doorOf(shed)
		-- The opposite wall, level with the door: two planks (the shed's windows are glass).
		local wx, wz = dxCell - 4 * ox, dzCell - 4 * oz
		local world = newWorld()
		t.eq(world:getBlock(wx, H, wz), B.Planks, "a plank wall")
		t.eq(world:getBlock(wx, H + 1, wz), B.Planks, "two high")
		t.eq(Blocks.zombieBreak(B.Planks), 600)
		local r = breakIn(wx, wz, -ox, -oz, function(h: any): boolean
			return #h.bites > 0
		end, 2400)
		local h, p = r.h, r.player
		t.ok(r.ticks ~= nil, "it broke through and hit the player")
		t.eq(h.world:getBlock(wx, H, wz), AIR, "the lower plank gone")
		t.eq(h.world:getBlock(wx, H + 1, wz), AIR, "and the upper")
		t.ok((r.ticks :: number) >= 2 * 600 - 20, `two planks' 1200 ticks at least ({r.ticks})`)
		t.ok((r.ticks :: number) <= 2 * 600 + 200, `and not much more ({r.ticks})`)
		t.eq(#h.drops, 0, "nothing dropped")
		local breaks = 0
		local plankBreak = soundName[SharedSounds.block(B.Planks, "break") :: number]
		for _, cue in h.sounds do
			if cue.name == plankBreak then
				breaks += 1
			end
		end
		t.eq(breaks, 2, "each plank breaks with its own sound")
		t.eq(h.bites[1].player, p)
		print(`    the shed's plank wall broken and the player bitten in {r.ticks} ticks`)
	end)

	--[[ 4. The Brute ]]

	t.test("glue: the Brute walks through a ruined house's doorway, and climbs the shed's bunker ladder", function()
		with(Config.Mobs, "Spawning", false, function()
			local x, z, ox, oz = doorOf(gapHouse)
			local world = newWorld()
			t.eq(world:getBlock(x, H, z), AIR, "a doorway (no door)")
			t.eq(world:getBlock(x, H + 1, z), AIR)
			t.ok(Blocks.isSolid(world:getBlock(x + oz, H, z + ox)), "its frame stands on one side")
			t.ok(Blocks.isSolid(world:getBlock(x - oz, H, z - ox)), "and on the other")
			local h = glue(world)
			h.time = MIDNIGHT
			local p = h.join(x - 3 * ox + 0.5, H, z - 3 * oz + 0.5)
			local id = h.Mobs.spawn("zombie_brute", x + 4 * ox + 0.5, H, z + 4 * oz + 0.5)
			local brute = mobOf(h, id)
			t.eq(brute.kind.name, "ZombieBrute")
			brute.ai.hunt, brute.persistent = p, true
			local through, broke = false, false
			for _ = 1, 400 do
				h.tick(1)
				broke = broke or brute.ai.bx ~= nil
				-- (Its whole box past the wall's line.)
				local inside = (brute.body.x - x - 0.5) * ox + (brute.body.z - z - 0.5) * oz
				if inside < -1 then
					through = true
					break
				end
			end
			t.ok(through, `through the doorway ({brute.body.x}, {brute.body.z})`)
			t.ok(not broke, "breaking nothing on the way")
			t.eq(next(world.edits), nil, "no block changed")
		end)
		-- Up the bunker's ladder: from the airlock's floor, the hatch opened by a right click, the
		-- player in the shed beside it (as far from the shaft as the shed allows).
		with(Config.Mobs, "Spawning", false, function()
			local world = newWorld()
			local h = glue(world)
			h.time = MIDNIGHT
			local p = h.join(HX + 0.5, H, HZ + 1.7)
			h.menus.Toggle(p, HX, H, HZ, world:getBlock(HX, H, HZ))
			t.eq(world:getBlock(HX, H, HZ), B.BunkerHatchOpen, "the hatch open")
			local id = h.Mobs.spawn("ZombieBrute", HX + 0.5, bunker.floor, HZ + 0.5)
			local brute = mobOf(h, id)
			brute.ai.hunt, brute.persistent = p, true
			local top, broke = -math.huge, false
			local first: number? = nil
			for tick = 1, 400 do
				h.tick(1)
				top = math.max(top, brute.body.y)
				broke = broke or brute.ai.bx ~= nil
				first = first or (if #h.bites > 0 then tick else nil)
			end
			print(
				`    the brute up {H - bunker.floor} blocks of ladder: highest feet {top} (the shed's floor {H}), its first hit at tick {first}`
			)
			t.ok(top >= H - 1.2, `it climbed the shaft to its top (highest feet {top})`)
			t.ok(#h.bites > 0 and h.bites[1].id == id, "and hits the player beside the hatch")
			t.eq(h.bites[1] and h.bites[1].kind, "ZombieBrute")
			t.ok(not broke, "breaking nothing")
		end)
	end)

	--[[ 5. The hatch ]]

	t.test("glue: a right click opens the hatch with its sound and noise; climbed out of; shut, it holds", function()
		local world = newWorld()
		local h = glue(world)
		h.time = MIDNIGHT
		local p = h.join(HX + 0.5, bunker.floor, HZ + 0.5)
		t.eq(world:getBlock(HX, H, HZ), B.BunkerHatch, "the hatch shut on the shed's floor")
		t.eq(Blocks.zombieBreak(B.BunkerHatch), 0, "which no zombie breaks")
		-- A zombie may walk over the shut hatch (its plate is ground, the shaft under it no drop:
		-- the shed's middle cell), never into the open shaft.
		local function getBlock(x: number, y: number, z: number): number?
			return world:peekBlock(x, y, z)
		end
		t.eq(MobPhysics.dropAt(getBlock, HX + 0.5, H, HZ + 0.5, 3), 0, "shut: ground")
		h.menus.Toggle(p, HX, H, HZ, B.BunkerHatch)
		t.eq(world:getBlock(HX, H, HZ), B.BunkerHatchOpen, "a right click opens it (Players/ToggleUse)")
		t.eq(MobPhysics.dropAt(getBlock, HX + 0.5, H, HZ + 0.5, 3), nil, "open: a 12 block drop")
		local sound = h.sounds[#h.sounds]
		t.eq(sound.name, "block.bunker_hatch.open", "with its sound")
		t.ok(math.abs(sound.x - HX - 0.5) < 1e-9 and math.abs(sound.z - HZ - 0.5) < 1e-9, "at the hatch")
		t.eq(sound.except, nil, "for everyone near, its user too (nothing predicts a hatch)")
		-- (Heard by the zombies next tick: a door's noise, louder at night.)
		local heard = nil
		h.onContext = function(context: any)
			for _, noise in context.noises or {} do
				if math.abs(noise.x - HX - 0.5) < 1e-9 and math.abs(noise.z - HZ - 0.5) < 1e-9 then
					heard = noise
				end
			end
		end
		h.tick(1)
		h.onContext = nil
		t.ok(heard ~= nil, "a noise at the hatch")
		t.near(heard and heard.radius or 0, Apoc.Noise.Door * Apoc.Noise.NightFactor, 1e-9, "a door's, at night")
		-- Climbing out (Shared/Movement/PlayerPhysics over the server world's blocks), pressed against
		-- the ladder's wall (south) all the way, until standing on the shed's floor clear of the shaft.
		local function climb(): (number, boolean, number)
			local state = PlayerPhysics.new(HX + 0.5, bunker.floor, HZ + 0.5)
			state.onGround = true
			local press = {
				moveX = 0,
				moveZ = 1,
				forward = 1,
				facingX = 0,
				facingZ = 1,
				lookY = 0,
				jump = false,
				sneak = false,
				sprint = false,
			}
			local blocks = {
				getBlock = function(x: number, y: number, z: number): number?
					return world:getBlock(x, y, z)
				end,
			}
			local top, damage = -math.huge, 0
			for _ = 1, 600 do
				local events = PlayerPhysics.tick(state, press :: any, blocks :: any)
				damage += events.damage
				top = math.max(top, state.y)
				if state.onGround and state.y >= H - 1e-9 and state.z - 0.3 >= HZ + 1 then
					return top, true, damage
				end
			end
			return top, false, damage
		end
		local top, out, damage = climb()
		t.ok(out, `out through the open hatch onto the shed's floor (highest feet {top}, the floor {H})`)
		t.eq(damage, 0, "unhurt")
		h.menus.Toggle(p, HX, H, HZ, B.BunkerHatchOpen)
		t.eq(world:getBlock(HX, H, HZ), B.BunkerHatch, "a second click shuts it")
		t.eq(h.sounds[#h.sounds].name, "block.bunker_hatch.close")
		local shutTop, shutOut = climb()
		t.ok(not shutOut, "shut, it keeps the climber in")
		t.near(shutTop, H - 1.8, 1e-6, "the head under it")
	end)

	--[[ 6. Leaving at dawn ]]

	t.test("glue: zombies round a player sealed in the shed's bunker leave at dawn, down to the town's 12", function()
		with(Config.Mobs, "Spawning", false, function()
			local world = newWorld()
			local h = glue(world)
			h.time = 23000
			h.flow = true
			local p = h.join(HX + 0.5, bunker.floor, HZ + 0.5)
			t.eq(world:getBlock(HX, H, HZ), B.BunkerHatch, "sealed: the hatch shut")
			-- 20 zombies standing round the shed, 6-20 blocks out.
			local placed = 0
			local taken: { [string]: boolean } = {}
			for ring = 6, 20, 2 do
				for k = 0, 15 do
					local angle = k / 16 * math.pi * 2 + ring
					local x = math.floor(HX + 0.5 + math.cos(angle) * ring)
					local z = math.floor(HZ + 0.5 + math.sin(angle) * ring)
					local y = standing(world, x, z)
					if y and not taken[`{x // 2},{z // 2}`] and placed < 20 then
						taken[`{x // 2},{z // 2}`] = true
						if h.Mobs.spawn("Zombie", x + 0.5, y, z + 0.5) ~= 0 then
							placed += 1
						end
					end
				end
			end
			t.eq(placed, 20, "20 zombies round the shed")
			local function near(): number
				local n = 0
				for _, mob in zombies(h) do
					local dx, dy, dz = mob.body.x - p.x, mob.body.y - p.y, mob.body.z - p.z
					if dx * dx + dy * dy + dz * dz <= ZombieDirector.LEAVE_RADIUS ^ 2 then
						n += 1
					end
				end
				return n
			end
			local leavers: { [number]: boolean } = {}
			local dawn: number? = nil
			local removed = 0
			local before = #zombies(h)
			for _ = 1, 2400 do
				h.tick(1)
				for _, mob in zombies(h) do
					if mob.ai.leave > 0 and not leavers[mob.id] then
						leavers[mob.id] = true
						dawn = dawn or h.time
					end
				end
			end
			removed = before - #zombies(h)
			local sent = 0
			for _ in leavers do
				sent += 1
			end
			t.ok(dawn ~= nil and DayCycle.isDay(dawn :: number), `a leave round at dawn ({dawn})`)
			t.ok(sent >= 20 - 12, `the surplus over the town's day cap of 12 sent away ({sent})`)
			t.ok(near() <= 12, `at most 12 within 32 blocks after ({near()})`)
			t.ok(removed >= 6, `the leavers gone out of sight ({removed})`)
			t.eq(world:getBlock(HX, H, HZ), B.BunkerHatch, "the hatch held")
			print(`    {sent} of 20 sent away at dawn ({dawn}), {removed} gone, {near()} left within 32 blocks`)
		end)
	end)

	--[[ 7. Bites, infection, medicine, kills, rising ]]

	t.test("glue: a bite through Mobs.playerHit infects; /effect, a poultice and Antibiotics; kills; rising", function()
		with(Config.Mobs, "Spawning", false, function()
			local world = newWorld()
			local h = glue(world)
			h.time = MIDNIGHT
			local p = h.join(HX - 0.5, H, HZ + 0.5)
			h.tick(1)
			-- A zombie at the player; the roll of its bite and of the wound both come up.
			h.biteRolls = { 0, 0 }
			local id = h.Mobs.spawn("Zombie", HX + 1.5, H, HZ + 0.5)
			local zombie = mobOf(h, id)
			zombie.ai.target, zombie.ai.goal = p, "chase"
			for _ = 1, 200 do
				h.tick(1)
				if #h.bites > 0 then
					break
				end
			end
			t.ok(#h.bites > 0, "the zombie's hit landed (Mobs.playerHit)")
			t.eq(h.bites[1].kind, "Zombie")
			t.ok(h.bites[1].fresh, "a fresh hurt")
			t.eq(h.Infection.stage(p), 1, "infected: stage I (Apocalypse/Infection.bite)")
			t.ok(h.Effects.has(p, "Infection"), "an Infection effect (Players/Effects' external adapter)")
			t.eq(h.Effects.ticks(p, "Bleeding"), Apoc.Bleeding.Ticks, "and a wound: Bleeding")
			t.eq(h.Effects.amplifier(p, "Bleeding"), 0)
			-- The player kills it: a kill on the Survivor record, sent to them.
			local from = #h.sent
			t.ok(h.Mobs.damage(id, 100, p) > 0, "the player kills the zombie")
			h.tick(2)
			t.eq(h.died[#h.died].killer, p, "Mobs.died names the killer")
			t.eq(h.died[#h.died].kind, "Zombie")
			local records = h.messages(p, Protocol.ServerMessage.Survivor, from + 1)
			t.ok(#records > 0, "a Survivor message")
			t.eq((Protocol.decodeSurvivor(records[#records]) :: any).kills, 1, "one zombie killed")
			-- The client's Effects message: the infection's stage as its amplifier.
			local function effectsOf(): { [number]: any }
				local list = h.messages(p, Protocol.ServerMessage.Effects)
				local entries = Protocol.decodeEffects(list[#list]) :: any
				local byId = {}
				for _, entry in entries do
					byId[entry.effect] = entry
				end
				return byId
			end
			h.Effects.tick(p, SURVIVAL, 20, 20)
			local shown = effectsOf()
			t.ok(shown[Effects.id.Infection] ~= nil, "the client hears of it")
			t.eq(shown[Effects.id.Infection].amplifier, 0, "Infection I")
			t.ok(shown[Effects.id.Bleeding] ~= nil, "and the bleeding")
			-- /effect give takes it on a stage (12000 ticks) at a time.
			local effectCommand = nil
			for _, command in h.commands do
				if command.Name == "IceVoxelEffect" then
					effectCommand = command
				end
			end
			t.ok(effectCommand ~= nil, "/effect listens")
			local function chat(command: any, text: string)
				command.Triggered.fire({ UserId = p.UserId }, text)
			end
			chat(effectCommand, `/effect give {p.Name} infection 600`)
			chat(effectCommand, `/effect give {p.Name} infection 600`)
			t.eq(h.Infection.stage(p), 3, "two stages on: III")
			h.Effects.tick(p, SURVIVAL, 20, 20)
			t.eq(effectsOf()[Effects.id.Infection].amplifier, 2, "Infection III on the client")
			-- Players/Eating: a Herbal Poultice, held and used for its ticks.
			local eat = h.handlers[Protocol.ClientMessage.Eat]
			local function use(item: number): boolean
				h.held[p] = { item = item, count = 2 }
				eat(p, Protocol.encodeEat(Protocol.EatAction.Start))
				h.tick(Foods.useTicks(Foods.of(item) :: any))
				eat(p, Protocol.encodeEat(Protocol.EatAction.Finish))
				return (h.held[p] :: any).count == 1
			end
			t.ok(use(I.HerbalPoultice), "a poultice used up")
			t.eq(h.Infection.stage(p), 2, "back a stage")
			t.eq(h.sounds[#h.sounds].name, "item.bandage.apply", "its sound for everyone else")
			chat(effectCommand, `/effect give {p.Name} infection 600`)
			t.eq(h.Infection.stage(p), 3)
			t.ok(use(I.Antibiotics), "Antibiotics used up")
			t.eq(h.Infection.progress(p), 0, "cured")
			t.ok(not h.Effects.has(p, "Infection"), "the effect gone")
			t.eq(
				h.Effects.ticks(p, "Weakness"),
				InfectionRules.AFTERMATH_TICKS,
				"a minute's Weakness after a late cure"
			)
			-- Bitten again (a roll at most every RollInterval ticks), then dead: they rise where
			-- they fell, in the blue tee.
			h.tick(Apoc.Infection.RollInterval)
			h.biteRolls = { 0, 0 }
			local again = mobOf(h, h.Mobs.spawn("ZombieWorker", HX + 1.5, H, HZ + 0.5))
			again.ai.target, again.ai.goal = p, "chase"
			local bites = #h.bites
			for _ = 1, 200 do
				h.tick(1)
				if #h.bites > bites then
					break
				end
			end
			t.ok(#h.bites > bites, "bitten again")
			t.ok(h.Infection.stage(p) >= 1, "infected again")
			h.Mobs.damage(again.id, 100, p)
			h.tick(2)
			local before: { [number]: boolean } = {}
			for _, mob in zombies(h) do
				before[mob.id] = true
			end
			p.humanoid.Health = 0
			p.humanoid.Died.fire()
			t.eq(h.Infection.progress(p), 0, "death clears it")
			h.tick(Apoc.Zombies.RiseDelay + 2)
			local risen = {}
			for _, mob in zombies(h) do
				if not before[mob.id] then
					table.insert(risen, mob)
				end
			end
			t.eq(#risen, 1, "a zombie rose")
			local zombie1 = risen[1]
			t.eq(zombie1 and zombie1.kind.name, "Zombie")
			t.ok(
				zombie1 and math.abs(zombie1.body.x - p.x) < 0.5 and math.abs(zombie1.body.z - p.z) < 0.5,
				"where they fell"
			)
			local kind = MobList.get(MobList.find("Zombie") :: number) :: MobList.Kind
			local look = MobList.look(kind, zombie1.variant)
			t.eq(look, (MobList.looksOf(kind) :: any)[2], "in the blue tee, as their shirt")
			local notices = h.notices(p)
			t.eq(notices[#notices], `{p.DisplayName} rose again`, "everyone is told")
		end)
	end)

	--[[ 8. Sprinting is a noise ]]

	t.test("glue: a sprint is a noise the director hears (louder at night) and a zombie goes to look", function()
		with(Config.Mobs, "Spawning", false, function()
			local world = newWorld()
			local h = glue(world)
			h.time = MIDNIGHT
			-- A zombie on the town's ground; a creative player (no zombie targets them, so only
			-- the noise can bring one) going round it 6 blocks away.
			local zx, zz = math.floor(town.x) + 3, math.floor(town.z) + 20
			local zy = nil
			for dx = 0, 12 do
				zy = standing(world, zx + dx, zz)
				if zy then
					zx += dx
					break
				end
			end
			t.ok(zy ~= nil, "ground for the zombie")
			local id = h.Mobs.spawn("Zombie", zx + 0.5, zy, zz + 0.5)
			local zombie = mobOf(h, id)
			local angle = 0
			local p = h.join(zx + 0.5 + 6, zy, zz + 0.5, CREATIVE)
			local loud = 0
			h.onContext = function(context: any)
				for _, noise in context.noises or {} do
					if math.abs(noise.x - p.x) < 2 and math.abs(noise.z - p.z) < 2 then
						loud = math.max(loud, noise.radius)
					end
				end
			end
			local function step(speed: number)
				angle += speed / 6
				p.x, p.z = zx + 0.5 + math.cos(angle) * 6, zz + 0.5 + math.sin(angle) * 6
			end
			-- Walking 2 blocks a second round it: no noise.
			for _ = 1, 60 do
				step(0.1)
				h.tick(1)
			end
			t.eq(loud, 0, "walking makes none")
			t.ok(zombie.ai.goal ~= "investigate", "the zombie stays")
			-- Sprinting at 5.6 a second: a noise every second.
			h.sprinting = true
			for _ = 1, 45 do
				step(0.28)
				h.tick(1)
				if zombie.ai.goal == "investigate" then
					break
				end
			end
			h.onContext = nil
			t.near(loud, Apoc.Noise.Sprint * Apoc.Noise.NightFactor, 1e-9, "a sprint's 8, x 1.25 at night")
			t.eq(zombie.ai.goal, "investigate", "the zombie goes to look")
		end)
	end)

	--[[ 9. Op 6 through the client's decoding ]]

	t.test("glue: op 6 through the client's MobModel: its baselines are the server's positions exactly", function()
		local h = glue(newWorld())
		h.time = MOON1
		local p = h.join(HX + 0.5, H, HZ + 1.5)
		local syncs, checked, moved, deltas = 0, 0, 0, 0
		local last: { [number]: { number } } = {}
		for tick = 1, 300 do
			h.tick(1)
			if tick % Config.Mobs.SyncTicks == 0 then
				syncs += 1
				local models = h.view(p)
				for _, mob in (h.Mobs.world() :: any):each() do
					local now = MobTracking.snapshot(mob)
					local model = models[mob.id]
					local dx, dy, dz = mob.body.x - p.x, mob.body.y - p.y, mob.body.z - p.z
					if model and dx * dx + dy * dy + dz * dz <= MobTracking.FAR * MobTracking.FAR then
						checked += 1
						-- (Within FAR every sync is due: the client holds this sync's state.)
						t.eq(model.bx * Protocol.MOB_POSITION_SCALE, now.x, "x to the step")
						t.eq(model.by * Protocol.MOB_POSITION_SCALE, now.y, "y to the step")
						t.eq(model.bz * Protocol.MOB_POSITION_SCALE, now.z, "z to the step")
						t.eq(model.flags, now.flags, "the flags")
						t.eq(model.health, now.health, "the health")
						local x, _, z = MobModel.pose(model, h.clock + 10)
						t.eq(x, model.bx, "the glide ends on the baseline")
						t.eq(z, model.bz)
						local before = last[mob.id]
						if before and (before[1] ~= now.x or before[3] ~= now.z) then
							moved += 1
						end
						last[mob.id] = { now.x, now.y, now.z }
					end
				end
			end
		end
		for _, payload in h.messages(p, Protocol.ServerMessage.Mobs) do
			for _, op in Protocol.decodeMobs(payload, MobList.COUNT) :: { any } do
				if op.op == "move" then
					deltas += 1
				end
			end
		end
		print(`    {syncs} syncs, {checked} baselines checked, {moved} moves seen, {deltas} op 6 deltas decoded`)
		t.ok(checked >= 200, `zombies on the client to check ({checked})`)
		t.ok(moved >= 50 and deltas >= 50, `moving, by op 6 deltas ({moved}, {deltas})`)
	end)

	--[[ 10. /summon and /locate ]]

	t.test("glue: /summon zombie_brute through the chat command; /locate structure city, bunker, #ruins", function()
		local h = glue(newWorld())
		h.time = NOON
		local p = h.join(HX + 0.5, H, HZ + 1.5)
		h.tick(1)
		local summon = nil
		for _, command in h.commands do
			if command.Name == "IceVoxelSummon" then
				summon = command
			end
		end
		t.ok(summon ~= nil, "/summon listens")
		local before = #zombies(h)
		summon.Triggered.fire({ UserId = p.UserId }, "/summon zombie_brute ~2 ~ ~")
		local brutes = {}
		for _, mob in zombies(h) do
			if mob.kind.name == "ZombieBrute" then
				table.insert(brutes, mob)
			end
		end
		t.eq(#zombies(h), before + 1, "one summoned")
		t.eq(#brutes, 1, "a Brute")
		t.near(brutes[1].body.x, p.x + 2, 1e-9, "two blocks east of the player")
		local notices = h.notices(p)
		t.eq(
			notices[#notices],
			`Summoned new {(MobList.get(MobList.find("ZombieBrute") :: number) :: any).displayName}`
		)
		summon.Triggered.fire({ UserId = p.UserId }, "/summon minecraft:ZOMBIE_BRUTE")
		t.eq(#zombies(h), before + 2, "any spelling")
		summon.Triggered.fire({ UserId = p.UserId }, "/summon creeper")
		notices = h.notices(p)
		t.eq(notices[#notices - 1], "Unknown entity: creeper", "the creeper is gone")

		-- /locate from beside the shed: the bunker under it, the town, and #ruins' nearer.
		local context = { mayUse = true, registries = LocateCommand.registries({}) }
		local function locate(text: string): (any, any)
			local result = LocateCommand.run(text, context) :: any
			t.ok(result and result.request, `{text} resolves`)
			local found = LocateCommand.search(result.request, gen, nil, HX + 3.5, H, HZ + 0.5)
			return result.request, found
		end
		local request, found = locate("/locate structure bunker")
		t.ok(found ~= nil, "a bunker")
		t.eq(found.x, HX, "the shed's")
		t.eq(found.z, HZ)
		local text = LocateCommand.success(request, found)
		t.ok(string.find(text, "The nearest bunker is at", 1, true) ~= nil, text)
		request, found = locate("/locate structure city")
		t.ok(found ~= nil, "a city")
		t.eq(found.x, town.x, "the town")
		t.eq(found.z, town.z)
		request, found = locate("/locate structure #ruins")
		t.eq(found.id, "bunker", "#ruins answers the nearer: the bunker under the shed")
		t.eq(LocateCommand.success(request, found):match("^The nearest ([^%[]+) is"), "#ruins (bunker)")
	end)

	--[[ 11. Old worlds ]]

	t.test("glue: an old world (no `ruins` in its meta) has no cities, roads, bunkers or city caps", function()
		local function settings(options: { [string]: any }): any
			return {
				name = "Old",
				gameMode = SURVIVAL,
				difficulty = 2,
				allowCommands = true,
				worldType = WorldTypes.DEFAULT,
				options = options,
				seed = SEED,
			}
		end
		local function reread(): any
			local meta = WorldMeta.new("w0000old1", settings({ structures = true }), 1)
			return WorldMeta.settings(WorldMeta.read(WorldMeta.stored(meta)) :: any) :: any
		end
		local read = reread()
		t.eq(read.options.ruins, false, "a meta without the key reads Ruins off")
		local old: any = WorldTypes.create(read.worldType, read.seed, read.options)
		local R = 4096
		t.eq(#old.cities(town.x - R, town.z - R, town.x + R, town.z + R), 0, "no cities")
		t.eq(#old.roads(town.x - R, town.z - R, town.x + R, town.z + R), 0, "no roads")
		t.eq(#old.bunkers(town.x - R, town.z - R, town.x + R, town.z + R), 0, "no bunkers")
		t.eq(old.prepare, nil, "nothing to prepare")
		t.eq(old.cityAt(HX, HZ), 0, "the town's ground is no city")
		local plain = TerrainGenerator.new(SEED, { structures = true, ruins = false })
		local a, b, c = old.generate(0, CX, CZ), plain.generate(0, CX, CZ), gen.generate(0, CX, CZ)
		t.ok(buffer.tostring(a.data) == buffer.tostring(b.data), "the shed's chunk is the plain world's")
		t.ok(buffer.tostring(a.data) ~= buffer.tostring(c.data), "not the new world's")
		local registries = { mayUse = true, registries = LocateCommand.registries({}) }
		for _, text in { "/locate structure city", "/locate structure bunker", "/locate structure #ruins" } do
			local result = LocateCommand.run(text, registries) :: any
			t.eq(LocateCommand.search(result.request, old, nil, HX, H, HZ), nil, `{text}: none`)
		end
		-- The zombies' caps there: the wild's.
		local h = glue(newWorld(old))
		h.time = NOON
		local p = h.join(HX + 0.5, H, HZ + 0.5)
		h.tick(1)
		t.eq(h.context.hostileCap(h.viewOf(p)), 7, "by day, the wild's cap of 7")
		-- Config.Cities.OldWorlds opts such worlds in.
		with(Config.Cities, "OldWorlds", true, function()
			local opted = reread()
			t.eq(opted.options.ruins, true, "OldWorlds: Ruins on")
			local again: any = WorldTypes.create(opted.worldType, opted.seed, opted.options)
			t.ok(#again.cities(town.x - 10, town.z - 10, town.x + 10, town.z + 10) == 1, "the town is back")
		end)
	end)

	--[[ 12. One blood moon schedule ]]

	t.test("glue: the server's moon, the client's sky and day line and the survivor's count agree", function()
		local record = SurvivalRules.new()
		local counted = 0
		local disagreements = 0
		local nights: { [number]: boolean } = {}
		for time = 0, 10 * DAY, 5 do
			local up, k = ZombieDirector.moon(Apoc, time)
			local sky = BloodMoonSky.intensity(time) > 0
			local _, notice = SurvivorLine.text(time, 0, true, Moon)
			local maxMobs = ZombieDirector.limits(Config.Mobs, Apoc, time)
			if up ~= sky or up ~= (notice == "Blood Moon") or up ~= (maxMobs == Moon.MaxMobs) then
				disagreements += 1
			end
			if up then
				nights[DayCycle.day(time)] = true
				t.eq(k, BloodMoon.number(DayCycle.day(time), Moon), "the director's k is the moon's number")
			end
		end
		for time = 0, 10 * DAY do
			if SurvivalRules.moonTick(record, time, Moon) then
				counted += 1
			end
		end
		t.eq(disagreements, 0, "the server's waves and limits, the sky and the day line, tick by tick")
		local list = {}
		for day in nights do
			table.insert(list, day + 1)
		end
		table.sort(list)
		t.eq(table.concat(list, " "), "3 6 9", "the blood moons of ten days: nights 3, 6 and 9")
		t.eq(counted, 3, "a survivor counts each one at its set")
		t.eq(record.moons, 3)
	end)

	--[[ 13. Everything new is reachable ]]

	t.test("glue: every new block, item and sound is reachable; sounds overridable, textures blank", function()
		-- Blocks the town and its bunker hold (the chunks round the shed).
		local generated: { [number]: boolean } = {}
		for _, c in terrain do
			local data = c[3]
			for i = 0, buffer.len(data) // 2 - 1 do
				generated[buffer.readu16(data, i * 2)] = true
			end
		end
		local made: { [number]: boolean } = {}
		for _, recipe in Crafting.recipes do
			made[recipe.result] = true
		end
		for _, recipe in Smelting.recipes() do
			made[recipe.result.item] = true
		end
		local looted: { [string]: boolean } = {}
		for _, pools in ScavengeLoot.TABLES do
			for _, pool in pools do
				for _, entry in pool.entries do
					if entry[1] then
						looted[entry[1]] = true
					end
				end
			end
		end
		local dropped: { [string]: boolean } = {}
		for _, kind in MobList.kinds do
			for _, drop in kind.drops or {} do
				dropped[drop.item] = true
			end
		end
		local FIRST_BLOCK, LAST_BLOCK = B.Asphalt, B.CaveCeilingLamp
		local reach: { [number]: string } = {}
		local function reachable(id: number): string?
			if generated[id] then
				return "generated"
			elseif made[id] then
				return "made"
			end
			local def = Blocks.get(id)
			local toggled = Blocks.toggleOf(id)
			if toggled and (generated[toggled] or made[toggled]) then
				return "toggled"
			elseif Blocks.isCaveTwin(id) then
				return "a twin"
			elseif def.item and Items.find(def.item) and made[Items.find(def.item) :: number] then
				return "turned"
			end
			return nil
		end
		for id = FIRST_BLOCK, LAST_BLOCK do
			local how = reachable(id)
			reach[id] = how or "-"
			t.ok(how ~= nil, `{Blocks.get(id).name} is generated, made, toggled or turned`)
			local faces = TexturePack.Blocks[Blocks.get(id).item or Blocks.get(id).name]
			for _, name in faces or {} do
				t.ok(TexturePack.Textures[name] ~= nil, `{name} is a texture`)
			end
		end
		-- (The fourth sheet made the roads', the concrete's, the aged bricks', the supply crate's
		-- and the medicine cabinet's: tests/spec/DataSheet checks their ids. The rest wait.)
		for _, name in { "rusty metal", "bunker hatch" } do
			local texture = TexturePack.Textures[name]
			t.eq(texture and texture.Color, "", `the {name} texture is blank, ready to fill`)
		end
		for _, name in
			{
				"asphalt",
				"cracked asphalt",
				"road line",
				"road line yellow",
				"concrete",
				"cracked concrete",
				"mossy concrete",
				"cracked bricks",
				"mossy bricks",
				"supply crate side",
				"supply crate top",
				"medicine cabinet side",
				"medicine cabinet top",
			}
		do
			local texture = TexturePack.Textures[name]
			t.ok(texture ~= nil and texture.Color ~= "", `the {name} texture is made`)
		end
		for name, how in { Asphalt = "generated", RoadLine = "generated", RoadLineYellow = "generated" } do
			t.eq(reach[B[name]], how, `{name} lies in the town's streets`)
		end
		for id = I.Bandage, I.HerbalPoultice do
			local name = Items.get(id).name
			t.ok(made[id] or looted[name] or dropped[name], `{name} is made, found or dropped`)
			t.eq(TexturePack.Icons[name], "", `{name}'s icon blank, ready to fill`)
		end
		-- Sounds: each new event an ordinary one (SoundService.IceVoxelSounds overrides any event by
		-- name), and something plays it.
		local code = {}
		for _, path in sources("src", {}) do
			if not string.find(path, "SoundList", 1, true) then
				table.insert(code, fs.readFile(path))
			end
		end
		local everything = table.concat(code, "\n")
		local voices: { [string]: boolean } = {}
		for _, kind in MobList.kinds do
			for _, sound in kind.sounds or {} do
				voices[sound] = true
			end
		end
		for _, name in
			{
				"entity.zombie.ambient",
				"entity.zombie.attack_wooden_door",
				"entity.zombie.break_wooden_door",
				"entity.zombie_screamer.scream",
				"block.bunker_hatch.open",
				"block.bunker_hatch.close",
				"item.bandage.apply",
				"item.medkit.use",
				"item.pills.swallow",
				"ambient.blood_moon.rise",
				"entity.zombie_runner.hurt",
				"entity.zombie_runner.death",
				"entity.zombie_brute.hurt",
				"entity.zombie_brute.death",
				"entity.zombie_screamer.hurt",
				"entity.zombie_screamer.death",
			}
		do
			local index = SharedSounds.find(name)
			t.ok(index ~= nil, `{name} is a SoundList event`)
			local event = SharedSounds.get(name) :: any
			t.ok(event and event.name == name, `{name}: an ordinary event, overridable by its name`)
			t.ok(
				string.find(everything, `"{name}"`, 1, true) ~= nil or voices[name],
				`{name} is played (by name, or as a mob's voice)`
			)
		end
	end)
end
