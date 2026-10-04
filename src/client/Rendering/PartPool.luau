--!strict
--[[
	Recycles terrain parts.

	One template per (appearance, shape box, near/far) holds every property except size and
	position, so reusing a part only costs two property writes. Near parts (full detail chunks)
	collide and can be raycast; far parts (LOD chunks) do neither and skip shadows.

	Textures: a block with `texture` uses that MaterialVariant (it must exist in MaterialService with
	the block's material as BaseMaterial, otherwise the plain colour is used and a warning printed).
	`faces` images become Texture children of near templates, tiled once per block, so recycled parts
	keep them for free.

	"Plain" templates (far levels merged into meshes, see MeshOverlay) look like those meshes:
	SmoothPlastic in the block's colour, no textures, fluids opaque.

	Decorated blocks (appearances with `decor`: chests, crafting tables, furnaces): near templates
	carry the faces as SurfaceGuis (Rendering/BlockDecor), which every recycled part keeps. The
	mesher draws such blocks one part each, so the faces fit. Far and plain templates stay plain.

	Shaped blocks (BlockList `shape`: torches, lanterns) are drawn one part per shape box, box `i`
	from its own template (`acquire(appearance, far, plain, i)`; box 0 is the whole cube). They take
	the box's colour and material (glowing boxes are Neon), don't collide, can't be raycast (the
	camera ignores them) and cast no shadow.

	Light: the near template of a light source's glowing box (its cube for glowstone) carries one
	PointLight: range `light` x LIGHT_RANGE blocks (at most 60 studs), a warm colour from the block
	(`lightColor`), shadows on when Config.Render.Shadows is (so light stops at walls instead of
	shining through them). The parts of light sources cast no shadow themselves, or they would block
	their own light. Far and plain templates and item models get no light.
]]

local MaterialService = game:GetService("MaterialService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Blocks = require(Shared.Blocks)

local BlockDecor = require(script.Parent.BlockDecor)

-- A light's reach per light level, in blocks (Minecraft's light fades 1 level per block; Roblox's
-- falls off smoothly, so a little less looks alike), and the engine's longest range (studs).
local LIGHT_RANGE = 0.9
local MAX_LIGHT_RANGE = 60
-- PointLight brightness of a level 15 light (dimmer sources scale down with their level).
local LIGHT_BRIGHTNESS = 1.6
-- Light sources cast shadows (only when terrain shadows are on). Each shadowed light costs more,
-- but without shadows a torch lights the cave on the other side of the wall too.
local LIGHT_SHADOWS = true
-- Shape box templates per appearance (Blocks.MAX_SHAPE_BOXES, plus box 0: the cube).
local BOX_KEYS = Blocks.MAX_SHAPE_BOXES + 1

export type PartPool = {
	templates: { [number]: BasePart },
	free: { [number]: { BasePart } },
	keyOf: { [BasePart]: number },
	freeCount: number,
	limit: number,

	acquire: (self: PartPool, appearance: number, far: boolean, plain: boolean?, box: number?) -> BasePart,
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

local function colour(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local warned: { [string]: boolean } = {}

-- The box of a shaped appearance that carries its light: the first glowing one, else the first.
local function lightBox(info: Blocks.Appearance): number
	local shape = info.shape
	if shape == nil then
		return 0
	end
	for i, box in shape do
		if box.glow then
			return i
		end
	end
	return 1
end

-- Gives `part` the light of `info` (a light source).
local function addLight(part: BasePart, info: Blocks.Appearance)
	local light = Instance.new("PointLight")
	light.Name = "IceVoxelLight"
	light.Range = math.min(MAX_LIGHT_RANGE, info.light * LIGHT_RANGE * Config.BlockSize)
	light.Brightness = LIGHT_BRIGHTNESS * info.light / 15
	light.Color = colour(info.lightColor)
	light.Shadows = LIGHT_SHADOWS and Config.Render.Shadows
	light.Parent = part
end

--[[
	A template for `appearance` (`box` 0: the block's cube; i > 0: box i of its shape). `decor`:
	draw decorated faces; `lit`: carry the light of a light source.
]]
local function makeTemplate(
	appearance: number,
	far: boolean,
	plain: boolean,
	decor: boolean,
	box: number,
	lit: boolean
): BasePart
	local info = Blocks.appearances[appearance]
	local opaque = info.kind == Blocks.KIND_OPAQUE
	local shapeBox = if box > 0 and info.shape then info.shape[box] else nil
	local glowing = info.light > 0

	local part = Instance.new("Part")
	part.Name = "Voxel"
	part.Anchored = true
	part.Locked = true
	part.CanTouch = false
	part.CanCollide = info.solid and not far
	part.CanQuery = not far and info.kind ~= Blocks.KIND_FLUID and shapeBox == nil
	part.CastShadow = opaque
		and not glowing
		and shapeBox == nil
		and (if far then Config.Render.FarShadows else Config.Render.Shadows)
	part.EnableFluidForces = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = material(info.material)
	part.Color = colour(info.color)
	part.Transparency = info.transparency
	part.Reflectance = info.reflectance

	if shapeBox then
		part.Name = `Voxel{box}`
		part.Material = if shapeBox.glow then Enum.Material.Neon else material(shapeBox.material or info.material)
		part.Color = colour(shapeBox.color or info.color)
	end

	if plain then
		part.Material = Enum.Material.SmoothPlastic
		part.Transparency = 0
		part.Reflectance = 0
		return part
	end

	if Config.Render.Textures and shapeBox == nil then
		local texture = info.texture
		if texture then
			if MaterialService:GetMaterialVariant(part.Material, texture) then
				part.MaterialVariant = texture
				part.Color = colour(info.tint)
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
	if decor and info.decor and not far and shapeBox == nil then
		BlockDecor.applySurfaces(part, info.decor)
	end
	if lit and glowing and not far and box == lightBox(info) then
		addLight(part, info)
	end
	return part
end

local PartPool = {}
PartPool.__index = PartPool

--[[
	A new part with the look of `appearance` (full detail: textures and face images), e.g. for items;
	`box` > 0: that box of its shape (size and position are left to the caller). Decorated faces are
	left out (item models draw them with parts: BlockDecor.buildParts), and so are lights.
]]
function PartPool.makeTemplate(appearance: number, box: number?): BasePart
	return makeTemplate(appearance, false, false, false, box or 0, false)
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

-- A part of `appearance` (box `box` of its shape; 0 or nil: the cube) for a near / far / plain node.
function PartPool.acquire(self: PartPool, appearance: number, far: boolean, plain: boolean?, box: number?): BasePart
	local index = box or 0
	local key = (appearance * BOX_KEYS + index) * 4 + (if far then 1 else 0) + (if plain then 2 else 0)
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
		local created = makeTemplate(appearance, far, plain == true, true, index, true)
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
