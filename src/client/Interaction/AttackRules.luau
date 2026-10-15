--!strict
--[[
	What the attack button does to blocks, and what a tap on the touch screen does, with a weapon in
	hand (pure: Interaction/BlockInteraction asks, tests/spec/Melee checks it):

	  breaking  the attack button held breaks blocks: at once, and again every BreakInterval, with
	            instabuild ("instant"); over time in survival ("mine"); never without mayBuild,
	            never with a firearm in hand (it raises, fires and bashes: Interaction/Firearms),
	            and never while a melee weapon's press waits for its release (a light or heavy
	            attack on the mob it went down on) or its guard is up (Interaction/
	            MeleeInput.pressing), so a heavy attack wound up at a mob that walks off never digs
	            the block behind it
	  tap       a tap on a mob in front of the block (not a spectator) is a light attack
	            ("attack"), but with a firearm in hand nothing (its tap never bashes, and never uses
	            the door or the chest behind the mob either); anywhere else it uses ("use")
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)

export type Breaking = "instant" | "mine"
export type Tap = "attack" | "use"

local AttackRules = {}

-- How the attack button held breaks blocks in game `mode` (see the header; nil: it doesn't).
function AttackRules.breaking(mode: string, firearm: boolean, melee: boolean): Breaking?
	if firearm or melee then
		return nil
	elseif GameMode.instabuild(mode) then
		return "instant"
	elseif GameMode.mayBuild(mode) then
		return "mine"
	end
	return nil
end

-- What a tap does (see the header): `mob` one in front of the block tapped; nil: nothing.
function AttackRules.tap(mob: boolean, mode: string, firearm: boolean): Tap?
	if mob and not GameMode.isSpectator(mode) then
		return if firearm then nil else "attack"
	end
	return "use"
end

return AttackRules
