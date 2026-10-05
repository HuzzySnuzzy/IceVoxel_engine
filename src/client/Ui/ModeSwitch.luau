--!strict
--[[
	The game mode switcher's model (Minecraft 1.20.1's GameModeSwitcherScreen), pure so the tests run
	it; Ui/GameModeSwitcher draws it and feeds it the keys and the mouse.

	  slots      four, in GameMode.ORDER: Creative (a grass block), Survival (an iron sword),
	             Adventure (a map), Spectator (an ender eye)
	  opening    the highlighted slot starts on the previous game mode; without one, on Survival
	             when in Creative, else on Creative (getDefaultSelected)
	  F4         highlights the next mode in that order, wrapping round (GameModeIcon.getNext)
	  the mouse  highlights the slot it is over, but only once it has moved: where it was when the
	             screen opened, or when F4 was last pressed, does not count (firstMouseX / Y), so
	             a pointer resting on a slot does not undo F4
	  F3 up      switches to the highlighted mode unless it is the current one, and closes
	             (checkToClose: switchToHoveredGameMode)

	Layout (GUI pixels from the screen's centre, Minecraft's): the 125 x 75 background at (-62, -58);
	slots of 26 x 26, 31 apart, the first at (-59, -31), their 16 x 16 icon 5 pixels in; the
	highlighted mode's name centred at y -51 and "[ F4 ] Next" at y 5.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)

local ModeSwitch = {}

-- Layout, from the centre of the screen (GameModeSwitcherScreen.render / init).
ModeSwitch.PANEL_X = -62
ModeSwitch.PANEL_Y = -58
ModeSwitch.PANEL_WIDTH = 125
ModeSwitch.PANEL_HEIGHT = 75
ModeSwitch.SLOT = 26
ModeSwitch.SLOT_SPACING = 31
ModeSwitch.SLOT_Y = -31
ModeSwitch.ICON_INSET = 5
ModeSwitch.TITLE_Y = -51
ModeSwitch.HELP_Y = 5
-- "[ F4 ] Next": debug.gamemodes.select_next with debug.gamemodes.press_f4 in aqua.
ModeSwitch.HELP_KEY = "[ F4 ]"
ModeSwitch.HELP_TEXT = "Next"

export type Switcher = {
	-- The player's mode when the screen opened.
	current: string,
	-- The highlighted mode.
	hovered: string,
	-- Where the mouse was when the screen opened or F4 was last pressed (nil: not seen yet).
	anchorX: number?,
	anchorY: number?,
}

-- The mode highlighted when the screen opens (getDefaultSelected).
function ModeSwitch.defaultSelected(current: string, previous: string?): string
	if previous then
		return previous
	end
	return if current == GameMode.CREATIVE then GameMode.SURVIVAL else GameMode.CREATIVE
end

-- The mode after `mode` in the switcher's order (wrapping round).
function ModeSwitch.nextMode(mode: string): string
	local index = table.find(GameMode.ORDER, mode) or 0
	return GameMode.ORDER[index % #GameMode.ORDER + 1]
end

-- A switcher opened by a player in `current` mode whose previous mode is `previous`.
function ModeSwitch.new(current: string, previous: string?): Switcher
	return { current = current, hovered = ModeSwitch.defaultSelected(current, previous), anchorX = nil, anchorY = nil }
end

-- F4: the next mode; the mouse counts again only once it moves.
function ModeSwitch.next(switcher: Switcher)
	switcher.hovered = ModeSwitch.nextMode(switcher.hovered)
	switcher.anchorX, switcher.anchorY = nil, nil
end

--[[
	The mouse is at (x, y) (any pixels) over slot `slot` (a mode, nil: none), once a frame: once it
	has left where it was first seen, the slot under it is highlighted.
]]
function ModeSwitch.pointer(switcher: Switcher, x: number, y: number, slot: string?)
	if switcher.anchorX == nil or switcher.anchorY == nil then
		switcher.anchorX, switcher.anchorY = x, y
		return
	end
	local moved = x ~= switcher.anchorX or y ~= switcher.anchorY
	if moved and slot and GameMode.isValid(slot) then
		switcher.hovered = slot
	end
end

-- What letting go of F3 switches to: the highlighted mode, nil when the player is already in it.
function ModeSwitch.choice(switcher: Switcher): string?
	return if switcher.hovered ~= switcher.current then switcher.hovered else nil
end

-- The left edge of slot `index` (1..4), from the screen's centre: Minecraft's integer maths.
function ModeSwitch.slotX(index: number): number
	local all = #GameMode.ORDER * ModeSwitch.SLOT_SPACING - (ModeSwitch.SLOT_SPACING - ModeSwitch.SLOT)
	return -(all // 2) + (index - 1) * ModeSwitch.SLOT_SPACING
end

-- The title: the highlighted mode's name ("Creative Mode").
function ModeSwitch.title(switcher: Switcher): string
	return GameMode.displayName(switcher.hovered)
end

return ModeSwitch
