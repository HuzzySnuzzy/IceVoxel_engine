--!strict
--[[
	Anti-aliased alpha masks drawn from vector shapes: the silhouettes, glyphs and badges of the
	inventory and the HUD's status icons, and the vignette behind an open inventory. Pure: no Roblox
	APIs, so the specs check the drawing (tests/spec/Masks).

	A drawing is a list of operations, applied in order to every sample: a shape either paints
	its area in (alpha 1) or, with `cut`, takes it out again (alpha 0), so a ring is a circle with a
	smaller one cut out and a padlock is a body with its keyhole cut. Shapes are in unit coordinates:
	0..1 across the mask's width and 0..1 down its height, whatever its pixel size (on a mask that is
	not square a circle is an ellipse in pixels).

	  circle  centre (x, y), radius r
	  rect    top left (x, y), w x h, corners rounded by `r` (0 or nil: square corners)
	  poly    the points x1, y1, x2, y2, ... in order, filled by the even-odd rule (a star drawn
	          as one outline keeps a hole in its middle)
	  ring    the band of a circle's outline: centre (x, y), from radius r - width out to r

	`render` samples each pixel `samples` x `samples` times on a regular grid (4 x 4 unless told
	otherwise) and keeps the share of samples inside as the pixel's alpha (0..1), so edges come out
	smooth at any size; `begin` and `step` draw the same mask a few rows at a time, so a caller
	with a frame budget can stop in the middle of a mask. The masks are drawn once, at 48 x 48 px (Ui/Theme's Size.MASK), and shown
	smaller by the GPU, or `downsample`d (each target pixel the area-weighted mean of the source
	pixels it covers, so the mean alpha is kept) when a smaller copy is needed. `rows` turns a mask
	into "#" / "." text rows, the blocky art drawn with Frames where images can't be made.

	`vignette` is the darkening at the edges behind an open screen: no alpha inside `inner` (a
	share of the distance from the centre to the corners), `edge` at the corners, and a smoothstep
	between, so it is monotonic from the centre outwards.
]]

export type Shape =
	{ kind: "circle", x: number, y: number, r: number }
	| { kind: "rect", x: number, y: number, w: number, h: number, r: number? }
	| { kind: "poly", points: { number } }
	| { kind: "ring", x: number, y: number, r: number, width: number }
-- One step of a drawing: the shape paints in, or with `cut` takes out.
export type Op = { shape: Shape, cut: boolean? }
-- `w` x `h` pixels, their alpha (0..1) row by row from the top left.
export type Mask = { w: number, h: number, alpha: { number } }
-- A mask being drawn (`begin`): `step` draws its next rows into `mask`; `row` rows are done.
export type Job = { ops: { Op }, samples: number, row: number, mask: Mask }
-- What a mask's maker gives Style.Dayz: the mask drawn, or a job to draw over frames.
export type Drawing = Mask | Job

local Masks = {}

-- Samples per axis in each pixel unless told otherwise.
Masks.SAMPLES = 4

-- Is (px, py) (unit coordinates) inside the rectangle (rounded corners of radius r)?
local function inRect(px: number, py: number, x: number, y: number, w: number, h: number, r: number?): boolean
	if px < x or py < y or px >= x + w or py >= y + h then
		return false
	end
	local radius = r or 0
	if radius <= 0 then
		return true
	end
	radius = math.min(radius, w / 2, h / 2)
	-- The nearest point of the rectangle shrunk by the radius: inside when within the radius of it.
	-- (With the radius half a side, rounding can leave that side's far bound a hair under its near
	-- one, which math.clamp refuses: the far bound is kept at least the near one.)
	local left, top = x + radius, y + radius
	local cx = math.clamp(px, left, math.max(left, x + w - radius))
	local cy = math.clamp(py, top, math.max(top, y + h - radius))
	local dx, dy = px - cx, py - cy
	return dx * dx + dy * dy <= radius * radius
end

-- Is (px, py) inside the polygon (even-odd rule: a ray to the right crosses it an odd number of times)?
local function inPoly(px: number, py: number, points: { number }): boolean
	local count = #points // 2
	if count < 3 then
		return false
	end
	local inside = false
	local jx, jy = points[2 * count - 1], points[2 * count]
	for i = 1, count do
		local ix, iy = points[2 * i - 1], points[2 * i]
		if (iy > py) ~= (jy > py) then
			local crossX = ix + (py - iy) / (jy - iy) * (jx - ix)
			if px < crossX then
				inside = not inside
			end
		end
		jx, jy = ix, iy
	end
	return inside
end

-- Is the point (unit coordinates) inside `shape`?
function Masks.contains(shape: Shape, px: number, py: number): boolean
	if shape.kind == "circle" then
		local dx, dy = px - shape.x, py - shape.y
		return dx * dx + dy * dy <= shape.r * shape.r
	elseif shape.kind == "rect" then
		return inRect(px, py, shape.x, shape.y, shape.w, shape.h, shape.r)
	elseif shape.kind == "poly" then
		return inPoly(px, py, shape.points)
	elseif shape.kind == "ring" then
		local dx, dy = px - shape.x, py - shape.y
		local d2 = dx * dx + dy * dy
		local inner = math.max(0, shape.r - shape.width)
		return d2 <= shape.r * shape.r and d2 >= inner * inner
	end
	return false
end

--[[
	A drawing of `ops` into `w` x `h` pixels, not drawn yet: `step` draws it a few rows at a time
	(Style.Dayz spreads a mask over frames that way), `render` all at once. Each pixel's alpha is
	the share of its `samples` x `samples` sample points (default SAMPLES) the drawing covers.
]]
function Masks.begin(ops: { Op }, w: number, h: number, samples: number?): Job
	return {
		ops = ops,
		samples = math.max(1, math.floor(samples or Masks.SAMPLES)),
		row = 0,
		mask = { w = w, h = h, alpha = table.create(w * h, 0) },
	}
end

-- Draws up to `rows` more rows of `job` (from the top); whether the mask is done.
function Masks.step(job: Job, rows: number): boolean
	local mask = job.mask
	local w, h = mask.w, mask.h
	local alpha = mask.alpha
	local ops = job.ops
	local n = job.samples
	local total = n * n
	local first = job.row
	local last = math.min(h, first + math.max(0, rows)) - 1
	for py = first, last do
		for px = 0, w - 1 do
			local covered = 0
			for sy = 0, n - 1 do
				local v = (py + (sy + 0.5) / n) / h
				for sx = 0, n - 1 do
					local u = (px + (sx + 0.5) / n) / w
					local inside = false
					for _, op in ops do
						if Masks.contains(op.shape, u, v) then
							inside = not op.cut
						end
					end
					if inside then
						covered += 1
					end
				end
			end
			alpha[py * w + px + 1] = covered / total
		end
	end
	job.row = math.max(first, last + 1)
	return job.row >= h
end

--[[
	The mask of `ops` drawn into `w` x `h` pixels at once, each pixel's alpha the share of its
	`samples` x `samples` sample points (default SAMPLES) the drawing covers.
]]
function Masks.render(ops: { Op }, w: number, h: number, samples: number?): Mask
	local job = Masks.begin(ops, w, h, samples)
	Masks.step(job, h)
	return job.mask
end

--[[
	`mask` resampled to `w` x `h` pixels: each target pixel is the mean of the source area under it
	(area-weighted, so partly covered source pixels count by their share), which keeps the mask's
	mean alpha. Works for enlarging too (each target pixel then takes its source pixel's alpha).
]]
function Masks.downsample(mask: Mask, w: number, h: number): Mask
	local sw, sh = mask.w, mask.h
	local scaleX, scaleY = sw / w, sh / h
	local alpha = table.create(w * h, 0)
	for ty = 0, h - 1 do
		local y0, y1 = ty * scaleY, (ty + 1) * scaleY
		for tx = 0, w - 1 do
			local x0, x1 = tx * scaleX, (tx + 1) * scaleX
			local sum, area = 0, 0
			for sy = math.floor(y0), math.min(sh - 1, math.ceil(y1) - 1) do
				local hy = math.min(y1, sy + 1) - math.max(y0, sy)
				if hy > 0 then
					for sx = math.floor(x0), math.min(sw - 1, math.ceil(x1) - 1) do
						local hx = math.min(x1, sx + 1) - math.max(x0, sx)
						if hx > 0 then
							local weight = hx * hy
							sum += mask.alpha[sy * sw + sx + 1] * weight
							area += weight
						end
					end
				end
			end
			alpha[ty * w + tx + 1] = if area > 0 then sum / area else 0
		end
	end
	return { w = w, h = h, alpha = alpha }
end

-- The mask as text rows, "#" where its alpha reaches `threshold` (default 0.5), else ".".
function Masks.rows(mask: Mask, threshold: number?): { string }
	local limit = threshold or 0.5
	local rows = table.create(mask.h, "")
	local chars = table.create(mask.w, ".")
	for y = 0, mask.h - 1 do
		for x = 0, mask.w - 1 do
			chars[x + 1] = if mask.alpha[y * mask.w + x + 1] >= limit then "#" else "."
		end
		rows[y + 1] = table.concat(chars)
	end
	return rows
end

--[[
	The vignette: alpha 0 within `inner` (the share of the distance from the centre to the corner
	pixels), rising by a smoothstep to `edge` at the corner pixels.
]]
function Masks.vignette(w: number, h: number, inner: number, edge: number): Mask
	local cx, cy = w / 2, h / 2
	-- (The corner pixels' centres are the farthest: they get exactly `edge`.)
	local farX, farY = (w - 0.5 - cx) / w, (h - 0.5 - cy) / h
	local far = math.sqrt(farX * farX + farY * farY)
	local alpha = table.create(w * h, 0)
	for y = 0, h - 1 do
		local dy = (y + 0.5 - cy) / h
		for x = 0, w - 1 do
			local dx = (x + 0.5 - cx) / w
			local d = if far > 0 then math.sqrt(dx * dx + dy * dy) / far else 0
			local value = 0
			if d > inner then
				local s = if inner < 1 then math.clamp((d - inner) / (1 - inner), 0, 1) else 1
				value = edge * s * s * (3 - 2 * s)
			end
			alpha[y * w + x + 1] = value
		end
	end
	return { w = w, h = h, alpha = alpha }
end

return Masks
