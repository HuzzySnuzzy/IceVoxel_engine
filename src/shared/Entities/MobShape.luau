--!strict
--[[
	Where a mob kind is drawn, in its own frame, pure: blocks from its feet, x across (+x its
	left), y up, z forward along its facing. Client Entities/MobRig draws the zombies' R15 rigs by
	these proportions and stances, Entities/MobModel the other kinds' two boxes (MobList `parts`),
	and Shared/Weapons/Ballistics hits by them (a bullet's body and head boxes), so a shot at the
	head as drawn is a head shot (tests/spec/Ballistics poses every kind's rig to check it).

	  R15      an R15 body R15_HEIGHT (5.2) studs tall at scale 1, its root (the lower torso's
	           centre) ROOT up, the waist WAIST, the neck NECK, a HEAD stud cube on the neck and
	           an upper torso TORSO_WIDTH wide and TORSO_DEPTH deep. A rig (MobList `rig`) is drawn
	           `rig.height` (else the kind's height) blocks tall: `scale` gives sy = height / 5.2
	           blocks a stud up and sx = sy x `rig.width` (default DEFAULT_WIDTH) across and deep.
	  Stances  a standing gait (GAITS) leans the torso `lean` forward about the waist and the head
	           `droop` less half the lean about the neck; the crawl pitches the whole rig
	           CRAWL_PITCH forward about its root, which lies CRAWL_HEIGHT above the floor and
	           CRAWL_BACK behind the feet, and raises its head CRAWL_LOOK.
	  Head     `head`: the box (min x, y, z, max x, y, z) the head fills at rest: a standing rig's
	           head part leaned and drooped (its box grown by the turn), the crawler's head part
	           pitched with the rig; a kind without a rig, its second part (the head on the facing
	           side). nil for a kind with neither.
	  Neck     `neck`: the height a standing rig's neck is drawn at (the torso below, the head
	           above); nil for the crawl and kinds without a rig.

	The rig's animation (the walk's sway, the lurch's twitch, the scream) moves the head a few
	hundredths of a block about this rest; Ballistics' margin takes it in.
]]

local MobList = require(script.Parent.MobList)

export type Box = { number }

-- A standing gait's stance: radians forward of the torso at the waist and of the head.
export type Stance = { lean: number, droop: number }

local MobShape = {}

-- The R15 body (studs at scale 1, from the feet).
MobShape.R15_HEIGHT = 5.2
MobShape.ROOT = 2.2
MobShape.WAIST = 2.4
MobShape.NECK = 4.0
MobShape.HEAD = 1.2
MobShape.TORSO_WIDTH = 2
MobShape.TORSO_DEPTH = 1
-- A rig's width when its kind gives none (times the 4 stud R15 width).
MobShape.DEFAULT_WIDTH = 0.8

-- The standing gaits' stances (client Entities/MobRig's gaits read theirs from here).
MobShape.GAITS = table.freeze({
	shamble = table.freeze({ lean = 0.06, droop = 0.12 }),
	run = table.freeze({ lean = 0.25, droop = 0 }),
	brute = table.freeze({ lean = 0.1, droop = 0.15 }),
	lurch = table.freeze({ lean = 0.06, droop = 0.12 }),
}) :: { [string]: Stance }

-- Crawling: the whole rig's pitch forward (radians), the root's height above the floor and how far
-- behind the feet it lies (blocks), and how far the head is raised to look ahead (radians).
MobShape.CRAWL_PITCH = math.rad(88)
MobShape.CRAWL_HEIGHT = 0.22
MobShape.CRAWL_BACK = 0.3
MobShape.CRAWL_LOOK = 0.4

-- A rig's blocks a stud: up (sy) and across and deep (sx). nil for a kind without a rig.
function MobShape.scale(kind: MobList.Kind): (number?, number)
	local rig = kind.rig
	if rig == nil then
		return nil, 0
	end
	local sy = (rig.height or kind.height) / MobShape.R15_HEIGHT
	return sy, sy * (rig.width or MobShape.DEFAULT_WIDTH)
end

-- (A box of half extents hx, hy, hz about (cx, cy, cz) turned `pitch` forward about x: its bounds.)
local function pitched(cx: number, cy: number, cz: number, hx: number, hy: number, hz: number, pitch: number): Box
	local c, s = math.abs(math.cos(pitch)), math.abs(math.sin(pitch))
	local y, z = hy * c + hz * s, hy * s + hz * c
	return { cx - hx, cy - y, cz - z, cx + hx, cy + y, cz + z }
end

-- The head's box at rest (see the header), nil for a kind drawn without one.
local function drawnHead(kind: MobList.Kind): Box?
	local rig = kind.rig
	local sy, sx = MobShape.scale(kind)
	if rig and sy then
		local half = MobShape.HEAD / 2
		local hx, hy, hz = half * sx, half * sy, half * sx
		if rig.gait == "crawl" then
			-- Up the rig from its root to the neck, then the head's centre, all pitched.
			local pitch = MobShape.CRAWL_PITCH
			local turn = pitch - MobShape.CRAWL_LOOK
			local up = (MobShape.NECK - MobShape.ROOT) * sy
			local cy = MobShape.CRAWL_HEIGHT + up * math.cos(pitch) + half * sy * math.cos(turn)
			local cz = -MobShape.CRAWL_BACK + up * math.sin(pitch) + half * sy * math.sin(turn)
			return pitched(0, cy, cz, hx, hy, hz, turn)
		end
		-- The torso leaned about the waist, the head turned about the neck as well.
		local stance = MobShape.GAITS[rig.gait] or MobShape.GAITS.shamble
		local lean = stance.lean
		local turn = lean + stance.droop - lean / 2
		local up = (MobShape.NECK - MobShape.WAIST) * sy
		local cy = MobShape.WAIST * sy + up * math.cos(lean) + half * sy * math.cos(turn)
		local cz = up * math.sin(lean) + half * sy * math.sin(turn)
		return pitched(0, cy, cz, hx, hy, hz, turn)
	end
	local part = kind.parts[2]
	if part == nil then
		return nil
	end
	local size, offset = part.size, part.offset
	return {
		offset[1] - size[1] / 2,
		offset[2] - size[2] / 2,
		offset[3] - size[3] / 2,
		offset[1] + size[1] / 2,
		offset[2] + size[2] / 2,
		offset[3] + size[3] / 2,
	}
end

-- (Worked out once a kind; NO_HEAD for none.)
local NO_HEAD: Box = table.freeze({})
local heads: { [MobList.Kind]: Box } = {}

-- The box the kind's head fills at rest (see the header; a new table each call).
function MobShape.head(kind: MobList.Kind): Box?
	local known = heads[kind]
	if known == nil then
		known = drawnHead(kind) or NO_HEAD
		heads[kind] = known
	end
	return if known == NO_HEAD then nil else table.clone(known)
end

-- The height a standing rig's neck is drawn at (see the header); nil for others.
function MobShape.neck(kind: MobList.Kind): number?
	local rig = kind.rig
	local sy = MobShape.scale(kind)
	if rig == nil or sy == nil or rig.gait == "crawl" then
		return nil
	end
	local stance = MobShape.GAITS[rig.gait] or MobShape.GAITS.shamble
	return (MobShape.WAIST + (MobShape.NECK - MobShape.WAIST) * math.cos(stance.lean)) * sy
end

return MobShape
