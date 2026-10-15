--[[
	The inventory family's look in numbers (client Ui/Theme): every colour a 0..255 colour with a
	transparency in 0..1, text sizes and fonts that exist, the five condition levels from Pristine
	to Ruined (no tint, sips have none), the drag feedback rules, capitals and section titles, the
	slot face states, the text weight rule (Light only from 14 screen pixels), count boxes by scale,
	stroke thicknesses, quickbar number boxes, tooltip colour names, the liquid pill, the held
	item's texts, and Ui/MenuLayout.wear (durability left, and canteens' sips told apart).
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
