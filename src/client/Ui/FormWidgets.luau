--!strict
--[[
	Minecraft's screen widgets in this game's UI style (Ui/Style), for screens with fields and
	buttons (Ui/StructureScreen). Positions and sizes are in GUI pixels, as Minecraft's.

	  editBox    Minecraft's EditBox: black with a 1 pixel border (gray, white while focused), the
	             text #E0E0E0 four pixels in, vertically centred. `filter` rewrites what is typed
	             (Ui/StructureForm's field filters). Read only boxes (`readOnly`) can still be
	             focused and selected, so their text can be copied: Roblox scripts can't write the
	             clipboard, but a TextBox with TextEditable off keeps Ctrl+C (creator docs:
	             TextBox.TextEditable, "copy and paste text within a TextBox"). Focusing one
	             selects everything (SelectionStart / CursorPosition).
	  button     Minecraft's button with a label that can change (cycle buttons, "ON" / "OFF")
	             and an inactive look; Activated covers mouse, touch and gamepad A (not a long
	             press that showed its Ui/HoverTip description). A label wider than the button
	             shrinks to fit (the pixel font is wider than Minecraft's).
	  label      text with Minecraft's shadow, left aligned, centred or ending at its right edge;
	             a right aligned or centred label shrinks its text to fit (the pixel font is wider
	             than Minecraft's, and right aligned labels share their row with another).
	  slider     Minecraft's slider (AbstractSliderButton): a button whose handle is dragged,
	             clicked or stepped with the gamepad: D-pad left / right one step down / up
	             (clamped; the D-pad doesn't move the gamepad selection off a slider, see
	             `stepSelected`), A one step up, wrapping. Whole values only (callers map
	             fractional steps to indexes, Ui/SettingsScreen).
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local HoverTip = require(script.Parent.HoverTip)
local Style = require(script.Parent.Style)

local FormWidgets = {}

-- Minecraft's EditBox colours.
local FIELD_BORDER = Color3.fromRGB(160, 160, 160)
local FIELD_FOCUSED = Color3.fromRGB(255, 255, 255)
local FIELD_TEXT = Color3.fromRGB(224, 224, 224)
local FIELD_READ_ONLY = Color3.fromRGB(160, 160, 160)

export type EditBox = {
	frame: Frame,
	box: TextBox,
	setVisible: (self: EditBox, visible: boolean) -> (),
	setText: (self: EditBox, text: string) -> (),
	text: (self: EditBox) -> string,
	-- Called with the (filtered) text after the player changed it.
	changed: ((text: string) -> ())?,
	-- Called when the player leaves the box.
	left: (() -> ())?,
}

--[[
	A text field at (x, y), `w` x `h` (the border is drawn around it, as Minecraft does).
	`placeholder`, `filter` (text -> allowed text) and `readOnly` are optional.
]]
function FormWidgets.editBox(
	parent: Instance,
	x: number,
	y: number,
	w: number,
	h: number,
	z: number?,
	filter: ((string) -> string)?,
	readOnly: boolean?
): EditBox
	local zIndex = z or 4
	local frame = Style.frame(parent, x - 1, y - 1, w + 2, h + 2, FIELD_BORDER, zIndex)
	local inside = Style.frame(frame, 1, 1, w, h, Color3.new(0, 0, 0), 1)
	inside.ClipsDescendants = true
	local box = Instance.new("TextBox")
	box.Name = "Field"
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.Position = UDim2.fromOffset(4, math.floor((h - Style.TEXT_SIZE) / 2))
	box.Size = UDim2.fromOffset(w - 8, Style.TEXT_SIZE)
	box.ClearTextOnFocus = false
	box.MultiLine = false
	box.TextWrapped = false
	box.TextEditable = readOnly ~= true
	box.Font = Style.FONT
	box.TextSize = Style.TEXT_SIZE
	box.TextColor3 = if readOnly then FIELD_READ_ONLY else FIELD_TEXT
	box.PlaceholderColor3 = Color3.fromRGB(112, 112, 112)
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.TextYAlignment = Enum.TextYAlignment.Center
	box.Text = ""
	box.ZIndex = 2
	box.SelectionImageObject = Style.selectionImage
	box.Parent = inside

	local self = { frame = frame, box = box, changed = nil, left = nil }
	-- Set while this code writes the text, so the change is not taken for typing.
	local writing = false

	function self.setVisible(_: EditBox, visible: boolean)
		frame.Visible = visible
		if not visible and box:IsFocused() then
			box:ReleaseFocus()
		end
	end
	function self.setText(_: EditBox, text: string)
		if box.Text ~= text then
			writing = true
			box.Text = text
			writing = false
		end
	end
	function self.text(_: EditBox): string
		return box.Text
	end

	box:GetPropertyChangedSignal("Text"):Connect(function()
		if writing then
			return
		end
		local text = box.Text
		if filter then
			local allowed = filter(text)
			if allowed ~= text then
				writing = true
				box.Text = allowed
				writing = false
				text = allowed
			end
		end
		local callback = (self :: any).changed
		if callback then
			callback(text)
		end
	end)
	box.Focused:Connect(function()
		frame.BackgroundColor3 = FIELD_FOCUSED
		if readOnly then
			-- Everything selected, ready for Ctrl+C (positions are 1-based bytes).
			box.SelectionStart = 1
			box.CursorPosition = #box.Text + 1
		end
	end)
	box.FocusLost:Connect(function()
		frame.BackgroundColor3 = FIELD_BORDER
		local callback = (self :: any).left
		if callback then
			callback()
		end
	end)
	return (self :: any) :: EditBox
end

export type Button = {
	button: TextButton,
	setText: (self: Button, text: string) -> (),
	setEnabled: (self: Button, enabled: boolean) -> (),
	setVisible: (self: Button, visible: boolean) -> (),
	-- The label's colour while enabled (nil: Minecraft's white; the Key Binds screen's red
	-- conflicts and yellow "> key <").
	setColour: (self: Button, colour: Color3?) -> (),
	enabled: boolean,
	-- Called on a click (mouse, touch, gamepad A) while enabled.
	clicked: (() -> ())?,
}

-- Minecraft's button at (x, y), `w` x `h`, labelled `text`.
function FormWidgets.button(
	parent: Instance,
	text: string,
	x: number,
	y: number,
	w: number,
	h: number,
	z: number?
): Button
	local button = Instance.new("TextButton")
	button.Text = ""
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.BackgroundColor3 = Style.Colour.Outline
	button.Position = UDim2.fromOffset(x, y)
	button.Size = UDim2.fromOffset(w, h)
	button.ZIndex = z or 4
	local light = Style.frame(button, 1, 1, w - 2, h - 2, Style.Colour.ButtonLight, 1)
	local dark = Style.frame(button, 2, 2, w - 3, h - 3, Style.Colour.ButtonDark, 2)
	local face = Style.frame(button, 2, 2, w - 4, h - 4, Style.Colour.Button, 3)
	local label, shadow = Style.shadowText(
		button,
		text,
		0,
		math.floor((h - Style.TEXT_SIZE) / 2),
		w,
		Style.TEXT_SIZE,
		Style.Colour.Text,
		4,
		Enum.TextXAlignment.Center
	)
	button.SelectionImageObject = Style.selectionImage
	button.Parent = parent

	-- A label too wide for the button gets smaller, down to 5 pixels.
	local function fit(value: string)
		local size = Style.TEXT_SIZE
		while size > 5 and Style.textWidth(value, size) > w - 4 do
			size -= 1
		end
		if label.TextSize ~= size then
			label.TextSize = size
			shadow.TextSize = size
			local y = math.floor((h - size) / 2)
			label.Position = UDim2.fromOffset(0, y)
			shadow.Position = UDim2.fromOffset(1, y + 1)
		end
	end
	fit(text)

	local self = { button = button, enabled = true, clicked = nil }
	local hovered = false
	local textColour: Color3? = nil
	local function paint()
		local enabled = (self :: any).enabled
		face.BackgroundColor3 = if not enabled
			then Style.Colour.ButtonDisabled
			elseif hovered then Style.Colour.ButtonHover
			else Style.Colour.Button
		light.BackgroundColor3 = if enabled then Style.Colour.ButtonLight else Style.Colour.ButtonDisabled
		dark.BackgroundColor3 = if enabled then Style.Colour.ButtonDark else Style.Colour.ButtonDisabled
		local colour = if enabled then textColour or Style.Colour.Text else Style.Colour.TextDisabled
		label.TextColor3 = colour
		shadow.TextColor3 = Style.shadowOf(colour)
	end
	local function hover(on: boolean)
		hovered = on
		paint()
	end
	button.MouseEnter:Connect(function()
		hover(true)
	end)
	button.MouseLeave:Connect(function()
		hover(false)
	end)
	button.SelectionGained:Connect(function()
		hover(true)
	end)
	button.SelectionLost:Connect(function()
		hover(false)
	end)
	button.Activated:Connect(function()
		local callback = (self :: any).clicked
		-- (A long press that showed the button's tooltip, Ui/HoverTip, is no click.)
		if (self :: any).enabled and callback and not HoverTip.consumed(button) then
			callback()
		end
	end)

	function self.setText(_: Button, value: string)
		if label.Text ~= value then
			label.Text = value
			shadow.Text = value
			fit(value)
		end
	end
	function self.setEnabled(_: Button, value: boolean)
		if (self :: any).enabled ~= value then
			(self :: any).enabled = value
			paint()
		end
	end
	function self.setVisible(_: Button, visible: boolean)
		button.Visible = visible
	end
	function self.setColour(_: Button, colour: Color3?)
		if textColour ~= colour then
			textColour = colour
			paint()
		end
	end
	return (self :: any) :: Button
end

export type Label = {
	frame: Frame,
	setText: (self: Label, text: string, colour: Color3?) -> (),
	setVisible: (self: Label, visible: boolean) -> (),
}

--[[
	Text with Minecraft's shadow in a `w` wide row at (x, y): "left", "centre" or "right" aligned
	(a right aligned one ends at x + w and shrinks its text to fit the row). `plain`: no shadow,
	Minecraft's dark titles on a light panel (a shadow under dark text only smudges it).
]]
function FormWidgets.label(
	parent: Instance,
	text: string,
	x: number,
	y: number,
	w: number,
	colour: Color3,
	align: string?,
	z: number?,
	plain: boolean?
): Label
	local frame = Instance.new("Frame")
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Position = UDim2.fromOffset(x, y)
	frame.Size = UDim2.fromOffset(w, Style.TEXT_SIZE + 1)
	frame.ZIndex = z or 5
	frame.Parent = parent
	local alignment = if align == "centre"
		then Enum.TextXAlignment.Center
		elseif align == "right" then Enum.TextXAlignment.Right
		else Enum.TextXAlignment.Left
	local label, shadow = Style.shadowText(frame, text, 0, 0, w, Style.TEXT_SIZE, colour, 1, alignment)
	shadow.Visible = not plain
	local function fit(value: string)
		local size = Style.TEXT_SIZE
		if align == "right" or align == "centre" then
			while size > 5 and Style.textWidth(value, size) > w do
				size -= 1
			end
		end
		label.TextSize = size
		shadow.TextSize = size
	end
	fit(text)
	local self = { frame = frame }
	function self.setText(_: Label, value: string, newColour: Color3?)
		if label.Text ~= value then
			label.Text = value
			shadow.Text = value
			fit(value)
		end
		if newColour then
			label.TextColor3 = newColour
			shadow.TextColor3 = Style.shadowOf(newColour)
		end
	end
	function self.setVisible(_: Label, visible: boolean)
		frame.Visible = visible
	end
	return (self :: any) :: Label
end

export type Slider = {
	button: Button,
	value: number,
	setValue: (self: Slider, value: number) -> (),
	setVisible: (self: Slider, visible: boolean) -> (),
	-- One step up (+1) or down (-1), as the player (clamped).
	step: (self: Slider, delta: number) -> (),
	-- Called with the new value when the player moves it.
	changed: ((value: number) -> ())?,
}

-- Sliders by their button: the D-pad steps the gamepad-selected one.
local slidersByButton: { [GuiObject]: Slider } = setmetatable({}, { __mode = "k" }) :: any
local STEP_ACTION = "IceVoxelSliderStep"
local dpadListening = false
-- The slider button the sinking binding is for (selection events may come in either order).
local sinkingFor: GuiObject? = nil

--[[
	D-pad left / right over a selected slider steps it. The same press would also move Roblox's
	gamepad selection sideways: while a slider is selected a ContextActionService binding above
	the default priority sinks those two buttons, and should the selection move anyway it is put
	back on the slider the next frame.
]]
local function listenDpad()
	if dpadListening then
		return
	end
	dpadListening = true
	UserInputService.InputBegan:Connect(function(input: InputObject)
		local key = input.KeyCode
		if key ~= Enum.KeyCode.DPadLeft and key ~= Enum.KeyCode.DPadRight then
			return
		end
		local selected = GuiService.SelectedObject
		local slider = if selected then slidersByButton[selected] else nil
		if selected == nil or slider == nil then
			return
		end
		slider:step(if key == Enum.KeyCode.DPadRight then 1 else -1)
		task.defer(function()
			if GuiService.SelectedObject ~= selected and selected.Visible and selected.Parent ~= nil then
				GuiService.SelectedObject = selected
			end
		end)
	end)
end

-- Minecraft's slider of whole values `low`..`high`, labelled by `text(value)`.
function FormWidgets.slider(
	parent: Instance,
	x: number,
	y: number,
	w: number,
	h: number,
	low: number,
	high: number,
	text: (number) -> string,
	z: number?
): Slider
	local button = FormWidgets.button(parent, text(low), x, y, w, h, z)
	-- Minecraft's handle: 8 pixels wide, the button's full height.
	local handle = Style.frame(button.button, 0, 0, 8, h, Style.Colour.Outline, 5)
	Style.frame(handle, 1, 1, 6, h - 2, Style.Colour.ButtonLight, 1)
	Style.frame(handle, 2, 2, 5, h - 3, Style.Colour.ButtonDark, 2)
	Style.frame(handle, 2, 2, 4, h - 4, Style.Colour.Button, 3)
	local self = { button = button, value = low, changed = nil }

	local function show(value: number)
		local share = if high > low then (value - low) / (high - low) else 0
		handle.Position = UDim2.fromOffset(math.floor(share * (w - 8) + 0.5), 0)
		button:setText(text(value))
	end
	local function set(value: number, byPlayer: boolean)
		local clamped = math.clamp(math.floor(value + 0.5), low, high)
		if clamped ~= (self :: any).value then
			(self :: any).value = clamped
			show(clamped)
			local callback = (self :: any).changed
			if byPlayer and callback then
				callback(clamped)
			end
		end
	end
	show(low)

	-- The value under a screen x (the handle's centre follows the pointer).
	local function valueAt(screenX: number): number
		local b = button.button
		local scale = if b.Size.X.Offset > 0 then b.AbsoluteSize.X / b.Size.X.Offset else 1
		local share = (screenX - b.AbsolutePosition.X - 4 * scale) / math.max(1, (w - 8) * scale)
		return low + math.clamp(share, 0, 1) * (high - low)
	end
	local dragging: InputObject? = nil
	button.button.InputBegan:Connect(function(input: InputObject)
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then
			dragging = input
			set(valueAt(input.Position.X), true)
		end
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject)
		local drag = dragging
		if drag == nil then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement or input == drag then
			set(valueAt(input.Position.X), true)
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		local drag = dragging
		if drag and (input == drag or input.UserInputType == Enum.UserInputType.MouseButton1) then
			dragging = nil
		end
	end)
	-- Gamepad A steps through the values (a pointer's press already set one: its Activated is
	-- that press).
	button.clicked = function()
		local last = UserInputService:GetLastInputType()
		local pointer = last == Enum.UserInputType.MouseButton1
			or last == Enum.UserInputType.MouseMovement
			or last == Enum.UserInputType.Touch
		if not pointer then
			local current = (self :: any).value
			set(if current >= high then low else current + 1, true)
		end
	end

	function self.setValue(_: Slider, value: number)
		set(value, false)
	end
	function self.setVisible(_: Slider, visible: boolean)
		button:setVisible(visible)
	end
	function self.step(_: Slider, delta: number)
		set((self :: any).value + delta, true)
	end

	-- The D-pad steps it while it is the gamepad selection (see listenDpad).
	local slider = (self :: any) :: Slider
	slidersByButton[button.button] = slider
	listenDpad()
	local object = button.button
	object.SelectionGained:Connect(function()
		sinkingFor = object
		ContextActionService:BindActionAtPriority(STEP_ACTION, function(): Enum.ContextActionResult
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value + 1, Enum.KeyCode.DPadLeft, Enum.KeyCode.DPadRight)
	end)
	object.SelectionLost:Connect(function()
		if sinkingFor == object then
			sinkingFor = nil
			ContextActionService:UnbindAction(STEP_ACTION)
		end
	end)
	return slider
end

return FormWidgets
