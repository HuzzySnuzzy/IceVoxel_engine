--!strict
--[[
	The zombie apocalypse's infection on the server: each player's progress (the rules are
	Shared/Apocalypse/Infection, pure and tested; this plays them out). Apocalypse/Survival drives
	it: the bites it rolls from Mobs/Mobs.playerHit, a tick for every living player, and deaths.

	  Effect     Shared/Effects' Infection is an external effect (Players/Effects `addExternal`):
	             its ticks are the countdown to death (Infection.ticksLeft), its amplifier the
	             stage less one ("Infection III"), paused while the player's game mode can't be
	             hurt (creative and spectator neither catch it nor get worse). /effect give
	             starts one (or takes one that many ticks on), /effect clear cures it.
	  Ticks      `tick`, 20 a second for a living player (Survival's loop): the progress grows; the
	             stage's symptoms are given (Players/Effects: Weakness, Slowness, stage III's
	             Nausea spells); stage II on drains Tough As Nails' thirst; stage IV's half heart
	             is magic damage that never kills (Players/Characters.magicHurt(player, 1, false):
	             Resistance applies, armour doesn't), and the tick past the end kills
	             (magicHurt(player, math.huge, true); a player whom even that can't hurt, under
	             Resistance V, stays at the end and is tried again every tick).
	  Healing    from stage III no natural health comes back (Infection.blocksRegeneration):
	             Players/ToughAsNails' regeneration block (`setRegenBlock`) stops thirst's
	             regeneration and pauses the Roblox Health script in its own tick; with Tough As
	             Nails off (no tick runs there) this asks it every tick to pause the script itself
	             (ToughAsNails.pauseRegeneration: it does nothing while that tick runs, nothing
	             twice, and finds a new character's script, Roblox adding it after the body).
	  Cures      `cure` (Antibiotics through Players/Effects.remove, Players/Eating; /effect
	             clear): healthy at once, the symptoms it gave taken off (an effect with no more
	             time left than a symptom's: a longer one came from elsewhere and stays).
	             Antibiotics' Weakness after a late cure is theirs (Items/Foods `aftermath`).
	             `setBack` (the Herbal Poultice): back a stage, never a cure.
	  Death      `died` clears it and says whether the player was infected (Survival raises the
	             zombie) and whether the infection itself killed them.
	  Saved      the progress is the character's (Save/CharacterCodec; Save/PlayerCodec with
	             Config.Characters off), through Survival's export and restore.
	With Infection.Enabled false, or Config.Apocalypse.Enabled false (the rules then get a copy of
	Config.Apocalypse.Infection with Enabled false), no bite infects and a saved infection is
	dormant (Shared/Apocalypse/Infection.dormant: kept, but nothing shows, grows, hurts or holds
	regeneration back, and a death with it raises no zombie).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Effects = require(Shared.Effects)
local GameMode = require(Shared.GameMode)
local Rules = require(Shared.Apocalypse.Infection)
local SharedToughAsNails = require(Shared.ToughAsNails)
local Thirst = require(Shared.ToughAsNails.Thirst)

local Characters = require(script.Parent.Parent.Players.Characters)
local EffectsServer = require(script.Parent.Parent.Players.Effects)
local ToughAsNails = require(script.Parent.Parent.Players.ToughAsNails)

local Infection = {}

local progress: { [Player]: number } = {}
-- The tick of each player's last infection roll.
local lastRoll: { [Player]: number } = {}
-- Players the infection is killing this tick (the death notice).
local succumbing: { [Player]: boolean } = {}
local step = Rules.newStep()
local started = false

-- Config.Apocalypse.Infection with Enabled false (the apocalypse off: see the header).
local OFF: Rules.Settings = table.clone(Config.Apocalypse.Infection)
OFF.Enabled = false
table.freeze(OFF)

local function settings(): Rules.Settings
	return if Config.Apocalypse.Enabled then Config.Apocalypse.Infection else OFF
end

-- Do bites infect at all?
local function enabled(): boolean
	return not Rules.dormant(settings())
end

local function held(player: Player): boolean
	return not Rules.affects(GameMode.of(player))
end

-- Takes the symptoms of an infection at `p` off (see the header).
local function clearSymptoms(player: Player, p: number)
	local s = settings()
	local longest: { [string]: number } = {}
	for stage = 1, Rules.stage(p, s) do
		for _, symptom in Rules.symptoms(stage) do
			longest[symptom.name] = Rules.SYMPTOM_TICKS
		end
	end
	if Rules.stage(p, s) >= 3 then
		longest.Nausea = Rules.NAUSEA_TICKS
	end
	for name, ticks in longest do
		local left = EffectsServer.ticks(player, name)
		if left > 0 and left <= ticks then
			EffectsServer.remove(player, name)
		end
	end
end

--[[ API ]]

-- `player`'s infection progress (0: healthy; Shared/Apocalypse/Infection's p).
function Infection.progress(player: Player): number
	return progress[player] or 0
end

-- `player`'s infection stage (0: healthy, or dormant: see the header).
function Infection.stage(player: Player): number
	local s = settings()
	return if Rules.dormant(s) then 0 else Rules.stage(Infection.progress(player), s)
end

--[[
	A landed bite on `player` by a kind with `infect`, the player wearing `armorPoints`, at tick
	`now` (Survival's count): rolled with `random` (0..1) at most every RollInterval ticks.
	Returns whether it infected (or took the infection on).
]]
function Infection.bite(player: Player, infect: number, armorPoints: number, now: number, random: () -> number): boolean
	if not enabled() then
		return false
	end
	local p = Infection.progress(player)
	local nextP, rolled =
		Rules.rollBite(p, lastRoll[player], now, GameMode.of(player), infect, armorPoints, random, settings())
	if rolled then
		lastRoll[player] = rolled
	end
	if nextP == p then
		return false
	end
	progress[player] = nextP
	return true
end

-- Cures `player` (see the header). Returns whether they were infected.
function Infection.cure(player: Player): boolean
	local p = Infection.progress(player)
	if p <= 0 then
		return false
	end
	progress[player] = nil
	clearSymptoms(player, p)
	return true
end

-- Takes `player`'s infection back a stage (the Herbal Poultice). Returns whether they had one.
function Infection.setBack(player: Player): boolean
	local p = Infection.progress(player)
	if p <= 0 then
		return false
	end
	progress[player] = Rules.setBack(p, settings())
	return true
end

--[[
	One tick of `player` (living, in game `mode`; Survival's loop): see the header.
]]
function Infection.tick(player: Player, mode: string)
	local s = settings()
	local p = Infection.progress(player)
	local invulnerable = not Rules.affects(mode)
	-- (The regeneration pause where Tough As Nails' own tick doesn't run: every tick, so a new
	-- character's Health script is found too.)
	ToughAsNails.pauseRegeneration(player, not invulnerable and Rules.blocksRegeneration(p, s))
	if p <= 0 or invulnerable or Rules.dormant(s) then
		return
	end
	local nextP = Rules.tick(p, s, step)
	if step.dies then
		succumbing[player] = true
		Characters.magicHurt(player, math.huge, true)
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			-- (Nothing could hurt them: tried again next tick.)
			succumbing[player] = nil
			progress[player] = Rules.lethal(s)
		end
		return
	end
	progress[player] = nextP
	if step.refresh then
		for _, symptom in Rules.symptoms(step.stage) do
			EffectsServer.give(player, symptom.name, Rules.SYMPTOM_TICKS, symptom.amplifier)
		end
	end
	if step.nausea then
		EffectsServer.give(player, "Nausea", Rules.NAUSEA_TICKS, 0)
	end
	if step.hurt then
		Characters.magicHurt(player, 1, false)
	end
	if Rules.drainsThirst(nextP, s) and SharedToughAsNails.thirstOn() and SharedToughAsNails.affects(mode) then
		local thirst = ToughAsNails.state(player)
		if thirst then
			Thirst.addExhaustion(thirst, Rules.THIRST_EXHAUSTION)
		end
	end
end

--[[
	`player` died: their infection is cleared. Returns its progress then (0: they weren't
	infected, or it was dormant) and whether the infection itself killed them.
]]
function Infection.died(player: Player): (number, boolean)
	local p = if Rules.dormant(settings()) then 0 else Infection.progress(player)
	local succumbed = succumbing[player] == true
	progress[player] = nil
	succumbing[player] = nil
	return p, succumbed
end

-- `player`'s progress as a save keeps it.
function Infection.export(player: Player): number
	return Infection.progress(player)
end

-- A saved player's progress (0: healthy), checked against the rules' range (kept while dormant).
function Infection.restore(player: Player, p: number)
	local saved = Rules.fromSaved(p, settings())
	if saved > 0 then
		progress[player] = saved
	else
		progress[player] = nil
	end
end

--[[
	Registers the Infection effect's owner and the regeneration block (Players/Effects and
	Players/ToughAsNails must be loaded; nothing ticks here: Survival's loop calls `tick`).
]]
function Infection.start()
	assert(not started, "Infection.start was already called")
	started = true
	local s = settings()
	EffectsServer.addExternal(Effects.id.Infection, {
		get = function(player: Player): number?
			return Rules.ticksLeft(Infection.progress(player), s)
		end,
		paused = held,
		give = function(player: Player, ticks: number)
			if not enabled() then
				return
			end
			local p = Infection.progress(player)
			-- (/effect give starts one, or takes one `ticks` on.)
			progress[player] = if p <= 0 then 1 else math.min(Rules.lethal(s), p + math.max(0, math.floor(ticks)))
		end,
		clear = function(player: Player)
			Infection.cure(player)
		end,
		amplifier = function(player: Player): number
			return Rules.amplifier(Infection.progress(player), s)
		end,
	})
	ToughAsNails.setRegenBlock(function(player: Player): boolean
		return not held(player) and Rules.blocksRegeneration(Infection.progress(player), s)
	end)
	Players.PlayerRemoving:Connect(function(player)
		-- (After every other PlayerRemoving handler: the saves made as a player leaves read the
		-- progress, through Survival.export.)
		task.defer(function()
			progress[player] = nil
			lastRoll[player] = nil
			succumbing[player] = nil
		end)
	end)
end

return Infection
