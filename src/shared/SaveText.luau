--!strict
--[[
	The words and numbers about saved worlds that both sides show: the server's chat warnings
	(World/WorldSave), the saving toast and the Load World list (client Ui/SaveIndicator,
	Ui/MainMenu, Ui/WorldListRules). Pure, so the specs run it.

	  Sizes     megabytes as Roblox counts a DataStore key's 4 MB (1,048,576 bytes): one decimal
	            under 10 MB ("1.4 MB", "0.3 MB"), whole above ("64 MB"); under 0.1 MB in KB
	            ("12 KB"), under a KB in bytes.
	  Saved     the toast after a save: "World saved — 1.4 MB of 64 MB (largest region 0.3 / 4 MB)";
	            a refused or failed one says why.
	  Dates     "2026-10-07 14:03" from a date table (os.date("*t")'s fields), as the list
	            shows when a world was last played.
	  States    what the title screen and the chat say about saving (Protocol.SaveState).
]]

local SaveText = {}

SaveText.MB = 1048576

-- `bytes` as Minecraft-ish text: "1.4 MB", "64 MB", "12 KB", "512 B".
function SaveText.size(bytes: number): string
	bytes = math.max(0, bytes)
	if bytes >= SaveText.MB * 10 then
		return `{math.floor(bytes / SaveText.MB + 0.5)} MB`
	elseif bytes >= SaveText.MB / 10 then
		return `{string.format("%.1f", bytes / SaveText.MB)} MB`
	elseif bytes >= 1024 then
		return `{math.floor(bytes / 1024 + 0.5)} KB`
	end
	return `{math.floor(bytes)} B`
end

-- Megabytes for "0.3 / 4 MB": one decimal under 10, whole above, never "0.0" for some bytes.
function SaveText.megabytes(bytes: number): string
	local mb = math.max(0, bytes) / SaveText.MB
	if mb >= 10 or mb == math.floor(mb) then
		return tostring(math.floor(mb + 0.5))
	elseif bytes > 0 and mb < 0.1 then
		return "0.1"
	end
	return string.format("%.1f", mb)
end

-- The toast's line after a save: what the world takes of its most, and its largest key.
function SaveText.saved(bytes: number, max: number, largest: number, keyLimit: number): string
	return `World saved — {SaveText.size(bytes)} of {SaveText.size(max)} (largest region {SaveText.megabytes(largest)} / {SaveText.megabytes(
		keyLimit
	)} MB)`
end

-- The share of the most a world may take that `bytes` is (0..1+).
function SaveText.share(bytes: number, max: number): number
	return if max > 0 then bytes / max else 0
end

-- The chat's warning when a world nears its most: "The world takes 52 MB of its 64 MB (81%)".
function SaveText.nearing(bytes: number, max: number): string
	return `The world takes {SaveText.size(bytes)} of its {SaveText.size(max)} ({math.floor(
		SaveText.share(bytes, max) * 100
	)}%): it can't be saved once it is full`
end

-- A date table's text: "2026-10-07 14:03" (nil fields as 0).
function SaveText.date(t: { [string]: any }): string
	return string.format(
		"%04d-%02d-%02d %02d:%02d",
		tonumber(t.year) or 0,
		tonumber(t.month) or 0,
		tonumber(t.day) or 0,
		tonumber(t.hour) or 0,
		tonumber(t.min) or 0
	)
end

-- What saving is doing (Protocol.SaveState) in words, nil when all is well.
function SaveText.state(state: number, reason: string?): string?
	if state == 1 then
		return "Automatic saving is off (/save-on turns it back on)"
	elseif state == 2 then
		return `Worlds can't be saved here: {reason or "no DataStore access"}`
	elseif state == 3 then
		return `This world is not being saved: {reason or "it could not be read"}`
	end
	return nil
end

return SaveText
