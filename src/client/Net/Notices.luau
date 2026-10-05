--!strict
--[[
	Shows the server's Notice messages (Protocol.ServerMessage.Notice, e.g. the /gamemode command's
	feedback) in the chat, as system messages only this player sees.

	  TextChatService  RBXSystem:DisplaySystemMessage. The channel appears a moment after joining,
	                   so messages wait for it (in order) instead of being lost.
	  Legacy chat      StarterGui:SetCore("ChatMakeSystemMessage"), retried until the chat has
	                   registered it.

	`listen` lets a screen show them too (the structure block screen repeats the answers to its
	buttons on its status line, where the player is looking).

	`debug` shows the debug keys' feedback (Debug/DebugKeys) as Minecraft's debugFeedbackTranslated
	does: "[Debug]:" in bold yellow, then the message (the legacy chat shows it all in white).
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
-- Minecraft shows command feedback in white, and the debug prefix in yellow (§e).
local LEGACY_COLOUR = Color3.fromRGB(255, 255, 255)
local DEBUG_COLOUR = "#FFFF55"

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

-- Calls `listener` with every notice shown from now on.
function Notices.listen(listener: (text: string) -> ())
	table.insert(listeners, listener)
end

-- Shows `text` (plain) in this player's chat, `rich` (its rich text form) where rich text shows.
local function display(text: string, rich: string)
	for _, listener in listeners do
		task.spawn(listener, text)
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

-- Shows `text` in this player's chat.
function Notices.show(text: string)
	display(text, escape(text))
end

-- Shows `text` after Minecraft's bold yellow debug prefix (`prefix`, "[Debug]:").
function Notices.debug(prefix: string, text: string)
	display(`{prefix} {text}`, `<font color="{DEBUG_COLOUR}"><b>{escape(prefix)}</b></font> {escape(text)}`)
end

function Notices.start()
	ClientNet.on(Protocol.ServerMessage.Notice, function(payload: buffer)
		if buffer.len(payload) >= 2 then
			local ok, text = pcall(Protocol.decodeNotice, payload)
			if ok then
				Notices.show(text)
			end
		end
	end)
end

return Notices
