--[[
	The menus' descriptions (client Ui/ButtonHelp, shown by Ui/HoverTip): every Options setting has
	a tooltip (Shared/PlayerSettings, the key bindings' from Shared/KeyBindings) that fits a
	tooltip; the registry, read from the sources: every HoverTip.attach names its button with a
	string literal that Ui/ButtonHelp has (a plain text, or variants when the call passes one),
	and every text there is used; the variants of the buttons built in loops cover what the loops
	go over (the avatar's scales and presets, the Options pages, the key binds' categories, JEI's
	tabs, the forecast steps, the spectator menu's items, the game modes, the structure screens'
	widgets); and how ButtonHelp.text picks a variant.
]]

local fs = require("@lune/fs")

-- Every client source.
local function walk(dir: string, out: { string })
	for _, entry in fs.readDir(dir) do
		local path = `{dir}/{entry}`
		if fs.isDir(path) then
			walk(path, out)
		elseif string.sub(entry, -5) == ".luau" then
			table.insert(out, path)
		end
	end
end

-- The source without comments, so prose naming the API never counts as a use.
local function code(source: string): string
	local stripped = string.gsub(source, "%-%-%[(=*)%[.-%]%1%]", "")
	stripped = string.gsub(stripped, "%-%-[^\n]*", "")
	return stripped
end

-- The pixel font's advance (8 GUI pixels a character at TEXT_SIZE 8), for wrapping in tests.
local function measure(text: string): number
	return #text * 8
end

return function(t, shared, require, _server, client)
	local Appearance = require(shared.Characters.Appearance)
	local GameMode = require(shared.GameMode)
	local KeyBindings = require(shared.KeyBindings)
	local PlayerSettings = require(shared.PlayerSettings)
	local StructureSettings = require(shared.Structures.Settings)
	local ButtonHelp = require(client.Ui.ButtonHelp)
	local CharacterRules = require(client.Ui.CharacterRules)
	local JeiData = require(client.Ui.Jei.JeiData)
	local Pages = require(client.Settings.Pages)
	local StructureForm = require(client.Ui.StructureForm)
	local TooltipLayout = require(client.Ui.TooltipLayout)
	local WeatherMap = require(client.Map.WeatherMap)

	-- Every HoverTip.attach in the client: its id, whether it passes a variant, and where.
	type Use = { id: string?, variant: boolean, file: string, call: string }
	local uses: { Use } = {}
	local files: { string } = {}
	walk("src/client", files)
	table.sort(files)
	for _, file in files do
		if file == "src/client/Ui/HoverTip.luau" then
			-- (Its own definition.)
			continue
		end
		local source = code(fs.readFile(file))
		for call in string.gmatch(source, "HoverTip%.attach(%b())") do
			-- (The object, then the id as a string literal, then perhaps a variant.)
			local id, rest = string.match(call, '^%(%s*[^,]-,%s*"([%w%.]+)"%s*(.-)%)$')
			table.insert(uses, {
				id = id,
				variant = rest ~= nil and string.match(rest, "^,") ~= nil,
				file = file,
				call = call,
			})
		end
	end

	t.test("button help: every Options setting has a tooltip that fits a tooltip", function()
		for _, entry in PlayerSettings.ENTRIES do
			local text = entry.tooltip
			t.ok(type(text) == "string" and #text > 10, `{entry.key} has a tooltip`)
			local tooltip = text :: string
			t.ok(string.match(tooltip, "[%.!?]$") ~= nil, `{entry.key}'s tooltip ends a sentence`)
			local rows = TooltipLayout.wrap(tooltip, measure)
			t.ok(#rows <= 8, `{entry.key}'s tooltip is short ({#rows} rows)`)
			t.eq(ButtonHelp.text("options.setting", entry.key), tooltip, `{entry.key} reaches the menu`)
		end
		for _, action in KeyBindings.ACTIONS do
			local entry = PlayerSettings.entry(KeyBindings.settingKey(action.id))
			t.eq(entry.tooltip, action.tooltip, `{action.id}: the binding's tooltip is its action's`)
			local button = ButtonHelp.text("options.keyButton", action.id)
			t.ok(button ~= nil and string.find(button, action.tooltip, 1, true) == 1, `{action.id}'s key button`)
		end
	end)

	t.test("button help: every HoverTip.attach names an id ButtonHelp has, as a string literal", function()
		t.ok(#uses >= 80, `the menus register their buttons ({#uses} calls)`)
		local menus: { [string]: boolean } = {}
		for _, use in uses do
			local id = use.id
			t.ok(id ~= nil, `{use.file}: HoverTip.attach{use.call} names its id as a string literal`)
			local entry = ButtonHelp.TEXTS[id :: string]
			t.ok(entry ~= nil, `{use.file}: ButtonHelp has "{id}"`)
			if use.variant then
				t.ok(type(entry) == "table", `{use.file}: "{id}" is passed a variant, so it has variants`)
			else
				t.ok(type(entry) == "string", `{use.file}: "{id}" is passed no variant, so it is one text`)
			end
			menus[string.match(id :: string, "^(%w+)%.") or ""] = true
		end
		for _, menu in
			{
				"title",
				"world",
				"create",
				"load",
				"confirm",
				"rename",
				"characters",
				"avatar",
				"options",
				"skills",
				"inventory",
				"creative",
				"jei",
				"map",
				"hud",
				"spectator",
				"switcher",
				"structure",
				"jigsaw",
			}
		do
			t.ok(menus[menu], `the {menu} menu registers its buttons`)
		end
	end)

	t.test("button help: every text is used, every text is a sentence", function()
		local used: { [string]: boolean } = {}
		for _, use in uses do
			if use.id then
				used[use.id] = true
			end
		end
		for id, entry in ButtonHelp.TEXTS do
			t.ok(used[id], `"{id}" is used by a menu`)
			t.ok(string.match(id, "^%w+%.%w+$") ~= nil, `"{id}" is "<menu>.<button>"`)
			local texts: { [string]: string } = if type(entry) == "string" then { [""] = entry } else entry
			for variant, text in texts do
				t.ok(#text > 3 and string.match(text, "[%.!?]$") ~= nil, `"{id}" {variant}: "{text}"`)
				t.ok(#TooltipLayout.wrap(text, measure) <= 8, `"{id}" {variant} is short`)
			end
		end
	end)

	t.test("button help: the buttons built in loops have a text for each of theirs", function()
		local function covers(id: string, keys: { string }, what: string)
			for _, key in keys do
				t.ok(ButtonHelp.text(id, key) ~= nil, `{id}: {what} "{key}"`)
			end
		end
		covers("avatar.tab", { "skin", "body", "clothing", "presets" }, "the tab")
		covers("avatar.scale", Appearance.SCALES, "the scale")
		covers("avatar.preset", CharacterRules.PRESETS, "the preset")
		local pages = {}
		for _, page in Pages.list do
			if page.id ~= "main" then
				table.insert(pages, page.id)
			end
		end
		covers("options.page", pages, "the page")
		local categories = {}
		for _, category in KeyBindings.CATEGORIES do
			table.insert(categories, category.id)
		end
		covers("options.keyCategory", categories, "the category")
		covers("jei.tab", JeiData.CATEGORIES, "the recipe category")
		local steps = {}
		for index in WeatherMap.LABELS do
			table.insert(steps, tostring(index))
		end
		covers("map.forecast", steps, "the forecast step")
		covers("spectator.slot", { "teleport", "player", "previous", "next", "close" }, "the item")
		t.eq(ButtonHelp.text("spectator.slot", "empty"), nil, "an empty slot says nothing")
		covers("switcher.mode", GameMode.ORDER, "the mode")
		covers("inventory.eye", { "hideArmor", "showArmor", "hideAccessory", "showAccessory" }, "the eye")
		local NOT_WIDGETS = { title = true, label = true, rightLabel = true, status = true }
		local widgets: { string } = {}
		for _, mode in StructureSettings.MODES do
			for _, w in StructureForm.layout(mode) do
				if not NOT_WIDGETS[w.kind] then
					table.insert(widgets, w.id)
				end
			end
		end
		covers("structure.widget", widgets, "the structure block's widget")
		local jigsaw: { string } = {}
		for _, w in StructureForm.jigsawLayout("Up") do
			if not NOT_WIDGETS[w.kind] then
				table.insert(jigsaw, w.id)
			end
		end
		covers("jigsaw.widget", jigsaw, "the jigsaw's widget")
	end)

	t.test("button help: a text, a variant's, the default, or none", function()
		t.eq(ButtonHelp.text("title.join"), ButtonHelp.TEXTS["title.join"], "a plain text")
		t.eq(ButtonHelp.text("title.join", "anything"), ButtonHelp.TEXTS["title.join"], "a variant of a text")
		t.ok(ButtonHelp.text("avatar.scale", "height") ~= ButtonHelp.text("avatar.scale", "width"), "variants")
		t.eq(ButtonHelp.text("avatar.scale", "nope"), nil, "no such variant, no default")
		t.eq(ButtonHelp.text("avatar.scale"), nil, "variants and no variant")
		t.eq(ButtonHelp.text("no.such"), nil, "no such id")
		t.ok(ButtonHelp.has("title.join") and not ButtonHelp.has("no.such"), "has")
		-- (The character's difficulty is fixed once made: its tooltip says what each one does.)
		local difficulty = ButtonHelp.text("avatar.difficulty") :: string
		for _, name in { "Classic", "Mediumcore", "Hardcore" } do
			t.ok(string.find(difficulty, name, 1, true) ~= nil, `the difficulty explains {name}`)
		end
	end)
end
