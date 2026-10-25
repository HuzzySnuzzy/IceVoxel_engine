--!strict
--[[
	What a weapon stack holds, kept in its item data (Items `data`: Minecraft's NBT, flat, at most
	Items.MAX_DATA_KEYS keys), pure. Values are numbers or booleans; a key left out is its default:

	  Key      On                  Meaning
	  ch       firearm             the ammunition item of the chambered round (none: empty)
	  jam      firearm             true: that round is stuck, the gun can't fire until cleared
	  n        firearm, magazine   rounds in the attached or internal magazine, or in this magazine
	                               (none: 0)
	  ammo     firearm, magazine   the ammunition item of those rounds (none when `n` is 0)
	  mag      firearm             the attached magazine item (a detachable feed only)
	  magD     firearm             that magazine's wear (its stack's `damage`)
	  mode     firearm             the fire mode, an index into its modes (none: 1)
	  optic, muzzle, light         the attachment items mounted
	  muzzleD  firearm             the muzzle device's wear
	  lit      firearm             the weapon light is on

	Twelve keys at most (with `jam` only beside `ch`). Data tables are frozen values: every change
	makes new data (Items.withData), never one changed in place. The keys holding item ids are
	listed in Items/ItemData.ID_KEYS too (saves keep them by name): a new one goes there as well.

	Everything that reads a weapon stack reads it through `sane`: a clamped copy (the same table
	when nothing needed changing), so a creative player's odd data (Inventory/Menu lets creative
	slots carry any valid data) never fires more than the gun holds: `n` within 0..the capacity,
	`ch` and `ammo` rounds of the gun's calibre (else dropped; rounds without a kind go too), a
	magazine only on the gun it fits and only on a detachable feed, attachments only in their slot
	and only where they fit, wear within the part's durability, `mode` within the gun's modes,
	`lit` only with a light, `jam` only with a round chambered; unknown keys are dropped. Stacks
	that are no firearm or magazine come back as they are.

	Firing (`fire`, server Weapons/ and the client's prediction alike through Inventory/Menu's
	`fire` action):
	  1. `canFire` first: a Ruined gun (Weapons.level 5: durability left at or below 0.2) never
	     fires ("ruined"), a jammed one neither ("jammed"), an empty chamber is "empty" (creative
	     fires without a round). Refused: nil.
	  2. Creative (instabuild): the stack comes back unchanged: rounds and wear are free (as
	     Shared/Magic/Casting.free).
	  3. The chamber empties; the gun wears 1 (`damage`, at most its durability: guns never
	     break), a muzzle device with a durability 1 (`muzzleD`, at most its own), the attached
	     magazine 1 (`magD`, at most its own).
	  4. The next round feeds from the magazine (`n` - 1 into `ch`; at 0 `n` and `ammo` go). Pumps
	     and bolts cycle by themselves (their rate includes it).
	  5. `jam` (rolled by the server: Weapons/Handling.jamChance) sticks the round just fed: a
	     jam is a feeding failure, so the last round never jams.

	The HUD and HANDS (`detail`): a detachable feed "12 / 15" (" +1" with a round chambered), or
	"No magazine" (" +1" too); an internal one "4 / 6" (the chamber counted, its round too); then
	" AUTO" or " SEMI" for guns with more than one mode; "JAMMED" instead of all of it while
	jammed. A magazine "12 / 15". The icon's count box (`shownCount`): a gun's rounds and its
	chambered one, a magazine's rounds, nil for none.

	`lookKey` is what other clients need to dress a held gun (Inventory/Types
	.HELD_LOOK_ATTRIBUTE): "mag,optic,muzzle,light,lit" as item ids (0 for none) and 1/0 for the
	light, "" for anything that is no firearm.
]]

local Items = require(script.Parent.Parent.Items)
local Weapons = require(script.Parent)

type Stack = Items.Stack
type Data = Items.Data

local WeaponState = {}

-- Every key a weapon stack's data may hold (see the header).
WeaponState.KEYS =
	table.freeze({ "ch", "jam", "n", "ammo", "mag", "magD", "mode", "optic", "muzzle", "muzzleD", "light", "lit" })
-- Refusal reasons of `canFire`.
WeaponState.RUINED = "ruined"
WeaponState.JAMMED = "jammed"
WeaponState.EMPTY = "empty"

-- `value` as a whole number clamped to `most`, nil when it is no number or below `least` (before
-- or after clamping).
local function whole(value: any, least: number, most: number): number?
	if type(value) ~= "number" or value ~= value then
		return nil
	end
	local n = math.min(math.floor(value), most)
	return if n >= least then n else nil
end

-- The durability of `item` (nil: it doesn't wear).
local function durabilityOf(item: number?): number?
	local def = if item then Items.get(item) else nil
	return if def then def.durability else nil
end

-- Do two data hold the same keys and values (both nil alike)?
local same = Items.sameData

-- A clean firearm's data from `data` (empty: none).
local function saneFirearm(spec: Weapons.FirearmSpec, data: Data): { [string]: Items.DataValue }
	local out: { [string]: Items.DataValue } = {}
	local item = spec.item
	-- The chambered round (any round of the calibre), and a jam only on it.
	local ch = data.ch
	if type(ch) == "number" and Weapons.takes(item, ch) then
		out.ch = ch
		if data.jam == true then
			out.jam = true
		end
	end
	-- The magazine: on a detachable feed, the one it takes.
	local capacity = spec.internal
	local mag = spec.magazine
	if mag ~= nil and data.mag == mag then
		out.mag = mag
		local magazine = Weapons.magazine(mag) :: Weapons.MagazineSpec
		capacity = magazine.capacity
		local wear = whole(data.magD, 1, durabilityOf(mag) or 0)
		if wear then
			out.magD = wear
		end
	elseif mag ~= nil then
		-- (No magazine: no rounds.)
		capacity = 0
	end
	local n = whole(data.n, 1, capacity)
	local ammo = data.ammo
	if n and type(ammo) == "number" and Weapons.takes(item, ammo) then
		out.n = n
		out.ammo = ammo
	end
	local mode = whole(data.mode, 2, #spec.modes)
	if mode then
		out.mode = mode
	end
	for _, slot in Weapons.SLOTS do
		local part = data[slot]
		local attachment = if type(part) == "number" then Weapons.attachment(part) else nil
		if attachment and attachment.slot == slot and Weapons.fits(attachment.item, item) then
			out[slot] = attachment.item
		end
	end
	local muzzle = out.muzzle
	if type(muzzle) == "number" then
		local wear = whole(data.muzzleD, 1, durabilityOf(muzzle) or 0)
		if wear then
			out.muzzleD = wear
		end
	end
	if out.light ~= nil and data.lit == true then
		out.lit = true
	end
	return out
end

-- A clean magazine's data (empty: none).
local function saneMagazine(spec: Weapons.MagazineSpec, data: Data): { [string]: Items.DataValue }
	local out: { [string]: Items.DataValue } = {}
	local n = whole(data.n, 1, spec.capacity)
	local ammo = data.ammo
	if n and type(ammo) == "number" and Weapons.takes(spec.item, ammo) then
		out.n = n
		out.ammo = ammo
	end
	return out
end

--[[
	`stack` with its weapon data clamped (see the header): the same table when it was sane already,
	else a copy with clean, frozen data. Stacks that are no firearm or magazine come back as they
	are.
]]
function WeaponState.sane(stack: Stack): Stack
	local gun = Weapons.firearm(stack.item)
	local mag = if gun then nil else Weapons.magazine(stack.item)
	if gun == nil and mag == nil then
		return stack
	end
	local data = stack.data or {}
	local clean = if gun then saneFirearm(gun, data) else saneMagazine(mag :: Weapons.MagazineSpec, data)
	local cleaned: Data? = if next(clean) == nil then nil else clean
	if same(stack.data, cleaned) then
		return stack
	end
	return Items.withData(stack, cleaned)
end

local function number(data: Data?, key: string): number?
	local value = if data then data[key] else nil
	return if type(value) == "number" then value else nil
end

-- The ammunition item of the chambered round (nil: the chamber is empty).
function WeaponState.chamber(stack: Stack): number?
	return number(WeaponState.sane(stack).data, "ch")
end

-- Is the chambered round stuck?
function WeaponState.jammed(stack: Stack): boolean
	local data = WeaponState.sane(stack).data
	return data ~= nil and data.jam == true
end

-- Rounds in the magazine (a firearm's attached or internal one, or a magazine's own) and their
-- ammunition item (nil when there are none).
function WeaponState.rounds(stack: Stack): (number, number?)
	local data = WeaponState.sane(stack).data
	local n = number(data, "n") or 0
	return n, if n > 0 then number(data, "ammo") else nil
end

--[[
	How many rounds `item` holds besides a chamber: a magazine's capacity, an internal magazine's
	rounds, or for a detachable feed the capacity of the magazine it takes. 0 for anything else.
]]
function WeaponState.capacity(item: number): number
	local mag = Weapons.magazine(item)
	if mag then
		return mag.capacity
	end
	local gun = Weapons.firearm(item)
	if gun == nil then
		return 0
	end
	local magazine = Weapons.magazine(gun.magazine)
	return if magazine then magazine.capacity else gun.internal
end

-- The attached magazine item (nil: none) and its wear (0: new).
function WeaponState.magazine(stack: Stack): (number?, number)
	local data = WeaponState.sane(stack).data
	local mag = number(data, "mag")
	return mag, if mag then number(data, "magD") or 0 else 0
end

-- The attachment in `slot` ("optic", "muzzle" or "light"; nil: none) and its wear (0: new; only a
-- muzzle device wears).
function WeaponState.attachment(stack: Stack, slot: Weapons.AttachmentSlot): (number?, number)
	local data = WeaponState.sane(stack).data
	local part = number(data, slot)
	local wear = if part and slot == "muzzle" then number(data, "muzzleD") or 0 else 0
	return part, wear
end

-- The fire mode's index (1 the first) into the firearm's modes.
function WeaponState.modeIndex(stack: Stack): number
	return number(WeaponState.sane(stack).data, "mode") or 1
end

-- The fire mode: "semi" or "auto" ("semi" for anything that is no firearm).
function WeaponState.mode(stack: Stack): Weapons.FireModeKind
	local gun = Weapons.firearm(stack.item)
	if gun == nil then
		return "semi"
	end
	local mode = gun.modes[WeaponState.modeIndex(stack)] or gun.modes[1]
	return mode.kind
end

-- Durability left (0..1) of `item` worn by `damage`: 1 for an item that doesn't wear.
function WeaponState.fraction(item: number, damage: number?): number
	local durability = durabilityOf(item)
	if durability == nil or durability <= 0 then
		return 1
	end
	local worn = Items.cleanDamage(damage) or 0
	return math.clamp((durability - worn) / durability, 0, 1)
end

--[[
	May the firearm fire now (see the header)? false and why: "ruined", "jammed" or "empty" (no
	round chambered; `creative` fires without one). false and nil for anything that is no firearm.
]]
function WeaponState.canFire(stack: Stack, creative: boolean): (boolean, string?)
	if Weapons.firearm(stack.item) == nil then
		return false, nil
	end
	local clean = WeaponState.sane(stack)
	if Weapons.level(WeaponState.fraction(clean.item, clean.damage)) >= Weapons.RUINED then
		return false, WeaponState.RUINED
	end
	local data = clean.data
	if data and data.jam == true then
		return false, WeaponState.JAMMED
	end
	if not creative and number(data, "ch") == nil then
		return false, WeaponState.EMPTY
	end
	return true, nil
end

--[[
	The firearm after one shot (see the header: the chamber empties, wear, the next round fed, a
	jam when `jam` and a round was fed); `stack` itself unchanged in creative; nil when it can't
	fire.
]]
function WeaponState.fire(stack: Stack, jam: boolean, creative: boolean): Stack?
	if not WeaponState.canFire(stack, creative) then
		return nil
	end
	if creative then
		return stack
	end
	local clean = WeaponState.sane(stack)
	local data: { [string]: any } = if clean.data then table.clone(clean.data) else {}
	data.ch = nil
	local durability = durabilityOf(clean.item) or 0
	local damage = math.min((Items.cleanDamage(clean.damage) or 0) + 1, durability)
	local muzzle = number(data, "muzzle")
	local muzzleDurability = durabilityOf(muzzle)
	if muzzle and muzzleDurability then
		data.muzzleD = math.min((number(data, "muzzleD") or 0) + 1, muzzleDurability)
	end
	local mag = number(data, "mag")
	local magDurability = durabilityOf(mag)
	if mag and magDurability then
		data.magD = math.min((number(data, "magD") or 0) + 1, magDurability)
	end
	local n = number(data, "n") or 0
	local fed = false
	if n > 0 then
		data.ch = data.ammo
		fed = true
		if n > 1 then
			data.n = n - 1
		else
			data.n = nil
			data.ammo = nil
		end
	end
	if jam and fed then
		data.jam = true
	end
	local fired = Items.withData(clean, data)
	fired.damage = Items.cleanDamage(damage)
	return fired
end

-- What other clients need to dress a held firearm (see the header): "" for anything else.
function WeaponState.lookKey(stack: Stack?): string
	if stack == nil or Weapons.firearm(stack.item) == nil then
		return ""
	end
	local data = WeaponState.sane(stack).data
	local function id(key: string): number
		return number(data, key) or 0
	end
	local lit = if data and data.lit == true then 1 else 0
	return `{id("mag")},{id("optic")},{id("muzzle")},{id("light")},{lit}`
end

-- The HUD's and HANDS' detail line of a firearm or a magazine (see the header); nil for others.
function WeaponState.detail(stack: Stack?): string?
	if stack == nil then
		return nil
	end
	local gun = Weapons.firearm(stack.item)
	local magSpec = Weapons.magazine(stack.item)
	if gun == nil and magSpec == nil then
		return nil
	end
	local clean = WeaponState.sane(stack)
	local data = clean.data
	local n = number(data, "n") or 0
	if gun == nil then
		return `{n} / {(magSpec :: Weapons.MagazineSpec).capacity}`
	end
	if data and data.jam == true then
		return "JAMMED"
	end
	local chambered = number(data, "ch") ~= nil
	local text: string
	if gun.magazine ~= nil then
		local mag = number(data, "mag")
		text = if mag then `{n} / {WeaponState.capacity(clean.item)}` else "No magazine"
		if chambered then
			text ..= " +1"
		end
	else
		text = `{n + (if chambered then 1 else 0)} / {gun.internal + 1}`
	end
	if #gun.modes > 1 then
		text ..= if WeaponState.mode(clean) == "auto" then " AUTO" else " SEMI"
	end
	return text
end

-- The count an icon shows for a firearm (its rounds and the chambered one) or a magazine (its
-- rounds); nil for none, and for anything else.
function WeaponState.shownCount(stack: Stack?): number?
	if stack == nil then
		return nil
	end
	local gun = Weapons.firearm(stack.item)
	if gun == nil and Weapons.magazine(stack.item) == nil then
		return nil
	end
	local data = WeaponState.sane(stack).data
	local count = (number(data, "n") or 0) + (if gun and number(data, "ch") then 1 else 0)
	return if count > 0 then count else nil
end

return WeaponState
