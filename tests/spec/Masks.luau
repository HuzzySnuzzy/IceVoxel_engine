--[[
	Anti-aliased masks from vector shapes (client Ui/Masks): the rendered size and alphas in 0..1, a
	full rectangle covering everything, a half-plane's edge column half covered with 4 x 4 samples,
	a circle's area close to pi r squared, cuts taking area out, rounded corners and rings and the
	even-odd polygon, downsampling keeping the mean alpha, the "#" / "." rows of the blocky art, and
	the vignette: clear inside, `edge` at the corners, rising along the diagonal.
]]

return function(t, _shared, require, _server, client)
	local Masks = require(client.Ui.Masks)

	local function mean(mask: any): number
		local sum = 0
		for _, a in mask.alpha do
			sum += a
		end
		return sum / #mask.alpha
	end

	local function at(mask: any, x: number, y: number): number
		return mask.alpha[y * mask.w + x + 1]
	end

	t.test("masks: render sizes and alphas", function()
		local mask = Masks.render({ { shape = { kind = "circle", x = 0.5, y = 0.5, r = 0.4 } } }, 12, 9)
		t.eq(mask.w, 12)
		t.eq(mask.h, 9)
		t.eq(#mask.alpha, 12 * 9)
		for i, a in mask.alpha do
			t.ok(a >= 0 and a <= 1, `alpha {i} in 0..1`)
		end
		local full = Masks.render({ { shape = { kind = "rect", x = 0, y = 0, w = 1, h = 1 } } }, 8, 8)
		for i, a in full.alpha do
			t.eq(a, 1, `a full rect is 1 at {i}`)
		end
		local nothing = Masks.render({}, 4, 4)
		t.eq(mean(nothing), 0, "no shapes: nothing")
	end)

	t.test("masks: a half-plane's edge column is half covered with 4 samples", function()
		-- The edge at 3.5 pixels of 7: column 3 is cut down its middle.
		local mask = Masks.render({ { shape = { kind = "rect", x = 0, y = 0, w = 0.5, h = 1 } } }, 7, 4, 4)
		for y = 0, 3 do
			t.eq(at(mask, 2, y), 1, "inside")
			t.eq(at(mask, 3, y), 0.5, "the edge column")
			t.eq(at(mask, 4, y), 0, "outside")
		end
	end)

	t.test("masks: a circle's area, cuts, rings, rounded corners and polygons", function()
		local size = 48
		local r = 0.4
		local circle = Masks.render({ { shape = { kind = "circle", x = 0.5, y = 0.5, r = r } } }, size, size)
		local area = mean(circle)
		t.ok(math.abs(area - math.pi * r * r) <= 0.02 * math.pi * r * r, `area {area} near pi r^2`)
		-- A cut takes its area out again.
		local cut = Masks.render({
			{ shape = { kind = "circle", x = 0.5, y = 0.5, r = r } },
			{ shape = { kind = "circle", x = 0.5, y = 0.5, r = 0.2 }, cut = true },
		}, size, size)
		local expected = math.pi * (r * r - 0.04)
		t.ok(math.abs(mean(cut) - expected) <= 0.03 * expected, "the cut circle's area")
		t.eq(at(cut, 24, 24), 0, "the hole is clear")
		-- A ring of the same radii: the same area.
		local ring = Masks.render({ { shape = { kind = "ring", x = 0.5, y = 0.5, r = r, width = 0.2 } } }, size, size)
		t.ok(math.abs(mean(ring) - mean(cut)) < 0.01, "a ring is a circle with its middle cut")
		-- Rounded corners leave the corner clear but the middle full.
		local rounded =
			Masks.render({ { shape = { kind = "rect", x = 0, y = 0, w = 1, h = 1, r = 0.25 } } }, size, size)
		t.eq(at(rounded, 0, 0), 0, "the corner is rounded off")
		t.eq(at(rounded, 24, 24), 1)
		t.eq(at(rounded, 24, 0), 1, "the middle of an edge stays")
		-- A triangle covers half its bounding square.
		local triangle = Masks.render({ { shape = { kind = "poly", points = { 0, 0, 1, 0, 0, 1 } } } }, size, size)
		t.ok(math.abs(mean(triangle) - 0.5) < 0.02, "a triangle's half")
		-- Even-odd: a square drawn twice over itself in one outline is empty inside the inner one.
		local frame = Masks.render({
			{
				shape = {
					kind = "poly",
					points = {
						0,
						0,
						1,
						0,
						1,
						1,
						0,
						1,
						0,
						0,
						0.25,
						0.25,
						0.25,
						0.75,
						0.75,
						0.75,
						0.75,
						0.25,
						0.25,
						0.25,
					},
				},
			},
		}, size, size)
		t.eq(at(frame, 24, 24), 0, "the even-odd hole")
		t.eq(at(frame, 2, 24), 1, "the frame")
	end)

	t.test("masks: downsample keeps the mean alpha", function()
		local star = Masks.render({
			{
				shape = {
					kind = "poly",
					points = { 0.5, 0, 0.62, 0.38, 1, 0.5, 0.62, 0.62, 0.5, 1, 0.38, 0.62, 0, 0.5, 0.38, 0.38 },
				},
			},
			{ shape = { kind = "circle", x = 0.5, y = 0.5, r = 0.1 }, cut = true },
		}, 48, 48)
		for _, size in { 11, 9, 14, 24, 5 } do
			local small = Masks.downsample(star, size, size)
			t.eq(small.w, size)
			t.eq(small.h, size)
			t.ok(math.abs(mean(small) - mean(star)) <= 0.05 * mean(star), `{size}: mean kept`)
			for _, a in small.alpha do
				t.ok(a >= 0 and a <= 1 + 1e-9, "alpha in 0..1")
			end
		end
		local wide = Masks.downsample(star, 20, 8)
		t.ok(math.abs(mean(wide) - mean(star)) <= 0.05 * mean(star), "unequal axes")
	end)

	t.test("masks: rows are the blocky art", function()
		local mask = Masks.render({ { shape = { kind = "rect", x = 0, y = 0, w = 0.5, h = 1 } } }, 6, 3)
		local rows = Masks.rows(mask)
		t.eq(#rows, 3)
		for _, row in rows do
			t.eq(#row, 6)
			t.eq(row, "###...")
		end
		local small = Masks.rows(Masks.downsample(mask, 11, 11), 0.5)
		t.eq(#small, 11)
		t.eq(#small[1], 11)
		for _, row in small do
			t.ok(string.match(row, "^[#.]+$") ~= nil, "only # and .")
		end
		t.eq(Masks.rows(mask, 1.1)[1], "......", "a threshold over 1: nothing")
	end)

	t.test("masks: the vignette is clear inside, edge at the corners, rising along the diagonal", function()
		local w, h, inner, edge = 64, 36, 0.45, 0.7
		local mask = Masks.vignette(w, h, inner, edge)
		t.eq(#mask.alpha, w * h)
		t.eq(at(mask, w // 2, h // 2), 0, "the centre")
		t.near(at(mask, 0, 0), edge, 1e-9, "a corner")
		t.near(at(mask, w - 1, h - 1), edge, 1e-9, "the other corner")
		local previous = -1
		for i = 0, 31 do
			local x = w // 2 + math.floor(i * (w // 2 - 1) / 31)
			local y = h // 2 + math.floor(i * (h // 2 - 1) / 31)
			local a = at(mask, x, y)
			t.ok(a >= previous - 1e-12, `monotonic at step {i}`)
			previous = a
		end
		for _, a in mask.alpha do
			t.ok(a >= 0 and a <= edge + 1e-9, "never past edge")
		end
		-- Everything within `inner` of the centre is clear.
		local cx, cy = w / 2, h / 2
		local far = math.sqrt(((w - 0.5 - cx) / w) ^ 2 + ((h - 0.5 - cy) / h) ^ 2)
		for y = 0, h - 1 do
			for x = 0, w - 1 do
				local d = math.sqrt(((x + 0.5 - cx) / w) ^ 2 + ((y + 0.5 - cy) / h) ^ 2) / far
				if d <= inner then
					t.eq(at(mask, x, y), 0, `clear inside at {x}, {y}`)
				end
			end
		end
	end)
end
