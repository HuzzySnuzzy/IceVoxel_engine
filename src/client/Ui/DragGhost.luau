--!strict
--[[
	The carried stack of the inventory screens (Ui/Screens draws it every frame while a screen is
	open): the stack on the cursor, following the pointer (the mouse, a finger, or the gamepad's
	selected slot), centred on it.

	It is drawn in the inventory family's survival look: the stack's icon (the look's ItemIcon: its
	picture darker, its count in a dark box) on a slot's filled face (Theme's CellFilled, white at
	0.04, 17 x 17 like a slot's), and round the face an outline that says what dropping the stack
	where it is would do (Ui/Theme.feedback): green it fits, red it doesn't, light blue a swap,
	orange it stacks, white the drop strip, all at Theme.FEEDBACK_T; white at FEEDBACK_T over
	nothing. Only the outline changes colour, never the face.

	Rules:

	  * `render` shows the `cursor` stack at `point` (screen pixels, InputObject.Position space;
	    `origin` is the cursor layer's AbsolutePosition) or hides the ghost when either is nil.
	    The icon's `set` and the outline's colour are written only when they change, so calling it
	    every frame costs nothing.
	  * The ghost's UIScale is its owner's GUI scale (`setScale`), which also keeps the outline
	    Theme.Size.OUTLINE_PX screen pixels thick and sizes the count box.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Items = require(Shared.Items)

local ItemIcon = require(script.Parent.ItemIcon)
local Style = require(script.Parent.Style)
local Theme = require(script.Parent.Theme)

export type DragGhost = {
	-- "Carried": 16 x 16 GUI pixels, centred on the pointer.
	root: Frame,
	icon: ItemIcon.ItemIcon,
	scale: UIScale,
	setScale: (self: DragGhost, scale: number) -> (),
	render: (
		self: DragGhost,
		point: Vector2?,
		origin: Vector2,
		cursor: Items.Stack?,
		feedback: Theme.Feedback?
	) -> (),
}

type Self = DragGhost & {
	outline: UIStroke,
	-- The feedback the outline shows ("" for none).
	shown: string,
	scaled: Style.Scaled,
}

local DragGhost = {}
DragGhost.__index = DragGhost

-- A hidden ghost in `parent` (the cursor layer's GUI).
function DragGhost.new(parent: Instance): DragGhost
	local Dayz = Style.Dayz
	local root = Instance.new("Frame")
	root.Name = "Carried"
	root.BackgroundTransparency = 1
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Size = UDim2.fromOffset(Style.ITEM, Style.ITEM)
	root.Visible = false
	local scale = Instance.new("UIScale")
	scale.Parent = root
	local scaled = Dayz.scaled()
	-- The face: a slot's (the item at its top left, Theme.Size.CELL square), filled.
	local face = Dayz.slotFace(root, 0, 0, Theme.Size.CELL, Theme.Size.CELL, 1)
	Dayz.paintFace(face, "filled")
	local outline = Dayz.outline(face, Dayz.Colour.Outline, Theme.FEEDBACK_T, scaled)
	local icon = ItemIcon.new(root, 0, 0, 2, "dayz", scaled)
	root.Parent = parent
	local self = { root = root, icon = icon, scale = scale, outline = outline, shown = "", scaled = scaled }
	return (setmetatable(self, DragGhost) :: any) :: DragGhost
end

function DragGhost.setScale(self: Self, scale: number)
	if self.scale.Scale ~= scale then
		self.scale.Scale = scale
	end
	self.scaled:setScale(scale)
end

function DragGhost.render(self: Self, point: Vector2?, origin: Vector2, cursor: Items.Stack?, feedback: Theme.Feedback?)
	if cursor and point then
		self.icon:set(cursor.item, cursor.count, cursor.damage, cursor.data)
		self.root.Position = UDim2.fromOffset(point.X - origin.X, point.Y - origin.Y)
		local key = feedback or ""
		if key ~= self.shown then
			self.shown = key
			self.outline.Color = if feedback then Style.Dayz.Feedback[feedback] else Style.Dayz.Colour.Outline
		end
		if not self.root.Visible then
			self.root.Visible = true
		end
	elseif self.root.Visible then
		self.root.Visible = false
	end
end

return DragGhost
