--[[
	The survival look's inventory screen layout (client Ui/InventoryColumns): for every mode, input
	(a mouse, touch with 22 and 26 px headers), window (window 0, a 27 and a 54 chest, a crafting
	table, a furnace, every real machine's panel), collapse bitmask, height and centre width, the
	sections sit inside their columns 2 apart (strips right under their header), the slots' frames
	inside their section bodies and apart, the eyes clear of every other slot and of their own
	slot's middle, the block's content cut by its title strip, ITEMS growing with the height, the
	band at the bottom with the quickbar and the status icons apart; the least heights and the
	placement table of the design (mode, scale, height, centre width per screen); the root inside
	its area on every screen, GuiScale base, window and collapse (MARGIN off its bottom while that
	fits); section counts read from the window, collapsed or not; grid lines that paint every frame
	edge once and never a face.
]]

return function(t, shared, require, _server, client)
	local Blocks = require(shared.Blocks)
	local Machines = require(shared.Machines)
	local Types = require(shared.Inventory.Types)
	local HudLayout = require(client.Ui.HudLayout)
	local InventoryColumns = require(client.Ui.InventoryColumns)
	local MenuLayout = require(client.Ui.MenuLayout)
	local Theme = require(client.Ui.Theme)

	local C = InventoryColumns
	local B = Blocks.id
	local BIT = C.BIT
	local SECTION_GAP = Theme.Size.SECTION_GAP

	type Rect = { x: number, y: number, w: number, h: number }

	local function overlaps(a: Rect, b: Rect): boolean
		return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
	end
	local function inside(r: Rect, outer: Rect): boolean
		return r.x >= outer.x and r.y >= outer.y and r.x + r.w <= outer.x + outer.w and r.y + r.h <= outer.y + outer.h
	end
	local function show(r: Rect): string
		return `({r.x}, {r.y}, {r.w} x {r.h})`
	end

	--[[ The windows ]]

	type Window = { name: string, container: any? }
	local windows: { Window } = {
		{ name = "window 0", container = nil },
		{ name = "chest 27", container = { kind = "chest", block = B.Chest, size = 27, slots = {} } },
		{ name = "chest 54", container = { kind = "chest", block = B.Chest, size = 54, slots = {} } },
		{ name = "crafting table", container = Types.newCrafting("crafting", B.CraftingTable) },
		{ name = "furnace", container = { kind = "furnace", block = B.Furnace, size = 3, slots = {} } },
	}
	local machineKinds: { [string]: boolean } = {}
	for block = 0, Blocks.count - 1 do
		if Machines.isMachine(block) then
			local kind = Machines.kindOf(block) :: any
			if not machineKinds[kind.name] then
				machineKinds[kind.name] = true
				table.insert(windows, { name = `machine {kind.name}`, container = Machines.newContainer(block) })
			end
		end
	end

	-- The Input for `window` in `mode`, touch or not with header `top`.
	local function inputOf(window: Window, mode: string, touch: boolean, top: number, collapsed: number): any
		local container = window.container
		local panel = if container then MenuLayout.panel(container) else nil
		return {
			mode = mode,
			touch = touch,
			top = top,
			container = if panel then panel.height else nil,
			panel = panel,
			equipment = container == nil,
			collapsed = collapsed,
			height = nil,
			centreW = nil,
		}
	end

	t.test("inventory columns: the windows include every machine kind", function()
		local count = 0
		for _ in machineKinds do
			count += 1
		end
		t.ok(count >= 7, `{count} machine kinds`)
		t.ok(#windows >= 12, `{#windows} windows`)
	end)

	t.test("inventory columns: top headers, widths and the least heights of the design", function()
		t.eq(C.topHeader(true, 1.25), 26, "touch at 1.25")
		t.eq(C.topHeader(true, 1.5), 22, "touch at 1.5")
		t.eq(C.topHeader(true, 1), 32, "touch at 1: 32 screen pixels")
		t.eq(C.topHeader(true, 4), 22, "never under 22")
		for _, base in { 0.5, 1, 2, 4, 9 } do
			t.eq(C.topHeader(false, base), 14, `a mouse at {base}`)
		end
		local function least(name: string, mode: string, touch: boolean, top: number, collapsed: number): number
			for _, window in windows do
				if window.name == name then
					local width, height = C.minimum(inputOf(window, mode, touch, top, collapsed))
					t.eq(width, if mode == "wide" then 450 else 358, `{name} {mode} width`)
					return height
				end
			end
			error(name)
		end
		t.eq(least("window 0", "wide", false, 14, 0), 214, "mouse, window 0")
		t.eq(least("window 0", "narrow", false, 14, 0), 214, "mouse, window 0, narrow")
		t.eq(least("window 0", "wide", false, 14, BIT.vanity), 200, "mouse, VANITY collapsed")
		for _, name in { "chest 27", "crafting table", "furnace", "machine smelter", "machine battery" } do
			t.eq(least(name, "wide", false, 14, 0), 212, `mouse, {name}`)
		end
		t.eq(least("chest 54", "wide", false, 14, 0), 266, "mouse, chest 54")
		t.eq(least("window 0", "wide", true, 22, BIT.vanity), 200, "touch 22, VANITY collapsed, wide")
		t.eq(least("window 0", "narrow", true, 22, BIT.vanity), 196, "touch 22, VANITY collapsed, narrow")
		t.eq(least("window 0", "wide", true, 22, 0), 238, "touch 22, VANITY open")
		t.eq(least("window 0", "wide", true, 26, BIT.vanity), 200, "touch 26, wide")
		t.eq(least("window 0", "narrow", true, 26, BIT.vanity), 200, "touch 26, narrow")
		t.eq(least("chest 54", "wide", true, 22, 0), 274, "touch 22, chest 54")
		-- The columns of the design's table, at the least height.
		local function bottoms(name: string, touch: boolean, top: number, collapsed: number): (number, number)
			for _, window in windows do
				if window.name == name then
					local a = C.arrange(inputOf(window, "wide", touch, top, collapsed))
					local right = 0
					for _, section in a.sections do
						if section.column == 3 then
							right = math.max(right, section.y + section.header + section.body)
						end
					end
					local block = a.byKind.craft or a.byKind.container
					-- (ITEMS at its least: its bar and 52.)
					local left = block.y + block.header + block.body + SECTION_GAP + C.JEI_MIN
					return left, right
				end
			end
			error(name)
		end
		local left, right = bottoms("window 0", false, 14, 0)
		t.eq(left, 160, "window 0's left column")
		t.eq(right, 188, "window 0's right column")
		left, right = bottoms("chest 27", false, 14, 0)
		t.eq(left, 186, "a chest's left column")
		t.eq(right, 110, "the right column without equipment")
		left, right = bottoms("chest 54", true, 22, 0)
		t.eq(left, 248, "touch, a 54 chest's left column")
		t.eq(right, 118, "touch, the right column without equipment")
	end)

	--[[ Every arrangement ]]

	-- Spots, eyes and frames checked once per section kind and input (they are body-local).
	local checkedSpots: { [string]: boolean } = {}
	local function checkSpots(kind: string, input: any, section: any, what: string, window: string)
		-- (A collapsed section's slots are checked with it open.)
		if section.collapsed then
			return
		end
		local key = `{window}|{kind}|{input.touch}|{input.mode}`
		if checkedSpots[key] then
			return
		end
		checkedSpots[key] = true
		local spots = C.spots(kind :: any, input)
		local body = { x = 0, y = 0, w = section.w, h = section.body }
		if kind == "container" then
			t.eq(body.h, input.container - C.BODY_CUT, `{what}: the block's body is its panel less the title strip`)
		end
		local frames = {}
		for i, spot in spots do
			local frame = C.frame(spot)
			t.eq(frame.w, if spot.big then 26 else 18, `{what}: frame size`)
			t.ok(inside(frame, body), `{what}: {kind} spot {i} {show(frame)} inside its body {show(body)}`)
			for j, other in frames do
				t.ok(not overlaps(frame, other), `{what}: {kind} frames {i} and {j} apart`)
			end
			table.insert(frames, frame)
		end
		if kind == "container" then
			local panel = input.panel
			t.eq(#spots, #panel.slots, `{what}: every panel slot`)
			for i, spot in spots do
				local at = panel.slots[i]
				t.eq(spot.slot, at.slot, `{what}: slot {i}`)
				t.eq(spot.x, at.x, `{what}: x {i}`)
				t.eq(spot.y, at.y - C.BODY_CUT, `{what}: y {i} cut by the title strip`)
				t.ok(spot.y >= 0, `{what}: y {i} >= 0`)
			end
			-- The panel's other content, cut the same, stays in the body.
			local cut = C.containerOffset()
			t.eq(cut, -C.BODY_CUT)
			local function within(r: Rect?, name: string)
				if r then
					local moved = { x = r.x, y = r.y + cut, w = r.w, h = r.h }
					t.ok(inside(moved, body), `{what}: the {name} {show(moved)} inside the body`)
				end
			end
			within(panel.arrow, "arrow")
			within(panel.progress, "progress")
			within(panel.flame, "flame")
			within(panel.energy, "energy bar")
			for _, tank in panel.tanks do
				within(tank.frame, "tank")
			end
			local status = panel.status
			if status then
				within({ x = status.x, y = status.y, w = 1, h = 8 }, "status line")
			end
			for _, line in panel.lines do
				within({ x = line.x, y = line.y, w = 1, h = 8 }, "line")
			end
		end
		-- Eyes: inside the body, apart, over no slot but (in its corner) their own.
		local eyes = C.eyes(kind :: any, input)
		local owners = {}
		for _, spot in spots do
			if
				(kind == "equipment" and spot.store == "accessory")
				or (kind == "vanity" and spot.store == "vanityArmor")
			then
				table.insert(owners, spot)
			end
		end
		if input.equipment and (kind == "equipment" or kind == "vanity") then
			t.eq(#eyes, #owners, `{what}: an eye per {kind} slot`)
		else
			t.eq(#eyes, 0, `{what}: no eyes in {kind}`)
		end
		for i, eye in eyes do
			t.ok(inside(eye, body), `{what}: {kind} eye {i} inside the body`)
			local own = owners[i]
			for j, other in eyes do
				t.ok(j == i or not overlaps(eye, other), `{what}: eyes {i} and {j} apart`)
			end
			for j, spot in spots do
				local frame = C.frame(spot)
				if spot ~= own then
					t.ok(not overlaps(eye, frame), `{what}: {kind} eye {i} clear of slot {j}`)
				end
			end
			local middle = { x = own.x + 7, y = own.y + 7, w = 2, h = 2 }
			t.ok(not overlaps(eye, middle), `{what}: {kind} eye {i} off its slot's middle`)
			if kind == "equipment" and input.touch then
				t.eq(eye.w, 16, `{what}: a finger's accessory eye`)
				t.eq(eye.h, 18)
			end
		end
	end

	local CONTAINER_KINDS = { craft = true, container = true, jei = true, backpack = true, vanity = true }

	local function checkArrangement(a: any, input: any, what: string, window: string)
		local width, least = C.minimum(input)
		t.eq(a.width, width, `{what}: width`)
		t.ok(a.height >= least and a.height <= math.max(least, C.MAX_HEIGHT), `{what}: height`)
		local root = { x = 0, y = 0, w = a.width, h = a.height }
		local columnH = a.height - Theme.Size.QUICK_BAND
		-- Columns inside the root, above the band, apart.
		local wide = input.mode == "wide"
		t.eq(a.columns[2] ~= nil, wide, `{what}: a centre column only when wide`)
		for index, column in a.columns do
			t.ok(inside(column, root), `{what}: column {index} inside the root`)
			t.eq(column.y + column.h, columnH, `{what}: column {index} down to the band`)
			for other, second in a.columns do
				if other ~= index then
					t.ok(not overlaps(column, second), `{what}: columns {index} and {other} apart`)
				end
			end
		end
		t.eq(a.columns[1].x, 0)
		t.eq(a.columns[3].x + a.columns[3].w, a.width, `{what}: the right column at the right edge`)
		-- Top headers.
		t.eq(#a.tops, 2)
		for i, header in a.tops do
			t.eq(header.y, 0, `{what}: top header {i} at y 0`)
			t.eq(header.h, input.top, `{what}: top header {i} {input.top} tall`)
			t.eq(header.x, a.columns[if i == 1 then 1 else 3].x)
		end
		t.eq(a.titles[1], "VICINITY")
		t.eq(a.titles[2], "EQUIPMENT")
		-- Sections: inside their column, 2 apart, the strips right under their header.
		local byColumn: { [number]: { any } } = {}
		for _, section in a.sections do
			local column = a.columns[section.column]
			t.ok(column ~= nil, `{what}: {section.kind} has a column`)
			local r = { x = section.x, y = section.y, w = section.w, h = section.header + section.body }
			t.ok(inside(r, column), `{what}: {section.kind} {show(r)} inside column {section.column}`)
			t.eq(section.w, column.w, `{what}: {section.kind} as wide as its column`)
			t.eq(a.byKind[section.kind], section)
			t.eq(section.collapsible, CONTAINER_KINDS[section.kind] == true, `{what}: {section.kind} collapsible`)
			if section.collapsed then
				t.eq(section.body, 0, `{what}: a collapsed {section.kind} is its bar`)
				t.ok(not C.live(a, section.kind), `{what}: a collapsed {section.kind} is not live`)
			else
				t.ok(C.live(a, section.kind), `{what}: {section.kind} live`)
			end
			byColumn[section.column] = byColumn[section.column] or {}
			table.insert(byColumn[section.column], section)
		end
		for index, list in byColumn do
			table.sort(list, function(p, q)
				return p.y < q.y
			end)
			for i, section in list do
				if i == 1 then
					local expected = if index == 2 then 0 else input.top
					t.eq(section.y, expected, `{what}: {section.kind} first in column {index}`)
				else
					local previous = list[i - 1]
					local gap = section.y - (previous.y + previous.header + previous.body)
					t.eq(gap, SECTION_GAP, `{what}: {section.kind} {SECTION_GAP} below {previous.kind}`)
				end
			end
		end
		t.eq(a.byKind.ground.header, 0, "the ground strip has no bar")
		t.eq(a.byKind.equipment.header, 0, "the worn strip has no bar")
		-- Absent kinds are not live.
		t.eq(a.byKind.craft ~= nil, input.container == nil, `{what}: CRAFTING only in window 0`)
		t.eq(a.byKind.container ~= nil, input.container ~= nil, `{what}: the block's section only with a block`)
		t.eq(a.byKind.vanity ~= nil, input.equipment, `{what}: VANITY only with the equipment`)
		t.eq(a.byKind.character ~= nil, wide, `{what}: the character only when wide`)
		t.eq(a.byKind.hands ~= nil, wide, `{what}: HANDS only when wide`)
		if input.container then
			t.ok(not C.live(a, "craft"), `{what}: no CRAFTING`)
		else
			t.ok(not C.live(a, "container"), `{what}: no block`)
		end
		if not input.equipment then
			t.ok(not C.live(a, "vanity"), `{what}: no VANITY`)
		end
		-- The character and HANDS.
		local character = a.byKind.character
		if character then
			t.ok(character.body >= C.CHARACTER_MIN, `{what}: the character at least {C.CHARACTER_MIN}`)
			local hands = a.byKind.hands
			t.eq(hands.y + hands.header + hands.body, columnH, `{what}: HANDS at the bottom`)
			t.eq(hands.header + hands.body, C.HANDS_H)
			local parts = C.hands(hands.w)
			for name, r in parts :: any do
				t.ok(inside(r, { x = 0, y = 0, w = hands.w, h = hands.body }), `{what}: HANDS {name} inside`)
			end
			-- (No slot in the centre column: the side columns' sections are apart from it.)
			for _, section in a.sections do
				if section.column ~= 2 then
					t.ok(
						not overlaps(
							{ x = character.x, y = character.y, w = character.w, h = character.body },
							{ x = section.x, y = section.y, w = section.w, h = section.header + section.body }
						),
						`{what}: the character clear of {section.kind}`
					)
				end
			end
		end
		-- ITEMS, the drop strip, the band.
		local jei = a.byKind.jei
		if jei.collapsed then
			t.eq(a.jei, nil, `{what}: no list while ITEMS is collapsed`)
		else
			local body = a.jei :: Rect
			t.ok(body ~= nil and body.h >= 52, `{what}: ITEMS at least 52 tall`)
			t.eq(body.y, jei.y + jei.header)
			t.eq(body.y + body.h, columnH, `{what}: ITEMS down to the band`)
			t.eq(body.w, 176)
		end
		local ground = a.byKind.ground
		t.eq(a.drop.x, ground.x)
		t.eq(a.drop.y, ground.y)
		t.eq(a.drop.w, ground.w)
		t.eq(a.drop.h, ground.body, `{what}: the drop place is the ground strip`)
		t.eq(a.band.y + a.band.h, a.height, `{what}: the band at the bottom`)
		t.eq(a.band.h, Theme.Size.QUICK_BAND)
		t.eq(a.band.w, a.width)
		t.ok(inside(a.quickbar, a.band), `{what}: the quickbar in the band`)
		t.eq(a.quickbar.w, 182)
		t.eq(a.quickbar.h, 22)
		local status = a.status
		t.ok(status ~= nil, `{what}: the status icons have a place`)
		if status then
			t.ok(inside(status, a.band), `{what}: the status icons in the band`)
			t.ok(not overlaps(status, a.quickbar), `{what}: the status icons clear of the quickbar`)
			t.eq(status.w, C.STATUS_W)
			t.eq(status.h, C.STATUS_H)
		end
		if wide then
			t.eq(a.quickbar.x, math.floor((a.width - 182) / 2), `{what}: the quickbar centred when wide`)
		end
		local right = a.columns[3]
		local from = if wide then a.columns[2].x else right.x
		t.eq(C.viewCentre(a), (from + right.x + right.w) / 2, `{what}: the recipe view's centre`)
		-- Every section's slots.
		for _, section in a.sections do
			checkSpots(section.kind, input, section, what, window)
		end
	end

	t.test("inventory columns: every mode, input, window, collapse, height and centre width", function()
		local count = 0
		local inputs = { { touch = false, top = 14 }, { touch = true, top = 22 }, { touch = true, top = 26 } }
		for _, mode in { "wide", "narrow" } do
			for _, kind in inputs do
				for _, window in windows do
					for collapsed = 0, 31 do
						local input = inputOf(window, mode, kind.touch, kind.top, collapsed)
						local _, least = C.minimum(input)
						local previousJei: number? = nil
						for _, extra in { 0, 37, math.huge } do
							input.height = if extra == math.huge then C.MAX_HEIGHT else least + extra
							for _, centreW in (if mode == "wide" then { 86, 130, 176 } else { 86 }) do
								input.centreW = centreW
								local a = C.arrange(input)
								local what =
									`{mode} touch={kind.touch} top={kind.top} {window.name} collapsed={collapsed} height={input.height} centre={centreW}`
								checkArrangement(a, input, what, window.name)
								if mode == "wide" then
									t.eq(a.width, 364 + centreW, `{what}: wide width`)
								else
									t.eq(a.width, 358, `{what}: narrow width`)
								end
								count += 1
							end
							-- ITEMS grows with the height.
							local a = C.arrange(input)
							if a.jei then
								local h = (a.jei :: Rect).h
								if previousJei then
									t.ok(h >= previousJei, `ITEMS grows with the height ({window.name})`)
								end
								previousJei = h
							end
						end
					end
				end
			end
		end
		t.ok(count > 10000, `{count} arrangements`)
		-- Extra height goes to ITEMS (and the character).
		local input = inputOf(windows[1], "wide", false, 14, 0)
		local _, least = C.minimum(input)
		local low = C.arrange(input)
		input.height = least + 37
		local high = C.arrange(input)
		t.eq((high.jei :: Rect).h - (low.jei :: Rect).h, 37, "ITEMS takes the extra height")
		t.eq(high.byKind.character.body - low.byKind.character.body, 37, "so does the character")
		t.eq(low.byKind.character.body, least - 26 - 2 - C.HANDS_H, "the character at the least height")
		-- The status icons fit at both least widths.
		t.ok(C.arrange(inputOf(windows[1], "wide", false, 14, 0)).status ~= nil, "status at 450")
		t.ok(C.arrange(inputOf(windows[1], "narrow", false, 14, 0)).status ~= nil, "status at 358")
	end)

	t.test("inventory columns: live is false for collapsed and absent kinds", function()
		local a = C.arrange(inputOf(windows[1], "wide", false, 14, BIT.backpack + BIT.jei))
		t.ok(not C.live(a, "backpack"), "collapsed BACKPACK")
		t.ok(not C.live(a, "jei"), "collapsed ITEMS")
		t.ok(not C.live(a, "container"), "no block in window 0")
		t.ok(C.live(a, "craft") and C.live(a, "vanity") and C.live(a, "equipment") and C.live(a, "ground"))
		local narrow = C.arrange(inputOf(windows[2], "narrow", false, 14, 0))
		t.ok(not C.live(narrow, "character") and not C.live(narrow, "hands"), "no centre when narrow")
		t.ok(not C.live(narrow, "vanity") and not C.live(narrow, "craft"), "a chest: no VANITY, no CRAFTING")
		t.ok(C.live(narrow, "container"), "the chest's section")
	end)

	t.test("inventory columns: a section's count comes from the window, collapsed or not", function()
		local inventory = Types.newInventory()
		local function stack(): any
			return { item = 1, count = 1 }
		end
		-- Two in the hotbar (not BACKPACK's), three in the backpack.
		for _, slot in { 1, 9, 10, 20, 36 } do
			inventory.slots[slot] = stack()
		end
		local first, last = Types.HOTBAR_SIZE + 1, Types.INVENTORY_SIZE
		t.eq(C.used(inventory.slots, first, last), 3, "BACKPACK (3/27)")
		-- Collapsed, BACKPACK's slots are not live (nothing is drawn), and the count stays.
		local a = C.arrange(inputOf(windows[1], "wide", false, 14, BIT.backpack))
		t.ok(not C.live(a, "backpack"), "a collapsed BACKPACK draws no slots")
		t.eq(C.used(inventory.slots, first, last), 3, "and still says (3/27)")
		t.eq(C.used(Types.newInventory().slots, first, last), 0, "an empty backpack")
		-- A double chest: the slots past the size are not counted.
		local slots: { [number]: any } = {}
		for slot = 1, 54, 3 do
			slots[slot] = stack()
		end
		slots[55] = stack()
		t.eq(C.used(slots, 1, 54), 18, "CHEST (18/54)")
		t.eq(C.used(slots, 1, 27), 9, "a single chest's 27")
	end)

	--[[ The placement table ]]

	t.test("inventory columns: place gives the design's mode, scale, centre and height per screen", function()
		type Case = {
			what: string,
			w: number,
			h: number,
			top: number,
			base: number,
			touch: boolean,
			window: number?,
			mode: string,
			scale: number,
			centre: number?,
			height: number?,
		}
		local cases: { Case } = {
			{
				what = "1920 x 1080",
				w = 1920,
				h = 1080,
				top = 58,
				base = 4,
				touch = false,
				mode = "wide",
				scale = 4,
				centre = 86,
				height = 238,
			},
			{
				what = "2560 x 1440",
				w = 2560,
				h = 1440,
				top = 58,
				base = 6,
				touch = false,
				mode = "wide",
				scale = 5,
				centre = 96,
			},
			{ what = "3840 x 2160", w = 3840, h = 2160, top = 58, base = 9, touch = false, mode = "wide", scale = 8 },
			{
				what = "1366 x 768",
				w = 1366,
				h = 768,
				top = 58,
				base = 3,
				touch = false,
				mode = "wide",
				scale = 3,
				height = 218,
			},
			{
				what = "1280 x 660",
				w = 1280,
				h = 660,
				top = 58,
				base = 2,
				touch = false,
				mode = "wide",
				scale = 2,
				centre = 176,
			},
			{
				what = "1024 x 768 touch",
				w = 1024,
				h = 768,
				top = 58,
				base = 3.125,
				touch = true,
				mode = "wide",
				scale = 2.125,
				centre = 86,
			},
			-- (The notched phone: 47 px off each side, 21 at the bottom.)
			{
				what = "844 x 390 touch",
				w = 750,
				h = 369,
				top = 58,
				base = 1.625,
				touch = true,
				mode = "narrow",
				scale = 1.5,
			},
			{
				what = "667 x 375 touch",
				w = 667,
				h = 375,
				top = 58,
				base = 1.5,
				touch = true,
				mode = "narrow",
				scale = 1.5,
			},
			{
				what = "667 x 375 touch, bar 36",
				w = 667,
				h = 375,
				top = 36,
				base = 1.5,
				touch = true,
				mode = "narrow",
				scale = 1.5,
			},
			{
				what = "568 x 320 touch",
				w = 568,
				h = 320,
				top = 58,
				base = 1.25,
				touch = true,
				mode = "wide",
				scale = 1.25,
			},
			{
				what = "3840 x 2160, GUI Scale 1",
				w = 3840,
				h = 2160,
				top = 58,
				base = 1,
				touch = false,
				mode = "wide",
				scale = 1,
			},
			{
				what = "3840 x 2160, GUI Scale 2",
				w = 3840,
				h = 2160,
				top = 58,
				base = 2,
				touch = false,
				mode = "wide",
				scale = 2,
			},
			{
				what = "3840 x 2160, GUI Scale 3",
				w = 3840,
				h = 2160,
				top = 58,
				base = 3,
				touch = false,
				mode = "wide",
				scale = 3,
			},
			{
				what = "1920 x 1080, GUI Scale 1",
				w = 1920,
				h = 1080,
				top = 58,
				base = 1,
				touch = false,
				mode = "wide",
				scale = 1,
			},
			{
				what = "1920 x 1080, chest 54",
				w = 1920,
				h = 1080,
				top = 58,
				base = 4,
				touch = false,
				window = 3,
				mode = "wide",
				scale = 3,
			},
			{
				what = "667 x 375 touch, chest 54",
				w = 667,
				h = 375,
				top = 58,
				base = 1.5,
				touch = true,
				window = 3,
				mode = "narrow",
				scale = 1,
			},
		}
		for _, case in cases do
			local window = windows[case.window or 1]
			-- (VANITY starts collapsed on touch screens.)
			local collapsed = if case.touch and window.container == nil then BIT.vanity else 0
			local wide = inputOf(window, "wide", false, 0, collapsed)
			local narrow = inputOf(window, "narrow", false, 0, collapsed)
			local view = { w = case.w, h = case.h, top = case.top, base = case.base, touch = case.touch }
			local p = C.place(view, wide, narrow)
			t.eq(p.mode, case.mode, `{case.what}: mode`)
			t.eq(p.scale, case.scale, `{case.what}: scale`)
			if case.centre then
				t.eq(p.centreW, case.centre, `{case.what}: centre`)
			end
			if case.height then
				t.eq(p.height, case.height, `{case.what}: height`)
			end
			t.eq(wide.mode, "wide", "place fills the inputs in")
			t.eq(narrow.mode, "narrow")
			t.eq(wide.top, C.topHeader(case.touch, case.base))
			t.eq(wide.touch, case.touch)
			-- The root inside the area, below the top bar, the band on the lifted bottom.
			local input = if p.mode == "wide" then wide else narrow
			input.height, input.centreW = p.height, p.centreW
			local a = C.arrange(input)
			t.eq(a.height, p.height, `{case.what}: the arrangement takes the height`)
			local lift = if case.touch then 0 else math.floor(C.INSET * case.h)
			t.ok(p.x >= 0 and p.x + a.width * p.scale <= case.w + 1e-6, `{case.what}: inside horizontally`)
			t.ok(p.y >= case.top, `{case.what}: below the top bar`)
			t.ok(p.y + a.height * p.scale <= case.h - lift + 1e-6, `{case.what}: above the lifted bottom`)
			t.ok(p.y + a.height * p.scale <= case.h + 1e-6, `{case.what}: on the screen`)
			t.ok(math.abs(p.x + a.width * p.scale / 2 - case.w / 2) <= 1, `{case.what}: centred`)
			t.ok(p.height >= select(2, C.minimum(input)) and p.height <= C.MAX_HEIGHT, `{case.what}: height range`)
			-- The JEI dock fits nine columns when ITEMS is open.
			if a.jei then
				t.eq((a.jei :: Rect).w, 176)
			end
		end
		-- The iPad would fit narrow at 2.75: wide wins with the character and HANDS.
		local wide = inputOf(windows[1], "wide", false, 0, BIT.vanity)
		local narrow = inputOf(windows[1], "narrow", false, 0, BIT.vanity)
		C.place({ w = 1024, h = 768, top = 58, base = 3.125, touch = true }, wide, narrow)
		local _, narrowLeast = C.minimum(narrow)
		local guiScale = require(client.Ui.GuiScale)
		t.eq(guiScale.fit(3.125, 358, narrowLeast, 1024, 710, true, narrowLeast), 2.75, "narrow would be 2.75")
	end)

	t.test("inventory columns: the root stays inside the area on every screen, window and collapse", function()
		local GuiScale = require(client.Ui.GuiScale)
		local MARGIN = GuiScale.MARGIN
		local GAP = Theme.Size.COLUMN_GAP
		-- (Phones 360 to 428 tall among them: their least heights leave less than both margins.)
		local widths = { 480, 568, 667, 740, 800, 844, 915, 1024, 1180, 1366, 1920, 3840 }
		local heights = { 270, 320, 360, 375, 390, 412, 428, 480, 660, 768, 1080, 2160 }
		local masks = { 0, BIT.vanity, BIT.jei, BIT.container + BIT.craft, BIT.backpack + BIT.vanity, 31 }
		local count, tight, failures = 0, 0, 0
		local first: string? = nil
		local function fail(what: string)
			failures += 1
			first = first or what
		end
		for _, w in widths do
			for _, h in heights do
				for _, touch in { false, true } do
					for _, top in { 36, 58 } do
						for _, setting in { 0, 2 } do
							local base = GuiScale.base(w, h, touch, setting)
							local view = { w = w, h = h, top = top, base = base, touch = touch }
							local lift = if touch then 0 else math.floor(C.INSET * h)
							local area = h - top - lift
							for _, window in windows do
								for _, mask in masks do
									local wide = inputOf(window, "wide", false, 0, mask)
									local narrow = inputOf(window, "narrow", false, 0, mask)
									local p = C.place(view, wide, narrow)
									count += 1
									local what =
										`{w} x {h} touch {touch} top {top} base {base} {window.name} collapsed {mask}`
									local width = if p.mode == "wide"
										then 2 * GAP + 176 + 176 + p.centreW
										else GAP + 176 + 176
									local extent = p.height * p.scale
									local bottom = p.y + extent
									if p.y < top then
										fail(`{what}: y {p.y} above the top bar`)
									end
									if bottom > h - lift + 1e-6 then
										fail(`{what}: bottom {bottom} past {h - lift}`)
									end
									if p.x < 0 or p.x + width * p.scale > w + 1e-6 then
										fail(`{what}: x {p.x} .. {p.x + width * p.scale} off the screen`)
									end
									-- On the bottom line, MARGIN up (less only when there is no room).
									if bottom < h - lift - MARGIN - 1 then
										fail(`{what}: bottom {bottom} not at the bottom`)
									end
									if extent + 2 * MARGIN <= area then
										if p.y < top + MARGIN or bottom > h - lift - MARGIN + 1e-6 then
											fail(`{what}: both margins fit but y {p.y}, bottom {bottom}`)
										end
									else
										tight += 1
									end
								end
							end
						end
					end
				end
			end
		end
		t.eq(failures, 0, first or "every root inside its area")
		t.ok(count > 50000, `{count} placements`)
		t.ok(tight > 100, `{tight} placements with less room than both margins`)
		-- The phone of the review: 800 x 360 under a 58 px bar, window 0 (VANITY collapsed on touch).
		local wide = inputOf(windows[1], "wide", false, 0, BIT.vanity)
		local narrow = inputOf(windows[1], "narrow", false, 0, BIT.vanity)
		local p = C.place({ w = 800, h = 360, top = 58, base = 1.5, touch = true }, wide, narrow)
		t.eq(p.mode, "wide")
		t.eq(p.scale, 1.5)
		t.eq(p.height, 200)
		t.eq(p.y, 58, "300 tall in 302: no top margin, 2 of the bottom one")
		t.eq(p.y + p.height * p.scale, 358, "the band on the screen (it was at 366 with both margins)")
		-- 1080p: the same y as before (both margins fit).
		local wide1080 = inputOf(windows[1], "wide", false, 0, 0)
		local narrow1080 = inputOf(windows[1], "narrow", false, 0, 0)
		local q = C.place({ w = 1920, h = 1080, top = 58, base = 4, touch = false }, wide1080, narrow1080)
		t.eq(q.y, 58 + MARGIN + math.floor((1080 - 58 - 54 - 2 * MARGIN) - q.height * q.scale))
	end)

	--[[ Grid lines ]]

	local function key(x: number, y: number): number
		return (y + 64) * 4096 + (x + 64)
	end

	local function checkLines(spots: { any }, what: string, body: Rect?)
		local rects = C.gridLines(spots)
		local painted: { [number]: boolean } = {}
		for i, r in rects do
			t.ok(r.w >= 1 and r.h >= 1 and (r.w == 1 or r.h == 1), `{what}: rect {i} is a line`)
			if body then
				t.ok(inside(r, body), `{what}: line {show(r)} inside the body`)
			end
			for x = r.x, r.x + r.w - 1 do
				for y = r.y, r.y + r.h - 1 do
					t.ok(not painted[key(x, y)], `{what}: ({x}, {y}) painted once`)
					painted[key(x, y)] = true
				end
			end
		end
		for i, spot in spots do
			local left, top, right, bottom
			if spot.big then
				left, top, right, bottom = spot.x - 5, spot.y - 5, spot.x + 20, spot.y + 20
			else
				left, top, right, bottom = spot.x - 1, spot.y - 1, spot.x + 17, spot.y + 17
			end
			for x = left, right do
				t.ok(painted[key(x, top)] and painted[key(x, bottom)], `{what}: spot {i}'s top and bottom edges`)
			end
			for y = top, bottom do
				t.ok(painted[key(left, y)] and painted[key(right, y)], `{what}: spot {i}'s sides`)
			end
			-- The face: inside the lines.
			local face = if spot.big
				then { x = spot.x - 4, y = spot.y - 4, w = 24, h = 24 }
				else { x = spot.x, y = spot.y, w = 17, h = 17 }
			for x = face.x, face.x + face.w - 1 do
				for y = face.y, face.y + face.h - 1 do
					t.ok(not painted[key(x, y)], `{what}: no line in spot {i}'s face at ({x}, {y})`)
				end
			end
		end
		return rects
	end

	t.test("inventory columns: grid lines paint every edge once and never a face", function()
		-- A 9 x 3 grid: four horizontal lines, ten columns cut into three.
		local grid = {}
		for row = 0, 2 do
			for column = 0, 8 do
				table.insert(
					grid,
					{ store = "inventory", slot = 1, x = 8 + column * 18, y = 3 + row * 18, big = false }
				)
			end
		end
		local rects = checkLines(grid, "9 x 3", { x = 0, y = 0, w = 176, h = 58 })
		local horizontal, vertical = 0, 0
		for _, r in rects do
			if r.h == 1 and r.w > 1 then
				horizontal += 1
				t.eq(r.w, 9 * 18 + 1, "a whole row")
			else
				vertical += 1
				t.eq(r.h, 17, "cut between the rows")
			end
		end
		t.eq(horizontal, 4, "a 9 x 3 grid gives 4 horizontal rects")
		t.eq(vertical, 30, "and 30 vertical ones")
		-- Every section that draws lines, for every window.
		for _, window in windows do
			local input = inputOf(window, "wide", false, 14, 0)
			local a = C.arrange(input)
			for _, kind in { "craft", "container", "backpack" } do
				local section = a.byKind[kind]
				if section then
					local spots = C.spots(kind :: any, input)
					checkLines(spots, `{window.name} {kind}`, { x = 0, y = 0, w = section.w, h = section.body })
				end
			end
		end
		t.eq(#C.gridLines({}), 0, "no spots, no lines")
	end)

	t.test("inventory columns: the strips, CRAFTING, the band's cells and the ground", function()
		local input = inputOf(windows[1], "wide", false, 14, 0)
		local craft = C.spots("craft", input)
		t.eq(#craft, 5, "the 2 x 2 grid and its result")
		t.eq(craft[5].slot, Types.CRAFT_RESULT, "the result last (gamepad order)")
		for i = 1, 4 do
			t.eq(craft[i].slot, i + 1, `grid slot {i + 1}`)
		end
		local equipment = C.spots("equipment", input)
		t.eq(#equipment, Types.ARMOR_SIZE + Types.ACCESSORY_SIZE, "armor over the accessories")
		local chest = inputOf(windows[2], "wide", false, 14, 0)
		t.eq(#C.spots("equipment", chest), Types.ARMOR_SIZE, "other windows: the armor alone")
		t.eq(#C.spots("vanity", chest), 0)
		t.eq(#C.spots("vanity", input), Types.VANITY_ARMOR_SIZE + Types.VANITY_ACCESSORY_SIZE)
		local backpack = C.spots("backpack", input)
		t.eq(#backpack, 27)
		t.eq(backpack[1].slot, 10)
		t.eq(backpack[27].slot, 36)
		local ground = C.spots("ground", input)
		t.eq(#ground, C.GROUND_SLOTS)
		for _, spot in ground do
			t.eq(spot.store, "ground")
			t.ok(inside(C.frame(spot), { x = 0, y = 0, w = 176, h = C.GROUND_H }), "a ground place inside the strip")
		end
		-- The band's cells: HudLayout's quickbar maths from the bar's top left, inside the band's
		-- quickbar (QUICK_W x QUICK_H), the item one pixel into its cell.
		for i = 1, Types.HOTBAR_SIZE do
			local icon, cell = HudLayout.quickIcon(i, 0), HudLayout.quickCell(i, 0)
			t.eq(icon.x, 3 + 20 * (i - 1))
			t.eq(icon.y, 3)
			t.eq(cell.x, icon.x - 1)
			t.eq(cell.y, icon.y - 1)
			t.ok(
				cell.x >= 0 and cell.x + cell.w <= C.QUICK_W and cell.y + cell.h <= C.QUICK_H,
				`cell {i} inside the bar`
			)
		end
		t.eq(C.spots("jei", input)[1], nil, "ITEMS has no slots")
		t.eq(C.spots("character", input)[1], nil)
	end)
end
