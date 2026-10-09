--!strict
--[[
	The title screen's character pages (Terraria's Select Player and Create Player screens, in
	Minecraft's widgets), their rules without the Roblox parts (Ui/MainMenu, Ui/CharacterSelect,
	Ui/AvatarEditor), so the tests run them. The server's side: Players/CharacterStore.

	  Flow      title (Play, Options...) -> characters (the list) -> world (Join / Create / Load
	            World, as the title had them) -> the world. Create New Character opens the
	            editor; its Create makes the character, selected at once, and goes on to the
	            world page. Play Selected Character selects it (the server loads it and takes its
	            lock) and goes on once the server's list says it is the selected one. Rename and
	            Delete reuse the world list's name box and confirmation. Back (Escape, gamepad B)
	            goes back a page (`back`).
	  Rows      a character as two lines (`row`): its name in its difficulty's colour (Terraria's
	            white, blue, red; gray once dead), then its difficulty, time played (Terraria's
	            h:mm) and the day it was last played: "Classic, 1:23, 2026-10-09" ("Dead, "
	            first). The highlighted row stays across new lists while its character is
	            listed, else the server's selected one, else the first (`keepHighlight`).
	  Buttons   Play needs a living highlighted character and nothing under way; Create needs
	            room (Characters.MAX); Rename and Delete a highlighted one; Back always works.
	  Editor    Skin (Appearance.SKIN_TONES for every part or one part, hue and brightness
	            sliders, Randomise), Body (a slider a scale within Config.Characters.Scales, in
	            hundredths; body type and proportion in twentieths), Clothing (a toggle per thing of
	            the user's own avatar, one of each single kind worn, "Blocky body" for none of the
	            six body parts), Presets (Classic, Natural, My Avatar), the name (Characters
	            .cleanName: 1..20 characters) and the difficulty cycled with its line.
	  Colours   0xRRGGBB to hue, saturation, value and back (`toHsv`, `fromHsv`); the R15 parts each
	            body colour paints (`PART_NAMES`) and the BodyColors property (`BODY_COLORS`),
	            for the editor's instant edits on its preview.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Appearance = require(Shared.Characters.Appearance)
local Characters = require(Shared.Characters)
local Config = require(Shared.Config)
local SaveText = require(Shared.SaveText)

type Appearance = Appearance.Appearance
type Summary = Characters.Summary

local CharacterRules = {}

--[[ Pages ]]

export type Page = "title" | "characters" | "editor" | "world" | "rename" | "confirm" | "options" | string

--[[
	The page Back leads to from `page` (nil: none, it is the title). `dialogFor` is what the
	shared rename and confirm pages are open for ("character" or "world").
]]
function CharacterRules.back(page: Page, dialogFor: string?): Page?
	if page == "characters" then
		return "title"
	elseif page == "editor" or page == "world" then
		return "characters"
	elseif page == "rename" or page == "confirm" then
		return if dialogFor == "character" then "characters" else "load"
	end
	return nil
end

--[[ The list ]]

-- The list's colour of a character (0..255 each): its difficulty's, gray once dead.
function CharacterRules.colour(summary: Summary): { number }
	if summary.dead then
		return { 128, 128, 128 }
	end
	return Characters.DIFFICULTY_COLORS[summary.difficulty] or Characters.DIFFICULTY_COLORS[1]
end

-- A character's two lines; `date` is os.date("*t") of its last play.
function CharacterRules.row(summary: Summary, date: { [string]: any }): (string, string)
	local difficulty = Characters.DIFFICULTIES[summary.difficulty] or "Classic"
	local state = if summary.dead then "Dead, " else ""
	local day = string.sub(SaveText.date(date), 1, 10)
	return summary.name, `{state}{difficulty}, {Characters.formatPlayed(summary.played)}, {day}`
end

-- The highlighted character after a new list (see the header).
function CharacterRules.keepHighlight(list: { Summary }, highlighted: number?, selected: number?): number?
	local first: number? = nil
	local selectedFound = false
	for _, summary in list do
		if summary.id == highlighted then
			return highlighted
		end
		first = first or summary.id
		if summary.id == selected then
			selectedFound = true
		end
	end
	return if selectedFound then selected else first
end

-- The listed character `id` (nil: not listed).
function CharacterRules.find(list: { Summary }, id: number?): Summary?
	for _, summary in list do
		if summary.id == id then
			return summary
		end
	end
	return nil
end

export type Buttons = { play: boolean, create: boolean, rename: boolean, delete: boolean, back: boolean }

-- Which of the list's buttons work (see the header).
function CharacterRules.buttons(list: { Summary }, highlighted: number?, busy: boolean, max: number?): Buttons
	local chosen = CharacterRules.find(list, highlighted)
	local ready = chosen ~= nil and not busy
	return {
		play = ready and not (chosen :: Summary).dead,
		create = not busy and #list < (max or Characters.MAX),
		rename = ready,
		delete = ready,
		back = true,
	}
end

-- The delete confirmation's two lines (Minecraft's words).
function CharacterRules.deleteQuestion(name: string): (string, string)
	return "Are you sure you want to delete this character?", `'{name}' will be lost forever! (A long time!)`
end

--[[ The editor ]]

-- What is wrong with `name` as a character's name (nil: nothing).
function CharacterRules.nameProblem(name: string): string?
	if Characters.cleanName(name) == nil then
		return `A name has 1 to {Characters.MAX_NAME} characters`
	end
	return nil
end

-- The difficulty after `difficulty` (Classic, Mediumcore, Hardcore, around).
function CharacterRules.nextDifficulty(difficulty: number): number
	return difficulty % #Characters.DIFFICULTIES + 1
end

function CharacterRules.difficultyLabel(difficulty: number): string
	return `Difficulty: {Characters.DIFFICULTIES[difficulty] or "Classic"}`
end

-- The body colour names, in Appearance.PARTS' order, for the Skin tab ("All" first).
CharacterRules.PART_LABELS = table.freeze({ "All", "Head", "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg" })

-- The R15 parts each body colour paints, and the BodyColors property it is.
CharacterRules.PART_NAMES = table.freeze({
	table.freeze({ "Head" }),
	table.freeze({ "UpperTorso", "LowerTorso" }),
	table.freeze({ "LeftUpperArm", "LeftLowerArm", "LeftHand" }),
	table.freeze({ "RightUpperArm", "RightLowerArm", "RightHand" }),
	table.freeze({ "LeftUpperLeg", "LeftLowerLeg", "LeftFoot" }),
	table.freeze({ "RightUpperLeg", "RightLowerLeg", "RightFoot" }),
})
CharacterRules.BODY_COLORS = table.freeze({
	"HeadColor3",
	"TorsoColor3",
	"LeftArmColor3",
	"RightArmColor3",
	"LeftLegColor3",
	"RightLegColor3",
})

-- `look` with body colour `part` (1..6; 0 every part) set to `rgb` (a copy).
function CharacterRules.paint(look: Appearance, part: number, rgb: number): Appearance
	local result = Appearance.copy(look)
	for i = 1, #Appearance.PARTS do
		if part == 0 or part == i then
			result.colors[i] = rgb
		end
	end
	return result
end

-- `look` with every part one of the skin tones, picked by `random(n)` (1..n).
function CharacterRules.randomSkin(look: Appearance, random: (n: number) -> number): Appearance
	local tones = Appearance.SKIN_TONES
	return CharacterRules.paint(look, 0, tones[math.clamp(random(#tones), 1, #tones)])
end

-- 0xRRGGBB as hue, saturation and value (0..1 each).
function CharacterRules.toHsv(rgb: number): (number, number, number)
	local r = bit32.rshift(rgb, 16) / 255
	local g = bit32.band(bit32.rshift(rgb, 8), 0xFF) / 255
	local b = bit32.band(rgb, 0xFF) / 255
	local most, least = math.max(r, g, b), math.min(r, g, b)
	local delta = most - least
	local hue = 0
	if delta > 0 then
		if most == r then
			hue = ((g - b) / delta) % 6
		elseif most == g then
			hue = (b - r) / delta + 2
		else
			hue = (r - g) / delta + 4
		end
		hue /= 6
	end
	return hue, if most > 0 then delta / most else 0, most
end

-- Hue, saturation and value (0..1 each) as 0xRRGGBB.
function CharacterRules.fromHsv(hue: number, saturation: number, value: number): number
	local h = (hue % 1) * 6
	local s, v = math.clamp(saturation, 0, 1), math.clamp(value, 0, 1)
	local c = v * s
	local x = c * (1 - math.abs(h % 2 - 1))
	local m = v - c
	local r, g, b = 0, 0, 0
	if h < 1 then
		r, g, b = c, x, 0
	elseif h < 2 then
		r, g, b = x, c, 0
	elseif h < 3 then
		r, g, b = 0, c, x
	elseif h < 4 then
		r, g, b = 0, x, c
	elseif h < 5 then
		r, g, b = x, 0, c
	else
		r, g, b = c, 0, x
	end
	local function byte(n: number): number
		return math.clamp(math.round((n + m) * 255), 0, 255)
	end
	return byte(r) * 65536 + byte(g) * 256 + byte(b)
end

-- The hue and brightness sliders' steps.
CharacterRules.HUE_STEPS = 36
CharacterRules.VALUE_STEPS = 20

-- Steps of a scale's slider: hundredths, body type and proportion twentieths.
function CharacterRules.scaleSteps(name: string): number
	local range = (Config.Characters.Scales :: any)[name] :: { number }
	local step = if name == "bodyType" or name == "proportion" then 0.05 else 0.01
	return math.max(1, math.round((range[2] - range[1]) / step))
end

-- The scale at slider `step` (0..scaleSteps), and the step of a scale.
function CharacterRules.scaleAt(name: string, step: number): number
	local range = (Config.Characters.Scales :: any)[name] :: { number }
	local steps = CharacterRules.scaleSteps(name)
	return range[1] + (range[2] - range[1]) * math.clamp(step, 0, steps) / steps
end

function CharacterRules.stepOf(name: string, value: number): number
	local range = (Config.Characters.Scales :: any)[name] :: { number }
	local steps = CharacterRules.scaleSteps(name)
	if range[2] <= range[1] then
		return 0
	end
	return math.clamp(math.round((value - range[1]) / (range[2] - range[1]) * steps), 0, steps)
end

local SCALE_LABELS = { "Height", "Width", "Depth", "Head", "Body Type", "Proportion" }

-- A scale slider's label ("Height: 105%").
function CharacterRules.scaleLabel(name: string, value: number): string
	local index = table.find(Appearance.SCALES, name) or 1
	return `{SCALE_LABELS[index]}: {math.round(value * 100)}%`
end

-- Enum.AccessoryType's names by value (Appearance's accessory kinds are ACCESSORY + these).
local ACCESSORY_NAMES = {
	"Hat",
	"Hair",
	"Face Accessory",
	"Neck",
	"Shoulder",
	"Front",
	"Back",
	"Waist",
	"T-Shirt",
	"Shirt",
	"Pants",
	"Jacket",
	"Sweater",
	"Shorts",
	"Left Shoe",
	"Right Shoe",
	"Dress",
	"Eyebrows",
	"Eyelashes",
}
local KIND_NAMES = {
	"Head",
	"Torso",
	"Left Arm",
	"Right Arm",
	"Left Leg",
	"Right Leg",
	"Face",
	"Shirt",
	"Pants",
	"T-Shirt",
	"Idle Animation",
	"Walk Animation",
	"Run Animation",
	"Jump Animation",
	"Fall Animation",
	"Climb Animation",
	"Swim Animation",
	"Mood Animation",
}

-- The name of `look`'s asset `index` in the Clothing tab: its kind, numbered when there are more
-- of that kind ("Hat 2").
function CharacterRules.assetLabel(look: Appearance, index: number): string
	local asset = look.assets[index]
	if asset == nil then
		return ""
	end
	local accessory = Appearance.accessoryType(asset.kind)
	local name = if accessory
		then ACCESSORY_NAMES[accessory] or `Accessory {accessory}`
		else KIND_NAMES[asset.kind] or `Item {asset.kind}`
	local count, nth = 0, 0
	for i, other in look.assets do
		if other.kind == asset.kind then
			count += 1
			if i == index then
				nth = count
			end
		end
	end
	return if count > 1 then `{name} {nth}` else name
end

-- The Clothing tab's toggle text ("Hat 1: ON").
function CharacterRules.assetToggleLabel(look: Appearance, index: number): string
	local asset = look.assets[index]
	return `{CharacterRules.assetLabel(look, index)}: {if asset and asset.worn then "ON" else "OFF"}`
end

--[[
	`look` with asset `index` switched on or off (a copy): switching on one of a single kind (a
	face, a shirt, a body part) switches the others of its kind off.
]]
function CharacterRules.toggleAsset(look: Appearance, index: number): Appearance
	local result = Appearance.copy(look)
	local asset = result.assets[index]
	if asset == nil then
		return result
	end
	asset.worn = not asset.worn
	if asset.worn and not Appearance.isAccessory(asset.kind) then
		for i, other in result.assets do
			if i ~= index and other.kind == asset.kind then
				other.worn = false
			end
		end
	end
	return result
end

-- Does `look` wear none of the six body parts (the plain blocky body)?
function CharacterRules.isBlocky(look: Appearance): boolean
	for _, asset in look.assets do
		if asset.worn and asset.kind <= #Appearance.PARTS then
			return false
		end
	end
	return true
end

-- `look` with the blocky body (`on`: no body part worn) or the user's own parts back (a copy).
function CharacterRules.setBlocky(look: Appearance, on: boolean): Appearance
	local result = Appearance.copy(look)
	local taken: { [number]: boolean } = {}
	for _, asset in result.assets do
		if asset.kind <= #Appearance.PARTS then
			asset.worn = not on and not taken[asset.kind]
			taken[asset.kind] = true
		end
	end
	return result
end

-- The Presets tab's choices: Appearance.PRESETS, then the user's own avatar as it is.
CharacterRules.PRESETS = table.freeze({ "Classic", "Natural", "My Avatar" })

-- `look` with preset `name` (see PRESETS; "My Avatar": `snapshot` itself), a copy.
function CharacterRules.preset(look: Appearance, snapshot: Appearance, name: string): Appearance
	if name == "My Avatar" then
		return Appearance.copy(snapshot)
	end
	return Appearance.preset(look, name)
end

return CharacterRules
