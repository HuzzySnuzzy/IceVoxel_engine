--[[
	A character's accessories on Roblox's side (server Players/CharacterLooks): `fields` gives
	HumanoidDescription:SetAccessories(list, true) exactly what it takes, against a fake
	description that files entries as Roblox's documentation says (an entry without Order goes
	under the rigid property of its AccessoryType, HatAccessory..., one with Order into
	AccessoryBlob as layered clothing; GetAccessories(true) gives rigid ones back without Order and
	Puffiness): a rigid hat stays a hat, layered clothing stays layered, the user's own avatar
	read back and set again lands where it was, a record saved before this rule (rigid accessories
	stored with order 0) is set right at spawn, "not worn" stays off, and one accessory Roblox
	refuses never takes the others off (`setAccessories`).

	Reading the user's own avatar: a failed read is tried again with a backoff (`retry`) and its
	plain look stands in only briefly, never for a character being made (`serves`), and a create
	whose editor was opened on a failed read wears the avatar's things it didn't show, keeping
	what the edit switched off (Appearance.sanitize).
]]

return function(t, shared, require, server)
	local Appearance = require(shared.Characters.Appearance)
	local Config = require(shared.Config)
	local CharacterLooks = require(server.Players.CharacterLooks)
	local CharacterMigration = require(server.Save.CharacterMigration)

	local A = Appearance.ACCESSORY
	local HAT, HAIR, FACE, BACK = 1, 2, 3, 7
	local SHIRT, JACKET = 10, 12

	local function asset(kind: number, id: number, worn: boolean, layered: boolean, order: number?, puffiness: number?)
		return {
			kind = kind,
			id = id,
			worn = worn,
			layered = layered,
			order = order or 0,
			puffiness = puffiness or 1,
		}
	end

	--[[
		A HumanoidDescription's accessories as its documentation describes them (see the header):
		`refuse[assetId]` is an error SetAccessories raises for that entry, as Roblox raises one for
		an entry it does not take; a refused list leaves no accessory set (the harshest case).
	]]
	local function fakeDescription(refuse: { [number]: string }?)
		local self: any = { rigid = {}, blob = {}, calls = 0 }
		function self.SetAccessories(_: any, list: { any }, includeRigid: boolean)
			self.calls += 1
			assert(includeRigid == true, "rigid accessories included")
			local rigid: { [string]: { number } } = {}
			local blob: { any } = {}
			self.rigid, self.blob = rigid, blob
			for _, entry in list do
				local why = refuse and refuse[entry.AssetId]
				if why then
					self.rigid, self.blob = {}, {}
					error(why, 0)
				end
				if entry.Order == nil then
					local property = CharacterLooks.RIGID_PROPERTY[entry.AccessoryType]
					if property == nil then
						self.rigid, self.blob = {}, {}
						error(`no rigid accessory property for AccessoryType {entry.AccessoryType}`, 0)
					end
					rigid[property] = rigid[property] or {}
					table.insert(rigid[property], entry.AssetId)
				else
					table.insert(blob, table.clone(entry))
				end
			end
		end
		function self.GetAccessories(_: any, includeRigid: boolean): { any }
			local list = {}
			if includeRigid then
				for accessoryType, property in CharacterLooks.RIGID_PROPERTY do
					for _, id in self.rigid[property] or {} do
						table.insert(list, { AssetId = id, AccessoryType = accessoryType, IsLayered = false })
					end
				end
			end
			for _, entry in self.blob do
				table.insert(list, table.clone(entry))
			end
			return list
		end
		return self
	end

	local function setOn(description: any, accessories: { any })
		return CharacterLooks.setAccessories(accessories, function(list: { any }): (boolean, unknown)
			return pcall(description.SetAccessories, description, table.clone(list), true)
		end)
	end

	-- A user's avatar: a hat, hair, a back accessory (rigid), a layered shirt and jacket.
	local function ownAvatar(): any
		local description = fakeDescription()
		description.rigid = {
			HatAccessory = { 111 },
			HairAccessory = { 222 },
			BackAccessory = { 777 },
		}
		description.blob = {
			{ AssetId = 1010, AccessoryType = SHIRT, IsLayered = true, Order = 1, Puffiness = 0.5 },
			{ AssetId = 1212, AccessoryType = JACKET, IsLayered = true, Order = 2, Puffiness = 1 },
		}
		return description
	end

	t.test("character looks: a rigid accessory is set without Order, layered clothing with it", function()
		local look = Appearance.default()
		look.assets = {
			asset(A + HAT, 123456789012, true, false),
			asset(A + JACKET, 77, true, true, 3, 0.5),
		}
		local fields = CharacterLooks.fields(look)
		t.eq(#fields.accessories, 2)
		local hat, jacket = fields.accessories[1], fields.accessories[2]
		t.eq(hat.AssetId, 123456789012)
		t.eq(hat.AccessoryType, HAT)
		t.eq(hat.IsLayered, false)
		t.eq(hat.Order, nil, "a rigid accessory names no Order (SetAccessories would take it for layered clothing)")
		t.eq(hat.Puffiness, nil, "nor Puffiness")
		t.eq(jacket.IsLayered, true)
		t.eq(jacket.Order, 3)
		t.eq(jacket.Puffiness, 0.5)
		-- On a description: the hat under HatAccessory, the jacket in AccessoryBlob.
		local description = fakeDescription()
		t.eq(#setOn(description, fields.accessories), 0, "nothing refused")
		t.eq(description.calls, 1, "one SetAccessories when Roblox takes the list")
		t.eq(description.rigid.HatAccessory and description.rigid.HatAccessory[1], 123456789012, "the hat is a hat")
		t.eq(#description.blob, 1, "only the jacket is layered clothing")
		t.eq(description.blob[1].AssetId, 77)
		t.eq(description.blob[1].Order, 3)
		-- Puffiness stays within WrapLayer's range.
		look.assets[2].puffiness = 2.5
		t.eq(CharacterLooks.fields(look).accessories[2].Puffiness, 1)
	end)

	t.test("character looks: the user's own avatar read back and set again lands where it was", function()
		local own = ownAvatar()
		local read = CharacterLooks.fromFields({
			colors = {},
			scales = {},
			properties = {},
			accessories = own:GetAccessories(true),
		})
		t.eq(#read.assets, 5, "every accessory read")
		for _, item in read.assets do
			t.eq(item.worn, true, "a user's own avatar: everything worn")
		end
		-- Kept and sent as a character's look is (bytes, as the record and the editor carry it).
		local stored = Appearance.decode(Appearance.encode(read)) :: Appearance.Appearance
		local description = fakeDescription()
		t.eq(#setOn(description, CharacterLooks.fields(stored).accessories), 0)
		t.eq(description.rigid.HatAccessory and description.rigid.HatAccessory[1], 111)
		t.eq(description.rigid.HairAccessory and description.rigid.HairAccessory[1], 222)
		t.eq(description.rigid.BackAccessory and description.rigid.BackAccessory[1], 777)
		t.eq(#description.blob, 2, "the layered shirt and jacket, nothing else")
		local orders = {}
		for _, entry in description.blob do
			orders[entry.AssetId] = entry.Order
			t.eq(entry.IsLayered, true)
		end
		t.eq(orders[1010], 1)
		t.eq(orders[1212], 2)
	end)

	t.test("character looks: a record saved before keeps its things and its choices", function()
		-- What the first characters stored: rigid accessories with order 0 and puffiness 1, one
		-- switched off in the editor.
		local look = Appearance.default()
		look.assets = {
			asset(A + HAT, 5001, true, false, 0, 1),
			asset(A + HAIR, 5002, false, false, 0, 1),
			asset(A + FACE, 5003, true, false, 0, 1),
			asset(A + SHIRT, 5004, true, true, 4, 1),
			asset(Appearance.KIND.Shirt, 5005, true, false, 0, 1),
		}
		local saved = Appearance.decode(Appearance.encode(look)) :: Appearance.Appearance
		local fields = CharacterLooks.fields(saved)
		t.eq(#fields.accessories, 3, "the worn accessories, not the hair switched off")
		local description = fakeDescription()
		t.eq(#setOn(description, fields.accessories), 0)
		t.eq(description.rigid.HatAccessory and description.rigid.HatAccessory[1], 5001)
		t.eq(description.rigid.FaceAccessory and description.rigid.FaceAccessory[1], 5003)
		t.eq(description.rigid.HairAccessory, nil, "a user's own 'not worn' stays off")
		t.eq(#description.blob, 1)
		t.eq(description.blob[1].AssetId, 5004)
		t.eq(fields.properties.Shirt, 5005, "classic clothing is a property, not an accessory")
	end)

	t.test("character looks: what SetAccessories can't take is left out and named", function()
		local look = Appearance.default()
		look.assets = {
			asset(A + HAT, 1, true, false),
			-- (A jacket only exists layered: no rigid property holds it.)
			asset(A + JACKET, 2, true, false),
			asset(A + BACK, 1, true, false),
			asset(A + HAIR, 3, true, true, 2),
		}
		local fields = CharacterLooks.fields(look)
		t.eq(#fields.accessories, 2, "the hat and the layered hair")
		t.eq(fields.accessories[1].AssetId, 1)
		t.eq(fields.accessories[2].AssetId, 3)
		local skipped = fields.skipped :: { CharacterLooks.Skipped }
		t.eq(#skipped, 2)
		t.eq(skipped[1].AssetId, 2)
		t.ok(string.find(skipped[1].why, "rigid", 1, true) ~= nil, skipped[1].why)
		t.eq(skipped[2].AssetId, 1)
		t.eq(skipped[2].why, "worn twice")
		local description = fakeDescription()
		t.eq(#setOn(description, fields.accessories), 0, "the rest goes on")
	end)

	t.test("character looks: one accessory Roblox refuses never takes the others off", function()
		local look = Appearance.default()
		look.assets = {
			asset(A + HAT, 11, true, false),
			asset(A + FACE, 13, true, false),
			asset(A + SHIRT, 14, true, true, 1),
			asset(A + BACK, 12, true, false),
		}
		local fields = CharacterLooks.fields(look)
		-- Refused in the middle: the others stay on.
		local description = fakeDescription({ [13] = "asset 13 is not an accessory" })
		local refused = setOn(description, fields.accessories)
		t.eq(#refused, 1)
		t.eq(refused[1].entry.AssetId, 13)
		t.eq(refused[1].why, "asset 13 is not an accessory", "Roblox's own error, for the warning")
		t.eq(description.rigid.HatAccessory and description.rigid.HatAccessory[1], 11)
		t.eq(description.rigid.BackAccessory and description.rigid.BackAccessory[1], 12)
		t.eq(description.rigid.FaceAccessory, nil)
		t.eq(#description.blob, 1)
		-- Refused last: the description ends holding the ones kept, not a refused try.
		local last = fakeDescription({ [12] = "no" })
		local lastRefused = setOn(last, fields.accessories)
		t.eq(#lastRefused, 1)
		t.eq(lastRefused[1].entry.AssetId, 12)
		t.eq(last.rigid.HatAccessory and last.rigid.HatAccessory[1], 11)
		t.eq(last.rigid.FaceAccessory and last.rigid.FaceAccessory[1], 13)
		t.eq(#last.blob, 1)
		-- Everything refused: none, and each named.
		local none = fakeDescription({ [11] = "a", [12] = "b", [13] = "c", [14] = "d" })
		t.eq(#setOn(none, fields.accessories), 4)
		t.eq(next(none.rigid), nil)
		t.eq(#none.blob, 0)
		-- What the first characters sent (Order on rigid ones) files a hat as layered clothing.
		local old = fakeDescription()
		t.eq(#setOn(old, { { AssetId = 11, AccessoryType = HAT, IsLayered = false, Order = 0, Puffiness = 1 } }), 0)
		t.eq(old.rigid.HatAccessory, nil, "the old shape: no hat")
	end)

	--[[ Reading the avatar ]]

	-- A user's avatar as read: two accessories, two faces (the first worn), a shirt, a head.
	local function readAvatar(): Appearance.Appearance
		local look = Appearance.default()
		look.assets = {
			asset(A + HAT, 1, true, false),
			asset(A + HAIR, 2, true, false),
			asset(Appearance.KIND.Face, 3, true, false),
			asset(Appearance.KIND.Face, 4, true, false),
			asset(Appearance.KIND.Shirt, 5, true, false),
			asset(Appearance.KIND.Head, 6, true, false),
		}
		return look
	end

	local function wornIds(look: Appearance.Appearance): { [number]: boolean }
		local worn = {}
		for _, item in look.assets do
			worn[item.id] = item.worn
		end
		return worn
	end

	t.test("character looks: a create after the editor's failed read wears the avatar's things", function()
		-- The editor opened on a failed read: the plain look, no assets; the player picked colours.
		local edited = Appearance.default()
		edited.colors = { 0x101010, 0x202020, 0x303030, 0x404040, 0x505050, 0x606060 }
		-- The create reads the real avatar.
		local snapshot = readAvatar()
		local kept = Appearance.sanitize(edited, snapshot)
		local worn = wornIds(kept)
		t.eq(worn[1], true, "the hat, never shown, is worn as the user wears it")
		t.eq(worn[2], true, "the hair too")
		t.eq(worn[3], true, "the first face")
		t.eq(worn[4], false, "one face at a time")
		t.eq(worn[5], true, "the shirt")
		t.eq(worn[6], true, "the head")
		t.eq(kept.colors[1], 0x101010, "the edit's colours")
		-- The same as the legacy character's rule (CharacterMigration.allWorn).
		local all = wornIds(CharacterMigration.allWorn(snapshot))
		for id, isWorn in worn do
			t.eq(isWorn, all[id], `asset {id} as allWorn wears it`)
		end
	end)

	t.test("character looks: what the edit names stays as the player chose it", function()
		local snapshot = readAvatar()
		-- The edit saw the hat (switched off) and the second face (switched on); not the rest.
		local edited = Appearance.default()
		edited.assets = {
			asset(A + HAT, 1, false, false),
			asset(Appearance.KIND.Face, 4, true, false),
			asset(Appearance.KIND.Shirt, 5, false, false),
		}
		local worn = wornIds(Appearance.sanitize(edited, snapshot))
		t.eq(worn[1], false, "the hat switched off stays off")
		t.eq(worn[4], true, "the face chosen")
		t.eq(worn[3], false, "the face not named gives way to the one chosen")
		t.eq(worn[5], false, "the shirt switched off stays off")
		t.eq(worn[2], true, "the hair not named is worn")
		t.eq(worn[6], true, "the head not named is worn")
		-- An edit that saw everything keeps every choice (the editor's usual case).
		local seen = Appearance.copy(snapshot)
		for _, item in seen.assets do
			item.worn = false
		end
		for id, isWorn in wornIds(Appearance.sanitize(seen, snapshot)) do
			t.eq(isWorn, false, `asset {id} switched off`)
		end
	end)

	t.test("character looks: an avatar read is kept, a failed one only briefly, never for a new character", function()
		local retry = Config.Characters.SnapshotRetrySeconds
		t.ok(retry > 0 and Config.Characters.SnapshotTries >= 1, "the read's settings")
		local read: CharacterLooks.Snapshot = { look = readAvatar(), read = true, at = 100 }
		local failed: CharacterLooks.Snapshot = { look = Appearance.default(), read = false, at = 100 }
		t.eq(CharacterLooks.serves(nil, 100), false, "nothing kept: read")
		t.eq(CharacterLooks.serves(read, 100 + 1e9), true, "a read avatar serves the session")
		t.eq(CharacterLooks.serves(read, 200, 150), true, "and a new character")
		t.eq(CharacterLooks.serves(failed, 100 + retry / 2), true, "a failure stands in briefly")
		t.eq(CharacterLooks.serves(failed, 100 + retry), false, "then the avatar is read again")
		t.eq(CharacterLooks.serves(failed, 101, 100.5), false, "a new character never takes an older failure")
		failed.at = 102
		t.eq(CharacterLooks.serves(failed, 102, 100.5), true, "but one read while it waited")
	end)

	t.test("character looks: a failed avatar read is tried again with a backoff", function()
		local function reader(results: { any })
			local calls = 0
			return function(): (boolean, unknown)
				calls += 1
				local result = results[calls]
				return result.ok, result.value
			end, function(): number
				return calls
			end
		end
		local waits: { number } = {}
		local function wait(seconds: number)
			table.insert(waits, seconds)
		end
		-- Two failures, then the avatar.
		local read, calls =
			reader({ { ok = false, value = "e1" }, { ok = false, value = "e2" }, { ok = true, value = "desc" } })
		local ok, value = CharacterLooks.retry(read, 3, 1, wait)
		t.eq(ok, true)
		t.eq(value, "desc")
		t.eq(calls(), 3)
		t.eq(#waits, 2)
		t.eq(waits[1], 1, "the backoff")
		t.eq(waits[2], 2, "doubled")
		-- Every try fails: the last error.
		table.clear(waits)
		read, calls =
			reader({ { ok = false, value = "e1" }, { ok = false, value = "e2" }, { ok = false, value = "e3" } })
		ok, value = CharacterLooks.retry(read, 3, 0.5, wait)
		t.eq(ok, false)
		t.eq(value, "e3")
		t.eq(calls(), 3, "no more than the tries")
		t.eq(#waits, 2)
		t.eq(waits[2], 1)
		-- Read at once: no wait; no tries asked for still reads once.
		table.clear(waits)
		read, calls = reader({ { ok = true, value = "now" } })
		ok = CharacterLooks.retry(read, 3, 1, wait)
		t.eq(ok, true)
		t.eq(#waits, 0)
		read, calls = reader({ { ok = false, value = "x" } })
		ok = CharacterLooks.retry(read, 0, 1, wait)
		t.eq(ok, false)
		t.eq(calls(), 1)
	end)
end
