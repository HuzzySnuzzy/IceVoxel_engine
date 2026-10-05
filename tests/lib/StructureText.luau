--[[
	Structure data (IVS1) in pasted text: what tests/structure finds in a chat message, a text file
	or a library module, and how it decodes data with chat words after it. Pure (no Lune APIs), so
	tests/spec/StructureTemplate covers the paths "paste it into chat and Claude decodes it" takes.

	  findTexts(source)          every "IVS1:" text in `source`: from the prefix through the
	                             base64url characters and whitespace after it, up to the next
	                             "IVS1:", trailing whitespace cut (quotes, commas, brackets, code
	                             fences and punctuation around it end it)
	  decodeLoose(decode, text)  `decode` (Template.decode) of `text`, else of the longest part of
	                             it that ends before a space or line break and decodes (words after
	                             the data look like base64 too); a part that never decodes gives
	                             the whole text's message (cut off, damaged...)
]]

local StructureText = {}

-- Bytes an IVS1 text runs through: base64url and whitespace.
local DATA: { [number]: boolean } = {}
for c = string.byte("A"), string.byte("Z") do
	DATA[c] = true
end
for c = string.byte("a"), string.byte("z") do
	DATA[c] = true
end
for c = string.byte("0"), string.byte("9") do
	DATA[c] = true
end
local SPACE: { [number]: boolean } = {}
for _, c in { " ", "\t", "\n", "\r", "\v", "\f" } do
	SPACE[string.byte(c)] = true
	DATA[string.byte(c)] = true
end
DATA[string.byte("-")] = true
DATA[string.byte("_")] = true

-- The last byte at or before `at` that is not whitespace (0 if none): backward scans, as a
-- pattern anchored at the end would rescan every whitespace run inside the text.
local function trimEnd(text: string, at: number): number
	while at > 0 and SPACE[string.byte(text, at)] do
		at -= 1
	end
	return at
end

function StructureText.findTexts(source: string): { string }
	local starts = {}
	local from = 1
	while true do
		local start = string.find(source, "IVS1:", from, true)
		if start == nil then
			break
		end
		table.insert(starts, start)
		from = start + 5
	end
	local texts = {}
	for i, start in starts do
		local limit = if starts[i + 1] then starts[i + 1] - 1 else #source
		local stop = start + 5
		while stop <= limit and DATA[string.byte(source, stop)] do
			stop += 1
		end
		table.insert(texts, string.sub(source, start, trimEnd(source, stop - 1)))
	end
	return texts
end

function StructureText.decodeLoose(
	decode: (text: string) -> (any, string?, { string }?),
	text: string
): (any, string?, { string }?, string)
	local t, err, warnings = decode(text)
	if t then
		return t, err, warnings, text
	end
	local cut = #text
	while true do
		-- (The last word goes: back over it, then over the whitespace before it.)
		while cut > 0 and not SPACE[string.byte(text, cut)] do
			cut -= 1
		end
		cut = trimEnd(text, cut)
		if cut <= 5 then
			return nil, err, nil, text
		end
		local part = string.sub(text, 1, cut)
		local shorter, _, partWarnings = decode(part)
		if shorter then
			return shorter, nil, partWarnings, part
		end
	end
end

return StructureText
