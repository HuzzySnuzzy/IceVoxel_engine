--!strict
--[[
	What a zombie wears, part by part, pure (Entities/MobRigPool paints the rig's parts with it;
	tests/spec/MobRig checks it). A zombie's `variant` is a look and a skin tone (MobList.look),
	picked once by the server, so every client draws it the same; tears and blood come from the
	mob's id (Util/Hash), the same everywhere too. Worked out once, when the zombie spawns.

	  Head          skin
	  UpperTorso    the shirt (shirtless: skin)
	  LowerTorso    the pants
	  UpperLeg      the pants
	  LowerLeg      the pants (`legs` "long", the default), else skin (shorts)
	  UpperArm      the shirt, unless `sleeves` is "none"
	  LowerArm      the shirt only with `sleeves` "long" (short sleeves, the default: skin)
	  Hand          the gloves, else skin
	  Foot          the shoes, else skin (barefoot)
	  extras        the vest's, the stripes' and the hat's own colours (MobRig.extras' order)
	Then each cloth part (any part above in clothes, but the pants' seat, the lower torso, which
	never tears) shows skin where hash2(id, slot) < `torn` (default 0.2), and any cloth part
	(the lower torso and the extras too) is blood-stained, 0.35 of the way to dark red, where
	hash2(id, slot + 32) < `blood` (default 0.3): a torn sleeve can bleed.

	The reduced rig takes each upper part's colour (MobRig.REDUCED_FROM) and its hat's and
	vest's; the far impostor, the look's shirt (MobList.variantColor, WAILA's colour) and skin.
	Colours are packed 0xRRGGBB; `hurt` blends one towards Minecraft's hurt red (MobModel).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local MobList = require(Shared.Entities.MobList)
local Hash = require(Shared.Util.Hash)

local MobModel = require(script.Parent.MobModel)
local MobRig = require(script.Parent.MobRig)

local U32 = 4294967296

local ZombieLooks = {}

-- A look's defaults (MobList.Look).
ZombieLooks.TORN = 0.2
ZombieLooks.BLOOD = 0.3
-- Blood: this share of the way to this colour.
ZombieLooks.BLOOD_SHARE = 0.35
ZombieLooks.BLOOD_COLOUR = { 110, 20, 20 }

-- A mob's colours by tier (packed 0xRRGGBB a slot).
export type Paint = {
	full: { number },
	reduced: { number },
	impostor: { number },
}

function ZombieLooks.pack(r: number, g: number, b: number): number
	return math.round(r) * 65536 + math.round(g) * 256 + math.round(b)
end

function ZombieLooks.unpack(colour: number): (number, number, number)
	return colour // 65536, (colour // 256) % 256, colour % 256
end

local function packed(colour: { number }): number
	return ZombieLooks.pack(colour[1], colour[2], colour[3])
end

-- The packed `colour` blended `share` of the way to `towards` (r, g, b).
local function blend(colour: number, towards: { number }, share: number): number
	local r, g, b = ZombieLooks.unpack(colour)
	return ZombieLooks.pack(r + (towards[1] - r) * share, g + (towards[2] - g) * share, b + (towards[3] - b) * share)
end

-- A colour reddened as a hurt or dying mob is drawn (MobModel's hurt red).
function ZombieLooks.hurt(colour: number): number
	return blend(colour, MobModel.HURT_COLOUR, MobModel.HURT_RED)
end

--[[
	The colour of every full-rig slot of a zombie of `kind` in `variant` with id `id`: the body
	(MobRig's 15 parts) and its look's extras, packed.
]]
function ZombieLooks.full(kind: MobList.Kind, variant: number, id: number): { number }
	local look, skin = MobList.look(kind, variant)
	local colours = table.create(MobRig.FULL_SLOTS, packed(skin))
	if look == nil then
		return colours
	end
	local skinColour = packed(skin)
	local shirt = if look.shirt then packed(look.shirt) else nil
	local pants = packed(look.pants)
	local sleeves = look.sleeves or "short"
	local shoes = look.shoes
	local cloth: { [number]: boolean } = {}
	local function wear(slot: number, colour: number?)
		if colour then
			colours[slot] = colour
			cloth[slot] = true
		else
			colours[slot] = skinColour
		end
	end
	wear(MobRig.HEAD, nil)
	wear(MobRig.UPPER_TORSO, shirt)
	wear(MobRig.LOWER_TORSO, pants)
	local upperSleeve = if sleeves ~= "none" then shirt else nil
	local lowerSleeve = if sleeves == "long" then shirt else nil
	wear(MobRig.LEFT_UPPER_ARM, upperSleeve)
	wear(MobRig.RIGHT_UPPER_ARM, upperSleeve)
	wear(MobRig.LEFT_LOWER_ARM, lowerSleeve)
	wear(MobRig.RIGHT_LOWER_ARM, lowerSleeve)
	local gloves = if look.gloves then packed(look.gloves) else nil
	wear(MobRig.LEFT_HAND, gloves)
	wear(MobRig.RIGHT_HAND, gloves)
	wear(MobRig.LEFT_UPPER_LEG, pants)
	wear(MobRig.RIGHT_UPPER_LEG, pants)
	local shins = if (look.legs or "long") == "long" then pants else nil
	wear(MobRig.LEFT_LOWER_LEG, shins)
	wear(MobRig.RIGHT_LOWER_LEG, shins)
	local feet = if shoes then packed(shoes) else nil
	wear(MobRig.LEFT_FOOT, feet)
	wear(MobRig.RIGHT_FOOT, feet)
	local slot = MobRig.BODY
	for _, extra in MobRig.extras(look) do
		slot += 1
		local colour = if extra == "vest"
			then look.vest
			elseif extra == "stripes" then look.stripes
			else (look.hat :: MobList.Hat).color
		wear(slot, packed(colour :: { number }))
	end
	-- Tears (never the extras or the seat of the pants), then blood.
	local torn = look.torn or ZombieLooks.TORN
	local blood = look.blood or ZombieLooks.BLOOD
	for part = 1, slot do
		if cloth[part] then
			if part <= MobRig.BODY and part ~= MobRig.LOWER_TORSO and Hash.hash2(id % U32, part, 0) / U32 < torn then
				colours[part] = skinColour
			end
			if Hash.hash2(id % U32, part + 32, 0) / U32 < blood then
				colours[part] = blend(colours[part], ZombieLooks.BLOOD_COLOUR, ZombieLooks.BLOOD_SHARE)
			end
		end
	end
	return colours
end

--[[
	A mob's colours for every tier, worked out once at its spawn: a zombie's rig from its look
	(above), any other kind's two boxes from MobList (a sheep's fleece in its variant).
]]
function ZombieLooks.paint(kind: MobList.Kind, variant: number, id: number): Paint
	local impostor = {}
	for index, box in kind.parts do
		local colour = if index == 1 then MobList.variantColor(kind, variant) else box.color
		impostor[index] = packed(colour)
	end
	if kind.rig == nil or MobList.looksOf(kind) == nil then
		return { full = {}, reduced = {}, impostor = impostor }
	end
	local _, skin = MobList.look(kind, variant)
	-- (The far impostor's head in the zombie's own skin.)
	if #kind.parts >= 2 then
		impostor[2] = packed(skin)
	end
	local full = ZombieLooks.full(kind, variant, id)
	local reduced = {}
	for slot, from in MobRig.REDUCED_FROM do
		reduced[slot] = full[from]
	end
	local build = MobRig.build(kind, variant)
	local fullShape = build.full :: MobRig.Shape
	local reducedShape = build.reduced :: MobRig.Shape
	-- The reduced extras (hat, vest) take the full extras' colours by name.
	for slot = reducedShape.body + 1, reducedShape.count do
		local name = reducedShape.extras[slot - reducedShape.body]
		for fullSlot = fullShape.body + 1, fullShape.count do
			if fullShape.extras[fullSlot - fullShape.body] == name then
				reduced[slot] = full[fullSlot]
			end
		end
	end
	return { full = full, reduced = reduced, impostor = impostor }
end

-- The colours of a paint for a tier (MobRig.FULL, REDUCED or IMPOSTOR).
function ZombieLooks.of(paint: Paint, tier: number): { number }
	if tier == MobRig.FULL then
		return paint.full
	elseif tier == MobRig.REDUCED then
		return paint.reduced
	end
	return paint.impostor
end

return ZombieLooks
