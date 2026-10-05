--!strict
--[[
	The spectator menu's model: Minecraft 1.20.1's SpectatorMenu with its categories, and the
	SpectatorGui state around it (opening, the selection, fading out). Pure, so the tests run it;
	Ui/SpectatorGui draws it in the hotbar's place and feeds it the keys, the wheel and the clock.

	  opening    a number key or the middle click opens the root page (nothing selected yet)
	  number     selects that slot; the same number again uses it (selectSlot). Middle click uses
	             the selected slot. The wheel moves the selection, skipping empty and disabled
	             slots (onMouseScrolled).
	  root       1 "Teleport to Player" (enabled while someone can be teleported to). Minecraft's
	             "Teleport to Team Member" is left out: the game has no teams.
	  players    the other players who are not spectating, by user id, as they were when the menu
	             opened (TeleportToPlayerMenuCategory): slots 1-7 on the first page, then 6 a page
	             after "Previous Page" in slot 1. Using one teleports there (SpectatorTeleport).
	  8          "Next Page" (dimmed on the last page); 9 "Close Menu" on every page.
	  fading     the menu shows for 3 seconds after the last key, fades over 2 more and then closes
	             (getHotbarAlpha). Closing forgets the page and the selection.

	Slots are numbered 0..8 here, as in Minecraft (number key 1 is slot 0).
]]

local SpectatorMenu = {}

-- Minecraft's texts (en_us: spectatorMenu.*).
SpectatorMenu.ROOT_PROMPT = "Press a key to select a command, and again to use it."
SpectatorMenu.TELEPORT = "Teleport to Player"
SpectatorMenu.TELEPORT_PROMPT = "Select a player to teleport to"
SpectatorMenu.PREVIOUS_PAGE = "Previous Page"
SpectatorMenu.NEXT_PAGE = "Next Page"
SpectatorMenu.CLOSE = "Close Menu"

SpectatorMenu.SLOTS = 9
-- Items on the first page; later pages lose slot 0 to "Previous Page" (getItem: i + page * 6).
SpectatorMenu.PER_PAGE = 6
-- Seconds the menu stays after the last key, then fades over FADE (5000 ms, / 2000 ms).
SpectatorMenu.SHOWN = 5
SpectatorMenu.FADE = 2

export type Player = { userId: number, name: string }

export type ItemKind = "teleport" | "player" | "previous" | "next" | "close" | "empty"

export type Item = {
	kind: ItemKind,
	-- Shown over the menu while selected (empty slots: none).
	name: string,
	-- Disabled items are drawn dimmed, can be selected but not used, and the wheel skips them.
	enabled: boolean,
	-- The player of a "player" item.
	player: Player?,
}

export type Category = "root" | "teleport"

export type Menu = {
	category: Category,
	page: number,
	-- The selected slot, 0..8 (-1: none).
	selected: number,
	-- Whom "Teleport to Player" lists.
	players: { Player },
}

export type Gui = {
	-- The open menu (nil: closed).
	menu: Menu?,
	-- When a key last changed it (seconds).
	lastSelection: number,
}

-- What using an item asks the game to do (only teleporting leaves the menu).
export type Action = { kind: "teleport", userId: number }

local EMPTY: Item = table.freeze({ kind = "empty" :: ItemKind, name = "", enabled = false, player = nil })
local CLOSE: Item =
	table.freeze({ kind = "close" :: ItemKind, name = SpectatorMenu.CLOSE, enabled = true, player = nil })
local PREVIOUS: Item =
	table.freeze({ kind = "previous" :: ItemKind, name = SpectatorMenu.PREVIOUS_PAGE, enabled = true, player = nil })

SpectatorMenu.EMPTY = EMPTY

--[[
	Whom the teleport page lists: `players` (everyone in the game, with their game mode) without
	`selfId` and spectators, by user id (Minecraft sorts by profile id).
]]
function SpectatorMenu.targets(
	players: { { userId: number, name: string, spectator: boolean } },
	selfId: number
): { Player }
	local list: { Player } = {}
	for _, p in players do
		if p.userId ~= selfId and not p.spectator then
			table.insert(list, { userId = p.userId, name = p.name })
		end
	end
	table.sort(list, function(a, b)
		return a.userId < b.userId
	end)
	return list
end

-- The items of a category, in order.
local function categoryItems(menu: Menu): { Item }
	if menu.category == "root" then
		return { { kind = "teleport", name = SpectatorMenu.TELEPORT, enabled = #menu.players > 0, player = nil } }
	end
	local items: { Item } = {}
	for _, p in menu.players do
		table.insert(items, { kind = "player", name = p.name, enabled = true, player = p })
	end
	return items
end

-- The item in `slot` (0..8) on the menu's page (SpectatorMenu.getItem).
function SpectatorMenu.item(menu: Menu, slot: number): Item
	if slot < 0 or slot >= SpectatorMenu.SLOTS then
		return EMPTY
	end
	local items = categoryItems(menu)
	local index = slot + menu.page * SpectatorMenu.PER_PAGE
	if menu.page > 0 and slot == 0 then
		return PREVIOUS
	elseif slot == 7 then
		return { kind = "next", name = SpectatorMenu.NEXT_PAGE, enabled = index < #items, player = nil }
	elseif slot == 8 then
		return CLOSE
	elseif index >= 0 and index < #items then
		return items[index + 1]
	end
	return EMPTY
end

-- The nine items shown.
function SpectatorMenu.items(menu: Menu): { Item }
	local list = {}
	for slot = 0, SpectatorMenu.SLOTS - 1 do
		list[slot + 1] = SpectatorMenu.item(menu, slot)
	end
	return list
end

-- The line over the menu: the selected item's name, or the page's prompt with nothing selected.
function SpectatorMenu.label(menu: Menu): string
	local item = SpectatorMenu.item(menu, menu.selected)
	if item.kind ~= "empty" then
		return item.name
	end
	return if menu.category == "root" then SpectatorMenu.ROOT_PROMPT else SpectatorMenu.TELEPORT_PROMPT
end

function SpectatorMenu.newGui(): Gui
	return { menu = nil, lastSelection = 0 }
end

-- Opens the root page (a new SpectatorMenu), listing `players` (SpectatorMenu.targets).
function SpectatorMenu.open(gui: Gui, players: { Player }, now: number)
	gui.menu = { category = "root", page = 0, selected = -1, players = players }
	gui.lastSelection = now
end

-- Closes the menu (onSpectatorMenuClosed).
function SpectatorMenu.close(gui: Gui)
	gui.menu = nil
	gui.lastSelection = 0
end

function SpectatorMenu.isOpen(gui: Gui): boolean
	return gui.menu ~= nil
end

-- Uses `item` (SpectatorMenuItem.selectItem).
local function use(gui: Gui, menu: Menu, item: Item): Action?
	if item.kind == "teleport" then
		-- (selectCategory: the first page, nothing selected.)
		menu.category = "teleport"
		menu.page = 0
		menu.selected = -1
	elseif item.kind == "previous" then
		menu.page -= 1
	elseif item.kind == "next" then
		menu.page += 1
	elseif item.kind == "close" then
		SpectatorMenu.close(gui)
	elseif item.kind == "player" and item.player then
		return { kind = "teleport", userId = item.player.userId }
	end
	return nil
end

-- Selects `slot`, or uses it when it was selected already and is enabled (selectSlot).
local function selectSlot(gui: Gui, menu: Menu, slot: number): Action?
	local item = SpectatorMenu.item(menu, slot)
	if item.kind == "empty" then
		return nil
	end
	if menu.selected == slot and item.enabled then
		return use(gui, menu, item)
	end
	menu.selected = slot
	return nil
end

-- Number key `slot` (0..8): opens the menu, or selects / uses that slot (onHotbarSelected).
function SpectatorMenu.hotbarKey(gui: Gui, slot: number, players: { Player }, now: number): Action?
	gui.lastSelection = now
	local menu = gui.menu
	if menu == nil then
		SpectatorMenu.open(gui, players, now)
		return nil
	end
	return selectSlot(gui, menu, slot)
end

-- The middle click: opens the menu, or uses the selected slot (onMouseMiddleClick).
function SpectatorMenu.middleClick(gui: Gui, players: { Player }, now: number): Action?
	gui.lastSelection = now
	local menu = gui.menu
	if menu == nil then
		SpectatorMenu.open(gui, players, now)
		return nil
	end
	if menu.selected ~= -1 then
		return selectSlot(gui, menu, menu.selected)
	end
	return nil
end

--[[
	The wheel while the menu is open: `direction` +1 moves the selection right (Minecraft passes
	the wheel turned down), -1 left, to the next slot that holds an enabled item (onMouseScrolled).
]]
function SpectatorMenu.scroll(gui: Gui, direction: number, now: number)
	local menu = gui.menu
	if menu == nil or direction == 0 then
		return
	end
	local step = if direction > 0 then 1 else -1
	local slot = menu.selected + step
	while slot >= 0 and slot < SpectatorMenu.SLOTS do
		local item = SpectatorMenu.item(menu, slot)
		if item.kind ~= "empty" and item.enabled then
			break
		end
		slot += step
	end
	if slot >= 0 and slot < SpectatorMenu.SLOTS then
		selectSlot(gui, menu, slot)
		gui.lastSelection = now
	end
end

-- How opaque the menu is drawn (0..1): full for SHOWN - FADE seconds, then fading (getHotbarAlpha).
function SpectatorMenu.alpha(gui: Gui, now: number): number
	if gui.menu == nil then
		return 0
	end
	return math.clamp((gui.lastSelection - now + SpectatorMenu.SHOWN) / SpectatorMenu.FADE, 0, 1)
end

-- Once a frame: a menu that has faded away closes (renderHotbar).
function SpectatorMenu.update(gui: Gui, now: number)
	if gui.menu ~= nil and SpectatorMenu.alpha(gui, now) <= 0 then
		SpectatorMenu.close(gui)
	end
end

return SpectatorMenu
