--!strict
--[[
	Recycles terrain parts.

	One template per (appearance, near/far) pair holds every property except size and position, so
	reusing a part only costs two property writes. Near parts (full detail chunks) collide and can be
	raycast; far parts (LOD chunks) do neither and skip shadows.

	Textures: a block with `texture` uses that MaterialVariant (it must exist in MaterialService with
	the block's material as BaseMaterial, otherwise the plain colour is used and a warning printed).
	`faces` images become Texture children of near templates, tiled once per block, so recycled parts
	keep them for free.

	"Plain" templates (far levels merged into meshes, see MeshOverlay) look like those meshes:
	SmoothPlastic in the block's colour, no textures, fluids opaque.

	Decorated blocks (appearances with `decor`: chests, crafting tables, furnaces): near templates
	carry the faces as SurfaceGuis (Rendering/BlockDecor), which every recycled part keeps. The
	mesher draws such blocks one part each, so the faces fit. Far and plain templates stay plain.
]]

local MaterialService = game:GetService("MaterialService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Blocks = require(Shared.Blocks)

local BlockDecor = require(script.Parent.BlockDecor)

export type PartPool = {
	templates: { [number]: BasePart },
	free: { [number]: { BasePart } },
	keyOf: { [BasePart]: number },
	freeCount: number,
	limit: number,

	acquire: (self: PartPool, appearance: number, far: boolean, plain: boolean?) -> BasePart,
	release: (self: PartPool, part: BasePart) -> (),
}

local function material(name: string): Enum.Material
	local ok, value = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	if ok and value then
		return value
	end
	warn(`[IceVoxel] unknown material '{name}', using SmoothPlastic`)
	return Enum.Material.SmoothPlastic
end

local warned: { [string]: boolean } = {}

local function makeTemplate(appearance: number, far: boolean, plain: boolean, decor: boolean): BasePart
	local info = Blocks.appearances[appearance]
	local opaque = info.kind == Blocks.KIND_OPAQUE

	local part = Instance.new("Part")
	part.Name = "Voxel"
	part.Anchored = true
	part.Locked = true
	part.CanTouch = false
	part.CanCollide = info.solid and not far
	part.CanQuery = not far and info.kind ~= Blocks.KIND_FLUID
	part.CastShadow = opaque and (if far then Config.Render.FarShadows else Config.Render.Shadows)
	part.EnableFluidForces = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = material(info.material)
	part.Color = Color3.fromRGB(info.color[1], info.color[2], info.color[3])
	part.Transparency = info.transparency
	part.Reflectance = info.reflectance

	if plain then
		part.Material = Enum.Material.SmoothPlastic
		part.Transparency = 0
		part.Reflectance = 0
		return part
	end

	if Config.Render.Textures then
		local texture = info.texture
		if texture then
			if MaterialService:GetMaterialVariant(part.Material, texture) then
				part.MaterialVariant = texture
				part.Color = Color3.fromRGB(info.tint[1], info.tint[2], info.tint[3])
			elseif not warned[texture] then
				warned[texture] = true
				warn(
					`[IceVoxel] MaterialVariant '{texture}' with BaseMaterial {info.material} not found in MaterialService`
				)
			end
		end
		if info.faces and not far then
			for face, image in info.faces do
				local overlay = Instance.new("Texture")
				overlay.Face = (Enum.NormalId :: any)[face]
				overlay.Texture = image
				overlay.StudsPerTileU = Config.BlockSize
				overlay.StudsPerTileV = Config.BlockSize
				overlay.Parent = part
			end
		end
	end
	if decor and info.decor and not far then
		BlockDecor.applySurfaces(part, info.decor)
	end
	return part
end

local PartPool = {}
PartPool.__index = PartPool

--[[
	A new part with the look of `appearance` (full detail: textures and face images), e.g. for items.
	Decorated faces are left out: item models draw them with parts (BlockDecor.buildParts).
]]
function PartPool.makeTemplate(appearance: number): BasePart
	return makeTemplate(appearance, false, false, false)
end

function PartPool.new(limit: number): PartPool
	local self = {
		templates = {},
		free = {},
		keyOf = {},
		freeCount = 0,
		limit = limit,
	}
	return (setmetatable(self, PartPool) :: any) :: PartPool
end

function PartPool.acquire(self: PartPool, appearance: number, far: boolean, plain: boolean?): BasePart
	local key = appearance * 4 + (if far then 1 else 0) + (if plain then 2 else 0)
	local list = self.free[key]
	if list then
		local part = table.remove(list)
		if part then
			self.freeCount -= 1
			return part
		end
	end

	local template = self.templates[key] :: BasePart?
	if template == nil then
		local created = makeTemplate(appearance, far, plain == true, true)
		self.templates[key] = created
		template = created
	end
	local part = (template :: BasePart):Clone()
	self.keyOf[part] = key
	return part
end

-- The part must already be out of the workspace (e.g. its folder was unparented).
function PartPool.release(self: PartPool, part: BasePart)
	local key = self.keyOf[part]
	if key == nil or self.freeCount >= self.limit then
		self.keyOf[part] = nil
		part:Destroy()
		return
	end
	local list = self.free[key]
	if list == nil then
		list = {}
		self.free[key] = list
	end
	table.insert(list, part)
	self.freeCount += 1
end

return PartPool
