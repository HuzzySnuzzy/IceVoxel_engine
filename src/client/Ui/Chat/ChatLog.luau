--!strict
--[[
	The chat's lines: Minecraft 1.20.1's ChatComponent (allMessages, trimmedMessages, the scroll
	position, getTimeFactor) and ChatListener's Chat Delay queue, with the Chat Settings' numbers.
	Pure: times are passed in (os.clock()), text is measured by the caller (Style.textWidth on the
	client, a fixed advance in the tests).

	  Messages  the newest MAX_MESSAGES (100) are kept; each is wrapped to the chat's width into
	            lines, and the newest MAX_LINES (100) lines are kept, newest first (line 1 is the
	            bottom row). Wrapping breaks at spaces (the space at a break is dropped), a word
	            wider than a line is cut by characters, and "\n" always breaks. A change of width
	            or text size wraps every kept message again (refreshTrimmedMessage).
	  Fading    a line shows for 10 s after its message arrived: fully for 9 s, then fading out
	            over the last second as Minecraft's (1 - age / 10) * 10, clamped and squared
	            (`fade`). While the chat is open (focused) every line shows at full strength. A row
	            whose text would be drawn at an alpha of 3 / 255 or less is skipped.
	  Rows      the chat holds as many rows as its height allows: floor(height / line height),
	            with the focused or unfocused height (`page`). Rows go up from the bottom: row 0
	            shows line 1 + the scroll position.
	  Scroll    only while open: the wheel scrolls 7 lines a notch (1 with Shift), Page Up / Down a
	            page less one; at most to the oldest line's page. A message arriving while
	            scrolled up keeps the view where it is (the position moves up with it) and marks
	            the scroll bar red (newSinceScroll); closing the chat scrolls back to the bottom.
	  Delay     Chat Delay (0-6 s): other players' messages (ChatFormat.isPlayerKind) wait in a
	            queue and come out one per delay; everything else shows at once. "[+N pending
	            lines]" shows how many wait (`pending`). Setting the delay to 0 lets them all out.

	`version` changes whenever the lines do, so the chat's labels are rebuilt only then.
	`spanAt` finds the span under a point of a line (a click on /locate's coordinates, a hover).
]]

local ChatFormat = require(script.Parent.ChatFormat)

type Message = ChatFormat.Message

export type Measure = (text: string) -> number

export type Entry = {
	message: Message,
	-- os.clock() when it was shown (its lines fade from then).
	addedAt: number,
}

export type Line = {
	entry: Entry,
	-- Bytes of entry.message.text on this line.
	first: number,
	last: number,
	-- The line's rich text and its shadow's (ChatFormat.rich), made once.
	rich: string,
	shadow: string,
}

export type Log = {
	-- Newest first.
	messages: { Entry },
	lines: { Line },
	queue: { Message },
	delay: number,
	-- When the next delayed message may come out.
	releaseAt: number,
	scrollPos: number,
	newSinceScroll: boolean,
	focused: boolean,
	page: number,
	-- Wrap width (chat units: GUI pixels divided by the text size).
	width: number,
	measure: Measure,
	version: number,
}

-- The Chat Settings in the units the chat draws with (`metrics`).
export type Metrics = {
	visibility: number,
	-- Text alpha (0.1..1) and background alpha (0..1) of a fully shown line.
	textOpacity: number,
	backgroundOpacity: number,
	-- Text size: chat units to GUI pixels (0: the lines are not drawn).
	scale: number,
	spacing: number,
	-- Seconds between delayed messages.
	delay: number,
	-- GUI pixels.
	width: number,
	focusedHeight: number,
	unfocusedHeight: number,
	-- Chat units: a row's height, and where its text starts above the row's bottom (negative).
	lineHeight: number,
	textOffset: number,
	suggestions: boolean,
}

local ChatLog = {}

ChatLog.MAX_MESSAGES = 100
ChatLog.MAX_LINES = 100
-- A line shows this long after arriving (Minecraft: 200 ticks).
ChatLog.SHOW_TIME = 10
-- Lines scrolled per wheel notch (Shift: 1).
ChatLog.WHEEL_LINES = 7
-- Minecraft's font is 9 GUI pixels a line (8 high, 1 between).
ChatLog.FONT_LINE = 9
-- Text alpha at or below which a row is not drawn (Minecraft's `v > 3` of 255).
ChatLog.MIN_ALPHA = 3 / 255

--[[ Settings ]]

-- The Chat Settings' values (PlayerSettings keys chat*) as Metrics.
function ChatLog.metrics(values: { [string]: number }): Metrics
	local spacing = (values.chatLineSpacing or 0) / 100
	return {
		visibility = values.chatVisibility or ChatFormat.SHOWN,
		textOpacity = (values.chatOpacity or 100) / 100,
		backgroundOpacity = (values.chatBackground or 50) / 100,
		scale = (values.chatScale or 100) / 100,
		spacing = spacing,
		delay = values.chatDelay or 0,
		width = values.chatWidth or 320,
		focusedHeight = values.chatHeightFocused or 180,
		unfocusedHeight = values.chatHeightUnfocused or 90,
		lineHeight = math.floor(ChatLog.FONT_LINE * (spacing + 1)),
		textOffset = math.floor(-8 * (spacing + 1) + 4 * spacing + 0.5),
		suggestions = (values.commandSuggestions or 1) >= 0.5,
	}
end

-- The wrap width in chat units: the chat's width in GUI pixels at its text size.
function ChatLog.wrapWidth(metrics: Metrics): number
	if metrics.scale <= 0 then
		return metrics.width
	end
	return math.floor(metrics.width / metrics.scale)
end

-- Rows the chat holds, focused or not.
function ChatLog.rowsFor(metrics: Metrics, focused: boolean): number
	local height = if focused then metrics.focusedHeight else metrics.unfocusedHeight
	return math.max(1, height // metrics.lineHeight)
end

--[[ Wrapping ]]

export type Range = { first: number, last: number }

-- One "\n"-free piece (bytes `from`..`to` of `text`) into ranges no wider than `width`.
local function wrapPiece(text: string, from: number, to: number, width: number, measure: Measure, out: { Range })
	local lineStart: number? = nil
	local lineEnd = from - 1
	local i = from
	while i <= to do
		-- The next word: spaces skipped, then up to the next space.
		local wordStart = string.find(text, "[^ ]", i)
		if wordStart == nil or wordStart > to then
			break
		end
		local spaceAt = string.find(text, " ", wordStart, true)
		local wordEnd = if spaceAt and spaceAt <= to then spaceAt - 1 else to
		local start = lineStart
		if start ~= nil and measure(string.sub(text, start, wordEnd)) <= width then
			-- (The spaces between stay on the line.)
			lineEnd = wordEnd
		else
			if start ~= nil then
				table.insert(out, { first = start, last = lineEnd })
			end
			-- A word wider than a line: as many characters as fit (at least one), then the rest.
			local cut = wordStart
			while measure(string.sub(text, cut, wordEnd)) > width do
				local fitEnd = cut - 1
				local position = cut
				while position <= wordEnd do
					local nextChar = utf8.offset(text, 2, position) or (wordEnd + 1)
					if fitEnd >= cut and measure(string.sub(text, cut, nextChar - 1)) > width then
						break
					end
					fitEnd = nextChar - 1
					position = nextChar
				end
				if fitEnd >= wordEnd then
					break
				end
				table.insert(out, { first = cut, last = fitEnd })
				cut = fitEnd + 1
			end
			lineStart = cut
			lineEnd = wordEnd
		end
		i = wordEnd + 1
	end
	if lineStart ~= nil then
		table.insert(out, { first = lineStart, last = lineEnd })
	else
		-- An empty (or all spaces) piece is one empty line.
		table.insert(out, { first = from, last = from - 1 })
	end
end

--[[
	`text` cut into lines no wider than `width` (as `measure` says): byte ranges, top line first.
	An empty text is one empty line.
]]
function ChatLog.wrap(text: string, width: number, measure: Measure): { Range }
	local out: { Range } = {}
	local from = 1
	while true do
		local newline = string.find(text, "\n", from, true)
		local to = if newline then newline - 1 else #text
		wrapPiece(text, from, to, width, measure, out)
		if newline == nil then
			break
		end
		from = newline + 1
	end
	return out
end

--[[ The log ]]

function ChatLog.new(measure: Measure, width: number): Log
	return {
		messages = {},
		lines = {},
		queue = {},
		delay = 0,
		releaseAt = -math.huge,
		scrollPos = 0,
		newSinceScroll = false,
		focused = false,
		page = 10,
		width = width,
		measure = measure,
		version = 0,
	}
end

local function clampScroll(log: Log)
	local most = math.max(0, #log.lines - log.page)
	if log.scrollPos > most then
		log.scrollPos = most
	end
	if log.scrollPos <= 0 then
		log.scrollPos = 0
		log.newSinceScroll = false
	end
end

-- Wraps `entry` and puts its lines at the bottom (newest first), keeping MAX_LINES.
local function addLines(log: Log, entry: Entry, follow: boolean)
	local message = entry.message
	for _, range in ChatLog.wrap(message.text, log.width, log.measure) do
		if follow and log.focused and log.scrollPos > 0 then
			-- Scrolled up: the view stays on the lines it shows.
			log.newSinceScroll = true
			log.scrollPos += 1
		end
		table.insert(log.lines, 1, {
			entry = entry,
			first = range.first,
			last = range.last,
			rich = ChatFormat.rich(message, range.first, range.last, false),
			shadow = ChatFormat.rich(message, range.first, range.last, true),
		})
	end
	for i = #log.lines, ChatLog.MAX_LINES + 1, -1 do
		log.lines[i] = nil
	end
end

local function display(log: Log, message: Message, now: number)
	local entry: Entry = { message = message, addedAt = now }
	table.insert(log.messages, 1, entry)
	for i = #log.messages, ChatLog.MAX_MESSAGES + 1, -1 do
		log.messages[i] = nil
	end
	addLines(log, entry, true)
	clampScroll(log)
	log.version += 1
end

--[[
	Adds `message` at `now`: other players' messages wait in the delay queue while Chat Delay is on
	and the last one came out less than the delay ago (or others wait); the rest show at once.
]]
function ChatLog.add(log: Log, message: Message, now: number)
	if log.delay > 0 and ChatFormat.isPlayerKind(message.kind) then
		if #log.queue > 0 or now < log.releaseAt then
			table.insert(log.queue, message)
			return
		end
		log.releaseAt = now + log.delay
	end
	display(log, message, now)
end

-- Lets the next delayed message out when its time has come. Call every frame.
function ChatLog.update(log: Log, now: number)
	if #log.queue > 0 and now >= log.releaseAt then
		local message = table.remove(log.queue, 1) :: Message
		log.releaseAt = now + log.delay
		display(log, message, now)
	end
end

-- Messages waiting for Chat Delay.
function ChatLog.pending(log: Log): number
	return #log.queue
end

-- Chat Delay (seconds); 0 lets every waiting message out at once.
function ChatLog.setDelay(log: Log, seconds: number, now: number)
	log.delay = math.max(seconds, 0)
	if log.delay <= 0 then
		while #log.queue > 0 do
			display(log, table.remove(log.queue, 1) :: Message, now)
		end
		log.releaseAt = -math.huge
	else
		log.releaseAt = math.min(log.releaseAt, now + log.delay)
	end
end

-- Wraps every kept message again for a new width (chat units) or measure.
function ChatLog.rewrap(log: Log, width: number, measure: Measure?)
	log.width = width
	if measure then
		log.measure = measure
	end
	table.clear(log.lines)
	for i = #log.messages, 1, -1 do
		addLines(log, log.messages[i], false)
	end
	clampScroll(log)
	log.version += 1
end

-- Removes every line and waiting message (Roblox's /clear).
function ChatLog.clear(log: Log)
	table.clear(log.messages)
	table.clear(log.lines)
	table.clear(log.queue)
	log.scrollPos = 0
	log.newSinceScroll = false
	log.version += 1
end

--[[
	The chat opened or closed (`focused`) and holds `page` rows. Closing scrolls back to the
	bottom (resetChatScroll).
]]
function ChatLog.setView(log: Log, focused: boolean, page: number)
	local changed = log.focused ~= focused or log.page ~= page
	log.focused = focused
	log.page = math.max(1, page)
	if not focused then
		log.scrollPos = 0
		log.newSinceScroll = false
	end
	clampScroll(log)
	if changed then
		log.version += 1
	end
end

-- Scrolls `delta` lines up (negative: down), within the kept lines.
function ChatLog.scroll(log: Log, delta: number)
	local before = log.scrollPos
	log.scrollPos += delta
	clampScroll(log)
	if log.scrollPos ~= before then
		log.version += 1
	end
end

--[[ Drawing ]]

-- Minecraft's getTimeFactor: how strongly a line `age` seconds old shows (1 .. 0).
function ChatLog.fade(age: number): number
	local factor = math.clamp((ChatLog.SHOW_TIME - age) * 10 / ChatLog.SHOW_TIME, 0, 1)
	return factor * factor
end

--[[
	Row `row` (0 = the bottom) of the chat at `now`: its line and how strongly it shows (0: not
	drawn). Rows past the kept lines have no line.
]]
function ChatLog.row(log: Log, row: number, now: number): (Line?, number)
	if row >= log.page then
		return nil, 0
	end
	local line = log.lines[row + log.scrollPos + 1]
	if line == nil then
		return nil, 0
	end
	if log.focused then
		return line, 1
	end
	local age = now - line.entry.addedAt
	if age >= ChatLog.SHOW_TIME then
		return line, 0
	end
	return line, ChatLog.fade(age)
end

--[[
	The span of `line` drawn at `x` (chat units from where its text starts, as `measure` measures
	it), nil before it or past its end.
]]
function ChatLog.spanAt(line: Line, x: number, measure: Measure): ChatFormat.Span?
	if x < 0 then
		return nil
	end
	local message = line.entry.message
	local offset = 0
	for _, part in message.spans do
		local from, to = offset + 1, offset + #part.text
		offset = to
		local last = math.min(to, line.last)
		if math.max(from, line.first) > last then
			continue
		end
		if x < measure(string.sub(message.text, line.first, last)) then
			return part
		end
	end
	return nil
end

-- Is anything to draw at `now` (an open chat, a line still fading, delayed messages)?
function ChatLog.active(log: Log, now: number): boolean
	if log.focused or #log.queue > 0 then
		return true
	end
	local newest = log.messages[1]
	return newest ~= nil and now - newest.addedAt < ChatLog.SHOW_TIME
end

--[[
	The scroll bar while open (Minecraft's, beside the lines): nil when every line fits. `top` and
	`height` are in rows from the bottom of the chat; `bright` when scrolled up; `red` when a
	message arrived while scrolled up.
]]
function ChatLog.scrollBar(log: Log): (number?, number, boolean, boolean)
	local total = #log.lines
	if not log.focused or total <= log.page then
		return nil, 0, false, false
	end
	local shown = log.page
	local height = shown * shown / total
	local bottom = log.scrollPos * shown / total
	return bottom, height, log.scrollPos > 0, log.newSinceScroll
end

return ChatLog
