--[[
	Mobs on the client: how they are drawn between the server's updates (Entities/MobModel: the
	glide, the facing the short way round, snapping, the hurt red, a creeper's flash, tipping
	over when dying), what the crosshair hits (`pick`), and what WAILA says about them
	(Ui/WailaInfo.mob).
]]

return function(t, shared, require, _server, client)
	local MobList = require(shared.Entities.MobList)
	local MobModel = require(client.Entities.MobModel)
	local WailaInfo = require(client.Ui.WailaInfo)

	local ZOMBIE = MobList.find("Zombie") :: number
	local SHEEP = MobList.find("Sheep") :: number
	local CREEPER = MobList.find("Creeper") :: number

	local function state(x: number, y: number, z: number, yaw: number?, flags: number?, fuse: number?)
		return { x = x, y = y, z = z, yaw = yaw or 0, health = 20, flags = flags or 0, fuse = fuse or 0 }
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

	t.test("mob model: hurt red, a creeper's white flash, dying tips over", function()
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
		local creeper = MobList.get(CREEPER) :: MobList.Kind
		local fuse = MobModel.new(3, creeper, 1, state(0, 0, 0, 0, MobModel.FUSE, 20), 0)
		local white, green = 0, 0
		for i = 0, 99 do
			local cr, cg, cb = MobModel.colour(fuse, 1, i / 100)
			if cr == 255 and cg == 255 and cb == 255 then
				white += 1
			else
				green += 1
			end
		end
		t.ok(white > 20 and green > 20, `a lit creeper flashes ({white} white, {green} green)`)
		t.ok(not MobModel.flashing(MobModel.new(4, creeper, 1, state(0, 0, 0), 0), 0.5), "an unlit one doesn't")
		local dying = MobModel.new(5, creeper, 1, state(0, 0, 0), 0)
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
end
