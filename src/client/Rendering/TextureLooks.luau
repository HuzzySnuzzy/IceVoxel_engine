--!strict
--[[
	How blocks look with the texture pack (Shared/TexturePack, resolved per face by Blocks): the
	one place that decides which MaterialVariant, material and colour a part takes, which faces get
	Texture images, plants' sprites, glow lichen's image, the colour every face averages to on
	screen, and the looks of the far meshes. PartPool (terrain parts), ItemModels (items) and
	MeshOverlay (far meshes, through ChunkRenderer) all ask here, so near, far, plain and meshed
	terrain agree.

	Colour maths (pure: `toLinear`, `toSrgb`, `tintOf`, `shownOf`, `shortfall`, `averagePixels`).
	A part shows its texture times its Color; Roblox stores BasePart.Color in 8 bits, so a part's
	tint can only darken (it is clamped to 1), while Texture and Decal Color3 can also brighten.
	Averages are means in linear light, written as sRGB 0-255.
	  * Average of a texture: the pack's `Average`, else one measured in the game (`start`), else
	    unknown.
	  * Tint of a texture drawn on a block: its target is the drawn block's voxel colour (Tint
	    true), the named block's (Tint "Dirt") or none (Tint false). With a target and a known
	    average the tint is target / average per channel in linear light, so the texture averages
	    exactly the target; clamped to 1 on parts; with an unknown average it is the target itself
	    (a plain multiply); without a target, white.
	  * Too dark for a part (`shortfall`): when the clamped tint leaves a part's texture more than
	    CLAMP_VISIBLE (0-255, in some channel) darker than its target, an opaque block draws that
	    texture as images instead (near: over every face that showed it) and far away in its
	    plain colour, so it still takes its voxel colour (a birch log on a dark bark texture); a
	    see-through block keeps it darker (images would hide what is behind). One summary names
	    them all (`changed`, and at the end of `start`): a lighter texture keeps the variant.
	  * What a face averages to on screen (`averageOf`): the texture it draws times its tint
	    (clamped where a part draws it) when the average is known; else the target, or the voxel
	    colour for Tint false; the voxel colour for faces without a texture.

	Looks (per appearance, cached until the next generation):
	  near   full detail cubes: the parts take Blocks.variantTexture's MaterialVariant (the sides'
	         texture, else the top's when it is the only one; with Config.Textures.SideImages the
	         top's) on every face, in its texture's Material, Color = its clamped tint. The top,
	         when it draws another texture, gets a Texture image (StudsPerTile 3, Color3 = its
	         unclamped tint); the bottom too with Config.Textures.BottomFaces, the four sides with
	         SideImages; every face still showing the variant when it is too dark (see above).
	         Nothing filled: the BlockList material and colour, as without textures.
	  far    levels >= 1 not drawn plain: one variant and no images: the top's texture (tops
	         dominate from afar), else the sides'; the plain look when that one is too dark.
	  plain  merged far levels (MeshOverlay.plainLevel): SmoothPlastic in averageOf(top).
	  sprite plants with a filled Sprite texture (Config.Textures.Sprites): two crossed planes
	         carrying Decals (ChunkRenderer, PartPool, ItemModels), Color3 = the plant's target
	         (its soil's foliage colour for tinted plants, per tint like their boxes) / average.
	  front  glow lichen's, a ladder's, a rail's and a vine's plate: one Decal with its Front
	         texture on the face away from its support; the plate itself goes see-through.
	  shapes two rules for textured shaped blocks (`drawnBoxes`, `shapeLook`):
	         * Front replaces the boxes: with a Front image drawn, a shaped block builds only its
	           plate (the first box that does not glow, which carries the image) and its glowing
	           boxes, so a ladder's rails and rungs or a rail's iron bars give way to the picture
	           (Minecraft's single textured quad); without one, a plate that is fully see-through
	           (transparency 1: the ladder's carrier, there only for the image) is not built;
	         * shaped boxes take the near look: a shaped block whose entry has cube faces (All,
	           Sides, Top: the oak fence's planks, the moss carpet's moss block) draws its boxes
	           (glowing ones aside) in that texture's MaterialVariant, material and tint at full
	           detail, as a cube's near look does, without images (its Minecraft model uses the
	           texture); far boxes keep their own colours.
	  mesh   far meshes (`lookOf`, `lookInfo`): with Render.FarMaterials every face takes its
	         appearance's far look (material + variant + transparency + reflectance), vertex
	         colour = the far part's Color, or its BlockList material in its voxel colour; without
	         it every face is the plain look (SmoothPlastic) in its plain colour, like the plain
	         parts it replaces. One look per appearance, as a far part has one variant;
	         `lookInfo` also gives what the look's texture averages to, when known.

	Missing textures: a blank face draws the pack's missing texture when TexturePack.ShowMissing
	is on, otherwise what the block draws without it. A filled texture whose MaterialVariant is
	not in MaterialService (the generator was not run, or Rojo is older than 7.7) or whose id
	failed to load also draws the missing texture, with one warning naming it and the fix. When
	the missing texture itself cannot be drawn (its id failed) those faces draw the plain block.

	Generations: `generation()` bumps on every change of looks (`changed` fires with what changed):
	the Textures or Far Materials setting (`setStyle`), averages measured, ids that failed.
	`partGeneration()` follows the near and far part looks and `plainGeneration()` the plain
	colours, compared before and after, so PartPool keys and ChunkRenderer's restyles only redo
	what really changed; `meshes` says the far meshes' looks changed (MeshOverlay:setLooks).
	Item looks (near looks, item cube faces, sprites, lichen) are compared too: `itemsChanged`
	fires only when they changed (ItemModels.changed), so Far Materials alone rebuilds no item.

	Startup (`start`, before the first chunk is drawn): in the background, never blocking a frame,
	every filled image id (colour, normal, roughness and metalness maps) is preloaded once through
	a temporary Decal (Config.Textures.ValidateIds; a colour map that fails marks its texture
	failed, see above; any failure is named with its texture and map), then every texture without
	an Average is measured one at a time with EditableImage (Config.Textures.MeasureAverages:
	needs "Enable Mesh / Image APIs" and images the place's owner owns; every 8th texel, alpha
	weighted; the missing texture only when something draws it), and a block ready to paste into
	the pack is printed; textures that could not be measured are named, by cause. Until then
	looks are provisional (pack averages or a plain multiply); the generation bump restyles what
	is shown, paced like the Textures setting.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Blocks = require(Shared.Blocks)
local TexturePack = require(Shared.TexturePack)

local Options = Config.Textures
local STUDS = TexturePack.StudsPerTile
local MISSING = TexturePack.Missing
local PROTOTYPES = "IceVoxelTextures"
-- Texels between samples when measuring an average (each way: 64 x 64 samples of 512 x 512).
local SAMPLE_STEP = 8
-- Tries per image when the editable memory budget is full, and seconds between them.
local MEASURE_TRIES = 3
local MEASURE_RETRY = 1
-- Measuring stops after this many images in a row could not be loaded.
local MEASURE_FAILURES = 3
-- A tint channel above 1 by more than this (an 8-bit step) counts as clamped.
local CLAMP_SLACK = 1.004
-- A part showing its texture darker than its target by more than this (0-255, in some channel)
-- is too dark: smaller differences do not show.
local CLAMP_VISIBLE = 4
-- The maps of a texture that can carry an image id, and their names in messages.
local MAPS: { { key: string, label: string } } = {
	{ key = "Color", label = "colour" },
	{ key = "Normal", label = "normal" },
	{ key = "Roughness", label = "roughness" },
	{ key = "Metalness", label = "metalness" },
}
-- Every face key, with its face (near looks' images).
local FACES: { { face: Enum.NormalId, key: string } } = {
	{ face = Enum.NormalId.Top, key = "top" },
	{ face = Enum.NormalId.Bottom, key = "bottom" },
	{ face = Enum.NormalId.Front, key = "north" },
	{ face = Enum.NormalId.Back, key = "south" },
	{ face = Enum.NormalId.Right, key = "east" },
	{ face = Enum.NormalId.Left, key = "west" },
}

local packTextures = TexturePack.Textures
local appearances = Blocks.appearances

-- QuadMesher directions (0 +X, 1 -X, 2 +Y, 3 -Y, 4 +Z, 5 -Z) as TextureFaces keys.
local DIR_FACES: { [number]: string } = { [0] = "east", "west", "top", "bottom", "south", "north" }

-- The face of glow lichen's plate looking away from its support (NormalId Front is -Z).
local AWAY_FROM: { [string]: Enum.NormalId } = {
	Down = Enum.NormalId.Top,
	Up = Enum.NormalId.Bottom,
	North = Enum.NormalId.Back,
	South = Enum.NormalId.Front,
	West = Enum.NormalId.Right,
	East = Enum.NormalId.Left,
}

local SIDES: { { face: Enum.NormalId, key: string } } = {
	{ face = Enum.NormalId.Front, key = "north" },
	{ face = Enum.NormalId.Back, key = "south" },
	{ face = Enum.NormalId.Right, key = "east" },
	{ face = Enum.NormalId.Left, key = "west" },
}

-- An image on one face of a part: its texture and Color3 (unclamped).
export type Image = { face: Enum.NormalId, texture: string, color: Color3 }

-- A part's look: material, MaterialVariant ("" none) of `texture` (nil: the block's own material,
-- or for a far look whose texture is too dark, SmoothPlastic in the plain colour) and Color, plus
-- Texture images (near only).
export type PartLook = {
	texture: string?,
	material: Enum.Material,
	variant: string,
	color: Color3,
	images: { Image },
}

-- A plant's sprite: its texture and the Decals' Color3, per foliage tint like ChunkRenderer's
-- box colours (`tints[1]` untinted, `tints[t + 1]` on soil tint t); `tinted`: it changes with
-- the soil.
export type Sprite = { texture: string, tints: { Color3 }, tinted: boolean }

-- A far mesh look (one MeshPart each): MeshOverlay's lookInfo; `average`: what its texture
-- averages to at vertex colour white (sRGB 0..1; nil: unknown, or no texture).
export type Look = {
	id: number,
	material: Enum.Material,
	variant: string,
	transparency: number,
	reflectance: number,
	opaque: boolean,
	textured: boolean,
	average: { number }?,
}

-- What a change of looks touched (`changed`).
export type Changes = {
	-- Near and far part looks (sprites and lichen too): PartPool's texture generation.
	parts: boolean,
	-- Plain colours (merged far levels): PartPool's plain generation.
	plain: boolean,
	-- The far meshes' looks: MeshOverlay:setLooks.
	meshes: boolean,
	-- Item models' looks (`itemsChanged`, ItemModels.changed).
	items: boolean,
}

export type Connection = { Disconnect: (self: Connection) -> () }
export type Signal = { Connect: (self: Signal, fn: (changes: Changes) -> ()) -> Connection }

local TextureLooks = {}

-- The plain look's id in `lookOf` (SmoothPlastic, opaque, no variant).
TextureLooks.PLAIN = 0

--[[ Colour maths (pure) ]]

-- sRGB 0..1 -> linear light.
local function toLinear(c: number): number
	return if c <= 0.04045 then c / 12.92 else ((c + 0.055) / 1.055) ^ 2.4
end

-- Linear light -> sRGB 0..1 (values above 1 stay above 1: brightening tints).
local function toSrgb(l: number): number
	return if l <= 0.0031308 then l * 12.92 else 1.055 * l ^ (1 / 2.4) - 0.055
end

TextureLooks.toLinear = toLinear
TextureLooks.toSrgb = toSrgb

-- sRGB byte -> linear light.
local LINEAR: { number } = table.create(256)
for i = 0, 255 do
	LINEAR[i + 1] = toLinear(i / 255)
end

--[[
	The tint that makes a texture of `average` (0-255; nil: unknown) average `target` (0-255; nil:
	no target): { r, g, b } sRGB 0..1 and above, the same clamped to 1 (a part's Color), and whether
	clamping changed it.
]]
function TextureLooks.tintOf(target: { number }?, average: { number }?): ({ number }, { number }, boolean)
	if target == nil then
		return { 1, 1, 1 }, { 1, 1, 1 }, false
	end
	if average == nil then
		local plain = { target[1] / 255, target[2] / 255, target[3] / 255 }
		return plain, table.clone(plain), false
	end
	local tint, clamped = table.create(3), table.create(3)
	local didClamp = false
	for k = 1, 3 do
		local a = LINEAR[math.clamp(math.round(average[k]), 0, 255) + 1]
		local ratio = if a > 1e-6 then toLinear(target[k] / 255) / a else 1
		tint[k] = toSrgb(ratio)
		if ratio > CLAMP_SLACK then
			didClamp = true
		end
		clamped[k] = math.min(1, tint[k])
	end
	return tint, clamped, didClamp
end

-- What a texture of `average` (0-255) shows times `tint` (sRGB 0..1+): sRGB 0..1.
function TextureLooks.shownOf(average: { number }, tint: { number }): { number }
	local out = table.create(3)
	for k = 1, 3 do
		out[k] = math.clamp(toSrgb(toLinear(average[k] / 255) * toLinear(tint[k])), 0, 1)
	end
	return out
end

--[[
	How much darker (0-255, the largest channel) a texture of `average` tinted towards `target`
	shows on a part, whose tint stops at 1, than `target`: 0 when it reaches it (no target, an
	unknown average, or a texture light enough).
]]
function TextureLooks.shortfall(target: { number }?, average: { number }?): number
	if target == nil or average == nil then
		return 0
	end
	local _, clamped = TextureLooks.tintOf(target, average)
	local shown = TextureLooks.shownOf(average, clamped)
	local worst = 0
	for k = 1, 3 do
		worst = math.max(worst, target[k] - shown[k] * 255)
	end
	return worst
end

--[[
	The average colour of RGBA8 pixels (EditableImage:ReadPixelsBuffer: row-major from the top
	left) of a `width` x `height` image, sampling every `step`th texel each way: the mean in linear
	light weighted by alpha, as sRGB 0-255 (rounded), or nil when nothing sampled is opaque.
]]
function TextureLooks.averagePixels(pixels: buffer, width: number, height: number, step: number): { number }?
	local r, g, b, weight = 0, 0, 0, 0
	local readu8 = buffer.readu8
	for y = 0, height - 1, step do
		local row = y * width
		for x = 0, width - 1, step do
			local o = (row + x) * 4
			local a = readu8(pixels, o + 3) / 255
			if a > 0 then
				r += LINEAR[readu8(pixels, o) + 1] * a
				g += LINEAR[readu8(pixels, o + 1) + 1] * a
				b += LINEAR[readu8(pixels, o + 2) + 1] * a
				weight += a
			end
		end
	end
	if weight <= 0 then
		return nil
	end
	local function byte(l: number): number
		return math.clamp(math.round(toSrgb(l / weight) * 255), 0, 255)
	end
	return { byte(r), byte(g), byte(b) }
end

-- The header of the averages print.
TextureLooks.AVERAGES_HEADER = "[IceVoxel] Texture averages (paste into TexturePack.Textures[...].Average):"

--[[
	The print of measured averages: the header, then one line per texture (sorted by name) in the
	pack's syntax, to paste into that texture's entry:
	    Average = { 121, 85, 58 }, -- ["dirt"]
]]
function TextureLooks.formatAverages(averages: { [string]: { number } }): string
	local names: { string } = {}
	for name in averages do
		table.insert(names, name)
	end
	table.sort(names)
	local lines = { TextureLooks.AVERAGES_HEADER }
	for _, name in names do
		local a = averages[name]
		table.insert(lines, `\tAverage = \{ {a[1]}, {a[2]}, {a[3]} \}, -- ["{name}"]`)
	end
	return table.concat(lines, "\n")
end

--[[ State ]]

local style = { textures = Config.Render.Textures, farMaterials = Config.Render.FarMaterials }
-- Averages measured in the game, textures whose id failed to load.
local measured: { [string]: { number } } = {}
local failed: { [string]: boolean } = {}
-- Whether a texture's MaterialVariant is in MaterialService (looked up once).
local variantFound: { [string]: boolean } = {}
local warned: { [string]: boolean } = {}
local generations = { all = 0, parts = 0, plain = 0 }
local started = false
-- The last summary of textures too dark for their blocks (warned when it changes).
local darkReport = ""

-- A signal and the list of its listeners (called in the order they connected).
local function newSignal(): (Signal, { (changes: Changes) -> () })
	local listeners: { (changes: Changes) -> () } = {}
	local signal = {}
	function signal.Connect(_self: Signal, fn: (changes: Changes) -> ()): Connection
		table.insert(listeners, fn)
		local connection = {}
		function connection.Disconnect(_: Connection)
			local i = table.find(listeners, fn)
			if i then
				table.remove(listeners, i)
			end
		end
		return connection :: Connection
	end
	return (signal :: any) :: Signal, listeners
end

local changedSignal, listeners = newSignal()
local itemsSignal, itemListeners = newSignal()
-- Fires after every change of part, plain or far mesh looks, with what changed (the generations
-- are already bumped).
TextureLooks.changed = changedSignal
-- Fires after a change of item looks (`Changes.items`), after `changed`.
TextureLooks.itemsChanged = itemsSignal

local function warnOnce(key: string, message: string)
	if not warned[key] then
		warned[key] = true
		warn(message)
	end
end

local function materialOf(name: string): Enum.Material
	local ok, value = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	return if ok and value then value else Enum.Material.SmoothPlastic
end

local function rgb(c: { number }): Color3
	return Color3.new(c[1], c[2], c[3])
end

local function bytes(c: { number }): { number }
	return { c[1] / 255, c[2] / 255, c[3] / 255 }
end

-- The first block of each appearance (its name in messages, glow lichen's support).
local blockOf: { [number]: number } = {}
for id = 0, Blocks.count - 1 do
	local appearance = Blocks.get(id).appearance
	if appearance > 0 and blockOf[appearance] == nil then
		blockOf[appearance] = id
	end
end

-- Does any appearance draw a texture (else the Textures setting changes nothing)?
local used = false
for _, info in appearances do
	if info.textured then
		used = true
	end
end
TextureLooks.used = used

--[[ Textures ]]

-- The texture's average colour (0-255): the pack's, else measured, else nil.
function TextureLooks.averageKnown(name: string): { number }?
	local texture = packTextures[name]
	if texture == nil then
		return nil
	end
	return texture.Average or measured[name]
end

-- Did the texture's id fail to load?
function TextureLooks.isFailed(name: string): boolean
	return failed[name] == true
end

local function variantExists(name: string): boolean
	local known = variantFound[name]
	if known ~= nil then
		return known
	end
	local texture = packTextures[name]
	local ok, result = pcall(function()
		local MaterialService = game:GetService("MaterialService")
		return MaterialService:GetMaterialVariant(materialOf(texture.Material), Blocks.variantName(name))
	end)
	local found = ok and result ~= nil
	variantFound[name] = found
	if not found then
		warnOnce(
			`variant {name}`,
			`[IceVoxel] MaterialVariant {Blocks.variantName(name)} (texture "{name}", BaseMaterial {texture.Material}) is not in MaterialService: run "lune run tests/build_textures" and sync with Rojo 7.7 (rokit install, rojo plugin install); its faces draw the missing texture (or the plain block) instead`
		)
	end
	return found
end

-- The missing texture, when it can be drawn (as a variant: when its MaterialVariant exists).
local function missing(asVariant: boolean): string?
	if not Blocks.textureFilled(MISSING) or failed[MISSING] then
		return nil
	end
	if asVariant and not variantExists(MISSING) then
		return nil
	end
	return MISSING
end

--[[
	The texture actually drawn for `name` (as a part's MaterialVariant with `asVariant`, else as an
	image): itself; the missing texture for a blank one with ShowMissing, a failed one, or one
	whose variant is missing; nil for nothing (the block's own look).
]]
local function drawable(name: string?, asVariant: boolean): string?
	if name == nil then
		return nil
	end
	if not Blocks.textureFilled(name) then
		return if TexturePack.ShowMissing then missing(asVariant) else nil
	end
	if failed[name] or (asVariant and not variantExists(name)) then
		return missing(asVariant)
	end
	return name
end

-- The colour a texture is tinted towards on `info`'s blocks (0-255), nil for Tint false.
local function targetOf(info: Blocks.Appearance, texture: Blocks.Texture): { number }?
	local mode = texture.Tint
	if mode == false then
		return nil
	elseif type(mode) == "string" then
		return Blocks.get(Blocks.id[mode]).color
	end
	return info.color
end

-- A texture's tint on `info`'s blocks: unclamped (images) or clamped (parts).
local function paint(info: Blocks.Appearance, name: string, part: boolean): { number }
	local tint, clamped = TextureLooks.tintOf(targetOf(info, packTextures[name]), TextureLooks.averageKnown(name))
	return if part then clamped else tint
end

-- How much darker than its target texture `name` shows on a part of `info` (0-255, `shortfall`).
local function partShortfall(info: Blocks.Appearance, name: string): number
	return TextureLooks.shortfall(targetOf(info, packTextures[name]), TextureLooks.averageKnown(name))
end

-- Can the block's parts be covered by images (opaque: images would hide what is behind)?
local function coverable(info: Blocks.Appearance): boolean
	return info.kind == Blocks.KIND_OPAQUE and info.transparency == 0
end

--[[ Looks of an appearance ]]

-- A texture too dark for an appearance's parts: by how much (0-255) and what was done about it.
type Dark = { amount: number, near: boolean, far: boolean, darker: boolean }

type Resolved = {
	near: PartLook?,
	far: PartLook?,
	-- A shaped block's boxes' look (`shapeLook`), and the boxes built near / far and plain
	-- (`drawnBoxes`).
	shape: PartLook?,
	drawn: { number }?,
	drawnPlain: { number }?,
	-- Per face key: the texture drawn and whether a part (variant) draws it, for averageOf.
	faces: { [string]: { texture: string, part: boolean } },
	plain: { number },
	sprite: Sprite?,
	front: Image?,
	items: { Image }?,
	look: number,
	lookColour: { number },
	-- Textures too dark for its parts, by name.
	dark: { [string]: Dark },
	-- What part looks and item looks are made of (compared before and after a change).
	signature: string,
	itemSignature: string,
}

-- Notes that texture `name` falls `amount` short on an appearance's parts (`dark`).
local function noteDark(dark: { [string]: Dark }, name: string, amount: number, near: boolean, far: boolean)
	local entry = dark[name]
	if entry == nil then
		entry = { amount = amount, near = false, far = false, darker = false }
		dark[name] = entry
	end
	entry.amount = math.max(entry.amount, amount)
	entry.near = entry.near or near
	entry.far = entry.far or far
	entry.darker = entry.darker or not (near or far)
end

local cache: { [number]: Resolved } = {}

-- A cube that can carry a texture (not a shape, fluid or air) and has one, with textures on.
local function cubeTextures(info: Blocks.Appearance): Blocks.TextureFaces?
	if not style.textures or not info.textured or info.shape ~= nil then
		return nil
	end
	if info.kind ~= Blocks.KIND_OPAQUE and info.kind ~= Blocks.KIND_TRANSPARENT then
		return nil
	end
	return info.textures
end

local function partLook(info: Blocks.Appearance, name: string?): PartLook
	if name == nil then
		return {
			texture = nil,
			material = materialOf(info.material),
			variant = "",
			color = rgb(bytes(info.color)),
			images = {},
		}
	end
	return {
		texture = name,
		material = materialOf(packTextures[name].Material),
		variant = Blocks.variantName(name),
		color = rgb(paint(info, name, true)),
		images = {},
	}
end

local function nearOf(
	info: Blocks.Appearance,
	faces: { [string]: { texture: string, part: boolean } },
	dark: { [string]: Dark }
): PartLook?
	local textures = cubeTextures(info)
	if textures == nil then
		return nil
	end
	local wanted = Blocks.variantTexture(info)
	local chosen = drawable(wanted, true)
	local look = partLook(info, chosen)
	if chosen then
		for _, entry in FACES do
			faces[entry.key] = { texture = chosen, part = true }
		end
	end
	-- (A face of the variant's own texture shows the variant, or what replaces it.)
	local function image(face: Enum.NormalId, key: string)
		local name = (textures :: any)[key]
		local drawn = if name == wanted then nil else drawable(name, false)
		if drawn and drawn ~= chosen then
			table.insert(look.images, { face = face, texture = drawn, color = rgb(paint(info, drawn, false)) })
			faces[key] = { texture = drawn, part = false }
		end
	end
	image(Enum.NormalId.Top, "top")
	if Options.BottomFaces then
		image(Enum.NormalId.Bottom, "bottom")
	end
	if Options.SideImages then
		for _, side in SIDES do
			image(side.face, side.key)
		end
	end
	-- A variant too dark for the block's colour (a part's tint stops at 1): every face still
	-- showing it gets its texture as an image, which can brighten, so the block takes its colour.
	local short = if chosen then partShortfall(info, chosen) else 0
	if chosen and short > CLAMP_VISIBLE then
		if coverable(info) then
			local color = rgb(paint(info, chosen, false))
			for _, entry in FACES do
				if faces[entry.key].part then
					table.insert(look.images, { face = entry.face, texture = chosen, color = color })
					faces[entry.key] = { texture = chosen, part = false }
				end
			end
		end
		noteDark(dark, chosen, short, coverable(info), false)
	end
	if chosen == nil and #look.images == 0 then
		return nil
	end
	return look
end

-- `plain`: the plain colour, for a far texture too dark for the block (see the header).
local function farOf(info: Blocks.Appearance, plain: { number }, dark: { [string]: Dark }): PartLook?
	local textures = cubeTextures(info)
	if textures == nil then
		return nil
	end
	local name: string? = nil
	if Blocks.textureFilled(textures.top) then
		name = textures.top
	elseif Blocks.textureFilled(textures.north) then
		name = textures.north
	elseif TexturePack.ShowMissing and (textures.top ~= nil or textures.north ~= nil) then
		name = MISSING
	end
	local chosen = drawable(name, true)
	if chosen == nil then
		return nil
	end
	local short = partShortfall(info, chosen)
	if short > CLAMP_VISIBLE and coverable(info) then
		-- (Far away a tile is under a pixel: the colour matters more than the texture.)
		noteDark(dark, chosen, short, false, true)
		return {
			texture = nil,
			material = Enum.Material.SmoothPlastic,
			variant = "",
			color = rgb(plain),
			images = {},
		}
	elseif short > CLAMP_VISIBLE then
		noteDark(dark, chosen, short, false, false)
	end
	return partLook(info, chosen)
end

-- What a face draws averages to (sRGB 0..1).
local function faceAverage(info: Blocks.Appearance, drawn: { texture: string, part: boolean }?): { number }
	if drawn == nil then
		return bytes(info.color)
	end
	local name = drawn.texture
	local texture = packTextures[name]
	local average = TextureLooks.averageKnown(name)
	if average then
		return TextureLooks.shownOf(average, paint(info, name, drawn.part))
	end
	local target = targetOf(info, texture)
	return bytes(target or info.color)
end

local function spriteOf(info: Blocks.Appearance): Sprite?
	local name = info.sprite
	if name == nil or not style.textures or not Options.Sprites then
		return nil
	end
	local drawn = drawable(name, false)
	if drawn == nil then
		return nil
	end
	local texture = packTextures[drawn]
	local target = targetOf(info, texture)
	local average = TextureLooks.averageKnown(drawn)
	local tints: { Color3 } = { rgb((TextureLooks.tintOf(target, average))) }
	local tinted = info.tinted and target ~= nil
	if tinted then
		local base = target :: { number }
		for t, m in Blocks.FOLIAGE_TINTS do
			-- (As ChunkRenderer's box colours: each channel clamped to 255.)
			local foliage = {
				math.min(255, math.round(base[1] * m[1])),
				math.min(255, math.round(base[2] * m[2])),
				math.min(255, math.round(base[3] * m[3])),
			}
			tints[t + 1] = rgb((TextureLooks.tintOf(foliage, average)))
		end
	end
	return { texture = drawn, tints = tints, tinted = tinted }
end

--[[
	The look of a shaped block's boxes (see the header): its cube faces' variant texture (Blocks.
	variantTexture: the sides', else the top's), material and part tint, with textures on and a
	texture to draw (a blank one draws nothing, or the missing texture with ShowMissing); nil for
	cubes, for shapes without cube faces (plants' sprites, Front plates) and with nothing to draw.
]]
local function shapeOf(info: Blocks.Appearance): PartLook?
	local textures = info.textures
	if not style.textures or info.shape == nil or textures == nil then
		return nil
	end
	if textures.north == nil and textures.top == nil then
		return nil
	end
	local chosen = drawable(Blocks.variantTexture(info), true)
	return if chosen then partLook(info, chosen) else nil
end

local function frontOf(info: Blocks.Appearance): Image?
	local textures = info.textures
	if textures == nil or textures.front == nil or not style.textures or info.shape == nil then
		return nil
	end
	local drawn = drawable(textures.front, false)
	local block = blockOf[info.id]
	local support = if block then Blocks.get(block).support else nil
	local face = if support then AWAY_FROM[support] else nil
	if drawn == nil or face == nil then
		return nil
	end
	return { face = face, texture = drawn, color = rgb(paint(info, drawn, false)) }
end

--[[ Far mesh looks ]]

local lookList: { [number]: Look } = {
	[0] = {
		id = 0,
		material = Enum.Material.SmoothPlastic,
		variant = "",
		transparency = 0,
		reflectance = 0,
		opaque = true,
		textured = false,
	},
}
local lookIds: { [string]: number } = { [`{Enum.Material.SmoothPlastic.Name}||0|0`] = 0 }
local lookCount = 0

-- (`average`: the look's texture's, kept current: a measured average replaces an unknown one.)
local function lookId(
	material: Enum.Material,
	variant: string,
	transparency: number,
	reflectance: number,
	average: { number }?
): number
	local key = `{material.Name}|{variant}|{transparency}|{reflectance}`
	local id = lookIds[key]
	if id == nil then
		lookCount += 1
		id = lookCount
		lookIds[key] = id
		lookList[id] = {
			id = id,
			material = material,
			variant = variant,
			transparency = transparency,
			reflectance = reflectance,
			opaque = transparency == 0,
			textured = variant ~= "",
			average = average,
		}
	else
		lookList[id].average = average
	end
	return id :: number
end

-- An item cube's images: one per face that draws a texture (unclamped tints), nil for none.
local function itemFacesOf(info: Blocks.Appearance): { Image }?
	local textures = cubeTextures(info)
	if textures == nil then
		return nil
	end
	local list: { Image } = {}
	for _, entry in FACES do
		local drawn = drawable((textures :: any)[entry.key], false)
		if drawn then
			table.insert(list, { face = entry.face, texture = drawn, color = rgb(paint(info, drawn, false)) })
		end
	end
	return if #list > 0 then list else nil
end

local function imagesSignature(images: { Image }?): string
	if images == nil then
		return ""
	end
	local parts = {}
	for _, image in images do
		table.insert(parts, `{image.face.Name}={image.texture}:{image.color}`)
	end
	return table.concat(parts, ",")
end

local function signatureOf(look: PartLook?): string
	if look == nil then
		return "-"
	end
	return `{look.material.Name},{look.variant},{look.color},{imagesSignature(look.images)}`
end

local function resolve(appearance: number): Resolved
	local hit = cache[appearance]
	if hit then
		return hit
	end
	local info = appearances[appearance]
	local faces = {}
	local dark: { [string]: Dark } = {}
	local near = nearOf(info, faces, dark)
	local plain = faceAverage(info, faces.top)
	local far = farOf(info, plain, dark)
	local sprite = spriteOf(info)
	local front = frontOf(info)
	local items = itemFacesOf(info)
	local look, lookColour
	if not style.farMaterials then
		look, lookColour = TextureLooks.PLAIN, plain
	elseif far then
		local average = if far.texture then TextureLooks.averageKnown(far.texture) else nil
		look = lookId(far.material, far.variant, info.transparency, info.reflectance, average and bytes(average))
		lookColour = { far.color.R, far.color.G, far.color.B }
	else
		look = lookId(materialOf(info.material), "", info.transparency, info.reflectance)
		lookColour = bytes(info.color)
	end
	local spriteSignature = "-"
	if sprite then
		local tints = { sprite.texture }
		for _, c in sprite.tints do
			table.insert(tints, tostring(c))
		end
		spriteSignature = table.concat(tints, ",")
	end
	local frontSignature = if front then `{front.texture}:{front.color}` else "-"
	local shape = shapeOf(info)
	local shapeSignature = signatureOf(shape)
	local nearSignature = signatureOf(near)
	local drawn, drawnPlain = nil, nil
	if info.shape then
		drawn = TextureLooks.drawnBoxesOf(info.shape, info.transparency, front ~= nil)
		drawnPlain = TextureLooks.drawnBoxesOf(info.shape, info.transparency, false)
	end
	local resolved: Resolved = {
		near = near,
		far = far,
		shape = shape,
		drawn = drawn,
		drawnPlain = drawnPlain,
		faces = faces,
		plain = plain,
		sprite = sprite,
		front = front,
		items = items,
		look = look,
		lookColour = lookColour,
		dark = dark,
		signature = `{nearSignature};{signatureOf(far)};{spriteSignature};{frontSignature};{shapeSignature}`,
		itemSignature = `{nearSignature};{imagesSignature(items)};{spriteSignature};{frontSignature};{shapeSignature}`,
	}
	cache[appearance] = resolved
	return resolved
end

--[[ Public: looks ]]

-- The near (full detail) look of a cube appearance, nil for its plain BlockList look.
function TextureLooks.nearLook(appearance: number): PartLook?
	return resolve(appearance).near
end

-- The far (levels >= 1, not plain) look of a cube appearance, nil for its BlockList look.
function TextureLooks.farLook(appearance: number): PartLook?
	return resolve(appearance).far
end

-- The plain look's colour (merged far levels): what its top averages to.
function TextureLooks.plainColour(appearance: number): Color3
	return rgb(resolve(appearance).plain)
end

-- What face `face` ("top", "bottom", "north", "south", "east", "west", or a QuadMesher direction
-- 0..5) of the appearance's near look averages to on screen.
function TextureLooks.averageOf(appearance: number, face: string | number): Color3
	local key = if type(face) == "number" then DIR_FACES[face] else face
	local resolved = resolve(appearance)
	return rgb(faceAverage(appearances[appearance], resolved.faces[key]))
end

-- A plant's sprite (Config.Textures.Sprites, textures on, a drawable Sprite texture), else nil.
function TextureLooks.spriteOf(appearance: number): Sprite?
	return resolve(appearance).sprite
end

-- A Front plate's image (glow lichen, ladders, rails, vines): the face of the plate away from
-- its support, else nil.
function TextureLooks.frontOf(appearance: number): Image?
	return resolve(appearance).front
end

--[[
	The look a shaped appearance's boxes take at full detail (see the header: the fence post's
	planks), nil when they keep their own colours and materials.
]]
function TextureLooks.shapeLook(appearance: number): PartLook?
	return resolve(appearance).shape
end

-- The plate of a shape: its first box that does not glow (0: none). It carries a Front image.
function TextureLooks.plateBox(shape: { Blocks.ShapeBox }): number
	for i, box in shape do
		if not box.glow then
			return i
		end
	end
	return 0
end

--[[
	Which boxes of `shape` (indices, in order) are built (pure; `transparency` is the block's,
	for boxes without their own): with a Front image drawn (`front`), the plate and the glowing
	boxes only; without one, every box but those that do not glow and are fully see-through
	(transparency 1: they would show nothing). See the header.
]]
function TextureLooks.drawnBoxesOf(shape: { Blocks.ShapeBox }, transparency: number, front: boolean): { number }
	local plate = TextureLooks.plateBox(shape)
	local list: { number } = {}
	for i, box in shape do
		local keep = if front
			then i == plate or box.glow == true
			else box.glow == true or (box.transparency or transparency) < 1
		if keep then
			table.insert(list, i)
		end
	end
	return list
end

-- The boxes of a shaped appearance ChunkRenderer builds per cell (`drawnBoxesOf` with its Front
-- image, none on plain parts, which carry no images); nil for a cube.
function TextureLooks.drawnBoxes(appearance: number, plain: boolean?): { number }?
	local resolved = resolve(appearance)
	return if plain then resolved.drawnPlain else resolved.drawn
end

--[[
	The images of an item cube of the appearance, one per face that draws a texture (unclamped
	tints; faces without one keep the block's own material), or nil when none does.
]]
function TextureLooks.itemFaces(appearance: number): { Image }?
	return resolve(appearance).items
end

--[[
	Far meshes: the look id of face `face` (QuadMesher direction) of the appearance and its vertex
	colour (r, g, b 0..1); `plain`: the plain look and its colour instead (the plain remainder).
	Looks are per appearance (a far part has one variant for all faces).
]]
function TextureLooks.lookOf(appearance: number, _face: number, plain: boolean?): (number, number, number, number)
	local resolved = resolve(appearance)
	local c = if plain then resolved.plain else resolved.lookColour
	return if plain then TextureLooks.PLAIN else resolved.look, c[1], c[2], c[3]
end

-- The far mesh look `id` (lookOf).
function TextureLooks.lookInfo(id: number): Look
	return lookList[id] or lookList[TextureLooks.PLAIN]
end

-- The plain colour as r, g, b 0..1 (far meshes' plain remainder: MeshOverlay's plainOf; the same
-- for every face, like a plain part).
function TextureLooks.plainRgb(appearance: number, _face: number?): (number, number, number)
	local c = resolve(appearance).plain
	return c[1], c[2], c[3]
end

--[[ Generations and changes ]]

function TextureLooks.generation(): number
	return generations.all
end

function TextureLooks.partGeneration(): number
	return generations.parts
end

function TextureLooks.plainGeneration(): number
	return generations.plain
end

-- The Textures setting.
function TextureLooks.enabled(): boolean
	return style.textures
end

-- The Far Materials setting.
function TextureLooks.farMaterials(): boolean
	return style.farMaterials
end

type Snapshot = { parts: { [number]: string }, plain: { [number]: string }, items: { [number]: string } }

local function snapshot(): Snapshot
	local shot: Snapshot = { parts = {}, plain = {}, items = {} }
	for _, info in appearances do
		local resolved = resolve(info.id)
		shot.parts[info.id] = resolved.signature
		shot.items[info.id] = resolved.itemSignature
		local c = resolved.plain
		shot.plain[info.id] = `{math.round(c[1] * 255)},{math.round(c[2] * 255)},{math.round(c[3] * 255)}`
	end
	return shot
end

local function differs(a: { [number]: string }, b: { [number]: string }): boolean
	for id, value in a do
		if b[id] ~= value then
			return true
		end
	end
	return false
end

--[[
	Warns once with every texture too dark for the blocks it tints (see the header), whenever that
	list changes (an empty list says nothing).
]]
local function reportDark()
	local byTexture: { [string]: { { block: string, amount: number, note: string } } } = {}
	local names: { string } = {}
	for _, info in appearances do
		for name, entry in resolve(info.id).dark do
			if byTexture[name] == nil then
				byTexture[name] = {}
				table.insert(names, name)
			end
			local how = if entry.darker
				then "see-through: drawn darker"
				elseif entry.near and entry.far then ""
				elseif entry.near then "near"
				else "far"
			table.insert(byTexture[name], {
				block = Blocks.get(blockOf[info.id] or 0).name,
				amount = math.round(entry.amount),
				note = how,
			})
		end
	end
	if #names == 0 then
		return
	end
	table.sort(names)
	local lines = {
		"[IceVoxel] textures darker than the blocks they tint (by how much, 0-255): a part's tint can only darken, so these blocks draw them as tinted images up close and in their plain colour far away (more instances, no MaterialVariant). A lighter texture, ideally greyscale, keeps the variant:",
	}
	for _, name in names do
		local list = byTexture[name]
		table.sort(list, function(a, b)
			return if a.amount ~= b.amount then a.amount > b.amount else a.block < b.block
		end)
		local entries = {}
		for _, entry in list do
			local note = if entry.note ~= "" then ` ({entry.note})` else ""
			table.insert(entries, `{entry.block} {entry.amount}{note}`)
		end
		table.insert(lines, `\t"{name}": {table.concat(entries, ", ")}`)
	end
	local text = table.concat(lines, "\n")
	if text ~= darkReport then
		darkReport = text
		warn(text)
	end
end

-- Applies `edit` to the state, then bumps what changed and tells the listeners.
local function change(edit: () -> (), farToggled: boolean): Changes
	local before = snapshot()
	edit()
	table.clear(cache)
	local after = snapshot()
	local changes: Changes = {
		parts = differs(before.parts, after.parts),
		plain = differs(before.plain, after.plain),
		meshes = false,
		items = differs(before.items, after.items),
	}
	changes.meshes = farToggled or changes.plain or (style.farMaterials and changes.parts)
	if not (changes.parts or changes.plain or changes.meshes or changes.items) then
		return changes
	end
	generations.all += 1
	if changes.parts then
		generations.parts += 1
	end
	if changes.plain then
		generations.plain += 1
	end
	if changes.parts or changes.plain or changes.meshes then
		for _, fn in table.clone(listeners) do
			fn(changes)
		end
	end
	if changes.items then
		for _, fn in table.clone(itemListeners) do
			fn(changes)
		end
	end
	reportDark()
	return changes
end

--[[
	The Textures and Far Materials settings. Bumps the generations (and fires `changed`) when looks
	changed; returns what changed.
]]
function TextureLooks.setStyle(textures: boolean, farMaterials: boolean): Changes
	local farToggled = farMaterials ~= style.farMaterials
	if textures == style.textures and not farToggled then
		return { parts = false, plain = false, meshes = false, items = false }
	end
	return change(function()
		style.textures = textures
		style.farMaterials = farMaterials
	end, farToggled)
end

-- Averages measured in the game (texture name -> 0-255), as `start` applies them.
function TextureLooks.applyAverages(averages: { [string]: { number } }): Changes
	return change(function()
		for name, average in averages do
			measured[name] = average
		end
	end, false)
end

-- Textures whose id failed to load, as `start` applies them: drawn as the missing texture.
function TextureLooks.applyFailed(names: { string }): Changes
	return change(function()
		for _, name in names do
			failed[name] = true
		end
	end, false)
end

--[[ Instances ]]

-- The edit-time Texture prototype of a texture (tests/build_textures), if the place has it.
local function prototype(name: string): Texture?
	local folder = ReplicatedStorage:FindFirstChild(PROTOTYPES)
	local found = if folder then folder:FindFirstChild(Blocks.variantName(name)) else nil
	return if found and found:IsA("Texture") then found else nil
end

--[[
	A Texture image of texture `name` on `face`, tinted `color`, one tile per `studs` (a clone of
	its prototype, which keeps the normal / roughness / metalness maps scripts cannot set, else a
	new Texture with the colour map).
]]
function TextureLooks.newImage(name: string, face: Enum.NormalId, color: Color3, studs: number?): Texture
	local proto = prototype(name)
	local image: Texture
	if proto then
		image = proto:Clone()
	else
		image = Instance.new("Texture")
		image.TextureContent = Content.fromUri(packTextures[name].Color)
	end
	image.Name = Blocks.variantName(name)
	image.Face = face
	image.Color3 = color
	image.StudsPerTileU = studs or STUDS
	image.StudsPerTileV = studs or STUDS
	return image
end

-- A Decal of texture `name` on `face`, tinted `color` (sprites, glow lichen: one image per face).
function TextureLooks.newDecal(name: string, face: Enum.NormalId, color: Color3): Decal
	local decal = Instance.new("Decal")
	local proto = prototype(name)
	if proto then
		decal.TextureContent = proto.TextureContent
	else
		decal.TextureContent = Content.fromUri(packTextures[name].Color)
	end
	decal.Name = Blocks.variantName(name)
	decal.Face = face
	decal.Color3 = color
	return decal
end

--[[ Startup: validation and measuring ]]

-- Why an id that failed to load most likely did.
local DECAL_CAUSE = "Most likely it is a Decal id, not an Image id: copy the Image id (see the header of TexturePack)"

-- Who uses an image id: a texture and one of its maps (MAPS).
type IdUser = { name: string, map: string, label: string }

--[[
	The filled ids of `maps` of the textures some block uses (and the missing texture): the ids
	(sorted by texture name, then map; each once) and who uses each.
]]
local function filledIds(maps: { { key: string, label: string } }): ({ string }, { [string]: { IdUser } })
	local ids: { string } = {}
	local users: { [string]: { IdUser } } = {}
	local list = table.clone(Blocks.texturesUsed)
	if not table.find(list, MISSING) then
		table.insert(list, MISSING)
	end
	table.sort(list)
	for _, name in list do
		if Blocks.textureFilled(name) then
			for _, map in maps do
				local id = (packTextures[name] :: any)[map.key]
				if type(id) == "string" and id ~= "" then
					if users[id] == nil then
						users[id] = {}
						table.insert(ids, id)
					end
					table.insert(users[id], { name = name, map = map.key, label = map.label })
				end
			end
		end
	end
	return ids, users
end

local function number(id: string): string
	return string.match(id, "%d+$") or id
end

-- The warning for an id of `user` that failed to load; `missingWorks`: the missing texture loads.
local function failedMessage(user: IdUser, id: string, missingWorks: boolean): string
	if user.map ~= "Color" then
		return `[IceVoxel] the {user.label} map of texture "{user.name}" ({id}) failed to load, so the texture is drawn without it. {DECAL_CAUSE}`
	elseif user.name == MISSING then
		return `[IceVoxel] the missing texture ("{MISSING}", {id}) failed to load: until its id is fixed, ShowMissing and textures that fail to load show the plain block instead. {DECAL_CAUSE}`
	end
	local blocks = Blocks.textureUsers(user.name)
	local usedBy = if #blocks > 0 then `used by {table.concat(blocks, ", ")}` else "no block uses it"
	local instead = if missingWorks then "the missing texture" else "the plain block (the missing texture failed too)"
	return `[IceVoxel] texture "{user.name}" ({id}, {usedBy}) failed to load, so {instead} is drawn wherever it would be. {DECAL_CAUSE}`
end

--[[
	Preloads every filled image id (every map) once through temporary Decals and names each one
	that fails; textures whose colour map failed are marked failed.
]]
local function validate()
	local ContentProvider = game:GetService("ContentProvider")
	local ids, users = filledIds(MAPS)
	local byNumber: { [string]: string } = {}
	local decals: { Instance } = {}
	for _, id in ids do
		byNumber[number(id)] = id
		local decal = Instance.new("Decal")
		decal.TextureContent = Content.fromUri(id)
		table.insert(decals, decal)
	end
	local bad: { [string]: boolean } = {}
	pcall(function()
		ContentProvider:PreloadAsync(decals, function(contentId: string, status: Enum.AssetFetchStatus)
			local id = byNumber[number(contentId)]
			if id and status == Enum.AssetFetchStatus.Failure then
				bad[id] = true
			end
		end)
	end)
	for _, decal in decals do
		decal:Destroy()
	end
	local missingWorks = Blocks.textureFilled(MISSING) and not bad[packTextures[MISSING].Color] and not failed[MISSING]
	local failedNames: { string } = {}
	for _, id in ids do
		if bad[id] then
			for _, user in users[id] do
				warn(failedMessage(user, id, missingWorks))
				if user.map == "Color" then
					table.insert(failedNames, user.name)
				end
			end
		end
	end
	if #failedNames > 0 then
		TextureLooks.applyFailed(failedNames)
	end
end

--[[
	One image's average, or nil and why: "budget" (the editable memory budget is full),
	"transparent", or "refused" (Roblox would not open it) with its error.
]]
local function measureOne(id: string): ({ number }?, string?, string?)
	local AssetService = game:GetService("AssetService")
	local ok, result = pcall(function()
		return AssetService:CreateEditableImageAsync(Content.fromUri(id))
	end)
	if not ok then
		return nil, "refused", tostring(result)
	end
	local image = result :: EditableImage?
	if image == nil then
		return nil, "budget", nil
	end
	local size = image.Size
	local okRead, pixels = pcall(function()
		return image:ReadPixelsBuffer(Vector2.zero, size)
	end)
	image:Destroy()
	if not okRead then
		return nil, "refused", tostring(pixels)
	end
	local average = TextureLooks.averagePixels(pixels :: buffer, size.X, size.Y, SAMPLE_STEP)
	if average == nil then
		return nil, "transparent", nil
	end
	return average, nil, nil
end

-- Does any look draw the missing texture (ShowMissing, a failed id, a missing variant)?
local function drawsMissing(): boolean
	for _, info in appearances do
		local resolved = resolve(info.id)
		local images: { Image } = {}
		for _, look in { resolved.near, resolved.far } do
			if look then
				if look.texture == MISSING then
					return true
				end
				table.move(look.images, 1, #look.images, #images + 1, images)
			end
		end
		local items: { Image } = resolved.items or {}
		table.move(items, 1, #items, #images + 1, images)
		if resolved.front then
			table.insert(images, resolved.front)
		end
		for _, image in images do
			if image.texture == MISSING then
				return true
			end
		end
		if resolved.sprite and resolved.sprite.texture == MISSING then
			return true
		end
	end
	return false
end

local function quoted(names: { string }): string
	local list = {}
	for _, name in names do
		table.insert(list, `"{name}"`)
	end
	return table.concat(list, ", ")
end

--[[
	Measures every texture without an Average (the missing texture only when something draws it),
	one image at a time; prints and applies them, and names those that failed, by cause.
]]
local function measure()
	local ids, users = filledIds({ MAPS[1] })
	local missingWanted = drawsMissing()
	local averages: { [string]: { number } } = {}
	local found = false
	local inRow = 0
	local stopped = false
	local why: { [string]: { string } } = { refused = {}, budget = {}, transparent = {}, untried = {} }
	local detail: string? = nil
	for _, id in ids do
		local wanted: { string } = {}
		for _, user in users[id] do
			local name = user.name
			if packTextures[name].Average == nil and not failed[name] and (name ~= MISSING or missingWanted) then
				table.insert(wanted, name)
			end
		end
		if #wanted > 0 and stopped then
			table.move(wanted, 1, #wanted, #why.untried + 1, why.untried)
		elseif #wanted > 0 then
			local average, kind, err = nil, nil, nil
			for try = 1, MEASURE_TRIES do
				average, kind, err = measureOne(id)
				if kind ~= "budget" or try == MEASURE_TRIES then
					break
				end
				task.wait(MEASURE_RETRY)
			end
			if average then
				inRow = 0
				for _, name in wanted do
					averages[name] = average
					found = true
				end
			else
				inRow += 1
				local list = why[kind or "refused"]
				table.move(wanted, 1, #wanted, #list + 1, list)
				detail = detail or err
				stopped = inRow >= MEASURE_FAILURES
			end
			-- (One image at a time, a frame apart.)
			task.wait()
		end
	end
	if #why.refused > 0 then
		warn(
			`[IceVoxel] could not measure the average of {quoted(why.refused)}: Roblox would not open the image ({detail or "refused"}). Turn on "Enable Mesh / Image APIs" (Game Settings > Security) and use images the place's owner owns, or paste each texture's Average into TexturePack`
		)
	end
	if #why.budget > 0 then
		warn(
			`[IceVoxel] could not measure the average of {quoted(why.budget)}: the editable image memory budget was full (the far meshes share it). It is measured again next time, or paste each texture's Average into TexturePack`
		)
	end
	if #why.transparent > 0 then
		warn(
			`[IceVoxel] could not measure the average of {quoted(why.transparent)}: the image is fully transparent. Paste an Average into TexturePack`
		)
	end
	if #why.untried > 0 then
		warn(
			`[IceVoxel] measuring stopped after {MEASURE_FAILURES} images in a row failed; not measured: {quoted(
				why.untried
			)}`
		)
	end
	if found then
		print(TextureLooks.formatAverages(averages))
		TextureLooks.applyAverages(averages)
	end
end

--[[
	Starts checking ids and measuring averages in the background (see the header). Call once,
	before the first chunk is drawn; the looks are provisional until then.
]]
function TextureLooks.start()
	if started then
		return
	end
	started = true
	task.spawn(function()
		-- (Never in the first frame.)
		task.wait()
		if Options.ValidateIds then
			validate()
		end
		if Options.MeasureAverages then
			measure()
		end
		reportDark()
	end)
end

return TextureLooks
