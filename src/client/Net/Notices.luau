--!strict
--[[
	Shows the server's Notice messages (Protocol.ServerMessage.Notice, e.g. the /gamemode command's
	feedback) in the chat, as system messages only this player sees.

	  Game chat        the game's own chat (Ui/Chat, which replaces Roblox's chat window) takes
	                   them once it runs (`setSink`): white lines, the debug prefix in bold
	                   yellow, at once (they never wait for Chat Delay).
	  TextChatService  otherwise RBXSystem:DisplaySystemMessage. The channel appears a moment after
	                   joining, so messages wait for it (in order) instead of being lost.
	  Legacy chat      StarterGui:SetCore("ChatMakeSystemMessage"), retried until the chat has
	                   registered it.

	`listen` lets a screen show them too (the structure block screen repeats the answers to its
	buttons on its status line, where the player is looking).

	`debug` shows the debug keys' feedback (Debug/DebugKeys) as Minecraft's debugFeedbackTranslated
	does: "[Debug]:" in bold yellow, then the message (the legacy chat shows it all in white).

	A notice may carry a link (Protocol.NoticeLink: /locate's coordinates and the "/tp" they
	suggest): the game's chat gets it with the text (green, clickable: Ui/Chat), Roblox's chat
	shows that part green (nothing to click there), the legacy chat plain.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Protocol = require(Shared.Net.Protocol)

local ClientNet = require(script.Parent.ClientNet)

-- Seconds to wait for the chat to be ready, and between legacy retries.
local CHAT_TIMEOUT = 60
local RETRY_DELAY = 0.5
-- Minecraft shows command feedback in white, the debug prefix in yellow (§e) and a link (the
-- coordinates /locate answers with) in green (§a).
local LEGACY_COLOUR = Color3.fromRGB(255, 255, 255)
local DEBUG_COLOUR = "#FFFF55"
local LINK_COLOUR = "#55FF55"

local Notices = {}

-- Rich text waiting for the system channel.
local queue: { string } = {}
local channel: TextChannel? = nil
local waiting = false

-- System messages are rich text: show the server's text (which may quote what a player typed) as
-- written. Quotes need no escaping outside tags, and plain apostrophes read better if rich text
-- is ever off.
local function escape(text: string): string
	return (string.gsub(text, "[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
end

local function showLegacy(text: string)
	task.spawn(function()
		local deadline = os.clock() + CHAT_TIMEOUT
		while true do
			local ok = pcall(StarterGui.SetCore, StarterGui, "ChatMakeSystemMessage", {
				Text = text,
				Color = LEGACY_COLOUR,
				Font = Enum.Font.SourceSansBold,
				TextSize = 18,
			})
			if ok or os.clock() > deadline then
				return
			end
			task.wait(RETRY_DELAY)
		end
	end)
end

local function flush()
	local system = channel
	if system == nil then
		return
	end
	while #queue > 0 do
		local rich = table.remove(queue, 1) :: string
		pcall(system.DisplaySystemMessage, system, rich)
	end
end

-- Finds the system channel once, then shows what queued up meanwhile.
local function findChannel()
	if waiting then
		return
	end
	waiting = true
	task.spawn(function()
		local channels = TextChatService:WaitForChild("TextChannels", CHAT_TIMEOUT)
		local system = channels and channels:WaitForChild("RBXSystem", CHAT_TIMEOUT)
		if system and system:IsA("TextChannel") then
			channel = system
			flush()
		else
			-- (CreateDefaultTextChannels off?) Drop these; a later notice looks again.
			warn("[IceVoxel] no RBXSystem text channel; notices are not shown")
			table.clear(queue)
			waiting = false
		end
	end)
end

local listeners: { (text: string) -> () } = {}

-- Where notices go instead of Roblox's chat: (text, debug prefix or nil, link or nil). Set by
-- Ui/Chat.
export type Sink = (text: string, prefix: string?, link: Protocol.NoticeLink?) -> ()
local sink: Sink? = nil

-- Sends every notice from now on to `fn` (the game's chat) instead of Roblox's chat.
function Notices.setSink(fn: Sink?)
	sink = fn
end

-- Calls `listener` with every notice shown from now on.
function Notices.listen(listener: (text: string) -> ())
	table.insert(listeners, listener)
end

-- Shows `text` (plain) in this player's chat, `rich` (its rich text form) where rich text shows;
-- `prefix`: the debug prefix that starts `text` (for the game's chat); `link` its link.
local function display(text: string, rich: string, prefix: string?, link: Protocol.NoticeLink?)
	for _, listener in listeners do
		task.spawn(listener, text)
	end
	local gameChat = sink
	if gameChat then
		if prefix then
			gameChat(string.sub(text, #prefix + 2), prefix)
		else
			gameChat(text, nil, link)
		end
		return
	end
	if TextChatService.ChatVersion == Enum.ChatVersion.LegacyChatService then
		showLegacy(text)
		return
	end
	table.insert(queue, rich)
	if channel then
		flush()
	else
		findChannel()
	end
end

-- Shows `text` in this player's chat; `link`: its clickable part (green).
function Notices.show(text: string, link: Protocol.NoticeLink?)
	local rich = escape(text)
	if link then
		local before = string.sub(text, 1, link.first - 1)
		local part = string.sub(text, link.first, link.last)
		local after = string.sub(text, link.last + 1)
		rich = `{escape(before)}<font color="{LINK_COLOUR}">{escape(part)}</font>{escape(after)}`
	end
	display(text, rich, nil, link)
end

-- Shows `text` after Minecraft's bold yellow debug prefix (`prefix`, "[Debug]:").
function Notices.debug(prefix: string, text: string)
	display(`{prefix} {text}`, `<font color="{DEBUG_COLOUR}"><b>{escape(prefix)}</b></font> {escape(text)}`, prefix)
end

function Notices.start()
	ClientNet.on(Protocol.ServerMessage.Notice, function(payload: buffer)
		if buffer.len(payload) >= 2 then
			local ok, text, link = pcall(Protocol.decodeNotice, payload)
			if ok then
				Notices.show(text, link)
			end
		end
	end)
end

return Notices
