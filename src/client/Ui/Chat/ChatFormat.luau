--!strict
--[[
	What a chat line says and how it looks: Minecraft 1.20.1's chat messages (ChatComponent's lines,
	the en_us texts) as coloured spans, and the rich text the chat draws them with. Pure: colours
	are hex strings, so the tests run it; Ui/Chat turns them into labels.

	  Kinds      player   "<Name> message" in white (chat.type.text), from TextChatService's
	                      general channel
	             whisper  Roblox's /whisper channels as Minecraft's private messages, gray italic:
	                      "Name whispers to you: ..." / "You whisper to Name: ..."
	             team     Roblox's team channels: "[Team] <Name> message"
	             join     "Name joined the game" / "Name left the game" in yellow
	                      (multiplayer.player.joined / left)
	             notice   the server's messages (Protocol Notice: command feedback, Age
	                      announcements, structure saves) in white, Minecraft's command feedback
	             debug    the debug keys' feedback: "[Debug]:" bold yellow, then white
	                      (debugFeedbackTranslated)
	             error    what the chat itself refuses, in red: unknown commands, chat turned off,
	                      a message Roblox did not send
	             system   Roblox's own system messages (rich text stripped), gray
	  Visibility the Chat setting (Minecraft's chatVisibility): Shown shows everything, Commands
	             Only every kind but players' messages (player, whisper, team), Hidden nothing.
	  Rich text  every span in <font color>, with <b>, <i>, <u>; the shadow copy (Minecraft's text
	             shadow, a quarter of the colour's brightness) has the same tags in shadow colours.
	             Text from players arrives escaped by TextChatService (&lt; ...): it is unescaped
	             for the plain text and escaped again for the labels, so "<3" reads as typed.
	  Target     Roblox's /whisper and /team point the box at their channel: the box says so
	             (`targetHint`).
	  Unknown    a command no TextChatCommand answers is not sent: Minecraft's two red lines,
	             "Unknown or incomplete command, see below for error" and the input (without the
	             slash) underlined, then "<--[HERE]" in italics (Commands.performCommand's
	             context: the cursor of an unknown command is at its start).
]]

export type Kind = "player" | "whisper" | "team" | "join" | "notice" | "debug" | "error" | "system"

export type Span = {
	text: string,
	-- "#RRGGBB".
	colour: string,
	bold: boolean?,
	italic: boolean?,
	underline: boolean?,
}

export type Message = {
	kind: Kind,
	spans: { Span },
	-- The spans' texts joined: what is wrapped and searched.
	text: string,
}

local ChatFormat = {}

-- Minecraft's chat colours (ChatFormatting: §f, §e, §c, §7) and the suggestion list's.
ChatFormat.WHITE = "#FFFFFF"
ChatFormat.YELLOW = "#FFFF55"
ChatFormat.RED = "#FF5555"
ChatFormat.GRAY = "#AAAAAA"
ChatFormat.SUGGESTION = "#AAAAAA"
ChatFormat.SUGGESTION_SELECTED = "#FFFF00"

-- The Chat setting's values (PlayerSettings "chatVisibility").
ChatFormat.SHOWN = 1
ChatFormat.COMMANDS_ONLY = 2
ChatFormat.HIDDEN = 3

-- Minecraft's texts (en_us).
ChatFormat.UNKNOWN_COMMAND = "Unknown or incomplete command, see below for error"
ChatFormat.HERE = "<--[HERE]"
ChatFormat.DISABLED_OPTIONS = "Chat disabled in client options."
ChatFormat.DISABLED_PROFILE = "Chat not allowed by account settings."
ChatFormat.CANNOT_SEND = "Cannot send chat message"
ChatFormat.UNAVAILABLE = "Chat is not available here"
-- Roblox's refusals of a sent message (TextChatMessageStatus names).
ChatFormat.STATUS_TEXT = table.freeze({
	Floodchecked = "You must wait before sending another message.",
	InvalidPrivacySettings = ChatFormat.DISABLED_PROFILE,
	InvalidTextChannelPermissions = "You can't chat in this channel.",
	MessageTooLong = "Your message is too long.",
	TextFilterFailed = "Your message could not be sent.",
	ModerationTimeout = "Your message could not be sent.",
	Unknown = "Your message could not be sent.",
} :: { [string]: string })

-- Kinds that are other players talking (hidden by Commands Only, delayed by Chat Delay).
local PLAYER_KINDS: { [string]: boolean } = { player = true, whisper = true, team = true }

local function span(text: string, colour: string, bold: boolean?, italic: boolean?, underline: boolean?): Span
	return { text = text, colour = colour, bold = bold, italic = italic, underline = underline }
end

-- A message of `kind` from its spans.
function ChatFormat.message(kind: Kind, spans: { Span }): Message
	local parts = table.create(#spans)
	for i, part in spans do
		parts[i] = part.text
	end
	return { kind = kind, spans = spans, text = table.concat(parts) }
end

-- Is `kind` other players talking?
function ChatFormat.isPlayerKind(kind: Kind): boolean
	return PLAYER_KINDS[kind] == true
end

-- Does the Chat setting `visibility` show messages of `kind`?
function ChatFormat.shows(kind: Kind, visibility: number): boolean
	if visibility >= ChatFormat.HIDDEN then
		return false
	elseif visibility >= ChatFormat.COMMANDS_ONLY then
		return not PLAYER_KINDS[kind]
	end
	return true
end

--[[ The kinds ]]

function ChatFormat.player(name: string, text: string): Message
	return ChatFormat.message("player", { span(`<{name}> {text}`, ChatFormat.WHITE) })
end

function ChatFormat.team(name: string, text: string): Message
	return ChatFormat.message("team", { span(`[Team] <{name}> {text}`, ChatFormat.WHITE) })
end

-- A private message: from `name` to this player, or (`outgoing`) from this player to `name`.
function ChatFormat.whisper(name: string, text: string, outgoing: boolean): Message
	local line = if outgoing then `You whisper to {name}: {text}` else `{name} whispers to you: {text}`
	return ChatFormat.message("whisper", { span(line, ChatFormat.GRAY, false, true) })
end

function ChatFormat.joined(name: string): Message
	return ChatFormat.message("join", { span(`{name} joined the game`, ChatFormat.YELLOW) })
end

function ChatFormat.left(name: string): Message
	return ChatFormat.message("join", { span(`{name} left the game`, ChatFormat.YELLOW) })
end

function ChatFormat.notice(text: string): Message
	return ChatFormat.message("notice", { span(text, ChatFormat.WHITE) })
end

function ChatFormat.debug(prefix: string, text: string): Message
	return ChatFormat.message("debug", { span(prefix, ChatFormat.YELLOW, true), span(` {text}`, ChatFormat.WHITE) })
end

function ChatFormat.error(text: string): Message
	return ChatFormat.message("error", { span(text, ChatFormat.RED) })
end

function ChatFormat.system(text: string): Message
	return ChatFormat.message("system", { span(text, ChatFormat.GRAY) })
end

-- Minecraft's two lines for `input` (what was typed, with its slash) that no command answers.
function ChatFormat.unknownCommand(input: string): { Message }
	local command = if string.sub(input, 1, 1) == "/" then string.sub(input, 2) else input
	local context: { Span } = {}
	if command ~= "" then
		table.insert(context, span(command, ChatFormat.RED, false, false, true))
	end
	table.insert(context, span(ChatFormat.HERE, ChatFormat.RED, false, true))
	return { ChatFormat.error(ChatFormat.UNKNOWN_COMMAND), ChatFormat.message("error", context) }
end

-- What to say when Roblox refused a sent message (a TextChatMessageStatus name); nil: it went.
function ChatFormat.statusText(status: string): string?
	return ChatFormat.STATUS_TEXT[status]
end

--[[ TextChatService's messages ]]

-- What Ui/Chat reads off a TextChatMessage.
export type Incoming = {
	text: string,
	-- The channel's name ("RBXGeneral", "RBXSystem", "RBXWhisper:1_2", "RBXTeamBright red"...).
	channel: string,
	-- The sender's name (nil: a system message).
	from: string?,
	-- Sent by this player.
	own: boolean,
	-- The other player of a whisper channel.
	partner: string?,
}

--[[
	The chat box's hint while what is typed goes to a whisper or team channel (Roblox's /whisper
	and /team switch the target: ChatInputBarConfiguration.TargetTextChannel); nil for the general
	channel. Backspace in an empty box goes back to everyone.
]]
function ChatFormat.targetHint(channel: string, partner: string?): string?
	if string.sub(channel, 1, 11) == "RBXWhisper:" then
		return `To {partner or "?"} (Backspace: everyone)`
	elseif string.sub(channel, 1, 7) == "RBXTeam" then
		return "To your team (Backspace: everyone)"
	end
	return nil
end

-- The chat message for a TextChatService message.
function ChatFormat.incoming(info: Incoming): Message
	local from = info.from
	if from == nil then
		return ChatFormat.system(ChatFormat.stripTags(info.text))
	end
	local text = ChatFormat.unescape(info.text)
	local channel = info.channel
	if string.sub(channel, 1, 11) == "RBXWhisper:" then
		if info.own then
			return ChatFormat.whisper(info.partner or "?", text, true)
		end
		return ChatFormat.whisper(from, text, false)
	elseif string.sub(channel, 1, 7) == "RBXTeam" then
		return ChatFormat.team(from, text)
	end
	return ChatFormat.player(from, text)
end

--[[ Rich text ]]

local ESCAPES = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }

-- `text` safe inside rich text.
function ChatFormat.escape(text: string): string
	return (string.gsub(text, "[&<>]", ESCAPES))
end

local ENTITIES = { lt = "<", gt = ">", quot = '"', apos = "'", amp = "&" }

-- Rich text's entities back to characters (&lt; &gt; &quot; &apos; &amp;).
function ChatFormat.unescape(text: string): string
	return (string.gsub(text, "&(%a+);", function(name: string): string
		return ENTITIES[name] or `&{name};`
	end))
end

-- Rich text as plain text: tags dropped, entities back to characters.
function ChatFormat.stripTags(text: string): string
	return ChatFormat.unescape((string.gsub(text, "<[^<>]*>", "")))
end

-- Minecraft's shadow colour of `hex`: a quarter of its brightness.
function ChatFormat.shadowHex(hex: string): string
	local r = tonumber(string.sub(hex, 2, 3), 16) or 0
	local g = tonumber(string.sub(hex, 4, 5), 16) or 0
	local b = tonumber(string.sub(hex, 6, 7), 16) or 0
	return string.format("#%02X%02X%02X", r // 4, g // 4, b // 4)
end

--[[
	The rich text of bytes `first`..`last` of `message.text` (a wrapped line), each span's part in
	its colour and style; `shadow`: the shadow copy's colours.
]]
function ChatFormat.rich(message: Message, first: number, last: number, shadow: boolean): string
	local out = {}
	local offset = 0
	for _, part in message.spans do
		local from, to = offset + 1, offset + #part.text
		offset = to
		local a, b = math.max(from, first), math.min(to, last)
		if a > b then
			continue
		end
		local text = ChatFormat.escape(string.sub(part.text, a - from + 1, b - from + 1))
		if part.underline then
			text = `<u>{text}</u>`
		end
		if part.italic then
			text = `<i>{text}</i>`
		end
		if part.bold then
			text = `<b>{text}</b>`
		end
		local colour = if shadow then ChatFormat.shadowHex(part.colour) else part.colour
		table.insert(out, `<font color="{colour}">{text}</font>`)
	end
	return table.concat(out)
end

return ChatFormat
