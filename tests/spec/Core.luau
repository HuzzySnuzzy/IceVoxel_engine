return function(t, shared, require)
	local Hash = require(shared.Util.Hash)
	local Coords = require(shared.World.Coords)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Blocks = require(shared.Blocks)
	local LodTree = require(shared.World.LodTree)
	local Config = require(shared.Config)

	t.test("mul32 matches exact 32-bit multiplication", function()
		t.eq(Hash.mul32(0xFFFFFFFF, 0xFFFFFFFF), 1)
		t.eq(Hash.mul32(0x12345678, 0x9ABCDEF1), 0x366176F8) -- (0x12345678 * 0x9ABCDEF1) mod 2^32
		t.eq(Hash.mul32(65536, 65536), 0)
		t.eq(Hash.mul32(3, 5), 15)
	end)

	t.test("hashes are deterministic, in range and sensitive to every input", function()
		local a = Hash.hash3(1, 2, 3, 4)
		t.eq(a, Hash.hash3(1, 2, 3, 4))
		t.ok(a >= 0 and a < 2 ^ 32 and a == math.floor(a))
		t.ok(a ~= Hash.hash3(2, 2, 3, 4) and a ~= Hash.hash3(1, 3, 3, 4))
		t.ok(a ~= Hash.hash3(1, 2, 4, 4) and a ~= Hash.hash3(1, 2, 3, 5))
		t.ok(Hash.hash3(1, -5, 0, -7) ~= Hash.hash3(1, 5, 0, 7), "negative coordinates")
	end)

	t.test("rng is uniform-ish and respects bounds", function()
		local rng = Hash.rng(1234)
		local counts = { 0, 0, 0, 0 }
		for _ = 1, 40000 do
			local v = rng:int(1, 4)
			t.ok(v >= 1 and v <= 4)
			counts[v] += 1
		end
		for i = 1, 4 do
			t.near(counts[i], 10000, 500, `bucket {i}`)
		end
		local f = Hash.rng(99):float()
		t.ok(f >= 0 and f < 1)
	end)

	t.test("coordinate keys round-trip", function()
		for _, v in { { 0, 0, 0 }, { 4, -3, 7 }, { 0, 100000, -100000 }, { 3, -1, -1 } } do
			local level, nx, nz = Coords.decodeNodeKey(Coords.nodeKey(v[1], v[2], v[3]))
			t.eq(level, v[1])
			t.eq(nx, v[2])
			t.eq(nz, v[3])
		end
		t.eq(Coords.nodeKey(0, -4, 9), Coords.chunkKey(-4, 9), "LOD 0 node key == chunk key")
		local x, y, z = Coords.decodePosKey(Coords.posKey(-123456, 255, 98765))
		t.eq(x, -123456)
		t.eq(y, 255)
		t.eq(z, 98765)
		local cx, cz, lx, lz = Coords.blockToChunk(-1, 17)
		t.eq(cx, -1)
		t.eq(cz, 1)
		t.eq(lx, 15)
		t.eq(lz, 1)
	end)

	t.test("chunk layout indices", function()
		local data = ChunkLayout.create(8)
		t.eq(ChunkLayout.height(data), 8)
		ChunkLayout.set(data, 3, 5, 7, 42)
		t.eq(ChunkLayout.get(data, 3, 5, 7), 42)
		t.eq(ChunkLayout.getPadded(data, 3, 5, 7), 42)
		ChunkLayout.setPadded(data, -1, 2, 16, 9)
		t.eq(buffer.readu16(data, ChunkLayout.index(0, 2, 17) * 2), 9)
		local lx, y, lz = ChunkLayout.fromLocalIndex(ChunkLayout.localIndex(15, 200, 4))
		t.eq(lx, 15)
		t.eq(y, 200)
		t.eq(lz, 4)
	end)

	t.test("block registry", function()
		t.eq(Blocks.id.Air, 0)
		t.eq(Blocks.get(Blocks.id.Stone).name, "Stone")
		t.ok(not pcall(function()
			return Blocks.id.NotABlock
		end), "unknown names error")
		-- All water levels share one appearance so they merge into the same boxes.
		local water = Blocks.get(Blocks.fluidId("Water", 0))
		for level = 1, 8 do
			t.eq(Blocks.get(Blocks.fluidId("Water", level)).appearance, water.appearance)
		end
		t.ok(Blocks.isOpaque(Blocks.id.Stone) and not Blocks.isOpaque(Blocks.id.Glass))
		t.ok(Blocks.isReplaceable(Blocks.id.Air) and Blocks.isReplaceable(water.id))
		t.ok(Blocks.isTargetable(Blocks.id.Glass) and not Blocks.isTargetable(water.id))
		t.eq(buffer.readu8(Blocks.cullLutHiddenCaves, Blocks.CAVE_AIR), 1)
		t.eq(buffer.readu8(Blocks.cullLut, Blocks.CAVE_AIR), 0)
	end)

	t.test("LOD tree covers the view without overlaps", function()
		for _, pos in { { 0, 0 }, { 1000.5, -333.25 }, { -4096, 77 } } do
			local nodes = LodTree.select(pos[1], pos[2])
			-- Rasterise at LOD 0 chunk resolution around the viewer; each chunk must be covered once.
			local covered: { [number]: number } = {}
			local count = 0
			for key, level in nodes do
				count += 1
				local _, nx, nz = Coords.decodeNodeKey(key)
				local span = bit32.lshift(1, level)
				for cz = nz * span, nz * span + span - 1 do
					for cx = nx * span, nx * span + span - 1 do
						local k = Coords.chunkKey(cx, cz)
						covered[k] = (covered[k] or 0) + 1
					end
				end
			end
			for _, n in covered do
				t.eq(n, 1, "chunk covered more than once")
			end
			local radius = Config.Lod.ViewDistance // Config.ChunkSize - 1
			local ccx, ccz = pos[1] // Config.ChunkSize, pos[2] // Config.ChunkSize
			for cz = ccz - radius, ccz + radius, 7 do
				for cx = ccx - radius, ccx + radius, 7 do
					local dx, dz = (cx - ccx) * Config.ChunkSize, (cz - ccz) * Config.ChunkSize
					if dx * dx + dz * dz < (Config.Lod.ViewDistance * 0.9) ^ 2 then
						t.ok(covered[Coords.chunkKey(cx, cz)], "gap inside the view distance")
					end
				end
			end
			-- The chunk under the viewer is full detail.
			local level = nodes[Coords.nodeKey(0, ccx, ccz)]
			t.eq(level, 0, "viewer chunk is LOD 0")
			t.ok(count < 1000, `reasonable node count ({count})`)
		end
	end)

	t.test("LOD hysteresis keeps leaves until the viewer is clearly closer", function()
		local first = LodTree.select(0, 0)
		local again = LodTree.select(0.5, 0.5, first)
		local changed = 0
		for key in again do
			if not first[key] then
				changed += 1
			end
		end
		t.eq(changed, 0, "tiny movement changes nothing")
	end)
end
