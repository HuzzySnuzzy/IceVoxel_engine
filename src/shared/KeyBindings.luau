--!strict
--[[
	Minecraft's key mappings (KeyMapping, the Controls > Key Binds screen) for this game: every
	action a key or mouse button does on a computer, its default, and the rules the Key Binds
	screen shows. Pure: the client's Settings/Keybinds reads the player's bindings with it, the
	settings schema (Shared/PlayerSettings) stores them, the tests check them.

	  Actions    `ACTIONS`, append-only (their order gives the settings ids: PlayerSettings stores
	             action i as the setting "key.<action>", id KEY_BASE + i - 1). Each has a category
	             (Minecraft's Movement, Gameplay, Inventory, Multiplayer, Miscellaneous, then this
	             game's Map and JEI's, as mods add theirs), Minecraft's name ("Walk Forwards"),
	             the default (today's keys: Config's sprint, sneak, Options and skill tree keys,
	             the rest Minecraft's) and a context, Forge's KeyConflictContext: "game" (in the
	             world, no screen open), "screen" (in the inventory screens: JEI's keys) or
	             "universal" (both: E closes the inventory, Q throws the hovered stack, 1-9 swap
	             with the hotbar, P and K close their own screens).
	  Inputs     a binding is one input, kept as a number (`code`, so it fits the settings' f32
	             wire): Roblox's Enum.KeyCode value for a key (W = 119, Left Shift = 304), and for
	             the mouse buttons the values Roblox gives its mouse KeyCodes (MouseLeftButton
	             1018, MouseRightButton 1019, MouseMiddleButton 1020), named after the
	             UserInputType they arrive as (MouseButton1..3); 0 is "Not Bound" (KeyCode.
	             Unknown). `KEYS` lists every input that can be bound (every keyboard KeyCode but
	             Escape, which unbinds as in Minecraft, and the international World keys), each
	             with Minecraft's display name ("Left Shift", "Right Button", "/").
	  Conflicts  two actions bound to the same input conflict when their contexts overlap (game
	             with game, screen with screen, universal with either); the Key Binds screen
	             draws them red, as Minecraft does, as a warning: one key need not reach both, as
	             in Minecraft (where one mapping gets a key). Sprint and Sneak take their key from
	             every other action (bound through ContextActionService, the key then arrives
	             processed everywhere else; with each other, the one bound last), and an
	             inventory screen acts on the first of its bindings that matches. The defaults
	             conflict nowhere (tests/spec/Keybinds).
	  Order      the Key Binds list shows categories in `CATEGORIES` order and, within one,
	             actions by name (KeyMapping.compareTo sorts by the translated name), `ordered`.

	Fixed keys stay out of the list, as in Minecraft: Escape, the modifiers of clicks (Shift,
	Ctrl + Q for the whole stack), F3's combinations' second keys (F3 + N, F3 + Q, F3 + F4: the
	debug key's), the mouse buttons on slots, and every gamepad and touch control.
]]

local Config = require(script.Parent.Config)

export type Context = "game" | "screen" | "universal"

export type Action = {
	-- The action's id ("forward"); its setting is "key." .. id.
	id: string,
	-- Minecraft's name of the mapping (en_us), shown on the Key Binds screen.
	name: string,
	category: string,
	-- The default input's name (an Enum.KeyCode name or "MouseButton1".."MouseButton3").
	default: string,
	context: Context,
	-- What the action does (`TOOLTIPS`): the Key Binds screen's tooltip, and its setting's
	-- (PlayerSettings) tooltip.
	tooltip: string,
}

export type Category = { id: string, name: string }

export type Key = {
	-- Enum.KeyCode name, or the UserInputType name of a mouse button.
	name: string,
	code: number,
	-- Minecraft's display name.
	text: string,
}

local KeyBindings = {}

-- "Not Bound" (Enum.KeyCode.Unknown's value).
KeyBindings.NONE = 0
-- The settings id of the first action (PlayerSettings: plain settings stay below it).
KeyBindings.KEY_BASE = 128
KeyBindings.SETTING_PREFIX = "key."

-- The mouse buttons, by the UserInputType they arrive as: Roblox's mouse KeyCode values.
KeyBindings.MOUSE = table.freeze({
	MouseButton1 = 1018,
	MouseButton2 = 1019,
	MouseButton3 = 1020,
})

--[[ Inputs ]]

-- name, Roblox's Enum.KeyCode value, Minecraft's display name. (tests/spec/Keybinds checks every
-- value against Roblox's enum.)
local KEY_LIST: { { any } } = {
	{ "A", 97, "A" },
	{ "B", 98, "B" },
	{ "C", 99, "C" },
	{ "D", 100, "D" },
	{ "E", 101, "E" },
	{ "F", 102, "F" },
	{ "G", 103, "G" },
	{ "H", 104, "H" },
	{ "I", 105, "I" },
	{ "J", 106, "J" },
	{ "K", 107, "K" },
	{ "L", 108, "L" },
	{ "M", 109, "M" },
	{ "N", 110, "N" },
	{ "O", 111, "O" },
	{ "P", 112, "P" },
	{ "Q", 113, "Q" },
	{ "R", 114, "R" },
	{ "S", 115, "S" },
	{ "T", 116, "T" },
	{ "U", 117, "U" },
	{ "V", 118, "V" },
	{ "W", 119, "W" },
	{ "X", 120, "X" },
	{ "Y", 121, "Y" },
	{ "Z", 122, "Z" },
	{ "Zero", 48, "0" },
	{ "One", 49, "1" },
	{ "Two", 50, "2" },
	{ "Three", 51, "3" },
	{ "Four", 52, "4" },
	{ "Five", 53, "5" },
	{ "Six", 54, "6" },
	{ "Seven", 55, "7" },
	{ "Eight", 56, "8" },
	{ "Nine", 57, "9" },
	{ "F1", 282, "F1" },
	{ "F2", 283, "F2" },
	{ "F3", 284, "F3" },
	{ "F4", 285, "F4" },
	{ "F5", 286, "F5" },
	{ "F6", 287, "F6" },
	{ "F7", 288, "F7" },
	{ "F8", 289, "F8" },
	{ "F9", 290, "F9" },
	{ "F10", 291, "F10" },
	{ "F11", 292, "F11" },
	{ "F12", 293, "F12" },
	{ "F13", 294, "F13" },
	{ "F14", 295, "F14" },
	{ "F15", 296, "F15" },
	{ "Space", 32, "Space" },
	{ "Tab", 9, "Tab" },
	{ "Return", 13, "Enter" },
	{ "Backspace", 8, "Backspace" },
	{ "CapsLock", 301, "Caps Lock" },
	{ "LeftShift", 304, "Left Shift" },
	{ "RightShift", 303, "Right Shift" },
	{ "LeftControl", 306, "Left Control" },
	{ "RightControl", 305, "Right Control" },
	{ "LeftAlt", 308, "Left Alt" },
	{ "RightAlt", 307, "Right Alt" },
	{ "LeftSuper", 311, "Left Win" },
	{ "RightSuper", 312, "Right Win" },
	{ "LeftMeta", 310, "Left Cmd" },
	{ "RightMeta", 309, "Right Cmd" },
	{ "Up", 273, "Up Arrow" },
	{ "Down", 274, "Down Arrow" },
	{ "Right", 275, "Right Arrow" },
	{ "Left", 276, "Left Arrow" },
	{ "Insert", 277, "Insert" },
	{ "Delete", 127, "Delete" },
	{ "Home", 278, "Home" },
	{ "End", 279, "End" },
	{ "PageUp", 280, "Page Up" },
	{ "PageDown", 281, "Page Down" },
	{ "NumLock", 300, "Num Lock" },
	{ "ScrollLock", 302, "Scroll Lock" },
	{ "Pause", 19, "Pause" },
	{ "Print", 316, "Print Screen" },
	{ "Menu", 319, "Menu" },
	{ "Quote", 39, "'" },
	{ "Comma", 44, "," },
	{ "Minus", 45, "-" },
	{ "Period", 46, "." },
	{ "Slash", 47, "/" },
	{ "Semicolon", 59, ";" },
	{ "Equals", 61, "=" },
	{ "LeftBracket", 91, "[" },
	{ "BackSlash", 92, "\\" },
	{ "RightBracket", 93, "]" },
	{ "Backquote", 96, "`" },
	{ "QuotedDouble", 34, '"' },
	{ "Hash", 35, "#" },
	{ "Dollar", 36, "$" },
	{ "Percent", 37, "%" },
	{ "Ampersand", 38, "&" },
	{ "LeftParenthesis", 40, "(" },
	{ "RightParenthesis", 41, ")" },
	{ "Asterisk", 42, "*" },
	{ "Plus", 43, "+" },
	{ "Colon", 58, ":" },
	{ "LessThan", 60, "<" },
	{ "GreaterThan", 62, ">" },
	{ "Question", 63, "?" },
	{ "At", 64, "@" },
	{ "Caret", 94, "^" },
	{ "Underscore", 95, "_" },
	{ "LeftCurly", 123, "{" },
	{ "Pipe", 124, "|" },
	{ "RightCurly", 125, "}" },
	{ "Tilde", 126, "~" },
	{ "KeypadZero", 256, "Keypad 0" },
	{ "KeypadOne", 257, "Keypad 1" },
	{ "KeypadTwo", 258, "Keypad 2" },
	{ "KeypadThree", 259, "Keypad 3" },
	{ "KeypadFour", 260, "Keypad 4" },
	{ "KeypadFive", 261, "Keypad 5" },
	{ "KeypadSix", 262, "Keypad 6" },
	{ "KeypadSeven", 263, "Keypad 7" },
	{ "KeypadEight", 264, "Keypad 8" },
	{ "KeypadNine", 265, "Keypad 9" },
	{ "KeypadPeriod", 266, "Keypad Decimal" },
	{ "KeypadDivide", 267, "Keypad /" },
	{ "KeypadMultiply", 268, "Keypad *" },
	{ "KeypadMinus", 269, "Keypad -" },
	{ "KeypadPlus", 270, "Keypad +" },
	{ "KeypadEnter", 271, "Keypad Enter" },
	{ "KeypadEquals", 272, "Keypad =" },
	{ "MouseButton1", 1018, "Left Button" },
	{ "MouseButton2", 1019, "Right Button" },
	{ "MouseButton3", 1020, "Middle Button" },
}

local KEYS: { Key } = {}
local keyByName: { [string]: Key } = {}
local keyByCode: { [number]: Key } = {}
for _, row in KEY_LIST do
	local key: Key = table.freeze({ name = row[1], code = row[2], text = row[3] })
	assert(keyByName[key.name] == nil and keyByCode[key.code] == nil, `KeyBindings: duplicate key {key.name}`)
	table.insert(KEYS, key)
	keyByName[key.name] = key
	keyByCode[key.code] = key
end
KeyBindings.KEYS = table.freeze(KEYS)
-- The highest code (the settings' range).
KeyBindings.MAX_CODE = 1020

--[[ Actions ]]

KeyBindings.CATEGORIES = table.freeze({
	{ id = "movement", name = "Movement" },
	{ id = "gameplay", name = "Gameplay" },
	{ id = "inventory", name = "Inventory" },
	{ id = "multiplayer", name = "Multiplayer" },
	{ id = "misc", name = "Miscellaneous" },
	{ id = "map", name = "Map" },
	{ id = "jei", name = "Just Enough Items" },
} :: { Category })

-- The first keyboard key among Config's key names (its gamepad buttons stay Config's).
local function keyboardKey(names: { any }?, fallback: string): string
	local list: { any } = names or {}
	for _, name in list do
		if type(name) == "string" and keyByName[name] then
			return name
		end
	end
	return fallback
end

local function action(id: string, name: string, category: string, default: string, context: Context): Action
	return { id = id, name = name, category = category, default = default, context = context, tooltip = "" }
end

--[[
	What each action does, by id: the Key Binds screen's tooltips (Minecraft has none there; its
	option tooltips' style: what it does, then what else the key does in a screen). Every action
	needs one (checked as ACTIONS is built).
]]
local TOOLTIPS: { [string]: string } = {
	forward = "Walks forwards. Twice quickly (or with Sprint): sprints.",
	back = "Walks backwards.",
	left = "Steps to the left.",
	right = "Steps to the right.",
	jump = "Jumps; swims up in water and climbs ropes and ladders. Creative: twice quickly to fly, " .. "held to rise.",
	sneak = "Sneaks: slower, and you never walk off an edge. Flying: goes down.",
	sprint = "Runs while walking forwards.",
	attack = "Attacks, and breaks the block you look at (held: mines it).",
	use = "Uses the held item: places a block, eats, drinks. Opens a chest, a furnace or a machine.",
	pickItem = "Puts the block you look at in your hand, from your inventory (Creative: a new stack). "
		.. "Spectators: the spectator menu.",
	drop = "Throws one of the held item away (with Control: the whole stack). In a screen: the "
		.. "stack under the pointer.",
	inventory = "Opens your inventory, and closes any screen.",
	hotbar1 = "Selects hotbar slot 1. In a screen: swaps the stack under the pointer with it.",
	hotbar2 = "Selects hotbar slot 2. In a screen: swaps the stack under the pointer with it.",
	hotbar3 = "Selects hotbar slot 3. In a screen: swaps the stack under the pointer with it.",
	hotbar4 = "Selects hotbar slot 4. In a screen: swaps the stack under the pointer with it.",
	hotbar5 = "Selects hotbar slot 5. In a screen: swaps the stack under the pointer with it.",
	hotbar6 = "Selects hotbar slot 6. In a screen: swaps the stack under the pointer with it.",
	hotbar7 = "Selects hotbar slot 7. In a screen: swaps the stack under the pointer with it.",
	hotbar8 = "Selects hotbar slot 8. In a screen: swaps the stack under the pointer with it.",
	hotbar9 = "Selects hotbar slot 9. In a screen: swaps the stack under the pointer with it.",
	chat = "Opens the chat to talk to the other players.",
	command = "Opens the chat with a / typed, for a command.",
	options = "Opens the Options menu, and closes it.",
	skillTree = "Opens the skill tree: your Age, knowledge and the skills to unlock.",
	debug = "Shows the debug screen (position, chunk, frame rate). Held with another key: the debug "
		.. "keys (F3 + Q lists them).",
	worldMap = "Opens the world map: the land all around, where you are and your waypoints.",
	zoomIn = "Zooms the minimap in.",
	zoomOut = "Zooms the minimap out.",
	jeiRecipes = "Over an item in a screen: the recipes that make it (Just Enough Items).",
	jeiUses = "Over an item in a screen: the recipes it is used in (Just Enough Items).",
	jeiBack = "Back to the recipes shown before.",
	weatherMap = "Switches the minimap and the world map to the weather: rain, snow, storms, clouds, "
		.. "the wind and a forecast.",
}

local progression = (Config :: any).Progression
local settings = (Config :: any).Settings

-- Append-only: an action's place is its settings id (KEY_BASE + index - 1).
local ACTIONS: { Action } = {
	action("forward", "Walk Forwards", "movement", "W", "game"),
	action("back", "Walk Backwards", "movement", "S", "game"),
	action("left", "Strafe Left", "movement", "A", "game"),
	action("right", "Strafe Right", "movement", "D", "game"),
	action("jump", "Jump", "movement", "Space", "game"),
	action("sneak", "Sneak", "movement", keyboardKey(Config.Movement.SneakKeys, "LeftShift"), "game"),
	action("sprint", "Sprint", "movement", keyboardKey(Config.Movement.SprintKeys, "LeftControl"), "game"),
	action("attack", "Attack/Destroy", "gameplay", "MouseButton1", "game"),
	action("use", "Use Item/Place Block", "gameplay", "MouseButton2", "game"),
	action("pickItem", "Pick Block", "gameplay", "MouseButton3", "game"),
	action("drop", "Drop Selected Item", "inventory", "Q", "universal"),
	action("inventory", "Open/Close Inventory", "inventory", "E", "universal"),
	action("hotbar1", "Hotbar Slot 1", "inventory", "One", "universal"),
	action("hotbar2", "Hotbar Slot 2", "inventory", "Two", "universal"),
	action("hotbar3", "Hotbar Slot 3", "inventory", "Three", "universal"),
	action("hotbar4", "Hotbar Slot 4", "inventory", "Four", "universal"),
	action("hotbar5", "Hotbar Slot 5", "inventory", "Five", "universal"),
	action("hotbar6", "Hotbar Slot 6", "inventory", "Six", "universal"),
	action("hotbar7", "Hotbar Slot 7", "inventory", "Seven", "universal"),
	action("hotbar8", "Hotbar Slot 8", "inventory", "Eight", "universal"),
	action("hotbar9", "Hotbar Slot 9", "inventory", "Nine", "universal"),
	action("chat", "Open Chat", "multiplayer", "T", "game"),
	action("command", "Open Command", "multiplayer", "Slash", "game"),
	action("options", "Options", "misc", keyboardKey({ settings and settings.Key }, "P"), "universal"),
	action("skillTree", "Skill Tree", "misc", keyboardKey({ progression and progression.Key }, "K"), "universal"),
	action("debug", "Debug Screen", "misc", "F3", "game"),
	action("worldMap", "World Map", "map", "M", "game"),
	action("zoomIn", "Minimap Zoom In", "map", "Equals", "game"),
	action("zoomOut", "Minimap Zoom Out", "map", "Minus", "game"),
	action("jeiRecipes", "Show Recipe", "jei", "R", "screen"),
	action("jeiUses", "Show Uses", "jei", "U", "screen"),
	action("jeiBack", "Recipe Back", "jei", "Backspace", "screen"),
	-- The maps' weather mode (Map/WeatherLayer: precipitation, thunder and clouds, the wind and
	-- the forecast over the minimap and the world map).
	action("weatherMap", "Weather Map", "map", "B", "game"),
}

local byId: { [string]: Action } = {}
local settingKeys: { [string]: string } = {}
local categoryIds: { [string]: number } = {}
for i, category in KeyBindings.CATEGORIES do
	categoryIds[category.id] = i
end
for _, entry in ACTIONS do
	assert(byId[entry.id] == nil, `KeyBindings: duplicate action {entry.id}`)
	assert(keyByName[entry.default], `KeyBindings: unknown default {entry.default} of {entry.id}`)
	assert(categoryIds[entry.category], `KeyBindings: unknown category {entry.category}`)
	local tooltip = TOOLTIPS[entry.id]
	assert(tooltip, `KeyBindings: no tooltip for {entry.id}`)
	entry.tooltip = tooltip
	byId[entry.id] = entry
	settingKeys[entry.id] = KeyBindings.SETTING_PREFIX .. entry.id
	table.freeze(entry)
end
KeyBindings.ACTIONS = table.freeze(ACTIONS)
KeyBindings.byId = table.freeze(byId)

-- The hotbar slot keys, slot by slot.
KeyBindings.HOTBAR = table.freeze({
	"hotbar1",
	"hotbar2",
	"hotbar3",
	"hotbar4",
	"hotbar5",
	"hotbar6",
	"hotbar7",
	"hotbar8",
	"hotbar9",
})

-- The action `id` (errors on unknown ones: a typo should not be silent).
function KeyBindings.action(id: string): Action
	local entry = byId[id]
	assert(entry, `KeyBindings: unknown action {id}`)
	return entry
end

-- The settings key holding action `id`'s binding ("key.forward").
function KeyBindings.settingKey(id: string): string
	local key = settingKeys[id]
	assert(key, `KeyBindings: unknown action {id}`)
	return key
end

--[[ Inputs and names ]]

-- The input `name` (an Enum.KeyCode name or "MouseButton1".."3"), nil when it can't be bound.
function KeyBindings.find(name: string): Key?
	return keyByName[name]
end

-- The input of `code`, nil for "Not Bound" and unknown codes.
function KeyBindings.keyOf(code: number): Key?
	return keyByCode[code]
end

-- Can `code` be stored as a binding ("Not Bound" can)?
function KeyBindings.isCode(code: number): boolean
	return code == KeyBindings.NONE or keyByCode[code] ~= nil
end

-- Minecraft's name of `code`: "W", "Left Shift", "Right Button", "Not Bound".
function KeyBindings.text(code: number): string
	local key = keyByCode[code]
	return if key then key.text else "Not Bound"
end

-- The code of action `id`'s default.
function KeyBindings.defaultCode(id: string): number
	return keyByName[KeyBindings.action(id).default].code
end

--[[
	The code of an input as Roblox reports it: the UserInputType's name and, for keys, the
	KeyCode's value. nil for anything that can't be bound (gamepads, touches, the wheel, Escape).
]]
function KeyBindings.inputCode(inputType: string, keyCode: number): number?
	if inputType == "Keyboard" then
		return if keyByCode[keyCode] and keyCode < 1000 then keyCode else nil
	end
	return KeyBindings.MOUSE[inputType]
end

--[[
	Do the key bindings drive the player (the keyboard and mouse are the input in use)? With a
	keyboard (`keyboardEnabled`), unless Roblox's last input (`lastInputType`, a UserInputType
	name) was a gamepad or a touch: then the control scripts' stick and thumbstick do.
]]
function KeyBindings.usingKeys(keyboardEnabled: boolean, lastInputType: string): boolean
	if not keyboardEnabled then
		return false
	end
	return lastInputType ~= "Touch" and string.find(lastInputType, "^Gamepad") == nil
end

--[[ Bindings in a settings values table ]]

-- Action `id`'s binding in `values` (PlayerSettings values; its default when missing).
function KeyBindings.codeOf(values: { [string]: number }, id: string): number
	local code = values[settingKeys[id]]
	if code == nil then
		return KeyBindings.defaultCode(id)
	end
	return code
end

-- Is `code` action `id`'s input ("Not Bound" matches nothing)?
function KeyBindings.matches(values: { [string]: number }, id: string, code: number?): boolean
	if code == nil or code == KeyBindings.NONE then
		return false
	end
	return KeyBindings.codeOf(values, id) == code
end

-- The hotbar slot (1-9) whose key `code` is, nil for none (the first slot when two share it).
function KeyBindings.hotbarSlot(values: { [string]: number }, code: number?): number?
	if code == nil or code == KeyBindings.NONE then
		return nil
	end
	for slot, id in KeyBindings.HOTBAR do
		if KeyBindings.codeOf(values, id) == code then
			return slot
		end
	end
	return nil
end

-- Can two contexts be active at once (Forge's KeyConflictContext.conflicts)?
function KeyBindings.overlap(a: Context, b: Context): boolean
	return a == b or a == "universal" or b == "universal"
end

-- The other actions bound to action `id`'s input in an overlapping context, in list order.
function KeyBindings.conflicts(values: { [string]: number }, id: string): { string }
	local list = {}
	local mine = KeyBindings.action(id)
	local code = KeyBindings.codeOf(values, id)
	if code == KeyBindings.NONE then
		return list
	end
	for _, other in ACTIONS do
		if
			other.id ~= id
			and KeyBindings.codeOf(values, other.id) == code
			and KeyBindings.overlap(mine.context, other.context)
		then
			table.insert(list, other.id)
		end
	end
	return list
end

-- Every action that conflicts with another (the Key Binds screen's red ones).
function KeyBindings.conflicting(values: { [string]: number }): { [string]: boolean }
	local out: { [string]: boolean } = {}
	local byCode: { [number]: { Action } } = {}
	for _, entry in ACTIONS do
		local code = KeyBindings.codeOf(values, entry.id)
		if code ~= KeyBindings.NONE then
			local list = byCode[code]
			if list == nil then
				list = {}
				byCode[code] = list
			end
			table.insert(list, entry)
		end
	end
	for _, list in byCode do
		for i = 1, #list do
			for j = i + 1, #list do
				if KeyBindings.overlap(list[i].context, list[j].context) then
					out[list[i].id] = true
					out[list[j].id] = true
				end
			end
		end
	end
	return out
end

-- Is action `id` on its default?
function KeyBindings.isDefault(values: { [string]: number }, id: string): boolean
	return KeyBindings.codeOf(values, id) == KeyBindings.defaultCode(id)
end

--[[
	The Key Binds list: every category in CATEGORIES order with its actions sorted by name
	(KeyMapping.compareTo), empty categories left out.
]]
function KeyBindings.ordered(): { { category: Category, actions: { Action } } }
	local out = {}
	for _, category in KeyBindings.CATEGORIES do
		local actions = {}
		for _, entry in ACTIONS do
			if entry.category == category.id then
				table.insert(actions, entry)
			end
		end
		table.sort(actions, function(a: Action, b: Action): boolean
			return a.name < b.name
		end)
		if #actions > 0 then
			table.insert(out, { category = category, actions = actions })
		end
	end
	return out
end

return KeyBindings
