--!strict
--[[
	The Create World screen's form (Minecraft 1.20's CreateWorldScreen and WorldCreationUiState,
	simplified) without the Roblox parts (Ui/MainMenu draws it), so the tests can run it.

	  Game tab   World Name, Game Mode (Survival / Creative / Adventure, cycled; the line under it
	             says what each is), Difficulty (Peaceful / Easy / Normal / Hard), Allow Commands
	             (ON / OFF). As Minecraft's screen, choosing Creative turns Allow Commands on and
	             Survival or Adventure off, until the player sets it themselves.
	  World tab  World Type (the registry's types the menu may offer, Generation/WorldTypes.list
	             without hidden ones, cycled in its order; the line under it is the type's
	             description), Customize (only for a type that declares `settings`), the seed (as
	             typed: Shared/WorldSettings.parseSeed reads it on the server) and Generate
	             Structures (ON / OFF). A type's `gameMode` hint (the debug worlds: Spectator for
	             All Blocks, Creative for the others) is preselected when the type is picked, and
	             the mode the player had comes back on a type without one, unless they chose a
	             mode in between; the hinted mode joins the Game Mode cycle (WorldSettings.modes).
	  Customize  one widget per declared setting (WorldTypes.Setting) but "structures" (the World
	             tab's Generate Structures, greyed out for a type without it): toggles and choices
	             cycle,
	             text is typed (WorldSettings.cleanText), with its `presets` cycled on a button
	             beside it and its `check` (superflat: Generation/Superflat.parse) shown under it;
	             `problem` keeps Create New World from sending a text that fails it. Each type
	             keeps its own values while the screen is open, so switching types and back loses
	             nothing.
	  Request    `request` is what the screen sends (Protocol CreateWorld): the chosen type's
	             settings encoded (WorldTypes.encodeOptions). The server checks everything again.
	Starting values: Shared/WorldSettings.defaults (Config.World, Config.Gameplay.DefaultGameMode).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)
local Protocol = require(Shared.Net.Protocol)
local WorldSettings = require(Shared.WorldSettings)
local WorldTypes = require(Shared.Generation.WorldTypes)

type Value = string | number | boolean

export type Form = {
	tab: "game" | "world",
	name: string,
	gameMode: string,
	difficulty: number,
	allowCommands: boolean,
	-- The player set Allow Commands themselves (the game mode no longer changes it).
	commandsChosen: boolean,
	-- The game mode before a world type's hint replaced it (nil: no hint in force).
	modeBeforeHint: string?,
	worldType: string,
	structures: boolean,
	seed: string,
	-- Customize values by world type id, then setting key.
	settings: { [string]: { [string]: Value } },
}

local CreateWorldForm = {}

-- The world types the screen offers, in the registry's order.
function CreateWorldForm.types(): { WorldTypes.WorldType }
	local shown = {}
	for _, worldType in WorldTypes.list do
		if not worldType.hidden then
			table.insert(shown, worldType)
		end
	end
	return shown
end

function CreateWorldForm.new(defaults: WorldSettings.Request?): Form
	local start = defaults or WorldSettings.defaults()
	local form: Form = {
		tab = "game",
		name = start.name,
		gameMode = start.gameMode,
		difficulty = start.difficulty,
		allowCommands = start.allowCommands,
		commandsChosen = false,
		modeBeforeHint = nil,
		worldType = start.worldType,
		structures = start.structures,
		seed = start.seed,
		settings = {},
	}
	local worldType = WorldTypes.get(form.worldType)
	if worldType == nil or worldType.hidden then
		local first = CreateWorldForm.types()[1]
		form.worldType = if first then first.id else WorldTypes.DEFAULT
	end
	CreateWorldForm.applyHint(form)
	return form
end

local function cycle<T>(list: { T }, current: T, delta: number): T
	local index = table.find(list, current) or 1
	return list[(index - 1 + delta) % #list + 1]
end

-- Minecraft's rule: Creative (and here Spectator) turns Allow Commands on, the others off, until
-- the player sets it themselves.
local function setMode(form: Form, mode: string)
	form.gameMode = mode
	if not form.commandsChosen then
		form.allowCommands = mode == GameMode.CREATIVE or mode == GameMode.SPECTATOR
	end
end

function CreateWorldForm.cycleGameMode(form: Form, delta: number?)
	setMode(form, cycle(WorldSettings.modes(CreateWorldForm.worldType(form)), form.gameMode, delta or 1))
	-- (The player's choice: no hint takes it back.)
	form.modeBeforeHint = nil
end

-- The chosen type's game mode hint, preselected; without one the mode before the last hint (or
-- the screen's first when that is not offered any more).
function CreateWorldForm.applyHint(form: Form)
	local worldType = CreateWorldForm.worldType(form)
	local hint = worldType.gameMode
	if hint and GameMode.isValid(hint) then
		if hint ~= form.gameMode then
			form.modeBeforeHint = form.modeBeforeHint or form.gameMode
			setMode(form, hint)
		end
	elseif form.modeBeforeHint then
		local before = form.modeBeforeHint :: string
		form.modeBeforeHint = nil
		setMode(form, before)
	end
	if not table.find(WorldSettings.modes(worldType), form.gameMode) then
		setMode(form, WorldSettings.GAME_MODES[1])
	end
end

function CreateWorldForm.cycleDifficulty(form: Form, delta: number?)
	form.difficulty = (form.difficulty + (delta or 1)) % #WorldSettings.DIFFICULTIES
end

function CreateWorldForm.toggleCommands(form: Form)
	form.allowCommands = not form.allowCommands
	form.commandsChosen = true
end

function CreateWorldForm.toggleStructures(form: Form)
	form.structures = not form.structures
end

function CreateWorldForm.cycleWorldType(form: Form, delta: number?)
	local ids = {}
	for _, worldType in CreateWorldForm.types() do
		table.insert(ids, worldType.id)
	end
	if #ids > 0 then
		form.worldType = cycle(ids, form.worldType, delta or 1)
		CreateWorldForm.applyHint(form)
	end
end

-- The chosen world type (the Default when it went missing).
function CreateWorldForm.worldType(form: Form): WorldTypes.WorldType
	return WorldTypes.get(form.worldType) or WorldTypes.get(WorldTypes.DEFAULT) :: WorldTypes.WorldType
end

--[[
	The chosen type's settings on its Customize screen: all it declares but "structures", which is
	the World tab's own Generate Structures (WorldSettings.validateOptions takes it from there).
]]
function CreateWorldForm.customSettings(form: Form): { WorldTypes.Setting }
	local shown = {}
	local settings: { WorldTypes.Setting } = CreateWorldForm.worldType(form).settings or {}
	for _, setting in settings do
		if setting.key ~= WorldSettings.STRUCTURES then
			table.insert(shown, setting)
		end
	end
	return shown
end

-- Does the chosen type have a Customize screen?
function CreateWorldForm.customizable(form: Form): boolean
	return #CreateWorldForm.customSettings(form) > 0
end

-- Does Generate Structures mean anything for the chosen type (it declares "structures")?
function CreateWorldForm.hasStructures(form: Form): boolean
	local settings: { WorldTypes.Setting } = CreateWorldForm.worldType(form).settings or {}
	for _, setting in settings do
		if setting.key == WorldSettings.STRUCTURES then
			return true
		end
	end
	return false
end

--[[ Customize ]]

-- The value of `setting` of the chosen type (its default until changed).
function CreateWorldForm.settingValue(form: Form, setting: WorldTypes.Setting): Value
	local values = form.settings[form.worldType]
	local value = values and values[setting.key]
	if value == nil then
		return setting.default
	end
	return value
end

function CreateWorldForm.setSetting(form: Form, setting: WorldTypes.Setting, value: Value)
	local values = form.settings[form.worldType]
	if values == nil then
		values = {}
		form.settings[form.worldType] = values
	end
	if setting.kind == "text" then
		value = WorldSettings.cleanText(tostring(value), setting.maxLength)
	end
	values[setting.key] = value
end

-- The next (`delta` 1) or previous of a text setting's presets (none: nothing happens).
function CreateWorldForm.cyclePreset(form: Form, setting: WorldTypes.Setting, delta: number?)
	local presets = setting.presets
	if presets == nil or #presets == 0 then
		return
	end
	local value = tostring(CreateWorldForm.settingValue(form, setting))
	local index = 0
	for i, preset in presets do
		if preset.value == value then
			index = i
		end
	end
	local step = delta or 1
	if index == 0 and step < 0 then
		index = 1
	end
	CreateWorldForm.setSetting(form, setting, presets[(index - 1 + step) % #presets + 1].value)
end

-- The presets button's text: the preset the text is, or "Custom".
function CreateWorldForm.presetLabel(form: Form, setting: WorldTypes.Setting): string
	local value = tostring(CreateWorldForm.settingValue(form, setting))
	local presets: { { name: string, value: string } } = setting.presets or {}
	for _, preset in presets do
		if preset.value == value then
			return preset.name
		end
	end
	return "Custom"
end

-- What is wrong with a text setting's value (its `check`), nil when nothing or it has no check.
function CreateWorldForm.settingProblem(form: Form, setting: WorldTypes.Setting): string?
	local check = setting.check
	if setting.kind ~= "text" or check == nil then
		return nil
	end
	return check(tostring(CreateWorldForm.settingValue(form, setting)))
end

-- The first problem of the chosen type's settings ("Preset: ..."), nil when they are all good.
function CreateWorldForm.problem(form: Form): string?
	for _, setting in CreateWorldForm.customSettings(form) do
		local problem = CreateWorldForm.settingProblem(form, setting)
		if problem then
			return `{setting.name}: {problem}`
		end
	end
	return nil
end

-- A toggle flips, a choice moves on (text settings are typed).
function CreateWorldForm.cycleSetting(form: Form, setting: WorldTypes.Setting, delta: number?)
	local value = CreateWorldForm.settingValue(form, setting)
	if setting.kind == "toggle" then
		CreateWorldForm.setSetting(form, setting, not (value == true))
	elseif setting.kind == "choice" then
		local choices = setting.choices
		if choices and #choices > 0 then
			CreateWorldForm.setSetting(form, setting, cycle(choices, tostring(value), delta or 1))
		end
	end
end

--[[ Labels (Minecraft's "Name: Value" buttons) ]]

local function onOff(on: boolean): string
	return if on then "ON" else "OFF"
end

function CreateWorldForm.gameModeLabel(form: Form): string
	return `Game Mode: {form.gameMode}`
end

function CreateWorldForm.gameModeInfo(form: Form): string
	return WorldSettings.MODE_INFO[form.gameMode] or ""
end

function CreateWorldForm.difficultyLabel(form: Form): string
	return `Difficulty: {WorldSettings.difficultyName(form.difficulty) or "?"}`
end

function CreateWorldForm.difficultyInfo(form: Form): string
	return WorldSettings.DIFFICULTY_INFO[form.difficulty + 1] or ""
end

function CreateWorldForm.commandsLabel(form: Form): string
	return `Allow Commands: {onOff(form.allowCommands)}`
end

function CreateWorldForm.commandsInfo(form: Form): string
	return if form.allowCommands
		then "Everyone may use /gamemode, /time, /effect..."
		else "Only operators may use /gamemode, /time, /effect..."
end

function CreateWorldForm.worldTypeLabel(form: Form): string
	return `World Type: {CreateWorldForm.worldType(form).name}`
end

function CreateWorldForm.structuresLabel(form: Form): string
	return `Generate Structures: {onOff(form.structures)}`
end

-- A toggle's or choice's button text.
function CreateWorldForm.settingLabel(form: Form, setting: WorldTypes.Setting): string
	local value = CreateWorldForm.settingValue(form, setting)
	if setting.kind == "toggle" then
		return `{setting.name}: {onOff(value == true)}`
	elseif setting.kind == "choice" then
		local choices, labels = setting.choices, setting.labels
		local index = if choices then table.find(choices, tostring(value)) else nil
		local shown = if index and labels and labels[index] then labels[index] else tostring(value)
		return `{setting.name}: {shown}`
	end
	return setting.name
end

--[[ The request ]]

-- What the Create New World button sends (Protocol CreateWorld).
function CreateWorldForm.request(form: Form): Protocol.CreateWorld
	local worldType = CreateWorldForm.worldType(form)
	local options: WorldTypes.Options = {}
	local settings: { WorldTypes.Setting } = worldType.settings or {}
	for _, setting in settings do
		options[setting.key] = CreateWorldForm.settingValue(form, setting)
	end
	return {
		name = form.name,
		gameMode = form.gameMode,
		difficulty = form.difficulty,
		allowCommands = form.allowCommands,
		structures = form.structures,
		worldType = worldType.id,
		options = WorldTypes.encodeOptions(options),
		seed = form.seed,
	}
end

return CreateWorldForm
