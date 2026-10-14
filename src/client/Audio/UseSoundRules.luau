--!strict
--[[
	What a held eat or drink use sounds like (pure, so the tests check it; Audio/UseSounds plays
	it for every player near: the local player from their own hold, at once, the others from the
	server's player attribute Inventory/Types.USE_ATTRIBUTE).

	  loop    while the use lasts, its recording loops at the player's mouth (LOOPS: the fourth
	          sheet's "loop this during eating / drinking", Sounds/SoundList), and it stops the
	          moment the use ends: finished, cancelled, the hotbar slot changed, the player dead or
	          gone (no use, or not `alive`).
	  clicks  only when the loop's recording cannot play (its file failed to load, and no
	          developer's Sound replaces it: Audio/SoundPlayer.loads), Minecraft's clicks instead
	          (CLICKS: entity.generic.eat / .drink on the use's CLICK_EVERY-th ticks from the
	          CLICK_FROM-th, LivingEntity.triggerItemUseEffects), never both. That is Minecraft's
	          rule (remaining ticks at most length - 7, a multiple of 4) for every use whose length
	          is a multiple of 4, as every food's and drink's is, so a remote player's clicks need
	          no length; a use of a known length (the local player's) clicks no more on its last
	          tick, which has its own sound.
	  ends    the burp after a food and the last gulp after a drink (Interaction/Eating, Drinking;
	          the server plays them to everyone else) stay either way: they tell a finished use
	          from one put away. Medicine plays its own sound and makes no "eat" use at all.

	`step` is called every frame for each player with a use (a fresh `new()` state each), with the
	use's kind (Types.USE_EAT, USE_DRINK, nil: none), whether the player is alive, the frame's
	seconds, the use's length when known, and SoundPlayer.loads; it returns the loop to play (an
	event name, nil: none) and the click due this frame (nil: none). A different kind, or a use
	after none, starts counting over.
]]

local UseSoundRules = {}

-- Minecraft's tick (seconds).
UseSoundRules.TICK = 1 / 20
-- Minecraft's clicks: every 4 ticks once 7 have passed (LivingEntity.shouldTriggerItemUseEffect).
UseSoundRules.CLICK_EVERY = 4
UseSoundRules.CLICK_FROM = 7

-- The loop of each use (Inventory/Types.USE_EAT, USE_DRINK) and the clicks that stand in for it.
UseSoundRules.LOOPS = table.freeze({ eat = "entity.generic.eating", drink = "entity.generic.drinking" })
UseSoundRules.CLICKS = table.freeze({ eat = "entity.generic.eat", drink = "entity.generic.drink" })

export type Use = {
	-- The use counted (nil: none), its seconds and whole ticks so far.
	kind: string?,
	elapsed: number,
	ticks: number,
}

function UseSoundRules.new(): Use
	return { kind = nil, elapsed = 0, ticks = 0 }
end

-- The use an attribute value names ("eat", "drink"), nil for anything else.
function UseSoundRules.kindOf(value: any): string?
	return if type(value) == "string" and UseSoundRules.LOOPS[value] ~= nil then value else nil
end

-- Is a click due on the use's `tick`-th tick (from 1)? Never on or after a known `length`'s end.
function UseSoundRules.clickDue(tick: number, length: number?): boolean
	if length and tick >= length then
		return false
	end
	return tick >= UseSoundRules.CLICK_FROM and tick % UseSoundRules.CLICK_EVERY == 0
end

--[[
	One frame of a player's use (see the header): returns the loop to play and the click due, as
	event names (nil: none). `loads(name)` says whether an event plays its own sound.
]]
function UseSoundRules.step(
	use: Use,
	kind: string?,
	alive: boolean,
	dt: number,
	length: number?,
	loads: (name: string) -> boolean
): (string?, string?)
	local loop = if kind then UseSoundRules.LOOPS[kind] else nil
	if loop == nil or not alive then
		use.kind, use.elapsed, use.ticks = nil, 0, 0
		return nil, nil
	end
	if use.kind ~= kind then
		use.kind, use.elapsed, use.ticks = kind, 0, 0
	end
	-- (The ticks count either way, so clicks come in step should the loop fail midway.)
	use.elapsed += math.max(dt, 0)
	local due = false
	while use.elapsed >= (use.ticks + 1) * UseSoundRules.TICK do
		use.ticks += 1
		due = due or UseSoundRules.clickDue(use.ticks, length)
	end
	if loads(loop) then
		return loop, nil
	end
	return nil, if due then UseSoundRules.CLICKS[kind :: string] else nil
end

return UseSoundRules
