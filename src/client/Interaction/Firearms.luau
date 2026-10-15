--!strict
--[[
	Firearms in the hand, in the manner of DayZ (Shared/Weapons): raising and lowering, the sights,
	firing (predicted: ClientInventory.fire, then a Fire message, Net/WeaponSync), reloading, the
	fire mode and the light (Inventory action "weapon"), the aim camera, the poses, the HUD and
	the touch buttons. The client builder owns it; this is FOUNDATION's stub: a firearm in hand is
	never raised, so it only bashes (Interaction/BlockInteraction hits a mob with it as with a
	club) and never mines.

	Interaction/BlockInteraction calls in (and requires this module, so nothing this module
	requires may require BlockInteraction):
	  attackPress(source, mob, attack)  the attack button went down with a firearm in hand
	                                    (`source` "mouse", "gamepad" or "touch"; `mob` the mob in
	                                    reach aimed at, if any; `attack(mob, heavy?)` hits it).
	                                    true: taken (a raised gun fires); false: BlockInteraction
	                                    bashes `mob` (a lowered gun). Mining never starts.
	  attackRelease(source)             the attack button went up (any held item; maybe never
	                                    pressed here)
	  usePress(source)                  the use button went down with a firearm in hand, not on a
	                                    block that opens a menu (unless sneaking): true when taken
	                                    (raising), false for BlockInteraction's use as before
	  useRelease(source)                the use button taken by usePress went up
	  hidesCrosshair()                  polled every frame: true hides Minecraft's crosshair
	                                    (raised: a shoulder dot or the sights instead)
	Which presses come here is BlockInteraction's (a firearm of Shared/Weapons in hand); every
	function above answers false ("not taken") in this stub. The client boot script calls
	`start(world)` after BlockInteraction.start; the builder's own modules (aim camera, poses, HUD,
	touch buttons) start from there.
]]

local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local MobRenderer = require(script.Parent.Parent.Entities.MobRenderer)

-- Hits a mob (BlockInteraction's: an Attack message and a swing); `heavy` for the melee rework's
-- heavy attack.
export type Attack = (mob: MobRenderer.MobView, heavy: boolean?) -> ()

local Firearms = {}

-- Starts the firearms' input, camera, poses and HUD (the stub: nothing).
function Firearms.start(_world: ClientWorld.ClientWorld) end

-- The attack button went down with a firearm in hand (see the header): the stub never takes it.
function Firearms.attackPress(_source: string, _mob: MobRenderer.MobView?, _attack: Attack): boolean
	return false
end

-- The attack button went up.
function Firearms.attackRelease(_source: string) end

-- The use button went down with a firearm in hand (see the header): the stub never takes it.
function Firearms.usePress(_source: string): boolean
	return false
end

-- The use button usePress took went up.
function Firearms.useRelease(_source: string) end

-- Should Minecraft's crosshair hide now (see the header)?
function Firearms.hidesCrosshair(): boolean
	return false
end

return Firearms
