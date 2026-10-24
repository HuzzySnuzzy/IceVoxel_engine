--!strict
--[[
	The turrets registry (pure): SMG, Rifle and Sniper turrets in four tiers matching the
	transmitters' (Basic, Advanced, Elite, Ultimate), their numbers (Config.Turrets) by block,
	checked as this loads, and what the machine kind, the server's simulation and the client
	share about one: its slots, its packed state, the cell over its gun, what an optic does.

	A turret is a Mekanism machine (Shared/Machines kind "turret_<type>_<tier>": Machines/Kinds/
	Turret) holding a tiny buffer of its calibre's rounds and energy. It borrows a gun's numbers:
	its type's stand-in firearm (Weapons/WeaponList: the SMG's Smg, the rifle's Assault Rifle,
	the sniper's Hunting Rifle) gives the fire sound, the noise and a muzzle device's effects, its
	round (9mm, 5.56, .308) the damage, flight and range, times the type's damage scale. A
	Logistical Transporter feeds the ammo slot; the feeder rule caps its rate at the rate of the
	best transporter tier feeding it (`rpm`), and the demand rule (server Transmitters/Transport,
	KindSpec `demand`) keeps a line into a full turret ready to send the next round as soon as
	there is room. Requires Config, Blocks, Items, Weapons and Transmitters/Tiers, never
	Shared/Transmitters or Shared/Machines (which load the kinds that require this).

	  SPECS        every turret's Spec, type by type (TYPES' order) and tier by tier within each:
	               SPECS[(t - 1) x 4 + tier] for the t-th type, the BlockList order of their blocks
	  spec         the Spec of a turret block (nil for other blocks); isTurret; of(type, tier)
	  rpm          the rate it may fire at: its type's rate at the lower of its tier and the feed's
	               (0: fed by hand, its own)
	  SLOT         its machine slots: the ammo (1), the optic (2), the muzzle device (3)
	  STATUS       what it is doing, the status line (STATUS_NAMES): No target, Targeting,
	               Firing, No ammo, No power, Blocked, Disabled
	  packState    its state field (the kind's `state`, which Machines records carry, so WAILA and
	               the client know it without the window): status + 8 x feed + 64 x lure + 128 x
	               tracking, a byte (at most 230); unpackState reads it back (frozen: saved
	               containers keep it)
	  headClear    does the cell above let the gun work: nothing opaque and no obstruction box
	               there (Blocks.obstruction): air, torches, plants, water and a one-layer snow
	               pass; a block, a transporter or deeper snow block it ("Blocked")
	  optic        what an optic in its optic slot does: the cone's factor, the rescan ticks, the
	               range's factor, aiming at heads
	  GHOSTS       the three slots' outlines while empty (Core SlotSpec `ghost`)

	Frozen (the kind, the server's simulation and the client are built on them): the Spec shape,
	STATUS and the state packing, the slots. Everything returned is frozen: never change a spec.
]]

local Blocks = require(script.Parent.Blocks)
local Config = require(script.Parent.Config)
local Items = require(script.Parent.Items)
local Weapons = require(script.Parent.Weapons)
local Tiers = require(script.Parent.Transmitters.Tiers)

export type TurretType = "smg" | "rifle" | "sniper"

-- A turret (see the header): numbers are Config.Turrets' at its type and tier.
export type Spec = {
	-- Its block (BlockList "<Tier><Type>Turret"), machine kind ("turret_<type>_<tier>"), type,
	-- tier (1..4) and block name ("BasicSmgTurret").
	block: number,
	kind: string,
	type: TurretType,
	tier: number,
	name: string,
	-- Its round's calibre ("9mm"), the round's item and the stand-in gun's item (its sound and
	-- noise), and damage times the round's.
	calibre: string,
	ammo: number,
	firearm: number,
	damageScale: number,
	-- Range (blocks), rate (rounds a minute), rounds its ammo slot holds, turn rate (degrees a
	-- second), cone (degrees: the half angle), the most degrees off its aim it fires at, the
	-- barrel (blocks from the pivot to the muzzle), the lowest pitch it aims at (degrees: its
	-- type's, the lowest its drawn gun clears its own block at; TurretRules.inPitch).
	range: number,
	rpm: number,
	buffer: number,
	turn: number,
	spread: number,
	settle: number,
	barrel: number,
	pitchMin: number,
	-- Energy: its store (J), J a tick idle and tracking, J a shot.
	capacity: number,
	idle: number,
	tracking: number,
	shot: number,
	-- The optics and muzzle devices its slots take (item ids).
	optics: { [number]: true },
	muzzles: { [number]: true },
}

-- What an optic does on a turret (`optic`): the cone times `spread`, a rescan every `scan`
-- ticks, the range times `range`, aiming at heads.
export type Optic = { spread: number, scan: number, range: number, head: boolean }

local Turrets = {}

local SETTINGS = Config.Turrets
-- (Config.Turrets.Optics by name: what each one does, all its numbers optional but `types`.)
type OpticNumbers = { types: { string }, spread: number?, scan: number?, range: number?, head: boolean? }
local OPTICS: { [string]: OpticNumbers } = SETTINGS.Optics :: any

local TYPES: { TurretType } = { "smg", "rifle", "sniper" }
Turrets.TYPES = table.freeze(TYPES)
-- Each type's part of its blocks' names (BlockList "<Tier><Type>Turret").
Turrets.TYPE_NAMES = table.freeze({ smg = "Smg", rifle = "Rifle", sniper = "Sniper" } :: { [string]: string })
-- Tiers 1..4 (the transmitters': Transmitters/Tiers).
Turrets.TIERS = #Tiers.TIERS

-- Its machine slots.
Turrets.SLOT = table.freeze({ AMMO = 1, OPTIC = 2, MUZZLE = 3 })

-- Status codes (the packed state's low three bits) and their status lines.
Turrets.STATUS = table.freeze({
	NO_TARGET = 0,
	TARGETING = 1,
	FIRING = 2,
	NO_AMMO = 3,
	NO_POWER = 4,
	BLOCKED = 5,
	DISABLED = 6,
})
Turrets.STATUS_NAMES = table.freeze({
	[0] = "No target",
	[1] = "Targeting",
	[2] = "Firing",
	[3] = "No ammo",
	[4] = "No power",
	[5] = "Blocked",
	[6] = "Disabled",
} :: { [number]: string })
local MAX_STATUS = Turrets.STATUS.DISABLED

--[[ The registry ]]

local function itemOf(name: string, what: string): number
	local id = rawget(Items.id :: any, name)
	assert(type(id) == "number", `Turrets: {what} {name} is no item`)
	return id
end

local specs: { Spec } = {}
local byBlock: { [number]: Spec } = {}
local byType: { [string]: { Spec } } = {}

for _, turretType in TYPES do
	local numbers = SETTINGS.Types[turretType]
	assert(numbers, `Turrets: no Config.Turrets.Types.{turretType}`)
	local ammo = itemOf(numbers.ammo, "round")
	local round = Weapons.ammo(ammo)
	assert(round, `Turrets: {numbers.ammo} is no round`)
	local firearm = itemOf(numbers.firearm, "stand-in gun")
	local gun = Weapons.firearm(firearm)
	assert(gun and gun.calibre == round.calibre, `Turrets: {numbers.firearm} is no gun of {round.calibre}`)
	local optics: { [number]: true } = {}
	for opticName, optic in OPTICS do
		if table.find(optic.types, turretType) then
			optics[itemOf(opticName, "optic")] = true
		end
	end
	local muzzles: { [number]: true } = {}
	for _, muzzleName in SETTINGS.Muzzles do
		local item = itemOf(muzzleName, "muzzle device")
		local device = Weapons.attachment(item)
		assert(device and device.slot == "muzzle", `Turrets: {muzzleName} is no muzzle device`)
		muzzles[item] = true
	end
	table.freeze(optics)
	table.freeze(muzzles)
	local pitchMin = numbers.pitchMin
	assert(
		pitchMin >= SETTINGS.PitchMin and pitchMin < 0,
		`Turrets: {turretType}'s pitchMin is under 0, never under Config.Turrets.PitchMin`
	)
	local list: { Spec } = {}
	byType[turretType] = list
	for tier = 1, Turrets.TIERS do
		local name = `{Tiers.TIERS[tier].name}{Turrets.TYPE_NAMES[turretType]}Turret`
		local block = Blocks.id[name]
		local def = Blocks.get(block)
		local kind = `turret_{turretType}_{tier}`
		assert(def.machine and def.machine.kind == kind, `Turrets: {name} must be a machine of kind {kind}`)
		local capacity = SETTINGS.Capacity[tier]
		assert(def.energy and def.energy.capacity == capacity, `Turrets: {name}'s energy is Config.Turrets.Capacity's`)
		local rpm, buffer = numbers.rpm[tier], numbers.buffer[tier]
		assert(rpm > 0 and rpm == math.floor(rpm), `Turrets: {name}'s rate is whole rounds a minute`)
		assert(
			buffer >= 1 and buffer == math.floor(buffer) and buffer <= Items.maxStack(ammo),
			`Turrets: {name} holds 1..{Items.maxStack(ammo)} rounds`
		)
		local spec: Spec = {
			block = block,
			kind = kind,
			type = turretType :: TurretType,
			tier = tier,
			name = name,
			calibre = round.calibre,
			ammo = ammo,
			firearm = firearm,
			damageScale = numbers.damageScale,
			range = numbers.range[tier],
			rpm = rpm,
			buffer = buffer,
			turn = numbers.turn[tier],
			spread = numbers.spread[tier],
			settle = numbers.settle,
			barrel = numbers.barrel,
			pitchMin = pitchMin,
			capacity = capacity,
			idle = SETTINGS.IdleJoules[tier],
			tracking = SETTINGS.TrackingJoules[tier],
			shot = numbers.shot,
			optics = optics,
			muzzles = muzzles,
		}
		table.freeze(spec)
		table.insert(specs, spec)
		table.insert(list, spec)
		byBlock[block] = spec
	end
	table.freeze(list)
end
-- (Their blocks follow each other in BlockList, in this order.)
for i, spec in specs do
	assert(spec.block == specs[1].block + i - 1, `Turrets: {spec.name} is out of BlockList's order`)
end

Turrets.SPECS = table.freeze(specs)

-- The Spec of the turret `block`, nil for other blocks.
function Turrets.spec(block: number?): Spec?
	return if block then byBlock[block] else nil
end

-- Is `block` a turret?
function Turrets.isTurret(block: number?): boolean
	return block ~= nil and byBlock[block] ~= nil
end

-- The Spec of `turretType` at `tier` (1..4). Errors on anything else.
function Turrets.of(turretType: TurretType, tier: number): Spec
	local list = byType[turretType]
	local spec = if list then list[tier] else nil
	assert(spec, `Turrets: no {turretType} turret of tier {tier}`)
	return spec
end

--[[
	The feeder rule: rounds a minute `spec` fires at most when the best Logistical Transporter
	feeding it is of tier `feed` (1..4; the Restrictive Transporter counts as Basic): its type's
	rate at the lower of its tier and the feed's. 0 (fed by hand, no such transporter): its own.
]]
function Turrets.rpm(spec: Spec, feed: number): number
	if feed ~= feed or feed < 1 then
		return spec.rpm
	end
	local tier = math.clamp(math.floor(feed), 1, spec.tier)
	return byType[spec.type][tier].rpm
end

--[[ The packed state ]]

--[[
	A turret's state field: `status` (STATUS) + 8 x `feed` (0..4) + 64 x `lure` + 128 x `tracking`,
	one byte. Out of range numbers go as their nearest (a status as No target).
]]
function Turrets.packState(status: number, feed: number, lure: boolean, tracking: boolean): number
	local code = if status == status
			and status >= 0
			and status <= MAX_STATUS
		then math.floor(status)
		else Turrets.STATUS.NO_TARGET
	local tier = if feed == feed then math.clamp(math.floor(feed), 0, Turrets.TIERS) else 0
	return code + 8 * tier + (if lure then 64 else 0) + (if tracking then 128 else 0)
end

--[[
	A state field read back: (status, feed, lure, tracking). Anything that is no packed state
	(not a whole number 0..255, a status or feed beyond theirs) reads as No target, by hand, the
	Lure off, not tracking.
]]
function Turrets.unpackState(state: number): (number, number, boolean, boolean)
	if type(state) ~= "number" or state ~= math.floor(state) or state < 0 or state > 255 then
		return Turrets.STATUS.NO_TARGET, 0, false, false
	end
	local status, feed = state % 8, (state // 8) % 8
	if status > MAX_STATUS or feed > Turrets.TIERS then
		return Turrets.STATUS.NO_TARGET, 0, false, false
	end
	return status, feed, (state // 64) % 2 == 1, state >= 128
end

--[[ The cell over the gun ]]

--[[
	Does the block in the cell above a turret let its gun work (see the header)? nil (unknown: an
	unloaded, unedited cell is generated terrain, where no block was put over a turret) and an
	unknown id count as clear.
]]
function Turrets.headClear(block: number?): boolean
	if block == nil or not Blocks.isValid(block) then
		return true
	end
	return not Blocks.isOpaque(block) and Blocks.obstruction(block) == nil
end

--[[ Optics ]]

local NO_OPTIC: Optic = table.freeze({ spread = 1, scan = SETTINGS.ScanTicks, range = 1, head = false })
local optics: { [Spec]: { [number]: Optic } } = {}
for _, spec in specs do
	local byItem: { [number]: Optic } = {}
	for opticName, optic in OPTICS do
		local item = itemOf(opticName, "optic")
		if spec.optics[item] then
			byItem[item] = table.freeze({
				spread = optic.spread or 1,
				scan = optic.scan or SETTINGS.ScanTicks,
				range = optic.range or 1,
				-- (A scope's head shots are the sniper's: its round kills in one there.)
				head = optic.head == true and spec.type == "sniper",
			})
		end
	end
	optics[spec] = table.freeze(byItem)
end

-- What the optic `item` (nil or 0: none) does on `spec` (one it takes no optic does nothing).
function Turrets.optic(spec: Spec, item: number?): Optic
	local list = optics[spec]
	local optic = if list and item then list[item] else nil
	return optic or NO_OPTIC
end

--[[ Slot outlines ]]

-- The three slots' outlines while empty (16 rows of 16: "G" a pixel): a round, a sight with
-- its lens, a suppressor's can.
Turrets.GHOSTS = table.freeze({
	ammo = table.freeze({
		"................",
		"................",
		".......GG.......",
		"......GGGG......",
		"......GGGG......",
		"......G..G......",
		"......G..G......",
		"......G..G......",
		"......G..G......",
		"......G..G......",
		"......G..G......",
		"......G..G......",
		"......GGGG......",
		"......GGGG......",
		"................",
		"................",
	}),
	optic = table.freeze({
		"................",
		"................",
		"................",
		"................",
		"....GGGGGGG.....",
		"...G.......G....",
		"..GG..GGG..GG...",
		"..GG..G.G..GG...",
		"..GG..GGG..GG...",
		"...G.......G....",
		"....GGGGGGG.....",
		"......G..G......",
		"....GGGGGGGG....",
		"................",
		"................",
		"................",
	}),
	muzzle = table.freeze({
		"................",
		"................",
		"................",
		"................",
		"................",
		"..GGGGGGGGGGG...",
		"..G.........GGG.",
		"..G.G.G.G.G...G.",
		"..G.........GGG.",
		"..GGGGGGGGGGG...",
		"................",
		"................",
		"................",
		"................",
		"................",
		"................",
	}),
} :: { [string]: { string } })

return table.freeze(Turrets)
