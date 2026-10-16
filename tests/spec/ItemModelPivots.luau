--[[
	Rendering/ItemModels: every model's pivot is the origin of its own space, the frame every pose
	in ItemModels (handPivot, holdPivot, firearmPivot) and its callers (Player/HeldItems,
	Player/EquipmentLooks, Ui/PlayerPreview) is built on. Roblox ignores a Model's WorldPivot when
	it has a PrimaryPart (Model.WorldPivot: "the pivot of the Model is equal to the pivot of that
	primary part instead"), and an item's first box, its PrimaryPart, sits half a turn round (its
	view space) and off the origin, so a model posed with PivotTo turned half round: every held
	gun pointed its muzzle back at the player. Checked here with Roblox's rule (the primary part's
	CFrame times its PivotOffset), and with PivotTo's move: a gun posed by firearmPivot along a
	frame points its muzzle along that frame's barrel.
]]

local roblox = require("@lune/roblox")
local FakeClient = require("../lib/FakeClient")

local CFrame, Vector3 = roblox.CFrame, roblox.Vector3

return function(t, shared, require, _server, _client)
	local ItemModels = FakeClient.loader(shared, require, {}, {})("src/client/Rendering/ItemModels.luau")
	local Items = require(shared.Items)
	local Weapons = require(shared.Weapons)

	local function props(object: any): any
		return FakeClient.props(object)
	end

	-- Roblox's pivot of a Model (Model:GetPivot): its PrimaryPart's (CFrame * PivotOffset), else
	-- its WorldPivot.
	local function pivotOf(model: any): CFrame
		local p = props(model)
		local primary = p.PrimaryPart
		if primary then
			local pp = props(primary)
			return pp.CFrame * (pp.PivotOffset or CFrame.identity)
		end
		return p.WorldPivot or CFrame.identity
	end

	local function nearIdentity(frame: CFrame): boolean
		local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = frame:GetComponents()
		return frame.Position.Magnitude < 1e-4
			and math.abs(r00 - 1) < 1e-4
			and math.abs(r11 - 1) < 1e-4
			and math.abs(r22 - 1) < 1e-4
			and math.abs(r01) + math.abs(r02) + math.abs(r10) + math.abs(r12) + math.abs(r20) + math.abs(r21) < 1e-4
	end

	t.test("item models: the pivot is the model space's origin, with a PrimaryPart too", function()
		local checked, boxed = 0, 0
		for id = 1, 20000 do
			local def = Items.get(id)
			if def and def.model then
				local model = if Weapons.firearm(id)
					then ItemModels.buildFirearm(id, "", ItemModels.firearmSize(id))
					else ItemModels.build(id, 1)
				local pivot = pivotOf(model)
				t.ok(nearIdentity(pivot), `{def.name}'s pivot is the origin (got {pivot})`)
				checked += 1
				if props(model).PrimaryPart then
					boxed += 1
				end
			end
		end
		t.ok(checked > 20, `item models checked: {checked}`)
		t.ok(boxed > 20, `with a PrimaryPart: {boxed}`)
	end)

	t.test("item models: a gun posed by firearmPivot points its muzzle along the frame's barrel", function()
		local barrel = Vector3.new(0, 0, -1)
		local frame = CFrame.fromMatrix(Vector3.new(4, 3, -2), barrel, Vector3.yAxis)
		for _, item in Weapons.FIREARMS do
			local size = ItemModels.firearmSize(item)
			local model = ItemModels.buildFirearm(item, "", size)
			local where = ItemModels.firearmPivot(item, size, "hand", frame)
			-- PivotTo(where): every part moved by where * pivot⁻¹.
			local move = where * pivotOf(model):Inverse()
			local grip = ItemModels.firearmPoint(item, "", size, where, "grip")
			local muzzle = ItemModels.firearmPoint(item, "", size, where, "muzzle")
			t.ok((muzzle - grip):Dot(barrel) > 0, `{Items.get(item).name}: the muzzle point is ahead`)
			-- Every drawn box lands where the pose puts it (`where` is the model space's place), and
			-- the box furthest along the barrel is ahead of the grip (turned half round, it's behind).
			local name = Items.get(item).name
			local ahead = -math.huge
			for _, part in model:GetDescendants() do
				local p = props(part)
				if p.ClassName == "Part" and p.CFrame then
					local posed = move * p.CFrame
					local expected = where * p.CFrame
					t.ok(
						(posed.Position - expected.Position).Magnitude < 1e-3
							and posed.LookVector:Dot(expected.LookVector) > 0.9999
							and posed.UpVector:Dot(expected.UpVector) > 0.9999,
						`{name}: {p.Name} is drawn where the pose puts it`
					)
					ahead = math.max(ahead, (posed.Position - grip):Dot(barrel))
				end
			end
			local reach = (muzzle - grip):Dot(barrel)
			t.ok(ahead > 0.3 * reach, `{name}: its barrel is drawn ahead of the grip ({ahead} of {reach})`)
		end
	end)
end
