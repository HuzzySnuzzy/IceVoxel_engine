--[[
	The local body seen in true first person, through its pure rules (Player/FirstPersonRules): the
	roles of what a character is drawn with (the head and a face decal, a hat by its weld, hair by
	its attachment, a Face type, layered hair and clothing by type or attachment, back and arm
	accessories, the arms), the full hiding matrix (views, the First-Person Body setting, a scope,
	near the camera) and when the near test can be skipped, the two-bone arm (its lengths kept, the
	elbow on the pole's side, straight towards a target out of reach, no NaN at the shoulder or with
	the pole on the line), which holds take the left hand (a handgun's in its sights), the hand
	poses (at rest, at the bottom of the swing, the melee guard's shift, and off the crosshair at 70
	degrees), the wall's pull and lift; an arm's side, the near plane's cut (`clips`: exact against
	a sampled near view; in view only), the sight line through a box (`crosses`), a target's slide
	into reach, the sights at the cheek (`sightsDepth`) and the lowered guns on the body
	(`lowered`); and the glue (Player/FirstPersonBody under Lune): the arm's IK (the grip lands on
	its target whatever the animation does, the hand turned with it, a target out of reach reported,
	the joints put back, R6 left alone, the elbow away from the camera); its render step on a fake
	character (an arm hidden whole where the near plane cuts it in view and only then, a tall chest
	drawn unless cut, a Fire on the root part kept from the eyes, a scope hiding the arms at Camera
	+ 7 in the gun's frame); the hands on every gun (the real Rendering/ItemModels grips,
	Player/HeldItems' hold at rest: lowered and in the sights from 60 degrees down to 30 up (lowered
	to 60 up), four bodies (short and tall, the shoulder at the arm's middle or its inner face, the
	chest leant in the sights), PC's and a phone's near planes: the sight line on the view's axis, a
	hand either on its grip with no part of its arm cut nor in front of the sights, or the
	animation's; both hands on every long gun and the right on every handgun on PC; the hold rates
	printed per body and near plane); and the muzzle placed with the frame's camera.
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local FakeClient = require("../lib/FakeClient")

local CFrame, Vector3 = roblox.CFrame, roblox.Vector3

return function(t, shared, require, _server, client)
	local Rules = require(client.Player.FirstPersonRules)
	local AimRules = require(client.Player.AimRules)
	local Config = require(shared.Config)

	local HEAD: { [string]: boolean } = {
		FaceCenterAttachment = true,
		FaceFrontAttachment = true,
		HairAttachment = true,
		HatAttachment = true,
		NeckRigAttachment = true,
	}

	--[[ Roles ]]

	t.test("first person: roles of the head, the face, rigid and layered accessories, the arms", function()
		local roleOf = Rules.roleOf
		t.eq(roleOf("Head", nil, HEAD), "head", "the head")
		t.eq(roleOf("Head", nil, HEAD), "head", "a face decal is on the head")
		t.eq(roleOf("UpperTorso", nil, HEAD), "body")
		t.eq(roleOf("LeftFoot", nil, HEAD), "body")
		for _, arm in { "RightUpperArm", "RightLowerArm", "RightHand", "LeftUpperArm", "LeftLowerArm", "LeftHand" } do
			t.eq(roleOf(arm, nil, HEAD), "arm", arm)
		end
		t.eq(roleOf("Right Arm", nil, HEAD), "arm", "an R6 arm")
		-- Rigid accessories, welded (AccessoryWeld) to their body part.
		t.eq(
			roleOf("Handle", { kind = "Unknown", joinedTo = "Head", attachments = {} }, HEAD),
			"headWorn",
			"a hat by its weld"
		)
		t.eq(
			roleOf("Handle", { kind = "Back", joinedTo = "UpperTorso", attachments = { "BodyBackAttachment" } }, HEAD),
			"body",
			"a back accessory"
		)
		t.eq(
			roleOf("Handle", { kind = "Waist", joinedTo = "LowerTorso", attachments = { "WaistBackAttachment" } }, HEAD),
			"body",
			"a waist accessory"
		)
		t.eq(
			roleOf("Handle", { kind = "Shoulder", joinedTo = "RightUpperArm", attachments = {} }, HEAD),
			"arm",
			"an accessory on an arm"
		)
		-- By the handle's attachment (not welded yet), by the type.
		t.eq(
			roleOf("Handle", { kind = nil, joinedTo = nil, attachments = { "HairAttachment" } }, HEAD),
			"headWorn",
			"hair by its attachment"
		)
		t.eq(
			roleOf("Handle", { kind = "Face", joinedTo = nil, attachments = {} }, HEAD),
			"headWorn",
			"a Face accessory by its type"
		)
		for _, kind in { "Hat", "Hair", "Face", "Eyebrow", "Eyelash", "Neck" } do
			t.eq(roleOf("Handle", { kind = kind }, HEAD), "headWorn", kind)
		end
		-- Layered (WrapLayer) accessories: hair by its type and attachment, clothing on the body.
		t.eq(
			roleOf("Handle", { kind = "Hair", joinedTo = nil, attachments = { "HairAttachment" } }, HEAD),
			"headWorn",
			"layered hair"
		)
		t.eq(
			roleOf(
				"Handle",
				{ kind = "Jacket", joinedTo = "UpperTorso", attachments = { "BodyFrontAttachment" } },
				HEAD
			),
			"body",
			"a layered jacket"
		)
		t.eq(
			roleOf(
				"Handle",
				{ kind = "Pants", joinedTo = "LowerTorso", attachments = { "WaistCenterAttachment" } },
				HEAD
			),
			"body",
			"layered pants"
		)
		-- A rig attachment the head shares with the torso doesn't make a piece head-worn.
		t.eq(
			roleOf("Handle", { kind = "Front", joinedTo = "UpperTorso", attachments = { "NeckRigAttachment" } }, HEAD),
			"body",
			"not by a rig attachment"
		)
		t.eq(roleOf("Handle", { kind = "Hat" }, {}), "headWorn", "a head without attachments: by type")
	end)

	--[[ Hiding ]]

	t.test("first person: the hiding matrix, and the near test skipped only where it changes nothing", function()
		local hidden = Rules.hidden
		local roles = { "head", "headWorn", "arm", "body" }
		local views = { "third", "first", "sights" }
		for _, role in roles do
			for _, view in views do
				for _, bodyOn in { true, false } do
					for _, scoped in { true, false } do
						for _, near in { true, false } do
							local expected
							if view == "third" then
								expected = near
							elseif not bodyOn then
								expected = true
							elseif role == "head" or role == "headWorn" then
								expected = true
							elseif role == "arm" then
								expected = scoped or near
							else
								expected = near
							end
							local got = hidden(role :: any, view :: any, bodyOn, scoped, near)
							t.eq(got, expected, `{role} {view} body {bodyOn} scoped {scoped} near {near}`)
							if not Rules.needsNear(role :: any, view :: any, bodyOn, scoped) then
								t.eq(
									got,
									hidden(role :: any, view :: any, bodyOn, scoped, not near),
									`{role} {view}: the near test changes nothing`
								)
							end
						end
					end
				end
			end
		end
		-- The rows of the design's table.
		t.eq(hidden("body", "third", true, false, false), false, "third person: drawn")
		t.eq(hidden("head", "third", true, false, true), true, "third person: a camera in the head hides it")
		t.eq(hidden("head", "first", true, false, false), true, "first person: no head")
		t.eq(hidden("headWorn", "sights", true, false, false), true, "the sights: no hat")
		t.eq(hidden("arm", "sights", true, true, false), true, "a scope hides the arms")
		t.eq(hidden("arm", "sights", true, false, false), false, "iron sights: the arms on the gun")
		t.eq(hidden("body", "first", true, false, false), false, "first person: the chest, legs and feet")
		t.eq(hidden("body", "first", false, false, false), true, "the setting off: Minecraft's hand")
		-- Near: the near plane's distance and a margin (more for what the bob and the sway move).
		t.eq(Rules.CLIP_MARGIN, 0.05)
		t.eq(Rules.CAMERA_SLACK, 0.1)
	end)

	--[[ Arms ]]

	local function dist(ax: number, ay: number, az: number, bx: number, by: number, bz: number): number
		return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2 + (az - bz) ^ 2)
	end
	local function finite(...: number): boolean
		for _, v in { ... } do
			if v ~= v or v == math.huge or v == -math.huge then
				return false
			end
		end
		return true
	end

	t.test("first person: the two-bone arm keeps its lengths and bends to the pole", function()
		local twoBone = Rules.twoBone
		math.randomseed(1703)
		local function r(lo: number, hi: number): number
			return lo + (hi - lo) * math.random()
		end
		for _ = 1, 2000 do
			local sx, sy, sz = r(-3, 3), r(-3, 3), r(-3, 3)
			local a, b = r(0.3, 1.5), r(0.3, 1.5)
			-- Targets inside, at the edges and out of reach.
			local reach = r(0, (a + b) * 1.4)
			local theta, phi = r(0, 2 * math.pi), r(-1.5, 1.5)
			local wx = sx + reach * math.cos(phi) * math.cos(theta)
			local wy = sy + reach * math.sin(phi)
			local wz = sz + reach * math.cos(phi) * math.sin(theta)
			local px, py, pz = sx + r(-2, 2), sy + r(-2, 2), sz + r(-2, 2)
			local ex, ey, ez, reached, rx, ry, rz = twoBone(sx, sy, sz, wx, wy, wz, px, py, pz, a, b)
			t.ok(finite(ex, ey, ez, rx, ry, rz), "no NaN")
			t.near(dist(ex, ey, ez, sx, sy, sz), a, 1e-9, "the upper arm's length")
			t.near(dist(rx, ry, rz, ex, ey, ez), b, 1e-9, "the forearm's length")
			local d = dist(wx, wy, wz, sx, sy, sz)
			local inside = d <= a + b and d >= math.abs(a - b)
			t.eq(reached, inside, "reached when within reach")
			if reached then
				t.near(dist(rx, ry, rz, wx, wy, wz), 0, 1e-9, "the wrist on the target")
			else
				-- Straight towards the target: the wrist on the line from the shoulder.
				local ux, uy, uz = (wx - sx) / d, (wy - sy) / d, (wz - sz) / d
				local along = (rx - sx) * ux + (ry - sy) * uy + (rz - sz) * uz
				t.near(dist(rx, ry, rz, sx + ux * along, sy + uy * along, sz + uz * along), 0, 1e-9, "on the line")
				t.ok(along >= 0, "towards it")
				if d > a + b then
					t.near(along, a + b, 1e-9, "as far as it reaches")
					t.near(
						dist(ex, ey, ez, sx + ux * a, sy + uy * a, sz + uz * a),
						0,
						1e-7,
						"the elbow straight on the line"
					)
				end
			end
			-- The elbow on the pole's side of the reach.
			if reached and d > 1e-3 then
				local ux, uy, uz = (wx - sx) / d, (wy - sy) / d, (wz - sz) / d
				local qx, qy, qz = px - sx, py - sy, pz - sz
				local q = qx * ux + qy * uy + qz * uz
				local nx, ny, nz = qx - ux * q, qy - uy * q, qz - uz * q
				local n = math.sqrt(nx * nx + ny * ny + nz * nz)
				if n > 1e-3 then
					local side = ((ex - sx) * nx + (ey - sy) * ny + (ez - sz) * nz) / n
					t.ok(side >= -1e-9, "the elbow towards the pole")
				end
			end
		end
	end)

	t.test("first person: the two-bone arm at its edges gives no NaN", function()
		local twoBone = Rules.twoBone
		-- A target at the shoulder: folded towards the pole.
		local ex, ey, ez, reached, rx, ry, rz = twoBone(1, 2, 3, 1, 2, 3, 1, 1, 3, 1, 1)
		t.ok(finite(ex, ey, ez, rx, ry, rz), "no NaN at the shoulder")
		t.eq(reached, true, "equal bones fold onto the shoulder")
		t.near(dist(ex, ey, ez, 1, 2, 3), 1, 1e-9)
		t.near(dist(rx, ry, rz, 1, 2, 3), 0, 1e-9)
		t.ok(ey < 2, "folded towards the pole (below)")
		-- Unequal bones can't reach their shoulder: as close as they fold.
		ex, ey, ez, reached, rx, ry, rz = twoBone(0, 0, 0, 0, 0, 0, 0, -1, 0, 1, 0.6)
		t.ok(finite(ex, ey, ez, rx, ry, rz), "no NaN")
		t.eq(reached, false)
		t.near(dist(rx, ry, rz, 0, 0, 0), 0.4, 1e-9, "folded")
		-- The shoulder, the target and the pole all in one point.
		ex, ey, ez, _, rx, ry, rz = twoBone(0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1)
		t.ok(finite(ex, ey, ez, rx, ry, rz), "no NaN with nothing to go by")
		-- The pole on the reach's line (straight down, and straight ahead).
		ex, ey, ez, reached = twoBone(0, 0, 0, 0, -1.5, 0, 0, -3, 0, 1, 1)
		t.ok(finite(ex, ey, ez), "a pole on the line")
		t.eq(reached, true)
		t.near(dist(ex, ey, ez, 0, 0, 0), 1, 1e-9)
		ex, ey, ez = twoBone(0, 0, 0, 0, 0, -1.5, 0, 0, -3, 1, 1)
		t.ok(finite(ex, ey, ez), "a pole on the line ahead")
		-- Fully stretched exactly.
		ex, ey, ez, reached, rx, ry, rz = twoBone(0, 0, 0, 2, 0, 0, 1, -1, 0, 1, 1)
		t.eq(reached, true)
		t.near(ex, 1, 1e-9, "straight")
		t.near(ey, 0, 1e-6)
	end)

	t.test("first person: the left hand on a long gun and a guard only", function()
		t.eq(Rules.leftHand("firearm", true, false), true, "a long gun's fore end")
		t.eq(Rules.leftHand("firearm", false, false), false, "a handgun lowered: one hand")
		t.eq(Rules.leftHand("firearm", false, false, true), true, "a handgun in its sights: two hands")
		t.eq(Rules.leftHand("firearm", true, false, false), true, "a long gun lowered: both")
		t.eq(Rules.leftHand("tool", false, true), true, "a guard: both hands on the handle")
		t.eq(Rules.leftHand("tool", false, false), false)
		t.eq(Rules.leftHand("block", false, false), false)
		t.eq(Rules.leftHand("empty", false, false), false)
	end)

	--[[ Poses ]]

	t.test("first person: the hand poses at rest, at the bottom of the swing, guarding", function()
		local handPose = Rules.handPose
		local function pose(kind: string, dip: number, guard: number?, charge: number?): { number }
			return { handPose(kind :: any, dip, guard or 0, charge or 0) }
		end
		-- The punch: from low at the side to ahead of the middle.
		local rest, punched = pose("empty", 0), pose("empty", 1)
		t.near(rest[1], 0.5, 1e-9)
		t.near(rest[2], -0.9, 1e-9)
		t.near(rest[3], -0.8, 1e-9)
		t.near(punched[1], 0.15, 1e-9)
		t.near(punched[2], -0.35, 1e-9)
		t.near(punched[3], -1.6, 1e-9)
		-- A tool chops 55 degrees forward and down; a block dips 40.
		local tool, chopped = pose("tool", 0), pose("tool", 1)
		t.near(math.deg(chopped[4] - tool[4]), -55, 1e-9, "the chop")
		t.ok(chopped[1] < tool[1] and chopped[2] < tool[2], "towards the middle and down")
		t.ok(tool[6] > 0, "leaning left")
		local block, dipped = pose("block", 0), pose("block", 1)
		t.near(math.deg(dipped[4] - block[4]), -40, 1e-9)
		t.near(math.deg(block[5]), 40, 1e-9, "turned to show two sides")
		-- Out of range dips are the ends.
		t.near(pose("tool", 2)[4], chopped[4], 1e-12)
		t.near(pose("tool", -1)[4], tool[4], 1e-12)
		-- The melee guard and the wind-up: AimRules.meleeView's shift.
		for _, gc in { { 1, 0 }, { 0, 1 }, { 0.4, 0.7 } } do
			local g, c = gc[1], gc[2]
			local sx, sy, sz, roll, tip = AimRules.meleeView(g, c)
			local shifted = pose("tool", 0, g, c)
			t.near(shifted[1] - tool[1], sx, 1e-9)
			t.near(shifted[2] - tool[2], sy, 1e-9)
			t.near(shifted[3] - tool[3], sz, 1e-9)
			t.near(math.deg(shifted[6] - tool[6]), roll, 1e-9)
			t.near(math.deg(shifted[4] - tool[4]), tip, 1e-9)
		end
	end)

	-- (x, y, z) turned by CFrame.Angles(rx, ry, rz) (X, then Y, then Z: Rx * Ry * Rz).
	local function turn(rx: number, ry: number, rz: number, x: number, y: number, z: number): (number, number, number)
		local c, s = math.cos(rz), math.sin(rz)
		x, y = c * x - s * y, s * x + c * y
		c, s = math.cos(ry), math.sin(ry)
		x, z = c * x + s * z, -s * x + c * z
		c, s = math.cos(rx), math.sin(rx)
		y, z = c * y - s * z, s * y + c * z
		return x, y, z
	end
	-- Degrees off the crosshair of a point in the camera's space.
	local function off(x: number, y: number, z: number): number
		return math.deg(math.atan(math.sqrt(x * x + y * y) / -z))
	end

	t.test("first person: the tool's head and the block's corners stay off the crosshair at 70 degrees", function()
		local half = math.rad(35)
		for _, dip in { 0, 0.25, 0.5, 0.75, 1 } do
			-- A 1.8 stud tool (ItemModels.handSize): 1.4 above the grip, a head up to 0.8 each way.
			local x, y, z, p, yw, r = Rules.handPose("tool", dip, 0, 0)
			for _, at in { { 0, 1.4, 0 }, { -0.8, 1.4, 0 }, { 0.8, 1.4, 0 }, { 0, 0.7, 0 }, { -0.4, 1.4, 0 } } do
				local ox, oy, oz = turn(p, yw, r, at[1], at[2], at[3])
				t.ok(off(x + ox, y + oy, z + oz) > 3, `the tool at dip {dip} clears the crosshair`)
			end
			t.ok(-y / -z < math.tan(half) * 1.05, "the hand at the bottom edge or above")
			-- A 1.2 stud block, its centre 0.36 past the fist.
			x, y, z, p, yw, r = Rules.handPose("block", dip, 0, 0)
			local cx, cy, cz = turn(p, yw, r, 0, 0, -0.36)
			cx, cy, cz = x + cx, y + cy, z + cz
			for _, sx in { -0.6, 0.6 } do
				for _, sy in { -0.6, 0.6 } do
					for _, sz in { -0.6, 0.6 } do
						local ox, oy, oz = turn(p, yw, r, sx, sy, sz)
						t.ok(off(cx + ox, cy + oy, cz + oz) > 8, `the block at dip {dip} clears the crosshair`)
					end
				end
			end
		end
	end)

	t.test("first person: an item at a wall is pulled back, then lifted", function()
		local obstruction = Rules.obstruction
		local pull, lift = obstruction(math.huge, 2.5)
		t.eq(pull, 0)
		t.eq(lift, 0, "nothing in the way")
		pull, lift = obstruction(2.5, 2.5)
		t.eq(pull, 0, "just fits")
		pull, lift = obstruction(2.2, 2.5)
		t.near(pull, 0.3, 1e-12, "pulled back by the overlap")
		t.eq(lift, 0, "not lifted yet")
		pull, lift = obstruction(2.5 - Rules.PULL, 2.5)
		t.near(pull, Rules.PULL, 1e-12)
		t.near(lift, 0, 1e-12, "fully pulled, not lifted")
		pull, lift = obstruction(2.5 - Rules.PULL - Rules.LIFT_SPAN / 2, 2.5)
		t.near(pull, Rules.PULL, 1e-12)
		t.near(lift, Rules.LIFT / 2, 1e-12, "then lifted")
		pull, lift = obstruction(0, 2.5)
		t.near(pull, Rules.PULL, 1e-12)
		t.near(lift, Rules.LIFT, 1e-12, "at most")
		t.near(math.deg(Rules.LIFT), 60, 1e-9, "DayZ's lift")
		t.near(Rules.PULL, 0.8, 1e-12)
	end)

	--[[ The glue's arm ]]

	-- A fake instance tree for the arm: parts, Motor6Ds and attachments with Roblox's datatypes.
	local function fake(class: string, name: string, props: { [string]: any }?): any
		local object: any = props or {}
		object.ClassName = class
		object.Name = name
		object.__children = {}
		local bases: { [string]: { string } } = {
			Part = { "Part", "BasePart", "Instance" },
			MeshPart = { "MeshPart", "BasePart", "Instance" },
			Motor6D = { "Motor6D", "JointInstance", "Instance" },
			Attachment = { "Attachment", "Instance" },
			Model = { "Model", "Instance" },
			Humanoid = { "Humanoid", "Instance" },
			Fire = { "Fire", "Instance" },
		}
		function object.IsA(self: any, wanted: string): boolean
			return table.find(bases[self.ClassName], wanted) ~= nil
		end
		function object.FindFirstChild(self: any, wanted: string): any
			return self.__children[wanted]
		end
		function object.GetChildren(self: any): { any }
			local list = {}
			for _, child in self.__children do
				table.insert(list, child)
			end
			return list
		end
		function object.GetDescendants(self: any): { any }
			local list = {}
			local function walk(at: any)
				for _, child in at.__children do
					table.insert(list, child)
					walk(child)
				end
			end
			walk(self)
			return list
		end
		function object.FindFirstChildOfClass(self: any, class: string): any
			for _, child in self.__children do
				if child.ClassName == class then
					return child
				end
			end
			return nil
		end
		function object.FindFirstAncestorWhichIsA(self: any, class: string): any
			local at = self.Parent
			while at do
				if at:IsA(class) then
					return at
				end
				at = at.Parent
			end
			return nil
		end
		return object
	end
	local function parent(child: any, to: any)
		child.Parent = to
		to.__children[child.Name] = child
	end

	-- An R15 right arm on a torso at `torsoFrame` (C0 / C1 from rig attachments, as Roblox's).
	local function r15(torsoFrame: any): (any, any)
		local character = fake("Model", "Character")
		local torso = fake("MeshPart", "UpperTorso", { CFrame = torsoFrame, Size = Vector3.new(2, 1.6, 1) })
		parent(torso, character)
		local chain: { any } = { torso }
		-- (part, size, joint, Part0's attachment, Part1's attachment)
		local specs = {
			{
				"RightUpperArm",
				Vector3.new(1, 1.17, 1),
				"RightShoulder",
				CFrame.new(1, 0.56, 0) * CFrame.Angles(0, 0, 0.05),
				CFrame.new(-0.25, 0.42, 0.02),
			},
			{ "RightLowerArm", Vector3.new(1, 1.05, 1), "RightElbow", CFrame.new(0, -0.33, 0), CFrame.new(0, 0.2, 0) },
			{ "RightHand", Vector3.new(1, 0.3, 1), "RightWrist", CFrame.new(0, -0.5, 0), CFrame.new(0, 0.125, 0) },
		}
		for _, spec in specs do
			local name, size, jointName, at0, at1 = spec[1], spec[2], spec[3], spec[4], spec[5]
			local part0 = chain[#chain]
			local part1 = fake("MeshPart", name, { Size = size })
			parent(part1, character)
			local a0 = fake("Attachment", jointName .. "RigAttachment", { CFrame = at0, Position = at0.Position })
			parent(a0, part0)
			local motor = fake("Motor6D", jointName, {
				Part0 = part0,
				Part1 = part1,
				C0 = at0,
				C1 = at1,
				Transform = CFrame.identity,
			})
			parent(motor, part1)
			table.insert(chain, part1)
		end
		local hand = chain[4]
		local grip = CFrame.new(0, -0.15, 0) * CFrame.Angles(-math.pi / 2, 0, 0)
		parent(fake("Attachment", "RightGripAttachment", { CFrame = grip, Position = grip.Position }), hand)
		-- (A left arm too, the same mirrored, so the rig is whole.)
		local left = fake("MeshPart", "LeftUpperArm", { Size = Vector3.new(1, 1.17, 1) })
		parent(left, character)
		local leftLower = fake("MeshPart", "LeftLowerArm", { Size = Vector3.new(1, 1.05, 1) })
		parent(leftLower, character)
		local leftHand = fake("MeshPart", "LeftHand", { Size = Vector3.new(1, 0.3, 1) })
		parent(leftHand, character)
		local function joint(name: string, part0: any, part1: any, at0: any, at1: any)
			local a0 = fake("Attachment", name .. "RigAttachment", { CFrame = at0, Position = at0.Position })
			parent(a0, part0)
			parent(
				fake("Motor6D", name, { Part0 = part0, Part1 = part1, C0 = at0, C1 = at1, Transform = CFrame.identity }),
				part1
			)
		end
		joint("LeftShoulder", torso, left, CFrame.new(-1, 0.56, 0), CFrame.new(0.25, 0.42, 0))
		joint("LeftElbow", left, leftLower, CFrame.new(0, -0.33, 0), CFrame.new(0, 0.2, 0))
		joint("LeftWrist", leftLower, leftHand, CFrame.new(0, -0.5, 0), CFrame.new(0, 0.125, 0))
		return character, hand
	end

	-- The right hand's world frame from the joints (Part1 = Part0 * C0 * Transform * C1^-1).
	local function handFrame(character: any): any
		local frame = character:FindFirstChild("UpperTorso").CFrame
		for _, name in
			{ { "RightUpperArm", "RightShoulder" }, { "RightLowerArm", "RightElbow" }, { "RightHand", "RightWrist" } }
		do
			local motor = character:FindFirstChild(name[1]):FindFirstChild(name[2])
			frame = frame * motor.C0 * motor.Transform * motor.C1:Inverse()
		end
		return frame
	end

	local function loadBody(): any
		local load = FakeClient.loader(shared, require, {
			["src/client/Player/CameraRig.luau"] = {},
		}, { Players = {}, RunService = {} })
		return load("src/client/Player/FirstPersonBody.luau")
	end

	t.test("first person: the arm's IK puts the grip on its target whatever the animation does", function()
		local Body = loadBody()
		local torsoFrame = CFrame.new(10, 4, -3) * CFrame.Angles(0.1, 0.7, -0.05)
		local character, hand = r15(torsoFrame)
		local gripAt = hand:FindFirstChild("RightGripAttachment").Position
		local shoulder = character:FindFirstChild("RightUpperArm"):FindFirstChild("RightShoulder")
		local elbow = character:FindFirstChild("RightLowerArm"):FindFirstChild("RightElbow")
		local wrist = hand:FindFirstChild("RightWrist")
		local turnHand = CFrame.Angles(math.pi / 2, 0, 0)
		math.randomseed(77)
		for i = 1, 60 do
			-- The animation turns every joint (its Transform).
			shoulder.Transform = CFrame.Angles(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5)
			elbow.Transform = CFrame.Angles(math.random() - 0.5, 0, 0)
			wrist.Transform = CFrame.Angles(0, math.random() - 0.5, math.random() - 0.5)
			-- A grip ahead of the right shoulder, within reach, turned anyhow.
			local ahead = torsoFrame
				* CFrame.new(0.4 + math.random() * 0.6, 0.2 + math.random() * 0.6, -1.0 - math.random() * 0.4)
				* CFrame.Angles(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5)
			Body.poseArms(character, ahead, nil)
			local frame = handFrame(character)
			local got = frame * gripAt
			t.near((got - ahead.Position).Magnitude, 0, 2e-3, `grip {i} on its target`)
			t.near(Body.reach().Magnitude, 0, 2e-3, "reached")
			local want = ahead.Rotation * turnHand
			local axisError = (frame.LookVector - want.LookVector).Magnitude
				+ (frame.UpVector - want.UpVector).Magnitude
			t.ok(axisError < 5e-3, `hand {i} turned with the grip ({axisError})`)
		end
		-- Out of reach: the hand gets as far as it can and says where.
		shoulder.Transform, elbow.Transform, wrist.Transform = CFrame.identity, CFrame.identity, CFrame.identity
		local far = torsoFrame * CFrame.new(1, 0.5, -6)
		Body.poseArms(character, far, nil)
		local got = handFrame(character) * gripAt
		local miss = Body.reach()
		t.ok(miss.Magnitude > 2, "out of reach")
		t.near((got - (far.Position + miss)).Magnitude, 0, 2e-3, "the miss is where the grip got")
		-- Released: the joints as they were (their rig attachments).
		Body.release(character)
		t.eq(shoulder.C0, character:FindFirstChild("UpperTorso"):FindFirstChild("RightShoulderRigAttachment").CFrame)
		t.eq(elbow.C0, character:FindFirstChild("RightUpperArm"):FindFirstChild("RightElbowRigAttachment").CFrame)
		t.eq(wrist.C0, character:FindFirstChild("RightLowerArm"):FindFirstChild("RightWristRigAttachment").CFrame)
		-- A punch eases in: half the weight is half way in the joints.
		local target = torsoFrame * CFrame.new(0.6, 0.4, -1.2)
		Body.poseArmsWeighted(character, target, nil, 0.5, 0)
		local half = shoulder.C0
		Body.poseArms(character, target, nil)
		local full = shoulder.C0
		local base = character:FindFirstChild("UpperTorso"):FindFirstChild("RightShoulderRigAttachment").CFrame
		t.near((half.Position - base:Lerp(full, 0.5).Position).Magnitude, 0, 1e-4, "weighted from the animation")
		-- nil leaves the arm to the animation.
		Body.poseArms(character, nil, nil)
		t.eq(shoulder.C0, base, "nil: put back")
	end)

	t.test("first person: no IK for an R6 body", function()
		local Body = loadBody()
		local character = fake("Model", "R6")
		local torso = fake("Part", "Torso", { CFrame = CFrame.identity, Size = Vector3.new(2, 2, 1) })
		parent(torso, character)
		local arm = fake("Part", "Right Arm", { CFrame = CFrame.new(1.5, 0, 0), Size = Vector3.new(1, 2, 1) })
		parent(arm, character)
		local motor = fake("Motor6D", "Right Shoulder", {
			Part0 = torso,
			Part1 = arm,
			C0 = CFrame.new(1, 0.5, 0),
			C1 = CFrame.new(-0.5, 0.5, 0),
			Transform = CFrame.identity,
		})
		parent(motor, torso)
		Body.poseArms(character, CFrame.new(1, 0, -2), nil)
		t.eq(motor.C0, CFrame.new(1, 0.5, 0), "left alone")
		t.eq(Body.reach().Magnitude, 0)
	end)

	--[[ The near plane, an arm whole, what burns on the root ]]

	t.test("first person: an arm is one piece, by its side; what is on the root is kept from the eyes", function()
		for name in Rules.ARM_PARTS do
			local side = Rules.armSide(name)
			t.eq(side, if string.sub(name, 1, 5) == "Right" then 1 else -1, name)
		end
		t.eq(Rules.armSide("UpperTorso"), 0)
		t.eq(Rules.armSide(nil), 0, "an accessory joined to nothing yet")
		-- A burning player's Fire is in their root part (Rendering/BurningView): drawn like the head,
		-- so it never rises through the camera from the eyes, and is seen in third person.
		t.eq(Rules.roleOf("HumanoidRootPart", nil, HEAD), "head", "an effect on the root part")
		t.eq(Rules.hidden("head", "first", true, false, false), true, "from the eyes: hidden")
		t.eq(Rules.hidden("head", "third", true, false, false), false, "over the shoulder: drawn")
	end)

	-- Every point of the near view sampled (`n` a side), whether any is inside the box (camera space:
	-- centre c, half axes u, v, w).
	local function sampledInside(
		c: any,
		u: any,
		v: any,
		w: any,
		depth: number,
		tx: number,
		ty: number,
		n: number
	): boolean
		local frame = CFrame.fromMatrix(c, u.Unit, v.Unit, w.Unit)
		local hu, hv, hw = u.Magnitude, v.Magnitude, w.Magnitude
		for k = 0, n do
			local d = depth * k / n
			for i = 0, n do
				for j = 0, n do
					local p =
						frame:PointToObjectSpace(Vector3.new((i / n * 2 - 1) * tx * d, (j / n * 2 - 1) * ty * d, -d))
					if math.abs(p.X) <= hu and math.abs(p.Y) <= hv and math.abs(p.Z) <= hw then
						return true
					end
				end
			end
		end
		return false
	end

	t.test("first person: the near plane's cut (clips) is exact: in view, never beside or behind", function()
		local clips = Rules.clips
		local function box(c: any, size: any, turn: any?): boolean
			local frame = (turn or CFrame.identity)
			local u = frame.XVector * size.X / 2
			local v = frame.YVector * size.Y / 2
			local w = frame.ZVector * size.Z / 2
			return clips(c.X, c.Y, c.Z, u.X, u.Y, u.Z, v.X, v.Y, v.Z, w.X, w.Y, w.Z, 0.15, 0.8, 0.45)
		end
		local unit = Vector3.new(1, 1, 1)
		t.eq(box(Vector3.new(0, 0, -0.3), unit), true, "straddling the near plane ahead")
		t.eq(box(Vector3.new(0, 0, 0), unit), true, "the camera inside it")
		t.eq(box(Vector3.new(0, 0, -0.7), unit), false, "ahead, past the near view")
		t.eq(box(Vector3.new(0, 0, 0.6), unit), false, "behind the camera")
		t.eq(box(Vector3.new(0.75, 0, 0), unit), false, "beside the camera, out of view")
		t.eq(box(Vector3.new(0, -0.62, -0.1), unit), false, "below it, out of view")
		t.eq(box(Vector3.new(0, -0.55, -0.1), unit), true, "reaching up into the view")
		t.eq(box(Vector3.new(0.6, 0, -0.1), unit, CFrame.Angles(0, math.rad(45), 0)), true, "turned, a corner in view")
		-- Random boxes against a sampled near view: never a miss (a sampled point inside means it
		-- clips), and where it says it clips, a finer sampling finds the overlap (exact, no false
		-- alarms but for slivers thinner than the sampling).
		math.randomseed(2024)
		local function r(lo: number, hi: number): number
			return lo + (hi - lo) * math.random()
		end
		local alarms, checked, clipping = 0, 0, 0
		for _ = 1, 400 do
			local depth, tx, ty = r(0.1, 0.6), r(0.5, 1.5), r(0.4, 1)
			local c = Vector3.new(r(-1.2, 1.2), r(-1.2, 1.2), r(-1.2, 0.8))
			local turn = CFrame.Angles(r(-3, 3), r(-3, 3), r(-3, 3))
			local u = turn.XVector * r(0.05, 0.6)
			local v = turn.YVector * r(0.05, 0.6)
			local w = turn.ZVector * r(0.05, 0.6)
			local said = clips(c.X, c.Y, c.Z, u.X, u.Y, u.Z, v.X, v.Y, v.Z, w.X, w.Y, w.Z, depth, tx, ty)
			local seen = sampledInside(c, u, v, w, depth, tx, ty, 10)
			if said then
				clipping += 1
			end
			if seen then
				t.eq(said, true, "a box the sampling finds in the near view clips")
			elseif said then
				checked += 1
				if not sampledInside(c, u, v, w, depth, tx, ty, 40) then
					alarms += 1
				end
			end
		end
		t.ok(clipping > 50 and clipping < 350, `boxes either way ({clipping} of 400 clip)`)
		t.ok(alarms <= 1, `no false alarms (one sliver allowed): {alarms} of {checked}`)
	end)

	t.test("first person: the sights at the cheek, the lowered guns on the body, the sight line kept clear", function()
		-- The sight line's rear 0.45 ahead of the eyes, nearer looking up; never within the near
		-- plane's margin and SIGHTS_CLEAR (a phone's 0.5 near plane keeps it further).
		t.near(Rules.sightsDepth(0, 0.15), 0.45, 1e-12, "level, a computer")
		t.near(Rules.sightsDepth(math.rad(-60), 0.15), 0.45, 1e-12, "looking down: the same")
		t.near(Rules.sightsDepth(math.rad(30), 0.15), 0.45 - 0.2 * 0.5, 1e-12, "looking up: nearer")
		t.near(Rules.sightsDepth(math.rad(90), 0.15), 0.35, 1e-12, "never within the clearance")
		t.near(Rules.sightsDepth(0, 0.55), 0.75, 1e-12, "a phone's near plane")
		-- Lowered on the body, following a share of the aim's pitch: a long gun across it (the barrel
		-- to the left), a handgun ahead on the right.
		local turn, x, y, z, yaw, pitch = Rules.lowered(math.rad(-50), true)
		t.near(turn, math.rad(-50) * Rules.LOWERED.follow, 1e-12)
		t.near(x, Rules.LOWERED.x, 1e-12)
		t.near(y, Rules.LOWERED.y, 1e-12)
		t.near(z, Rules.LOWERED.z, 1e-12)
		t.ok(yaw > math.rad(20), "across the body, the muzzle to the left")
		t.near(pitch, math.rad(Rules.LOWERED.pitch), 1e-12)
		local _, hx = Rules.lowered(0, false)
		t.near(hx, Rules.LOWERED_HANDGUN.x, 1e-12, "a handgun's own")
		-- The hands under the gun: the right hand's fingers up its grip, the left's up round the fore
		-- end; a left hand in the way tries back along the barrel, and once a little forward.
		t.near(math.deg(Rules.GRIP_TILT), 90, 1e-9)
		t.near(math.deg(Rules.FORE_TILT), 45, 1e-9)
		t.eq(Rules.FORE_TRIES[1], 0, "where it reaches first")
		-- The sight line through a box: a unit box straddling the axis ahead, beside it, behind the
		-- camera, past the reach, and the near part before `near`.
		local function cross(cx: number, cy: number, cz: number, near: number, far: number): boolean
			-- (The camera at the origin looking down -z; the box's own space: the camera at -c.)
			return Rules.crosses(-cx, -cy, -cz, 0, 0, -1, 0.5, 0.5, 0.5, near, far)
		end
		t.eq(cross(0, 0, -2, 0.1, 4), true, "a box on the sight line")
		t.eq(cross(0.6, 0, -2, 0.1, 4), false, "beside it")
		t.eq(cross(0, -0.49, -2, 0.1, 4), true, "its top edge across it")
		t.eq(cross(0, 0, 2, 0.1, 4), false, "behind the camera")
		t.eq(cross(0, 0, -5, 0.1, 4), false, "past the reach")
		t.eq(cross(0, 0, -0.3, 0.9, 4), false, "only before `near`")
		-- A turned box (any direction of the view in its space).
		local frame = CFrame.new(0.3, 0.1, -1.5) * CFrame.Angles(0.4, 0.7, 0.2)
		local at = frame:PointToObjectSpace(Vector3.zero)
		local along = frame:VectorToObjectSpace(Vector3.new(0, 0, -1))
		t.eq(Rules.crosses(at.X, at.Y, at.Z, along.X, along.Y, along.Z, 0.5, 0.5, 0.5, 0.1, 4), true, "turned, on it")
	end)

	t.test("first person: a target slides along a line to come in reach (slide)", function()
		local slide = Rules.slide
		t.eq(slide(0, 0, 0, 1, 0, 0, 1, 0, 0, 2, 5), 0, "in reach already")
		-- From 3 ahead, sliding back towards the shoulder: in reach of 2 after 1.
		t.near(slide(0, 0, 0, 0, 0, -3, 0, 0, 1, 2, 5) :: number, 1, 1e-12, "the least slide")
		t.eq(slide(0, 0, 0, 0, 0, -3, 0, 0, 1, 2, 0.5), nil, "not within the limit")
		t.eq(slide(0, 0, 0, 0, 0, -3, 0, 0, -1, 2, 5), nil, "sliding away never comes in reach")
		t.eq(slide(0, 0, 0, 3, 0, -3, 0, 0, 1, 2, 10), nil, "the line passes out of reach")
		-- Past a line's nearest point: the first point in reach.
		local t1 = slide(0, 0, 0, 1, 0, -3, 0, 0, 1, 2, 10) :: number
		t.near(t1, 3 - math.sqrt(3), 1e-12)
		t.near(math.sqrt(1 + (t1 - 3) ^ 2), 2, 1e-12, "on the reach")
	end)

	--[[ The glue's visibility (Player/FirstPersonBody's render step on a fake character) ]]

	-- A camera as Roblox's: its frame, near plane, field of view and viewport.
	local function cameraAt(frame: any, nearZ: number): any
		return { CFrame = frame, NearPlaneZ = -nearZ, FieldOfView = 70, ViewportSize = roblox.Vector2.new(1600, 900) }
	end

	--[[
		FirstPersonBody with its render step caught, the rig active in `view` (h.view), a local
		character whose parts sit where a test puts them, the camera at the eyes (0, 5, 0) looking
		down -Z with PC's near plane.
	]]
	local function harness(): any
		local h: any = { view = "first" }
		h.camera = cameraAt(CFrame.new(0, 5, 0), 0.1)
		local character = fake("Model", "Character")
		local function signal(): any
			return {
				Connect = function()
					return { Disconnect = function() end }
				end,
			}
		end
		character.DescendantAdded = signal()
		character.DescendantRemoving = signal()
		parent(fake("Humanoid", "Humanoid", { RigType = roblox.Enum.HumanoidRigType.R15, Health = 100 }), character)
		h.character = character
		function h.part(name: string, at: any, size: any, under: any?): any
			local p =
				fake("Part", name, { CFrame = at, Position = at.Position, Size = size, LocalTransparencyModifier = 0 })
			parent(p, under or character)
			return p
		end
		local player = {
			Character = character,
			GetAttribute = function(): any
				return nil
			end,
		}
		h.Body = FakeClient.loader(shared, require, {
			["src/client/Player/CameraRig.luau"] = {
				active = function(): boolean
					return true
				end,
				holding = function(): boolean
					return false
				end,
				view = function(): string
					return h.view
				end,
			},
		}, {
			Players = { LocalPlayer = player },
			RunService = {
				BindToRenderStep = function(_, _name: string, _priority: number, fn: () -> ())
					h.step = fn
				end,
			},
		})("src/client/Player/FirstPersonBody.luau")
		h.Body.start()
		-- (Roblox's `workspace` for the step, for this test only.)
		h.env = getfenv(h.Body.start)
		h.env.workspace = { CurrentCamera = h.camera }
		function h.done()
			h.env.workspace = nil
		end
		return h
	end

	t.test("first person: an arm is hidden whole where the near plane cuts it in view, and only then", function()
		local h = harness()
		local size = { upper = Vector3.new(1, 1.17, 1), lower = Vector3.new(1, 1.05, 1), hand = Vector3.new(1, 0.3, 1) }
		h.part("Head", CFrame.new(0, 5, 0.1), Vector3.new(1.2, 1.2, 1.2))
		local torso = h.part("UpperTorso", CFrame.new(0, 3.4, 0.15), Vector3.new(2, 1.6, 1))
		-- The right arm: its forearm cut by the near plane in view, its hand well ahead.
		local rightUpper = h.part("RightUpperArm", CFrame.new(1.5, 3.8, 0.2), size.upper)
		local rightLower = h.part("RightLowerArm", CFrame.new(0.3, 4.7, -0.3), size.lower)
		local rightHand = h.part("RightHand", CFrame.new(0.6, 4.0, -2), size.hand)
		-- The left arm: its upper arm within NearClear of the camera but beside and behind it, out
		-- of view; its hand ahead.
		local leftUpper = h.part("LeftUpperArm", CFrame.new(-0.9, 5, 0.4), size.upper)
		local leftLower = h.part("LeftLowerArm", CFrame.new(-1.2, 4, -0.8), size.lower)
		local leftHand = h.part("LeftHand", CFrame.new(-0.6, 4, -2), size.hand)
		h.step()
		for _, p in { rightUpper, rightLower, rightHand } do
			t.eq(p.LocalTransparencyModifier, 1, `{p.Name}: the right arm hidden whole (no lone hand)`)
			t.eq(h.Body.hides(p), true, `{p.Name}: its worn pieces go with it`)
		end
		for _, p in { leftUpper, leftLower, leftHand } do
			t.eq(p.LocalTransparencyModifier, 0, `{p.Name}: the left arm drawn (out of view is never cut)`)
		end
		t.eq(torso.LocalTransparencyModifier, 0, "the chest drawn")
		t.eq(h.character:FindFirstChild("Head").LocalTransparencyModifier, 1, "no head")
		-- The forearm moved out of the near view: the whole arm comes back.
		rightLower.CFrame = CFrame.new(1.2, 3.6, -0.6)
		rightLower.Position = rightLower.CFrame.Position
		h.step()
		for _, p in { rightUpper, rightLower, rightHand } do
			t.eq(p.LocalTransparencyModifier, 0, `{p.Name}: back`)
		end
		-- Over the shoulder the same: a cut arm hides whole.
		h.view = "third"
		rightLower.CFrame = CFrame.new(0.3, 4.7, -0.3)
		rightLower.Position = rightLower.CFrame.Position
		h.step()
		t.eq(rightHand.LocalTransparencyModifier, 1, "third person: the hand with its cut arm")
		h.done()
	end)

	t.test("first person: a tall body's chest close under the eyes is drawn unless the near plane cuts it", function()
		local h = harness()
		-- The chest's top 0.3 under the eyes (a tall body; within the old 0.6 of clearance).
		local chest = h.part("UpperTorso", CFrame.new(0, 3.9, 0.15), Vector3.new(2, 1.6, 1))
		local legs = h.part("LeftUpperLeg", CFrame.new(-0.5, 2.6, 0.15), Vector3.new(1, 1.2, 1))
		h.step()
		t.eq(chest.LocalTransparencyModifier, 0, "looking ahead: the chest drawn")
		-- Looking 60 degrees down the near plane reaches into it: hidden (the camera rig pushes the
		-- eyes forward looking down so this rarely happens; Player/CameraRules).
		h.camera.CFrame = CFrame.new(0, 5, 0) * CFrame.Angles(math.rad(-60), 0, 0)
		h.step()
		t.eq(chest.LocalTransparencyModifier, 1, "cut looking down: hidden")
		t.eq(legs.LocalTransparencyModifier, 0, "the legs drawn")
		h.done()
	end)

	t.test(
		"first person: a fire on the root part is not drawn from the eyes; a scope hides the arms in its frame",
		function()
			local h = harness()
			local root = h.part("HumanoidRootPart", CFrame.new(0, 2.5, 0), Vector3.new(2, 2, 1))
			local fire = fake("Fire", "Fire", { LocalTransparencyModifier = 0 })
			parent(fire, root)
			local hand = h.part("RightHand", CFrame.new(0.6, 4, -2), Vector3.new(1, 0.3, 1))
			local arm = h.part("RightLowerArm", CFrame.new(1, 3.8, -1.2), Vector3.new(1, 1.05, 1))
			h.step()
			t.eq(fire.LocalTransparencyModifier, 1, "the fire from the eyes: hidden")
			t.eq(root.LocalTransparencyModifier, 0, "the root itself is never touched")
			t.eq(hand.LocalTransparencyModifier, 0, "the hand drawn")
			h.view = "third"
			h.step()
			t.eq(fire.LocalTransparencyModifier, 0, "over the shoulder: the fire drawn")
			-- In the sights the gun's scope comes in at Camera + 7 (Player/HeldItems: setHeld, then
			-- settleArms): the arms hide in that frame, with the gun, not a frame later at + 2.
			h.view = "sights"
			h.step()
			t.eq(hand.LocalTransparencyModifier, 0, "iron sights: the arms on the gun")
			h.Body.setHeld({ kind = "firearm", scoped = true, sightsShare = 1, long = true, guard = false })
			h.Body.settleArms(h.camera)
			t.eq(hand.LocalTransparencyModifier, 1, "scoped at + 7: the hand hidden this frame")
			t.eq(arm.LocalTransparencyModifier, 1, "its arm too")
			h.Body.setHeld({ kind = "firearm", scoped = false, sightsShare = 1, long = true, guard = false })
			h.Body.settleArms(h.camera)
			t.eq(hand.LocalTransparencyModifier, 0, "out of the scope at + 7: back this frame")
			h.done()
		end
	)

	--[[ The glue's hands on a gun (Player/FirstPersonBody's reach rules, Player/HeldItems' hold) ]]

	-- Both arms on an R15 torso at `torsoFrame` (the spec's arm numbers; `inner` the shoulder's x in
	-- the upper arm: -0.25, or the arm's inner face -0.5).
	local function body(torsoFrame: any, inner: number): any
		local character = fake("Model", "Character")
		local torso = fake("MeshPart", "UpperTorso", { CFrame = torsoFrame, Size = Vector3.new(2, 1.6, 1) })
		parent(torso, character)
		for _, side in { { "Right", 1 }, { "Left", -1 } } do
			local prefix, s = side[1], side[2]
			local chain = { torso }
			local specs = {
				{
					"UpperArm",
					Vector3.new(1, 1.17, 1),
					"Shoulder",
					CFrame.new(s, 0.56, 0),
					CFrame.new(inner * s, 0.42, 0),
				},
				{ "LowerArm", Vector3.new(1, 1.05, 1), "Elbow", CFrame.new(0, -0.33, 0), CFrame.new(0, 0.2, 0) },
				{ "Hand", Vector3.new(1, 0.3, 1), "Wrist", CFrame.new(0, -0.5, 0), CFrame.new(0, 0.125, 0) },
			}
			for _, spec in specs do
				local part0 = chain[#chain]
				local part1 = fake("MeshPart", prefix .. spec[1], { Size = spec[2] })
				parent(part1, character)
				local jointName = prefix .. spec[3]
				parent(
					fake("Attachment", jointName .. "RigAttachment", { CFrame = spec[4], Position = spec[4].Position }),
					part0
				)
				parent(
					fake(
						"Motor6D",
						jointName,
						{ Part0 = part0, Part1 = part1, C0 = spec[4], C1 = spec[5], Transform = CFrame.identity }
					),
					part1
				)
				table.insert(chain, part1)
			end
			local grip = CFrame.new(0, -0.15, 0) * CFrame.Angles(-math.pi / 2, 0, 0)
			parent(
				fake("Attachment", prefix .. "GripAttachment", { CFrame = grip, Position = grip.Position }),
				chain[4]
			)
		end
		return character
	end

	-- An arm's parts' world frames from its joints (Part1 = Part0 * C0 * Transform * C1^-1).
	local function armFrames(character: any, prefix: string): { { frame: any, size: any } }
		local out = {}
		local frame = character:FindFirstChild("UpperTorso").CFrame
		for _, pair in { { "UpperArm", "Shoulder" }, { "LowerArm", "Elbow" }, { "Hand", "Wrist" } } do
			local part = character:FindFirstChild(prefix .. pair[1])
			local motor = part:FindFirstChild(prefix .. pair[2])
			frame = frame * motor.C0 * motor.Transform * motor.C1:Inverse()
			table.insert(out, { frame = frame, size = part.Size })
		end
		return out
	end

	-- Is `prefix`'s arm as the animation has it (every C0 its rig attachment's)?
	local function released(character: any, prefix: string): boolean
		local torso = character:FindFirstChild("UpperTorso")
		local upper = character:FindFirstChild(prefix .. "UpperArm")
		local lower = character:FindFirstChild(prefix .. "LowerArm")
		local hand = character:FindFirstChild(prefix .. "Hand")
		return upper:FindFirstChild(prefix .. "Shoulder").C0
				== torso:FindFirstChild(prefix .. "ShoulderRigAttachment").CFrame
			and lower:FindFirstChild(prefix .. "Elbow").C0 == upper:FindFirstChild(prefix .. "ElbowRigAttachment").CFrame
			and hand:FindFirstChild(prefix .. "Wrist").C0
				== lower:FindFirstChild(prefix .. "WristRigAttachment").CFrame
	end

	t.test(
		"first person: both hands on every long gun, lowered and in the sights; short and tall bodies; PC and phone",
		function()
			local Body = loadBody()
			local ItemModels = FakeClient.loader(shared, require, {}, {})("src/client/Rendering/ItemModels.luau")
			local Weapons = require(shared.Weapons)
			local BodyRules = require(client.Player.BodyRules)
			local Items = require(shared.Items)
			-- Player/HeldItems' frames: the gun ahead; lowered on the body (FirstPersonRules.lowered: a
			-- long gun across it), the sights near the eyes (sightsDepth); the hands under the gun
			-- (GRIP_TILT, FORE_TILT).
			local AHEAD = CFrame.fromMatrix(Vector3.zero, Vector3.new(0, 0, -1), Vector3.yAxis)
			local GUN_GRIP = CFrame.Angles(0, 0, Rules.GRIP_TILT) * CFrame.Angles(0, -math.pi / 2, 0)
			local cf, sf = math.cos(Rules.FORE_TILT), math.sin(Rules.FORE_TILT)
			local FORE_GRIP =
				CFrame.fromMatrix(Vector3.zero, Vector3.new(0, cf, -sf), Vector3.new(1, 0, 0), Vector3.new(0, -sf, -cf))
			local BODIES = {
				{ "blocky", 1.1, -0.25 },
				{ "blocky, inner shoulders", 1.1, -0.5 },
				{ "tall", 0.4, -0.25 },
				{ "tall, inner shoulders", 0.4, -0.5 },
			}
			local rates: { [string]: { number } } = {}
			local order: { string } = {}
			local function count(key: string, slot: number, hit: boolean)
				local row = rates[key]
				if row == nil then
					row = { 0, 0, 0, 0 }
					rates[key] = row
					table.insert(order, key)
				end
				row[slot] += 1
				if hit then
					row[slot + 1] += 1
				end
			end
			local misses: { string } = {}
			for _, nearZ in { 0.1, 0.5 } do
				for _, b in BODIES do
					for _, item in Weapons.FIREARMS do
						local spec = Weapons.firearm(item)
						local long = AimRules.longGun(spec)
						local size = ItemModels.firearmSize(item)
						for _, pose in { "lowered", "sights" } do
							local pitches = if pose == "sights"
								then { -60, -30, 0, 15, 30 }
								else { -60, -30, 0, 30, 60 }
							for _, deg in pitches do
								local key = `{nearZ} {b[1]} {pose} {deg}`
								local pitch = math.rad(deg)
								-- The body under the eyes as Player/MovementController puts it (the eyes
								-- FirstForward ahead of its middle, more looking down), the shoulders
								-- `drop` below them; in the sights the chest leans forward at the waist,
								-- 0.8 under its middle (Player/BodyTwist).
								local push = Config.Camera.FirstForward
									+ Config.Camera.FirstDownPush * math.max(0, -math.sin(pitch))
								local lean = if pose == "sights" then BodyRules.lean(1) else 0
								local waist = Vector3.new(0, -b[2] - 0.56 - 0.8, push)
								local torso = CFrame.new(waist) * CFrame.Angles(lean, 0, 0) * CFrame.new(0, 0.8, 0)
								local character = body(torso, b[3])
								local view = CFrame.Angles(pitch, 0, 0)
								local camera = cameraAt(view, nearZ)
								local nearDepth, tx, ty = Body.nearView(camera)
								local frame
								if pose == "sights" then
									frame = view * CFrame.new(0, 0, -Rules.sightsDepth(pitch, nearDepth)) * AHEAD
								else
									local turn, x, y, z, yaw, gunPitch = Rules.lowered(pitch, long)
									frame = CFrame.new(torso.Position)
										* CFrame.Angles(turn, 0, 0)
										* CFrame.new(x, y, z)
										* CFrame.Angles(0, yaw, 0)
										* CFrame.Angles(gunPitch, 0, 0)
										* AHEAD
								end
								-- Player/HeldItems.holdGun at rest.
								local pivot = ItemModels.firearmPivot(
									item,
									size,
									if pose == "sights" then "sights" else "hip",
									frame,
									""
								)
								local axes = ItemModels.firearmAxes(item, pivot)
								local right = CFrame.new(ItemModels.firearmPoint(item, "", size, pivot, "grip"))
									* axes
									* GUN_GRIP
								local fore = if Rules.leftHand("firearm", long, false, pose == "sights")
									then CFrame.new(ItemModels.firearmPoint(item, "", size, pivot, "fore"))
										* axes
										* FORE_GRIP
									else nil
								local sights = pose == "sights"
								local look = view.LookVector
								local toEye = -look
								local depth = (right.Position - view.Position):Dot(look)
								local limit = if sights then math.max(depth - nearDepth - Rules.GRIP_CLEAR, 0) else 0
								local want = Body.gripSlide(character, right, toEye, limit, Rules.COMFORT)
									or Body.gripSlide(character, right, toEye, limit, 1)
								if want and Body.armClips(character, true, right + toEye * want, camera, 0, sights) then
									want = nil
								end
								local shift = toEye * (want or 0)
								right += shift
								local left = nil
								local why = if want then "" else "right out of reach or in the way"
								if fore and want then
									fore += shift
									for _, from in Rules.FORE_TRIES do
										local at = Body.foreHold(character, fore, right.Position, from)
										if at == nil then
											why ..= " left out of reach"
											break
										elseif not Body.armClips(character, false, at, camera, 0, sights) then
											left = at
											break
										end
										why ..= if Body.armClips(character, false, at, camera, 0, false)
											then " left cut"
											else " left in front of the sights"
									end
								end
								Body.poseArmsWeighted(
									character,
									right,
									left,
									if want then 1 else 0,
									if left then 1 else 0,
									view.Position
								)
								-- The sight picture: on the view's axis, the gun moved along it only.
								if sights then
									local anchor = frame.Position + shift - view.Position
									t.near(
										(anchor - look * anchor:Dot(look)).Magnitude,
										0,
										1e-5,
										`{key}: the sight line on the axis`
									)
								end
								for _, side in { { "Right", right, want ~= nil }, { "Left", left, left ~= nil } } do
									local prefix, target, holds = side[1], side[2], side[3]
									if holds then
										local frames = armFrames(character, prefix)
										local got = frames[3].frame * Vector3.new(0, -0.15, 0)
										t.near(
											(got - target.Position).Magnitude,
											0,
											2e-3,
											`{key} {prefix}: the hand on its grip`
										)
										for _, entry in frames do
											t.eq(
												Body.clipped(view, entry.frame, entry.size, nearDepth, tx, ty),
												false,
												`{key} {prefix}: no part of the holding arm cut by the near plane`
											)
											if sights then
												local at = entry.frame:PointToObjectSpace(view.Position)
												local along = entry.frame:VectorToObjectSpace(look)
												local half = entry.size / 2
												t.eq(
													Rules.crosses(
														at.X,
														at.Y,
														at.Z,
														along.X,
														along.Y,
														along.Z,
														half.X,
														half.Y,
														half.Z,
														nearDepth,
														Rules.SIGHT_REACH
													),
													false,
													`{key} {prefix}: no part of the holding arm in front of the sights`
												)
											end
										end
									else
										t.ok(
											released(character, prefix),
											`{key} {prefix}: not holding, the animation's arm`
										)
									end
								end
								if left and fore then
									-- (Between the right hand and the fore end, or a forward try past it.)
									local ahead = (left.Position - right.Position).Magnitude
									local span = (fore.Position - right.Position).Magnitude
									local forward = -math.min(table.unpack(Rules.FORE_TRIES))
									t.ok(
										ahead >= Rules.FORE_MIN - 1e-6 and ahead <= span + forward + 1e-6,
										`{key}: the left hand along the fore end`
									)
								end
								-- The rates (a long gun's both hands; a handgun's right, and its left in the
								-- sights).
								local range = if sights then deg <= 30 else true
								if range then
									local row = `near {nearZ}, {b[1]}, {pose}`
									if not long then
										count(row .. ", handguns", 1, want ~= nil)
										count(row .. ", handguns", 3, left ~= nil)
										if nearZ == 0.1 and not want then
											table.insert(misses, `{key} {Items.get(item).name}:{why}`)
										end
									end
									if long then
										count(row, 1, want ~= nil)
										count(row, 3, left ~= nil)
										if nearZ == 0.1 and not (want and left) then
											table.insert(misses, `{key} {Items.get(item).name}:{why}`)
										end
									end
								end
							end
						end
					end
				end
			end
			print("         hands on guns (right, left: held of cases; lowered -60..60, sights -60..30):")
			for _, row in order do
				local r = rates[row]
				print(string.format("           %-46s right %3d/%3d  left %3d/%3d", row, r[2], r[1], r[4], r[3]))
			end
			-- Where both hands hold every long gun (and the right every handgun): PC's near plane, every
			-- body, lowered at every pitch and in the sights from 60 degrees down to 30 up.
			t.eq(table.concat(misses, "; "), "", "both hands on every long gun on PC")
		end
	)

	t.test("first person: the elbow goes away from the camera", function()
		local Body = loadBody()
		local function elbowFrom(eye: any?): number
			local character = body(CFrame.new(0, -1.66, 0.15), -0.25)
			Body.poseArms(character, CFrame.new(0.3, -0.5, -1.1) * CFrame.Angles(0.2, 0.3, 0), nil, eye)
			local elbow = armFrames(character, "Right")[2].frame * Vector3.new(0, 0.2, 0)
			return elbow.Magnitude
		end
		t.ok(elbowFrom(Vector3.zero) > elbowFrom(nil) + 0.01, "further from the eyes than down and out alone")
	end)

	t.test("first person: the muzzle of the gun at the eyes is where it is drawn this frame", function()
		-- Interaction/Firearms fires at Camera + 6, before Player/HeldItems places the gun at + 7:
		-- the gun is kept in the camera's space and placed with this frame's camera.
		local held = fs.readFile("src/client/Player/HeldItems.luau")
		t.ok(
			string.find(held, "current.relative = view.CFrame:ToObjectSpace(where)", 1, true) ~= nil,
			"kept in the camera's space"
		)
		t.ok(
			string.find(held, "if relative then workspace.CurrentCamera.CFrame * relative else current.pivot", 1, true)
				~= nil,
			"placed with the camera of the frame that asks"
		)
	end)
end
