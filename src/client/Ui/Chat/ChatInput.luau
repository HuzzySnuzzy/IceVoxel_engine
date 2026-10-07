--!strict
--[[
	The chat box's rules: Minecraft 1.20.1's ChatScreen (what is sent, the sent history) and
	CommandSuggestions (Tab completion), on top of Roblox's TextChatService commands. Pure, so the
	tests run it; Ui/Chat feeds it the box's text and cursor (TextBox.CursorPosition: the byte
	after the cursor, from 1).

	  Sending   the text is trimmed, runs of spaces become one (StringUtils.normalizeSpace) and it
	            is cut to MAX_LENGTH, Roblox's longest chat message (Minecraft's is 256); nothing is
	            sent when nothing is left. Text starting with "/" is a command: its first word must
	            be the alias of a TextChatCommand (the server's /time, /gamemode, /summon...,
	            Roblox's /whisper, /team, /e...) or it is "unknown" and never sent (Minecraft's
	            red error instead); the word is sent as the alias is written, so Roblox's command
	            matching finds it whatever case was typed. TextChatService runs a command it
	            matches and shows it to no one.
	  History   every sent text (commands too) is kept, MAX_HISTORY of them, a repeat of the last
	            one only once (ChatComponent.addRecentChat). Up goes back through them, Down
	            forward; past the newest the text being typed comes back (moveInHistory's
	            historyBuffer). Opening the chat starts at the end again.
	  Tab       completes the word before the cursor: the command's name while typing it (every
	            alias starting with it, in alphabetical order, the slash included), else players'
	            names (names and display names starting with it, any case; all of them for an
	            empty word). The first Tab uses the highlighted suggestion; each further one moves
	            to the next and uses it (Shift + Tab: the previous), as SuggestionsList does, and
	            the list stays until the text is typed into. Up / Down move the highlight while a
	            list is shown. While a command's name is typed, its suggestions show by themselves
	            (the Command Suggestions setting), at most SUGGESTION_ROWS at a time.
]]

local ChatInput = {}

-- Roblox's TextChatService refuses longer messages (MessageTooLong).
ChatInput.MAX_LENGTH = 200
-- Sent texts kept for Up / Down (ChatComponent's recentChat).
ChatInput.MAX_HISTORY = 100
-- Suggestions shown at once (CommandSuggestions' chat list).
ChatInput.SUGGESTION_ROWS = 10

--[[ Sending ]]

-- `text` cut to at most `length` bytes without splitting a character.
function ChatInput.limit(text: string, length: number?): string
	local most = length or ChatInput.MAX_LENGTH
	if #text <= most then
		return text
	end
	local cut = most
	-- (A continuation byte, 10xxxxxx, belongs to the character before it.)
	while cut > 0 and bit32.band(string.byte(text, cut + 1) or 0, 0xC0) == 0x80 do
		cut -= 1
	end
	return string.sub(text, 1, cut)
end

-- What sending `text` sends: trimmed, spaces collapsed, at most MAX_LENGTH.
function ChatInput.normalize(text: string): string
	local collapsed = string.gsub(text, "%s+", " ")
	local trimmed = string.match(collapsed, "^ *(.-) *$") or ""
	return ChatInput.limit(trimmed)
end

function ChatInput.isCommand(text: string): boolean
	return string.sub(text, 1, 1) == "/"
end

-- The aliases by their lower case: { ["/time"] = "/time", ["/gm"] = "/gm" }, from the aliases
-- of the TextChatCommands (empty ones left out).
function ChatInput.aliasMap(aliases: { string }): { [string]: string }
	local map: { [string]: string } = {}
	for _, alias in aliases do
		if alias ~= "" then
			map[string.lower(alias)] = alias
		end
	end
	return map
end

--[[
	What to do with `text` (normalized): "chat" (send it as it is), "command" (send the returned
	text: the first word as its alias is written) or "unknown" (a command nobody answers).
]]
function ChatInput.resolve(text: string, aliases: { [string]: string }): ("chat" | "command" | "unknown", string)
	if not ChatInput.isCommand(text) then
		return "chat", text
	end
	local word, rest = string.match(text, "^(%S+)(.*)$")
	local alias = if word then aliases[string.lower(word)] else nil
	if alias == nil then
		return "unknown", text
	end
	return "command", alias .. (rest or "")
end

--[[ History ]]

export type History = {
	entries: { string },
	-- 1..#entries, or #entries + 1: the text being typed.
	pos: number,
	-- What was typed before going back (historyBuffer).
	draft: string,
}

function ChatInput.newHistory(): History
	return { entries = {}, pos = 1, draft = "" }
end

-- Remembers a sent text (not a repeat of the last one), at most MAX_HISTORY.
function ChatInput.remember(history: History, text: string)
	local entries = history.entries
	if text == "" or entries[#entries] == text then
		return
	end
	table.insert(entries, text)
	while #entries > ChatInput.MAX_HISTORY do
		table.remove(entries, 1)
	end
end

-- The chat opened: Up starts from the newest again.
function ChatInput.resetHistory(history: History)
	history.pos = #history.entries + 1
	history.draft = ""
end

--[[
	Moves `delta` through the history (-1: Up, older; 1: Down, newer) from what the box holds
	(`current`). Returns the text to show, or nil when it stays.
]]
function ChatInput.recall(history: History, delta: number, current: string): string?
	local count = #history.entries
	local target = math.clamp(history.pos + delta, 1, count + 1)
	if target == history.pos then
		return nil
	end
	if history.pos == count + 1 then
		history.draft = current
	end
	history.pos = target
	if target == count + 1 then
		return history.draft
	end
	return history.entries[target]
end

--[[ Completion ]]

export type Completion = {
	-- The word being completed: bytes `start`..`cursor - 1` of the text.
	start: number,
	word: string,
	candidates: { string },
	-- It is a command's name.
	command: boolean,
}

local function startsWith(text: string, prefix: string): boolean
	return string.sub(string.lower(text), 1, #prefix) == string.lower(prefix)
end

local function sortedUnique(list: { string }): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for _, value in list do
		if not seen[value] then
			seen[value] = true
			table.insert(out, value)
		end
	end
	table.sort(out, function(a: string, b: string): boolean
		local la, lb = string.lower(a), string.lower(b)
		if la == lb then
			return a < b
		end
		return la < lb
	end)
	return out
end

--[[
	What Tab completes in `text` with the cursor at byte `cursor` (the word before it): a
	command's name (`commands`: the aliases, slash included) while the cursor is in the first word
	of a command, else `players` (names); nil when nothing matches. `commandsOnly`: only a
	command's name (the suggestions that show by themselves).
]]
function ChatInput.complete(
	text: string,
	cursor: number,
	commands: { string },
	players: { string },
	commandsOnly: boolean?
): Completion?
	local before = string.sub(text, 1, math.max(cursor - 1, 0))
	local lastSpace = 0
	for i = #before, 1, -1 do
		if string.sub(before, i, i) == " " then
			lastSpace = i
			break
		end
	end
	local start = lastSpace + 1
	local word = string.sub(before, start)
	local commandWord = lastSpace == 0 and ChatInput.isCommand(before)
	if commandsOnly and not commandWord then
		return nil
	end
	local pool: { string } = if commandWord then commands else players
	local matches = {}
	for _, candidate in pool do
		if startsWith(candidate, word) then
			table.insert(matches, candidate)
		end
	end
	if #matches == 0 then
		return nil
	end
	return { start = start, word = word, candidates = sortedUnique(matches), command = commandWord }
end

export type Suggestions = {
	completion: Completion,
	-- The highlighted candidate.
	index: number,
	-- A Tab used a candidate: the next Tab moves on first (SuggestionsList.tabCycles).
	used: boolean,
	-- The text around the word.
	prefix: string,
	tail: string,
}

-- A suggestion list for `completion` of `text` (cursor at `cursor`), the first one highlighted.
function ChatInput.suggest(text: string, cursor: number, completion: Completion): Suggestions
	return {
		completion = completion,
		index = 1,
		used = false,
		prefix = string.sub(text, 1, completion.start - 1),
		tail = string.sub(text, math.max(cursor, 1)),
	}
end

-- Moves the highlight `delta` (wrapping).
function ChatInput.cycle(suggestions: Suggestions, delta: number)
	local count = #suggestions.completion.candidates
	suggestions.index = (suggestions.index - 1 + delta) % count + 1
end

-- The text with the highlighted candidate in the word's place, and the cursor after it.
function ChatInput.use(suggestions: Suggestions): (string, number)
	local candidate = suggestions.completion.candidates[suggestions.index]
	local text = suggestions.prefix .. candidate .. suggestions.tail
	return text, #suggestions.prefix + #candidate + 1
end

-- Tab (`backwards`: Shift + Tab): moves on if a Tab already used one, then uses the highlight.
function ChatInput.tab(suggestions: Suggestions, backwards: boolean?): (string, number)
	if suggestions.used then
		ChatInput.cycle(suggestions, if backwards then -1 else 1)
	end
	suggestions.used = true
	return ChatInput.use(suggestions)
end

-- The first candidate shown when at most SUGGESTION_ROWS fit (the highlight always shows).
function ChatInput.firstShown(suggestions: Suggestions): number
	local count = #suggestions.completion.candidates
	local rows = ChatInput.SUGGESTION_ROWS
	if count <= rows then
		return 1
	end
	return math.clamp(suggestions.index - rows + 1, 1, count - rows + 1)
end

return ChatInput
