--!strict
--[[
	Terraria's mana (Config.Mana), shared and pure: how much a player may hold, how it comes back,
	what spending and potions do, and Mana Sickness. Server Players/Mana plays it out at 20 ticks a
	second (the authority: casting, potions, crystals, saving), client Player/ManaState and
	Ui/ManaHud only show what the server says.

	  Capacity   max = min(Max 400, Base 20 + PerCrystal 20 x crystals + the accessories' `mana`)
	             (Terraria's statManaMax2: 20 to start, each Mana Crystal adds 20 for good while
	             fewer than MaxCrystals 9 were used (200 with nine), a Band of Starpower 20 more
	             (Items/Accessories.stats), 400 at most). `maxOf` reads the accessories off an
	             inventory with a scratch Stats table, so it allocates nothing.
	  Regen      Terraria 1.4.4's Player.UpdateManaRegen with its own 60 Hz numbers, run
	             STEPS_PER_TICK = 3 steps every IceVoxel tick (20 Hz), in floats (Terraria keeps
	             whole numbers and a counter of 120ths: a low max regenerating slowly would round
	             to nothing, which floats don't):
	               spending  delay = 0.7 x (45 + 240 x (1 - mana / max)) Terraria ticks, from the
	                         mana before the spend (Terraria's maxRegenDelay of that update):
	                         0.525 s at full mana to 3.325 s empty;
	               a step    while delay > 0: delay -= 1, and 1 more standing still;
	                         when delay <= 0: r = floor(max / 7) + 1 (+ floor(max / 2) standing
	                         still), times (0.2 + 0.8 x mana / max) x 1.15, and mana += r / 120
	                         (r / 2 a second).
	             So, a second:            standing, full   empty   moving, full   empty
	                           max 20          7.47        1.49        1.72       0.35
	                           max 200         74.2        14.8        16.7       3.33
	             "Standing still" is the server's (Players/Mana, `stillness`): the feet moved no
	             more than 0.01 blocks and nothing was cast for STILL_TICKS 4 ticks running (0.2 s:
	             moves come at most 20 a second, unreliably, on the client's frames, so a single
	             tick without one says nothing; with 4, no walking player counts as still at 20 to
	             144 fps and up to 100 ms of jitter). Terraria 1.4.5.7 replaced the
	             delay with a slow regeneration while attacking; that was not taken: 1.4.4's rules
	             are the ones its wiki numbers (Mana Regeneration Band: +2.875 to +14.375 a second
	             = 25 x 1.15 x (0.2..1) / 2) cross-check.
	  Full       a tick that regenerated mana up to the max says so (`tick` returns true):
	             Terraria's "mana full" chime and sparkle, for regeneration only (not potions).
	  Sickness   Mana Sickness (effect 25, Shared/Effects): every mana potion adds SicknessSeconds
	             5 s to what is left, up to SicknessMax 10 s (`sicknessTicks`); while it lasts magic
	             damage is cut by SicknessDamage 5% for each second left (`damageFactor`: 25% at
	             5 s, 50% at 10 s), Terraria's.
	  HUD        a star holds STAR = 20 mana (`stars`: how many the max needs).
	  Tooltip    `tooltip(item)`: what a mana item says under its name (Items/Tooltip: the
	             first line gray, the rest blue, as the accessories'): a magic weapon its damage
	             (half hearts, Minecraft's "Attack Damage"), mana a cast and fire chance; a mana
	             potion the mana it restores; a Mana Crystal its +20 max (Terraria's
	             "Permanently increases maximum mana by 20"); a Fallen Star Terraria's
	             "Disappears after the sunrise".
]]

local Config = require(script.Parent.Config)
local Accessories = require(script.Parent.Items.Accessories)
local Drinks = require(script.Parent.ToughAsNails.Drinks)
local Items = require(script.Parent.Items)
local Types = require(script.Parent.Inventory.Types)

local Settings = Config.Mana

-- A player's mana as the regeneration needs it: the mana (a float) and the regeneration delay
-- (Terraria ticks, a float; 0 once mana comes back).
export type State = { mana: number, delay: number }

local Mana = {}

-- Terraria's ticks (60 a second) in one IceVoxel tick (20 a second).
Mana.STEPS_PER_TICK = 3
-- Terraria's ticks a second.
Mana.STEPS_PER_SECOND = 60
-- Mana a HUD star stands for.
Mana.STAR = 20
-- Terraria's numbers: the delay (0.7 x (45 + 240 x missing share)), a regeneration step's divisor
-- (mana += r / 120), the rate's bonus factor and its floor at no mana.
Mana.DELAY_FACTOR = 0.7
Mana.DELAY_BASE = 45
Mana.DELAY_MISSING = 240
Mana.REGEN_DIVISOR = 120
Mana.REGEN_FACTOR = 1.15
Mana.REGEN_FLOOR = 0.2

local scratch = Accessories.new()

--[[ Capacity ]]

-- Max mana with `crystals` Mana Crystals used and `bonus` mana from accessories.
function Mana.capacity(crystals: number, bonus: number?): number
	local used = math.clamp(math.floor(crystals), 0, Settings.MaxCrystals)
	return math.min(Settings.Max, Settings.Base + Settings.PerCrystal * used + math.max(bonus or 0, 0))
end

-- Max mana with `crystals` used and the accessories worn in `inventory` (nil: none).
function Mana.maxOf(crystals: number, inventory: Types.Inventory?): number
	local bonus = if inventory then Accessories.stats(inventory, scratch).mana else 0
	return Mana.capacity(crystals, bonus)
end

-- May one more Mana Crystal be used (Terraria: while the crystals' max is under 200)?
function Mana.canUseCrystal(crystals: number): boolean
	return crystals < Settings.MaxCrystals
end

-- HUD stars a max of `max` needs (one per STAR mana, a part star counting as one).
function Mana.stars(max: number): number
	return math.max(0, math.ceil(max / Mana.STAR))
end

--[[ Regeneration ]]

-- A full player's state.
function Mana.new(max: number): State
	return { mana = max, delay = 0 }
end

-- The regeneration delay (Terraria ticks) spending at `mana` of `max` starts.
function Mana.delayFor(mana: number, max: number): number
	local missing = if max > 0 then 1 - math.clamp(mana / max, 0, 1) else 0
	return Mana.DELAY_FACTOR * (Mana.DELAY_BASE + Mana.DELAY_MISSING * missing)
end

-- Regeneration a Terraria tick (r of the header, before the / 120) at `mana` of `max`.
local function regenPerStep(mana: number, max: number, still: boolean): number
	local r = math.floor(max / 7) + 1
	if still then
		r += math.floor(max / 2)
	end
	return r * (Mana.REGEN_FLOOR + (1 - Mana.REGEN_FLOOR) * math.clamp(mana / max, 0, 1)) * Mana.REGEN_FACTOR
end

-- Mana a second coming back at `mana` of `max` once the delay is over (standing still or not).
function Mana.rate(mana: number, max: number, still: boolean): number
	if max <= 0 then
		return 0
	end
	return regenPerStep(mana, max, still) / Mana.REGEN_DIVISOR * Mana.STEPS_PER_SECOND
end

-- Keeps mana within 0..max (accessories taken off lower the max).
function Mana.clamp(state: State, max: number)
	if state.mana ~= state.mana then
		state.mana = 0
	end
	state.mana = math.clamp(state.mana, 0, math.max(max, 0))
end

-- Takes `amount` if there is that much (whether it did); the delay starts from the mana before.
function Mana.spend(state: State, max: number, amount: number): boolean
	if amount ~= amount or amount < 0 or state.mana < amount then
		return false
	end
	if amount > 0 then
		state.delay = Mana.delayFor(state.mana, max)
		state.mana -= amount
	end
	return true
end

-- Gives up to `amount` (never past max); how much it gave.
function Mana.add(state: State, max: number, amount: number): number
	if amount ~= amount or amount <= 0 or state.mana >= max then
		return 0
	end
	local before = state.mana
	state.mana = math.min(max, before + amount)
	return state.mana - before
end

-- One Terraria tick of regeneration (see the header). Whether it filled mana up to the max.
function Mana.step(state: State, max: number, still: boolean): boolean
	if max <= 0 then
		return false
	end
	if state.delay > 0 then
		state.delay -= if still then 2 else 1
	end
	if state.delay > 0 or state.mana >= max then
		return false
	end
	state.delay = 0
	state.mana += regenPerStep(state.mana, max, still) / Mana.REGEN_DIVISOR
	if state.mana >= max then
		state.mana = max
		return true
	end
	return false
end

-- Ticks without a move or a cast before a player stands still (see the header).
Mana.STILL_TICKS = 4

--[[
	Standing still (see the header): `quiet` ticks so far without a move or a cast and whether this
	tick had one (`moved`: the feet more than 0.01 blocks from where they last moved, or a cast).
	Returns the new count and whether the player stands still now.
]]
function Mana.stillness(quiet: number, moved: boolean): (number, boolean)
	if moved then
		return 0, false
	end
	local count = math.min(quiet + 1, Mana.STILL_TICKS)
	return count, count >= Mana.STILL_TICKS
end

-- One IceVoxel tick: STEPS_PER_TICK steps. Whether regeneration filled mana up this tick.
function Mana.tick(state: State, max: number, still: boolean): boolean
	Mana.clamp(state, max)
	local filled = false
	for _ = 1, Mana.STEPS_PER_TICK do
		if Mana.step(state, max, still) then
			filled = true
		end
	end
	return filled
end

--[[ Mana Sickness ]]

-- Mana Sickness's ticks after one more mana potion, with `current` ticks left.
function Mana.sicknessTicks(current: number): number
	local tps = 20
	local add, most = Settings.SicknessSeconds * tps, Settings.SicknessMax * tps
	return math.min(math.max(current, 0) + add, most)
end

-- What magic damage is multiplied by with `ticks` of Mana Sickness left (1 without).
function Mana.damageFactor(ticks: number): number
	local seconds = math.max(ticks, 0) / 20
	return math.max(0, 1 - Settings.SicknessDamage * seconds)
end

--[[ Tooltips ]]

-- What `item` says about mana under its name (see the header; empty: nothing).
function Mana.tooltip(item: number): { string }
	local lines: { string } = {}
	local magic = Items.magic(item)
	if magic then
		table.insert(lines, "When used:")
		table.insert(lines, `{magic.damage} Magic Damage`)
		table.insert(lines, `Uses {magic.mana} mana`)
		local fire = magic.fire or 0
		if fire > 0 then
			table.insert(lines, `{math.floor(fire * 100 + 0.5)}% chance to set on fire`)
		end
		return lines
	end
	local restores = Drinks.manaOf(Drinks.of(item))
	if restores > 0 then
		table.insert(lines, "When drunk:")
		table.insert(lines, `Restores {restores} mana`)
	elseif item == Items.id.ManaCrystal then
		table.insert(lines, "When used:")
		table.insert(lines, `+{Settings.PerCrystal} max mana for good ({Settings.MaxCrystals} at most)`)
	elseif item == Items.id.FallenStar then
		table.insert(lines, "Disappears after the sunrise")
	end
	return lines
end

return Mana
