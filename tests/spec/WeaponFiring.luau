--[[
	Firing on the server (server Weapons/FireRules, Weapons/Firing, Weapons/WeaponActions) on fake
	players, mobs and blocks over a real Players/InventoryState: every check and its order, the
	exploits (too fast, not raised, raised with another gun, the wrong item, an origin through a
	wall, empty, jammed, Ruined), every Fire acknowledged and the refused ones told, damage summed
	per target with head factors and helmets, PvP, noise, who is sent a shot, crossbow bolts,
	raising and the weapon actions' locks and sounds, a gun changed in hand by clicks (down, and
	locked as R would lock it), no melee attack while guarding or raised; then the loot
	(Generation/ScavengeLoot's worn entries and new pools) and the police, soldier and
	construction zombies' drops (Entities/MobList).
]]

local fs = require("@lune/fs")

return function(t, shared, require, server)
	local Items = require(shared.Items)
	local Blocks = require(shared.Blocks)
	local Config = require(shared.Config)
	local GameMode = require(shared.GameMode)
	local MobList = require(shared.Entities.MobList)
	local Types = require(shared.Inventory.Types)
	local WeaponSync = require(shared.Net.WeaponSync)
	local Weapons = require(shared.Weapons)
	local WeaponState = require(shared.Weapons.WeaponState)
	local Handling = require(shared.Weapons.Handling)
	local Ballistics = require(shared.Weapons.Ballistics)
	local ScavengeLoot = require(shared.Generation.ScavengeLoot)
	local Hash = require(shared.Util.Hash)
	local FireRules = require(server.Weapons.FireRules)
	local Firing = require(server.Weapons.Firing)
	local WeaponActions = require(server.Weapons.WeaponActions)
	local InventoryState = require(server.Players.InventoryState)
	local Menu = require(shared.Inventory.Menu)
	local Melee = require(shared.Weapons.Melee)

	local I = Items.id
	local AIR = Blocks.AIR
	local STONE = Blocks.id.Stone
	local GLASS = Blocks.id.Glass
	local SURVIVAL, CREATIVE, SPECTATOR = GameMode.SURVIVAL, GameMode.CREATIVE, GameMode.SPECTATOR
	local TICK = 1 / 20
	local Op = WeaponSync.Op
	local Hit = WeaponSync.Hit

	--[[ Fixtures ]]

	-- A stack of `item` with weapon data `data` and wear `damage`.
	local function stack(item: number, data: { [string]: any }?, damage: number?): Items.Stack
		return { item = item, count = 1, damage = damage, data = Items.cleanData(data) }
	end

	-- A loaded pistol: a round chambered and a magazine of `n`.
	local function pistol(n: number, extra: { [string]: any }?, damage: number?): Items.Stack
		local data: { [string]: any } = { ch = I.Rounds9mm, mag = I.PistolMagazine }
		if n > 0 then
			data.n, data.ammo = n, I.Rounds9mm
		end
		for key, value in extra or {} do
			data[key] = value
		end
		return stack(I.Pistol, data, damage)
	end

	local function durability(item: number): number
		return (Items.get(item) :: any).durability
	end

	-- Config.Weapons with some fields changed (a copy: Config is never touched).
	local function settings(changes: { [string]: any }?): any
		local s = table.clone(Config.Weapons)
		for key, value in changes or {} do
			s[key] = value
		end
		return s
	end

	local function kind(name: string): any
		return MobList.get(MobList.find(name) :: number)
	end

	-- A deterministic stream in [0, 1).
	local function stream(seed: number): () -> number
		local rng = Hash.rng(seed)
		return function(): number
			return rng:float()
		end
	end

	--[[
		A fake world: blocks (`cells`, air elsewhere; `unloaded(x, y, z)` for nil), players (a real
		InventoryState and their positions), mobs, and every call Firing and WeaponActions make.
	]]
	local function newWorld(changes: { [string]: any }?): any
		local s = settings(changes)
		local w: any = {
			s = s,
			time = 100,
			roll = function(): number
				return 0
			end,
			cells = {},
			unloaded = nil,
			state = InventoryState.new(),
			info = {},
			order = {},
			mobs = {},
			seq = 0,
			shot = 0,
			acks = {},
			fired = {},
			mobHits = {},
			playerHits = {},
			noises = {},
			shattered = {},
			drops = {},
			inbox = {},
			sounds = {},
			later = {},
		}
		local function getBlock(x: number, y: number, z: number): number?
			local block = w.cells[`{x},{y},{z}`]
			if block ~= nil then
				return block
			end
			if w.unloaded and w.unloaded(x, y, z) then
				return nil
			end
			return AIR
		end
		w.getBlock = getBlock
		w.actions = WeaponActions.new({
			settings = s,
			now = function(): number
				return w.time
			end,
			held = function(key: any): Items.Stack?
				return w.state:heldStack(key)
			end,
			selected = function(key: any): number?
				local window = w.state:window(key)
				return if window then window.inventory.selected else nil
			end,
			alive = function(key: any): boolean
				return w.info[key].alive
			end,
			mode = function(key: any): string
				return w.info[key].mode
			end,
			setAim = function(key: any, aim: string?)
				w.info[key].attribute = aim
			end,
			play = function(key: any, sound: string)
				table.insert(w.sounds, { key = key, sound = sound, at = w.time })
			end,
			later = function(seconds: number, callback: () -> ())
				table.insert(w.later, { at = w.time + seconds, callback = callback })
			end,
		})
		w.firing = Firing.new({
			settings = s,
			now = function(): number
				return w.time
			end,
			random = function(): number
				return w.roll()
			end,
			getBlock = getBlock,
			shooter = function(key: any): FireRules.Shooter
				local p = w.info[key]
				local window = w.state:window(key)
				local aim, raisedAt, raisedSlot, raisedItem = w.actions:raised(key)
				return {
					now = 0,
					mode = p.mode,
					alive = p.alive,
					selected = window.inventory.selected,
					held = w.state:heldStack(key),
					aim = aim,
					raisedAt = raisedAt,
					raisedSlot = raisedSlot,
					raisedItem = raisedItem,
					busyUntil = w.actions:busyUntil(key),
					lastShot = nil,
					eyeX = p.x,
					eyeY = p.eyeY,
					eyeZ = p.z,
				}
			end,
			userId = function(key: any): number
				return w.info[key].userId
			end,
			acknowledge = function(key: any, seq: number)
				w.acks[seq] = (w.acks[seq] or 0) + 1
				w.state:acknowledge(key, seq)
			end,
			fire = function(key: any, seq: number, item: number, jam: boolean): Items.Stack?
				w.acks[seq] = (w.acks[seq] or 0) + 1
				table.insert(w.fired, { key = key, seq = seq, item = item, jam = jam })
				return w.state:fire(key, seq, item, jam, GameMode.instabuild(w.info[key].mode))
			end,
			held = function(key: any): Items.Stack?
				return w.state:heldStack(key)
			end,
			mobs = function(_key: any, x: number, y: number, z: number, radius: number): { FireRules.MobCandidate }
				w.asked = { x = x, y = y, z = z, radius = radius }
				local out = {}
				for _, mob in w.mobs do
					local dx, dy, dz = mob.x - x, mob.y - y, mob.z - z
					if dx * dx + dy * dy + dz * dz <= radius * radius then
						table.insert(out, mob)
					end
				end
				return out
			end,
			players = function(): { FireRules.PlayerCandidate }
				local out = {}
				for _, key in w.order do
					local p = w.info[key]
					table.insert(
						out,
						{ key = key, x = p.x, y = p.y, z = p.z, eyeY = p.eyeY, alive = p.alive, mode = p.mode }
					)
				end
				return out
			end,
			hurtMob = function(
				id: number,
				amount: number,
				key: any,
				ox: number,
				oz: number,
				knockback: number,
				head: boolean
			): number
				table.insert(
					w.mobHits,
					{ id = id, amount = amount, key = key, ox = ox, oz = oz, knockback = knockback, head = head }
				)
				return amount
			end,
			hurtPlayer = function(key: any, amount: number, head: boolean, bleed: boolean): number
				table.insert(w.playerHits, { key = key, amount = amount, head = head, bleed = bleed })
				return amount
			end,
			noise = function(x: number, y: number, z: number, radius: number)
				table.insert(w.noises, { x = x, y = y, z = z, radius = radius })
			end,
			shatter = function(x: number, y: number, z: number)
				table.insert(w.shattered, { x, y, z })
				w.cells[`{x},{y},{z}`] = AIR
			end,
			drop = function(item: number, x: number, y: number, z: number)
				table.insert(w.drops, { item = item, x = x, y = y, z = z })
			end,
			send = function(key: any, payload: buffer)
				local shots = WeaponSync.decodeShots(payload)
				assert(shots, "a well formed Shots message")
				local list = w.inbox[key]
				if list == nil then
					list = {}
					w.inbox[key] = list
				end
				table.insert(list, shots)
			end,
		})
		return w
	end

	-- A player `key` with `held` in hotbar slot 1 (selected), feet at (x, y, z).
	local function join(w: any, key: any, held: Items.Stack?, x: number, y: number, z: number, mode: string?)
		w.state:join(key)
		local window = w.state:window(key)
		window.inventory.slots[1] = held
		window.inventory.selected = 1
		table.insert(w.order, key)
		w.info[key] =
			{ userId = 1000 + #w.order, mode = mode or SURVIVAL, alive = true, x = x, y = y, z = z, eyeY = y + 1.62 }
	end

	-- Raises `key`'s gun and lets RaiseTicks pass.
	local function raise(w: any, key: any)
		t.ok(w.actions:weapon(key, Op.Raise), "raised")
		w.time += (w.s.RaiseTicks + 1) * TICK
	end

	-- A Fire message from `key`'s eyes along +x (the next seq and shot counter), with changes.
	local function fireOf(w: any, key: any, changes: { [string]: any }?): any
		w.seq += 1
		w.shot += 1
		local p = w.info[key]
		local held = w.state:heldStack(key)
		local fire = {
			seq = w.seq,
			shot = w.shot,
			slot = 1,
			item = if held then held.item else I.Pistol,
			sights = true,
			moving = false,
			crouching = false,
			breath = false,
			ox = p.x,
			oy = p.eyeY,
			oz = p.z,
			dx = 1,
			dy = 0,
			dz = 0,
		}
		for k, v in changes or {} do
			fire[k] = v
		end
		return fire
	end

	local function shoot(w: any, key: any, changes: { [string]: any }?): (string?, any)
		local fire = fireOf(w, key, changes)
		return w.firing:handle(key, fire), fire
	end

	-- What `key` was sent (every record of every message), after a flush.
	local function received(w: any, key: any): { any }
		w.firing:flush()
		local out = {}
		for _, message in w.inbox[key] or {} do
			for _, shot in message do
				table.insert(out, shot)
			end
		end
		w.inbox[key] = nil
		return out
	end

	local function zombieAt(w: any, id: number, name: string, x: number, z: number, variant: number?): any
		local mob = { id = id, kind = kind(name), variant = variant or 1, x = x, y = 70, z = z, yaw = 0 }
		table.insert(w.mobs, mob)
		return mob
	end

	--[[
		An inventory action of `key`'s as Players/Inventories plays it: a weapon action through the
		weapon hooks (`allow`, then `applied` with the stack it acted on), any other with the stack
		in the hotbar slot in hand before it and that slot's after (`changed`).
	]]
	local function act(w: any, key: any, action: any)
		w.seq += 1
		local window = w.state:window(key)
		if action.kind == "weapon" then
			if not w.actions:allow(key, action) then
				w.state:acknowledge(key, w.seq)
				return
			end
			local before = Items.copyStack(w.state:heldStack(key))
			w.state:applyAs(key, w.seq, action, w.info[key].mode)
			w.actions:applied(key, action, before, Items.copyStack(w.state:heldStack(key)))
			return
		end
		local slot = window.inventory.selected
		local before = Items.copyStack(window.inventory.slots[slot])
		w.state:applyAs(key, w.seq, action, w.info[key].mode)
		w.actions:changed(key, before, window.inventory.slots[slot])
	end

	-- A left (0) or right (1) click on inventory slot `slot` (1..36; 1..9 the hotbar).
	local function click(w: any, key: any, slot: number, button: number)
		local window = w.state:window(key)
		act(w, key, {
			kind = "click",
			window = window.id,
			slot = Menu.windowIndex(window, "inventory", slot),
			clickType = Menu.ClickType.Pickup,
			button = button,
		})
	end

	--[[ The checks ]]

	t.test("weapon firing: every check refuses in its order", function()
		local function good(): (any, any, any, any)
			local shooter = {
				now = 10,
				mode = SURVIVAL,
				alive = true,
				selected = 1,
				held = pistol(5),
				aim = Types.AIM_RAISED,
				raisedAt = 9,
				raisedSlot = 1,
				raisedItem = I.Pistol,
				busyUntil = nil,
				lastShot = nil,
				eyeX = 0.5,
				eyeY = 71.62,
				eyeZ = 0.5,
			}
			local fire = {
				seq = 1,
				shot = 1,
				slot = 1,
				item = I.Pistol,
				sights = true,
				moving = false,
				crouching = false,
				breath = false,
				ox = 0.5,
				oy = 71.62,
				oz = 0.5,
				dx = 1,
				dy = 0,
				dz = 0,
			}
			local cells: { [string]: number } = {}
			local function getBlock(x: number, y: number, z: number): number?
				return cells[`{x},{y},{z}`] or AIR
			end
			return shooter, fire, settings(), { cells = cells, getBlock = getBlock }
		end
		do
			local shooter, fire, s, world = good()
			t.eq(FireRules.check(shooter, fire, world.getBlock, s), nil, "a good shot goes")
		end
		-- Each reason's change (the order of FireRules.REASONS after "rate").
		local changes: { [string]: (any, any, any, any) -> () } = {
			disabled = function(_shooter, _fire, s)
				s.Enabled = false
			end,
			spectator = function(shooter)
				shooter.mode = SPECTATOR
			end,
			dead = function(shooter)
				shooter.alive = false
			end,
			slot = function(_shooter, fire)
				fire.slot = 2
			end,
			item = function(shooter, fire)
				shooter.held = stack(I.Smg, nil)
				fire.item = I.Pistol
			end,
			weapon = function(shooter, fire)
				shooter.held = stack(I.BaseballBat, nil)
				fire.item = I.BaseballBat
			end,
			raise = function(shooter)
				shooter.aim = nil
			end,
			busy = function(shooter)
				shooter.busyUntil = shooter.now + 1
			end,
			cadence = function(shooter)
				shooter.lastShot = shooter.now - 2 * TICK
			end,
			origin = function(_shooter, fire)
				fire.ox += 3
			end,
			ruined = function(shooter)
				shooter.held = Items.withData(shooter.held, shooter.held.data)
				shooter.held.damage = math.floor(durability(I.Pistol) * 0.85)
			end,
			jammed = function(shooter)
				local data = table.clone(shooter.held.data or {})
				data.ch, data.jam = I.Rounds9mm, true
				shooter.held = Items.withData(shooter.held, data)
			end,
			empty = function(shooter)
				local data = table.clone(shooter.held.data or {})
				data.ch, data.jam = nil, nil
				shooter.held = Items.withData(shooter.held, data)
			end,
		}
		local reasons = FireRules.REASONS
		t.eq(reasons[1], "rate", "the bucket first (Firing's own)")
		for k = 2, #reasons do
			local shooter, fire, s, world = good()
			-- (Every later reason's change too, the latest first: the earliest still wins.)
			for j = #reasons, k, -1 do
				changes[reasons[j]](shooter, fire, s, world)
			end
			t.eq(FireRules.check(shooter, fire, world.getBlock, s), reasons[k], `with {reasons[k]} and every later one`)
			-- And alone.
			local alone, fire2, s2, world2 = good()
			changes[reasons[k]](alone, fire2, s2, world2)
			t.eq(FireRules.check(alone, fire2, world2.getBlock, s2), reasons[k], `{reasons[k]} alone`)
		end
	end)

	t.test("weapon firing: the edges of raise, busy, cadence, origin and creative", function()
		local s = settings()
		local function shooterOf(changes: { [string]: any }?): any
			local shooter = {
				now = 10,
				mode = SURVIVAL,
				alive = true,
				selected = 1,
				held = pistol(5),
				aim = Types.AIM_RAISED,
				raisedAt = 9,
				eyeX = 0.5,
				eyeY = 71.62,
				eyeZ = 0.5,
			}
			for k, v in changes or {} do
				shooter[k] = v
			end
			-- (Raised in the slot and with the item in hand, unless told otherwise.)
			shooter.raisedSlot = shooter.raisedSlot or shooter.selected
			shooter.raisedItem = shooter.raisedItem or shooter.held.item
			return shooter
		end
		local fire = {
			seq = 1,
			shot = 1,
			slot = 1,
			item = I.Pistol,
			sights = true,
			moving = false,
			crouching = false,
			breath = false,
			ox = 0.5,
			oy = 71.62,
			oz = 0.5,
			dx = 1,
			dy = 0,
			dz = 0,
		}
		local cells: { [string]: number } = {}
		local function getBlock(x: number, y: number, z: number): number?
			return cells[`{x},{y},{z}`] or AIR
		end
		local function check(shooter: any, f: any?): string?
			return FireRules.check(shooter, f or fire, getBlock, s)
		end
		-- Raised RaiseTicks ago (one tick of slack), not before; guarding is no raise.
		t.eq(check(shooterOf({ raisedAt = 10 - (s.RaiseTicks - 1) * TICK })), nil, "a tick early is fine")
		t.eq(check(shooterOf({ raisedAt = 10 - (s.RaiseTicks - 2) * TICK })), "raise", "two ticks early")
		t.eq(check(shooterOf({ raisedAt = 10 })), "raise", "just raised")
		t.eq(check(shooterOf({ aim = Types.AIM_GUARD })), "raise", "guarding")
		local never = shooterOf()
		never.raisedAt = nil
		t.eq(check(never), "raise", "raised, but never told when")
		-- A raise never carries over to another slot or item, even before the aims are looked over.
		t.eq(check(shooterOf({ raisedSlot = 2 })), "raise", "raised in another slot")
		t.eq(check(shooterOf({ raisedItem = I.Smg })), "raise", "raised with another gun")
		-- A lock ends a tick early for the clocks.
		t.eq(check(shooterOf({ busyUntil = 10 + 0.5 * TICK })), nil, "within a tick of its end")
		t.eq(check(shooterOf({ busyUntil = 10 + 2 * TICK })), "busy")
		-- Cadence: the pistol's 4 ticks, one of slack.
		t.eq(check(shooterOf({ lastShot = 10 - 3 * TICK })), nil, "a tick early")
		t.eq(check(shooterOf({ lastShot = 10 - 2 * TICK })), "cadence", "too fast")
		local smg = stack(I.Smg, { ch = I.Rounds9mm, mode = 2 })
		local auto = table.clone(fire)
		auto.item = I.Smg
		t.eq(check(shooterOf({ held = smg, lastShot = 10 - 1.5 * TICK }), auto), nil, "700 rpm in auto")
		t.eq(
			check(shooterOf({ held = stack(I.Smg, { ch = I.Rounds9mm }), lastShot = 10 - 1.5 * TICK }), auto),
			"cadence",
			"not in semi"
		)
		-- Origin: OriginSlack from the server's eyes, nothing between, a unit aim.
		local near = table.clone(fire)
		near.ox += 2.4
		t.eq(check(shooterOf(), near), nil, "2.4 blocks off")
		local far = table.clone(fire)
		far.oy += 2.6
		t.eq(check(shooterOf(), far), "origin", "2.6 blocks off")
		cells["1,71,0"] = STONE
		local behind = table.clone(fire)
		behind.ox += 2
		t.eq(check(shooterOf(), behind), "origin", "through a wall")
		t.ok(FireRules.wallBetween(getBlock, 0.5, 71.62, 0.5, 2.5, 71.62, 0.5), "the wall")
		t.eq(check(shooterOf()), nil, "from its own eyes, the wall ahead")
		cells["1,71,0"] = nil
		t.eq(check(shooterOf(), behind), nil, "no wall")
		local long = table.clone(fire)
		long.dx = 1.05
		t.eq(check(shooterOf(), long), "origin", "an aim off unit length")
		local nowhere = shooterOf()
		nowhere.eyeX = nil
		t.eq(check(nowhere), "origin", "no position")
		-- Creative fires an empty gun, never a Ruined or jammed one.
		local empty = stack(I.Pistol, { mag = I.PistolMagazine })
		t.eq(check(shooterOf({ held = empty })), "empty")
		t.eq(check(shooterOf({ held = empty, mode = CREATIVE })), nil, "creative: no round needed")
		local jammed = pistol(3, { jam = true })
		t.eq(check(shooterOf({ held = jammed, mode = CREATIVE })), "jammed")
		local ruined = pistol(3, nil, math.floor(durability(I.Pistol) * 0.8))
		t.eq(check(shooterOf({ held = ruined })), "ruined", "at 20% left")
		t.eq(check(shooterOf({ held = ruined, mode = CREATIVE })), "ruined")
		local worn = pistol(3, nil, math.floor(durability(I.Pistol) * 0.79))
		t.eq(check(shooterOf({ held = worn })), nil, "just above Ruined")
	end)

	--[[ The pipeline ]]

	t.test("weapon firing: every Fire is acknowledged; the bucket drops silently, refusals are told", function()
		local w = newWorld()
		join(w, "a", pistol(15), 0.5, 70, 0.5)
		raise(w, "a")
		local reasons: { [string]: number } = {}
		for _ = 1, 60 do
			local reason = shoot(w, "a")
			reasons[reason or "ok"] = (reasons[reason or "ok"] or 0) + 1
		end
		t.eq(reasons.ok, 1, "the first")
		t.eq(reasons.cadence, 39, "the rest of the burst: too fast")
		t.eq(reasons.rate, 20, "past the burst of 40: dropped")
		for seq = 1, 60 do
			t.eq(w.acks[seq], 1, `seq {seq} acknowledged once`)
		end
		local got = received(w, "a")
		t.eq(#got, 40, "the shot and 39 refusals; nothing for the dropped")
		t.eq(got[1].refused, false)
		t.eq(#got[1].pellets, 1)
		local refused = 0
		for i = 2, #got do
			if got[i].refused and #got[i].pellets == 0 and got[i].shooter == w.info.a.userId then
				refused += 1
			end
		end
		t.eq(refused, 39, "each refusal its own record")
		-- The bucket fills again at ShotsPerSecond.
		w.time += 1
		t.eq((shoot(w, "a")), nil, "a second later")
		-- More than 64 records for one player go in several messages.
		for _ = 1, 70 do
			w.time += 1
			shoot(w, "a", { slot = 5 })
		end
		w.firing:flush()
		t.eq(#w.inbox.a, 2, "two messages")
		t.eq(#w.inbox.a[1], WeaponSync.MAX_SHOTS)
		t.eq(#w.inbox.a[2], 70 + 1 - WeaponSync.MAX_SHOTS)
	end)

	t.test("weapon firing: the exploits are refused and change nothing", function()
		local w = newWorld()
		join(w, "a", pistol(5), 0.5, 70, 0.5)
		local zombie = zombieAt(w, 7, "Zombie", 10.5, 0.5)
		local function refused(reason: string, changes: { [string]: any }?, why: string)
			local before = w.state:heldStack("a")
			local got, fire = shoot(w, "a", changes)
			t.eq(got, reason, why)
			t.eq(w.acks[fire.seq], 1, `{why}: acknowledged`)
			t.eq(w.state:heldStack("a"), before, `{why}: the gun as it was`)
			t.eq(#w.mobHits, 0, `{why}: nobody hurt`)
			local records = received(w, "a")
			t.eq(#records, 1, `{why}: told`)
			t.eq(records[1].refused, true)
			t.eq(#records[1].pellets, 0)
			t.eq(records[1].jammed, reason == "jammed", `{why}: the jam flag`)
		end
		-- Not raised (and a raise only counts after RaiseTicks).
		refused("raise", nil, "never raised")
		w.actions:weapon("a", Op.Raise)
		w.time += 2 * TICK
		refused("raise", nil, "raised two ticks ago")
		w.time += 5 * TICK
		-- The wrong item, the wrong slot.
		refused("item", { item = I.Smg }, "claims another gun")
		refused("slot", { slot = 3 }, "another hotbar slot")
		-- An origin through a wall, or far from the eyes.
		w.cells["1,71,0"] = STONE
		refused("origin", { ox = 2.4 }, "eyes behind a wall")
		w.cells["1,71,0"] = nil
		refused("origin", { oy = 75 }, "eyes in the air")
		-- Too fast: a shot, then another two ticks later.
		t.eq((shoot(w, "a")), nil, "a shot")
		received(w, "a")
		w.mobHits = {}
		w.time += 2 * TICK
		refused("cadence", nil, "two ticks after it")
		w.time += 3 * TICK
		-- Jammed, empty, Ruined.
		w.state:setHeld("a", pistol(3, { jam = true }))
		refused("jammed", nil, "a jammed gun")
		w.state:setHeld("a", stack(I.Pistol, { mag = I.PistolMagazine }))
		refused("empty", nil, "an empty chamber")
		w.state:setHeld("a", pistol(3, nil, math.floor(durability(I.Pistol) * 0.9)))
		refused("ruined", nil, "a Ruined gun")
		-- Dead and spectating players fire nothing.
		w.state:setHeld("a", pistol(3))
		w.info.a.alive = false
		refused("dead", nil, "dead")
		w.info.a.alive = true
		w.info.a.mode = SPECTATOR
		refused("spectator", nil, "a spectator")
		t.ok(zombie ~= nil)
	end)

	t.test("weapon firing: a shot fires the round, hurts the mob in its head, is heard and sent", function()
		local w = newWorld()
		join(w, "a", pistol(5), 0.5, 70, 0.5)
		join(w, "near", nil, 100.5, 70, 0.5)
		join(w, "far", nil, 300.5, 70, 0.5)
		zombieAt(w, 7, "Zombie", 10.5, 0.5)
		raise(w, "a")
		local reason, fire = shoot(w, "a")
		t.eq(reason, nil, "it went")
		t.eq(w.acks[fire.seq], 1, "acknowledged by the shot")
		t.eq(#w.fired, 1)
		t.eq(w.fired[1].jam, false, "a Pristine gun never jams")
		local held = w.state:heldStack("a") :: Items.Stack
		t.eq((WeaponState.rounds(held)), 4, "a round fed")
		t.eq(WeaponState.chamber(held), I.Rounds9mm)
		t.eq(held.damage, 1, "worn 1")
		t.eq(#w.mobHits, 1)
		local hit = w.mobHits[1]
		t.eq(hit.id, 7)
		t.eq(hit.head, true, "at eye level: the head")
		t.near(hit.amount, 7 * Config.Weapons.ZombieHead, 1e-9, "a 9mm round times 3")
		t.near(hit.knockback, Config.Weapons.BulletKnockback, 1e-12)
		t.eq(hit.key, "a", "credited to the shooter")
		t.near(hit.ox, 0.5, 1e-12, "pushed away from the muzzle")
		-- The mobs were asked for once, around the whole flight.
		t.ok(w.asked.radius >= 50, `a radius over the flight: {w.asked.radius}`)
		-- Noise: the muzzle's and where it landed (10 blocks off).
		t.eq(#w.noises, 2)
		t.eq(w.noises[1].radius, 48, "a pistol's")
		t.near(w.noises[1].x, 0.5, 1e-12)
		t.eq(w.noises[2].radius, Config.Weapons.ImpactNoise)
		t.near(w.noises[2].x, 10.22, 1e-9, "at the impact (the drawn head's side, 0.1 out)")
		-- The record: the shooter and the listener 100 blocks off, not the one at 300.
		local mine = received(w, "a")
		t.eq(#mine, 1)
		t.eq(mine[1].refused, false)
		t.eq(mine[1].item, I.Pistol)
		t.eq(mine[1].shot, fire.shot)
		t.eq(mine[1].shooter, w.info.a.userId)
		t.eq(mine[1].suppressed, false)
		t.eq(mine[1].jammed, false)
		t.eq(#mine[1].pellets, 1)
		t.eq(mine[1].pellets[1].hit, Hit.MobHead)
		t.near(mine[1].pellets[1].x, 10.22, 1e-4)
		t.eq(#received(w, "near"), 1, "within ShotBroadcast")
		t.eq(#received(w, "far"), 0, "beyond it")
		-- A body shot at the chest: 7, through its armour (Mobs' affair).
		w.time += 1
		t.eq((shoot(w, "a", { oy = 71.0 })), nil)
		t.eq(w.mobHits[2].head, false)
		t.near(w.mobHits[2].amount, 7, 1e-9)
		-- A jam the server rolls: a worn gun, a roll under its chance.
		w.time += 1
		w.state:setHeld("a", pistol(5, nil, math.floor(durability(I.Pistol) * 0.5)))
		w.roll = function(): number
			return 0.001
		end
		t.eq((shoot(w, "a")), nil, "it fires")
		t.eq(w.fired[#w.fired].jam, true, "rolled")
		t.eq(WeaponState.jammed(w.state:heldStack("a") :: Items.Stack), true, "the next round stuck")
		local records = received(w, "a")
		t.eq(#records, 2, "the body shot's and this one's")
		t.eq(records[1].jammed, false)
		t.eq(records[2].jammed, true, "the record says so")
		w.time += 1
		t.eq((shoot(w, "a")), "jammed", "and it fires no more")
	end)

	t.test("weapon firing: damage sums per target, head factors and helmets, buckshot", function()
		local s = settings()
		-- Hand made impacts: two targets, heads and bodies, panes counted once.
		local zombieTarget =
			FireRules.mobTarget({ id = 1, kind = kind("Zombie"), variant = 1, x = 0, y = 0, z = 0, yaw = 0 }, s)
		local soldierTarget =
			FireRules.mobTarget({ id = 2, kind = kind("ZombieSoldier"), variant = 1, x = 0, y = 0, z = 0, yaw = 0 }, s)
		t.eq(soldierTarget.helmet, true, "a soldier wears a helmet")
		t.eq(zombieTarget.helmet, false)
		t.eq(FireRules.helmet(kind("ZombieFirefighter"), 1), true, "a fire helmet")
		local shot = {
			damage = 2.5,
			range = 10,
			maxRange = 25,
			falloffMin = 0.2,
			velocity = 400,
			gravity = 9.8,
			zero = 20,
			segment = 0.05,
		}
		local function impact(target: any, head: boolean, share: number): any
			return { kind = "mob", x = 0, y = 0, z = 0, distance = 1, target = target, head = head, share = share }
		end
		local pane = {
			kind = "glass",
			x = 0,
			y = 0,
			z = 0,
			distance = 0.5,
			head = false,
			share = 1,
			cell = { 3, 4, 5 },
			block = GLASS,
		}
		local traces = {
			{ pane, impact(zombieTarget, true, 0.7) },
			{ pane, impact(zombieTarget, false, 0.7) },
			{ impact(zombieTarget, false, 1) },
			{ impact(soldierTarget, true, 1) },
			{ { kind = "block", x = 0, y = 0, z = 0, distance = 2, head = false, share = 1, cell = { 9, 9, 9 } } },
			{ { kind = "none", x = 0, y = 0, z = 0, distance = 25, head = false, share = 0.2 } },
		}
		local tally = FireRules.tally(traces, shot :: any, s)
		t.eq(#tally.mobs, 2)
		t.eq(#tally.players, 0)
		t.eq(#tally.glass, 1, "a pane twice is one pane")
		t.eq(#tally.finals, 6)
		local z, sol = tally.mobs[1], tally.mobs[2]
		t.eq(z.target, zombieTarget, "in the order first hit")
		t.eq(z.pellets, 3)
		t.near(z.head, 2.5 * 0.7 * s.ZombieHead, 1e-9)
		t.near(z.body, 2.5 * 0.7 + 2.5, 1e-9)
		t.near(sol.head, 2.5 * s.ZombieHead * s.HelmetShare, 1e-9, "a helmet takes its share")
		t.eq(sol.body, 0)
		t.eq(FireRules.knockback(3, 8, s), 3 * s.PelletKnockback)
		t.eq(FireRules.knockback(8, 8, s), FireRules.MAX_PELLET_KNOCKBACK, "at most 0.4")
		t.eq(FireRules.knockback(1, 1, s), s.BulletKnockback, "a bullet")
		-- Buckshot through the pipeline: 8 pellets into a brute 3 blocks off, summed.
		local w = newWorld()
		local shotgun = stack(I.PumpShotgun, { ch = I.Buckshot, n = 4, ammo = I.Buckshot })
		join(w, "a", shotgun, 0.5, 70, 0.5)
		zombieAt(w, 9, "ZombieBrute", 3.5, 0.5)
		w.roll = stream(77)
		raise(w, "a")
		t.eq((shoot(w, "a", { oy = 71.6 })), nil)
		local head, body, kicks, calls = 0, 0, 0, 0
		for _, hit in w.mobHits do
			t.eq(hit.id, 9)
			calls += 1
			kicks += hit.knockback
			if hit.head then
				head += hit.amount
			else
				body += hit.amount
			end
		end
		t.ok(calls == 1 or calls == 2, "once for the head, once for the body at most")
		local factor = Ballistics.headFactor(FireRules.mobTarget(w.mobs[1], s), s)
		t.near(head / factor + body, 8 * 2.5, 1e-9, "all 8 pellets summed, the head's times its factor")
		t.near(kicks, FireRules.MAX_PELLET_KNOCKBACK, 1e-9, "the knockback once, at most 0.4")
		local record = received(w, "a")[1]
		t.eq(#record.pellets, 8, "each pellet's impact sent")
		-- A soldier's helmet through the pipeline.
		local w2 = newWorld()
		join(w2, "a", pistol(5), 0.5, 70, 0.5)
		zombieAt(w2, 3, "ZombieSoldier", 10.5, 0.5)
		raise(w2, "a")
		t.eq((shoot(w2, "a")), nil)
		t.near(w2.mobHits[1].amount, 7 * s.ZombieHead * s.HelmetShare, 1e-9, "x3 x0.6")
		t.eq(w2.mobHits[1].head, true)
	end)

	t.test("weapon firing: PvP hurts players (heads x2); off, bullets pass them by", function()
		local function scene(pvp: boolean): any
			local w = newWorld({ PvP = pvp })
			join(w, "a", pistol(5), 0.5, 70, 0.5)
			join(w, "b", nil, 8.5, 70, 0.5)
			zombieAt(w, 4, "Zombie", 15.5, 0.5)
			raise(w, "a")
			t.eq((shoot(w, "a")), nil)
			return w
		end
		local on = scene(true)
		t.eq(#on.playerHits, 1)
		t.eq(on.playerHits[1].key, "b")
		t.eq(on.playerHits[1].head, true, "eye to eye")
		t.near(on.playerHits[1].amount, 7 * Config.Weapons.PlayerHead, 1e-9)
		t.eq(on.playerHits[1].bleed, true, "the Bleeding roll")
		t.eq(#on.mobHits, 0, "the player took it")
		t.eq(received(on, "a")[1].pellets[1].hit, Hit.PlayerHead)
		local off = scene(false)
		t.eq(#off.playerHits, 0, "PvP off spares players")
		t.eq(#off.mobHits, 1, "the zombie behind")
		-- Spectators and the dead are never in the way; the shooter never hits themselves.
		local w = newWorld()
		join(w, "a", pistol(5), 0.5, 70, 0.5)
		join(w, "ghost", nil, 5.5, 70, 0.5, SPECTATOR)
		join(w, "corpse", nil, 7.5, 70, 0.5)
		w.info.corpse.alive = false
		raise(w, "a")
		t.eq((shoot(w, "a")), nil)
		t.eq(#w.playerHits, 0)
		t.eq(received(w, "a")[1].pellets[1].hit, Hit.None)
	end)

	t.test("weapon firing: noise at the muzzle (suppressors) and where the shot lands", function()
		local pistolSpec = Weapons.firearm(I.Pistol) :: Weapons.FirearmSpec
		local small = Weapons.firearm(I.SmallBoreRifle) :: Weapons.FirearmSpec
		local suppressor = durability(I.Suppressor)
		t.eq(Handling.noise(pistolSpec, nil, nil), 48)
		t.eq(Handling.noise(pistolSpec, I.Suppressor, 1), 12, "x0.25")
		t.near(Handling.noise(pistolSpec, I.ImprovisedSuppressor, 1), 48 * 0.45, 1e-9, "x0.45")
		t.eq(Handling.noise(pistolSpec, I.Suppressor, 0.1), 48, "a Ruined one muffles nothing")
		t.eq(Handling.noise(small, I.Suppressor, 1), Config.Weapons.SuppressedMinNoise, "never under 8")
		-- Through the pipeline: a suppressed shot is quieter and says so.
		local w = newWorld()
		join(w, "a", pistol(5, { muzzle = I.Suppressor }), 0.5, 70, 0.5)
		w.cells["4,71,0"] = STONE
		raise(w, "a")
		t.eq((shoot(w, "a")), nil)
		t.eq(#w.noises, 1, "a wall 3.5 blocks off: no impact noise that near")
		t.eq(w.noises[1].radius, 12)
		local record = received(w, "a")[1]
		t.eq(record.suppressed, true)
		t.eq(record.pellets[1].hit, Hit.Block)
		t.eq((WeaponState.attachment(w.state:heldStack("a") :: Items.Stack, "muzzle")), I.Suppressor)
		t.eq(select(2, WeaponState.attachment(w.state:heldStack("a") :: Items.Stack, "muzzle")), 1, "the can wore 1")
		-- A Ruined suppressor is loud again.
		w.state:setHeld("a", pistol(5, { muzzle = I.Suppressor, muzzleD = suppressor }))
		w.time += 1
		w.noises = {}
		t.eq((shoot(w, "a")), nil)
		t.eq(w.noises[1].radius, 48)
		t.eq(received(w, "a")[1].suppressed, false)
		-- The farthest impact at least ImpactNoise away is heard.
		local s = Config.Weapons
		local finals = {
			{ kind = "block", x = 5, y = 0, z = 0 },
			{ kind = "mob", x = 12, y = 0, z = 0 },
			{ kind = "none", x = 90, y = 0, z = 0 },
		} :: any
		local x = FireRules.impactNoise(finals, 0, 0, 0, s)
		t.eq(x, 12, "the mob 12 away; the end of a flight is no impact")
		t.eq((FireRules.impactNoise({ { kind = "block", x = 7.9, y = 0, z = 0 } } :: any, 0, 0, 0, s)), nil, "too near")
		t.eq((FireRules.impactNoise({ { kind = "block", x = 8, y = 0, z = 0 } } :: any, 0, 0, 0, s)), 8, "at 8")
	end)

	t.test("weapon firing: glass shatters for builders only; unloaded cells end a shot", function()
		local w = newWorld()
		join(w, "a", pistol(5), 0.5, 70, 0.5)
		zombieAt(w, 1, "Zombie", 12.5, 0.5)
		w.cells["5,71,0"] = GLASS
		raise(w, "a")
		t.eq((shoot(w, "a")), nil)
		t.eq(#w.shattered, 1)
		t.eq(w.shattered[1][1], 5)
		t.near(w.mobHits[1].amount, 7 * 0.7 * Config.Weapons.ZombieHead, 1e-9, "0.7 through the pane")
		-- Adventure players don't break glass: it stops their bullet.
		local w2 = newWorld()
		join(w2, "a", pistol(5), 0.5, 70, 0.5, GameMode.ADVENTURE)
		zombieAt(w2, 1, "Zombie", 12.5, 0.5)
		w2.cells["5,71,0"] = GLASS
		raise(w2, "a")
		t.eq((shoot(w2, "a")), nil)
		t.eq(#w2.shattered, 0)
		t.eq(#w2.mobHits, 0)
		t.eq(received(w2, "a")[1].pellets[1].hit, Hit.Block)
		-- Nor does anyone with ShatterGlass off.
		local w3 = newWorld({ ShatterGlass = false })
		join(w3, "a", pistol(5), 0.5, 70, 0.5)
		w3.cells["5,71,0"] = GLASS
		raise(w3, "a")
		shoot(w3, "a")
		t.eq(#w3.shattered, 0)
		-- An unloaded cell: the flight ends there.
		local w4 = newWorld()
		join(w4, "a", pistol(5), 0.5, 70, 0.5)
		zombieAt(w4, 1, "Zombie", 30.5, 0.5)
		w4.unloaded = function(x: number): boolean
			return x >= 20
		end
		raise(w4, "a")
		shoot(w4, "a")
		t.eq(#w4.mobHits, 0)
		local pellet = received(w4, "a")[1].pellets[1]
		t.eq(pellet.hit, Hit.None)
		t.near(pellet.x, 20, 1e-4)
	end)

	t.test("weapon firing: who is sent a shot", function()
		local s = settings({ ShotBroadcast = 256 })
		local listeners = {
			{ key = "me", x = 0, y = 0, z = 0, eyeY = 1.62, alive = true, mode = SURVIVAL },
			{ key = "in", x = 200, y = 500, z = 100, eyeY = 0, alive = true, mode = SURVIVAL },
			{ key = "edge", x = 256, y = 0, z = 0, eyeY = 0, alive = false, mode = SPECTATOR },
			{ key = "out", x = 200, y = 0, z = 200, eyeY = 0, alive = true, mode = SURVIVAL },
		} :: any
		local who = FireRules.audience(listeners, 0, 0, "me", s)
		t.eq(#who, 3)
		t.eq(who[1], "me", "the shooter first, once")
		t.eq(who[2], "in", "horizontally within 256 (whatever the height)")
		t.eq(who[3], "edge", "the dead and spectators hear too")
		t.eq(#FireRules.audience({}, 0, 0, "me", s), 1, "always the shooter")
		-- The record's hit kinds.
		t.eq(FireRules.hitKind({ kind = "glass" } :: any), Hit.Glass)
		t.eq(FireRules.hitKind({ kind = "mob", head = false } :: any), Hit.Mob)
		t.eq(FireRules.hitKind({ kind = "player", head = false } :: any), Hit.Player)
		t.eq(FireRules.hitKind({ kind = "none" } :: any), Hit.None)
		local fire = { item = I.Pistol, shot = 9, ox = 1, oy = 2, oz = 3 } :: any
		local refused = FireRules.refused(42, fire, "jammed")
		t.eq(refused.refused, true)
		t.eq(refused.jammed, true)
		t.eq(#refused.pellets, 0)
		t.eq(FireRules.refused(42, fire, "cadence").jammed, false)
		-- A flight off the edge of the world still makes a well formed message.
		local edge = FireRules.record(42, fire, false, false, {
			{ kind = "none", x = 2e6, y = 9000, z = -2e6, head = false } :: any,
		})
		local decoded = WeaponSync.decodeShots(WeaponSync.encodeShots({ edge }))
		t.ok(decoded ~= nil, "clamped to what the message carries")
		t.eq((decoded :: any)[1].pellets[1].y, 4096)
	end)

	t.test("weapon firing: crossbow bolts drop again 70% from blocks, 35% from mobs", function()
		local s = settings()
		local bolt = Weapons.ammo(I.CrossbowBolt) :: Weapons.AmmoSpec
		local nine = Weapons.ammo(I.Rounds9mm) :: Weapons.AmmoSpec
		t.ok(bolt.recover and not nine.recover, "only bolts are recovered")
		local block = { kind = "block", x = 10, y = 5, z = 0, dx = 1, dy = 0, dz = 0 } :: any
		local mob = { kind = "mob", x = 10, y = 5, z = 0, dx = 1, dy = 0, dz = 0 } :: any
		local none = { kind = "none", x = 10, y = 5, z = 0 } :: any
		local fromBlock, fromMob = 0, 0
		for i = 0, 999 do
			local roll = (i + 0.5) / 1000
			if FireRules.recovery(bolt, block, roll, s) then
				fromBlock += 1
			end
			if FireRules.recovery(bolt, mob, roll, s) then
				fromMob += 1
			end
			t.eq((FireRules.recovery(bolt, none, roll, s)), nil, "a bolt that flew off is gone")
			t.eq((FireRules.recovery(nine, block, roll, s)), nil, "bullets are never recovered")
		end
		t.eq(fromBlock, 700, "BoltRecover of them from a block")
		t.eq(fromMob, 350, "half that from a mob")
		local x, y = FireRules.recovery(bolt, block, 0, s)
		t.near(x :: number, 10 - FireRules.BOLT_BACK, 1e-12, "backed out along its path")
		t.eq(y, 5)
		local mx = FireRules.recovery(bolt, mob, 0, s)
		t.eq(mx, 10, "at the mob")
		-- Through the pipeline: a crossbow into a wall.
		local w = newWorld()
		join(w, "a", stack(I.Crossbow, { ch = I.CrossbowBolt }), 0.5, 70, 0.5)
		w.cells["12,71,0"] = STONE
		raise(w, "a")
		t.eq((shoot(w, "a")), nil)
		t.eq(#w.drops, 1, "a roll of 0 always recovers")
		t.eq(w.drops[1].item, I.CrossbowBolt)
		t.ok(w.drops[1].x < 12 and w.drops[1].x > 11.7, `in front of the wall: {w.drops[1].x}`)
		t.eq(w.noises[1].radius, 6, "almost silent")
	end)

	t.test("weapon firing: creative fires without rounds, the calibre's first round", function()
		local w = newWorld()
		join(w, "a", stack(I.PumpShotgun, nil), 0.5, 70, 0.5, CREATIVE)
		zombieAt(w, 2, "Zombie", 5.5, 0.5)
		raise(w, "a")
		t.eq((shoot(w, "a", { oy = 71.2 })), nil, "an empty shotgun fires in creative")
		t.eq(FireRules.round(stack(I.PumpShotgun, nil), Weapons.firearm(I.PumpShotgun) :: any, true), I.Buckshot)
		t.eq(FireRules.round(stack(I.PumpShotgun, nil), Weapons.firearm(I.PumpShotgun) :: any, false), nil)
		t.eq(#received(w, "a")[1].pellets, 8, "buckshot: 8 pellets")
		t.ok(#w.mobHits >= 1)
		t.eq(w.state:heldStack("a").data, nil, "nothing used")
		t.eq(w.state:heldStack("a").damage, nil, "nor worn")
	end)

	--[[ Raising, locks and sounds ]]

	t.test("weapon actions: raise, lower and guard; dropped when the hand changes", function()
		local w = newWorld()
		join(w, "a", pistol(5), 0.5, 70, 0.5)
		local actions = w.actions
		t.ok(actions:weapon("a", Op.Raise))
		t.eq(w.info.a.attribute, Types.AIM_RAISED, "the attribute for everyone's poses")
		local aim, at = actions:raised("a")
		t.eq(aim, Types.AIM_RAISED)
		t.eq(at, w.time)
		w.time += 1
		t.eq(actions:weapon("a", Op.Raise), false, "raised already")
		t.eq(select(2, actions:raised("a")), w.time - 1, "the time it went up stands")
		t.ok(actions:weapon("a", Op.Lower))
		t.eq(w.info.a.attribute, nil)
		t.eq(actions:weapon("a", Op.Lower), false)
		t.eq(actions:weapon("a", Op.Guard), false, "a gun doesn't guard")
		-- A melee weapon guards, never raises.
		w.state:setHeld("a", stack(I.Machete, nil))
		t.eq(actions:weapon("a", Op.Raise), false)
		t.ok(actions:weapon("a", Op.Guard))
		t.eq(w.info.a.attribute, Types.AIM_GUARD)
		t.eq(select(2, actions:raised("a")), nil, "guarding is no raise")
		t.ok(actions:weapon("a", Op.Unguard))
		t.eq(w.info.a.attribute, nil)
		-- Dropped when the hand changes, the slot changes, or the player dies.
		w.state:setHeld("a", pistol(5))
		t.ok(actions:weapon("a", Op.Raise))
		actions:tick()
		t.eq(w.info.a.attribute, Types.AIM_RAISED, "nothing changed")
		w.state:setHeld("a", stack(I.Machete, nil))
		actions:tick()
		t.eq(w.info.a.attribute, nil, "another item in hand")
		w.state:setHeld("a", pistol(5))
		t.ok(actions:weapon("a", Op.Raise))
		w.state:window("a").inventory.selected = 2
		w.state:window("a").inventory.slots[2] = pistol(5)
		actions:tick()
		t.eq(w.info.a.attribute, nil, "another slot, even with a gun in it")
		w.state:window("a").inventory.selected = 1
		t.ok(actions:weapon("a", Op.Raise))
		w.info.a.alive = false
		actions:tick()
		t.eq(w.info.a.attribute, nil, "dead")
		t.eq(actions:weapon("a", Op.Raise), false, "the dead raise nothing")
		w.info.a.alive = true
		w.info.a.mode = SPECTATOR
		t.eq(actions:weapon("a", Op.Raise), false, "nor spectators")
		w.info.a.mode = SURVIVAL
		-- With firearms off nothing is raised; with the melee rework off nothing guards.
		local off = newWorld({ Enabled = false, Melee = { Enabled = false } })
		join(off, "a", pistol(5), 0.5, 70, 0.5)
		t.eq(off.actions:weapon("a", Op.Raise), false)
		off.state:setHeld("a", stack(I.Machete, nil))
		t.eq(off.actions:weapon("a", Op.Guard), false)
		-- At most WEAPON_RATE ops a second.
		local busy = newWorld()
		join(busy, "a", pistol(5), 0.5, 70, 0.5)
		local handled = 0
		for i = 1, 40 do
			if busy.actions:weapon("a", if i % 2 == 1 then Op.Raise else Op.Lower) then
				handled += 1
			end
		end
		t.eq(handled, WeaponActions.WEAPON_RATE, "the rest dropped")
		-- A guard goes with the weapon that held it, and with a life.
		w.state:setHeld("a", stack(I.Machete, nil))
		t.ok(actions:weapon("a", Op.Guard))
		w.state:setHeld("a", stack(I.KitchenKnife, nil))
		actions:tick()
		t.eq(w.info.a.attribute, nil, "another melee weapon: no guard until asked again")
		t.ok(actions:weapon("a", Op.Guard))
		w.info.a.alive = false
		actions:tick()
		t.eq(w.info.a.attribute, nil, "dead: no guard")
		w.info.a.alive = true
		-- `lower` (a character coming or going) drops either at once.
		t.ok(actions:weapon("a", Op.Guard))
		actions:lower("a")
		t.eq(w.info.a.attribute, nil, "guard dropped")
		t.eq((actions:raised("a")), nil)
		w.state:setHeld("a", pistol(5))
		t.ok(actions:weapon("a", Op.Raise))
		actions:lower("a")
		t.eq(w.info.a.attribute, nil, "raise dropped")
		t.eq(select(2, actions:raised("a")), nil)
		actions:lower("a")
		actions:lower("nobody")
		t.ok(actions:weapon("a", Op.Raise), "raised again from scratch")
		t.eq(select(2, actions:raised("a")), w.time)
		actions:forget("a")
		t.eq(actions:raised("a"), nil, "forgotten")
	end)

	t.test("weapon actions: what each action locks and sounds", function()
		local s = settings()
		local pistolSpec = Weapons.firearm(I.Pistol) :: Weapons.FirearmSpec
		local function effect(op: number, before: Items.Stack?, after: Items.Stack?): (number, { any })
			return WeaponActions.effect({ kind = "weapon", op = op, slot = -1, part = 0 }, before, after, s)
		end
		local emptyMag = stack(I.Pistol, { mag = I.PistolMagazine })
		local fresh = pistol(14)
		local ticks, cues = effect(WeaponActions.RELOAD, emptyMag, fresh)
		t.eq(ticks, pistolSpec.reloadTicks + pistolSpec.chamberTicks, "a magazine in and a round chambered")
		t.eq(#cues, 2)
		t.eq(cues[1].sound, "item.firearm.reload")
		t.eq(cues[1].delay, 0)
		t.eq(cues[2].sound, "item.firearm.chamber")
		t.eq(cues[2].delay, pistolSpec.reloadTicks, "after the magazine")
		ticks, cues = effect(WeaponActions.RELOAD, pistol(2), pistol(15))
		t.eq(ticks, pistolSpec.reloadTicks, "a fuller magazine, chambered already")
		t.eq(#cues, 1)
		ticks, cues = effect(WeaponActions.RELOAD, pistol(2, nil, 0), pistol(2, { magD = 30 }))
		t.eq(ticks, pistolSpec.reloadTicks, "another magazine as full (its wear tells)")
		local unchambered = stack(I.Pistol, { mag = I.PistolMagazine, n = 5, ammo = I.Rounds9mm })
		ticks, cues = effect(WeaponActions.RELOAD, unchambered, pistol(4))
		t.eq(ticks, pistolSpec.chamberTicks, "only chambered")
		t.eq(cues[1].sound, "item.firearm.chamber")
		t.eq((effect(WeaponActions.RELOAD, pistol(5), pistol(5))), 0, "nothing better: nothing")
		local revolver = Weapons.firearm(I.Revolver) :: Weapons.FirearmSpec
		ticks, cues = effect(
			WeaponActions.LOAD_ROUND,
			stack(I.Revolver, { ch = I.Rounds357, n = 2, ammo = I.Rounds357 }),
			stack(I.Revolver, { ch = I.Rounds357, n = 3, ammo = I.Rounds357 })
		)
		t.eq(ticks, revolver.roundTicks, "a round by hand")
		t.eq(cues[1].sound, "item.firearm.load_round")
		t.eq(
			(effect(WeaponActions.RELOAD, stack(I.Revolver, nil), stack(I.Revolver, { ch = I.Rounds357 }))),
			revolver.roundTicks,
			"R on an internal magazine loads a round"
		)
		ticks, cues = effect(WeaponActions.UNJAM, pistol(3, { jam = true }), pistol(2))
		t.eq(ticks, s.UnjamTicks)
		t.eq(cues[1].sound, "item.firearm.chamber")
		t.eq((effect(WeaponActions.MODE, stack(I.Smg, nil), stack(I.Smg, { mode = 2 }))), s.ModeTicks)
		t.eq(
			(
				effect(
					WeaponActions.LIGHT,
					pistol(2, { light = I.WeaponFlashlight }),
					pistol(2, { light = I.WeaponFlashlight, lit = true })
				)
			),
			0
		)
		t.eq((effect(WeaponActions.DETACH, pistol(2), stack(I.Pistol, { ch = I.Rounds9mm }))), 0)
		t.eq((effect(WeaponActions.RELOAD, nil, pistol(2))), 0, "nothing in hand")
		t.eq((effect(WeaponActions.RELOAD, stack(I.Machete, nil), stack(I.Machete, nil))), 0, "no firearm")
		t.eq((effect(WeaponActions.RELOAD, pistol(2), stack(I.Smg, { ch = I.Rounds9mm }))), 0, "another item")
		-- Actions Loading refused hand back the stack as it was: no lock, no sound.
		local jammedGun = stack(I.Revolver, { ch = I.Rounds357, jam = true, n = 2, ammo = I.Rounds357 })
		ticks, cues = effect(WeaponActions.LOAD_ROUND, jammedGun, table.clone(jammedGun))
		t.eq(ticks, 0, "a round into a jammed gun, refused")
		t.eq(#cues, 0)
		local bare = stack(I.Pistol, { mag = I.PistolMagazine })
		t.eq((effect(WeaponActions.RELOAD, bare, table.clone(bare))), 0, "no loaded magazine to swap in")
		t.eq((effect(WeaponActions.MODE, pistol(2), pistol(2))), 0, "one fire mode")
		t.eq((effect(WeaponActions.UNJAM, pistol(2), pistol(2))), 0, "nothing stuck")
	end)

	t.test("weapon actions: a lock holds back actions and shots; sounds go to the others", function()
		local w = newWorld()
		join(w, "a", stack(I.Pistol, { mag = I.PistolMagazine }), 0.5, 70, 0.5)
		raise(w, "a")
		local pistolSpec = Weapons.firearm(I.Pistol) :: Weapons.FirearmSpec
		local reload = { kind = "weapon", op = WeaponActions.RELOAD, slot = -1, part = 0 }
		t.ok(w.actions:allow("a", reload), "nothing running")
		-- (The inventory's Loading swaps a magazine in: here by hand.)
		local before = w.state:heldStack("a")
		w.state:setHeld("a", pistol(14))
		w.actions:applied("a", reload, before, w.state:heldStack("a"))
		local ends = w.time + (pistolSpec.reloadTicks + pistolSpec.chamberTicks) * TICK
		t.near(w.actions:busyUntil("a") :: number, ends, 1e-9)
		t.eq(#w.sounds, 1, "the reload at once")
		t.eq(w.sounds[1].sound, "item.firearm.reload")
		t.eq(#w.later, 1, "the chamber later")
		t.near(w.later[1].at, w.time + pistolSpec.reloadTicks * TICK, 1e-9)
		for op = WeaponActions.RELOAD, WeaponActions.MODE do
			t.eq(w.actions:allow("a", { kind = "weapon", op = op, slot = -1, part = 0 }), false, `op {op} waits`)
		end
		t.ok(w.actions:allow("a", { kind = "weapon", op = WeaponActions.LIGHT, slot = -1, part = 0 }), "the light")
		t.ok(w.actions:allow("a", { kind = "weapon", op = WeaponActions.DETACH, slot = 3, part = 1 }), "detaching")
		t.ok(w.actions:allow("a", { kind = "close", window = 0 } :: any), "anything else")
		t.eq((shoot(w, "a")), "busy", "no shot while reloading")
		w.time = ends - 0.5 * TICK
		t.ok(w.actions:allow("a", reload), "a tick of slack at the end")
		t.eq((shoot(w, "a")), nil, "and the shot goes")
		w.later[1].callback()
		t.eq(#w.sounds, 2)
		t.eq(w.sounds[2].sound, "item.firearm.chamber")
		-- A player who left hears of nothing more.
		w.actions:applied("a", reload, before, pistol(14))
		w.actions:forget("a")
		w.later[2].callback()
		t.eq(#w.sounds, 3, "only the reload at once")
		-- An action that changed nothing locks nothing (Loading refused it), nor sounds.
		w.actions:applied("a", reload, pistol(5), pistol(5))
		t.eq(w.actions:busyUntil("a"), nil)
		t.eq(#w.sounds, 3)
		t.ok(w.actions:allow("a", reload), "free to try again")
	end)

	t.test("weapon actions: a gun loaded in hand by clicks comes down and takes R's time", function()
		local pistolSpec = Weapons.firearm(I.Pistol) :: Weapons.FirearmSpec
		local raiseSeconds = (Config.Weapons.RaiseTicks + 1) * TICK
		-- A raised pistol, its magazine empty and nothing chambered; a full magazine and rounds by.
		local w = newWorld()
		join(w, "a", stack(I.Pistol, { mag = I.PistolMagazine }), 0.5, 70, 0.5)
		local inv = w.state:window("a").inventory
		inv.slots[10] = stack(I.PistolMagazine, { n = 15, ammo = I.Rounds9mm })
		inv.slots[11] = { item = I.Rounds9mm, count = 10 }
		raise(w, "a")
		t.eq((shoot(w, "a")), "empty")
		local t0 = w.time
		click(w, "a", 10, 0) -- the full magazine onto the cursor: the gun as it was
		t.eq(w.info.a.attribute, Types.AIM_RAISED, "nothing done to the gun yet")
		t.eq(w.actions:busyUntil("a"), nil)
		click(w, "a", 1, 0) -- onto the gun: swapped in
		t.eq((WeaponState.rounds(w.state:heldStack("a") :: any)), 15, "the magazine went in")
		t.eq(w.info.a.attribute, nil, "the gun came down")
		t.near(w.actions:busyUntil("a") :: number, t0 + pistolSpec.reloadTicks * TICK, 1e-9, "a magazine's ticks")
		click(w, "a", 10, 0) -- the empty one down
		click(w, "a", 11, 0) -- rounds onto the cursor
		click(w, "a", 1, 1) -- one chambered by hand
		t.eq(WeaponState.chamber(w.state:heldStack("a") :: any), I.Rounds9mm, "chambered by hand")
		local ends = t0 + (pistolSpec.reloadTicks + pistolSpec.chamberTicks) * TICK
		t.near(w.actions:busyUntil("a") :: number, ends, 1e-9, "and chambering's after it: R's 50 ticks")
		t.eq((shoot(w, "a")), "raise", "no shot from a gun brought down")
		t.ok(w.actions:weapon("a", Op.Raise), "raised again")
		w.time += raiseSeconds
		t.eq((shoot(w, "a")), "busy", "raised, but still loading")
		w.time = ends
		t.eq((shoot(w, "a")), nil, "R's time later it fires")

		-- A pump shotgun filled by clicks: a round's ticks each, as R round by round.
		local pump = Weapons.firearm(I.PumpShotgun) :: Weapons.FirearmSpec
		local p = newWorld()
		join(p, "a", stack(I.PumpShotgun, nil), 0.5, 70, 0.5)
		p.state:window("a").inventory.slots[11] = { item = I.Buckshot, count = 30 }
		raise(p, "a")
		local p0 = p.time
		click(p, "a", 11, 0)
		click(p, "a", 1, 0)
		click(p, "a", 11, 0)
		local loaded = (WeaponState.rounds(p.state:heldStack("a") :: any)) + 1
		t.eq(loaded, pump.internal + 1, "five in the tube and one chambered")
		t.near(p.actions:busyUntil("a") :: number, p0 + loaded * pump.roundTicks * TICK, 1e-9, "84 ticks, as by R")
		t.eq(p.info.a.attribute, nil)
		-- Right clicks one round at a time add up the same.
		local q = newWorld()
		join(q, "a", stack(I.PumpShotgun, nil), 0.5, 70, 0.5)
		q.state:window("a").inventory.slots[11] = { item = I.Buckshot, count = 30 }
		local q0 = q.time
		click(q, "a", 11, 0)
		for _ = 1, 3 do
			click(q, "a", 1, 1)
		end
		t.near(q.actions:busyUntil("a") :: number, q0 + 3 * pump.roundTicks * TICK, 1e-9, "three rounds, one by one")

		-- A jammed raised pistol swapped for a loaded one: down, and R's unjam and reload.
		local j = newWorld()
		join(j, "a", pistol(3, { jam = true }), 0.5, 70, 0.5)
		j.state:window("a").inventory.slots[10] = pistol(14)
		raise(j, "a")
		t.eq((shoot(j, "a")), "jammed")
		local j0 = j.time
		click(j, "a", 10, 0)
		click(j, "a", 1, 0)
		click(j, "a", 10, 0)
		j.actions:tick()
		t.eq((j.actions:raised("a")), nil, "down")
		t.near(
			j.actions:busyUntil("a") :: number,
			j0 + (j.s.UnjamTicks + pistolSpec.reloadTicks) * TICK,
			1e-9,
			"as long as clearing the jam and putting a magazine in"
		)
		t.eq((shoot(j, "a")), "raise")

		-- A Ruined magazine never jams a round chambered by hand, but each round takes its time.
		local r = newWorld()
		join(r, "a", pistol(0, { magD = durability(I.PistolMagazine) }), 0.5, 70, 0.5)
		r.state:window("a").inventory.slots[11] = { item = I.Rounds9mm, count = 20 }
		raise(r, "a")
		t.eq((shoot(r, "a")), nil, "the chambered round")
		local r0 = r.time
		click(r, "a", 11, 0)
		click(r, "a", 1, 1)
		click(r, "a", 11, 0)
		t.eq(r.info.a.attribute, nil, "down to chamber by hand")
		t.near(r.actions:busyUntil("a") :: number, r0 + pistolSpec.chamberTicks * TICK, 1e-9, "chambering's ticks")
		t.eq((shoot(r, "a")), "raise")
	end)

	t.test("weapon actions: what else changes the gun in hand, and what doesn't", function()
		local pistolSpec = Weapons.firearm(I.Pistol) :: Weapons.FirearmSpec
		-- A raise never carries over to another slot, even within the frame (before `tick`).
		local w = newWorld()
		join(w, "a", pistol(5), 0.5, 70, 0.5)
		local inv = w.state:window("a").inventory
		inv.slots[2] = stack(I.HuntingRifle, { ch = I.Rounds308, mag = I.HuntingMagazine, n = 4, ammo = I.Rounds308 })
		raise(w, "a")
		act(w, "a", { kind = "select", slot = 2 })
		t.eq(w.info.a.attribute, nil, "another slot: down at once")
		t.eq((shoot(w, "a", { slot = 2, item = I.HuntingRifle })), "raise", "the rifle was never raised")
		t.eq(w.actions:busyUntil("a"), nil, "a selection takes no time but the raise")
		-- Clicks elsewhere leave a raised gun alone: rounds into a magazine, stacks moved about.
		act(w, "a", { kind = "select", slot = 1 })
		raise(w, "a")
		inv.slots[10] = stack(I.PistolMagazine, nil)
		inv.slots[11] = { item = I.Rounds9mm, count = 10 }
		click(w, "a", 11, 0)
		click(w, "a", 10, 0)
		click(w, "a", 20, 0)
		t.eq((WeaponState.rounds(inv.slots[10] :: any)), 10, "a magazine loaded in the inventory")
		t.eq(w.info.a.attribute, Types.AIM_RAISED, "still raised")
		t.eq(w.actions:busyUntil("a"), nil, "nothing locked")
		t.eq((shoot(w, "a")), nil, "and it fires")
		-- Taken apart by a right click: down, and no lock (detaching takes none).
		click(w, "a", 1, 1)
		t.eq(WeaponState.magazine(inv.slots[1] :: any), nil, "the magazine out")
		t.eq(w.info.a.attribute, nil, "down")
		t.eq(w.actions:busyUntil("a"), nil, "no lock")
		click(w, "a", 25, 0)
		-- Another item clicked into its place: down, nothing to time.
		raise(w, "a")
		inv.slots[12] = stack(I.Machete, nil)
		click(w, "a", 12, 0)
		click(w, "a", 1, 0)
		t.eq(inv.slots[1] and inv.slots[1].item, I.Machete)
		t.eq(w.info.a.attribute, nil)
		t.eq(w.actions:busyUntil("a"), nil)

		-- The inventory screen open (the client lowered the gun): loading works, and is timed.
		local o = newWorld()
		join(o, "a", stack(I.Pistol, { mag = I.PistolMagazine }), 0.5, 70, 0.5)
		local oinv = o.state:window("a").inventory
		oinv.slots[10] = stack(I.PistolMagazine, { n = 15, ammo = I.Rounds9mm })
		local o0 = o.time
		click(o, "a", 10, 0)
		click(o, "a", 1, 0)
		click(o, "a", 10, 0)
		t.eq((WeaponState.rounds(oinv.slots[1] :: any)), 15, "loaded by the screen")
		t.near(o.actions:busyUntil("a") :: number, o0 + pistolSpec.reloadTicks * TICK, 1e-9)
		-- R then chambers after it (the lock's tick of slack lets it in at the end) and locks once.
		local reload = { kind = "weapon", op = WeaponActions.RELOAD, slot = -1, part = 0 }
		t.eq(o.actions:allow("a", reload), false, "R waits for the magazine")
		o.time = o0 + pistolSpec.reloadTicks * TICK
		local o1 = o.time
		act(o, "a", reload)
		t.eq(WeaponState.chamber(oinv.slots[1] :: any), I.Rounds9mm, "chambered by R")
		t.near(o.actions:busyUntil("a") :: number, o1 + pistolSpec.chamberTicks * TICK, 1e-9, "R's own lock, once")
		-- A click during a lock comes after it.
		oinv.slots[11] = stack(I.SmgMagazine, nil)
		oinv.slots[12] = pistol(15, { mag = I.PistolMagazine })
		click(o, "a", 12, 0)
		click(o, "a", 1, 0)
		t.near(
			o.actions:busyUntil("a") :: number,
			o1 + pistolSpec.chamberTicks * TICK + pistolSpec.reloadTicks * TICK,
			1e-9,
			"after the chambering still running"
		)
		-- Creative slots and drops change the hand too.
		local c = newWorld()
		join(c, "a", pistol(2), 0.5, 70, 0.5, CREATIVE)
		raise(c, "a")
		act(c, "a", { kind = "drop", all = true })
		t.eq(c.info.a.attribute, nil, "thrown: down at once")
	end)

	t.test("weapon actions: no attack while guarding or raised; a guard goes with the hand at once", function()
		t.ok(Melee.mayAttack(nil), "a hand held as ever")
		t.eq(Melee.mayAttack(Types.AIM_GUARD), false, "guarding")
		t.eq(Melee.mayAttack(Types.AIM_RAISED), false, "a gun raised fires; it never bashes")
		local w = newWorld()
		join(w, "a", stack(I.Machete, nil), 0.5, 70, 0.5)
		w.state:window("a").inventory.slots[2] = stack(I.Pistol, nil)
		w.state:window("a").inventory.slots[3] = stack(I.BaseballBat, nil)
		t.ok(Melee.mayAttack(w.info.a.attribute))
		t.ok(w.actions:weapon("a", Op.Guard))
		t.eq(Melee.mayAttack(w.info.a.attribute), false, "the server refuses its Attack")
		t.ok(w.actions:weapon("a", Op.Unguard))
		t.ok(Melee.mayAttack(w.info.a.attribute), "guard down: attacks again")
		-- Switching to the bat drops the guard as the selection arrives, so an attack sent right
		-- after it (the client's next message) lands.
		t.ok(w.actions:weapon("a", Op.Guard))
		act(w, "a", { kind = "select", slot = 3 })
		t.ok(Melee.mayAttack(w.info.a.attribute), "another weapon in hand: no guard")
		act(w, "a", { kind = "select", slot = 2 })
		t.ok(w.actions:weapon("a", Op.Raise))
		t.eq(Melee.mayAttack(w.info.a.attribute), false, "raised")
		t.ok(w.actions:weapon("a", Op.Lower))
		t.ok(Melee.mayAttack(w.info.a.attribute), "lowered: a bash")
		-- The server's Attack handler asks it before anything else is done.
		local mobs = fs.readFile("src/server/Mobs/Mobs.luau")
		local at = string.find(mobs, "Melee.mayAttack(player:GetAttribute(Types.AIM_ATTRIBUTE))", 1, true)
		local attack = string.find(mobs, "mobs:attack(id,", 1, true)
		t.ok(at ~= nil and attack ~= nil and at < attack, "Mobs' Attack handler refuses before MobWorld.attack")
	end)

	--[[ Loot and drops ]]

	t.test("weapon loot: worn entries within their range, real items, whole stacks", function()
		-- The tables: every entry a real item, wear only on items that wear, within 0..1.
		local worn: { [string]: { [string]: { number } } } = {}
		for name, pools in ScavengeLoot.TABLES do
			worn[name] = {}
			for _, pool in pools do
				for _, entry in pool.entries do
					local item = entry[1]
					if item then
						local id = Items.find(item)
						t.ok(id ~= nil, `{name}: {item} is an item`)
						t.ok(entry[3] >= 1 and entry[4] >= entry[3], `{name}: {item}'s counts`)
						t.ok(entry[4] <= Items.maxStack(id :: number), `{name}: {item} at most a stack`)
						local wear = entry[5]
						local range = worn[name][item] or { math.huge, -math.huge }
						if wear then
							t.ok((Items.get(id :: number) :: any).durability ~= nil, `{name}: {item} wears`)
							t.ok(wear[1] >= 0 and wear[1] <= wear[2] and wear[2] <= 1, `{name}: {item}'s wear`)
							range = { math.min(range[1], wear[1]), math.max(range[2], wear[2]) }
						else
							range = { math.min(range[1], 0), math.max(range[2], 0) }
						end
						worn[name][item] = range
					end
				end
			end
		end
		-- Rolls: damage within the entry's share of the durability, never a broken item.
		local salt = Hash.hash2(4242, Hash.string("cities.loot"), 0x0C17)
		local guns: { [string]: number } = {}
		local stats: { [string]: { containers: number, guns: number, ammo: number, magazines: number } } = {}
		for name in ScavengeLoot.TABLES do
			stats[name] = { containers = 0, guns = 0, ammo = 0, magazines = 0 }
			local found = 0
			for i = 1, 300 do
				local x, z = i * 7, -i * 13
				local items = ScavengeLoot.roll(name, salt, x, 64, z)
				local withGun = false
				for _, item in items do
					local id = Items.find(item.item) :: number
					t.ok(id ~= nil, `{item.item} exists`)
					t.ok(item.count >= 1 and item.count <= Items.maxStack(id), "a whole stack")
					local range = worn[name][item.item]
					local def = Items.get(id) :: any
					if def.durability then
						t.ok(item.damage >= math.floor(def.durability * range[1]), `{name}: {item.item} worn enough`)
						t.ok(item.damage <= math.floor(def.durability * range[2]), `{name}: {item.item} not too worn`)
						t.ok(item.damage < def.durability, "never broken")
					else
						t.eq(item.damage, 0, `{item.item} has no wear`)
					end
					if Weapons.firearm(id) then
						withGun = true
						guns[item.item] = (guns[item.item] or 0) + 1
						if i <= 100 then
							stats[name].guns += 1
						end
					elseif Weapons.ammo(id) and i <= 100 then
						stats[name].ammo += 1
					elseif Weapons.magazine(id) and i <= 100 then
						stats[name].magazines += 1
					end
					found += 1
				end
				if withGun and i <= 100 then
					stats[name].containers += 1
				end
			end
			t.ok(found > 0, `{name} holds something`)
		end
		-- Firearms are rare, but the police and the armory have them.
		t.ok(stats.police.guns > 0 and stats.bunker_armory.guns > 0, "guns in police stations and armories")
		t.ok(stats.bunker_armory.ammo > stats.bunker_armory.guns, "more rounds than guns")
		t.eq(stats.grocery.guns, 0, "none in a grocery")
		for _, name in { "police", "bunker_armory", "house" } do
			local s = stats[name]
			print(
				`    {name}: 100 containers, {s.containers} with a firearm ({s.guns} firearms), {s.ammo} ammunition stacks, {s.magazines} magazines`
			)
		end
		t.ok(guns.Pistol ~= nil and guns.AssaultRifle ~= nil, "pistols and assault rifles turn up")
		-- Unedited tables roll as before: the pharmacy's first container.
		local pharmacy = ScavengeLoot.roll("pharmacy", salt, 7, 64, -13)
		for _, item in pharmacy do
			t.eq(item.damage, 0)
		end
	end)

	t.test("weapon loot: police, soldier and construction zombies drop rounds, magazines, a wrench", function()
		local function drop(name: string, item: string): any
			for _, d in kind(name).drops do
				if d.item == item then
					return d
				end
			end
			return nil
		end
		local police = drop("ZombiePolice", "Rounds9mm")
		t.ok(police and police.min == 2 and police.max == 6 and police.chance == 0.15 and police.byPlayer, "9mm")
		local mag = drop("ZombiePolice", "PistolMagazine")
		t.ok(mag and mag.min == 1 and mag.max == 1 and mag.chance == 0.03 and mag.byPlayer, "a pistol magazine")
		local soldier = drop("ZombieSoldier", "Rounds556")
		t.ok(soldier and soldier.min == 3 and soldier.max == 10 and soldier.chance == 0.2 and soldier.byPlayer, "5.56")
		local rifleMag = drop("ZombieSoldier", "RifleMagazine")
		t.ok(rifleMag and rifleMag.chance == 0.04 and rifleMag.byPlayer, "a rifle magazine")
		local wrench = drop("ZombieWorker", "PipeWrench")
		t.ok(wrench and wrench.chance == 0.02 and wrench.byPlayer, "a pipe wrench")
		t.eq(drop("Zombie", "Rounds9mm"), nil, "civilians carry no rounds")
		for _, d in kind("ZombiePolice").drops do
			t.ok(d.max <= Items.maxStack(Items.find(d.item) :: number), `{d.item} within a stack`)
		end
	end)
end
