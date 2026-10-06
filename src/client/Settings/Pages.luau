--!strict
--[[
	The Options menu's pages and where their widgets go (pure; Ui/SettingsScreen draws them).

	Minecraft's Options screen: a title, then buttons and sliders 150 x 20 GUI pixels in two
	columns 10 apart (310 wide), rows 24 apart, the status lines, and "Done" (200 wide) at the
	bottom. Items flow in reading order, two to a row; a `wide` item takes a whole row (310) and
	`row` starts a new one. Settings a device doesn't offer (`shown`) are left out and the rest
	close up, so no page has holes.

	  main          Graphics (the preset, cycled), FOV; the other pages; Reset (the current
	                preset again) and Defaults (the device's defaults); Done closes the menu
	  video         render distance, detail falloff, full detail, cave view, plants, lichen
	                lights, shadows, far shadows, fog, textures, far materials, brightness,
	                distance or lighting
	  performance   far meshes, build budget, hidden terrain, swap frames
	  sounds        Music & Sounds: the volumes (master, music, blocks, players, ambient,
	                interface), footsteps, interface clicks, cave moods and music toasts
	  controls      FOV effects, sprint, the scroll wheel, touch buttons
	  hud           minimap, WAILA, GUI scale
	A sub-page's Done goes back to the main page. `status` lists the status lines a page shows
	(the controller's Settings.setStatus kinds).
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
			setting("fovEffects"),
			setting("toggleSprint"),
			setting("scrollHotbar"),
			setting("touchButtons"),
		},
		status = { "controls" },
	},
	{
		id = "hud",
		title = "HUD",
		items = {
			setting("minimap"),
			setting("waila"),
			setting("guiScale"),
		},
		status = {},
	},
} :: { Page }

local byId: { [string]: Page } = {}
for _, p in Pages.list do
	byId[p.id] = p
end
Pages.byId = byId

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

return Pages
