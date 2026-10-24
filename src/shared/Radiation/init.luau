--!strict
--[[
	Radiation (Mekanism's, simplified), shared and pure: what is radioactive and how strongly, how
	an exposure falls off and is shielded, how a dose builds up and decays, which doses make which
	Radiation Sickness, and the client's Geiger counter clicks. Server Players/RadiationRules plays
	a player's look out with these (Players/Radiation, the glue, once a second a player); client
	Audio/Geiger clicks from the rate the server publishes. Numbers in Config.Radiation.

	  Sources    by id (`strength`: Sv/h a block away or nearer, or carried): Uranium Ore, the Block
	             of Raw Uranium and the Block of Uranium in the world; those three as items, Raw
	             Uranium, the Uranium Ingot and Nugget carried (Config.Radiation.Sources by name: a
	             block item's id is its block's, so one table holds both). A chest's uranium is not
	             looked at: only blocks and what the player carries.
	  Carried    `carried(inventory, extra)`: every stack in the 36 slots, the armor, the cursor and
	             `extra` (an open personal crafting grid) at its strength times its count.
	  Falloff    `falloff(d^2)`: Mekanism's magnitude / max(1, d^2) (d from the body's centre to the
	             block's, in blocks), less its value at Config.Radiation.Radius so it fades to
	             nothing there instead of stopping (continuous as a player walks away).
	  Shielding  `transmission`: the share a ray from a source to the body gets through, each cell
	             strictly between them (a voxel walk, Amanatides and Woo's) letting through its
	             block's `TRANSMISSION` (Config.Radiation.Shielding: any full solid opaque block
	             `Solid` (leaves too: they are solid and opaque), lead and raw lead blocks their own;
	             anything else, and unknown cells, all of it). `scan(getBlock, x, y, z)` reads every cell of the sphere (OFFSETS, nearest
	             first) and traces the nearest MaxRays sources it finds; the rest take the mean
	             share of those traced in their octant of directions from the body, all of it in
	             an octant with none traced (only a player-built heap has that many within the
	             radius; a lead wall on one side hides none in the open on the other). Its cost is bounded: #OFFSETS reads and MaxRays rays of at
	             most 3 x (Radius + 1) cells each (`readsBound`).
	  Hazmat     `shielding(armor)`: the share the armor worn keeps out (Config.Radiation.Hazmat:
	             Mekanism's 0.25, 0.4, 0.2 and 0.15, summed as Mekanism's getRadiationResistance,
	             at most all of it), of the blocks' radiation and the carried alike; `exposure`
	             applies it (and MinRate).
	  Dose       `dose(dose, rate, seconds)`: dD/dt = rate / 3600 - D ln 2 / HalfLife, solved exactly
	             over the step (Mekanism adds magnitude / 3600 a second and multiplies the dose by
	             its decay rate), so a dose under a steady rate settles at rate x HalfLife / (3600
	             ln 2) and decays by halves without one.
	  Sickness   `level(dose)`: 0, or the highest of Config.Radiation.Sickness.Bands reached
	             (Mekanism's 0.1, 1 and 10 Sv); `symptoms(level)`: Radiation Sickness at the level's
	             amplifier, Minecraft's Hunger from HungerFrom, Nausea from NauseaFrom; `renewal`
	             gives or renews each of them (see there) so they last Sickness.Ticks after the dose
	             falls below their band, and an effect that acts on an interval (the sickness's
	             hurt: EffectList `interval`) keeps acting on it.
	  Clicks     `clickRate(rate)`: clicks a second, Config.Radiation.Clicks.PerSvh x the rate's
	             square root, at most Max (none below MinRate); `clicks(rate, dt, roll)`: whether a
	             frame of `dt` seconds clicks, a Poisson process's chance rate x dt (at most one a
	             frame).
	  Shown      RATE_ATTRIBUTE and DOSE_ATTRIBUTE: the player attributes the server publishes
	             (`round`: two significant figures, so they change only when it shows; absent at 0),
	             `format` for F3 ("1.2 Sv/h", "350 mSv").
]]

local Blocks = require(script.Parent.Blocks)
local Config = require(script.Parent.Config)
local Effects = require(script.Parent.Effects)
local Items = require(script.Parent.Items)

type Stack = Items.Stack

-- What `carried` reads of an inventory (Inventory/Types.Inventory has these).
export type Carrying = {
	slots: { [number]: Stack? },
	armor: { [number]: Stack? },
	cursor: Stack?,
}

-- The block at a cell, nil when unknown (not loaded).
export type GetBlock = (x: number, y: number, z: number) -> number?

-- A symptom of a level: an effect and its amplifier.
export type Symptom = { effect: number, amplifier: number }

local Radiation = {}

local settings = Config.Radiation
local sickness = settings.Sickness

-- The player attributes the server publishes (server Players/Radiation): the exposure rate
-- (Sv/h, after shielding) and the dose (Sv); absent at 0.
Radiation.RATE_ATTRIBUTE = "IceVoxelRadiation"
Radiation.DOSE_ATTRIBUTE = "IceVoxelRadiationDose"
-- Ticks a non-interval symptom (Hunger, Nausea) is renewed by at a time: about one Effects
-- message every 10 s while it holds.
Radiation.RENEW_TICKS = 200
-- A ray that let through less than this is stopped.
local CUTOFF = 1e-4
-- Doses under this are none (Sv).
local NO_DOSE = 1e-6

--[[ Sources ]]

-- Sv/h by block or item id (block items share their block's id).
local strength: { [number]: number } = {}
for name, value in settings.Sources :: { [string]: number } do
	assert(type(value) == "number" and value > 0, `Config.Radiation.Sources.{name} must be a positive number`)
	strength[Items.id[name]] = value
end
Radiation.STRENGTH = table.freeze(strength)

-- Sv/h a source `id` gives a block away or carried (0: none).
function Radiation.strength(id: number): number
	return strength[id] or 0
end

-- Is block `id` radioactive?
function Radiation.isSource(id: number): boolean
	return strength[id] ~= nil
end

local function stackStrength(stack: Stack?): number
	if stack == nil then
		return 0
	end
	local value = strength[stack.item]
	return if value then value * stack.count else 0
end

--[[
	Sv/h of what is carried: every stack of `inventory`'s slots, armor and cursor, and of `extra`
	(nil: none), at its strength times its count.
]]
function Radiation.carried(inventory: Carrying, extra: { [number]: Stack? }?): number
	local total = 0
	for _, stack in inventory.slots do
		total += stackStrength(stack)
	end
	for _, stack in inventory.armor do
		total += stackStrength(stack)
	end
	total += stackStrength(inventory.cursor)
	if extra then
		for _, stack in extra do
			total += stackStrength(stack)
		end
	end
	return total
end

--[[ The Hazmat suit ]]

-- The share each item worn keeps out, by item id.
local hazmat: { [number]: number } = {}
for name, share in settings.Hazmat :: { [string]: number } do
	assert(type(share) == "number" and share >= 0 and share <= 1, `Config.Radiation.Hazmat.{name} must be 0..1`)
	hazmat[Items.id[name]] = share
end
Radiation.SHIELDING = table.freeze(hazmat)

-- The share of radiation the armor worn (`armor`, slots 1..4) keeps out: the pieces' summed, at
-- most 1 (Mekanism's getRadiationResistance).
function Radiation.shielding(armor: { [number]: Stack? }): number
	local share = 0
	for _, stack in armor do
		if stack then
			share += hazmat[stack.item] or 0
		end
	end
	return math.min(1, share)
end

-- The rate (Sv/h) a body gets of `raw` (blocks and carried) with `share` kept out; 0 below
-- MinRate.
function Radiation.exposure(raw: number, share: number): number
	local rate = raw * (1 - math.clamp(share, 0, 1))
	return if rate >= settings.MinRate then rate else 0
end

--[[ Falloff and shielding ]]

local RADIUS = settings.Radius
local EDGE = 1 / (RADIUS * RADIUS)

--[[
	The share of a source's strength reaching a point `d2` (blocks squared) from it: 1 / max(1, d2)
	less its value at the radius (0 there and beyond).
]]
function Radiation.falloff(d2: number): number
	return math.max(0, 1 / math.max(1, d2) - EDGE)
end

-- Share each block lets through (absent: all of it).
local passes: { [number]: number } = {}
do
	local shielding = settings.Shielding :: { [string]: number }
	for id = 0, Blocks.count - 1 do
		if Blocks.isSolid(id) and Blocks.isOpaque(id) then
			passes[id] = shielding.Solid
		end
	end
	for name, share in shielding do
		if name ~= "Solid" then
			passes[Blocks.id[name]] = share
		end
	end
end
Radiation.TRANSMISSION = table.freeze(passes)

--[[
	The share of radiation a ray from the centre of source cell (sx, sy, sz) to the point (px, py,
	pz) (blocks) gets through: each cell strictly between them lets through its block's share (see
	the header). Visits at most the Manhattan distance between the two cells.
]]
function Radiation.transmission(
	getBlock: GetBlock,
	sx: number,
	sy: number,
	sz: number,
	px: number,
	py: number,
	pz: number
): number
	local ox, oy, oz = sx + 0.5, sy + 0.5, sz + 0.5
	local dx, dy, dz = px - ox, py - oy, pz - oz
	local ex, ey, ez = math.floor(px), math.floor(py), math.floor(pz)
	local x, y, z = sx, sy, sz
	local stepX = if dx > 0 then 1 else -1
	local stepY = if dy > 0 then 1 else -1
	local stepZ = if dz > 0 then 1 else -1
	-- (The ray's parameter at the next boundary on each axis, and between boundaries.)
	local nextX = if dx ~= 0 then ((if dx > 0 then x + 1 else x) - ox) / dx else math.huge
	local nextY = if dy ~= 0 then ((if dy > 0 then y + 1 else y) - oy) / dy else math.huge
	local nextZ = if dz ~= 0 then ((if dz > 0 then z + 1 else z) - oz) / dz else math.huge
	local deltaX = if dx ~= 0 then math.abs(1 / dx) else math.huge
	local deltaY = if dy ~= 0 then math.abs(1 / dy) else math.huge
	local deltaZ = if dz ~= 0 then math.abs(1 / dz) else math.huge
	local share = 1
	for _ = 1, math.abs(ex - x) + math.abs(ey - y) + math.abs(ez - z) do
		if nextX <= nextY and nextX <= nextZ then
			x += stepX
			nextX += deltaX
		elseif nextY <= nextZ then
			y += stepY
			nextY += deltaY
		else
			z += stepZ
			nextZ += deltaZ
		end
		if x == ex and y == ey and z == ez then
			break
		end
		local block = getBlock(x, y, z)
		local pass = if block then passes[block] else nil
		if pass then
			share *= pass
			if share < CUTOFF then
				return 0
			end
		end
	end
	return share
end

-- The sphere's cells, as offsets from the body's cell, nearest first: every cell whose centre
-- may be within the radius of a point anywhere in the body's cell.
local offsetX: { number }, offsetY: { number }, offsetZ: { number } = {}, {}, {}
do
	local reach = RADIUS + math.sqrt(3) / 2
	local limit = math.ceil(reach)
	local cells: { { number } } = {}
	for dy = -limit, limit do
		for dz = -limit, limit do
			for dx = -limit, limit do
				local d2 = dx * dx + dy * dy + dz * dz
				if d2 < reach * reach then
					table.insert(cells, { d2, dx, dy, dz })
				end
			end
		end
	end
	table.sort(cells, function(a: { number }, b: { number }): boolean
		if a[1] ~= b[1] then
			return a[1] < b[1]
		elseif a[3] ~= b[3] then
			return a[3] < b[3]
		elseif a[4] ~= b[4] then
			return a[4] < b[4]
		end
		return a[2] < b[2]
	end)
	for i, cell in cells do
		offsetX[i], offsetY[i], offsetZ[i] = cell[2], cell[3], cell[4]
	end
end
-- Cells a look reads.
Radiation.OFFSETS = #offsetX
local MAX_RAYS = settings.MaxRays

-- The most block reads one `scan` makes: the sphere and MaxRays rays (each at most the Manhattan
-- distance of a cell within the radius, 3 x (Radius + 1)).
function Radiation.readsBound(): number
	return Radiation.OFFSETS + MAX_RAYS * 3 * (math.ceil(RADIUS) + 1)
end

-- (`scan`'s sums per octant, reused.)
local octantPassed: { number } = table.create(8, 0)
local octantCount: { number } = table.create(8, 0)
local octantUntraced: { number } = table.create(8, 0)

--[[
	The rate (Sv/h, before the Hazmat suit) the blocks around the point (x, y, z) give it (the
	body's centre, blocks): every source within the radius, its falloff and shielding (see the
	header).
]]
function Radiation.scan(getBlock: GetBlock, x: number, y: number, z: number): number
	local cx, cy, cz = math.floor(x), math.floor(y), math.floor(z)
	local total, traced = 0, 0
	-- (Per octant of directions from the body: the traced sources' summed share let through and
	-- their count, and the untraced ones' unshielded rate.)
	local passed, count, untraced = octantPassed, octantCount, octantUntraced
	for octant = 1, 8 do
		passed[octant], count[octant], untraced[octant] = 0, 0, 0
	end
	for i = 1, #offsetX do
		local bx, by, bz = cx + offsetX[i], cy + offsetY[i], cz + offsetZ[i]
		local block = getBlock(bx, by, bz)
		local source = if block then strength[block] else nil
		if source then
			local dx, dy, dz = bx + 0.5 - x, by + 0.5 - y, bz + 0.5 - z
			local share = Radiation.falloff(dx * dx + dy * dy + dz * dz)
			if share > 0 then
				local octant = 1 + (if dx < 0 then 1 else 0) + (if dy < 0 then 2 else 0) + (if dz < 0 then 4 else 0)
				if traced < MAX_RAYS then
					local pass = Radiation.transmission(getBlock, bx, by, bz, x, y, z)
					traced += 1
					passed[octant] += pass
					count[octant] += 1
					total += source * share * pass
				else
					untraced[octant] += source * share
				end
			end
		end
	end
	-- The untraced take the mean share of the traced in their octant (a wall round the body
	-- shields them as it does the near ones), or all of it where none was traced (a lead wall on
	-- one side hides no heap in the open on the other).
	for octant = 1, 8 do
		local rest = untraced[octant]
		if rest > 0 then
			local n = count[octant]
			total += rest * (if n > 0 then passed[octant] / n else 1)
		end
	end
	return total
end

--[[ The dose ]]

local DECAY = math.log(2) / settings.HalfLife

--[[
	The dose (Sv) after `seconds` at `rate` (Sv/h) from `dose` (see the header): it rises towards
	rate x HalfLife / (3600 ln 2) and decays by halves every HalfLife.
]]
function Radiation.dose(dose: number, rate: number, seconds: number): number
	local settled = math.max(0, rate) / 3600 / DECAY
	local after = settled + (math.max(0, dose) - settled) * math.exp(-DECAY * math.max(0, seconds))
	return if after >= NO_DOSE then after else 0
end

-- The dose `rate` settles at (Sv).
function Radiation.settled(rate: number): number
	return math.max(0, rate) / 3600 / DECAY
end

--[[ Sickness ]]

local BANDS: { number } = sickness.Bands
local SICKNESS = Effects.id.RadiationSickness
local HUNGER = Effects.id.Hunger
local NAUSEA = Effects.id.Nausea

-- The sickness's level at `dose`: 0, or 1.. the highest band reached.
function Radiation.level(dose: number): number
	local level = 0
	for i, band in BANDS do
		if dose >= band then
			level = i
		end
	end
	return level
end

-- What a level brings (none at 0): Radiation Sickness at amplifier level - 1, Hunger and Nausea
-- from their levels (see the header).
function Radiation.symptoms(level: number): { Symptom }
	local list: { Symptom } = {}
	if level >= 1 then
		table.insert(list, { effect = SICKNESS, amplifier = level - 1 })
	end
	if level >= sickness.HungerFrom then
		table.insert(list, { effect = HUNGER, amplifier = level - sickness.HungerFrom })
	end
	if level >= sickness.NauseaFrom then
		table.insert(list, { effect = NAUSEA, amplifier = 0 })
	end
	return list
end

-- Ticks effect `effect` at `amplifier` is renewed by at a time: its acting interval (EffectList
-- `interval` >> amplifier, at least 1), else RENEW_TICKS.
function Radiation.step(effect: number, amplifier: number): number
	local def = Effects.get(effect)
	if def and def.interval > 0 then
		return math.max(1, bit32.rshift(def.interval, math.clamp(amplifier, 0, 31)))
	end
	return Radiation.RENEW_TICKS
end

--[[
	The ticks to give `effect` at `amplifier` now (nil: leave it), the player having it at
	`current` (nil: not) with `ticks` left (Effects.INFINITE: for good):
	  * none, or a weaker one: Sickness.Ticks afresh (the stronger wins: MobEffectInstance.update);
	  * a stronger one, or one for good: nothing (it runs out first);
	  * the same, once it ran down a step (`step`): its ticks plus whole steps, up to
	    Sickness.Ticks, so an effect acting on an interval keeps acting every interval (renewed to
	    the full time it would act at once again).
]]
function Radiation.renewal(effect: number, amplifier: number, current: number?, ticks: number): number?
	local full = sickness.Ticks
	if current == nil or ticks == 0 or amplifier > current then
		return full
	elseif amplifier < current or ticks == Effects.INFINITE then
		return nil
	end
	local step = Radiation.step(effect, amplifier)
	if ticks > full - step then
		return nil
	end
	return ticks + step * ((full - ticks) // step)
end

--[[ The Geiger counter ]]

-- Clicks a second at `rate` (Sv/h; see the header).
function Radiation.clickRate(rate: number): number
	if not (rate >= settings.MinRate) then
		return 0
	end
	local clicks = settings.Clicks
	return math.min(clicks.Max, clicks.PerSvh * math.sqrt(rate))
end

-- Does a frame of `dt` seconds at `rate` click (`roll`: uniform 0..1)?
function Radiation.clicks(rate: number, dt: number, roll: number): boolean
	return roll < math.min(1, Radiation.clickRate(rate) * math.max(0, dt))
end

--[[ Shown ]]

-- `value` to two significant figures (0 for none, negative or not a number).
function Radiation.round(value: number): number
	if not (value > 0) or value == math.huge then
		return 0
	end
	local scale = 10 ^ (math.floor(math.log10(value)) - 1)
	return math.round(value / scale) * scale
end

local PREFIXES: { { scale: number, prefix: string } } = {
	{ scale = 1, prefix = "" },
	{ scale = 1e-3, prefix = "m" },
	{ scale = 1e-6, prefix = "µ" },
	{ scale = 1e-9, prefix = "n" },
}

-- Sieverts with Mekanism's SI prefix, two significant figures, `unit` after ("Sv" or "Sv/h"):
-- "54 Sv/h", "350 mSv", "0 Sv".
function Radiation.format(value: number, unit: string): string
	local rounded = Radiation.round(value)
	if rounded <= 0 then
		return `0 {unit}`
	end
	for _, prefix in PREFIXES do
		if rounded >= prefix.scale * 0.9999 then
			local scaled = rounded / prefix.scale
			local text = if scaled >= 10 then string.format("%d", math.round(scaled)) else string.format("%.1f", scaled)
			return `{text} {prefix.prefix}{unit}`
		end
	end
	return `<1 n{unit}`
end

return Radiation
