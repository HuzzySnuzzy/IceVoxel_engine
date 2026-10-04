--!strict
--[[
	3D models of items: inventory icons (ViewportFrames), dropped items and the item in hand.

	  block items  a cube with the block's look, as the terrain draws it (material, colour,
	               MaterialVariant texture, face images)
	  other items  their ItemList boxes (pixels, 1/16 of the size), in the item's colour and material

	`build(item, size)` returns a new Model that fits a cube of `size` studs centred on its pivot
	(CFrame.identity until moved with PivotTo). Its parts are anchored and touch, collide with and
	cast nothing. The caller owns the Model.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Items = require(Shared.Items)

local PartPool = require(script.Parent.PartPool)

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

local prototypes: { [string]: Model } = {}

local function prototype(item: number, size: number): Model
	local model = Instance.new("Model")
	model.Name = Items.displayName(item)
	local def = Items.get(item)
	if def and def.block then
		local part = PartPool.makeTemplate(Blocks.get(def.block).appearance)
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
	elseif def and def.model then
		local pixel = size / 16
		local color = Color3.fromRGB(def.color[1], def.color[2], def.color[3])
		for i, box in def.model do
			local part = Instance.new("Part")
			inert(part)
			part.Name = `Box{i}`
			part.TopSurface = Enum.SurfaceType.Smooth
			part.BottomSurface = Enum.SurfaceType.Smooth
			part.Size = Vector3.new(box.size[1], box.size[2], box.size[3]) * pixel
			part.CFrame = CFrame.new(Vector3.new(box.offset[1], box.offset[2], box.offset[3]) * pixel)
			part.Material = material(box.material or def.material)
			part.Color = if box.color then Color3.fromRGB(box.color[1], box.color[2], box.color[3]) else color
			part.Parent = model
			if i == 1 then
				model.PrimaryPart = part
			end
		end
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
	local cached = prototypes[key]
	if cached == nil then
		cached = prototype(item, size)
		prototypes[key] = cached
	end
	return cached:Clone()
end

-- Is the item drawn as a block (a cube), rather than from boxes?
function ItemModels.isBlock(item: number): boolean
	local def = Items.get(item)
	return def ~= nil and def.block ~= nil
end

return ItemModels
