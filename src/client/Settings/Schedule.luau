--!strict
--[[
	When the effects of settings changes run (pure; the client's Settings controller asks it once
	per frame).

	  * Cheap effects (the field of view, volumes, the HUD, fog, lights...) run at the next frame,
	    once however many changes asked for them in between.
	  * Costly ones (PlayerSettings.EXPENSIVE: the view, caves, plants, shadows, textures, far
	    meshes) wait until no change has asked for them for `delay` seconds, so dragging a slider
	    rebuilds the world once, after it stops, instead of at every step.
	  * `due` gives them in PlayerSettings.EFFECT_ORDER (the view before the fog that follows it);
	    `due(now, true)` gives every waiting one at once (the menu closing).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local PlayerSettings = require(Shared.PlayerSettings)

export type Schedule = {
	delay: number,
	-- Effect -> the time (seconds, the caller's clock) it may run from.
	dueAt: { [string]: number },
}

local Schedule = {}

-- Effects not in EFFECT_ORDER run after the listed ones, by name.
local ORDER: { [string]: number } = {}
for i, effect in PlayerSettings.EFFECT_ORDER do
	ORDER[effect] = i
end

function Schedule.new(delay: number): Schedule
	return { delay = delay, dueAt = {} }
end

-- Asks for `effect` at `now` (a costly one moves back to `now + delay`).
function Schedule.mark(self: Schedule, effect: string, now: number)
	self.dueAt[effect] = if PlayerSettings.EXPENSIVE[effect] then now + self.delay else now
end

-- Asks for every effect the settings `keys` need.
function Schedule.markKeys(self: Schedule, keys: { string }, now: number)
	for _, key in keys do
		for _, effect in PlayerSettings.effectsOf(key) do
			Schedule.mark(self, effect, now)
		end
	end
end

-- The effects to run now (all waiting ones with `all`), in order; they are no longer waiting.
function Schedule.due(self: Schedule, now: number, all: boolean?): { string }
	local list: { string } = {}
	for effect, at in self.dueAt do
		if all or at <= now then
			table.insert(list, effect)
		end
	end
	for _, effect in list do
		self.dueAt[effect] = nil
	end
	table.sort(list, function(a: string, b: string): boolean
		local oa, ob = ORDER[a] or math.huge, ORDER[b] or math.huge
		if oa ~= ob then
			return oa < ob
		end
		return a < b
	end)
	return list
end

-- How many effects are waiting.
function Schedule.waiting(self: Schedule): number
	local count = 0
	for _ in self.dueAt do
		count += 1
	end
	return count
end

return Schedule
