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

	A firearm or a magazine (Shared/Weapons) counts its rounds instead of its stack, as DayZ's
	inventory does: the count is WeaponState.shownCount of the stack (a gun's rounds and its
	chambered one, a magazine's rounds), shown even when it is 1 and not at all when 0, in either
	look. It is worked out only when the item or its data changed (data tables are values), so a
	screen drawn every frame does no work for it.

	A worn tool gets Minecraft's durability bar under it (Ui/MenuLayout.durabilityBar: up to 13
	pixels at (2, 13) of the 16 x 16 item on a black 13 x 2 background, from green to red). A
	machine's item that holds energy (its data's `energy`: a charged Battery, a generator broken
	with energy in it) gets Mekanism's energy bar in the same place instead
	(MenuLayout.energyItemBar: its charge, coloured like the panels' energy bar), so `set` takes
	the stack's data too. The bar is made the first time an icon needs one and scales with the
	icon.

	Two looks. Without a `look` an icon is the Minecraft one above (WAILA, the skill tree, the game
	mode switcher keep it). With `look = "dayz"` (the inventory family: Ui/Theme, Style.Dayz) the
	picture is drawn darker (Theme's ItemTint, ImageColor3: `setDimmed`'s colour wins while dimmed
	and un-dimming gives the tint back), the count is a small dark box at the bottom right
	(Style.Dayz.countBox: shown above 1, as wide as its digits, sized by the GUI scale through
	`setScale`, its digits Light once they are tall enough on screen: Theme.thin), and the bar is
	one pixel tall along the bottom (Theme.Size.BAR): a damaged durable item's in its condition's
	colour (Theme.condition of MenuLayout.wear) on a dark track, a canteen's sips in white on a
	light track (always: a quantity), an energy item's in the energy colour. Nothing tints the
	cell. `setTransparency` fades the whole icon (the quickbar's fade), combined with `setDimmed`.

	`ItemIcon.slot` is an inventory slot in that look (only the inventory family uses it): an 18 x
	18 transparent button one pixel up and left of the item (the hit area), a face (17 x 17 inside
	the slot's grid lines, or 24 x 24 for a `big` result slot) made with Style.Dayz.slotFace and
	never painted here afterwards (its owner paints it: Style.Dayz.paintFace), the icon, and the
	hover: a transparent frame over the face with an outline, hidden (Style.Dayz.setLit). `tab` is
	a creative / JEI tab in that look: a dark panel square with a hairline, the active one grey.

	Style.Dayz and Style.Theme are looked up inside the functions only (never at load), so the
	RenderPipeline spec's Style stub keeps loading this module.

	An item with a picture in Shared/TexturePack's `Icons` (Items.icon: filled in, not "") is drawn
	as that image instead of its model (pixel art kept sharp: ResamplerMode.Pixelated); the image
	label is made the first time an icon needs one. Items whose entry is still blank keep their
	model, so filling an icon in later is all it takes to change the look.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local Weapons = require(Shared.Weapons)
local WeaponState = require(Shared.Weapons.WeaponState)

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
-- A dimmed icon (`setDimmed`): greyed and faded; `mild`, less (still clearly the item: the skill
-- tree's locked skills, which a player needs to recognise).
local DIMMED_COLOUR = Color3.fromRGB(120, 120, 120)
local DIMMED_TRANSPARENCY = 0.35
local MILD_COLOUR = Color3.fromRGB(175, 175, 175)
local MILD_TRANSPARENCY = 0.15

-- The icon looks: nil is Minecraft's, "dayz" the inventory family's (see the header).
export type Look = "dayz"

export type ItemIcon = {
	-- 16 x 16 GUI pixels: the viewport and the count.
	root: Frame,
	look: Look?,
	item: number?,
	count: number,
	-- The tool wear shown (0 = none) and the item data shown (its energy bar).
	damage: number,
	data: Items.Data?,
	set: (self: ItemIcon, item: number?, count: number?, damage: number?, data: Items.Data?) -> (),
	setCountColour: (self: ItemIcon, colour: Color3?) -> (),
	setDimmed: (self: ItemIcon, dimmed: boolean, mild: boolean?) -> (),
	-- The GUI scale the icon is shown at (dayz look: the count box's size; no-op when unchanged).
	setScale: (self: ItemIcon, scale: number) -> (),
	-- Fades the whole icon (0 shown .. 1 gone), combined with setDimmed.
	setTransparency: (self: ItemIcon, transparency: number) -> (),
	destroy: (self: ItemIcon) -> (),
}

type Self = ItemIcon & {
	viewport: ViewportFrame,
	camera: Camera,
	-- The count: Minecraft's shadowed text, or the dayz look's box and its text.
	label: TextLabel?,
	shadow: TextLabel?,
	countBox: Frame?,
	countText: TextLabel?,
	model: Model?,
	block: boolean?,
	-- The durability or energy bar (made when first needed), its coloured part and the
	-- transparency of its track (dayz: dark or light).
	bar: Frame?,
	barFill: Frame?,
	barTrackAlpha: number,
	-- The item's picture (TexturePack.Icons), made when first needed.
	image: ImageLabel?,
	-- The picture's colour and transparency when not dimmed, as dimmed, and the fade.
	baseColour: Color3,
	dimColour: Color3,
	dimAlpha: number,
	fade: number,
	-- The GUI scale the count box is sized for (dayz).
	scale: number,
	-- The count's text shown ("" for none), and a firearm's or magazine's rounds (WeaponState
	-- .shownCount) with the data they were read from.
	shownText: string,
	rounds: number?,
	roundsData: Items.Data?,
}

-- An inventory slot: its button (the 18 x 18 hit area), its face, the icon and the hover outline.
export type Slot = {
	button: TextButton,
	icon: ItemIcon,
	hover: Frame,
	face: Frame,
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
	bottom right when above 1, Minecraft style, or in the `look` (see the header). With `scaled`
	(a Style.Dayz.scaled registry, dayz look) the icon follows its owner's GUI scale.
]]
function ItemIcon.new(parent: Instance, x: number, y: number, z: number?, look: Look?, scaled: Style.Scaled?): ItemIcon
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

	local label: TextLabel?, shadow: TextLabel?, countBox: Frame?, countText: TextLabel? = nil, nil, nil, nil
	local baseColour = Color3.new(1, 1, 1)
	if look == "dayz" then
		local Dayz = Style.Dayz
		baseColour = Dayz.Colour.ItemTint
		viewport.ImageColor3 = baseColour
		countBox, countText = Dayz.countBox(root, 3)
	else
		-- Minecraft draws the count with its right edge one pixel past the item, at the bottom.
		local text, textShadow = Style.shadowText(
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
		text.Visible = false
		textShadow.Visible = false
		label, shadow = text, textShadow
	end

	root.Parent = parent

	local self = {
		root = root,
		look = look,
		item = nil,
		count = 0,
		damage = 0,
		data = nil,
		viewport = viewport,
		camera = camera,
		label = label,
		shadow = shadow,
		countBox = countBox,
		countText = countText,
		model = nil,
		block = nil,
		bar = nil,
		barFill = nil,
		barTrackAlpha = 0,
		image = nil,
		baseColour = baseColour,
		dimColour = baseColour,
		dimAlpha = 0,
		fade = 0,
		scale = 1,
		shownText = "",
		rounds = nil,
		roundsData = nil,
	}
	live[self] = true
	local icon = (setmetatable(self, ItemIcon) :: any) :: ItemIcon
	if scaled and look == "dayz" then
		scaled:add(icon)
	end
	return icon
end

-- 1 - (1 - a)(1 - b): two transparencies over each other.
local function over(a: number, b: number): number
	return 1 - (1 - a) * (1 - b)
end

-- The picture's colour and transparency now (dimmed, faded).
local function paintPicture(self: Self)
	local transparency = over(self.dimAlpha, self.fade)
	self.viewport.ImageColor3 = self.dimColour
	self.viewport.ImageTransparency = transparency
	local image = self.image
	if image then
		image.ImageColor3 = self.dimColour
		image.ImageTransparency = transparency
	end
end

-- The count's and the bar's transparency now (faded).
local function paintFade(self: Self)
	local fade = self.fade
	local label, shadow = self.label, self.shadow
	if label and shadow then
		label.TextTransparency = fade
		shadow.TextTransparency = fade
	end
	local box, text = self.countBox, self.countText
	if box and text then
		box.BackgroundTransparency = over(Style.Dayz.Alpha.CountBox, fade)
		text.TextTransparency = fade
	end
	local bar, fill = self.bar, self.barFill
	if bar and fill then
		if self.look == "dayz" then
			bar.BackgroundTransparency = over(self.barTrackAlpha, fade)
		else
			bar.BackgroundTransparency = fade
		end
		fill.BackgroundTransparency = fade
	end
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
		paintFade(self)
	end
	assert(bar and fill, "durability bar")
	-- The top one of its two rows, `width` of 13 pixels.
	fill.Size = UDim2.fromScale(width / MenuLayout.BAR_WIDTH, 1 / MenuLayout.BAR_HEIGHT)
	fill.BackgroundColor3 = rgb
	bar.Visible = true
end

--[[
	The dayz look's bar: one pixel along the bottom (Theme.Size.BAR). A damaged durable item's
	durability left in its condition's colour on BarTrack, a canteen's sips in white on
	QuantityTrack (shown full too: a quantity), else an energy item's charge in the energy colour.
]]
local function setDayzBar(self: Self, damage: number, data: Items.Data?)
	local Dayz, Theme = Style.Dayz, Style.Theme
	local fraction, sips = MenuLayout.wear(self.item, damage)
	local fill: number? = nil
	local colour: Color3 = Dayz.Colour.Quantity
	local track = "BarTrack"
	if fraction and sips then
		fill = fraction
		track = "QuantityTrack"
	elseif fraction and damage > 0 then
		local condition = Theme.condition(fraction)
		fill = fraction
		if condition then
			colour = Dayz.Condition[condition.name]
		end
	else
		local width, energyColour = MenuLayout.energyItemBar(self.item, data)
		if width then
			fill = width / MenuLayout.BAR_WIDTH
			colour = Color3.fromRGB(energyColour[1], energyColour[2], energyColour[3])
		end
	end
	local bar, barFill = self.bar, self.barFill
	if fill == nil then
		if bar and bar.Visible then
			bar.Visible = false
		end
		return
	end
	if bar == nil or barFill == nil then
		local item, geometry = Style.ITEM, Theme.Size.BAR
		local newBar = Instance.new("Frame")
		newBar.Name = "Bar"
		newBar.BorderSizePixel = 0
		newBar.Position = UDim2.fromScale(geometry.x / item, geometry.y / item)
		newBar.Size = UDim2.fromScale(geometry.w / item, geometry.h / item)
		-- Above the model, under the count box.
		newBar.ZIndex = 2
		newBar.Parent = self.root
		local newFill = Instance.new("Frame")
		newFill.Name = "Fill"
		newFill.BorderSizePixel = 0
		newFill.ZIndex = 1
		newFill.Parent = newBar
		bar, barFill = newBar, newFill
		self.bar, self.barFill = newBar, newFill
	end
	assert(bar and barFill, "bar")
	bar.BackgroundColor3 = Dayz.Colour[track]
	self.barTrackAlpha = Dayz.Alpha[track]
	barFill.Size = UDim2.fromScale(fill :: number, 1)
	barFill.BackgroundColor3 = colour
	bar.Visible = true
	paintFade(self)
end

-- The dayz count box's size for `text` at the icon's scale, and its digits' weight (Light once
-- they are tall enough on screen: Theme.thin).
local function sizeCount(self: Self, text: string)
	local box, label = self.countBox, self.countText
	if box == nil or label == nil then
		return
	end
	local Theme = Style.Theme
	local height, size, digit = Theme.count(self.scale)
	box.Size = UDim2.fromOffset(Theme.countWidth(text, digit), height)
	label.TextSize = size
	label.FontFace = Style.Dayz.face(Theme.thin(size, self.scale))
end

--[[
	Shows `item` (nil = nothing) with `count` (drawn when above 1), a tool's wear `damage` (its
	durability bar when worn) and the stack's `data` (the energy bar of an item that holds energy;
	a firearm's or a magazine's rounds, drawn instead of the count: see the header). Cheap when
	nothing changed (data tables are values: a new one is new data).
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
		local picture = Items.icon(item)
		local image = self.image
		if picture then
			if image == nil then
				local label = Instance.new("ImageLabel")
				label.Name = "Icon"
				label.BackgroundTransparency = 1
				label.BorderSizePixel = 0
				label.Size = UDim2.fromScale(1, 1)
				label.ResampleMode = Enum.ResamplerMode.Pixelated
				label.ZIndex = 1
				label.ImageColor3 = self.viewport.ImageColor3
				label.ImageTransparency = self.viewport.ImageTransparency
				label.Parent = self.root
				image = label
				self.image = label
			end
			assert(image, "icon image")
			image.Image = picture
			image.Visible = true
			self.viewport.Visible = false
		elseif image and image.Visible then
			image.Visible = false
			self.viewport.Visible = true
		end
		if item and picture == nil then
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
	self.count = shown
	-- (A firearm's or a magazine's rounds instead of its count: read again only on new data.)
	local rounds: number? = nil
	if item and (Weapons.firearm(item) or Weapons.magazine(item)) then
		if itemChanged or data ~= self.roundsData then
			self.roundsData = data
			self.rounds = WeaponState.shownCount({ item = item, count = 1, data = data })
		end
		rounds = self.rounds
	else
		self.roundsData, self.rounds = nil, nil
	end
	local text = if rounds then tostring(rounds) elseif shown > 1 then tostring(shown) else ""
	if text ~= self.shownText then
		self.shownText = text
		local visible = text ~= ""
		local label, shadow, box, countText = self.label, self.shadow, self.countBox, self.countText
		if label and shadow then
			label.Text = text
			shadow.Text = text
			label.Visible = visible
			shadow.Visible = visible
		end
		if box and countText then
			countText.Text = text
			sizeCount(self, text)
			box.Visible = visible
		end
	end
	local wear = if item and damage and damage > 0 then damage else 0
	local held = if item then data else nil
	if wear ~= self.damage or held ~= self.data or itemChanged then
		self.damage = wear
		self.data = held
		if self.look == "dayz" then
			setDayzBar(self, wear, held)
		else
			setBar(self, wear, held)
		end
	end
end

-- Count colour (Minecraft draws an over-full drag preview in yellow); nil = white.
function ItemIcon.setCountColour(self: Self, colour: Color3?)
	local c = colour or Style.Colour.Text
	local label, shadow, countText = self.label, self.shadow, self.countText
	if label and shadow then
		if label.TextColor3 ~= c then
			label.TextColor3 = c
			shadow.TextColor3 = Style.shadowOf(c)
		end
	elseif countText and countText.TextColor3 ~= c then
		countText.TextColor3 = c
	end
end

--[[
	Draws the item greyed and faded (a locked recipe's result; `mild`: a locked skill), or as it is
	(in the dayz look: tinted).
]]
function ItemIcon.setDimmed(self: Self, dimmed: boolean, mild: boolean?)
	local colour = if not dimmed then self.baseColour elseif mild then MILD_COLOUR else DIMMED_COLOUR
	local alpha = if not dimmed then 0 elseif mild then MILD_TRANSPARENCY else DIMMED_TRANSPARENCY
	if colour ~= self.dimColour or alpha ~= self.dimAlpha then
		self.dimColour, self.dimAlpha = colour, alpha
		paintPicture(self)
	end
end

-- The GUI scale the icon is shown at: the dayz count box follows Theme.count (its size, its
-- digits' weight). Classic: nothing.
function ItemIcon.setScale(self: Self, scale: number)
	if self.look ~= "dayz" or scale == self.scale or scale ~= scale or scale <= 0 then
		return
	end
	self.scale = scale
	local text = self.countText
	if text then
		sizeCount(self, text.Text)
	end
end

-- Fades the whole icon (picture, count, bar): 0 shown .. 1 gone, over any dimming.
function ItemIcon.setTransparency(self: Self, transparency: number)
	local t = math.clamp(transparency, 0, 1)
	if t ~= self.fade then
		self.fade = t
		paintPicture(self)
		paintFade(self)
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
	An inventory slot in `parent` for the item at (x, y) (GUI pixels; the slot's 18 x 18 hit area is
	one pixel up and left of it), in the dayz look (see the header): the transparent button, its
	face (a `big` result slot's 24 x 24), the icon and the hover outline, all inside the button.
	With `scaled` the outline and the icon follow its owner's GUI scale.
]]
function ItemIcon.slot(parent: Instance, x: number, y: number, z: number?, big: boolean?, scaled: Style.Scaled?): Slot
	local Dayz, Theme = Style.Dayz, Style.Theme
	local button = Style.itemButton(parent, x, y, z)
	local size = if big then Theme.Size.BIG_FACE else Theme.Size.CELL
	local offset = if big then 1 - (Theme.Size.BIG_FACE - Style.ITEM) // 2 else 1
	local face = Dayz.slotFace(button, offset, offset, size, size, 1)
	local icon = ItemIcon.new(button, 1, 1, 5, "dayz", scaled)
	local hover = Instance.new("Frame")
	hover.Name = "Hover"
	hover.BackgroundTransparency = 1
	hover.BorderSizePixel = 0
	hover.Position = UDim2.fromOffset(offset, offset)
	hover.Size = UDim2.fromOffset(size, size)
	hover.ZIndex = 10
	hover.Visible = false
	Dayz.outline(hover, nil, nil, scaled)
	hover.Parent = button
	return { button = button, icon = icon, hover = hover, face = face }
end

-- Height of a tab above its panel's top edge, and its width (Minecraft's creative tabs).
ItemIcon.TAB_HEIGHT = 26
ItemIcon.TAB_WIDTH = 28

-- A creative tab: its button and every frame it draws (to show / hide and hit-test them).
export type Tab = { button: TextButton, frames: { GuiObject } }

--[[
	A creative or JEI tab showing `item`, at x on top of a panel whose top edge is at y = TAB_HEIGHT
	in `parent` (Minecraft's footprint and hit area), in the dayz look: an inactive tab is a dark
	Panel square with a hairline behind the panel (ZIndex 0); the active one is TopHeader grey,
	reaching down over the panel's edge (ZIndex 2) so it merges into it. A gamepad's selection is
	the Focus outline (Style.Dayz.focus).
]]
function ItemIcon.tab(parent: Instance, x: number, item: number?, active: boolean, scaled: Style.Scaled?): Tab
	local Dayz = Style.Dayz
	local width, top = ItemIcon.TAB_WIDTH, ItemIcon.TAB_HEIGHT
	local key = if active then "TopHeader" else "Panel"
	local root = if active
		then Style.frame(parent, x, 0, width, top + 4, Dayz.Colour[key], 2)
		else Style.frame(parent, x, 2, width, top + 2, Dayz.Colour[key], 0)
	root.Name = "Tab"
	root.BackgroundTransparency = Dayz.Alpha[key]
	root.Active = true
	if not active then
		Dayz.outline(root, Dayz.Colour.Hairline, Dayz.Alpha.Hairline, scaled)
	end
	local frames: { GuiObject } = { root }
	if item then
		ItemIcon.new(root, 6, if active then 7 else 6, 6, "dayz", scaled):set(item, 1)
	end
	local button = Instance.new("TextButton")
	button.Text = ""
	button.BackgroundTransparency = 1
	button.AutoButtonColor = false
	button.Size = UDim2.fromScale(1, 1)
	button.ZIndex = 8
	button.Parent = root
	Dayz.focus(button, scaled)
	return { button = button, frames = frames }
end

return ItemIcon
