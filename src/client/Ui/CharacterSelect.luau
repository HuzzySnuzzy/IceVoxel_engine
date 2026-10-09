--!strict
--[[
	The title screen's character list (Terraria's Select Player, in Minecraft's Select World
	widgets), a page of Ui/MainMenu's scaled 320 x 240 canvas; the rules are Ui/CharacterRules,
	the server's side Players/CharacterStore.

	  List      the user's characters, last played first: two lines each (name in its
	            difficulty's colour, then difficulty, time played and the day: CharacterRules
	            .row), the highlighted one framed in white (a click; a double click plays it).
	            The highlighted character's R15 rig stands on the right (Ui/CharacterPreview: the
	            server builds "c<id>" on CharacterAction preview), turned by dragging.
	  Buttons   Play Selected Character, Create New Character, Rename, Delete and Back
	            (CharacterRules.buttons: Play needs a living character, nothing waits while a
	            request is out); what the server last said under the list, and in red when
	            characters last for this session only. The buttons and rows describe themselves
	            when hovered, selected or long pressed (Ui/HoverTip, Ui/ButtonHelp's "characters.*").
	  Gamepad   the rows, then the buttons (D-pad down from the last row).
	The page only draws and reports: Ui/MainMenu sends the requests (`onPlay`, `onCreate`,
	`onRename`, `onDelete`, `onBack`) except the previews, asked for here as rows are highlighted.
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local CharacterSync = require(Shared.Net.CharacterSync)
local Characters = require(Shared.Characters)
local Protocol = require(Shared.Net.Protocol)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local CharacterPreview = require(script.Parent.CharacterPreview)
local CharacterRules = require(script.Parent.CharacterRules)
local FormWidgets = require(script.Parent.FormWidgets)
local HoverTip = require(script.Parent.HoverTip)
local Style = require(script.Parent.Style)

local BUTTON_H = 20
local ROW = 24
local ROW_H = 30
local LIST_W = 186
local PREVIEW_W, PREVIEW_H = 118, 130
local WHITE = Color3.fromRGB(255, 255, 255)
local GRAY = Color3.fromRGB(160, 160, 160)
-- Seconds within which a second click on a row plays it.
local DOUBLE_CLICK = 0.4

export type Page = {
	frame: Frame,
	-- A new list from the server (and whether a request of this screen is out).
	setList: (self: Page, list: CharacterSync.List, busy: boolean) -> (),
	setBusy: (self: Page, busy: boolean) -> (),
	setMessage: (self: Page, text: string, colour: Color3?) -> (),
	highlighted: (self: Page) -> Characters.Summary?,
	-- The page is shown (`opened`: its preview asked for, the gamepad's selection placed).
	opened: (self: Page, gamepad: boolean) -> (),
	destroy: (self: Page) -> (),
	onPlay: ((summary: Characters.Summary) -> ())?,
	onCreate: (() -> ())?,
	onRename: ((summary: Characters.Summary) -> ())?,
	onDelete: ((summary: Characters.Summary) -> ())?,
	onBack: (() -> ())?,
}

local CharacterSelect = {}

-- Wrapped centred text with Minecraft's shadow; returns its setter.
local function infoText(parent: Instance, x: number, y: number, w: number, lines: number): (string, Color3?) -> ()
	local h = lines * (Style.TEXT_SIZE + 2)
	local label, shadow = Style.shadowText(parent, "", x, y, w, h, GRAY, 5, Enum.TextXAlignment.Center, Style.TEXT_SIZE)
	label.TextWrapped = true
	shadow.TextWrapped = true
	return function(text: string, colour: Color3?)
		label.Text = text
		shadow.Text = text
		if colour then
			label.TextColor3 = colour
			shadow.TextColor3 = Style.shadowOf(colour)
		end
	end
end

local function place(parent: Instance, position: UDim2, size: UDim2, z: number?): Frame
	local frame = Instance.new("Frame")
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Position = position
	frame.Size = size
	frame.ZIndex = z or 5
	frame.Parent = parent
	return frame
end

-- The page in `frame` (a page of the title screen's canvas).
function CharacterSelect.new(frame: Frame): Page
	local self = {
		frame = frame,
		onPlay = nil,
		onCreate = nil,
		onRename = nil,
		onDelete = nil,
		onBack = nil,
	}
	local title = FormWidgets.label(frame, "Select Character", 0, 0, 320, WHITE, "centre")
	title.frame.Position = UDim2.new(0.5, -160, 0, 6)
	local noteHolder = place(frame, UDim2.new(0.5, -160, 0, 16), UDim2.fromOffset(320, 10))
	local setNote = infoText(noteHolder, 0, 0, 320, 1)

	local list = Instance.new("ScrollingFrame")
	list.BackgroundTransparency = 0.5
	list.BackgroundColor3 = Color3.new(0, 0, 0)
	list.BorderSizePixel = 0
	list.Position = UDim2.new(0.5, -155, 0, 28)
	list.Size = UDim2.new(0, LIST_W, 1, -28 - 82)
	list.ScrollBarThickness = 4
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.ZIndex = 5
	list.Parent = frame
	local previewHolder = place(frame, UDim2.new(0.5, 155 - PREVIEW_W, 0, 28), UDim2.fromOffset(PREVIEW_W, PREVIEW_H))
	local preview = CharacterPreview.new(previewHolder, 0, 0, PREVIEW_W, PREVIEW_H, 5)
	local emptyHolder = place(previewHolder, UDim2.fromOffset(0, 0), UDim2.fromOffset(PREVIEW_W, PREVIEW_H), 8)
	local setEmpty = infoText(emptyHolder, 4, PREVIEW_H / 2 - 10, PREVIEW_W - 8, 2)

	local messageHolder = place(frame, UDim2.new(0.5, -160, 1, -78), UDim2.fromOffset(320, 22))
	local setMessage = infoText(messageHolder, 0, 0, 320, 2)
	local footer = place(frame, UDim2.new(0.5, -155, 1, -52), UDim2.fromOffset(310, ROW + BUTTON_H))
	local playButton = FormWidgets.button(footer, "Play Selected Character", 0, 0, 150, BUTTON_H)
	local createButton = FormWidgets.button(footer, "Create New Character", 160, 0, 150, BUTTON_H)
	local renameButton = FormWidgets.button(footer, "Rename", 0, ROW, 72, BUTTON_H)
	local deleteButton = FormWidgets.button(footer, "Delete", 78, ROW, 72, BUTTON_H)
	local backButton = FormWidgets.button(footer, "Back", 160, ROW, 150, BUTTON_H)
	HoverTip.attach(playButton.button, "characters.play")
	HoverTip.attach(createButton.button, "characters.create")
	HoverTip.attach(renameButton.button, "characters.rename")
	HoverTip.attach(deleteButton.button, "characters.delete")
	HoverTip.attach(backButton.button, "characters.back")
	local buttonOrder: { GuiObject } =
		{ playButton.button, createButton.button, renameButton.button, deleteButton.button, backButton.button }

	local current: CharacterSync.List? = nil
	local highlight: number? = nil
	local busy = false
	local rows: { TextButton } = {}
	local lastClick = { id = 0, at = -math.huge }

	local function summaries(): { Characters.Summary }
		local listNow = current
		return if listNow then listNow.characters else {}
	end

	local function chosen(): Characters.Summary?
		return CharacterRules.find(summaries(), highlight)
	end

	local function refresh()
		local listNow = current
		local buttons = CharacterRules.buttons(summaries(), highlight, busy, if listNow then listNow.max else nil)
		playButton:setEnabled(buttons.play)
		createButton:setEnabled(buttons.create)
		renameButton:setEnabled(buttons.rename)
		deleteButton:setEnabled(buttons.delete)
		backButton:setEnabled(buttons.back)
		setNote(
			if listNow and not listNow.saving then "Characters last for this session only" else "",
			Style.Colour.Red
		)
	end

	-- Shows the highlighted character's rig (asked of the server: it builds it once).
	local function showPreview()
		local summary = chosen()
		if summary == nil then
			preview:show(nil)
			setEmpty(if #summaries() == 0 then "No characters yet: create one" else "", GRAY)
			return
		end
		setEmpty("")
		preview:show(`c{summary.id}`)
		ClientNet.send(
			Protocol.ClientMessage.CharacterAction,
			CharacterSync.encodeAction({ action = CharacterSync.Action.Preview, id = summary.id })
		)
	end

	local function buildRows()
		for _, row in rows do
			row:Destroy()
		end
		table.clear(rows)
		local y = 2
		for _, summary in summaries() do
			local picked = summary.id == highlight
			local line1, line2 = CharacterRules.row(summary, os.date("*t", math.floor(summary.lastPlayed)) :: any)
			local rgb = CharacterRules.colour(summary)
			local row = Instance.new("TextButton")
			row.Name = `c{summary.id}`
			row.Text = ""
			row.AutoButtonColor = false
			row.BackgroundTransparency = if picked then 0 else 1
			row.BackgroundColor3 = WHITE
			row.BorderSizePixel = 0
			row.Position = UDim2.fromOffset(2, y)
			row.Size = UDim2.fromOffset(LIST_W - 8, ROW_H - 2)
			row.ZIndex = 6
			row.SelectionImageObject = Style.selectionImage
			row.Parent = list
			HoverTip.attach(row, "characters.row")
			local inside = Style.frame(row, 1, 1, LIST_W - 10, ROW_H - 4, Color3.new(0, 0, 0), 6)
			inside.BackgroundTransparency = if picked then 0 else 1
			Style.shadowText(row, line1, 4, 3, LIST_W - 16, 10, Color3.fromRGB(rgb[1], rgb[2], rgb[3]), 7)
			Style.shadowText(row, line2, 4, 15, LIST_W - 16, 10, GRAY, 7)
			row.Activated:Connect(function()
				local now = os.clock()
				local again = lastClick.id == summary.id and now - lastClick.at < DOUBLE_CLICK
				lastClick.id, lastClick.at = summary.id, now
				if highlight ~= summary.id then
					SoundPlayer.click()
					highlight = summary.id
					buildRows()
					refresh()
					showPreview()
				elseif again and not summary.dead and not busy then
					local play = (self :: any).onPlay
					if play then
						play(summary)
					end
				end
			end)
			table.insert(rows, row)
			y += ROW_H
		end
		list.CanvasSize = UDim2.fromOffset(0, y + 2)
		-- Gamepad: the rows, then the buttons.
		for i, row in rows do
			row.NextSelectionUp = rows[i - 1] or row
			row.NextSelectionDown = rows[i + 1] or playButton.button
		end
		local last = rows[#rows]
		for _, object in buttonOrder do
			object.NextSelectionUp = last or object
		end
	end

	function self.setList(_: Page, list: CharacterSync.List, isBusy: boolean)
		current = list
		busy = isBusy
		local before = highlight
		highlight = CharacterRules.keepHighlight(list.characters, highlight, list.selected)
		buildRows()
		refresh()
		-- (Rigs are asked for only while the list shows: `opened` asks when it is shown.)
		if frame.Visible and (highlight ~= before or preview:model() == nil) then
			showPreview()
		end
	end

	function self.setBusy(_: Page, isBusy: boolean)
		busy = isBusy
		refresh()
	end

	function self.setMessage(_: Page, text: string, colour: Color3?)
		setMessage(text, colour or GRAY)
	end

	function self.highlighted(_: Page): Characters.Summary?
		return chosen()
	end

	function self.opened(_: Page, gamepad: boolean)
		refresh()
		showPreview()
		if gamepad then
			GuiService.SelectedObject = rows[1] or createButton.button
		end
	end

	function self.destroy(_: Page)
		preview:destroy()
	end

	local function call(name: string, withSummary: boolean)
		return function()
			SoundPlayer.click()
			local fn = (self :: any)[name]
			if fn == nil then
				return
			end
			if withSummary then
				local summary = chosen()
				if summary then
					fn(summary)
				end
			else
				fn()
			end
		end
	end
	playButton.clicked = call("onPlay", true)
	createButton.clicked = call("onCreate", false)
	renameButton.clicked = call("onRename", true)
	deleteButton.clicked = call("onDelete", true)
	backButton.clicked = call("onBack", false)
	refresh()
	return (self :: any) :: Page
end

return CharacterSelect
