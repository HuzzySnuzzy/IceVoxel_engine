--!strict
--[[
	Loading weapons in the inventory, pure: DayZ's "combine" by clicks, and the weapon actions
	(Inventory/Types action kind "weapon"). The inventory and melee builder owns the rules; this
	is FOUNDATION's stub, which changes nothing (every click behaves as Minecraft's).

	Clicks (`click`, from Inventory/Menu's PICKUP before Minecraft's own: true = handled, the
	click is done): button 0 left, 1 right, on window slot `index` holding the current stack with
	the carried one on the cursor:
	  ammo on a magazine of its calibre (empty or the same ammo, not full): left loads all that
	  fit, right one round; ammo on an internal-feed gun: the chamber first, then the magazine;
	  ammo on a detachable-feed gun with an empty chamber (not jammed): one round chambered by
	  hand; a magazine on its gun: attached (one already in comes out onto the cursor); an
	  attachment on a gun it fits: mounted (one already in that slot comes onto the cursor); the
	  same family refused (wrong calibre, full, other ammo, doesn't fit): nothing; an empty cursor
	  right-clicking a magazine with rounds: its rounds onto the cursor; on a gun with something
	  in it: out comes the magazine (rounds and wear in it), else the internal rounds then the
	  chambered one, else the muzzle device, else the optic, else the light; an empty gun or
	  magazine: Minecraft's take-half.
	Actions (`apply`, Inventory/Menu's `weapon` action; returns the stacks thrown out): op 1
	reload, 2 load one round (internal feed), 3 clear a jam (the round is lost), 4 next fire mode,
	5 the light on or off (ops 1..5 on the held gun, slot -1), 6 detach part `part` of the gun or
	magazine in window slot `slot` (1 magazine, 2 internal rounds and the chamber, 3 optic,
	4 muzzle, 5 light, 6 the chamber alone; on a magazine 2 its rounds). Out-going stacks go onto
	the cursor when a screen is open and it is empty, else into the inventory (`ops.add`), else
	are thrown (returned).
	`combines` answers the screens' outline (Ui/Screens.feedbackAt): "combine" when a left click
	would load or attach, "blocked" when it is the same family but refused, nil otherwise.

	Inventory/Menu requires this module, so this module never requires Menu: Menu hands it its own
	slot functions (`MenuOps`: Menu.get, Menu.set, Menu.add).
]]

local Items = require(script.Parent.Parent.Items)
local Types = require(script.Parent.Parent.Inventory.Types)

type Stack = Items.Stack

-- Inventory/Menu's slot functions (see the header).
export type MenuOps = {
	get: (window: Types.Window, index: number) -> Stack?,
	set: (window: Types.Window, index: number, stack: Stack?) -> (),
	add: (inventory: Types.Inventory, stack: Stack) -> Stack?,
}

export type Combine = "combine" | "blocked"

local Loading = {}

-- The weapon actions' ops (Types action kind "weapon"), and detach's parts.
Loading.Op = table.freeze({ Reload = 1, LoadRound = 2, Unjam = 3, Mode = 4, Light = 5, Detach = 6 })
Loading.Part = table.freeze({ Magazine = 1, Rounds = 2, Optic = 3, Muzzle = 4, Light = 5, Chamber = 6 })
-- `slot` of the ops on the held gun.
Loading.HELD = -1

--[[
	A PICKUP click (`button` 0 or 1) on window slot `index` (see the header): true when the
	weapon rules handled it (the click is done), false to let Minecraft's pickup run.
]]
function Loading.click(_window: Types.Window, _index: number, _button: number, _ops: MenuOps): boolean
	return false
end

-- A weapon action (see the header): the stacks thrown out of the window.
function Loading.apply(_window: Types.Window, _action: Types.Action, _creative: boolean, _ops: MenuOps): { Stack }
	return {}
end

-- The screens' outline for `carried` over `current` (see the header).
function Loading.combines(_carried: Stack?, _current: Stack?): Combine?
	return nil
end

return Loading
