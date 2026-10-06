--[[
	Far materials (Config.Render.FarMaterials, the "Far Materials" setting): merged far levels split
	by look.
	  * MeshGeometry's looks, pure: grouping by look (every quad once, in its look, looks in order,
	    the triangle cap and bands per look), the LookMinShare / MaxLooks / LookRemainder rule,
	    vertex colours, box-mapped UVs (tile edges on block edges), and one look giving exactly the
	    meshes of before.
	  * MeshOverlay in a small fake world (instances as plain tables, the builder thread as a
	    coroutine, EditableMesh and AssetService faked): `setLooks` and `plainLevel`, builds of old
	    looks dropped, regions merged only once their members are current, and real builds making
	    one MeshPart per look in its material, variant and transparency, UVs only where textured.
	Look callbacks are fakes with the shape of Rendering/TextureLooks' (`lookOf`, `lookInfo`,
	`plainRgb`), except in the integration test, which runs TextureLooks itself on the pack made
	neutral (ShowMissing off, no Average), so filling the pack never breaks it.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local Loader = require("../lib/Loader")

local Vector3 = roblox.Vector3
local Vector2 = roblox.Vector2
local CFrame = roblox.CFrame
local Color3 = roblox.Color3

--[[ A small fake world for MeshOverlay ]]

-- Enums lune does not know (EditableMesh's), on top of its own.
local FakeEnum = setmetatable({
	MeshAttribute = {
		Vertex = { Name = "Vertex" },
		Face = { Name = "Face" },
		Color = { Name = "Color" },
		UV = { Name = "UV" },
	},
	CreateContentResult = { Success = { Name = "Success" } },
}, { __index = roblox.Enum })

local function newWorld(shared: any, sharedRequire: (any) -> any): any
	local world: any = { clock = 0, frame = 0, heartbeat = {}, threads = {}, warnings = {}, meshes = {} }
	local function new(class: string): any
		local o: any = {
			ClassName = class,
			Name = class,
			Parent = nil,
			Material = roblox.Enum.Material.Plastic,
			MaterialVariant = "",
			Transparency = 0,
			Reflectance = 0,
			CastShadow = true,
			Size = Vector3.new(1, 1, 1),
			destroyed = false,
		}
		function o.Destroy(self: any)
			self.destroyed = true
			self.Parent = nil
		end
		return o
	end
	world.new = new

	-- EditableMesh: vertices, faces, and one colour id and one UV id per vertex (given when its
	-- first face is added, as in Roblox), with the values set through BatchSetValues.
	local function editableMesh(): any
		local em: any = {}
		local function reset()
			em.positions, em.colorId, em.uvId, em.values, em.faces, em.nextId = {}, {}, {}, {}, 0, 0
		end
		reset()
		local function newId(): number
			em.nextId += 1
			return em.nextId
		end
		function em.Clear(_self: any)
			reset()
		end
		function em.BatchAdd(_self: any, attribute: any, data: { any }): { number }
			local ids = {}
			for _, item in data do
				if attribute == FakeEnum.MeshAttribute.Vertex then
					local id = newId()
					em.positions[id] = item
					table.insert(ids, id)
				else
					for _, v in item do
						if em.colorId[v] == nil then
							em.colorId[v] = newId()
							em.uvId[v] = newId()
						end
					end
					em.faces += 1
					table.insert(ids, newId())
				end
			end
			return ids
		end
		function em.BatchGetVertexAttributes(_self: any, attribute: any, vertexIds: { number }): { { number } }
			if world.failAttribute == attribute then
				error(`no {attribute.Name} here`)
			end
			local out = {}
			for _, v in vertexIds do
				table.insert(out, { if attribute == FakeEnum.MeshAttribute.Color then em.colorId[v] else em.uvId[v] })
			end
			return out
		end
		function em.BatchSetValues(_self: any, ids: { number }, values: { any })
			for i, id in ids do
				em.values[id] = values[i]
			end
		end
		return em
	end

	local services: { [string]: any } = {
		ReplicatedStorage = {
			WaitForChild = function(_, name: string)
				assert(name == "IceVoxel")
				return shared
			end,
		},
		RunService = {
			Heartbeat = {
				Connect = function(_, fn: (number) -> ())
					world.heartbeat[fn] = true
					return {
						Disconnect = function()
							world.heartbeat[fn] = nil
						end,
					}
				end,
			},
		},
		AssetService = {
			CreateEditableMesh = function()
				return editableMesh()
			end,
			-- The baked content: every vertex's position, colour and UV (nil: never written).
			CreateDataModelContentAsync = function(_, content: any)
				local em = content.object
				local vertices = {}
				for id, position in em.positions do
					local colorId, uvId = em.colorId[id], em.uvId[id]
					table.insert(vertices, {
						id = id,
						position = position,
						color = if colorId then em.values[colorId] else nil,
						uv = if uvId then em.values[uvId] else nil,
					})
				end
				table.sort(vertices, function(a, b)
					return a.id < b.id
				end)
				return FakeEnum.CreateContentResult.Success, { vertices = vertices, faces = em.faces }
			end,
			CreateMeshPartAsync = function(_, baked: any)
				if world.onMeshPart then
					world.onMeshPart(baked)
				end
				local min = { math.huge, math.huge, math.huge }
				local max = { -math.huge, -math.huge, -math.huge }
				for _, vertex in baked.vertices do
					local p = vertex.position
					for a, value in { p.X, p.Y, p.Z } do
						min[a] = math.min(min[a], value)
						max[a] = math.max(max[a], value)
					end
				end
				local part = new("MeshPart")
				part.Size = Vector3.new(max[1] - min[1], max[2] - min[2], max[3] - min[3])
				world.meshes[part] = baked
				return part
			end,
		},
		Lighting = new("Lighting"),
		UserInputService = { TouchEnabled = false, KeyboardEnabled = true },
	}
	world.game = {
		GetService = function(_, name: string)
			return services[name] or error(`no fake service {name}`)
		end,
	}
	world.workspace = { CurrentCamera = { CFrame = CFrame.new(0, 100, 0) } }
	world.os = {
		clock = function(): number
			return world.clock
		end,
		time = os.time,
	}
	-- Threads (the builder): run at once until they wait, resumed every frame.
	world.task = {
		spawn = function(fn: (...any) -> (), ...: any)
			local thread = coroutine.create(fn)
			table.insert(world.threads, thread)
			local ok, err = coroutine.resume(thread, ...)
			assert(ok, err)
		end,
		defer = function() end,
		wait = function(): number
			if not coroutine.isyieldable() then
				return 0
			end
			return coroutine.yield()
		end,
	}
	world.warn = function(...)
		table.insert(world.warnings, table.concat({ ... }, " "))
	end
	world.Instance = { new = new }
	world.Content = {
		fromObject = function(o: any)
			return { object = o }
		end,
	}

	-- One frame: the clock, Heartbeat, the threads (`longFrame`: the next frame takes that long).
	function world.tick(dt: number?)
		local step = dt or world.longFrame or 1 / 60
		world.longFrame = nil
		world.frame += 1
		world.clock += step
		for fn in table.clone(world.heartbeat) do
			fn(step)
		end
		for _, thread in world.threads do
			if coroutine.status(thread) == "suspended" then
				local ok, err = coroutine.resume(thread, step)
				assert(ok, err)
			end
		end
	end

	-- Loads src/client/Rendering modules with this world's globals.
	local cache: { [string]: any } = {}
	local folder: any = setmetatable({}, {
		__index = function(_, name: string)
			return { __fake = true, Name = name, path = `src/client/Rendering/{name}.luau` }
		end,
	})
	local GLOBALS =
		"script, require, game, workspace, Instance, Vector3, Vector2, CFrame, Color3, Enum, Content, os, task, warn"
	local function req(node: any): any
		if type(node) == "table" and rawget(node, "__fake") then
			local cached = cache[node.path]
			if cached ~= nil then
				return cached
			end
			local lines = string.split(fs.readFile(node.path), "\n")
			local i = 1
			while lines[i] and string.sub(lines[i], 1, 3) == "--!" do
				i += 1
			end
			lines[i] = `local {GLOBALS} = ...; ` .. (lines[i] or "")
			local chunk = luau.load(table.concat(lines, "\n"), { debugName = node.path })
			local script = { Parent = folder, Name = node.Name }
			local result = chunk(
				script,
				req,
				world.game,
				world.workspace,
				world.Instance,
				Vector3,
				Vector2,
				CFrame,
				Color3,
				FakeEnum,
				world.Content,
				world.os,
				world.task,
				world.warn
			)
			cache[node.path] = result
			return result
		end
		return sharedRequire(node)
	end
	function world.load(name: string): any
		return req(folder[name])
	end
	world.root = new("Folder")
	return world
end

return function(t, shared, require, _server, _client)
	local Config = require(shared.Config)
	local Blocks = require(shared.Blocks)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local QuadMesher = require(shared.Meshing.QuadMesher)
	local GreedyMesher = require(shared.Meshing.GreedyMesher)
	local MeshGeometry = require(shared.Meshing.MeshGeometry)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)

	local SIZE = ChunkLayout.SIZE
	local BLOCK = Config.BlockSize
	local PLAIN = MeshGeometry.PLAIN
	local QUAD = QuadMesher.QUAD_BYTES
	local FarMeshes = Config.Render.FarMeshes

	-- Quads of generated terrain at level `level`, nodes (nx .. nx + n - 1, nz).
	local function terrain(level: number, nx: number, nz: number, n: number): { any }
		local gen = TerrainGenerator.new(777)
		local step, stepY = ChunkLayout.steps(level)
		local scale, scaleY = step * BLOCK, stepY * BLOCK
		local nodes = {}
		for i = 0, n - 1 do
			local r = gen.generate(level, nx + i, nz)
			local y0, y1 = GreedyMesher.activeRange(r.solidBelow, r.emptyAbove, r.height)
			local quads, count = QuadMesher.mesh(r.data, r.height, y0, y1, true)
			table.insert(nodes, {
				quads = quads,
				count = count,
				ox = (nx + i) * SIZE * scale,
				oz = nz * SIZE * scale,
				scale = scale,
				scaleY = scaleY,
			})
		end
		return nodes
	end

	local function build(nodes: { any }, grow: number, maxTriangles: number, options: any?): { MeshGeometry.Mesh }
		local builder = MeshGeometry.builder(BLOCK, grow, maxTriangles, options)
		for _, node in nodes do
			builder:add(node.quads, node.count, node.ox, node.oz, node.scale, node.scaleY)
		end
		return builder:finish()
	end

	-- An appearance's colour (0..1), the fake plain colour (half of it), and a look per appearance.
	local function colorOf(appearance: number): (number, number, number)
		local c = Blocks.appearances[appearance].color
		return c[1] / 255, c[2] / 255, c[3] / 255
	end
	local function plainOf(appearance: number): (number, number, number)
		local r, g, b = colorOf(appearance)
		return r / 2, g / 2, b / 2
	end

	-- Is quad q of a mesh its anchor (a MIN_EXTENT square facing down)?
	local function isAnchor(mesh: MeshGeometry.Mesh, q: number): boolean
		local p = mesh.positions
		local o = q * 12
		local side = math.abs(p[o + 4] - p[o + 1]) + math.abs(p[o + 6] - p[o + 3])
		return p[o + 2] == p[o + 5] and p[o + 2] == p[o + 8] and math.abs(side - MeshGeometry.MIN_EXTENT) < 1e-9
	end

	-- The outward direction (QuadMesher) of quad q of a mesh, from its winding.
	local function dirOf(mesh: MeshGeometry.Mesh, q: number): number
		local p = mesh.positions
		local o = q * 12
		local ux, uy, uz = p[o + 4] - p[o + 1], p[o + 5] - p[o + 2], p[o + 6] - p[o + 3]
		local vx, vy, vz = p[o + 10] - p[o + 1], p[o + 11] - p[o + 2], p[o + 12] - p[o + 3]
		local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
		if math.abs(nx) >= math.abs(ny) and math.abs(nx) >= math.abs(nz) then
			return if nx > 0 then 0 else 1
		elseif math.abs(ny) >= math.abs(nz) then
			return if ny > 0 then 2 else 3
		end
		return if nz > 0 then 4 else 5
	end

	--[[ MeshGeometry ]]

	t.test("far looks: one look gives exactly the meshes without looks, plus their colours", function()
		local nodes = terrain(2, 40, -60, 4)
		local before = build(nodes, FarMeshes.Overlap, 400)
		local calls = 0
		local after = build(nodes, FarMeshes.Overlap, 400, {
			lookOf = function(appearance: number, _face: number): (number, number, number, number)
				calls += 1
				local r, g, b = colorOf(appearance)
				return PLAIN, r, g, b
			end,
		})
		t.ok(#before > 1, "split at the cap")
		t.eq(#after, #before, "same meshes")
		for i, mesh in after do
			local old = before[i]
			t.eq(mesh.quads, old.quads)
			t.eq(mesh.look, PLAIN)
			t.eq(old.look, PLAIN)
			t.eq(old.colors, nil, "no colours without looks")
			t.eq(mesh.uvs, nil, "no UVs without uvStuds")
			t.eq(table.concat(mesh.positions, ","), table.concat(old.positions, ","), "positions")
			t.eq(table.concat(mesh.appearances, ","), table.concat(old.appearances, ","), "appearances")
			t.eq(table.concat(mesh.center, ","), table.concat(old.center, ","), "centre")
			t.eq(table.concat(mesh.size, ","), table.concat(old.size, ","), "size")
			local colors = mesh.colors :: { number }
			t.eq(#colors, mesh.quads * 3, "a colour per quad")
			for q = 1, mesh.quads do
				local r, g, b = colorOf(mesh.appearances[q])
				t.ok(colors[q * 3 - 2] == r and colors[q * 3 - 1] == g and colors[q * 3] == b, "the look's colour")
			end
		end
		-- (lookOf once per appearance and face in a builder.)
		local total = 0
		for _, node in nodes do
			total += node.count
		end
		t.ok(calls < total / 4, `lookOf calls {calls} for {total} quads`)
	end)

	t.test("far looks: quads grouped by look, each once and in order, looks ascending, cap per mesh", function()
		local nodes = terrain(2, 40, -60, 4)
		local function lookOf(appearance: number, face: number): (number, number, number, number)
			-- Tops apart from sides, as per-face looks would be.
			local look = 1 + appearance % 3 + (if face == 2 then 3 else 0)
			local r, g, b = colorOf(appearance)
			return look, r, g, b
		end
		local meshes = build(nodes, 0, 400, { lookOf = lookOf })
		local again = build(nodes, 0, 400, { lookOf = lookOf })
		-- Expected: every input quad, per look, in input order.
		local expected: { [number]: { { number } } } = {}
		for _, node in nodes do
			for i = 0, node.count - 1 do
				local appearance = buffer.readu16(node.quads, i * QUAD + 12) % QuadMesher.KEY_STRIDE
				local look = lookOf(appearance, buffer.readu16(node.quads, i * QUAD))
				expected[look] = expected[look] or {}
				table.insert(
					expected[look],
					{ QuadMesher.corners(node.quads, i, node.ox, node.oz, node.scale, node.scaleY, BLOCK, 0) }
				)
			end
		end
		local index: { [number]: number } = {}
		local lastLook = -1
		t.eq(#again, #meshes, "deterministic")
		for m, mesh in meshes do
			t.ok(mesh.quads * 2 <= 400, "cap respected")
			t.ok(mesh.look >= lastLook, "looks in ascending order")
			lastLook = mesh.look
			t.eq(table.concat(mesh.positions, ","), table.concat(again[m].positions, ","), "deterministic")
			local want = expected[mesh.look]
			for q = 0, mesh.quads - 1 do
				if isAnchor(mesh, q) then
					t.eq(q, mesh.quads - 1, "an anchor quad comes last")
					break
				end
				local at = (index[mesh.look] or 0) + 1
				local corners = want[at]
				index[mesh.look] = at
				local c = mesh.center
				for k = 1, 12 do
					local got = mesh.positions[q * 12 + k] + c[(k - 1) % 3 + 1]
					t.ok(math.abs(got - corners[k]) < 1e-6, "corner of the next quad of its look")
				end
				local look = lookOf(mesh.appearances[q + 1], dirOf(mesh, q))
				t.eq(look, mesh.look, "a quad in its own look")
			end
		end
		for look, list in expected do
			t.eq(index[look], #list, `every quad of look {look} placed once`)
		end
	end)

	-- Flat +Y quads (du x dv cells each, at x = 0, z stacked) of the given appearances.
	local function sheets(list: { { number } }): buffer
		local quads = buffer.create(#list * QUAD)
		local z = 0
		for i, item in list do
			local o = (i - 1) * QUAD
			buffer.writeu16(quads, o, 2)
			buffer.writeu16(quads, o + 4, 4)
			buffer.writeu16(quads, o + 6, z)
			buffer.writeu16(quads, o + 8, item[2])
			buffer.writeu16(quads, o + 10, item[3])
			buffer.writeu16(quads, o + 12, item[1])
			z += item[2]
		end
		return quads
	end

	t.test("far looks: the largest looks keep their meshes; the rest is plain or joins the largest", function()
		-- Five appearances, a look each, covering 60, 25, 8, 4 and 3 % of the area.
		local apps = {}
		for app = 1, #Blocks.appearances do
			if Blocks.appearances[app].kind == Blocks.KIND_OPAQUE and #apps < 5 then
				table.insert(apps, app)
			end
		end
		local lookByApp: { [number]: number } = {}
		local areas = { 60, 25, 8, 4, 3 }
		local list = {}
		for i, app in apps do
			lookByApp[app] = i
			table.insert(list, { app, areas[i], 1 })
		end
		local quads = sheets(list)
		local function lookOf(appearance: number, _face: number): (number, number, number, number)
			local r, g, b = colorOf(appearance)
			return lookByApp[appearance], r, g, b
		end
		local function run(options: any): { [number]: { number } }
			options.lookOf = lookOf
			local builder = MeshGeometry.builder(BLOCK, 0, 1000, options)
			builder:add(quads, #list, 0, 0, BLOCK, BLOCK)
			-- Per look: the appearances of its quads (anchors left out) and their colours.
			local out: { [number]: { number } } = {}
			for _, mesh in builder:finish() do
				local colors = mesh.colors :: { number }
				for q = 1, mesh.quads do
					if dirOf(mesh, q - 1) == 2 then
						out[mesh.look] = out[mesh.look] or {}
						table.insert(out[mesh.look], mesh.appearances[q])
						local r, g = colors[q * 3 - 2], colors[q * 3 - 1]
						table.insert(out[mesh.look], r * 1000 + g)
					end
				end
			end
			return out
		end
		local function looks(out: { [number]: { number } }): string
			local ids = {}
			for id in out do
				table.insert(ids, id)
			end
			table.sort(ids)
			return table.concat(ids, ",")
		end
		local function colourKey(r: number, g: number): number
			return r * 1000 + g
		end

		-- Every look covering 5 %, the rest plain in the plain colour.
		local out = run({ minShare = 0.05, maxLooks = 4, remainder = "plain", plainOf = plainOf })
		t.eq(looks(out), "0,1,2,3", "looks 4 and 5 are under 5 %")
		local plain = out[PLAIN]
		t.eq(#plain, 4, "two quads in the plain remainder")
		for k = 1, #plain, 2 do
			local r, g = plainOf(plain[k])
			t.eq(plain[k + 1], colourKey(r, g), "in its plain colour")
		end
		local r1, g1 = colorOf(apps[1])
		t.eq(out[1][2], colourKey(r1, g1), "kept looks keep their colour")
		-- At most MaxLooks.
		t.eq(looks(run({ minShare = 0.05, maxLooks = 2, plainOf = plainOf })), "0,1,2")
		-- Without plainOf the remainder keeps its own colours.
		local own = run({ minShare = 0.05, maxLooks = 4 })[PLAIN]
		local r4, g4 = colorOf(own[1])
		t.eq(own[2], colourKey(r4, g4), "own colour")
		-- "largest": the remainder joins the largest kept look the `opaque` test accepts.
		local joined = run({
			minShare = 0.05,
			maxLooks = 4,
			remainder = "largest",
			opaque = function(look: number): boolean
				return look ~= 1
			end,
		})
		t.eq(looks(joined), "1,2,3", "no plain mesh")
		t.eq(#joined[2], 6, "looks 4 and 5 joined look 2 (look 1 is see-through)")
		local r5, g5 = colorOf(joined[2][5])
		t.eq(joined[2][6], colourKey(r5, g5), "in their own colour")
		-- No opaque look kept: plain after all.
		local none = run({
			minShare = 0.05,
			remainder = "largest",
			opaque = function(_look: number): boolean
				return false
			end,
		})
		t.eq(looks(none), "0,1,2,3")
		-- No rule: every look its own.
		t.eq(looks(run({})), "1,2,3,4,5")
	end)

	t.test("far looks: a face joining the largest look is tinted to what it averages to", function()
		-- Stone (look 1: a texture tinted to its colour) and one coal ore on it (look 2: a texture
		-- in its own colours, so its vertex colour is white), under LookMinShare: the ore joins.
		local data = ChunkLayout.create(8)
		for z = 0, SIZE - 1 do
			for x = 0, SIZE - 1 do
				for y = 0, 2 do
					ChunkLayout.set(data, x, y, z, Blocks.id.Stone)
				end
			end
		end
		ChunkLayout.set(data, 5, 3, 5, Blocks.id.CoalOre)
		local quads, count = QuadMesher.mesh(data, 8, 0, 8, true)
		local STONE_APP = Blocks.get(Blocks.id.Stone).appearance
		local ORE = Blocks.get(Blocks.id.CoalOre).appearance
		-- What the ore averages to on screen (plainOf).
		local ORE_PLAIN = { 0.3, 0.25, 0.2 }
		local function oreColours(
			stoneLook: number,
			averageOf: ((look: number) -> { number }?)?
		): ({ { number } }, number?)
			local builder = MeshGeometry.builder(BLOCK, 0, 20000, {
				lookOf = function(appearance: number, _face: number): (number, number, number, number)
					if appearance == ORE then
						return 2, 1, 1, 1
					end
					return stoneLook, 0.5, 0.5, 0.5
				end,
				plainOf = function(appearance: number, _face: number): (number, number, number)
					if appearance == ORE then
						return ORE_PLAIN[1], ORE_PLAIN[2], ORE_PLAIN[3]
					end
					return 0.5, 0.5, 0.5
				end,
				minShare = 0.05,
				remainder = "largest",
				averageOf = averageOf,
			})
			builder:add(quads, count, 0, 0, BLOCK, BLOCK)
			local out: { { number } } = {}
			local look = nil
			for _, mesh in builder:finish() do
				local colors = mesh.colors :: { number }
				for q = 1, mesh.quads do
					if mesh.appearances[q] == ORE then
						table.insert(out, { colors[q * 3 - 2], colors[q * 3 - 1], colors[q * 3] })
						look = mesh.look
					end
				end
			end
			return out, look
		end
		t.ok(STONE_APP ~= ORE)
		-- An unknown average: the ore's plain colour, not the white meant for its own texture.
		local got, look = oreColours(1, nil)
		t.eq(look, 1, "joined stone's look")
		t.eq(#got, 5, "the ore's five faces")
		for _, c in got do
			t.ok(c[1] == ORE_PLAIN[1] and c[2] == ORE_PLAIN[2] and c[3] == ORE_PLAIN[3], "its plain colour")
		end
		-- A known average: stone's texture times the tint averages the plain colour (linear light).
		local AVERAGE = { 0.5, 0.45, 0.4 }
		got = oreColours(1, function(id: number): { number }?
			return if id == 1 then AVERAGE else nil
		end)
		local toLinear = function(c: number): number
			return if c <= 0.04045 then c / 12.92 else ((c + 0.055) / 1.055) ^ 2.4
		end
		for _, c in got do
			for k = 1, 3 do
				t.ok(c[k] < 1, "darkens")
				t.ok(math.abs(toLinear(AVERAGE[k]) * toLinear(c[k]) - toLinear(ORE_PLAIN[k])) < 1e-9, "averages it")
			end
		end
		-- A texture too dark for it: the tint stops at 1.
		got = oreColours(1, function(_id: number): { number }?
			return { 0.1, 0.1, 0.1 }
		end)
		t.ok(got[1][1] == 1 and got[1][2] == 1 and got[1][3] == 1, "at most 1")
		-- Joining the plain look (an untextured block in SmoothPlastic): the plain colour itself.
		got, look = oreColours(PLAIN, function(_id: number): { number }?
			error("the plain look has no texture")
		end)
		t.eq(look, PLAIN)
		t.ok(got[1][1] == ORE_PLAIN[1] and got[1][2] == ORE_PLAIN[2] and got[1][3] == ORE_PLAIN[3], "plain colour")
	end)

	t.test("far looks: UVs follow world studs per face, tile edges on block edges, small numbers", function()
		local S = FarMeshes.UvStuds
		t.eq(S, BLOCK, "one tile per block face")
		for _, level in { 2, 4 } do
			local nodes = terrain(level, 3, -2, 2)
			local meshes = build(nodes, 0, 2000, {
				lookOf = function(appearance: number, _face: number): (number, number, number, number)
					local r, g, b = colorOf(appearance)
					return appearance % 2, r, g, b
				end,
				uvStuds = S,
			})
			for _, mesh in meshes do
				local uvs = mesh.uvs :: { number }
				t.eq(#uvs, mesh.quads * 8, "u, v per vertex")
				-- Where the same world point appears twice on faces of one direction, same UV.
				local seen: { [string]: string } = {}
				for q = 0, mesh.quads - 1 do
					local dir = dirOf(mesh, q)
					for v = 0, 3 do
						local k = q * 4 + v
						local x = mesh.positions[k * 3 + 1] + mesh.center[1]
						local y = mesh.positions[k * 3 + 2] + mesh.center[2]
						local z = mesh.positions[k * 3 + 3] + mesh.center[3]
						local u, w = uvs[k * 2 + 1], uvs[k * 2 + 2]
						-- Linear in world studs with a whole-tile offset: tile edges on block edges.
						local wu, ww = MeshGeometry.uv(dir, x / S, y / S, z / S)
						local du, dw = u - wu, w - ww
						t.ok(math.abs(du - math.round(du)) < 1e-6, `u offset {du} is whole tiles`)
						t.ok(math.abs(dw - math.round(dw)) < 1e-6, `v offset {dw} is whole tiles`)
						t.ok(math.abs(u) <= 2048 / S + 1 and math.abs(w) <= 2048 / S + 1, "small numbers")
						local key = `{dir}:{x},{y},{z}`
						local value = `{u},{w}`
						t.ok(seen[key] == nil or seen[key] == value, "continuous across quads")
						seen[key] = value
					end
				end
			end
		end
		-- The mapping: u to the right and v down seen from outside each face (up is up the image).
		local function uv(dir: number, x: number, y: number, z: number): string
			local u, v = MeshGeometry.uv(dir, x, y, z)
			return `{u},{v}`
		end
		t.eq(uv(4, 1, 2, 5), "1,-2", "+Z: east is right")
		t.eq(uv(5, 1, 2, 5), "-1,-2", "-Z: east is left")
		t.eq(uv(0, 5, 2, 1), "-1,-2", "+X: south is left")
		t.eq(uv(1, 5, 2, 1), "1,-2", "-X: south is right")
		t.eq(uv(2, 1, 5, 2), "1,2", "tops: x, z")
	end)

	t.test("far looks: tall regions are banded per look; anchors take their mesh's colour", function()
		local BAND = MeshGeometry.BAND
		local stone = Blocks.get(Blocks.id.Stone).appearance
		local dirt = Blocks.get(Blocks.id.Dirt).appearance
		local quads = buffer.create(2 * QUAD)
		-- A +X stone wall 1000 cells high and a dirt floor on the first band boundary.
		buffer.writeu16(quads, 0, 0)
		buffer.writeu16(quads, 8, 1000)
		buffer.writeu16(quads, 10, 4)
		buffer.writeu16(quads, 12, stone)
		buffer.writeu16(quads, QUAD, 2)
		buffer.writeu16(quads, QUAD + 4, BAND // BLOCK - 1)
		buffer.writeu16(quads, QUAD + 8, 4)
		buffer.writeu16(quads, QUAD + 10, 4)
		buffer.writeu16(quads, QUAD + 12, dirt)
		local builder = MeshGeometry.builder(BLOCK, 0, 1000, {
			lookOf = function(appearance: number, _face: number): (number, number, number, number)
				local r, g, b = colorOf(appearance)
				return if appearance == dirt then 7 else 3, r, g, b
			end,
			uvStuds = BLOCK,
		})
		builder:add(quads, 2, 0, 0, BLOCK, BLOCK)
		local meshes = builder:finish()
		t.eq(#meshes, 3, "the wall's two bands, then the floor")
		t.eq(meshes[1].look, 3)
		t.eq(meshes[2].look, 3)
		t.eq(meshes[3].look, 7)
		for _, mesh in meshes do
			t.ok(mesh.size[2] <= BAND + 2 * MeshGeometry.MIN_EXTENT, "fits its band")
		end
		-- The floor is flat: its anchor quad copies the floor's colour and gets UVs.
		local floor = meshes[3]
		t.eq(floor.quads, 2, "floor plus anchor")
		local colors = floor.colors :: { number }
		t.ok(colors[4] == colors[1] and colors[5] == colors[2] and colors[6] == colors[3], "anchor colour")
		t.eq(#(floor.uvs :: { number }), 16)
	end)

	--[[ MeshOverlay ]]

	local MATERIALS = roblox.Enum.Material
	-- Fake TextureLooks: looks by appearance (Grass is textured, Water see-through, Stone plain
	-- material), lookInfo, and plain colours.
	local GRASS = Blocks.get(Blocks.id.Grass).appearance
	local STONE = Blocks.get(Blocks.id.Stone).appearance
	local WATER = Blocks.get(Blocks.fluidId("Water", 0)).appearance
	local LOOKS = {
		[1] = { id = 1, material = MATERIALS.Grass, variant = "IV_grass_top", transparency = 0, reflectance = 0 },
		[2] = { id = 2, material = MATERIALS.Slate, variant = "", transparency = 0, reflectance = 0 },
		[3] = { id = 3, material = MATERIALS.Glass, variant = "", transparency = 0.4, reflectance = 0.1 },
	}
	local LOOK_OF = { [GRASS] = 1, [STONE] = 2, [WATER] = 3 }
	local function lookOf(appearance: number, _face: number): (number, number, number, number)
		local r, g, b = colorOf(appearance)
		return LOOK_OF[appearance] or PLAIN, r, g, b
	end
	local function lookInfo(id: number): any
		return LOOKS[id]
	end

	--[[
		A world with a MeshOverlay that merges level 2 regions; `builder`: run the real builder;
		`root`, `sharedRequire`: shared modules of another Loader environment.
	]]
	local function overlayWorld(builder: boolean, root: any?, sharedRequire: ((any) -> any)?): (any, any)
		local world = newWorld(root or shared, sharedRequire or require)
		local MeshOverlay = world.load("MeshOverlay")
		local overlay
		local farMeshes = (sharedRequire or require)((root or shared).Config).Render.FarMeshes
		local saved = farMeshes.Enabled
		farMeshes.Enabled = builder
		local ok, err = pcall(function()
			overlay = MeshOverlay.new(world.root)
		end)
		farMeshes.Enabled = saved
		assert(ok, err)
		if not builder then
			overlay.status = "on"
			overlay.active = true
			overlay.configured = true
		end
		return world, overlay
	end

	-- Level 2 nodes of one region, shown, with quads of a little hand-made terrain each.
	local function members(world: any, overlay: any, n: number): { any }
		local data = ChunkLayout.create(8)
		for z = 0, SIZE - 1 do
			for x = 0, SIZE - 1 do
				for y = 0, 2 do
					ChunkLayout.set(data, x, y, z, Blocks.id.Stone)
				end
				local pool = x < 6 and z < 6
				ChunkLayout.set(data, x, 3, z, if pool then Blocks.fluidId("Water", 0) else Blocks.id.Grass)
			end
		end
		ChunkLayout.set(data, 8, 4, 8, Blocks.id.Dirt)
		local quads, count = QuadMesher.mesh(data, 8, 0, 8, true)
		local nodes = {}
		for i = 0, n - 1 do
			local model = world.new("Folder")
			model.Parent = world.root
			local node = { level = 2, nx = i % 4, nz = i // 4, removed = false, model = model }
			overlay:setQuads(node, quads, count)
			overlay:onShow(node)
			table.insert(nodes, node)
		end
		return nodes
	end

	-- Steps frames until `until()` or the limit; returns the frames taken.
	local function run(world: any, overlay: any, limit: number, done: () -> boolean): number
		for frame = 1, limit do
			world.tick()
			overlay:step()
			if done() then
				return frame
			end
		end
		return limit + 1
	end

	t.test("far looks: setLooks switches merged levels between plain and their look", function()
		local _, overlay = overlayWorld(false)
		t.ok(overlay:plainLevel(2) and overlay:plainLevel(5), "merged levels plain by default")
		t.ok(not overlay:plainLevel(0) and not overlay:plainLevel(1), "full detail and level 1 never")
		local gen = overlay.lookGen
		t.eq(overlay:setLooks(false, lookOf, lookInfo, plainOf), false, "still plain")
		t.ok(overlay.lookGen > gen, "a new look generation all the same")
		t.ok(overlay:plainLevel(2))
		t.eq(overlay:setLooks(true, lookOf, lookInfo, plainOf), true, "merged levels change look")
		t.ok(not overlay:plainLevel(2) and overlay:mergedLevel(2), "merged, not plain")
		t.eq(overlay:setLooks(true, lookOf, lookInfo, plainOf), false)
		t.eq(overlay:setLooks(false, lookOf, lookInfo), true, "and back")
		-- Meshes off from the start: nothing is plain, nothing changes.
		overlay.configured = false
		t.eq(overlay:setLooks(true, lookOf, lookInfo), false)
		t.ok(not overlay:plainLevel(2))
	end)

	t.test("far looks: builds of old looks are dropped; meshes demoted on new looks", function()
		local world, overlay = overlayWorld(false)
		overlay:setLooks(false, lookOf, lookInfo, plainOf)
		local nodes = members(world, overlay, 4)
		t.ok(run(world, overlay, 600, function()
			return overlay.pending ~= nil
		end) <= 600, "a build starts")
		local job = overlay.pending
		t.eq(job.payload.lookGen, overlay.lookGen, "the job keeps its look generation")
		t.ok(job.payload.options and job.payload.options.lookOf, "and its looks")
		-- New looks while it builds: it is asked to stop, and dropped when it comes back.
		overlay:setLooks(true, lookOf, lookInfo, plainOf)
		t.ok(overlay.abort, "the running build stops")
		overlay.pending = nil
		local late = world.new("MeshPart")
		table.insert(overlay.done, { job = job, parts = { late }, triangles = 2 })
		overlay.abort = false
		world.tick()
		overlay:step()
		t.ok(late.destroyed, "a mesh in the old looks is never shown")
		t.eq(job.region.failures, 0, "not a failure")
		for _, node in nodes do
			t.ok(node.model.Parent ~= nil, "parts stay")
		end
		-- Built again with the new looks, shown, then demoted by the next change.
		t.ok(run(world, overlay, 600, function()
			return overlay.pending ~= nil
		end) <= 600, "built again")
		local again = overlay.pending
		t.eq(again.payload.lookGen, overlay.lookGen)
		t.eq(again.payload.options.uvStuds, FarMeshes.UvStuds, "with the far looks: UVs")
		t.eq(again.payload.options.minShare, FarMeshes.LookMinShare)
		overlay.pending = nil
		local mesh = world.new("MeshPart")
		table.insert(overlay.done, { job = again, parts = { mesh }, triangles = 2 })
		run(world, overlay, 10, function()
			return false
		end)
		t.eq(mesh.Parent, overlay.root, "shown")
		t.eq(nodes[1].model.Parent, nil, "its parts hidden")
		overlay:setLooks(false, lookOf, lookInfo, plainOf)
		run(world, overlay, 10, function()
			return false
		end)
		t.ok(nodes[1].model.Parent ~= nil, "parts back")
		t.ok(mesh.destroyed, "mesh gone after them")
	end)

	t.test("far looks: a region is merged only once all its members carry the current look", function()
		local world, overlay = overlayWorld(false)
		local nodes = members(world, overlay, 4)
		local current: { [any]: boolean } = {}
		overlay.isCurrent = function(node: any): boolean
			return current[node] == true
		end
		current[nodes[1]], current[nodes[2]], current[nodes[3]] = true, true, true
		t.eq(
			run(world, overlay, 300, function()
				return overlay.pending ~= nil
			end),
			301,
			"no build while a member is being restyled"
		)
		current[nodes[4]] = true
		t.ok(run(world, overlay, 60, function()
			return overlay.pending ~= nil
		end) <= 60, "built once it is current")
	end)

	t.test("far looks: the builder makes a MeshPart per look, in its material, UVs where textured", function()
		local world, overlay = overlayWorld(true)
		t.eq(overlay.status, "probing", "the builder started")
		overlay.farShadows = true
		overlay:setLooks(true, lookOf, lookInfo, plainOf)
		local nodes = members(world, overlay, 1)
		local entry
		local frames = run(world, overlay, 2000, function()
			entry = overlay.instances[overlay.regions:regionOfNode(nodes[1])]
			return entry ~= nil and #entry.parts > 0
		end)
		t.ok(frames <= 2000, `meshed ({overlay.status}, {table.concat(world.warnings, "; ")})`)
		t.ok(overlay.stats.tinyFrameMs >= 0)
		local byMaterial: { [string]: any } = {}
		for _, part in entry.parts do
			byMaterial[part.Material.Name] = part
			t.eq(part.Color, Color3.new(1, 1, 1), "white: the vertices carry the colour")
		end
		local grass, slate, glass = byMaterial.Grass, byMaterial.Slate, byMaterial.Glass
		t.ok(grass and slate and glass, "a MeshPart per look")
		t.eq(grass.MaterialVariant, "IV_grass_top")
		t.ok(grass.CastShadow and slate.CastShadow, "opaque looks cast shadows")
		t.eq(glass.Transparency, 0.4)
		t.eq(glass.Reflectance, 0.1)
		t.eq(glass.CastShadow, false, "see-through looks never")
		-- The dirt block is a tiny share: plain remainder, in its plain colour.
		local plain = byMaterial.SmoothPlastic
		t.ok(plain ~= nil, "the plain remainder")
		local function vertices(part: any): { any }
			return world.meshes[part].vertices
		end
		local dr, dg, db = plainOf(Blocks.get(Blocks.id.Dirt).appearance)
		local first = vertices(plain)[1]
		t.ok(math.abs(first.color.R - dr) < 1e-6 and math.abs(first.color.B - db) < 1e-6, "plain colour")
		t.ok(math.abs(first.color.G - dg) < 1e-6)
		t.eq(first.uv, nil, "no UVs on the plain look")
		-- Textured looks have every vertex's UV; their colours are lookOf's.
		local gr, gg, gb = colorOf(GRASS)
		for _, vertex in vertices(grass) do
			t.ok(vertex.uv ~= nil, "UV written")
			t.ok(math.abs(vertex.color.R - gr) < 1e-6 and math.abs(vertex.color.G - gg) < 1e-6, "grass colour")
			t.ok(math.abs(vertex.color.B - gb) < 1e-6)
		end
		t.ok(vertices(slate)[1].uv ~= nil, "a material without a variant is textured too")
		t.eq(overlay:getStats().looks, true)
		t.eq(overlay:getStats().lookParts, #entry.parts - 1, "every MeshPart but the plain one")

		-- Far Materials off: one plain mesh in the plain colours.
		overlay:setLooks(false, lookOf, lookInfo, plainOf)
		frames = run(world, overlay, 2000, function()
			local e = overlay.instances[overlay.regions:regionOfNode(nodes[1])]
			return e ~= nil and #e.parts > 0 and e.parts[1].Material == MATERIALS.SmoothPlastic
		end)
		t.ok(frames <= 2000, "meshed again")
		entry = overlay.instances[overlay.regions:regionOfNode(nodes[1])]
		t.eq(#entry.parts, 1, "one plain mesh")
		local sr, sg, sb = plainOf(STONE)
		local found = false
		for _, vertex in vertices(entry.parts[1]) do
			t.eq(vertex.uv, nil, "no UVs")
			if math.abs(vertex.color.R - sr) < 1e-6 and math.abs(vertex.color.G - sg) < 1e-6 then
				found = math.abs(vertex.color.B - sb) < 1e-6
			end
		end
		t.ok(found, "stone in its plain colour")
	end)

	t.test("far looks: the probe times its one-block mesh by its long frame, then builds it in a look", function()
		local world, overlay = overlayWorld(true)
		-- The first probe mesh (the block) makes the next frame 50 ms long.
		local first = true
		world.onMeshPart = function(_baked: any)
			if first then
				first = false
				world.longFrame = 0.05
				coroutine.yield()
			end
		end
		local frames = run(world, overlay, 2000, function()
			return overlay.status ~= "probing"
		end)
		t.ok(frames <= 2000, "probed")
		t.eq(overlay.status, "on", table.concat(world.warnings, "; "))
		local excess = 50 - 1000 / 60
		t.ok(
			math.abs(overlay.stats.tinyFrameMs - excess) < 1e-6,
			`the longest frame over the usual one, not the time across its yields ({overlay.stats.tinyFrameMs})`
		)
		-- Built again in a look: a Material, and UVs on every vertex.
		local looked = nil
		for part, baked in world.meshes do
			if part.Material == MATERIALS.Slate then
				looked = baked
				t.ok(part.destroyed, "a probe mesh")
			end
		end
		t.ok(looked ~= nil, "a probe mesh in a material")
		for _, vertex in (looked :: any).vertices do
			t.ok(vertex.uv ~= nil, "UV written")
		end
		t.ok(overlay.lookable, "Far Materials can be used")
	end)

	t.test("far looks: a probe mesh in a look fails: meshes stay on, plain, whatever the setting", function()
		local world, overlay = overlayWorld(true)
		-- UVs cannot be written here (the first thing a textured look needs).
		world.failAttribute = FakeEnum.MeshAttribute.UV
		local restyles = 0
		overlay.onLooks = function()
			restyles += 1
		end
		t.eq(overlay:setLooks(true, lookOf, lookInfo, plainOf), true, "Far Materials on before the probe")
		t.ok(not overlay:plainLevel(2))
		local nodes = members(world, overlay, 1)
		local entry
		local frames = run(world, overlay, 3000, function()
			entry = overlay.instances[overlay.regions:regionOfNode(nodes[1])]
			return entry ~= nil and #entry.parts > 0
		end)
		t.ok(frames <= 3000, `meshed ({overlay.status}, {table.concat(world.warnings, "; ")})`)
		t.eq(overlay.status, "on", "meshes stay on")
		t.eq(overlay.stats.failures, 0, "no region build failed")
		t.eq(#entry.parts, 1, "one plain mesh")
		t.eq(entry.parts[1].Material, MATERIALS.SmoothPlastic)
		t.eq(restyles, 1, "the renderer restyles the merged levels")
		t.ok(overlay:plainLevel(2), "merged levels plain again")
		local warned = 0
		for _, warning in world.warnings do
			if string.find(warning, "Far Materials off", 1, true) and string.find(warning, "UV", 1, true) then
				warned += 1
			end
		end
		t.eq(warned, 1, "said once, with the reason")
		-- The setting cannot turn them on any more.
		t.eq(overlay:setLooks(true, lookOf, lookInfo, plainOf), false)
		t.ok(overlay:plainLevel(2))
		t.eq(overlay:getStats().looks, false)
		overlay:dropLooks("again")
		t.eq(restyles, 1, "once")
	end)

	t.test("far looks: the overlay takes a look's average from lookInfo for the largest remainder", function()
		local _, overlay = overlayWorld(false)
		local AVERAGE = { 0.4, 0.5, 0.6 }
		local withAverage = table.clone(LOOKS[1])
		withAverage.average = AVERAGE
		overlay:setLooks(true, lookOf, function(id: number): any
			return if id == 1 then withAverage else LOOKS[id]
		end, plainOf)
		local averageOf = overlay.lookOptions.averageOf
		t.eq(averageOf(1), AVERAGE)
		t.eq(averageOf(2), nil, "unknown")
		t.eq(overlay.lookOptions.remainder, FarMeshes.LookRemainder)
	end)

	--[[
		Integration: generated far terrain merged with Rendering/TextureLooks' own looks (Far
		Materials on, then off), through the real builder: every MeshPart is one of TextureLooks'
		looks, its vertices in that look's colours (the plain ones off), UVs where textured.
	]]
	t.test("far looks: generated terrain with TextureLooks' looks, Far Materials on and off", function()
		-- (A pasted Average can turn a far look plain, a filled blank add one: the pack made neutral.)
		local env = Loader.new()
		local root = env.mount("src/shared", "ReplicatedStorage", "IceVoxel")
		local pack = env.require(root.TexturePack)
		pack.ShowMissing = false
		for _, texture in pack.Textures do
			texture.Average = nil
		end
		local world, overlay = overlayWorld(true, root, env.require)
		-- (MaterialService has every variant: TextureLooks checks them before using one.)
		local getService = world.game.GetService
		world.game.GetService = function(self: any, name: string): any
			if name == "MaterialService" then
				return {
					GetMaterialVariant = function(_, material: any, variant: string): any
						return { Name = variant, BaseMaterial = material }
					end,
				}
			end
			return getService(self, name)
		end
		local Looks = world.load("TextureLooks")
		overlay.farShadows = true
		-- What ChunkRenderer does when the setting changes (TextureLooks.changed: meshes).
		local function follow()
			overlay:setLooks(Looks.farMaterials(), Looks.lookOf, Looks.lookInfo, Looks.plainRgb)
		end
		t.ok(Looks.setStyle(true, true).meshes, "Far Materials on: the meshes' looks change")
		follow()

		-- The level 2 region at the spawn (4 x 4 nodes), quads as the workers make them.
		local gen = TerrainGenerator.new(12345)
		local sx, _, sz = gen.findSpawn()
		local step = ChunkLayout.steps(2)
		local perSide = FarMeshes.RegionNodes
		local baseX = sx // (SIZE * step) // perSide * perSide
		local baseZ = sz // (SIZE * step) // perSide * perSide
		local present: { [number]: boolean } = {}
		local node
		for dz = 0, perSide - 1 do
			for dx = 0, perSide - 1 do
				local r = gen.generate(2, baseX + dx, baseZ + dz)
				local y0, y1 = GreedyMesher.activeRange(r.solidBelow, r.emptyAbove, r.height)
				local quads, count = QuadMesher.mesh(r.data, r.height, y0, y1, true)
				for q = 0, count - 1 do
					present[(GreedyMesher.decodeKey(buffer.readu16(quads, q * QUAD + 12)))] = true
				end
				local model = world.new("Folder")
				model.Parent = world.root
				node = { level = 2, nx = baseX + dx, nz = baseZ + dz, removed = false, model = model }
				overlay:setQuads(node, quads, count)
				overlay:onShow(node)
			end
		end
		local GRASS_APP = Blocks.get(Blocks.id.Grass).appearance
		t.ok(present[GRASS_APP], "grass at the spawn")

		-- Each look's MeshPart properties and the vertex colours its quads may have.
		local function key(material: any, variant: string, transparency: number, reflectance: number): string
			return `{material.Name}|{variant}|{transparency}|{reflectance}`
		end
		local function rgbKey(r: number, g: number, b: number): string
			return `{math.round(r * 1e5)},{math.round(g * 1e5)},{math.round(b * 1e5)}`
		end
		local function expected(): ({ [string]: number }, { [number]: { [string]: boolean } })
			local ids: { [string]: number } = { [key(MATERIALS.SmoothPlastic, "", 0, 0)] = PLAIN }
			local colours: { [number]: { [string]: boolean } } = { [PLAIN] = {} }
			for appearance in present do
				local id, cr, cg, cb = Looks.lookOf(appearance, 2)
				local info = Looks.lookInfo(id)
				ids[key(info.material, info.variant, info.transparency, info.reflectance)] = id
				colours[id] = colours[id] or {}
				colours[id][rgbKey(cr, cg, cb)] = true
				-- (The plain remainder: the plain colours.)
				colours[PLAIN][rgbKey(Looks.plainRgb(appearance, 2))] = true
			end
			return ids, colours
		end
		local function meshed(plainOnly: boolean): { any }
			local entry
			local frames = run(world, overlay, 3000, function()
				entry = overlay.instances[overlay.regions:regionOfNode(node)]
				if entry == nil or #entry.parts == 0 then
					return false
				end
				for _, part in entry.parts do
					if plainOnly and part.Material ~= MATERIALS.SmoothPlastic then
						return false
					end
				end
				return true
			end)
			t.ok(frames <= 3000, `meshed ({overlay.status}, {table.concat(world.warnings, "; ")})`)
			return entry.parts
		end

		-- Far Materials on: one MeshPart per look, each one of TextureLooks' looks.
		local parts = meshed(false)
		local ids, colours = expected()
		local looks: { [number]: boolean } = {}
		local grassLook = nil
		for _, part in parts do
			local id = ids[key(part.Material, part.MaterialVariant, part.Transparency, part.Reflectance)]
			t.ok(id ~= nil, `{part.Material.Name} {part.MaterialVariant}: one of TextureLooks' looks`)
			t.eq(part.Color, Color3.new(1, 1, 1), "white: the vertices carry the colour")
			looks[id :: number] = true
			if part.MaterialVariant == "IV_grass_top" then
				grassLook = part
			end
			local textured = part.Material ~= MATERIALS.SmoothPlastic or part.MaterialVariant ~= ""
			for _, vertex in world.meshes[part].vertices do
				local c = vertex.color
				t.ok(colours[id :: number][rgbKey(c.R, c.G, c.B)], `{part.MaterialVariant}: a colour of its look`)
				t.eq(vertex.uv ~= nil, textured, "UVs exactly where textured")
			end
		end
		local kept = 0
		for id in looks do
			if id ~= PLAIN then
				kept += 1
			end
		end
		t.ok(kept >= 2 and kept <= FarMeshes.MaxLooks, `looks with meshes of their own: {kept}`)
		t.ok(grassLook ~= nil, "the grass top's look")
		t.eq((grassLook :: any).Material, MATERIALS[require(shared.TexturePack).Textures["grass top"].Material])
		local far = Looks.farLook(GRASS_APP)
		local first = world.meshes[grassLook].vertices[1].color
		t.ok(rgbKey(first.R, first.G, first.B) == rgbKey(far.color.R, far.color.G, far.color.B), "the far part's tint")

		-- Far Materials off: plain meshes in the plain colours, what the plain parts take.
		t.ok(Looks.setStyle(true, false).meshes)
		follow()
		parts = meshed(true)
		local plainColours: { [string]: boolean } = {}
		for appearance in present do
			local c = Looks.plainColour(appearance)
			plainColours[rgbKey(c.R, c.G, c.B)] = true
		end
		local grassPlain = Looks.plainColour(GRASS_APP)
		local sawGrass = false
		for _, part in parts do
			t.eq(part.MaterialVariant, "")
			for _, vertex in world.meshes[part].vertices do
				local c = vertex.color
				t.ok(plainColours[rgbKey(c.R, c.G, c.B)], "a plain part's colour")
				t.eq(vertex.uv, nil, "no UVs")
				if rgbKey(c.R, c.G, c.B) == rgbKey(grassPlain.R, grassPlain.G, grassPlain.B) then
					sawGrass = true
				end
			end
		end
		t.ok(sawGrass, "grass in what it averages to")
	end)
end
