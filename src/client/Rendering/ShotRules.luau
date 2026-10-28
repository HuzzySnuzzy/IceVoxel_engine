--!strict
--[[
	What a shot looks and sounds like on this client, in the manner of DayZ (pure: Rendering/
	ShotView draws what it says, Interaction/Firearms asks it for the player's own predicted shot,
	tests/spec/WeaponClient checks it).

	  Sound     at the shooter: its calibre's recorded shot where there is one (item.firearm.
	            <calibre>.fire: 9mm, 556, 308), else the gun's class shot (FirearmSpec `sound`:
	            item.firearm.<class>.fire, item.crossbow.fire); through a working suppressor its
	            calibre's item.firearm.<calibre>.suppressed, else item.firearm.suppressed; and
	            beyond Config.Weapons.FarSound blocks from the listener the low rolling
	            item.firearm.far instead (a suppressed shot that far is not heard: `fireSound`).
	            The empty click is item.firearm.dry, a jammed or Ruined gun's item.firearm.jam;
	            a pump or a bolt racks (item.firearm.chamber) `cycleDelay` after each shot (0.4 of
	            its shot time).
	  Flash     at the muzzle, none when suppressed (`flash`).
	  Tracer    from the muzzle to where each pellet's flight ended (Config.Weapons.Tracers), glowing
	            (Neon) unless the muzzle device says `glow` false (the suppressor: `glow`) or the
	            record says `plain` (a suppressed turret's shot: its device's glow is off).
	  Impact    where a pellet ended, by what it hit (Net/WeaponSync.Hit): a block or nothing in
	            reach of a block throws dust in the block's colour with entity.bullet.impact; a
	            mob or a player (body or head) dark red blood with entity.bullet.flesh; glass
	            nothing (the server's edit shatters it with its own sound); a flight that ended in
	            the air nothing (`impact`, `impactSound`).
	  Own shot  the shooter drew theirs at once (Interaction/Firearms: the sound, flash, a tracer to
	            the aim, the kick); the server's record of it (same shooter) only adds the
	            authoritative impacts, and its `refused` or `jammed` flag stops automatic fire
	            (`effects`' `stop`; a jam also clicks).
	  Turrets   a turret's shot (Shared/Turrets) is a record with shooter TURRET (0: no player) and
	            the turret's stand-in gun as its item, so it sounds as that gun's class (the SMG's
	            item.firearm.smg.fire, the rifle's, the sniper's heavy shot), suppressed or far as
	            any shot, flashes unless suppressed, draws its tracers from the turret's barrel
	            (Rendering/ShotView), plain when the record says so, and is never the player's own.
	  Looks     a held gun's look key (Shared/Weapons/WeaponState.lookKey, the player attribute
	            Types.HELD_LOOK_ATTRIBUTE: "mag,optic,muzzle,light,lit") read back into its parts
	            (`lookParts`).

	Distances are in blocks.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Handling = require(Shared.Weapons.Handling)
local Sounds = require(Shared.Sounds)
local WeaponSync = require(Shared.Net.WeaponSync)
local Weapons = require(Shared.Weapons)

export type Impact = "block" | "blood"

-- What to do for one shot (filled in place by `effects`: one table reused for every shot).
export type Effects = {
	-- The local player's own shot.
	own: boolean,
	-- A muzzle flash, tracers to the pellets' ends, the fire sound (nil: none).
	flash: boolean,
	tracer: boolean,
	glow: boolean,
	sound: string?,
	-- The pellets' impacts.
	impacts: boolean,
	-- (Own shots) automatic fire stops; the gun jammed after this shot.
	stop: boolean,
	jammed: boolean,
}

local ShotRules = {}

ShotRules.SUPPRESSED = "item.firearm.suppressed"
ShotRules.FAR = "item.firearm.far"

-- The calibres with recorded shots of their own (the Apocalypse pack's sounds:
-- item.firearm.<calibre>.fire and .suppressed, the fifth data sheet's), found once by name, so a
-- calibre without them does without: calibre -> { fire, suppressed } event names.
local CALIBRE_SHOTS: { [string]: { fire: string?, suppressed: string? } } = {}
for _, item in Weapons.FIREARMS do
	local calibre = (Weapons.firearm(item) :: Weapons.FirearmSpec).calibre
	if CALIBRE_SHOTS[calibre] == nil then
		local fire, suppressed = `item.firearm.{calibre}.fire`, `item.firearm.{calibre}.suppressed`
		CALIBRE_SHOTS[calibre] = {
			fire = if Sounds.find(fire) then fire else nil,
			suppressed = if Sounds.find(suppressed) then suppressed else nil,
		}
	end
end
ShotRules.DRY = "item.firearm.dry"
ShotRules.JAM = "item.firearm.jam"
ShotRules.CHAMBER = "item.firearm.chamber"
ShotRules.RELOAD = "item.firearm.reload"
ShotRules.LOAD_ROUND = "item.firearm.load_round"
ShotRules.IMPACT = "entity.bullet.impact"
ShotRules.FLESH = "entity.bullet.flesh"
-- A pump's or a bolt's rack comes this share of a shot's time after the shot.
ShotRules.CYCLE_SHARE = 0.4
-- The shooter of a turret's shot (Net/WeaponSync: no player's UserId).
ShotRules.TURRET = 0

local Hit = WeaponSync.Hit

function ShotRules.newEffects(): Effects
	return {
		own = false,
		flash = false,
		tracer = false,
		glow = true,
		sound = nil,
		impacts = false,
		stop = false,
		jammed = false,
	}
end

--[[
	The fire sound of gun `spec` (nil: an unknown item) heard `distance` blocks away (see the
	header); nil for none.
]]
function ShotRules.fireSound(spec: Weapons.FirearmSpec?, suppressed: boolean, distance: number): string?
	if spec == nil then
		return nil
	end
	if distance > Config.Weapons.FarSound then
		return if suppressed then nil else ShotRules.FAR
	end
	local own = CALIBRE_SHOTS[spec.calibre]
	if suppressed then
		return own and own.suppressed or ShotRules.SUPPRESSED
	end
	return own and own.fire or spec.sound
end

-- Is there a muzzle flash (none when suppressed)?
function ShotRules.flash(suppressed: boolean): boolean
	return not suppressed
end

-- Do the tracers glow: a muzzle device `muzzle` (item; nil: none) whose spec says `glow` false
-- takes the glow away while it still works (`fraction` of its durability left).
function ShotRules.glow(muzzle: number?, fraction: number?): boolean
	local device = Weapons.attachment(muzzle)
	if device == nil or not Handling.muzzleWorks(muzzle, fraction) then
		return true
	end
	return device.glow
end

-- What a pellet that hit `hit` (WeaponSync.Hit) leaves where it ended (nil: nothing).
function ShotRules.impact(hit: number): Impact?
	if hit == Hit.Block then
		return "block"
	elseif hit == Hit.Mob or hit == Hit.MobHead or hit == Hit.Player or hit == Hit.PlayerHead then
		return "blood"
	end
	return nil
end

-- The sound of a pellet that hit `hit` (nil: none).
function ShotRules.impactSound(hit: number): string?
	local kind = ShotRules.impact(hit)
	if kind == "block" then
		return ShotRules.IMPACT
	elseif kind == "blood" then
		return ShotRules.FLESH
	end
	return nil
end

-- Seconds after a shot of `spec` in fire mode `mode` (an index) its action racks (nil: it
-- doesn't: only pumps and bolts).
function ShotRules.cycleDelay(spec: Weapons.FirearmSpec, mode: number): number?
	if not spec.cycle then
		return nil
	end
	return ShotRules.CYCLE_SHARE * Handling.shotTicks(spec, mode) * Handling.TICK
end

-- Is `shot` a turret's (shooter TURRET)?
function ShotRules.isTurret(shot: WeaponSync.Shot): boolean
	return shot.shooter == ShotRules.TURRET
end

--[[
	Fills `out` with what to draw for `shot` (Net/WeaponSync.Shot) seen by the player whose
	UserId is `localUserId`, `distance` blocks from where it was fired, the shooter's tracers
	glowing or not (`glow`; never when the record is `plain`); returns `out`.
]]
function ShotRules.effects(
	shot: WeaponSync.Shot,
	localUserId: number,
	distance: number,
	glow: boolean,
	out: Effects
): Effects
	local own = shot.shooter == localUserId and not ShotRules.isTurret(shot)
	out.own = own
	out.jammed = shot.jammed
	out.stop = own and (shot.refused or shot.jammed)
	out.glow = glow and shot.plain ~= true
	if own or shot.refused then
		-- (Drawn already when fired; a refused shot has no pellets.)
		out.flash = false
		out.tracer = false
		out.sound = nil
		out.impacts = not shot.refused
		return out
	end
	out.flash = ShotRules.flash(shot.suppressed)
	out.tracer = Config.Weapons.Tracers == true
	out.sound = ShotRules.fireSound(Weapons.firearm(shot.item), shot.suppressed, distance)
	out.impacts = true
	return out
end

--[[
	A look key's parts (see the header): the magazine, optic, muzzle device and light items (0:
	none) and whether the light is on. Anything malformed reads as nothing mounted.
]]
function ShotRules.lookParts(key: string?): (number, number, number, number, boolean)
	if key == nil or key == "" then
		return 0, 0, 0, 0, false
	end
	local a, b, c, d, e = string.match(key, "^(%d+),(%d+),(%d+),(%d+),([01])$")
	if a == nil then
		return 0, 0, 0, 0, false
	end
	return tonumber(a) :: number, tonumber(b) :: number, tonumber(c) :: number, tonumber(d) :: number, e == "1"
end

return ShotRules
