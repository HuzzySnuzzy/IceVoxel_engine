--!strict
--[[
	Wrapping text into rows of a fixed width, pure (no Roblox APIs, so the tests run it): the
	caller measures (Style.textWidth on the client, a fixed advance in tests).

	  `wrap`   cuts a text into rows at word breaks, a row as wide as fits; a word wider than a
	           row is cut by characters (never a row past the width, unless a single character is
	           wider). An empty text is one empty row.
	  `fit`    wraps lines (text and colour) into at most `rows` rows; when they don't all fit, the
	           last line keeps its rows (a status: ready, locked and why) and the rows before it
	           give way from the end.
]]

export type Measure = (text: string) -> number
export type Line = { text: string, colour: Color3 }

local TextWrap = {}

function TextWrap.wrap(text: string, width: number, measure: Measure): { string }
	local out: { string } = {}
	local current = ""
	for word in string.gmatch(text, "%S+") do
		local candidate = if current == "" then word else current .. " " .. word
		if measure(candidate) <= width then
			current = candidate
			continue
		end
		if current ~= "" then
			table.insert(out, current)
		end
		current = word
		-- (A word wider than the row: as many characters as fit, then the rest.)
		while measure(current) > width do
			local length = utf8.len(current) or #current
			if length <= 1 then
				break
			end
			local cut = length - 1
			while cut > 1 and measure(string.sub(current, 1, (utf8.offset(current, cut + 1) or 1) - 1)) > width do
				cut -= 1
			end
			local at = (utf8.offset(current, cut + 1) or (#current + 1)) - 1
			table.insert(out, string.sub(current, 1, at))
			current = string.sub(current, at + 1)
		end
	end
	table.insert(out, current)
	return out
end

function TextWrap.fit(lines: { Line }, rows: number, width: number, measure: Measure): { Line }
	local out: { Line } = {}
	for _, line in lines do
		for _, text in TextWrap.wrap(line.text, width, measure) do
			table.insert(out, { text = text, colour = line.colour })
		end
	end
	if #out <= rows or #lines < 2 then
		return table.move(out, 1, math.min(#out, rows), 1, {})
	end
	local last = lines[#lines]
	local tail = TextWrap.wrap(last.text, width, measure)
	local keep = math.max(rows - #tail, 0)
	local trimmed: { Line } = table.move(out, 1, keep, 1, {})
	for i = 1, math.min(#tail, rows) do
		table.insert(trimmed, { text = tail[i], colour = last.colour })
	end
	return trimmed
end

return TextWrap
