--!strict
--[[
	The zombie apocalypse's survival rules on the server, pure (no Roblox APIs, so the tests run
	them); server Apocalypse/Survival plays them out.

	  Survivor  each character's record (Protocol Survivor; saved with the character,
	            Save/CharacterCodec): `alive` ticks since it last died (a tick while alive, in
	            every game mode and every world; the day counter shows it in survival and
	            adventure), `kills` (zombies it killed: Mobs/Mobs.died with it the killer and a
	            `zombie` kind) and `moons` (blood moons it survived: alive when one rose and when
	            it set, `moonTick`). All three start over when the character dies.
	  Moons     `moonTick` watches the blood moon (Shared/Apocalypse/BloodMoon) a tick at a time:
	            it notes the night a moon rose on while the character lived (seen going from not
	            up to up), and counts it once the moon has set that same night (`End` reached; a
	            `/time set` back to the day or to another day forgets it, one forward past `End`
	            counts as survived).
	  A tick    `tickLiving`, a living character's tick: a tick alive whatever the switches, and
	            the moon's watch only with Config.Apocalypse.Enabled (with it off there are no
	            blood moons to survive: the client draws none and the director sends none).
	  Bleeding  a wounding hit gives Bleeding for at least Config.Apocalypse.Bleeding.Ticks (or
	            what is left, if longer), one level up when already bleeding, at most
	            MaxAmplifier (`bleeding`).
	  Rising    an infected player's death raises a zombie (`rises`: Config.Apocalypse.Enabled,
	            Zombies.RiseOnDeath, and an infection), dressed in the civilian look whose shirt
	            is nearest the player's torso colour, in one of the skin tones by the player's
	            id (`riseVariant`, MobList.lookVariant).
	  Sprinting a sprinting player makes a Noise.Sprint noise every SPRINT_EVERY ticks: Tough As
	            Nails' sprint reports (Players/ToughAsNails.sprinting), or with Tough As Nails and
	            Minecraft's hunger off (no reports come then) the feet's horizontal speed over a second
	            (`measuredSprint`: above SPRINT_SPEED, below TELEPORT_SPEED, so a teleport is no
	            noise).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local BloodMoon = require(Shared.Apocalypse.BloodMoon)
local DayCycle = require(Shared.DayCycle)
local MobList = require(Shared.Entities.MobList)

export type Record = {
	alive: number,
	kills: number,
	moons: number,
	-- The day whose blood moon rose while this character lived (nil: none being watched), and
	-- whether a moon was up on its last tick (nil before its first).
	moonDay: number?,
	moonUp: boolean?,
}

-- What a save keeps of a record (and the infection's progress beside it).
export type Saved = { alive: number, kills: number, moons: number, infection: number }

-- What the rules read of Config.Apocalypse.Bleeding.
export type BleedingSettings = { Enabled: boolean?, Ticks: number, MaxAmplifier: number }

local SurvivalRules = {}

-- The Survivor message's limits (u32 alive ticks, u16 counts).
SurvivalRules.MAX_ALIVE = 4294967295
SurvivalRules.MAX_COUNT = 65535
-- A sprinting player's noise, every this many ticks.
SurvivalRules.SPRINT_EVERY = 20
-- Blocks a second (horizontal) that count as sprinting without Tough As Nails' reports: above a
-- walk (4.3) and below a sprint (5.6); and above which it was a teleport.
SurvivalRules.SPRINT_SPEED = 5
SurvivalRules.TELEPORT_SPEED = 12

function SurvivalRules.new(): Record
	return { alive = 0, kills = 0, moons = 0, moonDay = nil, moonUp = nil }
end

-- A record from what a save kept (numbers checked and clamped; nil: a fresh one).
function SurvivalRules.fromSaved(saved: Saved?): Record
	local record = SurvivalRules.new()
	if saved then
		local function whole(value: unknown, limit: number): number
			if type(value) ~= "number" or value ~= value then
				return 0
			end
			return math.clamp(math.floor(value), 0, limit)
		end
		record.alive = whole(saved.alive, SurvivalRules.MAX_ALIVE)
		record.kills = whole(saved.kills, SurvivalRules.MAX_COUNT)
		record.moons = whole(saved.moons, SurvivalRules.MAX_COUNT)
	end
	return record
end

-- One tick alive.
function SurvivalRules.tickAlive(record: Record)
	if record.alive < SurvivalRules.MAX_ALIVE then
		record.alive += 1
	end
end

-- A mob of `kind` (a MobList name) killed by this character: a zombie counts. Returns whether.
function SurvivalRules.killed(record: Record, kind: string): boolean
	local id = MobList.find(kind)
	if id == nil or not MobList.isZombie(id) then
		return false
	end
	if record.kills < SurvivalRules.MAX_COUNT then
		record.kills += 1
	end
	return true
end

--[[
	One tick of the blood moon's watch at day time `dayTime` with `s` (Config.Apocalypse
	.BloodMoon; see the header). Returns true on the tick a moon this character lived through
	from its rise has set.
]]
function SurvivalRules.moonTick(record: Record, dayTime: number, s: BloodMoon.Settings): boolean
	local up = BloodMoon.active(dayTime, s)
	local day = DayCycle.day(dayTime)
	local was = record.moonUp
	record.moonUp = up
	if up then
		if was == false then
			-- (Seen rising: the character lived at its Start.)
			record.moonDay = day
		elseif record.moonDay ~= nil and record.moonDay ~= day then
			record.moonDay = nil
		end
		return false
	end
	local watched = record.moonDay
	if watched == nil then
		return false
	end
	record.moonDay = nil
	if was and watched == day and DayCycle.timeInDay(dayTime) >= s.End then
		if record.moons < SurvivalRules.MAX_COUNT then
			record.moons += 1
		end
		return true
	end
	return false
end

--[[
	A living character's tick at day time `dayTime` (see the header), the apocalypse on or not, `s`
	Config.Apocalypse.BloodMoon. Returns true on the tick a blood moon counts as survived.
]]
function SurvivalRules.tickLiving(record: Record, dayTime: number, apocalypse: boolean, s: BloodMoon.Settings): boolean
	SurvivalRules.tickAlive(record)
	if not apocalypse then
		record.moonDay, record.moonUp = nil, nil
		return false
	end
	return SurvivalRules.moonTick(record, dayTime, s)
end

--[[
	A wounding hit on a player bleeding for `ticks` at `amplifier` (nil: not bleeding): the
	Bleeding to give (ticks, amplifier).
]]
function SurvivalRules.bleeding(ticks: number, amplifier: number?, s: BleedingSettings): (number, number)
	local level = if amplifier then math.min(s.MaxAmplifier, amplifier + 1) else 0
	return math.max(ticks, s.Ticks), math.max(0, level)
end

--[[
	Does a death with infection progress `p` raise a zombie, with the apocalypse `enabled`
	(Config.Apocalypse.Enabled) and `riseOnDeath` (Config.Apocalypse.Zombies.RiseOnDeath)?
]]
function SurvivalRules.rises(p: number, enabled: boolean, riseOnDeath: boolean): boolean
	return enabled and riseOnDeath and p > 0
end

--[[
	The variant of the zombie a player rises as: of `looks` (MobList's civilian looks), the one
	whose shirt is nearest `rgb` (the player's torso colour, 0..255; looks without a shirt are
	never picked), in skin tone `skin` (1 .. #MobList.SKIN_TONES, wrapped).
]]
function SurvivalRules.riseVariant(looks: { MobList.Look }, rgb: { number }, skin: number): number
	local best, bestDistance = 1, math.huge
	for i, look in looks do
		local shirt = look.shirt
		if shirt then
			local dr, dg, db = shirt[1] - rgb[1], shirt[2] - rgb[2], shirt[3] - rgb[3]
			local distance = dr * dr + dg * dg + db * db
			if distance < bestDistance then
				best, bestDistance = i, distance
			end
		end
	end
	local tones = #MobList.SKIN_TONES
	local tone = (math.floor(skin) - 1) % tones + 1
	return MobList.lookVariant(best, tone)
end

--[[
	Does moving (dx, dz) blocks in `seconds` count as sprinting, with no Tough As Nails report to
	go by (see the header)?
]]
function SurvivalRules.measuredSprint(dx: number, dz: number, seconds: number): boolean
	if not (seconds > 0) then
		return false
	end
	local speed = math.sqrt(dx * dx + dz * dz) / seconds
	return speed > SurvivalRules.SPRINT_SPEED and speed < SurvivalRules.TELEPORT_SPEED
end

return SurvivalRules
