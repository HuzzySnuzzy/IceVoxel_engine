--!strict
--[[
	The item tooltip of the inventory screens (Ui/Screens shows it): what an item is, for the stack
	it is in when it is a slot's, plus extra lines from JEI (a tag ingredient's tag, a fluid, a lock)
	or the inventory (a machine's energy bar, a tank, a locked result, a closed accessory slot).

	It is drawn in the inventory family's survival look (Ui/Theme's `tip` lays it out, Style.Dayz
	draws it): a near-black header over a dark body, no border.

	  header   a dot in the item's condition colour at half strength (durable items: Theme.condition
	           of Ui/MenuLayout.wear, the stack's wear), the name in white, under it the condition
	           word and, right-aligned, a stack's count against its most ("32 / 64"; room kept for
	           as many digits as the most has, "88 / 64", or the count's own when past it)
	  body     the item's picture on the left (one survival-look icon, 40 x 40: an ItemIcon under a
	           UIScale, kept and only `set` when the item changes), and on the right a liquid pill
	           (Theme.liquid: a bucket's fluid, a water drink's water) and the lines: Shared/Items/
	           Tooltip's lines after the name (item data, lore, what the item is, its stat blocks,
	           its wear, the recipe gate's lock), then the extra lines, wrapped to the column, each
	           in its look colour (Theme.tooltipColour; the extra lines' Minecraft colours mapped
	           the same way: red is Warning, gray TextMuted)
	  plain    without an item (a fluid, a gauge, a locked slot, a button of the recipe view) the
	           first line is the header and the rest the body, without a picture

	Rules:

	  * `key` says what a tooltip shows (the item, its wear, data and lock, and every extra line):
	    the owner compares keys and calls `build` only when the key changed, so nothing is drawn
	    per frame while the same thing stays hovered. The owner also restarts its hover delay when
	    the key changes (Ui/Screens: a mouse's tooltip shows once the same key has been hovered
	    Theme.Time.TOOLTIP_DELAY), so the key leaves out what changes under a still pointer: the
	    stack's count (a furnace's output, fuel burning down, a stack filling from pickups). The
	    key holds only how many digits the header keeps room for, which changes only past the
	    most's (a container that holds more), and then the box is drawn again.
	  * So `key` keeps the shown count current itself: when the key is the drawn box's and the
	    count differs from the one it shows, it rewrites the header's count text in place (one
	    property write per change, none while the count stays). The box keeps its width, the
	    header having room for the count's digits.
	  * `build` draws the box into the root's "Box" frame (the old one goes), sizes the root and
	    returns the size in GUI pixels; the root keeps its UIScale "Scale", which `setScale` sets
	    (its owner's GUI scale, which also re-weights the small text) and nothing else touches.
	  * Where the box goes, when it shows and for how long is the owner's (Ui/Screens: its top left
	    at the pointer, the hover delay, hidden while a stack is carried).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Items = require(Shared.Items)
local Tooltip = require(Shared.Items.Tooltip)

local ProgressionState = require(script.Parent.Parent.Player.ProgressionState)
local ItemIcon = require(script.Parent.ItemIcon)
local MenuLayout = require(script.Parent.MenuLayout)
local Style = require(script.Parent.Style)
local Theme = require(script.Parent.Theme)

-- A line of text in its colour.
export type Line = { text: string, colour: Color3 }

export type ItemTooltip = {
	-- "Tooltip": the box's holder, sized to it, with its UIScale "Scale".
	root: Frame,
	scale: UIScale,
	-- What the tooltip of `item` in `stack` with `extra` lines shows ("" for nothing).
	key: (self: ItemTooltip, item: number?, stack: Items.Stack?, extra: { Line }?) -> string,
	-- Draws it; returns its size in GUI pixels.
	build: (self: ItemTooltip, item: number?, stack: Items.Stack?, extra: { Line }?) -> Vector2,
	setScale: (self: ItemTooltip, scale: number) -> (),
}

local ItemTooltip = {}
ItemTooltip.__index = ItemTooltip

-- The widest a tooltip gets (GUI pixels): its lines wrap inside it.
ItemTooltip.WRAP = Theme.Tip.MAX_W

-- The look colours an extra line's colour may already be (B's and C's lines in the look's own).
local LOOK_KEYS = { "Text", "TextSoft", "TextMuted", "TextDisabled", "Warning" }

-- The look colour key of an extra line's colour: Minecraft's palette (Style.Colour) mapped as
-- Theme.tooltipColour maps the item lines' names; the look's own colours kept; else Text.
local function keyOf(colour: Color3): string
	local C = Style.Colour
	if colour == C.Red or colour == C.Missing then
		return "Warning"
	elseif colour == C.Gray or colour == C.Lore or colour == C.TextDisabled then
		return "TextMuted"
	elseif colour == C.Blue or colour == C.DarkGreen then
		return "TextSoft"
	end
	for _, key in LOOK_KEYS do
		if colour == Style.Dayz.Colour[key] then
			return key
		end
	end
	return "Text"
end

-- How many digits `n` (a whole number from 0) has.
local function digits(n: number): number
	local count = 1
	while n >= 10 do
		n = n // 10
		count += 1
	end
	return count
end

-- How many digits the header keeps room for in `stack`'s count of `item` (0: no count shown, one
-- to a stack): as many as the most has, or the count's own when past it.
local function roomOf(item: number, stack: Items.Stack): number
	local most = Items.maxStack(item)
	if most <= 1 then
		return 0
	end
	return digits(math.max(stack.count, most))
end

-- What the tooltip of `item` in `stack` depends on beyond the item (its wear, its data, the room
-- for its count, the recipe gate's verdict): not the count itself, which `key` writes in place.
local function state(item: number, stack: Items.Stack?): string
	local lock = ProgressionState.lockText(item) or ""
	if stack == nil or stack.item ~= item then
		return lock
	end
	return `{Items.cleanDamage(stack.damage) or 0}#{Items.dataKey(stack.data)}#{roomOf(item, stack)}#{lock}`
end

-- What the tooltip of `item` in `stack` with `extra` lines shows ("" for nothing).
local function tipKey(item: number?, stack: Items.Stack?, extra: { Line }?): string
	local key = if item then `{item}#{state(item, stack)}` else ""
	if extra then
		for _, line in extra do
			key ..= `|{line.text}`
		end
	end
	return key
end

-- The header's count of `stack` against its most.
local function countText(stack: Items.Stack, most: number): string
	return `{stack.count} / {most}`
end

-- `extra` from its `first` line on, in look colours.
local function extraLines(lines: { Theme.TipLine }, extra: { Line }?, first: number)
	if extra == nil then
		return
	end
	for i = first, #extra do
		local line = extra[i]
		table.insert(lines, { text = line.text, colour = keyOf(line.colour) })
	end
end

-- What the tooltip of `item` (in `stack`) with `extra` shows, for Theme.tip.
local function inputOf(item: number?, stack: Items.Stack?, extra: { Line }?): Theme.TipInput
	local lines: { Theme.TipLine } = {}
	if item == nil then
		local first = extra and extra[1]
		extraLines(lines, extra, 2)
		return {
			name = if first then first.text else "",
			nameColour = if first then keyOf(first.colour) else "Text",
			condition = nil,
			count = nil,
			countRoom = nil,
			liquid = nil,
			picture = false,
			lines = lines,
		}
	end
	local itemLines = Tooltip.lines(item, stack, { gate = ProgressionState.gate() })
	-- (The first line is the name: the header's.)
	for i = 2, #itemLines do
		local line = itemLines[i]
		table.insert(lines, { text = line.text, colour = Theme.tooltipColour(line.colour) })
	end
	extraLines(lines, extra, 1)
	local held = stack ~= nil and stack.item == item
	local fraction, sips = MenuLayout.wear(item, if held and stack then stack.damage else nil)
	local count: string?, countRoom: string? = nil, nil
	local most = Items.maxStack(item)
	if held and stack and most > 1 then
		count = countText(stack, most)
		countRoom = `{string.rep("8", roomOf(item, stack))} / {most}`
	end
	return {
		name = itemLines[1].text,
		nameColour = "Text",
		condition = Theme.condition(fraction, sips),
		count = count,
		countRoom = countRoom,
		liquid = Theme.liquid(item),
		picture = true,
		lines = lines,
	}
end

local ALIGN = {
	left = Enum.TextXAlignment.Left,
	right = Enum.TextXAlignment.Right,
	center = Enum.TextXAlignment.Center,
}

type Self = ItemTooltip & {
	box: Frame?,
	-- The picture's holder (16 x 16 under a UIScale to TIP_PICTURE) and its icon.
	picture: Frame,
	icon: ItemIcon.ItemIcon,
	-- The small text's weights follow the GUI scale.
	scaled: Style.Scaled,
	-- The drawn box's key, its count's text (nil: no count shown) and the count it shows.
	shownKey: string,
	countLabel: TextLabel?,
	shownCount: number,
}

-- A hidden tooltip in `parent` (the cursor layer's GUI).
function ItemTooltip.new(parent: Instance): ItemTooltip
	local root = Instance.new("Frame")
	root.Name = "Tooltip"
	root.BackgroundTransparency = 1
	root.Visible = false
	root.ZIndex = 2
	local scale = Instance.new("UIScale")
	scale.Name = "Scale"
	scale.Parent = root
	-- (Over the box: a higher sibling draws over the box and everything in it.)
	local picture = Instance.new("Frame")
	picture.Name = "Picture"
	picture.BackgroundTransparency = 1
	picture.BorderSizePixel = 0
	picture.Size = UDim2.fromOffset(Style.ITEM, Style.ITEM)
	picture.ZIndex = 2
	picture.Visible = false
	local grow = Instance.new("UIScale")
	grow.Scale = Theme.Size.TIP_PICTURE / Style.ITEM
	grow.Parent = picture
	local icon = ItemIcon.new(picture, 0, 0, 1, "dayz")
	picture.Parent = root
	root.Parent = parent
	local self = {
		root = root,
		scale = scale,
		box = nil,
		picture = picture,
		icon = icon,
		scaled = Style.Dayz.scaled(),
		shownKey = "",
		countLabel = nil,
		shownCount = 0,
	}
	return (setmetatable(self, ItemTooltip) :: any) :: ItemTooltip
end

function ItemTooltip.key(self: Self, item: number?, stack: Items.Stack?, extra: { Line }?): string
	local key = tipKey(item, stack, extra)
	-- (The drawn box's stack with another count: written in place, the key unchanged.)
	local label = self.countLabel
	if label and stack and item and key == self.shownKey and stack.count ~= self.shownCount then
		self.shownCount = stack.count
		label.Text = countText(stack, Items.maxStack(item))
	end
	return key
end

-- A Frame filled with the look colour `key` in `parent`.
local function filled(parent: Instance, x: number, y: number, w: number, h: number, key: string, z: number): Frame
	local frame = Style.frame(parent, x, y, w, h, Style.Dayz.Colour[key], z)
	frame.BackgroundTransparency = Style.Dayz.Alpha[key]
	return frame
end

function ItemTooltip.build(self: Self, item: number?, stack: Items.Stack?, extra: { Line }?): Vector2
	local Dayz = Style.Dayz
	local input = inputOf(item, stack, extra)
	local layout = Theme.tip(input, Dayz.measure)
	local old = self.box
	if old then
		old:Destroy()
	end
	self.shownKey = tipKey(item, stack, extra)
	self.countLabel = nil
	local box = Instance.new("Frame")
	box.Name = "Box"
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.Size = UDim2.fromOffset(layout.w, layout.h)
	box.ZIndex = 1
	filled(box, 0, 0, layout.w, layout.head, "TipHead", 1).Name = "Head"
	if layout.h > layout.head then
		filled(box, 0, layout.head, layout.w, layout.h - layout.head, "TipBody", 1).Name = "Body"
	end
	local dot, condition = layout.dot, input.condition
	if dot and condition then
		local frame = Dayz.dot(box, dot.x, dot.y, dot.w, 3)
		frame.BackgroundColor3 = Dayz.Condition[condition.name]
	end
	local pill = layout.pill
	if pill then
		filled(box, pill.x, pill.y, pill.w, pill.h, "Liquid", 2).Name = "Liquid"
	end
	for i, text in layout.texts do
		local label = Dayz.label(
			box,
			text.text,
			text.x,
			text.y,
			text.w,
			text.h,
			text.role,
			Dayz.Colour[text.colour],
			4,
			ALIGN[text.align],
			self.scaled
		)
		if i == 1 then
			-- (The name: cut short rather than past the box.)
			label.TextTruncate = Enum.TextTruncate.AtEnd
		elseif i == layout.countAt and stack then
			self.countLabel = label
			self.shownCount = stack.count
		end
	end
	local picture = layout.picture
	if picture and item then
		self.picture.Position = UDim2.fromOffset(picture.x, picture.y)
		self.icon:set(item, 1)
		self.picture.Visible = true
	else
		self.picture.Visible = false
		self.icon:set(nil)
	end
	box.Parent = self.root
	self.box = box
	self.root.Size = UDim2.fromOffset(layout.w, layout.h)
	return Vector2.new(layout.w, layout.h)
end

function ItemTooltip.setScale(self: Self, scale: number)
	if self.scale.Scale ~= scale then
		self.scale.Scale = scale
	end
	self.scaled:setScale(scale)
end

return ItemTooltip
