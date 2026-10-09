--[[
	Every interface follows the GUI scale the same way (client Ui/UiScale), read from the sources:
	only Ui/UiScale creates ScreenGuis; every UiScale.screenGui call names a layer of UiScale.Layer
	(the one table of what draws over what) and says IgnoreGuiInset explicitly; the ScreenGuis drawn
	relative to the screen rather than in GUI pixels ("screen" kind) are exactly the allowed ones,
	each with its reason; nothing in Ui/ or Map/ reads the camera's ViewportSize itself (UiScale is
	the one viewport source); and nothing asks Style.guiScale for a scale any more (the forward stays
	for older callers only).
]]

local fs = require("@lune/fs")

-- The "screen" kind: drawn as a share of the screen by design, not in GUI pixels.
local SCREEN_KINDS: { [string]: string } = {
	IceVoxelFireOverlay = "Player/BurningView: the fire glow rising from the screen's bottom",
	IceVoxelHand = "Player/HeldItems: the first-person hand, a view of the world sized by the screen",
	IceVoxelNukeFlash = "Rendering/ExplosionView: the Nuke's flash over the whole screen",
	IceVoxelTemperatureOverlay = "Ui/SurvivalHud: frost and heat closing in from the screen's edges",
	IceVoxelMap = "Map/init: the world map, its backdrop and panel shares of the screen",
}

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

-- The source without comments (block comments, then line comments), so prose naming an API
-- never counts as a use.
local function code(source: string): string
	local stripped = string.gsub(source, "%-%-%[(=*)%[.-%]%1%]", "")
	stripped = string.gsub(stripped, "%-%-[^\n]*", "")
	return stripped
end

return function(t, _shared, _require, _server, _client)
	local files: { string } = {}
	walk("src/client", files)
	table.sort(files)
	local UI_SCALE = "src/client/Ui/UiScale.luau"

	-- UiScale.Layer's names, from its table in the source.
	local layers: { [string]: number } = {}
	local layerTable = string.match(fs.readFile(UI_SCALE), "UiScale%.Layer = table%.freeze%((%b{})%)")
	assert(layerTable, "UiScale.Layer's table")
	for name, order in string.gmatch(code(layerTable), "(%w+) = (%-?%d+)") do
		layers[name] = tonumber(order) :: number
	end

	t.test("ui scale usage: UiScale.Layer keeps today's order", function()
		local count = 0
		for _ in layers do
			count += 1
		end
		t.ok(count >= 20, `the layers ({count})`)
		t.eq(layers.Hand, -1)
		t.eq(layers.Crosshair, 0)
		t.eq(layers.Map, 5)
		t.ok(layers.Map < layers.Toasts and layers.Toasts < layers.Saving, "the corner: map, toasts, saving icon")
		t.ok(layers.Waila < layers.Screens and layers.Screens < layers.Hud, "WAILA under the screens under the HUD")
		t.ok(layers.Hud < layers.AgeToast and layers.AgeToast < layers.Chat, "the Age banner, then the chat")
		t.ok(layers.ChatUnderScreens < layers.Screens, "the chat goes under an open screen's backdrop")
		t.ok(layers.Chat < layers.Switcher and layers.Switcher < layers.Cursor, "the switcher, then the cursor")
		t.ok(layers.Cursor < layers.Title and layers.Flash == layers.Title, "the title screen and the flash on top")
	end)

	t.test("ui scale usage: only Ui/UiScale creates ScreenGuis", function()
		local found: { string } = {}
		for _, file in files do
			if file ~= UI_SCALE and string.find(code(fs.readFile(file)), 'Instance.new("ScreenGui")', 1, true) then
				table.insert(found, file)
			end
		end
		t.ok(#found == 0, `ScreenGuis made outside Ui/UiScale: {table.concat(found, ", ")}`)
	end)

	t.test("ui scale usage: every screenGui names a layer, its inset and its kind", function()
		local calls = 0
		local screens: { [string]: boolean } = {}
		for _, file in files do
			-- (Its definition is no call.)
			local source = string.gsub(code(fs.readFile(file)), "function UiScale%.screenGui", "")
			for call in string.gmatch(source, "UiScale%.screenGui(%b())") do
				calls += 1
				local name, layer = string.match(call, '^%(%s*"([%w_]+)"%s*,%s*"(%w+)"%s*,')
				t.ok(name ~= nil and layer ~= nil, `{file}: UiScale.screenGui{call} names a gui and a layer`)
				t.ok(layers[layer :: string] ~= nil, `{file}: "{layer}" is a UiScale.Layer`)
				t.ok(string.find(call, "inset = (%a+)") ~= nil, `{file}: {name} says IgnoreGuiInset explicitly`)
				local kind = string.match(call, 'kind = "(%a+)"')
				t.ok(kind == "scaled" or kind == "screen", `{file}: {name} is "scaled" or "screen"`)
				if kind == "screen" then
					screens[name :: string] = true
					t.ok(
						SCREEN_KINDS[name :: string] ~= nil,
						`{file}: {name} is drawn by the screen without a reason here`
					)
				end
			end
		end
		t.ok(calls >= 18, `every interface goes through UiScale.screenGui ({calls} calls)`)
		for name, reason in SCREEN_KINDS do
			t.ok(screens[name], `{name} ({reason}) is still made, as "screen"`)
		end
	end)

	t.test("ui scale usage: one viewport source, no scale asked of Style", function()
		local found: { string } = {}
		for _, file in files do
			local source = code(fs.readFile(file))
			local inUi = string.find(file, "src/client/Ui/", 1, true) ~= nil
				or string.find(file, "src/client/Map/", 1, true) ~= nil
			if inUi and file ~= UI_SCALE and string.find(source, "ViewportSize", 1, true) then
				table.insert(found, `{file} reads ViewportSize`)
			end
			if file ~= "src/client/Ui/Style.luau" and string.find(source, "Style.guiScale(", 1, true) then
				table.insert(found, `{file} asks Style.guiScale`)
			end
			if string.find(source, "scaleChanged", 1, true) and file ~= "src/client/Ui/Style.luau" then
				table.insert(found, `{file} listens to Style.scaleChanged`)
			end
		end
		t.ok(#found == 0, table.concat(found, "; "))
	end)
end
