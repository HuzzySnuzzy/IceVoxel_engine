--!strict
--[[
	The old-school Minecraft look for the inventory UI, built only from Frames and TextLabels (no
	image assets).

	Everything is laid out in Minecraft GUI pixels (the inventory is 176 x 166 of them) and blown
	up by a UIScale with Minecraft's GUI scale, which Ui/UiScale owns (the screen, the GUI Scale
	setting, Ui/GuiScale's rule: Auto is the largest whole scale that still shows 320 x 240 GUI
	pixels, touch screens get eighths; shrunk to fit the content). `guiScale`, `setScaleOverride`
	and `scaleChanged` forward there for older callers.

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

	`Style.Dayz` is the other look: the dark, flat survival-game style of the inventory family (the
	inventory and creative screens, JEI, the HUD's quickbar and status icons, the item tooltip, the
	carried stack). Its numbers are Ui/Theme's (`Style.Theme`), made into Color3s (`Colour`),
	transparencies (`Alpha`) and Fonts (`face`) once, here. Its rules:

	  * Everything is a Frame, TextLabel, TextButton, UIStroke, UICorner (dots only) or UIGradient;
	    no image assets. Silhouettes and glyphs are masks (Ui/Masks) shown by `maskImage`, as blocky
	    Frames (`glyph`) where an image can't be made.
	  * Outlines are UIStrokes in Border mode (`outline`: never Contextual, which would stroke the
	    letters of a text object), inside the edge, mitred, FixedSize; their thickness keeps
	    Theme.Size.OUTLINE_PX screen pixels at any scale through a `scaled` registry.
	  * Text is Roboto (`face(weight)`), sized by role (Theme.Text), its weight by role and scale
	    (Theme.weight): a `scaled` registry re-weights its labels when the scale changes. Each owner
	    of a scaled root (the inventory, the creative screen, JEI, the recipe view, the quickbar, the
	    status icons, the tooltip, the carried stack) makes one `scaled()` and calls its `setScale`
	    when its UIScale changes: nothing is done per frame.
	  * A slot face's colour is written only by `paintFace` (from Theme.face's four states), and
	    only by the face's owner (the inventory's slot widgets, the quickbar): ItemIcon makes faces
	    and never paints them afterwards.
	  * Builders write properties only when a value changes (`paintFace`, `paintNumber`, `setLit`,
	    the bars, `setText`), so owners may call them every frame.
	  * `mark` tags a root of this look (attribute IceVoxelLook = "dayz"): button tooltips under it
	    draw the dark box (`tooltipBox`).
]]

local TextService = game:GetService("TextService")

local GuiScale = require(script.Parent.GuiScale)
local Masks = require(script.Parent.Masks)
local Theme = require(script.Parent.Theme)
local TooltipLayout = require(script.Parent.TooltipLayout)
local UiScale = require(script.Parent.UiScale)

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
	-- Minecraft's red text (§c), its inactive button and the red over missing ingredients (JEI).
	Red = Color3.fromRGB(255, 85, 85),
	ButtonDisabled = Color3.fromRGB(44, 44, 44),
	TextDisabled = Color3.fromRGB(160, 160, 160),
	Missing = Color3.fromRGB(255, 0, 0),
	-- Item tooltips (Shared/Items/Tooltip): a weapon's attack numbers (Minecraft's dark green,
	-- §2) and the lore (its dark purple, §5).
	DarkGreen = Color3.fromRGB(0, 170, 0),
	Lore = Color3.fromRGB(170, 0, 170),
}

-- The lit furnace flame's colours (MenuLayout.FLAME_ART): R red edge, O orange, Y yellow, W core.
Style.FirePalette = {
	R = Color3.fromRGB(214, 78, 0),
	O = Color3.fromRGB(255, 140, 0),
	Y = Color3.fromRGB(255, 214, 40),
	W = Color3.fromRGB(255, 250, 190),
} :: { [string]: Color3 }

Style.FONT = Enum.Font.Arcade
-- Text height in GUI pixels (Minecraft's font is 8 px tall with the shadow).
Style.TEXT_SIZE = 8
-- Stack counts are a little smaller: the pixel font is wider than Minecraft's.
Style.COUNT_SIZE = 7
-- A slot is 18 x 18, its item 16 x 16; a result slot's large frame 26 x 26.
Style.SLOT = 18
Style.ITEM = 16
Style.BIG_SLOT = 26

-- Fires when the GUI scale changes (UiScale.changed).
Style.scaleChanged = UiScale.changed

-- Sets the GUI Scale setting (UiScale.setSetting: a whole choice; nil or 0 is Auto).
function Style.setScaleOverride(scale: number?)
	UiScale.setSetting(scale)
end

--[[
	The UIScale for content of `width` x `height` GUI pixels on a `viewport`-sized screen: the GUI
	Scale setting's scale there (GuiScale.base), shrunk to fit the content into `area` (default:
	the whole viewport). New code asks Ui/UiScale (`base`, `fit`), which knows the screen.
]]
function Style.guiScale(viewport: Vector2, width: number, height: number, touch: boolean, area: Vector2?): number
	local space = area or viewport
	local base = GuiScale.base(viewport.X, viewport.Y, touch, UiScale.setting())
	return GuiScale.fit(base, width, height, space.X, space.Y, touch)
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

-- Width (GUI pixels) of `text` in the pixel font (or in `font`: Style.Dayz.FONT for that look).
function Style.textWidth(text: string, size: number?, font: Enum.Font?): number
	local ok, bounds = pcall(function()
		return TextService:GetTextSize(text, size or Style.TEXT_SIZE, font or Style.FONT, Vector2.new(10000, 1000))
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

-- The settings gear (11 x 11 pixel art, "#"), for the buttons that open the Options menu.
Style.GEAR_ART = table.freeze({
	"....###....",
	".##.###.##.",
	".#########.",
	"..##...##..",
	"###.....###",
	"###.....###",
	"###.....###",
	"..##...##..",
	".#########.",
	".##.###.##.",
	"....###....",
})

-- The gear in white with Minecraft's text shadow, its top left at (x, y) of `parent`.
function Style.gear(parent: Instance, x: number, y: number, z: number)
	Style.pixelArt(parent, x + 1, y + 1, Style.GEAR_ART, { ["#"] = Style.shadowOf(Style.Colour.Text) }, z)
	Style.pixelArt(parent, x, y, Style.GEAR_ART, { ["#"] = Style.Colour.Text }, z + 1)
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

--[[
	A bare item cell at (x, y) (slot coordinates, like Style.slot): an invisible 18 x 18 TextButton
	with no frame, for item lists (JEI's). Gamepads can select it; put the icon at (1, 1) inside.
]]
function Style.itemButton(parent: Instance, x: number, y: number, z: number?): TextButton
	local button = Instance.new("TextButton")
	button.Text = ""
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.BackgroundTransparency = 1
	button.Position = UDim2.fromOffset(x - 1, y - 1)
	button.Size = UDim2.fromOffset(Style.SLOT, Style.SLOT)
	button.ZIndex = z or 4
	button.SelectionImageObject = noSelectionImage
	button.Parent = parent
	return button
end

--[[
	Minecraft's text field at (x, y), `w` x 12: black with a gray border, white text, `placeholder`
	in gray while empty. Returns the TextBox (keys typed into it never reach the game: the screens
	check for a focused TextBox).
]]
function Style.field(parent: Instance, x: number, y: number, w: number, placeholder: string, z: number?): TextBox
	local zIndex = z or 4
	Style.frame(parent, x, y, w, 12, Style.Colour.FieldBorder, zIndex)
	-- (The inside clips long text.)
	local inside = Style.frame(parent, x + 1, y + 1, w - 2, 10, Style.Colour.Field, zIndex + 1)
	inside.ClipsDescendants = true
	local box = Instance.new("TextBox")
	box.Name = "Field"
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.Position = UDim2.fromOffset(2, 1)
	box.Size = UDim2.fromOffset(w - 6, 8)
	box.ClearTextOnFocus = false
	box.Font = Style.FONT
	box.TextSize = Style.TEXT_SIZE
	box.TextColor3 = Style.Colour.Text
	box.PlaceholderText = placeholder
	box.PlaceholderColor3 = Color3.fromRGB(112, 112, 112)
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.TextYAlignment = Enum.TextYAlignment.Top
	box.Text = ""
	box.ZIndex = 1
	box.SelectionImageObject = Style.selectionImage
	box.Parent = inside
	return box
end

--[[
	Style.button that can be turned off: inactive, it is drawn like Minecraft's inactive button
	(dark face, gray label) and does not light up when hovered. Returns the button and a function
	that turns it on or off (the caller still decides what a click on an inactive button does).
]]
function Style.toggleButton(
	parent: Instance,
	text: string,
	x: number,
	y: number,
	w: number,
	h: number,
	z: number?
): (TextButton, (enabled: boolean) -> ())
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
	local enabled, hovered = true, false
	local function paint()
		face.BackgroundColor3 = if not enabled
			then Style.Colour.ButtonDisabled
			elseif hovered then Style.Colour.ButtonHover
			else Style.Colour.Button
		light.BackgroundColor3 = if enabled then Style.Colour.ButtonLight else Style.Colour.ButtonDisabled
		dark.BackgroundColor3 = if enabled then Style.Colour.ButtonDark else Style.Colour.ButtonDisabled
		local colour = if enabled then Style.Colour.Text else Style.Colour.TextDisabled
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
	button.SelectionImageObject = noSelectionImage
	button.Parent = parent
	return button, function(value: boolean)
		if value ~= enabled then
			enabled = value
			paint()
		end
	end
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

--[[ The survival look (Style.Dayz): see the header and Ui/Theme ]]

Style.Theme = Theme

-- A rectangle in GUI pixels (MenuLayout.Rect, InventoryColumns' rects).
export type Rect = { x: number, y: number, w: number, h: number }

--[[
	Scale-dependent styling of one scaled root: outline thicknesses, text weights and anything else
	that changes with the GUI scale. Strokes, labels and `add`ed objects (item icons: their
	`setScale` resizes the count box) are held weakly, so a rebuilt section's go with it; `onScale`
	functions are kept for the registry's life, so register only long-lived things there. Each is
	brought to the current scale when registered; `setScale` does nothing when the scale is
	unchanged.
]]
export type Scaled = {
	-- The scale last set (1 until the owner's first setScale).
	scale: number,
	stroke: (self: Scaled, stroke: UIStroke) -> (),
	label: (self: Scaled, label: GuiObject, role: Theme.Role) -> (),
	onScale: (self: Scaled, fn: (scale: number) -> ()) -> (),
	add: (self: Scaled, object: Scalable) -> (),
	setScale: (self: Scaled, scale: number) -> (),
}
-- Anything with a `setScale` (ItemIcon), for Scaled.add.
export type Scalable = { setScale: (self: any, scale: number) -> () }

-- A column's grey top header ("VICINITY", "EQUIPMENT", "HANDS").
export type TopHeader = {
	root: Frame,
	label: TextLabel,
	-- Upper-cased; nothing written when unchanged.
	setText: (self: TopHeader, text: string) -> (),
	place: (self: TopHeader, x: number, y: number, w: number, h: number) -> (),
	-- A square button `size` wide whose right edge is `fromRight` from the bar's right end.
	button: (self: TopHeader, glyph: "gear" | "close" | "items", fromRight: number, size: number) -> TextButton,
}

export type SectionOptions = {
	-- The body's fill: SectionBody, StripBody, GroundBody, HandsBody, Panel, or none (default grid).
	face: ("grid" | "strip" | "ground" | "hands" | "panel" | "none")?,
	collapsible: boolean?,
	collapsed: boolean?,
	-- A Silhouettes name for the header's picture (backpack, crafting, vanity).
	glyph: string?,
	z: number?,
	scaled: Scaled?,
}

-- A section: a black header bar (title in capitals, a picture at its left, minus / plus at its
-- right when collapsible) over its body.
export type Section = {
	-- Active (sinks clicks); the header and the body.
	root: Frame,
	-- The bar: Selectable when collapsible (its owner connects Activated and calls setCollapsed).
	header: TextButton,
	title: TextLabel,
	-- 12 x 12 at the bar's left: a glyph, or the owner's ItemIcon.
	picture: Frame,
	-- Content goes here in body coordinates, at ZIndex 2 and up (grid lines are at 1).
	body: Frame,
	collapsed: boolean,
	setTitle: (self: Section, text: string) -> (),
	-- Swaps the minus / plus and hides the body.
	setCollapsed: (self: Section, collapsed: boolean) -> (),
	place: (self: Section, x: number, y: number, w: number, header: number, body: number) -> (),
	destroy: (self: Section) -> (),
}

-- A quickbar cell: its base, the face over it (paintFace), the number box and its digit.
export type QuickCell = { base: Frame, face: Frame, box: Frame, digit: TextLabel }
-- A bar (condition, quantity, energy, progress): `set` its fill (0..1) and, optionally, colour.
export type Bar = { track: Frame, fill: Frame, set: (self: Bar, fraction: number, colour: Color3?) -> () }
-- A scrollbar: `place` its thumb at `fraction` (0 top .. 1 bottom), dim when not `active`.
export type Scrollbar = { track: Frame, thumb: Frame, place: (self: Scrollbar, fraction: number, active: boolean) -> () }

local Dayz = {}
Style.Dayz = Dayz

-- (Unknown keys are mistakes: say so instead of drawing nil.)
local function strict<V>(kind: string, values: { [string]: V }): { [string]: V }
	return setmetatable(values, {
		__index = function(_, key)
			error(`Style.Dayz.{kind} has no {tostring(key)}`, 2)
		end,
	}) :: any
end

local function colourOf(c: Theme.Rgba): Color3
	return Color3.fromRGB(c.r, c.g, c.b)
end

local colours: { [string]: Color3 } = {}
local alphas: { [string]: number } = {}
for key, c in (Theme.Colour :: any) :: { [string]: Theme.Rgba } do
	colours[key] = colourOf(c)
	alphas[key] = c.t
end
-- Theme.Colour as Color3s, and their transparencies.
Dayz.Colour = strict("Colour", colours)
Dayz.Alpha = strict("Alpha", alphas)

-- Temperature zones -2..2.
Dayz.Zone = {} :: { [number]: Color3 }
for zone, c in Theme.Zone do
	Dayz.Zone[zone] = colourOf(c)
end

-- Drag feedback outline colours (at Theme.FEEDBACK_T).
local feedbackColours: { [string]: Color3 } = {}
for name, c in (Theme.FeedbackColour :: any) :: { [string]: Theme.Rgba } do
	feedbackColours[name] = colourOf(c)
end
Dayz.Feedback = strict("Feedback", feedbackColours)

-- Condition levels' colours by name ("Pristine" .. "Ruined").
local conditionColours: { [string]: Color3 } = {}
for _, level in Theme.CONDITIONS do
	conditionColours[level.name] = Color3.fromRGB(level.rgb[1], level.rgb[2], level.rgb[3])
end
Dayz.Condition = strict("Condition", conditionColours)

-- Text sizes by role (Theme.Text).
Dayz.Text = Theme.Text

local function enumFont(name: string): Enum.Font
	local ok, font = pcall(function()
		return (Enum.Font :: any)[name]
	end)
	return if ok and font then font else Enum.Font.Roboto
end

-- The look's font as an Enum.Font, for measuring (Style.textWidth(text, size, Style.Dayz.FONT)).
Dayz.FONT = enumFont(Theme.Font.family)
local FAMILY = Font.fromEnum(Dayz.FONT).Family

local WEIGHTS: { [string]: Enum.FontWeight } = {
	Light = Enum.FontWeight.Light,
	Regular = Enum.FontWeight.Regular,
	Bold = Enum.FontWeight.Bold,
}
local faces: { [string]: Font } = {}

-- The look's Font in `weight` (made once per weight).
function Dayz.face(weight: Theme.Weight): Font
	local font: Font? = faces[weight]
	if font then
		return font
	end
	local made = Font.new(FAMILY, WEIGHTS[weight] or Enum.FontWeight.Regular)
	faces[weight] = made
	return made
end

--[[ Scale-dependent styling ]]

type ScaledSelf = Scaled & {
	strokes: { [UIStroke]: boolean },
	labels: { [GuiObject]: Theme.Role },
	objects: { [Scalable]: boolean },
	functions: { (scale: number) -> () },
}

local ScaledClass = {}
ScaledClass.__index = ScaledClass

local function applyStroke(stroke: UIStroke, scale: number)
	local thickness = Theme.strokeThickness(scale, Theme.STROKE_FOLLOWS_UISCALE)
	if stroke.Thickness ~= thickness then
		stroke.Thickness = thickness
	end
end

local function applyWeight(label: GuiObject, role: Theme.Role, scale: number)
	local face = Dayz.face(Theme.weight(role, scale))
	local object = label :: any
	if object.FontFace ~= face then
		object.FontFace = face
	end
end

function ScaledClass.stroke(self: ScaledSelf, stroke: UIStroke)
	self.strokes[stroke] = true
	applyStroke(stroke, self.scale)
end

function ScaledClass.label(self: ScaledSelf, label: GuiObject, role: Theme.Role)
	self.labels[label] = role
	applyWeight(label, role, self.scale)
end

function ScaledClass.onScale(self: ScaledSelf, fn: (scale: number) -> ())
	table.insert(self.functions, fn)
	fn(self.scale)
end

function ScaledClass.add(self: ScaledSelf, object: Scalable)
	self.objects[object] = true
	object:setScale(self.scale)
end

function ScaledClass.setScale(self: ScaledSelf, scale: number)
	if scale == self.scale or scale ~= scale or scale <= 0 then
		return
	end
	self.scale = scale
	for stroke in self.strokes do
		applyStroke(stroke, scale)
	end
	for label, role in self.labels do
		-- (Iteration widens the role to a string.)
		applyWeight(label, (role :: any) :: Theme.Role, scale)
	end
	for object in self.objects do
		object:setScale(scale)
	end
	for _, fn in self.functions do
		fn(scale)
	end
end

-- A new registry (scale 1 until its owner's first setScale).
function Dayz.scaled(): Scaled
	local self = {
		scale = 1,
		strokes = setmetatable({}, { __mode = "k" }),
		labels = setmetatable({}, { __mode = "k" }),
		objects = setmetatable({}, { __mode = "k" }),
		functions = {},
	}
	return (setmetatable(self, ScaledClass) :: any) :: Scaled
end

--[[ Small pieces ]]

-- Tags a root of this look (button tooltips under it draw the dark box).
function Dayz.mark(root: GuiObject)
	root:SetAttribute("IceVoxelLook", "dayz")
end

-- A borderless Frame filled with the colour `key` at its transparency.
local function filled(parent: Instance, x: number, y: number, w: number, h: number, key: string, z: number?): Frame
	local frame = Style.frame(parent, x, y, w, h, Dayz.Colour[key], z)
	frame.BackgroundTransparency = Dayz.Alpha[key]
	return frame
end

-- The UIStroke of every object `outline` was given (weak).
local outlines: { [GuiObject]: UIStroke } = setmetatable({}, { __mode = "k" }) :: any

-- (UIStroke's newer properties, probed once: a client without them still gets its outlines.)
local function strokeValue(property: string, item: string): any?
	local ok, found = pcall(function()
		local value = (Enum :: any)[property][item]
		local probe = Instance.new("UIStroke") :: any
		probe[property] = value
		probe:Destroy()
		return value
	end)
	return if ok then found else nil
end
local STROKE_POSITION = strokeValue("BorderStrokePosition", "Inner")
local STROKE_SIZING = strokeValue("StrokeSizingMode", "FixedSize")

--[[
	An outline round `object`'s edge, inside it: `colour` (default Outline, white) at
	`transparency` (default 0), OUTLINE_PX screen pixels thick at the `scaled` registry's scale
	(OUTLINE_PX GUI pixels without one). Always Border mode, mitred, FixedSize.
]]
function Dayz.outline(object: GuiObject, colour: Color3?, transparency: number?, scaled: Scaled?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	if STROKE_POSITION then
		(stroke :: any).BorderStrokePosition = STROKE_POSITION
	end
	stroke.LineJoinMode = Enum.LineJoinMode.Miter
	if STROKE_SIZING then
		(stroke :: any).StrokeSizingMode = STROKE_SIZING
	end
	stroke.Color = colour or Dayz.Colour.Outline
	stroke.Transparency = transparency or Dayz.Alpha.Outline
	stroke.Thickness = Theme.Size.OUTLINE_PX
	stroke.Parent = object
	outlines[object] = stroke
	if scaled then
		scaled:stroke(stroke)
	end
	return stroke
end

-- The feedback each lit outline last showed ("" for the plain outline; weak).
local litWith: { [GuiObject]: string } = setmetatable({}, { __mode = "k" }) :: any

--[[
	Shows or hides a hover outline (a Frame given an `outline`), in a drag `feedback` colour at
	Theme.FEEDBACK_T, or white without one. Writes only what changed.
]]
function Dayz.setLit(hover: Frame, lit: boolean, feedback: Theme.Feedback?)
	if hover.Visible ~= lit then
		hover.Visible = lit
	end
	local stroke = outlines[hover]
	local key = feedback or ""
	if stroke and litWith[hover] ~= key then
		litWith[hover] = key
		if feedback then
			stroke.Color = Dayz.Feedback[feedback]
			stroke.Transparency = Theme.FEEDBACK_T
		else
			stroke.Color = Dayz.Colour.Outline
			stroke.Transparency = Dayz.Alpha.Outline
		end
	end
end

--[[
	A text label at (x, y), `w` x `h`: Roboto in `role`'s size and weight (re-weighted by `scaled`
	as the scale changes), `colour` (default Text), centred vertically, `align` (default left).
]]
function Dayz.label(
	parent: Instance,
	text: string,
	x: number,
	y: number,
	w: number,
	h: number,
	role: Theme.Role,
	colour: Color3?,
	z: number?,
	align: Enum.TextXAlignment?,
	scaled: Scaled?
): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Position = UDim2.fromOffset(x, y)
	label.Size = UDim2.fromOffset(w, h)
	label.FontFace = Dayz.face(Theme.weight(role, if scaled then scaled.scale else 1))
	label.TextSize = Theme.Text[role]
	label.TextColor3 = colour or Dayz.Colour.Text
	label.TextXAlignment = align or Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Text = text
	label.ZIndex = z or 5
	label.Parent = parent
	if scaled then
		scaled:label(label, role)
	end
	return label
end

--[[
	Blocky art: `art` rows, one GUI pixel per character, every character but "." drawn in `colour`
	(one Frame per run). Masks' fallback, and the small glyphs.
]]
function Dayz.glyph(
	parent: Instance,
	x: number,
	y: number,
	art: { string },
	colour: Color3,
	z: number?,
	transparency: number?
): { Frame }
	local frames: { Frame } = {}
	for row, line in art do
		local column = 1
		while column <= #line do
			if string.sub(line, column, column) == "." then
				column += 1
			else
				local length = 1
				while column + length <= #line and string.sub(line, column + length, column + length) ~= "." do
					length += 1
				end
				local frame = Style.frame(parent, x + column - 1, y + row - 1, length, 1, colour, z)
				frame.BackgroundTransparency = transparency or 0
				table.insert(frames, frame)
				column += length
			end
		end
	end
	return frames
end

--[[
	Recolours what `maskImage` or `glyph` drew into `object`: an image's ImageColor3 /
	ImageTransparency, or every Frame under a blocky holder. Call it on change, not per frame.
]]
function Dayz.tint(object: GuiObject, colour: Color3, transparency: number?)
	if object:IsA("ImageLabel") or object:IsA("ImageButton") then
		local image = object :: any
		image.ImageColor3 = colour
		image.ImageTransparency = transparency or 0
		return
	end
	for _, child in object:GetDescendants() do
		if child:IsA("Frame") then
			child.BackgroundColor3 = colour
			child.BackgroundTransparency = transparency or 0
		end
	end
end

-- Masks drawn so far, by name, and their blocky rows by name and size.
local maskCache: { [string]: Masks.Mask } = {}
local maskRows: { [string]: { string } } = {}

--[[
	A silhouette, glyph or badge at (x, y), `w` x `h`, from the mask `name` (drawn once by `mask`
	and kept): white tinted `colour` at `transparency`. (This version draws the blocky fallback:
	the mask at the target size as `glyph` Frames.) Recolour it with `tint`.
]]
function Dayz.maskImage(
	parent: Instance,
	name: string,
	mask: () -> Masks.Mask,
	x: number,
	y: number,
	w: number,
	h: number,
	colour: Color3,
	transparency: number,
	z: number?
): GuiObject
	local holder = Instance.new("Frame")
	holder.Name = name
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.Position = UDim2.fromOffset(x, y)
	holder.Size = UDim2.fromOffset(w, h)
	holder.ZIndex = z or 1
	local cw, ch = math.max(1, math.floor(w + 0.5)), math.max(1, math.floor(h + 0.5))
	local key = `{name}:{cw}x{ch}`
	local rows = maskRows[key]
	if rows == nil then
		local drawn = maskCache[name]
		if drawn == nil then
			drawn = mask()
			maskCache[name] = drawn
		end
		rows = Masks.rows(Masks.downsample(drawn :: Masks.Mask, cw, ch))
		maskRows[key] = rows
	end
	Dayz.glyph(holder, 0, 0, rows :: { string }, colour, 1, transparency)
	holder.Parent = parent
	return holder
end

-- 8 x 8 glyphs of this version's header buttons, section pictures and toggles.
local GLYPHS: { [string]: { string } } = {
	gear = { "...##...", ".######.", ".##..##.", "##....##", "##....##", ".##..##.", ".######.", "...##..." },
	close = { "#......#", ".#....#.", "..#..#..", "...##...", "...##...", "..#..#..", ".#....#.", "#......#" },
	items = { "###.###.", "###.###.", "###.###.", "........", "###.###.", "###.###.", "###.###.", "........" },
	minus = { "........", "........", "........", "########", "########", "........", "........", "........" },
	plus = { "...##...", "...##...", "...##...", "########", "########", "...##...", "...##...", "...##..." },
	backpack = { "..####..", ".#....#.", "########", "#......#", "#.####.#", "#......#", "#......#", "########" },
	crafting = { "########", "#..#..##", "#..#..##", "########", "#..#..##", "#..#..##", "########", "........" },
	vanity = { ".##..##.", "########", "########", ".######.", "..####..", "..####..", "..####..", "..####.." },
}

-- An 8 x 8 glyph in a transparent holder at (x, y) of `parent` (nothing for unknown names).
local function smallGlyph(parent: Instance, name: string, x: number, y: number, colour: Color3, z: number): Frame
	local holder = Instance.new("Frame")
	holder.Name = name
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.Position = UDim2.fromOffset(x, y)
	holder.Size = UDim2.fromOffset(8, 8)
	holder.ZIndex = z
	local art = GLYPHS[name]
	if art then
		Dayz.glyph(holder, 0, 0, art, colour, 1)
	end
	holder.Parent = parent
	return holder
end

--[[ Headers and sections ]]

type TopHeaderSelf = TopHeader & { text: string, scaled: Scaled? }

local TopHeaderClass = {}
TopHeaderClass.__index = TopHeaderClass

function TopHeaderClass.setText(self: TopHeaderSelf, text: string)
	local caps = Theme.caps(text)
	if caps ~= self.text then
		self.text = caps
		self.label.Text = caps
	end
end

function TopHeaderClass.place(self: TopHeaderSelf, x: number, y: number, w: number, h: number)
	local position, size = UDim2.fromOffset(x, y), UDim2.fromOffset(w, h)
	if self.root.Position ~= position then
		self.root.Position = position
	end
	if self.root.Size ~= size then
		self.root.Size = size
	end
end

function TopHeaderClass.button(
	self: TopHeaderSelf,
	glyph: "gear" | "close" | "items",
	fromRight: number,
	size: number
): TextButton
	local button = Instance.new("TextButton")
	button.Name = glyph
	button.Text = ""
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.BackgroundColor3 = Dayz.Colour.ButtonHover
	button.BackgroundTransparency = 1
	button.AnchorPoint = Vector2.new(1, 0.5)
	button.Position = UDim2.new(1, -fromRight, 0.5, 0)
	button.Size = UDim2.fromOffset(size, size)
	button.ZIndex = 4
	button.SelectionImageObject = Style.selectionImage
	local holder = smallGlyph(button, glyph, 0, 0, Dayz.Colour.TopHeaderText, 1)
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	local function hover(on: boolean)
		button.BackgroundTransparency = if on then Dayz.Alpha.ButtonHover else 1
	end
	button.MouseEnter:Connect(function()
		hover(true)
	end)
	button.MouseLeave:Connect(function()
		hover(false)
	end)
	button.Parent = self.root
	return button
end

--[[
	A column's top header bar (grey, its text bold black in capitals, centred). Place it with
	`place`; `button` adds the gear, close or items buttons at its right.
]]
function Dayz.topHeader(parent: Instance, text: string, z: number?, scaled: Scaled?): TopHeader
	local root = filled(parent, 0, 0, 0, Theme.Size.TOP_HEADER, "TopHeader", z or 2)
	root.Name = "TopHeader"
	root.Active = true
	local caps = Theme.caps(text)
	local label =
		Dayz.label(root, caps, 0, 0, 0, 0, "top", Dayz.Colour.TopHeaderText, 2, Enum.TextXAlignment.Center, scaled)
	label.Size = UDim2.fromScale(1, 1)
	local self = { root = root, label = label, text = caps, scaled = scaled }
	return (setmetatable(self, TopHeaderClass) :: any) :: TopHeader
end

local SECTION_FACES: { [string]: string } = {
	grid = "SectionBody",
	strip = "StripBody",
	ground = "GroundBody",
	hands = "HandsBody",
	panel = "Panel",
}

type SectionSelf = Section & {
	text: string,
	headerHeight: number,
	bodyHeight: number,
	minus: Frame?,
	plus: Frame?,
}

local SectionClass = {}
SectionClass.__index = SectionClass

function SectionClass.setTitle(self: SectionSelf, text: string)
	local caps = Theme.caps(text)
	if caps ~= self.text then
		self.text = caps
		self.title.Text = caps
	end
end

local function showBody(self: SectionSelf)
	local shown = self.bodyHeight > 0 and not self.collapsed
	if self.body.Visible ~= shown then
		self.body.Visible = shown
	end
end

function SectionClass.setCollapsed(self: SectionSelf, collapsed: boolean)
	if collapsed == self.collapsed then
		return
	end
	self.collapsed = collapsed
	local minus, plus = self.minus, self.plus
	if minus and plus then
		minus.Visible = not collapsed
		plus.Visible = collapsed
	end
	showBody(self)
end

function SectionClass.place(self: SectionSelf, x: number, y: number, w: number, header: number, body: number)
	self.headerHeight, self.bodyHeight = header, body
	local root = self.root
	local position = UDim2.fromOffset(x, y)
	if root.Position ~= position then
		root.Position = position
	end
	local size = UDim2.fromOffset(w, header + body)
	if root.Size ~= size then
		root.Size = size
	end
	local headerSize = UDim2.fromOffset(w, header)
	if self.header.Size ~= headerSize then
		self.header.Size = headerSize
	end
	if self.header.Visible ~= (header > 0) then
		self.header.Visible = header > 0
	end
	local bodyPosition, bodySize = UDim2.fromOffset(0, header), UDim2.fromOffset(w, body)
	if self.body.Position ~= bodyPosition then
		self.body.Position = bodyPosition
	end
	if self.body.Size ~= bodySize then
		self.body.Size = bodySize
	end
	showBody(self)
end

function SectionClass.destroy(self: SectionSelf)
	self.root:Destroy()
end

--[[
	A section: the black header bar (title in capitals, centred; a picture holder at its left; a
	minus / plus at its right when collapsible) over the body, filled per `options.face`. Place it
	with `place`; collapsing is the owner's (it lays the column out again).
]]
function Dayz.section(parent: Instance, title: string, options: SectionOptions?): Section
	local opts: SectionOptions = options or {}
	local scaled = opts.scaled
	local root = Instance.new("Frame")
	root.Name = "Section"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Active = true
	root.ZIndex = opts.z or 2
	local header = Instance.new("TextButton")
	header.Name = "Header"
	header.Text = ""
	header.AutoButtonColor = false
	header.BorderSizePixel = 0
	header.BackgroundColor3 = Dayz.Colour.SectionHeader
	header.BackgroundTransparency = Dayz.Alpha.SectionHeader
	header.Size = UDim2.fromOffset(0, Theme.Size.SECTION_HEADER)
	header.ZIndex = 3
	header.Selectable = opts.collapsible == true
	header.SelectionImageObject = Style.selectionImage
	header.Parent = root
	local caps = Theme.caps(title)
	local label = Dayz.label(
		header,
		caps,
		0,
		0,
		0,
		0,
		"section",
		Dayz.Colour.SectionHeaderText,
		2,
		Enum.TextXAlignment.Center,
		scaled
	)
	label.Size = UDim2.fromScale(1, 1)
	local pictureSize = Theme.Size.HEADER_PICTURE
	local picture = Instance.new("Frame")
	picture.Name = "Picture"
	picture.BackgroundTransparency = 1
	picture.BorderSizePixel = 0
	picture.Position = UDim2.fromOffset(1, 1)
	picture.Size = UDim2.fromOffset(pictureSize, pictureSize)
	picture.ZIndex = 3
	picture.Parent = header
	local glyph = opts.glyph
	if glyph then
		local inset = (pictureSize - 8) // 2
		smallGlyph(picture, glyph, inset, inset, Dayz.Colour.SectionHeaderText, 1)
	end
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BorderSizePixel = 0
	local faceKey = SECTION_FACES[opts.face or "grid"]
	if faceKey then
		body.BackgroundColor3 = Dayz.Colour[faceKey]
		body.BackgroundTransparency = Dayz.Alpha[faceKey]
	else
		body.BackgroundTransparency = 1
	end
	body.Position = UDim2.fromOffset(0, Theme.Size.SECTION_HEADER)
	body.ZIndex = 2
	body.Parent = root
	local self = {
		root = root,
		header = header,
		title = label,
		picture = picture,
		body = body,
		collapsed = false,
		text = caps,
		headerHeight = Theme.Size.SECTION_HEADER,
		bodyHeight = 0,
		minus = nil :: Frame?,
		plus = nil :: Frame?,
	}
	if opts.collapsible then
		local toggle = Theme.Size.HEADER_TOGGLE
		local holder = Instance.new("Frame")
		holder.Name = "Toggle"
		holder.BackgroundTransparency = 1
		holder.BorderSizePixel = 0
		holder.AnchorPoint = Vector2.new(1, 0.5)
		holder.Position = UDim2.new(1, -Theme.Size.HEADER_TOGGLE_INSET, 0.5, 0)
		holder.Size = UDim2.fromOffset(toggle, toggle)
		holder.ZIndex = 3
		holder.Parent = header
		local minus = smallGlyph(holder, "minus", 0, 0, Dayz.Colour.SectionHeaderText, 1)
		local plus = smallGlyph(holder, "plus", 0, 0, Dayz.Colour.SectionHeaderText, 1)
		plus.Visible = false
		self.minus = minus
		self.plus = plus
	end
	root.Parent = parent
	local section = (setmetatable(self, SectionClass) :: any) :: Section
	if opts.collapsed then
		section:setCollapsed(true)
	end
	return section
end

--[[ Slots and the quickbar ]]

-- The state each face was last painted (weak).
local faceStates: { [Frame]: Theme.FaceState } = setmetatable({}, { __mode = "k" }) :: any

-- Paints a slot face in one of Theme.face's states; the only writer of a face's colour.
function Dayz.paintFace(face: Frame, state: Theme.FaceState)
	if faceStates[face] == state then
		return
	end
	faceStates[face] = state
	local key, transparency = Theme.face(state)
	face.BackgroundColor3 = Dayz.Colour[key]
	face.BackgroundTransparency = transparency
end

-- A slot face at (x, y), `w` x `h` (17 x 17 for a slot, 24 x 24 for a big one), painted empty.
function Dayz.slotFace(parent: Instance, x: number, y: number, w: number, h: number, z: number?): Frame
	local face = Style.frame(parent, x, y, w, h, Dayz.Colour.Cell, z)
	face.Name = "Face"
	Dayz.paintFace(face, "empty")
	return face
end

-- What each number box last showed, and its outline (weak).
local numberShown: { [Frame]: string } = setmetatable({}, { __mode = "k" }) :: any

--[[
	A quickbar cell, 18 x 18 at (x, y): the cell's base, the face over it (painted by its owner),
	and the number box (hidden until `paintNumber`).
]]
function Dayz.quickCell(parent: Instance, x: number, y: number, z: number?, scaled: Scaled?): QuickCell
	local size = Theme.Size.PITCH
	local base = filled(parent, x, y, size, size, "QuickCell", z or 2)
	base.Name = "QuickCell"
	local face = Dayz.slotFace(base, 0, 0, size, size, 1)
	local bx, by, bw, bh = Theme.quickNumber(false)
	local box = filled(base, bx, by, bw, bh, "QuickNumberBoxEmpty", 3)
	box.Name = "Number"
	box.Visible = false
	Dayz.outline(box, Dayz.Colour.QuickNumberLineEmpty, Dayz.Alpha.QuickNumberLineEmpty, scaled)
	local digit =
		Dayz.label(box, "", 0, 0, 0, 0, "tiny", Dayz.Colour.QuickNumberTextEmpty, 2, Enum.TextXAlignment.Center)
	digit.Size = UDim2.fromScale(1, 1)
	digit.TextTransparency = Dayz.Alpha.QuickNumberTextEmpty
	return { base = base, face = face, box = box, digit = digit }
end

--[[
	Shows a quickbar cell's number `text` ("" hides the box): boxed in its corner over an item
	(`occupied`), faint in the middle of an empty cell (Theme.quickNumber). Writes only on change.
]]
function Dayz.paintNumber(cell: QuickCell, text: string, occupied: boolean)
	local key = if text == "" then "" elseif occupied then "1" .. text else "0" .. text
	local box = cell.box
	if numberShown[box] == key then
		return
	end
	numberShown[box] = key
	if text == "" then
		box.Visible = false
		return
	end
	local x, y, w, h = Theme.quickNumber(occupied)
	box.Position = UDim2.fromOffset(x, y)
	box.Size = UDim2.fromOffset(w, h)
	local suffix = if occupied then "" else "Empty"
	box.BackgroundColor3 = Dayz.Colour["QuickNumberBox" .. suffix]
	box.BackgroundTransparency = Dayz.Alpha["QuickNumberBox" .. suffix]
	local stroke = outlines[box]
	if stroke then
		stroke.Color = Dayz.Colour["QuickNumberLine" .. suffix]
		stroke.Transparency = Dayz.Alpha["QuickNumberLine" .. suffix]
	end
	cell.digit.TextColor3 = Dayz.Colour["QuickNumberText" .. suffix]
	cell.digit.TextTransparency = Dayz.Alpha["QuickNumberText" .. suffix]
	cell.digit.Text = text
	box.Visible = true
end

-- Grid lines: a GridLine Frame per rect (InventoryColumns.gridLines), at ZIndex `z` (default 1).
function Dayz.lines(parent: Instance, rects: { Rect }, z: number?): { Frame }
	local frames: { Frame } = {}
	for _, rect in rects do
		local frame = filled(parent, rect.x, rect.y, rect.w, rect.h, "GridLine", z or 1)
		frame.Name = "Line"
		table.insert(frames, frame)
	end
	return frames
end

--[[
	A stack count's box for the bottom right of a 16 x 16 icon (hidden; its owner sizes it by
	Theme.count and Theme.countWidth and sets the text).
]]
function Dayz.countBox(parent: Instance, z: number?): (Frame, TextLabel)
	local height, size, digit = Theme.count(1)
	local box = filled(parent, 0, 0, Theme.countWidth("", digit), height, "CountBox", z or 3)
	box.Name = "Count"
	box.AnchorPoint = Vector2.new(1, 1)
	box.Position = UDim2.fromScale(1, 1)
	box.Visible = false
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Size = UDim2.fromScale(1, 1)
	label.FontFace = Dayz.face("Regular")
	label.TextSize = size
	label.TextColor3 = Dayz.Colour.Text
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Text = ""
	label.ZIndex = 1
	label.Parent = box
	return box, label
end

-- A divider bar (the status icons' groups).
function Dayz.divider(parent: Instance, x: number, y: number, w: number, h: number, z: number?): Frame
	local frame = filled(parent, x, y, w, h, "Divider", z)
	frame.Name = "Divider"
	return frame
end

-- A round dot `size` across (a condition's: colour it with the level's colour at Theme.DOT_T).
function Dayz.dot(parent: Instance, x: number, y: number, size: number, z: number?): Frame
	local frame = Style.frame(parent, x, y, size, size, Dayz.Colour.Text, z)
	frame.Name = "Dot"
	frame.BackgroundTransparency = Theme.DOT_T
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0.5, 0)
	round.Parent = frame
	return frame
end

type BarSelf = Bar & { vertical: boolean, fraction: number, colour: Color3? }

local BarClass = {}
BarClass.__index = BarClass

function BarClass.set(self: BarSelf, fraction: number, colour: Color3?)
	local f = if fraction == fraction then math.clamp(fraction, 0, 1) else 0
	if f ~= self.fraction then
		self.fraction = f
		self.fill.Size = if self.vertical then UDim2.fromScale(1, f) else UDim2.fromScale(f, 1)
	end
	if colour and colour ~= self.colour then
		self.colour = colour
		self.fill.BackgroundColor3 = colour
	end
end

--[[
	A bar at (x, y), `w` x `h`: a BarTrack track and a Quantity (white) fill from the left, or from
	the bottom when `vertical`. `set` writes only on change.
]]
function Dayz.bar(parent: Instance, x: number, y: number, w: number, h: number, vertical: boolean, z: number?): Bar
	local track = filled(parent, x, y, w, h, "BarTrack", z)
	track.Name = "Bar"
	local fill = filled(track, 0, 0, 0, 0, "Quantity", 1)
	fill.Name = "Fill"
	if vertical then
		fill.AnchorPoint = Vector2.new(0, 1)
		fill.Position = UDim2.fromScale(0, 1)
		fill.Size = UDim2.fromScale(1, 0)
	else
		fill.Size = UDim2.fromScale(0, 1)
	end
	local self = { track = track, fill = fill, vertical = vertical, fraction = 0, colour = nil }
	return (setmetatable(self, BarClass) :: any) :: Bar
end

--[[ Controls ]]

--[[
	A flat button at (x, y), `w` x `h`: a dark face, a hairline, its text (TextSoft) centred; a light
	overlay while hovered or selected, and the Focus outline while a gamepad selects it.
]]
function Dayz.button(
	parent: Instance,
	text: string,
	x: number,
	y: number,
	w: number,
	h: number,
	z: number?,
	scaled: Scaled?
): TextButton
	local button = Instance.new("TextButton")
	button.Name = "Button"
	button.Text = ""
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.BackgroundColor3 = Dayz.Colour.Button
	button.BackgroundTransparency = Dayz.Alpha.Button
	button.Position = UDim2.fromOffset(x, y)
	button.Size = UDim2.fromOffset(w, h)
	button.ZIndex = z or 4
	button.SelectionImageObject = noSelectionImage
	local stroke = Dayz.outline(button, Dayz.Colour.Hairline, Dayz.Alpha.Hairline, scaled)
	local overlay = filled(button, 0, 0, 0, 0, "ButtonHover", 1)
	overlay.Name = "Hover"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.Visible = false
	if text ~= "" then
		local label =
			Dayz.label(button, text, 0, 0, 0, 0, "body", Dayz.Colour.TextSoft, 2, Enum.TextXAlignment.Center, scaled)
		label.Size = UDim2.fromScale(1, 1)
	end
	button.MouseEnter:Connect(function()
		overlay.Visible = true
	end)
	button.MouseLeave:Connect(function()
		overlay.Visible = false
	end)
	button.SelectionGained:Connect(function()
		overlay.Visible = true
		stroke.Color = Dayz.Colour.Focus
		stroke.Transparency = Dayz.Alpha.Focus
	end)
	button.SelectionLost:Connect(function()
		overlay.Visible = false
		stroke.Color = Dayz.Colour.Hairline
		stroke.Transparency = Dayz.Alpha.Hairline
	end)
	button.Parent = parent
	return button
end

--[[
	`button` that can be turned off: off, its text is TextDisabled and it does not light up (the
	caller still decides what a click on it does). Returns the button and its on / off switch.
]]
function Dayz.toggleButton(
	parent: Instance,
	text: string,
	x: number,
	y: number,
	w: number,
	h: number,
	z: number?
): (TextButton, (enabled: boolean) -> ())
	local button = Instance.new("TextButton")
	button.Name = "Button"
	button.Text = ""
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.BackgroundColor3 = Dayz.Colour.Button
	button.BackgroundTransparency = Dayz.Alpha.Button
	button.Position = UDim2.fromOffset(x, y)
	button.Size = UDim2.fromOffset(w, h)
	button.ZIndex = z or 4
	button.SelectionImageObject = noSelectionImage
	local stroke = Dayz.outline(button, Dayz.Colour.Hairline, Dayz.Alpha.Hairline)
	local overlay = filled(button, 0, 0, 0, 0, "ButtonHover", 1)
	overlay.Name = "Hover"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.Visible = false
	local label = Dayz.label(button, text, 0, 0, 0, 0, "body", Dayz.Colour.TextSoft, 2, Enum.TextXAlignment.Center)
	label.Size = UDim2.fromScale(1, 1)
	local enabled, hovered, selected = true, false, false
	local function paint()
		overlay.Visible = enabled and (hovered or selected)
		label.TextColor3 = if enabled then Dayz.Colour.TextSoft else Dayz.Colour.TextDisabled
		label.TextTransparency = if enabled then 0 else Dayz.Alpha.TextDisabled
		stroke.Color = if selected then Dayz.Colour.Focus else Dayz.Colour.Hairline
		stroke.Transparency = if selected then Dayz.Alpha.Focus else Dayz.Alpha.Hairline
	end
	button.MouseEnter:Connect(function()
		hovered = true
		paint()
	end)
	button.MouseLeave:Connect(function()
		hovered = false
		paint()
	end)
	button.SelectionGained:Connect(function()
		selected = true
		paint()
	end)
	button.SelectionLost:Connect(function()
		selected = false
		paint()
	end)
	button.Parent = parent
	return button, function(value: boolean)
		if value ~= enabled then
			enabled = value
			paint()
		end
	end
end

--[[
	A text field at (x, y), `w` x 12: a dark face with a hairline, white text, `placeholder` in
	Placeholder grey while empty. Returns the TextBox (inside a clipping frame).
]]
function Dayz.field(
	parent: Instance,
	x: number,
	y: number,
	w: number,
	placeholder: string,
	z: number?,
	scaled: Scaled?
): TextBox
	local frame = filled(parent, x, y, w, 12, "Field", z or 4)
	frame.Name = "FieldFrame"
	frame.ClipsDescendants = true
	Dayz.outline(frame, Dayz.Colour.Hairline, Dayz.Alpha.Hairline, scaled)
	local box = Instance.new("TextBox")
	box.Name = "Field"
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.Position = UDim2.fromOffset(3, 0)
	box.Size = UDim2.fromOffset(w - 6, 12)
	box.ClearTextOnFocus = false
	box.FontFace = Dayz.face("Regular")
	box.TextSize = Theme.Text.body
	box.TextColor3 = Dayz.Colour.Text
	box.PlaceholderText = placeholder
	box.PlaceholderColor3 = Dayz.Colour.Placeholder
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.TextYAlignment = Enum.TextYAlignment.Center
	box.Text = ""
	box.ZIndex = 1
	box.SelectionImageObject = Style.selectionImage
	box.Parent = frame
	if scaled then
		scaled:label(box, "body")
	end
	return box
end

-- The scrollbar's thumb: its height and its transparency while it can scroll and while not.
local THUMB_H = 15
local THUMB_ACTIVE, THUMB_IDLE = 0.3, 0.8

type ScrollbarSelf = Scrollbar & { h: number, fraction: number, active: boolean? }

local ScrollbarClass = {}
ScrollbarClass.__index = ScrollbarClass

function ScrollbarClass.place(self: ScrollbarSelf, fraction: number, active: boolean)
	local f = if fraction == fraction then math.clamp(fraction, 0, 1) else 0
	if f ~= self.fraction then
		self.fraction = f
		local thumbH = math.min(THUMB_H, self.h)
		self.thumb.Position = UDim2.fromOffset(0, math.floor((self.h - thumbH) * f + 0.5))
	end
	if active ~= self.active then
		self.active = active
		self.thumb.BackgroundTransparency = if active then THUMB_ACTIVE else THUMB_IDLE
	end
end

-- A scrollbar at (x, y), `w` x `h`: a Field track with a hairline and a light thumb.
function Dayz.scrollbar(parent: Instance, x: number, y: number, w: number, h: number, z: number?): Scrollbar
	local track = filled(parent, x, y, w, h, "Field", z or 4)
	track.Name = "Scrollbar"
	Dayz.outline(track, Dayz.Colour.Hairline, Dayz.Alpha.Hairline)
	local thumb = Style.frame(track, 0, 0, w, math.min(THUMB_H, h), Dayz.Colour.TextSoft, 1)
	thumb.Name = "Thumb"
	thumb.BackgroundTransparency = THUMB_IDLE
	local self = { track = track, thumb = thumb, h = h, fraction = 0, active = nil }
	local scrollbar = (setmetatable(self, ScrollbarClass) :: any) :: Scrollbar
	scrollbar:place(0, false)
	return scrollbar
end

--[[
	A button tooltip's dark box with `rows` (TooltipLayout's geometry, measured in Roboto) into
	`parent` at (0, 0); returns its width and height (Ui/HoverTip under a marked root).
]]
function Dayz.tooltipBox(parent: Instance, rows: { string }): (number, number)
	local measure = function(text: string): number
		return Style.textWidth(text, TooltipLayout.TEXT, Dayz.FONT)
	end
	local w, h = TooltipLayout.size(rows, measure)
	local pad = TooltipLayout.PAD
	local back = filled(parent, 0, 0, w, h, "TipBody", 1)
	back.Name = "Box"
	Dayz.outline(back, Dayz.Colour.Hairline, Dayz.Alpha.Hairline)
	for i, row in rows do
		Dayz.label(
			back,
			row,
			pad,
			pad + (i - 1) * TooltipLayout.LINE,
			w - 2 * pad + 2,
			TooltipLayout.TEXT,
			"body",
			Dayz.Colour.TextSoft,
			5
		)
	end
	return w, h
end

return Style
