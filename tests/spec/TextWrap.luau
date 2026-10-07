--[[
	Ui/TextWrap: rows of a fixed width (the skill tree's info lines), with a monospaced measure
	like the Arcade font's (8 pixels a character at Style.TEXT_SIZE).
]]

return function(t, _shared, require, _server, client)
	local TextWrap = require(client.Ui.TextWrap)

	local function measure(text: string): number
		return (utf8.len(text) or #text) * 8
	end
	local function join(list: { string }): string
		return table.concat(list, "|")
	end
	local function texts(rows): { string }
		local out = {}
		for _, row in rows do
			table.insert(out, row.text)
		end
		return out
	end

	t.test("wrap: at word breaks, never past the width; long words by characters", function()
		t.eq(join(TextWrap.wrap("Mine 10% faster", 200, measure)), join({ "Mine 10% faster" }), "fits")
		t.eq(
			join(TextWrap.wrap("Mine 10% faster with diamond tools", 120, measure)),
			join({ "Mine 10% faster", "with diamond", "tools" })
		)
		for _, row in TextWrap.wrap("Mine 10% faster with diamond tools", 120, measure) do
			t.ok(measure(row) <= 120, `"{row}" fits`)
		end
		t.eq(join(TextWrap.wrap("", 120, measure)), join({ "" }), "an empty line stays a row")
		t.eq(
			join(TextWrap.wrap("Thermoregulation", 64, measure)),
			join({ "Thermore", "gulation" }),
			"a word wider than the row"
		)
		t.eq(join(TextWrap.wrap("a Thermoregulation b", 64, measure)), join({ "a", "Thermore", "gulation", "b" }))
	end)

	t.test("fit: as many rows as there are; the status line keeps its place", function()
		local A, B, C = "white", "grey", "red"
		local lines = {
			{ text = "Diamond Cutting", colour = A },
			{ text = "Mine 10% faster with diamond tools and more words here", colour = B },
			{ text = "Costs 3 skill points", colour = B },
			{ text = "Needs Ironworking", colour = B },
			{ text = "Reach the Industrial Age first", colour = C },
		}
		local rows = TextWrap.fit(lines, 5, 160, measure)
		t.eq(#rows, 5, "at most 5 rows")
		t.eq(rows[1].text, "Diamond Cutting")
		t.eq(rows[#rows].colour, C, "the status is last")
		t.eq(texts(rows)[#rows - 1] .. " " .. rows[#rows].text, "Reach the Industrial Age first", "all of it")
		local short = TextWrap.fit(
			{ { text = "Stone Age", colour = A }, { text = "Where everyone starts", colour = B } },
			5,
			400,
			measure
		)
		t.eq(join(texts(short)), join({ "Stone Age", "Where everyone starts" }), "short info as it is")
		t.eq(
			#TextWrap.fit({ { text = "one two three four five six", colour = A } }, 2, 40, measure),
			2,
			"a single line cut"
		)
	end)
end
