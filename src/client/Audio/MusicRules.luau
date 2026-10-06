--!strict
--[[
	When background music plays, and which kind (pure; Audio/Music plays it). Minecraft's
	MusicManager, with the surface and caves as its "situations":

	  Place    where the player is: "cave" once the sky light reaching the camera
	           (Rendering/LightingController.skyExposure) has stayed below CaveExposure for
	           SwitchSeconds, "surface" again once it has stayed above SurfaceExposure as long (the
	           gap between the two keeps a cave mouth from flipping it). The game starts on the
	           surface unless the first exposure says otherwise.
	  Waits    nothing plays for `wait` seconds: FirstDelay after joining (Minecraft's 100 ticks),
	           then a random MinDelay to MaxDelay after each track ends (music.game's 12000 to
	           24000 ticks). Once it runs out a track of the place's kind starts.
	  Changes  when the place changes, a track of the other kind playing fades out (`"fade"`;
	           FadeSeconds, Audio/Music) and the wait becomes at most a random SwitchDelay, so a
	           track of the new kind follows (Minecraft's replaceCurrentMusic, which waits up to
	           half its MinDelay). So surface music never plays underground, nor cave music above
	           it. A track of the right kind keeps playing.
	  Tracks   picked at random, never the one that played last of that kind (when there is
	           another), and never one that failed to load (Audio/Music says which). None starts
	           while the exposure already says the other place (a change on its way).

	`step` is called every frame with the seconds passed and the exposure; it returns what to do:
	{ kind = "play", place = "surface" | "cave", track = index } or { kind = "fade" }. Audio/Music
	reports back: `started` once a track plays, `ended` when it stops (finished, faded out or
	failed to load).
]]

export type Place = "surface" | "cave"

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

export type Action = { kind: "play", place: Place, track: number } | { kind: "fade" }

-- How a track stopped: it played to its end, it faded out because the place changed, or it never
-- started (its file failed to load, or it was cancelled while loading).
export type Ending = "finished" | "faded" | "failed"

export type State = {
	place: Place,
	-- Seconds the exposure has said the other place, in a row.
	changing: number,
	-- Seconds until the next track may start (counts down while nothing plays).
	wait: number,
	-- The kind of the track playing or loading (nil: none), and whether it is fading out.
	playing: Place?,
	fading: boolean,
	-- The last track of each kind (no repeats) and the tracks that failed to load.
	last: { [Place]: number },
	failed: { [Place]: { [number]: boolean } },
}

local MusicRules = {}

function MusicRules.new(settings: Settings, place: Place?): State
	return {
		place = place or "surface" :: Place,
		changing = 0,
		wait = settings.FirstDelay,
		playing = nil,
		fading = false,
		last = {},
		failed = { surface = {}, cave = {} },
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
	One frame: `dt` seconds passed with sky exposure `exposure`; `counts` gives the tracks of each
	kind and `random` rolls in [0, 1). Returns the actions due (at most one of each kind).
]]
function MusicRules.step(
	state: State,
	settings: Settings,
	dt: number,
	exposure: number,
	counts: { [Place]: number },
	random: () -> number
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
			local track = MusicRules.pick(counts[place] or 0, state.last[place], state.failed[place], random())
			if track then
				state.playing = place
				state.fading = false
				state.last[place] = track
				table.insert(actions, { kind = "play", place = place, track = track })
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
	local place: Place? = state.playing
	state.playing = nil
	state.fading = false
	if ending == "finished" then
		state.wait = settings.MinDelay + random() * (settings.MaxDelay - settings.MinDelay)
	else
		if ending == "failed" and place and track then
			local failed = state.failed[place :: Place]
			failed[track] = true
		end
		state.wait = random() * settings.SwitchDelay
	end
end

return MusicRules
