--!strict
--[[
	What the day counter says and when the blood moon's notices come (pure: numbers in, text out,
	so the tests read every case). Ui/SurvivorHud draws it; Shared/Apocalypse/BloodMoon is the
	schedule both sides agree on from the day time alone, and Player/SurvivorState brings this
	character's record (Protocol Survivor).

	  The line   "Day N" (DayCycle.day + 1: the world's day) and, in survival and adventure,
	             " · Survived D days" (the character's alive ticks / 24000, whole days; "1 day").
	  Notice     a red word after it: "Blood Moon" while one is up (BloodMoon.active), "Blood Moon
	             tonight" on a blood moon's day until it rises (BloodMoon.daysUntil 0, up to its
	             Start: never after it set), "Blood Moon tomorrow" the day before (1). Every third
	             night has one, so no longer countdown.
	  Widths     `widths`: the line's width on one row (the notice after " · ") and wrapped (the
	             notice on a row of its own under the day's text), in the pixel font, WIDTH_STEP
	             steps so a changing digit doesn't move it every second. HudLayout puts it on one
	             row where that fits and wraps it where it doesn't (an iPad's or a 1024 x 768
	             window's corner at its Auto GUI scale: about 320 GUI pixels).
	  Toasts     `events(before, now)` from one frame's day time to the next: "tonight" at dawn of a
	             blood moon's day (the day changing to one), "rises" at its Start, "sets" at its End.
	             A step back in time or of more than MAX_STEP ticks (a `/time set`, a long hitch) is
	             no event, so moving the clock never fires a burst of them. A toast is as wide as
	             its text (`toastWidth`: Minecraft's 160 GUI pixels at least).
	  Survived   "You survived the Blood Moon" is the server's word: the clock's "sets" and a
	             Survivor message raising the moons survived (server Apocalypse/SurvivalRules: alive
	             from the moon's rise to its set) must come within CONFIRM_SECONDS of each other,
	             either first (`confirmSet`). A character that died under the moon (the server
	             starts its record over) hears nothing; a saved record coming back (moons raised
	             with no moon setting) neither.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local BloodMoon = require(Shared.Apocalypse.BloodMoon)
local DayCycle = require(Shared.DayCycle)

export type Event = "tonight" | "rises" | "sets"

-- The halves of a survived moon's toast (`confirmSet`): os.clock() of the clock's "sets" and of
-- the Survivor message that raised the moons survived (nil: not yet).
export type Pending = { sets: number?, raised: number? }

local SurvivorLine = {}

-- The notices' red ({200, 40, 40}).
SurvivorLine.NOTICE_COLOUR = table.freeze({ 200, 40, 40 })
-- Ticks one frame may move the clock and still be watched for events.
SurvivorLine.MAX_STEP = 600
-- The toasts' texts.
SurvivorLine.TOASTS = table.freeze({
	tonight = "A Blood Moon rises tonight",
	rises = "The Blood Moon rises",
	sets = "You survived the Blood Moon",
} :: { [string]: string })
-- Between the line's text and its notice on one row.
SurvivorLine.GAP = " · "
-- GUI pixels the line's width moves in.
SurvivorLine.WIDTH_STEP = 8
-- Minecraft's toast (GUI pixels), and the room kept each side of its text.
SurvivorLine.TOAST_WIDTH = 160
SurvivorLine.TOAST_PADDING = 8
-- Seconds the two halves of a survived moon's toast may come apart.
SurvivorLine.CONFIRM_SECONDS = 10

--[[
	The day line at `dayTime` for a character alive `alive` ticks (nil: not known yet), whose
	survival days show when `survivalLike`: the line's text, and the notice after it (nil: none).
]]
function SurvivorLine.text(
	dayTime: number,
	alive: number?,
	survivalLike: boolean,
	s: BloodMoon.Settings
): (string, string?)
	local text = `Day {DayCycle.day(dayTime) + 1}`
	if survivalLike and alive then
		local days = math.floor(math.max(alive, 0) / DayCycle.TICKS_PER_DAY)
		text ..= ` · Survived {days} {if days == 1 then "day" else "days"}`
	end
	local notice: string? = nil
	if BloodMoon.active(dayTime, s) then
		notice = "Blood Moon"
	else
		local days = BloodMoon.daysUntil(dayTime, s)
		if days == 0 and DayCycle.timeInDay(dayTime) <= s.Start then
			notice = "Blood Moon tonight"
		elseif days == 1 then
			notice = "Blood Moon tomorrow"
		end
	end
	return text, notice
end

-- `w` GUI pixels of text (with the shadow's pixel) rounded up to WIDTH_STEP.
local function stepped(w: number): number
	local step = SurvivorLine.WIDTH_STEP
	return math.ceil((w + 1) / step) * step
end

--[[
	The day line's widths (GUI pixels) for `main` and its `notice`, `measure` giving a text's width
	in the pixel font (Ui/Style.textWidth): on one row, and wrapped with the notice on a second row
	(nil without a notice: one row is all it has).
]]
function SurvivorLine.widths(main: string, notice: string?, measure: (text: string) -> number): (number, number?)
	local mainWidth = measure(main)
	if notice == nil then
		return stepped(mainWidth), nil
	end
	return stepped(mainWidth + measure(SurvivorLine.GAP .. notice)), stepped(math.max(mainWidth, measure(notice)))
end

-- The notice toast's width (GUI pixels) for a text `textWidth` wide (see the header).
function SurvivorLine.toastWidth(textWidth: number): number
	return math.max(SurvivorLine.TOAST_WIDTH, stepped(textWidth + 2 * SurvivorLine.TOAST_PADDING))
end

-- The toasts due between day times `before` (nil: the first frame) and `now` (see the header).
function SurvivorLine.events(before: number?, now: number, s: BloodMoon.Settings): { Event }
	local events: { Event } = {}
	if before == nil or now < before or now - before > SurvivorLine.MAX_STEP then
		return events
	end
	local day = DayCycle.day(now)
	if day ~= DayCycle.day(before) and BloodMoon.isBloodDay(day, s) then
		table.insert(events, "tonight")
	end
	local was, up = BloodMoon.active(before, s), BloodMoon.active(now, s)
	if up and not was then
		table.insert(events, "rises")
	elseif was and not up and DayCycle.day(before) == day and DayCycle.timeInDay(now) >= s.End then
		table.insert(events, "sets")
	end
	return events
end

--[[
	Notes one half of a survived moon's toast at `now` (os.clock() seconds): "sets" (the clock
	passed a blood moon's End) or "raised" (a Survivor message raised the moons survived). True
	when the other half came within CONFIRM_SECONDS: the toast is due, and both are forgotten.
]]
function SurvivorLine.confirmSet(pending: Pending, half: "sets" | "raised", now: number): boolean
	local other = if half == "sets" then pending.raised else pending.sets
	if other ~= nil and math.abs(now - other) <= SurvivorLine.CONFIRM_SECONDS then
		pending.sets, pending.raised = nil, nil
		return true
	end
	if half == "sets" then
		pending.sets = now
	else
		pending.raised = now
	end
	return false
end

return SurvivorLine
