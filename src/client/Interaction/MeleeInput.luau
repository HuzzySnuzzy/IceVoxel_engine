--!strict
--[[
	The melee rework's input, in the manner of DayZ (Shared/Weapons/Melee holds the rules; the
	server Mobs/MobWorld lands the hits). Thin glue over Interaction/BlockInteraction's buttons:

	  light    with a listed melee weapon (Weapons.melee: the knives, the machete, the bats, the
	           crowbar, the axe, the pipe wrench, the sledgehammer) a press of the attack button on
	           a mob in reach is held here and lands on release: a press shorter than
	           Config.Weapons.Melee.HeavyHold (0.45 s) is a light attack (an Attack message, the
	           attack strength as ever) on the mob in reach at the release, with the
	           item.melee.swing whoosh
	  heavy    held HeavyHold or longer (Melee.heavyHold) and released with a mob in reach: an
	           Attack with the heavy flag (the weapon's heavy damage, twice the knockback, three
	           times the food) and the item.melee.heavy whoosh. Released with no mob in reach: a
	           miss, nothing is sent
	  others   any other item (swords, tools, the hand) hits at once on the press, as before, and
	           so does everything while the rework is off (Melee.spec is nil then)
	  guard    the use button held with a listed melee weapon (not on a block that opens a menu,
	           unless sneaking: BlockInteraction's call) guards: a Weapon message op Guard, which
	           the server keeps as the player's Types.AIM_ATTRIBUTE "guard" (zombie hits from the
	           front are cut by the weapon's guard share, Mobs/Mobs); releasing it sends Unguard.
	           While guarding no attack is sent (a press is dropped). Switching the held slot or
	           item away from the weapon ends the guard (and drops a held press)

	Touch: a tap on a mob is BlockInteraction's own light attack; a finger held still on a mob
	becomes a press here once it is a hold (BlockInteraction's TOUCH_HOLD, 0.3 s) and lands on
	lifting, heavy when held HeavyHold more. No guard on touch (the use button is a tap there).

	One press and one guard at a time: a second source's press while one is held is ignored. The
	server checks every hit (reach, sight, the attack strength) and every guard (only with a
	listed weapon in hand); this module only decides what to send. `guarding()` and `charge()`
	(0..1 of a heavy wind-up) let the client's poses and HUD (Player/WeaponPoses, Ui/WeaponHud)
	show them.

	Interaction/BlockInteraction calls in (and requires this module, so nothing this module
	requires may require BlockInteraction):
	  press(source, mob, held, attack)   the attack button went down on `mob` (in reach) with
	                                     `held` in hand (nil: empty); `attack(mob, heavy?)` hits it
	  release(source, mob, attack)       the attack button went up (`mob`: the one in reach now,
	                                     nil when none or when a screen opened; maybe never
	                                     pressed here)
	  guardPress(source)                 the use button went down with a listed melee weapon in
	                                     hand, not on a block that opens a menu (unless sneaking):
	                                     true when taken (guarding), false for BlockInteraction's
	                                     use as before
	  guardRelease(source)               the use button guardPress took went up
	The client boot script calls `start()` after BlockInteraction.start.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local Melee = require(Shared.Weapons.Melee)
local Protocol = require(Shared.Net.Protocol)
local WeaponSync = require(Shared.Net.WeaponSync)

local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local MobRenderer = require(script.Parent.Parent.Entities.MobRenderer)

-- Hits a mob (BlockInteraction's); `heavy` for a heavy attack.
export type Attack = (mob: MobRenderer.MobView, heavy: boolean?) -> ()

-- A press of the attack button held with a listed melee weapon: from which source, with which
-- item in which hotbar slot, since when (os.clock).
type Press = { source: string, item: number, slot: number, at: number }
-- The guard: the source holding it, with which item in which hotbar slot.
type Guard = { source: string, item: number, slot: number }

local MeleeInput = {}

local started = false
local pressed: Press? = nil
local guard: Guard? = nil

-- The held item's id (nil: an empty hand) and the selected hotbar slot.
local function holding(): (number?, number)
	local stack = ClientInventory.selectedStack()
	return if stack then stack.item else nil, ClientInventory.selected()
end

local function sendWeapon(op: number)
	ClientNet.send(Protocol.ClientMessage.Weapon, WeaponSync.encodeWeapon(op))
end

-- Ends the guard (Unguard sent) when there is one.
local function endGuard()
	if guard then
		guard = nil
		sendWeapon(WeaponSync.Op.Unguard)
	end
end

-- Is the press or the guard still on the item it began with (the same slot, the same item)?
local function stillHolding(item: number, slot: number): boolean
	local now, selected = holding()
	return now == item and selected == slot
end

-- Starts the melee input: a held press or a guard ends when the hand changes.
function MeleeInput.start()
	if started then
		return
	end
	started = true
	RunService.Heartbeat:Connect(function()
		local press = pressed
		if press and not stillHolding(press.item, press.slot) then
			pressed = nil
		end
		local held = guard
		if held and not (stillHolding(held.item, held.slot) and Melee.spec(held.item) ~= nil) then
			endGuard()
		end
	end)
end

-- The attack button went down on `mob` (see the header).
function MeleeInput.press(source: string, mob: MobRenderer.MobView, held: Items.Stack?, attack: Attack)
	local item = if held then held.item else nil
	if item == nil or Melee.spec(item) == nil then
		-- (Every other item, and everything with the rework off: at once, as before.)
		attack(mob, false)
		return
	end
	if guard ~= nil or pressed ~= nil then
		-- (No attacks while guarding; one press at a time.)
		return
	end
	pressed = { source = source, item = item, slot = ClientInventory.selected(), at = os.clock() }
end

-- The attack button went up (see the header).
function MeleeInput.release(source: string, mob: MobRenderer.MobView?, attack: Attack)
	local press = pressed
	if press == nil or press.source ~= source then
		return
	end
	pressed = nil
	if mob == nil or guard ~= nil or not stillHolding(press.item, press.slot) then
		return
	end
	local heavy = Melee.heavyHold(press.item, os.clock() - press.at)
	attack(mob, heavy)
	SoundPlayer.playFlat(if heavy then "item.melee.heavy" else "item.melee.swing")
end

-- The use button went down with a listed melee weapon (see the header): true when guarding.
function MeleeInput.guardPress(source: string): boolean
	if not Config.Weapons.Melee.Enabled then
		return false
	end
	local item, slot = holding()
	if item == nil or Melee.spec(item) == nil then
		return false
	end
	if guard then
		return true
	end
	guard = { source = source, item = item, slot = slot }
	-- (A press held for a hit is dropped: no attacks while guarding.)
	pressed = nil
	sendWeapon(WeaponSync.Op.Guard)
	return true
end

-- The use button guardPress took went up.
function MeleeInput.guardRelease(source: string)
	local held = guard
	if held and held.source == source then
		endGuard()
	end
end

-- Is the local player guarding with a melee weapon now?
function MeleeInput.guarding(): boolean
	return guard ~= nil
end

-- How far a held press has wound up to a heavy attack: 0 (none, or not a heavy weapon) .. 1 (a
-- release now is heavy).
function MeleeInput.charge(): number
	local press = pressed
	if press == nil then
		return 0
	end
	local hold = Config.Weapons.Melee.HeavyHold
	if not (hold > 0) then
		return 1
	end
	return math.clamp((os.clock() - press.at) / hold, 0, 1)
end

return MeleeInput
