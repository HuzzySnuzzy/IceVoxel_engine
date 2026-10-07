--[[
	Creating the world from the title screen: seeds as Minecraft reads them (Shared/WorldSettings:
	numbers as they are, text by Java's String.hashCode), the Create World request's checks and a
	world type's declared settings, the server's one creation (World/WorldInfo: the boot's
	startWorld with Config.MainMenu.Enabled off, and from the menu), the protocol's messages, the
	title screen's buttons and splash (client Ui/TitleRules) and the Create World form (client
	Ui/CreateWorldForm).
]]

return function(t, shared, require, server, client)
	local Config = require(shared.Config)
	local GameMode = require(shared.GameMode)
	local Protocol = require(shared.Net.Protocol)
	local WorldSettings = require(shared.WorldSettings)
	local WorldTypes = require(shared.Generation.WorldTypes)
	local WorldInfo = require(server.World.WorldInfo)
	local TitleRules = require(client.Ui.TitleRules)
	local CreateWorldForm = require(client.Ui.CreateWorldForm)

	local function never(): number
		error("no random seed expected")
	end

	local function request(overrides: { [string]: any }?)
		local base = WorldSettings.defaults()
		for key, value in overrides or {} do
			(base :: any)[key] = value
		end
		return base
	end

	-- A world type with every kind of setting, registered for a test and taken out after.
	local function withCustomType(fn: () -> ())
		WorldTypes.register({
			id = "spec.custom",
			name = "Custom",
			description = "A spec's",
			create = function(seed, options)
				return WorldTypes.create(WorldTypes.DEFAULT, seed, options)
			end,
			settings = {
				{ key = "flat", name = "Flat", kind = "toggle", default = false },
				{
					key = "biome",
					name = "Biome",
					kind = "choice",
					choices = { "plains", "desert" },
					names = { "Plains", "Desert" },
					default = "plains",
				},
				{ key = "preset", name = "Preset", kind = "text", default = "stone", maxLength = 12 },
			},
		})
		local ok, err = pcall(fn)
		local index = table.find(WorldTypes.list, WorldTypes.get("spec.custom"))
		if index then
			table.remove(WorldTypes.list, index)
		end
		if not ok then
			error(err, 0)
		end
	end

	--[[ Seeds ]]

	t.test("world creation: text seeds are Java's String.hashCode", function()
		t.eq(WorldSettings.hashCode(""), 0)
		t.eq(WorldSettings.hashCode("a"), 97)
		t.eq(WorldSettings.hashCode("hello"), 99162322)
		t.eq(WorldSettings.hashCode("Hello World"), -862545276, "wraps to a negative int")
		t.eq(WorldSettings.hashCode("glacier"), 108181935)
		t.eq(WorldSettings.hashCode("Minecraft"), -1595926131)
		t.eq(WorldSettings.hashCode("é"), 233, "a UTF-16 unit, not UTF-8 bytes")
		t.eq(WorldSettings.hashCode("😀"), 1772899, "a surrogate pair")
	end)

	t.test("world creation: seeds as Minecraft's WorldOptions.parseSeed reads them", function()
		t.eq(WorldSettings.parseSeed(""), nil, "blank: random")
		t.eq(WorldSettings.parseSeed("   "), nil, "only spaces: random")
		t.eq(WorldSettings.parseSeed("12345"), 12345)
		t.eq(WorldSettings.parseSeed("-42"), -42)
		t.eq(WorldSettings.parseSeed("+7"), 7)
		t.eq(WorldSettings.parseSeed("  42 "), 42, "trimmed")
		t.eq(WorldSettings.parseSeed("-0"), 0)
		t.eq(WorldSettings.parseSeed("007"), 7)
		t.eq(WorldSettings.parseSeed("glacier"), 108181935, "text")
		t.eq(WorldSettings.parseSeed("12a"), WorldSettings.hashCode("12a"), "not a number")
		t.eq(WorldSettings.parseSeed("1 2"), WorldSettings.hashCode("1 2"))
		t.eq(WorldSettings.parseSeed("9007199254740991"), 9007199254740991, "the largest exact one")
		t.eq(WorldSettings.parseSeed("9007199254740993"), WorldSettings.hashCode("9007199254740993"), "beyond: text")
		t.eq(WorldSettings.seedText(9007199254740991), "9007199254740991", "printed in full")
		t.eq(WorldSettings.seedText(-42), "-42")
	end)

	--[[ Checking a request ]]

	t.test("world creation: a request becomes the world's settings", function()
		local settings = WorldSettings.validate(
			request({ name = "  My World  ", gameMode = GameMode.CREATIVE, difficulty = 3, seed = "glacier" }),
			never
		) :: any
		t.ok(settings ~= nil)
		t.eq(settings.name, "My World", "trimmed")
		t.eq(settings.gameMode, GameMode.CREATIVE)
		t.eq(settings.difficulty, 3)
		t.eq(settings.seed, 108181935)
		t.eq(settings.worldType, WorldTypes.DEFAULT)
		t.eq(settings.options.structures, true, "Generate Structures")
		local random = WorldSettings.validate(request({ seed = "" }), function()
			return 777
		end) :: any
		t.eq(random.seed, 777, "blank seed: the random one")
		local plain = WorldSettings.validate(request({ structures = false }), function()
			return 1
		end) :: any
		t.eq(plain.options.structures, false)
	end)

	t.test("world creation: names are cleaned, at most 32 characters", function()
		t.eq(WorldSettings.cleanName(""), WorldSettings.DEFAULT_NAME, "blank")
		t.eq(WorldSettings.cleanName("   "), WorldSettings.DEFAULT_NAME)
		t.eq(WorldSettings.cleanName("a\nb\tc"), "abc", "control characters dropped")
		t.eq(WorldSettings.cleanName(string.rep("x", 40)), string.rep("x", 32))
		local long = string.rep("é", 40)
		t.eq(utf8.len(WorldSettings.cleanName(long)), 32, "characters, not bytes")
		t.eq(WorldSettings.cleanName("\255bad"), WorldSettings.DEFAULT_NAME, "invalid UTF-8")
	end)

	t.test("world creation: bad requests are refused with a reason", function()
		local function refused(overrides): string?
			local settings, problem = WorldSettings.validate(request(overrides), function()
				return 1
			end)
			t.eq(settings, nil)
			return problem
		end
		t.ok(string.find(refused({ worldType = "nope" }) or "", "Unknown world type", 1, true) ~= nil)
		t.ok(refused({ gameMode = GameMode.SPECTATOR }) ~= nil, "no spectator worlds")
		t.ok(refused({ gameMode = "Hardcore" }) ~= nil)
		t.ok(refused({ difficulty = 4 }) ~= nil)
		t.ok(refused({ difficulty = 1.5 }) ~= nil)
		t.ok(string.find(refused({ seed = string.rep("1", 33) }) or "", "too long", 1, true) ~= nil)
		-- A hidden world type: not from the menu, but from the server's own Config.
		WorldTypes.register({
			id = "spec.hidden",
			name = "Hidden",
			description = "",
			create = function(seed, options)
				return WorldTypes.create(WorldTypes.DEFAULT, seed, options)
			end,
			hidden = true,
		})
		t.ok(refused({ worldType = "spec.hidden" }) ~= nil, "hidden from the menu")
		local allowed = WorldSettings.validate(request({ worldType = "spec.hidden" }), function()
			return 1
		end, true)
		t.ok(allowed ~= nil, "allowed for the server's Config")
		table.remove(WorldTypes.list, table.find(WorldTypes.list, WorldTypes.get("spec.hidden")))
	end)

	t.test("world creation: a type's declared settings are all the options it gets", function()
		withCustomType(function()
			local custom = WorldTypes.get("spec.custom") :: any
			local kept = WorldSettings.validateOptions(custom, {
				flat = true,
				biome = "desert",
				preset = "minecraft:bedrock, 2*dirt;<b>",
				junk = 5,
			}, false)
			t.eq(kept.flat, true)
			t.eq(kept.biome, "desert")
			t.eq(kept.preset, "minecraft:be", "cleaned, then cut to maxLength 12")
			t.eq(kept.junk, nil, "undeclared keys dropped")
			t.eq(kept.structures, false, "the screen's toggle")
			local wrong = WorldSettings.validateOptions(custom, { flat = "yes", biome = "moon", preset = 3 }, true)
			t.eq(wrong.flat, false, "wrong kind: the default")
			t.eq(wrong.biome, "plains")
			t.eq(wrong.preset, "stone")
			t.eq(WorldSettings.cleanText("a b<c>/d#e%f"), "abc/d#ef")
		end)
	end)

	t.test("world creation: the server's own world (MainMenu off) comes from Config", function()
		local settings = WorldSettings.fromConfig(4242)
		t.eq(settings.seed, 4242)
		t.eq(settings.name, Config.World.Name)
		t.eq(settings.worldType, WorldTypes.DEFAULT)
		t.eq(settings.gameMode, GameMode.default())
		t.eq(WorldSettings.difficultyName(settings.difficulty), Config.World.Difficulty)
		t.eq(settings.allowCommands, Config.World.AllowCommands)
		t.eq(settings.options.structures, Config.World.Structures)
		t.eq(WorldSettings.parseDifficulty("peaceful"), 0)
		t.eq(WorldSettings.parseDifficulty("Hard"), 3)
		t.eq(WorldSettings.parseDifficulty("2"), 2)
		t.eq(WorldSettings.parseDifficulty("nightmare"), nil)
	end)

	--[[ Creating it once (World/WorldInfo) ]]

	-- Runs `fn` with Config's values that creating a world changes put back after.
	local function keepingConfig(fn: () -> ())
		local mode = Config.Gameplay.DefaultGameMode
		local fire = Config.Server.Fire.Difficulty
		local cap, max = Config.Mobs.HostileCap, Config.Mobs.MaxHostile
		local ok, err = pcall(fn)
		Config.Gameplay.DefaultGameMode = mode
		Config.Server.Fire.Difficulty = fire
		Config.Mobs.HostileCap, Config.Mobs.MaxHostile = cap, max
		WorldInfo._reset()
		if not ok then
			error(err, 0)
		end
	end

	t.test("world creation: the boot's startWorld runs once, with the settings in Config", function()
		keepingConfig(function()
			WorldInfo._reset()
			t.eq(WorldInfo.state(), "waiting")
			t.eq(WorldInfo.get(), nil)
			local settings = WorldSettings.fromConfig(99)
			settings.gameMode = GameMode.CREATIVE
			settings.difficulty = 3
			local started = 0
			local seen = nil
			local ready = nil
			WorldInfo.onReady(function(s)
				ready = s
			end)
			local ok, problem = WorldInfo.create(settings, function(s)
				started += 1
				seen = s
				-- Config holds the world's settings while the world's parts start.
				t.eq(Config.Gameplay.DefaultGameMode, GameMode.CREATIVE)
				t.eq(Config.Server.Fire.Difficulty, 3)
				t.eq(WorldInfo.state(), "creating")
			end)
			t.ok(ok, problem)
			t.eq(started, 1)
			t.eq(seen, settings)
			t.eq(ready, settings, "onReady")
			t.eq(WorldInfo.state(), "ready")
			t.ok(WorldInfo.exists())
			t.eq(WorldInfo.get(), settings)
			local again, why = WorldInfo.create(settings, function()
				started += 1
			end)
			t.eq(again, false)
			t.eq(why, "The world already exists")
			t.eq(started, 1, "only once")
			local late = nil
			WorldInfo.onReady(function(s)
				late = s
			end)
			t.eq(late, settings, "at once when ready")
		end)
	end)

	t.test("world creation: only an operator, only once", function()
		keepingConfig(function()
			WorldInfo._reset()
			t.eq(WorldInfo.refusal(false, false), "Only the operator can create the world")
			t.eq(WorldInfo.refusal(true, false), nil, "the operator, no world yet")
			t.eq(WorldInfo.refusal(true, true), "The world is being created", "a request under way")
			WorldInfo.create(WorldSettings.fromConfig(1), function()
				t.eq(WorldInfo.refusal(true, false), "The world is being created")
			end)
			t.eq(WorldInfo.refusal(true, false), "The world already exists")
			t.eq(WorldInfo.refusal(false, false), "Only the operator can create the world")
		end)
	end)

	t.test("world creation: Peaceful spawns no monsters; a failed start is final", function()
		keepingConfig(function()
			WorldInfo._reset()
			local settings = WorldSettings.fromConfig(5)
			settings.difficulty = 0
			local ok = WorldInfo.create(settings, function() end)
			t.ok(ok)
			t.eq(Config.Mobs.HostileCap, 0, "Peaceful")
			t.eq(Config.Mobs.MaxHostile, 0)
		end)
		keepingConfig(function()
			WorldInfo._reset()
			local ok, problem = WorldInfo.create(WorldSettings.fromConfig(5), function()
				error("broken part")
			end)
			t.eq(ok, false)
			t.ok(string.find(problem or "", "broken part", 1, true) ~= nil)
			t.eq(WorldInfo.state(), "failed")
			t.eq(WorldInfo.get(), nil)
			local again, why = WorldInfo.create(WorldSettings.fromConfig(5), function() end)
			t.eq(again, false)
			t.eq(why, "The world could not be created")
			t.eq(WorldInfo.refusal(true, false), "The world could not be created")
		end)
	end)

	t.test("world creation: published for the clients, the seed last", function()
		local folder = shared
		local settings = WorldSettings.fromConfig(31337)
		settings.name = "Published"
		settings.allowCommands = true
		WorldSettings.publish(folder, settings)
		local info = WorldSettings.info(folder) :: any
		t.eq(info.name, "Published")
		t.eq(info.seed, 31337)
		t.eq(info.allowCommands, true)
		t.eq(info.worldType, settings.worldType)
		t.eq(WorldTypes.decodeOptions(folder:GetAttribute("WorldOptions")).structures, settings.options.structures)
		folder:SetAttribute("Seed", nil)
		t.eq(WorldSettings.info(folder), nil, "nothing before the seed")
		for _, name in { "WorldName", "Difficulty", "AllowCommands", "WorldType", "WorldOptions" } do
			folder:SetAttribute(name, nil)
		end
	end)

	--[[ Protocol ]]

	t.test("world creation: CreateWorld, MenuState and CreateWorldResult round trips", function()
		local message = {
			name = "Mon Monde é",
			gameMode = GameMode.ADVENTURE,
			difficulty = 1,
			allowCommands = true,
			structures = false,
			worldType = WorldTypes.DEFAULT,
			options = WorldTypes.encodeOptions({ flat = true, biome = "desert" }),
			seed = "-12345",
		}
		local back = Protocol.decodeCreateWorld(Protocol.encodeCreateWorld(message)) :: any
		for key, value in message do
			t.eq(back[key], value, key)
		end
		t.eq(Protocol.decodeCreateWorld(buffer.create(2)), nil, "too short")
		local b = Protocol.encodeCreateWorld(message)
		buffer.writeu8(b, 0, 3)
		t.eq(Protocol.decodeCreateWorld(b), nil, "spectator")
		b = Protocol.encodeCreateWorld(message)
		buffer.writeu8(b, 1, 4)
		t.eq(Protocol.decodeCreateWorld(b), nil, "difficulty 4")
		b = Protocol.encodeCreateWorld(message)
		buffer.writeu8(b, 2, 4)
		t.eq(Protocol.decodeCreateWorld(b), nil, "unknown flags")
		local long = buffer.create(buffer.len(b) + 1)
		buffer.copy(long, 0, Protocol.encodeCreateWorld(message))
		t.eq(Protocol.decodeCreateWorld(long), nil, "a byte too many")
		local bad = Protocol.encodeCreateWorld(message)
		buffer.writeu8(bad, 5, 0xFF)
		t.eq(Protocol.decodeCreateWorld(bad), nil, "invalid UTF-8")
		-- Texts too long for the wire are cut at a character's start (still valid UTF-8).
		local huge = table.clone(message)
		huge.name = string.rep("é", 200)
		local cut = Protocol.decodeCreateWorld(Protocol.encodeCreateWorld(huge)) :: any
		t.eq(#cut.name, Protocol.MAX_WORLD_NAME)
		t.ok(utf8.len(cut.name) ~= nil)

		local state, operator, world =
			Protocol.decodeMenuState(Protocol.encodeMenuState(Protocol.MenuState.Ready, "Steve", "Island"))
		t.eq(state, Protocol.MenuState.Ready)
		t.eq(operator, "Steve")
		t.eq(world, "Island")
		local waiting = Protocol.decodeMenuState(Protocol.encodeMenuState(Protocol.MenuState.Waiting, "", ""))
		t.eq(waiting, Protocol.MenuState.Waiting)
		local wrong = Protocol.encodeMenuState(Protocol.MenuState.Ready, "a", "b")
		buffer.writeu8(wrong, 0, 9)
		t.eq((Protocol.decodeMenuState(wrong)), nil, "unknown state")

		local ok, text = Protocol.decodeCreateWorldResult(Protocol.encodeCreateWorldResult(false, "Only the operator"))
		t.eq(ok, false)
		t.eq(text, "Only the operator")
		t.eq((Protocol.decodeCreateWorldResult(Protocol.encodeCreateWorldResult(true, ""))), true)
		t.eq((Protocol.decodeCreateWorldResult(buffer.create(0))), nil)
		t.ok(Protocol.ClientMessage.CreateWorld ~= nil and Protocol.ClientMessage.EnterWorld ~= nil)
		t.ok(Protocol.ServerMessage.MenuState ~= nil and Protocol.ServerMessage.CreateWorldResult ~= nil)
	end)

	t.test("world creation: message ids are new, after every older one", function()
		local function unique(ids: { [string]: number })
			local seen = {}
			for name, id in ids do
				t.eq(seen[id], nil, `{name} shares id {id}`)
				seen[id] = name
			end
		end
		unique(Protocol.ClientMessage)
		unique(Protocol.ServerMessage)
		t.ok(Protocol.ClientMessage.CreateWorld > Protocol.ClientMessage.UnlockSkill)
		t.ok(Protocol.ServerMessage.MenuState > Protocol.ServerMessage.Progress)
	end)

	--[[ The title screen (client) ]]

	t.test("world creation: the title screen's buttons and status", function()
		local MenuState = Protocol.MenuState
		local waiting = TitleRules.buttons(MenuState.Waiting, false)
		t.eq(waiting.join, false)
		t.eq(waiting.create, false, "not the operator")
		t.eq(waiting.load, false, "saves are for the future")
		t.eq(waiting.options, true)
		t.eq(TitleRules.buttons(MenuState.Waiting, true).create, true, "the operator creates")
		t.eq(TitleRules.buttons(MenuState.Creating, true).create, false, "once")
		local ready = TitleRules.buttons(MenuState.Ready, true)
		t.eq(ready.join, true)
		t.eq(ready.create, false)
		t.eq(TitleRules.buttons(nil, true).join, false, "nothing heard yet")
		t.eq(TitleRules.status(MenuState.Waiting, false, "Steve", ""), "Waiting for Steve to create the world...")
		local text, kind = TitleRules.status(MenuState.Ready, false, "Steve", "Island")
		t.eq(text, '"Island" is ready')
		t.eq(kind, "news")
		t.eq(select(2, TitleRules.status(MenuState.Failed, true, "", "")), "warning")
	end)

	t.test("world creation: splashes, Minecraft's dates and the pulse", function()
		t.eq(TitleRules.splash(12, 25, 1), "Merry X-mas!")
		t.eq(TitleRules.splash(1, 1, 1), "Happy new year!")
		t.eq(TitleRules.splash(10, 31, 1), "OOoooOOOoooo! Spooky!")
		t.eq(TitleRules.splash(5, 5, 2), TitleRules.SPLASHES[2])
		t.eq(TitleRules.splash(5, 5, 999), TitleRules.SPLASHES[#TitleRules.SPLASHES], "clamped")
		t.near(TitleRules.splashScale(0, 68), 1.8, 1e-9, "100 / (68 + 32) at the pulse's top")
		t.near(TitleRules.splashScale(0.25, 68), 1.7, 1e-9, "its bottom a quarter second on")
		t.ok(TitleRules.splashScale(0, 200) < TitleRules.splashScale(0, 50), "long splashes smaller")
	end)

	t.test("world creation: the Create World form, as Minecraft's screen", function()
		local form = CreateWorldForm.new()
		t.eq(form.name, Config.World.Name)
		t.eq(form.tab, "game")
		t.eq(CreateWorldForm.gameModeLabel(form), `Game Mode: {form.gameMode}`)
		-- Survival -> Creative turns Allow Commands on, as Minecraft's screen does.
		form.gameMode = GameMode.SURVIVAL
		form.allowCommands = false
		CreateWorldForm.cycleGameMode(form)
		t.eq(form.gameMode, GameMode.CREATIVE)
		t.eq(form.allowCommands, true)
		CreateWorldForm.cycleGameMode(form)
		t.eq(form.gameMode, GameMode.ADVENTURE)
		t.eq(form.allowCommands, false)
		CreateWorldForm.cycleGameMode(form)
		t.eq(form.gameMode, GameMode.SURVIVAL, "around")
		-- Once chosen by hand, the game mode leaves it.
		CreateWorldForm.toggleCommands(form)
		CreateWorldForm.cycleGameMode(form)
		t.eq(form.allowCommands, true)
		CreateWorldForm.cycleGameMode(form)
		t.eq(form.allowCommands, true, "the player's choice stays")
		form.difficulty = 3
		CreateWorldForm.cycleDifficulty(form)
		t.eq(form.difficulty, 0, "Hard -> Peaceful")
		t.eq(CreateWorldForm.difficultyLabel(form), "Difficulty: Peaceful")
		t.eq(CreateWorldForm.structuresLabel(form), "Generate Structures: ON")
		CreateWorldForm.toggleStructures(form)
		t.eq(CreateWorldForm.structuresLabel(form), "Generate Structures: OFF")
		t.eq(CreateWorldForm.customizable(form), false, "the Default has no settings")
	end)

	t.test("world creation: Customize draws a type's settings and sends them", function()
		withCustomType(function()
			local form = CreateWorldForm.new()
			local offered = {}
			for _, worldType in CreateWorldForm.types() do
				table.insert(offered, worldType.id)
			end
			t.ok(table.find(offered, "spec.custom") ~= nil, "offered")
			while form.worldType ~= "spec.custom" do
				CreateWorldForm.cycleWorldType(form)
			end
			t.ok(CreateWorldForm.customizable(form))
			t.eq(CreateWorldForm.worldTypeLabel(form), "World Type: Custom")
			local settings = (WorldTypes.get("spec.custom") :: any).settings
			local flat, biome, preset = settings[1], settings[2], settings[3]
			t.eq(CreateWorldForm.settingLabel(form, flat), "Flat: OFF")
			CreateWorldForm.cycleSetting(form, flat)
			t.eq(CreateWorldForm.settingLabel(form, flat), "Flat: ON")
			t.eq(CreateWorldForm.settingLabel(form, biome), "Biome: Plains")
			CreateWorldForm.cycleSetting(form, biome)
			t.eq(CreateWorldForm.settingLabel(form, biome), "Biome: Desert")
			CreateWorldForm.setSetting(form, preset, "grass block!")
			t.eq(CreateWorldForm.settingValue(form, preset), "grassblock", "a code")
			form.seed = "glacier"
			local sent = CreateWorldForm.request(form)
			t.eq(sent.worldType, "spec.custom")
			t.eq(sent.seed, "glacier")
			local options = WorldTypes.decodeOptions(sent.options)
			t.eq(options.flat, true)
			t.eq(options.biome, "desert")
			t.eq(options.preset, "grassblock")
			-- The server's check keeps them.
			local settingsBack = WorldSettings.validate({
				name = sent.name,
				gameMode = sent.gameMode,
				difficulty = sent.difficulty,
				allowCommands = sent.allowCommands,
				worldType = sent.worldType,
				options = options,
				structures = sent.structures,
				seed = sent.seed,
			}, never) :: any
			t.eq(settingsBack.options.biome, "desert")
			t.eq(settingsBack.seed, 108181935)
		end)
	end)
end
