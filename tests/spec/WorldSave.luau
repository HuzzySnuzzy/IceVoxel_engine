--[[
	Saving worlds (server Save/, World/WorldSave): the bytes (SaveCodec: numbers, stacks, base85
	text JSON never escapes), regions (RegionCodec: edit runs, every record, ids from a newer
	version dropped, damaged bytes refused, parts near the 4 MB a key holds), players
	(PlayerCodec), the records and keys (WorldMeta), locks (SaveLock), the write scheduler within
	Roblox's budgets and the 6 s per key (SaveScheduler, against a fake DataStore), the world's
	state to regions and back through the real server systems (WorldSnapshot: a generated chunk
	with its loaded edits is the chunk before saving; chests, furnaces, machines, pipes, tanks,
	transporters, structure blocks, items, animals, block updates), and the store's rules
	(WorldStore: save -> load, a failed load never written over, one server per world, the
	world's most, retries; owners, full lists, the lock kept through a long load and looked at
	before saving, two servers' parts never joined, players' records in order, what a newer
	version saved never written back, block updates waiting for their chunk), with the sizes a
	typical edited area takes.
]]

return function(t, shared, require, server, client)
	local Blocks = require(shared.Blocks)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Config = require(shared.Config)
	local Coords = require(shared.World.Coords)
	local GameMode = require(shared.GameMode)
	local Items = require(shared.Items)
	local Machines = require(shared.Machines)
	local MobList = require(shared.Entities.MobList)
	local SaveText = require(shared.SaveText)
	local Settings = require(shared.Structures.Settings)
	local WorldSettings = require(shared.WorldSettings)

	local WorldServer = require(server.World.WorldServer)
	local BlockTicker = require(server.World.BlockTicker)
	local Containers = require(server.Players.Containers)
	local TransmitterWorld = require(server.Transmitters.TransmitterWorld)
	local MachineWorld = require(server.Machines.MachineWorld)
	local StructureStore = require(server.Structures.StructureStore)
	local EntityWorld = require(server.Entities.EntityWorld)
	local MobWorld = require(server.Mobs.MobWorld)
	local SaveCodec = require(server.Save.SaveCodec)
	local RegionCodec = require(server.Save.RegionCodec)
	local PlayerCodec = require(server.Save.PlayerCodec)
	local WorldMeta = require(server.Save.WorldMeta)
	local SaveLock = require(server.Save.SaveLock)
	local SaveScheduler = require(server.Save.SaveScheduler)
	local SaveCommand = require(server.Save.SaveCommand)
	local WorldSnapshot = require(server.Save.WorldSnapshot)
	local WorldStore = require(server.Save.WorldStore)

	local id = Blocks.id
	local AIR, STONE = Blocks.AIR, id.Stone
	local FLOOR = 10
	local CROP = 32
	local REGION = RegionCodec.blocks()

	-- A flat stone world (y < FLOOR stone), as the Server spec's.
	local flat = {
		generate = function(level: number, nx: number, nz: number)
			local data = ChunkLayout.create(CROP)
			for y = 0, FLOOR - 1 do
				for i = 0, ChunkLayout.LAYER - 1 do
					buffer.writeu16(data, (y * ChunkLayout.LAYER + i) * 2, STONE)
				end
			end
			return {
				data = data,
				level = level,
				nx = nx,
				nz = nz,
				height = CROP,
				solidBelow = FLOOR,
				emptyAbove = FLOOR,
			}
		end,
		column = function()
			return FLOOR, 1, 0, STONE
		end,
		findSpawn = function()
			return 0, FLOOR, 0
		end,
	}

	local function lcg(seed: number): () -> number
		local state = seed
		return function(): number
			state = (state * 1103515245 + 12345) % 2147483648
			return state / 2147483648
		end
	end

	local function sameStack(a: any, b: any): boolean
		if a == nil or b == nil then
			return a == b
		end
		return a.item == b.item
			and a.count == b.count
			and (a.damage or 0) == (b.damage or 0)
			and Items.sameData(a.data, b.data)
	end

	local function sameBuffer(a: buffer, b: buffer): boolean
		if buffer.len(a) ~= buffer.len(b) then
			return false
		end
		for i = 0, buffer.len(a) - 1 do
			if buffer.readu8(a, i) ~= buffer.readu8(b, i) then
				return false
			end
		end
		return true
	end

	--[[ A server's systems on a flat world, wired as the boot script wires them. ]]
	local function newGame(seed: number?)
		local world = WorldServer.new(flat :: any)
		local containers = Containers.new()
		local function knownBlock(x: number, y: number, z: number): number?
			local block = world:peekBlock(x, y, z)
			if block ~= nil then
				return block
			end
			local cx, cz, lx, lz = Coords.blockToChunk(x, z)
			local edits = world:chunkEdits(cx, cz)
			return if edits then edits[ChunkLayout.localIndex(lx, y, lz)] else nil
		end
		local pipes = TransmitterWorld.new({ getBlock = knownBlock, containers = containers })
		local machines = MachineWorld.new({ getBlock = knownBlock, containers = containers, transmitters = pipes })
		local structures = StructureStore.new()
		local items = EntityWorld.new(function(x: number, y: number, z: number): number?
			return world:peekBlock(x, y, z)
		end, { maxItems = 1000, lifetimeTicks = 6000 })
		local mobs = MobWorld.new(function(x: number, y: number, z: number): number?
			return world:peekBlock(x, y, z)
		end, { maxMobs = 50, forgetTicks = 6000, random = lcg(seed or 7) })
		local ticker = BlockTicker.new(world, {}, 1000)
		world.onChanged = function(x, y, z, old, new)
			TransmitterWorld.blockChanged(pipes, x, y, z, old, new)
			MachineWorld.blockChanged(machines, x, y, z, old, new)
			structures:blockChanged(x, y, z, old, new)
		end
		return {
			world = world,
			containers = containers,
			transmitters = pipes,
			machines = machines,
			structures = structures,
			items = items,
			mobs = mobs,
			ticker = ticker,
		}
	end

	-- Encodes, decodes and returns the regions `collect` made (as a load gets them).
	local function throughBytes(regions: { [string]: any }): { any }
		local loaded = {}
		for name, region in regions do
			local rx, rz = RegionCodec.parseName(name)
			local bytes = RegionCodec.encode(region)
			local text = RegionCodec.split(bytes, 4000000)
			local back = RegionCodec.tryDecode(RegionCodec.join(text) :: buffer, rx, rz)
			assert(back, `region {name} decodes`)
			table.insert(loaded, back)
		end
		return loaded
	end

	--[[ A fake DataStore: budgets, the 6 s per key, latency, failures, JSON sizes ]]

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

	local function jsonLength(value: any): number
		if type(value) == "string" then
			return #value + 2
		elseif type(value) == "number" then
			return #tostring(value)
		elseif type(value) == "boolean" then
			return 5
		elseif type(value) == "table" then
			local n = 2
			for k, v in value do
				n += jsonLength(tostring(k)) + 1 + jsonLength(v) + 1
			end
			return n
		end
		return 4
	end

	local function newBackend()
		return { data = {}, lastWrite = {} }
	end

	-- A server's view of `backend` (shared between servers): its own budgets, clock and job.
	local function fakeStore(backend: any, options: any?)
		local o = options or {}
		local players = o.players or 0
		local cap = 60 + 10 * players
		local rate = cap / 60
		local self: any = {
			clock = o.clock or 0,
			budgets = { get = cap, set = cap, update = cap },
			violations = {},
			calls = { get = 0, set = 0, update = 0, remove = 0 },
			failures = {},
			down = false,
			latency = o.latency or 0.05,
			largest = 0,
			writes = {},
		}
		local function advance(dt: number)
			self.clock += dt
			for kind, value in self.budgets do
				self.budgets[kind] = math.min(cap, value + dt * rate)
			end
		end
		self.advance = advance
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
					table.insert(self.violations, `cooldown {key} at {self.clock} (last {last})`)
					return false, "write cooldown"
				end
				backend.lastWrite[key] = self.clock
				table.insert(self.writes, key)
			end
			advance(self.latency)
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
		local function check(value: any)
			local size = jsonLength(value)
			self.largest = math.max(self.largest, size)
			if size > Config.Save.KeyLimit then
				table.insert(self.violations, `a value of {size} characters`)
			end
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
				check(value)
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
					check(new)
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
			random = lcg(o.seed or 3),
		}
		return self
	end

	local function settings(name: string?): any
		return {
			name = name or "Island",
			gameMode = GameMode.SURVIVAL,
			difficulty = 2,
			allowCommands = false,
			worldType = "default",
			options = { structures = true },
			seed = 9007199254740991,
		}
	end

	--[[ Bytes ]]

	t.test("world save: numbers, varints and texts round trip", function()
		local w = SaveCodec.writer(4)
		local values = { 0, 1, 127, 128, 255, 16383, 16384, 2 ^ 31, 2 ^ 40 + 3, 2 ^ 53 }
		for _, value in values do
			SaveCodec.varint(w, value)
		end
		for _, value in { 0, -1, 1, -64, 64, -1000000, 1000000 } do
			SaveCodec.zigzag(w, value)
		end
		SaveCodec.u8(w, 200)
		SaveCodec.u16(w, 65535)
		SaveCodec.i32(w, -123456)
		SaveCodec.f32(w, 1.5)
		SaveCodec.f64(w, math.huge)
		SaveCodec.text(w, "héllo")
		local r = SaveCodec.reader(SaveCodec.finish(w))
		for _, value in values do
			t.eq(SaveCodec.readVarint(r), value, "varint")
		end
		for _, value in { 0, -1, 1, -64, 64, -1000000, 1000000 } do
			t.eq(SaveCodec.readZigzag(r), value, "zigzag")
		end
		t.eq(SaveCodec.readU8(r), 200)
		t.eq(SaveCodec.readU16(r), 65535)
		t.eq(SaveCodec.readI32(r), -123456)
		t.eq(SaveCodec.readF32(r), 1.5)
		t.eq(SaveCodec.readF64(r), math.huge)
		t.eq(SaveCodec.readText(r), "héllo")
		t.ok(SaveCodec.atEnd(r))
		t.ok(not pcall(SaveCodec.readU8, r), "reading past the end errors")
		t.eq(SaveCodec.varint(SaveCodec.writer(), 1) == nil, true)
		t.ok(not pcall(SaveCodec.varint, SaveCodec.writer(), -1), "a negative varint is a bug")
	end)

	t.test("world save: base85 round trips every length and stays clear of JSON's escapes", function()
		t.eq(#SaveCodec.ALPHABET, 85)
		for _, banned in { '"', "\\", "/", "<", ">", "&", "'", "`", " ", "~" } do
			t.ok(string.find(SaveCodec.ALPHABET, banned, 1, true) == nil, `no {banned}`)
		end
		local random = lcg(11)
		for length = 0, 23 do
			local b = buffer.create(length)
			for i = 0, length - 1 do
				buffer.writeu8(b, i, math.floor(random() * 256))
			end
			local text = SaveCodec.toText(b)
			t.eq(#text, SaveCodec.textLength(length), `length {length}`)
			local back = SaveCodec.fromText(text)
			t.ok(back and sameBuffer(back, b), `round trip of {length} bytes`)
		end
		-- All ones and all zeros (the largest and smallest groups).
		local ones = buffer.create(9)
		buffer.fill(ones, 0, 255)
		t.ok(sameBuffer(SaveCodec.fromText(SaveCodec.toText(ones)) :: buffer, ones))
		t.eq(SaveCodec.fromText("abc\\d"), nil, "a character outside the alphabet")
		t.eq(SaveCodec.fromText("abcdef"), nil, "a group cut to one character")
		t.eq(SaveCodec.fromText("}}}}}"), nil, "a group over 2^32")
	end)

	t.test("world save: stacks keep wear and item data, unknown items drop", function()
		local data = Items.cleanData({ fluid = 1, amount = 4000, name = "tank" })
		local stacks = {
			Items.newStack(id.Stone, 64),
			Items.newStack(Items.id.IronIngot, 3),
			Items.newStack(id.Chest, 1, nil, data),
		}
		local pick = Items.find("WoodenPickaxe") or Items.find("StonePickaxe")
		if pick then
			table.insert(stacks, Items.newStack(pick, 1, 17))
		end
		local w = SaveCodec.writer()
		for _, stack in stacks do
			SaveCodec.stack(w, stack)
		end
		SaveCodec.stack(w, nil)
		-- An item id this version doesn't know.
		SaveCodec.u16(w, 65000)
		SaveCodec.varint(w, 1)
		SaveCodec.varint(w, 0)
		SaveCodec.u8(w, 0)
		local r = SaveCodec.reader(SaveCodec.finish(w))
		for _, stack in stacks do
			t.ok(sameStack(SaveCodec.readStack(r), stack), "stack")
		end
		t.eq(SaveCodec.readStack(r), nil, "empty")
		t.eq(SaveCodec.readStack(r), nil, "unknown item dropped")
		t.ok(SaveCodec.atEnd(r))
	end)

	--[[ Regions ]]

	t.test("world save: regions are 32 x 32 chunks, negative ones too", function()
		t.eq(Config.Save.RegionChunks, 32)
		t.eq(REGION, 512)
		t.eq(select(1, RegionCodec.regionOf(0, 0)), 0)
		t.eq(select(1, RegionCodec.regionOf(31, 0)), 0)
		t.eq(select(1, RegionCodec.regionOf(32, 0)), 1)
		t.eq(select(1, RegionCodec.regionOf(-1, 0)), -1)
		t.eq(select(2, RegionCodec.regionOf(0, -33)), -2)
		t.eq(select(1, RegionCodec.regionOfBlock(-1, 0)), -1)
		t.eq(select(1, RegionCodec.regionOfBlock(511, 0)), 0)
		t.eq(RegionCodec.name(-3, 4), "-3_4")
		local rx, rz = RegionCodec.parseName("-3_4")
		t.eq(rx, -3)
		t.eq(rz, 4)
		t.eq((RegionCodec.parseName("x_4")), nil)
		local key = WorldMeta.partKey("w12345678", RegionCodec.name(-1954, -1954), 1, 9)
		t.ok(#key <= 50, `keys fit DataStore's 50 characters ({key})`)
	end)

	t.test("world save: a region's every record round trips", function()
		local region = RegionCodec.new(-1, 2)
		local x0, z0 = -REGION, 2 * REGION
		local cx, cz = x0 // 16, z0 // 16
		local key = Coords.chunkKey(cx, cz)
		local edits = {}
		-- A whole layer of one block (one run), a tunnel row, scattered blocks, a top cell.
		for i = 0, 255 do
			edits[ChunkLayout.localIndex(i % 16, 12, i // 16)] = id.Planks
		end
		for lx = 0, 15 do
			edits[ChunkLayout.localIndex(lx, 5, 7)] = AIR
		end
		edits[ChunkLayout.localIndex(3, 40, 9)] = id.OakLeaves
		edits[ChunkLayout.localIndex(15, Config.WorldHeight - 1, 15)] = id.Glass
		region.chunks[key] = edits
		region.chunks[Coords.chunkKey(cx + 31, cz + 31)] = { [0] = id.Sand }
		local chest = {
			kind = "chest",
			block = id.Chest,
			size = 27,
			slots = { [1] = Items.newStack(id.Stone, 64), [27] = Items.newStack(Items.id.IronIngot, 5) },
			data = nil,
		}
		table.insert(region.containers, { x = x0 + 1, y = 11, z = z0 + 2, container = chest })
		local furnace = {
			kind = "furnace",
			block = id.Furnace,
			size = 3,
			slots = { [2] = Items.newStack(Items.id.Coal, 8) },
			data = { 120, 1600, 33, 200, Items.id.IronIngot },
		}
		table.insert(region.containers, { x = x0 + 5, y = 11, z = z0 + 2, container = furnace })
		table.insert(region.sourced, Coords.posKey(x0 + 9, 30, z0 + 9))
		local structure = Settings.defaultStructure("save")
		structure.name = "house"
		structure.size = { 9, 5, 9 }
		table.insert(region.structures, { x = x0 + 20, y = 11, z = z0 + 20, settings = structure })
		local jigsaw = Settings.defaultJigsaw("north")
		jigsaw.pool = "village/houses"
		table.insert(region.jigsaws, { x = x0 + 21, y = 11, z = z0 + 20, settings = jigsaw })
		table.insert(
			region.pipes,
			{ x = x0 + 30, y = 11, z = z0 + 30, modes = 1234, colour = 0, fluid = 1, amount = 600 }
		)
		table.insert(region.tanks, { x = x0 + 31, y = 11, z = z0 + 30, fluid = 2, amount = 14000 })
		table.insert(
			region.transport,
			{ x = x0 + 32, y = 11, z = z0 + 30, colour = 4, stack = Items.newStack(id.Sand, 16) }
		)
		table.insert(
			region.items,
			{ x = x0 + 0.25, y = 10.5, z = z0 + 7.75, stack = Items.newStack(id.Stone, 3), age = 4321, pickupDelay = 9 }
		)
		local cow = MobList.find("Cow") :: number
		table.insert(
			region.mobs,
			{ kind = cow, variant = 0, x = x0 + 3.5, y = 10, z = z0 + 3.5, yaw = 1.25, health = 7 }
		)
		table.insert(region.ticks, { x = x0 + 4, y = 12, z = z0 + 4, delay = 5 })

		local bytes = RegionCodec.encode(region)
		t.ok(sameBuffer(RegionCodec.encode(region), bytes), "the same region encodes alike")
		local back = RegionCodec.decode(bytes, -1, 2)
		t.eq(back.rx, -1)
		t.eq(back.rz, 2)
		t.eq(RegionCodec.editCount(back), RegionCodec.editCount(region), "edits")
		for chunk, list in region.chunks do
			for index, block in list do
				t.eq(back.chunks[chunk][index], block, "edit")
			end
		end
		t.eq(#back.containers, 2)
		for i, entry in region.containers do
			local got = back.containers[i]
			t.eq(got.x, entry.x)
			t.eq(got.z, entry.z)
			t.eq(got.container.kind, entry.container.kind)
			t.eq(got.container.size, entry.container.size)
			for slot = 1, entry.container.size do
				t.ok(sameStack(got.container.slots[slot], entry.container.slots[slot]), "slot")
			end
		end
		t.eq(back.containers[2].container.data[3], 33, "furnace progress")
		t.eq(back.sourced[1], region.sourced[1])
		t.ok(Settings.sameStructure(back.structures[1].settings, structure), "structure block")
		t.eq(back.jigsaws[1].settings.pool, "village/houses")
		t.eq(back.pipes[1].modes, 1234)
		t.eq(back.pipes[1].amount, 600)
		t.eq(back.tanks[1].amount, 14000)
		t.eq(back.transport[1].colour, 4)
		t.eq(back.items[1].age, 4321)
		t.eq(back.items[1].x, x0 + 0.25)
		t.eq(back.mobs[1].health, 7)
		t.eq(back.ticks[1].delay, 5)
		t.eq(back.dropped, 0)

		-- The wrong key, a newer version, damage and leftovers are refused.
		t.eq((RegionCodec.tryDecode(bytes, 0, 2)), nil, "region under another key")
		local newer = buffer.create(buffer.len(bytes))
		buffer.copy(newer, 0, bytes)
		buffer.writeu8(newer, 0, RegionCodec.VERSION + 1)
		local _, why = RegionCodec.tryDecode(newer)
		t.eq(why, "saved by a newer version")
		local cut = buffer.create(buffer.len(bytes) - 3)
		buffer.copy(cut, 0, bytes, 0, buffer.len(cut))
		t.eq((RegionCodec.tryDecode(cut)), nil, "cut short")
	end)

	t.test("world save: edits of blocks this version doesn't know are dropped, the rest kept", function()
		local region = RegionCodec.new(0, 0)
		region.chunks[Coords.chunkKey(0, 0)] = { [0] = STONE, [1] = 60000, [2] = 60000, [5] = id.Glass }
		local back = RegionCodec.decode(RegionCodec.encode(region))
		t.eq(back.dropped, 2)
		t.eq(back.chunks[Coords.chunkKey(0, 0)][0], STONE)
		t.eq(back.chunks[Coords.chunkKey(0, 0)][1], nil)
		t.eq(back.chunks[Coords.chunkKey(0, 0)][5], id.Glass)
	end)

	t.test("world save: long regions split into parts below a key's 4 MB", function()
		local region = RegionCodec.new(0, 0)
		local random = lcg(5)
		local blocks = { STONE, id.Dirt, id.Glass, id.Sand }
		-- Every cell of 6 chunks a different block from its neighbour: no run compresses.
		for c = 0, 5 do
			local edits = table.create(0)
			for index = 0, 16 * 16 * Config.WorldHeight - 1 do
				edits[index] = blocks[1 + (index + math.floor(random() * 3) + 1) % 4]
			end
			region.chunks[Coords.chunkKey(c, 0)] = edits
		end
		local bytes = RegionCodec.encode(region)
		local maxText, keyLimit = WorldMeta.limits()
		local parts = RegionCodec.split(bytes, maxText)
		print(`    6 fully edited chunks: {buffer.len(bytes)} bytes, {#parts} parts`)
		t.ok(#parts >= 2, "more than one key's worth")
		for _, part in parts do
			t.ok(#part <= maxText, "a part fits its text")
			t.ok(WorldMeta.valueBytes(part) <= keyLimit, "a part's value fits a key")
		end
		local joined = RegionCodec.join(parts)
		t.ok(joined and sameBuffer(joined, bytes), "the parts join back")
		local back = RegionCodec.decode(joined :: buffer)
		t.eq(RegionCodec.editCount(back), 6 * 16 * 16 * Config.WorldHeight)
		-- Small parts too.
		local tiny = RegionCodec.new(3, 3)
		tiny.chunks[Coords.chunkKey(3 * 32, 3 * 32)] = { [0] = STONE, [7] = id.Glass, [300] = id.Sand }
		local small = RegionCodec.split(RegionCodec.encode(tiny), 10)
		t.ok(#small >= 2)
		t.ok(RegionCodec.decode(RegionCodec.join(small) :: buffer, 3, 3) ~= nil)
	end)

	--[[ Players ]]

	t.test("world save: a player's record round trips; damage is refused", function()
		local record = PlayerCodec.new()
		record.position = true
		record.x, record.y, record.z, record.yaw = -1234.5, 87, 99999.25, 2.5
		record.health = 13.5
		record.mode = GameMode.CREATIVE
		record.previous = GameMode.SURVIVAL
		record.selected = 4
		record.slots[1] = Items.newStack(id.Stone, 64)
		record.slots[36] = Items.newStack(id.Chest, 1, nil, Items.cleanData({ amount = 3 }))
		record.armor[2] = Items.newStack(Items.find("IronChestplate") or Items.id.IronIngot, 1, 40)
		record.cursor = Items.newStack(id.Sand, 7)
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
			{ effect = 2, amplifier = 0, ticks = -1, ambient = true },
		}
		local text = PlayerCodec.toText(record)
		local back = PlayerCodec.fromText(text) :: any
		t.ok(back ~= nil)
		t.eq(back.position, true)
		t.eq(back.x, -1234.5)
		t.eq(back.z, 99999.25)
		t.eq(back.yaw, 2.5)
		t.eq(back.health, 13.5)
		t.eq(back.mode, GameMode.CREATIVE)
		t.eq(back.previous, GameMode.SURVIVAL)
		t.eq(back.selected, 4)
		t.ok(sameStack(back.slots[1], record.slots[1]))
		t.ok(sameStack(back.slots[36], record.slots[36]))
		t.ok(sameStack(back.armor[2], record.armor[2]))
		t.ok(sameStack(back.cursor, record.cursor))
		t.eq(back.thirst.hydration, 2.5)
		t.eq(back.temperature.clemency, 4000)
		t.eq(#back.effects, 2)
		t.eq(back.effects[2].ticks, -1)
		t.eq(back.mana, nil, "no mana kept: the player starts full")
		print(`    a player's record: {#text} characters`)
		-- Terraria's mana and Mana Crystals (version 2, characters off): kept, clamped, checked.
		record.mana, record.crystals = 87.25, 4
		local withMana = PlayerCodec.fromText(PlayerCodec.toText(record)) :: any
		t.eq(withMana.mana, 87.25)
		t.eq(withMana.crystals, 4)
		t.eq(#withMana.effects, 2, "the effects after the mana")
		record.mana, record.crystals = 1e9, 99
		local clamped = PlayerCodec.fromText(PlayerCodec.toText(record)) :: any
		t.eq(clamped.mana, Config.Mana.Max)
		t.eq(clamped.crystals, Config.Mana.MaxCrystals)
		record.mana, record.crystals = nil, 0
		-- No position, nothing held: tiny.
		t.ok(#PlayerCodec.toText(PlayerCodec.new()) < 20)
		t.eq((PlayerCodec.fromText("not base85 \\")), nil)
		t.eq((PlayerCodec.fromText(42)), nil)
		local bytes = PlayerCodec.encode(record)
		local damaged = buffer.create(buffer.len(bytes) + 1)
		buffer.copy(damaged, 0, bytes)
		t.eq((PlayerCodec.decode(damaged)), nil, "bytes left over")
	end)

	--[[ Records, sizes and words ]]

	t.test("world save: the world's record keeps settings exactly, refuses newer versions", function()
		local meta = WorldMeta.new("w0000abcd", settings(), 1700000000)
		local stored = WorldMeta.stored(meta)
		local back = WorldMeta.read(deepCopy(stored)) :: any
		t.ok(back ~= nil)
		local s = WorldMeta.settings(back) :: any
		t.eq(s.seed, 9007199254740991, "the seed to 2^53")
		t.eq(s.worldType, "default")
		t.eq(s.options.structures, true)
		t.eq(s.difficulty, 2)
		stored.v = WorldMeta.VERSION + 1
		local none, why = WorldMeta.read(stored)
		t.eq(none, nil)
		t.eq(why, "saved by a newer version")
		t.eq((WorldMeta.read({ v = 1, id = "nope" })), nil, "a bad id")
		local gone = WorldMeta.stored(meta)
		gone.worldType = "spec.gone"
		t.eq((WorldMeta.settings(WorldMeta.read(gone) :: any)), nil, "a world type that is gone")
		-- Characters' entries and the migration's marks are kept, counted and checked (a record
		-- saved before characters reads with none).
		meta.characters[WorldMeta.characterName(42, 3)] = 150
		meta.legacyImported["42"] = 3
		local withCharacters = WorldMeta.read(deepCopy(WorldMeta.stored(meta))) :: any
		t.eq(withCharacters.characters["42_3"], 150)
		t.eq(withCharacters.legacyImported["42"], 3)
		local before = WorldMeta.stored(meta)
		before.characters, before.legacyImported = nil, nil
		local old = WorldMeta.read(before) :: any
		t.eq(next(old.characters), nil)
		t.eq(next(old.legacyImported), nil)
		local damaged = WorldMeta.stored(meta)
		damaged.legacyImported = { ["42"] = -1, ["43"] = "x" }
		t.eq(next((WorldMeta.read(damaged) :: any).legacyImported), nil, "only character ids")
		t.ok(select(1, WorldMeta.total(meta)) >= 150, "the entries count in the world's bytes")
		t.eq(WorldMeta.characterKey("w0000abcd", 42, 3), "w0000abcd/c/42_3")
		local user, char = WorldMeta.parseCharacterName("-5_12")
		t.eq(user, -5, "Studio's test users")
		t.eq(char, 12)
		t.eq((WorldMeta.parseCharacterName("42")), nil)
		t.ok(#WorldMeta.characterKey("w12345678", 99999999999, 4294967295) <= 50)
		-- Ids are unique and short.
		local taken = {}
		local random = lcg(1)
		for _ = 1, 50 do
			local newId = WorldMeta.newId(random, taken)
			t.ok(WorldMeta.validId(newId) and not taken[newId])
			taken[newId] = true
		end
	end)

	t.test("world save: the index lists the last played first and drops bad entries", function()
		local index = WorldMeta.readIndex(nil) :: any
		t.eq(#index.worlds, 0)
		local a = WorldMeta.entry(WorldMeta.new("w000000a1", settings("A"), 100), 1000)
		local b = WorldMeta.entry(WorldMeta.new("w000000b2", settings("B"), 200), 2000)
		index = WorldMeta.withEntry(WorldMeta.withEntry(index, a), b)
		t.eq(index.worlds[1].name, "B")
		a.lastPlayed = 300
		index = WorldMeta.withEntry(index, a)
		t.eq(index.worlds[1].name, "A", "played again: first")
		t.eq(#index.worlds, 2)
		index = WorldMeta.without(index, "w000000a1")
		t.eq(#index.worlds, 1)
		local read = WorldMeta.readIndex({ v = 1, worlds = { { id = "bad id" }, { id = "w1", name = 5 } } }) :: any
		t.eq(#read.worlds, 1)
		t.eq(read.worlds[1].name, WorldSettings.DEFAULT_NAME)
		t.eq((WorldMeta.readIndex({ v = 99 })), nil, "a newer list")
	end)

	t.test("world save: sizes, limits and the toast's words", function()
		t.eq(WorldMeta.sizeState(10, 100, 0.8), "ok")
		t.eq(WorldMeta.sizeState(80, 100, 0.8), "warn")
		t.eq(WorldMeta.sizeState(101, 100, 0.8), "over")
		t.eq(SaveText.size(1.4 * 1048576), "1.4 MB")
		t.eq(SaveText.size(64 * 1048576), "64 MB")
		t.eq(SaveText.size(12 * 1024), "12 KB")
		t.eq(SaveText.size(300), "300 B")
		t.eq(
			SaveText.saved(1.4 * 1048576, 64 * 1048576, 0.3 * 1048576, 4194304),
			"World saved — 1.4 MB of 64 MB (largest region 0.3 / 4 MB)"
		)
		t.eq(SaveText.megabytes(100), "0.1", "some bytes never read as 0.0")
		t.eq(SaveText.date({ year = 2026, month = 10, day = 7, hour = 9, min = 5 }), "2026-10-07 09:05")
		t.ok(string.find(SaveText.nearing(52 * 1048576, 64 * 1048576), "81%", 1, true) ~= nil)
		t.eq(SaveText.state(0), nil)
		t.ok(SaveText.state(2, "no API access") ~= nil)
		local maxText, keyLimit, maxBytes = WorldMeta.limits()
		t.eq(keyLimit, 4194304)
		t.ok(maxText + WorldMeta.VALUE_OVERHEAD <= keyLimit)
		t.eq(maxBytes, 64 * 1048576)
	end)

	--[[ Locks ]]

	t.test("world save: a live lock blocks, a stale one expires, one's own is renewed", function()
		local timeout = 180
		local lock = SaveLock.acquire(nil, "a", 1000, timeout) :: any
		t.eq(lock.job, "a")
		local refused, why = SaveLock.acquire(lock, "b", 1100, timeout)
		t.eq(refused, nil, "live: refused")
		t.eq(why, "in use by another server")
		t.ok(SaveLock.acquire(lock, "a", 1100, timeout) ~= nil, "its own: taken again")
		local stale = SaveLock.acquire(lock, "b", 1000 + timeout, timeout) :: any
		t.eq(stale.job, "b", "stale after the timeout: taken over")
		local renewed, lost = SaveLock.renew(lock, "a", 1150)
		t.eq(lost, false)
		t.eq((renewed :: any).at, 1150)
		local _, lostToB = SaveLock.renew(stale, "a", 1200)
		t.eq(lostToB, true, "taken over: lost")
		local released = SaveLock.release(lock, "a", 1200) :: any
		t.eq(released.released, true)
		t.eq(SaveLock.isLive(released, 1201, timeout), false, "released: free")
		t.ok(SaveLock.acquire(released, "b", 1201, timeout) ~= nil)
		t.eq(SaveLock.release(lock, "b", 1200), nil, "another's lock is left alone")
		t.eq(SaveLock.isLive({ job = 5 }, 0, timeout), false, "nonsense is no lock")
	end)

	--[[ The scheduler ]]

	t.test("world save: writes stay within the budget and the 6 s a key, retrying failures", function()
		local fake = fakeStore(newBackend(), { players = 0, latency = 0.2 })
		local scheduler = SaveScheduler.new(fake.env, { concurrency = 8 })
		local jobs = {}
		-- 150 writes over 50 keys: three to each key, more than a minute's budget (60).
		for round = 1, 3 do
			for k = 1, 50 do
				local key = `key{k}`
				table.insert(
					jobs,
					SaveScheduler.job(key, "set", function()
						return fake.store.set(key, round)
					end)
				)
			end
		end
		fake.failures["key7"] = 2
		local result = SaveScheduler.run(scheduler, jobs)
		t.eq(#fake.violations, 0, `no budget or cooldown broken: {fake.violations[1]}`)
		t.eq(result.ok, 150)
		t.eq(#result.failed, 0)
		t.ok(fake.clock >= 60, `a minute's budget is 60 writes: {fake.clock} s for 150`)
		-- Retried twice, then written.
		t.eq(jobs[7].attempts, 3)
		-- A key always failing is reported after its attempts.
		fake.failures["always"] = 99
		local always = SaveScheduler.job("always", "set", function()
			return fake.store.set("always", 1)
		end)
		local failed = SaveScheduler.run(scheduler, { always })
		t.eq(#failed.failed, 1)
		t.eq(always.attempts, scheduler.attempts)
		t.eq(#fake.violations, 0)
		-- The deadline stops starting new ones.
		local late = {}
		for k = 1, 100 do
			table.insert(
				late,
				SaveScheduler.job(`late{k}`, "set", function()
					return fake.store.set(`late{k}`, 1)
				end)
			)
		end
		local stopped = SaveScheduler.run(scheduler, late, fake.clock + 5)
		t.eq(stopped.timedOut, true)
		t.ok(#stopped.failed > 0 and stopped.failed[1].err ~= nil)
	end)

	--[[ The world's state and back ]]

	-- A game with something of everything, and what to compare after a load.
	local function furnish(game: any)
		local world = game.world
		local planks = id.Planks
		-- A 9 x 9 x 5 hollow house and a 3 x 3 tunnel 64 blocks long.
		for x = 0, 8 do
			for z = 0, 8 do
				for y = FLOOR, FLOOR + 4 do
					local wall = x == 0 or x == 8 or z == 0 or z == 8 or y == FLOOR + 4
					if wall then
						world:setBlock(x, y, z, planks)
					end
				end
			end
		end
		for x = 20, 83 do
			for y = FLOOR - 4, FLOOR - 2 do
				for z = 1, 3 do
					world:setBlock(x, y, z, AIR)
				end
			end
		end
		world:setBlock(4, FLOOR + 5, 4, id.OakLeaves)
		-- A chest and a furnace.
		world:setBlock(2, FLOOR, 2, id.Chest)
		local chest = game.containers:get(2, FLOOR, 2, id.Chest)
		for slot = 1, 27 do
			chest.slots[slot] = Items.newStack(if slot % 2 == 0 then STONE else id.Sand, slot)
		end
		chest.slots[5] = Items.newStack(id.Chest, 1, nil, Items.cleanData({ amount = 9 }))
		world:setBlock(3, FLOOR, 2, id.Furnace)
		local furnace = game.containers:get(3, FLOOR, 2, id.Furnace)
		furnace.slots[1] = Items.newStack(id.Sand, 10)
		furnace.slots[2] = Items.newStack(Items.id.Coal, 3)
		furnace.data = { 900, 1600, 120, 200, id.Glass }
		game.containers:markActive(3, FLOOR, 2)
		-- A generated chest asked about.
		game.containers.sourced["40,11,40"] = true
		-- A battery with energy.
		world:setBlock(6, FLOOR, 2, id.BasicBattery)
		local battery = (MachineWorld.machine(game.machines, 6, FLOOR, 2) :: any).container
		battery.data[Machines.ENERGY] = 123456
		-- Pipes with water and a tank, a coloured transporter carrying sand.
		for x = 10, 13 do
			world:setBlock(x, FLOOR, 5, id.BasicMechanicalPipe)
		end
		world:setBlock(14, FLOOR, 5, id.BasicFluidTank)
		TransmitterWorld.fillTank(game.transmitters, 14, FLOOR, 5, 1, 12000)
		for _ = 1, 3 do
			TransmitterWorld.step(game.transmitters)
		end
		local network = TransmitterWorld.network(game.transmitters, 10, FLOOR, 5) :: any
		network.fluid = 1
		network.amount = 777
		TransmitterWorld.setMode(game.transmitters, 11, FLOOR, 5, 4, 3)
		world:setBlock(10, FLOOR, 8, id.BasicLogisticalTransporter)
		TransmitterWorld.setColour(game.transmitters, 10, FLOOR, 8, 5)
		local Transport = require(server.Transmitters.Transport)
		Transport.restore(
			game.transmitters,
			TransmitterWorld.node(game.transmitters, 10, FLOOR, 8) :: any,
			Items.newStack(id.Sand, 12) :: any,
			5
		)
		-- A structure block with settings, a jigsaw.
		world:setBlock(16, FLOOR, 16, Blocks.structureBlock("save") :: number)
		local structure = Settings.defaultStructure("save")
		structure.name = "house"
		structure.size = { 9, 5, 9 }
		game.structures:setStructure(16, FLOOR, 16, structure)
		world:setBlock(17, FLOOR, 16, Blocks.jigsawBlock("North", "Up") :: number)
		local jigsaw = table.clone(game.structures:jigsaw(17, FLOOR, 16))
		jigsaw.pool = "village/houses"
		game.structures:setJigsaw(17, FLOOR, 16, jigsaw)
		-- Dropped items, a cow and a zombie (not kept), a block update due.
		local itemId = game.items:spawnItem(STONE, 5, 1.5, FLOOR, 1.5, 0, 0, 0, 10)
		game.items:get(itemId).age = 5000
		local cow = game.mobs:get(game.mobs:spawn(MobList.find("Cow") :: number, 5.5, FLOOR, 5.5, 1, 0.5))
		cow.health = 6
		game.mobs:spawn(MobList.find("Zombie") :: number, 7.5, FLOOR, 7.5)
		game.ticker:schedule(1, FLOOR + 1, 1, 7)
		-- An edit in a far region (negative).
		world:setBlock(-600, FLOOR, -9000, id.Glass)
	end

	t.test("world save: a loaded world is the world that was saved (chunks, containers, machines, pipes...)", function()
		local a = newGame()
		furnish(a)
		local regions, live = WorldSnapshot.collect(a, WorldSnapshot.editedRegions(a.world), nil, true, true)
		local names = {}
		for name in regions do
			table.insert(names, name)
		end
		table.sort(names)
		t.eq(table.concat(names, " "), "-2_-18 0_0", "the regions with something in them")
		t.ok(live["0_0"] and not live["-2_-18"], "state lives in 0_0; -2_-18 only has an edit")
		local loaded = throughBytes(regions)

		local b = newGame()
		WorldSnapshot.applyEdits(b.world, loaded)
		local report = WorldSnapshot.restore(b, loaded)
		-- Chunks: generated + the loaded edits are the chunks before saving.
		for key in a.world.edits do
			local cx, cz = Coords.decodeChunkKey(key)
			local before = a.world:getChunk(cx, cz)
			local after = b.world:getChunk(cx, cz)
			t.eq(after.height, before.height, "height")
			t.ok(sameBuffer(after.data, before.data), `chunk {cx}, {cz} is as it was`)
		end
		-- Containers.
		t.eq(report.containers, 3, "chest, furnace and the battery's")
		local chest = b.containers:peek(2, FLOOR, 2) :: any
		local chestBefore = a.containers:peek(2, FLOOR, 2) :: any
		for slot = 1, 27 do
			t.ok(sameStack(chest.slots[slot], chestBefore.slots[slot]), `chest slot {slot}`)
		end
		local furnace = b.containers:peek(3, FLOOR, 2) :: any
		t.eq(furnace.data[1], 900, "still burning")
		t.eq(furnace.data[3], 120, "cook progress")
		t.ok(b.containers.active["3,10,2"], "it cooks on")
		t.ok(b.containers.sourced["40,11,40"], "the generated chest stays looted")
		-- Machines.
		t.eq(report.machines, 1)
		local machine = MachineWorld.machine(b.machines, 6, FLOOR, 2) :: any
		t.ok(machine ~= nil)
		t.eq(machine.container.data[Machines.ENERGY], 123456, "its energy")
		t.eq(machine.container, b.containers:peek(6, FLOOR, 2), "the machine took its restored container")
		-- Pipes: modes, colours, the water in the pipes and the tank, the transporter's sand.
		t.eq(
			(TransmitterWorld.state(b.transmitters, 11, FLOOR, 5)),
			(TransmitterWorld.state(a.transmitters, 11, FLOOR, 5))
		)
		t.eq(select(2, TransmitterWorld.state(b.transmitters, 10, FLOOR, 8)), 5, "colour")
		t.eq((TransmitterWorld.tank(b.transmitters, 14, FLOOR, 5) :: any).amount, 12000)
		for _ = 1, 3 do
			TransmitterWorld.step(b.transmitters)
		end
		-- Pipe 11's west side is cut: pipe 10 keeps its own share, 11-13 join theirs (and push
		-- some into the tank): not a drop is lost.
		local west = TransmitterWorld.network(b.transmitters, 10, FLOOR, 5) :: any
		local east = TransmitterWorld.network(b.transmitters, 12, FLOOR, 5) :: any
		t.ok(west ~= east, "the cut stays cut")
		t.eq(east.size, 3)
		t.eq(west.fluid, 1)
		local tank = TransmitterWorld.tank(b.transmitters, 14, FLOOR, 5) :: any
		t.eq(west.amount + east.amount + tank.amount, 777 + 12000, "the water, shared out and joined again")
		t.eq(b.transmitters.itemCount, 1, "the sand waits in its transporter")
		-- Structure blocks.
		t.eq((b.structures:structure(16, FLOOR, 16) :: any).name, "house")
		t.eq((b.structures:jigsaw(17, FLOOR, 16) :: any).pool, "village/houses")
		-- Items, animals, block updates.
		local items = b.items:each()
		t.eq(#items, 1)
		t.eq(items[1].age, 5000)
		t.eq(items[1].count, 5)
		local mobs = b.mobs:each()
		t.eq(#mobs, 1, "the cow, not the zombie")
		t.eq(mobs[1].health, 6)
		t.eq(mobs[1].variant, 1)
		local ticks = report.ticks[Coords.chunkKey(0, 0)]
		t.ok(ticks and ticks[1].delay == 7, "the update due, by chunk")
		WorldSnapshot.scheduleTicks(b.ticker, ticks)
		t.eq(b.ticker:pendingCount(), 1)
	end)

	t.test("world save: an edit dirties exactly its region; what moved out is written out", function()
		local game = newGame()
		game.world:setBlock(5000, FLOOR, 5000, id.Glass)
		local dirty = { [RegionCodec.name(RegionCodec.regionOfBlock(5000, 5000))] = true }
		local regions = WorldSnapshot.collect(game, dirty, nil)
		local count = 0
		for name in regions do
			count += 1
			t.eq(name, "9_9")
		end
		t.eq(count, 1, "one edit, one region")
		-- Not dirty, no state: nothing to write.
		local none = WorldSnapshot.collect(game, {}, nil)
		t.eq(next(none), nil)
		-- An item that was in 0_0 at the last save and is gone: 0_0 is written (empty).
		local again = WorldSnapshot.collect(game, {}, { ["0_0"] = true })
		t.ok(again["0_0"] ~= nil and RegionCodec.isEmpty(again["0_0"]))
	end)

	t.test("world save: a typical edited area's size", function()
		local game = newGame()
		furnish(game)
		local regions = WorldSnapshot.collect(game, nil, nil)
		local region = regions["0_0"]
		local bytes = RegionCodec.encode(region)
		local text = SaveCodec.toText(bytes)
		print(
			`    house 9x9x5 + tunnel 3x3x64 + chest, furnace, battery, pipes, items, a cow: {RegionCodec.editCount(
				region
			)} edits, {buffer.len(bytes)} bytes, {#text} characters stored`
		)
		t.ok(#text < 8000, "a few KB")
		-- The time to collect and encode it.
		local started = os.clock()
		for _ = 1, 20 do
			local r = WorldSnapshot.collect(game, nil, nil)
			RegionCodec.encode(r["0_0"])
		end
		print(`    collect + encode: {string.format("%.2f", (os.clock() - started) / 20 * 1000)} ms`)
	end)

	--[[ The store ]]

	-- A save input from a game: its regions encoded, players' texts.
	local function input(game: any, dirty: any?, previous: any?, players: any?)
		local regions = WorldSnapshot.collect(game, dirty or WorldSnapshot.editedRegions(game.world), previous)
		local encoded, empty = {}, {}
		for name, region in regions do
			encoded[name] = RegionCodec.encode(region)
			if RegionCodec.isEmpty(region) then
				empty[name] = true
			end
		end
		return {
			regions = encoded,
			empty = empty,
			players = players or {},
			sections = { time = { dayTime = 6000 } },
			operators = { 1 },
		}
	end

	t.test("world save: save -> load through the store, only what changed written again", function()
		local backend = newBackend()
		local fake = fakeStore(backend)
		local saves = WorldStore.new(fake.store, fake.env)
		local game = newGame()
		furnish(game)
		local world = WorldStore.create(saves, settings())
		local player = PlayerCodec.new()
		player.position = true
		player.x, player.y, player.z = 4, FLOOR, 4
		player.slots[1] = Items.newStack(id.Stone, 10)
		local result = WorldStore.save(saves, world, input(game, nil, nil, { [101] = PlayerCodec.toText(player) }))
		t.eq(result.ok, true, result.message)
		t.eq(result.regionsWritten, 2)
		t.eq(result.playersWritten, 1)
		t.eq(#fake.violations, 0)
		t.ok(backend.data[WorldMeta.metaKey(world.id)] ~= nil, "the record")
		t.ok(backend.data[WorldMeta.regionKey(world.id, "0_0")] ~= nil, "a region head")
		local listed = WorldStore.list(saves) :: any
		t.eq(#listed.worlds, 1)
		t.eq(listed.worlds[1].name, "Island")
		t.ok(listed.worlds[1].bytes > 0)
		print(`    saved: {result.bytes} bytes, largest key {result.largest}`)

		-- Nothing changed: no region or player is written again (the record and index are).
		fake.advance(10)
		local writes = #fake.writes
		local again = WorldStore.save(saves, world, input(game, nil, nil, { [101] = PlayerCodec.toText(player) }))
		t.eq(again.ok, true)
		t.eq(again.regionsWritten, 0)
		t.eq(again.playersWritten, 0)
		t.eq(#fake.writes - writes, 2, "only the record and the index")

		-- Another server loads it after this one let go.
		WorldStore.release(saves, world)
		local other = fakeStore(backend, { job = "server-b", clock = fake.clock })
		local loads = WorldStore.new(other.store, other.env)
		local progress = {}
		local loaded = WorldStore.load(loads, world.id, function(done, total)
			table.insert(progress, `{done}/{total}`)
		end) :: any
		t.ok(loaded ~= nil)
		t.eq(progress[#progress], "2/2")
		t.eq(loaded.settings.seed, 9007199254740991)
		t.eq(loaded.world.meta.sections.time.dayTime, 6000)
		t.eq(#loaded.regions, 2)
		local b = newGame()
		WorldSnapshot.applyEdits(b.world, loaded.regions)
		WorldSnapshot.restore(b, loaded.regions)
		t.ok(sameBuffer(b.world:getChunk(0, 0).data, game.world:getChunk(0, 0).data), "the house")
		local ok, record = WorldStore.loadPlayer(loads, loaded.world, 101)
		t.eq(ok, true)
		t.ok(sameStack((record :: any).slots[1], player.slots[1]), "the player's stone")
		local okNew, none = WorldStore.loadPlayer(loads, loaded.world, 202)
		t.eq(okNew, true)
		t.eq(none, nil, "a new player")
	end)

	t.test("world save: the weather goes on where it was saved; a world saved without it starts clear", function()
		local Weather = require(shared.Weather)
		local field = Weather.new(12345)
		local tick = Weather.TICKS_PER_SECOND
		-- A storm over spawn some way into the clock (a world played a while).
		local stormy = 0
		for clock = 200000, 4000000, 600 do
			if field:at(0, 0, clock) > 0.6 then
				stormy = clock
				break
			end
		end
		t.ok(stormy > 0, "a storm over spawn")
		-- This server's weather: its clock running since server time 100 and reaching the storm at
		-- 700, when it saves, with a thunder override from 400 for 15 minutes (10 of them left).
		local savedAt = 700
		local state = Weather.newState(stormy - (savedAt - 100) * tick, 100, true, true)
		Weather.setOverride(state, Weather.THUNDER, 900, 400)
		local saved = Weather.encodeState(state, savedAt)

		-- Into the world's record (WorldSave's "weather" section: WeatherServer.encode) and back
		-- out on another server.
		local backend = newBackend()
		local fake = fakeStore(backend)
		local saves = WorldStore.new(fake.store, fake.env)
		local game = newGame()
		local world = WorldStore.create(saves, settings())
		local withWeather = input(game)
		withWeather.sections.weather = saved
		t.eq(WorldStore.save(saves, world, withWeather).ok, true)
		WorldStore.release(saves, world)
		local other = fakeStore(backend, { job = "server-b", clock = fake.clock })
		local loaded = WorldStore.load(WorldStore.new(other.store, other.env), world.id) :: any
		t.ok(loaded ~= nil)
		local value = loaded.world.meta.sections.weather
		t.eq(value, saved, "the text as saved")
		t.eq(string.find(value, '[%c"\\]'), nil, "nothing JSON escapes")
		t.eq(loaded.world.meta.sections.time.dayTime, 6000, "beside the day clock")

		-- The new server (its own server time) reads it back (WeatherServer.decode, once the
		-- weather started): the clock where it was, the override blended in with its time left.
		local loadedAt = 52.25
		local restored = Weather.decodeState(value, loadedAt, true) :: Weather.State
		t.ok(restored ~= nil)
		t.eq(Weather.clock(restored, loadedAt), stormy, "the clock where it was saved")
		t.ok(field:at(0, 0, Weather.clock(restored, loadedAt)) > 0.6, "the storm still over spawn")
		t.eq(restored.cycle, true)
		t.eq(Weather.overrideAt(restored, loadedAt), Weather.THUNDER)
		-- The same weather from then on: the override, its blend out after 10 minutes and the storms
		-- after it.
		for _, after in { 0, 30, 300, 597.5, 600, 1200 } do
			local a = Weather.momentAt(state, savedAt + after)
			local b = Weather.momentAt(restored, loadedAt + after)
			for _, place in { { 0, 0 }, { 700, -300 }, { -2500, 4100 } } do
				local p1, th1, c1 = field:at(place[1], place[2], a)
				local p2, th2, c2 = field:at(place[1], place[2], b)
				t.ok(
					math.abs(p1 - p2) < 1e-9 and math.abs(th1 - th2) < 1e-9 and math.abs(c1 - c2) < 1e-9,
					`{after} s after loading at {place[1]}, {place[2]}`
				)
			end
		end
		-- doWeatherCycle off: the clock and the override's time left stay held.
		local held = Weather.newState(stormy, 0, false, true)
		Weather.setOverride(held, Weather.RAIN, 300, 10)
		local back = Weather.decodeState(Weather.encodeState(held, 5000), 3, true) :: Weather.State
		t.eq(back.cycle, false)
		t.eq(Weather.clock(back, 100000), stormy, "a stopped clock stays stopped")
		t.eq(back.left, 300, "the override's time held")
		t.eq(Weather.overrideAt(back, 100000), Weather.RAIN)
		-- A debug world stays clear; damaged text is refused (the clear start stays).
		t.eq((Weather.decodeState(value, 0, false) :: Weather.State).enabled, false)
		t.eq(Weather.decodeState(42, 0, true), nil)
		t.eq(Weather.decodeState("w1;1;1;storm;5", 0, true), nil)

		-- A world saved without it (before the weather, or a new one): no section, so the weather
		-- server keeps a new world's start, dry at spawn for its first minutes.
		local loads = WorldStore.new(other.store, other.env)
		local plainWorld = WorldStore.create(loads, settings("Plain"))
		other.advance(10)
		t.eq(WorldStore.save(loads, plainWorld, input(game)).ok, true)
		WorldStore.release(loads, plainWorld)
		local plain = WorldStore.load(WorldStore.new(other.store, other.env), plainWorld.id) :: any
		t.ok(plain ~= nil)
		t.eq(plain.world.meta.sections.weather, nil)
		local seconds = Config.Weather.ClearStartSeconds
		local start = Weather.clearStart(field, 0, 0, seconds)
		for clock = start, start + seconds * tick, 10 * tick do
			t.eq(field:at(0, 0, clock), 0, "dry at spawn")
		end
	end)

	t.test("world save: protocol ids stay unique and appended (saving's, then the weather's)", function()
		local Protocol = require(shared.Net.Protocol)
		for _, kinds in { Protocol.ClientMessage, Protocol.ServerMessage } do
			local seen: { [number]: string } = {}
			local count = 0
			for name, value in kinds do
				t.eq(seen[value], nil, `{name} shares id {value}`)
				seen[value] = name
				count += 1
			end
			for i = 1, count do
				t.ok(seen[i] ~= nil, `no gap at {i}`)
			end
		end
		t.eq(Protocol.ClientMessage.WorldAction, 23)
		t.eq(Protocol.ServerMessage.WorldList, 23)
		t.eq(Protocol.ServerMessage.WorldSave, 24)
		t.eq(Protocol.ServerMessage.Lightning, 25)
	end)

	t.test("world save: one server per world; a stale lock is taken over, the old server stops saving", function()
		local backend = newBackend()
		local a = fakeStore(backend, { job = "a" })
		local savesA = WorldStore.new(a.store, a.env)
		local game = newGame()
		furnish(game)
		local world = WorldStore.create(savesA, settings())
		t.eq(WorldStore.save(savesA, world, input(game)).ok, true)
		local b = fakeStore(backend, { job = "b", clock = a.clock })
		local savesB = WorldStore.new(b.store, b.env)
		local refused, why = WorldStore.load(savesB, world.id)
		t.eq(refused, nil)
		t.eq(why, "it is open on another server")
		local deleted, deleteWhy = WorldStore.delete(savesB, world.id)
		t.eq(deleted, false, "a world in use can't be deleted")
		t.eq(deleteWhy, "it is open on another server")
		-- A crashed server: its lock goes stale, B takes over, A's heartbeat finds it lost.
		b.advance(Config.Save.LockTimeout + 1)
		local loaded = WorldStore.load(savesB, world.id)
		t.ok(loaded ~= nil, "taken over")
		a.advance(Config.Save.LockTimeout + 1)
		t.eq(WorldStore.heartbeat(savesA, world), false, "A lost it")
		t.eq(world.canSave, false)
		local writes = #a.writes
		local result = WorldStore.save(savesA, world, input(game))
		t.eq(result.refused, true, "A never writes it again")
		t.eq(#a.writes, writes)
	end)

	t.test("world save: a failed load is never written over and gives its lock back", function()
		local backend = newBackend()
		local a = fakeStore(backend)
		local saves = WorldStore.new(a.store, a.env)
		local game = newGame()
		furnish(game)
		local world = WorldStore.create(saves, settings())
		WorldStore.save(saves, world, input(game))
		WorldStore.release(saves, world)
		local before = deepCopy(backend.data)
		-- A region head that can't be read (every try fails).
		local b = fakeStore(backend, { job = "b", clock = a.clock + 10 })
		b.failures[WorldMeta.regionKey(world.id, "0_0")] = 99
		local loads = WorldStore.new(b.store, b.env)
		local none, why = WorldStore.load(loads, world.id)
		t.eq(none, nil)
		t.ok(string.find(why or "", "could not be read", 1, true) ~= nil, why)
		for key, value in backend.data do
			if key ~= WorldMeta.lockKey(world.id) then
				t.eq(jsonLength(value), jsonLength(before[key]), `{key} untouched`)
			end
		end
		t.eq((backend.data[WorldMeta.lockKey(world.id)] :: any).released, true, "the lock given back")
		-- Damaged region bytes: the same.
		local head = backend.data[WorldMeta.regionKey(world.id, "0_0")]
		head.d = "!!!!" .. string.sub(head.d, 5)
		local c = fakeStore(backend, { job = "c", clock = b.clock + 10 })
		local damaged = WorldStore.load(WorldStore.new(c.store, c.env), world.id)
		t.eq(damaged, nil, "a damaged region refuses the load")
		-- A player whose record can't be read is reported so (the caller never writes them).
		local d = fakeStore(backend, { job = "d", clock = c.clock + 10 })
		d.failures[WorldMeta.playerKey(world.id, 5)] = 99
		local okPlayer = WorldStore.loadPlayer(WorldStore.new(d.store, d.env), world, 5)
		t.eq(okPlayer, false)
	end)

	t.test("world save: past the world's most a save is refused whole; failed parts keep the old region", function()
		local backend = newBackend()
		local fake = fakeStore(backend)
		local saves = WorldStore.new(fake.store, fake.env)
		local game = newGame()
		furnish(game)
		local world = WorldStore.create(saves, settings())
		local max = Config.Save.MaxWorldBytes
		Config.Save.MaxWorldBytes = 2000
		local refused = WorldStore.save(saves, world, input(game))
		Config.Save.MaxWorldBytes = max
		t.eq(refused.refused, true)
		t.eq(refused.state, "over")
		t.eq(#fake.writes, 0, "nothing written")
		-- A long region (parts) whose second part keeps failing: its head isn't written, so the
		-- region stays as it was (none) and the next save writes it.
		local maxKey = Config.Save.MaxKeyBytes
		Config.Save.MaxKeyBytes = 1024
		fake.failures[WorldMeta.partKey(world.id, "0_0", 0, 2)] = 99
		local partial = WorldStore.save(saves, world, input(game))
		t.eq(partial.ok, false)
		t.eq(backend.data[WorldMeta.regionKey(world.id, "0_0")], nil, "no head without its parts")
		t.ok(world.regions["0_0"] == nil, "not committed")
		fake.failures[WorldMeta.partKey(world.id, "0_0", 0, 2)] = nil
		fake.advance(10)
		local fixed = WorldStore.save(saves, world, input(game))
		t.eq(fixed.ok, true, fixed.message)
		local head = backend.data[WorldMeta.regionKey(world.id, "0_0")]
		t.ok(head and head.parts > 1, "written in parts")
		-- The next change goes to the other slot: the committed parts stay intact meanwhile.
		game.world:setBlock(1, FLOOR + 20, 1, id.Glass)
		fake.advance(10)
		local moved = WorldStore.save(saves, world, input(game, { ["0_0"] = true }))
		t.eq(moved.ok, true)
		t.eq(backend.data[WorldMeta.regionKey(world.id, "0_0")].slot, 1 - head.slot)
		Config.Save.MaxKeyBytes = maxKey
		WorldStore.release(saves, world)
		local again = fakeStore(backend, { job = "x", clock = fake.clock + 1 })
		local loaded = WorldStore.load(WorldStore.new(again.store, again.env), world.id) :: any
		t.ok(loaded ~= nil)
		local b = newGame()
		WorldSnapshot.applyEdits(b.world, loaded.regions)
		t.eq(b.world:getBlock(1, FLOOR + 20, 1), id.Glass, "the latest slot's region")
		t.eq(#fake.violations, 0)
	end)

	t.test("world save: delete and rename", function()
		local backend = newBackend()
		local fake = fakeStore(backend)
		local saves = WorldStore.new(fake.store, fake.env)
		local game = newGame()
		furnish(game)
		local world = WorldStore.create(saves, settings())
		WorldStore.save(saves, world, input(game, nil, nil, { [7] = PlayerCodec.toText(PlayerCodec.new()) }))
		WorldStore.release(saves, world)
		fake.advance(10)
		t.eq((WorldStore.rename(saves, world.id, "  Castle\n ")), true)
		local list = WorldStore.list(saves) :: any
		t.eq(list.worlds[1].name, "Castle")
		t.eq((WorldMeta.read(backend.data[WorldMeta.metaKey(world.id)]) :: any).name, "Castle")
		fake.advance(10)
		t.eq((WorldStore.delete(saves, world.id)), true)
		t.eq(#(WorldStore.list(saves) :: any).worlds, 0)
		local left = 0
		for _ in backend.data do
			left += 1
		end
		t.eq(left, 1, "only the index is left")
		t.eq(#fake.violations, 0)
	end)

	--[[ Owners, lists, locks and records: what keeps saved worlds safe ]]

	t.test("world save: a world is its owner's: others can't list, load, rename or delete it", function()
		local backend = newBackend()
		local fake = fakeStore(backend)
		local saves = WorldStore.new(fake.store, fake.env)
		local game = newGame()
		furnish(game)
		local OWNER, STRANGER, ADMIN = 501, 777, 1
		local world = WorldStore.create(saves, settings("Base"), OWNER)
		t.eq(WorldStore.save(saves, world, input(game)).ok, true)
		WorldStore.release(saves, world)
		fake.advance(10)
		t.eq(#(WorldStore.list(saves) :: any).worlds, 0, "not in the game's list")
		t.eq(#(WorldStore.list(saves, STRANGER) :: any).worlds, 0, "nor a stranger's")
		local mine = WorldStore.list(saves, OWNER) :: any
		t.eq(#mine.worlds, 1)
		t.eq(mine.worlds[1].owner, OWNER)
		t.eq(WorldMeta.mayManage(OWNER, { userId = OWNER, permanent = false }), true)
		t.eq(WorldMeta.mayManage(OWNER, { userId = STRANGER, permanent = false }), false)
		t.eq(WorldMeta.mayManage(0, { userId = STRANGER, permanent = false }), false, "the game's: its people only")
		t.eq(WorldMeta.mayManage(OWNER, { userId = ADMIN, permanent = true }), true)
		t.eq(WorldMeta.mayManage(OWNER, nil), true, "the server itself")

		-- A stranger, the operator of an empty server, sends the world's id anyway.
		local stranger = { userId = STRANGER, permanent = false }
		local before = deepCopy(backend.data)
		local none, why = WorldStore.load(saves, world.id, nil, stranger)
		t.eq(none, nil)
		t.eq(why, "it is not yours")
		fake.advance(10)
		local deleted, deleteWhy = WorldStore.delete(saves, world.id, stranger)
		t.eq(deleted, false)
		t.eq(deleteWhy, "it is not yours")
		fake.advance(10)
		local renamed, renameWhy = WorldStore.rename(saves, world.id, "Mine now", stranger)
		t.eq(renamed, false)
		t.eq(renameWhy, "it is not yours")
		for key, value in backend.data do
			if key ~= WorldMeta.lockKey(world.id) then
				t.eq(jsonLength(value), jsonLength(before[key]), `{key} untouched`)
			end
		end
		t.eq((backend.data[WorldMeta.lockKey(world.id)] :: any).released, true, "its lock given back")

		-- The game's own people may; the owner may.
		fake.advance(10)
		local opened = WorldStore.load(saves, world.id, nil, { userId = ADMIN, permanent = true })
		t.ok(opened ~= nil, "an admin opens it")
		WorldStore.release(saves, (opened :: any).world)
		fake.advance(10)
		t.eq((WorldStore.rename(saves, world.id, "Castle", { userId = OWNER, permanent = false })), true)
		t.eq((WorldStore.list(saves, OWNER) :: any).worlds[1].name, "Castle")

		-- A world whose record is gone is deleted only from a list of one's own.
		local lost = WorldStore.create(saves, settings("Lost"), OWNER)
		fake.advance(10)
		t.eq(WorldStore.save(saves, lost, input(game)).ok, true)
		WorldStore.release(saves, lost)
		backend.data[WorldMeta.metaKey(lost.id)] = nil
		fake.advance(10)
		local gone, goneWhy = WorldStore.delete(saves, lost.id, stranger)
		t.eq(gone, false)
		t.eq(goneWhy, "there is no such world")
		t.eq(#(WorldStore.list(saves, OWNER) :: any).worlds, 2, "still listed")
		fake.advance(10)
		t.eq((WorldStore.delete(saves, lost.id, { userId = OWNER, permanent = false })), true)
		fake.advance(10)
		t.eq((WorldStore.delete(saves, world.id, { userId = OWNER, permanent = false })), true)
		t.eq(#(WorldStore.list(saves, OWNER) :: any).worlds, 0)
	end)

	t.test("world save: a full list refuses a new world whole and never drops one", function()
		local backend = newBackend()
		local fake = fakeStore(backend)
		local saves = WorldStore.new(fake.store, fake.env)
		local OWNER = 9
		local index = WorldMeta.readIndex(nil) :: any
		for i = 1, WorldMeta.MAX_WORLDS do
			local meta = WorldMeta.new(string.format("w%08d", i), settings(`World {i}`), 1000 + i, OWNER)
			index = WorldMeta.withEntry(index, WorldMeta.entry(meta, 100)) :: any
			t.ok(index ~= nil)
		end
		t.eq(#index.worlds, WorldMeta.MAX_WORLDS)
		local newcomer = WorldMeta.entry(WorldMeta.new("wnewcomer", settings("New"), 99999, OWNER), 100)
		t.eq(WorldMeta.withEntry(index, newcomer), nil, "full: refused, none dropped")
		local played = table.clone(index.worlds[WorldMeta.MAX_WORLDS])
		played.lastPlayed = 99999
		local again = WorldMeta.withEntry(index, played) :: any
		t.eq(#again.worlds, WorldMeta.MAX_WORLDS, "a listed one is still updated")
		t.eq(again.worlds[1].id, played.id)
		backend.data[WorldMeta.indexKey(OWNER)] = index

		local room, why = WorldStore.room(saves, OWNER)
		t.eq(room, false)
		t.ok(string.find(why or "", "full", 1, true) ~= nil, why)
		t.eq((WorldStore.room(saves, 10)), true, "another player's list is their own")
		local game = newGame()
		furnish(game)
		local world = WorldStore.create(saves, settings("One too many"), OWNER)
		local refused = WorldStore.save(saves, world, input(game))
		t.eq(refused.refused, true)
		t.eq(#fake.writes, 0, "nothing written: no world without its line in the list")
		t.eq(world.canSave, false)
		t.eq(#(backend.data[WorldMeta.indexKey(OWNER)] :: any).worlds, WorldMeta.MAX_WORLDS)
		t.eq((backend.data[WorldMeta.indexKey(OWNER)] :: any).worlds[1].id, index.worlds[1].id)
	end)

	t.test("world save: a long load keeps its lock; a save looks at it first; two servers' parts never mix", function()
		local Region = RegionCodec
		local backend = newBackend()
		local writer = fakeStore(backend, { job = "w", players = 20 })
		local savesW = WorldStore.new(writer.store, writer.env)
		local world = WorldStore.create(savesW, settings())
		local regions = {}
		local N = 250
		for i = 1, N do
			local rx, rz = i % 40, i // 40
			local region = Region.new(rx, rz)
			table.insert(region.sourced, Coords.posKey(rx * REGION + 1, FLOOR, rz * REGION + 1))
			regions[Region.name(rx, rz)] = Region.encode(region)
		end
		local saved = WorldStore.save(savesW, world, { regions = regions, players = {}, sections = {}, operators = {} })
		t.eq(saved.ok, true, saved.message)
		WorldStore.release(savesW, world)

		-- An empty server reads 250 keys at 60 a minute: longer than the lock's timeout.
		local a = fakeStore(backend, { job = "a", players = 0, clock = writer.clock + 600 })
		local savesA = WorldStore.new(a.store, a.env)
		local t0 = a.clock
		local oldest = 0
		local loaded = WorldStore.load(savesA, world.id, function()
			local lock = backend.data[WorldMeta.lockKey(world.id)] :: any
			oldest = math.max(oldest, a.env.time() - lock.at)
		end) :: any
		t.ok(loaded ~= nil)
		local took = a.clock - t0
		print(`    {N} regions loaded in {string.format("%.0f", took)} s; the lock at most {oldest} s old meanwhile`)
		t.ok(took > Config.Save.LockTimeout, "longer than the lock's timeout")
		t.ok(oldest <= Config.Save.LockTimeout / 3 + 10, `renewed while it loads ({oldest} s)`)
		local b = fakeStore(backend, { job = "b", players = 1, clock = a.clock })
		local savesB = WorldStore.new(b.store, b.env)
		local taken, refusal = WorldStore.lock(savesB, world.id)
		t.eq(taken, false, "a second server can't take a running server's world")
		t.eq(refusal, "it is open on another server")

		-- A stalls past the timeout (no heartbeat), B takes it over: A's next save looks first.
		b.advance(Config.Save.LockTimeout + 10)
		local loadedB = WorldStore.load(savesB, world.id) :: any
		t.ok(loadedB ~= nil, "taken over")
		a.advance(b.clock - a.clock + 10)
		local writes = #a.writes
		local changed = Region.new(0, 0)
		table.insert(changed.sourced, Coords.posKey(5, FLOOR, 5))
		local stale = WorldStore.save(
			savesA,
			loaded.world,
			{ regions = { ["0_0"] = Region.encode(changed) }, players = {}, sections = {}, operators = {} }
		)
		t.eq(stale.refused, true)
		t.eq(loaded.world.canSave, false)
		t.eq(#a.writes - writes, 1, "only the look at the lock")

		-- Even two servers that both believe they hold it (a clock gone wrong) never mix their
		-- saves' parts: B's parts over the slot A's head names are refused, never joined.
		local maxKey = Config.Save.MaxKeyBytes
		Config.Save.MaxKeyBytes = 1100
		local function long(seed: number)
			local region = Region.new(0, 0)
			for i = 1, 300 do
				table.insert(region.sourced, Coords.posKey((i * 7 + seed) % 512, 60, (i * 13) % 512))
			end
			return Region.encode(region)
		end
		local c = fakeStore(backend, { job = "c", players = 20, clock = b.clock + Config.Save.LockTimeout + 10 })
		local savesC = WorldStore.new(c.store, c.env)
		local first = WorldStore.load(savesC, world.id) :: any
		t.eq(
			WorldStore.save(
				savesC,
				first.world,
				{ regions = { ["0_0"] = long(1) }, players = {}, sections = {}, operators = {} }
			).ok,
			true
		)
		WorldStore.release(savesC, first.world)
		c.advance(10)
		local d = fakeStore(backend, { job = "d", players = 20, clock = c.clock })
		local e = fakeStore(backend, { job = "e", players = 20, clock = c.clock })
		local savesD, savesE = WorldStore.new(d.store, d.env), WorldStore.new(e.store, e.env)
		local loadedD = WorldStore.load(savesD, world.id) :: any
		e.advance(Config.Save.LockTimeout + 10)
		d.advance(Config.Save.LockTimeout + 10)
		local loadedE = WorldStore.load(savesE, world.id) :: any
		t.ok(loadedD ~= nil and loadedE ~= nil)
		loadedD.world.renewedAt = d.env.now() -- (D's clock says its lock is fresh)
		t.eq(
			WorldStore.save(
				savesD,
				loadedD.world,
				{ regions = { ["0_0"] = long(2) }, players = {}, sections = {}, operators = {} }
			).ok,
			true
		)
		e.advance(10)
		e.failures[WorldMeta.regionKey(world.id, "0_0")] = 99
		local failedE = WorldStore.save(
			savesE,
			loadedE.world,
			{ regions = { ["0_0"] = long(3) }, players = {}, sections = {}, operators = {} }
		)
		t.eq(failedE.ok, false)
		Config.Save.MaxKeyBytes = maxKey
		local f = fakeStore(backend, { job = "f", players = 20, clock = e.clock + Config.Save.LockTimeout + 10 })
		local mixed, mixedWhy = WorldStore.load(WorldStore.new(f.store, f.env), world.id)
		t.eq(mixed, nil, "never a region equal to neither save")
		t.ok(string.find(mixedWhy or "", "another save", 1, true) ~= nil, mixedWhy)
		t.ok(WorldMeta.writerTag("d") ~= WorldMeta.writerTag("e"))
		t.eq(WorldMeta.writerTag("d"), WorldMeta.writerTag("d"))
	end)

	t.test(
		"world save: a player's older record never goes over a newer one; one who never stood keeps theirs",
		function()
			local backend = newBackend()
			local fake = fakeStore(backend)
			local saves = WorldStore.new(fake.store, fake.env)
			local game = newGame()
			local world = WorldStore.create(saves, settings())
			t.eq(WorldStore.save(saves, world, input(game)).ok, true)
			local function holding(count: number): string
				local record = PlayerCodec.new()
				record.slots[1] = Items.newStack(id.Stone, count)
				return PlayerCodec.toText(record)
			end
			local key = WorldMeta.playerKey(world.id, 7)
			-- An autosave captured P (order 3); P left (order 5) and was written first.
			fake.advance(10)
			t.eq(WorldStore.savePlayers(saves, world, { [7] = holding(50) }, nil, { [7] = 5 })[7], true)
			local tagged = input(game, {}, nil, { [7] = holding(10) })
			tagged.order = { [7] = 3 }
			fake.advance(10)
			local retried = WorldStore.save(saves, world, tagged)
			t.eq(retried.ok, true)
			t.eq(retried.playersWritten, 0, "the older one is not written")
			t.eq((backend.data[key] :: any).d, holding(50), "what P left with stays")
			t.eq(world.players["7"], holding(50))
			-- A newer one is.
			fake.advance(10)
			local newer = input(game, {}, nil, { [7] = holding(60) })
			newer.order = { [7] = 9 }
			t.eq(WorldStore.save(saves, world, newer).playersWritten, 1)
			t.eq((backend.data[key] :: any).d, holding(60))
			fake.advance(10)
			t.eq(next(WorldStore.savePlayers(saves, world, { [7] = holding(55) }, nil, { [7] = 6 })), nil)
			t.eq((backend.data[key] :: any).d, holding(60), "nor a leaving record older than the save's")

			-- Saved far from spawn, back on the title screen, gone again before a character stood:
			-- the record they are saved with is the saved one, not a fresh player at spawn.
			local saved = PlayerCodec.new()
			saved.position = true
			saved.x, saved.y, saved.z, saved.yaw = 5000, 70, -1200, 1.5
			saved.health = 11
			saved.slots[3] = Items.newStack(id.Sand, 4)
			saved.thirst = { thirst = 9, hydration = 1, exhaustion = 0.5, effect = 0, timer = 3 }
			saved.temperature = {
				value = 2,
				target = 1,
				drift = 0,
				frozen = 0,
				heat = 0,
				timer = 0,
				wet = 0,
				warmth = 0,
				chill = 0,
				clemency = 100,
			}
			saved.effects = { { effect = 1, amplifier = 0, ticks = 400, ambient = false } }
			saved.mana, saved.crystals = 60, 2
			local captured = PlayerCodec.new()
			captured.slots[3] = Items.newStack(id.Sand, 4)
			local kept = PlayerCodec.withWaiting(
				captured,
				saved,
				{ standing = false, climate = false, effects = false, mana = false }
			)
			t.eq(PlayerCodec.toText(kept), PlayerCodec.toText(saved), "exactly as saved: nothing new to write")
			-- What lives already is the live one's.
			local standing = PlayerCodec.new()
			standing.position = true
			standing.x, standing.y, standing.z = 1, 2, 3
			standing.thirst = { thirst = 20, hydration = 5, exhaustion = 0, effect = 0, timer = 0 }
			standing.temperature = saved.temperature
			standing.mana, standing.crystals = 35, 3
			local live = PlayerCodec.withWaiting(
				standing,
				saved,
				{ standing = true, climate = true, effects = false, mana = true }
			)
			t.eq(live.x, 1)
			t.eq((live.thirst :: any).thirst, 20)
			t.eq(#live.effects, 1, "effects not made yet: the saved ones")
			t.eq(live.mana, 35, "mana kept live: the live one's")
			t.eq(live.crystals, 3)
			t.eq(
				PlayerCodec.withWaiting(
					PlayerCodec.new(),
					nil,
					{ standing = false, climate = false, effects = false, mana = false }
				).position,
				false
			)
		end
	)

	t.test("world save: what this version doesn't know keeps the world (or player) from being written", function()
		local backend = newBackend()
		local fake = fakeStore(backend)
		local saves = WorldStore.new(fake.store, fake.env)
		local game = newGame()
		furnish(game)
		local world = WorldStore.create(saves, settings())
		local saved = input(game)
		-- A block a newer version added, in a chunk of region 0_0.
		local newer = RegionCodec.decode(saved.regions["0_0"], 0, 0)
		newer.chunks[Coords.chunkKey(0, 0)][7] = 60000
		saved.regions["0_0"] = RegionCodec.encode(newer)
		t.eq(WorldStore.save(saves, world, saved).ok, true)
		WorldStore.release(saves, world)
		local b = fakeStore(backend, { job = "b", clock = fake.clock + 10 })
		local savesB = WorldStore.new(b.store, b.env)
		local loaded = WorldStore.load(savesB, world.id) :: any
		t.ok(loaded ~= nil, "it opens")
		t.ok(loaded.dropped > 0)
		t.eq(loaded.world.canSave, false, "but is never written")
		b.advance(10)
		local writes = #b.writes
		local result = WorldStore.save(savesB, loaded.world, input(game))
		t.eq(result.refused, true)
		t.ok(string.find(result.message or "", "newer version", 1, true) ~= nil, result.message)
		t.eq(#b.writes, writes)

		-- A chest holding an item, and a player record holding one, this version doesn't know.
		local isValid = Items.isValid
		local region = RegionCodec.new(0, 0)
		table.insert(region.containers, {
			x = 2,
			y = FLOOR,
			z = 2,
			container = {
				kind = "chest",
				block = id.Chest,
				size = 27,
				slots = { [1] = Items.newStack(id.Sand, 3), [2] = Items.newStack(id.Stone, 1) },
			},
		})
		local bytes = RegionCodec.encode(region)
		local record = PlayerCodec.new()
		record.slots[1] = Items.newStack(id.Sand, 3)
		record.slots[2] = Items.newStack(id.Stone, 5)
		local text = PlayerCodec.toText(record)
		local items: any = Items
		items.isValid = function(item: number): boolean
			return item ~= id.Sand and isValid(item)
		end
		local back = RegionCodec.decode(bytes, 0, 0)
		local player = PlayerCodec.fromText(text) :: any
		items.isValid = isValid
		t.eq(back.dropped, 1, "the chest's unknown stack counts")
		t.eq(player.dropped, 1, "the record's too")
		t.ok(sameStack(player.slots[2], record.slots[2]), "the rest is read")
		t.eq(PlayerCodec.fromText(text).dropped, 0)
	end)

	t.test("world save: block updates waiting for their chunk are saved again as they were", function()
		local a = newGame()
		a.world:setBlock(100, FLOOR, 100, id.Glass)
		a.ticker:schedule(101, FLOOR, 100, 5)
		local regions = WorldSnapshot.collect(a, WorldSnapshot.editedRegions(a.world))
		t.eq(#regions["0_0"].ticks, 1)
		local stored = RegionCodec.encode(regions["0_0"])
		local loaded = { RegionCodec.decode(stored, 0, 0) }
		local b = newGame()
		WorldSnapshot.applyEdits(b.world, loaded)
		local report = WorldSnapshot.restore(b, loaded)
		-- Nobody went near chunk (6, 6) before the next save.
		local again = WorldSnapshot.collect(b, {}, { ["0_0"] = true }, nil, nil, report.ticks)
		t.eq(#again["0_0"].ticks, 1, "kept")
		t.eq(again["0_0"].ticks[1].delay, 5)
		t.ok(sameBuffer(RegionCodec.encode(again["0_0"]), stored), "the region as it was: nothing to write")
	end)

	--[[ Commands ]]

	t.test("world save: /save-all, /save-off and /save-on", function()
		local ctx = { operator = true, autosave = true, available = true }
		t.eq(SaveCommand.matches("/save-all"), true)
		t.eq(SaveCommand.matches("/saveall"), false)
		local all = SaveCommand.run("/save-all flush", ctx) :: any
		t.eq(all.action, "save")
		t.eq(all.feedback[1], "Saving the game (this may take a moment!)")
		t.eq((SaveCommand.run("/save-all now", ctx) :: any).action, nil, "usage")
		t.eq((SaveCommand.run("/save-off", ctx) :: any).action, "off")
		t.eq((SaveCommand.run("/save-on", ctx) :: any).feedback[1], "Saving is already turned on")
		local off = { operator = true, autosave = false, available = true }
		t.eq((SaveCommand.run("/save-on", off) :: any).action, "on")
		t.eq((SaveCommand.run("/save-off", off) :: any).feedback[1], "Saving is already turned off")
		local denied = SaveCommand.run("/save-all", { operator = false, autosave = true, available = true }) :: any
		t.eq(denied.action, nil)
		t.eq(denied.feedback[1], SaveCommand.DENIED)
		local unavailable = SaveCommand.run(
			"/save-all",
			{ operator = true, autosave = true, available = false, reason = "no API access" }
		) :: any
		t.eq(unavailable.action, nil)
		t.ok(string.find(unavailable.feedback[1], "no API access", 1, true) ~= nil)
		t.eq(SaveCommand.run("/time set day", ctx), nil)
		-- A world not being saved has no automatic saving to turn off or on: it says why.
		local sessionOnly = { operator = true, autosave = true, available = false, reason = "its lock was lost" }
		for _, command in { "/save-off", "/save-on" } do
			local refused = SaveCommand.run(command, sessionOnly) :: any
			t.eq(refused.action, nil, command)
			t.ok(string.find(refused.feedback[1], "its lock was lost", 1, true) ~= nil)
		end
		local offUnavailable = { operator = true, autosave = false, available = false }
		t.eq((SaveCommand.run("/save-on", offUnavailable) :: any).action, nil)
	end)

	--[[ Players' things back in the game's own parts ]]

	t.test("world save: a returning player's inventory, operators and records written as they leave", function()
		local InventoryState = require(server.Players.InventoryState)
		local Types = require(shared.Inventory.Types)
		local inventories = InventoryState.new()
		inventories:join("p")
		local slots = { [1] = Items.newStack(id.Stone, 64), [36] = Items.newStack(id.Sand, 3) }
		local armor = { [2] = Items.newStack(Items.find("IronChestplate") or Items.id.IronIngot, 1) }
		local thrown = inventories:restore("p", slots, armor, 5, Items.newStack(id.Glass, 2))
		t.eq(#thrown, 0)
		local inventory = (inventories:window("p") :: any).inventory
		t.ok(sameStack(inventory.slots[1], slots[1]))
		t.ok(sameStack(inventory.slots[36], slots[36]))
		t.ok(sameStack(inventory.armor[2], armor[2]))
		t.eq(inventory.selected, 5)
		local glass = 0
		for slot = 1, Types.INVENTORY_SIZE do
			local stack = inventory.slots[slot]
			if stack and stack.item == id.Glass then
				glass += stack.count
			end
		end
		t.eq(glass, 2, "the cursor went into the inventory")
		t.ok(inventory.slots[1] ~= slots[1], "copies, not the record's tables")

		local OperatorList = require(server.Players.OperatorList)
		local list = OperatorList.new()
		OperatorList.setAutoOperator(list, false)
		OperatorList.join(list, { key = 5, name = "Steve", displayName = "Steve" }, false)
		local result = OperatorList.grant(list, { 5, 9 })
		t.eq(OperatorList.isOperator(list, 5), true)
		t.eq(OperatorList.isOperator(list, 9), true, "not here, still on the list")
		t.eq(#result.changed, 1, "only those here are told")
		t.eq(table.concat(OperatorList.ops(list), ","), "5,9")

		-- A player who leaves is written at once (only their key); the next save skips them.
		local backend = newBackend()
		local fake = fakeStore(backend)
		local saves = WorldStore.new(fake.store, fake.env)
		local game = newGame()
		local world = WorldStore.create(saves, settings())
		t.eq(next(WorldStore.savePlayers(saves, world, { [7] = "x" })), nil, "not before the world's first save")
		WorldStore.save(saves, world, input(game))
		fake.advance(10)
		local record = PlayerCodec.new()
		record.slots[1] = Items.newStack(id.Stone, 1)
		local text = PlayerCodec.toText(record)
		local writes = #fake.writes
		local written = WorldStore.savePlayers(saves, world, { [7] = text })
		t.eq(written[7], true)
		t.eq(#fake.writes - writes, 1, "one key")
		fake.advance(10)
		local again = WorldStore.save(saves, world, input(game, nil, nil, { [7] = text }))
		t.eq(again.playersWritten, 0, "already written")
	end)

	--[[ The wire ]]

	t.test("world save: WorldAction, WorldList and WorldSave round trip; malformed ones are refused", function()
		local Protocol = require(shared.Net.Protocol)
		local action, wid, name = Protocol.decodeWorldAction(Protocol.encodeWorldAction(Protocol.WorldAction.List))
		t.eq(action, Protocol.WorldAction.List)
		t.eq(wid, "")
		action, wid = Protocol.decodeWorldAction(Protocol.encodeWorldAction(Protocol.WorldAction.Load, "w0000abcd"))
		t.eq(action, Protocol.WorldAction.Load)
		t.eq(wid, "w0000abcd")
		action, wid, name =
			Protocol.decodeWorldAction(Protocol.encodeWorldAction(Protocol.WorldAction.Rename, "w0000abcd", "Castle"))
		t.eq(action, Protocol.WorldAction.Rename)
		t.eq(name, "Castle")
		t.eq((Protocol.decodeWorldAction(buffer.create(0))), nil)
		local bad = buffer.create(1)
		buffer.writeu8(bad, 0, 9)
		t.eq((Protocol.decodeWorldAction(bad)), nil, "an unknown action")
		local short = Protocol.encodeWorldAction(Protocol.WorldAction.Delete, "w1")
		t.eq((Protocol.decodeWorldAction(buffer.create(buffer.len(short) - 1))), nil, "cut short")

		local worlds = {
			{
				id = "w0000abcd",
				name = "Island",
				worldType = "default",
				seed = "-42",
				gameMode = GameMode.CREATIVE,
				lastPlayed = 1700000000,
				bytes = 1.4 * 1048576,
			},
			{
				id = "w1",
				name = "Flat",
				worldType = "superflat",
				seed = "1",
				gameMode = GameMode.SURVIVAL,
				lastPlayed = 0,
				bytes = 0,
			},
		}
		local list, saving, message = Protocol.decodeWorldList(Protocol.encodeWorldList(worlds, true, "Renamed"))
		t.ok(list ~= nil)
		t.eq(#(list :: any), 2)
		t.eq((list :: any)[1].name, "Island")
		t.eq((list :: any)[1].gameMode, GameMode.CREATIVE)
		t.eq((list :: any)[1].bytes, 1.4 * 1048576)
		t.eq(saving, true)
		t.eq(message, "Renamed")
		local empty = Protocol.decodeWorldList(Protocol.encodeWorldList({}, false, ""))
		t.eq(#(empty :: any), 0)
		local listBytes = Protocol.encodeWorldList(worlds, true, "")
		t.eq((Protocol.decodeWorldList(buffer.create(buffer.len(listBytes) - 1))), nil)

		local saved = Protocol.decodeWorldSave(Protocol.encodeWorldSave({
			op = Protocol.SaveOp.Saved,
			ok = true,
			sizes = true,
			warn = true,
			bytes = 1000,
			max = 2000,
			largest = 300,
			keyLimit = 4194304,
			text = "",
		})) :: any
		t.eq(saved.ok, true)
		t.eq(saved.sizes, true)
		t.eq(saved.warn, true)
		t.eq(saved.largest, 300)
		local plain = Protocol.decodeWorldSave(
			Protocol.encodeWorldSave({ op = Protocol.SaveOp.Saved, ok = false, text = "x" })
		) :: any
		t.eq(plain.sizes, false)
		t.eq(plain.bytes, nil, "no sizes for players")
		t.eq(plain.text, "x")
		local loading = Protocol.decodeWorldSave(
			Protocol.encodeWorldSave({ op = Protocol.SaveOp.Loading, done = 12, total = 40, text = "" })
		) :: any
		t.eq(loading.done, 12)
		t.eq(loading.total, 40)
		local saveState = Protocol.decodeWorldSave(Protocol.encodeWorldSave({
			op = Protocol.SaveOp.State,
			state = Protocol.SaveState.Unavailable,
			text = "no API",
		})) :: any
		t.eq(saveState.state, Protocol.SaveState.Unavailable)
		t.eq(saveState.text, "no API")
		t.eq(
			(Protocol.decodeWorldSave(Protocol.encodeWorldSave({ op = Protocol.SaveOp.Saving }))).op,
			Protocol.SaveOp.Saving
		)
		local wrong = buffer.create(2)
		buffer.writeu8(wrong, 0, Protocol.SaveOp.State)
		buffer.writeu8(wrong, 1, 9)
		t.eq(Protocol.decodeWorldSave(wrong), nil, "an unknown state")
		t.ok(Protocol.ClientMessage.WorldAction > Protocol.ClientMessage.EnterWorld)
		t.ok(Protocol.ServerMessage.WorldSave > Protocol.ServerMessage.CreateWorldResult)
	end)

	--[[ The client's rules ]]

	t.test("world save: the Load World list, its buttons, the delete question, the icon and the toast", function()
		local Protocol = require(shared.Net.Protocol)
		local WorldListRules = require(client.Ui.WorldListRules)
		local entry = {
			id = "w0000abcd",
			name = "Island",
			worldType = "superflat",
			seed = "1",
			gameMode = GameMode.CREATIVE,
			lastPlayed = 0,
			bytes = 1.4 * 1048576,
		}
		local name, second, third = WorldListRules.row(entry, { year = 2026, month = 10, day = 7, hour = 14, min = 3 })
		t.eq(name, "Island")
		t.eq(second, "Superflat, last played 2026-10-07 14:03")
		t.eq(third, "Creative Mode, 1.4 MB")
		t.eq(WorldListRules.typeName("spec.gone"), "spec.gone")
		local none = WorldListRules.buttons(false, false)
		t.eq(none.play, false)
		t.eq(none.cancel, true)
		t.eq(WorldListRules.buttons(true, false).delete, true)
		t.eq(WorldListRules.buttons(true, true).play, false, "not while a request is out")
		t.eq(WorldListRules.keepSelection({ entry }, "w0000abcd"), "w0000abcd")
		t.eq(WorldListRules.keepSelection({ entry }, "w9"), nil, "deleted: no selection")
		local question, warning = WorldListRules.deleteQuestion("Island")
		t.eq(question, "Are you sure you want to delete this world?")
		t.eq(warning, "'Island' will be lost forever! (A long time!)")
		t.eq(WorldListRules.loading(12, 40), "Loading world: 12 / 40")
		t.eq(WorldListRules.loading(0, 0), "Loading world...")
		t.eq(WorldListRules.iconShown(true, 99), true)
		t.eq(WorldListRules.iconShown(false, 0.5), true, "a quick save still shows")
		t.eq(WorldListRules.iconShown(false, WorldListRules.MIN_SHOW + 0.1), false)
		for i = 0, 20 do
			local bob = WorldListRules.bob(i / 10)
			t.ok(bob >= 0 and bob <= WorldListRules.BOB)
		end
		local heading, line, warn = WorldListRules.toast({
			op = Protocol.SaveOp.Saved,
			ok = true,
			sizes = true,
			bytes = 1.4 * 1048576,
			max = 64 * 1048576,
			largest = 0.3 * 1048576,
			keyLimit = 4194304,
		})
		t.eq(heading, "World saved")
		t.eq(line, "1.4 MB of 64 MB (largest region 0.3 / 4 MB)")
		t.eq(warn, false)
		local failed, why, red =
			WorldListRules.toast({ op = Protocol.SaveOp.Saved, ok = false, sizes = true, text = "too large" })
		t.eq(failed, "World not saved")
		t.eq(why, "too large")
		t.eq(red, true)
		t.eq(
			(WorldListRules.toast({ op = Protocol.SaveOp.Saved, ok = true, sizes = false })),
			nil,
			"players see only the icon"
		)
	end)
end
