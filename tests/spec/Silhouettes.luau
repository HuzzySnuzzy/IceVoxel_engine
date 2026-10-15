--[[
	The inventory family's own silhouettes (client Ui/Silhouettes): every name the look uses is
	drawn, inside the unit square, no rectangle or band thinner than a twentieth of it, solid enough
	to read (between a twentieth and three quarters of the square), never two the same, still there as 8 x 8 blocks (the header glyphs' size), mirror
	symmetric where they say so, a rounded rectangle's corners always less than half its shorter
	side (Ui/Masks draws those), an unknown name an empty drawing, and `render` at the sizes and
	sample count it promises.
]]

-- Every name another module asks for (Style.Dayz's headers and toggles, the inventory's worn
-- slots, closed accessory slots and crafting arrows).
local USED = {
	"head",
	"chest",
	"legs",
	"feet",
	"accessory",
	"backpack",
	"crafting",
	"vanity",
	"gear",
	"close",
	"items",
	"minus",
	"plus",
	"padlock",
	"chevron",
}

-- The thinnest a rectangle or a ring's band may be (a twentieth of the square: thinner vanishes
-- when shown small).
local THINNEST = 0.05 - 1e-9

return function(t, _shared, require, _server, client)
	local Silhouettes = require(client.Ui.Silhouettes)
	local Masks = require(client.Ui.Masks)
	local Theme = require(client.Ui.Theme)

	local function mean(mask: any): number
		local sum = 0
		for _, a in mask.alpha do
			sum += a
		end
		return sum / #mask.alpha
	end

	-- (Drawn once each: rendering is the slow part.)
	local masks: { [string]: any } = {}
	local function maskOf(name: string): any
		local mask = masks[name]
		if mask == nil then
			mask = Silhouettes.render(name)
			masks[name] = mask
		end
		return mask
	end

	t.test("silhouettes: every name used is drawn, and listed", function()
		local listed = {}
		for _, name in Silhouettes.NAMES do
			listed[name] = true
			t.ok(Silhouettes.has(name), `{name} drawn`)
			t.ok(#Silhouettes.ops(name) > 0, `{name}: operations`)
		end
		for _, name in USED do
			t.ok(listed[name] == true, `{name} listed`)
		end
		for name in Silhouettes.SYMMETRIC do
			t.ok(listed[name] == true, `symmetric {name} listed`)
		end
		t.eq(Silhouettes.SIZE, Theme.Size.MASK, "drawn at the look's mask size")
	end)

	t.test("silhouettes: shapes inside the unit square, corners Masks can draw", function()
		local function within(v: number, what: string)
			t.ok(v >= 0 and v <= 1, `{what}: {v} in 0..1`)
		end
		for _, name in Silhouettes.NAMES do
			for i, op in Silhouettes.ops(name) do
				local shape = op.shape :: any
				local what = `{name} op {i} ({shape.kind})`
				if shape.kind == "rect" then
					within(shape.x, what)
					within(shape.y, what)
					within(shape.x + shape.w, what)
					within(shape.y + shape.h, what)
					local r = shape.r or 0
					t.ok(r < math.min(shape.w, shape.h) / 2, `{what}: corner radius below half its side`)
					t.ok(math.min(shape.w, shape.h) >= THINNEST, `{what}: no thinner than a twentieth`)
				elseif shape.kind == "circle" or shape.kind == "ring" then
					within(shape.x - shape.r, what)
					within(shape.x + shape.r, what)
					within(shape.y - shape.r, what)
					within(shape.y + shape.r, what)
					if shape.kind == "ring" then
						t.ok(shape.width >= THINNEST and shape.width < shape.r, `{what}: a band, not a hairline`)
					end
				elseif shape.kind == "poly" then
					t.ok(#shape.points >= 6 and #shape.points % 2 == 0, `{what}: points in pairs`)
					for _, v in shape.points do
						within(v, what)
					end
				else
					t.ok(false, `{what}: a known kind`)
				end
			end
		end
	end)

	t.test("silhouettes: rendered at the size promised, solid enough to read, alphas in 0..1", function()
		for _, name in Silhouettes.NAMES do
			local mask = maskOf(name)
			t.eq(mask.w, Silhouettes.SIZE)
			t.eq(mask.h, Silhouettes.SIZE)
			for _, a in mask.alpha do
				if a < 0 or a > 1 then
					t.ok(false, `{name}: alpha {a} outside 0..1`)
					break
				end
			end
			local cover = mean(mask)
			t.ok(cover >= 0.05 and cover <= 0.75, `{name}: covers {cover} of its square`)
			-- (Edges are smooth: some pixels partly covered.)
			local partial = 0
			for _, a in mask.alpha do
				if a > 0 and a < 1 then
					partial += 1
				end
			end
			t.ok(partial > 0, `{name}: anti-aliased edges`)
		end
		local small = Silhouettes.render("plus", 12)
		t.eq(small.w, 12, "another size when asked")
	end)

	t.test("silhouettes: none the same, each still there as 8 x 8 blocks", function()
		local seen: { [string]: string } = {}
		for _, name in Silhouettes.NAMES do
			local mask = maskOf(name)
			local key = table.concat(Masks.rows(Masks.downsample(mask, 11, 11)), "/")
			t.ok(seen[key] == nil, `{name} differs from {seen[key] or "the rest"}`)
			seen[key] = name
			local blocks = 0
			for _, row in Masks.rows(Masks.downsample(mask, 8, 8)) do
				local _, count = string.gsub(row, "#", "")
				blocks += count
			end
			t.ok(blocks >= 6, `{name}: {blocks} blocks at 8 x 8`)
		end
	end)

	t.test("silhouettes: the symmetric ones are their own mirror image", function()
		for name in Silhouettes.SYMMETRIC do
			local mask = maskOf(name)
			local w, h = mask.w, mask.h
			local worst = 0
			for y = 0, h - 1 do
				for x = 0, w - 1 do
					local a = mask.alpha[y * w + x + 1]
					local b = mask.alpha[y * w + (w - 1 - x) + 1]
					worst = math.max(worst, math.abs(a - b))
				end
			end
			-- (A sample exactly on an edge may fall either side: one sample's worth at most.)
			t.ok(worst <= 1 / Silhouettes.SAMPLES ^ 2 + 1e-9, `{name}: mirror difference {worst}`)
		end
		-- The boot and the arrow are not symmetric, and say so.
		t.ok(Silhouettes.SYMMETRIC.feet == nil)
		t.ok(Silhouettes.SYMMETRIC.chevron == nil)
	end)

	t.test("silhouettes: an unknown name is an empty drawing, never an error", function()
		t.eq(#Silhouettes.ops("nothing"), 0)
		t.eq(Silhouettes.has("nothing"), false)
		local mask = Silhouettes.render("nothing", 8)
		t.eq(mean(mask), 0, "an empty mask")
		t.ok(table.isfrozen(Silhouettes.ops("nothing")), "the empty drawing is shared and frozen")
	end)
end
