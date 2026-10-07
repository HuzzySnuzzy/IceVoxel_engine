--!strict
--[[
	The world's settings, as Minecraft 1.20's Create World screen makes them (CreateWorldScreen's Game
	and World tabs, WorldCreationUiState): pure rules shared by the title screen (client
	Ui/MainMenu), the server that creates the world (Players/WorldMenu, World/WorldInfo) and the
	specs.

	  Settings    { name, gameMode, difficulty, allowCommands, worldType, options, seed }: what the
	              world is. `options` are the world type's (Generation/WorldTypes), with
	              "structures" from the Generate Structures toggle (false: no library structures).
	  Request     what the Create World screen asks for (Protocol CreateWorld): the same with the
	              seed as typed and the options not checked yet. `validate` turns one into Settings
	              or says what is wrong with it (the server's check; the screen shows the answer).
	  Name        World Name: at most MAX_NAME characters (Minecraft's EditBox holds 32), control
	              characters dropped, blank = DEFAULT_NAME. Every player sees it (the title screen,
	              F3), so the server filters it (TextService) before publishing it.
	  Seed        Minecraft's WorldOptions.parseSeed: trimmed (Java's trim: characters up to the
	              space), empty = random; a whole number (Long.parseLong: digits with an optional
	              sign) is the seed itself, while it fits a double exactly (|n| < 2^53; longer ones
	              hash as text, where Minecraft would read a long); any other text is Java's
	              String.hashCode of it (31 x h + c over UTF-16 units, 32 bit, signed), so a text
	              seed gives Minecraft's number. At most MAX_SEED characters. The generator takes
	              any whole number (its hashes use it modulo 2^32).
	  Difficulty  Minecraft's ids: 0 Peaceful, 1 Easy, 2 Normal, 3 Hard (DIFFICULTIES).
	  Game mode   the screen's: Survival, Creative, Adventure (GAME_MODES; Hardcore is not here),
	              plus the world type's own `gameMode` hint (Spectator for the All Blocks debug
	              world, as Minecraft's debug world puts players in spectator): `modes`. With the
	              menu off the type's hint is the game mode too (`fromConfig`).
	  Options     `validateOptions` keeps what the world type declares in its `settings`
	              (WorldTypes.Setting), of the declared kind: a toggle's boolean, one of a choice's
	              values, a text code cut to its length (`cleanText`); the rest is dropped, and
	              "structures" is the screen's toggle. Text options are codes (presets, ids) of a
	              small alphabet, never free text, so they need no filtering.
	  Progress    `savesProgress`: whether progression earned in the world is saved for every
	              server (Players/Progression, ProgressStore's global DataStore): not in a world
	              type with `savesProgress = false` (superflat, the debug worlds:
	              Generation/WorldTypes), nor with Allow Commands (everyone may /knowledge set:
	              Minecraft turns achievements off with cheats). There it is this server's only.
	  Published   the server sets ReplicatedStorage.IceVoxel's "WorldName", "Difficulty" and
	              "AllowCommands", then WorldTypes.publish ("WorldType", "WorldOptions", "Seed"
	              last: clients start once it is there); `info` reads them back (F3).
	  Operators   OPERATOR_ATTRIBUTE, a Player attribute the server's Players/Operators keeps (true
	              for operators): the title screen offers Create World to them.
	  Commands    COMMAND_ATTRIBUTE on a server TextChatCommand says who may use it: "operator"
	              (/op, /deop: operators only), "commands" (/effect, /summon, /kill: the
	              operators' permission, Players/Operators.permitted: operators, or everyone with
	              Allow Commands), "gamemode" (/gamemode: the player's GameMode.PERMISSION_ATTRIBUTE),
	              none (everyone: /time, /gamerule and /knowledge answer queries to all, Roblox's
	              own commands). `mayRun` is the rule; the chat (client Ui/Chat) completes and
	              suggests only what the player may run, as Minecraft's client knows only the
	              commands its permission level allows. The server checks every command anyway.
]]

local Config = require(script.Parent.Config)
local GameMode = require(script.Parent.GameMode)
local WorldTypes = require(script.Parent.Generation.WorldTypes)

export type Options = WorldTypes.Options

export type Settings = {
	name: string,
	-- The game mode new players get (a GAME_MODES mode).
	gameMode: string,
	-- 0 Peaceful .. 3 Hard.
	difficulty: number,
	allowCommands: boolean,
	worldType: string,
	options: Options,
	seed: number,
}

export type Request = {
	name: string,
	gameMode: string,
	difficulty: number,
	allowCommands: boolean,
	worldType: string,
	options: Options,
	-- Generate Structures.
	structures: boolean,
	-- The seed as typed (empty: random).
	seed: string,
}

-- What the clients read back (`info`).
-- What a player may do, as their client sees it (the attributes: OPERATOR_ATTRIBUTE, the world's
-- "AllowCommands", GameMode.PERMISSION_ATTRIBUTE).
export type Access = {
	operator: boolean,
	allowCommands: boolean,
	gameMode: boolean,
}

export type Info = {
	name: string,
	difficulty: number,
	allowCommands: boolean,
	worldType: string,
	seed: number,
}

local WorldSettings = {}

WorldSettings.OPERATOR_ATTRIBUTE = "IceVoxelOperator"
-- The option the Generate Structures toggle sets (a world type declares it to use it).
WorldSettings.STRUCTURES = "structures"
-- A TextChatCommand's attribute: who may use it (see the header), and its values.
WorldSettings.COMMAND_ATTRIBUTE = "IceVoxelPermission"
WorldSettings.COMMAND_OPERATOR = "operator"
WorldSettings.COMMAND_PERMITTED = "commands"
WorldSettings.COMMAND_GAMEMODE = "gamemode"

WorldSettings.MAX_NAME = 32
WorldSettings.MAX_SEED = 32
WorldSettings.DEFAULT_NAME = "New World"
-- A text setting's length when its type names none.
WorldSettings.MAX_TEXT = 64

-- By Minecraft's id + 1.
WorldSettings.DIFFICULTIES = table.freeze({ "Peaceful", "Easy", "Normal", "Hard" })
-- What each does here (the Create World screen's line under the button).
WorldSettings.DIFFICULTY_INFO = table.freeze({
	"No monsters spawn",
	"Monsters spawn; fire spreads slowly",
	"Monsters spawn; fire spreads a little faster",
	"Monsters spawn; fire spreads fastest",
})

-- The Create World screen's game modes, in its order, with Minecraft's lines under the button.
WorldSettings.GAME_MODES = table.freeze({ GameMode.SURVIVAL, GameMode.CREATIVE, GameMode.ADVENTURE })
WorldSettings.MODE_INFO = table.freeze({
	[GameMode.SURVIVAL] = "Search for resources, craft, gain knowledge, health and thirst",
	[GameMode.CREATIVE] = "Unlimited resources, free flying and destroy blocks instantly",
	[GameMode.ADVENTURE] = "Survival, but blocks can't be broken or placed",
	[GameMode.SPECTATOR] = "Fly through everything and look; nothing can be changed",
} :: { [string]: string })

-- The game modes the Create World screen offers for `worldType`: GAME_MODES, plus the type's
-- own `gameMode` when that is another (Spectator for the All Blocks world).
function WorldSettings.modes(worldType: WorldTypes.WorldType?): { string }
	local hint = worldType and worldType.gameMode
	if hint == nil or table.find(WorldSettings.GAME_MODES, hint) then
		return WorldSettings.GAME_MODES
	end
	local modes = table.clone(WorldSettings.GAME_MODES)
	table.insert(modes, hint)
	return modes
end

-- The difficulty with Minecraft's id `id`, nil when there is none.
function WorldSettings.difficultyName(id: number): string?
	return WorldSettings.DIFFICULTIES[id + 1]
end

-- "peaceful" / "Easy" / "2" ... -> the id, nil when it is none of them.
function WorldSettings.parseDifficulty(text: string): number?
	local number = tonumber(text)
	if number and WorldSettings.DIFFICULTIES[number + 1] and number == math.floor(number) then
		return number
	end
	for i, name in WorldSettings.DIFFICULTIES do
		if string.lower(name) == string.lower(text) then
			return i - 1
		end
	end
	return nil
end

--[[ Text ]]

-- Java's String.trim: characters up to the space (U+0020) off both ends.
local function trim(text: string): string
	return string.match(text, "^[%z\1- ]*(.-)[%z\1- ]*$") :: string
end

-- The first `count` characters of UTF-8 `text` (bytes when it is no valid UTF-8).
local function firstCharacters(text: string, count: number): string
	local length = utf8.len(text)
	if length == nil then
		return string.sub(text, 1, count)
	elseif length <= count then
		return text
	end
	local stop = utf8.offset(text, count + 1)
	return string.sub(text, 1, (stop :: number) - 1)
end

-- Number of characters (bytes when it is no valid UTF-8).
local function characters(text: string): number
	return utf8.len(text) or #text
end

--[[
	A world name as the server keeps it: control characters dropped (and invalid UTF-8 as a
	whole: nothing typed makes it), trimmed, at most MAX_NAME characters, blank = DEFAULT_NAME.
]]
function WorldSettings.cleanName(text: string): string
	if utf8.len(text) == nil then
		return WorldSettings.DEFAULT_NAME
	end
	local name = trim((string.gsub(text, "%c", "")))
	name = trim(firstCharacters(name, WorldSettings.MAX_NAME))
	return if name == "" then WorldSettings.DEFAULT_NAME else name
end

-- A text setting's code: letters, digits and _ : ; , . * + - = / # only, at most `maxLength`.
function WorldSettings.cleanText(text: string, maxLength: number?): string
	local code = string.gsub(text, "[^%w_:;,%.%*%+%-=/#]", "")
	return string.sub(code, 1, maxLength or WorldSettings.MAX_TEXT)
end

--[[ Seeds ]]

local U32 = 2 ^ 32
local SAFE = 2 ^ 53

-- Java's String.hashCode of UTF-8 `text`: 31 x h + c over its UTF-16 units, as a signed 32 bit int.
function WorldSettings.hashCode(text: string): number
	local h = 0
	local function add(unit: number)
		h = (h * 31 + unit) % U32
	end
	if utf8.len(text) then
		for _, code in utf8.codes(text) do
			if code >= 0x10000 then
				-- (A surrogate pair, as Java strings hold it.)
				local rest = code - 0x10000
				add(0xD800 + bit32.rshift(rest, 10))
				add(0xDC00 + bit32.band(rest, 0x3FF))
			else
				add(code)
			end
		end
	else
		for i = 1, #text do
			add(string.byte(text, i))
		end
	end
	return if h >= 2 ^ 31 then h - U32 else h
end

-- The seed `text` gives (see the header), nil when it is blank (a random seed).
function WorldSettings.parseSeed(text: string): number?
	local seed = trim(text)
	if seed == "" then
		return nil
	end
	local sign, digits = string.match(seed, "^([+-]?)(%d+)$")
	if digits then
		local number = tonumber(digits) :: number
		if number < SAFE then
			if number == 0 then
				return 0
			end
			return if sign == "-" then -number else number
		end
	end
	return WorldSettings.hashCode(seed)
end

-- A seed as Minecraft's /seed prints it: every digit (tostring writes big ones as 1.2e+15).
function WorldSettings.seedText(seed: number): string
	return string.format("%.0f", seed)
end

--[[ Options ]]

local function settingValue(setting: WorldTypes.Setting, value: unknown): (string | number | boolean)?
	if setting.kind == "toggle" then
		return if type(value) == "boolean" then value else nil
	elseif setting.kind == "choice" then
		local choices = setting.choices
		if choices and table.find(choices, value :: any) then
			return value :: string
		end
		return nil
	elseif setting.kind == "text" then
		return if type(value) == "string" then WorldSettings.cleanText(value, setting.maxLength) else nil
	end
	return nil
end

--[[
	The options of `worldType` kept from `options` (see the header), each declared setting given
	its default when missing or wrong; "structures" comes from `structures`.
]]
function WorldSettings.validateOptions(worldType: WorldTypes.WorldType, options: Options, structures: boolean): Options
	local kept: Options = {}
	local settings: { WorldTypes.Setting } = worldType.settings or {}
	for _, setting in settings do
		local value = settingValue(setting, options[setting.key])
		kept[setting.key] = if value ~= nil then value else setting.default
	end
	kept[WorldSettings.STRUCTURES] = structures
	return kept
end

--[[ Requests ]]

--[[
	The settings `request` asks for, or nil and why not. `randomSeed` gives the seed when none was
	typed. `allowHidden`: hidden world types may be picked too (the server's own Config.World).
]]
function WorldSettings.validate(request: Request, randomSeed: () -> number, allowHidden: boolean?): (Settings?, string?)
	local worldType = WorldTypes.get(request.worldType)
	if worldType == nil then
		return nil, `Unknown world type '{request.worldType}'`
	elseif worldType.hidden and not allowHidden then
		return nil, `The world type '{worldType.name}' can't be picked here`
	end
	if not table.find(WorldSettings.modes(worldType), request.gameMode) then
		return nil, `Unknown game mode '{request.gameMode}'`
	end
	local difficulty = request.difficulty
	if WorldSettings.difficultyName(difficulty) == nil or difficulty ~= math.floor(difficulty) then
		return nil, "Unknown difficulty"
	end
	if characters(request.seed) > WorldSettings.MAX_SEED then
		return nil, `The seed is too long (at most {WorldSettings.MAX_SEED} characters)`
	end
	local seed = WorldSettings.parseSeed(request.seed)
	return {
		name = WorldSettings.cleanName(request.name),
		gameMode = request.gameMode,
		difficulty = difficulty,
		allowCommands = request.allowCommands,
		worldType = worldType.id,
		options = WorldSettings.validateOptions(worldType, request.options, request.structures),
		seed = if seed ~= nil then seed else randomSeed(),
	},
		nil
end

-- The Create World screen's first choices (Config.World, Config.Gameplay.DefaultGameMode).
function WorldSettings.defaults(): Request
	local world = Config.World
	local mode = GameMode.parse(Config.Gameplay.DefaultGameMode)
	local worldType = if WorldTypes.get(world.Type) then world.Type else WorldTypes.DEFAULT
	return {
		name = world.Name,
		gameMode = if mode and table.find(WorldSettings.GAME_MODES, mode) then mode else GameMode.SURVIVAL,
		difficulty = WorldSettings.parseDifficulty(world.Difficulty) or 2,
		allowCommands = world.AllowCommands,
		worldType = worldType,
		options = {},
		structures = world.Structures,
		seed = "",
	}
end

--[[
	The world the server creates at once (Config.MainMenu.Enabled false): Config.World, the seed
	`seed` (Config.Seed, or a random one), hidden world types allowed, an unknown one the Default,
	its options Config.World.Options (kept as `validateOptions` keeps a request's). The game mode
	is the world type's hint (the debug worlds: Generation/WorldTypes) or else
	Config.Gameplay.DefaultGameMode as it is (Spectator too).
]]
function WorldSettings.fromConfig(seed: number): Settings
	local request = WorldSettings.defaults()
	local configured = WorldTypes.get(Config.World.Type)
	if configured then
		request.worldType = configured.id
	end
	request.options = Config.World.Options or {}
	local settings = WorldSettings.validate(request, function(): number
		return seed
	end, true) :: Settings
	settings.seed = seed
	local hint = configured and configured.gameMode
	settings.gameMode = if hint and GameMode.isValid(hint) then hint else GameMode.default()
	return settings
end

--[[ Progress ]]

-- Is progression earned in the world `settings` make saved for every server (see the header)?
function WorldSettings.savesProgress(settings: Settings): boolean
	local worldType = WorldTypes.get(settings.worldType)
	return not settings.allowCommands and not (worldType and worldType.savesProgress == false)
end

--[[ Commands ]]

-- May a player with `access` run a command whose COMMAND_ATTRIBUTE is `level` (unknown: yes)?
function WorldSettings.mayRun(level: unknown, access: Access): boolean
	if level == WorldSettings.COMMAND_OPERATOR then
		return access.operator
	elseif level == WorldSettings.COMMAND_PERMITTED then
		return access.operator or access.allowCommands
	elseif level == WorldSettings.COMMAND_GAMEMODE then
		return access.gameMode
	end
	return true
end

--[[ Attributes ]]

-- Publishes `settings` on `folder` (ReplicatedStorage.IceVoxel) for the clients; "Seed" goes last.
function WorldSettings.publish(folder: Instance, settings: Settings)
	folder:SetAttribute("WorldName", settings.name)
	folder:SetAttribute("Difficulty", settings.difficulty)
	folder:SetAttribute("AllowCommands", settings.allowCommands)
	WorldTypes.publish(folder, settings.worldType, settings.seed, settings.options)
end

-- The published world (nil before the "Seed" attribute is there).
function WorldSettings.info(folder: Instance): Info?
	local seed = folder:GetAttribute("Seed")
	if type(seed) ~= "number" then
		return nil
	end
	local name = folder:GetAttribute("WorldName")
	local difficulty = folder:GetAttribute("Difficulty")
	local worldType = folder:GetAttribute("WorldType")
	return {
		name = if type(name) == "string" then name else WorldSettings.DEFAULT_NAME,
		difficulty = if type(difficulty) == "number" then difficulty else 2,
		allowCommands = folder:GetAttribute("AllowCommands") == true,
		worldType = if type(worldType) == "string" then worldType else WorldTypes.DEFAULT,
		seed = seed,
	}
end

return WorldSettings
