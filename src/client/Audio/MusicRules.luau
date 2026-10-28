--!strict
--[[
	When background music plays, and which kind (pure; Audio/Music plays it). Minecraft's
	MusicManager, with the surface and caves as its "situations", and the surface's night as a
	list of its own:

	  Place    where the player is: "cave" once the sky light reaching the camera
	           (Rendering/LightingController.skyExposure) has stayed below CaveExposure for
	           SwitchSeconds, "surface" again once it has stayed above SurfaceExposure as long (the
	           gap between the two keeps a cave mouth from flipping it). The game starts on the
	           surface unless the first exposure says otherwise.
	  Lists    the tracks a place plays (Sounds/MusicList, the packs' music sets; `listOf`): "cave"
	           underground; on the surface "night" at night (the caller's `night`:
	           Shared/DayCycle.isDay false at the game's clock) and "surface" by day, or at night
	           when the night list has nothing to play (empty, or every track failed to load). The
	           list is chosen when a track is
	           picked: one already playing is never cut at dusk or dawn, as it is no change of
	           place; the next follows the time then.
	  Waits    nothing plays for `wait` seconds: FirstDelay after joining (Minecraft's 100 ticks),
	           then a random MinDelay to MaxDelay after each track ends (music.game's 12000 to
	           24000 ticks). Once it runs out a track of the place's list starts.
	  Changes  when the place changes, a track of the other place playing fades out (`"fade"`;
	           FadeSeconds, Audio/Music) and the wait becomes at most a random SwitchDelay, so a
	           track of the new place follows (Minecraft's replaceCurrentMusic, which waits up to
	           half its MinDelay). So surface (and night) music never plays underground, nor cave
	           music above it. A track of the right place keeps playing.
	  Tracks   picked at random, never the one that played last of that list (when there is
	           another), and never one that failed to load (Audio/Music says which). None starts
	           while the exposure already says the other place (a change on its way).

	`step` is called every frame with the seconds passed, the exposure and whether it is night; it
	returns what to do: { kind = "play", place = "surface" | "cave", list = "surface" | "night" |
	"cave", track = index } or { kind = "fade" }. Audio/Music reports back with `ended` when the
	track stops (finished, faded out or failed to load).
]]

export type Place = "surface" | "cave"

-- A list of tracks (Sounds/MusicList: Surface, Night, Cave, the packs' music sets).
export type List = "surface" | "night" | "cave"

export type Settings = {
	FirstDelay: number,
	MinDelay: number,
	MaxDelay: number,
	CaveExposure: number,
	SurfaceExposure: number,
	SwitchSeconds: number,
	FadeSeconds: number,
	SwitchDelay: number,
}

export type Action = { kind: "play", place: Place, list: List, track: number } | { kind: "fade" }

-- How a track stopped: it played to its end, it faded out because the place changed, or it never
-- started (its file failed to load, or it was cancelled while loading).
export type Ending = "finished" | "faded" | "failed"

export type State = {
	place: Place,
	-- Seconds the exposure has said the other place, in a row.
	changing: number,
	-- Seconds until the next track may start (counts down while nothing plays).
	wait: number,
	-- The place and list of the track playing or loading (nil: none), and whether it is fading
	-- out.
	playing: Place?,
	list: List?,
	fading: boolean,
	-- The last track of each list (no repeats) and the tracks that failed to load.
	last: { [List]: number },
	failed: { [List]: { [number]: boolean } },
}

local MusicRules = {}

function MusicRules.new(settings: Settings, place: Place?): State
	return {
		place = place or "surface" :: Place,
		changing = 0,
		wait = settings.FirstDelay,
		playing = nil,
		list = nil,
		fading = false,
		last = {},
		failed = { surface = {}, night = {}, cave = {} },
	}
end

-- The place an exposure says, or nil in the gap between the two thresholds.
function MusicRules.placeOf(settings: Settings, exposure: number): Place?
	if exposure < settings.CaveExposure then
		return "cave" :: Place
	elseif exposure > settings.SurfaceExposure then
		return "surface" :: Place
	end
	return nil
end

-- Has a list of `count` tracks one that has not failed to load?
local function playable(count: number, failed: { [number]: boolean }): boolean
	for i = 1, count do
		if not failed[i] then
			return true
		end
	end
	return false
end

--[[
	The list a track for `place` comes from: "cave" underground; on the surface "night" at night
	(`night`) while it has a track to play (`counts`, `failed`), else "surface".
]]
function MusicRules.listOf(
	place: Place,
	night: boolean,
	counts: { [List]: number },
	failed: { [List]: { [number]: boolean } }?
): List
	if place == "cave" then
		return "cave" :: List
	end
	local nightList: List = "night"
	if night and playable(counts[nightList] or 0, if failed then failed[nightList] or {} else {}) then
		return nightList
	end
	return "surface" :: List
end

--[[
	A track of `count` for `roll` in [0, 1): any but `last` (when there is another) and those in
	`failed`; nil when none is left.
]]
function MusicRules.pick(count: number, last: number?, failed: { [number]: boolean }, roll: number): number?
	local choices: { number } = {}
	for i = 1, count do
		if not failed[i] and i ~= last then
			table.insert(choices, i)
		end
	end
	if #choices == 0 and last and last <= count and not failed[last] then
		-- (The only one left is the last one: play it again rather than nothing.)
		return last
	end
	if #choices == 0 then
		return nil
	end
	return choices[math.clamp(math.floor(roll * #choices) + 1, 1, #choices)]
end

--[[
	One frame: `dt` seconds passed with sky exposure `exposure`, at night or not (`night`, nil:
	not); `counts` gives the tracks of each list and `random` rolls in [0, 1). Returns the actions
	due (at most one of each kind).
]]
function MusicRules.step(
	state: State,
	settings: Settings,
	dt: number,
	exposure: number,
	counts: { [List]: number },
	random: () -> number,
	night: boolean?
): { Action }
	local actions: { Action } = {}
	-- Where the player is, once it has lasted.
	local said: Place? = MusicRules.placeOf(settings, exposure)
	if said and said ~= state.place then
		state.changing += dt
		if state.changing >= settings.SwitchSeconds then
			state.place = said
			state.changing = 0
			if state.playing and state.playing ~= said and not state.fading then
				state.fading = true
				table.insert(actions, { kind = "fade" })
			end
			state.wait = math.min(state.wait, random() * settings.SwitchDelay)
		end
	else
		state.changing = 0
	end

	if state.playing == nil then
		state.wait -= dt
		-- (Not while the exposure already says the other place: the track would be the wrong kind.)
		if state.wait <= 0 and not (said and said ~= state.place) then
			local place: Place = state.place
			local list: List = MusicRules.listOf(place, night == true, counts, state.failed)
			local track = MusicRules.pick(counts[list] or 0, state.last[list], state.failed[list], random())
			if track then
				state.playing = place
				state.list = list
				state.fading = false
				state.last[list] = track
				table.insert(actions, { kind = "play", place = place, list = list, track = track })
			else
				-- (Nothing of this kind to play: look again after a usual wait.)
				state.wait = settings.MinDelay
			end
		end
	end
	return actions
end

--[[
	The track playing stopped (`ending`, see the header; `track` is the one that failed, if any).
	The next waits: a usual MinDelay to MaxDelay after a finished track, at most SwitchDelay after
	one that faded out or failed (the place still wants music).
]]
function MusicRules.ended(state: State, settings: Settings, ending: Ending, random: () -> number, track: number?)
	local list: List? = state.list
	state.playing = nil
	state.list = nil
	state.fading = false
	if ending == "finished" then
		state.wait = settings.MinDelay + random() * (settings.MaxDelay - settings.MinDelay)
	else
		if ending == "failed" and list and track then
			local failed = state.failed[list :: List]
			failed[track] = true
		end
		state.wait = random() * settings.SwitchDelay
	end
end

return MusicRules
