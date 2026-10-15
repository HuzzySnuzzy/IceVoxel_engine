--!strict
--[[
	The item tooltip of the inventory screens (Ui/Screens shows it): what an item is, for the stack
	it is in when it is a slot's, plus extra lines from JEI (a tag ingredient's tag, a fluid, a lock)
	or the inventory (a machine's energy bar, a tank, a locked result, a closed accessory slot).

	The lines are Shared/Items/Tooltip's (name, item data, lore, what it is, its stat blocks, its
	wear, and for a player the recipe gate's verdict on what making it needs). Lines wider than
	WRAP GUI pixels (never narrower than the name) are wrapped at word breaks (Ui/TextWrap).

	Rules:

	  * `key` says what a tooltip shows (the item, its wear, data and lock, and every extra line):
	    the owner compares keys and calls `build` only when the key changed, so nothing is drawn
	    per frame while the same thing stays hovered.
	  * `build` draws the box into the root's "Box" frame (the old one goes), sizes the root and
	    returns the size in GUI pixels; the root keeps its UIScale "Scale", which `setScale` sets
	    (its owner's GUI scale) and nothing else touches.
	  * Where the box goes, when it shows and for how long is the owner's (Ui/Screens: placement,
	    the hover delay, hidden while a stack is carried).

	This version draws Minecraft's tooltip: a dark purple box with a lighter purple border, the
	name, then the details, each line in its Minecraft colour.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Items = require(Shared.Items)
local Tooltip = require(Shared.Items.Tooltip)

local ProgressionState = require(script.Parent.Parent.Player.ProgressionState)
local Style = require(script.Parent.Style)
local TextWrap = require(script.Parent.TextWrap)

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

-- Lines wider than this (GUI pixels) wrap (the lore), as the settings' tooltips do.
ItemTooltip.WRAP = 200

-- Shared/Items/Tooltip's colour names -> the palette.
local COLOURS: { [Tooltip.Colour]: Color3 } = {
	white = Style.Colour.Text,
	gray = Style.Colour.Gray,
	blue = Style.Colour.Blue,
	red = Style.Colour.Red,
	darkGreen = Style.Colour.DarkGreen,
	lore = Style.Colour.Lore,
}

-- The tooltip lines of `item` (in `stack`, when it is a slot's: its data and wear), coloured.
local function itemLines(item: number, stack: Items.Stack?): { Line }
	local lines: { Line } = {}
	for _, line in Tooltip.lines(item, stack, { gate = ProgressionState.gate() }) do
		table.insert(lines, { text = line.text, colour = COLOURS[line.colour] or Style.Colour.Text })
	end
	return lines
end

-- What the tooltip of `item` in `stack` depends on beyond the item (its wear, its data, the
-- recipe gate's verdict).
local function state(item: number, stack: Items.Stack?): string
	local lock = ProgressionState.lockText(item) or ""
	if stack == nil or stack.item ~= item then
		return lock
	end
	return `{Items.cleanDamage(stack.damage) or 0}#{Items.dataKey(stack.data)}#{lock}`
end

-- `lines` with every line wider than the wrap width cut into rows of its colour (Ui/TextWrap).
local function wrapLines(lines: { Line }): { Line }
	local width = ItemTooltip.WRAP
	if lines[1] then
		width = math.max(width, Style.textWidth(lines[1].text))
	end
	local measure = function(text: string): number
		return Style.textWidth(text)
	end
	local out: { Line } = {}
	for i, line in lines do
		if i == 1 or line.text == "" or measure(line.text) <= width then
			table.insert(out, line)
		else
			for _, row in TextWrap.wrap(line.text, width, measure) do
				table.insert(out, { text = row, colour = line.colour })
			end
		end
	end
	return out
end

-- Minecraft's tooltip box with `lines` into `box`: returns its size.
local function draw(box: Frame, lines: { Line }): Vector2
	lines = wrapLines(lines)
	local width = 0
	for _, line in lines do
		width = math.max(width, Style.textWidth(line.text))
	end
	-- 10 pixels per line, and 2 more under the name.
	local height = 8 + (#lines - 1) * 10 + (if #lines > 1 then 2 else 0)
	local w, h = width + 8, height + 8
	local back = Style.frame(box, 0, 0, w, h, Style.Colour.TooltipBack, 1)
	back.BackgroundTransparency = 0.06
	local border = Style.border(back, 1, 1, w - 2, h - 2, 1, Color3.new(1, 1, 1), 2)
	-- (The border colours blended over the background, as Minecraft draws them translucent.)
	local top, bottom = Color3.fromRGB(36, 0, 90), Color3.fromRGB(23, 0, 50)
	for i, frame in border do
		frame.BackgroundColor3 = if i == 2 then bottom else top
		if i >= 3 then
			frame.BackgroundColor3 = Color3.new(1, 1, 1)
			local gradient = Instance.new("UIGradient")
			gradient.Rotation = 90
			gradient.Color = ColorSequence.new(top, bottom)
			gradient.Parent = frame
		end
	end
	local y = 4
	for i, line in lines do
		if line.text ~= "" then
			Style.shadowText(back, line.text, 4, y, width + 2, 8, line.colour, 5)
		end
		y += if i == 1 then 12 else 10
	end
	return Vector2.new(w, h)
end

type Self = ItemTooltip & { box: Frame? }

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
	root.Parent = parent
	local self = { root = root, scale = scale, box = nil }
	return (setmetatable(self, ItemTooltip) :: any) :: ItemTooltip
end

function ItemTooltip.key(_self: Self, item: number?, stack: Items.Stack?, extra: { Line }?): string
	local key = if item then `{item}#{state(item, stack)}` else ""
	if extra then
		for _, line in extra do
			key ..= `|{line.text}`
		end
	end
	return key
end

function ItemTooltip.build(self: Self, item: number?, stack: Items.Stack?, extra: { Line }?): Vector2
	local lines: { Line } = if item then itemLines(item, stack) else {}
	if extra then
		table.move(extra, 1, #extra, #lines + 1, lines)
	end
	local old = self.box
	if old then
		old:Destroy()
	end
	local box = Instance.new("Frame")
	box.Name = "Box"
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.ZIndex = 1
	local size = draw(box, lines)
	box.Size = UDim2.fromOffset(size.X, size.Y)
	box.Parent = self.root
	self.box = box
	self.root.Size = UDim2.fromOffset(size.X, size.Y)
	return size
end

function ItemTooltip.setScale(self: Self, scale: number)
	if self.scale.Scale ~= scale then
		self.scale.Scale = scale
	end
end

return ItemTooltip
