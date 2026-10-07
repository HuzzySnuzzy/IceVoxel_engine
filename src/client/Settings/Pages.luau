--!strict
--[[
	The Options menu's pages and where their widgets go (pure; Ui/SettingsScreen draws them).

	Minecraft's Options screen: a title, then buttons and sliders 150 x 20 GUI pixels in two
	columns 10 apart (310 wide), rows 24 apart, the status lines, and "Done" (200 wide) at the
	bottom. Items flow in reading order, two to a row; a `wide` item takes a whole row (310) and
	`row` starts a new one. Settings a device doesn't offer (`shown`) are left out and the rest
	close up, so no page has holes.

	  main           Graphics (the preset, cycled), FOV; the other pages; Reset (the current
	                 preset again) and Defaults (the device's defaults); Done closes the menu
	  video          render distance, detail falloff, full detail, cave view, plants, lichen
	                 lights, shadows, far shadows, fog, textures, far materials, brightness,
	                 distance or lighting, caves (hidden until seen or always shown)
	  performance    far meshes, build budget, hidden terrain, swap frames
	  sounds         Music & Sounds: the volumes (master, music, blocks, players, ambient,
	                 interface), footsteps, interface clicks, cave moods and music toasts
	  controls       Minecraft's ControlsScreen: Mouse Settings..., Key Binds..., Sneak and
	                 Sprint (Hold / Toggle), touch buttons
	    mouse        Minecraft's MouseSettingsScreen: sensitivity, scroll sensitivity, invert
	                 mouse, discrete scrolling, and this game's scroll wheel (hotbar or zoom)
	    keybinds     Minecraft's KeyBindsScreen: a scrolling list (`list = "keys"`, laid out by
	                 `keyList`), Reset Keys and Done
	  hud            minimap, WAILA, attack indicator, GUI scale
	  chat           Chat Settings (Ui/Chat): Chat (shown, commands only, hidden), text opacity,
	                 background opacity, text size, line spacing, chat delay, width, focused and
	                 unfocused height, command suggestions
	  accessibility  Minecraft's Accessibility Settings that apply here: view bobbing,
	                 distortion effects, FOV effects, damage tilt
	  weather        clouds and rain / snow (Off, Fast, Fancy): Minecraft keeps Clouds on its
	                 Video Settings, but that page is full (MAX_ROWS)
	A sub-page's Done goes back to its `parent` (the main page when none). `status` lists the
	status lines a page shows (the controller's Settings.setStatus kinds).

	The Key Binds list (`keyList`): Minecraft's KeyBindsList, a row per category (its name
	centred) and per action (KEY_ROW apart): the action's name, the key button (KEY_BUTTON_W:
	wider than Minecraft's 75, for Roblox's pixel font) and Reset (KEY_RESET_W), in a scrolling
	frame from TOP down to the bottom row: Reset Keys and Done side by side (Minecraft's 150 each).

	Tooltips (`tooltipAt`): a setting with a PlayerSettings `tooltip` shows it while hovered or
	selected, as Minecraft's options do: wrapped to TOOLTIP_W pixels, below the widget
	(BelowOrAboveWidgetTooltipPositioner), or above it when the panel has no room below.
]]

export type Item = {
	kind: "setting" | "page" | "action",
	-- The setting's key, the page's id or the action ("reset", "defaults").
	id: string,
	-- Button text of pages and actions.
	text: string?,
	wide: boolean?,
	row: boolean?,
}

export type Page = {
	id: string,
	title: string,
	items: { Item },
	status: { string },
	-- The page Done goes back to (nil: the main page; the main page's Done closes the menu).
	parent: string?,
	-- A page drawn as a list instead of `items`: "keys", the Key Binds list.
	list: string?,
}

export type Placed = {
	item: Item,
	x: number,
	y: number,
	w: number,
	h: number,
}

export type Layout = {
	widgets: { Placed },
	-- Where the status lines go (one per `status` kind, LINE apart) and the Done button.
	statusY: number,
	done: Placed,
}

-- A row of the Key Binds list: a category's name or an action (`id`), `y` from the list's top.
export type KeyRow = {
	kind: "category" | "key",
	id: string,
	text: string,
	y: number,
}

local Pages = {}

Pages.WIDTH = 310
Pages.HEIGHT = 228
Pages.BUTTON_W = 150
Pages.BUTTON_H = 20
Pages.GAP = 10
Pages.ROW = 24
Pages.TITLE_Y = 6
Pages.TOP = 22
Pages.LINE = 11
Pages.DONE_W = 200
-- Rows a page can hold above its status lines (the video page needs 7).
Pages.MAX_ROWS = 7
-- Tooltips: the width their text wraps at (Minecraft splits option tooltips at a fixed width; this
-- pixel font is wider than Minecraft's), the padding around the text and the gap to the widget.
Pages.TOOLTIP_W = 200
Pages.TOOLTIP_PAD = 4
Pages.TOOLTIP_GAP = 4

-- The Key Binds list: rows, columns (name, key button, Reset), the scroll bar and the bottom row.
Pages.KEY_ROW = 24
Pages.KEY_NAME_W = 140
Pages.KEY_BUTTON_X = 146
Pages.KEY_BUTTON_W = 100
Pages.KEY_RESET_X = 250
Pages.KEY_RESET_W = 50
Pages.SCROLL_BAR = 6
Pages.LIST_BOTTOM = Pages.HEIGHT - Pages.BUTTON_H - 4

local function setting(key: string, wide: boolean?): Item
	return { kind = "setting", id = key, wide = wide }
end

local function page(id: string, text: string): Item
	return { kind = "page", id = id, text = text }
end

Pages.list = {
	{
		id = "main",
		title = "Options",
		items = {
			setting("preset"),
			setting("fov"),
			page("video", "Video Settings..."),
			page("performance", "Performance..."),
			page("sounds", "Music & Sounds..."),
			page("controls", "Controls..."),
			page("hud", "HUD..."),
			page("chat", "Chat Settings..."),
			page("accessibility", "Accessibility Settings..."),
			page("weather", "Weather..."),
			{ kind = "action", id = "reset", text = "Reset", row = true },
			{ kind = "action", id = "defaults", text = "Defaults" },
		},
		status = { "terrain" },
	},
	{
		id = "video",
		title = "Video Settings",
		items = {
			setting("renderDistance"),
			setting("detailFalloff"),
			setting("fullDetail"),
			setting("caveView"),
			setting("plants"),
			setting("lichenLights"),
			setting("shadows"),
			setting("farShadows"),
			setting("fog"),
			setting("textures"),
			setting("farMaterials"),
			setting("brightness"),
			setting("preferDistance"),
			setting("alwaysCaves"),
		},
		status = { "terrain" },
	},
	{
		id = "performance",
		title = "Performance",
		items = {
			setting("farMeshes"),
			setting("buildBudget"),
			setting("skipHidden"),
			setting("swapFrames"),
		},
		status = { "terrain", "farMeshes" },
	},
	{
		id = "sounds",
		title = "Music & Sounds",
		items = {
			setting("masterVolume", true),
			setting("musicVolume"),
			setting("blocksVolume"),
			setting("playersVolume"),
			setting("ambientVolume"),
			setting("uiVolume"),
			setting("footsteps"),
			setting("interfaceClicks"),
			setting("caveRumble"),
			setting("musicToasts"),
		},
		status = {},
	},
	{
		id = "controls",
		title = "Controls",
		items = {
			page("mouse", "Mouse Settings..."),
			page("keybinds", "Key Binds..."),
			setting("toggleSneak"),
			setting("toggleSprint"),
			setting("touchButtons"),
		},
		status = { "controls" },
	},
	{
		id = "mouse",
		title = "Mouse Settings",
		parent = "controls",
		items = {
			setting("sensitivity", true),
			setting("scrollSensitivity", true),
			setting("invertMouse"),
			setting("discreteScrolling"),
			setting("scrollHotbar"),
		},
		status = { "mouse" },
	},
	{
		id = "keybinds",
		title = "Key Binds",
		parent = "controls",
		list = "keys",
		items = {},
		status = {},
	},
	{
		id = "hud",
		title = "HUD",
		items = {
			setting("minimap"),
			setting("waila"),
			setting("attackIndicator", true),
			setting("guiScale"),
		},
		status = {},
	},
	{
		id = "chat",
		title = "Chat Settings",
		items = {
			setting("chatVisibility"),
			setting("commandSuggestions"),
			setting("chatOpacity"),
			setting("chatBackground"),
			setting("chatScale"),
			setting("chatLineSpacing"),
			setting("chatDelay"),
			setting("chatWidth"),
			setting("chatHeightFocused"),
			setting("chatHeightUnfocused"),
		},
		status = {},
	},
	{
		id = "weather",
		title = "Weather",
		items = {
			setting("clouds"),
			setting("weather"),
		},
		status = {},
	},
	{
		id = "accessibility",
		title = "Accessibility Settings",
		items = {
			setting("viewBobbing"),
			setting("distortionEffects"),
			setting("fovEffects"),
			setting("damageTilt"),
		},
		status = {},
	},
} :: { Page }

local byId: { [string]: Page } = {}
for _, p in Pages.list do
	byId[p.id] = p
end
Pages.byId = byId

-- The page Done goes back to from `id` (nil from the main page: Done closes the menu).
function Pages.back(id: string): string?
	if id == "main" then
		return nil
	end
	local p = byId[id]
	return if p and p.parent then p.parent else "main"
end

--[[
	Places page `p`'s items; `shown(item)` says whether an item is offered (default: all).
	Positions are GUI pixels in the WIDTH x HEIGHT panel.
]]
function Pages.layout(p: Page, shown: ((item: Item) -> boolean)?): Layout
	local widgets: { Placed } = {}
	local row, column = 0, 0
	for _, item in p.items do
		if shown and not shown(item) then
			continue
		end
		if (item.wide or item.row) and column > 0 then
			row += 1
			column = 0
		end
		local y = Pages.TOP + row * Pages.ROW
		if item.wide then
			table.insert(widgets, { item = item, x = 0, y = y, w = Pages.WIDTH, h = Pages.BUTTON_H })
			row += 1
		else
			local x = column * (Pages.BUTTON_W + Pages.GAP)
			table.insert(widgets, { item = item, x = x, y = y, w = Pages.BUTTON_W, h = Pages.BUTTON_H })
			column += 1
			if column == 2 then
				row += 1
				column = 0
			end
		end
	end
	local rows = row + (if column > 0 then 1 else 0)
	local statusY = Pages.TOP + rows * Pages.ROW + 2
	local doneY = Pages.HEIGHT - Pages.BUTTON_H
	local done: Placed = {
		item = { kind = "action", id = "done", text = "Done" },
		x = (Pages.WIDTH - Pages.DONE_W) / 2,
		y = doneY,
		w = Pages.DONE_W,
		h = Pages.BUTTON_H,
	}
	return { widgets = widgets, statusY = statusY, done = done }
end

--[[
	The Key Binds list's rows from KeyBindings.ordered()'s groups ({ category = { name },
	actions = { { id, name } } }): a category row, then its actions, KEY_ROW apart from y = 0.
	Returns the rows and the list's whole height.
]]
function Pages.keyList(groups: { { category: any, actions: { any } } }): ({ KeyRow }, number)
	local rows: { KeyRow } = {}
	local y = 0
	for _, group in groups do
		table.insert(rows, { kind = "category", id = group.category.name, text = group.category.name, y = y })
		y += Pages.KEY_ROW
		for _, action in group.actions do
			table.insert(rows, { kind = "key", id = action.id, text = action.name, y = y })
			y += Pages.KEY_ROW
		end
	end
	return rows, y
end

--[[ Scrolling the list (Minecraft's AbstractSelectionList) ]]

-- The list's visible height, between the title and the bottom row.
Pages.LIST_HEIGHT = Pages.LIST_BOTTOM - Pages.TOP
-- A wheel step scrolls half a row (AbstractSelectionList.mouseScrolled: itemHeight / 2).
Pages.WHEEL_STEP = Pages.KEY_ROW / 2
-- The thumb is at least this tall (AbstractSelectionList: 32).
Pages.MIN_THUMB = 32

-- `scroll` (pixels from the list's top) kept within 0..content - view.
function Pages.clampScroll(scroll: number, content: number, view: number): number
	return math.clamp(scroll, 0, math.max(0, content - view))
end

--[[
	The scroll bar's thumb: its top and height in a `view` tall bar for a `content` tall list
	scrolled by `scroll` (Minecraft's: view^2 / content tall, at least MIN_THUMB, at most view -
	8). A list that fits shows no thumb (height 0).
]]
function Pages.thumb(scroll: number, content: number, view: number): (number, number)
	local most = content - view
	if most <= 0 then
		return 0, 0
	end
	local height = math.clamp(math.floor(view * view / content), Pages.MIN_THUMB, view - 8)
	local top = math.floor(Pages.clampScroll(scroll, content, view) * (view - height) / most + 0.5)
	return top, height
end

-- The scroll at which the thumb's top is at `top` (dragging it).
function Pages.scrollAtThumb(top: number, content: number, view: number): number
	local most = content - view
	local _, height = Pages.thumb(0, content, view)
	if most <= 0 or view - height <= 0 then
		return 0
	end
	return Pages.clampScroll(top * most / (view - height), content, view)
end

-- The scroll that shows a row at `y` (`h` tall) whole, moving as little as possible.
function Pages.scrollToShow(scroll: number, y: number, h: number, content: number, view: number): number
	if y < scroll then
		scroll = y
	elseif y + h > scroll + view then
		scroll = y + h - view
	end
	return Pages.clampScroll(scroll, content, view)
end

-- The Key Binds screen's bottom row: Reset Keys on the left, Done on the right (150 each).
function Pages.keyButtons(): (Placed, Placed)
	local y = Pages.HEIGHT - Pages.BUTTON_H
	local reset: Placed = {
		item = { kind = "action", id = "resetKeys", text = "Reset Keys" },
		x = 0,
		y = y,
		w = Pages.BUTTON_W,
		h = Pages.BUTTON_H,
	}
	local done: Placed = {
		item = { kind = "action", id = "done", text = "Done" },
		x = Pages.BUTTON_W + Pages.GAP,
		y = y,
		w = Pages.BUTTON_W,
		h = Pages.BUTTON_H,
	}
	return reset, done
end

--[[
	Where a `w` x `h` tooltip goes for the widget `placed` (panel GUI pixels): below it, or above
	it when it would reach past the panel's bottom (and there is room above); its left edge at
	the widget's, moved left so it ends inside the panel where it can.
]]
function Pages.tooltipAt(placed: Placed, w: number, h: number): (number, number)
	local x = math.max(0, math.min(placed.x, Pages.WIDTH - w))
	local below = placed.y + placed.h + Pages.TOOLTIP_GAP
	local above = placed.y - Pages.TOOLTIP_GAP - h
	local y = if below + h > Pages.HEIGHT and above >= 0 then above else below
	return x, y
end

return Pages
