--!strict
--[[
	3D models of items: inventory icons (ViewportFrames), dropped items and the item in hand.

	  block items  a cube with the block's look. A textured block (Rendering/TextureLooks) is a cube
	               with a Texture image on every face that has a texture, sized so one tile spans
	               the face (a MaterialVariant tiles every 3 studs whatever the cube's size), each
	               in its face's tint (unclamped); faces without one keep the block's material and
	               colour (all six textured: white SmoothPlastic under them). Decorated blocks
	               (chest, crafting table, furnace) get their faces as thin raised slabs
	               (Rendering/BlockDecor), since ViewportFrames do not draw SurfaceGuis. Shaped
	               blocks (torches, lanterns, plants) are their shape's boxes, as the terrain draws
	               them (glowing boxes Neon, a Front plate its image, which then replaces the other
	               boxes: a ladder's picture; a fence post in its planks), centred on the shape's
	               outline; they count as items rather than blocks (`isBlock`), so icons show them
	               from the front and they drop like items. A block's `icon` boxes replace its shape
	               when it has them (a Mekanism transmitter: its core and two arms; a tall plant: its
	               lower half and the top's look, in one cell), each in its own colour, material and
	               transparency. A plant with a sprite (TextureLooks.spriteOf; a tall plant's top
	               half's, else its lower half's) is that sprite on a thin upright plane filling the
	               cube instead, both sides. Plants are drawn untinted (the Grass block's green) and
	               held like blocks, upright.
	  other items  their ItemList boxes (pixels, 1/16 of the size), in the item's colour and material,
	               turned by each box's `rotation`, as balls or cylinders by `shape`, and the whole
	               model turned by the item's `tilt` (tools and sticks lie diagonally).

	ItemList boxes are given as the icon shows them ("view space": x right, y up, z towards the
	viewer, angles anticlockwise). Icons look at a model's -Z face (the front, where a character
	faces), so view space is the model turned half a turn about Y.

	`build(item, size)` returns a new Model that fits a cube of `size` studs centred on its pivot
	(CFrame.identity until moved with PivotTo). Its parts are anchored and touch, collide with and
	cast nothing. The caller owns the Model. Models follow the Textures setting and TextureLooks'
	item looks: the cached prototypes are dropped whenever those change (`changed`: not for changes
	that leave items alone, such as Far Materials), so later builds take the new look, and whoever
	keeps models builds them again.

	In a hand: `handSize` / `handPivot` place a model in a character's right hand (Player/HeldItems,
	the inventory's character preview). Tools and sticks are held like Minecraft's "handheld" items:
	upright (their tilt undone), held at the handle, pointing forward and up with the blade forward.
	Torches, the Configurator and the melee weapons (Shared/Weapons: the bats, the wrench) are held
	the same way, by the stick or the grip. A firearm at rest is held at its grip, its barrel along
	the hand's forward a little down (Player/HeldItems poses guns with Player/WeaponPoses instead).
	Everything else keeps the block pose.
	`holdPivot` does the same for any pose (first person).

	Firearms (Shared/Weapons) are dressed and aimed by their WeaponList `look` (model pixels, the
	view space before the tilt: x along the barrel, y up):
	  build     `buildFirearm(item, lookKey, size)`: the gun's boxes plus what is mounted
	            (Shared/Weapons/WeaponState.lookKey: the player attribute Types.HELD_LOOK_ATTRIBUTE
	            for other players), each the item's own model at the gun's `scale`: the magazine
	            hanging below its `mag` point (centred on it), an optic standing on its `optic`
	            point, a muzzle device going on from the barrel's end (`muzzle`), the weapon light
	            centred on its `light` point with a SpotLight shining along the barrel from its lens
	            (its Beam: range in blocks, at most Roblox's 60 studs, cone angle, brightness; on
	            while the look says lit, without shadows: Player/HeldItems gives the local player's
	            its shadows). Cached per gun, look and size like `build`.
	  size      `firearmSize(item)`: every gun at FIREARM_STUDS studs a design pixel, so a pistol
	            and a rifle keep their proportions in a hand and in the first-person view.
	  pivots    `firearmPivot(item, size, pose, frame)` puts the gun's view space on `frame`'s axes
	            (right = the barrel, up = up) with its anchor at `frame`'s position: the grip for
	            "hand" (third person) and "hip" (first person, low right), the sight line above the
	            grip for "sights" (so the sight line lies on the view axis). `firearmPoint` gives
	            where the barrel ends (past a muzzle device: tracers and flashes start there) or the
	            light's lens for a placed gun.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local Weapons = require(Shared.Weapons)

local BlockDecor = require(script.Parent.BlockDecor)
local PartPool = require(script.Parent.PartPool)
local ShotRules = require(script.Parent.ShotRules)
local TextureLooks = require(script.Parent.TextureLooks)

local BLOCK = Config.BlockSize
-- View space -> model space.
local FLIP = CFrame.Angles(0, math.pi, 0)
-- Cylinders (whose axis is a part's X) turned so the axis is the view axis.
local CYLINDER_TURN = CFrame.Angles(0, math.pi / 2, 0)
-- Size (studs) of an item in a character's hand: a block is drawn 0.4 blocks wide; tools and sticks
-- (16 pixels) 0.6 blocks, about as long as the arm, as in Minecraft.
local HAND_SIZE = 0.4 * BLOCK
local HANDHELD_SIZE = 0.6 * BLOCK
-- Handheld items point this far above the forearm's forward direction (radians).
local HANDHELD_PITCH = math.rad(45)
-- Where the fist holds a handheld item: this many pixels above the bottom of its model.
local GRIP_FROM_END = 3.5
-- Non-tool items held like tools (by the end, pointing forward).
local HANDHELD_NAMES: { [string]: boolean } = { Stick = true, Torch = true, Configurator = true }
-- Studs a design pixel of a firearm spans in a hand and in the first-person view.
local FIREARM_STUDS = 0.075
-- Roblox's longest light (studs).
local MAX_LIGHT_RANGE = 60
-- A gun held at rest (`handPivot`: the inventory's preview) points this far down (radians).
local FIREARM_REST = math.rad(20)

local ItemModels = {}

local function material(name: string): Enum.Material
	local ok, value = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	return if ok and value then value else Enum.Material.SmoothPlastic
end

local function inert(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
end

-- An item's view space relative to its model's pivot (half a turn, then its tilt).
local function viewFrame(def: Items.ItemDef?): CFrame
	local tilt = if def then def.tilt else 0
	return if tilt ~= 0 then FLIP * CFrame.Angles(0, 0, math.rad(tilt)) else FLIP
end

local prototypes: { [string]: Model } = {}
-- Bumped with every change of item looks (`generation`).
local generation = 0
-- New item looks (the Textures setting, measured averages...): build the models again.
TextureLooks.itemsChanged:Connect(function()
	generation += 1
	for _, model in prototypes do
		model:Destroy()
	end
	table.clear(prototypes)
end)

--[[
	Fires after item models change look (TextureLooks.itemsChanged), once the cached prototypes are
	gone: models built before keep the old look, so whoever keeps models builds them again
	(Ui/ItemIcon's icons; keepers that check each frame compare `generation` instead).
]]
ItemModels.changed = TextureLooks.itemsChanged

-- The look generation models are built with now: a model built under an older one has an older
-- look (for keepers that check each frame instead of listening to `changed`).
function ItemModels.generation(): number
	return generation
end

-- The centre of a shape's outline (pixels from the cell's centre): shaped models are built
-- around it.
local function shapeCentre(block: number): Vector3
	local bounds = Blocks.get(block).bounds
	return Vector3.new(
		(bounds.min[1] + bounds.max[1]) / 2 - 8,
		(bounds.min[2] + bounds.max[2]) / 2 - 8,
		(bounds.min[3] + bounds.max[3]) / 2 - 8
	)
end

--[[
	A shaped block (torch, lantern): its boxes as the terrain draws them, centred on the shape.
	`shape` may be the block's `icon`, which starts with the shape's boxes and adds its own: every
	box takes its own colour, material and transparency over its template's.
]]
local function shapePrototype(model: Model, block: number, shape: { Blocks.ShapeBox }, size: number)
	local def = Blocks.get(block)
	local appearance = def.appearance
	local own = def.shape
	local boxes = if own then #own else 1
	local pixel = size / 16
	local centre = shapeCentre(block)
	-- The terrain's rules for textured shapes (TextureLooks): a Front image replaces the other
	-- boxes of the block's own shape, and cube faces' texture dresses its boxes.
	local drawn: { [number]: boolean }? = nil
	if shape == own then
		local set: { [number]: boolean } = {}
		local list: { number } = TextureLooks.drawnBoxes(appearance) or {}
		for _, index in list do
			set[index] = true
		end
		drawn = set
	end
	local dressed = TextureLooks.shapeLook(appearance) ~= nil
	for i, box in shape do
		if drawn and not drawn[i] then
			continue
		end
		-- (Boxes past the shape's take the first box's template: no textures, no light, and not
		-- its Front image either: a door's icon draws its upper half's boxes so.)
		local part = PartPool.makeTemplate(appearance, if i <= boxes then i else 1)
		if i > boxes then
			for _, child in part:GetChildren() do
				if child:IsA("Decal") then
					child:Destroy()
				end
			end
		end
		if box.glow or not dressed or i > boxes then
			part.Material = if box.glow then Enum.Material.Neon else material(box.material or def.material)
			local c = box.color or def.color
			part.Color = Color3.fromRGB(c[1], c[2], c[3])
		end
		-- (A box carrying an image, glow lichen's plate, shows only the image.)
		part.Transparency = if part:FindFirstChildOfClass("Decal") then 1 else box.transparency or def.transparency
		inert(part)
		part.Name = `Box{i}`
		part.Size = Vector3.new(box.size[1], box.size[2], box.size[3]) * pixel
		local r = box.rotation or { 0, 0, 0 }
		local offset = Vector3.new(box.offset[1], box.offset[2], box.offset[3]) - centre
		part.CFrame = CFrame.new(offset * pixel) * CFrame.Angles(math.rad(r[1]), math.rad(r[2]), math.rad(r[3]))
		part.Parent = model
		if model.PrimaryPart == nil then
			model.PrimaryPart = part
		end
	end
end

-- The sprite an item of a plant shows: a tall plant's top half's, else its own (nil: none).
local function itemSprite(block: number): TextureLooks.Sprite?
	local top = Blocks.plantTop(block)
	local sprite = if top then TextureLooks.spriteOf(Blocks.get(top).appearance) else nil
	return sprite or TextureLooks.spriteOf(Blocks.get(block).appearance)
end

-- A plant with a sprite: the sprite on a thin upright plane filling the cube, seen from both sides.
local function spritePrototype(model: Model, sprite: TextureLooks.Sprite, size: number)
	local part = Instance.new("Part")
	inert(part)
	part.Name = "Sprite"
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = Enum.Material.SmoothPlastic
	part.Transparency = 1
	part.Size = Vector3.new(size, size, PartPool.SPRITE_THICKNESS)
	part.CFrame = CFrame.identity
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		TextureLooks.newDecal(sprite.texture, face, sprite.tints[1]).Parent = part
	end
	part.Parent = model
	model.PrimaryPart = part
end

local function blockPrototype(model: Model, block: number, size: number)
	local appearance = Blocks.get(block).appearance
	-- Textured faces: one image each, one tile across the face (a variant would tile every 3
	-- studs whatever the cube's size); the rest keep the block's material and colour.
	local images = TextureLooks.itemFaces(appearance)
	local part = PartPool.makeTemplate(appearance, 0, images ~= nil)
	inert(part)
	part.Name = "Block"
	part.Size = Vector3.one * size
	part.CFrame = CFrame.identity
	if images then
		if #images == 6 then
			part.Material = Enum.Material.SmoothPlastic
			part.Color = Color3.new(1, 1, 1)
		end
		for _, image in images do
			TextureLooks.newImage(image.texture, image.face, image.color, size).Parent = part
		end
	end
	part.Parent = model
	model.PrimaryPart = part
	local decor = Blocks.appearances[appearance].decor
	if decor then
		for _, slab in BlockDecor.buildParts(decor, size, part) do
			slab.Parent = model
		end
	end
end

local function boxesPrototype(model: Model, def: Items.ItemDef, boxes: { Items.ModelBox }, size: number)
	local pixel = size / 16
	local color = Color3.fromRGB(def.color[1], def.color[2], def.color[3])
	local view = viewFrame(def)
	for i, box in boxes do
		local part = Instance.new("Part")
		inert(part)
		part.Name = `Box{i}`
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		local s = box.size
		local cframe = view * CFrame.new(box.offset[1] * pixel, box.offset[2] * pixel, box.offset[3] * pixel)
		if box.rotation then
			cframe *= CFrame.Angles(0, 0, math.rad(box.rotation))
		end
		-- The shape first: a ball forces its size to be the same on every axis.
		if box.shape == "Ball" then
			part.Shape = Enum.PartType.Ball
			part.Size = Vector3.one * math.min(s[1], s[2], s[3]) * pixel
		elseif box.shape == "Cylinder" then
			part.Shape = Enum.PartType.Cylinder
			part.Size = Vector3.new(s[3], s[2], s[1]) * pixel
			cframe *= CYLINDER_TURN
		else
			part.Size = Vector3.new(s[1], s[2], s[3]) * pixel
		end
		part.CFrame = cframe
		part.Material = material(box.material or def.material)
		part.Color = if box.color then Color3.fromRGB(box.color[1], box.color[2], box.color[3]) else color
		part.Parent = model
		if i == 1 then
			model.PrimaryPart = part
		end
	end
end

local function prototype(item: number, size: number): Model
	local model = Instance.new("Model")
	model.Name = Items.displayName(item)
	local def = Items.get(item)
	local blockDef = if def and def.block then Blocks.get(def.block) else nil
	local shape = if blockDef then blockDef.icon or blockDef.shape else nil
	local sprite = if def and def.block and blockDef and blockDef.plant then itemSprite(def.block) else nil
	if def and def.model then
		-- (Items of ItemList, also those that place a block: Mint Leaves look like leaves.)
		boxesPrototype(model, def, def.model, size)
	elseif sprite then
		spritePrototype(model, sprite, size)
	elseif def and def.block and shape then
		shapePrototype(model, def.block, shape, size)
	elseif def and def.block then
		blockPrototype(model, def.block, size)
	else
		-- Unknown item: a magenta cube.
		local part = Instance.new("Part")
		inert(part)
		part.Size = Vector3.one * size * 0.6
		part.Color = Color3.fromRGB(255, 0, 255)
		part.Parent = model
		model.PrimaryPart = part
	end
	model.WorldPivot = CFrame.identity
	return model
end

-- A new model of `item` fitting a cube of `size` studs, centred on its pivot.
function ItemModels.build(item: number, size: number): Model
	local key = `{item}:{size}`
	local cached: Model? = prototypes[key]
	if not cached then
		local built = prototype(item, size)
		prototypes[key] = built
		return built:Clone()
	end
	return cached:Clone()
end

-- Is the item drawn as a block (a cube), rather than from boxes (items, shaped blocks)?
function ItemModels.isBlock(item: number): boolean
	local def = Items.get(item)
	return def ~= nil and def.model == nil and def.block ~= nil and Blocks.get(def.block).shape == nil
end

-- Is the item held like a tool (Minecraft's "handheld" models: tools and sticks; and torches)?
function ItemModels.isHandheld(item: number): boolean
	local def = Items.get(item)
	return def ~= nil
		and ((def.block == nil and def.tool ~= nil) or HANDHELD_NAMES[def.name] == true or Weapons.melee(item) ~= nil)
end

-- Height (view space pixels) of the point a handheld item is held by: near the end of its handle.
local grips: { [number]: number } = {}
local function gripHeight(item: number): number
	local cached = grips[item]
	if cached then
		return cached
	end
	local def = Items.get(item)
	local bottom = 0
	local shape = if def and def.block then Blocks.get(def.block).shape else nil
	if def and def.model then
		bottom = math.huge
		for _, box in def.model do
			bottom = math.min(bottom, box.offset[2] - box.size[2] / 2)
		end
		bottom += GRIP_FROM_END
	elseif def and def.block and shape then
		-- Shaped blocks are built around their outline's centre.
		local bounds = Blocks.get(def.block).bounds
		bottom = (bounds.min[2] - bounds.max[2]) / 2 + GRIP_FROM_END
	end
	grips[item] = bottom
	return bottom
end

--[[
	The pivot that puts a model of `item` built at `size` upright (its tilt undone) in `pose`: the
	model's view space (x right, y up along the handle, z out of the icon) lands on `pose`'s axes,
	with the item's grip point (near the bottom of the handle) at `pose`'s position.
]]
function ItemModels.holdPivot(item: number, size: number, pose: CFrame): CFrame
	local grip = gripHeight(item) * size / 16
	return pose * CFrame.new(0, -grip, 0) * viewFrame(Items.get(item)):Inverse()
end

-- Size (studs) to build `item` at for a character's hand.
function ItemModels.handSize(item: number): number
	if Weapons.firearm(item) then
		return ItemModels.firearmSize(item)
	end
	return if ItemModels.isHandheld(item) then HANDHELD_SIZE else HAND_SIZE
end

--[[
	Where a model of `item` (built at `handSize(item)`) goes in `character`'s right hand, or nil
	without a hand. Blocks and other items: turned like a block held in Minecraft, a little past the
	fist. Tools and sticks: held at the handle, pointing forward and up from the forearm, blade side
	forward, flat side facing the body.
]]
function ItemModels.handPivot(item: number, character: Model): CFrame?
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if hand == nil or not hand:IsA("BasePart") then
		return nil
	end
	local attachment = hand:FindFirstChild("RightGripAttachment")
	local base = if attachment and attachment:IsA("Attachment")
		then attachment.WorldCFrame
		else hand.CFrame * CFrame.new(0, -hand.Size.Y / 2, 0)
	if Weapons.firearm(item) then
		-- A gun at rest: at the grip, along the hand's forward, its muzzle a little down.
		local frame = hand.CFrame
		local forward, up = frame.LookVector, frame.UpVector
		local c, s = math.cos(FIREARM_REST), math.sin(FIREARM_REST)
		local rest = CFrame.fromMatrix(base.Position, forward * c - up * s, up * c + forward * s)
		return ItemModels.firearmPivot(item, ItemModels.firearmSize(item), "hand", rest)
	end
	if not ItemModels.isHandheld(item) then
		return base * CFrame.new(0, 0, -HAND_SIZE * 0.3) * CFrame.Angles(0, math.rad(45), 0)
	end
	-- From the hand's own axes (the same for R6 and R15, whatever the attachment's orientation).
	local frame = hand.CFrame
	local forward, up = frame.LookVector, frame.UpVector
	local c, s = math.cos(HANDHELD_PITCH), math.sin(HANDHELD_PITCH)
	local along = forward * c + up * s
	-- The item's right: back and up, so its left (where blades are drawn) faces forward and down.
	local right = up * c - forward * s
	return ItemModels.holdPivot(item, HANDHELD_SIZE, CFrame.fromMatrix(base.Position, right, along))
end

--[[ Firearms (see the header) ]]

export type FirearmPose = "hand" | "hip" | "sights"

-- An item model's extent (design pixels, view space, boxes unrotated): min x, max x, min y, max y.
local extents: { [number]: { number } } = {}
local function extentOf(item: number): { number }
	local cached = extents[item]
	if cached then
		return cached
	end
	local def = Items.get(item)
	local out = { 0, 0, 0, 0 }
	if def and def.model and #def.model > 0 then
		out = { math.huge, -math.huge, math.huge, -math.huge }
		for _, box in def.model do
			out[1] = math.min(out[1], box.offset[1] - box.size[1] / 2)
			out[2] = math.max(out[2], box.offset[1] + box.size[1] / 2)
			out[3] = math.min(out[3], box.offset[2] - box.size[2] / 2)
			out[4] = math.max(out[4], box.offset[2] + box.size[2] / 2)
		end
	end
	extents[item] = out
	return out
end

local function pointOf(point: { number }?): Vector3?
	if point == nil then
		return nil
	end
	return Vector3.new(point[1], point[2], point[3] or 0)
end

-- A mounted part: its item, where its view space's origin goes (model pixels) and the name its
-- parts take ("Magazine", "Optic", "Muzzle", "Light").
type Mounted = { item: number, at: Vector3, name: string }

-- Where a gun's mounted parts go and where its barrel and light end (model pixels, view space).
type Dress = {
	parts: { Mounted },
	muzzle: Vector3,
	-- The sight line's height: through the optic's middle when one is mounted.
	sight: number,
	-- The light's lens (nil: no light), its beam and whether it is on.
	lens: Vector3?,
	beam: Weapons.Beam?,
	lit: boolean,
}

local dresses: { [string]: Dress } = {}
-- The last one asked for (asked every frame for the first-person gun: no key built then).
local lastSpec: Weapons.FirearmSpec? = nil
local lastKey = ""
local lastDress: Dress? = nil

-- How gun `spec` is dressed for look key `lookKey` (cached by both).
local function dressOf(spec: Weapons.FirearmSpec, lookKey: string): Dress
	local last = lastDress
	if last and spec == lastSpec and lookKey == lastKey then
		return last
	end
	local key = `{spec.item}:{lookKey}`
	local cached = dresses[key]
	if cached then
		lastSpec, lastKey, lastDress = spec, lookKey, cached
		return cached
	end
	local scale = spec.scale
	local look = spec.look
	local mag, optic, device, lamp, lit = ShotRules.lookParts(lookKey)
	local parts: { Mounted } = {}
	local muzzle = pointOf(look.muzzle) :: Vector3
	local lens: Vector3? = nil
	local beam: Weapons.Beam? = nil
	-- (Each part's own pixels are drawn at the gun's scale.)
	local magPoint = pointOf(look.mag)
	if mag ~= 0 and magPoint and Items.get(mag) then
		local e = extentOf(mag)
		local at = magPoint - Vector3.new((e[1] + e[2]) / 2, e[4], 0) * scale
		table.insert(parts, { item = mag, at = at, name = "Magazine" })
	end
	local sight = look.sight
	local opticPoint = pointOf(look.optic)
	if optic ~= 0 and opticPoint and Items.get(optic) then
		local e = extentOf(optic)
		local at = opticPoint - Vector3.new((e[1] + e[2]) / 2, e[3], 0) * scale
		table.insert(parts, { item = optic, at = at, name = "Optic" })
		sight = opticPoint.Y + (e[4] - e[3]) / 2 * scale
	end
	if device ~= 0 and Items.get(device) then
		local e = extentOf(device)
		local at = muzzle - Vector3.new(e[1], (e[3] + e[4]) / 2, 0) * scale
		table.insert(parts, { item = device, at = at, name = "Muzzle" })
		muzzle += Vector3.new((e[2] - e[1]) * scale, 0, 0)
	end
	local lightPoint = pointOf(look.light)
	local light = Weapons.attachment(lamp)
	if lamp ~= 0 and lightPoint and light and Items.get(lamp) then
		local e = extentOf(lamp)
		local centreX, centreY = (e[1] + e[2]) / 2, (e[3] + e[4]) / 2
		local at = lightPoint - Vector3.new(centreX, centreY, 0) * scale
		table.insert(parts, { item = lamp, at = at, name = "Light" })
		lens = lightPoint + Vector3.new((e[2] - centreX) * scale, 0, 0)
		beam = light.beam
	end
	local dress: Dress = {
		parts = table.freeze(parts),
		muzzle = muzzle,
		sight = sight,
		lens = lens,
		beam = beam,
		lit = lit and lens ~= nil,
	}
	dresses[key] = table.freeze(dress)
	lastSpec, lastKey, lastDress = spec, lookKey, dress
	return dress
end

-- Size (studs) to build firearm `item` at for a hand or the first-person view (see the header).
function ItemModels.firearmSize(item: number): number
	local spec = Weapons.firearm(item)
	return FIREARM_STUDS * 16 / (if spec then spec.scale else 1)
end

local function firearmPrototype(item: number, lookKey: string, size: number): Model
	local model = prototype(item, size)
	local spec = Weapons.firearm(item)
	if spec == nil then
		return model
	end
	local view = viewFrame(Items.get(item))
	local pixel = size / 16
	local dress = dressOf(spec, lookKey)
	for _, mounted in dress.parts do
		local part = prototype(mounted.item, size * spec.scale)
		local place = view * CFrame.new(mounted.at * pixel) * viewFrame(Items.get(mounted.item)):Inverse()
		for _, child in part:GetChildren() do
			if child:IsA("BasePart") then
				child.CFrame = place * child.CFrame
				child.Name = mounted.name
				child.Parent = model
			end
		end
		part:Destroy()
	end
	local lens = dress.lens
	local beam = dress.beam
	local body = model.PrimaryPart
	if lens and beam and body then
		-- The light shines along the barrel from the lens (a light in an Attachment shines along
		-- its front, -Z).
		local mount = Instance.new("Attachment")
		mount.Name = "LightMount"
		local origin = view * (lens * pixel)
		local barrel = view:VectorToWorldSpace(Vector3.xAxis)
		mount.CFrame = body.CFrame:Inverse() * CFrame.lookAt(origin, origin + barrel)
		mount.Parent = body
		local spot = Instance.new("SpotLight")
		spot.Name = "Beam"
		spot.Face = Enum.NormalId.Front
		spot.Range = math.min(beam.range * BLOCK, MAX_LIGHT_RANGE)
		spot.Angle = beam.angle
		spot.Brightness = beam.brightness
		spot.Color = Color3.fromRGB(255, 244, 214)
		spot.Shadows = false
		spot.Enabled = dress.lit
		spot.Parent = mount
	end
	return model
end

--[[
	A new model of firearm `item` dressed as look key `lookKey` says (see the header), fitting
	`size` like `build` (its pivot the view space's origin turned like `build`'s). Anything that
	is no firearm is `build`'s.
]]
function ItemModels.buildFirearm(item: number, lookKey: string, size: number): Model
	if Weapons.firearm(item) == nil then
		return ItemModels.build(item, size)
	end
	local key = `{item}:{size}:{lookKey}`
	local cached: Model? = prototypes[key]
	if not cached then
		local built = firearmPrototype(item, lookKey, size)
		prototypes[key] = built
		return built:Clone()
	end
	return cached:Clone()
end

--[[
	The pivot for a model of firearm `item` built at `size` (dressed as `lookKey`) so its view space
	lies on `frame`'s axes (x: the barrel, y: up) with the pose's anchor at `frame`'s position: the
	grip for "hand" and "hip", the sight line above the grip for "sights" (through a mounted
	optic's middle: the optic's parts are named "Optic", for the first-person view to hide in the
	sights).
]]
function ItemModels.firearmPivot(item: number, size: number, pose: FirearmPose, frame: CFrame, lookKey: string?): CFrame
	local spec = Weapons.firearm(item)
	local pixel = size / 16
	local ax, ay = 0, 0
	if spec then
		local grip = spec.look.grip
		ax, ay = grip[1], grip[2]
		if pose == "sights" then
			ay = if lookKey then dressOf(spec, lookKey).sight else spec.look.sight
		end
	end
	return frame * CFrame.new(-ax * pixel, -ay * pixel, 0) * viewFrame(Items.get(item)):Inverse()
end

--[[
	Where the barrel of firearm `item` (built at `size`, dressed as `lookKey`, its model at
	`pivot`) ends ("muzzle": past a muzzle device), or its light's lens ("lens"; the muzzle when
	it has none), in `pivot`'s space.
]]
function ItemModels.firearmPoint(
	item: number,
	lookKey: string,
	size: number,
	pivot: CFrame,
	which: "muzzle" | "lens"
): Vector3
	local spec = Weapons.firearm(item)
	if spec == nil then
		return pivot.Position
	end
	local dress = dressOf(spec, lookKey)
	local point = if which == "lens" then dress.lens or dress.muzzle else dress.muzzle
	return (pivot * viewFrame(Items.get(item))) * (point * (size / 16))
end

return ItemModels
