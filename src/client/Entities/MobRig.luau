--!strict
--!native
--[[
	The zombies' R15 rigs, pure (Entities/MobRigPool keeps them on parts, Entities/MobParts
	moves the parts; tests/spec/MobRig checks it): which boxes a zombie is drawn with, and where
	each box is this frame. A zombie reads as a Roblox R15 character, as players do: no Humanoid,
	no Motor6D and no Animator (one each per zombie would cost far more than the boxes), only
	anchored boxes posed in code and moved with the frame's single BulkMoveTo.

	  Parts     the R15 body (studs at scale 1, from the feet; +Z forward and left +X, the mob's
	            own frame, which is Roblox's front -Z and left -X turned half round):
	              part           size            centre          joint (pivot)
	              LowerTorso     2 x 0.4 x 1     0, 2.2, 0       the root (0, 2.2, 0)
	              UpperTorso     2 x 1.6 x 1     0, 3.2, 0       waist (0, 2.4, 0)
	              Head           1.2 cube        0, 4.6, 0       neck (0, 4.0, 0)
	              L/R UpperArm   1 x 1.0 x 1     +-1.5, 3.5, 0   shoulder (+-1.5, 3.65, 0)
	              L/R LowerArm   1 x 0.7 x 1     +-1.5, 2.65, 0  elbow (+-1.5, 3.0, 0)
	              L/R Hand       1 x 0.3 x 1     +-1.5, 2.15, 0  wrist (fixed)
	              L/R UpperLeg   1 x 1.0 x 1     +-0.5, 1.5, 0   hip (+-0.5, 2.0, 0)
	              L/R LowerLeg   1 x 0.7 x 1     +-0.5, 0.65, 0  knee (+-0.5, 1.0, 0)
	              L/R Foot       1 x 0.3 x 1     +-0.5, 0.15, 0  ankle (fixed)
	            plus at most two extras from the look (MobList.Look: vest, stripes, hat), each
	            one box riding on its part: so a full rig is at most 17 boxes (FULL_SLOTS).
	              vest           1.08 x 0.94 x 1.16 of the upper torso, its collar showing
	              stripes        a 0.15 stud band round the upper torso (over a vest) at 60%
	                             of its height
	              hats (head)    cap 1.25 x 0.45 x 1.25 (a little forward), helmet 1.4 x 0.6 x
	                             1.4, hard hat 1.4 x 0.5 x 1.4, fire helmet 1.45 x 0.55 x 1.5 (a
	                             little back), beanie 1.3 x 0.5 x 1.3: one box each, no brims
	  Reduced   (to Config.Mobs.Rig.ReducedDistance) at most 8 boxes: the head; one Torso 2 x 2 x
	            1 (centre 0, 3, 0, on the waist joint); one box per arm 1 x 2 x 1 (shoulder) and
	            per leg (hip); the hat and the vest (the stripes dropped). It takes the upper
	            limbs' angles and colours. A crawler's hides nothing: its legs drag.
	  Impostor  beyond the rigs, the kind's two boxes (MobList `parts`), unposed.
	  Scale     a rig is drawn `rig.height` (else the kind's height) blocks tall: sy =
	            height x BlockSize / 5.2 vertically, sx = sy x `rig.width` (default 0.8) across
	            and deep. The rest pose is scaled first, then posed rigidly.
	  Pose      each part's frame is its parent's x CFrame.new(pivot - parent's pivot) x the
	            joint's rotation (pitch about X, then roll about Z) x CFrame.new(centre - pivot);
	            the root is the lower torso's centre. Angles: a negative pitch swings a hanging
	            limb forward; a positive one tips an upright part (the torso, the head) forward;
	            a positive roll moves a left limb out to the left. From MobModel's stride: `walk`
	            (0..1) and `phase` (Minecraft's limb swing, advancing `walk` a tick):
	              legs     hip pitch -+cos(phase x 0.6662 x f) x legs x walk (left and right
	                       opposite: HumanoidModel's), the knee bending back on the forward swing:
	                       max(0, -+sin(...)) x knees x walk
	              shamble  arms forward (pitch -pi/2.25, -pi/1.9 aggressive, eased by the
	                       aggro blend), elbows bent 0.2, Minecraft's arm bob (pitch + sin(age x
	                       0.067) x 0.05, roll out cos(age x 0.09) x 0.05 + 0.05, age in ticks),
	                       the head drooping 0.12 and tilted +-0.15 by the zombie's id, the torso
	                       swaying sin(phase x 0.333) x 0.06 x walk, leaning 0.06 forward
	              run      a sprinter's stride: frequency x0.7 (a stride every 0.67 s at walk 1,
	                       three steps a second), legs 0.6 rad, knees 0.9, lean 0.25, the arms
	                       pumping opposite the legs (+-0.8 rad x walk, elbows 1.2), half forward
	                       (-pi/3) when aggressive. (A runner chases at walk 1: Minecraft's
	                       frequency and legs x1.4 there would swing a foot a stud a frame.)
	              brute    frequency x0.8, legs x0.8, splayed 0.08, lean 0.1, sway 0.1, a heavier
	                       bob (x2), arms forward low (-pi/2.6; -pi/2.1 aggressive)
	              crawl    the whole rig pitched 88 degrees forward about the hips, the hips 0.22
	                       blocks above the floor and the body slid 0.3 back to lie over its box;
	                       arms reaching -pi/1.1 +- 0.35 sin(phase x 0.5), alternating; the upper
	                       legs dragging +-0.15; the head raised 0.4 to look ahead; hidden parts
	                       (`rig.hide`) are neither drawn nor posed. Every box stays within 0.7
	                       blocks of the floor (the box is 0.6 high); the hands press into it a
	                       little as they claw
	              lurch    the shamble, plus a twitch every ~3 s (id-timed): the right arm jerks up
	                       0.4 rad and the head 0.2, and back, at a steady pace over 0.3 s
	            On top, by MobModel's flags: an attack (the Attack flag's rising edge) swings both
	            arms down 0.9 rad and back at a steady pace over 0.35 s (a crawler raises them
	            0.3); breaking (`hammer` blend) hammers both arms at -pi/2 + 0.6 sin(t x 12) (a
	            crawler from its reach); screaming (`shriek` blend) throws the head back 0.5 and
	            spreads the arms 0.9 out. Every blend eases, so no pose jumps when a flag changes.
	            Dying is MobRenderer's (the base tips over, as for every mob).
	  Speed     no corner of a box moves more than 0.3 studs a frame at 60 frames a second
	            (relative to the base), at any walk and whatever the flags do. A limb's corners
	            move at most LIMB_SPEED (17.4 studs a second: 0.29 a frame), the torso's sway
	            carrying the arms included (`limbs`): its joints turn no faster than that allows
	            from where they were last posed, by a bound that holds for every bend (|upper
	            joint's turn| x (the upper bone + the lower limb's reach) + |the bend| x the
	            lower limb's reach, + |the waist's turn| x the arm's reach from the waist for an
	            arm). The torso and the head move only by the sway and the neck's blends (the
	            scream throws the head back in a quarter second): at most about 0.1 studs a
	            frame. The gaits stay under the limit at the zombies' own paces (it changes
	            nothing there); where layers overlap (a swing during a twitch or a sprint,
	            hammering, a scream) or a mob is flung faster than it walks, the limb takes a
	            few frames longer instead of jumping.
	  Output    `pose` writes each drawn slot's frame relative to the mob's base (12 numbers:
	            x, y, z, then the rotation row by row, CFrame.new's order), `place` multiplies
	            them by the base into a frame's list (MobRigPool poses every rig every frame;
	            MobRigPool.REDUCED_EVERY can space a reduced rig's poses out).
	  Shadows   only the Head, UpperTorso and LowerTorso cast shadows (the reduced rig's Head and
	            Torso): the first Config.Mobs.Rig.ShadowParts of those.

	Units: studs inside (the parts), blocks for the kinds' sizes; seconds.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local MobList = require(Shared.Entities.MobList)
local MobShape = require(Shared.Entities.MobShape)

local MobModel = require(script.Parent.MobModel)

local BLOCK = Config.BlockSize
local PI = math.pi
local cos, sin = math.cos, math.sin

local MobRig = {}

-- Studs from an R15 rig's feet to the top of its head, at scale 1 (Shared/Entities/MobShape's, as
-- every proportion and stance the bullets' boxes are sized by).
MobRig.R15_HEIGHT = MobShape.R15_HEIGHT
-- The rig's width when a kind's rig gives none (times the 4 stud R15 width).
MobRig.DEFAULT_WIDTH = MobShape.DEFAULT_WIDTH

-- Tiers (Entities/MobRigPool).
MobRig.FULL = 1
MobRig.REDUCED = 2
MobRig.IMPOSTOR = 3

-- Full rig slots.
MobRig.LOWER_TORSO = 1
MobRig.UPPER_TORSO = 2
MobRig.HEAD = 3
MobRig.LEFT_UPPER_ARM = 4
MobRig.LEFT_LOWER_ARM = 5
MobRig.LEFT_HAND = 6
MobRig.RIGHT_UPPER_ARM = 7
MobRig.RIGHT_LOWER_ARM = 8
MobRig.RIGHT_HAND = 9
MobRig.LEFT_UPPER_LEG = 10
MobRig.LEFT_LOWER_LEG = 11
MobRig.LEFT_FOOT = 12
MobRig.RIGHT_UPPER_LEG = 13
MobRig.RIGHT_LOWER_LEG = 14
MobRig.RIGHT_FOOT = 15
-- Body parts of the full rig, and its slots with the extras.
MobRig.BODY = 15
MobRig.FULL_SLOTS = 15 + MobList.MAX_EXTRAS
-- Reduced rig slots.
MobRig.TORSO = 1
MobRig.REDUCED_HEAD = 2
MobRig.LEFT_ARM = 3
MobRig.RIGHT_ARM = 4
MobRig.LEFT_LEG = 5
MobRig.RIGHT_LEG = 6
MobRig.REDUCED_BODY = 6
MobRig.REDUCED_SLOTS = 8
-- Impostor slots (the kind's boxes).
MobRig.IMPOSTOR_SLOTS = MobList.MAX_PARTS
-- The full slot each reduced body slot takes its colour from (the upper limb's, the shirt's).
MobRig.REDUCED_FROM = table.freeze({ 2, 3, 4, 7, 10, 13 })
-- The slot a burning mob's flames sit on, by tier.
MobRig.FIRE_SLOT = table.freeze({ 2, 1, 1 })

-- Crawling: the pitch of the whole rig (radians, forward), the hips' height above the floor
-- (blocks) and how far back (blocks) the body slides to lie over its box.
MobRig.CRAWL_PITCH = MobShape.CRAWL_PITCH
MobRig.CRAWL_HEIGHT = MobShape.CRAWL_HEIGHT
MobRig.CRAWL_BACK = MobShape.CRAWL_BACK
-- Seconds an attack swing takes (MobModel's), and a lurching zombie's twitch.
MobRig.SWING = MobModel.SWING
MobRig.TWITCH = 0.3
-- The fastest any corner of a limb's boxes moves, studs a second (relative to the base: its own
-- joints, shoulder and elbow or hip and knee, and for an arm the torso's sway carrying it): 0.29
-- studs a frame at 60 frames a second, inside the 0.3 a frame budget.
MobRig.LIMB_SPEED = 17.4

-- Joints (two angles each: pitch, roll).
local NONE, WAIST, NECK = 0, 1, 2
local L_SHOULDER, L_ELBOW, R_SHOULDER, R_ELBOW = 3, 4, 5, 6
local L_HIP, L_KNEE, R_HIP, R_KNEE = 7, 8, 9, 10
local JOINTS = 10

type PartSpec = {
	name: string,
	size: { number },
	centre: { number },
	parent: number,
	pivot: { number },
	joint: number,
}

local ROOT_PIVOT = { 0, MobShape.ROOT, 0 }
local HEAD = MobShape.HEAD
local NECK_PIVOT = { 0, MobShape.NECK, 0 }
local HEAD_CENTRE = { 0, MobShape.NECK + HEAD / 2, 0 }

local function limb(
	name: string,
	size: { number },
	centre: { number },
	parent: number,
	pivot: { number },
	joint: number
): PartSpec
	return { name = name, size = size, centre = centre, parent = parent, pivot = pivot, joint = joint }
end

local FULL_PARTS: { PartSpec } = {
	limb("LowerTorso", { 2, 0.4, 1 }, { 0, 2.2, 0 }, 0, { 0, 2.2, 0 }, NONE),
	limb(
		"UpperTorso",
		{ MobShape.TORSO_WIDTH, 1.6, MobShape.TORSO_DEPTH },
		{ 0, 3.2, 0 },
		1,
		{ 0, MobShape.WAIST, 0 },
		WAIST
	),
	limb("Head", { HEAD, HEAD, HEAD }, HEAD_CENTRE, 2, NECK_PIVOT, NECK),
	limb("LeftUpperArm", { 1, 1, 1 }, { 1.5, 3.5, 0 }, 2, { 1.5, 3.65, 0 }, L_SHOULDER),
	limb("LeftLowerArm", { 1, 0.7, 1 }, { 1.5, 2.65, 0 }, 4, { 1.5, 3.0, 0 }, L_ELBOW),
	limb("LeftHand", { 1, 0.3, 1 }, { 1.5, 2.15, 0 }, 5, { 1.5, 2.3, 0 }, NONE),
	limb("RightUpperArm", { 1, 1, 1 }, { -1.5, 3.5, 0 }, 2, { -1.5, 3.65, 0 }, R_SHOULDER),
	limb("RightLowerArm", { 1, 0.7, 1 }, { -1.5, 2.65, 0 }, 7, { -1.5, 3.0, 0 }, R_ELBOW),
	limb("RightHand", { 1, 0.3, 1 }, { -1.5, 2.15, 0 }, 8, { -1.5, 2.3, 0 }, NONE),
	limb("LeftUpperLeg", { 1, 1, 1 }, { 0.5, 1.5, 0 }, 1, { 0.5, 2.0, 0 }, L_HIP),
	limb("LeftLowerLeg", { 1, 0.7, 1 }, { 0.5, 0.65, 0 }, 10, { 0.5, 1.0, 0 }, L_KNEE),
	limb("LeftFoot", { 1, 0.3, 1 }, { 0.5, 0.15, 0 }, 11, { 0.5, 0.3, 0 }, NONE),
	limb("RightUpperLeg", { 1, 1, 1 }, { -0.5, 1.5, 0 }, 1, { -0.5, 2.0, 0 }, R_HIP),
	limb("RightLowerLeg", { 1, 0.7, 1 }, { -0.5, 0.65, 0 }, 13, { -0.5, 1.0, 0 }, R_KNEE),
	limb("RightFoot", { 1, 0.3, 1 }, { -0.5, 0.15, 0 }, 14, { -0.5, 0.3, 0 }, NONE),
}

local REDUCED_PARTS: { PartSpec } = {
	limb("Torso", { 2, 2, 1 }, { 0, 3.0, 0 }, 0, { 0, 2.4, 0 }, WAIST),
	limb("Head", { HEAD, HEAD, HEAD }, HEAD_CENTRE, 1, NECK_PIVOT, NECK),
	limb("LeftArm", { 1, 2, 1 }, { 1.5, 3.0, 0 }, 1, { 1.5, 3.65, 0 }, L_SHOULDER),
	limb("RightArm", { 1, 2, 1 }, { -1.5, 3.0, 0 }, 1, { -1.5, 3.65, 0 }, R_SHOULDER),
	limb("LeftLeg", { 1, 2, 1 }, { 0.5, 1.0, 0 }, 0, { 0.5, 2.0, 0 }, L_HIP),
	limb("RightLeg", { 1, 2, 1 }, { -0.5, 1.0, 0 }, 0, { -0.5, 2.0, 0 }, R_HIP),
}

-- The extras: size and centre (studs at scale 1, the mob's frame).
local VEST = { size = { 2.16, 1.5, 1.16 }, centre = { 0, 3.15, 0 } }
local STRIPES = { size = { 2.08, 0.15, 1.08 }, centre = { 0, 3.36, 0 } }
local STRIPES_OVER_VEST = { size = { 2.24, 0.15, 1.24 }, centre = { 0, 3.36, 0 } }
local HATS: { [string]: { size: { number }, centre: { number } } } = {
	cap = { size = { 1.25, 0.45, 1.25 }, centre = { 0, 5.1, 0.05 } },
	helmet = { size = { 1.4, 0.6, 1.4 }, centre = { 0, 5.05, 0 } },
	hardhat = { size = { 1.4, 0.5, 1.4 }, centre = { 0, 5.1, 0 } },
	firehelmet = { size = { 1.45, 0.55, 1.5 }, centre = { 0, 5.075, -0.1 } },
	beanie = { size = { 1.3, 0.5, 1.3 }, centre = { 0, 5.05, 0 } },
}
MobRig.HATS = HATS

-- Gaits.
local SHAMBLE, RUN, BRUTE, CRAWL, LURCH = 1, 2, 3, 4, 5
local GAIT_IDS = { shamble = SHAMBLE, run = RUN, brute = BRUTE, crawl = CRAWL, lurch = LURCH }

type Gait = {
	-- Limb swing frequency and the legs' and knees' amplitudes (radians at walk 1).
	frequency: number,
	legs: number,
	knees: number,
	-- Leg roll out (each side), torso lean forward and sway (radians).
	splay: number,
	lean: number,
	sway: number,
	-- How far the arms reach forward (radians from hanging down), calm and aggressive, and the
	-- elbows' bend.
	arms: number,
	aggressive: number,
	elbows: number,
	-- Minecraft's arm bob, times.
	bob: number,
	-- Run: the arms' pump amplitude at walk 1 (0: arms forward).
	pump: number,
	-- The head's droop forward (radians).
	droop: number,
}

local GAITS: { [number]: Gait } = {
	[SHAMBLE] = {
		frequency = 1,
		legs = 1.4,
		knees = 0.5,
		splay = 0,
		lean = MobShape.GAITS.shamble.lean,
		sway = 0.06,
		arms = PI / 2.25,
		aggressive = PI / 1.9,
		elbows = 0.2,
		bob = 1,
		pump = 0,
		droop = MobShape.GAITS.shamble.droop,
	},
	[RUN] = {
		frequency = 0.7,
		legs = 0.6,
		knees = 0.9,
		splay = 0,
		lean = MobShape.GAITS.run.lean,
		sway = 0.04,
		arms = PI / 3,
		aggressive = PI / 3,
		elbows = 1.2,
		bob = 0.5,
		pump = 0.8,
		droop = MobShape.GAITS.run.droop,
	},
	[BRUTE] = {
		frequency = 0.8,
		legs = 1.4 * 0.8,
		knees = 0.4,
		splay = 0.08,
		lean = MobShape.GAITS.brute.lean,
		sway = 0.1,
		arms = PI / 2.6,
		aggressive = PI / 2.1,
		elbows = 0.25,
		bob = 2,
		pump = 0,
		droop = MobShape.GAITS.brute.droop,
	},
}
GAITS[LURCH] = GAITS[SHAMBLE]
assert(
	MobShape.GAITS.lurch.lean == MobShape.GAITS.shamble.lean
		and MobShape.GAITS.lurch.droop == MobShape.GAITS.shamble.droop,
	"the lurch stands as the shamble"
)
-- (The crawl has its own code; its numbers are the constants below.)
GAITS[CRAWL] = GAITS[SHAMBLE]
-- Crawling arms reach (pitch) and claw (+-, at walk 0.7 and above), the legs' drag and splay,
-- and how far the head is raised to look ahead.
MobRig.CRAWL_REACH = -PI / 1.1
MobRig.CRAWL_CLAW = 0.35
MobRig.CRAWL_DRAG = 0.15
MobRig.CRAWL_SPLAY = 0.12
MobRig.CRAWL_LOOK = MobShape.CRAWL_LOOK
-- A crawler's attack lifts its arms this much, a scream its head this much more (radians).
MobRig.CRAWL_LIFT = 0.3
MobRig.CRAWL_SHRIEK = 0.15

-- A rig's boxes for one tier, as flat arrays (3 numbers a slot for the vectors).
export type Shape = {
	tier: number,
	-- Slots drawn or kept (body + extras), and the body's.
	count: number,
	body: number,
	names: { string },
	-- Studs, scaled: the box's size, its rest centre, its joint's pivot minus the parent's
	-- pivot, and its centre minus its pivot.
	size: { number },
	centre: { number },
	offset: { number },
	arm: { number },
	parent: { number },
	joint: { number },
	hidden: { boolean },
	shadow: { boolean },
	-- The extras in slot order ("vest", "stripes", "hat").
	extras: { string },
	-- The root's pivot (studs, scaled).
	rootX: number,
	rootY: number,
	rootZ: number,
	-- Impostor: the boxes' frames relative to the base (12 numbers a slot).
	rest: { number },
}

-- One kind in one look: its scale, gait and the shapes of the three tiers.
export type Build = {
	kind: MobList.Kind,
	look: MobList.Look?,
	gait: number,
	sx: number,
	sy: number,
	-- Studs from each limb's upper and lower joint to the furthest corner of the limb below it,
	-- whatever the bend (the upper joint's: the bone to the lower joint plus the lower one's), 2
	-- a limb: left arm, right arm, left leg, right leg; and from the waist to the furthest corner
	-- of an arm, however posed (the waist to the shoulder plus the shoulder's reach).
	reach: { number },
	carry: number,
	full: Shape?,
	reduced: Shape?,
	impostor: Shape,
}

-- The extras of a look, in slot order: vest, stripes, hat (at most two: MobList checks).
function MobRig.extras(look: MobList.Look?): { string }
	local list = {}
	if look then
		if look.vest then
			table.insert(list, "vest")
		end
		if look.stripes then
			table.insert(list, "stripes")
		end
		if look.hat then
			table.insert(list, "hat")
		end
	end
	return list
end

local function newShape(tier: number): Shape
	return {
		tier = tier,
		count = 0,
		body = 0,
		names = {},
		size = {},
		centre = {},
		offset = {},
		arm = {},
		parent = {},
		joint = {},
		hidden = {},
		shadow = {},
		extras = {},
		rootX = 0,
		rootY = 0,
		rootZ = 0,
		rest = {},
	}
end

local function push(
	shape: Shape,
	pivots: { [number]: { number } },
	name: string,
	size: { number },
	centre: { number },
	parent: number,
	pivot: { number },
	joint: number,
	sx: number,
	sy: number
)
	local slot = shape.count + 1
	shape.count = slot
	shape.names[slot] = name
	local parentPivot = if parent == 0 then ROOT_PIVOT else pivots[parent]
	pivots[slot] = pivot
	local k = slot * 3
	shape.size[k - 2], shape.size[k - 1], shape.size[k] = size[1] * sx, size[2] * sy, size[3] * sx
	shape.centre[k - 2], shape.centre[k - 1], shape.centre[k] = centre[1] * sx, centre[2] * sy, centre[3] * sx
	shape.arm[k - 2], shape.arm[k - 1], shape.arm[k] =
		(centre[1] - pivot[1]) * sx, (centre[2] - pivot[2]) * sy, (centre[3] - pivot[3]) * sx
	shape.parent[slot] = parent
	shape.joint[slot] = joint
	shape.hidden[slot] = false
	shape.shadow[slot] = false
	shape.offset[k - 2], shape.offset[k - 1], shape.offset[k] =
		(pivot[1] - parentPivot[1]) * sx, (pivot[2] - parentPivot[2]) * sy, (pivot[3] - parentPivot[3]) * sx
end

local function extraBox(name: string, look: MobList.Look): ({ number }, { number })
	if name == "vest" then
		return VEST.size, VEST.centre
	elseif name == "stripes" then
		local box = if look.vest then STRIPES_OVER_VEST else STRIPES
		return box.size, box.centre
	end
	local hat = HATS[(look.hat :: MobList.Hat).kind]
	return hat.size, hat.centre
end

local function bodyShape(
	tier: number,
	parts: { PartSpec },
	look: MobList.Look?,
	sx: number,
	sy: number,
	hide: { string }?
): Shape
	local shape = newShape(tier)
	-- (Each slot's unscaled pivot, for its children's offsets.)
	local pivots: { [number]: { number } } = {}
	for _, part in parts do
		push(shape, pivots, part.name, part.size, part.centre, part.parent, part.pivot, part.joint, sx, sy)
	end
	shape.body = shape.count
	shape.rootX, shape.rootY, shape.rootZ = ROOT_PIVOT[1] * sx, ROOT_PIVOT[2] * sy, ROOT_PIVOT[3] * sx
	-- Extras ride on the upper torso (the reduced torso) or the head, with no joint of their own.
	local torso = if tier == MobRig.FULL then MobRig.UPPER_TORSO else MobRig.TORSO
	local head = if tier == MobRig.FULL then MobRig.HEAD else MobRig.REDUCED_HEAD
	if look then
		for _, extra in MobRig.extras(look) do
			if tier == MobRig.FULL or extra ~= "stripes" then
				local size, centre = extraBox(extra, look)
				local anchor = if extra == "hat" then head else torso
				push(shape, pivots, extra, size, centre, anchor, pivots[anchor], NONE, sx, sy)
				table.insert(shape.extras, extra)
			end
		end
	end
	-- Hidden parts and everything hanging from them.
	if hide and tier == MobRig.FULL then
		for _, name in hide do
			for slot = 1, shape.body do
				if shape.names[slot] == name then
					shape.hidden[slot] = true
				end
			end
		end
		for slot = 1, shape.count do
			local parent = shape.parent[slot]
			if parent > 0 and shape.hidden[parent] then
				shape.hidden[slot] = true
			end
		end
	end
	-- Shadows: the first ShadowParts of the head and torso parts.
	local casters = if tier == MobRig.FULL
		then { MobRig.HEAD, MobRig.UPPER_TORSO, MobRig.LOWER_TORSO }
		else { MobRig.REDUCED_HEAD, MobRig.TORSO }
	for i = 1, math.min(#casters, Config.Mobs.Rig.ShadowParts) do
		shape.shadow[casters[i]] = true
	end
	return shape
end

-- The kind's own two boxes, unposed: frames relative to the base, in studs.
local function impostorShape(kind: MobList.Kind): Shape
	local shape = newShape(MobRig.IMPOSTOR)
	for slot, box in kind.parts do
		shape.count = slot
		shape.names[slot] = "Box"
		local k = slot * 3
		shape.size[k - 2], shape.size[k - 1], shape.size[k] =
			box.size[1] * BLOCK, box.size[2] * BLOCK, box.size[3] * BLOCK
		shape.centre[k - 2], shape.centre[k - 1], shape.centre[k] =
			box.offset[1] * BLOCK, box.offset[2] * BLOCK, box.offset[3] * BLOCK
		shape.offset[k - 2], shape.offset[k - 1], shape.offset[k] = 0, 0, 0
		shape.arm[k - 2], shape.arm[k - 1], shape.arm[k] = 0, 0, 0
		shape.parent[slot] = 0
		shape.joint[slot] = NONE
		shape.hidden[slot] = false
		shape.shadow[slot] = true
		local r = (slot - 1) * 12
		local rest = shape.rest
		rest[r + 1], rest[r + 2], rest[r + 3] = shape.centre[k - 2], shape.centre[k - 1], shape.centre[k]
		rest[r + 4], rest[r + 5], rest[r + 6] = 1, 0, 0
		rest[r + 7], rest[r + 8], rest[r + 9] = 0, 1, 0
		rest[r + 10], rest[r + 11], rest[r + 12] = 0, 0, 1
	end
	shape.body = shape.count
	return shape
end

--[[
	A build's `reach` and `carry`. The hand's bottom is 1 below the elbow and the foot's 1 below
	the knee, their corners half a box out on X and Z: that is the lower joints' reach, however
	the limb is posed. The elbow is 0.65 below the shoulder and the knee 1 below the hip, so the
	upper joints' reach is that plus the lower one's (a bent elbow swings the hand's outer corner
	further out than the straight arm's 1.65). The shoulder is (1.5, 1.25) from the waist (X,
	Y), so the arm's furthest corner from the waist is that plus the shoulder's reach. (The
	reduced rig's straight limbs are inside the same bounds.)
]]
local function limbReach(sx: number, sy: number): ({ number }, number)
	local side = 2 * (0.5 * sx) ^ 2
	local elbow = math.sqrt((1.0 * sy) ^ 2 + side)
	local knee = elbow
	local shoulder, hip = 0.65 * sy + elbow, 1.0 * sy + knee
	local carry = math.sqrt((1.5 * sx) ^ 2 + (1.25 * sy) ^ 2) + shoulder
	return { shoulder, elbow, shoulder, elbow, hip, knee, hip, knee }, carry
end

local cache: { [MobList.Kind]: { [any]: Build } } = {}
local NO_LOOK = {}

--[[
	The build of `kind` in `variant` (its look: MobList.look), made once and kept: the scale,
	the gait and the three tiers' shapes. Kinds without a rig only have the impostor.
]]
function MobRig.build(kind: MobList.Kind, variant: number): Build
	local look = if MobList.looksOf(kind) then (MobList.look(kind, variant)) else nil
	local byLook = cache[kind]
	if byLook == nil then
		byLook = {}
		cache[kind] = byLook
	end
	local key = look or NO_LOOK
	local built = byLook[key]
	if built then
		return built
	end
	local rig = kind.rig
	local sy = (if rig and rig.height then rig.height else kind.height) * BLOCK / MobRig.R15_HEIGHT
	local sx = sy * (if rig and rig.width then rig.width else MobRig.DEFAULT_WIDTH)
	local reach, carry = limbReach(sx, sy)
	local result: Build = {
		kind = kind,
		look = look,
		gait = if rig then GAIT_IDS[rig.gait] else SHAMBLE,
		sx = sx,
		sy = sy,
		reach = reach,
		carry = carry,
		full = if rig then bodyShape(MobRig.FULL, FULL_PARTS, look, sx, sy, rig.hide) else nil,
		reduced = if rig then bodyShape(MobRig.REDUCED, REDUCED_PARTS, look, sx, sy, nil) else nil,
		impostor = impostorShape(kind),
	}
	byLook[key] = result
	return result
end

-- The shape of a build's tier (the impostor when the kind has no rig).
function MobRig.shape(build: Build, tier: number): Shape
	if tier == MobRig.FULL then
		return build.full or build.impostor
	elseif tier == MobRig.REDUCED then
		return build.reduced or build.impostor
	end
	return build.impostor
end

--[[ Pose ]]

-- This frame's joint angles (pitch, roll a joint) and the root's.
local ANG = table.create(2 * JOINTS, 0)
local root = { pitch = 0, roll = 0, x = 0, y = 0, z = 0 }
-- Joint frames while composing: slot 0 (the root) to FULL_SLOTS, 12 numbers each.
local J = table.create(12 * (MobRig.FULL_SLOTS + 1), 0)

local function setJoint(joint: number, pitch: number, roll: number)
	ANG[2 * joint - 1] = pitch
	ANG[2 * joint] = roll
end

-- This frame's wanted limb angles before the speed limit, 3 a limb as `mob.limbs` (which keeps
-- the waist's two angles after them).
local WANT = table.create(12, 0)
local LEFT_ARM, RIGHT_ARM, LEFT_LEG, RIGHT_LEG = 1, 2, 3, 4
-- (A limb's joints are consecutive: the upper joint L_SHOULDER + 2 x (limb - 1), the lower one
-- after it, so its four angles in ANG start at 4 x limb + 1.)
assert(
	L_ELBOW == L_SHOULDER + 1 and R_SHOULDER == L_SHOULDER + 2 and L_HIP == L_SHOULDER + 4,
	"a limb's joints are consecutive"
)
assert(R_KNEE == L_SHOULDER + 7 and 2 * L_SHOULDER - 1 == 4 * LEFT_ARM + 1, "the limbs' angles start at ANG[5]")

local function want(which: number, pitch: number, roll: number, bend: number)
	local k = which * 3
	WANT[k - 2], WANT[k - 1], WANT[k] = pitch, roll, bend
end

--[[
	Sets the limbs' joints to the wanted angles (the waist's already set), each limb moved from
	where it was last posed (`mob.limbs`) by no more than LIMB_SPEED allows since. A corner of a
	limb travels at most |upper joint's turn| x its reach + |lower joint's bend| x the lower
	reach (a turn of pitch dp and roll dr is at most sqrt(dp^2 + dr^2), the two axes being
	square to each other), and an arm's also |the waist's turn| x `carry`: so an arm gets what
	the waist's own step leaves. The gaits keep their own limbs under it at the zombies' own
	speeds; it bites where swings, the twitch, hammering, a scream and the aggressive pose
	overlap or switch, or when a mob is flung faster than it walks, which then take a few frames
	longer instead of adding up into a jump. A rig not posed for more than MAX_STEP (new, or
	back from the boxes) starts where it is wanted.
]]
local function limbs(build: Build, mob: MobModel.Mob, now: number)
	local state, reach = mob.limbs, build.reach
	local dt = now - mob.limbsAt
	local limited = dt <= MobModel.MAX_STEP
	local limit = if dt > 0 then MobRig.LIMB_SPEED * dt else 0
	if dt > 0 then
		mob.limbsAt = now
	end
	-- The waist's turn since the last pose, and what it leaves the arms.
	local waistPitch, waistRoll = ANG[2 * WAIST - 1], ANG[2 * WAIST]
	local wp, wr = waistPitch - state[13], waistRoll - state[14]
	state[13], state[14] = waistPitch, waistRoll
	local armLimit = limit - math.sqrt(wp * wp + wr * wr) * build.carry
	if armLimit < 0 then
		armLimit = 0
	end
	for which = 1, 4 do
		local k = which * 3
		local pitch, roll, bend = WANT[k - 2], WANT[k - 1], WANT[k]
		if limited then
			local dp, dr, db = pitch - state[k - 2], roll - state[k - 1], bend - state[k]
			local travel = math.sqrt(dp * dp + dr * dr) * reach[2 * which - 1] + math.abs(db) * reach[2 * which]
			local most = if which <= RIGHT_ARM then armLimit else limit
			if travel > most then
				local f = most / travel
				pitch, roll, bend = state[k - 2] + dp * f, state[k - 1] + dr * f, state[k] + db * f
			end
		end
		state[k - 2], state[k - 1], state[k] = pitch, roll, bend
		local o = 4 * which
		ANG[o + 1], ANG[o + 2], ANG[o + 3], ANG[o + 4] = pitch, roll, bend, 0
	end
end

-- The joint angles of a build's gait for `mob` at `now` (see the header).
local function angles(build: Build, mob: MobModel.Mob, now: number)
	local gaitId = build.gait
	local g = GAITS[gaitId]
	local walk = mob.walk
	local age = now * 20
	local swing = mob.phase * 0.6662 * g.frequency
	local legCos, legSin = cos(swing), sin(swing)
	local aggro, hammer, shriek = mob.aggro, mob.hammer, mob.shriek
	local tilt = (mob.seed * 2 - 1) * 0.15
	-- The attack swing (0 outside it): down and back up at a steady pace, the slowest a swing
	-- of its size and length can go.
	local attack = 0
	local since = now - mob.swingStart
	if since > 0 and since < MobRig.SWING then
		attack = 1 - math.abs(2 * since / MobRig.SWING - 1)
	end
	local hammerSwing = 0.6 * sin(now * 12)

	if gaitId == CRAWL then
		root.pitch = MobRig.CRAWL_PITCH
		root.roll = 0
		root.x = 0
		root.y = MobRig.CRAWL_HEIGHT * BLOCK - build.sy * ROOT_PIVOT[2]
		root.z = -MobRig.CRAWL_BACK * BLOCK
		local reach = MobRig.CRAWL_REACH
		local claw = sin(mob.phase * 0.5) * MobRig.CRAWL_CLAW * math.min(1, 0.3 + walk)
		local left = reach + claw - MobRig.CRAWL_LIFT * attack
		local right = reach - claw - MobRig.CRAWL_LIFT * attack
		local beat = reach + 0.4 * sin(now * 12)
		left += (beat - left) * hammer
		right += (beat - right) * hammer
		local spread = 0.2 + (0.9 - 0.2) * shriek
		want(LEFT_ARM, left, spread, -0.3)
		want(RIGHT_ARM, right, -spread, -0.3)
		local drag = sin(mob.phase * 0.5) * MobRig.CRAWL_DRAG
		want(LEFT_LEG, drag, MobRig.CRAWL_SPLAY, 0)
		want(RIGHT_LEG, -drag, -MobRig.CRAWL_SPLAY, 0)
		setJoint(WAIST, 0, sin(mob.phase * 0.5) * 0.1 * walk)
		limbs(build, mob, now)
		setJoint(NECK, -MobRig.CRAWL_LOOK - MobRig.CRAWL_SHRIEK * shriek, tilt)
		return
	end

	root.pitch, root.roll, root.x, root.y, root.z = 0, 0, 0, 0, 0
	-- Legs (HumanoidModel's swing), knees bending back on the forward swing.
	local legs = g.legs * walk
	local knees = g.knees * walk
	want(LEFT_LEG, legs * legCos, g.splay, (if legSin > 0 then legSin else 0) * knees)
	want(RIGHT_LEG, -legs * legCos, -g.splay, (if legSin < 0 then -legSin else 0) * knees)
	-- Torso and head.
	setJoint(WAIST, g.lean, sin(swing * 0.5) * g.sway * walk)
	local neck = g.droop - g.lean * 0.5
	neck += (-0.5 - neck) * shriek
	-- Arms: forward (bobbing), or pumping (the run).
	local bobPitch = sin(age * 0.067) * 0.05 * g.bob
	local bobRoll = (cos(age * 0.09) * 0.05 + 0.05) * g.bob
	local leftPitch, rightPitch, elbows
	if g.pump > 0 then
		-- (Calm: the arms pump opposite the legs; aggressive: half forward, pumping a quarter.)
		local pump = g.pump * walk * legCos
		local forward = -g.aggressive
		leftPitch = -pump + (forward + 0.75 * pump) * aggro
		rightPitch = pump + (forward - 0.75 * pump) * aggro
		elbows = g.elbows + (0.3 - g.elbows) * aggro
	else
		local forward = -(g.arms + (g.aggressive - g.arms) * aggro)
		leftPitch = forward + bobPitch
		rightPitch = forward + bobPitch
		elbows = g.elbows
	end
	leftPitch += 0.9 * attack
	rightPitch += 0.9 * attack
	local beat = -PI / 2 + hammerSwing
	leftPitch += (beat - leftPitch) * hammer
	rightPitch += (beat - rightPitch) * hammer
	leftPitch += (-0.4 - leftPitch) * shriek
	rightPitch += (-0.4 - rightPitch) * shriek
	local roll = bobRoll + (0.9 - bobRoll) * shriek
	-- The lurch's twitch: the right arm jerks up, the head with it.
	local headRoll = tilt
	if gaitId == LURCH then
		local period = 2.6 + mob.seed * 0.8
		local t = (now + mob.seed * 7.3) % period
		if t < MobRig.TWITCH then
			local twitch = 0.4 * (1 - math.abs(2 * t / MobRig.TWITCH - 1))
			rightPitch -= twitch
			headRoll += twitch * 0.5
		end
	end
	local elbow = -elbows * (1 - hammer) - 0.3 * hammer
	want(LEFT_ARM, leftPitch, roll, elbow)
	want(RIGHT_ARM, rightPitch, -roll, elbow)
	limbs(build, mob, now)
	setJoint(NECK, neck, headRoll)
end

-- Composes the shape's frames from this frame's angles into `rel` (12 numbers a slot).
local function compose(rel: { number }, s: Shape)
	-- The root: CFrame.new(offset + pivot) x Rx(pitch) x Rz(roll).
	do
		local cp, sp, cr, sr = cos(root.pitch), sin(root.pitch), cos(root.roll), sin(root.roll)
		J[1], J[2], J[3] = root.x + s.rootX, root.y + s.rootY, root.z + s.rootZ
		J[4], J[5], J[6] = cr, -sr, 0
		J[7], J[8], J[9] = cp * sr, cp * cr, -sp
		J[10], J[11], J[12] = sp * sr, sp * cr, cp
	end
	local parent, joint, offset, arm, hidden = s.parent, s.joint, s.offset, s.arm, s.hidden
	for slot = 1, s.count do
		if not hidden[slot] then
			local p = parent[slot] * 12
			local a00, a01, a02 = J[p + 4], J[p + 5], J[p + 6]
			local a10, a11, a12 = J[p + 7], J[p + 8], J[p + 9]
			local a20, a21, a22 = J[p + 10], J[p + 11], J[p + 12]
			local k = slot * 3
			local dx, dy, dz = offset[k - 2], offset[k - 1], offset[k]
			local tx = J[p + 1] + a00 * dx + a01 * dy + a02 * dz
			local ty = J[p + 2] + a10 * dx + a11 * dy + a12 * dz
			local tz = J[p + 3] + a20 * dx + a21 * dy + a22 * dz
			local j = joint[slot]
			if j ~= NONE then
				local pitch, roll = ANG[2 * j - 1], ANG[2 * j]
				local cp, sp = cos(pitch), sin(pitch)
				-- Rx(pitch) x Rz(roll) = [cr, -sr, 0; cp sr, cp cr, -sp; sp sr, sp cr, cp]
				if roll == 0 then
					a01, a02 = a01 * cp + a02 * sp, a02 * cp - a01 * sp
					a11, a12 = a11 * cp + a12 * sp, a12 * cp - a11 * sp
					a21, a22 = a21 * cp + a22 * sp, a22 * cp - a21 * sp
				else
					local cr, sr = cos(roll), sin(roll)
					local b10, b11 = cp * sr, cp * cr
					local b20, b21 = sp * sr, sp * cr
					local n00 = a00 * cr + a01 * b10 + a02 * b20
					local n01 = -a00 * sr + a01 * b11 + a02 * b21
					local n02 = -a01 * sp + a02 * cp
					local n10 = a10 * cr + a11 * b10 + a12 * b20
					local n11 = -a10 * sr + a11 * b11 + a12 * b21
					local n12 = -a11 * sp + a12 * cp
					local n20 = a20 * cr + a21 * b10 + a22 * b20
					local n21 = -a20 * sr + a21 * b11 + a22 * b21
					local n22 = -a21 * sp + a22 * cp
					a00, a01, a02 = n00, n01, n02
					a10, a11, a12 = n10, n11, n12
					a20, a21, a22 = n20, n21, n22
				end
			end
			local o = slot * 12
			J[o + 1], J[o + 2], J[o + 3] = tx, ty, tz
			J[o + 4], J[o + 5], J[o + 6] = a00, a01, a02
			J[o + 7], J[o + 8], J[o + 9] = a10, a11, a12
			J[o + 10], J[o + 11], J[o + 12] = a20, a21, a22
			local ax, ay, az = arm[k - 2], arm[k - 1], arm[k]
			local r = o - 12
			rel[r + 1] = tx + a00 * ax + a01 * ay + a02 * az
			rel[r + 2] = ty + a10 * ax + a11 * ay + a12 * az
			rel[r + 3] = tz + a20 * ax + a21 * ay + a22 * az
			rel[r + 4], rel[r + 5], rel[r + 6] = a00, a01, a02
			rel[r + 7], rel[r + 8], rel[r + 9] = a10, a11, a12
			rel[r + 10], rel[r + 11], rel[r + 12] = a20, a21, a22
		end
	end
end

--[[
	Poses `mob` (its stride and blends: MobModel.stride first) at `now` into `rel`: the frame of
	each drawn slot of `shape` (the build's full or reduced shape) relative to the mob's base,
	12 numbers a slot from (slot - 1) x 12. Hidden slots are left as they are.
]]
function MobRig.pose(rel: { number }, build: Build, shape: Shape, mob: MobModel.Mob, now: number)
	if shape.tier == MobRig.IMPOSTOR then
		table.move(shape.rest, 1, shape.count * 12, 1, rel)
		return
	end
	angles(build, mob, now)
	compose(rel, shape)
end

-- The rest pose (no joint turned) of `shape` into `rel`, as `pose` writes it.
function MobRig.rest(rel: { number }, shape: Shape)
	if shape.tier == MobRig.IMPOSTOR then
		table.move(shape.rest, 1, shape.count * 12, 1, rel)
		return
	end
	table.clear(ANG)
	for i = 1, 2 * JOINTS do
		ANG[i] = 0
	end
	root.pitch, root.roll, root.x, root.y, root.z = 0, 0, 0, 0, 0
	compose(rel, shape)
end

--[[
	The base frame (12 numbers, CFrame.new's order) of a mob drawn with its feet at (x, y, z)
	render studs, facing `yaw`, tipped `tip` radians onto its side (MobModel.tip) about the edge
	`half` studs to its left.
]]
function MobRig.base(
	x: number,
	y: number,
	z: number,
	yaw: number,
	tip: number,
	half: number
): (number, number, number, number, number, number, number, number, number, number, number, number)
	local cy, sy = cos(yaw), sin(yaw)
	if tip == 0 then
		return x, y, z, cy, 0, sy, 0, 1, 0, -sy, 0, cy
	end
	-- Ry(yaw) x [CFrame.new(half, 0, 0) x Rz(-tip) x CFrame.new(-half, 0, 0)]
	local ct, st = cos(tip), sin(tip)
	local lx, ly = half - half * ct, half * st
	return x + cy * lx, y + ly, z - sy * lx, cy * ct, cy * st, sy, -st, ct, 0, -sy * ct, -sy * st, cy
end

--[[
	Writes base x rel for every drawn slot of `shape` into `dst` from `at` (12 numbers each, in
	slot order) and returns where it stopped.
]]
function MobRig.place(
	dst: { number },
	at: number,
	rel: { number },
	shape: Shape,
	bx: number,
	by: number,
	bz: number,
	b00: number,
	b01: number,
	b02: number,
	b10: number,
	b11: number,
	b12: number,
	b20: number,
	b21: number,
	b22: number
): number
	local hidden = shape.hidden
	for slot = 1, shape.count do
		if not hidden[slot] then
			local r = (slot - 1) * 12
			local x, y, z = rel[r + 1], rel[r + 2], rel[r + 3]
			local m00, m01, m02 = rel[r + 4], rel[r + 5], rel[r + 6]
			local m10, m11, m12 = rel[r + 7], rel[r + 8], rel[r + 9]
			local m20, m21, m22 = rel[r + 10], rel[r + 11], rel[r + 12]
			dst[at + 1] = bx + b00 * x + b01 * y + b02 * z
			dst[at + 2] = by + b10 * x + b11 * y + b12 * z
			dst[at + 3] = bz + b20 * x + b21 * y + b22 * z
			dst[at + 4] = b00 * m00 + b01 * m10 + b02 * m20
			dst[at + 5] = b00 * m01 + b01 * m11 + b02 * m21
			dst[at + 6] = b00 * m02 + b01 * m12 + b02 * m22
			dst[at + 7] = b10 * m00 + b11 * m10 + b12 * m20
			dst[at + 8] = b10 * m01 + b11 * m11 + b12 * m21
			dst[at + 9] = b10 * m02 + b11 * m12 + b12 * m22
			dst[at + 10] = b20 * m00 + b21 * m10 + b22 * m20
			dst[at + 11] = b20 * m01 + b21 * m11 + b22 * m21
			dst[at + 12] = b20 * m02 + b21 * m12 + b22 * m22
			at += 12
		end
	end
	return at
end

-- Slots of `shape` drawn (not hidden).
function MobRig.drawn(shape: Shape): number
	local n = 0
	for slot = 1, shape.count do
		if not shape.hidden[slot] then
			n += 1
		end
	end
	return n
end

return MobRig
