--[[
	Loading weapons in the inventory (Shared/Weapons/Loading, through Inventory/Menu as the server
	and the client's prediction both run it): every combine of the weapons design's section 4.4
	(rounds onto magazines and guns, partial loads, the chamber first, mixed rounds and wrong
	calibres refused, magazines and attachments attached with the old part back on the cursor,
	right clicks unloading one thing at a time, empty items falling through to Minecraft's
	take-half), `combines` and `kind` for every pair of items, the weapon actions of 4.5 (reload
	picking the fullest magazine, a round by hand, a jam cleared, the fire mode, the light,
	detaching to the cursor, the inventory or the ground), creative's free rounds, and the client's
	prediction agreeing with the server's Players/InventoryState action by action. Last, the real
	Ui/InventoryScreen on a fake client (tests/lib/FakeClient, as tests/spec/SurvivalLookGlue): a
	held gun's HANDS chips show its parts, say what they are and send detach for the held slot.
]]

local roblox = require("@lune/roblox")
local FakeClient = require("../lib/FakeClient")

return function(t, shared, require, server, client)
	local Items = require(shared.Items)
	local Weapons = require(shared.Weapons)
	local WeaponState = require(shared.Weapons.WeaponState)
	local Loading = require(shared.Weapons.Loading)
	local Types = require(shared.Inventory.Types)
	local Menu = require(shared.Inventory.Menu)
	local Protocol = require(shared.Net.Protocol)
	local GameMode = require(shared.GameMode)
	local Prediction = require(client.Inventory.Prediction)
	local InventoryState = require(server.Players.InventoryState)

	local I = Items.id
	local Op, Part, HELD = Loading.Op, Loading.Part, Loading.HELD
	local PICKUP = Menu.ClickType.Pickup
	local SURVIVAL = GameMode.SURVIVAL

	--[[ Helpers ]]

	-- A stack of `count` (1) `item` with weapon data `data` and wear `damage`.
	local function stack(item: number, data: { [string]: any }?, damage: number?, count: number?): Items.Stack
		return { item = item, count = count or 1, damage = damage, data = Items.cleanData(data) }
	end

	local function rounds(item: number, count: number): Items.Stack
		return stack(item, nil, nil, count)
	end

	-- The value a stack's data keeps under `key` (nil: none).
	local function key(s: Items.Stack?, name: string): any
		return if s and s.data then s.data[name] else nil
	end

	-- Window 0 with an empty inventory (hotbar slot 1 selected).
	local function newWindow(): Types.Window
		return Types.newWindow(Types.newInventory())
	end

	-- The window slot of inventory slot `slot`.
	local function at(window: Types.Window, slot: number): number
		return Menu.windowIndex(window, "inventory", slot) :: number
	end

	-- A PICKUP click on inventory slot `slot` (0 left, 1 right).
	local function click(window: Types.Window, slot: number, button: number, creative: boolean?): { Items.Stack }
		return Menu.apply(window, {
			kind = "click",
			window = window.id,
			slot = at(window, slot),
			clickType = PICKUP,
			button = button,
		}, creative == true)
	end

	-- A weapon action.
	local function weapon(
		window: Types.Window,
		op: number,
		slot: number,
		part: number?,
		creative: boolean?
	): { Items.Stack }
		return Menu.apply(window, { kind = "weapon", op = op, slot = slot, part = part or 0 }, creative == true)
	end

	-- Do two stacks hold the same (nil alike)?
	local function same(a: Items.Stack?, b: Items.Stack?): boolean
		if a == nil or b == nil then
			return a == b
		end
		return a.count == b.count and Items.stacksMatch(a, b)
	end

	-- Every slot and the cursor of two inventories agree.
	local function sameInventory(a: Types.Inventory, b: Types.Inventory, message: string)
		for slot = 1, Types.INVENTORY_SIZE do
			t.ok(same(a.slots[slot], b.slots[slot]), `{message}: slot {slot}`)
		end
		t.ok(same(a.cursor, b.cursor), `{message}: the cursor`)
		t.eq(a.selected, b.selected, `{message}: the selection`)
	end

	-- Fills every empty inventory slot with stone (a full inventory).
	local function fill(inventory: Types.Inventory)
		for slot = 1, Types.INVENTORY_SIZE do
			if inventory.slots[slot] == nil then
				inventory.slots[slot] = rounds(I.Stone, 64)
			end
		end
	end

	-- An empty gun of every kind, a magazine of every kind, and so on.
	local function empty(item: number): Items.Stack
		return stack(item)
	end

	--[[ Rounds onto magazines ]]

	t.test("loading: rounds onto a magazine load all that fit (the rest stays carried), a right click one", function()
		local window = newWindow()
		local inventory = window.inventory
		inventory.slots[10] = empty(I.PistolMagazine)
		inventory.cursor = rounds(I.Rounds9mm, 20)
		t.eq(#click(window, 10, 0), 0, "throws nothing")
		local mag = inventory.slots[10] :: Items.Stack
		t.eq(mag.item, I.PistolMagazine, "the magazine stays in its slot")
		t.eq((WeaponState.rounds(mag)), 15, "full: 15")
		t.eq(select(2, WeaponState.rounds(mag)), I.Rounds9mm)
		t.ok(same(inventory.cursor, rounds(I.Rounds9mm, 5)), "the 5 left stay carried")
		-- Full: refused, nothing moves (no swap).
		local cursor = inventory.cursor
		click(window, 10, 0)
		t.eq(inventory.slots[10], mag, "a full magazine is unchanged")
		t.eq(inventory.cursor, cursor, "the rounds stay carried")
		click(window, 10, 1)
		t.eq(inventory.slots[10], mag, "on a right click too")
		-- Partial: 3 in, 4 carried: all 4 go.
		inventory.slots[11] = stack(I.SmgMagazine, { n = 3, ammo = I.Rounds9mm })
		inventory.cursor = rounds(I.Rounds9mm, 4)
		click(window, 11, 0)
		t.eq((WeaponState.rounds(inventory.slots[11] :: Items.Stack)), 7)
		t.eq(inventory.cursor, nil, "all carried rounds went in")
		-- A right click loads one.
		inventory.cursor = rounds(I.Rounds9mm, 10)
		click(window, 11, 1)
		t.eq((WeaponState.rounds(inventory.slots[11] :: Items.Stack)), 8)
		t.ok(same(inventory.cursor, rounds(I.Rounds9mm, 9)), "one round less")
		-- A worn magazine keeps its wear.
		inventory.slots[12] = stack(I.RifleMagazine, nil, 300)
		inventory.cursor = rounds(I.Rounds556, 60)
		click(window, 12, 0)
		t.eq((inventory.slots[12] :: Items.Stack).damage, 300, "the wear stays")
		t.eq((WeaponState.rounds(inventory.slots[12] :: Items.Stack)), 30)
		t.eq((inventory.cursor :: Items.Stack).count, 30)
	end)

	t.test("loading: wrong calibres and full magazines are refused on either button, nothing swaps", function()
		local window = newWindow()
		local inventory = window.inventory
		local mag = empty(I.PistolMagazine)
		inventory.slots[10] = mag
		for _, round in { I.Rounds556, I.Rounds22, I.Buckshot, I.CrossbowBolt } do
			for button = 0, 1 do
				local carried = rounds(round, 5)
				inventory.cursor = carried
				click(window, 10, button)
				t.eq(inventory.slots[10], mag, `{Items.displayName(round)} stays out (button {button})`)
				t.eq(inventory.cursor, carried, "and stays carried")
			end
		end
		t.eq(Loading.combines(rounds(I.Rounds556, 5), mag), "blocked")
		t.eq(Loading.combines(rounds(I.Rounds9mm, 5), mag), "combine")
		t.eq(
			Loading.combines(rounds(I.Rounds9mm, 5), stack(I.PistolMagazine, { n = 15, ammo = I.Rounds9mm })),
			"blocked"
		)
	end)

	--[[ Rounds onto guns ]]

	t.test("loading: rounds onto an internal-feed gun fill the chamber first, then the magazine", function()
		local window = newWindow()
		local inventory = window.inventory
		inventory.slots[1] = empty(I.PumpShotgun)
		inventory.cursor = rounds(I.Buckshot, 10)
		click(window, 1, 0)
		local pump = inventory.slots[1] :: Items.Stack
		t.eq(WeaponState.chamber(pump), I.Buckshot, "the chamber first")
		t.eq((WeaponState.rounds(pump)), 5, "then the tube: 5")
		t.eq(WeaponState.detail(pump), "6 / 6")
		t.ok(same(inventory.cursor, rounds(I.Buckshot, 4)), "4 left")
		-- One at a time with a right click.
		inventory.slots[2] = empty(I.Revolver)
		inventory.cursor = rounds(I.Rounds357, 10)
		click(window, 2, 1)
		t.eq(WeaponState.chamber(inventory.slots[2] :: Items.Stack), I.Rounds357, "the first into the chamber")
		t.eq((WeaponState.rounds(inventory.slots[2] :: Items.Stack)), 0)
		click(window, 2, 1)
		t.eq((WeaponState.rounds(inventory.slots[2] :: Items.Stack)), 1, "the next into the cylinder")
		t.eq((inventory.cursor :: Items.Stack).count, 8)
		click(window, 2, 0)
		t.eq((WeaponState.rounds(inventory.slots[2] :: Items.Stack)), 5, "the rest that fit")
		t.eq((inventory.cursor :: Items.Stack).count, 4)
		-- Two barrels, a crossbow's one bolt.
		inventory.slots[3] = empty(I.DoubleBarrelShotgun)
		inventory.cursor = rounds(I.Slugs, 5)
		click(window, 3, 0)
		t.eq(WeaponState.detail(inventory.slots[3] :: Items.Stack), "2 / 2")
		t.eq((inventory.cursor :: Items.Stack).count, 3)
		inventory.slots[4] = empty(I.Crossbow)
		inventory.cursor = rounds(I.CrossbowBolt, 3)
		click(window, 4, 0)
		t.eq(WeaponState.chamber(inventory.slots[4] :: Items.Stack), I.CrossbowBolt, "a bolt on the string")
		t.eq((inventory.cursor :: Items.Stack).count, 2)
		local crossbow = inventory.slots[4]
		click(window, 4, 0)
		t.eq(inventory.slots[4], crossbow, "loaded: refused")
		t.eq((inventory.cursor :: Items.Stack).count, 2)
	end)

	t.test("loading: other rounds of the calibre go only into an empty chamber or an empty magazine", function()
		local window = newWindow()
		local inventory = window.inventory
		-- Buckshot in the tube, the chamber empty: a slug goes into the chamber only.
		inventory.slots[1] = stack(I.PumpShotgun, { n = 2, ammo = I.Buckshot })
		inventory.cursor = rounds(I.Slugs, 5)
		t.eq(Loading.combines(inventory.cursor, inventory.slots[1]), "combine")
		click(window, 1, 0)
		local pump = inventory.slots[1] :: Items.Stack
		t.eq(WeaponState.chamber(pump), I.Slugs, "a slug chambered")
		t.eq((WeaponState.rounds(pump)), 2, "no slug in the buckshot")
		t.eq((inventory.cursor :: Items.Stack).count, 4)
		-- Now nothing takes a slug.
		t.eq(Loading.combines(inventory.cursor, pump), "blocked")
		click(window, 1, 0)
		t.eq(inventory.slots[1], pump, "refused")
		-- A magazine with other rounds of its calibre: none exist for magazines, so the gun's tube
		-- is the case; an emptied tube takes them.
		inventory.slots[2] = stack(I.PumpShotgun, { ch = I.Buckshot })
		click(window, 2, 0)
		t.eq((WeaponState.rounds(inventory.slots[2] :: Items.Stack)), 4, "an empty tube takes slugs")
		t.eq(select(2, WeaponState.rounds(inventory.slots[2] :: Items.Stack)), I.Slugs)
		t.eq(WeaponState.chamber(inventory.slots[2] :: Items.Stack), I.Buckshot, "the chamber keeps its round")
	end)

	t.test("loading: a detachable-feed gun takes one round by hand into an empty chamber", function()
		local window = newWindow()
		local inventory = window.inventory
		inventory.slots[1] = stack(I.Pistol, { mag = I.PistolMagazine, n = 3, ammo = I.Rounds9mm })
		inventory.cursor = rounds(I.Rounds9mm, 5)
		click(window, 1, 0)
		local pistol = inventory.slots[1] :: Items.Stack
		t.eq(WeaponState.chamber(pistol), I.Rounds9mm, "chambered by hand")
		t.eq((WeaponState.rounds(pistol)), 3, "the magazine untouched")
		t.eq((inventory.cursor :: Items.Stack).count, 4, "one round used")
		click(window, 1, 0)
		t.eq(inventory.slots[1], pistol, "a full chamber: refused")
		t.eq((inventory.cursor :: Items.Stack).count, 4)
		-- Without a magazine too; a jammed gun never.
		inventory.slots[2] = empty(I.Smg)
		click(window, 2, 1)
		t.eq(WeaponState.chamber(inventory.slots[2] :: Items.Stack), I.Rounds9mm)
		local jammed = stack(I.HuntingRifle, { ch = I.Rounds308, jam = true })
		inventory.slots[3] = jammed
		inventory.cursor = rounds(I.Rounds308, 5)
		t.eq(Loading.combines(inventory.cursor, jammed), "blocked")
		click(window, 3, 0)
		t.eq(inventory.slots[3], jammed, "jammed: nothing")
		-- An internal feed with a jam: the tube still loads.
		inventory.slots[4] = stack(I.BoltActionRifle, { ch = I.Rounds762, jam = true })
		inventory.cursor = rounds(I.Rounds762, 10)
		click(window, 4, 0)
		t.eq((WeaponState.rounds(inventory.slots[4] :: Items.Stack)), 4, "the magazine fills")
		t.eq(WeaponState.jammed(inventory.slots[4] :: Items.Stack), true, "the jam stays")
	end)

	--[[ Magazines and attachments onto guns ]]

	t.test("loading: a magazine onto its gun attaches it; the one in comes back onto the cursor", function()
		local window = newWindow()
		local inventory = window.inventory
		inventory.slots[1] =
			stack(I.Pistol, { ch = I.Rounds9mm, mag = I.PistolMagazine, magD = 10, n = 3, ammo = I.Rounds9mm }, 20)
		inventory.cursor = stack(I.PistolMagazine, { n = 15, ammo = I.Rounds9mm }, 5)
		t.eq(Loading.kind(inventory.cursor, inventory.slots[1], 0), "attach")
		click(window, 1, 0)
		local pistol = inventory.slots[1] :: Items.Stack
		t.eq(pistol.damage, 20, "the gun's own wear stays")
		t.eq(key(pistol, "mag"), I.PistolMagazine)
		t.eq(key(pistol, "magD"), 5, "the new magazine's wear")
		t.eq((WeaponState.rounds(pistol)), 15, "its rounds")
		t.eq(WeaponState.chamber(pistol), I.Rounds9mm, "the chamber unchanged")
		local old = inventory.cursor :: Items.Stack
		t.eq(old.item, I.PistolMagazine, "the old one onto the cursor")
		t.eq(old.damage, 10, "with its wear")
		t.eq((WeaponState.rounds(old)), 3, "and its rounds")
		-- Into an empty gun: the cursor empties.
		inventory.slots[2] = empty(I.Pistol)
		click(window, 2, 0)
		t.eq(inventory.cursor, nil, "nothing came out")
		t.eq((WeaponState.rounds(inventory.slots[2] :: Items.Stack)), 3)
		t.eq(WeaponState.chamber(inventory.slots[2] :: Items.Stack), nil, "no round chambered by attaching")
		-- Another gun's magazine, or a gun with an internal magazine: refused.
		local smgMag = stack(I.SmgMagazine, { n = 30, ammo = I.Rounds9mm })
		inventory.cursor = smgMag
		click(window, 2, 0)
		t.eq(inventory.cursor, smgMag, "an SMG magazine stays carried")
		inventory.slots[3] = empty(I.Revolver)
		inventory.cursor = empty(I.PistolMagazine)
		t.eq(Loading.combines(inventory.cursor, inventory.slots[3]), "blocked")
		click(window, 3, 0)
		t.eq((inventory.cursor :: Items.Stack).item, I.PistolMagazine, "a revolver takes no magazine")
		-- A right click with a magazine is Minecraft's: a swap.
		inventory.cursor = empty(I.PistolMagazine)
		click(window, 2, 1)
		t.eq((inventory.cursor :: Items.Stack).item, I.Pistol, "swapped")
		t.eq((inventory.slots[2] :: Items.Stack).item, I.PistolMagazine)
	end)

	t.test("loading: an attachment onto a gun it fits mounts; the one in that slot comes back", function()
		local window = newWindow()
		local inventory = window.inventory
		inventory.slots[1] = empty(I.AssaultRifle)
		inventory.cursor = stack(I.Suppressor, nil, 30)
		click(window, 1, 0)
		local rifle = inventory.slots[1] :: Items.Stack
		t.eq(key(rifle, "muzzle"), I.Suppressor)
		t.eq(key(rifle, "muzzleD"), 30, "its wear rides along")
		t.eq(inventory.cursor, nil)
		inventory.cursor = stack(I.ImprovisedSuppressor, nil, 2)
		click(window, 1, 0)
		rifle = inventory.slots[1] :: Items.Stack
		t.eq(key(rifle, "muzzle"), I.ImprovisedSuppressor, "swapped in")
		t.eq(key(rifle, "muzzleD"), 2)
		t.ok(same(inventory.cursor, stack(I.Suppressor, nil, 30)), "the old one back, worn as it was")
		inventory.cursor = stack(I.RifleScope)
		click(window, 1, 0)
		t.eq(key(inventory.slots[1], "optic"), I.RifleScope, "a scope on the rifle")
		t.eq(inventory.cursor, nil)
		inventory.cursor = stack(I.RedDotSight)
		click(window, 1, 0)
		t.eq(key(inventory.slots[1], "optic"), I.RedDotSight)
		t.ok(same(inventory.cursor, stack(I.RifleScope)), "the scope back")
		-- A light mounted is off.
		inventory.slots[2] = stack(I.Pistol, { light = I.WeaponFlashlight, lit = true })
		inventory.cursor = stack(I.WeaponFlashlight)
		click(window, 2, 0)
		t.eq(key(inventory.slots[2], "light"), I.WeaponFlashlight)
		t.eq(key(inventory.slots[2], "lit"), nil, "the new light is off")
		t.ok(same(inventory.cursor, stack(I.WeaponFlashlight)))
		-- What doesn't fit stays carried.
		local scope = stack(I.RifleScope)
		inventory.cursor = scope
		click(window, 2, 0)
		t.eq(inventory.cursor, scope, "no scope on a pistol")
		inventory.slots[3] = empty(I.Revolver)
		inventory.cursor = stack(I.WeaponFlashlight)
		click(window, 3, 0)
		t.eq(inventory.slots[3] and inventory.slots[3].data, nil, "a revolver has no mounts")
		inventory.slots[4] = empty(I.HuntingRifle)
		inventory.cursor = stack(I.RedDotSight)
		t.eq(Loading.combines(inventory.cursor, inventory.slots[4]), "blocked", "its scope is built in")
	end)

	--[[ Unloading ]]

	t.test("loading: a right click with an empty cursor takes out one thing at a time", function()
		local window = newWindow()
		local inventory = window.inventory
		inventory.slots[1] = stack(I.Pistol, {
			ch = I.Rounds9mm,
			mag = I.PistolMagazine,
			magD = 4,
			n = 10,
			ammo = I.Rounds9mm,
			muzzle = I.Suppressor,
			muzzleD = 7,
			optic = I.RedDotSight,
			light = I.WeaponFlashlight,
			lit = true,
		}, 9)
		local expected = {
			stack(I.PistolMagazine, { n = 10, ammo = I.Rounds9mm }, 4),
			rounds(I.Rounds9mm, 1),
			stack(I.Suppressor, nil, 7),
			stack(I.RedDotSight),
			stack(I.WeaponFlashlight),
		}
		for index, out in expected do
			t.eq(Loading.kind(nil, inventory.slots[1], 1), "unload")
			click(window, 1, 1)
			t.ok(same(inventory.cursor, out), `out {index}: {Items.displayName(out.item)}`)
			t.eq((inventory.slots[1] :: Items.Stack).item, I.Pistol, "the gun stays")
			t.eq((inventory.slots[1] :: Items.Stack).damage, 9, "worn as it was")
			inventory.cursor = nil
		end
		t.eq((inventory.slots[1] :: Items.Stack).data, nil, "nothing left in it")
		t.eq(Loading.kind(nil, inventory.slots[1], 1), nil, "an empty gun: Minecraft's")
		click(window, 1, 1)
		t.eq((inventory.cursor :: Items.Stack).item, I.Pistol, "take-half: the whole gun")
		t.eq(inventory.slots[1], nil)
		-- A left click with an empty cursor is always Minecraft's.
		inventory.slots[2] = stack(I.PistolMagazine, { n = 5, ammo = I.Rounds9mm })
		inventory.cursor = nil
		click(window, 2, 0)
		t.eq((inventory.cursor :: Items.Stack).item, I.PistolMagazine, "picked up whole")
		inventory.slots[2] = inventory.cursor
		inventory.cursor = nil
		-- A magazine's rounds; then the empty magazine itself.
		click(window, 2, 1)
		t.ok(same(inventory.cursor, rounds(I.Rounds9mm, 5)), "its rounds")
		t.eq((WeaponState.rounds(inventory.slots[2] :: Items.Stack)), 0)
		inventory.cursor = nil
		click(window, 2, 1)
		t.eq((inventory.cursor :: Items.Stack).item, I.PistolMagazine, "an empty magazine: take-half")
	end)

	t.test("loading: internal rounds and the chamber come out together, a stuck round never", function()
		local window = newWindow()
		local inventory = window.inventory
		-- The same rounds: one stack.
		inventory.slots[1] = stack(I.PumpShotgun, { ch = I.Buckshot, n = 4, ammo = I.Buckshot })
		click(window, 1, 1)
		t.ok(same(inventory.cursor, rounds(I.Buckshot, 5)), "five shells")
		t.eq((inventory.slots[1] :: Items.Stack).data, nil)
		-- Other rounds chambered: the tube's onto the cursor, the chambered one into the inventory.
		inventory.cursor = nil
		inventory.slots[1] = stack(I.PumpShotgun, { ch = I.Slugs, n = 4, ammo = I.Buckshot })
		click(window, 1, 1)
		t.ok(same(inventory.cursor, rounds(I.Buckshot, 4)), "the tube's")
		t.ok(same(inventory.slots[2], rounds(I.Slugs, 1)), "the slug into the inventory")
		t.eq((inventory.slots[1] :: Items.Stack).data, nil)
		-- No room: the slug stays chambered (taken by the next click).
		inventory.cursor = nil
		inventory.slots[2] = nil
		inventory.slots[1] = stack(I.PumpShotgun, { ch = I.Slugs, n = 4, ammo = I.Buckshot })
		fill(inventory)
		click(window, 1, 1)
		t.ok(same(inventory.cursor, rounds(I.Buckshot, 4)), "the tube's")
		t.eq(WeaponState.chamber(inventory.slots[1] :: Items.Stack), I.Slugs, "the slug stays chambered")
		inventory.cursor = nil
		click(window, 1, 1)
		t.ok(same(inventory.cursor, rounds(I.Slugs, 1)), "then the slug")
		-- A jammed round stays; the tube's come out.
		inventory.cursor = nil
		inventory.slots[1] = stack(I.BoltActionRifle, { ch = I.Rounds762, jam = true, n = 3, ammo = I.Rounds762 })
		click(window, 1, 1)
		t.ok(same(inventory.cursor, rounds(I.Rounds762, 3)), "the magazine's three")
		t.eq(WeaponState.jammed(inventory.slots[1] :: Items.Stack), true, "the stuck round stays")
		inventory.cursor = nil
		t.eq(Loading.kind(nil, inventory.slots[1], 1), nil, "nothing more by hand")
		click(window, 1, 1)
		t.eq((inventory.cursor :: Items.Stack).item, I.BoltActionRifle, "take-half picks the gun up")
	end)

	--[[ Every pair ]]

	t.test("loading: every pair of weapon items combines, blocks or is Minecraft's as the rules say", function()
		local everything: { number } = {}
		for _, list in { Weapons.FIREARMS, Weapons.MAGAZINES, Weapons.AMMO, Weapons.ATTACHMENTS, Weapons.MELEE } do
			for _, item in list do
				table.insert(everything, item)
			end
		end
		table.insert(everything, I.Stone)
		local checked = 0
		for _, carriedItem in everything do
			for _, currentItem in everything do
				local carried = stack(carriedItem, nil, nil, math.min(5, Items.maxStack(carriedItem)))
				local current = empty(currentItem)
				local gun = Weapons.firearm(currentItem)
				local expected: string? = nil
				if Weapons.ammo(carriedItem) and (gun or Weapons.magazine(currentItem)) then
					expected = if Weapons.takes(currentItem, carriedItem) then "combine" else "blocked"
				elseif gun and Weapons.magazine(carriedItem) then
					expected = if gun.magazine == carriedItem then "combine" else "blocked"
				elseif gun and Weapons.attachment(carriedItem) then
					expected = if Weapons.fits(carriedItem, currentItem) then "combine" else "blocked"
				end
				local name = `{Items.displayName(carriedItem)} on {Items.displayName(currentItem)}`
				t.eq(Loading.combines(carried, current), expected, name)
				-- The click does what the outline says.
				local window = newWindow()
				window.inventory.slots[10] = current
				window.inventory.cursor = carried
				click(window, 10, 0)
				local after = window.inventory.slots[10]
				if expected == "combine" then
					t.ok(after ~= nil and after.item == currentItem and after.data ~= nil, `{name}: loaded`)
				elseif expected == "blocked" then
					t.eq(after, current, `{name}: unchanged`)
					t.eq(window.inventory.cursor, carried, `{name}: still carried`)
				end
				checked += 1
			end
		end
		t.eq(checked, #everything * #everything)
		-- Nothing carried, nothing under it.
		t.eq(Loading.combines(nil, empty(I.Pistol)), nil)
		t.eq(Loading.combines(rounds(I.Rounds9mm, 3), nil), nil)
		t.eq(Loading.kind(rounds(I.Rounds9mm, 3), empty(I.Pistol), 2), nil, "only left and right")
	end)

	t.test("loading: kind names what a click does for the screen's sounds", function()
		local loaded = stack(I.Pistol, { mag = I.PistolMagazine, n = 2, ammo = I.Rounds9mm })
		t.eq(Loading.kind(rounds(I.Rounds9mm, 3), empty(I.PistolMagazine), 0), "load")
		t.eq(Loading.kind(rounds(I.Rounds9mm, 3), empty(I.PistolMagazine), 1), "load")
		t.eq(Loading.kind(empty(I.PistolMagazine), empty(I.Pistol), 0), "attach")
		t.eq(Loading.kind(empty(I.PistolMagazine), empty(I.Pistol), 1), nil, "a right click swaps")
		t.eq(Loading.kind(stack(I.Suppressor), empty(I.Pistol), 0), "attach")
		t.eq(Loading.kind(nil, loaded, 1), "unload")
		t.eq(Loading.kind(nil, loaded, 0), nil)
		t.eq(Loading.kind(rounds(I.Rounds556, 3), loaded, 0), "blocked")
		t.eq(Loading.kind(rounds(I.Stone, 3), loaded, 0), nil)
	end)

	--[[ Weapon actions ]]

	t.test(
		"weapon actions: reload swaps in the fullest magazine (ties: condition, then slot), then chambers",
		function()
			local window = newWindow()
			local inventory = window.inventory
			inventory.slots[1] = stack(I.Pistol, { mag = I.PistolMagazine, magD = 70, n = 2, ammo = I.Rounds9mm })
			inventory.slots[5] = stack(I.PistolMagazine, { n = 10, ammo = I.Rounds9mm }, 50)
			inventory.slots[12] = stack(I.PistolMagazine, { n = 15, ammo = I.Rounds9mm }, 100)
			inventory.slots[20] = stack(I.PistolMagazine, { n = 15, ammo = I.Rounds9mm }, 10)
			inventory.slots[30] = stack(I.PistolMagazine, { n = 15, ammo = I.Rounds9mm }, 10)
			inventory.slots[31] = stack(I.SmgMagazine, { n = 30, ammo = I.Rounds9mm })
			t.eq(#weapon(window, Op.Reload, HELD), 0, "nothing thrown")
			local pistol = inventory.slots[1] :: Items.Stack
			t.eq(key(pistol, "magD"), 10, "the better condition of the full ones")
			t.eq(WeaponState.chamber(pistol), I.Rounds9mm, "chambered")
			t.eq((WeaponState.rounds(pistol)), 14)
			local old = inventory.slots[20] :: Items.Stack
			t.eq(old.item, I.PistolMagazine, "the old one where the new one was (the lower slot of the tie)")
			t.eq(old.damage, 70)
			t.eq((WeaponState.rounds(old)), 2)
			t.ok(
				same(inventory.slots[30], stack(I.PistolMagazine, { n = 15, ammo = I.Rounds9mm }, 10)),
				"the tie's other"
			)
			t.eq((inventory.slots[31] :: Items.Stack).item, I.SmgMagazine, "another gun's magazine is never taken")
			-- No fuller magazine: nothing changes (the chamber is full).
			local before = inventory.slots[1]
			weapon(window, Op.Reload, HELD)
			t.eq((WeaponState.rounds(inventory.slots[1] :: Items.Stack)), 15, "the 15 swapped in for the 14")
			t.eq(key(inventory.slots[1], "magD"), 10, "the twin of the same condition")
			before = inventory.slots[1]
			weapon(window, Op.Reload, HELD)
			t.eq(inventory.slots[1], before, "nothing fuller left")
			-- An empty chamber and no better magazine: chambers only.
			inventory.slots[2] = stack(I.Smg, { mag = I.SmgMagazine, n = 30, ammo = I.Rounds9mm })
			inventory.selected = 2
			weapon(window, Op.Reload, HELD)
			t.eq(WeaponState.chamber(inventory.slots[2] :: Items.Stack), I.Rounds9mm, "chambered")
			t.eq((WeaponState.rounds(inventory.slots[2] :: Items.Stack)), 29)
			t.eq((inventory.slots[31] :: Items.Stack).item, I.SmgMagazine, "the 30 in the inventory is no fuller")
			-- None attached: one with a round goes in; an empty one doesn't.
			inventory.slots[3] = empty(I.SmallBoreRifle)
			inventory.slots[14] = empty(I.SmallBoreMagazine)
			inventory.selected = 3
			weapon(window, Op.Reload, HELD)
			t.eq(inventory.slots[3] and inventory.slots[3].data, nil, "an empty magazine is no reload")
			inventory.slots[15] = stack(I.SmallBoreMagazine, { n = 1, ammo = I.Rounds22 })
			weapon(window, Op.Reload, HELD)
			t.eq(key(inventory.slots[3], "mag"), I.SmallBoreMagazine, "attached")
			t.eq(WeaponState.chamber(inventory.slots[3] :: Items.Stack), I.Rounds22, "its round chambered")
			t.eq((WeaponState.rounds(inventory.slots[3] :: Items.Stack)), 0)
			t.eq(inventory.slots[15], nil, "taken from its slot")
			-- Jammed: nothing.
			local jammed = stack(I.AssaultRifle, { ch = I.Rounds556, jam = true })
			inventory.slots[4] = jammed
			inventory.slots[16] = stack(I.RifleMagazine, { n = 30, ammo = I.Rounds556 })
			inventory.selected = 4
			weapon(window, Op.Reload, HELD)
			t.eq(inventory.slots[4], jammed, "a jam first")
			-- Only the held gun (slot -1), only guns.
			inventory.selected = 3
			weapon(window, Op.Reload, at(window, 4))
			t.eq(inventory.slots[4], jammed)
			inventory.slots[5] = rounds(I.Stone, 3)
			inventory.selected = 5
			weapon(window, Op.Reload, HELD)
			t.ok(same(inventory.slots[5], rounds(I.Stone, 3)), "stone doesn't reload")
		end
	)

	t.test(
		"weapon actions: a round by hand from the first stack of the loaded rounds (the calibre's when empty)",
		function()
			local window = newWindow()
			local inventory = window.inventory
			inventory.slots[1] = empty(I.PumpShotgun)
			inventory.slots[3] = rounds(I.Slugs, 2)
			inventory.slots[7] = rounds(I.Buckshot, 10)
			weapon(window, Op.LoadRound, HELD)
			t.eq(WeaponState.chamber(inventory.slots[1] :: Items.Stack), I.Slugs, "the first stack of the calibre")
			t.eq((inventory.slots[3] :: Items.Stack).count, 1, "one used")
			weapon(window, Op.LoadRound, HELD)
			t.eq((WeaponState.rounds(inventory.slots[1] :: Items.Stack)), 1, "into the tube")
			t.eq(inventory.slots[3], nil, "the slugs used up")
			local pump = inventory.slots[1]
			weapon(window, Op.LoadRound, HELD)
			t.eq(inventory.slots[1], pump, "no more slugs: the buckshot doesn't join them")
			t.eq((inventory.slots[7] :: Items.Stack).count, 10)
			-- Reload on an internal feed is a round.
			inventory.slots[2] = stack(I.Revolver, { ch = I.Rounds357, n = 4, ammo = I.Rounds357 })
			inventory.slots[8] = rounds(I.Rounds357, 6)
			inventory.selected = 2
			weapon(window, Op.Reload, HELD)
			t.eq((WeaponState.rounds(inventory.slots[2] :: Items.Stack)), 5)
			t.eq((inventory.slots[8] :: Items.Stack).count, 5)
			local full = inventory.slots[2]
			weapon(window, Op.LoadRound, HELD)
			t.eq(inventory.slots[2], full, "full")
			t.eq((inventory.slots[8] :: Items.Stack).count, 5)
			-- Never a detachable feed, never a jammed gun.
			inventory.slots[4] = empty(I.Pistol)
			inventory.slots[9] = rounds(I.Rounds9mm, 5)
			inventory.selected = 4
			weapon(window, Op.LoadRound, HELD)
			t.eq(inventory.slots[4] and inventory.slots[4].data, nil, "a pistol loads by its magazine")
			local jammed = stack(I.SemiAutoRifle, { ch = I.Rounds762, jam = true })
			inventory.slots[5] = jammed
			inventory.slots[10] = rounds(I.Rounds762, 5)
			inventory.selected = 5
			weapon(window, Op.LoadRound, HELD)
			t.eq(inventory.slots[5], jammed)
			t.eq((inventory.slots[10] :: Items.Stack).count, 5)
		end
	)

	t.test("weapon actions: a jam cleared loses its round, the fire mode cycles, the light flips", function()
		local window = newWindow()
		local inventory = window.inventory
		inventory.slots[1] =
			stack(I.AssaultRifle, { ch = I.Rounds556, jam = true, mag = I.RifleMagazine, n = 5, ammo = I.Rounds556 })
		weapon(window, Op.Unjam, HELD)
		local rifle = inventory.slots[1] :: Items.Stack
		t.eq(WeaponState.jammed(rifle), false, "cleared")
		t.eq(WeaponState.chamber(rifle), I.Rounds556, "the next round chambered")
		t.eq((WeaponState.rounds(rifle)), 4, "the stuck one lost")
		weapon(window, Op.Unjam, HELD)
		t.eq(inventory.slots[1], rifle, "not jammed: nothing")
		-- An empty magazine behind it: the chamber stays empty.
		inventory.slots[2] = stack(I.HuntingRifle, { ch = I.Rounds308, jam = true })
		inventory.selected = 2
		weapon(window, Op.Unjam, HELD)
		t.eq((inventory.slots[2] :: Items.Stack).data, nil)
		-- Fire modes.
		inventory.selected = 1
		weapon(window, Op.Mode, HELD)
		t.eq(WeaponState.mode(inventory.slots[1] :: Items.Stack), "auto")
		t.eq(key(inventory.slots[1], "mode"), 2)
		weapon(window, Op.Mode, HELD)
		t.eq(WeaponState.mode(inventory.slots[1] :: Items.Stack), "semi", "round to the first")
		t.eq(key(inventory.slots[1], "mode"), nil, "the first is no data")
		inventory.slots[2] = empty(I.Pistol)
		inventory.selected = 2
		weapon(window, Op.Mode, HELD)
		t.eq((inventory.slots[2] :: Items.Stack).data, nil, "one mode: nothing")
		-- The light.
		weapon(window, Op.Light, HELD)
		t.eq((inventory.slots[2] :: Items.Stack).data, nil, "no light mounted: nothing")
		inventory.slots[2] = stack(I.Pistol, { light = I.WeaponFlashlight })
		weapon(window, Op.Light, HELD)
		t.eq(key(inventory.slots[2], "lit"), true, "on")
		weapon(window, Op.Light, HELD)
		t.eq(key(inventory.slots[2], "lit"), nil, "off")
	end)

	t.test("weapon actions: detaching goes onto the cursor, then into the inventory, then is thrown", function()
		local window = newWindow()
		local inventory = window.inventory
		local kit = {
			ch = I.Rounds9mm,
			mag = I.PistolMagazine,
			magD = 4,
			n = 10,
			ammo = I.Rounds9mm,
			muzzle = I.Suppressor,
			muzzleD = 7,
			optic = I.RedDotSight,
			light = I.WeaponFlashlight,
		}
		inventory.slots[1] = stack(I.Pistol, kit)
		local held = at(window, 1)
		t.eq(#weapon(window, Op.Detach, held, Part.Magazine), 0)
		t.ok(same(inventory.cursor, stack(I.PistolMagazine, { n = 10, ammo = I.Rounds9mm }, 4)), "onto the cursor")
		t.eq(WeaponState.chamber(inventory.slots[1] :: Items.Stack), I.Rounds9mm, "the chamber stays")
		weapon(window, Op.Detach, held, Part.Muzzle)
		t.ok(same(inventory.slots[2], stack(I.Suppressor, nil, 7)), "the cursor full: into the inventory")
		weapon(window, Op.Detach, HELD, Part.Chamber)
		t.ok(same(inventory.slots[3], rounds(I.Rounds9mm, 1)), "the held gun by slot -1 too")
		fill(inventory)
		local thrown = weapon(window, Op.Detach, held, Part.Optic)
		t.eq(#thrown, 1, "no room: thrown")
		t.ok(same(thrown[1], stack(I.RedDotSight)))
		t.eq(key(inventory.slots[1], "optic"), nil)
		-- Nothing to take, a part out of range, no weapon: nothing.
		local gun = inventory.slots[1]
		weapon(window, Op.Detach, held, Part.Magazine)
		t.eq(inventory.slots[1], gun, "no magazine left")
		weapon(window, Op.Detach, held, 0)
		weapon(window, Op.Detach, held, 7)
		t.eq(inventory.slots[1], gun)
		local stone = inventory.slots[4]
		weapon(window, Op.Detach, at(window, 4), Part.Rounds)
		t.eq(inventory.slots[4], stone)
		t.eq(#weapon(window, Op.Detach, 999, Part.Light), 0, "no such slot")
		weapon(window, Op.Detach, held, Part.Light)
		t.eq((inventory.slots[1] :: Items.Stack).data, nil, "the light came off (thrown: no room)")
		-- A magazine's rounds; an internal gun's rounds and chamber (other rounds: two stacks).
		local second = newWindow()
		local inv = second.inventory
		inv.slots[10] = stack(I.RifleMagazine, { n = 30, ammo = I.Rounds556 })
		weapon(second, Op.Detach, at(second, 10), Part.Rounds)
		t.ok(same(inv.cursor, rounds(I.Rounds556, 30)), "a magazine's rounds")
		t.eq((WeaponState.rounds(inv.slots[10] :: Items.Stack)), 0)
		inv.cursor = nil
		inv.slots[11] = stack(I.PumpShotgun, { ch = I.Slugs, n = 3, ammo = I.Buckshot })
		weapon(second, Op.Detach, at(second, 11), Part.Rounds)
		t.ok(same(inv.cursor, rounds(I.Buckshot, 3)), "the tube's onto the cursor")
		t.ok(same(inv.slots[1], rounds(I.Slugs, 1)), "the chambered one into the inventory")
		t.eq((inv.slots[11] :: Items.Stack).data, nil)
		-- A jammed round never comes out.
		inv.cursor = nil
		local jammed = stack(I.SemiAutoRifle, { ch = I.Rounds762, jam = true })
		inv.slots[12] = jammed
		weapon(second, Op.Detach, at(second, 12), Part.Chamber)
		weapon(second, Op.Detach, at(second, 12), Part.Rounds)
		t.eq(inv.slots[12], jammed, "stuck")
		-- A gun in a chest: out into the player's inventory as usual.
		local chest = Types.newInventory()
		local chestWindow: Types.Window = {
			id = 1,
			inventory = chest,
			container = { kind = "chest", block = 0, size = 27, slots = {} },
		};
		(chestWindow.container :: Types.Container).slots[1] =
			stack(I.Smg, { mag = I.SmgMagazine, n = 30, ammo = I.Rounds9mm })
		weapon(chestWindow, Op.Detach, 0, Part.Magazine)
		t.ok(same(chest.cursor, stack(I.SmgMagazine, { n = 30, ammo = I.Rounds9mm })), "out of the chest's gun")
		t.eq(((chestWindow.container :: Types.Container).slots[1] :: Items.Stack).data, nil)
	end)

	t.test("weapon actions: creative rounds are free; creative clicks are survival's", function()
		local window = newWindow()
		local inventory = window.inventory
		inventory.slots[1] = empty(I.PumpShotgun)
		weapon(window, Op.LoadRound, HELD, 0, false)
		t.eq((inventory.slots[1] :: Items.Stack).data, nil, "survival: no shells, no round")
		weapon(window, Op.LoadRound, HELD, 0, true)
		t.eq(WeaponState.chamber(inventory.slots[1] :: Items.Stack), I.Buckshot, "creative: the calibre's first")
		inventory.slots[6] = rounds(I.Slugs, 3)
		weapon(window, Op.LoadRound, HELD, 0, true)
		t.eq(select(2, WeaponState.rounds(inventory.slots[1] :: Items.Stack)), I.Slugs, "the inventory's first")
		t.eq((inventory.slots[6] :: Items.Stack).count, 3, "not used up")
		weapon(window, Op.Reload, HELD, 0, true)
		weapon(window, Op.Reload, HELD, 0, true)
		t.eq((WeaponState.rounds(inventory.slots[1] :: Items.Stack)), 3)
		-- A detachable feed with no magazine anywhere: a full one.
		inventory.slots[2] = empty(I.AssaultRifle)
		inventory.selected = 2
		weapon(window, Op.Reload, HELD, 0, true)
		local rifle = inventory.slots[2] :: Items.Stack
		t.eq(key(rifle, "mag"), I.RifleMagazine, "a magazine from nothing")
		t.eq(WeaponState.chamber(rifle), I.Rounds556)
		t.eq((WeaponState.rounds(rifle)), 29, "30, one chambered")
		weapon(window, Op.Reload, HELD, 0, true)
		t.eq((WeaponState.rounds(inventory.slots[2] :: Items.Stack)), 30, "topped up")
		local full = inventory.slots[2]
		weapon(window, Op.Reload, HELD, 0, true)
		t.eq(inventory.slots[2], full, "full: nothing")
		-- A fuller magazine in the inventory still swaps as in survival.
		inventory.slots[3] = stack(I.Pistol, { mag = I.PistolMagazine, n = 1, ammo = I.Rounds9mm, ch = I.Rounds9mm })
		inventory.slots[12] = stack(I.PistolMagazine, { n = 15, ammo = I.Rounds9mm })
		inventory.selected = 3
		weapon(window, Op.Reload, HELD, 0, true)
		t.eq((WeaponState.rounds(inventory.slots[3] :: Items.Stack)), 15)
		t.eq((WeaponState.rounds(inventory.slots[12] :: Items.Stack)), 1, "the old one in its slot")
		-- Creative clicks use the carried rounds up.
		inventory.slots[13] = empty(I.PistolMagazine)
		inventory.cursor = rounds(I.Rounds9mm, 20)
		click(window, 13, 0, true)
		t.eq((inventory.cursor :: Items.Stack).count, 5, "as in survival")
	end)

	t.test("weapon actions: allowed where a player interacts; odd actions change nothing", function()
		local action: Types.Action = { kind = "weapon", op = Op.Detach, slot = 0, part = Part.Rounds }
		t.ok(Menu.allows(action, SURVIVAL))
		t.ok(not Menu.allows(action, GameMode.SPECTATOR), "spectators look only")
		local window = newWindow()
		local inventory = window.inventory
		local gun = stack(I.Pistol, { mag = I.PistolMagazine, n = 3, ammo = I.Rounds9mm })
		inventory.slots[1] = gun
		for _, odd in
			{
				{ kind = "weapon", op = 0, slot = HELD, part = 0 },
				{ kind = "weapon", op = 7, slot = HELD, part = 0 },
				{ kind = "weapon", op = 1.5, slot = HELD, part = 0 },
				{ kind = "weapon", op = Op.Reload, slot = 0 / 0, part = 0 },
				{ kind = "weapon", op = Op.Detach, slot = HELD, part = 1.5 },
				{ kind = "weapon", op = Op.Detach, slot = HELD, part = "x" },
			} :: { any }
		do
			Menu.apply(window, odd, false)
			t.eq(inventory.slots[1], gun, "unchanged")
		end
		inventory.selected = 0
		weapon(window, Op.Mode, HELD)
		t.eq(inventory.slots[1], gun, "no hotbar slot selected")
	end)

	--[[ Prediction ]]

	t.test("weapon actions: the client's prediction agrees with the server's, action by action", function()
		local function snapshot(state, key)
			return Protocol.decodeInventory(Protocol.encodeInventory(state:snapshot(key)))
		end
		local state = InventoryState.new()
		state:join("p")
		local window = state:window("p") :: Types.Window
		local inventory = window.inventory
		inventory.slots[1] = stack(I.Pistol, { mag = I.PistolMagazine, magD = 3, n = 2, ammo = I.Rounds9mm }, 40)
		inventory.slots[2] = empty(I.PumpShotgun)
		inventory.slots[3] =
			stack(I.AssaultRifle, { ch = I.Rounds556, jam = true, mag = I.RifleMagazine, n = 4, ammo = I.Rounds556 })
		inventory.slots[10] = empty(I.PistolMagazine)
		inventory.slots[11] = stack(I.PistolMagazine, { n = 9, ammo = I.Rounds9mm }, 12)
		inventory.slots[12] = rounds(I.Rounds9mm, 40)
		inventory.slots[13] = rounds(I.Buckshot, 3)
		inventory.slots[14] = rounds(I.Slugs, 2)
		inventory.slots[15] = stack(I.Suppressor, nil, 5)
		inventory.slots[16] = stack(I.RedDotSight)
		local prediction = Prediction.new()
		prediction:receive(snapshot(state, "p"), SURVIVAL)
		local function clickAction(slot: number, button: number): Types.Action
			return { kind = "click", window = 0, slot = at(window, slot), clickType = PICKUP, button = button }
		end
		local function weaponAction(op: number, slot: number, part: number?): Types.Action
			return { kind = "weapon", op = op, slot = slot, part = part or 0 }
		end
		local actions: { Types.Action } = {
			clickAction(12, 0), -- pick up the 9mm rounds
			clickAction(10, 0), -- fill the empty magazine (15)
			clickAction(11, 1), -- one more into the worn one (10)
			clickAction(12, 0), -- put the rest back
			clickAction(10, 0), -- pick up the full magazine
			clickAction(1, 0), -- attach it (the old one onto the cursor)
			clickAction(20, 0), -- put the old one down
			weaponAction(Op.Reload, HELD), -- chamber
			clickAction(15, 0), -- the suppressor
			clickAction(1, 0), -- mounted
			clickAction(16, 0), -- the red dot
			clickAction(1, 0), -- mounted
			weaponAction(Op.Detach, at(window, 1), Part.Muzzle), -- off again, onto the cursor
			clickAction(15, 0), -- back down
			{ kind = "select", slot = 2 },
			weaponAction(Op.LoadRound, HELD), -- a shell
			weaponAction(Op.Reload, HELD), -- another
			clickAction(14, 0), -- the slugs
			clickAction(2, 0), -- into the tube? no: the chamber is full and the tube holds buckshot
			clickAction(14, 0), -- put them back
			clickAction(2, 1), -- unload: the shells (the same rounds: one stack)
			clickAction(21, 0), -- down
			{ kind = "select", slot = 3 },
			weaponAction(Op.Unjam, HELD),
			weaponAction(Op.Mode, HELD),
			weaponAction(Op.Reload, HELD),
			clickAction(3, 1), -- the magazine out
			clickAction(22, 0),
			weaponAction(Op.Detach, HELD, Part.Chamber),
		}
		for index, action in actions do
			local seq = prediction:push(action, SURVIVAL)
			state:applyAs("p", seq, action, SURVIVAL)
			sameInventory(prediction:window().inventory, inventory, `after action {index}`)
		end
		prediction:receive(snapshot(state, "p"), SURVIVAL)
		t.eq(#prediction.pending, 0, "all acknowledged")
		sameInventory(prediction:window().inventory, inventory, "after the snapshot")
		-- (What the run did, so the comparison compares something.)
		local pistol = inventory.slots[1] :: Items.Stack
		t.eq(key(pistol, "optic"), I.RedDotSight)
		t.eq(key(pistol, "muzzle"), nil)
		t.eq(WeaponState.chamber(pistol), I.Rounds9mm)
		t.eq((WeaponState.rounds(pistol)), 14)
		t.eq(inventory.slots[2] and inventory.slots[2].data, nil, "the pump emptied")
		t.ok(same(inventory.slots[21], rounds(I.Buckshot, 2)), "its two shells")
		t.eq(WeaponState.mode(inventory.slots[3] :: Items.Stack), "auto")
		t.eq(WeaponState.chamber(inventory.slots[3] :: Items.Stack), nil, "the chamber taken off")
		t.ok(same(inventory.slots[22], stack(I.RifleMagazine, { n = 3, ammo = I.Rounds556 })), "the rifle's magazine")
	end)

	--[[ HANDS ]]

	t.test("HANDS: a held gun's chips show its parts, say what they are and take them off", function()
		local Instance, UDim2, Vector2 = FakeClient.Instance, roblox.UDim2, roblox.Vector2
		local window = newWindow()
		local applied: { Types.Action } = {}
		local sounds: { string } = {}
		local stubs: { [string]: any } = {
			["src/client/Ui/UiScale.luau"] = {
				changed = FakeClient.signal(),
				touch = function()
					return false
				end,
				setting = function()
					return 0
				end,
				setSetting = function() end,
				base = function()
					return 4
				end,
				layerOf = function()
					return 1
				end,
				screenGui = function(name: string): any
					local made = Instance.new("ScreenGui")
					made.Name = name
					return made
				end,
			},
			["src/client/Settings/Keybinds.luau"] = {
				changed = FakeClient.signal(),
				name = function(action: string): string
					return string.sub(action, 7)
				end,
			},
			["src/client/Inventory/ClientInventory.luau"] = {
				mode = function()
					return SURVIVAL
				end,
				allows = function(action: Types.Action): boolean
					return Menu.allows(action, SURVIVAL)
				end,
				apply = function(action: Types.Action)
					table.insert(applied, action)
				end,
				window = function()
					return window
				end,
			},
			["src/client/Audio/SoundPlayer.luau"] = {
				click = function() end,
				playFlat = function(name: string): boolean
					table.insert(sounds, name)
					return true
				end,
			},
			["src/client/Player/ProgressionState.luau"] = {
				get = function()
					return nil
				end,
				lockText = function()
					return nil
				end,
				gate = function()
					return nil
				end,
			},
			["src/client/Entities/EntityRenderer.luau"] = {
				itemsNear = function()
					return {}
				end,
			},
		}
		local Preview = {}
		Preview.__index = Preview
		function Preview.new(parent)
			local frame = Instance.new("ViewportFrame")
			frame.Parent = parent
			return setmetatable({ frame = frame }, Preview)
		end
		function Preview.setRect(self, x, y, w, h)
			self.frame.Position = UDim2.fromOffset(x, y)
			self.frame.Size = UDim2.fromOffset(w, h)
		end
		function Preview.opened() end
		function Preview.closed() end
		function Preview.update() end
		function Preview.follow() end
		stubs["src/client/Ui/PlayerPreview.luau"] = Preview
		-- ItemIcon: a bare root for `new`; `slot` builds its parts as the real one does.
		stubs["src/client/Ui/ItemIcon.luau"] = function(req, node)
			local Icon = {}
			Icon.__index = Icon
			local M = { TAB_HEIGHT = 26, TAB_WIDTH = 28 }
			function M.new(parent, x, y, z)
				local root = Instance.new("Frame")
				root.Name = "ItemIcon"
				root.BackgroundTransparency = 1
				root.Position = UDim2.fromOffset(x, y)
				root.Size = UDim2.fromOffset(16, 16)
				root.ZIndex = z or 5
				root.Parent = parent
				return setmetatable({ root = root, item = nil, count = 0 }, Icon)
			end
			function Icon.set(self, item, count)
				self.item, self.count = item, count
			end
			function Icon.setDimmed() end
			function Icon.destroy(self)
				self.root:Destroy()
			end
			function Icon.setTransparency() end
			function Icon.setScale() end
			function M.slot(parent, x, y, z, big, scaled)
				local Style = req(node("src/client/Ui/Style.luau", true))
				local Dayz, Theme = Style.Dayz, Style.Theme
				local button = Style.itemButton(parent, x, y, z)
				local size = if big then Theme.Size.BIG_FACE else Theme.Size.CELL
				local offset = if big then 1 - (Theme.Size.BIG_FACE - 16) // 2 else 1
				local face = Dayz.slotFace(button, offset, offset, size, size, 1)
				local hover = Instance.new("Frame")
				hover.Name = "Hover"
				hover.BackgroundTransparency = 1
				hover.Visible = false
				Dayz.outline(hover, nil, nil, scaled)
				hover.Parent = button
				return { button = button, icon = M.new(button, 1, 1, 5), hover = hover, face = face }
			end
			return M
		end
		local services = {
			TextService = {
				GetTextSize = function(_, text: string, size: number)
					return Vector2.new(#text * size / 2, size)
				end,
			},
			RunService = { Heartbeat = FakeClient.signal(), RenderStepped = FakeClient.signal() },
			AssetService = {
				CreateEditableImage = function()
					error("no EditableImage in Lune")
				end,
			},
			Players = {
				LocalPlayer = {
					Character = nil,
					DisplayName = "Tester",
					WaitForChild = function()
						return Instance.new("Folder")
					end,
				},
			},
			GuiService = {
				SelectedObject = nil,
				GetGuiInset = function()
					return Vector2.zero
				end,
			},
			UserInputService = {
				TouchEnabled = false,
				GetLastInputType = function()
					return roblox.Enum.UserInputType.MouseMovement
				end,
				GetMouseLocation = function()
					return Vector2.new(100, 100)
				end,
				InputBegan = FakeClient.signal(),
				InputChanged = FakeClient.signal(),
				InputEnded = FakeClient.signal(),
			},
		}
		local load = FakeClient.loader(shared, require, stubs, services)
		local InventoryScreen = load("src/client/Ui/InventoryScreen.luau")
		local VIEW = { w = 1920, h = 1080, top = 58, base = 4, touch = false }
		FakeClient.VIEW.w, FakeClient.VIEW.h = VIEW.w, VIEW.h
		local screen = InventoryScreen.new(Instance.new("ScreenGui"))
		local uiScale = Instance.new("UIScale")
		uiScale.Parent = screen.root
		screen.root.Visible = true
		screen:setLayout(window.container, false)
		uiScale.Scale = screen:place(VIEW)
		local inventory = window.inventory
		inventory.slots[1] = stack(I.Pistol, {
			ch = I.Rounds9mm,
			mag = I.PistolMagazine,
			n = 9,
			ammo = I.Rounds9mm,
			optic = I.RedDotSight,
			muzzle = I.Suppressor,
			muzzleD = 100,
		})
		screen:render(window, nil, {})
		local chips = screen.hands.chips
		t.eq(#chips, 4, "MAG, OPTIC, MUZZLE, LIGHT")
		local mag, optic, muzzle, light = chips[1], chips[2], chips[3], chips[4]
		t.ok(FakeClient.shown(mag.button) and FakeClient.shown(optic.button) and FakeClient.shown(muzzle.button))
		t.ok(not FakeClient.shown(light.button), "no light: no chip")
		for _, chip in { mag, optic, muzzle } do
			local name = Items.displayName(chip.item)
			t.ok(chip.text.Text == name or chip.text.Text == chip.spec.label, `{name}: its name or its slot's`)
		end
		t.ok(FakeClient.shown(mag.dot), "a magazine wears: its dot")
		t.ok(FakeClient.shown(muzzle.dot), "so does a suppressor")
		t.ok(not FakeClient.shown(optic.dot), "an optic doesn't")
		-- Left of the item and right of it.
		local item = FakeClient.centre(screen.hands.holder)
		t.ok(FakeClient.centre(mag.button).X < item.X and FakeClient.centre(muzzle.button).X > item.X)
		t.ok(FakeClient.centre(optic.button).Y > FakeClient.centre(mag.button).Y, "two rows")
		-- Resting on one says what it is.
		local tip = screen:tooltipAt(FakeClient.centre(muzzle.button), window) :: { string }
		t.eq(table.concat(tip or {}, " | "), "Suppressor | Worn | Click to take it off")
		local opticTip = screen:tooltipAt(FakeClient.centre(optic.button), window) :: { string }
		t.eq(table.concat(opticTip or {}, " | "), "Red Dot Sight | Click to take it off")
		-- A click detaches it from the held slot, with the unload sound.
		muzzle.button.Activated:Fire()
		t.eq(#applied, 1)
		local action = applied[1] :: any
		t.eq(action.kind, "weapon")
		t.eq(action.op, Loading.Op.Detach)
		t.eq(action.part, Loading.Part.Muzzle)
		t.eq(action.slot, at(window, 1), "the held gun's window slot")
		t.eq(sounds[1], "item.firearm.unload")
		Menu.apply(window, action, false)
		t.ok(same(inventory.cursor, stack(I.Suppressor, nil, 100)), "onto the cursor")
		screen:render(window, nil, {})
		t.ok(not FakeClient.shown(muzzle.button), "the muzzle chip goes")
		muzzle.button.Activated:Fire()
		t.eq(#applied, 1, "a hidden chip sends nothing")
		-- No gun in hand: no chips.
		inventory.selected = 2
		inventory.slots[2] = stack(I.PistolMagazine, { n = 3, ammo = I.Rounds9mm })
		screen:render(window, nil, {})
		for _, chip in chips do
			t.ok(not FakeClient.shown(chip.button), "a magazine has no chips")
		end
	end)
end
