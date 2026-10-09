--[[
	Characters (Terraria's player files, Config.Characters): the shared rules (Shared/Characters:
	difficulties, names, the list's order and times), looks (Characters/Appearance: bytes that
	refuse anything odd, scales kept within Roblox's avatar rules, a client's edit kept only over
	the server's snapshot of the user's own avatar, presets), the record and its DataStore value and
	index (server Save/CharacterCodec: every part of the inventory and equipment by place, newer
	versions and damage refused, the lock and the progress beside the bytes), what a world keeps of
	each character (Save/WorldCharacterCodec) and the title screen's messages (Net/CharacterSync).
]]

return function(t, shared, require, server)
	local Appearance = require(shared.Characters.Appearance)
	local CharacterSync = require(shared.Net.CharacterSync)
	local Characters = require(shared.Characters)
	local Config = require(shared.Config)
	local GameMode = require(shared.GameMode)
	local Items = require(shared.Items)
	local Protocol = require(shared.Net.Protocol)
	local Types = require(shared.Inventory.Types)
	local CharacterCodec = require(server.Save.CharacterCodec)
	local PlayerCodec = require(server.Save.PlayerCodec)
	local SaveCodec = require(server.Save.SaveCodec)
	local WorldCharacterCodec = require(server.Save.WorldCharacterCodec)

	local id = Items.id
	local D = Characters.Difficulty

	local function sameStack(a: Items.Stack?, b: Items.Stack?): boolean
		if a == nil or b == nil then
			return a == b
		end
		return Items.stacksMatch(a, b) and a.count == b.count
	end

	-- A look with a few of the user's own things: a hat (worn), hair (not), a shirt, a head part.
	local function sampleLook(): Appearance.Appearance
		local look = Appearance.default()
		look.colors = { 0x112233, 0xFFFFFF, 0, 0xABCDEF, 0x010203, 0xEAB892 }
		look.scales = Appearance.clampScales({
			height = 1.05,
			width = 0.8,
			depth = 0.75,
			head = 0.95,
			bodyType = 0.3,
			proportion = 0.6,
		})
		look.assets = {
			{
				kind = Appearance.ACCESSORY + 1,
				id = 123456789012,
				worn = true,
				layered = false,
				order = 0,
				puffiness = 1,
			},
			{ kind = Appearance.ACCESSORY + 2, id = 42, worn = false, layered = false, order = 0, puffiness = 1 },
			{
				kind = Appearance.KIND.Shirt,
				id = 9007199254740992,
				worn = true,
				layered = false,
				order = 0,
				puffiness = 1,
			},
			{ kind = Appearance.ACCESSORY + 10, id = 77, worn = true, layered = true, order = 3, puffiness = 0.5 },
			{ kind = Appearance.KIND.Head, id = 5, worn = true, layered = false, order = 0, puffiness = 1 },
		}
		return look
	end

	--[[ Shared rules ]]

	t.test("characters: difficulties, names and the list", function()
		t.eq(D.Classic, 1)
		t.eq(D.Mediumcore, 2)
		t.eq(D.Hardcore, 3)
		t.eq(Characters.difficultyOf("mediumcore"), D.Mediumcore)
		t.eq(Characters.difficultyOf("Journey"), nil, "Terraria's Journey is not offered")
		t.eq(Characters.DEFAULT_DIFFICULTY, Characters.difficultyOf(Config.Characters.DefaultDifficulty))
		t.ok(Characters.keepsInventory(D.Classic))
		t.ok(not Characters.keepsInventory(D.Mediumcore) and not Characters.keepsInventory(D.Hardcore))
		t.ok(Characters.diesForGood(D.Hardcore) and not Characters.diesForGood(D.Mediumcore))
		t.eq(Characters.cleanName("  Steve   the  Miner "), "Steve the Miner")
		t.eq(Characters.cleanName("Ünïcødé ✓"), "Ünïcødé ✓")
		t.eq(Characters.cleanName("   "), nil, "blank")
		t.eq(Characters.cleanName("a\nb"), nil, "control characters")
		t.eq(Characters.cleanName("\255\254"), nil, "invalid UTF-8")
		t.eq(Characters.cleanName(string.rep("x", Characters.MAX_NAME)), string.rep("x", Characters.MAX_NAME))
		t.eq(Characters.cleanName(string.rep("x", Characters.MAX_NAME + 1)), nil, "too long")
		t.eq(Characters.cleanName(42), nil)
		t.eq(Characters.formatPlayed(0), "0:00")
		t.eq(Characters.formatPlayed(59), "0:00")
		t.eq(Characters.formatPlayed(3600 + 5 * 60 + 30), "1:05")
		t.eq(Characters.formatPlayed(0 / 0), "0:00")
		local list = {
			{
				id = 1,
				name = "A",
				difficulty = 1,
				dead = false,
				legacy = false,
				created = 10,
				lastPlayed = 50,
				played = 0,
			},
			{
				id = 2,
				name = "B",
				difficulty = 1,
				dead = false,
				legacy = false,
				created = 20,
				lastPlayed = 90,
				played = 0,
			},
			{
				id = 3,
				name = "C",
				difficulty = 3,
				dead = true,
				legacy = false,
				created = 30,
				lastPlayed = 50,
				played = 0,
			},
		}
		Characters.sort(list)
		t.eq(list[1].id, 2, "last played first")
		t.eq(list[2].id, 3, "then the newest made")
		t.ok(Characters.validSummary(list[1]))
		t.ok(not Characters.validSummary({ id = 0, name = "A" }))
	end)

	--[[ Looks ]]

	t.test("characters: a look round trips as bytes; anything odd is refused", function()
		local look = sampleLook()
		local bytes = Appearance.encode(look)
		t.eq(buffer.len(bytes), 32 + 5 * 12)
		local back = Appearance.decode(bytes) :: Appearance.Appearance
		t.ok(back ~= nil)
		for i = 1, 6 do
			t.eq(back.colors[i], look.colors[i], `colour {i}`)
		end
		for _, name in Appearance.SCALES do
			t.near((back.scales :: any)[name], (look.scales :: any)[name], 1e-4, name)
		end
		t.eq(#back.assets, 5)
		t.eq(back.assets[1].id, 123456789012, "ids past 32 bits")
		t.eq(back.assets[3].id, 9007199254740992, "up to 2^53")
		t.eq(back.assets[2].worn, false)
		t.eq(back.assets[4].layered, true)
		t.eq(back.assets[4].order, 3)
		t.near(back.assets[4].puffiness, 0.5, 1e-9)
		t.eq(Appearance.accessoryType(back.assets[1].kind), 1, "Enum.AccessoryType.Hat")
		t.eq(Appearance.accessoryType(Appearance.KIND.Shirt), nil)
		t.eq(Appearance.PROPERTY[Appearance.KIND.GraphicTShirt], "GraphicTShirt")
		-- Damage.
		local newer = buffer.create(buffer.len(bytes))
		buffer.copy(newer, 0, bytes)
		buffer.writeu8(newer, 0, Appearance.VERSION + 1)
		t.eq(Appearance.decode(newer), nil, "a newer version")
		local badKind = buffer.create(buffer.len(bytes))
		buffer.copy(badKind, 0, bytes)
		buffer.writeu8(badKind, 32, 20)
		t.eq(Appearance.decode(badKind), nil, "an unknown kind")
		local badId = buffer.create(buffer.len(bytes))
		buffer.copy(badId, 0, bytes)
		buffer.writef64(badId, 33, 0.5)
		t.eq(Appearance.decode(badId), nil, "an id that is no asset id")
		local longer = buffer.create(buffer.len(bytes) + 1)
		buffer.copy(longer, 0, bytes)
		t.eq(Appearance.decode(longer), nil, "bytes left over")
		t.eq(Appearance.decode(buffer.create(3)), nil, "too short")
	end)

	t.test("characters: scales stay within the avatar rules; presets", function()
		local limits = Config.Characters.Scales
		local scales = Appearance.clampScales({ height = 9, width = -1, depth = 0 / 0, head = 0.5 })
		t.eq(scales.height, limits.height[2])
		t.eq(scales.width, limits.width[1])
		t.eq(scales.depth, 1, "junk reads as 1")
		t.eq(scales.head, limits.head[1])
		t.eq(scales.bodyType, 0, "missing body type: blocky")
		local look = sampleLook()
		local classic = Appearance.preset(look, "Classic")
		t.eq(classic.scales.bodyType, 0)
		t.eq(classic.scales.proportion, 0)
		t.eq(classic.colors[1], 0xF5CD30, "the classic yellow head")
		t.eq(classic.assets[5].worn, false, "body parts off: the blocky shape")
		t.eq(classic.assets[1].worn, true, "accessories stay")
		t.eq(look.assets[5].worn, true, "a copy: the look itself is untouched")
		local natural = Appearance.preset(classic, "Natural")
		t.eq(natural.scales.bodyType, 1)
		t.eq(natural.assets[5].worn, true)
		t.eq(#Appearance.SKIN_TONES, 12)
		t.eq(Appearance.default().assets[1], nil, "the default has no assets")
	end)

	t.test("characters: an edit keeps only the server's snapshot of the user's own things", function()
		local snapshot = sampleLook()
		local edited = Appearance.copy(snapshot)
		edited.colors[1] = 0x00FF00
		edited.colors[2] = -5
		edited.scales.height = 3
		-- Toggles: the hat off, the hair on.
		edited.assets[1].worn = false
		edited.assets[2].worn = true
		-- A catalog item the user does not own, worn: dropped.
		table.insert(edited.assets, {
			kind = Appearance.ACCESSORY + 1,
			id = 999,
			worn = true,
			layered = false,
			order = 0,
			puffiness = 1,
		})
		-- A second shirt worn: only one of a single kind (and only the snapshot's).
		table.insert(edited.assets, {
			kind = Appearance.KIND.Shirt,
			id = 31337,
			worn = true,
			layered = false,
			order = 0,
			puffiness = 1,
		})
		local kept = Appearance.sanitize(edited, snapshot)
		t.eq(kept.colors[1], 0x00FF00)
		t.eq(kept.colors[2], snapshot.colors[2], "a bad colour keeps the snapshot's")
		t.eq(kept.scales.height, Config.Characters.Scales.height[2])
		t.eq(#kept.assets, #snapshot.assets, "nothing added")
		t.eq(kept.assets[1].worn, false)
		t.eq(kept.assets[2].worn, true)
		t.eq(kept.assets[3].worn, true, "the user's own shirt")
		for _, asset in kept.assets do
			t.ok(asset.id ~= 999 and asset.id ~= 31337, "no foreign asset")
		end
		-- Two of the user's own faces worn: the first one.
		local faces = Appearance.default()
		faces.assets = {
			{ kind = Appearance.KIND.Face, id = 1, worn = true, layered = false, order = 0, puffiness = 1 },
			{ kind = Appearance.KIND.Face, id = 2, worn = true, layered = false, order = 0, puffiness = 1 },
		}
		local one = Appearance.sanitize(faces, faces)
		t.eq(one.assets[1].worn, true)
		t.eq(one.assets[2].worn, false)
	end)

	--[[ The record ]]

	local function fullRecord(): CharacterCodec.Record
		local record = CharacterCodec.new(7, "Steve", D.Mediumcore, sampleLook(), 1700000000)
		record.dead = true
		record.legacy = true
		record.lastPlayed = 1700000500.5
		record.played = 3725.25
		record.deaths = 3
		record.health = 13.5
		record.mana = 37.5
		record.crystals = 2
		record.selected = 4
		record.hidden = bit32.bor(1, bit32.lshift(1, Types.HIDE_ARMOR + 3))
		record.slots[1] = Items.newStack(id.Stone, 64)
		record.slots[36] = Items.newStack(id.Chest, 1, nil, Items.cleanData({ amount = 3 }))
		record.armor[2] = Items.newStack(id.IronChestplate, 1)
		record.cursor = Items.newStack(id.Sand, 7)
		record.accessories[1] = Items.newStack(id.HermesBoots, 1)
		record.accessories[7] = Items.newStack(id.CobaltShield, 1)
		record.vanityArmor[1] = Items.newStack(id.TopHat, 1)
		record.vanityArmor[4] = Items.newStack(id.LeatherBoots, 1)
		record.vanityAccessories[3] = Items.newStack(id.ShinyRedBalloon, 1)
		record.thirst = { thirst = 14, hydration = 2.5, exhaustion = 1.25, effect = 0, timer = 30 }
		record.temperature = {
			value = -3,
			target = -5,
			drift = 10,
			frozen = 0,
			heat = 0,
			timer = 0,
			wet = 20,
			warmth = 0,
			chill = 0,
			clemency = 4000,
		}
		record.effects = {
			{ effect = 1, amplifier = 1, ticks = 600, ambient = false },
			{ effect = 25, amplifier = 0, ticks = 100, ambient = false },
		}
		record.imported = { "w12345678", "wabc" }
		return record
	end

	t.test("characters: a record round trips with every store; damage and newer versions are refused", function()
		local record = fullRecord()
		local text = CharacterCodec.toText(record)
		local back = CharacterCodec.fromText(text) :: CharacterCodec.Record
		t.ok(back ~= nil)
		t.eq(back.id, 7)
		t.eq(back.name, "Steve")
		t.eq(back.difficulty, D.Mediumcore)
		t.eq(back.dead, true)
		t.eq(back.legacy, true)
		t.eq(back.created, 1700000000)
		t.eq(back.lastPlayed, 1700000500.5)
		t.eq(back.played, 3725.25)
		t.eq(back.deaths, 3)
		t.eq(back.health, 13.5)
		t.eq(back.maxHealth, 20)
		t.eq(back.mana, 37.5)
		t.eq(back.crystals, 2)
		t.eq(back.selected, 4)
		t.eq(back.hidden, record.hidden)
		t.ok(sameStack(back.slots[1], record.slots[1]))
		t.ok(sameStack(back.slots[36], record.slots[36]), "item data kept")
		t.ok(sameStack(back.armor[2], record.armor[2]))
		t.ok(sameStack(back.cursor, record.cursor))
		t.ok(sameStack(back.accessories[1], record.accessories[1]))
		t.ok(sameStack(back.accessories[7], record.accessories[7]))
		t.ok(sameStack(back.vanityArmor[1], record.vanityArmor[1]))
		t.ok(sameStack(back.vanityArmor[4], record.vanityArmor[4]))
		t.ok(sameStack(back.vanityAccessories[3], record.vanityAccessories[3]))
		t.eq(back.accessories[2], nil)
		t.eq((back.thirst :: any).hydration, 2.5)
		t.eq((back.temperature :: any).clemency, 4000)
		t.eq(#back.effects, 2)
		t.eq(back.effects[2].effect, 25)
		t.eq(#back.imported, 2)
		t.eq(back.imported[2], "wabc")
		t.eq(#back.appearance.assets, 5)
		t.eq(back.dropped, 0)
		print(`    a full character: {#text} characters`)
		-- A new character: small.
		local fresh = CharacterCodec.new(1, "Alex", D.Classic, Appearance.default(), 0)
		t.ok(#CharacterCodec.toText(fresh) < 160)
		t.eq((CharacterCodec.fromText(CharacterCodec.toText(fresh)) :: any).mana, Config.Mana.Base)
		-- Damage.
		local bytes = CharacterCodec.encode(record)
		local longer = buffer.create(buffer.len(bytes) + 1)
		buffer.copy(longer, 0, bytes)
		t.eq((CharacterCodec.decode(longer)), nil, "bytes left over")
		local newer = buffer.create(buffer.len(bytes))
		buffer.copy(newer, 0, bytes)
		buffer.writeu8(newer, 0, CharacterCodec.VERSION + 1)
		local none, why = CharacterCodec.decode(newer)
		t.eq(none, nil, "a newer version")
		t.ok(why ~= nil)
		t.eq((CharacterCodec.decode(buffer.create(0))), nil, "nothing")
		t.eq((CharacterCodec.fromText("not base85 \\")), nil)
		t.eq((CharacterCodec.fromText(42)), nil)
		-- A bad place (60 is past the vanity accessories).
		local w = SaveCodec.writer()
		SaveCodec.u8(w, 1)
		SaveCodec.u8(w, 0)
		SaveCodec.u32(w, 1)
		SaveCodec.text(w, "A")
		SaveCodec.u8(w, 1)
		for _ = 1, 3 do
			SaveCodec.f64(w, 0)
		end
		SaveCodec.u32(w, 0)
		local look = Appearance.encode(Appearance.default())
		SaveCodec.u16(w, buffer.len(look))
		SaveCodec.bytes(w, look)
		for _, value in { 20, 20, 20 } do
			SaveCodec.f32(w, value)
		end
		SaveCodec.u8(w, 0)
		SaveCodec.u8(w, 1)
		SaveCodec.u16(w, 0)
		SaveCodec.u8(w, 1)
		SaveCodec.u8(w, Types.PLACE_END + 1)
		SaveCodec.stack(w, Items.newStack(id.Stone, 1))
		SaveCodec.u8(w, 0)
		SaveCodec.u8(w, 0)
		local _, badPlace = CharacterCodec.decode(SaveCodec.finish(w))
		t.eq(badPlace, "bad inventory place")
	end)

	t.test("characters: the DataStore value keeps the lock and the progress beside the bytes", function()
		local record = fullRecord()
		local progress = { v = 1, points = 120, age = "iron", skills = {}, found = {} }
		local value = CharacterCodec.value(record, progress, { job = "job-a", at = 100 })
		t.eq(value.v, CharacterCodec.VALUE_VERSION)
		local back, keptProgress, lock, why = CharacterCodec.readValue(value)
		t.eq(why, nil)
		t.eq((back :: any).name, "Steve")
		t.eq((keptProgress :: any).points, 120)
		t.eq((lock :: any).job, "job-a")
		-- Nothing saved; another version (never written over); damage.
		local none, _, noLock, noWhy = CharacterCodec.readValue(nil)
		t.eq(none, nil)
		t.eq(noLock, nil)
		t.eq(noWhy, nil, "nothing is no error")
		local _, _, newerLock, newer =
			CharacterCodec.readValue({ v = 2, data = value.data, lock = { job = "b", at = 1 } })
		t.ok(newer ~= nil, "another version is refused")
		t.eq((newerLock :: any).job, "b", "its lock still reads")
		local _, _, _, damaged = CharacterCodec.readValue({ v = 1, data = "!!" })
		t.ok(damaged ~= nil)
		local _, _, _, wrong = CharacterCodec.readValue("text")
		t.ok(wrong ~= nil)
	end)

	t.test("characters: the index lists summaries, refuses damage and never reuses an id", function()
		local index = CharacterCodec.newIndex()
		t.eq(index.next, 1)
		t.eq(#index.chars, 0)
		local record = fullRecord()
		local summary = CharacterCodec.summary(record)
		index.chars = { summary }
		index.next = 8
		local stored = CharacterCodec.indexValue(index)
		t.eq(stored.v, CharacterCodec.INDEX_VERSION)
		local back = CharacterCodec.readIndex(stored) :: CharacterCodec.Index
		t.eq(back.next, 8)
		t.eq(back.chars[1].name, "Steve")
		t.eq(back.chars[1].dead, true)
		t.ok(back.chars[1] ~= stored.chars[1], "copies")
		t.eq((CharacterCodec.readIndex(nil) :: any).next, 1, "nothing saved: a new list")
		t.ok(select(2, CharacterCodec.readIndex({ v = 2, next = 1, chars = {} })) ~= nil, "another version")
		local reused = CharacterCodec.indexValue(index)
		reused.next = 7
		t.eq(CharacterCodec.readIndex(reused), nil, "an id at or past next")
		local twice = CharacterCodec.indexValue(index)
		table.insert(twice.chars, table.clone(twice.chars[1]))
		t.eq(CharacterCodec.readIndex(twice), nil, "an id twice")
		local badName = CharacterCodec.indexValue(index)
		badName.chars[1].name = "  "
		t.eq(CharacterCodec.readIndex(badName), nil, "a malformed summary")
		local many = { v = 1, next = 1000, chars = {} }
		for i = 1, Characters.MAX + 1 do
			table.insert(many.chars, {
				id = i,
				name = `C{i}`,
				difficulty = 1,
				dead = false,
				legacy = false,
				created = 0,
				lastPlayed = 0,
				played = 0,
			})
		end
		t.eq(CharacterCodec.readIndex(many), nil, "more than the most")
	end)

	t.test("characters: what a world keeps of a character; the old player record's place", function()
		local entry = WorldCharacterCodec.new()
		entry.position = true
		entry.x, entry.y, entry.z, entry.yaw = -1234.5, 87, 99999.25, 2.5
		entry.mode = GameMode.CREATIVE
		entry.previous = GameMode.SURVIVAL
		entry.spawn = { 10, 64, -20 }
		local back = WorldCharacterCodec.fromText(WorldCharacterCodec.toText(entry)) :: WorldCharacterCodec.Entry
		t.eq(back.position, true)
		t.eq(back.x, -1234.5)
		t.eq(back.z, 99999.25)
		t.eq(back.yaw, 2.5)
		t.eq(back.mode, GameMode.CREATIVE)
		t.eq(back.previous, GameMode.SURVIVAL)
		t.eq((back.spawn :: any)[3], -20)
		local empty = WorldCharacterCodec.fromText(WorldCharacterCodec.toText(WorldCharacterCodec.new())) :: any
		t.eq(empty.position, false)
		t.eq(empty.mode, nil)
		t.eq(empty.spawn, nil)
		t.ok(#WorldCharacterCodec.toText(WorldCharacterCodec.new()) < 10)
		entry.spawn = { 1.5, 2, 3 }
		t.eq(
			(WorldCharacterCodec.fromText(WorldCharacterCodec.toText(entry)) :: any).spawn,
			nil,
			"a bad spawn is left out"
		)
		local bytes = WorldCharacterCodec.encode(entry)
		local longer = buffer.create(buffer.len(bytes) + 1)
		buffer.copy(longer, 0, bytes)
		t.eq((WorldCharacterCodec.decode(longer)), nil, "bytes left over")
		local legacy = PlayerCodec.new()
		legacy.position = true
		legacy.x, legacy.y, legacy.z, legacy.yaw = 5, 70, 6, 1
		legacy.mode = GameMode.ADVENTURE
		local moved = WorldCharacterCodec.fromLegacy(legacy)
		t.eq(moved.position, true)
		t.eq(moved.y, 70)
		t.eq(moved.mode, GameMode.ADVENTURE)
		t.eq(moved.spawn, nil)
	end)

	--[[ The title screen's messages ]]

	t.test("characters: the title screen's messages round trip; malformed ones are refused", function()
		local A = CharacterSync.Action
		t.eq(Protocol.ClientMessage.CharacterAction, 25)
		t.eq(Protocol.ServerMessage.Characters, 28)
		t.eq(Protocol.ServerMessage.Avatar, 29)
		local function trip(request: CharacterSync.Request): CharacterSync.Request
			return CharacterSync.decodeAction(CharacterSync.encodeAction(request)) :: CharacterSync.Request
		end
		t.eq(trip({ action = A.List }).action, A.List)
		t.eq(trip({ action = A.Avatar }).action, A.Avatar)
		local created = trip({ action = A.Create, difficulty = D.Hardcore, name = "Alex", appearance = sampleLook() })
		t.eq(created.difficulty, D.Hardcore)
		t.eq(created.name, "Alex")
		t.eq(#(created.appearance :: any).assets, 5)
		t.eq(trip({ action = A.Delete, id = 3 }).id, 3)
		t.eq(trip({ action = A.Select, id = 4 }).id, 4)
		t.eq(trip({ action = A.Preview, id = 5 }).id, 5)
		local renamed = trip({ action = A.Rename, id = 6, name = "Bob" })
		t.eq(renamed.id, 6)
		t.eq(renamed.name, "Bob")
		t.eq(#(trip({ action = A.EditPreview, appearance = sampleLook() }).appearance :: any).assets, 5)
		-- Malformed.
		t.eq(CharacterSync.decodeAction(buffer.create(0)), nil, "empty")
		local unknown = buffer.create(1)
		buffer.writeu8(unknown, 0, 99)
		t.eq(CharacterSync.decodeAction(unknown), nil, "an unknown action")
		t.eq(CharacterSync.decodeAction(CharacterSync.encodeAction({ action = A.Delete, id = 0 })), nil, "id 0")
		t.eq(
			CharacterSync.decodeAction(CharacterSync.encodeAction({ action = A.Rename, id = 1, name = "  padded " })),
			nil,
			"a name the server would clean differently"
		)
		local badDifficulty = CharacterSync.encodeAction({
			action = A.Create,
			difficulty = D.Classic,
			name = "A",
			appearance = Appearance.default(),
		})
		buffer.writeu8(badDifficulty, 1, 9)
		t.eq(CharacterSync.decodeAction(badDifficulty), nil, "an unknown difficulty")
		local select = CharacterSync.encodeAction({ action = A.Select, id = 2 })
		local longer = buffer.create(buffer.len(select) + 1)
		buffer.copy(longer, 0, select)
		t.eq(CharacterSync.decodeAction(longer), nil, "bytes left over")
		-- EnterWorld: the character, empty for none.
		t.eq(CharacterSync.decodeEnter(CharacterSync.encodeEnter(12)), 12)
		t.eq(CharacterSync.decodeEnter(buffer.create(0)), 0)
		t.eq(CharacterSync.decodeEnter(buffer.create(3)), nil)
		-- The list.
		local list: CharacterSync.List = {
			saving = true,
			busy = false,
			selected = 7,
			max = Characters.MAX,
			message = "Character created",
			characters = { CharacterCodec.summary(fullRecord()) },
		}
		local got = CharacterSync.decodeCharacters(CharacterSync.encodeCharacters(list)) :: CharacterSync.List
		t.eq(got.saving, true)
		t.eq(got.busy, false)
		t.eq(got.selected, 7)
		t.eq(got.max, Characters.MAX)
		t.eq(got.message, "Character created")
		t.eq(#got.characters, 1)
		t.eq(got.characters[1].name, "Steve")
		t.eq(got.characters[1].dead, true)
		t.eq(got.characters[1].legacy, true)
		t.eq(got.characters[1].played, 3725.25)
		local badFlags = CharacterSync.encodeCharacters(list)
		buffer.writeu8(badFlags, 0, 8)
		t.eq(CharacterSync.decodeCharacters(badFlags), nil)
		-- The avatar.
		local purpose, look = CharacterSync.decodeAvatar(CharacterSync.encodeAvatar(1, sampleLook()))
		t.eq(purpose, CharacterSync.AvatarPurpose.Own)
		t.eq(#(look :: any).assets, 5)
		t.eq((CharacterSync.decodeAvatar(CharacterSync.encodeAvatar(2, sampleLook()))), nil, "an unknown purpose")
	end)

	--[[ The look on Roblox's side (server Players/CharacterLooks' mapping) ]]

	t.test("characters: a look as HumanoidDescription's properties and back", function()
		local CharacterLooks = require(server.Players.CharacterLooks)
		local look = sampleLook()
		local fields = CharacterLooks.fields(look)
		t.eq(fields.colors.HeadColor, 0x112233)
		t.eq(fields.colors.RightLegColor, 0xEAB892)
		t.eq(fields.scales.HeightScale, 1.05)
		t.eq(fields.scales.BodyTypeScale, look.scales.bodyType)
		t.eq(fields.properties.Shirt, 9007199254740992, "a worn shirt")
		t.eq(fields.properties.Head, 5, "a worn head")
		t.eq(fields.properties.Torso, 0, "a body part not worn: the blocky one")
		t.eq(fields.properties.IdleAnimation, 0)
		t.eq(#fields.accessories, 2, "the worn accessories only")
		t.eq(fields.accessories[1].AssetId, 123456789012)
		t.eq(fields.accessories[1].AccessoryType, 1, "a Hat")
		t.eq(fields.accessories[2].IsLayered, true)
		t.eq(fields.accessories[2].Order, 3)
		-- A user's own avatar read back: everything worn, within the rules and the most kept.
		fields.scales.HeightScale = 1.4
		fields.properties.IdleAnimation = 777
		local back = CharacterLooks.fromFields(fields)
		t.eq(back.colors[1], 0x112233)
		t.eq(back.scales.height, Config.Characters.Scales.height[2], "clamped")
		local kinds = {}
		for _, asset in back.assets do
			t.eq(asset.worn, true)
			kinds[asset.kind] = asset.id
		end
		t.eq(kinds[Appearance.KIND.Head], 5)
		t.eq(kinds[Appearance.KIND.IdleAnimation], 777)
		t.eq(kinds[Appearance.KIND.Torso], nil, "0 is no asset")
		t.eq(kinds[Appearance.ACCESSORY + 10], 77)
		local many = { colors = {}, scales = {}, properties = {}, accessories = {} }
		for i = 1, 100 do
			table.insert(many.accessories, {
				AssetId = i,
				AccessoryType = 1,
				IsLayered = false,
				Order = 0,
				Puffiness = 1,
			})
		end
		t.eq(#CharacterLooks.fromFields(many :: any).assets, Config.Characters.MaxAssets, "at most MaxAssets")
		local plain = CharacterLooks.fromFields({ colors = {}, scales = {}, properties = {}, accessories = {} })
		t.eq(#plain.assets, 0)
		t.eq(plain.colors[1], Appearance.default().colors[1], "nothing read: the default look's")
	end)
end
