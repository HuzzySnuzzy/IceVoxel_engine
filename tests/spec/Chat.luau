--[[
	The chat's pure parts: the line buffer (Ui/Chat/ChatLog: wrapping, the 100-line cap, fading,
	rows, scrolling, Chat Delay), the box's rules (Ui/Chat/ChatInput: what is sent, commands,
	history, Tab completion) and the lines' looks (Ui/Chat/ChatFormat: message kinds, visibility,
	rich text, Minecraft's unknown command lines), with the Chat Settings' clamps
	(Shared/PlayerSettings) and the notices' route into the chat (Net/Notices' sink is glue; the
	formatting of what it hands over is checked here). Text is measured as the Arcade font
	(8 pixels a character).
]]

return function(t, shared, require, _server, client)
	local ChatFormat = require(client.Ui.Chat.ChatFormat)
	local ChatInput = require(client.Ui.Chat.ChatInput)
	local ChatLog = require(client.Ui.Chat.ChatLog)
	local PlayerSettings = require(shared.PlayerSettings)
	local Pages = require(client.Settings.Pages)

	local function measure(text: string): number
		return (utf8.len(text) or #text) * 8
	end

	-- The lines of `text` wrapped to `width`, joined with "|".
	local function wrapped(text: string, width: number): string
		local out = {}
		for _, range in ChatLog.wrap(text, width, measure) do
			table.insert(out, string.sub(text, range.first, range.last))
		end
		return table.concat(out, "|")
	end

	local function newLog(width: number?)
		return ChatLog.new(measure, width or 320)
	end

	-- The plain text of a line.
	local function lineText(line): string
		return string.sub(line.entry.message.text, line.first, line.last)
	end

	--[[ Wrapping ]]

	t.test("chat: wrapping at spaces, long words by characters, newlines, empty text", function()
		t.eq(wrapped("hello world", 320), "hello world", "fits")
		t.eq(wrapped("one two three four", 80), "one two|three four", "breaks at spaces, the space dropped")
		for _, range in ChatLog.wrap("one two three four five six", 80, measure) do
			t.ok(range.last - range.first + 1 <= 10, "no line wider than the chat")
		end
		t.eq(wrapped("abcdefghijklmnop", 40), "abcde|fghij|klmno|p", "a long word is cut")
		t.eq(wrapped("hi abcdefghijkl", 40), "hi|abcde|fghij|kl", "after a short word")
		t.eq(wrapped("first\nsecond", 320), "first|second", "a newline breaks")
		t.eq(#ChatLog.wrap("", 320, measure), 1, "empty text: one empty line")
		t.eq(wrapped("a  b", 320), "a  b", "spaces inside a line stay")
		-- Multi-byte characters are never split.
		local text = "ééééééé"
		for _, range in ChatLog.wrap(text, 24, measure) do
			t.ok(utf8.len(string.sub(text, range.first, range.last)) ~= nil, "whole characters")
		end
		t.eq(wrapped(text, 24), "ééé|ééé|é")
	end)

	--[[ The buffer ]]

	t.test("chat: newest line at the bottom, a message's lines in order, 100 lines and messages kept", function()
		local log = newLog(80)
		ChatLog.add(log, ChatFormat.notice("first"), 0)
		ChatLog.add(log, ChatFormat.notice("one two three four"), 1)
		t.eq(#log.lines, 3)
		t.eq(lineText(log.lines[1]), "three four", "the newest message's last line is the bottom row")
		t.eq(lineText(log.lines[2]), "one two")
		t.eq(lineText(log.lines[3]), "first")
		for i = 1, 150 do
			ChatLog.add(log, ChatFormat.notice(`message {i}`), 2 + i)
		end
		t.eq(#log.lines, ChatLog.MAX_LINES, "100 lines")
		t.eq(#log.messages, ChatLog.MAX_MESSAGES, "100 messages")
		t.eq(lineText(log.lines[1]), "150", "wrapped at 80")
		t.eq(lineText(log.lines[2]), "message")
		-- Rewrapping wider joins lines again (the 100 kept messages, one line each).
		ChatLog.rewrap(log, 320)
		t.eq(#log.lines, 100)
		t.eq(lineText(log.lines[1]), "message 150")
		t.eq(lineText(log.lines[100]), "message 51")
		ChatLog.clear(log)
		t.eq(#log.lines, 0, "cleared")
	end)

	t.test("chat: lines show 10 s, fading over the last second as Minecraft's; all while open", function()
		t.eq(ChatLog.fade(0), 1)
		t.eq(ChatLog.fade(9), 1, "full for 9 s")
		t.near(ChatLog.fade(9.5), 0.25, 1e-9, "squared")
		t.eq(ChatLog.fade(10), 0)
		t.eq(ChatLog.fade(20), 0)
		local log = newLog()
		ChatLog.setView(log, false, 10)
		ChatLog.add(log, ChatFormat.notice("old"), 0)
		ChatLog.add(log, ChatFormat.notice("new"), 5)
		local line, alpha = ChatLog.row(log, 0, 9.5)
		t.eq(lineText(line), "new")
		t.eq(alpha, 1)
		line, alpha = ChatLog.row(log, 1, 9.5)
		t.eq(lineText(line), "old")
		t.near(alpha, 0.25, 1e-9)
		_, alpha = ChatLog.row(log, 1, 11)
		t.eq(alpha, 0, "gone after 10 s")
		t.ok(ChatLog.active(log, 11), "the newer line still shows")
		t.ok(not ChatLog.active(log, 16), "nothing left to draw")
		ChatLog.setView(log, true, 10)
		_, alpha = ChatLog.row(log, 1, 100)
		t.eq(alpha, 1, "open: every line shows")
		t.ok(ChatLog.active(log, 100))
		local none = ChatLog.row(log, 2, 100)
		t.eq(none, nil, "no third line")
		local beyond = ChatLog.row(log, 10, 100)
		t.eq(beyond, nil, "past the page")
	end)

	t.test("chat: scrolling within the lines, kept in place by new messages, reset on close", function()
		local log = newLog()
		for i = 1, 30 do
			ChatLog.add(log, ChatFormat.notice(`line {i}`), i)
		end
		ChatLog.setView(log, true, 20)
		ChatLog.scroll(log, ChatLog.WHEEL_LINES)
		t.eq(log.scrollPos, 7)
		ChatLog.scroll(log, 100)
		t.eq(log.scrollPos, 10, "at most the oldest line's page")
		t.eq(lineText((ChatLog.row(log, 19, 0))), "line 1", "the top row is the oldest line")
		ChatLog.scroll(log, -3)
		t.eq(log.scrollPos, 7)
		local shown = lineText((ChatLog.row(log, 0, 0)))
		ChatLog.add(log, ChatFormat.notice("newer"), 40)
		t.eq(log.scrollPos, 8, "the view follows the lines it shows")
		t.ok(log.newSinceScroll, "the bar turns red")
		t.eq(lineText((ChatLog.row(log, 0, 0))), shown)
		local bottom, height, bright, red = ChatLog.scrollBar(log)
		t.ok(bottom ~= nil and height > 0 and bright and red, "a scroll bar while open")
		ChatLog.scroll(log, -100)
		t.eq(log.scrollPos, 0)
		t.ok(not log.newSinceScroll, "back at the bottom")
		ChatLog.scroll(log, 5)
		ChatLog.setView(log, false, 10)
		t.eq(log.scrollPos, 0, "closing scrolls back down")
		t.eq((ChatLog.scrollBar(log)), nil, "no bar while closed")
		-- Fewer lines than rows: no scrolling.
		local short = newLog()
		ChatLog.add(short, ChatFormat.notice("only"), 0)
		ChatLog.setView(short, true, 20)
		ChatLog.scroll(short, 7)
		t.eq(short.scrollPos, 0)
	end)

	t.test("chat: Chat Delay queues players' messages, one per delay; others at once", function()
		local log = newLog()
		ChatLog.setDelay(log, 2, 0)
		ChatLog.add(log, ChatFormat.player("Alex", "a"), 0)
		ChatLog.add(log, ChatFormat.player("Alex", "b"), 0.5)
		ChatLog.add(log, ChatFormat.player("Steve", "c"), 0.6)
		ChatLog.add(log, ChatFormat.notice("feedback"), 0.7)
		t.eq(#log.messages, 2, "the first message and the notice show")
		t.eq(ChatLog.pending(log), 2)
		ChatLog.update(log, 1.9)
		t.eq(ChatLog.pending(log), 2, "not before the delay")
		ChatLog.update(log, 2)
		t.eq(ChatLog.pending(log), 1)
		t.eq(log.messages[1].message.text, "<Alex> b")
		ChatLog.update(log, 3)
		t.eq(ChatLog.pending(log), 1, "one per delay")
		ChatLog.setDelay(log, 0, 3)
		t.eq(ChatLog.pending(log), 0, "no delay: all out")
		t.eq(log.messages[1].message.text, "<Steve> c")
	end)

	t.test("chat: metrics from the Chat Settings", function()
		local values = PlayerSettings.defaults(false, 0)
		local metrics = ChatLog.metrics(values)
		t.eq(metrics.visibility, ChatFormat.SHOWN)
		t.eq(metrics.textOpacity, 1)
		t.eq(metrics.backgroundOpacity, 0.5)
		t.eq(metrics.scale, 1)
		t.eq(metrics.width, 320)
		t.eq(metrics.focusedHeight, 180)
		t.eq(metrics.unfocusedHeight, 90)
		t.eq(metrics.lineHeight, 9, "Minecraft's 9 pixel lines")
		t.eq(metrics.textOffset, -8)
		t.eq(ChatLog.rowsFor(metrics, true), 20)
		t.eq(ChatLog.rowsFor(metrics, false), 10)
		t.eq(ChatLog.wrapWidth(metrics), 320)
		t.ok(metrics.suggestions)
		values.chatLineSpacing = 100
		values.chatScale = 50
		metrics = ChatLog.metrics(values)
		t.eq(metrics.lineHeight, 18, "double spacing")
		t.eq(metrics.textOffset, -12, "the text sits in the middle of the taller row")
		t.eq(ChatLog.wrapWidth(metrics), 640, "half size: twice the characters a line")
		t.eq(ChatLog.rowsFor(metrics, true), 10)
		values.chatScale = 0
		t.eq(ChatLog.wrapWidth(ChatLog.metrics(values)), 320, "size 0 divides by nothing")
	end)

	t.test("chat: the Chat Settings' ranges, clamps, labels and page", function()
		local clamp = PlayerSettings.clamp
		t.eq(clamp("chatVisibility", 0), 1)
		t.eq(clamp("chatVisibility", 7), 3)
		t.eq(clamp("chatOpacity", 0), 10, "text never fully transparent (10%)")
		t.eq(clamp("chatOpacity", 150), 100)
		t.eq(clamp("chatBackground", -5), 0)
		t.eq(clamp("chatScale", 101), 100)
		t.eq(clamp("chatLineSpacing", 0 / 0), 0, "NaN: the default")
		t.eq(clamp("chatDelay", 1.3), 1.5, "half seconds")
		t.eq(clamp("chatDelay", 10), 6)
		t.eq(clamp("chatWidth", 10), 40)
		t.eq(clamp("chatWidth", 1000), 320)
		t.eq(clamp("chatHeightFocused", 5), 20)
		t.eq(clamp("chatHeightUnfocused", 999), 180)
		t.eq(PlayerSettings.text("chatVisibility", 2), "Chat: Commands Only")
		t.eq(PlayerSettings.text("chatDelay", 0), "Chat Delay: None")
		t.eq(PlayerSettings.text("chatDelay", 1.5), "Chat Delay: 1.5 s")
		t.eq(PlayerSettings.text("chatScale", 0), "Text Size: OFF")
		t.eq(PlayerSettings.text("chatWidth", 320), "Width: 320 px")
		t.eq(PlayerSettings.text("chatOpacity", 100), "Chat Text Opacity: 100%")
		t.eq(PlayerSettings.text("commandSuggestions", 1), "Command Suggestions: ON")
		for _, entry in PlayerSettings.ENTRIES do
			if string.sub(entry.key, 1, 4) == "chat" or entry.key == "commandSuggestions" then
				t.eq(entry.page, "chat", `{entry.key} on the chat page`)
				t.eq(entry.effect, "chat", `{entry.key} applies through the chat`)
				t.ok(not entry.preset, `{entry.key} is no preset's`)
			end
		end
		t.ok(table.find(PlayerSettings.EFFECT_ORDER, "chat") ~= nil, "the chat effect runs")
		t.ok(not PlayerSettings.EXPENSIVE.chat, "and at once")
		t.ok(Pages.byId.chat ~= nil, "a Chat Settings page")
		local reached = false
		for _, item in Pages.byId.main.items do
			if item.kind == "page" and item.id == "chat" then
				reached = true
			end
		end
		t.ok(reached, "opened from Options")
		-- Saved and sent like every setting.
		local values = PlayerSettings.defaults(false, 0)
		values.chatDelay = 2.5
		values.chatVisibility = 3
		local _, decoded = PlayerSettings.decode(PlayerSettings.encode(PlayerSettings.Profile.Desktop, values))
		t.eq(decoded and decoded.chatDelay, 2.5)
		t.eq(decoded and decoded.chatVisibility, 3)
	end)

	--[[ Sending ]]

	t.test("chat input: normalizing, length, command detection and resolution", function()
		t.eq(ChatInput.normalize("  hello   there  "), "hello there", "trimmed, spaces collapsed")
		t.eq(ChatInput.normalize("   "), "", "nothing to send")
		t.eq(ChatInput.normalize("a\tb\nc"), "a b c")
		t.eq(#ChatInput.normalize(string.rep("x", 300)), ChatInput.MAX_LENGTH, "Roblox's longest message")
		local cut = ChatInput.limit(string.rep("é", 150))
		t.ok(utf8.len(cut) ~= nil and #cut <= ChatInput.MAX_LENGTH, "never splits a character")
		t.ok(ChatInput.isCommand("/time set day"))
		t.ok(not ChatInput.isCommand("hello /time"))
		local aliases = ChatInput.aliasMap({ "/time", "/gamemode", "/gm", "", "/Whisper" })
		t.eq(aliases[""], nil, "empty aliases left out")
		local kind, text = ChatInput.resolve("hello", aliases)
		t.eq(kind, "chat")
		t.eq(text, "hello")
		kind, text = ChatInput.resolve("/TIME set day", aliases)
		t.eq(kind, "command")
		t.eq(text, "/time set day", "the alias as it is written")
		kind, text = ChatInput.resolve("/whisper Bob hi", aliases)
		t.eq(text, "/Whisper Bob hi")
		kind = ChatInput.resolve("/gm", aliases)
		t.eq(kind, "command", "a command with no arguments")
		kind, text = ChatInput.resolve("/foo bar", aliases)
		t.eq(kind, "unknown", "never sent")
		t.eq(text, "/foo bar")
		t.eq((ChatInput.resolve("/", aliases)), "unknown")
	end)

	t.test("chat input: history recall with Up / Down, the draft kept, repeats once", function()
		local history = ChatInput.newHistory()
		ChatInput.remember(history, "first")
		ChatInput.remember(history, "second")
		ChatInput.remember(history, "second")
		ChatInput.remember(history, "")
		t.eq(#history.entries, 2, "a repeat of the last one and nothing are not kept")
		ChatInput.resetHistory(history)
		t.eq(ChatInput.recall(history, 1, "typing"), nil, "nothing newer than the draft")
		t.eq(ChatInput.recall(history, -1, "typing"), "second")
		t.eq(ChatInput.recall(history, -1, "second"), "first")
		t.eq(ChatInput.recall(history, -1, "first"), nil, "the oldest stays")
		t.eq(ChatInput.recall(history, 1, "first"), "second")
		t.eq(ChatInput.recall(history, 1, "second"), "typing", "the draft comes back")
		for i = 1, 150 do
			ChatInput.remember(history, `message {i}`)
		end
		t.eq(#history.entries, ChatInput.MAX_HISTORY)
		t.eq(history.entries[1], "message 51", "the oldest go")
		-- Reopening starts at the newest again.
		ChatInput.resetHistory(history)
		t.eq(ChatInput.recall(history, -1, ""), "message 150")
	end)

	--[[ Tab ]]

	local COMMANDS = { "/time", "/gamemode", "/gm", "/gamerule", "/summon", "/team", "/e" }
	local PLAYERS = { "Alex", "alexander", "Steve", "Sam" }

	t.test("chat input: Tab completes command names, then players' names", function()
		local completion = ChatInput.complete("/ga", 4, COMMANDS, PLAYERS)
		t.ok(completion ~= nil and completion.command, "a command's name")
		t.eq(table.concat((completion :: any).candidates, ","), "/gamemode,/gamerule", "sorted")
		completion = ChatInput.complete("/", 2, COMMANDS, PLAYERS)
		t.eq(#(completion :: any).candidates, #COMMANDS, "every command for a bare slash")
		completion = ChatInput.complete("/gamemode creative a", 21, COMMANDS, PLAYERS)
		t.ok(completion ~= nil and not completion.command, "arguments: players")
		t.eq(table.concat((completion :: any).candidates, ","), "Alex,alexander", "any case")
		t.eq((completion :: any).start, 20)
		completion = ChatInput.complete("hi s", 5, COMMANDS, PLAYERS)
		t.eq(table.concat((completion :: any).candidates, ","), "Sam,Steve", "names in chat")
		t.eq(ChatInput.complete("hi zz", 6, COMMANDS, PLAYERS), nil, "nothing matches")
		completion = ChatInput.complete("hi ", 4, COMMANDS, PLAYERS)
		t.eq(#(completion :: any).candidates, 4, "an empty word: everyone")
		t.eq(ChatInput.complete("hi s", 5, COMMANDS, PLAYERS, true), nil, "commands only: no names")
		t.eq(ChatInput.complete("/time s", 8, COMMANDS, {}, true), nil, "past the command's name")
		-- The cursor in the middle: the word before it.
		completion = ChatInput.complete("/ti set day", 4, COMMANDS, PLAYERS)
		t.eq(table.concat((completion :: any).candidates, ","), "/time")
	end)

	t.test("chat input: the first Tab uses the highlight, the next ones cycle (Shift back)", function()
		local text = "/ga"
		local completion = ChatInput.complete(text, 4, COMMANDS, PLAYERS) :: any
		local suggestions = ChatInput.suggest(text, 4, completion)
		local out, cursor = ChatInput.tab(suggestions)
		t.eq(out, "/gamemode")
		t.eq(cursor, 10)
		out = ChatInput.tab(suggestions)
		t.eq(out, "/gamerule", "the next one")
		out = ChatInput.tab(suggestions)
		t.eq(out, "/gamemode", "wrapping")
		out = ChatInput.tab(suggestions, true)
		t.eq(out, "/gamerule", "Shift + Tab: back")
		-- Text after the cursor stays.
		text = "/ti set day"
		completion = ChatInput.complete(text, 4, COMMANDS, PLAYERS) :: any
		suggestions = ChatInput.suggest(text, 4, completion)
		out, cursor = ChatInput.tab(suggestions)
		t.eq(out, "/time set day")
		t.eq(cursor, 6)
		-- Up / Down move the highlight; a long list shows its highlighted part.
		local many = {}
		for i = 1, 25 do
			table.insert(many, string.format("/c%02d", i))
		end
		completion = ChatInput.complete("/c", 3, many, {}) :: any
		suggestions = ChatInput.suggest("/c", 3, completion)
		t.eq(ChatInput.firstShown(suggestions), 1)
		ChatInput.cycle(suggestions, 14)
		t.eq(suggestions.index, 15)
		t.eq(ChatInput.firstShown(suggestions), 6, "the highlight is the last row shown")
		ChatInput.cycle(suggestions, -15)
		t.eq(suggestions.index, 25, "wrapping back")
		t.eq(ChatInput.firstShown(suggestions), 16)
		t.eq(select(1, ChatInput.use(suggestions)), "/c25")
	end)

	--[[ Looks ]]

	t.test("chat format: message kinds, their colours and who sees them", function()
		local player = ChatFormat.player("Alex", "hello")
		t.eq(player.text, "<Alex> hello", "Minecraft's chat.type.text")
		t.eq(player.spans[1].colour, ChatFormat.WHITE)
		t.eq(ChatFormat.joined("Alex").text, "Alex joined the game")
		t.eq(ChatFormat.left("Alex").text, "Alex left the game")
		t.eq(ChatFormat.joined("Alex").spans[1].colour, ChatFormat.YELLOW)
		local debug = ChatFormat.debug("[Debug]:", "Key bindings:")
		t.eq(debug.text, "[Debug]: Key bindings:")
		t.ok(debug.spans[1].bold and debug.spans[1].colour == ChatFormat.YELLOW, "bold yellow prefix")
		t.eq(debug.spans[2].colour, ChatFormat.WHITE)
		t.eq(ChatFormat.notice("Set the time to 1000").spans[1].colour, ChatFormat.WHITE)
		t.eq(ChatFormat.error("nope").spans[1].colour, ChatFormat.RED)
		t.eq(ChatFormat.whisper("Bob", "psst", false).text, "Bob whispers to you: psst")
		t.eq(ChatFormat.whisper("Bob", "psst", true).text, "You whisper to Bob: psst")
		t.ok(ChatFormat.whisper("Bob", "psst", true).spans[1].italic, "gray italic")
		-- Visibility: Shown, Commands Only, Hidden.
		for _, kind in { "player", "whisper", "team", "join", "notice", "debug", "error", "system" } do
			t.ok(ChatFormat.shows(kind :: any, ChatFormat.SHOWN), `{kind} shown`)
			t.ok(not ChatFormat.shows(kind :: any, ChatFormat.HIDDEN), `{kind} hidden`)
			t.eq(
				ChatFormat.shows(kind :: any, ChatFormat.COMMANDS_ONLY),
				not ChatFormat.isPlayerKind(kind :: any),
				`{kind} with commands only`
			)
		end
	end)

	t.test("chat format: TextChatService messages, escaping and rich text", function()
		local message =
			ChatFormat.incoming({ text = "I &lt;3 &amp; you", channel = "RBXGeneral", from = "Alex", own = false })
		t.eq(message.kind, "player")
		t.eq(message.text, "<Alex> I <3 & you", "unescaped as typed")
		local rich = ChatFormat.rich(message, 1, #message.text, false)
		t.eq(rich, '<font color="#FFFFFF">&lt;Alex&gt; I &lt;3 &amp; you</font>', "escaped again for the label")
		t.eq(
			ChatFormat.rich(message, 1, #message.text, true),
			'<font color="#3F3F3F">&lt;Alex&gt; I &lt;3 &amp; you</font>',
			"the shadow a quarter as bright"
		)
		local system = ChatFormat.incoming({
			text = '<font color="#ff0000">Hi</font> &amp; bye',
			channel = "RBXSystem",
			own = false,
		})
		t.eq(system.kind, "system")
		t.eq(system.text, "Hi & bye", "tags dropped")
		local whisper =
			ChatFormat.incoming({ text = "yo", channel = "RBXWhisper:1_2", from = "Alex", own = true, partner = "Bob" })
		t.eq(whisper.text, "You whisper to Bob: yo")
		whisper = ChatFormat.incoming({ text = "yo", channel = "RBXWhisper:1_2", from = "Bob", own = false })
		t.eq(whisper.text, "Bob whispers to you: yo")
		t.eq(
			ChatFormat.incoming({ text = "go", channel = "RBXTeamBright red", from = "Alex", own = false }).text,
			"[Team] <Alex> go"
		)
		-- A line of a debug message: the part of each span on it, styled.
		local debug = ChatFormat.debug("[Debug]:", "hi")
		t.eq(
			ChatFormat.rich(debug, 1, #debug.text, false),
			'<font color="#FFFF55"><b>[Debug]:</b></font><font color="#FFFFFF"> hi</font>'
		)
		t.eq(ChatFormat.rich(debug, 10, 11, false), '<font color="#FFFFFF">hi</font>', "only the second span")
		t.eq(ChatFormat.unescape("&quot;a&apos; &unknown; &amp;lt;"), "\"a' &unknown; &lt;", "&amp; last")
		-- Roblox's /whisper and /team point the box elsewhere: it says so.
		t.eq(ChatFormat.targetHint("RBXGeneral"), nil)
		t.eq(ChatFormat.targetHint("RBXWhisper:1_2", "Bob"), "To Bob (Backspace: everyone)")
		t.ok(ChatFormat.targetHint("RBXTeamBright red") ~= nil)
		t.eq(ChatFormat.shadowHex("#FFFF55"), "#3F3F15")
	end)

	t.test("chat format: unknown commands as Minecraft's two red lines; refused messages", function()
		local lines = ChatFormat.unknownCommand("/foo bar")
		t.eq(#lines, 2)
		t.eq(lines[1].text, "Unknown or incomplete command, see below for error")
		t.eq(lines[1].spans[1].colour, ChatFormat.RED)
		t.eq(lines[2].text, "foo bar<--[HERE]", "the input without its slash")
		t.ok(lines[2].spans[1].underline, "the unknown part underlined")
		t.ok(lines[2].spans[2].italic, "<--[HERE] in italics")
		t.eq(ChatFormat.unknownCommand("/")[2].text, "<--[HERE]", "an empty command")
		t.eq(ChatFormat.statusText("Success"), nil)
		t.eq(ChatFormat.statusText("Sending"), nil)
		t.eq(ChatFormat.statusText("InvalidPrivacySettings"), ChatFormat.DISABLED_PROFILE)
		t.ok(ChatFormat.statusText("Floodchecked") ~= nil)
		t.ok(ChatFormat.statusText("MessageTooLong") ~= nil)
		-- Unknown command lines wrap and show like any line.
		local log = newLog()
		for _, message in lines do
			ChatLog.add(log, message, 0)
		end
		t.eq(lineText(log.lines[1]), "foo bar<--[HERE]")
		t.eq(
			log.lines[1].rich,
			'<font color="#FF5555"><u>foo bar</u></font><font color="#FF5555"><i>&lt;--[HERE]</i></font>'
		)
	end)
end
