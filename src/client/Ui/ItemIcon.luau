--!strict
--[[
	Item icons: the item's 3D model (Rendering/ItemModels) in a ViewportFrame, with its stack count.

	  blocks       Minecraft's inventory view: isometric (yaw 45°, pitch 30°) so the top and two
	               sides show, lit so the top is brightest, then the left face, then the right
	               (Minecraft's 1 : 0.8 : 0.6), from the viewport's own ambient and directional light
	  other items  (armor) from the front, turned a little, lit from the upper front

	The camera is fitted to the model's projected bounds once per item and remembered. Icons are
	cheap to keep: each one builds its ViewportFrame once, and `set` only swaps the model when the
	item changes (models of items no longer shown go back to a pool, per item), so a screen of a
	hundred icons does no work while nothing changes.

	`ItemIcon.slot` is an inventory slot with an icon and the hover overlay.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)

local ItemModels = require(script.Parent.Parent.Rendering.ItemModels)
local Style = require(script.Parent.Style)

local MODEL_SIZE = Config.BlockSize
-- A narrow field of view looks almost like Minecraft's orthographic GUI projection.
local FIELD_OF_VIEW = 14
-- Share of the icon the model's bounds fill.
local FILL = 0.94
-- Spare models kept per item.
local POOL_PER_ITEM = 32

-- Blocks: looking down 30° from the +X +Z corner, so +Z is the left face and +X the right one.
local BLOCK_VIEW = CFrame.Angles(0, math.rad(45), 0) * CFrame.Angles(math.rad(-30), 0, 0)
-- Other items: from the front (-Z, where a character faces), turned 25° and looking down 15°.
local ITEM_VIEW = CFrame.Angles(0, math.pi + math.rad(25), 0) * CFrame.Angles(math.rad(-15), 0, 0)

--[[
	Lighting = ambient + light x cos(angle). Blocks: the light comes from above and +Z (towards the
	left face): top 0.6 + 0.4, left 0.6 + 0.2, right 0.6. Other items: from the upper front left.
]]
local BLOCK_AMBIENT = Color3.new(0.6, 0.6, 0.6)
local BLOCK_LIGHT = Color3.new(0.447, 0.447, 0.447)
local BLOCK_LIGHT_DIRECTION = Vector3.new(0, -2, -1)
local ITEM_AMBIENT = Color3.new(0.55, 0.55, 0.55)
local ITEM_LIGHT = Color3.new(0.5, 0.5, 0.5)
local ITEM_LIGHT_DIRECTION = Vector3.new(0.3, -0.7, 0.65)

export type ItemIcon = {
	-- 16 x 16 GUI pixels: the viewport and the count.
	root: Frame,
	item: number?,
	count: number,
	set: (self: ItemIcon, item: number?, count: number?) -> (),
	setCountColour: (self: ItemIcon, colour: Color3?) -> (),
	destroy: (self: ItemIcon) -> (),
}

type Self = ItemIcon & {
	viewport: ViewportFrame,
	camera: Camera,
	label: TextLabel,
	shadow: TextLabel,
	model: Model?,
	block: boolean?,
}

-- An inventory slot: the inset frame (a TextButton), the icon and the hover overlay.
export type Slot = {
	button: TextButton,
	icon: ItemIcon,
	hover: Frame,
}

local ItemIcon = {}
ItemIcon.__index = ItemIcon

local pool: { [number]: { Model } } = {}
local views: { [number]: CFrame } = {}

local function takeModel(item: number): Model
	local spare = pool[item]
	if spare and #spare > 0 then
		return table.remove(spare) :: Model
	end
	return ItemModels.build(item, MODEL_SIZE)
end

local function returnModel(item: number, model: Model)
	model.Parent = nil
	local spare = pool[item]
	if spare == nil then
		spare = {}
		pool[item] = spare
	end
	if #spare < POOL_PER_ITEM then
		table.insert(spare, model)
	else
		model:Destroy()
	end
end

-- The camera CFrame that fits `model` (at the origin) in the icon, seen from `rotation`.
local function fit(model: Model, rotation: CFrame): CFrame
	local right, up, look = rotation.RightVector, rotation.UpVector, rotation.LookVector
	local minU, maxU, minV, maxV, nearest = math.huge, -math.huge, math.huge, -math.huge, math.huge
	local any = false
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			any = true
			local cframe, half = part.CFrame, part.Size / 2
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					for _, sz in { -1, 1 } do
						local corner = cframe * Vector3.new(half.X * sx, half.Y * sy, half.Z * sz)
						local u, v, w = corner:Dot(right), corner:Dot(up), corner:Dot(look)
						minU, maxU = math.min(minU, u), math.max(maxU, u)
						minV, maxV = math.min(minV, v), math.max(maxV, v)
						nearest = math.min(nearest, w)
					end
				end
			end
		end
	end
	if not any then
		minU, maxU, minV, maxV, nearest = -1, 1, -1, 1, -1
	end
	local half = math.max(maxU - minU, maxV - minV, 0.01) / 2 / FILL
	local distance = half / math.tan(math.rad(FIELD_OF_VIEW / 2))
	local centre = right * ((minU + maxU) / 2) + up * ((minV + maxV) / 2) + look * nearest
	return CFrame.new(centre - look * distance) * rotation.Rotation
end

local function viewOf(item: number, model: Model, block: boolean): CFrame
	local cached: CFrame? = views[item]
	if cached then
		return cached
	end
	local view = fit(model, if block then BLOCK_VIEW else ITEM_VIEW)
	views[item] = view
	return view
end

--[[
	A new icon in `parent` with the 16 x 16 item area at (x, y) (GUI pixels). Its count shows at the
	bottom right when above 1, Minecraft style.
]]
function ItemIcon.new(parent: Instance, x: number, y: number, z: number?): ItemIcon
	local root = Instance.new("Frame")
	root.Name = "ItemIcon"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Position = UDim2.fromOffset(x, y)
	root.Size = UDim2.fromOffset(Style.ITEM, Style.ITEM)
	root.ZIndex = z or 5

	local viewport = Instance.new("ViewportFrame")
	viewport.BackgroundTransparency = 1
	viewport.BorderSizePixel = 0
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.ZIndex = 1
	viewport.Ambient = BLOCK_AMBIENT
	viewport.LightColor = BLOCK_LIGHT
	viewport.LightDirection = BLOCK_LIGHT_DIRECTION
	viewport.Parent = root

	local camera = Instance.new("Camera")
	camera.FieldOfView = FIELD_OF_VIEW
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	-- Minecraft draws the count with its right edge one pixel past the item, at the bottom.
	local label, shadow = Style.shadowText(
		root,
		"",
		0,
		Style.ITEM - Style.COUNT_SIZE + 1,
		Style.ITEM + 1,
		Style.COUNT_SIZE,
		Style.Colour.Text,
		2,
		Enum.TextXAlignment.Right,
		Style.COUNT_SIZE
	)
	label.Visible = false
	shadow.Visible = false

	root.Parent = parent

	local self = {
		root = root,
		item = nil,
		count = 0,
		viewport = viewport,
		camera = camera,
		label = label,
		shadow = shadow,
		model = nil,
		block = nil,
	}
	return (setmetatable(self, ItemIcon) :: any) :: ItemIcon
end

-- Shows `item` (nil = nothing) with `count` (drawn when above 1). Cheap when nothing changed.
function ItemIcon.set(self: Self, item: number?, count: number?)
	if item ~= self.item then
		local old, model = self.item, self.model
		if old and model then
			returnModel(old, model)
		end
		self.item = item
		self.model = nil
		if item then
			local new = takeModel(item)
			local block = ItemModels.isBlock(item)
			if block ~= self.block then
				self.block = block
				self.viewport.Ambient = if block then BLOCK_AMBIENT else ITEM_AMBIENT
				self.viewport.LightColor = if block then BLOCK_LIGHT else ITEM_LIGHT
				self.viewport.LightDirection = if block then BLOCK_LIGHT_DIRECTION else ITEM_LIGHT_DIRECTION
			end
			self.camera.CFrame = viewOf(item, new, block)
			new.Parent = self.viewport
			self.model = new
		end
	end
	local shown = if item then count or 1 else 0
	if shown ~= self.count then
		self.count = shown
		local text = if shown > 1 then tostring(shown) else ""
		self.label.Text = text
		self.shadow.Text = text
		self.label.Visible = shown > 1
		self.shadow.Visible = shown > 1
	end
end

-- Count colour (Minecraft draws an over-full drag preview in yellow); nil = white.
function ItemIcon.setCountColour(self: Self, colour: Color3?)
	local c = colour or Style.Colour.Text
	if self.label.TextColor3 ~= c then
		self.label.TextColor3 = c
		self.shadow.TextColor3 = Style.shadowOf(c)
	end
end

function ItemIcon.destroy(self: Self)
	local item, model = self.item, self.model
	if item and model then
		returnModel(item, model)
	end
	self.item = nil
	self.model = nil
	self.root:Destroy()
end

--[[
	An inventory slot in `parent` for the item at (x, y) (GUI pixels; the slot frame is one pixel up
	and left of it): the inset frame, which is a selectable TextButton, its icon and the hover
	overlay, all inside the button.
]]
function ItemIcon.slot(parent: Instance, x: number, y: number, z: number?): Slot
	local button = Style.slot(parent, x, y, z)
	local icon = ItemIcon.new(button, 1, 1, 5)
	local hover = Style.hover(button, 1, 1, 10)
	return { button = button, icon = icon, hover = hover }
end

-- Height of a tab above its panel's top edge, and its width (Minecraft's creative tabs).
ItemIcon.TAB_HEIGHT = 26
ItemIcon.TAB_WIDTH = 28

-- A creative tab: its button and every frame it draws (to show / hide and hit-test them).
export type Tab = { button: TextButton, frames: { GuiObject } }

--[[
	A Minecraft creative tab showing `item`, at x on top of a panel whose top edge is at y = TAB_HEIGHT
	in `parent`. Put it in the same parent as the panel (ZIndex 1): the active tab is drawn over the
	panel's border (ZIndex 2 and 3), merging into it; the others sit behind the panel (ZIndex 0),
	darker.
]]
function ItemIcon.tab(parent: Instance, x: number, item: number?, active: boolean): Tab
	local width, top = ItemIcon.TAB_WIDTH, ItemIcon.TAB_HEIGHT
	local root = if active
		then Style.panel(parent, x, 0, width, top + 4)
		else Style.panel(parent, x, 2, width, top + 2, Style.Colour.Slot)
	root.ZIndex = if active then 2 else 0
	local frames: { GuiObject } = { root }
	if active then
		-- Hide the tab's bottom edge and the panel's top border under it.
		table.insert(frames, Style.frame(parent, x + 3, top, width - 6, 4, Style.Colour.Panel, 3))
	end
	if item then
		ItemIcon.new(root, 6, if active then 7 else 6, 6):set(item, 1)
	end
	local button = Instance.new("TextButton")
	button.Text = ""
	button.BackgroundTransparency = 1
	button.AutoButtonColor = false
	button.Size = UDim2.fromScale(1, 1)
	button.ZIndex = 8
	button.SelectionImageObject = Style.selectionImage
	button.Parent = root
	return { button = button, frames = frames }
end

return ItemIcon
