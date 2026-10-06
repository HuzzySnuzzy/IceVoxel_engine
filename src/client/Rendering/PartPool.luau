--!strict
--[[
	Recycles terrain parts.

	One template per (appearance, shape box, near/far) holds every property except size and
	position, so reusing a part only costs two property writes. Near parts (full detail chunks)
	collide and can be raycast; far parts (LOD chunks) do neither and skip shadows. No terrain part
	takes part in audio collisions (AudioCanCollide, set under pcall: it may be missing).

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
	the box's colour, material (glowing boxes are Neon) and transparency (a transmitter's glass is
	see-through, its frame is not), don't collide, can't be raycast (the camera ignores them) and
	cast no shadow.

	Light: the near template of a light source's glowing box (its cube for glowstone) carries one
	PointLight: range `light` x LIGHT_RANGE blocks (at most 60 studs), a warm colour from the block
	(`lightColor`), shadows on when shadows are (so light stops at walls instead of shining through
	them). A light inside a part that casts a shadow is blocked by that part, so one of the two has
	to give way:
	  - shaped boxes (torches, lanterns) cast no shadow: they are small, so their missing shadow
	    hardly shows, and their light keeps its shadows;
	  - full cubes (glowstone) do cast one, or a glowstone roof or wall would let the sun through
	    like glass; their light has no shadows instead, so it also reaches the far side of a wall
	    within its range. (Lights just outside each face would need up to six shadowed lights per
	    block, placed by its neighbours, which the shared templates can't do.)
	Far and plain templates and item models get no light. `light(part)` finds a part's PointLight
	without a search (ChunkRenderer switches lights off the moment a part is retired).

	Sparse lights (glow lichen, GreedyMesher.sparseLightLut): the mesher marks the one cell per box
	that carries the light, and every other cell's light box comes from a "dark" template, the same
	part without its PointLight (`acquire`'s `dark`), so lit and unlit lichen look alike. Their
	lights have no shadows: they are dim, short and many, and lichen grows only deep underground,
	so a glow reaching through a thin cave wall shows nowhere it shouldn't.

	Quarantine: a released part waits in `recent` until the next frame (`beginFrame`), so a part
	that was on screen at the start of a frame is never moved and shown elsewhere in that same frame
	(the engine treats that as a cluster transfer). `release` keeps at most `limit` parts; `trim`
	(called within a time budget) destroys parts beyond the limit (least recently used kinds first)
	and the parts of kinds not used for IDLE_SECONDS (an old biome after a teleport).

	Style (`setStyle`, from the settings menu; starts from Config.Render): shadows and far shadows
	change templates at once and every other part when it is next handed out or `refresh`ed
	(ChunkRenderer walks the live parts within its budget); a texture change starts a new set of
	template keys, so parts of the old look are never handed out again (ChunkRenderer rebuilds
	sections, and `trim` destroys the old ones).
]]

local MaterialService = game:GetService("MaterialService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Blocks = require(Shared.Blocks)
local GreedyMesher = require(Shared.Meshing.GreedyMesher)

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
-- Keys of one texture generation: (appearance * BOX_KEYS + box) * 8 + flags.
local TEXTURE_SPAN = (#Blocks.appearances + 1) * BOX_KEYS * 8
-- Kinds of parts not handed out for this long lose their pooled parts (seconds), and how often
-- `trim` looks for them and for parts beyond the limit.
local IDLE_SECONDS = 30
local TRIM_SCAN = 1

-- Shadow rules per key: never, near terrain (Shadows), far terrain (FarShadows).
local CAST_NEVER = 0
local CAST_NEAR = 1
local CAST_FAR = 2

export type Style = {
	shadows: boolean,
	farShadows: boolean,
	textures: boolean,
}

export type StyleChanges = {
	shadows: boolean,
	farShadows: boolean,
	textures: boolean,
}

export type PartPool = {
	templates: { [number]: BasePart },
	free: { [number]: { BasePart } },
	-- Released this frame (handed out from the next frame on).
	recent: { BasePart },
	keyOf: { [BasePart]: number },
	lightOf: { [BasePart]: PointLight },
	-- Shadow style generation each part was last set up for.
	shadowGenOf: { [BasePart]: number },
	-- Template keys whose parts carry a PointLight; their shadow rules.
	litKeys: { [number]: boolean },
	castRule: { [number]: number },
	sparseKeys: { [number]: boolean },
	-- Last time (os.clock) a part of each key was handed out.
	usedAt: { [number]: number },
	-- Pooled parts (free and recent).
	freeCount: number,
	limit: number,
	style: Style,
	shadowGen: number,
	textureGen: number,
	-- Parts taken out of the pool to be destroyed by `trim`.
	trimList: { BasePart },
	trimHead: number,
	nextScan: number,
	-- Counters: parts cloned, reused from the pool, destroyed.
	cloned: number,
	reused: number,
	destroyed: number,

	acquire: (
		self: PartPool,
		appearance: number,
		far: boolean,
		plain: boolean?,
		box: number?,
		dark: boolean?
	) -> BasePart,
	release: (self: PartPool, part: BasePart) -> boolean,
	room: (self: PartPool) -> number,
	hasLight: (self: PartPool, part: BasePart) -> boolean,
	light: (self: PartPool, part: BasePart) -> PointLight?,
	beginFrame: (self: PartPool) -> (),
	trim: (self: PartPool, deadline: number) -> number,
	trimming: (self: PartPool) -> number,
	setLimit: (self: PartPool, limit: number) -> (),
	setStyle: (self: PartPool, style: Style) -> StyleChanges,
	refresh: (self: PartPool, part: BasePart) -> (),
	isCurrent: (self: PartPool, part: BasePart) -> boolean,
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

-- Does any block use textures or face images (otherwise the Textures setting changes nothing)?
local texturesMatter = false
for _, appearance in Blocks.appearances do
	if appearance.texture or appearance.faces then
		texturesMatter = true
	end
end

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

local function isSparse(appearance: number): boolean
	return buffer.readu8(GreedyMesher.sparseLightLut, appearance) == 1
end

-- Shadows of a light inside a part casting `cast` (see the header).
local function lightShadows(style: Style, cast: boolean, sparse: boolean): boolean
	return LIGHT_SHADOWS and style.shadows and not cast and not sparse
end

-- Which shadow rule a template follows.
local function castRuleOf(info: Blocks.Appearance, far: boolean, shaped: boolean): number
	if info.kind ~= Blocks.KIND_OPAQUE or shaped then
		return CAST_NEVER
	end
	return if far then CAST_FAR else CAST_NEAR
end

local function casts(style: Style, rule: number): boolean
	return (rule == CAST_NEAR and style.shadows) or (rule == CAST_FAR and style.farShadows)
end

-- Gives `part` the light of `info` (a light source).
local function addLight(part: BasePart, info: Blocks.Appearance, style: Style)
	local light = Instance.new("PointLight")
	light.Name = "IceVoxelLight"
	light.Range = math.min(MAX_LIGHT_RANGE, info.light * LIGHT_RANGE * Config.BlockSize)
	light.Brightness = LIGHT_BRIGHTNESS * info.light / 15
	light.Color = colour(info.lightColor)
	-- Inside a part that casts a shadow (glowstone's cube) shadows would hide the light itself;
	-- sparse lights (glow lichen) go without, see above.
	light.Shadows = lightShadows(style, part.CastShadow, isSparse(info.id))
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
	lit: boolean,
	style: Style
): BasePart
	local info = Blocks.appearances[appearance]
	local shapeBox = if box > 0 and info.shape then info.shape[box] else nil
	local glowing = info.light > 0

	local part = Instance.new("Part")
	part.Name = "Voxel"
	part.Anchored = true
	part.Locked = true
	part.CanTouch = false
	part.CanCollide = info.solid and not far
	part.CanQuery = not far and info.kind ~= Blocks.KIND_FLUID and shapeBox == nil
	-- Light sources' full cubes too (glowstone blocks the sun; addLight gives way instead).
	part.CastShadow = casts(style, castRuleOf(info, far, shapeBox ~= nil))
	part.EnableFluidForces = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = material(info.material)
	part.Color = colour(info.color)
	part.Transparency = info.transparency
	part.Reflectance = info.reflectance
	-- Terrain takes no part in audio collisions (the audio counterpart of CastShadow).
	pcall(function()
		part.AudioCanCollide = false
	end)

	if shapeBox then
		part.Name = `Voxel{box}`
		part.Material = if shapeBox.glow then Enum.Material.Neon else material(shapeBox.material or info.material)
		part.Color = colour(shapeBox.color or info.color)
		part.Transparency = shapeBox.transparency or info.transparency
	end

	if plain then
		part.Material = Enum.Material.SmoothPlastic
		part.Transparency = 0
		part.Reflectance = 0
		return part
	end

	if style.textures and shapeBox == nil then
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
		addLight(part, info, style)
	end
	return part
end

local function configStyle(): Style
	return {
		shadows = Config.Render.Shadows,
		farShadows = Config.Render.FarShadows,
		textures = Config.Render.Textures,
	}
end

local function weak(): any
	return setmetatable({}, { __mode = "k" })
end

local PartPool = {}
PartPool.__index = PartPool

-- Does the Textures style change anything (some block has a texture or face images)? Tests may
-- set it to check the rebuild path.
PartPool.texturesMatter = texturesMatter

--[[
	A new part with the look of `appearance` (full detail: textures and face images), e.g. for items;
	`box` > 0: that box of its shape (size and position are left to the caller). Decorated faces are
	left out (item models draw them with parts: BlockDecor.buildParts), and so are lights.
]]
function PartPool.makeTemplate(appearance: number, box: number?): BasePart
	return makeTemplate(appearance, false, false, false, box or 0, false, configStyle())
end

function PartPool.new(limit: number): PartPool
	local self = {
		templates = {},
		free = {},
		recent = {},
		keyOf = weak(),
		lightOf = weak(),
		shadowGenOf = weak(),
		litKeys = {},
		castRule = {},
		sparseKeys = {},
		usedAt = {},
		freeCount = 0,
		limit = limit,
		style = configStyle(),
		shadowGen = 0,
		textureGen = 0,
		trimList = {},
		trimHead = 1,
		nextScan = 0,
		cloned = 0,
		reused = 0,
		destroyed = 0,
	}
	return (setmetatable(self, PartPool) :: any) :: PartPool
end

-- The box carrying each appearance's light (lightBox), filled as asked.
local lightBoxes: { [number]: number } = {}

--[[
	A part of `appearance` (box `box` of its shape; 0 or nil: the cube) for a near / far / plain
	node. `dark`: a sparse light's cell that does not carry the light (GreedyMesher), drawn without
	it (only the light's own box differs). The part is out of the workspace; its light (if any) is
	in whatever state it was left in.
]]
function PartPool.acquire(
	self: PartPool,
	appearance: number,
	far: boolean,
	plain: boolean?,
	box: number?,
	dark: boolean?
): BasePart
	local index = box or 0
	local unlit = false
	if dark and not far then
		local carrier = lightBoxes[appearance]
		if carrier == nil then
			carrier = lightBox(Blocks.appearances[appearance])
			lightBoxes[appearance] = carrier
		end
		unlit = index == carrier
	end
	local key = self.textureGen * TEXTURE_SPAN
		+ (appearance * BOX_KEYS + index) * 8
		+ (if far then 1 else 0)
		+ (if plain then 2 else 0)
		+ (if unlit then 4 else 0)
	self.usedAt[key] = os.clock()
	local list = self.free[key]
	if list then
		local part = table.remove(list)
		if part then
			self.freeCount -= 1
			self.reused += 1
			if self.shadowGenOf[part] ~= self.shadowGen then
				self:refresh(part)
			end
			return part
		end
	end

	local template = self.templates[key] :: BasePart?
	if template == nil then
		local info = Blocks.appearances[appearance]
		local shaped = index > 0 and info.shape ~= nil
		local created = makeTemplate(appearance, far, plain == true, true, index, not unlit, self.style)
		self.templates[key] = created
		self.castRule[key] = castRuleOf(info, far, shaped)
		if created:FindFirstChildOfClass("PointLight") then
			self.litKeys[key] = true
			self.sparseKeys[key] = isSparse(appearance)
		end
		template = created
	end
	local part = (template :: BasePart):Clone()
	self.cloned += 1
	self.keyOf[part] = key
	self.shadowGenOf[part] = self.shadowGen
	if self.litKeys[key] then
		local light = part:FindFirstChildOfClass("PointLight")
		if light then
			self.lightOf[part] = light
		end
	end
	return part
end

-- Does a part from `acquire` carry a light (for counting them: F3)?
function PartPool.hasLight(self: PartPool, part: BasePart): boolean
	local key = self.keyOf[part]
	return key ~= nil and self.litKeys[key] == true
end

-- The PointLight of a part from `acquire`, if it carries one.
function PartPool.light(self: PartPool, part: BasePart): PointLight?
	return self.lightOf[part]
end

--[[
	Takes a part back. It must already be out of the workspace (its folder unparented, or itself).
	Returns false when it was destroyed instead (pool full, or not one of ours). It is handed out
	again from the next frame on.
]]
function PartPool.release(self: PartPool, part: BasePart): boolean
	local key = self.keyOf[part]
	if key == nil or self.freeCount >= self.limit then
		self.keyOf[part] = nil
		self.destroyed += 1
		part:Destroy()
		return false
	end
	table.insert(self.recent, part)
	self.freeCount += 1
	return true
end

-- How many more parts the pool takes.
function PartPool.room(self: PartPool): number
	return math.max(0, self.limit - self.freeCount)
end

-- Start of a frame: last frame's releases may be handed out now.
function PartPool.beginFrame(self: PartPool)
	local recent = self.recent
	if #recent == 0 then
		return
	end
	local free = self.free
	local keyOf = self.keyOf
	for _, part in recent do
		local key = keyOf[part]
		if key then
			local list = free[key]
			if list == nil then
				list = {}
				free[key] = list
			end
			table.insert(list, part)
		end
	end
	table.clear(recent)
end

-- Moves `n` free parts of `key` to the trim list.
local function takeFree(self: PartPool, key: number, n: number)
	local list = self.free[key]
	if list == nil then
		return
	end
	for _ = 1, math.min(n, #list) do
		table.insert(self.trimList, table.remove(list) :: BasePart)
		self.freeCount -= 1
	end
	if #list == 0 then
		self.free[key] = nil
	end
end

-- Chooses what to destroy: parts beyond the limit, idle kinds, old texture generations.
local function scan(self: PartPool, now: number)
	local over = self.freeCount - self.limit
	local keys: { number } = {}
	for key, list in self.free do
		if #list > 0 then
			local idle = now - (self.usedAt[key] or 0) > IDLE_SECONDS
			if idle or key // TEXTURE_SPAN ~= self.textureGen then
				over -= #list
				takeFree(self, key, #list)
			else
				table.insert(keys, key)
			end
		end
	end
	if over > 0 then
		-- Least recently used kinds first.
		table.sort(keys, function(a, b)
			return (self.usedAt[a] or 0) < (self.usedAt[b] or 0)
		end)
		for _, key in keys do
			if over <= 0 then
				break
			end
			local list = self.free[key]
			if list then
				local n = math.min(over, #list)
				takeFree(self, key, n)
				over -= n
			end
		end
	end
end

--[[
	Destroys pooled parts beyond the limit or of idle kinds until os.clock() passes `deadline`.
	Returns how many it destroyed.
]]
function PartPool.trim(self: PartPool, deadline: number): number
	local now = os.clock()
	if now >= self.nextScan then
		self.nextScan = now + TRIM_SCAN
		scan(self, now)
	end
	local list = self.trimList
	local head = self.trimHead
	local count = 0
	while head <= #list and os.clock() < deadline do
		local part = list[head]
		head += 1
		self.keyOf[part] = nil
		part:Destroy()
		count += 1
	end
	if head > #list then
		table.clear(list)
		head = 1
	end
	self.trimHead = head
	self.destroyed += count
	return count
end

-- Parts waiting to be destroyed by `trim`.
function PartPool.trimming(self: PartPool): number
	return #self.trimList - self.trimHead + 1
end

-- A new pool size; `trim` destroys any excess over the next frames.
function PartPool.setLimit(self: PartPool, limit: number)
	self.limit = math.max(0, limit)
	self.nextScan = 0
end

-- Brings a part made under an older shadow style up to date (CastShadow and its light).
function PartPool.refresh(self: PartPool, part: BasePart)
	local key = self.keyOf[part]
	if key == nil then
		return
	end
	local rule = self.castRule[key] or CAST_NEVER
	local cast = casts(self.style, rule)
	if rule ~= CAST_NEVER then
		part.CastShadow = cast
	end
	local light = self.lightOf[part]
	if light then
		light.Shadows = lightShadows(self.style, cast, self.sparseKeys[key] == true)
	end
	self.shadowGenOf[part] = self.shadowGen
end

-- Is a part up to date with the current shadow style?
function PartPool.isCurrent(self: PartPool, part: BasePart): boolean
	return self.shadowGenOf[part] == self.shadowGen
end

--[[
	A new style. Shadow changes update the templates now and other parts as they are handed out or
	refreshed; a texture change (only when some block has textures) starts new template keys.
	Returns what changed.
]]
function PartPool.setStyle(self: PartPool, style: Style): StyleChanges
	local old = self.style
	local changes: StyleChanges = {
		shadows = style.shadows ~= old.shadows,
		farShadows = style.farShadows ~= old.farShadows,
		textures = PartPool.texturesMatter and style.textures ~= old.textures,
	}
	self.style = { shadows = style.shadows, farShadows = style.farShadows, textures = style.textures }
	if changes.shadows or changes.farShadows then
		self.shadowGen += 1
		for key, template in self.templates do
			local cast = casts(self.style, self.castRule[key] or CAST_NEVER)
			template.CastShadow = cast
			local light = template:FindFirstChildOfClass("PointLight")
			if light then
				light.Shadows = lightShadows(self.style, cast, self.sparseKeys[key] == true)
			end
		end
	end
	if changes.textures then
		self.textureGen += 1
		-- Old looks are never handed out again; trim destroys them.
		self.nextScan = 0
	end
	return changes
end

return PartPool
