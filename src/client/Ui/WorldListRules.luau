--!strict
--[[
	The Load World screen's and the saving indicator's rules (Minecraft's SelectWorldScreen and
	WorldSelectionList, its delete confirmation, and Bedrock's saving icon), without the Roblox
	parts (Ui/MainMenu, Ui/SaveIndicator), so the tests run them.

	  Rows      a saved world (Protocol WorldEntry) as three lines, as Minecraft's list draws
	            them: its name; its type and when it was last played ("Default, last played
	            2026-10-07 14:03"); its game mode and size ("Survival Mode, 1.4 MB").
	  Buttons   Play Selected World, Rename and Delete need a selection and nothing under way;
	            Cancel always works.
	  Delete    Minecraft's confirmation: "Are you sure you want to delete this world?" and
	            "'<name>' will be lost forever! (A long time!)".
	  Loading   "Loading world: 12 / 40" (keys read of all), "Loading world..." before the count.
	  Icon      the saving icon shows while a save is in flight and at least MIN_SHOW seconds
	            (a quick save still blinks visibly), bobbing a pixel or two (`bob`).
	  Toast     after a save, for operators: "World saved" over its sizes ("1.4 MB of 64 MB
	            (largest region 0.3 / 4 MB)", Shared/SaveText), or "World not saved" over why;
	            yellow for news, red when it failed or nears the world's most.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)
local Protocol = require(Shared.Net.Protocol)
local SaveText = require(Shared.SaveText)
local WorldTypes = require(Shared.Generation.WorldTypes)

local WorldListRules = {}

-- Seconds the saving icon shows at least, and its bob (GUI pixels, per second).
WorldListRules.MIN_SHOW = 1.2
WorldListRules.BOB = 2
WorldListRules.BOB_SPEED = 3

-- A world type's name ("Default"; its id when the game no longer has it).
function WorldListRules.typeName(id: string): string
	local worldType = WorldTypes.get(id)
	return if worldType then worldType.name else id
end

-- The three lines of a world's row; `date` is os.date("*t") of its last play.
function WorldListRules.row(entry: Protocol.WorldEntry, date: { [string]: any }): (string, string, string)
	local mode = GameMode.displayName(if GameMode.isValid(entry.gameMode) then entry.gameMode else GameMode.SURVIVAL)
	return entry.name,
		`{WorldListRules.typeName(entry.worldType)}, last played {SaveText.date(date)}`,
		`{mode}, {SaveText.size(entry.bytes)}`
end

export type Buttons = { play: boolean, rename: boolean, delete: boolean, cancel: boolean }

-- Which of the screen's buttons work with `selected` (a world picked) while `busy` (a request out).
function WorldListRules.buttons(selected: boolean, busy: boolean): Buttons
	local ready = selected and not busy
	return { play = ready, rename = ready, delete = ready, cancel = true }
end

-- The selection after the list changed: kept when its world is still listed, else none.
function WorldListRules.keepSelection(worlds: { Protocol.WorldEntry }, selected: string?): string?
	if selected == nil then
		return nil
	end
	for _, entry in worlds do
		if entry.id == selected then
			return selected
		end
	end
	return nil
end

-- Minecraft's delete confirmation: the question and the warning.
function WorldListRules.deleteQuestion(name: string): (string, string)
	return "Are you sure you want to delete this world?", `'{name}' will be lost forever! (A long time!)`
end

-- The loading line: "Loading world: 12 / 40".
function WorldListRules.loading(done: number, total: number): string
	if total <= 0 then
		return "Loading world..."
	end
	return `Loading world: {math.clamp(done, 0, total)} / {total}`
end

-- Is the saving icon up `since` seconds after a save started, with the save `inFlight`?
function WorldListRules.iconShown(inFlight: boolean, since: number): boolean
	return inFlight or since < WorldListRules.MIN_SHOW
end

-- The icon's bob (GUI pixels up) `t` seconds into a save.
function WorldListRules.bob(t: number): number
	return math.floor((math.sin(t * WorldListRules.BOB_SPEED * math.pi) + 1) / 2 * WorldListRules.BOB + 0.5)
end

--[[
	The toast after a save (Protocol WorldSave "saved"): its title, its line and whether it warns
	(red); nil when there is none to show (no sizes: not an operator).
]]
function WorldListRules.toast(status: Protocol.SaveStatus): (string?, string, boolean)
	if status.op ~= Protocol.SaveOp.Saved or not status.sizes then
		return nil, "", false
	end
	if not status.ok then
		local why = status.text or ""
		return "World not saved", if why ~= "" then why else "the store could not be written", true
	end
	local bytes, max = status.bytes or 0, status.max or 0
	local line =
		string.gsub(SaveText.saved(bytes, max, status.largest or 0, status.keyLimit or 0), "^World saved — ", "")
	return "World saved", line, status.warn == true
end

return WorldListRules
