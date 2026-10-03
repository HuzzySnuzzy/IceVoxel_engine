--!strict
--[[
	Recycles terrain parts.

	One template per (appearance, near/far) pair holds every property except size and position, so
	reusing a part only costs two property writes. Near parts (full detail chunks) collide and can be
	raycast; far parts (LOD chunks) do neither and skip shadows.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Blocks = require(Shared.Blocks)

export type PartPool = {
	templates: { [number]: BasePart },
	free: { [number]: { BasePart } },
	keyOf: { [BasePart]: number },
	freeCount: number,
	limit: number,

	acquire: (self: PartPool, appearance: number, far: boolean) -> BasePart,
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

local function makeTemplate(appearance: number, far: boolean): BasePart
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
	return part
end

local PartPool = {}
PartPool.__index = PartPool

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

function PartPool.acquire(self: PartPool, appearance: number, far: boolean): BasePart
	local key = appearance * 2 + (if far then 1 else 0)
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
		local created = makeTemplate(appearance, far)
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
