--!strict
--[[
	The melee rework's input, in the manner of DayZ (Shared/Weapons/Melee): a click on a mob is a
	light attack, a hold of Config.Weapons.Melee.HeavyHold a heavy one (an Attack with the heavy
	flag), and the use button held with a listed melee weapon guards (a Weapon message). The
	inventory and melee builder owns it; this is FOUNDATION's stub, which keeps today's melee:
	every press on a mob hits it at once, nothing guards.

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

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Items = require(Shared.Items)

local MobRenderer = require(script.Parent.Parent.Entities.MobRenderer)

-- Hits a mob (BlockInteraction's); `heavy` for a heavy attack.
export type Attack = (mob: MobRenderer.MobView, heavy: boolean?) -> ()

local MeleeInput = {}

-- Starts the melee input (the stub: nothing).
function MeleeInput.start() end

-- The attack button went down on `mob` (see the header): the stub hits it at once (light).
function MeleeInput.press(_source: string, mob: MobRenderer.MobView, _held: Items.Stack?, attack: Attack)
	attack(mob, false)
end

-- The attack button went up (see the header).
function MeleeInput.release(_source: string, _mob: MobRenderer.MobView?, _attack: Attack) end

-- The use button went down with a listed melee weapon (see the header): the stub never guards.
function MeleeInput.guardPress(_source: string): boolean
	return false
end

-- The use button guardPress took went up.
function MeleeInput.guardRelease(_source: string) end

return MeleeInput
