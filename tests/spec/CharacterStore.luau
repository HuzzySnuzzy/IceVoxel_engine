--[[
	Characters in the store (server Save/CharacterSaves, the rules Players/CharacterStore plays
	out with the DataStore "IceVoxelCharacters_v1"), against a fake DataStore with budgets, the
	6 s a key, failures and servers that share it: a list that could not be read is never written
	over, selecting takes the lock (one server at a time; another's live lock refuses, a stale one
	is taken; a rejoin to the same server waits for its character's last save there), a lost lock
	stops saving, saves carry order numbers, a visit that stopped being fair keeps the things it
	had then (CharacterCodec.keepThings), creating writes the record
	before the list (an orphan of a failed list write is taken over), the most a user keeps,
	deleting and renaming refused while another server has the character, and the session-only
	store in memory.
]]

return function(t, shared, require, server)
	local Appearance = require(shared.Characters.Appearance)
	local Characters = require(shared.Characters)
	local Config = require(shared.Config)
	local Items = require(shared.Items)
	local CharacterCodec = require(server.Save.CharacterCodec)
	local CharacterSaves = require(server.Save.CharacterSaves)
	local SaveLock = require(server.Save.SaveLock)

	local USER = 1234567
	local D = Characters.Difficulty
	local TIMEOUT = Config.Save.LockTimeout

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

	--[[ A fake DataStore shared by servers: budgets, the 6 s a key, latency, failures ]]

	local function newBackend()
		return { data = {}, lastWrite = {} }
	end

	local function fakeStore(backend: any, options: any?)
		local o = options or {}
		local cap = 100
		local self: any = {
			clock = o.clock or 0,
			budgets = { get = cap, set = cap, update = cap },
			violations = {},
			calls = { get = 0, set = 0, update = 0, remove = 0 },
			failures = {},
			down = false,
			writes = {},
		}
		local function advance(dt: number)
			self.clock += dt
			for kind, value in self.budgets do
				self.budgets[kind] = math.min(cap, value + dt * cap / 60)
			end
		end
		local function group(kind: string): string
			return if kind == "remove" then "set" else kind
		end
		local function spend(kind: string, key: string): (boolean, string?)
			self.calls[kind] += 1
			local g = group(kind)
			if self.budgets[g] < 1 then
				table.insert(self.violations, `budget {g} at {self.clock}`)
				return false, "throttled"
			end
			self.budgets[g] -= 1
			if kind ~= "get" then
				local last = backend.lastWrite[key]
				if last and self.clock - last < 6 - 1e-9 then
					table.insert(self.violations, `cooldown {key} at {self.clock}`)
					return false, "write cooldown"
				end
				backend.lastWrite[key] = self.clock
				table.insert(self.writes, key)
			end
			advance(0.05)
			if self.down then
				return false, "DataStore down"
			end
			local fail = self.failures[key]
			if fail and fail > 0 then
				self.failures[key] = fail - 1
				return false, "injected failure"
			end
			return true, nil
		end
		self.store = {
			get = function(key: string)
				local ok, err = spend("get", key)
				if not ok then
					return false, err
				end
				return true, deepCopy(backend.data[key])
			end,
			set = function(key: string, value: any)
				local ok, err = spend("set", key)
				if not ok then
					return false, err
				end
				backend.data[key] = deepCopy(value)
				return true, nil
			end,
			update = function(key: string, transform: any)
				local ok, err = spend("update", key)
				if not ok then
					return false, err
				end
				local new = transform(deepCopy(backend.data[key]))
				if new ~= nil then
					backend.data[key] = deepCopy(new)
				end
				return true, deepCopy(backend.data[key])
			end,
			remove = function(key: string)
				local ok, err = spend("remove", key)
				if not ok then
					return false, err
				end
				backend.data[key] = nil
				return true, nil
			end,
		}
		self.env = {
			now = function()
				return self.clock
			end,
			budget = function(kind: string): number
				return self.budgets[group(kind)]
			end,
			wait = function(dt: number)
				advance(dt)
			end,
			spawn = function(fn: () -> ())
				fn()
			end,
			time = function(): number
				return 1700000000 + math.floor(self.clock)
			end,
			job = o.job or "server-a",
			random = function(): number
				return 0.5
			end,
		}
		self.saves = CharacterSaves.new(self.store, self.env)
		return self
	end

	local function newRecord(id: number, name: string?): CharacterCodec.Record
		local record = CharacterCodec.new(id, name or `Hero {id}`, D.Classic, Appearance.default(), 1700000000)
		record.slots[1] = Items.newStack(Items.id.Stick, 16)
		return record
	end

	local function stored(backend: any, id: number): (CharacterCodec.Record?, any, any)
		local value = backend.data[CharacterSaves.recordKey(USER, id)]
		local record, progress, lock = CharacterCodec.readValue(value)
		return record, progress, lock
	end

	local function storedIndex(backend: any): CharacterCodec.Index?
		return (CharacterCodec.readIndex(backend.data[CharacterSaves.indexKey(USER)]))
	end

	--[[ Keys and the list ]]

	t.test("character store: keys are the user's, well under 50 characters", function()
		t.eq(CharacterSaves.indexKey(USER), "u1234567")
		t.eq(CharacterSaves.recordKey(USER, 3), "u1234567/c3")
		t.ok(#CharacterSaves.recordKey(99999999999, 4294967295) <= 50)
		t.eq(CharacterSaves.recordKey(-5, 1), "u-5/c1", "Studio's test users")
	end)

	t.test(
		"character store: a list that could not be read is said so; one of another version is never written",
		function()
			local backend = newBackend()
			local a = fakeStore(backend)
			local ok, index, why, fresh = CharacterSaves.readIndex(a.saves, USER)
			t.eq(ok, true)
			t.eq((index :: any).next, 1, "nothing saved: a new list")
			t.eq(fresh, true)
			t.eq(why, nil)
			a.down = true
			local okDown, none, downWhy = CharacterSaves.readIndex(a.saves, USER)
			t.eq(okDown, false, "the store is down: not read")
			t.eq(none, nil)
			t.ok(downWhy ~= nil)
			t.eq(a.calls.get, 4, "one, then three tries")
			t.eq(#a.writes, 0, "nothing written")
			a.down = false
			-- A newer server's list: read as unreadable, and nothing writes over it.
			local newer = { v = 2, next = 5, chars = {} }
			backend.data[CharacterSaves.indexKey(USER)] = newer
			local okNewer, refused, newerWhy = CharacterSaves.readIndex(a.saves, USER)
			t.eq(okNewer, true)
			t.eq(refused, nil)
			t.ok(newerWhy ~= nil)
			a.env.wait(10)
			local touched = CharacterSaves.touch(a.saves, USER, nil, true)
			t.eq(touched, nil, "not touched")
			t.eq(backend.data[CharacterSaves.indexKey(USER)].v, 2, "still the newer one")
			a.env.wait(10)
			local made = CharacterSaves.create(a.saves, USER, newRecord(5), nil, false)
			t.eq(made, nil, "nothing listed over it")
			t.eq(backend.data[CharacterSaves.indexKey(USER)].v, 2, "still the newer one")
		end
	)

	--[[ Creating ]]

	t.test(
		"character store: the record is made before the list; an orphan is taken over; ids never come back",
		function()
			local backend = newBackend()
			local a = fakeStore(backend)
			local _, index = CharacterSaves.readIndex(a.saves, USER)
			local first = newRecord((index :: any).next, "Alice")
			local listed = CharacterSaves.create(a.saves, USER, first, { v = 1, points = 7 }, true) :: any
			t.ok(listed ~= nil)
			t.eq(listed.next, 2)
			t.eq(#listed.chars, 1)
			t.eq(listed.chars[1].name, "Alice")
			local writes = a.writes
			t.eq(writes[1], CharacterSaves.recordKey(USER, 1), "the record first")
			t.eq(writes[2], CharacterSaves.indexKey(USER), "then the list")
			local record, progress, lock = stored(backend, 1)
			t.eq((record :: any).name, "Alice")
			t.eq(progress.points, 7)
			t.eq(lock.job, "server-a", "selected at once: this server's lock")
			-- The list write fails: the record stays unlisted, and the next create of that id takes it.
			a.env.wait(10)
			a.failures[CharacterSaves.indexKey(USER)] = 3
			local orphan = newRecord(2, "Bob")
			local failed, why = CharacterSaves.create(a.saves, USER, orphan, nil, false)
			t.eq(failed, nil)
			t.ok(why ~= nil)
			t.ok(stored(backend, 2) ~= nil, "an orphan record")
			t.eq(#(storedIndex(backend) :: any).chars, 1, "unlisted")
			a.env.wait(10)
			local again = CharacterSaves.create(a.saves, USER, newRecord(2, "Carol"), nil, false) :: any
			t.eq(#again.chars, 2)
			t.eq(((stored(backend, 2)) :: any).name, "Carol", "the orphan written over")
			-- Deleted ids are never used again.
			a.env.wait(10)
			local after = CharacterSaves.delete(a.saves, USER, 2) :: any
			t.eq(#after.chars, 1)
			t.eq(after.next, 3)
			t.eq(backend.data[CharacterSaves.recordKey(USER, 2)], nil, "the record removed")
		end
	)

	t.test("character store: an orphan another server still holds is not written over", function()
		local backend = newBackend()
		local b = fakeStore(backend, { job = "server-b" })
		backend.data[CharacterSaves.recordKey(USER, 1)] =
			CharacterCodec.value(newRecord(1, "Held"), nil, { job = "server-b", at = b.env.time() })
		local a = fakeStore(backend, { job = "server-a", clock = 5 })
		local made, why = CharacterSaves.create(a.saves, USER, newRecord(1, "New"), nil, true)
		t.eq(made, nil)
		t.eq(why, CharacterSaves.ELSEWHERE)
		t.eq(((stored(backend, 1)) :: any).name, "Held")
	end)

	t.test("character store: a user keeps at most Characters.MAX", function()
		local backend = newBackend()
		local a = fakeStore(backend)
		for i = 1, Characters.MAX do
			local listed = CharacterSaves.create(a.saves, USER, newRecord(i), nil, false)
			t.ok(listed ~= nil, `character {i}`)
		end
		local full, why = CharacterSaves.create(a.saves, USER, newRecord(Characters.MAX + 1), nil, false)
		t.eq(full, nil)
		t.eq(why, CharacterSaves.FULL)
		t.eq(#(storedIndex(backend) :: any).chars, Characters.MAX)
		t.eq(#a.violations, 0, `within the budgets and the 6 s a key: {a.violations[1]}`)
	end)

	--[[ Selecting, saving and locks ]]

	t.test(
		"character store: selecting takes the lock and keeps the bytes; another server's live lock refuses",
		function()
			local backend = newBackend()
			local a = fakeStore(backend, { job = "server-a" })
			CharacterSaves.create(a.saves, USER, newRecord(1, "Alice"), { v = 1, points = 3 }, false)
			local before = backend.data[CharacterSaves.recordKey(USER, 1)].data
			local status, record, progress = CharacterSaves.select(a.saves, USER, 1)
			t.eq(status, "ok")
			t.eq((record :: any).name, "Alice")
			t.eq((progress :: any).points, 3)
			local value = backend.data[CharacterSaves.recordKey(USER, 1)]
			t.eq(value.lock.job, "server-a")
			t.eq(value.data, before, "the bytes exactly as stored")
			-- Server B, while A's lock is live: busy, nothing written.
			local b = fakeStore(backend, { job = "server-b", clock = a.clock + 10 })
			local busy = CharacterSaves.select(b.saves, USER, 1)
			t.eq(busy, "busy")
			t.eq(backend.data[CharacterSaves.recordKey(USER, 1)].lock.job, "server-a")
			-- A stale lock (A crashed: no heartbeat for LockTimeout) is taken.
			local c = fakeStore(backend, { job = "server-c", clock = a.clock + TIMEOUT + 5 })
			local taken = CharacterSaves.select(c.saves, USER, 1)
			t.eq(taken, "ok")
			t.eq(backend.data[CharacterSaves.recordKey(USER, 1)].lock.job, "server-c")
			t.eq(CharacterSaves.select(c.saves, USER, 99), "missing")
			backend.data[CharacterSaves.recordKey(USER, 7)] = { v = 2, data = "x" }
			local damaged, _, _, why = CharacterSaves.select(c.saves, USER, 7)
			t.eq(damaged, "damaged")
			t.ok(why ~= nil)
			t.eq(backend.data[CharacterSaves.recordKey(USER, 7)].v, 2, "never written over")
		end
	)

	t.test("character store: a released character is taken at once; a lost lock stops saving", function()
		local backend = newBackend()
		local a = fakeStore(backend, { job = "server-a" })
		CharacterSaves.create(a.saves, USER, newRecord(1, "Alice"), nil, true)
		local record = newRecord(1, "Alice")
		record.deaths = 3
		a.env.wait(10)
		t.eq(CharacterSaves.save(a.saves, USER, 1, record, nil, 1, true), "ok", "the last save gives it back")
		local value = backend.data[CharacterSaves.recordKey(USER, 1)]
		t.eq(value.lock.released, true)
		t.eq(((stored(backend, 1)) :: any).deaths, 3)
		local b = fakeStore(backend, { job = "server-b", clock = a.clock + 1 })
		t.eq(CharacterSaves.select(b.saves, USER, 1), "ok", "released: B takes it at once")
		-- A writes again (stalled, then woke): its lock is gone, nothing is written.
		local stale = newRecord(1, "Alice")
		stale.deaths = 99
		a.env.wait(10)
		t.eq(CharacterSaves.save(a.saves, USER, 1, stale, nil, 2), "lost")
		t.eq(((stored(backend, 1)) :: any).deaths, 3, "B's record stays")
		t.eq(backend.data[CharacterSaves.recordKey(USER, 1)].lock.job, "server-b")
		-- B's own saves renew its lock.
		b.env.wait(60)
		t.eq(CharacterSaves.save(b.saves, USER, 1, nil, nil, 1), "ok", "a lock-only renewal")
		t.eq(backend.data[CharacterSaves.recordKey(USER, 1)].lock.at, b.env.time())
		-- A newer server's value is never written over.
		backend.data[CharacterSaves.recordKey(USER, 1)].v = 2
		b.env.wait(10)
		t.eq(CharacterSaves.save(b.saves, USER, 1, record, nil, 2), "lost")
	end)

	t.test("character store: an older capture never writes over a newer one", function()
		local backend = newBackend()
		local a = fakeStore(backend)
		CharacterSaves.create(a.saves, USER, newRecord(1), nil, true)
		local newer = newRecord(1)
		newer.played = 600
		local older = newRecord(1)
		older.played = 300
		a.env.wait(10)
		t.eq(CharacterSaves.save(a.saves, USER, 1, newer, nil, 5), "ok")
		t.eq(CharacterSaves.save(a.saves, USER, 1, older, nil, 4), "skipped")
		t.eq(((stored(backend, 1)) :: any).played, 600)
		-- The newest order's own retry still writes; a failed write is tried again (three tries).
		a.failures[CharacterSaves.recordKey(USER, 1)] = 2
		newer.played = 700
		t.eq(CharacterSaves.save(a.saves, USER, 1, newer, nil, 5), "ok")
		t.eq(((stored(backend, 1)) :: any).played, 700)
		a.failures[CharacterSaves.recordKey(USER, 1)] = 3
		newer.played = 800
		t.eq(CharacterSaves.save(a.saves, USER, 1, newer, nil, 6), "failed", "given up after three")
		t.eq(((stored(backend, 1)) :: any).played, 700)
	end)

	t.test("character store: a rejoin to the same server waits for the last save of its character", function()
		-- The player leaves: their character's last save (a release) fails once and backs off; they
		-- rejoin this server meanwhile. This server's own lock counts as free, so the select must
		-- wait for that save, else it would load the record from before it and every later save
		-- of the stale copy would be refused ("lost").
		local backend = newBackend()
		local a = fakeStore(backend, { job = "server-a" })
		CharacterSaves.create(a.saves, USER, newRecord(1, "Alice"), nil, true)
		local key = CharacterSaves.recordKey(USER, 1)
		local before = newRecord(1, "Alice")
		before.slots[2] = Items.newStack(Items.id.Diamond, 10)
		a.env.wait(10)
		t.eq(CharacterSaves.save(a.saves, USER, 1, before, nil, 1), "ok", "an autosave with 10 diamonds")
		-- (The diamonds go into a chest; the player leaves with none.)
		local left = newRecord(1, "Alice")
		a.env.wait(10)
		a.failures[key] = 1
		local during: any = nil
		local update = a.store.update
		a.store.update = function(k: string, transform: any)
			if k == key and during == nil then
				-- (The rejoined session asks while the release backs off.)
				during = {}
				local status, _, _, why = CharacterSaves.select(a.saves, USER, 1)
				local renamed, renameWhy = CharacterSaves.rename(a.saves, USER, 1, "Zed")
				during[1], during[4], during.renamed, during.renameWhy = status, why, renamed, renameWhy
			end
			return update(k, transform)
		end
		t.eq(CharacterSaves.save(a.saves, USER, 1, left, nil, 2, true), "ok", "the release, on its second try")
		a.store.update = update
		t.eq(during[1], "busy", "the rejoin waits for it")
		t.eq(during[4], CharacterSaves.STILL_SAVING)
		t.eq(during.renamed, nil, "no rename meanwhile either")
		t.eq(during.renameWhy, CharacterSaves.STILL_SAVING)
		t.eq(backend.data[key].lock.released, true)
		t.eq(a.saves.releasing[key], nil, "done")
		-- Asked again: the record as the release left it, and its saves go on.
		a.env.wait(10)
		local status, record = CharacterSaves.select(a.saves, USER, 1)
		t.eq(status, "ok")
		t.eq((record :: any).slots[2], nil, "no diamonds: they are in the chest")
		a.env.wait(10)
		t.eq(CharacterSaves.save(a.saves, USER, 1, record, nil, 3), "ok", "not lost")
		-- A release that fails for good also lets the next select through.
		a.env.wait(10)
		a.failures[key] = 3
		t.eq(CharacterSaves.save(a.saves, USER, 1, record, nil, 4, true), "failed")
		t.eq(a.saves.releasing[key], nil)
		a.env.wait(10)
		t.eq((CharacterSaves.select(a.saves, USER, 1)), "ok")
	end)

	t.test("character store: a visit that stopped being fair keeps the things it had then", function()
		-- (Players/CharacterStore: creative or a world that doesn't save progress; the things are
		-- copies, so the live inventory changing later doesn't reach them.)
		local frozen = newRecord(1, "Alice")
		frozen.slots[5] = Items.newStack(Items.id.IronIngot, 3)
		frozen.accessories[1] = Items.newStack(Items.id.HermesBoots, 1)
		frozen.vanityArmor[1] = Items.newStack(Items.id.TopHat, 1)
		frozen.cursor = Items.newStack(Items.id.Stick, 2)
		frozen.crystals, frozen.mana, frozen.hidden, frozen.selected = 2, 40, 0x0101, 4
		frozen.effects = { { effect = 1, amplifier = 0, ticks = 200, ambient = false } }
		local kept = CharacterCodec.new(1, "Alice", D.Classic, Appearance.default(), 0)
		CharacterCodec.keepThings(kept, frozen)
		frozen.slots[5].count = 64
		frozen.slots[6] = Items.newStack(Items.id.Diamond, 64)
		frozen.accessories[2] = Items.newStack(Items.id.CloudInABottle, 1)
		frozen.crystals = 9
		frozen.effects[1].ticks = 9999
		-- A later capture (live things: creative stacks) saved with the kept things instead.
		local live = newRecord(1, "Alice")
		live.slots[6] = Items.newStack(Items.id.Diamond, 64)
		live.accessories[2] = Items.newStack(Items.id.ManaCrystal, 1)
		live.crystals, live.deaths, live.played = 9, 3, 500
		CharacterCodec.keepThings(live, kept)
		t.eq(live.slots[5].count, 3, "as it was then")
		t.eq(live.slots[6], nil, "nothing made since")
		t.eq(live.accessories[1].item, Items.id.HermesBoots)
		t.eq(live.accessories[2], nil)
		t.eq(live.vanityArmor[1].item, Items.id.TopHat)
		t.eq(live.cursor.count, 2)
		t.eq(live.crystals, 2)
		t.eq(live.mana, 40)
		t.eq(live.hidden, 0x0101)
		t.eq(live.selected, 4)
		t.eq(live.effects[1].ticks, 200)
		t.eq(live.deaths, 3, "the rest is the character's now")
		t.eq(live.played, 500)
		t.ok(live.slots[5] ~= kept.slots[5], "copies: the kept things stay as they were")
		local back = CharacterCodec.fromText(CharacterCodec.toText(live)) :: any
		t.eq(back.slots[5].count, 3)
	end)

	--[[ Deleting and renaming ]]

	t.test("character store: delete and rename wait for another server's lock; the list goes first", function()
		local backend = newBackend()
		local a = fakeStore(backend, { job = "server-a" })
		CharacterSaves.create(a.saves, USER, newRecord(1, "Alice"), nil, false)
		CharacterSaves.create(a.saves, USER, newRecord(2, "Bob"), nil, false)
		local b = fakeStore(backend, { job = "server-b", clock = a.clock + 1 })
		t.eq(CharacterSaves.select(b.saves, USER, 1), "ok")
		a.env.wait(10)
		local refused, why = CharacterSaves.delete(a.saves, USER, 1)
		t.eq(refused, nil)
		t.eq(why, CharacterSaves.ELSEWHERE)
		local notRenamed, renameWhy = CharacterSaves.rename(a.saves, USER, 1, "Zed")
		t.eq(notRenamed, nil)
		t.eq(renameWhy, CharacterSaves.ELSEWHERE)
		t.eq(((stored(backend, 1)) :: any).name, "Alice")
		-- Bob is free: renamed in the record and the list.
		local renamed = CharacterSaves.rename(a.saves, USER, 2, "Robert") :: any
		t.ok(renamed ~= nil)
		t.eq(((stored(backend, 2)) :: any).name, "Robert")
		local names = {}
		for _, line in renamed.chars do
			names[line.id] = line.name
		end
		t.eq(names[2], "Robert")
		-- Deleting: the list first, then the record.
		a.env.wait(10)
		local before = #a.writes
		local after = CharacterSaves.delete(a.saves, USER, 2) :: any
		t.eq(#after.chars, 1)
		t.eq(a.writes[before + 1], CharacterSaves.indexKey(USER), "the list first")
		t.eq(a.writes[before + 2], CharacterSaves.recordKey(USER, 2), "then the record")
		-- Once B released Alice, she can go.
		b.env.wait(10)
		CharacterSaves.save(b.saves, USER, 1, nil, nil, 1, true)
		a.env.wait(10)
		t.ok(CharacterSaves.delete(a.saves, USER, 1) ~= nil)
		t.eq(#(storedIndex(backend) :: any).chars, 0)
	end)

	t.test("character store: a touch rewrites a character's line and marks the migration", function()
		local backend = newBackend()
		local a = fakeStore(backend)
		local record = newRecord(1, "Alice")
		CharacterSaves.create(a.saves, USER, record, nil, false)
		t.eq((storedIndex(backend) :: any).migrated, false)
		record.played = 3600
		record.lastPlayed = 1800000000
		a.env.wait(10)
		local touched = CharacterSaves.touch(a.saves, USER, CharacterCodec.summary(record), true) :: any
		t.eq(touched.chars[1].played, 3600)
		t.eq(touched.migrated, true)
		local back = storedIndex(backend) :: any
		t.eq(back.chars[1].played, 3600)
		t.eq(back.chars[1].lastPlayed, 1800000000)
		t.eq(back.migrated, true)
		-- Nothing to change: nothing written.
		a.env.wait(10)
		local before = #a.writes
		CharacterSaves.touch(a.saves, USER, nil, true)
		t.eq(#a.writes, before + 1, "an UpdateAsync")
		t.eq(backend.data[CharacterSaves.indexKey(USER)].migrated, true)
	end)

	--[[ Session only ]]

	t.test("character store: session-only characters live in memory, with the same rules", function()
		local fake = fakeStore(newBackend())
		local saves = CharacterSaves.new(CharacterSaves.memoryStore(), fake.env, { cooldown = 0 })
		local ok, index = CharacterSaves.readIndex(saves, USER)
		t.eq(ok, true)
		t.eq((index :: any).next, 1)
		local listed = CharacterSaves.create(saves, USER, newRecord(1, "Temp"), nil, true) :: any
		t.eq(#listed.chars, 1)
		local status, record = CharacterSaves.select(saves, USER, 1)
		t.eq(status, "ok")
		t.eq((record :: any).name, "Temp")
		record = record :: any
		record.deaths = 2
		t.eq(CharacterSaves.save(saves, USER, 1, record, nil, 1, true), "ok")
		local _, again = CharacterSaves.select(saves, USER, 1)
		t.eq((again :: any).deaths, 2)
		t.eq(fake.calls.get + fake.calls.update, 0, "no DataStore request")
		t.ok(SaveLock.read({ job = "x", at = 1 }) ~= nil)
	end)
end
