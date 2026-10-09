--!strict
--[[
	The menus' one hover tooltip: Minecraft's dark tooltip box (the Options menu's look) with a
	button's description from Ui/ButtonHelp, for every menu button that registers itself
	(`attach`). The shape and the place are Ui/TooltipLayout's (pure, tested); this draws it and
	follows the input.

	  attach     HoverTip.attach(object, id, variant?) registers a GuiObject under a ButtonHelp id
	             (written as a string literal: tests/spec/ButtonHelp finds them in the sources);
	             `variant` picks one of the entry's variants, a string or a function asked each time
	             the tooltip shows (a button whose meaning changes: an eye that hides or shows).
	             Attaching an object again replaces its id. Its connections go with the object.
	  Mouse      resting on the object for HOVER_DELAY seconds shows it near the pointer
	             (TooltipLayout.nearPointer: Minecraft's DefaultTooltipPositioner), following the
	             pointer; leaving hides it. MouseEnter that comes from a touch is ignored.
	  Touch      a finger held still (TOUCH_MOVE screen pixels) on the object for LONG_PRESS
	             seconds shows it above the finger (`aboveTouch`); that press then doesn't click
	             (the object is not Interactable until the finger lifts, and `consumed` tells
	             FormWidgets' buttons to ignore it). It stays LINGER seconds after the finger
	             lifts, or until the next touch.
	  Gamepad    the selection on the object (a gamepad or keyboard steering) shows it under or
	             over the object (`belowOrAbove`: BelowOrAboveWidgetTooltipPositioner); losing the
	             selection hides it.
	  Hiding     also when the object or a parent is hidden or gone (checked every frame while
	             shown), and `hide` (a page change). A text that changes while shown (a variant
	             function) is drawn again.
	  Scale      the tooltip takes the scale its object is drawn at (the UIScales over it: the
	             menu's GUI scale from Ui/UiScale; the base GUI scale for an object under none),
	             so it reads as the menu's own text. It is drawn on its own ScreenGui on the "Tip"
	             layer, over every menu (the title screen's too).
	`drawBox` draws the box itself (TooltipLayout.size, a 1 pixel purple border blended over the
	translucent back, rows LINE apart with the text's shadow), for callers that place their own.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local ButtonHelp = require(script.Parent.ButtonHelp)
local Style = require(script.Parent.Style)
local TooltipLayout = require(script.Parent.TooltipLayout)
local UiScale = require(script.Parent.UiScale)

export type Variant = string | () -> string?

type Attached = { id: string, variant: Variant? }
type Press = { object: GuiObject, input: InputObject, start: Vector2, moved: boolean, shown: boolean }

local HoverTip = {}

-- Seconds the mouse rests before the tooltip shows, a finger holds still, and the tooltip stays
-- after the finger lifts; how far (screen pixels) a held finger may move.
HoverTip.HOVER_DELAY = 0.25
HoverTip.LONG_PRESS = 0.5
HoverTip.LINGER = 2.5
HoverTip.TOUCH_MOVE = 10
-- Seconds after a long press within which its object's click is ignored (`consumed`).
local CONSUME = 0.4
-- The border's colours, blended over the back as Minecraft draws them (translucent).
local BORDER_TOP = Color3.fromRGB(36, 0, 90)
local BORDER_BOTTOM = Color3.fromRGB(23, 0, 50)

-- What is attached (weak: an object that is gone goes).
local attached: { [GuiObject]: Attached } = setmetatable({}, { __mode = "k" }) :: any

local gui: ScreenGui? = nil
local holder: Frame? = nil
local box: Frame? = nil
local scaler: UIScale? = nil
local started = false

-- What shows: its object, how it was asked for, its text and size (GUI pixels), the scale and
-- (touch) the finger's point.
local owner: GuiObject? = nil
local how: "mouse" | "touch" | "gamepad" | nil = nil
local shownText = ""
local shownW, shownH = 0, 0
local shownScale = 1
local touchPoint = Vector2.zero
-- The object the mouse rests on, the finger held down, the objects made not Interactable by a
-- long press, and when each object's last long press showed its tooltip.
local hovering: GuiObject? = nil
local press: Press? = nil
local disabled: { [GuiObject]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local pressedAt: { [GuiObject]: number } = setmetatable({}, { __mode = "k" }) :: any
-- Bumped by every touch-shown tooltip, so an old linger doesn't hide a newer one.
local lingerToken = 0

local function measure(text: string): number
	return Style.textWidth(text)
end

-- Draws Minecraft's tooltip box with `rows` into `parent` at (0, 0); returns its width and height.
function HoverTip.drawBox(parent: Instance, rows: { string }): (number, number)
	local w, h = TooltipLayout.size(rows, measure)
	local pad = TooltipLayout.PAD
	local back = Style.frame(parent, 0, 0, w, h, Style.Colour.TooltipBack, 1)
	back.BackgroundTransparency = 0.06
	for i, side in Style.border(back, 1, 1, w - 2, h - 2, 1, BORDER_TOP, 2) do
		side.BackgroundColor3 = if i == 2 then BORDER_BOTTOM else BORDER_TOP
		if i >= 3 then
			side.BackgroundColor3 = Color3.new(1, 1, 1)
			local gradient = Instance.new("UIGradient")
			gradient.Rotation = 90
			gradient.Color = ColorSequence.new(BORDER_TOP, BORDER_BOTTOM)
			gradient.Parent = side
		end
	end
	for i, row in rows do
		Style.shadowText(
			back,
			row,
			pad,
			pad + (i - 1) * TooltipLayout.LINE,
			w - 2 * pad + 2,
			TooltipLayout.TEXT,
			Style.Colour.Text,
			5
		)
	end
	return w, h
end

-- The text attached to `object` now (nil: none).
function HoverTip.textOf(object: GuiObject): string?
	local info = attached[object]
	if info == nil then
		return nil
	end
	local variant = info.variant
	local key: string? = if type(variant) == "function" then variant() else variant :: string?
	local text = ButtonHelp.text(info.id, key)
	return if text and text ~= "" then text else nil
end

-- Was `object`'s press a long press that showed its tooltip (its click should be ignored)?
function HoverTip.consumed(object: GuiObject): boolean
	local at = pressedAt[object]
	return at ~= nil and os.clock() - at < CONSUME
end

-- The scale `object` is drawn at: the UIScales over it, or the base GUI scale under none.
local function scaleOf(object: GuiObject): number
	local scale, found = 1, false
	local current: Instance? = object
	while current and not current:IsA("LayerCollector") do
		local uiScale = current:FindFirstChildWhichIsA("UIScale")
		if uiScale then
			scale *= uiScale.Scale
			found = true
		end
		current = current.Parent
	end
	if not found or scale <= 0 then
		return UiScale.base()
	end
	return scale
end

local function mousePoint(): Vector2
	return UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
end

local function lastInputIs(prefix: string): boolean
	return string.sub(UserInputService:GetLastInputType().Name, 1, #prefix) == prefix
end

-- Moves the shown tooltip for the pointer at `point` (screen pixels; the finger's for touch).
local function place(point: Vector2?)
	local screen, frame, object = gui, holder, owner
	if screen == nil or frame == nil or object == nil then
		return
	end
	local scale = shownScale
	local origin = screen.AbsolutePosition
	local size = screen.AbsoluteSize / scale
	local x, y
	if how == "gamepad" or point == nil then
		local at = (object.AbsolutePosition - origin) / scale
		local extent = object.AbsoluteSize / scale
		x, y = TooltipLayout.belowOrAbove(at.X, at.Y, extent.X, extent.Y, shownW, shownH, size.X, size.Y)
	else
		local p = (point - origin) / scale
		if how == "touch" then
			x, y = TooltipLayout.aboveTouch(p.X, p.Y, shownW, shownH, size.X, size.Y)
		else
			x, y = TooltipLayout.nearPointer(p.X, p.Y, shownW, shownH, size.X, size.Y)
		end
	end
	frame.Position = UDim2.fromOffset(math.floor(x * scale + 0.5), math.floor(y * scale + 0.5))
end

function HoverTip.hide()
	local frame = holder
	if frame then
		frame.Visible = false
	end
	owner = nil
	how = nil
	shownText = ""
end

-- Draws `text` for `object` (shown `kind`-wise) and places it.
local function draw(object: GuiObject, text: string)
	local frame, inner, uiScale = holder, box, scaler
	if frame == nil or inner == nil or uiScale == nil then
		return
	end
	inner:ClearAllChildren()
	local w, h = HoverTip.drawBox(inner, TooltipLayout.wrap(text, measure))
	shownText, shownW, shownH = text, w, h
	shownScale = scaleOf(object)
	uiScale.Scale = shownScale
	frame.Size = UDim2.fromOffset(w, h)
end

local start: () -> ()

local function show(object: GuiObject, kind: "mouse" | "touch" | "gamepad", point: Vector2?)
	start()
	local text = HoverTip.textOf(object)
	if text == nil or not Style.shown(object) then
		if owner == object then
			HoverTip.hide()
		end
		return
	end
	owner, how = object, kind
	draw(object, text)
	if kind == "touch" and point then
		touchPoint = point
	end
	place(if kind == "mouse" then mousePoint() elseif kind == "touch" then touchPoint else nil)
	local frame = holder
	if frame then
		frame.Visible = true
	end
end

-- Gives a long-pressed object its clicks back once the finger has lifted.
local function restore(object: GuiObject)
	if disabled[object] then
		disabled[object] = nil
		task.delay(0.1, function()
			if object.Parent ~= nil then
				object.Interactable = true
			end
		end)
	end
end

start = function()
	if started then
		return
	end
	started = true
	local screen = UiScale.screenGui("IceVoxelHoverTip", "Tip", { inset = true, kind = "scaled" })
	local frame = Instance.new("Frame")
	frame.Name = "Tooltip"
	frame.BackgroundTransparency = 1
	frame.Visible = false
	frame.Parent = screen
	local uiScale = Instance.new("UIScale")
	uiScale.Parent = frame
	local inner = Instance.new("Frame")
	inner.Name = "Box"
	inner.BackgroundTransparency = 1
	inner.Size = UDim2.fromScale(1, 1)
	inner.Parent = frame
	gui, holder, box, scaler = screen, frame, inner, uiScale
	screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	-- The mouse moving: the tooltip follows it.
	UserInputService.InputChanged:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			if owner and how == "mouse" then
				place(mousePoint())
			end
			return
		end
		local held = press
		if held and input == held.input then
			local p = Vector2.new(input.Position.X, input.Position.Y)
			if (p - held.start).Magnitude > HoverTip.TOUCH_MOVE then
				held.moved = true
				if held.shown and owner == held.object then
					HoverTip.hide()
				end
			end
		end
	end)
	-- A new touch hides a touch's tooltip (the press on an attached object starts its own), and
	-- gives back the clicks of any object a lost touch left without them.
	UserInputService.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		if how == "touch" then
			HoverTip.hide()
		end
		local held = press
		for object in disabled do
			if held == nil or held.object ~= object then
				restore(object)
			end
		end
	end)
	-- The finger lifting: the tooltip lingers, the object gets its clicks back.
	UserInputService.InputEnded:Connect(function(input: InputObject)
		local held = press
		if held == nil or input ~= held.input then
			return
		end
		press = nil
		restore(held.object)
		if held.shown and owner == held.object and how == "touch" then
			lingerToken += 1
			local mine = lingerToken
			task.delay(HoverTip.LINGER, function()
				if lingerToken == mine and how == "touch" then
					HoverTip.hide()
				end
			end)
		end
	end)
	-- While shown: gone or hidden objects hide it, a changed text is drawn again.
	RunService.Heartbeat:Connect(function()
		local object = owner
		if object == nil then
			return
		end
		if object.Parent == nil or not Style.shown(object) or (how == "mouse" and hovering ~= object) then
			HoverTip.hide()
			return
		end
		local text = HoverTip.textOf(object)
		if text == nil then
			HoverTip.hide()
		elseif text ~= shownText then
			draw(object, text)
			place(if how == "mouse" then mousePoint() elseif how == "touch" then touchPoint else nil)
		end
	end)
end

-- Starts a long press on `object` by the touch `input`.
local function beginPress(object: GuiObject, input: InputObject)
	local held: Press = {
		object = object,
		input = input,
		start = Vector2.new(input.Position.X, input.Position.Y),
		moved = false,
		shown = false,
	}
	press = held
	task.delay(HoverTip.LONG_PRESS, function()
		if press ~= held or held.moved or not Style.shown(object) or HoverTip.textOf(object) == nil then
			return
		end
		held.shown = true
		lingerToken += 1
		show(object, "touch", held.start)
		if owner == object then
			pressedAt[object] = os.clock()
			if object.Interactable then
				object.Interactable = false
				disabled[object] = true
			end
		end
	end)
end

--[[
	Registers `object` as the button ButtonHelp calls `id` (its `variant`, or the variant a
	function names when the tooltip shows). See the header.
]]
function HoverTip.attach(object: GuiObject, id: string, variant: Variant?)
	local info = attached[object]
	if info then
		info.id, info.variant = id, variant
		return
	end
	attached[object] = { id = id, variant = variant }
	object.MouseEnter:Connect(function()
		if lastInputIs("Touch") then
			return
		end
		hovering = object
		task.delay(HoverTip.HOVER_DELAY, function()
			if hovering == object and owner ~= object then
				show(object, "mouse", mousePoint())
			end
		end)
	end)
	object.MouseLeave:Connect(function()
		if hovering == object then
			hovering = nil
		end
		if owner == object and how == "mouse" then
			HoverTip.hide()
		end
	end)
	object.SelectionGained:Connect(function()
		if lastInputIs("Gamepad") or lastInputIs("Keyboard") then
			show(object, "gamepad", nil)
		end
	end)
	object.SelectionLost:Connect(function()
		if owner == object and how == "gamepad" then
			HoverTip.hide()
		end
	end)
	object.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch then
			beginPress(object, input)
		end
	end)
end

return HoverTip
