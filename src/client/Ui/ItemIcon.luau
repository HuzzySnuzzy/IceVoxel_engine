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
	hundred icons does no work while nothing changes. When item looks change (ItemModels.changed:
	the Textures setting, texture averages measured) the pool and the fitted views go, and the
	icons showing an item build their models again a few at a time (REBUILD_BUDGET per frame,
	hidden screens' icons too), never all in one frame.

	A worn tool gets Minecraft's durability bar under it (Ui/MenuLayout.durabilityBar: up to 13
	pixels at (2, 13) of the 16 x 16 item on a black 13 x 2 background, from green to red). A
	machine's item that holds energy (its data's `energy`: a charged Battery, a generator broken
	with energy in it) gets Mekanism's energy bar in the same place instead
	(MenuLayout.energyItemBar: its charge, coloured like the panels' energy bar), so `set` takes
	the stack's data too. The bar is made the first time an icon needs one and scales with the
	icon.

	`ItemIcon.slot` is an inventory slot with an icon and the hover overlay (`big`: a result slot's
	large frame).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Items = require(Shared.Items)

local ItemModels = require(script.Parent.Parent.Rendering.ItemModels)
local MenuLayout = require(script.Parent.MenuLayout)
local Style = require(script.Parent.Style)

local MODEL_SIZE = Config.BlockSize
-- A narrow field of view looks almost like Minecraft's orthographic GUI projection.
local FIELD_OF_VIEW = 14
-- Share of the icon the model's bounds fill.
local FILL = 0.94
-- Spare models kept per item.
local POOL_PER_ITEM = 32
-- Seconds per frame spent building icons' models again after a change of item looks.
local REBUILD_BUDGET = 0.001

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
	-- The tool wear shown (0 = none) and the item data shown (its energy bar).
	damage: number,
	data: Items.Data?,
	set: (self: ItemIcon, item: number?, count: number?, damage: number?, data: Items.Data?) -> (),
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
	-- The durability or energy bar (made when first needed) and its coloured part.
	bar: Frame?,
	barFill: Frame?,
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
-- Icons not destroyed yet (weak).
local live: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any
-- Icons whose model has an older look, built again over the next frames (weak).
local stale: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local rebuilding: RBXScriptConnection? = nil

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
		damage = 0,
		data = nil,
		viewport = viewport,
		camera = camera,
		label = label,
		shadow = shadow,
		model = nil,
		block = nil,
		bar = nil,
		barFill = nil,
	}
	live[self] = true
	return (setmetatable(self, ItemIcon) :: any) :: ItemIcon
end

--[[
	Shows (or hides) the bar under the icon's item: the durability bar when it is worn by `damage`,
	else Mekanism's energy bar when it holds energy (`data`).
]]
local function setBar(self: Self, damage: number, data: Items.Data?)
	local width, colour = MenuLayout.durabilityBar(self.item, damage)
	local rgb: Color3 = Color3.fromHSV(colour, 1, 1)
	if width == nil then
		local energy, energyColour = MenuLayout.energyItemBar(self.item, data)
		width = energy
		rgb = Color3.fromRGB(energyColour[1], energyColour[2], energyColour[3])
	end
	local bar, fill = self.bar, self.barFill
	if width == nil then
		if bar and bar.Visible then
			bar.Visible = false
		end
		return
	end
	if bar == nil or fill == nil then
		-- Fractions of the 16 x 16 item, so it scales with any icon size.
		local item = Style.ITEM
		local newBar = Instance.new("Frame")
		newBar.Name = "Bar"
		newBar.BorderSizePixel = 0
		newBar.BackgroundColor3 = Color3.new(0, 0, 0)
		newBar.Position = UDim2.fromScale(MenuLayout.BAR_X / item, MenuLayout.BAR_Y / item)
		newBar.Size = UDim2.fromScale(MenuLayout.BAR_WIDTH / item, MenuLayout.BAR_HEIGHT / item)
		-- Above the model and the count.
		newBar.ZIndex = 4
		newBar.Parent = self.root
		local newFill = Instance.new("Frame")
		newFill.Name = "Fill"
		newFill.BorderSizePixel = 0
		newFill.ZIndex = 1
		newFill.Parent = newBar
		bar, fill = newBar, newFill
		self.bar, self.barFill = newBar, newFill
	end
	assert(bar and fill, "durability bar")
	-- The top one of its two rows, `width` of 13 pixels.
	fill.Size = UDim2.fromScale(width / MenuLayout.BAR_WIDTH, 1 / MenuLayout.BAR_HEIGHT)
	fill.BackgroundColor3 = rgb
	bar.Visible = true
end

--[[
	Shows `item` (nil = nothing) with `count` (drawn when above 1), a tool's wear `damage` (its
	durability bar when worn) and the stack's `data` (the energy bar of an item that holds energy).
	Cheap when nothing changed (data tables are values: a new one is new data).
]]
function ItemIcon.set(self: Self, item: number?, count: number?, damage: number?, data: Items.Data?)
	local itemChanged = item ~= self.item
	if itemChanged then
		local old, model = self.item, self.model
		if old and model then
			-- (A model of an older look never goes back to the pool.)
			if stale[self] then
				stale[self] = nil
				model:Destroy()
			else
				returnModel(old, model)
			end
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
	local wear = if item and damage and damage > 0 then damage else 0
	local held = if item then data else nil
	if wear ~= self.damage or held ~= self.data or itemChanged then
		self.damage = wear
		self.data = held
		setBar(self, wear, held)
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
	live[self] = nil
	local item, model = self.item, self.model
	if item and model then
		if stale[self] then
			model:Destroy()
		else
			returnModel(item, model)
		end
	end
	stale[self] = nil
	self.item = nil
	self.model = nil
	self.root:Destroy()
end

-- Builds a stale icon's model again in the new look.
local function rebuild(icon: Self)
	stale[icon] = nil
	local item, old = icon.item, icon.model
	if item and old then
		old:Destroy()
		local new = takeModel(item)
		icon.camera.CFrame = viewOf(item, new, icon.block == true)
		new.Parent = icon.viewport
		icon.model = new
	end
end

-- Each frame: stale icons until the budget is spent (at least one), then stops when none is left.
local function rebuildSome()
	local deadline = os.clock() + REBUILD_BUDGET
	repeat
		local icon = next(stale)
		if icon == nil then
			if rebuilding then
				rebuilding:Disconnect()
				rebuilding = nil
			end
			return
		end
		rebuild(icon)
	until os.clock() >= deadline
end

-- New item looks: spare models and fitted views go; shown icons build their models again.
ItemModels.changed:Connect(function()
	for _, spare in pool do
		for _, model in spare do
			model:Destroy()
		end
	end
	table.clear(pool)
	table.clear(views)
	for icon: Self in live do
		if icon.item and icon.model then
			stale[icon] = true
		end
	end
	if rebuilding == nil and next(stale) ~= nil then
		rebuilding = RunService.Heartbeat:Connect(rebuildSome)
	end
end)

--[[
	An inventory slot in `parent` for the item at (x, y) (GUI pixels; the slot frame is one pixel up
	and left of it): the inset frame, which is a selectable TextButton, its icon and the hover
	overlay, all inside the button. `big`: drawn with the 26 x 26 result frame (Style.slot).
]]
function ItemIcon.slot(parent: Instance, x: number, y: number, z: number?, big: boolean?): Slot
	local button = Style.slot(parent, x, y, z, big)
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
