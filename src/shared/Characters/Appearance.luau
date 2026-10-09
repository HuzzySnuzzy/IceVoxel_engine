--!strict
--[[
	A character's look (Shared/Characters): the R15 avatar it is drawn as, made in the title
	screen's editor from the player's own Roblox avatar (client Ui/AvatarEditor) and applied when
	it spawns (`Player:LoadCharacterWithHumanoidDescriptionAsync`, server Players/CharacterLooks
	turns this into a HumanoidDescription). Pure, so the server checks it and the specs run it.

	  colors    six 0xRRGGBB body colours in HumanoidDescription's order: Head, Torso, LeftArm,
	            RightArm, LeftLeg, RightLeg (`<part>Color`).
	  scales    height, width, depth, head, bodyType, proportion (HumanoidDescription's
	            HeightScale ... ProportionScale), always within Config.Characters.Scales (Roblox's
	            avatar rules: height 0.90-1.05, width and depth 0.70-1, head 0.95-1, body type and
	            proportion 0-1; body type and proportion 0 are the classic blocky shape).
	  assets    a snapshot of the user's own avatar taken when the character was made (Terraria:
	            the look stays when the Roblox avatar changes), each { kind, id, worn, layered,
	            order, puffiness }. Kinds (KIND):
	              1..6    body parts Head, Torso, LeftArm, RightArm, LeftLeg, RightLeg (not worn:
	                      the plain blocky part)
	              7       the Face
	              8, 9, 10  classic Shirt, Pants and GraphicTShirt
	              11..18  the Idle, Walk, Run, Jump, Fall, Climb, Swim and Mood animations
	              33..63  accessories: ACCESSORY + Enum.AccessoryType's value (33 Hat, 34 Hair,
	                      35 Face, ... 51 Eyelash); `layered` (layered clothing), `order` and
	                      `puffiness` are HumanoidDescription:SetAccessories' Order and Puffiness
	            At most one worn of each kind below ACCESSORY (one face, one shirt...).
	  Bytes     u8 VERSION, 6 x (u8 r, g, b), 6 x u16 scale x 10000, u8 n (at most MAX_ASSETS),
	            n x (u8 kind, f64 asset id (whole, 1..2^53), u8 flags (bit 0 worn, bit 1 layered),
	            u8 order, u8 puffiness x 100). 32 bytes and 12 an asset: 150-600 typically.
	            Another version, an unknown kind or flag, a bad id or bytes left over is refused
	            (nil). Server Save/CharacterCodec keeps them in the record, Net/CharacterSync
	            sends them.
	  sanitize  what the server keeps of an edit from a client: its colours and its scales
	            (clamped), and the server's own snapshot with each asset's `worn` taken from the
	            edit when the edit names the same kind and id. A client can switch the user's own
	            things on and off, never name an asset of its own.
	  presets   Classic (blocky parts, body type and proportion 0, Roblox's classic yellow head and
	            arms, blue torso and green legs) and Natural (body type 1, proportion 0.5), applied
	            over a look (`preset`); SKIN_TONES are the editor's twelve swatches.
]]

local Config = require(script.Parent.Parent.Config)

export type Asset = {
	kind: number,
	id: number,
	worn: boolean,
	layered: boolean,
	order: number,
	puffiness: number,
}

export type Scales = {
	height: number,
	width: number,
	depth: number,
	head: number,
	bodyType: number,
	proportion: number,
}

export type Appearance = {
	colors: { number },
	scales: Scales,
	assets: { Asset },
}

local Appearance = {}

Appearance.VERSION = 1
Appearance.MAX_ASSETS = 64
-- The body parts, in colour order (and kinds 1..6), and the scales in byte order.
Appearance.PARTS = table.freeze({ "Head", "Torso", "LeftArm", "RightArm", "LeftLeg", "RightLeg" })
Appearance.SCALES = table.freeze({ "height", "width", "depth", "head", "bodyType", "proportion" })
-- HumanoidDescription's property for each scale.
Appearance.SCALE_PROPERTY = table.freeze({
	height = "HeightScale",
	width = "WidthScale",
	depth = "DepthScale",
	head = "HeadScale",
	bodyType = "BodyTypeScale",
	proportion = "ProportionScale",
} :: { [string]: string })

-- Asset kinds (see the header).
Appearance.KIND = table.freeze({
	Head = 1,
	Torso = 2,
	LeftArm = 3,
	RightArm = 4,
	LeftLeg = 5,
	RightLeg = 6,
	Face = 7,
	Shirt = 8,
	Pants = 9,
	GraphicTShirt = 10,
	IdleAnimation = 11,
	WalkAnimation = 12,
	RunAnimation = 13,
	JumpAnimation = 14,
	FallAnimation = 15,
	ClimbAnimation = 16,
	SwimAnimation = 17,
	MoodAnimation = 18,
})
-- Accessory kinds are ACCESSORY + Enum.AccessoryType's value (1 Hat .. 19 Eyelash; up to 31).
Appearance.ACCESSORY = 32
-- HumanoidDescription's property for each kind below ACCESSORY (kind -> name).
Appearance.PROPERTY = table.freeze((function(): { [number]: string }
	local names: { [number]: string } = {}
	for name: string, kind: number in Appearance.KIND :: { [string]: number } do
		names[kind] = name
	end
	return names
end)())

local SCALE = 10000
local SAFE_ID = 2 ^ 53

-- Is `kind` an asset kind (a property's or an accessory's)?
function Appearance.isKind(kind: number): boolean
	return (kind >= 1 and kind <= 18) or (kind > Appearance.ACCESSORY and kind <= Appearance.ACCESSORY + 31)
end

function Appearance.isAccessory(kind: number): boolean
	return kind > Appearance.ACCESSORY and kind <= Appearance.ACCESSORY + 31
end

-- Enum.AccessoryType's value of an accessory kind (nil for the others).
function Appearance.accessoryType(kind: number): number?
	return if Appearance.isAccessory(kind) then kind - Appearance.ACCESSORY else nil
end

local function validId(id: unknown): boolean
	return type(id) == "number" and id >= 1 and id <= SAFE_ID and id == math.floor(id)
end

local function validColor(value: unknown): boolean
	return type(value) == "number" and value >= 0 and value <= 0xFFFFFF and value == math.floor(value)
end

--[[ Scales ]]

-- The scales `scales` clamped into Config.Characters.Scales (a fresh table; junk reads as 1, or 0
-- for body type and proportion).
function Appearance.clampScales(scales: unknown): Scales
	local source = if type(scales) == "table" then scales :: { [string]: any } else {}
	local limits = Config.Characters.Scales :: { [string]: { number } }
	local clamped: { [string]: number } = {}
	for _, name in Appearance.SCALES do
		local range = limits[name]
		local value = source[name]
		if type(value) ~= "number" or value ~= value then
			value = if name == "bodyType" or name == "proportion" then 0 else 1
		end
		clamped[name] = math.clamp(value, range[1], range[2])
	end
	return (clamped :: any) :: Scales
end

--[[ Looks ]]

-- The editor's skin tones (BrickColors, light to dark).
Appearance.SKIN_TONES = table.freeze({
	0xE9DADA, -- Seashell
	0xFFCC99, -- Pastel brown
	0xEAB892, -- Light orange
	0xD7C59A, -- Brick yellow
	0xCC8E69, -- Nougat
	0x957977, -- Sand red
	0xA05F35, -- Dark orange
	0x7C5C46, -- Brown
	0x5A4C42, -- Dark taupe
	0x694028, -- Reddish brown
	0x564236, -- Cocoa
	0x6A3909, -- Burnt Sienna
})

-- A plain blocky look in the editor's first natural tone (no assets: no snapshot yet).
function Appearance.default(): Appearance
	local skin = Appearance.SKIN_TONES[3]
	return {
		colors = { skin, skin, skin, skin, skin, skin },
		scales = Appearance.clampScales({ height = 1, width = 1, depth = 1, head = 1, bodyType = 0, proportion = 0 }),
		assets = {},
	}
end

-- A deep copy of `appearance`.
function Appearance.copy(appearance: Appearance): Appearance
	local assets: { Asset } = table.create(#appearance.assets)
	for i, asset in appearance.assets do
		assets[i] = table.clone(asset)
	end
	return { colors = table.clone(appearance.colors), scales = table.clone(appearance.scales), assets = assets }
end

-- The preset names, in the editor's order.
Appearance.PRESETS = table.freeze({ "Classic", "Natural" })

-- Roblox's classic look: Bright yellow, Bright blue, Br. yellowish green.
local CLASSIC_COLORS = { 0xF5CD30, 0x0D69AC, 0xF5CD30, 0xF5CD30, 0xA4BD47, 0xA4BD47 }

--[[
	`appearance` with preset `name` applied (a copy; unknown names change nothing): Classic takes
	the body parts off, body type and proportion 0 and the classic colours; Natural puts the body
	parts back on with body type 1 and proportion 0.5.
]]
function Appearance.preset(appearance: Appearance, name: string): Appearance
	local result = Appearance.copy(appearance)
	if name == "Classic" then
		result.colors = table.clone(CLASSIC_COLORS)
		result.scales.bodyType, result.scales.proportion = 0, 0
		for _, asset in result.assets do
			if asset.kind <= #Appearance.PARTS then
				asset.worn = false
			end
		end
	elseif name == "Natural" then
		result.scales.bodyType, result.scales.proportion = 1, 0.5
		for _, asset in result.assets do
			if asset.kind <= #Appearance.PARTS then
				asset.worn = true
			end
		end
	end
	result.scales = Appearance.clampScales(result.scales)
	return result
end

--[[
	What the server keeps of `edited` (a client's) over its own `snapshot` (see the header): the
	edit's colours (the snapshot's where an edit's is no colour), its scales clamped, the snapshot's
	assets (at most MAX_ASSETS) worn as the edit says, one worn of each single kind.
]]
function Appearance.sanitize(edited: Appearance, snapshot: Appearance): Appearance
	local colors: { number } = table.create(#Appearance.PARTS)
	for i = 1, #Appearance.PARTS do
		local color = edited.colors[i]
		colors[i] = if validColor(color) then color else snapshot.colors[i] or 0
	end
	local worn: { [string]: boolean } = {}
	for _, asset in edited.assets do
		if asset.worn then
			worn[`{asset.kind}:{asset.id}`] = true
		end
	end
	local taken: { [number]: boolean } = {}
	local assets: { Asset } = {}
	for _, asset in snapshot.assets do
		if #assets >= Appearance.MAX_ASSETS then
			break
		end
		local copied = table.clone(asset)
		copied.worn = worn[`{asset.kind}:{asset.id}`] == true
		if copied.worn and not Appearance.isAccessory(asset.kind) then
			copied.worn = not taken[asset.kind]
			taken[asset.kind] = true
		end
		table.insert(assets, copied)
	end
	return { colors = colors, scales = Appearance.clampScales(edited.scales), assets = assets }
end

--[[ Bytes ]]

-- The look as bytes (see the header).
function Appearance.encode(appearance: Appearance): buffer
	local count = math.min(#appearance.assets, Appearance.MAX_ASSETS)
	local b = buffer.create(1 + 18 + 12 + 1 + count * 12)
	buffer.writeu8(b, 0, Appearance.VERSION)
	for i = 1, #Appearance.PARTS do
		local color = appearance.colors[i]
		color = if validColor(color) then color else 0
		local o = 1 + (i - 1) * 3
		buffer.writeu8(b, o, bit32.rshift(color, 16))
		buffer.writeu8(b, o + 1, bit32.band(bit32.rshift(color, 8), 0xFF))
		buffer.writeu8(b, o + 2, bit32.band(color, 0xFF))
	end
	local scales = Appearance.clampScales(appearance.scales) :: any
	for i, name in Appearance.SCALES do
		buffer.writeu16(b, 19 + (i - 1) * 2, math.clamp(math.round(scales[name] * SCALE), 0, 65535))
	end
	buffer.writeu8(b, 31, count)
	for i = 1, count do
		local asset = appearance.assets[i]
		local o = 32 + (i - 1) * 12
		buffer.writeu8(b, o, asset.kind)
		buffer.writef64(b, o + 1, asset.id)
		buffer.writeu8(b, o + 9, (if asset.worn then 1 else 0) + (if asset.layered then 2 else 0))
		buffer.writeu8(b, o + 10, math.clamp(math.floor(asset.order), 0, 255))
		buffer.writeu8(b, o + 11, math.clamp(math.round(asset.puffiness * 100), 0, 255))
	end
	return b
end

-- The look in `bytes`, or nil when they are not one of this version (see the header).
function Appearance.decode(bytes: buffer): Appearance?
	local len = buffer.len(bytes)
	if len < 32 or buffer.readu8(bytes, 0) ~= Appearance.VERSION then
		return nil
	end
	local count = buffer.readu8(bytes, 31)
	if count > Appearance.MAX_ASSETS or len ~= 32 + count * 12 then
		return nil
	end
	local colors: { number } = table.create(#Appearance.PARTS)
	for i = 1, #Appearance.PARTS do
		local o = 1 + (i - 1) * 3
		colors[i] = buffer.readu8(bytes, o) * 65536 + buffer.readu8(bytes, o + 1) * 256 + buffer.readu8(bytes, o + 2)
	end
	local scales: { [string]: number } = {}
	for i, name in Appearance.SCALES do
		scales[name] = buffer.readu16(bytes, 19 + (i - 1) * 2) / SCALE
	end
	local assets: { Asset } = table.create(count)
	for i = 1, count do
		local o = 32 + (i - 1) * 12
		local kind = buffer.readu8(bytes, o)
		local id = buffer.readf64(bytes, o + 1)
		local flags = buffer.readu8(bytes, o + 9)
		if not Appearance.isKind(kind) or not validId(id) or flags > 3 then
			return nil
		end
		assets[i] = {
			kind = kind,
			id = id,
			worn = bit32.btest(flags, 1),
			layered = bit32.btest(flags, 2),
			order = buffer.readu8(bytes, o + 10),
			puffiness = buffer.readu8(bytes, o + 11) / 100,
		}
	end
	return { colors = colors, scales = Appearance.clampScales(scales), assets = assets }
end

return Appearance
