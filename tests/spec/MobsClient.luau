--[[
	Mobs on the client: how they are drawn between the server's updates (Entities/MobModel: the
	glide, the facing the short way round, snapping, the hurt red, tipping over when dying), what
	the crosshair hits (`pick`), and what WAILA says about them
	(Ui/WailaInfo.mob). For the zombies' rigs: the flags' blends and the attack's edge, the stride
	estimate, and the move op's baseline (deltas add up exactly).
]]

return function(t, shared, require, _server, client)
	local MobList = require(shared.Entities.MobList)
	local Protocol = require(shared.Net.Protocol)
	local MobModel = require(client.Entities.MobModel)
	local WailaInfo = require(client.Ui.WailaInfo)

	local ZOMBIE = MobList.find("Zombie") :: number
	local SHEEP = MobList.find("Sheep") :: number

	local function state(x: number, y: number, z: number, yaw: number?, flags: number?)
		return { x = x, y = y, z = z, yaw = yaw or 0, health = 20, flags = flags or 0 }
	end

	t.test("mob model: glides between updates, turns the short way, snaps far jumps", function()
		local kind = MobList.get(ZOMBIE) :: MobList.Kind
		local mob = MobModel.new(1, kind, 1, state(0, 10, 0), 0)
		local x, y, z, yaw = MobModel.pose(mob, 5)
		t.eq(x, 0)
		t.eq(y, 10)
		MobModel.apply(mob, state(1, 10, 0, math.pi - 0.1), 10)
		x = MobModel.pose(mob, 10)
		t.eq(x, 0, "starts where it was drawn")
		x = MobModel.pose(mob, 10 + MobModel.GLIDE / 2)
		t.near(x, 0.5, 1e-9, "halfway through the glide")
		x, _, _, yaw = MobModel.pose(mob, 10 + MobModel.GLIDE * 2)
		t.eq(x, 1, "there at the end")
		t.near(yaw, math.pi - 0.1, 1e-9)
		-- The short way round: from just under pi to just over -pi.
		MobModel.apply(mob, state(1, 10, 0, -math.pi + 0.1), 20)
		_, _, _, yaw = MobModel.pose(mob, 20 + MobModel.GLIDE / 2)
		t.ok(math.abs(math.abs(yaw) - math.pi) < 0.01, `through pi, not through 0 ({yaw})`)
		-- A far jump snaps.
		MobModel.apply(mob, state(50, 10, 0), 30)
		x = MobModel.pose(mob, 30)
		t.eq(x, 50, "snapped")
	end)

	t.test("mob model: hurt red, dying tips over", function()
		local sheep = MobList.get(SHEEP) :: MobList.Kind
		local black = MobModel.new(2, sheep, 2, state(0, 0, 0), 0)
		local r, g, b = MobModel.colour(black, 1, 0)
		t.eq(r, 30, "a black sheep's fleece")
		t.eq(g, 27)
		t.eq(b, 27)
		r, g, b = MobModel.colour(black, 2, 0)
		t.eq(r, sheep.parts[2].color[1], "its face keeps the kind's colour")
		MobModel.apply(black, state(0, 0, 0, 0, MobModel.HURT), 1)
		r, g, b = MobModel.colour(black, 1, 1)
		t.ok(r > 150 and g < 20 and b < 20, `hurt: red ({r}, {g}, {b})`)
		local zombie = MobList.get(ZOMBIE) :: MobList.Kind
		local dying = MobModel.new(5, zombie, 1, state(0, 0, 0), 0)
		t.eq(MobModel.tip(dying, 1), 0, "alive: upright")
		MobModel.apply(dying, state(0, 0, 0, 0, MobModel.DYING), 2)
		t.ok(MobModel.tip(dying, 2.3) > 0 and MobModel.tip(dying, 2.3) < math.rad(90), "tipping")
		t.near(MobModel.tip(dying, 4), math.rad(90), 1e-9, "on its side")
	end)

	t.test("mob model: the crosshair picks the nearest live box on the ray", function()
		local zombie = MobList.get(ZOMBIE) :: MobList.Kind
		local mobs = {
			[1] = MobModel.new(1, zombie, 1, state(5, 0, 0), 0),
			[2] = MobModel.new(2, zombie, 1, state(8, 0, 0), 0),
		}
		local mob, distance = MobModel.pick(mobs, 0, 0, 1, 0, 1, 0, 0, 20)
		t.eq(mob and mob.id, 1, "the nearer")
		t.near(distance, 4.7, 1e-9, "its box's face")
		local none = MobModel.pick(mobs, 0, 0, 1, 0, 1, 0, 0, 4)
		t.eq(none, nil, "out of reach")
		local above = MobModel.pick(mobs, 0, 0, 3, 0, 1, 0, 0, 20)
		t.eq(above, nil, "over their heads")
		MobModel.apply(mobs[1], state(5, 0, 0, 0, MobModel.DYING), 1)
		local behind = MobModel.pick(mobs, 1, 0, 1, 0, 1, 0, 0, 20)
		t.eq(behind and behind.id, 2, "a dying one isn't aimed at")
	end)

	t.test("waila: a mob's name and health; F3 adds its kind and id", function()
		local zombie = MobList.get(ZOMBIE) :: MobList.Kind
		local info =
			WailaInfo.mob({ kind = zombie, variant = 1, id = 42, health = 13.2, x = 1.5, y = 20, z = -3.5 }, false)
		local texts = WailaInfo.texts(info)
		t.eq(texts[1], "Zombie")
		t.eq(texts[2], "Health 14 / 20", "half hearts, rounded up")
		t.eq(texts[#texts], WailaInfo.MOD_NAME)
		t.ok(info.icon and info.icon.colour ~= nil, "a colour box for an icon")
		local extended = WailaInfo.texts(
			WailaInfo.mob({ kind = zombie, variant = 1, id = 42, health = 20, x = 1.5, y = 20, z = -3.5 }, true)
		)
		t.eq(extended[3], `Zombie #{ZOMBIE}, monster`)
		t.eq(extended[4], "Mob entity 42")
		t.eq(extended[5], "Position 1, 20, -4")
		-- A mob in front of the block is named.
		t.eq(WailaInfo.choose(nil, false, 2, 5, false), "entity", "the block behind it is hidden")
	end)

	--[[ The zombies' rigs (Entities/MobRig) read these. ]]

	t.test("mob model: the flags blend steadily, and an attack starts on the flag's rising edge", function()
		local kind = MobList.get(ZOMBIE) :: MobList.Kind
		local mob = MobModel.new(9, kind, 1, state(0, 0, 0), 0)
		local all = MobModel.AGGRESSIVE + MobModel.BREAKING + MobModel.SCREAMING
		MobModel.stride(mob, 0.1)
		MobModel.apply(mob, state(0, 0, 0, 0, all), 0.1)
		local last = 0
		for frame = 1, 30 do
			local now = 0.1 + frame / 60
			MobModel.stride(mob, now)
			t.ok(mob.aggro >= last and mob.aggro - last <= MobModel.BLEND_RATE / 60 + 1e-9, "a steady climb")
			last = mob.aggro
		end
		t.eq(mob.aggro, 1, "aggressive after a quarter second")
		t.eq(mob.hammer, 1, "breaking")
		t.eq(mob.shriek, 1, "screaming")
		MobModel.stride(mob, 0.7)
		MobModel.apply(mob, state(0, 0, 0, 0, MobModel.AGGRESSIVE), 0.7)
		MobModel.stride(mob, 0.7 + 0.125)
		t.near(mob.hammer, 0.5, 1e-9, "half way down in an eighth of a second")
		t.eq(mob.aggro, 1, "still aggressive")
		MobModel.stride(mob, 1.2)
		t.eq(mob.hammer, 0)
		t.eq(mob.shriek, 0)
		-- A swing starts when the Attack flag rises, not while it stays up.
		t.eq(mob.swingStart, -math.huge, "no swing yet")
		MobModel.apply(mob, state(0, 0, 0, 0, MobModel.ATTACK), 2)
		t.eq(mob.swingStart, 2, "a swing")
		MobModel.apply(mob, state(0, 0, 0, 0, MobModel.ATTACK), 2.1)
		t.eq(mob.swingStart, 2, "the same swing")
		MobModel.apply(mob, state(0, 0, 0, 0, 0), 2.4)
		MobModel.apply(mob, state(0, 0, 0, 0, MobModel.ATTACK), 3)
		t.eq(mob.swingStart, 3, "the next one")
		-- A rising edge while a swing is still going doesn't restart it (the arms would jump).
		MobModel.apply(mob, state(0, 0, 0, 0, 0), 3.1)
		MobModel.apply(mob, state(0, 0, 0, 0, MobModel.ATTACK), 3.2)
		t.eq(mob.swingStart, 3, "not mid-swing")
		MobModel.apply(mob, state(0, 0, 0, 0, 0), 3.3)
		MobModel.apply(mob, state(0, 0, 0, 0, MobModel.ATTACK), 3 + MobModel.SWING)
		t.eq(mob.swingStart, 3 + MobModel.SWING, "once it is over")
		-- A mob spawned aggressive is drawn so at once.
		local angry = MobModel.new(10, kind, 1, state(0, 0, 0, 0, MobModel.AGGRESSIVE), 0)
		t.eq(angry.aggro, 1)
	end)

	t.test("mob model: the stride follows the glide, whatever the frame rate", function()
		local kind = MobList.get(ZOMBIE) :: MobList.Kind
		-- 0.115 blocks a tick (a zombie's 2.3 blocks a second), an update every 0.1 s.
		local function walk(fps: number, seconds: number, speed: number): MobModel.Mob
			local mob = MobModel.new(3, kind, 1, state(0, 0, 0), 0)
			local nextUpdate, x = 0.1, 0
			for frame = 1, seconds * fps do
				local now = frame / fps
				while nextUpdate <= now do
					x += speed * 2
					MobModel.apply(mob, state(x, 0, 0), nextUpdate)
					nextUpdate += 0.1
				end
				MobModel.stride(mob, now)
			end
			return mob
		end
		local at60 = walk(60, 2, 0.115)
		t.near(at60.walk, 0.46, 0.01, "walk = speed x 4")
		local at30 = walk(30, 2, 0.115)
		t.near(at30.walk, at60.walk, 0.01, "the same at 30 frames a second")
		t.near(at30.phase, at60.phase, 0.3, "and the legs as far through their swing")
		t.near(at60.phase, 0.46 * 40, 2, "the swing advances by walk a tick")
		local sprint = walk(60, 2, 0.4)
		t.ok(sprint.walk > 0.999 and sprint.walk <= 1, `at most 1 ({sprint.walk})`)
		-- Standing still: the legs come to rest.
		local mob = walk(60, 2, 0.115)
		for frame = 1, 120 do
			MobModel.stride(mob, 2 + frame / 60)
		end
		t.ok(mob.walk < 0.01, `stopped ({mob.walk})`)
		-- Far mobs come every other sync: their glide stretches, so they never stop between updates.
		local far = MobModel.new(4, kind, 1, state(0, 0, 0), 0)
		local x, last = 0, -1
		for update = 1, 10 do
			x += 0.5
			MobModel.apply(far, state(x, 0, 0), update * 0.2)
			if update > 1 then
				t.near(far.duration, 0.2, 1e-9, "the glide lasts the interval")
			end
			for frame = 1, 11 do
				local drawn = MobModel.pose(far, update * 0.2 + frame / 60)
				if update > 1 and frame < 11 then
					t.ok(drawn > last, "moving between updates")
				end
				last = drawn
			end
		end
		MobModel.apply(far, state(x + 0.5, 0, 0), 2 + 5)
		t.eq(far.duration, MobModel.GLIDE, "after a pause the glide is the usual one")
		-- The slowest and fastest a mob given `updates` ({ time, x, yaw }) is drawn moving along X
		-- (blocks a second) on the frames after `from` up to `to`, at 60 frames a second.
		local function drawnSpeeds(updates: { { time: number, x: number, yaw: number? } }, from: number, to: number)
			local mob = MobModel.new(5, kind, 1, state(0, 0, 0), 0)
			local u, drawn = 1, 0
			local slowest, fastest = math.huge, 0
			for frame = 1, math.ceil(to * 60) + 1 do
				local now = frame / 60
				while updates[u] and updates[u].time <= now + 1e-9 do
					MobModel.apply(mob, state(updates[u].x, 0, 0, updates[u].yaw), updates[u].time)
					u += 1
				end
				local x = MobModel.pose(mob, now)
				local speed = (x - drawn) * 60
				drawn = x
				if now > from + 1e-9 and now <= to then
					slowest, fastest = math.min(slowest, speed), math.max(fastest, speed)
				end
			end
			return slowest, fastest
		end
		-- A near zombie (an update every sync while it moves, none while it stands) stops for a
		-- sync or two and walks on: drawn at its own speed throughout, no creep and no rush.
		for _, pause in { 1, 2, 3 } do
			local updates = {}
			local at = 0
			for _ = 1, 10 do
				at += 0.228
				table.insert(updates, { time = #updates * 0.1 + 0.1, x = at })
			end
			local resume = 1 + pause * 0.1
			for i = 1, 10 do
				at += 0.228
				table.insert(updates, { time = resume + i * 0.1, x = at })
			end
			-- (From the first update after the pause to the last but one.)
			local slowest, fastest = drawnSpeeds(updates, resume + 0.1, resume + 0.9)
			t.near(slowest, 2.28, 0.01, `paused {pause} sync(s): no creep after it ({slowest} blocks a second)`)
			t.near(fastest, 2.28, 0.01, `paused {pause} sync(s): no rush ({fastest} blocks a second)`)
		end
		-- A near zombie standing and turning slowly (only its yaw sent, every other sync), then a
		-- still sync, then walking off with an update every sync: its updates came 0.2 s apart
		-- twice running, but they didn't move it, so it walks off at its own speed too.
		for _, still in { 0, 1, 2 } do
			local updates = {}
			for i = 1, 5 do
				table.insert(updates, { time = i * 0.2, x = 0, yaw = i * 0.0245 })
			end
			local resume = 1 + still * 0.1
			local at = 0
			for i = 1, 10 do
				at += 0.228
				table.insert(updates, { time = resume + i * 0.1, x = at, yaw = 0.1225 })
			end
			local slowest, fastest = drawnSpeeds(updates, resume + 0.1, resume + 0.9)
			t.near(slowest, 2.28, 0.01, `turned, still {still} sync(s): no creep ({slowest} blocks a second)`)
			t.near(fastest, 2.28, 0.01, `turned, still {still} sync(s): no rush ({fastest} blocks a second)`)
		end
	end)

	t.test("mob model: moves add up exactly from the last decoded position", function()
		local kind = MobList.get(ZOMBIE) :: MobList.Kind
		local scale = Protocol.MOB_POSITION_SCALE
		-- The server's side: integer steps, the position last sent per mob.
		local sx, sy, sz = 3200 * scale + 7, 64 * scale, -1600 * scale - 3
		local spawn = Protocol.decodeMobs(
			Protocol.encodeMobs({
				{
					op = "spawn",
					id = 5,
					kind = ZOMBIE,
					variant = 1,
					x = sx / scale,
					y = sy / scale,
					z = sz / scale,
					yaw = 0,
					health = 20,
					flags = 0,
				},
			}),
			MobList.COUNT
		) :: { any }
		local mob = MobModel.new(5, kind, 1, spawn[1], 0)
		local seed = 12345
		local function roll(limit: number): number
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed % (2 * limit + 1) - limit
		end
		for step = 1, 2000 do
			local now = step * 0.1
			local op
			if step % 500 == 0 then
				-- Now and then a full state (a delta too big for a move).
				sx += 40000
				op = {
					op = "state",
					id = 5,
					x = sx / scale,
					y = sy / scale,
					z = sz / scale,
					yaw = 1,
					health = 20,
					flags = 0,
				}
			else
				local dx, dy, dz = roll(Protocol.MOB_DELTA_LIMIT), roll(9), roll(300)
				sx, sy, sz = sx + dx, sy + dy, sz + dz
				op = {
					op = "move",
					id = 5,
					dx = dx / scale,
					dy = dy / scale,
					dz = dz / scale,
					yaw = 1,
					health = 20,
					flags = 0,
				}
			end
			local decoded = (Protocol.decodeMobs(Protocol.encodeMobs({ op }), MobList.COUNT) :: { any })[1]
			if decoded.op == "move" then
				MobModel.move(mob, decoded.dx, decoded.dy, decoded.dz, decoded.yaw, decoded.health, decoded.flags, now)
			else
				MobModel.apply(mob, decoded, now)
			end
		end
		t.eq(mob.bx, sx / scale, "x: exactly the server's")
		t.eq(mob.by, sy / scale, "y")
		t.eq(mob.bz, sz / scale, "z")
		t.eq(mob.x, mob.bx, "drawn there once the glide ends")
		-- A snap (more than SNAP_DISTANCE) lands on the baseline at once.
		MobModel.move(mob, 20, 0, 0, 0, 20, 0, 1000)
		t.eq((MobModel.pose(mob, 1000)), sx / scale + 20, "snapped")
	end)
end
