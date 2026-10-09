--!strict
--[[
	Using a magic weapon or a Mana Crystal without a block (Net/MagicSync HeldUse), pure: what the
	server checks before a cast (server Players/Magic) and the cadence both sides keep (client
	Interaction/Casting casts at it while the use button is held; the server refuses faster).

	  check    a HeldUse from a player in game `mode` (Shared/GameMode): refused for spectators
	           ("spectator") and the dead ("dead"), when its hotbar slot is not the selected one
	           ("slot"), when the hand doesn't hold the item it names ("item"), and for an item that
	           is neither a magic weapon nor a Mana Crystal ("use"); else the kind of use, "cast"
	           or "crystal". Mana is Players/Mana's (Shared/Mana.spend: not enough is "refused" and
	           told to the client); creative players (instabuild) cast for free (`free`).
	  ready    a weapon's `useTicks` (ItemList `magic`) since the last cast, with SLACK_TICKS 1 tick
	           of slack (the server's clock against the client's).
	  after    the time the cast counts from: when it was due (the last plus one use time) if it
	           came early within the slack or late by up to CREDIT_TICKS 2 ticks (network jitter:
	           a late cast doesn't push the next on-time one out), else (after a pause, or the
	           first) its arrival. So a run of casts never comes faster than one per use time,
	           but for the one slack tick.
]]

local GameMode = require(script.Parent.Parent.GameMode)
local Items = require(script.Parent.Parent.Items)

export type Use = "cast" | "crystal"

local Casting = {}

Casting.TICK = 1 / 20
Casting.SLACK_TICKS = 1
Casting.CREDIT_TICKS = 2
-- The Mana Crystal (used through HeldUse too).
Casting.CRYSTAL = Items.id.ManaCrystal

-- Does using `item` without a block go through HeldUse (a magic weapon, a Mana Crystal)?
function Casting.handles(item: number?): boolean
	return item ~= nil and (item == Casting.CRYSTAL or Items.magic(item) ~= nil)
end

--[[
	What a HeldUse may do (see the header): "cast" or "crystal", or nil and why not. `selected` is
	the player's selected hotbar slot and `held` the item in it (nil: empty).
]]
function Casting.check(
	mode: string,
	alive: boolean,
	selected: number,
	held: number?,
	slot: number,
	item: number
): (Use?, string?)
	if GameMode.isSpectator(mode) then
		return nil, "spectator"
	elseif not alive then
		return nil, "dead"
	elseif slot ~= selected then
		return nil, "slot"
	elseif held == nil or held ~= item then
		return nil, "item"
	elseif item == Casting.CRYSTAL then
		return "crystal", nil
	elseif Items.magic(item) then
		return "cast", nil
	end
	return nil, "use"
end

-- Do casts cost nothing in game `mode` (creative's instabuild)?
function Casting.free(mode: string): boolean
	return GameMode.instabuild(mode)
end

-- May a weapon with `useTicks` cast at `now` (seconds) after the last at `last` (nil: never)?
function Casting.ready(last: number?, now: number, useTicks: number): boolean
	return last == nil or now - last >= (useTicks - Casting.SLACK_TICKS) * Casting.TICK - 1e-9
end

-- The time a cast accepted at `now` counts from (see the header).
function Casting.after(last: number?, now: number, useTicks: number): number
	if last == nil then
		return now
	end
	local due = last + useTicks * Casting.TICK
	-- (Early within the slack, or late within the credit: it counts from when it was due.)
	if now <= due + Casting.CREDIT_TICKS * Casting.TICK then
		return due
	end
	-- (After a pause: from now.)
	return now
end

return Casting
