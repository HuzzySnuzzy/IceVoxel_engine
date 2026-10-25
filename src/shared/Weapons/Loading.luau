--!strict
--[[
	Loading weapons in the inventory, pure: DayZ's "combine" by clicks, and the weapon actions
	(Inventory/Types action kind "weapon"). Inventory/Menu runs both for the server (the authority)
	and for the client's prediction (Inventory/Prediction replays the same actions on a copy of the
	last snapshot), so everything here is deterministic: no Roblox APIs, no randomness, numeric
	loops only, and the same window and action always give the same result on both sides.

	Every weapon stack is read through Weapons/WeaponState.sane (a creative player's odd data never
	loads more than a gun holds) and every change is new data (Items.withData): data tables are
	values, never changed in place. A jammed round never comes out by hand: only clearing the jam
	(op 3) takes it, and it is lost.

	Clicks (`click`, from Inventory/Menu's PICKUP right after a crafting result's own rule, before
	Minecraft's: true = handled, the click is done; false = Minecraft's pickup runs as before).
	Button 0 is a left click, 1 a right click, on window slot `index` holding the current stack,
	with the carried one on the cursor:

	  Carried      Current                               Button  Result
	  rounds       a magazine of their calibre, empty     0 / 1   loads all that fit (the rest stays
	               or holding the same rounds, not full           carried) / one round
	  rounds       an internal-feed gun of their calibre  0 / 1   the chamber first (when empty),
	                                                              then the magazine (empty or the
	                                                              same rounds): all that fit / one
	  rounds       a detachable-feed gun of their         0 / 1   one round chambered by hand
	               calibre, its chamber empty
	  magazine     the gun it fits                        0       attached; one already in comes out
	                                                              onto the cursor (a swap), rounds
	                                                              and wear and all; the chamber
	                                                              stays as it was
	  attachment   a gun it fits                          0       mounted; the one in that slot
	                                                              comes onto the cursor (a light
	                                                              mounted is off)
	  any of them  the same family, refused (another      0       nothing ("blocked"); rounds are
	               calibre, full, other rounds, a part            refused on a right click too
	               that does not fit)
	  nothing      a magazine with rounds                 1       its rounds onto the cursor (one
	                                                              stack, at most the rounds' stack
	                                                              size; the rest stays)
	  nothing      a gun with something in it             1       the next thing out, in order: the
	                                                              magazine (its rounds and wear in
	                                                              it), else the internal rounds and
	                                                              the chambered round (one stack
	                                                              when they are the same rounds;
	                                                              else the first onto the cursor
	                                                              and the chambered one into the
	                                                              inventory, or left chambered when
	                                                              there is no room), else the muzzle
	                                                              device, the optic, the light
	  nothing      an empty gun or magazine               1       Minecraft's take-half (the whole
	                                                              item)

	Actions (`apply`, Inventory/Menu's `weapon` action; returns the stacks thrown out of the
	window). Ops 1..5 act on the held gun (slot HELD, -1; any other slot changes nothing), op 6 on
	the gun or magazine in window slot `slot` (or the held one, slot HELD). The server times them
	(server Weapons/, through Players/Inventories' weapon hooks); here they are instant.

	  1 reload     a jammed gun: nothing. A detachable feed: the fullest magazine it takes in the
	               inventory (slots 1..36) holding more rounds than the attached one (none
	               attached: at least one round; ties: the better condition, then the lower slot)
	               goes in, the attached one into that magazine's slot; then a round is chambered
	               when the chamber is empty and the magazine has one. No better magazine: the
	               chamber alone. An internal feed: as op 2
	  2 round      an internal feed, not jammed, not full: one round from the first inventory
	               stack of the rounds loaded (any of the calibre while the magazine is empty)
	               into the chamber when it is empty, else into the magazine
	  3 unjam      a jammed gun: the stuck round is lost (`jam` and `ch` go), then a round is
	               chambered from the magazine
	  4 mode       the next fire mode (guns with more than one), round to the first
	  5 light      the weapon light on or off (only with a light mounted)
	  6 detach     part `part` (Part): 1 the magazine, 2 the internal rounds and the chambered
	               round (on a magazine: its rounds), 3 the optic, 4 the muzzle device (its wear
	               with it), 5 the light, 6 the chambered round alone

	Creative (the instabuild ability) moves items as survival does, but rounds are free: op 2
	(and op 1 on an internal feed) loads a round without using one up (the inventory's first of
	the loaded rounds or of the calibre, else the loaded rounds, else the calibre's first), and op
	1 on a detachable feed with no better magazine in the inventory fills the attached magazine
	(a new one when none is attached) to its capacity with the rounds loaded, else the calibre's
	first, before chambering. Clicks are the same in every mode.

	Out-going stacks of op 6 go onto the cursor when it is empty (the HANDS chips are clicked in
	an open screen; Menu.close puts the cursor back into the inventory whenever a screen closes),
	the rest into the inventory (`ops.add`); what does not fit is thrown (returned). Ops 1..5 give
	nothing out but a swapped magazine, which goes into the slot its replacement came from.

	`combines` answers the screens' outline (Ui/Screens.feedbackAt): "combine" when a left click
	would load or attach, "blocked" when it is the same family but refused, nil otherwise.
	`kind` says what a click would do ("load", "attach", "unload", "blocked", or nil for
	Minecraft's), for the screen's sounds (item.firearm.load_round, attach, unload): it is the
	same reading `click` acts on.

	Inventory/Menu requires this module, so this module never requires Menu: Menu hands it its own
	slot functions (`MenuOps`: Menu.get, Menu.set, Menu.add).
]]

local Items = require(script.Parent.Parent.Items)
local Types = require(script.Parent.Parent.Inventory.Types)
local Weapons = require(script.Parent)
local WeaponState = require(script.Parent.WeaponState)

type Stack = Items.Stack
type Data = { [string]: any }

-- Inventory/Menu's slot functions (see the header).
export type MenuOps = {
	get: (window: Types.Window, index: number) -> Stack?,
	set: (window: Types.Window, index: number, stack: Stack?) -> (),
	add: (inventory: Types.Inventory, stack: Stack) -> Stack?,
}

export type Combine = "combine" | "blocked"
-- What a click does (see the header): nil is Minecraft's own.
export type Kind = "load" | "attach" | "unload" | "blocked"

local Loading = {}

-- The weapon actions' ops (Types action kind "weapon"), and detach's parts.
Loading.Op = table.freeze({ Reload = 1, LoadRound = 2, Unjam = 3, Mode = 4, Light = 5, Detach = 6 })
Loading.Part = table.freeze({ Magazine = 1, Rounds = 2, Optic = 3, Muzzle = 4, Light = 5, Chamber = 6 })
-- `slot` of the ops on the held gun.
Loading.HELD = -1

local Op, Part, HELD = Loading.Op, Loading.Part, Loading.HELD
local INVENTORY = Types.INVENTORY_SIZE
local HOTBAR = Types.HOTBAR_SIZE

-- What a right click with an empty cursor takes out of a gun, in order (see the header).
local UNLOAD_ORDER = table.freeze({ Part.Magazine, Part.Rounds, Part.Muzzle, Part.Optic, Part.Light })
-- The attachment slot of each attachment part.
local SLOT_OF: { [number]: Weapons.AttachmentSlot } =
	{ [Part.Optic] = "optic", [Part.Muzzle] = "muzzle", [Part.Light] = "light" }

--[[ Helpers ]]

local function isInt(value: any): boolean
	return type(value) == "number" and value == math.floor(value)
end

local function number(data: Items.Data?, key: string): number?
	local value = if data then data[key] else nil
	return if type(value) == "number" then value else nil
end

-- A stack in a slot (nil for none or a count below 1).
local function present(stack: Stack?): Stack?
	return if stack and stack.count >= 1 then stack else nil
end

-- A changeable copy of a (sane) stack's data.
local function dataOf(stack: Stack): Data
	local data = stack.data
	return if data then table.clone(data) :: Data else {}
end

-- `stack` with `data` (none when empty).
local function withData(stack: Stack, data: Data): Stack
	return Items.withData(stack, if next(data) == nil then nil else data)
end

-- `stack` when `data` changes something in it, else nil (nothing to write).
local function changed(stack: Stack, data: Data): Stack?
	local after = withData(stack, data)
	return if Items.sameData(stack.data, after.data) then nil else after
end

-- `count` rounds of `round` (nil for none).
local function roundsOf(round: number, count: number): Stack?
	return Items.newStack(round, count, nil, nil)
end

-- A magazine item as a stack: its wear and `n` rounds of `round`.
local function magazineStack(item: number, wear: number, n: number, round: number?): Stack
	local data = if n > 0 and round then Items.cleanData({ n = n, ammo = round }) else nil
	return Items.newStack(item, 1, wear, data) :: Stack
end

-- Sets the rounds (`n` of `round`) in a gun's or a magazine's data (none: both keys go).
local function setRounds(data: Data, n: number, round: number?)
	if n > 0 and round then
		data.n = n
		data.ammo = round
	else
		data.n = nil
		data.ammo = nil
	end
end

-- Chambers a round from the magazine when the chamber is empty and the magazine has one.
local function chamberFromMagazine(data: Data)
	if data.ch ~= nil then
		return
	end
	local n = number(data, "n") or 0
	local round = number(data, "ammo")
	if n > 0 and round then
		data.ch = round
		setRounds(data, n - 1, round)
	end
end

--[[ Loading rounds ]]

-- How many rounds of `round` the (sane) magazine `mag` takes: its free room when it is empty or
-- holds the same rounds and takes the calibre, else 0.
local function magazineRoom(mag: Stack, round: number): number
	local spec = Weapons.magazine(mag.item)
	if spec == nil or not Weapons.takes(mag.item, round) then
		return 0
	end
	local n, ammo = WeaponState.rounds(mag)
	if n > 0 and ammo ~= round then
		return 0
	end
	return math.max(0, spec.capacity - n)
end

-- How many rounds of `round` the (sane) gun `gun` takes by hand: its chamber when empty (a jam
-- keeps its round in it), and an internal magazine's room when it is empty or holds the same.
local function gunRoom(gun: Stack, round: number): number
	local spec = Weapons.firearm(gun.item)
	if spec == nil or not Weapons.takes(gun.item, round) then
		return 0
	end
	local data = gun.data
	local room = if number(data, "ch") == nil then 1 else 0
	if spec.magazine == nil then
		local n = number(data, "n") or 0
		if n == 0 or number(data, "ammo") == round then
			room += math.max(0, spec.internal - n)
		end
	end
	return room
end

-- The (sane) gun with up to `count` rounds of `round` loaded by hand (the chamber first, then an
-- internal magazine), and how many went in. The caller checked the calibre (gunRoom).
local function loadGun(gun: Stack, round: number, count: number): (Stack, number)
	local spec = Weapons.firearm(gun.item) :: Weapons.FirearmSpec
	local data = dataOf(gun)
	local loaded = 0
	if count > 0 and data.ch == nil then
		data.ch = round
		loaded = 1
	end
	if spec.magazine == nil and loaded < count then
		local n = number(data, "n") or 0
		if n == 0 or data.ammo == round then
			local add = math.min(spec.internal - n, count - loaded)
			if add > 0 then
				setRounds(data, n + add, round)
				loaded += add
			end
		end
	end
	return withData(gun, data), loaded
end

-- The (sane) magazine with up to `count` rounds of `round` loaded, and how many went in.
local function loadMagazine(mag: Stack, round: number, count: number): (Stack, number)
	local add = math.min(magazineRoom(mag, round), count)
	if add <= 0 then
		return mag, 0
	end
	local n = WeaponState.rounds(mag)
	local data = dataOf(mag)
	setRounds(data, n + add, round)
	return withData(mag, data), add
end

--[[ Taking parts out ]]

--[[
	Takes part `part` (Part) out of the (sane) gun or magazine `stack`: what comes out, in order
	(the first the main one; nil: nothing to take), and the stack after. A gun's Rounds are its
	internal rounds and its chambered round (one stack when they are the same rounds, the
	chambered one second otherwise; a detachable feed's rounds are its magazine's, so only the
	chamber); a magazine's Rounds are its rounds, at most a stack of them. A jammed round never
	comes out.
]]
local function take(stack: Stack, part: number): ({ Stack }?, Stack)
	local gun = Weapons.firearm(stack.item)
	local data = dataOf(stack)
	if gun == nil then
		-- A magazine: only its rounds.
		local n, round = WeaponState.rounds(stack)
		if part ~= Part.Rounds or n <= 0 or round == nil then
			return nil, stack
		end
		local out = math.min(n, Items.maxStack(round))
		setRounds(data, n - out, round)
		return { roundsOf(round, out) :: Stack }, withData(stack, data)
	end
	local jammed = data.jam == true
	local chambered = if jammed then nil else number(data, "ch")
	if part == Part.Magazine then
		local mag = number(data, "mag")
		if mag == nil then
			return nil, stack
		end
		local out = magazineStack(mag, number(data, "magD") or 0, number(data, "n") or 0, number(data, "ammo"))
		data.mag, data.magD = nil, nil
		setRounds(data, 0, nil)
		return { out }, withData(stack, data)
	elseif part == Part.Rounds then
		local n = if gun.magazine == nil then number(data, "n") or 0 else 0
		local round = number(data, "ammo")
		local out: { Stack } = {}
		if n > 0 and round then
			if chambered == round then
				table.insert(out, roundsOf(round, n + 1) :: Stack)
				data.ch = nil
			else
				table.insert(out, roundsOf(round, n) :: Stack)
				if chambered then
					table.insert(out, roundsOf(chambered, 1) :: Stack)
					data.ch = nil
				end
			end
			setRounds(data, 0, nil)
		elseif chambered then
			table.insert(out, roundsOf(chambered, 1) :: Stack)
			data.ch = nil
		end
		if #out == 0 then
			return nil, stack
		end
		return out, withData(stack, data)
	elseif part == Part.Chamber then
		if chambered == nil then
			return nil, stack
		end
		data.ch = nil
		return { roundsOf(chambered, 1) :: Stack }, withData(stack, data)
	end
	local slot = SLOT_OF[part]
	local item = if slot then number(data, slot) else nil
	if slot == nil or item == nil then
		return nil, stack
	end
	local wear = 0
	data[slot] = nil
	if slot == "muzzle" then
		wear = number(data, "muzzleD") or 0
		data.muzzleD = nil
	elseif slot == "light" then
		data.lit = nil
	end
	return { Items.newStack(item, 1, wear, nil) :: Stack }, withData(stack, data)
end

--[[ What a click does ]]

--[[
	What a click with `button` (0 left, 1 right) on `current` with `carried` on the cursor does
	(see the header): "load", "attach", "unload", "blocked", or nil for Minecraft's own click.
]]
function Loading.kind(carried: Stack?, current: Stack?, button: number): Kind?
	local slot = present(current)
	if slot == nil or (button ~= 0 and button ~= 1) then
		return nil
	end
	local cursor = present(carried)
	local gun = Weapons.firearm(slot.item)
	local isMagazine = Weapons.magazine(slot.item) ~= nil
	if gun == nil and not isMagazine then
		return nil
	end
	local stack = WeaponState.sane(slot)
	if cursor == nil then
		if button ~= 1 then
			return nil
		end
		local order: { number } = if gun then UNLOAD_ORDER else { Part.Rounds }
		for _, part in order do
			if take(stack, part) ~= nil then
				return "unload"
			end
		end
		return nil
	end
	local item = cursor.item
	if Weapons.ammo(item) then
		local room = if gun then gunRoom(stack, item) else magazineRoom(stack, item)
		return if room > 0 then "load" else "blocked"
	elseif button ~= 0 or gun == nil then
		return nil
	elseif Weapons.magazine(item) then
		return if gun.magazine == item then "attach" else "blocked"
	elseif Weapons.attachment(item) then
		return if Weapons.fits(item, gun.item) then "attach" else "blocked"
	end
	return nil
end

-- The screens' outline for `carried` over `current` (see the header).
function Loading.combines(carried: Stack?, current: Stack?): Combine?
	local kind = Loading.kind(carried, current, 0)
	if kind == "load" or kind == "attach" then
		return "combine"
	elseif kind == "blocked" then
		return "blocked"
	end
	return nil
end

--[[ Clicks ]]

-- A right click with an empty cursor on the gun or magazine in window slot `index`: the next
-- thing out onto the cursor (see the header). false when there is nothing to take.
local function unload(window: Types.Window, index: number, current: Stack, ops: MenuOps): boolean
	local stack = WeaponState.sane(current)
	local order: { number } = if Weapons.firearm(stack.item) then UNLOAD_ORDER else { Part.Rounds }
	for _, part in order do
		local out, after = take(stack, part)
		if out then
			local inventory = window.inventory
			-- (Only a gun's chambered round of other rounds comes second: into the inventory, or
			-- left chambered without room.)
			local second = out[2]
			if second and ops.add(inventory, second) ~= nil then
				local data = dataOf(after)
				data.ch = second.item
				after = withData(after, data)
			end
			ops.set(window, index, after)
			inventory.cursor = out[1]
			return true
		end
	end
	return false
end

--[[
	A PICKUP click (`button` 0 or 1) on window slot `index` (see the header): true when the
	weapon rules handled it (the click is done), false to let Minecraft's pickup run.
]]
function Loading.click(window: Types.Window, index: number, button: number, ops: MenuOps): boolean
	if not isInt(index) or (button ~= 0 and button ~= 1) then
		return false
	end
	local current = present(ops.get(window, index))
	local kind = Loading.kind(window.inventory.cursor, current, button)
	if kind == nil or current == nil then
		return false
	elseif kind == "blocked" then
		return true
	end
	local inventory = window.inventory
	if kind == "unload" then
		return unload(window, index, current, ops)
	end
	local carried = present(inventory.cursor) :: Stack
	local stack = WeaponState.sane(current)
	local gun = Weapons.firearm(stack.item)
	if kind == "load" then
		local want = if button == 0 then carried.count else 1
		local after, loaded
		if gun then
			after, loaded = loadGun(stack, carried.item, want)
		else
			after, loaded = loadMagazine(stack, carried.item, want)
		end
		if loaded > 0 then
			ops.set(window, index, after)
			inventory.cursor = Items.newStack(carried.item, carried.count - loaded, carried.damage, carried.data)
		end
		return true
	end
	-- Attaching: a magazine or an attachment onto its gun, the old one onto the cursor.
	local data = dataOf(stack)
	local out: Stack? = nil
	if Weapons.magazine(carried.item) then
		local old = number(data, "mag")
		if old then
			out = magazineStack(old, number(data, "magD") or 0, number(data, "n") or 0, number(data, "ammo"))
		end
		local magazine = WeaponState.sane(carried)
		local n, round = WeaponState.rounds(magazine)
		data.mag = carried.item
		data.magD = Items.cleanDamage(magazine.damage)
		setRounds(data, n, round)
	else
		local spec = Weapons.attachment(carried.item) :: Weapons.AttachmentSpec
		local slot = spec.slot
		local old = number(data, slot)
		local wear = 0
		data[slot] = carried.item
		if slot == "muzzle" then
			wear = number(data, "muzzleD") or 0
			data.muzzleD = Items.cleanDamage(carried.damage)
		elseif slot == "light" then
			data.lit = nil
		end
		if old then
			out = Items.newStack(old, 1, wear, nil)
		end
	end
	ops.set(window, index, withData(stack, data))
	inventory.cursor = out
	return true
end

--[[ Weapon actions ]]

-- A calibre's default round (WeaponList `default`).
local function firstRound(calibre: string): number?
	return Weapons.defaultRound(calibre)
end

-- Op 2 (and op 1 on an internal feed): one round by hand (see the header); nil: nothing changes.
local function loadRound(inventory: Types.Inventory, spec: Weapons.FirearmSpec, gun: Stack, creative: boolean): Stack?
	if spec.magazine ~= nil or WeaponState.jammed(gun) then
		return nil
	end
	local data = gun.data
	local n = number(data, "n") or 0
	local loaded = if n > 0 then number(data, "ammo") else nil
	if number(data, "ch") ~= nil and n >= spec.internal then
		return nil
	end
	local from: number? = nil
	for slot = 1, INVENTORY do
		local stack = present(inventory.slots[slot])
		if stack and (if loaded then stack.item == loaded else Weapons.takes(spec.item, stack.item)) then
			from = slot
			break
		end
	end
	local round: number? = nil
	if from then
		round = (inventory.slots[from] :: Stack).item
	elseif creative then
		round = loaded or firstRound(spec.calibre)
	end
	if round == nil then
		return nil
	end
	local after, count = loadGun(gun, round, 1)
	if count == 0 then
		return nil
	end
	if from and not creative then
		local stack = inventory.slots[from] :: Stack
		inventory.slots[from] = Items.newStack(stack.item, stack.count - 1, stack.damage, stack.data)
	end
	return after
end

-- Op 1: reload (see the header); nil: nothing changes.
local function reload(inventory: Types.Inventory, spec: Weapons.FirearmSpec, gun: Stack, creative: boolean): Stack?
	if WeaponState.jammed(gun) then
		return nil
	end
	local magazineItem = spec.magazine
	if magazineItem == nil then
		return loadRound(inventory, spec, gun, creative)
	end
	local data = dataOf(gun)
	local attached = number(data, "mag")
	local have = if attached then number(data, "n") or 0 else 0
	-- The fullest magazine in the inventory with more rounds; ties: the better condition, then the
	-- lower slot.
	local best: number? = nil
	local bestRounds, bestWear = have, math.huge
	for slot = 1, INVENTORY do
		local stack = present(inventory.slots[slot])
		if stack and stack.item == magazineItem then
			local magazine = WeaponState.sane(stack)
			local n = WeaponState.rounds(magazine)
			local wear = Items.cleanDamage(magazine.damage) or 0
			if n > bestRounds or (best ~= nil and n == bestRounds and wear < bestWear) then
				best, bestRounds, bestWear = slot, n, wear
			end
		end
	end
	if best then
		local magazine = WeaponState.sane(inventory.slots[best] :: Stack)
		local n, round = WeaponState.rounds(magazine)
		inventory.slots[best] = if attached
			then magazineStack(attached, number(data, "magD") or 0, have, number(data, "ammo"))
			else nil
		data.mag = magazineItem
		data.magD = Items.cleanDamage(magazine.damage)
		setRounds(data, n, round)
	elseif creative then
		local capacity = (Weapons.magazine(magazineItem) :: Weapons.MagazineSpec).capacity
		local round = number(data, "ammo") or firstRound(spec.calibre)
		if (attached == nil or have < capacity) and round then
			data.mag = magazineItem
			setRounds(data, capacity, round)
		end
	end
	chamberFromMagazine(data)
	return changed(gun, data)
end

-- Op 3: clears a jam (the round is lost) and chambers the next.
local function unjam(gun: Stack): Stack?
	if not WeaponState.jammed(gun) then
		return nil
	end
	local data = dataOf(gun)
	data.jam = nil
	data.ch = nil
	chamberFromMagazine(data)
	return changed(gun, data)
end

-- Op 4: the next fire mode (round to the first).
local function nextMode(spec: Weapons.FirearmSpec, gun: Stack): Stack?
	local modes = #spec.modes
	if modes <= 1 then
		return nil
	end
	local data = dataOf(gun)
	local mode = WeaponState.modeIndex(gun) % modes + 1
	data.mode = if mode > 1 then mode else nil
	return changed(gun, data)
end

-- Op 5: the light on or off.
local function flipLight(gun: Stack): Stack?
	local data = dataOf(gun)
	if data.light == nil then
		return nil
	end
	data.lit = if data.lit == true then nil else true
	return changed(gun, data)
end

-- Op 6: takes part `part` out of the gun or magazine in window slot `slot` (HELD: the held one).
local function detach(window: Types.Window, slot: number, part: any, ops: MenuOps): { Stack }
	if not isInt(part) then
		return {}
	end
	local inventory = window.inventory
	local selected = inventory.selected
	local current: Stack?
	if slot == HELD then
		if not isInt(selected) or selected < 1 or selected > HOTBAR then
			return {}
		end
		current = present(inventory.slots[selected])
	else
		current = present(ops.get(window, slot))
	end
	if current == nil or (Weapons.firearm(current.item) == nil and Weapons.magazine(current.item) == nil) then
		return {}
	end
	local out, after = take(WeaponState.sane(current), part)
	if out == nil then
		return {}
	end
	if slot == HELD then
		inventory.slots[selected] = after
	else
		ops.set(window, slot, after)
	end
	local thrown: { Stack } = {}
	for index, stack in out do
		if index == 1 and present(inventory.cursor) == nil then
			inventory.cursor = stack
		else
			local left = ops.add(inventory, stack)
			if left then
				table.insert(thrown, left)
			end
		end
	end
	return thrown
end

-- A weapon action (see the header): the stacks thrown out of the window.
function Loading.apply(window: Types.Window, action: Types.Action, creative: boolean, ops: MenuOps): { Stack }
	if type(action) ~= "table" or action.kind ~= "weapon" then
		return {}
	end
	local op, slot = action.op, action.slot
	if not isInt(op) or not isInt(slot) then
		return {}
	elseif op == Op.Detach then
		return detach(window, slot, action.part, ops)
	elseif op < Op.Reload or op > Op.Light or slot ~= HELD then
		return {}
	end
	local inventory = window.inventory
	local selected = inventory.selected
	if not isInt(selected) or selected < 1 or selected > HOTBAR then
		return {}
	end
	local held = present(inventory.slots[selected])
	local spec = if held then Weapons.firearm(held.item) else nil
	if held == nil or spec == nil then
		return {}
	end
	local gun = WeaponState.sane(held)
	local after: Stack? = nil
	if op == Op.Reload then
		after = reload(inventory, spec, gun, creative)
	elseif op == Op.LoadRound then
		after = loadRound(inventory, spec, gun, creative)
	elseif op == Op.Unjam then
		after = unjam(gun)
	elseif op == Op.Mode then
		after = nextMode(spec, gun)
	else
		after = flipLight(gun)
	end
	if after then
		inventory.slots[selected] = after
	end
	return {}
end

return Loading
