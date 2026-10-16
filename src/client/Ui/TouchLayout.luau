--!strict
--[[
	Where the game's touch buttons go (pure: screen pixels in, rectangles out; tests/spec/TouchButtons
	places them on phones and tablets). Every button has a slot of its own around Roblox's jump
	button, so none moves when another comes or goes, none covers another, the jump button or the
	HUD's quickbar, and all stay on the screen.

	Why not ContextActionService's own places: its touch buttons (Roblox's CoreScript
	ContextActionTouch) take the first free place of a fixed table of seven around a frame at the
	screen's lower right, in the order they were bound, and keep it even when SetPosition moves
	them. Bound in another order they move; on a landscape phone the third place is half under the
	screen's bottom and the sixth wholly under it; an eighth button is never made. So each button
	names its slot here and is put there explicitly: ContextActionService's (Sprint and Sneak:
	Player/MovementController; FIRE, AIM, RELOAD: Ui/WeaponButtons) with SetPosition, and the
	camera's VIEW and LOOK are the game's own buttons (Ui/TouchButtons), which take none of the
	seven.

	  slots   two rows above the jump button, GAP apart, in columns from the one over the jump
	          button leftwards (none beside it: the HUD's quickbar may reach there on a tablet):
	              row 2   AIM     RELOAD  LOOK
	              row 1   Sprint  FIRE    Sneak   VIEW
	                      [jump]
	  size    BUTTON screen pixels a side, ContextActionService's (its 35 on screens at most 320
	          pixels tall fit inside).
	  where   offsets from the safe area's bottom right corner (`offset`): ContextActionService's
	          button frame and PlayerModule's jump button are both anchored there (HudLayout.
	          jumpButton: 70 pixels where the safe area's smaller side is at most 500, else 120),
	          so a slot is the same offset on every screen with the same jump button; `rect` is a
	          slot on a given screen.
	  shown   the camera's VIEW and LOOK only where they do something (`cameraShown`): a touch
	          screen with the Touch Buttons setting on, the DayZ camera on and playing, not a
	          spectator (who always sees from the eyes and can't freelook).
]]

local HudLayout = require(script.Parent.HudLayout)

local TouchLayout = {}

export type Slot = "sprint" | "sneak" | "fire" | "aim" | "reload" | "view" | "look"

-- Screen pixels: a button's side, and the gap between buttons and round the jump button.
TouchLayout.BUTTON = 45
TouchLayout.GAP = 8

-- Each slot's column (0 over the jump button, then leftwards) and row (1 just above it).
TouchLayout.SLOTS = table.freeze({
	sprint = { 0, 1 },
	fire = { 1, 1 },
	sneak = { 2, 1 },
	view = { 3, 1 },
	aim = { 0, 2 },
	reload = { 1, 2 },
	look = { 2, 2 },
} :: { [Slot]: { number } })

-- Every slot, in a fixed order (the specs go through them).
TouchLayout.ORDER = table.freeze({ "sprint", "fire", "sneak", "view", "aim", "reload", "look" } :: { Slot })

--[[
	The slot's top left corner from the safe area's bottom right corner (screen pixels, both
	negative) on a `width` x `height` screen with `insets` (HudLayout.Insets), whole pixels.
]]
function TouchLayout.offset(slot: Slot, width: number, height: number, insets: HudLayout.Insets): (number, number)
	local place = TouchLayout.SLOTS[slot]
	local jump = HudLayout.jumpButton(width, height, insets)
	local right, bottom = width - insets.right, height - insets.bottom
	local step = TouchLayout.BUTTON + TouchLayout.GAP
	local x = jump.x + (jump.w - TouchLayout.BUTTON) / 2 - place[1] * step
	local y = jump.y - place[2] * step
	return math.floor(x - right), math.floor(y - bottom)
end

-- The slot's rectangle on a `width` x `height` screen with `insets` (screen pixels).
function TouchLayout.rect(slot: Slot, width: number, height: number, insets: HudLayout.Insets): HudLayout.Rect
	local x, y = TouchLayout.offset(slot, width, height, insets)
	local side = TouchLayout.BUTTON
	return { x = width - insets.right + x, y = height - insets.bottom + y, w = side, h = side }
end

--[[
	Do the camera's VIEW and LOOK show: a touch screen (`touch`) with the Touch Buttons setting on
	(`setting`), the DayZ camera on (`rig`) and playing (`playing`: Player/CameraRig.playing, no
	screen open), for a player who isn't a spectator?
]]
function TouchLayout.cameraShown(
	touch: boolean,
	setting: boolean,
	rig: boolean,
	playing: boolean,
	spectator: boolean
): boolean
	return touch and setting and rig and playing and not spectator
end

return TouchLayout
