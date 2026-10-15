--!strict
--[[
	The carried stack of the inventory screens (Ui/Screens draws it every frame while a screen is
	open): the stack on the cursor, following the pointer (the mouse, a finger, or the gamepad's
	selected slot), centred on it.

	Rules:

	  * `render` shows the `cursor` stack at `point` (screen pixels, InputObject.Position space;
	    `origin` is the cursor layer's AbsolutePosition) or hides the ghost when either is nil.
	    The icon's `set` is cheap when nothing changed, so calling it every frame costs nothing.
	  * `feedback` (Ui/Theme.feedback: what dropping the stack where it is would do) may colour the
	    ghost's outline; it is the only drag feedback the ghost shows. This version ignores it.
	  * The ghost's UIScale is its owner's GUI scale (`setScale`).

	This version draws the stack as Minecraft does: its icon and count, nothing around it.
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

local DragGhost = {}
DragGhost.__index = DragGhost

-- A hidden ghost in `parent` (the cursor layer's GUI).
function DragGhost.new(parent: Instance): DragGhost
	local root = Instance.new("Frame")
	root.Name = "Carried"
	root.BackgroundTransparency = 1
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Size = UDim2.fromOffset(Style.ITEM, Style.ITEM)
	root.Visible = false
	root.Parent = parent
	local scale = Instance.new("UIScale")
	scale.Parent = root
	local icon = ItemIcon.new(root, 0, 0, 1)
	local self = { root = root, icon = icon, scale = scale }
	return (setmetatable(self, DragGhost) :: any) :: DragGhost
end

function DragGhost.setScale(self: DragGhost, scale: number)
	if self.scale.Scale ~= scale then
		self.scale.Scale = scale
	end
end

function DragGhost.render(
	self: DragGhost,
	point: Vector2?,
	origin: Vector2,
	cursor: Items.Stack?,
	_feedback: Theme.Feedback?
)
	if cursor and point then
		self.icon:set(cursor.item, cursor.count, cursor.damage, cursor.data)
		self.root.Position = UDim2.fromOffset(point.X - origin.X, point.Y - origin.Y)
		self.root.Visible = true
	elseif self.root.Visible then
		self.root.Visible = false
	end
end

return DragGhost
