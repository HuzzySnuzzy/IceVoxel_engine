--!strict
--[[
	The old-school Minecraft look for the inventory UI, built only from Frames and TextLabels (no
	image assets).

	Everything is laid out in Minecraft GUI pixels (the inventory is 176 x 166 of them) and blown
	up by a UIScale with `guiScale`, Minecraft's automatic GUI scale: the largest whole number that
	still shows 320 x 240 GUI pixels (at most MAX_SCALE), never more than what fits the content.
	Touch screens get in-between scales too, so the UI is as big as fits.

	  panel   #C6C6C6 face, 2 px white bevel top-left and #555555 bottom-right, black outline with
	          slightly rounded corners
	  slot    18 x 18 inset: #373737 top-left, white bottom-right, #8B8B8B inside (the item is the
	          16 x 16 inside it, one pixel in); crafting results and furnace outputs get the same
	          look 26 x 26
	  hover   white at 50 % over a slot's item
	  text    the pixel font (Arcade, Press Start 2P); titles #404040, white text gets a #3F3F3F
	          shadow one pixel down-right like Minecraft's
	  button  Minecraft's gray button: beveled, white label, bluish when hovered

	The builders take positions in GUI pixels relative to their parent and set ZIndex explicitly
	where siblings overlap (ScreenGuis use ZIndexBehavior.Sibling: children always draw above their
	parent).
]]

local TextService = game:GetService("TextService")

local Style = {}

Style.Colour = {
	Panel = Color3.fromRGB(198, 198, 198),
	PanelLight = Color3.fromRGB(255, 255, 255),
	PanelDark = Color3.fromRGB(85, 85, 85),
	Outline = Color3.fromRGB(0, 0, 0),
	Slot = Color3.fromRGB(139, 139, 139),
	SlotDark = Color3.fromRGB(55, 55, 55),
	SlotLight = Color3.fromRGB(255, 255, 255),
	-- Faint outlines of the armor piece in empty armor slots.
	SlotGhost = Color3.fromRGB(122, 122, 122),
	Title = Color3.fromRGB(64, 64, 64),
	Text = Color3.fromRGB(255, 255, 255),
	TextShadow = Color3.fromRGB(63, 63, 63),
	Gray = Color3.fromRGB(170, 170, 170),
	Blue = Color3.fromRGB(85, 85, 255),
	Yellow = Color3.fromRGB(255, 255, 85),
	TooltipBack = Color3.fromRGB(16, 0, 16),
	TooltipBorderTop = Color3.fromRGB(80, 0, 255),
	TooltipBorderBottom = Color3.fromRGB(40, 0, 127),
	Button = Color3.fromRGB(111, 111, 111),
	ButtonHover = Color3.fromRGB(126, 136, 191),
	ButtonLight = Color3.fromRGB(170, 170, 170),
	ButtonDark = Color3.fromRGB(70, 70, 70),
	Field = Color3.fromRGB(0, 0, 0),
	FieldBorder = Color3.fromRGB(160, 160, 160),
}

Style.FONT = Enum.Font.Arcade
-- Text height in GUI pixels (Minecraft's font is 8 px tall with the shadow).
Style.TEXT_SIZE = 8
-- Stack counts are a little smaller: the pixel font is wider than Minecraft's.
Style.COUNT_SIZE = 7
-- A slot is 18 x 18, its item 16 x 16; a result slot's large frame 26 x 26.
Style.SLOT = 18
Style.ITEM = 16
Style.BIG_SLOT = 26

-- Minecraft's automatic GUI scale keeps at least 320 x 240 GUI pixels on screen.
local BASE_WIDTH, BASE_HEIGHT = 320, 240
local MAX_SCALE = 3
-- Screen pixels kept free around scaled content.
local MARGIN = 8

--[[
	The UIScale for content of `width` x `height` GUI pixels on a `viewport`-sized screen:
	Minecraft's automatic scale (a whole number, at most MAX_SCALE), shrunk to fit the content into
	`area` (default: the whole viewport; the automatic scale always comes from the viewport, so
	content fitted into part of the screen matches the rest). Touch screens may use fractions (in
	eighths), so they get as big as fits.
]]
function Style.guiScale(viewport: Vector2, width: number, height: number, touch: boolean, area: Vector2?): number
	local space = area or viewport
	local fit = math.min((space.X - 2 * MARGIN) / width, (space.Y - 2 * MARGIN) / height)
	local scale
	if touch then
		scale = math.min(viewport.X / BASE_WIDTH, viewport.Y / BASE_HEIGHT, MAX_SCALE, fit)
		scale = math.floor(scale * 8) / 8
	else
		local auto = 1
		while auto < MAX_SCALE and viewport.X / (auto + 1) >= BASE_WIDTH and viewport.Y / (auto + 1) >= BASE_HEIGHT do
			auto += 1
		end
		scale = math.min(auto, fit)
		if scale >= 1 then
			scale = math.floor(scale)
		else
			scale = math.floor(scale * 8) / 8
		end
	end
	return math.max(scale, 0.5)
end

--[[ Builders ]]

function Style.frame(parent: Instance, x: number, y: number, w: number, h: number, colour: Color3, z: number?): Frame
	local frame = Instance.new("Frame")
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = colour
	frame.Position = UDim2.fromOffset(x, y)
	frame.Size = UDim2.fromOffset(w, h)
	frame.ZIndex = z or 1
	frame.Parent = parent
	return frame
end

local function corner(frame: GuiObject, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = frame
end

-- A hollow rectangle `thickness` thick (four frames).
function Style.border(
	parent: Instance,
	x: number,
	y: number,
	w: number,
	h: number,
	thickness: number,
	colour: Color3,
	z: number?
): { Frame }
	return {
		Style.frame(parent, x, y, w, thickness, colour, z),
		Style.frame(parent, x, y + h - thickness, w, thickness, colour, z),
		Style.frame(parent, x, y + thickness, thickness, h - 2 * thickness, colour, z),
		Style.frame(parent, x + w - thickness, y + thickness, thickness, h - 2 * thickness, colour, z),
	}
end

--[[
	A beveled panel of `w` x `h` GUI pixels at (x, y). Returns its root (the black outline); put the
	content in it, in panel coordinates (ZIndex 4 and up draws above the bevel).
]]
function Style.panel(parent: Instance, x: number, y: number, w: number, h: number, face: Color3?): Frame
	local root = Style.frame(parent, x, y, w, h, Style.Colour.Outline)
	root.Active = true
	corner(root, 2)
	local light = Style.frame(root, 1, 1, w - 3, h - 3, Style.Colour.PanelLight, 1)
	corner(light, 1)
	local dark = Style.frame(root, 3, 3, w - 4, h - 4, Style.Colour.PanelDark, 2)
	corner(dark, 1)
	Style.frame(root, 3, 3, w - 6, h - 6, face or Style.Colour.Panel, 3)
	return root
end

-- A sunken rectangle (the slot look) at (x, y), `w` x `h` with its border.
function Style.inset(parent: Instance, x: number, y: number, w: number, h: number, z: number?, face: Color3?): Frame
	local root = Style.frame(parent, x, y, w, h, Style.Colour.SlotDark, z)
	Style.frame(root, 1, 1, w - 1, h - 1, Style.Colour.SlotLight, 1)
	Style.frame(root, 1, 1, w - 2, h - 2, face or Style.Colour.Slot, 2)
	return root
end

-- Gamepad selection of slots draws nothing of its own: the screens show the hover overlay instead.
local noSelectionImage = Instance.new("Frame")
noSelectionImage.BackgroundTransparency = 1
noSelectionImage.Size = UDim2.fromScale(1, 1)

-- Gamepad selection of other buttons (tabs): a light overlay.
Style.selectionImage = Instance.new("Frame")
Style.selectionImage.BackgroundColor3 = Color3.new(1, 1, 1)
Style.selectionImage.BackgroundTransparency = 0.6
Style.selectionImage.BorderSizePixel = 0
Style.selectionImage.Size = UDim2.fromScale(1, 1)

--[[
	An inventory slot for an item at (x, y) (Minecraft's slot coordinates: the 18 x 18 frame is drawn
	one pixel up and left of them). It is a TextButton, so gamepads can select it and clicks on it
	never reach the world. A `big` slot (a crafting result, a furnace output) is drawn with
	Minecraft's 26 x 26 result frame around the item instead; the button, which is what gets hit,
	stays 18 x 18.
]]
function Style.slot(parent: Instance, x: number, y: number, z: number?, big: boolean?): TextButton
	local button = Instance.new("TextButton")
	button.Text = ""
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.BackgroundColor3 = Style.Colour.SlotDark
	button.Position = UDim2.fromOffset(x - 1, y - 1)
	button.Size = UDim2.fromOffset(Style.SLOT, Style.SLOT)
	button.ZIndex = z or 4
	button.SelectionImageObject = noSelectionImage
	if big then
		-- (Inside the transparent button, so it moves and hides with it; the item draws above it.)
		local inset = (Style.BIG_SLOT - Style.SLOT) // 2
		button.BackgroundTransparency = 1
		Style.inset(button, -inset, -inset, Style.BIG_SLOT, Style.BIG_SLOT, 1)
	else
		Style.frame(button, 1, 1, Style.SLOT - 1, Style.SLOT - 1, Style.Colour.SlotLight, 1)
		Style.frame(button, 1, 1, Style.ITEM, Style.ITEM, Style.Colour.Slot, 2)
	end
	button.Parent = parent
	return button
end

-- The white 50 % overlay of a hovered slot, over the 16 x 16 item at (x, y). Hidden at first.
function Style.hover(parent: Instance, x: number, y: number, z: number?): Frame
	local frame = Style.frame(parent, x, y, Style.ITEM, Style.ITEM, Color3.new(1, 1, 1), z or 10)
	frame.BackgroundTransparency = 0.5
	frame.Visible = false
	return frame
end

function Style.text(
	parent: Instance,
	text: string,
	x: number,
	y: number,
	w: number,
	h: number,
	colour: Color3,
	z: number?,
	align: Enum.TextXAlignment?,
	size: number?
): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Position = UDim2.fromOffset(x, y)
	label.Size = UDim2.fromOffset(w, h)
	label.Font = Style.FONT
	label.TextSize = size or Style.TEXT_SIZE
	label.TextColor3 = colour
	label.TextXAlignment = align or Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Text = text
	label.ZIndex = z or 5
	label.Parent = parent
	return label
end

-- Text with Minecraft's drop shadow (a darker copy one pixel down-right). Returns text, shadow.
function Style.shadowText(
	parent: Instance,
	text: string,
	x: number,
	y: number,
	w: number,
	h: number,
	colour: Color3,
	z: number?,
	align: Enum.TextXAlignment?,
	size: number?
): (TextLabel, TextLabel)
	local zIndex = z or 5
	local shadow = Style.text(parent, text, x + 1, y + 1, w, h, Style.shadowOf(colour), zIndex, align, size)
	local label = Style.text(parent, text, x, y, w, h, colour, zIndex + 1, align, size)
	return label, shadow
end

-- Minecraft's shadow colour of a text colour (a quarter of its brightness).
function Style.shadowOf(colour: Color3): Color3
	return Color3.new(colour.R * 0.25, colour.G * 0.25, colour.B * 0.25)
end

-- Width (GUI pixels) of `text` in the pixel font.
function Style.textWidth(text: string, size: number?): number
	local ok, bounds = pcall(function()
		return TextService:GetTextSize(text, size or Style.TEXT_SIZE, Style.FONT, Vector2.new(10000, 1000))
	end)
	if ok then
		return bounds.X
	end
	return (utf8.len(text) or #text) * (size or Style.TEXT_SIZE)
end

--[[
	Pixel art: `rows` are strings, one character per pixel ("." = nothing). Each horizontal run of
	one character becomes a Frame of `pixel` GUI pixels per art pixel; the frames are returned by
	character, so a part (e.g. the left half of a heart) can be recoloured later. The colours start
	from `palette`.
]]
function Style.pixelArt(
	parent: Instance,
	x: number,
	y: number,
	rows: { string },
	palette: { [string]: Color3 },
	z: number?,
	pixel: number?
): { [string]: { Frame } }
	local size = pixel or 1
	local groups: { [string]: { Frame } } = {}
	for row, line in rows do
		local column = 1
		while column <= #line do
			local char = string.sub(line, column, column)
			local length = 1
			while string.sub(line, column + length, column + length) == char do
				length += 1
			end
			if char ~= "." then
				local frame = Style.frame(
					parent,
					x + (column - 1) * size,
					y + (row - 1) * size,
					length * size,
					size,
					palette[char] or Color3.new(1, 0, 1),
					z
				)
				local group = groups[char]
				if group == nil then
					group = {}
					groups[char] = group
				end
				table.insert(group, frame)
			end
			column += length
		end
	end
	return groups
end

-- Recolours every frame of a pixel art group.
function Style.paint(frames: { Frame }?, colour: Color3, transparency: number?)
	if frames == nil then
		return
	end
	for _, frame in frames do
		frame.BackgroundColor3 = colour
		frame.BackgroundTransparency = transparency or 0
	end
end

--[[
	Minecraft's gray button at (x, y), `w` x `h`: beveled, a white label with a shadow, bluish while
	hovered. Returns the button (put an icon in it at ZIndex 6 and up).
]]
function Style.button(
	parent: Instance,
	text: string,
	x: number,
	y: number,
	w: number,
	h: number,
	z: number?
): TextButton
	local button = Instance.new("TextButton")
	button.Text = ""
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.BackgroundColor3 = Style.Colour.Outline
	button.Position = UDim2.fromOffset(x, y)
	button.Size = UDim2.fromOffset(w, h)
	button.ZIndex = z or 4
	Style.frame(button, 1, 1, w - 2, h - 2, Style.Colour.ButtonLight, 1)
	Style.frame(button, 2, 2, w - 3, h - 3, Style.Colour.ButtonDark, 2)
	local face = Style.frame(button, 2, 2, w - 4, h - 4, Style.Colour.Button, 3)
	if text ~= "" then
		Style.shadowText(
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
	end
	button.MouseEnter:Connect(function()
		face.BackgroundColor3 = Style.Colour.ButtonHover
	end)
	button.MouseLeave:Connect(function()
		face.BackgroundColor3 = Style.Colour.Button
	end)
	button.SelectionGained:Connect(function()
		face.BackgroundColor3 = Style.Colour.ButtonHover
	end)
	button.SelectionLost:Connect(function()
		face.BackgroundColor3 = Style.Colour.Button
	end)
	button.SelectionImageObject = noSelectionImage
	button.Parent = parent
	return button
end

-- Is `point` (screen pixels, InputObject.Position space) inside `object`'s on-screen rectangle?
function Style.contains(object: GuiObject, point: Vector2): boolean
	if not object.Visible then
		return false
	end
	local position, size = object.AbsolutePosition, object.AbsoluteSize
	return point.X >= position.X
		and point.Y >= position.Y
		and point.X < position.X + size.X
		and point.Y < position.Y + size.Y
end

-- Is the object and every ancestor up to its ScreenGui visible (and the ScreenGui enabled)?
function Style.shown(object: GuiObject): boolean
	local current: Instance? = object
	while current do
		if current:IsA("GuiObject") then
			if not current.Visible then
				return false
			end
		elseif current:IsA("ScreenGui") then
			return current.Enabled
		end
		current = current.Parent
	end
	return false
end

return Style
