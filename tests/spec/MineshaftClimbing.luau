--[[
	Generated mineshafts meet climbing, the server's block updates and mob spawning
	(Generation/Mineshafts with Shared/Movement/PlayerPhysics, server Behaviours/Attached and
	Mobs/MobSpawning, all on the Default world's own chunks through WorldServer):
	  * an overgrown mineshaft's entrance rope is climbed from the floor to the surface, holding
	    jump, and stepped off onto the collar: the beam Mineshafts.FRAME (3) over the collar stops
	    the climber's head with their feet 1.2 over it, enough to drift onto the collar (a beam 2
	    over it, as first planned, stops the feet 0.2 over and a climber stepping off falls back
	    down the shaft);
	  * a player sprint-jumps from the collar onto the rope, holds on sneaking, then lets go and
	    slides to the floor (20 or more blocks down, onto planks where a cave crosses it) unhurt;
	  * a vine run down the shaft's wall starts in the collar's top layer, so it climbs out too;
	  * the server's neighbour updates over freshly generated mineshaft chunks break nothing that
	    was generated (every rope, vine, torch, rail, carpet and root holds: Blocks.canSurvive with
	    the chain rule), and cutting the entrance rope brings the part below down rope by rope,
	    each dropping itself, the part above staying on the beam;
	  * monsters spawn on a mineshaft's dark floors, never inside a rail, never by a lit torch;
	  * the server fills a generated chest with its loot (StructureServer.slotsFromItems, as
	    Structures/StructureBlocks hands the generator's structureContainer to Containers).
]]
return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local Mineshafts = require(shared.Generation.Mineshafts)
	local PlayerPhysics = require(shared.Movement.PlayerPhysics)
	local MobList = require(shared.Entities.MobList)
	local WorldServer = require(server.World.WorldServer)
	local BlockTicker = require(server.World.BlockTicker)
	local Behaviours = require(server.Behaviours)
	local Drops = require(server.Behaviours.Drops)
	local MobSpawning = require(server.Mobs.MobSpawning)
	local StructureServer = require(server.Structures.StructureServer)
	local Machines = require(shared.Machines)

	local SIZE = ChunkLayout.SIZE
	local SEED = 12345
	local SPAWN = { 512, -128 }
	local AREA = 1600
	local B = Blocks.id
	local AIR, CAVE_AIR, ROPE, LOG = Blocks.AIR, Blocks.CAVE_AIR, B.Rope, B.OakLog
	local FRAME = Mineshafts.FRAME
	local MIDNIGHT = 18000

	local gen = TerrainGenerator.new(SEED)
	-- The entrances near the spawn, nearest first.
	local plans = gen.mineshafts(SPAWN[1] - AREA, SPAWN[2] - AREA, SPAWN[1] + AREA, SPAWN[2] + AREA)
	local withEntrance = {}
	for _, plan in plans do
		if plan.entrance then
			table.insert(withEntrance, plan)
		end
	end
	table.sort(withEntrance, function(a, b)
		local da = (a.entrance.x - SPAWN[1]) ^ 2 + (a.entrance.z - SPAWN[2]) ^ 2
		local db = (b.entrance.x - SPAWN[1]) ^ 2 + (b.entrance.z - SPAWN[2]) ^ 2
		return da < db
	end)
	assert(#withEntrance >= 3, "three entrances near the spawn")
	-- And the normal one nearest the spawn.
	local normal = nil
	for _, plan in plans do
		local d = (plan.x - SPAWN[1]) ^ 2 + (plan.z - SPAWN[2]) ^ 2
		if not plan.overgrown and (normal == nil or d < (normal.x - SPAWN[1]) ^ 2 + (normal.z - SPAWN[2]) ^ 2) then
			normal = plan
		end
	end
	assert(normal, "a normal mineshaft near the spawn")

	-- One server world over the Default generator for every test (chunks generated as asked).
	local world = WorldServer.new(gen)
	local function isVine(id: number): boolean
		return string.find(Blocks.get(Blocks.caveTwinOf(id) or id).name, "Vine") ~= nil
	end
	-- What the player's physics sees: the world, without the shaft's vines when `bare` (so only
	-- the rope gets a climber out), and with the beam lowered to 2 over the collar when `low`.
	local function physicsWorld(e: any, bare: boolean, low: boolean?): PlayerPhysics.World
		local ax, az = if e.axis == "X" then 1 else 0, if e.axis == "X" then 0 else 1
		return {
			getBlock = function(x: number, y: number, z: number): number?
				local block = world:getBlock(x, y, z)
				if bare and isVine(block) then
					return AIR
				end
				if low then
					local along = (x - e.x) * ax + (z - e.z) * az
					local onRow = (x - e.x) * az + (z - e.z) * ax == 0 and math.abs(along) <= 2
					if onRow and y == e.top + FRAME then
						return AIR
					elseif onRow and y == e.top + 2 then
						return LOG
					end
				end
				return block
			end,
		}
	end
	local function input(moveX: number, moveZ: number, options: { [string]: any }?): PlayerPhysics.Input
		local o = options or {}
		local length = math.sqrt(moveX * moveX + moveZ * moveZ)
		return {
			moveX = moveX,
			moveZ = moveZ,
			forward = length,
			facingX = if length > 0 then moveX / length else 0,
			facingZ = if length > 0 then moveZ / length else 1,
			lookY = 0,
			jump = o.jump == true,
			sneak = o.sneak == true,
			sprint = o.sprint == true,
		}
	end
	-- Across the beam (the side the posts leave open): +1 along the other axis.
	local function across(e: any): (number, number)
		return if e.axis == "X" then 0 else 1, if e.axis == "X" then 1 else 0
	end

	--[[ Climbing the entrance rope ]]

	t.test("mineshaft entrances: climb the rope from the floor and step off onto the collar", function()
		for k = 1, 3 do
			local e = withEntrance[k].entrance
			for y = e.bottom, e.top + FRAME - 1 do
				t.eq(world:getBlock(e.x, y, e.z), ROPE, `rope at {y}`)
			end
			t.ok(Blocks.isClimbable(ROPE), "rope is climbable")
			t.eq(world:getBlock(e.x, e.top + FRAME, e.z), LOG, "the beam FRAME over the collar")
			t.ok(Blocks.isSturdy(world:getBlock(e.x, e.bottom - 1, e.z)), "a sturdy floor under the rope")

			local physics = physicsWorld(e, true)
			local state = PlayerPhysics.new(e.x + 0.5, e.bottom, e.z + 0.5)
			state.onGround = true
			-- Hold jump: up the rope until the head meets the beam.
			local ticks, lastY = 0, -1
			for tick = 1, 2000 do
				PlayerPhysics.tick(state, input(0, 0, { jump = true }), physics)
				ticks = tick
				if tick > 2 then
					t.ok(state.climbing, "climbing all the way")
					t.eq(state.fallDistance, 0, "no fall while climbing")
				end
				if state.y == lastY then
					break
				end
				lastY = state.y
			end
			local rise = e.top + FRAME - 1.8 - e.bottom
			t.near(state.y, e.top + FRAME - 1.8, 1e-6, "the head against the beam: the feet 1.2 over the collar")
			-- 0.1176 a tick (Minecraft's ladder speed) after the 0.42 jump.
			t.ok(ticks <= math.ceil((rise - 0.42) / ((0.2 - 0.08) * 0.98)) + 6, `{rise} blocks up in {ticks} ticks`)

			-- Still holding jump, step across the beam: onto the collar, unhurt.
			local mx, mz = across(e)
			local damage, landed = 0, false
			for _ = 1, 40 do
				local events = PlayerPhysics.tick(state, input(mx, mz, { jump = true }), physics)
				damage += events.damage
				if state.onGround then
					landed = true
					break
				end
			end
			t.ok(landed, "landed")
			t.near(state.y, e.top, 1e-9, "on the collar's top")
			local off = (state.x - e.x - 0.5) * mx + (state.z - e.z - 0.5) * mz
			t.ok(off >= 1.2, `over the collar ring ({off} from the rope)`)
			t.eq(damage, 0, "unhurt")

			-- Under a beam 2 over the collar (the first plan), the feet stop 0.2 over it and the same
			-- step drops the climber back down the shaft.
			if k == 1 then
				local lowWorld = physicsWorld(e, true, true)
				local low = PlayerPhysics.new(e.x + 0.5, e.bottom, e.z + 0.5)
				low.onGround = true
				for _ = 1, ticks + 20 do
					PlayerPhysics.tick(low, input(0, 0, { jump = true }), lowWorld)
				end
				t.near(low.y, e.top + 0.2, 1e-6, "a low beam: the feet 0.2 over the collar")
				for _ = 1, 40 do
					PlayerPhysics.tick(low, input(mx, mz, { jump = true }), lowWorld)
				end
				t.ok(low.y < e.top - 1, `a low beam: back down the shaft (at {low.y - e.top})`)
			end
		end
	end)

	t.test("mineshaft entrances: jump onto the rope from the collar, hold on, slide to the floor unhurt", function()
		for k = 1, 3 do
			local e = withEntrance[k].entrance
			local physics = physicsWorld(e, true)
			local mx, mz = across(e)
			-- On the collar across the beam, two blocks from the rope.
			local state = PlayerPhysics.new(e.x + 0.5 + 2 * mx, e.top, e.z + 0.5 + 2 * mz)
			state.onGround = true
			local function off(): number
				return (state.x - e.x - 0.5) * mx + (state.z - e.z - 0.5) * mz
			end
			local function speed(): number
				return state.vx * mx + state.vz * mz
			end
			-- Sprint at it, jumping off the collar's edge.
			local caught = false
			for _ = 1, 40 do
				PlayerPhysics.tick(state, input(-mx, -mz, { sprint = true, jump = off() < 1.6 }), physics)
				if state.climbing then
					caught = true
					break
				end
			end
			t.ok(caught, "caught the rope")
			-- Hold on (sneaking), steering back to the rope's middle.
			for _ = 1, 60 do
				local v, o = speed(), off()
				local push = if math.abs(v) > 0.01 then -math.sign(v) elseif math.abs(o) > 0.2 then -math.sign(o) else 0
				PlayerPhysics.tick(state, input(push * mx, push * mz, { sneak = true }), physics)
				t.ok(state.climbing, "on the rope")
			end
			local held = state.y
			for _ = 1, 20 do
				PlayerPhysics.tick(state, input(0, 0, { sneak = true }), physics)
			end
			t.eq(state.y, held, "sneaking holds")
			t.ok(held > e.top - 1, "near the top")

			-- Let go: down the rope in free fall, landing on the floor unhurt.
			local damage, ticks = 0, 0
			for tick = 1, 400 do
				local events = PlayerPhysics.tick(state, input(0, 0), physics)
				damage += events.damage
				ticks = tick
				if state.onGround then
					break
				end
			end
			t.eq(state.y, e.bottom, `slid to the floor ({held - e.bottom} blocks in {ticks} ticks)`)
			t.eq(damage, 0, "unhurt")
			t.ok(held - e.bottom >= 20, "a long way down")
		end
	end)

	t.test("mineshaft entrances: a vine down the shaft's wall reaches the collar and climbs out", function()
		local runs = 0
		for _, plan in withEntrance do
			local e = plan.entrance
			-- The opening's edge cells by each wall: the top of every vine run is in the collar's top layer.
			for _, side in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
				for along = -1, 1 do
					local x, z = e.x + side[1] + along * side[2], e.z + side[2] + along * side[1]
					local topVine = nil
					for y = e.top + FRAME, e.top - 12, -1 do
						if isVine(world:getBlock(x, y, z)) then
							topVine = y
							break
						end
					end
					if topVine == nil or topVine > e.top - 1 then
						continue
					end
					runs += 1
					t.eq(topVine, e.top - 1, "a shaft vine starts in the collar's top layer")
					t.ok(Blocks.isClimbable(world:getBlock(x, topVine, z)), "climbable")
					-- Pressing into the wall from the vine's lowest cell climbs out onto the collar.
					if runs <= 3 then
						local bottom = topVine
						while isVine(world:getBlock(x, bottom - 1, z)) do
							bottom -= 1
						end
						local physics = physicsWorld(e, false)
						local state = PlayerPhysics.new(x + 0.5 + side[1] * 0.2, bottom + 0.5, z + 0.5 + side[2] * 0.2)
						for _ = 1, 200 do
							PlayerPhysics.tick(state, input(side[1], side[2]), physics)
							if state.onGround and state.y >= e.top then
								break
							end
						end
						t.near(state.y, e.top, 1e-9, "climbed out by the vine onto the collar")
					end
				end
			end
		end
		t.ok(runs > 0, `shaft vine runs checked: {runs}`)
	end)

	--[[ The server's block updates ]]

	-- The world's loaded chunks over a plan's bounds (and a ring round them), with a ticker.
	local function serverOver(plan: any)
		local b = plan.bounds
		for cz = b[3] // SIZE - 1, b[6] // SIZE + 1 do
			for cx = b[1] // SIZE - 1, b[4] // SIZE + 1 do
				world:getChunk(cx, cz)
			end
		end
		local ticker = BlockTicker.new(world, Behaviours.byId, 100000)
		local changed = 0
		world.onChanged = function(x, y, z)
			changed += 1
			ticker:blockChanged(x, y, z)
		end
		local dropped = {}
		Drops.set(function(x, y, z, stack)
			table.insert(dropped, { x = x, y = y, z = z, item = stack.item, count = stack.count })
		end)
		local function settle()
			for _ = 1, 4000 do
				ticker:step()
				if ticker:pendingCount() == 0 then
					return
				end
			end
			error("block updates never settled")
		end
		return ticker, settle, dropped, function(): number
			return changed
		end
	end

	t.test("mineshafts: the server's block updates keep every generated rope, vine, torch and rail", function()
		local plan = withEntrance[1]
		local e = plan.entrance
		local ticker, settle, dropped, changes = serverOver(plan)
		-- Every attached block over the plan's bounds told a neighbour changed, at once.
		local b = plan.bounds
		local count: { [string]: number } = {}
		local total = 0
		for x = b[1], b[4] do
			for z = b[3], b[6] do
				for y = b[2], b[5] do
					local id = world:getBlock(x, y, z)
					if Blocks.supportOffset(id) ~= nil then
						ticker:schedule(x, y, z, 1)
						local name = Blocks.get(Blocks.caveTwinOf(id) or id).name
						name = if isVine(id) then "Vine" elseif string.find(name, "WallTorch") then "WallTorch" else name
						count[name] = (count[name] or 0) + 1
						total += 1
					end
				end
			end
		end
		settle()
		t.eq(changes(), 0, "nothing generated broke")
		t.eq(#dropped, 0, "nothing dropped")
		t.ok(total > 100, `attached blocks updated: {total}`)
		t.ok((count.Rope or 0) >= e.top + FRAME - e.bottom, "the entrance rope among them")
		for _, name in { "Vine", "HangingRoots", "MossCarpet" } do
			t.ok((count[name] or 0) > 0, `{name} among them ({count[name] or 0})`)
		end
		print(
			`    {total} attached blocks: {count.Rope or 0} rope, {count.Vine or 0} vines, {count.WallTorch or 0} torches, {count.Rail or 0} rails, {count.MossCarpet or 0} carpets, {count.HangingRoots or 0} roots`
		)

		-- Cut the entrance rope halfway: the part below comes down, rope by rope, each dropping
		-- itself; the part above still hangs from the beam.
		local cut = (e.bottom + e.top) // 2
		world:setBlock(e.x, cut, e.z, AIR)
		settle()
		for y = e.bottom, cut do
			t.eq(world:getBlock(e.x, y, e.z), AIR, `rope at {y} came down`)
		end
		for y = cut + 1, e.top + FRAME - 1 do
			t.eq(world:getBlock(e.x, y, e.z), ROPE, `rope at {y} still hangs`)
		end
		local ropes = 0
		for _, drop in dropped do
			if drop.item == Items.id.Rope then
				ropes += drop.count
			end
		end
		t.eq(ropes, cut - e.bottom, "each rope below the cut dropped itself")
		world.onChanged = nil
		Drops.set(nil)
	end)

	--[[ Mob spawning ]]

	t.test("mineshafts: monsters spawn on dark floors, never inside a rail or by a lit torch", function()
		-- (An overgrown one's glow lichen lights most of its floors, as lush caves' do: Minecraft's
		-- monsters need block light 0. A normal one is mostly dark.)
		local zombie = MobList.get(MobList.find("Zombie") :: number) :: MobList.Kind
		local function getBlock(x: number, y: number, z: number): number?
			return world:peekBlock(x, y, z)
		end
		local context = {
			players = {},
			dayTime = MIDNIGHT,
			skyOpen = function(x: number, y: number, z: number): boolean?
				return y >= (gen.column(x, z))
			end,
			active = function(): boolean
				return true
			end,
		}
		local function darkest(n: number): number
			return n - 1
		end
		local railSpots, torchSpots = 0, 0
		local spots, valid = {}, {}
		for k, plan in { normal, withEntrance[1] } do
			spots[k], valid[k] = 0, 0
			serverOver(plan)
			world.onChanged = nil
			Drops.set(nil)
			-- The plan's corridors: their floor layer's cells, standing on a sturdy floor.
			for _, piece in plan.pieces do
				if piece.kind ~= "corridor" then
					continue
				end
				local box = piece.box
				local y = box[2]
				for x = box[1], box[4] do
					for z = box[3], box[6] do
						local feet, below = getBlock(x, y, z), getBlock(x, y - 1, z)
						if feet == nil or below == nil or Blocks.isSolid(feet) or not Blocks.isSturdy(below) then
							continue
						end
						spots[k] += 1
						local ok = MobSpawning.validSpot(getBlock, context, zombie, x, y, z, darkest)
						if ok then
							valid[k] += 1
						end
						local base = Blocks.caveTwinOf(feet) or feet
						if Blocks.axisOf(base) ~= nil then
							railSpots += 1
							t.ok(not ok, `no spawn inside a rail at {x} {y} {z}`)
						end
						-- Next to a wall torch (light 13 or more): no spawn.
						for dy = 0, 2 do
							for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 0, 0 } } do
								local near = getBlock(x + d[1], y + dy, z + d[2])
								if near and string.find(Blocks.get(near).name, "WallTorch") then
									torchSpots += 1
									t.ok(not ok, `no spawn by a torch at {x} {y} {z}`)
								end
							end
						end
					end
				end
			end
		end
		print(
			`    corridor floor spots a zombie may spawn on: {valid[1]} of {spots[1]} (normal), {valid[2]} of {spots[2]} (overgrown); {railSpots} on rails, {torchSpots} by torches`
		)
		t.ok(spots[1] > 100 and spots[2] > 100, "corridor floors checked")
		t.ok(valid[1] > spots[1] // 2, "monsters spawn in a normal mineshaft's dark")
		t.ok(railSpots > 0 and torchSpots > 0, "rails and torches checked")
	end)

	--[[ Loot ]]

	t.test("mineshafts: the server fills a generated chest with its loot", function()
		local filled, stacks = 0, 0
		for _, plan in { normal, withEntrance[1], withEntrance[2], withEntrance[3] } do
			for _, piece in plan.pieces do
				local list = piece.chests
				for i = 1, #list, 3 do
					local x, y, z = list[i], list[i + 1], list[i + 2]
					if world:getBlock(x, y, z) ~= B.Chest then
						continue
					end
					local items = gen.structureContainer(x, y, z)
					t.ok(items ~= nil, "loot for a generated chest")
					local slots = StructureServer.slotsFromItems(items :: any, Machines.containerSize(B.Chest))
					local n = 0
					for slot, stack in slots do
						t.ok(slot >= 1 and slot <= Machines.containerSize(B.Chest), "a chest slot")
						t.ok(stack.count >= 1, "a stack")
						n += 1
					end
					t.eq(n, #(items :: any), "every item lands in the chest")
					filled += 1
					stacks += n
				end
			end
		end
		print(`    {filled} generated chests filled, {stacks} stacks`)
		t.ok(filled > 0, "a generated chest")
	end)
end
