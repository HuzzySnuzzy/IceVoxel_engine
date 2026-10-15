--[[
	Returning players' old data into characters (server Save/CharacterMigration, Config.Characters
	.Migrate): the old progress becomes a Mediumcore "legacy" character with the user's avatar all
	worn; an old per-world player record (Save/PlayerCodec, version 1, 2 or 3: the zombie
	apocalypse's survivor record, which versions 1 and 2 read as zeros) is taken in once per
	world by the first character entering it (its place and game mode to the world's entry for
	that character, its slots, armor, equipment (no accessory worn twice), cursor and Mana
	Crystals into the character, what does not fit listed to drop), the character keeping the
	world's id at once and the world who took it once that character was saved (WorldMeta's
	legacyImported, saved and read back); and what a world keeps of each character (WorldStore's
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
		-- (The zombie apocalypse's survivor record, CharacterCodec version 2: a migrated character
		-- starts it afresh, healthy, and keeps it through its key. 3 since the food bar.)
		t.eq(CharacterCodec.VERSION, 3)
		local stored = back :: CharacterCodec.Record
		t.eq(stored.alive + stored.kills + stored.moons + stored.infection, 0, "a fresh survivor record")
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

	t.test("character migration: no accessory is worn twice; a version 2 record's Mana Crystals come too", function()
		local record = CharacterCodec.new(6, "Boots", Characters.Difficulty.Classic, Appearance.default(), 0)
		record.accessories[1] = Items.newStack(Items.id.HermesBoots, 1)
		record.crystals = 5
		local old = oldRecord()
		old.accessories[2] = Items.newStack(Items.id.HermesBoots, 1)
		old.accessories[3] = Items.newStack(Items.id.Aglet, 1)
		old.crystals = 7
		local leftovers = CharacterMigration.import(record, old)
		t.eq(record.accessories[2], nil, "a second pair is not worn")
		t.eq(record.accessories[3].item, Items.id.Aglet, "another accessory is")
		local boots, crystals = 0, 0
		for slot = 1, Types.INVENTORY_SIZE do
			local stack = record.slots[slot]
			if stack and stack.item == Items.id.HermesBoots then
				boots += stack.count
			elseif stack and stack.item == Items.id.ManaCrystal then
				crystals += stack.count
			end
		end
		t.eq(boots, 1, "the second pair into the bag")
		t.eq(record.crystals, 9, "the crystals used add up to the most")
		t.eq(crystals, 5 + 7 - 9, "those past it come back as items")
		t.eq(#leftovers, 0)
		local fresh = CharacterCodec.new(7, "Fresh", Characters.Difficulty.Classic, Appearance.default(), 0)
		local few = oldRecord()
		few.crystals = 4
		CharacterMigration.import(fresh, few)
		t.eq(fresh.crystals, 4, "a character with none takes them all")
	end)

	t.test("character migration: the character's mark comes at once, the world's after its save", function()
		local f = fake()
		local saves = WorldStore.new(f.store, f.env)
		local world = WorldStore.create(saves, settings(), USER)
		world.meta.players[tostring(USER)] = 100
		local record = CharacterCodec.new(2, "Alex", Characters.Difficulty.Classic, Appearance.default(), 0)
		t.eq(CharacterMigration.shouldImport(world.meta, USER, record), true)
		CharacterMigration.markCharacter(world.meta, record)
		t.eq(record.imported[1], world.id, "the character never takes it twice")
		t.eq(world.meta.legacyImported[tostring(USER)], nil, "the world says nothing until it is saved")
		t.eq(CharacterMigration.shouldImport(world.meta, USER, record), false)
		CharacterMigration.markWorld(world.meta, USER, record.id)
		t.eq(world.meta.legacyImported[tostring(USER)], 2)
		local other = CharacterCodec.new(3, "Other", Characters.Difficulty.Classic, Appearance.default(), 0)
		t.eq(CharacterMigration.shouldImport(world.meta, USER, other), false, "then no other character")
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
	end)

	t.test("character migration: a survivor record (version 3) round trips; versions 1 and 2 read zeros", function()
		-- (4 since Minecraft's food bar: the test below.)
		t.eq(PlayerCodec.VERSION, 4, "bumped for the survivor record, then the food bar")
		local record = oldRecord()
		record.alive, record.kills, record.moons, record.infection = 50000, 12, 2, 30001
		local back = PlayerCodec.fromText(PlayerCodec.toText(record)) :: any
		t.eq(back.alive, 50000)
		t.eq(back.kills, 12)
		t.eq(back.moons, 2)
		t.eq(back.infection, 30001)
		t.eq(back.slots[20].item, id.IronIngot, "the rest as before")
		-- Version 2: the same bytes without the last 12 (u32 alive, u16 kills, u16 moons, u32
		-- infection) and their flag (bit 5) under version byte 2.
		local bytes = PlayerCodec.encode(record)
		t.ok(bit32.btest(buffer.readu8(bytes, 1), 32), "the survivor record's flag")
		local two = buffer.create(buffer.len(bytes) - 12)
		buffer.copy(two, 0, bytes, 0, buffer.len(two))
		buffer.writeu8(two, 0, 2)
		buffer.writeu8(two, 1, buffer.readu8(bytes, 1) - 32)
		local old = PlayerCodec.decode(two) :: any
		t.ok(old ~= nil, "a version 2 record reads")
		t.eq(old.alive, 0)
		t.eq(old.kills, 0)
		t.eq(old.moons, 0)
		t.eq(old.infection, 0, "healthy")
		t.eq(old.cursor.count, 60)
		-- Version 2 never had them: such bytes are damage. A fresh record writes none.
		t.ok(not bit32.btest(buffer.readu8(PlayerCodec.encode(PlayerCodec.new()), 1), 32), "all 0: none")
		local wrong = buffer.create(buffer.len(bytes))
		buffer.copy(wrong, 0, bytes, 0, buffer.len(bytes))
		buffer.writeu8(wrong, 0, 2)
		t.eq((PlayerCodec.decode(wrong)), nil)
		local plain = PlayerCodec.fromText(versionOne(oldRecord())) :: any
		t.eq(plain.alive, 0, "version 1: zeros too")
		-- Damage written as nothing odd: non-finite and out-of-range numbers are clamped.
		local odd = oldRecord()
		odd.alive, odd.kills, odd.moons, odd.infection = 0 / 0, 1e9, -3, math.huge
		local clamped = PlayerCodec.fromText(PlayerCodec.toText(odd)) :: any
		t.eq(clamped.alive, 0)
		t.eq(clamped.kills, 65535)
		t.eq(clamped.moons, 0)
		t.eq(clamped.infection, 0)
		-- Nothing live yet (the title screen): the saved record's survivor record is kept.
		local captured = PlayerCodec.new()
		local kept = PlayerCodec.withWaiting(
			captured,
			record,
			{ standing = false, climate = false, effects = false, mana = false, survivor = false }
		)
		t.eq(kept.alive, 50000)
		t.eq(kept.infection, 30001)
		local live = PlayerCodec.new()
		live.alive = 7
		t.eq(
			PlayerCodec.withWaiting(
				live,
				record,
				{ standing = true, climate = true, effects = true, mana = true, survivor = true }
			).alive,
			7,
			"live: the live one's"
		)
	end)

	t.test("character migration: the food bar (version 4) round trips; versions 1 to 3 have none", function()
		-- (Minecraft's hunger, Shared/Hunger: an optional block after the survivor record, as that
		-- one came, flag bit 6.)
		local record = oldRecord()
		record.alive = 5
		t.eq(record.hunger, nil, "none kept: the player starts with a full bar")
		local plain = PlayerCodec.encode(record)
		t.ok(not bit32.btest(buffer.readu8(plain, 1), 64), "no food bar, no flag")
		record.hunger = { food = 13, saturation = 0.5, exhaustion = 2.75, timer = 61 }
		local bytes = PlayerCodec.encode(record)
		t.ok(bit32.btest(buffer.readu8(bytes, 1), 64), "the food bar's flag")
		t.eq(buffer.len(bytes), buffer.len(plain) + 16, "four f32 at the end")
		local back = PlayerCodec.decode(bytes) :: any
		t.ok(back ~= nil, "round trips")
		t.eq(back.hunger.food, 13)
		t.eq(back.hunger.saturation, 0.5)
		t.eq(back.hunger.exhaustion, 2.75)
		t.eq(back.hunger.timer, 61)
		t.eq(back.alive, 5, "the survivor record before it")
		-- Version 3 (before the food bar): the same bytes without it read with none; a version 3
		-- byte with the flag is damage (an older server refuses a newer record the same way).
		local three = buffer.create(buffer.len(plain))
		buffer.copy(three, 0, plain, 0)
		buffer.writeu8(three, 0, 3)
		local old = PlayerCodec.decode(three) :: any
		t.ok(old ~= nil and old.hunger == nil, "version 3: no food bar")
		local wrong = buffer.create(buffer.len(bytes))
		buffer.copy(wrong, 0, bytes, 0)
		buffer.writeu8(wrong, 0, 3)
		t.eq((PlayerCodec.decode(wrong)), nil, "version 3 never had the flag")
		t.eq((PlayerCodec.fromText(versionOne(oldRecord())) :: any).hunger, nil, "version 1: none")
		local cut = buffer.create(buffer.len(bytes) - 1)
		buffer.copy(cut, 0, bytes, 0, buffer.len(cut))
		t.eq((PlayerCodec.decode(cut)), nil, "a truncated food bar")
		-- Nothing live yet (the title screen): the saved record's food bar is kept with the rest
		-- of the climate; once a character stands, the live one's.
		local waiting = PlayerCodec.withWaiting(
			PlayerCodec.new(),
			record,
			{ standing = false, climate = false, effects = false, mana = false, survivor = false }
		)
		t.eq((waiting.hunger :: any).food, 13)
		local live = PlayerCodec.new()
		live.hunger = { food = 20, saturation = 5, exhaustion = 0, timer = 0 }
		local standing = PlayerCodec.withWaiting(
			live,
			record,
			{ standing = true, climate = true, effects = true, mana = true, survivor = true }
		)
		t.eq((standing.hunger :: any).food, 20, "live: the live one's")
	end)
end
