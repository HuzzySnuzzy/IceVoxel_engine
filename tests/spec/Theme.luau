--[[
	The inventory family's look in numbers (client Ui/Theme): every colour a 0..255 colour with a
	transparency in 0..1, text sizes and fonts that exist, the five condition levels from Pristine
	to Ruined (no tint, sips have none), the drag feedback rules, capitals and section titles, the
	slot face states, the text weight rule (Light only from 14 screen pixels), count boxes by scale,
	stroke thicknesses, quickbar number boxes, tooltip colour names, the liquid pill, the held
	item's texts, and Ui/MenuLayout.wear (durability left, and canteens' sips told apart); the
	headers' gradients averaging their tokens, the Light rule for any text size, the scrollbar's
	thumb, and the item tooltip's layout (`tip`: header rows, dot, picture, pill, wrapped lines,
	gaps, widths between MIN_W and MAX_W, room kept for the count so the box keeps its width as
	the count changes, a plain tooltip; every text inside its part of the box, and real items'
	lines through it).
]]

-- Roblox's built-in font families the look may name.
local FONTS = {
	Roboto = true,
	RobotoCondensed = true,
	RobotoMono = true,
	GothamSSm = true,
	BuilderSans = true,
	Oswald = true,
	SourceSansPro = true,
}

return function(t, shared, require, _server, client)
	local Theme = require(client.Ui.Theme)
	local MenuLayout = require(client.Ui.MenuLayout)
	local Items = require(shared.Items)
	local I = Items.id

	local function isRgba(colour: any): boolean
		if type(colour) ~= "table" then
			return false
		end
		for _, key in { "r", "g", "b" } do
			local v = colour[key]
			if type(v) ~= "number" or v < 0 or v > 255 or v ~= math.floor(v) then
				return false
			end
		end
		return type(colour.t) == "number" and colour.t >= 0 and colour.t <= 1
	end

	t.test("theme: every colour is 0..255 with a transparency in 0..1", function()
		local count = 0
		for key, colour in Theme.Colour do
			t.ok(isRgba(colour), `Colour.{key}`)
			count += 1
		end
		t.ok(count >= 60, `{count} colours`)
		for zone = -2, 2 do
			t.ok(isRgba(Theme.Zone[zone]), `Zone[{zone}]`)
		end
		for name, colour in Theme.FeedbackColour do
			t.ok(isRgba(colour), `FeedbackColour.{name}`)
			t.eq(colour.t, Theme.FEEDBACK_T, `{name} at FEEDBACK_T`)
		end
		for _, name in { "fits", "blocked", "swap", "combine", "drop" } do
			t.ok(Theme.FeedbackColour[name] ~= nil, `feedback {name} has a colour`)
		end
		-- The values the builders were drawn from.
		t.eq(Theme.Colour.Cell.t, 1, "an empty face has no fill")
		t.eq(Theme.Colour.CellFilled.t, 0.96)
		t.eq(Theme.Colour.SectionBody.t, 0.29)
		t.eq(Theme.Colour.ItemTint.r, 179)
	end)

	t.test("theme: text sizes, fonts and sizes", function()
		for role, size in Theme.Text do
			t.ok(size >= 6, `{role} text at least 6`)
		end
		for _, role in { "top", "section", "body", "small", "tiny" } do
			t.ok(Theme.Text[role] ~= nil, `a {role} size`)
		end
		for key, family in Theme.Font do
			t.ok(FONTS[family] == true, `Font.{key} = {family} is built in`)
		end
		t.eq(Theme.Size.PITCH, 18, "slot pitch stays MenuLayout's")
		t.eq(Theme.Size.CELL + Theme.Size.LINE, Theme.Size.PITCH)
		t.eq(Theme.Size.OUTLINE_PX, 2)
		local bar = Theme.Size.BAR
		t.ok(bar.x >= 0 and bar.y >= 0 and bar.x + bar.w <= 16 and bar.y + bar.h <= 16, "the bar inside the item")
	end)

	t.test("theme: condition levels from Pristine to Ruined, no tint, none for sips", function()
		local cases = {
			{ 1.0, "Pristine" },
			{ 0.81, "Pristine" },
			{ 0.8, "Worn" },
			{ 0.61, "Worn" },
			{ 0.6, "Damaged" },
			{ 0.41, "Damaged" },
			{ 0.4, "Badly damaged" },
			{ 0.21, "Badly damaged" },
			{ 0.2, "Ruined" },
			{ 0, "Ruined" },
		}
		for _, case in cases do
			local level = Theme.condition(case[1])
			t.eq(level and level.name, case[2], `{case[1]}`)
		end
		t.eq(Theme.condition(nil), nil, "no durability")
		t.eq(Theme.condition(0.5, true), nil, "sips are a quantity")
		t.eq(Theme.condition(0 / 0), nil, "NaN")
		local seen = {}
		local previous = math.huge
		for i, level in Theme.CONDITIONS do
			t.ok(level.above < previous, `level {i} ordered`)
			previous = level.above
			t.eq(#level.rgb, 3, `{level.name}: rgb`)
			local key = table.concat(level.rgb, ",")
			t.ok(seen[key] == nil, `{level.name}: a colour of its own`)
			seen[key] = true
			t.eq((level :: any).tint, nil, `{level.name}: no cell tint`)
			t.ok(table.isfrozen(level), `{level.name}: frozen`)
		end
		t.eq(#Theme.CONDITIONS, 5)
	end)

	t.test("theme: drag feedback colours only what a click would do", function()
		-- carrying, over, empty, allowed, same, room, result
		t.eq(Theme.feedback(false, "slot", true, true, false, true, false), nil, "nothing carried")
		t.eq(Theme.feedback(true, "none", true, true, false, true, false), nil, "over nothing")
		t.eq(Theme.feedback(true, "drop", false, false, false, false, false), "drop", "the drop strip")
		t.eq(Theme.feedback(true, "slot", false, false, true, true, true), "combine", "a result taking more")
		t.eq(Theme.feedback(true, "slot", false, false, true, false, true), "blocked", "a result with no room")
		t.eq(Theme.feedback(true, "slot", false, false, false, true, true), "blocked", "another result")
		t.eq(Theme.feedback(true, "slot", true, false, false, true, false), "blocked", "not allowed")
		t.eq(Theme.feedback(true, "slot", true, true, false, true, false), "fits", "an empty slot")
		t.eq(Theme.feedback(true, "slot", false, true, true, true, false), "combine", "the same stack, room")
		t.eq(Theme.feedback(true, "slot", false, true, true, false, false), "blocked", "the same stack, full")
		t.eq(Theme.feedback(true, "slot", false, true, false, true, false), "swap", "another stack")
	end)

	t.test("theme: capitals and section titles", function()
		t.eq(Theme.caps("Vicinity"), "VICINITY")
		t.eq(Theme.sectionTitle("Backpack", 14, 27), "BACKPACK (14/27)")
		t.eq(Theme.sectionTitle("Crafting"), "CRAFTING")
		t.eq(Theme.sectionTitle("Chest", 0, 27), "CHEST (0/27)")
	end)

	t.test("theme: slot face states", function()
		local function face(state: string): (string, number)
			return Theme.face(state :: any)
		end
		local key, alpha = face("empty")
		t.eq(key, "Cell")
		t.eq(alpha, 1)
		key, alpha = face("filled")
		t.eq(key, "CellFilled")
		t.eq(alpha, 0.96)
		key, alpha = face("selected")
		t.eq(key, "Selected")
		t.eq(alpha, 0.75)
		key, alpha = face("locked")
		t.eq(key, "LockShade")
		t.eq(alpha, 0.40)
		for _, state in { "empty", "filled", "selected", "locked" } do
			local k = face(state)
			t.ok(Theme.Colour[k] ~= nil, `{state}: a colour`)
		end
	end)

	t.test("theme: weights (Light only where it is 14 screen pixels tall)", function()
		t.eq(Theme.weight("top", 1), "Bold")
		t.eq(Theme.weight("top", 4), "Bold")
		t.eq(Theme.weight("body", 1), "Regular")
		t.eq(Theme.weight("body", 4), "Regular")
		t.eq(Theme.weight("section", 2), "Light", "7 x 2 = 14")
		t.eq(Theme.weight("section", 1.5), "Regular", "7 x 1.5 = 10.5")
		t.eq(Theme.weight("small", 2), "Light")
		t.eq(Theme.weight("tiny", 2), "Regular", "6 x 2 = 12")
		t.eq(Theme.weight("tiny", 3), "Light")
	end)

	t.test("theme: count boxes by scale", function()
		local h, size, digit = Theme.count(2.49)
		t.eq(h, 7)
		t.eq(size, 7)
		t.eq(digit, 4)
		h, size, digit = Theme.count(2.5)
		t.eq(h, 6)
		t.eq(size, 6)
		t.eq(digit, 3)
		t.eq(Theme.countWidth("64", 4), 2 * Theme.Size.COUNT_PAD + 8)
		t.eq(Theme.countWidth("7", 3), 2 * Theme.Size.COUNT_PAD + 3)
	end)

	t.test("theme: stroke thickness keeps outlines OUTLINE_PX screen pixels", function()
		t.eq(Theme.strokeThickness(4, true), 0.5)
		t.eq(Theme.strokeThickness(4, false), 2)
		t.eq(Theme.strokeThickness(1, true), 2)
		t.eq(type(Theme.STROKE_FOLLOWS_UISCALE), "boolean")
	end)

	t.test("theme: quickbar number boxes sit inside the 18 x 18 cell", function()
		for _, occupied in { true, false } do
			local x, y, w, h = Theme.quickNumber(occupied)
			t.ok(x >= 0 and y >= 0 and x + w <= 18 and y + h <= 18, `occupied {occupied}: inside`)
		end
		local x, y = Theme.quickNumber(true)
		t.eq(x, 12, "top right over an item")
		t.eq(y, 0)
		local ex, ey = Theme.quickNumber(false)
		t.eq(ex, 6, "centred in an empty cell")
		t.eq(ey, 6)
	end)

	t.test("theme: quickbar numbers show off touch from 8 screen pixels of text", function()
		t.eq(Theme.NUMBER_MIN_PX, 8)
		t.eq(Theme.numbersShown(1, false), false, "6 px at scale 1")
		t.eq(Theme.numbersShown(1.25, false), false, "7.5 px")
		t.eq(Theme.numbersShown(4 / 3, false), true, "8 px")
		t.eq(Theme.numbersShown(4, false), true)
		t.eq(Theme.numbersShown(4, true), false, "never on touch")
		t.ok(#Theme.Words.GROUND_HINT > 0 and #Theme.Words.DROP_HERE > 0, "the fixed words")
	end)

	t.test("theme: tooltip colour names", function()
		t.eq(Theme.tooltipColour("white"), "Text")
		t.eq(Theme.tooltipColour("gray"), "TextMuted")
		t.eq(Theme.tooltipColour("blue"), "TextSoft")
		t.eq(Theme.tooltipColour("darkGreen"), "TextSoft")
		t.eq(Theme.tooltipColour("red"), "Warning")
		t.eq(Theme.tooltipColour("lore"), "TextMuted")
		t.eq(Theme.tooltipColour("purple"), "Text", "unknown names are Text")
		for _, name in { "white", "gray", "blue", "darkGreen", "red", "lore" } do
			t.ok(Theme.Colour[Theme.tooltipColour(name)] ~= nil, `{name}: a colour`)
		end
	end)

	t.test("theme: the liquid pill", function()
		t.eq(Theme.liquid(I.WaterBucket), "Water", "a water bucket: its fluid's name")
		t.eq(Theme.liquid(I.LavaBucket), "Lava")
		t.eq(Theme.liquid(I.DirtyWaterBottle), "Dirty Water")
		t.eq(Theme.liquid(I.DirtyWaterCanteen), "Dirty Water")
		t.eq(Theme.liquid(I.PurifiedWaterCanteen), "Water")
		t.eq(Theme.liquid(I.BottledWater), "Water")
		t.eq(Theme.liquid(I.Stone), nil, "a stone block")
		t.eq(Theme.liquid(I.GlassBottle), nil, "an empty bottle")
		t.eq(Theme.liquid(I.MintTea), nil, "a tea")
		t.eq(Theme.liquid(nil), nil)
	end)

	t.test("theme: the held item's texts", function()
		t.eq(Theme.handsLines(nil), nil, "an empty hand")
		local new = Theme.handsLines({ item = I.IronPickaxe, count = 1 }) :: any
		t.eq(new.name, "Iron Pickaxe")
		t.eq(new.condition and new.condition.name, "Pristine")
		t.eq(new.detail, "Durability 250 / 250")
		local worn = Theme.handsLines({ item = I.IronPickaxe, count = 1, damage = 125 }) :: any
		t.eq(worn.condition and worn.condition.name, "Damaged")
		t.eq(worn.detail, "Durability 125 / 250")
		local canteen = Theme.handsLines({ item = I.PurifiedWaterCanteen, count = 1, damage = 1 }) :: any
		t.eq(canteen.detail, "Sips 2 / 3")
		t.eq(canteen.condition, nil, "sips have no condition")
		local stack = Theme.handsLines({ item = I.Cobblestone, count = 32 }) :: any
		t.eq(stack.detail, "x 32")
		t.eq(stack.condition, nil)
		local one = Theme.handsLines({ item = I.Cobblestone, count = 1 }) :: any
		t.eq(one.detail, nil)
		local battery = Theme.handsLines({ item = I.BasicBattery, count = 1, data = { energy = 1200 } }) :: any
		t.eq(battery.detail, "1.2 kJ")
	end)

	t.test("theme: header gradients average their tokens", function()
		local g = Theme.Gradient
		for _, v in { g.TOP_FROM, g.TOP_TO, g.SECTION_FROM, g.SECTION_TO } do
			t.ok(v >= 0 and v <= 1, `{v} in 0..1`)
		end
		local top = Theme.Colour.TopHeader
		t.eq(top.r, top.g, "a grey")
		t.eq(top.g, top.b)
		t.ok(math.abs(g.TOP_GREY * (g.TOP_FROM + g.TOP_TO) / 2 - top.r) <= 1, "the grey's mean is TopHeader's")
		t.ok(g.TOP_TO < g.TOP_FROM, "darker towards the bottom")
		t.near((g.SECTION_FROM + g.SECTION_TO) / 2, Theme.Colour.SectionHeader.t, 1e-9, "the bar's mean")
		t.ok(g.SECTION_TO > g.SECTION_FROM, "thinner towards the bottom")
	end)

	t.test("theme: Light only from LIGHT_MIN screen pixels, for any text size", function()
		t.eq(Theme.thin(7, 2), "Light")
		t.eq(Theme.thin(7, 1.9), "Regular")
		t.eq(Theme.thin(6, 2.5), "Light", "a count's 6 px digits at 2.5")
		t.eq(Theme.thin(6, 2), "Regular")
		for _, role in { "section", "small", "tiny" } do
			for _, scale in { 1, 1.5, 2, 2.5, 3, 4 } do
				t.eq(Theme.weight(role :: any, scale), Theme.thin(Theme.Text[role], scale), `{role} at {scale}`)
			end
		end
	end)

	t.test("theme: the scrollbar's thumb", function()
		t.ok(Theme.Size.THUMB_H > 0)
		t.ok(Theme.Colour.ThumbActive.t < Theme.Colour.Thumb.t, "brighter while it can scroll")
	end)

	-- A fixed-advance measure: 5 GUI pixels a character at the body size, 4 at the small one.
	local function measure(text: string, size: number): number
		return #text * (size - 3)
	end

	local function inside(text: any, x: number, y: number, w: number, h: number, what: string)
		t.ok(
			text.x >= x and text.y >= y and text.x + text.w <= x + w and text.y + text.h <= y + h,
			`{what}: "{text.text}" inside`
		)
	end

	t.test("theme: the item tooltip's geometry", function()
		local tip = Theme.Tip
		t.eq(tip.TEXT_X, tip.PAD + Theme.Size.TIP_PICTURE + tip.PAD, "the text column right of the picture")
		t.eq(tip.BODY_MIN, Theme.Size.TIP_PICTURE + 2 * tip.PAD, "the picture and its padding")
		t.eq(2 * tip.DOT_Y + Theme.Size.DOT, tip.HEAD, "the dot centred down the header")
		t.ok(tip.NAME_Y + tip.ROW_H <= tip.WORD_Y + 1, "the rows don't overlap much")
		t.ok(tip.WORD_Y + tip.ROW_H <= tip.HEAD, "both rows inside the header")
		t.ok(tip.DOT_X + Theme.Size.DOT < tip.NAME_X, "the name right of the dot")
		t.ok(tip.MIN_W < tip.MAX_W)
	end)

	t.test("theme: an item tooltip: header rows, dot, picture, wrapped lines and gaps", function()
		local tip = Theme.Tip
		local damaged = Theme.condition(0.5)
		local layout = Theme.tip({
			name = "Iron Pickaxe",
			condition = damaged,
			count = nil,
			liquid = nil,
			picture = true,
			lines = {
				{ text = "", colour = "Text" },
				{ text = "Mining speed: 6x", colour = "TextMuted" },
				{ text = "", colour = "Text" },
				{ text = "When in Main Hand:", colour = "TextMuted" },
				{ text = " 5 Attack Damage", colour = "TextSoft" },
				{ text = "Durability: 125 / 250", colour = "TextMuted" },
				{ text = "", colour = "Text" },
			},
		}, measure)
		t.ok(layout.w >= tip.MIN_W and layout.w <= tip.MAX_W, `width {layout.w}`)
		t.eq(layout.head, tip.HEAD)
		t.ok(layout.h >= tip.HEAD + tip.BODY_MIN)
		local dot = layout.dot :: any
		t.ok(dot ~= nil, "a durable item's dot")
		t.eq(dot.x, tip.DOT_X)
		t.eq(dot.y, tip.DOT_Y)
		local picture = layout.picture :: any
		t.eq(picture.x, tip.PAD)
		t.eq(picture.y, tip.HEAD + tip.PAD)
		t.eq(picture.w, Theme.Size.TIP_PICTURE)
		t.ok(picture.y + picture.h + tip.PAD <= layout.h, "the picture inside the body")
		t.eq(layout.pill, nil)
		local texts = layout.texts
		t.eq(texts[1].text, "Iron Pickaxe")
		t.eq(texts[1].x, tip.NAME_X, "the name after the dot")
		t.eq(texts[1].y, tip.NAME_Y)
		t.eq(texts[1].role, "body")
		t.eq(texts[2].text, "Damaged", "the condition word under it")
		t.eq(texts[2].y, tip.WORD_Y)
		t.eq(texts[2].role, "small")
		local rows = {}
		for i, text in texts do
			t.ok(Theme.Colour[text.colour] ~= nil, `{text.text}: a colour`)
			if i <= 2 then
				inside(text, 0, 0, layout.w, layout.head, "header")
			else
				inside(text, tip.TEXT_X, layout.head, layout.w - tip.TEXT_X, layout.h - layout.head, "body")
				t.ok(text.x >= picture.x + picture.w, `{text.text}: right of the picture`)
				table.insert(rows, text)
			end
		end
		t.eq(#rows, 4, "four rows, no empty ones")
		t.eq(rows[1].y, tip.HEAD + tip.PAD, "no gap at the top")
		t.eq(rows[2].y, rows[1].y + Theme.Line.small + tip.BLANK, "a gap where a blank line was")
		t.eq(rows[3].y, rows[2].y + Theme.Line.small, "rows a line apart")
		t.eq(rows[4].y, rows[3].y + Theme.Line.small)
		local bottom = rows[4].y + rows[4].h + tip.PAD
		t.eq(layout.h, math.max(tip.HEAD + tip.BODY_MIN, bottom), "no gap at the bottom")
	end)

	t.test("theme: an item tooltip's count, liquid pill, wrapping and widths", function()
		local tip = Theme.Tip
		-- A stack: no condition (no dot, the name from PAD), its count right-aligned under the name.
		local stack = Theme.tip({ name = "Cobblestone", count = "32 / 64", picture = true, lines = {} }, measure)
		t.eq(stack.dot, nil)
		t.eq(stack.w, tip.MIN_W, "a short tooltip is MIN_W wide")
		t.eq(stack.h, tip.HEAD + tip.BODY_MIN, "and BODY_MIN tall")
		t.eq(stack.texts[1].x, tip.PAD)
		t.eq(stack.texts[1].y, tip.NAME_Y)
		local count = stack.texts[2]
		t.eq(count.text, "32 / 64")
		t.eq(count.align, "right")
		t.eq(count.y, tip.WORD_Y)
		t.eq(count.x + count.w, stack.w - tip.PAD, "against the right edge")
		-- Neither condition nor count: the name centred down the header.
		local plainItem = Theme.tip({ name = "Stick", picture = true, lines = {} }, measure)
		t.eq(#plainItem.texts, 1)
		t.eq(plainItem.texts[1].y, 0)
		t.eq(plainItem.texts[1].h, tip.HEAD)
		-- A water bucket: the pill first in the column, its text centred in it, the lines under it.
		local bucket = Theme.tip({
			name = "Water Bucket",
			liquid = "Water",
			picture = true,
			lines = { { text = "Places water", colour = "TextMuted" } },
		}, measure)
		local pill = bucket.pill :: any
		t.ok(pill ~= nil, "a pill")
		t.eq(pill.x, tip.TEXT_X)
		t.eq(pill.y, tip.HEAD + tip.PAD)
		t.eq(pill.h, tip.PILL_H)
		local pillText = bucket.texts[2]
		t.eq(pillText.text, "Water")
		t.eq(pillText.align, "center")
		inside(pillText, pill.x, pill.y, pill.w, pill.h, "pill")
		t.eq(bucket.texts[3].y, pill.y + tip.PILL_H + tip.PILL_GAP, "the lines under the pill")
		-- Long lore: as wide as allowed, wrapped into the column, every row fitting.
		local words = {}
		for i = 1, 60 do
			words[i] = "word"
		end
		local lore = Theme.tip({
			name = "Old Book",
			picture = true,
			lines = { { text = table.concat(words, " "), colour = "TextMuted" } },
		}, measure)
		t.eq(lore.w, tip.MAX_W, "a long line makes it MAX_W wide")
		local column = lore.w - tip.TEXT_X - tip.PAD
		local rowCount = 0
		for i = 2, #lore.texts do
			local row = lore.texts[i]
			t.ok(measure(row.text, Theme.Text.small) <= column, `row {i} fits the column`)
			rowCount += 1
		end
		t.ok(rowCount >= 3, `wrapped into {rowCount} rows`)
		t.eq(lore.h, lore.texts[#lore.texts].y + Theme.Line.small + tip.PAD, "the body grows with the rows")
		-- A long name: the width stops at MAX_W and the name's text stays inside it.
		local long = Theme.tip({ name = string.rep("Name ", 60), picture = true, lines = {} }, measure)
		t.eq(long.w, tip.MAX_W)
		inside(long.texts[1], 0, 0, long.w, long.head, "header")
	end)

	t.test("theme: an item tooltip keeps room for its count, so a count change keeps the box", function()
		local tip = Theme.Tip
		-- A wide measure (10 GUI pixels a character): the condition word and the count set the width.
		local function wide(text: string, _size: number): number
			return #text * 10
		end
		local pristine = Theme.condition(1)
		local word = (pristine :: any).name
		local function laid(count: string, room: string?): any
			return Theme.tip({
				name = "Ab",
				condition = pristine,
				count = count,
				countRoom = room,
				picture = true,
				lines = {},
			}, wide)
		end
		local few = laid("5 / 64", "88 / 64")
		local full = laid("64 / 64", "88 / 64")
		t.ok(few.w > tip.MIN_W and few.w < tip.MAX_W, `the count sets the width ({few.w})`)
		t.eq(few.w, full.w, "the same width whatever the count")
		t.eq(few.h, full.h)
		t.eq(laid("5 / 64").w, few.w - 10, "without room: the count's own width")
		-- The count's text, found by countAt, right-aligned with room for the widest count.
		local at = few.countAt :: number
		t.ok(at ~= nil, "the count's text")
		local count = few.texts[at]
		t.eq(count.text, "5 / 64")
		t.eq(count.align, "right")
		t.ok(wide(word, 0) + tip.GAP + wide("88 / 64", 0) <= count.w, "the widest count fits beside the word")
		t.eq(count.x + count.w, few.w - tip.PAD)
		-- No count, no countAt; a plain tooltip has none either.
		t.eq(Theme.tip({ name = "Stick", picture = true, lines = {} }, measure).countAt, nil)
		t.eq(Theme.tip({ name = "Water", picture = false, lines = {} }, measure).countAt, nil)
	end)

	t.test("theme: a plain tooltip (no item): its first line as the header", function()
		local tip = Theme.Tip
		local fluid = Theme.tip({
			name = "Water",
			nameColour = "Text",
			picture = false,
			lines = { { text = "1000 mB", colour = "TextMuted" } },
		}, measure)
		t.eq(fluid.head, tip.PLAIN_HEAD)
		t.eq(fluid.picture, nil)
		t.eq(fluid.dot, nil)
		local widest = math.max(measure("Water", Theme.Text.body), measure("1000 mB", Theme.Text.small))
		t.eq(fluid.w, widest + 2 * tip.PAD, "as wide as its widest text")
		t.eq(fluid.h, tip.PLAIN_HEAD + tip.PAD + Theme.Line.small + tip.PAD)
		t.eq(fluid.texts[1].x, tip.PAD)
		t.eq(fluid.texts[2].colour, "TextMuted")
		local one = Theme.tip({ name = "Shapeless", picture = false, lines = {} }, measure)
		t.eq(one.h, tip.PLAIN_HEAD, "one line: only the header")
		local warned = Theme.tip({
			name = "Locked",
			nameColour = "Warning",
			picture = false,
			lines = {},
		}, measure)
		t.eq(warned.texts[1].colour, "Warning", "its first line keeps its colour")
	end)

	t.test("theme: a real item's tooltip lines lay out inside the box", function()
		local Tooltip = require(shared.Items.Tooltip)
		local tip = Theme.Tip
		for _, name in { "IronPickaxe", "PurifiedWaterCanteen", "WaterBucket", "Cobblestone", "BasicBattery" } do
			local item = I[name]
			local lines = Tooltip.lines(item, { item = item, count = 1, damage = 1 })
			local body = {}
			for i = 2, #lines do
				table.insert(body, { text = lines[i].text, colour = Theme.tooltipColour(lines[i].colour) })
			end
			local fraction, sips = MenuLayout.wear(item, 1)
			local layout = Theme.tip({
				name = lines[1].text,
				condition = Theme.condition(fraction, sips),
				liquid = Theme.liquid(item),
				picture = true,
				lines = body,
			}, measure)
			t.ok(layout.w >= tip.MIN_W and layout.w <= tip.MAX_W, `{name}: width {layout.w}`)
			t.ok(#layout.texts > 1, `{name}: lines under the name`)
			for _, text in layout.texts do
				inside(text, 0, 0, layout.w, layout.h, name)
				t.ok(Theme.Colour[text.colour] ~= nil, `{name}: {text.colour} is a colour`)
			end
		end
	end)

	t.test("menu layout: wear is the durability left, sips told apart", function()
		local none, noSips = MenuLayout.wear(I.Stone, 0)
		t.eq(none, nil, "no durability")
		t.eq(noSips, false)
		t.eq(MenuLayout.wear(nil, nil), nil)
		local full, fullSips = MenuLayout.wear(I.IronPickaxe, 0)
		t.eq(full, 1.0)
		t.eq(fullSips, false)
		t.eq(MenuLayout.wear(I.IronPickaxe, nil), 1.0, "no damage")
		t.eq(MenuLayout.wear(I.IronPickaxe, 125), 0.5)
		t.eq(MenuLayout.wear(I.IronPickaxe, 400), 0, "never below 0")
		local sips, isSips = MenuLayout.wear(I.PurifiedWaterCanteen, 1)
		t.near(sips :: number, 2 / 3, 1e-9)
		t.eq(isSips, true, "a canteen")
	end)
end
