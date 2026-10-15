--[[
	The status icons (client Ui/StatusLayout, Ui/StatusGlyphs): the notifier columns for every
	combination of features on (right-aligned in the block, 2 apart in a group, the divider only
	between two groups and centred in its slot, nothing outside the block, in ORDER), the badges'
	places (rows of five above the notifiers, inside the width, never on the notifiers or on each
	other), the variants' sizes, the levels' thresholds (health in half hearts of 20 whatever the
	Humanoid's maximum, food, thirst, mana, temperature by zone with freezing and overheating), the
	colours by level and side, the glyph's fill (empty only at nothing, full only when full, never
	going down as the stat goes up, spread over the drawing's own height so any non-zero stat
	lights some of it), the emptied part's colour (the level's from level 3, blinking at 5, so
	the alarm shows at 0 where nothing is lit), full idle mana apart from an empty star, the trends, the regeneration rule with hunger on and off, the
	value and badge texts, and every silhouette: drawn, non-empty, alphas in 0..1, the drop and the
	thermometer symmetric, every badge an effect that exists.
]]

return function(t, shared, require, _server, client)
	local StatusLayout = require(client.Ui.StatusLayout)
	local StatusGlyphs = require(client.Ui.StatusGlyphs)
	local Effects = require(shared.Effects)
	local Hunger = require(shared.Hunger)
	local Thirst = require(shared.ToughAsNails.Thirst)

	local ORDER = StatusLayout.ORDER
	local COLUMN, W = StatusLayout.COLUMN, StatusLayout.NOTIFIERS_W

	t.test("status layout: the notifier columns for every combination of features", function()
		local out = {}
		local checked = 0
		for mask = 0, 63 do
			local present = {}
			for i, name in ORDER do
				present[name] = bit32.btest(mask, bit32.lshift(1, i - 1))
			end
			-- (A stale entry must go: `out` is reused.)
			out.thirst = -99
			local divider = StatusLayout.columns(present, 10, out)
			local where = `mask {mask}`
			local previous: string? = nil
			local groups: { [number]: boolean } = {}
			for _, name in ORDER do
				local x = out[name]
				if not present[name] then
					t.eq(x, nil, `{where}: {name} absent`)
					continue
				end
				t.ok(x ~= nil, `{where}: {name} placed`)
				t.ok(x >= 10 and x + COLUMN <= 10 + W, `{where}: {name} inside the block`)
				groups[StatusLayout.GROUP[name]] = true
				if previous then
					local px = out[previous] :: number
					t.ok(px < x, `{where}: {previous} left of {name}`)
					if StatusLayout.GROUP[previous] == StatusLayout.GROUP[name] then
						t.eq(x - (px + COLUMN), 2, `{where}: {previous} and {name} 2 apart`)
					else
						t.eq(x - (px + COLUMN), StatusLayout.DIVIDER, `{where}: the divider's slot`)
						t.ok(divider ~= nil, `{where}: a divider between the groups`)
						if divider then
							t.eq(divider, px + COLUMN + 3, `{where}: the divider centred in its slot`)
						end
					end
				end
				previous = name
			end
			if not (groups[1] and groups[2]) then
				t.eq(divider, nil, `{where}: no divider with one group`)
			end
			if previous then
				t.eq((out[previous] :: number) + COLUMN, 10 + W, `{where}: right-aligned`)
			end
			checked += 1
		end
		t.eq(checked, 64)
		-- Everything on: Ui/StatusLayout's header numbers.
		local all = {}
		for _, name in ORDER do
			all[name] = true
		end
		local divider = StatusLayout.columns(all, 0, out)
		t.eq(out.thirst, 0)
		t.eq(out.food, 15)
		t.eq(out.temperature, 30)
		t.eq(divider, 46)
		t.eq(out.mana, 50)
		t.eq(out.armor, 65)
		t.eq(out.health, 80)
	end)

	t.test("status layout: badges in rows of five above the notifiers", function()
		t.ok(#StatusLayout.BADGES + #StatusLayout.STATUS_BADGES <= StatusLayout.MAX_BADGES, "every badge has a place")
		local size = StatusLayout.BADGE
		local places = {}
		for i = 1, StatusLayout.MAX_BADGES do
			local x, y = StatusLayout.badgeAt(i)
			t.ok(x >= 0 and x + size <= StatusLayout.WIDTH, `badge {i} inside the width`)
			t.ok(y + size <= 0, `badge {i} above the notifier block`)
			local row = (i - 1) // StatusLayout.BADGES_PER_ROW
			local first = select(2, StatusLayout.badgeAt(row * StatusLayout.BADGES_PER_ROW + 1))
			t.eq(y, first, `badge {i} on its row`)
			for j, other in places do
				local overlap = x < other[1] + size
					and other[1] < x + size
					and y < other[2] + size
					and other[2] < y + size
				t.ok(not overlap, `badges {j} and {i} apart`)
			end
			table.insert(places, { x, y })
		end
		local x1, y1 = StatusLayout.badgeAt(1)
		t.eq(x1 + size, StatusLayout.WIDTH, "the first at the right end")
		local _, y6 = StatusLayout.badgeAt(6)
		t.eq(y1 - y6, StatusLayout.BADGE_ROW_H, "the sixth starts the row above")
		t.eq(StatusLayout.badgeRows(0), 0)
		t.eq(StatusLayout.badgeRows(5), 1)
		t.eq(StatusLayout.badgeRows(6), 2)
		t.eq(StatusLayout.badgeRows(10), 2)
		t.eq(StatusLayout.badgeRows(30), 2, "never more than MAX_BADGES")
	end)

	t.test("status layout: the variants' sizes and parts", function()
		local function size(variant, values, badges, knowledge)
			return { StatusLayout.size(variant, values, badges, knowledge) }
		end
		t.eq(size("dock", true, 10)[1], 93)
		t.eq(size("dock", true, 10)[2], 23, "the dock: notifiers only")
		t.eq(size("lean", false, 0)[2], 23)
		t.eq(size("lean", true, 0)[2], 23, "no values in the lean variant")
		t.eq(size("lean", false, 5)[2], 35)
		t.eq(size("lean", false, 10)[2], 47)
		t.eq(size("full", false, 0)[2], 31, "with the knowledge row")
		t.eq(size("full", true, 0)[2], 38, "and the values")
		t.eq(size("full", true, 10)[2], 62)
		t.eq(size("full", false, 0, false)[2], 23, "no knowledge to show")
		for _, variant in { "full", "lean", "dock" } do
			for _, badges in { 0, 5, 10 } do
				t.eq(size(variant, true, badges)[1], StatusLayout.WIDTH, `{variant} {badges}: one width`)
			end
		end
		local top, valueY, xpY = StatusLayout.blocks("full", true, 7)
		t.eq(top, 24, "two badge rows above the notifiers")
		t.eq(valueY, 24 + 23)
		t.eq(xpY, 24 + 23 + 7)
		local dockTop, dockValue, dockXp = StatusLayout.blocks("dock", true, 7)
		t.ok(dockTop == 0 and dockValue == nil and dockXp == nil, "the dock: no badges, values or knowledge")
		-- The knowledge row's parts fit it and the width.
		local bar = StatusLayout.XP_BAR
		t.ok(bar.x >= StatusLayout.LEVEL.x + StatusLayout.LEVEL.w, "the bar right of the level")
		t.ok(bar.x + bar.w <= StatusLayout.WIDTH and bar.y + bar.h <= StatusLayout.XP_H, "the bar inside")
	end)

	t.test("status layout: chevrons above the glyph rising, below it falling", function()
		local row = StatusLayout.ROW
		local c = StatusLayout.CHEVRON
		for i = 1, StatusLayout.MAX_TREND do
			local ux, uy = StatusLayout.chevronAt(1, i)
			local dx, dy = StatusLayout.chevronAt(-1, i)
			t.ok(ux >= 0 and ux + c.w <= COLUMN and dx == ux, `chevron {i} centred in the column`)
			t.ok(uy >= row.up and uy + c.h <= row.glyph, `rising chevron {i} above the glyph`)
			t.ok(dy >= row.down and dy + c.h <= StatusLayout.NOTIFIERS_H, `falling chevron {i} below it`)
			if i > 1 then
				local _, py = StatusLayout.chevronAt(1, i - 1)
				t.ok(uy + c.h <= py, `rising chevron {i} over {i - 1}`)
				local _, qy = StatusLayout.chevronAt(-1, i - 1)
				t.ok(dy >= qy + c.h, `falling chevron {i} under {i - 1}`)
			end
		end
		local gx = (COLUMN - StatusLayout.GLYPH) // 2
		t.ok(gx >= 0 and row.glyph + StatusLayout.GLYPH == row.down, "the glyph between the chevrons")
	end)

	t.test("status layout: levels, sides and colours", function()
		local L = StatusLayout.level
		-- Health in half hearts of 20, whatever the Humanoid's maximum.
		local healthCases =
			{ { 20, 1 }, { 19, 2 }, { 13, 2 }, { 12, 3 }, { 7, 3 }, { 6, 4 }, { 4, 4 }, { 3, 5 }, { 1, 5 }, { 0, 5 } }
		for _, case in healthCases do
			t.eq(L("health", case[1], 20), case[2], `health {case[1]} of 20`)
			t.eq(L("health", case[1] * 2, 40), case[2], `health {case[1] * 2} of 40`)
		end
		t.eq(L("health", 20, 40), 3, "half of 40: 10 halves")
		t.eq(StatusLayout.halves(20, 40), 10)
		t.eq(StatusLayout.halves(0.1, 20), 1, "a sliver is a half heart")
		t.eq(StatusLayout.halves(5, 0), 0, "no maximum")
		for _, stat in { "food", "thirst" } do
			for _, case in { { 20, 1 }, { 19, 2 }, { 7, 2 }, { 6, 3 }, { 4, 3 }, { 3, 4 }, { 1, 4 }, { 0, 5 } } do
				t.eq(L(stat, case[1], 20), case[2], `{stat} {case[1]}`)
			end
		end
		for _, case in { { 200, 1 }, { 199, 2 }, { 50, 2 }, { 49, 3 }, { 20, 3 }, { 19, 4 }, { 0, 4 } } do
			t.eq(L("mana", case[1], 200), case[2], `mana {case[1]} of 200`)
		end
		t.eq(L("mana", 0, 0), 1, "no mana yet")
		-- Temperature by zone; freezing and overheating blink.
		local T = StatusLayout.temperatureLevel
		local function both(zone, frozen, heat)
			local level, side = T(zone, frozen, heat)
			return `{level} {side}`
		end
		t.eq(both(0, 0, 0), "1 neutral")
		t.eq(both(-1, 0, 0), "3 cold")
		t.eq(both(1, 0, 0), "3 hot")
		t.eq(both(-2, 0, 0), "4 cold")
		t.eq(both(2, 0, 0), "4 hot")
		t.eq(both(-2, 30, 0), "5 cold")
		t.eq(both(2, 0, 30), "5 hot")
		t.eq(both(0, 10, 0), "5 cold", "freezing whatever the zone")
		-- Colours.
		local C = StatusLayout.colour
		t.eq(C(1, "neutral", true), "Icon")
		t.eq(C(2, "hot", false), "Icon")
		t.eq(C(3, "hot", true), "Warn")
		t.eq(C(3, "cold", true), "ColdWarn")
		t.eq(C(4, "neutral", true), "Critical")
		t.eq(C(4, "cold", true), "ColdCritical")
		t.eq(C(5, "neutral", true), "Blink")
		t.eq(C(5, "neutral", false), "Critical")
		t.eq(C(5, "cold", false), "ColdCritical")
		t.ok(StatusLayout.blinkOn(0.1, 0.25) and not StatusLayout.blinkOn(0.3, 0.25), "the blink's phases")
	end)

	t.test("status layout: a glyph's fill", function()
		local rows = StatusLayout.GLYPH
		for _, max in { 20, 400 } do
			local last = -1
			for value = 0, max do
				local fill = StatusLayout.fill(value, max)
				t.ok(fill >= last, `max {max}: {value} never fills less than {value - 1}`)
				if value == 0 then
					t.eq(fill, 0, `max {max}: empty at nothing`)
				elseif value == max then
					t.eq(fill, rows, `max {max}: full when full`)
				else
					t.ok(fill >= 1 and fill <= rows - 1, `max {max}: {value} neither empty nor full`)
				end
				last = fill
			end
		end
		t.eq(StatusLayout.fill(5, 0), 0, "no maximum")
		t.eq(StatusLayout.fill(30, 20), rows, "armor past 20")
	end)

	-- The share of a notifier's drawing (its alpha) inside the bright copy's clip, `height` GUI
	-- pixels up from the glyph's bottom (as the clip shows it).
	local function litShare(mask, height: number): number
		local total, inside = 0, 0
		local cut = mask.h * (1 - height / StatusLayout.GLYPH)
		for y = 0, mask.h - 1 do
			local below = math.clamp((y + 1) - cut, 0, 1)
			for x = 0, mask.w - 1 do
				local a = mask.alpha[y * mask.w + x + 1]
				total += a
				inside += a * below
			end
		end
		return if total > 0 then inside / total else 0
	end

	t.test("status layout: the rows lit spread over the drawing, not its margins", function()
		local G = StatusLayout.GLYPH
		for _, name in ORDER do
			local top, bottom = StatusGlyphs.extent(name)
			t.ok(top >= 0 and top < bottom and bottom <= 1, `{name}: its drawing's span {top}..{bottom}`)
			t.eq(StatusLayout.litHeight(0, top, bottom), 0, `{name}: nothing lit at 0 rows`)
			t.eq(StatusLayout.litHeight(G, top, bottom), G, `{name}: all of it when full`)
			local last = 0
			for rows = 1, G - 1 do
				local height = StatusLayout.litHeight(rows, top, bottom)
				t.ok(height > last and height < G, `{name}: {rows} rows lit more than {rows - 1}`)
				last = height
			end
			-- (The first row lit is a row of the drawing, above the empty margin under it.)
			local margin = (1 - bottom) * G
			t.ok(StatusLayout.litHeight(1, top, bottom) >= margin + (bottom - top) - 1e-9, `{name}: one row of it`)
		end
		local top, bottom = StatusGlyphs.extent("food")
		t.ok(math.abs(top - 0.02) < 1e-9 and math.abs(bottom - 0.88) < 1e-9, "the stomach's span: tube to sack")
		t.eq(select(2, StatusGlyphs.extent("nothing")), 1, "an unknown drawing: the whole square")
	end)

	t.test("status layout: the alarm shows however little of a glyph is lit", function()
		local Temperature = require(shared.ToughAsNails.Temperature)
		-- Each stat's values: level, side, and the rows lit, as Ui/StatusCluster works them out.
		local function each(name: string, visit: (value: number, level: number, side: string, rows: number) -> ())
			if name == "temperature" then
				for value = Temperature.MIN, Temperature.MAX do
					local level, side = StatusLayout.temperatureLevel(Temperature.zone(value), 0, 0)
					visit(
						value,
						level,
						side,
						StatusLayout.fill(value - Temperature.MIN, Temperature.MAX - Temperature.MIN)
					)
				end
				return
			end
			for value = 0, 20 do
				local level = StatusLayout.level(name :: any, value, 20)
				visit(value, level, "neutral", StatusLayout.fill(value, 20))
			end
		end
		local checked = 0
		for _, name in { "food", "thirst", "health", "temperature", "mana" } do
			local mask = StatusGlyphs.render(name)
			local top, bottom = StatusGlyphs.extent(name)
			local lastShare = -1
			each(name, function(value, level, side, rows)
				local share = litShare(mask, StatusLayout.litHeight(rows, top, bottom))
				local where = `{name} {value} (level {level}, {math.floor(share * 100 + 0.5)}% lit)`
				t.ok(share >= lastShare - 1e-9, `{where}: never less lit than the value under it`)
				lastShare = share
				if rows > 0 then
					t.ok(share > 0.005, `{where}: something of the drawing lit`)
				else
					t.eq(share, 0, `{where}: nothing lit`)
				end
				for _, blinkOn in { true, false } do
					local empty = StatusLayout.emptyColour(level, side, blinkOn)
					if level >= 3 then
						-- (Lit or not, the whole silhouette carries the level's colour.)
						t.eq(empty, StatusLayout.colour(level, side, blinkOn), `{where}: the emptied part's colour`)
						t.ok(empty ~= "GlyphEmpty" and empty ~= "Icon", `{where}: the emptied part warns`)
					else
						t.eq(empty, "GlyphEmpty", `{where}: faint while fine`)
					end
				end
				if level >= 5 then
					t.ok(
						StatusLayout.emptyColour(level, side, true) ~= StatusLayout.emptyColour(level, side, false),
						`{where}: the emptied part blinks`
					)
				end
				-- (What the review found: at 0 to 3 points of food or thirst nothing red showed.)
				if (name == "food" or name == "thirst") and value >= 1 and value <= 3 then
					t.ok(share >= 0.05, `{where}: a visible share lit`)
				end
				checked += 1
			end)
		end
		t.eq(checked, 5 * 21)
		-- Starving and dehydrated: blinking red, the whole stomach and drop.
		t.eq(StatusLayout.emptyColour(StatusLayout.level("food", 0, 20), "neutral", false), "Critical")
		t.eq(StatusLayout.emptyColour(StatusLayout.level("thirst", 0, 20), "neutral", true), "Blink")
		-- Freezing: blinking blue whatever the fill.
		local level, side = StatusLayout.temperatureLevel(-2, 10, 0)
		t.eq(StatusLayout.emptyColour(level, side, false), "ColdCritical")
		t.eq(StatusLayout.emptyColour(StatusLayout.level("mana", 0, 200), "neutral", true), "Critical", "no mana")
	end)

	t.test("status layout: full idle mana never looks like an empty star", function()
		local M = StatusLayout.manaPaint
		local G = StatusLayout.GLYPH
		for _, blinkOn in { true, false } do
			local idleRows, idleLit, idleEmpty = M(false, 200, 200, false, blinkOn)
			local emptyRows, emptyLit, emptyEmpty = M(true, 0, 200, false, blinkOn)
			t.eq(idleRows, G, "idle: lit through")
			t.eq(idleLit, "GlyphIdle", "idle: faint")
			t.eq(idleEmpty, "GlyphEmpty")
			t.eq(emptyRows, 0, "no mana: nothing lit")
			t.eq(emptyEmpty, "Critical", "no mana: the whole star red")
			t.ok(
				`{idleRows} {idleLit} {idleEmpty}` ~= `{emptyRows} {emptyLit} {emptyEmpty}`,
				"idle full and empty look apart"
			)
			local fullRows, fullLit = M(true, 200, 200, false, blinkOn)
			t.ok(fullRows == G and fullLit == "Icon", "full with a magic weapon: bright")
		end
		-- A refused cast blinks the whole star, at no mana too.
		local rows, lit, empty = M(true, 0, 200, true, true)
		t.ok(rows == 0 and lit == "Blink" and empty == "Blink", "refused at no mana: the emptied part blinks")
		local _, offLit, offEmpty = M(true, 0, 200, true, false)
		t.ok(offLit == "Critical" and offEmpty == "Critical", "refused, the dark phase: red")
		t.eq(M(false, 0, 0, false, true), 0, "no mana yet: nothing lit")
		t.eq(select(3, M(true, 30, 200, false, true)), "Warn", "low mana: the emptied part warns")
		t.eq(select(3, M(true, 120, 200, false, true)), "GlyphEmpty", "fine: faint")
	end)

	t.test("status layout: trends", function()
		local TT = StatusLayout.temperatureTrend
		t.eq(TT(2, 2, true), 0, "on target")
		t.eq(TT(0, 5, false), 1, "warming: one chevron without a Thermometer")
		t.eq(TT(0, -9, false), -1)
		t.eq(TT(0, 3, true), 1, "a Thermometer: by the distance")
		t.eq(TT(0, 5, true), 2)
		t.eq(TT(0, -9, true), -3)
		local HT = StatusLayout.healthTrend
		t.eq(HT(2, true, true), -2, "drains first")
		t.eq(HT(5, false, false), -3, "at most three")
		t.eq(HT(0, true, true), -1, "a recent hit")
		t.eq(HT(0, true, false), 1, "regenerating")
		t.eq(HT(0, false, false), 0)
		t.eq(StatusLayout.foodTrend(3, true), -2, "the Hunger effect")
		t.eq(StatusLayout.foodTrend(0, false), -1, "no saturation")
		t.eq(StatusLayout.foodTrend(3, false), 0)
		t.eq(StatusLayout.thirstTrend(3, true), -2, "the Thirst effect")
		t.eq(StatusLayout.thirstTrend(0, false), -1, "no hydration")
		t.eq(StatusLayout.thirstTrend(3, false), 0)
		t.eq(StatusLayout.manaTrend(5, 0.2), 1)
		t.eq(StatusLayout.manaTrend(-5, 0.2), -1)
		t.eq(StatusLayout.manaTrend(-5, 2), 0, "long ago")
		t.eq(StatusLayout.manaTrend(0, 0), 0)
	end)

	t.test("status layout: when health comes back", function()
		local R = StatusLayout.regenerating
		t.eq(Hunger.REGEN_FOOD, 18)
		t.eq(Hunger.THIRST_REGEN, 18)
		t.eq(Thirst.REGEN_THIRST, 18)
		-- Hunger on (thirst on and off).
		t.ok(R(true, true, 18, 18, false), "fed and watered")
		t.ok(not R(true, true, 17, 18, false), "food 17")
		t.ok(not R(true, true, 18, 17, false), "thirst 17")
		t.ok(R(true, false, 18, 0, false), "thirst off: food alone")
		t.ok(not R(true, false, 17, 20, false), "thirst off, food 17")
		-- Hunger off, thirst on: thirst's own regeneration (Config.ToughAsNails.ThirstRegeneration).
		t.ok(R(false, true, 0, 18, false), "thirst 18")
		t.ok(not R(false, true, 20, 17, false), "thirst 17")
		-- Neither, or full health.
		t.ok(not R(false, false, 20, 20, false), "neither bar")
		t.ok(not R(true, true, 20, 20, true), "full health")
	end)

	t.test("status layout: value and badge texts", function()
		t.eq(StatusLayout.valueText("temperature", 5), "+5")
		t.eq(StatusLayout.valueText("temperature", -3), "-3")
		t.eq(StatusLayout.valueText("temperature", 0.2), "0")
		t.eq(StatusLayout.valueText("health", 19.6), "20")
		t.eq(StatusLayout.valueText("mana", 140), "140")
		t.eq(StatusLayout.badgeText("Bleeding", 0, 100), "", "level I: no number")
		t.eq(StatusLayout.badgeText("Bleeding", 1, 100), "2")
		t.eq(StatusLayout.badgeText("Infection", 0, 0), "1", "an Infection's stage always")
		t.eq(StatusLayout.badgeText("Infection", 2, 0), "3")
		t.eq(StatusLayout.badgeText("ClimateClemency", 0, 1), "1", "minutes left, rounded up")
		t.eq(StatusLayout.badgeText("ClimateClemency", 0, 2400), "2")
		t.eq(StatusLayout.badgeText("ClimateClemency", 0, 2401), "3")
		t.eq(StatusLayout.badgeText("ClimateClemency", 0, 0), "")
	end)

	t.test("status glyphs: every silhouette drawn, the drop and the thermometer symmetric", function()
		local function check(name: string)
			local mask = StatusGlyphs.render(name)
			local chevron = name == "chevronUp" or name == "chevronDown"
			t.eq(mask.w, if chevron then StatusGlyphs.CHEVRON_W else StatusGlyphs.SIZE, `{name}: width`)
			t.eq(mask.h, if chevron then StatusGlyphs.CHEVRON_H else StatusGlyphs.SIZE, `{name}: height`)
			t.eq(#mask.alpha, mask.w * mask.h, `{name}: every pixel`)
			local sum, inRange = 0, true
			for _, a in mask.alpha do
				sum += a
				inRange = inRange and a >= 0 and a <= 1
			end
			t.ok(inRange, `{name}: alphas in 0..1`)
			t.ok(sum > mask.w * mask.h * 0.1, `{name}: drawn ({math.floor(sum)})`)
			t.ok(sum < mask.w * mask.h * 0.95, `{name}: not a block`)
			return mask
		end
		for _, name in ORDER do
			t.ok(StatusGlyphs.NOTIFIERS[name] ~= nil, `notifier {name} has a drawing`)
			check(name)
		end
		for _, list in { StatusLayout.BADGES, StatusLayout.STATUS_BADGES } do
			for _, name in list do
				t.ok(Effects.id[name] ~= nil, `badge {name} is an effect`)
				t.ok(StatusGlyphs.BADGES[name] ~= nil, `badge {name} has a drawing`)
				check(name)
			end
		end
		check("chevronUp")
		check("chevronDown")
		t.eq(StatusGlyphs.ops("nothing"), nil, "unknown names have no drawing")
		for _, name in { "thirst", "temperature" } do
			local mask = StatusGlyphs.render(name)
			local worst = 0
			for y = 0, mask.h - 1 do
				for x = 0, mask.w - 1 do
					local a = mask.alpha[y * mask.w + x + 1]
					local b = mask.alpha[y * mask.w + (mask.w - 1 - x) + 1]
					worst = math.max(worst, math.abs(a - b))
				end
			end
			t.ok(worst <= 1 / 16 + 1e-9, `{name}: symmetric about the vertical axis ({worst})`)
		end
		-- The rising chevron is the falling one upside down.
		local up, down = StatusGlyphs.render("chevronUp"), StatusGlyphs.render("chevronDown")
		local worst = 0
		for y = 0, up.h - 1 do
			for x = 0, up.w - 1 do
				worst =
					math.max(worst, math.abs(up.alpha[y * up.w + x + 1] - down.alpha[(up.h - 1 - y) * up.w + x + 1]))
			end
		end
		t.ok(worst <= 1 / 16 + 1e-9, `the chevrons mirror each other ({worst})`)
	end)
end
