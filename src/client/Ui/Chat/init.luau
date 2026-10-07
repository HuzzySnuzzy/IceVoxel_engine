--!strict
--[[
	The chat: Minecraft 1.20.1's chat (ChatComponent, ChatScreen, CommandSuggestions, ChatListener)
	in place of Roblox's chat window and input bar, which are turned off. Everything players say
	goes through TextChatService, so Roblox filters it: sent with TextChannel:SendAsync, shown from
	TextChatService.MessageReceived (the text filtered for this player).

	  Opening   the key bindings' "chat" and "command" (Settings/Keybinds, Minecraft's key.chat and
	            key.command: T and / by default): "chat" opens an empty box, "command" one with "/"
	            typed (no screen, the game mode switcher or Roblox's menu open, no other text box
	            focused); the HUD's touch chat
	            button (Hud.onChatButton) opens and closes it. With the Chat setting on Hidden it
	            does not open: "Chat disabled in client options." shows above the hotbar instead
	            (Minecraft's overlay message, 3 s).
	  Lines     bottom left, their bottom 40 GUI pixels above the screen's bottom, newest at the
	            bottom (Ui/Chat/ChatLog: 100 kept, wrapped to the Width setting, fading 10 s after
	            arriving, all shown while the box is open, scrolled with the wheel: 7 lines a notch,
	            Shift 1, Page Up / Down). Each line has Minecraft's black background (Text
	            Background) and shadowed text in the pixel font (Ui/Chat/ChatFormat's colours:
	            players white "<Name> message", joins yellow, errors red...). "[+N pending lines]"
	            while Chat Delay holds messages back. While open a scroll bar shows beside them
	            when they don't all fit (red once a message arrived while scrolled up).
	  Box       Minecraft's: across the bottom of the screen, half transparent. Enter sends (and
	            closes), Escape closes, Up / Down go through what was sent (Ui/Chat/ChatInput), Tab
	            completes command names and players' names, and while a command's name is typed its
	            suggestions show above the box (the Command Suggestions setting; Up / Down move
	            the highlight, Tab uses it); both offer only the commands this player may use
	            (WorldSettings.mayRun: operators, Allow Commands, the game mode permission, as
	            the server marks its commands). Typed text never reaches the game's keys: every key
	            handler ignores input a text box took (gameProcessedEvent, or GetFocusedTextBox),
	            the player stands still (Player/MovementController), the hotbar's keys and wheel do
	            nothing (Hud.setInputTaken), the mouse is free on computers and a click beside
	            the box keeps it focused (Minecraft's chat is a screen of its own); on touch a tap
	            elsewhere closes it, and box and lines move above the on-screen keyboard.
	  Sending   ChatInput.resolve: text is sent to the general channel (RBXGeneral, or the channel
	            Roblox's /whisper or /team pointed the box at: Backspace in an empty box goes back);
	            a command ("/...") whose name a TextChatCommand has (the server's /time, /gamemode,
	            /summon, /effect, /knowledge, /age..., Roblox's /whisper, /team, /e...) is sent too,
	            and TextChatService runs it and shows it to no one; any other command is not sent:
	            Minecraft's red "Unknown or incomplete command" lines. Plain text is refused with
	            Chat on Commands Only ("Cannot send chat message"), and when Roblox says this
	            account may not chat (its TextSource can't send: "Chat not allowed by account
	            settings."); what Roblox refuses after sending says why (too fast, too long...).
	  Receiving players' messages "<Name> message" (display names), Roblox's whispers and team
	            messages as Minecraft's, Roblox's system messages in gray; the server's notices
	            (Net/Notices: command feedback, Age announcements, saved structures, F3 + Q) in
	            white at once (Notices.setSink); "Name joined the game" / "Name left the game" in
	            yellow from Players.PlayerAdded / PlayerRemoving (this player's own join too).
	            The Chat setting drops what it doesn't show (Commands Only: other players' talk;
	            Hidden: everything), as Minecraft's server does not send it. Roblox's /clear
	            (RBXClearCommand) clears the lines.
	  Settings  `applySettings` (the "chat" settings effect): visibility, text and background
	            opacity, text size, line spacing, delay, width, focused / unfocused height,
	            command suggestions (Ui/Chat/ChatLog.metrics).
	  Legacy    with the legacy chat (TextChatService.ChatVersion LegacyChatService) nothing here
	            starts: Roblox's chat stays, and Net/Notices shows notices there.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)
local WorldSettings = require(Shared.WorldSettings)

local Notices = require(script.Parent.Parent.Net.Notices)
local Keybinds = require(script.Parent.Parent.Settings.Keybinds)
local GameModeSwitcher = require(script.Parent.GameModeSwitcher)
local Hud = require(script.Parent.Hud)
local Screens = require(script.Parent.Screens)
local Style = require(script.Parent.Style)
local ChatFormat = require(script.ChatFormat)
local ChatInput = require(script.ChatInput)
local ChatLog = require(script.ChatLog)

type Message = ChatFormat.Message

-- Layout (GUI pixels): the lines' bottom above the screen's bottom (ChatComponent: height - 40),
-- the box's strip (ChatScreen: a 12 pixel background 2 above the bottom, text 4 into it), the
-- suggestions' rows (12 high, 3 above the box), the overlay message (height - 68).
local CHAT_BOTTOM = 40
local BOX_STRIP = 14
local BOX_BACK_H = 12
local BOX_TEXT_Y = 4
local SUGGESTION_ROW = 12
local SUGGESTION_GAP = 3
local OVERLAY_Y = 68
-- Minecraft's overlay message shows 3 s, fading over the last one.
local OVERLAY_TIME = 3
local OVERLAY_FADE = 1
-- The HUD's content (Ui/Hud: the hotbar), so the chat uses the HUD's GUI scale.
local HUD_W, HUD_H = 182, 70
-- Colours: the box's text (EditBox #E0E0E0), its background (black at 50%), the suggestion list's
-- (#D0000000), the scroll bar's (blue, red after a new message; its light edge).
local BOX_TEXT = Color3.fromRGB(224, 224, 224)
local BOX_BACK_TRANSPARENCY = 0.5
local SUGGESTION_BACK_TRANSPARENCY = 1 - 0xD0 / 255
local BAR_BLUE = Color3.fromRGB(51, 51, 170)
local BAR_RED = Color3.fromRGB(204, 51, 51)
local BAR_EDGE = Color3.fromRGB(204, 204, 204)
-- Text widths remembered (per string) before the cache starts over.
local MEASURE_CACHE = 4096
-- Message ids remembered so one never shows twice.
local SEEN_IDS = 64
-- Seconds to look for Roblox's chat window and bar to turn them off.
local CONFIG_WAIT = 30
local MOUSE_STEP = "IceVoxelChatMouse"

type Row = {
	back: Frame,
	label: TextLabel,
	shadow: TextLabel,
	line: ChatLog.Line?,
	-- The strength the row was last drawn at (-1: redraw).
	alpha: number,
}

local Chat = {}

local started = false
local player = Players.LocalPlayer
local metrics: ChatLog.Metrics = ChatLog.metrics({})

-- Text widths in GUI pixels at the chat's text size (Style.textWidth), remembered.
local widths: { [string]: number } = {}
local widthCount = 0
local function measure(text: string): number
	local width = widths[text]
	if width == nil then
		if widthCount >= MEASURE_CACHE then
			table.clear(widths)
			widthCount = 0
		end
		width = Style.textWidth(text)
		widths[text] = width
		widthCount += 1
	end
	return width
end

local log = ChatLog.new(measure, ChatLog.wrapWidth(metrics))
local history = ChatInput.newHistory()
local open = false
local suggestions: ChatInput.Suggestions? = nil

-- Set by start.
local openImpl: (prefill: string) -> () = function() end
local closeImpl: () -> () = function() end
local relayout: () -> () = function() end

--[[ Public ]]

-- Is the chat box open?
function Chat.isOpen(): boolean
	return open
end

-- Opens the box with `prefill` typed ("" or "/").
function Chat.open(prefill: string?)
	openImpl(prefill or "")
end

function Chat.close()
	closeImpl()
end

-- Shows `message` (a ChatFormat message) if the Chat setting shows its kind.
function Chat.add(message: Message)
	if ChatFormat.shows(message.kind, metrics.visibility) then
		ChatLog.add(log, message, os.clock())
	end
end

-- The Chat Settings changed (the "chat" settings effect).
function Chat.applySettings(values: { [string]: number })
	metrics = ChatLog.metrics(values)
	ChatLog.setDelay(log, metrics.delay, os.clock())
	relayout()
end

--[[ TextChatService ]]

-- The general channel (nil until TextChatService made it; nil for good without default channels).
local function generalChannel(): TextChannel?
	local channels = TextChatService:FindFirstChild("TextChannels")
	local general = channels and channels:FindFirstChild("RBXGeneral")
	return if general and general:IsA("TextChannel") then general else nil
end

local function inputBar(): ChatInputBarConfiguration?
	return TextChatService:FindFirstChildOfClass("ChatInputBarConfiguration")
end

-- Where typed text goes: the channel Roblox's /whisper or /team set, else the general one.
local function targetChannel(): TextChannel?
	local bar = inputBar()
	local target = bar and bar.TargetTextChannel
	if target and target.Parent ~= nil then
		return target
	end
	return generalChannel()
end

-- The display name of a user id (the TextSource's name if they left).
local function nameOf(userId: number, fallback: string): string
	local other = Players:GetPlayerByUserId(userId)
	return if other then other.DisplayName else fallback
end

-- The other player of a whisper channel.
local function partnerOf(channel: TextChannel): string?
	for _, child in channel:GetChildren() do
		if child:IsA("TextSource") and child.UserId ~= player.UserId then
			return nameOf(child.UserId, child.Name)
		end
	end
	return nil
end

-- May this player chat in `channel` (Roblox's privacy settings: its TextSource's CanSend)?
local function canChat(channel: TextChannel): boolean
	for _, child in channel:GetChildren() do
		if child:IsA("TextSource") and child.UserId == player.UserId then
			return child.CanSend
		end
	end
	-- (Not in it yet: SendAsync says.)
	return true
end

-- Every TextChatCommand's aliases, and who may use each (WorldSettings.COMMAND_ATTRIBUTE),
-- remembered until commands come or go.
local aliasCache: { string }? = nil
local aliasLevels: { [string]: unknown } = {}
local function commandAliases(): { string }
	local cached = aliasCache
	if cached then
		return cached
	end
	local list: { string } = {}
	table.clear(aliasLevels)
	for _, instance in TextChatService:GetDescendants() do
		if instance:IsA("TextChatCommand") and instance.Enabled then
			local level = instance:GetAttribute(WorldSettings.COMMAND_ATTRIBUTE)
			table.insert(list, instance.PrimaryAlias)
			aliasLevels[instance.PrimaryAlias] = level
			if instance.SecondaryAlias ~= "" then
				table.insert(list, instance.SecondaryAlias)
				aliasLevels[instance.SecondaryAlias] = level
			end
		end
	end
	aliasCache = list
	return list
end

--[[
	The aliases this player may use (WorldSettings.mayRun: operator, the world's Allow Commands,
	their own game mode permission), for Tab and the suggestions: as Minecraft's client knows only
	the commands its permission level allows. Sending still knows every command (the server
	answers one the player may not use).
]]
local function usableAliases(): { string }
	local access: WorldSettings.Access = {
		operator = player:GetAttribute(WorldSettings.OPERATOR_ATTRIBUTE) == true,
		allowCommands = Shared:GetAttribute("AllowCommands") == true,
		gameMode = player:GetAttribute(GameMode.PERMISSION_ATTRIBUTE) == true,
	}
	local usable: { string } = {}
	for _, alias in commandAliases() do
		if WorldSettings.mayRun(aliasLevels[alias], access) then
			table.insert(usable, alias)
		end
	end
	return usable
end

-- Players' names and display names, for Tab.
local function playerNames(): { string }
	local names = {}
	for _, other in Players:GetPlayers() do
		table.insert(names, other.Name)
		if other.DisplayName ~= other.Name then
			table.insert(names, other.DisplayName)
		end
	end
	return names
end

local function addError(text: string)
	Chat.add(ChatFormat.error(text))
end

-- Sends what the box held (normalized, not empty).
local function send(text: string)
	local kind, out = ChatInput.resolve(text, ChatInput.aliasMap(commandAliases()))
	if kind == "unknown" then
		for _, message in ChatFormat.unknownCommand(text) do
			Chat.add(message)
		end
		return
	end
	local found = if kind == "command" then generalChannel() else targetChannel()
	if found == nil then
		addError(ChatFormat.UNAVAILABLE)
		return
	end
	local channel: TextChannel = found
	if kind == "chat" then
		if metrics.visibility >= ChatFormat.COMMANDS_ONLY then
			addError(ChatFormat.CANNOT_SEND)
			return
		elseif not canChat(channel) then
			addError(ChatFormat.DISABLED_PROFILE)
			return
		end
	end
	task.spawn(function()
		local ok, result = pcall(function()
			return channel:SendAsync(out)
		end)
		if not ok then
			warn(`[IceVoxel] chat: sending failed: {result}`)
			addError(ChatFormat.STATUS_TEXT.Unknown)
			return
		end
		-- (Commands answer through the server's notices; only chat says why it didn't go.)
		if kind == "chat" and typeof(result) == "Instance" and result:IsA("TextChatMessage") then
			local why = ChatFormat.statusText(result.Status.Name)
			if why then
				addError(why)
			end
		end
	end)
end

-- Turns Roblox's chat window, tabs and input bar off (they appear a moment after joining).
local function hideRobloxChat()
	for _, className in { "ChatWindowConfiguration", "ChatInputBarConfiguration", "ChannelTabsConfiguration" } do
		task.spawn(function()
			local deadline = os.clock() + CONFIG_WAIT
			repeat
				local config = TextChatService:FindFirstChildOfClass(className)
				if config then
					pcall(function()
						(config :: any).Enabled = false
					end)
					return
				end
				task.wait(0.5)
			until os.clock() > deadline
		end)
	end
end

--[[ Start ]]

function Chat.start()
	if started then
		return
	end
	if TextChatService.ChatVersion == Enum.ChatVersion.LegacyChatService then
		warn("[IceVoxel] the legacy chat is on: the game's chat needs TextChatService and stays off")
		return
	end
	started = true
	hideRobloxChat()

	local gui = Instance.new("ScreenGui")
	gui.Name = "IceVoxelChat"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- (Under the screens' darkened backdrop, 9, as Minecraft draws the chat under a screen.)
	gui.DisplayOrder = 8

	-- While open, clicks beside the box land here (not in the world) and the mouse is free.
	local catcher = Instance.new("TextButton")
	catcher.Name = "Catcher"
	catcher.Text = ""
	catcher.AutoButtonColor = false
	catcher.BackgroundTransparency = 1
	catcher.Size = UDim2.fromScale(1, 1)
	catcher.Selectable = false
	catcher.Visible = false
	catcher.ZIndex = 1
	catcher.Parent = gui

	-- The lines, in chat units (GUI pixels divided by the text size).
	local lines = Instance.new("Frame")
	lines.Name = "Lines"
	lines.BackgroundTransparency = 1
	lines.AnchorPoint = Vector2.new(0, 1)
	lines.ZIndex = 2
	lines.Parent = gui
	local linesScale = Instance.new("UIScale")
	linesScale.Parent = lines
	local barFill = Style.frame(lines, 0, 0, 2, 0, BAR_BLUE, 6)
	local barEdge = Style.frame(lines, 0, 0, 1, 0, BAR_EDGE, 7)
	barFill.Visible, barEdge.Visible = false, false
	local pendingBack = Style.frame(lines, 0, 0, 0, 9, Color3.new(0, 0, 0), 4)
	pendingBack.Visible = false
	local pendingLabel = Style.text(pendingBack, "", 2, 1, 300, 8, Style.Colour.Text, 5)

	-- The box and its suggestions, in GUI pixels.
	local strip = Instance.new("Frame")
	strip.Name = "Box"
	strip.BackgroundTransparency = 1
	strip.AnchorPoint = Vector2.new(0, 1)
	strip.Visible = false
	strip.ZIndex = 3
	strip.Parent = gui
	local stripScale = Instance.new("UIScale")
	stripScale.Parent = strip
	local boxBack = Style.frame(strip, 2, 0, 0, BOX_BACK_H, Color3.new(0, 0, 0), 1)
	boxBack.BackgroundTransparency = BOX_BACK_TRANSPARENCY
	local box = Instance.new("TextBox")
	box.Name = "ChatBox"
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.Position = UDim2.fromOffset(4, BOX_TEXT_Y)
	box.ClearTextOnFocus = false
	box.MultiLine = false
	box.ClipsDescendants = true
	box.Font = Style.FONT
	box.TextSize = Style.TEXT_SIZE
	box.TextColor3 = BOX_TEXT
	box.PlaceholderColor3 = Style.Colour.Gray
	box.PlaceholderText = ""
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.TextYAlignment = Enum.TextYAlignment.Top
	box.Text = ""
	box.ZIndex = 2
	box.Parent = strip

	local list = Style.frame(strip, 0, 0, 0, 0, Color3.new(0, 0, 0), 4)
	list.BackgroundTransparency = SUGGESTION_BACK_TRANSPARENCY
	list.Visible = false
	local listRows: { { label: TextLabel, shadow: TextLabel } } = {}
	for i = 1, ChatInput.SUGGESTION_ROWS do
		local label, shadow = Style.shadowText(list, "", 1, 2 + (i - 1) * SUGGESTION_ROW, 400, 8, Style.Colour.Gray, 5)
		listRows[i] = { label = label, shadow = shadow }
	end

	-- Minecraft's overlay message (above the hotbar, centred).
	local overlay = Instance.new("Frame")
	overlay.Name = "Overlay"
	overlay.BackgroundTransparency = 1
	overlay.AnchorPoint = Vector2.new(0.5, 1)
	overlay.Size = UDim2.fromOffset(400, 8)
	overlay.Visible = false
	overlay.ZIndex = 5
	overlay.Parent = gui
	local overlayScale = Instance.new("UIScale")
	overlayScale.Parent = overlay
	local overlayLabel, overlayShadow =
		Style.shadowText(overlay, "", 0, 0, 400, 8, Style.Colour.Red, 1, Enum.TextXAlignment.Center)
	local overlayUntil = 0

	local function showOverlay(text: string)
		overlayLabel.Text = text
		overlayShadow.Text = text
		overlayUntil = os.clock() + OVERLAY_TIME
	end

	--[[ Drawing ]]

	local rows: { Row } = {}
	-- The lines' background width (chat units: Minecraft's ceil(width / scale) + 12).
	local backWidth = 0
	local dirty = true
	local drawnVersion = -1
	local wasActive = false
	local keyboardInset = 0

	local function rowAt(index: number): Row
		local row = rows[index]
		if row == nil then
			local back = Style.frame(lines, 0, 0, 0, 0, Color3.new(0, 0, 0), 1)
			back.Visible = false
			local shadow = Style.text(back, "", 5, 0, 0, 8, Style.Colour.Text, 2)
			local label = Style.text(back, "", 4, 0, 0, 8, Style.Colour.Text, 3)
			shadow.RichText = true
			label.RichText = true
			row = { back = back, label = label, shadow = shadow, line = nil, alpha = -1 }
			rows[index] = row
		end
		return row
	end

	-- Places the rows for the page and the metrics (after a layout change).
	local function placeRows()
		local page = log.page
		local lineHeight = metrics.lineHeight
		local height = page * lineHeight
		local textWidth = backWidth - 12
		for index = 1, math.max(page, #rows) do
			local row = rowAt(index)
			local s = index - 1
			row.back.Position = UDim2.fromOffset(0, height - (s + 1) * lineHeight)
			row.back.Size = UDim2.fromOffset(backWidth, lineHeight)
			row.label.Position = UDim2.fromOffset(4, lineHeight + metrics.textOffset)
			row.label.Size = UDim2.fromOffset(textWidth, 8)
			row.shadow.Position = UDim2.fromOffset(5, lineHeight + metrics.textOffset + 1)
			row.shadow.Size = UDim2.fromOffset(textWidth, 8)
			row.alpha = -1
			if index > page then
				row.back.Visible = false
				row.line = nil
			end
		end
		lines.Size = UDim2.fromOffset(backWidth, height)
		pendingBack.Position = UDim2.fromOffset(2, height)
		pendingBack.Size = UDim2.fromOffset(backWidth - 4, 9)
	end

	local function draw(now: number)
		local textOpacity, backOpacity = metrics.textOpacity, metrics.backgroundOpacity
		for index = 1, log.page do
			local row = rowAt(index)
			local line, factor = ChatLog.row(log, index - 1, now)
			local alpha = factor * textOpacity
			local shown = line ~= nil and alpha > ChatLog.MIN_ALPHA
			if shown and line then
				if row.line ~= line then
					row.line = line
					row.label.Text = line.rich
					row.shadow.Text = line.shadow
				end
				if row.alpha ~= factor then
					row.alpha = factor
					row.label.TextTransparency = 1 - alpha
					row.shadow.TextTransparency = 1 - alpha
					row.back.BackgroundTransparency = 1 - factor * backOpacity
				end
			end
			if row.back.Visible ~= shown then
				row.back.Visible = shown
			end
		end
		-- The scroll bar (open, more lines than rows).
		local bottom, size, bright, red = ChatLog.scrollBar(log)
		if bottom then
			local lineHeight = metrics.lineHeight
			local height = log.page * lineHeight
			local transparency = 1 - (if bright then 170 else 96) / 255
			local top = height - (bottom + size) * lineHeight
			barFill.Position = UDim2.fromOffset(backWidth - 4, top)
			barFill.Size = UDim2.fromOffset(2, size * lineHeight)
			barFill.BackgroundColor3 = if red then BAR_RED else BAR_BLUE
			barFill.BackgroundTransparency = transparency
			barEdge.Position = UDim2.fromOffset(backWidth - 3, top)
			barEdge.Size = UDim2.fromOffset(1, size * lineHeight)
			barEdge.BackgroundTransparency = transparency
		end
		if barFill.Visible ~= (bottom ~= nil) then
			barFill.Visible = bottom ~= nil
			barEdge.Visible = bottom ~= nil
		end
		-- Chat Delay's queue.
		local pending = ChatLog.pending(log)
		if pendingBack.Visible ~= (pending > 0) then
			pendingBack.Visible = pending > 0
		end
		if pending > 0 then
			local text = `[+{pending} pending lines]`
			if pendingLabel.Text ~= text then
				pendingLabel.Text = text
			end
			pendingLabel.TextTransparency = 1 - 0.5 * textOpacity
			pendingBack.BackgroundTransparency = 1 - backOpacity
		end
	end

	-- The suggestion list above the box (none while there are no suggestions).
	local function drawSuggestions()
		local shown = suggestions
		if shown == nil or not open then
			list.Visible = false
			return
		end
		local candidates = shown.completion.candidates
		local first = ChatInput.firstShown(shown)
		local count = math.min(#candidates - first + 1, ChatInput.SUGGESTION_ROWS)
		local width = 0
		for i = first, first + count - 1 do
			width = math.max(width, measure(candidates[i]))
		end
		width += 1
		local stripWidth = boxBack.Size.X.Offset + 4
		local x = math.clamp(4 + measure(shown.prefix), 0, math.max(stripWidth - 4 - width, 0))
		local height = count * SUGGESTION_ROW
		list.Position = UDim2.fromOffset(x - 1, -SUGGESTION_GAP - height)
		list.Size = UDim2.fromOffset(width + 2, height)
		for i, entry in listRows do
			local index = first + i - 1
			local candidate = if i <= count then candidates[index] else nil
			entry.label.Visible = candidate ~= nil
			entry.shadow.Visible = candidate ~= nil
			if candidate then
				local colour = Color3.fromHex(
					if index == shown.index then ChatFormat.SUGGESTION_SELECTED else ChatFormat.SUGGESTION
				)
				entry.label.Text = candidate
				entry.shadow.Text = candidate
				entry.label.TextColor3 = colour
				entry.shadow.TextColor3 = Style.shadowOf(colour)
			end
		end
		list.Visible = true
	end

	local function layout()
		local viewport = gui.AbsoluteSize
		if viewport.X <= 0 or viewport.Y <= 0 then
			return
		end
		local scale = Style.guiScale(viewport, HUD_W, HUD_H, UserInputService.TouchEnabled)
		local inset = if open then keyboardInset else 0
		local size = metrics.scale
		lines.Visible = size > 0 and metrics.visibility < ChatFormat.HIDDEN
		local unit = scale * math.max(size, 0.01)
		linesScale.Scale = unit
		lines.Position = UDim2.new(0, 0, 1, -(CHAT_BOTTOM * scale + inset))
		backWidth = math.ceil(metrics.width / math.max(size, 0.01)) + 12
		local wrap = ChatLog.wrapWidth(metrics)
		if wrap ~= log.width then
			ChatLog.rewrap(log, wrap)
		end
		ChatLog.setView(log, open, ChatLog.rowsFor(metrics, open))
		placeRows()
		-- The box.
		stripScale.Scale = scale
		local stripWidth = math.floor(viewport.X / scale)
		strip.Size = UDim2.fromOffset(stripWidth, BOX_STRIP)
		strip.Position = UDim2.new(0, 0, 1, -inset)
		boxBack.Size = UDim2.fromOffset(stripWidth - 4, BOX_BACK_H)
		box.Size = UDim2.fromOffset(stripWidth - 8, Style.TEXT_SIZE)
		overlayScale.Scale = scale
		-- (Minecraft draws it 4 above that line.)
		overlay.Position = UDim2.new(0.5, 0, 1, -(OVERLAY_Y - 4) * scale)
		dirty = true
		drawSuggestions()
	end
	relayout = function()
		if started then
			layout()
			if open and metrics.visibility >= ChatFormat.HIDDEN then
				closeImpl()
			end
		end
	end

	--[[ The box ]]

	local applying = false
	-- The box's text as last set or seen (a stripped Tab changes nothing).
	local lastText = ""
	local mouseIconWas = true
	-- Right after opening, the opening key typed into the box is taken back (`guardText`: what
	-- the box held, `guardUntil`: until when, `guardKey`: the character that key types, lower
	-- case; "/" when unknown).
	local guardText = ""
	local guardUntil = 0
	local guardKey = "/"

	local function setText(text: string, cursor: number?)
		applying = true
		box.Text = text
		box.CursorPosition = cursor or (#text + 1)
		applying = false
		lastText = text
	end

	-- Where the cursor is (the end when the box can't say).
	local function cursorOf(text: string): number
		local cursor = box.CursorPosition
		if cursor < 1 or cursor > #text + 1 then
			return #text + 1
		end
		return cursor
	end

	-- The hint for a whisper or team target (Roblox's /whisper, /team).
	local function updateHint()
		local target = targetChannel()
		local hint = nil
		if target and target ~= generalChannel() then
			hint = ChatFormat.targetHint(target.Name, partnerOf(target))
		end
		box.PlaceholderText = hint or ""
	end

	-- The suggestions that show by themselves while a command's name is typed.
	local function autoSuggest()
		suggestions = nil
		if metrics.suggestions then
			local text = box.Text
			local cursor = cursorOf(text)
			local completion = ChatInput.complete(text, cursor, usableAliases(), {}, true)
			if completion and not (#completion.candidates == 1 and completion.candidates[1] == completion.word) then
				suggestions = ChatInput.suggest(text, cursor, completion)
			end
		end
		drawSuggestions()
	end

	openImpl = function(prefill: string)
		if open or not started then
			return
		end
		if metrics.visibility >= ChatFormat.HIDDEN then
			showOverlay(ChatFormat.DISABLED_OPTIONS)
			return
		end
		open = true
		ChatInput.resetHistory(history)
		suggestions = nil
		setText(prefill)
		updateHint()
		strip.Visible = true
		catcher.Visible = true
		local touch = UserInputService.TouchEnabled
		catcher.Modal = not touch
		Hud.setInputTaken(true)
		if not touch then
			mouseIconWas = UserInputService.MouseIconEnabled
			RunService:BindToRenderStep(MOUSE_STEP, Enum.RenderPriority.Camera.Value + 1, function()
				UserInputService.MouseBehavior = Enum.MouseBehavior.Default
				UserInputService.MouseIconEnabled = true
			end)
		end
		layout()
		autoSuggest()
		-- Next frame, so the key that opened the box is not typed into it.
		RunService.Heartbeat:Once(function()
			if open then
				guardText, guardUntil = prefill, os.clock() + 0.1
				box:CaptureFocus()
			end
		end)
	end

	closeImpl = function()
		if not open then
			return
		end
		open = false
		suggestions = nil
		drawSuggestions()
		strip.Visible = false
		catcher.Visible = false
		catcher.Modal = false
		if box:IsFocused() then
			box:ReleaseFocus()
		end
		setText("")
		Hud.setInputTaken(false)
		RunService:UnbindFromRenderStep(MOUSE_STEP)
		if not UserInputService.TouchEnabled then
			UserInputService.MouseIconEnabled = mouseIconWas
		end
		layout()
	end

	local function submit()
		local text = ChatInput.normalize(box.Text)
		closeImpl()
		if text == "" then
			return
		end
		ChatInput.remember(history, text)
		send(text)
	end

	box.FocusLost:Connect(function(enterPressed: boolean, input: InputObject?)
		if not open then
			return
		end
		if enterPressed then
			submit()
			return
		end
		local kind = input and input.UserInputType
		if
			kind == Enum.UserInputType.MouseButton1
			or kind == Enum.UserInputType.MouseButton2
			or kind == Enum.UserInputType.MouseButton3
		then
			-- A click beside the box: Minecraft's chat screen keeps its box focused.
			RunService.Heartbeat:Once(function()
				if open and not box:IsFocused() then
					box:CaptureFocus()
				end
			end)
			return
		end
		-- Escape, a tap elsewhere, the window losing focus.
		closeImpl()
	end)

	box:GetPropertyChangedSignal("Text"):Connect(function()
		if applying then
			return
		end
		local text = box.Text
		-- (Tab completes: the tab it typed goes. Pasted line breaks too; the length is Roblox's.)
		local clean = ChatInput.limit((string.gsub(text, "[\t\r\n]", "")))
		if clean ~= text then
			setText(clean, math.clamp(cursorOf(text) - (#text - #clean), 1, #clean + 1))
		end
		if os.clock() < guardUntil then
			guardUntil = 0
			local typed = string.sub(clean, #guardText + 1)
			if string.sub(clean, 1, #guardText) == guardText and string.lower(typed) == guardKey then
				setText(guardText)
				return
			end
		end
		if clean == lastText then
			return
		end
		lastText = clean
		if open then
			autoSuggest()
		end
	end)

	local function tab(backwards: boolean)
		local current = suggestions
		if current == nil then
			local text = box.Text
			local cursor = cursorOf(text)
			local completion = ChatInput.complete(text, cursor, usableAliases(), playerNames())
			if completion == nil then
				return
			end
			current = ChatInput.suggest(text, cursor, completion)
			suggestions = current
		end
		if current then
			setText(ChatInput.tab(current, backwards))
			drawSuggestions()
		end
	end

	local function shiftDown(): boolean
		return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
	end

	-- The box's own keys (it has the focus, so these come in as processed).
	local function boxKey(key: Enum.KeyCode)
		if key == Enum.KeyCode.Tab then
			tab(shiftDown())
		elseif key == Enum.KeyCode.Up or key == Enum.KeyCode.Down then
			local delta = if key == Enum.KeyCode.Up then -1 else 1
			local current = suggestions
			if current then
				ChatInput.cycle(current, delta)
				drawSuggestions()
			else
				local text = ChatInput.recall(history, delta, box.Text)
				if text then
					setText(text)
					-- (After the box's own handling of the key, which may move the cursor.)
					task.defer(function()
						if open and box.Text == text then
							box.CursorPosition = #text + 1
						end
					end)
				end
			end
		elseif key == Enum.KeyCode.PageUp then
			ChatLog.scroll(log, log.page - 1)
		elseif key == Enum.KeyCode.PageDown then
			ChatLog.scroll(log, -(log.page - 1))
		elseif key == Enum.KeyCode.Backspace and box.Text == "" then
			-- Back to everyone from a whisper or team channel.
			local bar = inputBar()
			local general = generalChannel()
			local target = if bar then bar.TargetTextChannel :: TextChannel? else nil
			if bar and general and target and target ~= general then
				bar.TargetTextChannel = general
				updateHint()
			end
		end
	end

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		local keyboard = input.UserInputType == Enum.UserInputType.Keyboard
		if open then
			if keyboard and box:IsFocused() then
				boxKey(input.KeyCode)
			end
			return
		end
		-- The key bindings' "chat" and "command". (Not `processed` for a key: Roblox's own chat
		-- hotkey may claim "/". A focused text box is typing; a mouse button bound to them counts
		-- only off the GUI.)
		local command = Keybinds.matches("command", input)
		if not command and not Keybinds.matches("chat", input) then
			return
		end
		if
			not keyboard and processed
			or Keybinds.typing()
			or Screens.isOpen()
			or GameModeSwitcher.isOpen()
			or GuiService.MenuIsOpen
		then
			return
		end
		local typed = if keyboard then UserInputService:GetStringForKeyCode(input.KeyCode) else ""
		guardKey = if typed ~= "" then string.lower(typed) else "/"
		Chat.open(if command then "/" else "")
	end)

	-- The wheel scrolls the open chat (Hud.setInputTaken keeps it from the hotbar and camera).
	UserInputService.InputChanged:Connect(function(input: InputObject)
		if open and input.UserInputType == Enum.UserInputType.MouseWheel then
			local notch = math.sign(input.Position.Z)
			ChatLog.scroll(log, notch * (if shiftDown() then 1 else ChatLog.WHEEL_LINES))
		end
	end)

	-- Something else takes over: a screen (a block's window the server opens), Roblox's menu.
	Screens.changed:Connect(function(isOpen: boolean)
		if isOpen then
			closeImpl()
		end
	end)
	GuiService.MenuOpened:Connect(closeImpl)

	-- The on-screen keyboard: the box and lines go above it.
	local function readKeyboard()
		local ok, visible, size = pcall(function()
			return UserInputService.OnScreenKeyboardVisible, UserInputService.OnScreenKeyboardSize
		end)
		local inset = if ok and visible and typeof(size) == "Vector2" then size.Y else 0
		if inset ~= keyboardInset then
			keyboardInset = inset
			layout()
		end
	end
	pcall(function()
		UserInputService:GetPropertyChangedSignal("OnScreenKeyboardVisible"):Connect(readKeyboard)
		UserInputService:GetPropertyChangedSignal("OnScreenKeyboardSize"):Connect(readKeyboard)
	end)

	Hud.onChatButton(function()
		if open then
			closeImpl()
		else
			Chat.open("")
		end
	end)

	--[[ Messages ]]

	-- The server's notices, at once (Chat Delay holds only players' messages).
	Notices.setSink(function(text: string, prefix: string?)
		if prefix then
			Chat.add(ChatFormat.debug(prefix, text))
		else
			Chat.add(ChatFormat.notice(text))
		end
	end)

	local seen: { [string]: boolean } = {}
	local seenOrder: { string } = {}
	TextChatService.MessageReceived:Connect(function(message: TextChatMessage)
		local id = message.MessageId
		if id ~= "" then
			if seen[id] then
				return
			end
			seen[id] = true
			table.insert(seenOrder, id)
			if #seenOrder > SEEN_IDS then
				seen[table.remove(seenOrder, 1) :: string] = nil
			end
		end
		local source = message.TextSource
		if source and message.Status ~= Enum.TextChatMessageStatus.Success then
			return
		end
		local channel = message.TextChannel
		local own = source ~= nil and source.UserId == player.UserId
		local partner = nil
		if channel and own and string.sub(channel.Name, 1, 11) == "RBXWhisper:" then
			partner = partnerOf(channel)
		end
		Chat.add(ChatFormat.incoming({
			text = message.Text,
			channel = if channel then channel.Name else "",
			from = if source then nameOf(source.UserId, source.Name) else nil,
			own = own,
			partner = partner,
		}))
	end)

	-- Commands come and go with the server's scripts (and Roblox's /clear clears the lines).
	local function watchCommand(instance: Instance)
		if instance:IsA("TextChatCommand") then
			aliasCache = nil
			if instance.Name == "RBXClearCommand" then
				instance.Triggered:Connect(function()
					ChatLog.clear(log)
				end)
			end
		end
	end
	TextChatService.DescendantAdded:Connect(watchCommand)
	TextChatService.DescendantRemoving:Connect(function(instance: Instance)
		if instance:IsA("TextChatCommand") then
			aliasCache = nil
		end
	end)
	for _, instance in TextChatService:GetDescendants() do
		watchCommand(instance)
	end

	Chat.add(ChatFormat.joined(player.DisplayName))
	Players.PlayerAdded:Connect(function(other: Player)
		Chat.add(ChatFormat.joined(other.DisplayName))
	end)
	Players.PlayerRemoving:Connect(function(other: Player)
		if other ~= player then
			Chat.add(ChatFormat.left(other.DisplayName))
		end
	end)

	--[[ Every frame ]]

	RunService.RenderStepped:Connect(function()
		local now = os.clock()
		ChatLog.update(log, now)
		local active = ChatLog.active(log, now)
		if active or wasActive or dirty or log.version ~= drawnVersion then
			drawnVersion = log.version
			dirty = false
			draw(now)
		end
		wasActive = active
		local left = overlayUntil - now
		if overlay.Visible ~= (left > 0) then
			overlay.Visible = left > 0
		end
		if left > 0 then
			local alpha = math.clamp(left / OVERLAY_FADE, 0, 1)
			overlayLabel.TextTransparency = 1 - alpha
			overlayShadow.TextTransparency = 1 - alpha
		end
	end)

	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
	Style.scaleChanged:Connect(layout)
	gui.Parent = player:WaitForChild("PlayerGui")
	layout()
end

return Chat
