--!strict
--[[
	The status icons' layout and rules (Ui/StatusCluster draws them; pure, so the specs check every
	rule: tests/spec/StatusLayout). A survival game's notifiers at the bottom right of the screen,
	in place of Minecraft's hearts, armor, hunger shanks, Tough As Nails' droplets and thermometer,
	Terraria's mana stars and the experience bar:

	  notifiers  six white silhouettes (Ui/StatusGlyphs), left to right THIRST, FOOD, TEMPERATURE,
	             a divider, MANA, ARMOR, HEALTH (ORDER, GROUP), in columns COLUMN wide at a PITCH
	             of 15 (2 apart in a group), the divider centred in a DIVIDER slot of 7 between the
	             groups: NOTIFIERS_W (93) GUI pixels across, right-aligned (`columns`). A notifier is
	             there while its feature is on (thirst, hunger, temperature: Tough As Nails' and
	             Minecraft's switches as the server sends them; mana: Config.Mana.Enabled; armor and
	             health always), so the columns never move because of a value: a stat that reads
	             nothing dims instead. The block is NOTIFIERS_H (23) tall (ROW): rising chevrons
	             0..6 above the glyph, the glyph 6..17, falling chevrons 17..23; with
	             Config.Ui.StatusValues the value 23..30 under it (`valueText`).
	  glyphs     each glyph empties from the top as its stat drops (`fill`: rows lit of GLYPH, 0
	             only at nothing, all only when full, spread over the drawing's own height rather
	             than its square, `litHeight`, so one row lit is a row of the drawing), and takes
	             its level's colour (`level`, `temperatureLevel`, `colour`): levels 1 and 2
	             white-grey (Icon), 3 yellow (Warn), 4 red (Critical), 5 blinking red and white
	             every Theme.Time.BLINK; temperature's cold side in its own blues (ColdWarn,
	             ColdCritical). The emptied part is faint grey while the stat is fine and takes the
	             level's colour (and blink) from level 3 (`emptyColour`, at Theme.GLYPH_ALARM_T),
	             so a starving player's empty stomach is a blinking red one. Thresholds: health in half
	             hearts of 20 (scaled from the Humanoid's maximum: `halves`) yellow at 12 or less,
	             red at 6, blinking at 3; food and thirst points yellow at 6, red at 3, blinking at
	             0; mana's share yellow under 0.25, red under 0.10 (no blink); armor always Icon
	             (its fill is its points, out of 20); temperature by zone: neutral 0, warning +-1,
	             critical +-2, blinking while freezing or overheating. Mana full and idle (no magic
	             weapon held) is lit through but faint (`manaPaint`), unlike an empty star.
	  trends     1 to 3 chevrons above a glyph while its stat rises, below while it falls
	             (`chevronAt`): health falls by its drains (Bleeding, Poison, Wither, starving,
	             dehydrated: one chevron each, up to 3), else one for a hit in the last 2 s, else
	             rises one while it regenerates (`regenerating`: hunger's rule with hunger on, thirst's
	             with hunger off, never at full health); food and thirst fall two under the Hunger /
	             Thirst effect, one with no saturation / hydration left; the body temperature moves
	             towards its target (one chevron; a held Thermometer tells how fast: 1 to 3 by the
	             distance); mana rises or falls one for a second after it changed.
	  badges     conditions as small silhouettes (BADGE, 9 GUI pixels, at a BADGE_PITCH of 11) in
	             rows of BADGES_PER_ROW (5) above the notifier block, right-aligned, the first
	             (highest priority, BADGES order) at the right of the lowest row, the sixth starting
	             the row above (`badgeAt`). BADGES always (the effect icons in the top right then
	             leave them out), STATUS_BADGES (Tough As Nails' Climate Clemency, Internal Warmth and
	             Chill) only with Config.Effects.Hud off, when nothing else shows them. A badge's
	             number (`badgeText`): its level from II, Infection's stage always, Climate
	             Clemency's whole minutes left.
	  knowledge  under the notifiers (the full variant): the knowledge level's number right-aligned
	             in LEVEL and the progress into the level as a 2 pixel bar in XP_BAR (XP_H tall).

	Variants (`size`, `blocks`): "full" (badges, notifiers, values, knowledge: the HUD where there
	is room), "lean" (badges and notifiers: the HUD where the full one doesn't fit) and "dock" (the
	notifiers alone: the open inventory's quickbar band, Ui/StatusDock). Every variant is
	NOTIFIERS_W wide, so the columns stay put whichever shows; the badges stack above the
	notifiers rather than beside them, because beside a 182 pixel quickbar the bottom right of a
	16:9 screen at its Auto scale has about 110 GUI pixels across: the notifiers and nothing more.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Hunger = require(Shared.Hunger)
local Thirst = require(Shared.ToughAsNails.Thirst)

-- A notifier's name: "thirst", "food", "temperature", "mana", "armor" or "health" (ORDER). (Plain
-- strings, so tables keyed by them and the names read from ORDER type-check alike.)
export type Notifier = string
-- A variant: "full", "lean" or "dock" (see the header).
export type Variant = string
-- A temperature's side: "cold", "hot" or "neutral".
export type Side = string

local StatusLayout = {}

--[[ Geometry (GUI pixels) ]]

-- A notifier's column, the step between columns in a group, and the glyph (centred in the column).
StatusLayout.COLUMN = 13
StatusLayout.PITCH = 15
StatusLayout.GLYPH = 11
-- The slot between the groups (a 1 x 6 Divider bar centred in it).
StatusLayout.DIVIDER = 7
StatusLayout.DIVIDER_BAR = table.freeze({ w = 1, h = 6 })
-- The notifier block: six columns and the divider's slot; 23 tall (30 with values).
StatusLayout.NOTIFIERS_W = 93
StatusLayout.NOTIFIERS_H = 23
StatusLayout.VALUE_H = 7
-- Every variant's width.
StatusLayout.WIDTH = StatusLayout.NOTIFIERS_W
-- Rows of the notifier block: rising chevrons, the glyph, falling chevrons, the value.
StatusLayout.ROW = table.freeze({ up = 0, glyph = 6, down = 17, value = 23 })
-- A chevron (5 x 2, centred in the column) and the step between stacked ones.
StatusLayout.CHEVRON = table.freeze({ w = 5, h = 2, step = 2 })
StatusLayout.MAX_TREND = 3
-- Badges: their size, step, a row's count and height (a row is BADGE_ROW_H above the last).
StatusLayout.BADGE = 9
StatusLayout.BADGE_PITCH = 11
StatusLayout.BADGES_PER_ROW = 5
StatusLayout.BADGE_ROW_H = 12
-- The knowledge row: its height, the level's text and the progress bar in it.
StatusLayout.XP_H = 8
StatusLayout.LEVEL = table.freeze({ x = 0, w = 14 })
StatusLayout.XP_BAR = table.freeze({ x = 16, y = 3, w = 77, h = 2 })

--[[ What shows ]]

StatusLayout.ORDER = table.freeze({ "thirst", "food", "temperature", "mana", "armor", "health" } :: { Notifier })
StatusLayout.GROUP = table.freeze({ thirst = 1, food = 1, temperature = 1, mana = 2, armor = 2, health = 2 } :: {
	[Notifier]: number,
})
-- Badges in priority order (the first nearest the notifiers' right end; Effects names).
StatusLayout.BADGES = table.freeze({ "Bleeding", "Infection", "Poison", "Wither", "Hunger", "Thirst", "Nausea" })
-- Tough As Nails' status effects, badges only while the effect icons are off (Config.Effects.Hud).
StatusLayout.STATUS_BADGES = table.freeze({ "ClimateClemency", "InternalWarmth", "InternalChill" })
StatusLayout.MAX_BADGES = 10

-- Seconds a hit makes health's trend fall, and a mana change makes mana's rise or fall.
StatusLayout.HURT_TREND = 2
StatusLayout.MANA_TREND = 1

--[[ Layout ]]

-- Badge rows `badges` badges take (0 for none).
function StatusLayout.badgeRows(badges: number): number
	return math.ceil(math.clamp(badges, 0, StatusLayout.MAX_BADGES) / StatusLayout.BADGES_PER_ROW)
end

--[[
	Where a variant's parts sit (GUI pixels from its top): the notifier block's top, the value row's
	top (nil: no values) and the knowledge row's top (nil: none). `values`: Config.Ui.StatusValues;
	`badges`: the badges shown; `knowledge`: the knowledge row has something to show (default true).
]]
function StatusLayout.blocks(
	variant: Variant,
	values: boolean,
	badges: number,
	knowledge: boolean?
): (number, number?, number?)
	if variant == "dock" then
		return 0, nil, nil
	end
	local top = StatusLayout.BADGE_ROW_H * StatusLayout.badgeRows(badges)
	local bottom = top + StatusLayout.NOTIFIERS_H
	if variant == "lean" then
		return top, nil, nil
	end
	local valueY: number? = nil
	if values then
		valueY = bottom
		bottom += StatusLayout.VALUE_H
	end
	return top, valueY, if knowledge == false then nil else bottom
end

-- A variant's size (GUI pixels; see `blocks`).
function StatusLayout.size(variant: Variant, values: boolean, badges: number, knowledge: boolean?): (number, number)
	local top, valueY, xpY = StatusLayout.blocks(variant, values, badges, knowledge)
	local bottom = top + StatusLayout.NOTIFIERS_H
	if valueY then
		bottom = valueY + StatusLayout.VALUE_H
	end
	if xpY then
		bottom = xpY + StatusLayout.XP_H
	end
	return StatusLayout.WIDTH, bottom
end

--[[
	The x of each present notifier's column (right-aligned in the block starting at `x0`), written
	into `out` (reused; absent notifiers are removed from it). Returns the divider bar's x, nil
	unless both groups are present.
]]
function StatusLayout.columns(present: { [Notifier]: boolean }, x0: number, out: { [Notifier]: number }): number?
	local x = x0 + StatusLayout.NOTIFIERS_W
	local group = 0
	local divider: number? = nil
	local seen = false
	for i = #StatusLayout.ORDER, 1, -1 do
		local name = StatusLayout.ORDER[i]
		if present[name] then
			local g = StatusLayout.GROUP[name]
			if seen and g ~= group then
				-- (The divider's slot between the groups, the bar in its middle.)
				x -= StatusLayout.DIVIDER
				divider = x + (StatusLayout.DIVIDER - StatusLayout.DIVIDER_BAR.w) // 2
			elseif seen then
				x -= StatusLayout.PITCH - StatusLayout.COLUMN
			end
			x -= StatusLayout.COLUMN
			out[name] = x
			group = g
			seen = true
		else
			out[name] = nil
		end
	end
	return divider
end

--[[
	Badge `i`'s top left (1 = highest priority), relative to the notifier block's top left: rows of
	BADGES_PER_ROW above the block, right-aligned, the first at the right of the lowest row.
]]
function StatusLayout.badgeAt(i: number): (number, number)
	local column = (i - 1) % StatusLayout.BADGES_PER_ROW
	local row = (i - 1) // StatusLayout.BADGES_PER_ROW
	local x = StatusLayout.NOTIFIERS_W - StatusLayout.BADGE - column * StatusLayout.BADGE_PITCH
	return x, 1 - StatusLayout.BADGE_ROW_H * (row + 1)
end

--[[
	Chevron `i` (1 = nearest the glyph) of a rising (`direction` > 0) or falling trend: its top
	left in the column.
]]
function StatusLayout.chevronAt(direction: number, i: number): (number, number)
	local c = StatusLayout.CHEVRON
	local x = (StatusLayout.COLUMN - c.w) // 2
	if direction > 0 then
		return x, StatusLayout.ROW.glyph - c.step * i
	end
	return x, StatusLayout.ROW.down + c.step * (i - 1)
end

--[[ Levels and colours ]]

-- Half hearts of 20 for `health` out of `max` (the Humanoid's), as Minecraft's hearts counted.
function StatusLayout.halves(health: number, max: number): number
	if max <= 0 or health ~= health then
		return 0
	end
	return math.clamp(math.ceil(health / max * 20 - 1e-6), 0, 20)
end

--[[
	The level (1..5, see the header) of `stat` at `value` of `max`: health as the Humanoid's health
	and maximum, food and thirst in points (max 20), mana as mana and its maximum.
]]
function StatusLayout.level(stat: "health" | "food" | "thirst" | "mana", value: number, max: number): number
	if stat == "health" then
		local halves = StatusLayout.halves(value, max)
		if halves <= 3 then
			return 5
		elseif halves <= 6 then
			return 4
		elseif halves <= 12 then
			return 3
		end
		return if halves < 20 then 2 else 1
	elseif stat == "mana" then
		if max <= 0 then
			return 1
		end
		local share = value / max
		if share < 0.10 then
			return 4
		elseif share < 0.25 then
			return 3
		end
		return if share < 1 then 2 else 1
	end
	if value <= 0 then
		return 5
	elseif value <= 3 then
		return 4
	elseif value <= 6 then
		return 3
	end
	return if value < max then 2 else 1
end

--[[
	The body temperature's level and side: by zone (-2..2: Temperature.zone) neutral 1, warning 3,
	critical 4; blinking (5) while freezing (`frozen` > 0, cold) or overheating (`heat` > 0, hot).
]]
function StatusLayout.temperatureLevel(zone: number, frozen: number, heat: number): (number, Side)
	if frozen > 0 or heat > 0 then
		return 5, if frozen >= heat then "cold" else "hot"
	end
	if zone == 0 then
		return 1, "neutral"
	end
	local side: Side = if zone < 0 then "cold" else "hot"
	return if math.abs(zone) >= 2 then 4 else 3, side
end

-- The Theme.Colour key of a glyph at `level` on `side`, `blinkOn` the blink's bright phase.
function StatusLayout.colour(level: number, side: Side, blinkOn: boolean): string
	local cold = side == "cold"
	if level >= 5 then
		if blinkOn then
			return "Blink"
		end
		return if cold then "ColdCritical" else "Critical"
	elseif level == 4 then
		return if cold then "ColdCritical" else "Critical"
	elseif level == 3 then
		return if cold then "ColdWarn" else "Warn"
	end
	return "Icon"
end

--[[
	The Theme.Colour key of a glyph's emptied part at `level` on `side`: GlyphEmpty (faint grey)
	while fine (levels 1 and 2), else the level's colour as `colour` gives it, blink included
	(Ui/StatusCluster draws it at Theme.GLYPH_ALARM_T), so the alarm shows however little is lit.
]]
function StatusLayout.emptyColour(level: number, side: Side, blinkOn: boolean): string
	if level <= 2 then
		return "GlyphEmpty"
	end
	return StatusLayout.colour(level, side, blinkOn)
end

-- Is the blink in its bright phase at `now` (seconds), blinking every `period`?
function StatusLayout.blinkOn(now: number, period: number): boolean
	return math.floor(now / period) % 2 == 0
end

-- Glyph rows lit (0..GLYPH) for `value` of `max`: none only at nothing, all only when full.
function StatusLayout.fill(value: number, max: number): number
	local rows = StatusLayout.GLYPH
	if max <= 0 or value ~= value or value <= 0 then
		return 0
	elseif value >= max then
		return rows
	end
	return math.clamp(math.floor(value / max * rows + 0.5), 1, rows - 1)
end

--[[
	How the mana star is painted: its rows lit, the lit part's colour key and the emptied part's.
	`shown`: Ui/ManaStars.shown (false: no magic weapon held, full and unchanged for a while);
	`refused`: a cast the server refused just now; `blinkOn`: the blink's bright phase. Not shown
	with a maximum, the star is full and idle: lit through in GlyphIdle (faint), never the empty
	star's look; without a maximum (no mana yet) only the faint empty copy. A refused cast blinks
	the whole star white, lit part and emptied part, so it shows at no mana too.
]]
function StatusLayout.manaPaint(
	shown: boolean,
	mana: number,
	max: number,
	refused: boolean,
	blinkOn: boolean
): (number, string, string)
	if not shown then
		if max > 0 then
			return StatusLayout.GLYPH, "GlyphIdle", "GlyphEmpty"
		end
		return 0, "Icon", "GlyphEmpty"
	end
	local rows = StatusLayout.fill(mana, max)
	if refused and blinkOn then
		return rows, "Blink", "Blink"
	end
	local level = StatusLayout.level("mana", mana, max)
	return rows, StatusLayout.colour(level, "neutral", blinkOn), StatusLayout.emptyColour(level, "neutral", blinkOn)
end

--[[
	The height (GUI pixels, up from the glyph's bottom) of the bright copy's clip for `rows` lit
	(`fill`) on a glyph whose drawing spans `top`..`bottom` (unit coordinates down its square:
	Ui/StatusGlyphs.extent): nothing at 0 rows, the whole glyph at GLYPH, else the empty margin
	under the drawing plus that share of the drawing's height, so the first row lit is a row of
	the drawing, not of the margin under it.
]]
function StatusLayout.litHeight(rows: number, top: number, bottom: number): number
	local glyph = StatusLayout.GLYPH
	if rows <= 0 then
		return 0
	elseif rows >= glyph then
		return glyph
	end
	local low = math.clamp(bottom, 0, 1)
	local high = math.clamp(top, 0, low)
	return ((1 - low) + rows / glyph * (low - high)) * glyph
end

--[[ Trends (chevrons: positive rising, negative falling, 0 none) ]]

--[[
	The body temperature going from `value` towards `target`: one chevron that way; with a
	Thermometer held (`thermometer`), 1 to 3 by the distance (1 for up to 3 steps, 2 up to 7, 3
	beyond).
]]
function StatusLayout.temperatureTrend(value: number, target: number, thermometer: boolean): number
	local distance = target - value
	if distance == 0 or distance ~= distance then
		return 0
	end
	local sign = if distance > 0 then 1 else -1
	if not thermometer then
		return sign
	end
	local far = math.abs(distance)
	return sign * (if far <= 3 then 1 elseif far <= 7 then 2 else 3)
end

--[[
	Health: falling one chevron for each of `drains` (up to 3), else one for a hit lately
	(`lostRecently`), else rising one while `regenerating`.
]]
function StatusLayout.healthTrend(drains: number, regenerating: boolean, lostRecently: boolean): number
	if drains > 0 then
		return -math.min(StatusLayout.MAX_TREND, drains)
	elseif lostRecently then
		return -1
	elseif regenerating then
		return 1
	end
	return 0
end

--[[
	Does health come back now (see the header)? Hunger on: food at Hunger.REGEN_FOOD or more and,
	with thirst on, thirst at Hunger.THIRST_REGEN or more (with Config.Hunger.NaturalRegeneration);
	hunger off and thirst on: Config.ToughAsNails.ThirstRegeneration and thirst at
	Thirst.REGEN_THIRST or more; neither: no. Never at `full` health.
]]
function StatusLayout.regenerating(
	hungerOn: boolean,
	thirstOn: boolean,
	food: number,
	thirst: number,
	full: boolean
): boolean
	if full then
		return false
	elseif hungerOn then
		return Config.Hunger.NaturalRegeneration == true
			and food >= Hunger.REGEN_FOOD
			and (not thirstOn or thirst >= Hunger.THIRST_REGEN)
	elseif thirstOn then
		return Config.ToughAsNails.ThirstRegeneration == true and thirst >= Thirst.REGEN_THIRST
	end
	return false
end

-- Food: two falling under the Hunger effect (`hungry`), one with no saturation left.
function StatusLayout.foodTrend(saturation: number, hungry: boolean): number
	if hungry then
		return -2
	end
	return if saturation <= 0 then -1 else 0
end

-- Thirst: two falling under the Thirst effect (`sick`), one with no hydration left.
function StatusLayout.thirstTrend(hydration: number, sick: boolean): number
	if sick then
		return -2
	end
	return if hydration <= 0 then -1 else 0
end

-- Mana: the way its last change went (`delta`), for MANA_TREND seconds after it (`since`).
function StatusLayout.manaTrend(delta: number, since: number): number
	if delta == 0 or since >= StatusLayout.MANA_TREND then
		return 0
	end
	return if delta > 0 then 1 else -1
end

--[[ Text ]]

-- The number under a notifier (Config.Ui.StatusValues): temperature signed ("-3", "0", "+5").
function StatusLayout.valueText(stat: Notifier, value: number): string
	local whole = math.round(value)
	if stat == "temperature" and whole ~= 0 then
		return string.format("%+d", whole)
	end
	return tostring(whole)
end

--[[
	A badge's number: its level (amplifier + 1) from II, an Infection's stage always (amplifier + 1),
	Climate Clemency's whole minutes left of `ticks` (rounded up); "" for none.
]]
function StatusLayout.badgeText(name: string, amplifier: number, ticks: number): string
	if name == "ClimateClemency" then
		return if ticks > 0 then tostring(math.ceil(ticks / (20 * 60))) else ""
	elseif name == "Infection" then
		return tostring(amplifier + 1)
	end
	return if amplifier >= 1 then tostring(amplifier + 1) else ""
end

return StatusLayout
