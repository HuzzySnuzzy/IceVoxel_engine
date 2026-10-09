--[[
	Returning players' old data into characters (server Save/CharacterMigration, Config.Characters
	.Migrate): the old progress becomes a Mediumcore "legacy" character with the user's avatar all
	worn; an old per-world player record (Save/PlayerCodec, version 1 or 2) is taken in once per
	world by the first character entering it (its place and game mode to the world's entry for
	that character, its slots, armor, equipment and cursor into the character's inventory, what
	does not fit listed to drop), the world keeping who took it (WorldMeta's legacyImported, saved and read
	back) and the character the world's id; and what a world keeps of each character (WorldStore's
	entries "<id>/c/<userId>_<charId>": written, read back, in order, deleted with the world).
]]

return function(t, shared, require, server)
	local Appearance = require(shared.Characters.Appearance)
	local Characters = require(shared.Characters)
	local GameMode = require(shared.GameMode)
	local Items = require(shared.Items)
	local Types = require(shared.Inventory.Types)
	local CharacterCodec = require(server.Save.CharacterCodec)
	local CharacterMigration = require(server.Save.CharacterMigration)
	local CharacterSaves = require(server.Save.CharacterSaves)
	local PlayerCodec = require(server.Save.PlayerCodec)
	local SaveCodec = require(server.Save.SaveCodec)
	local WorldCharacterCodec = require(server.Save.WorldCharacterCodec)
	local WorldMeta = require(server.Save.WorldMeta)
	local WorldStore = require(server.Save.WorldStore)

	local USER = 4242
	local id = Items.id

	local function deepCopy(value: any): any
		if type(value) ~= "table" then
			return value
		end
		local out = {}
		for k, v in value do
			out[k] = deepCopy(v)
		end
		return out
	end

	-- A plain fake DataStore (no budgets: CharacterStore's spec has those), with its Env.
	local function fake(job: string?)
		local self: any = { clock = 0, data = {}, writes = {} }
		self.store = {
			get = function(key: string)
				return true, deepCopy(self.data[key])
			end,
			set = function(key: string, value: any)
				table.insert(self.writes, key)
				self.data[key] = deepCopy(value)
				return true, nil
			end,
			update = function(key: string, transform: any)
				table.insert(self.writes, key)
				local new = transform(deepCopy(self.data[key]))
				if new ~= nil then
					self.data[key] = deepCopy(new)
				end
				return true, deepCopy(self.data[key])
			end,
			remove = function(key: string)
				self.data[key] = nil
				return true, nil
			end,
		}
		self.env = {
			now = function()
				return self.clock
			end,
			budget = function(): number
				return 100
			end,
			wait = function(dt: number)
				self.clock += dt
			end,
			spawn = function(fn: () -> ())
				fn()
			end,
			time = function(): number
				return 1700000000 + math.floor(self.clock)
			end,
			job = job or "server-a",
			random = function(): number
				return 0.25
			end,
		}
		return self
	end

	local function settings(): any
		return {
			name = "Island",
			gameMode = GameMode.SURVIVAL,
			difficulty = 2,
			allowCommands = false,
			worldType = "default",
			options = { structures = true },
			seed = 42,
		}
	end

	-- A version 1 player record's text, as a world saved before characters (and equipment) held it.
	local function versionOne(record: PlayerCodec.Record): string
		local w = SaveCodec.writer(256)
		SaveCodec.u8(w, 1)
		SaveCodec.u8(w, if record.position then 1 else 0)
		if record.position then
			SaveCodec.f64(w, record.x)
			SaveCodec.f64(w, record.y)
			SaveCodec.f64(w, record.z)
			SaveCodec.f32(w, record.yaw)
		end
		SaveCodec.f32(w, record.health)
		SaveCodec.u8(w, if record.mode then GameMode.id(record.mode) else 255)
		SaveCodec.u8(w, 255)
		SaveCodec.u8(w, record.selected)
		local held = {}
		for slot = 1, Types.INVENTORY_SIZE do
			if record.slots[slot] then
				table.insert(held, { slot, record.slots[slot] })
			end
		end
		for slot = 1, Types.ARMOR_SIZE do
			if record.armor[slot] then
				table.insert(held, { Types.INVENTORY_SIZE + slot, record.armor[slot] })
			end
		end
		if record.cursor then
			table.insert(held, { Types.PLACE_CURSOR, record.cursor })
		end
		SaveCodec.u8(w, #held)
		for _, entry in held do
			SaveCodec.u8(w, entry[1])
			SaveCodec.stack(w, entry[2])
		end
		SaveCodec.u8(w, 0)
		return SaveCodec.toText(SaveCodec.finish(w))
	end

	local function oldRecord(): PlayerCodec.Record
		local old = PlayerCodec.new()
		old.position = true
		old.x, old.y, old.z, old.yaw = 120.5, 70, -33.25, 1.5
		old.health = 6
		old.mode = GameMode.CREATIVE
		old.selected = 3
		old.slots[1] = Items.newStack(id.Stone, 64)
		old.slots[2] = Items.newStack(id.Stick, 10)
		old.slots[20] = Items.newStack(id.IronIngot, 5)
		old.armor[1] = Items.newStack(Items.id.LeatherHelmet, 1)
		old.cursor = Items.newStack(id.Stick, 60)
		return old
	end

	t.test("character migration: old progress becomes a Mediumcore legacy character, all worn", function()
		local look = Appearance.default()
		look.assets = {
			{ kind = Appearance.ACCESSORY + 1, id = 11, worn = false, layered = false, order = 0, puffiness = 1 },
			{ kind = Appearance.ACCESSORY + 1, id = 12, worn = false, layered = false, order = 0, puffiness = 1 },
			{ kind = Appearance.KIND.Shirt, id = 21, worn = false, layered = false, order = 0, puffiness = 1 },
			{ kind = Appearance.KIND.Shirt, id = 22, worn = false, layered = false, order = 0, puffiness = 1 },
		}
		local record = CharacterMigration.legacy(1, "  Steve  ", look, 1700000000)
		t.eq(record.name, "Steve")
		t.eq(record.difficulty, Characters.Difficulty.Mediumcore, "today's death rule")
		t.eq(record.legacy, true)
		t.eq(record.dead, false)
		t.eq(next(record.slots), nil, "an empty inventory")
		local worn = {}
		for _, asset in record.appearance.assets do
			worn[asset.id] = asset.worn
		end
		t.eq(worn[11], true, "every accessory")
		t.eq(worn[12], true)
		t.eq(worn[21], true, "the first shirt")
		t.eq(worn[22], false, "one of a single kind")
		t.eq(look.assets[1].worn, false, "a copy")
		t.eq(CharacterMigration.legacy(2, "\0bad", look, 0).name, CharacterMigration.DEFAULT_NAME)
		t.eq(CharacterMigration.legacy(2, nil, look, 0).name, "Character 1")
		-- Stored with the progress beside it, marked migrated, unlocked (not selected).
		local f = fake()
		local saves = CharacterSaves.new(f.store, f.env)
		local progress = { v = 1, points = 340, age = "iron", skills = { "Smithing" }, found = {} }
		local listed = CharacterSaves.create(saves, USER, record, progress, false, true) :: any
		t.eq(listed.migrated, true)
		t.eq(listed.chars[1].legacy, true)
		local back, keptProgress, lock = CharacterCodec.readValue(f.data[CharacterSaves.recordKey(USER, 1)])
		t.eq((back :: any).legacy, true)
		t.eq((keptProgress :: any).points, 340)
		t.eq(lock, nil, "nobody holds it until it is selected")
	end)

	t.test("character migration: an old record's things go into the character; what doesn't fit is listed", function()
		local record = CharacterCodec.new(3, "Alex", Characters.Difficulty.Classic, Appearance.default(), 0)
		record.slots[1] = Items.newStack(id.Dirt, 5)
		record.armor[1] = Items.newStack(Items.id.IronHelmet, 1)
		local old = oldRecord()
		local leftovers = CharacterMigration.import(record, old)
		t.eq(record.slots[1].item, id.Dirt, "the character's own stay")
		t.eq(record.slots[2].item, id.Stick, "the same slot when empty")
		t.eq(record.slots[20].item, id.IronIngot)
		t.eq(record.armor[1].item, Items.id.IronHelmet, "the armor slot was taken")
		local stone, sticks, helmets = 0, 0, 0
		for slot = 1, Types.INVENTORY_SIZE do
			local stack = record.slots[slot]
			if stack and stack.item == id.Stone then
				stone += stack.count
			elseif stack and stack.item == id.Stick then
				sticks += stack.count
			elseif stack and stack.item == Items.id.LeatherHelmet then
				helmets += stack.count
			end
		end
		t.eq(stone, 64, "the stone moved to an empty slot")
		t.eq(sticks, 70, "the cursor's sticks merged")
		t.eq(helmets, 1, "the helmet into the bag")
		t.eq(#leftovers, 0)
		t.eq(old.slots[1].count, 64, "the old record untouched")
		-- A full inventory: everything left over.
		local full = CharacterCodec.new(4, "Full", Characters.Difficulty.Classic, Appearance.default(), 0)
		for slot = 1, Types.INVENTORY_SIZE do
			full.slots[slot] = Items.newStack(id.Cobblestone, 64)
		end
		full.armor[1] = Items.newStack(Items.id.IronHelmet, 1)
		local left = CharacterMigration.import(full, oldRecord())
		local count = 0
		for _, stack in left do
			count += stack.count
		end
		t.eq(count, 64 + 10 + 5 + 1 + 60, "every stack listed to drop")
	end)

	t.test("character migration: a world's old record is taken in once, by the first character", function()
		local f = fake()
		local saves = WorldStore.new(f.store, f.env)
		local world = WorldStore.create(saves, settings(), USER)
		-- The world as saved before characters: a version 1 record for the user.
		local old = oldRecord()
		local text = versionOne(old)
		local first = WorldStore.save(saves, world, {
			regions = {},
			players = { [USER] = text },
			sections = {},
			operators = {},
		})
		t.eq(first.ok, true)
		t.ok(world.meta.players[tostring(USER)] ~= nil, "listed in the meta")
		-- A server opens it: the record reads (version 1), and the first character takes it in.
		local f2 = fake("server-b")
		f2.data = f.data
		f2.clock = f.clock + 1000
		local saves2 = WorldStore.new(f2.store, f2.env)
		local loaded = WorldStore.load(saves2, world.id) :: any
		t.ok(loaded ~= nil)
		local opened = loaded.world
		local record = CharacterCodec.new(2, "Alex", Characters.Difficulty.Classic, Appearance.default(), 0)
		t.eq(CharacterMigration.shouldImport(opened.meta, USER, record), true)
		local ok, previous = WorldStore.loadPlayer(saves2, opened, USER)
		t.eq(ok, true)
		previous = previous :: any
		t.eq(previous.x, 120.5)
		local okEntry, existing = WorldStore.loadCharacter(saves2, opened, USER, record.id)
		t.eq(okEntry, true)
		t.eq(existing, nil, "its first visit")
		local entry = CharacterMigration.entry(existing, previous)
		t.eq(entry.position, true)
		t.eq(entry.z, -33.25)
		t.eq(entry.yaw, 1.5)
		t.eq(entry.mode, GameMode.CREATIVE)
		local leftovers = CharacterMigration.import(record, previous)
		t.eq(#leftovers, 0)
		CharacterMigration.markImported(opened.meta, USER, record)
		t.eq(opened.meta.legacyImported[tostring(USER)], 2)
		t.eq(record.imported[1], opened.id)
		t.eq(CharacterMigration.shouldImport(opened.meta, USER, record), false, "once")
		local other = CharacterCodec.new(3, "Other", Characters.Difficulty.Classic, Appearance.default(), 0)
		t.eq(CharacterMigration.shouldImport(opened.meta, USER, other), false, "for every character of the user")
		-- Saved with the world (the entry and the mark), and read back.
		local name = WorldMeta.characterName(USER, record.id)
		local saved = WorldStore.save(saves2, opened, {
			regions = {},
			players = {},
			characters = { [name] = WorldCharacterCodec.toText(entry) },
			characterOrder = { [name] = 1 },
			sections = {},
			operators = {},
		})
		t.eq(saved.ok, true)
		t.eq(saved.writtenCharacters[name], true)
		t.ok(f.data[WorldMeta.characterKey(opened.id, USER, record.id)] ~= nil, "<id>/c/<userId>_<charId>")
		t.ok(f.data[WorldMeta.playerKey(opened.id, USER)] ~= nil, "the old record is kept")
		WorldStore.release(saves2, opened)
		local f3 = fake("server-c")
		f3.data = f.data
		f3.clock = f2.clock + 1000
		local saves3 = WorldStore.new(f3.store, f3.env)
		local again = (WorldStore.load(saves3, opened.id) :: any).world
		t.eq(again.meta.legacyImported[tostring(USER)], 2, "the mark is saved with the world")
		t.ok(again.meta.characters[name] ~= nil)
		local okBack, back = WorldStore.loadCharacter(saves3, again, USER, record.id)
		t.eq(okBack, true)
		t.eq((back :: any).x, 120.5)
		t.eq(CharacterMigration.shouldImport(again.meta, USER, other), false)
		-- An older entry capture never writes over a newer one.
		local newer = WorldCharacterCodec.new()
		newer.position, newer.x = true, 1
		local older = WorldCharacterCodec.new()
		older.position, older.x = true, 2
		WorldStore.saveCharacters(saves3, again, { [name] = WorldCharacterCodec.toText(newer) }, nil, { [name] = 9 })
		f3.env.wait(10)
		WorldStore.saveCharacters(saves3, again, { [name] = WorldCharacterCodec.toText(older) }, nil, { [name] = 8 })
		local _, kept = WorldStore.loadCharacter(saves3, again, USER, record.id)
		t.eq((kept :: any).x, 1)
		-- Deleting the world takes the entries too.
		WorldStore.release(saves3, again)
		f3.env.wait(1000)
		t.eq(WorldStore.delete(saves3, again.id), true)
		t.eq(f.data[WorldMeta.characterKey(again.id, USER, record.id)], nil)
	end)

	t.test("character migration: a version 2 record's equipment goes to the same place or the bag", function()
		local record = CharacterCodec.new(5, "Worn", Characters.Difficulty.Classic, Appearance.default(), 0)
		record.accessories[2] = Items.newStack(Items.id.Aglet, 1)
		local old = oldRecord()
		old.accessories[1] = Items.newStack(Items.id.HermesBoots, 1)
		old.accessories[2] = Items.newStack(Items.id.CloudInABottle, 1)
		old.vanityArmor[1] = Items.newStack(Items.id.TopHat, 1)
		old.vanityAccessories[7] = Items.newStack(Items.id.ShinyRedBalloon, 1)
		local leftovers = CharacterMigration.import(record, old)
		t.eq(record.accessories[1].item, Items.id.HermesBoots, "an empty accessory slot takes it")
		t.eq(record.accessories[2].item, Items.id.Aglet, "the character's own stays")
		t.eq(record.vanityArmor[1].item, Items.id.TopHat)
		t.eq(record.vanityAccessories[7].item, Items.id.ShinyRedBalloon)
		local clouds = 0
		for slot = 1, Types.INVENTORY_SIZE do
			local stack = record.slots[slot]
			if stack and stack.item == Items.id.CloudInABottle then
				clouds += stack.count
			end
		end
		t.eq(clouds, 1, "a taken accessory slot: into the bag")
		t.eq(#leftovers, 0)
		t.eq(old.accessories[1].item, Items.id.HermesBoots, "the old record untouched")
		t.ok(record.accessories[1] ~= old.accessories[1], "copies, not the old record's stacks")
	end)

	t.test("character migration: an equipment record (version 2) round trips; version 1 still reads", function()
		local record = oldRecord()
		record.accessories[1] = Items.newStack(Items.id.HermesBoots, 1)
		record.vanityArmor[1] = Items.newStack(Items.id.TopHat, 1)
		record.vanityAccessories[7] = Items.newStack(Items.id.ShinyRedBalloon, 1)
		record.hidden = 0x0101
		local back = PlayerCodec.fromText(PlayerCodec.toText(record)) :: any
		t.eq(back.accessories[1].item, Items.id.HermesBoots)
		t.eq(back.vanityArmor[1].item, Items.id.TopHat)
		t.eq(back.vanityAccessories[7].item, Items.id.ShinyRedBalloon)
		t.eq(back.hidden, 0x0101)
		t.eq(back.cursor.count, 60)
		local plain = PlayerCodec.fromText(versionOne(oldRecord())) :: any
		t.ok(plain ~= nil, "a version 1 record reads")
		t.eq(plain.slots[20].item, id.IronIngot)
		t.eq(plain.hidden, 0)
		t.eq(next(plain.accessories), nil)
		-- Version 1 never had places past the cursor: such bytes are damage.
		local w = SaveCodec.writer(64)
		SaveCodec.u8(w, 1)
		SaveCodec.u8(w, 0)
		SaveCodec.f32(w, 20)
		SaveCodec.u8(w, 255)
		SaveCodec.u8(w, 255)
		SaveCodec.u8(w, 1)
		SaveCodec.u8(w, 1)
		SaveCodec.u8(w, Types.PLACE_ACCESSORY)
		SaveCodec.stack(w, Items.newStack(Items.id.HermesBoots, 1) :: any)
		SaveCodec.u8(w, 0)
		t.eq((PlayerCodec.decode(SaveCodec.finish(w))), nil)
		t.eq(PlayerCodec.VERSION, 2)
	end)
end
