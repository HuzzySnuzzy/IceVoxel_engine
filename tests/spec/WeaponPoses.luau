--[[
	Third person's gun (Player/WeaponPoses) on a fake R15 body under Lune (a root, the pelvis, the
	chest on its waist, both arms, Roblox's rig attachments): the gun turns with the chest when
	Player/BodyTwist turns the waist (the idle lead, freelook beyond the neck), so it stays in the
	hands the shoulders were posed for (`apply` turns them in the chest's axes); the joints' own C0
	come from their rig attachments, so a rescaled body keeps its proportions when the pose is put
	back and a rebuilt body (new parts, new joints) is posed again.
]]

local roblox = require("@lune/roblox")
local FakeClient = require("../lib/FakeClient")

local CFrame, Vector3 = roblox.CFrame, roblox.Vector3

return function(t, shared, require, _server, _client)
	local function load(): any
		return FakeClient.loader(shared, require, {}, {})("src/client/Player/WeaponPoses.luau")
	end

	local function fake(class: string, name: string, props: { [string]: any }?): any
		local object: any = props or {}
		object.ClassName = class
		object.Name = name
		object.__children = {}
		local bases: { [string]: { string } } = {
			Part = { "Part", "BasePart", "Instance" },
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
		return object
	end
	local function parent(child: any, to: any)
		if child.Parent then
			child.Parent.__children[child.Name] = nil
		end
		child.Parent = to
		if to then
			to.__children[child.Name] = child
		end
	end
	-- A joint `name` from part0 to part1 at the rig attachments' frames c0 (in part0) and c1.
	local function joint(name: string, part0: any, part1: any, c0: any, c1: any): any
		parent(fake("Attachment", name .. "RigAttachment", { CFrame = c0, Position = c0.Position }), part0)
		local m = fake("Motor6D", name, { Part0 = part0, Part1 = part1, C0 = c0, C1 = c1, Transform = CFrame.identity })
		parent(m, part1)
		return m
	end

	-- An R15 body: the root at (0, 3, 0) facing -Z, the chest turned `waistYaw` on the waist.
	local function build(waistYaw: number): any
		local character = fake("Model", "Character")
		local root = fake("Part", "HumanoidRootPart", { CFrame = CFrame.new(0, 3, 0), Size = Vector3.new(2, 2, 1) })
		parent(root, character)
		local lower = fake("Part", "LowerTorso", { Size = Vector3.new(2, 0.4, 1) })
		parent(lower, character)
		joint("Root", root, lower, CFrame.new(0, -1, 0), CFrame.new(0, -0.2, 0))
		local upper = fake("Part", "UpperTorso", { Size = Vector3.new(2, 1.6, 1) })
		parent(upper, character)
		local waist = joint("Waist", lower, upper, CFrame.new(0, 0.2, 0), CFrame.new(0, -0.8, 0))
		waist.C0 = CFrame.new(0, 0.2, 0) * CFrame.Angles(0, waistYaw, 0)
		local head = fake("Part", "Head", { Size = Vector3.new(1.2, 1.2, 1.2) })
		parent(head, character)
		joint("Neck", upper, head, CFrame.new(0, 0.8, 0), CFrame.new(0, -0.5, 0))
		for _, side in { { "Right", 1 }, { "Left", -1 } } do
			local prefix, s = side[1], side[2]
			local upperArm = fake("Part", prefix .. "UpperArm", { Size = Vector3.new(1, 1.17, 1) })
			local lowerArm = fake("Part", prefix .. "LowerArm", { Size = Vector3.new(1, 1.05, 1) })
			local hand = fake("Part", prefix .. "Hand", { Size = Vector3.new(1, 0.3, 1) })
			parent(upperArm, character)
			parent(lowerArm, character)
			parent(hand, character)
			joint(prefix .. "Shoulder", upper, upperArm, CFrame.new(s, 0.56, 0), CFrame.new(-0.5 * s, 0.42, 0))
			joint(prefix .. "Elbow", upperArm, lowerArm, CFrame.new(0, -0.33, 0), CFrame.new(0, 0.2, 0))
			joint(prefix .. "Wrist", lowerArm, hand, CFrame.new(0, -0.5, 0), CFrame.new(0, 0.125, 0))
			parent(fake("Attachment", prefix .. "GripAttachment", { Position = Vector3.new(0, -0.15, 0) }), hand)
		end
		return character
	end

	-- Every part's frame from the joints (Part1 = Part0 * C0 * Transform * C1^-1), the grips' too.
	local function place(character: any)
		local chain = {
			{ "LowerTorso", "Root" },
			{ "UpperTorso", "Waist" },
			{ "Head", "Neck" },
			{ "RightUpperArm", "RightShoulder" },
			{ "RightLowerArm", "RightElbow" },
			{ "RightHand", "RightWrist" },
			{ "LeftUpperArm", "LeftShoulder" },
			{ "LeftLowerArm", "LeftElbow" },
			{ "LeftHand", "LeftWrist" },
		}
		for _, link in chain do
			local part = character:FindFirstChild(link[1])
			local m = part:FindFirstChild(link[2])
			part.CFrame = m.Part0.CFrame * m.C0 * m.Transform * m.C1:Inverse()
		end
		for _, prefix in { "Right", "Left" } do
			local hand = character:FindFirstChild(prefix .. "Hand")
			local grip = hand:FindFirstChild(prefix .. "GripAttachment")
			grip.WorldPosition = hand.CFrame * grip.Position
		end
	end

	t.test("weapon poses: the gun turns with the chest when the waist turns (in the hands still)", function()
		local WeaponPoses = load()
		for _, posture in { "lowered", "raised" } do
			for _, long in { true, false } do
				-- The gun's frame and the left hand in the chest's space, waist straight.
				local function inChest(waistYaw: number): (any, any)
					local character = build(waistYaw)
					place(character)
					WeaponPoses.apply(character, posture, 0.2, long)
					place(character)
					local frame = WeaponPoses.gunFrame(character, posture, 0.2, long)
					local chest = character:FindFirstChild("UpperTorso").CFrame
					local left = character:FindFirstChild("LeftHand"):FindFirstChild("LeftGripAttachment").WorldPosition
					return chest:ToObjectSpace(frame), chest:PointToObjectSpace(left)
				end
				local straight, leftStraight = inChest(0)
				for _, deg in { 15, 30, 45, -30 } do
					local turned, leftTurned = inChest(math.rad(deg))
					local what = `{posture} {if long then "long gun" else "handgun"}, waist {deg}`
					t.near((turned.Position - straight.Position).Magnitude, 0, 1e-6, `{what}: at the same grip`)
					t.near(
						(turned.RightVector - straight.RightVector).Magnitude,
						0,
						1e-6,
						`{what}: the barrel turned with the chest`
					)
					t.near((turned.UpVector - straight.UpVector).Magnitude, 0, 1e-6, `{what}: its top too`)
					t.near((leftTurned - leftStraight).Magnitude, 0, 1e-6, `{what}: the left hand where it was on it`)
				end
			end
		end
		-- A body without a chest (R6's Torso faces with the root): the root's facing, as before.
		local r6 = fake("Model", "R6")
		parent(fake("Part", "HumanoidRootPart", { CFrame = CFrame.Angles(0, 0.5, 0), Size = Vector3.new(2, 2, 1) }), r6)
		local hand = fake("Part", "Right Arm", { CFrame = CFrame.new(1.5, 0, 0), Size = Vector3.new(1, 2, 1) })
		parent(hand, r6)
		local frame = WeaponPoses.gunFrame(r6, "raised", 0, true)
		local look = CFrame.Angles(0, 0.5, 0).LookVector
		t.near((frame.RightVector - look).Magnitude, 0, 1e-6, "R6: along the root's facing")
	end)

	t.test("weapon poses: a rescaled body's joints come from their rig attachments; a rebuilt one is posed", function()
		local WeaponPoses = load()
		local character = build(0)
		local upper = character:FindFirstChild("UpperTorso")
		local shoulder = character:FindFirstChild("RightUpperArm"):FindFirstChild("RightShoulder")
		local neck = character:FindFirstChild("Head"):FindFirstChild("Neck")
		WeaponPoses.apply(character, "raised", 0.3, true)
		WeaponPoses.applyLook(character, 0.4, 0.1)
		-- Rescaled (ApplyDescriptionResetAsync, the body's scale): the rig attachments move and
		-- Roblox puts each joint's C0 on them.
		local attachment = upper:FindFirstChild("RightShoulderRigAttachment")
		local scaled = CFrame.new(1.2, 0.68, 0)
		attachment.CFrame, attachment.Position = scaled, scaled.Position
		shoulder.C0 = scaled
		local neckAttachment = upper:FindFirstChild("NeckRigAttachment")
		local neckScaled = CFrame.new(0, 0.96, 0)
		neckAttachment.CFrame, neckAttachment.Position = neckScaled, neckScaled.Position
		neck.C0 = neckScaled
		WeaponPoses.apply(character, "raised", 0.3, true)
		t.near((shoulder.C0.Position - scaled.Position).Magnitude, 0, 1e-9, "posed about the rescaled joint")
		t.near((neck.C0.Position - neckScaled.Position).Magnitude, 0, 1e-9, "the head too")
		WeaponPoses.release(character)
		WeaponPoses.applyLook(character, 0, 0)
		t.eq(shoulder.C0, scaled, "put back as rescaled, not as first found")
		t.eq(neck.C0, neckScaled, "the neck as rescaled")
		-- Rebuilt (its parts replaced, new joints): the new arm is posed, not the old one.
		WeaponPoses.apply(character, "raised", 0.3, true)
		local old = character:FindFirstChild("RightUpperArm")
		parent(old, nil)
		local arm = fake("Part", "RightUpperArm", { Size = Vector3.new(1, 1.17, 1) })
		parent(arm, character)
		upper.__children["RightShoulderRigAttachment"] = nil
		local fresh = joint("RightShoulder", upper, arm, CFrame.new(1, 0.56, 0), CFrame.new(-0.5, 0.42, 0))
		WeaponPoses.apply(character, "raised", 0.3, true)
		t.ok(fresh.C0 ~= CFrame.new(1, 0.56, 0), "the new shoulder posed")
		t.near((fresh.C0.Position - Vector3.new(1, 0.56, 0)).Magnitude, 0, 1e-9, "about its own joint")
		WeaponPoses.release(character)
		t.eq(fresh.C0, CFrame.new(1, 0.56, 0), "and put back")
	end)
end
