--!strict
--[[
	3D models of items: inventory icons (ViewportFrames), dropped items and the item in hand.

	  block items  a cube with the block's look, as the terrain draws it (material, colour,
	               MaterialVariant texture, face images). Decorated blocks (chest, crafting table,
	               furnace) get their faces as thin raised slabs (Rendering/BlockDecor), since
	               ViewportFrames do not draw SurfaceGuis.
	  other items  their ItemList boxes (pixels, 1/16 of the size), in the item's colour and material,
	               turned by each box's `rotation`, as balls or cylinders by `shape`, and the whole
	               model turned by the item's `tilt` (tools and sticks lie diagonally).

	ItemList boxes are given as the icon shows them ("view space": x right, y up, z towards the
	viewer, angles anticlockwise). Icons look at a model's -Z face (the front, where a character
	faces), so view space is the model turned half a turn about Y.

	`build(item, size)` returns a new Model that fits a cube of `size` studs centred on its pivot
	(CFrame.identity until moved with PivotTo). Its parts are anchored and touch, collide with and
	cast nothing. The caller owns the Model.

	In a hand: `handSize` / `handPivot` place a model in a character's right hand (Player/HeldItems,
	the inventory's character preview). Tools and sticks are held like Minecraft's "handheld" items:
	upright (their tilt undone), held at the handle, pointing forward and up with the blade forward.
	Everything else keeps the block pose. `holdPivot` does the same for any pose (first person).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local Items = require(Shared.Items)

local BlockDecor = require(script.Parent.BlockDecor)
local PartPool = require(script.Parent.PartPool)

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
-- Non-tool items held like tools.
local HANDHELD_NAMES: { [string]: boolean } = { Stick = true }

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

local function blockPrototype(model: Model, block: number, size: number)
	local appearance = Blocks.get(block).appearance
	local part = PartPool.makeTemplate(appearance)
	inert(part)
	part.Name = "Block"
	part.Size = Vector3.one * size
	part.CFrame = CFrame.identity
	-- Face images are tiled once per block in the world; once per face here.
	for _, child in part:GetChildren() do
		if child:IsA("Texture") then
			child.StudsPerTileU = size
			child.StudsPerTileV = size
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
	if def and def.block then
		blockPrototype(model, def.block, size)
	elseif def and def.model then
		boxesPrototype(model, def, def.model, size)
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

-- Is the item drawn as a block (a cube), rather than from boxes?
function ItemModels.isBlock(item: number): boolean
	local def = Items.get(item)
	return def ~= nil and def.block ~= nil
end

-- Is the item held like a tool (Minecraft's "handheld" models: tools and sticks)?
function ItemModels.isHandheld(item: number): boolean
	local def = Items.get(item)
	return def ~= nil and def.block == nil and (def.tool ~= nil or HANDHELD_NAMES[def.name] == true)
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
	if def and def.model then
		bottom = math.huge
		for _, box in def.model do
			bottom = math.min(bottom, box.offset[2] - box.size[2] / 2)
		end
		bottom += GRIP_FROM_END
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

return ItemModels
