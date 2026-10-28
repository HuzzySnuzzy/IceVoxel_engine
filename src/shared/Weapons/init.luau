--!strict
--[[
	The weapons registry (pure): Weapons/WeaponList's numbers by item id, checked as this loads.
	Firearms in the manner of DayZ (magazines, chambers, condition and jams, attachments, raising
	and aiming: the weapons design), their ammunition, magazines and attachments, and the melee
	rework's weapons. What a stack holds lives in its item data (Weapons/WeaponState); the maths
	of handling (cadence, spread, recoil, sway, jams, noise) is Weapons/Handling; the flight of a
	shot Weapons/Ballistics; the inventory's loading rules Weapons/Loading; the melee rules
	Weapons/Melee; the tooltips' lines Weapons/Describe.

	  firearm     a gun's spec (FirearmSpec): WeaponList's with its item id, the magazine as an
	              item id (detachable feed) or the internal magazine's `internal` rounds (0 for
	              the crossbow: only its chamber), its mounts as flags, its fire sound
	              ("item.firearm.<class>.fire", "item.crossbow.fire" for the crossbow), and the
	              ids of the attachments that fit it
	  ammo        a round's (AmmoSpec); `ammoFor(calibre)` lists a calibre's rounds, its default
	              first (WeaponList `default`), then the others in item order; `defaultRound`
	              answers the default
	  magazine    a detachable magazine's (MagazineSpec): calibre, capacity, the guns it fits
	  attachment  an optic's, a muzzle device's or the weapon light's (AttachmentSpec);
	              `fits(attachment, firearm)` asks whether it mounts on that gun
	  melee       a melee weapon's (MeleeSpec): heavy damage, guard share, finisher
	  takes       does a gun or a magazine take a round (the same calibre)?
	  level       a durability fraction's condition level: 1 Pristine (above 0.8), 2 Worn (above
	              0.6), 3 Damaged (above 0.4), 4 Badly damaged (above 0.2), 5 Ruined (the
	              survival look's Ui/Theme.CONDITIONS; tests/spec/WeaponHandling checks they agree)

	Checked as this loads (an error names the culprit): every class's fire sound is an event of the
	packs' sounds (`fireSound`); every name is an item; every firearm has a durability and stacks
	to 1, a known class, modes with rates above 0, a feed (a
	magazine of WeaponList's whose calibre is its own and which fits it, or an internal magazine
	of 0 or more rounds) and ammunition of its calibre; every magazine has a capacity above 0, a
	durability, and fits only guns that feed from it; every attachment has a known slot and fits
	only guns with that mount; every melee weapon has an `attack`; a calibre with several rounds
	has one default.

	Ids are item ids (Items), so lists are in item order (which follows the content packs: nothing
	picks the first by id). Everything returned is frozen: never change a spec.
]]

local Items = require(script.Parent.Items)
local Sounds = require(script.Parent.Sounds)
local WeaponList = require(script.WeaponList)

export type Point = WeaponList.Point
export type Look = WeaponList.Look
export type FireMode = WeaponList.FireMode
export type FireModeKind = WeaponList.FireModeKind
export type Beam = WeaponList.Beam

export type Mounts = { optic: boolean, muzzle: boolean, light: boolean }

export type FirearmSpec = {
	item: number,
	name: string,
	class: string,
	calibre: string,
	-- Detachable feed: the magazine item (nil: an internal magazine).
	magazine: number?,
	-- Internal magazine rounds (0 for a detachable feed: the magazine's capacity counts).
	internal: number,
	modes: { FireMode },
	damageScale: number,
	spread: number,
	recoil: number,
	recoilYaw: number,
	sway: number,
	noise: number,
	zero: number,
	reloadTicks: number,
	chamberTicks: number,
	roundTicks: number,
	jams: boolean,
	mounts: Mounts,
	cycle: boolean,
	scope: number?,
	-- The share of WeaponList's pixels the model is drawn at (its `look` here is scaled already:
	-- in the model's pixels).
	scale: number,
	look: Look,
	-- The fire sound event (Shared/Sounds).
	sound: string,
	-- The attachments that fit, in item order.
	fits: { number },
}

export type AmmoSpec = {
	item: number,
	name: string,
	calibre: string,
	damage: number,
	pellets: number,
	cone: number,
	velocity: number,
	range: number,
	falloffMin: number,
	-- A spent one may drop again (server Weapons/FireRules.recovery; the chance:
	-- Config.Weapons.BoltRecover).
	recover: boolean,
}

export type MagazineSpec = {
	item: number,
	name: string,
	calibre: string,
	capacity: number,
	-- The firearms it fits, in item order.
	fits: { number },
}

export type AttachmentSlot = "optic" | "muzzle" | "light"

export type AttachmentSpec = {
	item: number,
	name: string,
	slot: AttachmentSlot,
	-- Optic: field of view divided by this in the sights (nil: no optic).
	zoom: number?,
	-- Muzzle device: noise share and spread share (1: none), the suppressed sound with no flash,
	-- tracers with glow (false: without).
	noise: number,
	spread: number,
	suppressed: boolean,
	glow: boolean,
	-- Weapon light: its spotlight.
	beam: Beam?,
	-- The firearms it fits, in item order.
	fits: { number },
}

export type MeleeSpec = { item: number, name: string, heavy: number, guard: number, finisher: boolean }

local Weapons = {}

-- The firearm classes (each has its fire sound, `fireSound`: the Apocalypse pack's sounds).
Weapons.CLASSES = table.freeze({ "pistol", "revolver", "smg", "shotgun", "rifle", "heavy", "small", "crossbow" })
-- Attachment slots, in the order a firearm's are taken off (Weapons/Loading) and drawn.
Weapons.SLOTS = table.freeze({ "muzzle", "optic", "light" } :: { AttachmentSlot })
-- The condition levels' lower bounds (durability left, exclusive): Pristine, Worn, Damaged, Badly
-- damaged; anything at or below the last is Ruined (level 5), which never fires.
Weapons.CONDITIONS = table.freeze({ 0.8, 0.6, 0.4, 0.2 })
Weapons.RUINED = 5

-- A class's fire sound event: item.firearm.<class>.fire, the crossbow's item.crossbow.fire.
function Weapons.fireSound(class: string): string
	return if class == "crossbow" then "item.crossbow.fire" else `item.firearm.{class}.fire`
end

local CLASS_SET: { [string]: boolean } = {}
for _, class in Weapons.CLASSES do
	CLASS_SET[class] = true
	local sound = Weapons.fireSound(class)
	assert(Sounds.find(sound) ~= nil, `Weapons: class {class}'s shot {sound} is no pack's sound event`)
end
local SLOT_SET: { [string]: boolean } = { optic = true, muzzle = true, light = true }

local firearms: { [number]: FirearmSpec } = {}
local magazines: { [number]: MagazineSpec } = {}
local ammo: { [number]: AmmoSpec } = {}
local attachments: { [number]: AttachmentSpec } = {}
local melee: { [number]: MeleeSpec } = {}
local ammoByCalibre: { [string]: { number } } = {}

-- The item named `name` (an error when there is none).
local function itemOf(name: string, what: string): number
	local id = Items.find(name)
	assert(id ~= nil and Items.get(id) ~= nil, `Weapons: {what} {name} is no item`)
	return id
end

-- Sorted, frozen ids.
local function sortedIds(set: { [number]: any }): { number }
	local list: { number } = {}
	for id in set do
		table.insert(list, id)
	end
	table.sort(list)
	return table.freeze(list)
end

local function positive(value: number?): boolean
	return type(value) == "number" and value > 0 and value < math.huge
end

-- A point times `scale` (frozen).
local function scaledPoint(point: Point?, scale: number): Point?
	if point == nil then
		return nil
	end
	local out: Point = {}
	for i, value in point do
		out[i] = value * scale
	end
	return table.freeze(out)
end

-- A look in the model's pixels: WeaponList's times the gun's `scale` (frozen).
local function scaledLook(look: Look, scale: number): Look
	return table.freeze({
		grip = scaledPoint(look.grip, scale) :: Point,
		muzzle = scaledPoint(look.muzzle, scale) :: Point,
		sight = look.sight * scale,
		mag = scaledPoint(look.mag, scale),
		optic = scaledPoint(look.optic, scale),
		light = scaledPoint(look.light, scale),
		fore = scaledPoint(look.fore, scale),
	})
end

local function wholeAtLeast(value: number?, least: number): boolean
	return type(value) == "number" and value >= least and value == math.floor(value) and value < math.huge
end

--[[ Ammunition ]]

for name, data in WeaponList.ammo do
	local item = itemOf(name, "ammunition")
	assert(type(data.calibre) == "string" and data.calibre ~= "", `Weapons: {name} has no calibre`)
	assert(positive(data.damage) and positive(data.velocity) and positive(data.range), `Weapons: {name}'s numbers`)
	assert(wholeAtLeast(data.pellets, 1) and data.pellets <= 12, `Weapons: {name}'s pellets must be 1..12`)
	assert(data.cone >= 0 and data.falloffMin >= 0 and data.falloffMin <= 1, `Weapons: {name}'s cone or falloff`)
	assert(data.recover == nil or type(data.recover) == "boolean", `Weapons: {name}'s recover is a switch`)
	assert(data.default == nil or data.default == true, `Weapons: {name}'s default is true or left out`)
	assert(Items.maxStack(item) > 1, `Weapons: ammunition {name} must stack`)
	ammo[item] = table.freeze({
		item = item,
		name = name,
		calibre = data.calibre,
		damage = data.damage,
		pellets = data.pellets,
		cone = data.cone,
		velocity = data.velocity,
		range = data.range,
		falloffMin = data.falloffMin,
		recover = data.recover == true,
	})
	local list = ammoByCalibre[data.calibre]
	if list == nil then
		list = {}
		ammoByCalibre[data.calibre] = list
	end
	table.insert(list, item)
end
-- Each calibre's default round: its only one, else the one WeaponList marks `default` (never the
-- first by id: ids follow the content packs). It leads the calibre's list, the rest in item order.
local defaultRounds: { [string]: number } = {}
for calibre, list in ammoByCalibre do
	table.sort(list)
	local marked: { number } = {}
	for _, item in list do
		if WeaponList.ammo[ammo[item].name].default then
			table.insert(marked, item)
		end
	end
	assert(
		#marked <= 1 and (#list == 1 or #marked == 1),
		`Weapons: calibre {calibre} has {#list} rounds, so one of them (not {#marked}) must be its default`
	)
	local default = marked[1] or list[1]
	table.remove(list, table.find(list, default) :: number)
	table.insert(list, 1, default)
	defaultRounds[calibre] = default
	ammoByCalibre[calibre] = table.freeze(list)
end

--[[ Firearms (their magazines and attachments resolved after) ]]

local fitsOf: { [number]: { number } } = {}
for name, data in WeaponList.firearms do
	local item = itemOf(name, "firearm")
	local def = Items.get(item) :: Items.ItemDef
	assert(positive(def.durability) and def.maxStack == 1, `Weapons: firearm {name} needs a durability`)
	assert(def.attack ~= nil, `Weapons: firearm {name} needs an attack (its bash)`)
	assert(CLASS_SET[data.class], `Weapons: firearm {name} has unknown class {data.class}`)
	assert(ammoByCalibre[data.calibre] ~= nil, `Weapons: no ammunition for {name}'s calibre {data.calibre}`)
	assert(#data.modes >= 1 and #data.modes <= 8, `Weapons: firearm {name} needs 1..8 fire modes`)
	for _, mode in data.modes do
		assert((mode.kind == "semi" or mode.kind == "auto") and positive(mode.rpm), `Weapons: {name}'s fire modes`)
	end
	assert(
		(data.magazine == nil) ~= (data.internal == nil),
		`Weapons: firearm {name} feeds from a magazine or an internal magazine, one of them`
	)
	if data.internal ~= nil then
		assert(wholeAtLeast(data.internal, 0), `Weapons: {name}'s internal magazine`)
	end
	for _, field in { "reloadTicks", "chamberTicks", "roundTicks" } do
		assert(wholeAtLeast((data :: any)[field], 0), `Weapons: {name}'s {field} must be whole ticks`)
	end
	assert(positive(data.damageScale) and positive(data.zero), `Weapons: {name}'s damage scale and zero`)
	assert(data.spread >= 0 and data.recoil >= 0 and data.sway >= 0 and data.noise >= 0, `Weapons: {name}'s numbers`)
	local mounts: Mounts = { optic = false, muzzle = false, light = false }
	for _, mount in data.mounts do
		assert(SLOT_SET[mount], `Weapons: {name} has unknown mount {mount}`)
		mounts[mount :: AttachmentSlot] = true
	end
	assert(data.scope == nil or (positive(data.scope) and not mounts.optic), `Weapons: {name}'s scope`)
	local look = data.look
	assert(look and look.grip and look.muzzle and type(look.sight) == "number", `Weapons: {name}'s look`)
	local scale = data.scale or 1
	assert(positive(scale), `Weapons: {name}'s scale`)
	local fits: { number } = {}
	fitsOf[item] = fits
	firearms[item] = {
		item = item,
		name = name,
		class = data.class,
		calibre = data.calibre,
		magazine = if data.magazine then itemOf(data.magazine, "magazine") else nil,
		internal = data.internal or 0,
		modes = table.freeze(data.modes),
		damageScale = data.damageScale,
		spread = data.spread,
		recoil = data.recoil,
		recoilYaw = data.recoilYaw,
		sway = data.sway,
		noise = data.noise,
		zero = data.zero,
		reloadTicks = data.reloadTicks,
		chamberTicks = data.chamberTicks,
		roundTicks = data.roundTicks,
		jams = data.jams,
		mounts = table.freeze(mounts),
		cycle = data.cycle == true,
		scope = data.scope,
		scale = scale,
		look = scaledLook(look, scale),
		sound = Weapons.fireSound(data.class),
		fits = fits,
	}
end

--[[ Magazines ]]

for name, data in WeaponList.magazines do
	local item = itemOf(name, "magazine")
	local def = Items.get(item) :: Items.ItemDef
	assert(positive(def.durability) and def.maxStack == 1, `Weapons: magazine {name} needs a durability`)
	assert(wholeAtLeast(data.capacity, 1) and data.capacity <= 255, `Weapons: {name}'s capacity must be 1..255`)
	assert(ammoByCalibre[data.calibre] ~= nil, `Weapons: no ammunition for {name}'s calibre {data.calibre}`)
	local fits: { number } = {}
	for _, gun in data.fits do
		local id = itemOf(gun, "firearm")
		local spec = firearms[id]
		assert(spec ~= nil, `Weapons: magazine {name} fits {gun}, no firearm`)
		assert(spec.magazine == item, `Weapons: magazine {name} fits {gun}, which feeds from another`)
		assert(spec.calibre == data.calibre, `Weapons: magazine {name}'s calibre is not {gun}'s`)
		table.insert(fits, id)
	end
	table.sort(fits)
	magazines[item] = table.freeze({
		item = item,
		name = name,
		calibre = data.calibre,
		capacity = data.capacity,
		fits = table.freeze(fits),
	})
end
for item, spec in firearms do
	local magazine = spec.magazine
	if magazine ~= nil then
		local mag = magazines[magazine]
		assert(mag ~= nil, `Weapons: {spec.name} feeds from item {magazine}, which is no magazine`)
		assert(table.find(mag.fits, item) ~= nil, `Weapons: {mag.name} does not list {spec.name}`)
	end
end

--[[ Attachments ]]

for name, data in WeaponList.attachments do
	local item = itemOf(name, "attachment")
	local def = Items.get(item) :: Items.ItemDef
	assert(def.maxStack == 1, `Weapons: attachment {name} must stack to 1`)
	assert(SLOT_SET[data.slot], `Weapons: attachment {name} has unknown slot {data.slot}`)
	local slot: AttachmentSlot = if data.slot == "optic"
		then "optic"
		elseif data.slot == "muzzle" then "muzzle"
		else "light"
	assert((data.zoom ~= nil) == (slot == "optic"), `Weapons: only optics (all of them) zoom: {name}`)
	assert(data.zoom == nil or positive(data.zoom), `Weapons: {name}'s zoom`)
	assert((data.beam ~= nil) == (slot == "light"), `Weapons: only lights (all of them) have a beam: {name}`)
	assert(
		slot == "muzzle" or (data.noise == nil and data.spread == nil and data.suppressed == nil),
		`Weapons: {name} has a muzzle device's numbers`
	)
	local fits: { number } = {}
	for _, gun in data.fits do
		local id = itemOf(gun, "firearm")
		local spec = firearms[id]
		assert(spec ~= nil, `Weapons: attachment {name} fits {gun}, no firearm`)
		assert(spec.mounts[slot], `Weapons: attachment {name} fits {gun}, which has no {slot} mount`)
		table.insert(fits, id)
		table.insert(fitsOf[id], item)
	end
	table.sort(fits)
	attachments[item] = table.freeze({
		item = item,
		name = name,
		slot = slot,
		zoom = data.zoom,
		noise = data.noise or 1,
		spread = data.spread or 1,
		suppressed = data.suppressed == true,
		glow = data.glow ~= false,
		beam = if data.beam then table.freeze(table.clone(data.beam)) else nil,
		fits = table.freeze(fits),
	})
end
for item, spec in firearms do
	table.sort(spec.fits)
	table.freeze(spec.fits)
	firearms[item] = table.freeze(spec)
end

--[[ Melee ]]

for name, data in WeaponList.melee do
	local item = itemOf(name, "melee weapon")
	local def = Items.get(item) :: Items.ItemDef
	assert(
		def.attack ~= nil and positive(def.durability),
		`Weapons: melee weapon {name} needs an attack and a durability`
	)
	assert(positive(data.heavy), `Weapons: {name}'s heavy attack`)
	assert(data.guard >= 0 and data.guard <= 1, `Weapons: {name}'s guard share must be 0..1`)
	assert(firearms[item] == nil, `Weapons: {name} is a firearm and a melee weapon`)
	melee[item] = table.freeze({
		item = item,
		name = name,
		heavy = data.heavy,
		guard = data.guard,
		finisher = data.finisher == true,
	})
end

-- (One kind each.)
for item in ammo do
	assert(firearms[item] == nil and magazines[item] == nil and attachments[item] == nil, `Weapons: {item} twice`)
end
for item in magazines do
	assert(firearms[item] == nil and attachments[item] == nil and melee[item] == nil, `Weapons: {item} twice`)
end
for item in attachments do
	assert(firearms[item] == nil and melee[item] == nil, `Weapons: {item} twice`)
end

-- Every firearm, magazine, ammunition and attachment, by item id (item order).
Weapons.FIREARMS = sortedIds(firearms)
Weapons.MAGAZINES = sortedIds(magazines)
Weapons.AMMO = sortedIds(ammo)
Weapons.ATTACHMENTS = sortedIds(attachments)
Weapons.MELEE = sortedIds(melee)

--[[ Lookups (nil: not one) ]]

function Weapons.firearm(item: number?): FirearmSpec?
	return if item then firearms[item] else nil
end

function Weapons.magazine(item: number?): MagazineSpec?
	return if item then magazines[item] else nil
end

function Weapons.ammo(item: number?): AmmoSpec?
	return if item then ammo[item] else nil
end

function Weapons.attachment(item: number?): AttachmentSpec?
	return if item then attachments[item] else nil
end

function Weapons.melee(item: number?): MeleeSpec?
	return if item then melee[item] else nil
end

-- Does attachment `attachment` mount on firearm `firearm`?
function Weapons.fits(attachment: number?, firearm: number?): boolean
	local spec = if attachment then attachments[attachment] else nil
	return spec ~= nil and firearm ~= nil and table.find(spec.fits, firearm) ~= nil
end

-- Does a firearm or a magazine (`firearmOrMag`) take round `round` (the same calibre)?
function Weapons.takes(firearmOrMag: number?, round: number?): boolean
	local spec = if round then ammo[round] else nil
	if spec == nil or firearmOrMag == nil then
		return false
	end
	local gun = firearms[firearmOrMag]
	local mag = magazines[firearmOrMag]
	local calibre = if gun then gun.calibre elseif mag then mag.calibre else nil
	return calibre == spec.calibre
end

-- The rounds of a calibre: its default first, then the others in item order ({} for none).
function Weapons.ammoFor(calibre: string): { number }
	return ammoByCalibre[calibre] or table.freeze({})
end

-- A calibre's default round (WeaponList `default`, or its only one); nil for no such calibre.
function Weapons.defaultRound(calibre: string): number?
	return defaultRounds[calibre]
end

-- The condition level (1 Pristine .. 5 Ruined) of `fraction` of durability left (see the header).
function Weapons.level(fraction: number): number
	for index, above in Weapons.CONDITIONS do
		if fraction > above then
			return index
		end
	end
	return Weapons.RUINED
end

return Weapons
