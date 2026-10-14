--[[
	Eating and drinking loops (client Audio/UseSoundRules, played by Audio/UseSounds; the server's
	side is Players/UseState): while a player holds an eat or drink use, its recording loops and
	stops the moment the use ends (finished, cancelled, slot changed, death, leaving); only when
	the recording fails to load do Minecraft's clicks play instead, every 4 ticks from the 7th, on
	the old ticks, never both, never on the use's last tick; the server's attribute names the use
	every client plays (eat for food, not medicine; drink), and ends with it.
]]

return function(t, shared, require, server, client)
	local UseSoundRules = require(client.Audio.UseSoundRules)
	local UseState = require(server.Players.UseState)
	local Types = require(shared.Inventory.Types)
	local Foods = require(shared.Items.Foods)
	local Drinks = require(shared.ToughAsNails.Drinks)
	local Sounds = require(shared.Sounds)

	local TICK = UseSoundRules.TICK
	local function always(value: boolean): (name: string) -> boolean
		return function(_name: string): boolean
			return value
		end
	end

	-- Runs a use of `kind` for `seconds` in frames of `dt`; returns each frame's loop and click,
	-- and the elapsed time at each.
	local function run(
		use: any,
		kind: string?,
		seconds: number,
		dt: number,
		length: number?,
		loads: (name: string) -> boolean,
		alive: boolean?
	): { { loop: string?, click: string?, at: number } }
		local frames = {}
		local at = 0
		while at < seconds - 1e-9 do
			at += dt
			local loop, click = UseSoundRules.step(use, kind, alive ~= false, dt, length, loads)
			table.insert(frames, { loop = loop, click = click, at = at })
		end
		return frames
	end

	t.test("use sounds: a held use loops its recording, from the first frame to the moment it ends", function()
		for kind, loopName in UseSoundRules.LOOPS do
			local use = UseSoundRules.new()
			local frames = run(use, kind, 1.2, 1 / 60, 32, always(true))
			for _, frame in frames do
				t.eq(frame.loop, loopName, `{kind}: the loop at {frame.at}`)
				t.eq(frame.click, nil, `{kind}: no click while the loop plays`)
			end
			-- Ended (finished, cancelled, slot changed: the use is gone): silent that very frame.
			local loop, click = UseSoundRules.step(use, nil, true, 1 / 60, 32, always(true))
			t.eq(loop, nil, `{kind}: the loop stops at once`)
			t.eq(click, nil)
			t.eq(use.kind, nil, "the state starts over")
			-- Dead: silent too, whatever the attribute still says.
			local dead = UseSoundRules.new()
			run(dead, kind, 0.5, 1 / 60, nil, always(true))
			loop = UseSoundRules.step(dead, kind, false, 1 / 60, nil, always(true))
			t.eq(loop, nil, `{kind}: no loop for the dead`)
		end
		t.eq(UseSoundRules.LOOPS.eat, "entity.generic.eating")
		t.eq(UseSoundRules.LOOPS.drink, "entity.generic.drinking")
		t.eq(UseSoundRules.LOOPS[Types.USE_EAT], UseSoundRules.LOOPS.eat, "the attribute's names")
		t.eq(UseSoundRules.LOOPS[Types.USE_DRINK], UseSoundRules.LOOPS.drink)
		-- Nothing held: nothing.
		local idle = UseSoundRules.new()
		local loop, click = UseSoundRules.step(idle, nil, true, 1, nil, always(true))
		t.ok(loop == nil and click == nil, "no use, no sound")
	end)

	t.test("use sounds: a recording that failed to load gives Minecraft's clicks instead, never both", function()
		for kind, clickName in UseSoundRules.CLICKS do
			-- The local player's 32 tick use at 60 frames a second: clicks on ticks 8, 12 ... 28,
			-- none on the 32nd (the burp or last gulp's), and never a loop.
			local use = UseSoundRules.new()
			local frames = run(use, kind, 32 * TICK - 1e-6, 1 / 60, 32, always(false))
			local ticks = {}
			for _, frame in frames do
				t.eq(frame.loop, nil, `{kind}: no loop when it cannot play`)
				if frame.click then
					t.eq(frame.click, clickName)
					table.insert(ticks, math.floor(frame.at / TICK + 1e-6))
				end
			end
			t.eq(table.concat(ticks, ","), "8,12,16,20,24,28", `{kind}: Minecraft's clicks`)
			local _, last = UseSoundRules.step(use, kind, true, 2 * TICK, 32, always(false))
			t.eq(last, nil, `{kind}: none on the last tick`)
			-- Another player's (no length known): the same ticks, and on while the use lasts.
			local remote = UseSoundRules.new()
			local count = 0
			for _, frame in run(remote, kind, 50 * TICK, 1 / 30, nil, always(false)) do
				if frame.click then
					count += 1
				end
			end
			t.eq(count, 11, `{kind}: ticks 8 to 48 over 50 ticks (each in a frame of its own)`)
		end
		t.eq(UseSoundRules.CLICKS.eat, "entity.generic.eat")
		t.eq(UseSoundRules.CLICKS.drink, "entity.generic.drink")
		-- A recording that fails midway: the clicks come in step with the ticks already counted.
		-- (A tick and a hair a frame, so each frame is one tick whatever the rounding.)
		local use = UseSoundRules.new()
		for _ = 1, 10 do
			UseSoundRules.step(use, "eat", true, TICK + 1e-9, 32, always(true))
		end
		t.eq(use.ticks, 10, "ticks count while the loop plays")
		local clicks = {}
		for _ = 1, 10 do
			local _, click = UseSoundRules.step(use, "eat", true, TICK + 1e-9, 32, always(false))
			if click then
				table.insert(clicks, use.ticks)
			end
		end
		t.eq(table.concat(clicks, ","), "12,16,20", "on the use's own ticks")
		-- Never both, in any frame, loaded or not, over random frame lengths.
		local seed = 7
		local function rand(): number
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed / 2147483648
		end
		local any = UseSoundRules.new()
		for _ = 1, 2000 do
			local loads = rand() < 0.5
			local loop, click = UseSoundRules.step(any, "drink", true, rand() * 0.1, nil, always(loads))
			t.ok(loop == nil or click == nil, "a loop or clicks, never both")
			t.ok(loads == (loop ~= nil), "the loop exactly when it can play")
		end
	end)

	t.test("use sounds: the clicks are Minecraft's for every food and drink (lengths of 4s)", function()
		-- Minecraft (LivingEntity.shouldTriggerItemUseEffect): remaining ticks <= length - 7 and a
		-- multiple of 4, never at 0 (the end's own sound).
		local function minecraft(tick: number, length: number): boolean
			local remaining = length - tick
			return remaining > 0 and remaining <= length - 7 and remaining % 4 == 0
		end
		local lengths: { [number]: string } = { [Drinks.USE_TICKS] = "drinks" }
		for item, food in Foods.ITEMS do
			if not Foods.isMedical(food) then
				lengths[Foods.useTicks(food)] = `food {item}`
			end
		end
		for length, what in lengths do
			t.eq(length % 4, 0, `{what}: {length} ticks, a multiple of 4`)
			for tick = 1, length + 4 do
				t.eq(UseSoundRules.clickDue(tick, length), minecraft(tick, length), `{what}: tick {tick}`)
				if tick < length then
					t.eq(
						UseSoundRules.clickDue(tick, nil),
						minecraft(tick, length),
						`{what}: unknown length, tick {tick}`
					)
				end
			end
		end
	end)

	t.test("use sounds: only the attribute's two uses count", function()
		t.eq(UseSoundRules.kindOf("eat"), "eat")
		t.eq(UseSoundRules.kindOf("drink"), "drink")
		t.eq(UseSoundRules.kindOf(nil), nil)
		t.eq(UseSoundRules.kindOf("sip"), nil, "unknown names")
		t.eq(UseSoundRules.kindOf(3), nil, "not a name")
		t.eq(Types.USE_ATTRIBUTE, "IceVoxelUse")
		-- The events: each client plays the loops itself, at the players' volume, heard 16 blocks.
		for kind, name in UseSoundRules.LOOPS do
			local event = Sounds.get(name) :: any
			t.ok(event ~= nil, `{name} is an event`)
			t.eq(event.side, "client", `{name}: each client plays it`)
			t.eq(event.source, "players")
			t.eq(event.duration, nil, `{name}: played whole, looped`)
			t.eq(event.category, nil, `{name}: replaced by its own name only`)
			t.ok(Sounds.get(UseSoundRules.CLICKS[kind]) ~= nil, `{kind}'s clicks are events`)
		end
		t.eq((Sounds.get("entity.generic.eating") :: any).id, "rbxassetid://124005963174357", "the sheet's Eat")
		t.eq((Sounds.get("entity.generic.drinking") :: any).id, "rbxassetid://79766888063175", "the sheet's Drink")
		-- The burp stays.
		t.ok(Sounds.get(Foods.BURP) ~= nil, "the burp")
	end)

	t.test("use sounds: the server's attribute names a player's use while it lasts", function()
		local function fakePlayer(): any
			local attributes = {}
			return {
				GetAttribute = function(_, name: string): any
					return attributes[name]
				end,
				SetAttribute = function(_, name: string, value: any)
					attributes[name] = value
				end,
			}
		end
		local player = fakePlayer()
		UseState.begin(player, Types.USE_EAT, 32)
		t.eq(player:GetAttribute(Types.USE_ATTRIBUTE), "eat", "eating")
		t.eq(UseState.of(player), "eat")
		UseState.finish(player, Types.USE_DRINK)
		t.eq(player:GetAttribute(Types.USE_ATTRIBUTE), "eat", "a drink ending leaves the food alone")
		UseState.finish(player, Types.USE_EAT)
		t.eq(player:GetAttribute(Types.USE_ATTRIBUTE), nil, "ended")
		t.eq(UseState.of(player), nil)
		UseState.begin(player, Types.USE_DRINK, Drinks.USE_TICKS)
		t.eq(player:GetAttribute(Types.USE_ATTRIBUTE), "drink", "drinking")
		UseState.finish(player)
		t.eq(player:GetAttribute(Types.USE_ATTRIBUTE), nil, "any use ends")
		t.ok(not pcall(UseState.begin, player, "chew", 10), "unknown uses are refused")
		-- A use left hanging (no finish ever comes) runs out a second after its length.
		t.ok(not UseState.expired(0, 32, 32 * TICK), "not at its length")
		t.ok(not UseState.expired(0, 32, (32 + UseState.LEEWAY) * TICK - 0.01), "nor within the leeway")
		t.ok(UseState.expired(0, 32, (32 + UseState.LEEWAY) * TICK + 0.01), "then it ends")
		t.eq(UseState.LEEWAY * TICK, 1, "a second")
	end)
end
