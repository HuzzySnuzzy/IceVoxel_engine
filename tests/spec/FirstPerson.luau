--[[
	The local body seen in true first person, through its pure rules (Player/FirstPersonRules): the
	roles of what a character is drawn with (the head and a face decal, a hat by its weld, hair by
	its attachment, a Face type, layered hair and clothing by type or attachment, back and arm
	accessories, the arms), the full hiding matrix (views, the First-Person Body setting, a scope,
	near the camera) and when the near test can be skipped, the near box's edges, the two-bone arm
	(its lengths kept, the elbow on the pole's side, straight towards a target out of reach, no NaN
	at the shoulder or with the pole on the line), which holds take the left hand, the hand poses
	(at rest, at the bottom of the swing, the melee guard's shift, and off the crosshair at 70
	degrees), the wall's pull and lift; and the glue's arm (Player/FirstPersonBody.poseArms on a
	fake R15 arm under Lune: the grip lands on its target whatever the animation does, the hand
	turned with it, a target out of reach reported, the joints put back, R6 left alone).
]]

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
		t.eq(Rules.NEAR_CLEAR, Config.Camera.NearClear)
	end)

	t.test("first person: the near box's edges", function()
		local nearBox = Rules.nearBox
		t.eq(nearBox(0, 0, 0, 0.5, 0.5, 0.5, 0.6), true, "inside")
		t.eq(nearBox(1, 0, 0, 0.5, 0.5, 0.5, 0.5), true, "on the margin")
		t.eq(nearBox(1.0001, 0, 0, 0.5, 0.5, 0.5, 0.5), false, "just past it")
		t.eq(nearBox(0, -1, 0, 0.5, 0.5, 0.5, 0.5), true, "below, on the margin")
		t.eq(nearBox(1.09, 0, 0, 0.5, 0.5, 0.5, 0.6), true, "within NearClear")
		t.eq(nearBox(0, 0, 1.2, 0.5, 0.5, 0.5, 0.6), false, "behind, past it")
		-- A corner: the distance to the corner, not to each face.
		local d = 0.6 / math.sqrt(3)
		t.eq(nearBox(0.5 + d * 0.99, 0.5 + d * 0.99, 0.5 + d * 0.99, 0.5, 0.5, 0.5, 0.6), true, "near a corner")
		t.eq(nearBox(0.5 + d * 1.01, 0.5 + d * 1.01, 0.5 + d * 1.01, 0.5, 0.5, 0.5, 0.6), false, "past a corner")
		t.eq(nearBox(-0.9, 0.2, -0.3, 0.5, 0.5, 0.5, 0.6), true, "mirrored")
		t.eq(nearBox(0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0), true, "a zero margin: the surface counts")
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
		t.eq(Rules.leftHand("firearm", false, false), false, "a handgun: one hand")
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
end
