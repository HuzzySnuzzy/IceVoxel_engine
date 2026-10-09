--!strict
--[[
	The player's key bindings on this client: every input site asks here instead of naming a key
	(Minecraft's KeyMapping.matches / isDown). The bindings are settings ("key.<action>", Shared/
	KeyBindings' codes) in the session's values (Settings), so they are saved, merged and reset like
	any setting; the Key Binds screen (Ui/SettingsScreen) changes them.

	  matches(action, input)  the InputObject is the action's key or mouse button (a press or a
	                          release: the callers keep their own `processed`, screen and typing
	                          checks). "Not Bound" matches nothing.
	  isDown(action)          the action's key or mouse button is held now
	                          (UserInputService:IsKeyDown / IsMouseButtonPressed), and the player
	                          isn't typing (`typing`: a text box or Roblox's chat bar focused; the
	                          control scripts' keys stop there too).
	  hotbarSlot(input)       which Hotbar Slot key it is (1-9), nil for none.
	  name(action)            the key's name for hints ("E", "Left Shift", "Right Button").
	  input(action)           the Enum.KeyCode or Enum.UserInputType to bind (ContextActionService:
	                          the sprint and sneak actions, Player/MovementController), nil when
	                          not bound.
	  usingKeys()             the keyboard and mouse are the input in use (a keyboard is there and
	                          Roblox's last input was no gamepad or touch), so the movement keys
	                          drive the walk instead of a stick or the thumbstick.
	  changed                 fires after bindings changed (the "keys" settings effect, `refresh`).

	Touch and gamepad controls are not bindings: they stay where they are.

	Chat: the chat's own module listens for "chat" (T) and "command" (/) with
	`Keybinds.matches("chat", input)` / `matches("command", input)`; the hint on its touch button or
	help text comes from `Keybinds.name("chat")`.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local KeyBindings = require(Shared.KeyBindings)

local Settings = require(script.Parent)

local Keybinds = {}

local values = Settings.values

local changedEvent = Instance.new("BindableEvent")
-- Fires after the bindings changed.
Keybinds.changed = changedEvent.Event

-- Mouse button codes <-> Roblox's input types.
local MOUSE_TYPES: { [number]: Enum.UserInputType } = {
	[KeyBindings.MOUSE.MouseButton1] = Enum.UserInputType.MouseButton1,
	[KeyBindings.MOUSE.MouseButton2] = Enum.UserInputType.MouseButton2,
	[KeyBindings.MOUSE.MouseButton3] = Enum.UserInputType.MouseButton3,
}
local MOUSE_CODES: { [Enum.UserInputType]: number } = {}
for code, kind in MOUSE_TYPES do
	MOUSE_CODES[kind] = code
end

-- Key codes -> Enum.KeyCode (the bindable ones).
local KEY_CODES: { [number]: Enum.KeyCode } = {}
for _, key in KeyBindings.KEYS do
	if MOUSE_TYPES[key.code] == nil then
		local ok, code = pcall(function()
			return (Enum.KeyCode :: any)[key.name]
		end)
		if ok and code then
			KEY_CODES[key.code] = code
		end
	end
end

-- The code of an InputObject (nil for anything that can't be bound).
function Keybinds.codeOf(input: InputObject): number?
	local kind = input.UserInputType
	if kind == Enum.UserInputType.Keyboard then
		local value = input.KeyCode.Value
		return if KEY_CODES[value] then value else nil
	end
	return MOUSE_CODES[kind]
end

-- Action `action`'s binding (Shared/KeyBindings' code).
function Keybinds.code(action: string): number
	return KeyBindings.codeOf(values, action)
end

-- Is `input` action `action`'s key or mouse button?
function Keybinds.matches(action: string, input: InputObject): boolean
	return KeyBindings.matches(values, action, Keybinds.codeOf(input))
end

-- Does a text box of the game's own (in this player's PlayerGui) have the keys? Roblox's hidden
-- core boxes don't count: its chat bar, turned off by the game, can keep the focus a moment after
-- the game's chat box closed and would otherwise hold the player still meanwhile.
function Keybinds.textBoxFocused(): boolean
	local focused = UserInputService:GetFocusedTextBox()
	if focused == nil then
		return false
	end
	local player = Players.LocalPlayer
	local playerGui = if player then player:FindFirstChildOfClass("PlayerGui") else nil
	local ok, ours = pcall(function()
		return playerGui ~= nil and focused:IsDescendantOf(playerGui)
	end)
	return ok and ours
end

-- Is the player typing (a text box or Roblox's chat bar has the keys)?
function Keybinds.typing(): boolean
	if Keybinds.textBoxFocused() then
		return true
	end
	-- (Roblox's own input bar counts only while it is on: the game turns it off, and a bar left
	-- focused from before would otherwise block every key, the chat's T among them.)
	local bar = TextChatService:FindFirstChildOfClass("ChatInputBarConfiguration")
	return bar ~= nil and bar.Enabled and bar.IsFocused
end

-- Is action `action`'s key or mouse button held now (never while typing: the letters typed
-- don't walk)?
function Keybinds.isDown(action: string): boolean
	local code = KeyBindings.codeOf(values, action)
	if code == KeyBindings.NONE or Keybinds.typing() then
		return false
	end
	local mouse = MOUSE_TYPES[code]
	if mouse then
		return UserInputService:IsMouseButtonPressed(mouse)
	end
	local key = KEY_CODES[code]
	return key ~= nil and UserInputService:IsKeyDown(key)
end

-- The hotbar slot (1-9) whose key `input` is, nil for none.
function Keybinds.hotbarSlot(input: InputObject): number?
	return KeyBindings.hotbarSlot(values, Keybinds.codeOf(input))
end

-- The name of action `action`'s key ("E", "Left Shift", "Not Bound").
function Keybinds.name(action: string): string
	return KeyBindings.text(KeyBindings.codeOf(values, action))
end

-- The Enum.KeyCode or Enum.UserInputType of action `action`'s binding (nil: not bound).
function Keybinds.input(action: string): (Enum.KeyCode | Enum.UserInputType)?
	local code = KeyBindings.codeOf(values, action)
	return MOUSE_TYPES[code] or KEY_CODES[code]
end

--[[
	Are the keyboard and mouse the input in use: a keyboard is there and Roblox's last input was
	neither a gamepad nor a touch (a key, the mouse, or something in between such as the window
	getting the focus back)?
]]
function Keybinds.usingKeys(): boolean
	return KeyBindings.usingKeys(UserInputService.KeyboardEnabled, UserInputService:GetLastInputType().Name)
end

-- The "keys" settings effect: the bindings changed (or were loaded).
function Keybinds.refresh()
	changedEvent:Fire()
end

return Keybinds
