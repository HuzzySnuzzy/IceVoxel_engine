--!strict
--[[
	Tough As Nails on the server: every player's thirst and body temperature (the rules are
	Shared/ToughAsNails, pure and tested; this plays them out), and beside them Minecraft's hunger
	(Shared/Hunger: the food bar thirst was modelled on). Config.ToughAsNails turns thirst and
	temperature on and off, Config.Hunger the food bar; with all three off nothing here ticks, but
	drinking still listens: potions are drunk whatever TAN does, and bottles fill at water for
	brewing them.

	  Ticks      20 a second (catching up a few per frame), for every living player:
	               * a hurt that landed since the last tick (health went down, not by this
	                 module) costs Thirst.EXHAUSTION.hurt, and as much of the food bar's
	                 (Hunger.EXHAUSTION.hurt);
	               * water touching the standing box (Players/Burning.touching) makes them wet, and
	                 so does rain at their feet or the top of the box, looked at once a second
	                 (World/WeatherServer.rainingAt: Minecraft's isInRain, TAN's wetness);
	               * once a second (players spread over the second) the surroundings
	                 (Players/Climate, with the armor's insulation: Climate.insulation) set the
	                 temperature's target, with the player's effects and Climate Clemency
	                 (Temperature.target(env, state));
	               * Temperature.tick (the countdowns, the drift, hypothermia, hyperthermia; with
	                 temperature off only its countdowns, Temperature.tickEffects, for the
	                 clemency's sake), then Thirst.tick (with the HOT zone's sweating:
	                 Config.ToughAsNails.HotExhaustion; at half the drain under the clemency;
	                 no regeneration while fully frozen or overheated; none of its own at all with
	                 hunger on), then Hunger.tick (with Minecraft's Hunger effect's exhaustion,
	                 Hunger.effectExhaustion of the player's effects: Players/Effects; the
	                 regeneration held as thirst's is, and wanting thirst 18 or more while
	                 Config.ToughAsNails.ThirstRegeneration has thirst rule it; Climate Clemency
	                 leaves the food bar alone, as TAN's does) and
	                 what they cost or give back: Humanoid:TakeDamage (half hearts scaled to
	                 MaxHealth, as Players/Characters does; it respects the ForceField of creative
	                 players, who are spared anyway) and regeneration;
	               * the player's Survival message when what it says changed, at most every
	                 SEND_TICKS ticks (and at once for a new character).
	  Health     with hunger on, health comes back only by hunger's natural regeneration
	             (Config.Hunger.NaturalRegeneration; none at all without it, as Minecraft's
	             naturalRegeneration rule), and with thirst on and Config.ToughAsNails
	             .ThirstRegeneration only while thirst is 18 or more too; with hunger off, thirst
	             on and ThirstRegeneration, by thirst's rule (Thirst.tick's own). Either way the
	             character's Roblox "Health" script (its regeneration) is removed as it appears.
	             Otherwise that script stays, but is disabled while the
	             body is fully frozen or overheated, as thirst's and hunger's regeneration wait
	             then (Temperature.stopsRegeneration: its half heart every 5 s would undo the
	             extremes' hurts), and while the regeneration block says so (`setRegenBlock`:
	             the zombie apocalypse's infection from stage III, server Apocalypse/Infection),
	             which stops thirst's and hunger's regeneration too: one rule for every kind.
	             With thirst, temperature and hunger off no tick runs here, so the infection
	             pauses the script itself (`pauseRegeneration`).
	  Clemency   TAN's Climate Clemency: a player's first character since joining gets
	             Config.ToughAsNails.ClemencyTicks of it (5 minutes), every later one (a respawn)
	             RespawnClemencyTicks (a minute); a player returning to a saved world keeps what
	             was left of theirs (Saved, below).
	  Death      a new character starts over (full thirst, neutral, dry, and a full food bar: 20
	             food, 5 saturation), as TAN resets on respawn and Minecraft's respawned player
	             gets a new FoodData.
	  Saved      a saved world keeps each player's thirst, temperature and hunger (`export`), and
	             gives them back to a returning player's next character, or the one standing
	             (`restore`, World/WorldSave; with characters Players/CharacterStore), as TAN and
	             Minecraft keep them in the player's data.
	  Exertion   the client's movement reports (Protocol Exertion, ToughAsNails/Exertion), bounded
	             by the time since the last one, cost exhaustion, thirst's and the same of the
	             food bar's; their sprint flag counts as sprinting for SPRINT_HOLD seconds
	             (`sprinting`: the zombie apocalypse's sprint noise, server Apocalypse/Survival,
	             and the temperature's), unless the food bar is too low to sprint (hunger on,
	             Hunger.canSprint: 6 or less, not for creative and spectator players), which the
	             client's movement already keeps from sprinting. Breaking a block costs
	             Thirst.EXHAUSTION.mine and Hunger.EXHAUSTION.mine (ServerNet's `broke` rule,
	             `blockBroken`); an attack that lands on a mob Hunger.EXHAUSTION.attack, the food
	             bar's only (server Mobs/Mobs, `attacked`).
	  Drinking   Protocol Drink (Shared/ToughAsNails/Drinks): a living player who is not a
	             spectator, the item really in their hand.
	               start / finish  a bottle or canteen held from `start` to `finish` for at
	                               least Drinks.USE_TICKS - FINISH_LEEWAY ticks, the same item in
	                               the same slot (the player's use meanwhile, for every client
	                               to hear: Players/UseState, Types.USE_DRINK, the drinking
	                               loop; it ends with the drink, however it ends), while they
	                               may drink it (Drinks.drinkable:
	                               thirsty with thirst on, Thirst.canDrink; a tea whenever
	                               temperature is on): drunk (its water only with thirst on),
	                               the Thirst effect rolled, Internal Warmth or Chill given (a
	                               drink's `warmth` / `chill`), a potion's status effects given
	                               (Players/Effects.giveAll), a mana potion's mana and Mana
	                               Sickness (Players/Mana.potion), the bottle or sip used up
	                               (Drinks.afterDrinking); everyone else hears the last gulp
	                               (entity.generic.drink: the drinker's client plays its own);
	               hand            an empty hand at a water source within reach
	                               (Config.Interaction.Reach + 2 blocks, as ItemUse), at most
	                               every Drinks.HAND_INTERVAL ticks: a sip (with
	                               Config.ToughAsNails.HandDrinking);
	               fill            a Glass Bottle or canteen at a water source within reach:
	                               filled (Drinks.fill), item.bottle.fill for everyone near.
	             Sounds a player's requests cause use their budget (Audio/Sounds.allow).
	  Perks      Progression's (`setPerks`): thirst drains slower (Thirst.tick's `rate`), and steps
	             of insulation are added to the armor's.
	  Heat       lit furnaces (a furnace container burning: litTime > 0) and working Heat and
	             Combustion Generators (their machine's active flag) are heat sources
	             (Climate.addHeatSource), besides Config.ToughAsNails.HeatingBlocks; so are the
	             seasons' Wood Stove and Oil Heater (radiant) and Electric Heater (within
	             Config.Seasons.Heat.SpaceHeaterRadius) while they deliver heat (their `heat`
	             field), and the Air Conditioner and Electric Fan (within FanRadius) cold sources
	             while they cool. Rooms (server Seasons/RoomWorld) take the same machines' heat
	             through Climate.addRoomSource: a lit Furnace, a working generator, the heaters,
	             coolers and stoves' `heat`; those are registered at the start whatever thirst
	             and temperature say (rooms run with both off).
	  Seasons    while the calendar is on (Shared/Seasons: Calendar's state enabled), each
	             player's sample takes the season's climate (SeasonClimate.sample for the column's
	             biome class: shift and night drop), the room at their feet (Seasons/RoomWorld
	             .sample) and snow falling on them (World/WeatherServer.snowingAt) into the
	             environment (Players/Climate); a freeze immune piece no longer stops hypothermia
	             (Temperature.freezeImmune, Config.ToughAsNails.LeatherFreezeImmunity), the COLD
	             zone and below cost food (Temperature.coldExhaustion, next to the HOT zone's
	             sweating), and the Survival message carries the room's air and the outside value
	             (the thermometer's "Room +1 · Out -9"). With the calendar off none of it: as
	             before.
	  Eating     server Players/Eating asks for the food bar (`hunger`) and fills it (Hunger.eat).
	  Effects    TAN's Thirst, Internal Warmth, Internal Chill and Climate Clemency are status
	             effects in TAN 1.20, so they are listed with the others (Players/Effects
	             `addExternal`: read from the states here every tick, Thirst with thirst on, the
	             warmth and chill with temperature on; /effect gives them by the states' own
	             rules, a longer one staying, and clears them).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local SharedEffects = require(Shared.Effects)
local Fluids = require(Shared.Fluids)
local GameMode = require(Shared.GameMode)
local Hunger = require(Shared.Hunger)
local Protocol = require(Shared.Net.Protocol)
local PlayerPhysics = require(Shared.Movement.PlayerPhysics)
local SharedMachines = require(Shared.Machines)
local ToughAsNails = require(Shared.ToughAsNails)
local SeasonClimate = require(Shared.Seasons.SeasonClimate)

local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local WorldServer = require(script.Parent.Parent.World.WorldServer)
local TimeOfDay = require(script.Parent.Parent.World.TimeOfDay)
local WeatherServer = require(script.Parent.Parent.World.WeatherServer)
local Sounds = require(script.Parent.Parent.Audio.Sounds)
local SkyCheck = require(script.Parent.Parent.Machines.SkyCheck)
local MachineWorld = require(script.Parent.Parent.Machines.MachineWorld)
local Machines = require(script.Parent.Parent.Machines.Machines)
local RoomWorld = require(script.Parent.Parent.Seasons.RoomWorld)
local Burning = require(script.Parent.Burning)
local Characters = require(script.Parent.Characters)
local EffectsServer = require(script.Parent.Effects)
local Climate = require(script.Parent.Climate)
local Containers = require(script.Parent.Containers)
local Inventories = require(script.Parent.Inventories)
local ManaServer = require(script.Parent.Mana)
local PlayerPositions = require(script.Parent.PlayerPositions)
local UseState = require(script.Parent.UseState)
local Types = require(Shared.Inventory.Types)

local Thirst = require(Shared.ToughAsNails.Thirst)
local Temperature = require(Shared.ToughAsNails.Temperature)
local Drinks = require(Shared.ToughAsNails.Drinks)
local Exertion = require(Shared.ToughAsNails.Exertion)

-- Minecraft players have 20 health points (half hearts).
local HEALTH = 20
local TICK = 1 / 20
local MAX_TICKS_PER_FRAME = 4
-- Ticks between two Survival messages to one player.
local SEND_TICKS = 4
-- Seconds a report's sprint flag counts.
local SPRINT_HOLD = 2
-- Ticks a drink may finish early (the client's clock and the network's jitter).
local FINISH_LEEWAY = 4
-- Exertion reports a player may send per second.
local REPORTS_PER_SECOND = 4
-- The body water is looked for in: the standing box (the server can't tell the pose).
local BODY = PlayerPhysics.dimensions("standing")
local DRINK = "entity.generic.drink"
local FILL = "item.bottle.fill"

type Record = {
	thirst: Thirst.State,
	temperature: Temperature.State,
	hunger: Hunger.State,
	-- os.clock() until which the player counts as sprinting.
	sprintingUntil: number,
	-- The last Exertion report (os.clock()) and how many came this second.
	lastReport: number,
	reports: number,
	reportSecond: number,
	-- A drink being held: since when (os.clock()), the hotbar slot and the item.
	drinking: { started: number, slot: number, item: number }?,
	lastHand: number,
	-- Health (half hearts) after the last tick, to spot hurts.
	health: number?,
	-- The last Survival payload sent and the ticks until another may go.
	sent: string?,
	wait: number,
	-- The character's Roblox Health script while this module keeps it disabled (the extremes).
	paused: BaseScript?,
	-- Seasons: the room's air at the last sample (nil: none), the outside value there
	-- (Temperature.outside), and the season's sample (reused).
	room: number?,
	outside: number,
	season: SeasonClimate.Sample?,
}

local ToughAsNailsServer = {}

--[[
	Progression's perks for a player (server Players/Progression; set by the server script): how
	fast their thirst drains (Hardy: 0.9) and the steps of warmth and of cooling they add to their
	armor's (Insulation: 1). nil: none.
]]
export type Perks = {
	thirstRate: (player: Player) -> number,
	insulation: (player: Player) -> number,
}
local perks: Perks? = nil
-- Says whether a player's natural regeneration is held (see the header: `setRegenBlock`).
local regenBlock: ((player: Player) -> boolean)? = nil

local records: { [Player]: Record } = {}
-- Players whose first character since joining has come (their next ones are respawns).
local joined: { [Player]: true } = {}
local started = false
local random = Random.new()

-- A new character's record, with `clemency` ticks of Climate Clemency.
local function newRecord(clemency: number): Record
	return {
		thirst = Thirst.new(),
		temperature = Temperature.new(clemency),
		hunger = Hunger.new(),
		sprintingUntil = 0,
		lastReport = os.clock(),
		reports = 0,
		reportSecond = 0,
		drinking = nil,
		lastHand = -math.huge,
		health = nil,
		sent = nil,
		wait = 0,
		paused = nil,
		room = nil,
		outside = 0,
		season = nil,
	}
end

-- Is thirst / temperature on?
local function thirstOn(): boolean
	return ToughAsNails.thirstOn()
end
local function temperatureOn(): boolean
	return ToughAsNails.temperatureOn()
end
-- Is Minecraft's hunger on (Config.Hunger)?
local function hungerOn(): boolean
	return Hunger.on()
end

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		return humanoid
	end
	return nil
end

-- Is block (x, y, z) within the player's reach (as ItemUse checks: Players/PlayerPositions)?
local function inReach(player: Player, x: number, y: number, z: number): boolean
	return PlayerPositions.inReach(player, x, y, z)
end

-- May the player drink `item` now (Drinks.drinkable: thirsty with thirst on, or a tea with
-- temperature on)?
local function mayDrink(record: Record, item: number?, mode: string): boolean
	return Drinks.drinkable(Drinks.of(item), Thirst.canDrink(record.thirst, mode), thirstOn(), temperatureOn())
end

-- The selected hotbar slot (nil without an inventory).
local function selectedSlot(player: Player): number?
	local window = Inventories.get(player)
	return if window then window.inventory.selected else nil
end

-- The player's Survival message as of now.
local function status(record: Record): Protocol.SurvivalStatus
	local thirst, temperature, hunger = record.thirst, record.temperature, record.hunger
	return {
		thirstOn = thirstOn(),
		temperatureOn = temperatureOn(),
		hungerOn = hungerOn(),
		wet = Temperature.isWet(temperature),
		warmth = temperature.warmth > 0,
		chill = temperature.chill > 0,
		thirst = thirst.thirst,
		hydration = thirst.hydration,
		exhaustion = thirst.exhaustion,
		temperature = temperature.value,
		target = temperature.target,
		frozen = temperature.frozen,
		heat = temperature.heat,
		effect = thirst.effect,
		-- (Whole seconds, so it changes the message once a second.)
		clemency = math.ceil(temperature.clemency / 20),
		food = hunger.food,
		saturation = hunger.saturation,
		foodExhaustion = hunger.exhaustion,
		room = record.room,
		outside = record.outside,
	}
end

local function send(net: ServerNet.ServerNet, player: Player, record: Record)
	if record.wait > 0 then
		record.wait -= 1
	end
	local payload = Protocol.encodeSurvival(status(record))
	local text = buffer.tostring(payload)
	if text ~= record.sent and record.wait <= 0 then
		record.sent = text
		record.wait = SEND_TICKS
		net.send(player, Protocol.ServerMessage.Survival, payload)
	end
end

-- Removes the character's Roblox regeneration (its "Health" script), now and when it appears.
local function stopRobloxRegeneration(character: Model)
	local function check(child: Instance)
		if child.Name == "Health" and child:IsA("BaseScript") then
			child:Destroy()
		end
	end
	for _, child in character:GetChildren() do
		check(child)
	end
	character.ChildAdded:Connect(check)
end

-- Pauses the character's Roblox regeneration (its "Health" script, where it is kept and
-- running) while `paused`, and lets the script it paused run again after (see the header).
local function pauseRobloxRegeneration(record: Record, character: Model, paused: boolean)
	local held = record.paused
	if paused and held == nil then
		local health = character:FindFirstChild("Health")
		if health and health:IsA("BaseScript") and health.Enabled then
			health.Enabled = false
			record.paused = health
		end
	elseif not paused and held then
		held.Enabled = true
		record.paused = nil
	end
end

--[[ Ticking ]]

-- The world's seed (heat waves), set by `start`.
local worldSeed = 0

-- One tick of one player (see the header). `sample`: look at the surroundings this tick.
local function tickPlayer(net: ServerNet.ServerNet, view: Climate.View, player: Player, record: Record, sample: boolean)
	local character = player.Character
	local humanoid = humanoidOf(player)
	local fx, fy, fz = PlayerPositions.feet(player)
	if
		character == nil
		or humanoid == nil
		or fx == nil
		or not (math.abs(fx) <= Protocol.MAX_COORDINATE)
		or not (math.abs(fy) <= Protocol.MAX_COORDINATE)
		or not (math.abs(fz) <= Protocol.MAX_COORDINATE)
	then
		return
	end
	local mode = GameMode.of(player)
	local maxHealth = humanoid.MaxHealth
	if maxHealth <= 0 then
		return
	end
	local health = humanoid.Health / maxHealth * HEALTH
	local thirst, temperature, hunger = record.thirst, record.temperature, record.hunger
	if record.health and health < record.health - 1e-3 and ToughAsNails.affects(mode) then
		if thirstOn() then
			Thirst.addExhaustion(thirst, Thirst.EXHAUSTION.hurt)
		end
		if hungerOn() then
			Hunger.addExhaustion(hunger, Hunger.EXHAUSTION.hurt)
		end
	end

	local damage, heal = 0, 0
	-- (The seasons count while the calendar is on: see the header.)
	local seasons = SeasonClimate.active()
	if temperatureOn() then
		local touching = Burning.touchingAt(view.getBlock, fx, fy, fz, BODY.width, BODY.height)
		if Burning.has(touching, Fluids.WATER) then
			Temperature.soak(temperature)
		elseif
			sample and (WeatherServer.rainingAt(fx, fy, fz) or WeatherServer.rainingAt(fx, fy + BODY.height, fz))
		then
			-- (Rain at the feet or the top of the box: Minecraft's isInRain. Once a second keeps
			-- the wet countdown topped up.)
			Temperature.soak(temperature)
		end
		local window = Inventories.get(player)
		local warmth, cooling, freezeImmune = 0, 0, false
		if window then
			warmth, cooling, freezeImmune = Climate.insulation(window.inventory.armor)
		end
		if perks then
			local steps = perks.insulation(player)
			warmth += steps
			cooling += steps
		end
		if sample then
			local dayTime = TimeOfDay.get()
			local season: SeasonClimate.Sample? = nil
			if seasons then
				local _, biome = view.column(math.floor(fx), math.floor(fz))
				season = SeasonClimate.sample(dayTime, SeasonClimate.classOf(biome), worldSeed, nil, record.season)
				record.season = season
			end
			local env = Climate.environment(view, fx, fy, fz, dayTime, {
				wet = Temperature.isWet(temperature),
				sprinting = os.clock() < record.sprintingUntil,
				burning = character:GetAttribute(Characters.ON_FIRE) == true,
				armorWarmth = warmth,
				armorCooling = cooling,
			}, season)
			temperature.target = Temperature.target(env, temperature)
			record.room = env.room
			record.outside = Temperature.outside(env)
		end
		-- (Resistance softens the extremes, as Minecraft's freeze damage, which TAN's
		-- hypothermia is: in neither bypasses_resistance nor bypasses_effects. Dehydration below
		-- doesn't: it is starvation's, which bypasses effects.)
		local immune = Temperature.freezeImmune(freezeImmune, seasons)
		damage += EffectsServer.incomingDamage(player, Temperature.tick(temperature, mode, immune))
	else
		Temperature.tickEffects(temperature, mode)
	end
	-- (Fully frozen or overheated, or the regeneration block holding it: no health comes back, by
	-- hunger's rule, thirst's or Roblox's.)
	local block = regenBlock
	local stopped = (temperatureOn() and Temperature.stopsRegeneration(temperature)) or (block ~= nil and block(player))
	pauseRobloxRegeneration(record, character, stopped)
	if thirstOn() then
		local hot = temperatureOn() and Temperature.zone(temperature.value) == Temperature.HOT
		local lost, gained = Thirst.tick(
			thirst,
			mode,
			health,
			HEALTH,
			if hot then Config.ToughAsNails.HotExhaustion else 0,
			Temperature.clement(temperature),
			-- (Hunger on: its regeneration is the only one, so thirst's own is always held.)
			stopped or hungerOn(),
			if perks then perks.thirstRate(player) else nil
		)
		damage += lost
		heal += gained
	end
	if hungerOn() then
		-- (Thirst has its say while it rules regeneration: TAN's both bars high.)
		local rules = thirstOn() and Config.ToughAsNails.ThirstRegeneration
		-- (Shivering in the COLD zone and below costs food, with the seasons on: the mirror of
		-- the HOT zone's sweating.)
		if temperatureOn() and ToughAsNails.affects(mode) then
			local shiver = Temperature.coldExhaustion(temperature.value, seasons)
			if shiver > 0 then
				Hunger.addExhaustion(hunger, shiver)
			end
		end
		local lost, gained = Hunger.tick(
			hunger,
			mode,
			health,
			HEALTH,
			Hunger.effectExhaustion(EffectsServer.levels(player)),
			stopped,
			if rules then thirst.thirst else nil
		)
		damage += lost
		heal += gained
	end
	if damage > 0 then
		humanoid:TakeDamage(damage / HEALTH * maxHealth)
	end
	if heal > 0 and humanoid.Health > 0 then
		humanoid.Health = math.min(maxHealth, humanoid.Health + heal / HEALTH * maxHealth)
	end
	-- (Read after this tick's own hurts and healing, which cost no exhaustion of their own.)
	record.health = humanoid.Health / maxHealth * HEALTH
	send(net, player, record)
end

--[[ Requests ]]

local function onExertion(player: Player, payload: buffer)
	local report = Protocol.decodeExertion(payload)
	local record = records[player]
	if report == nil or record == nil then
		return
	end
	local now = os.clock()
	local second = math.floor(now)
	if second ~= record.reportSecond then
		record.reportSecond, record.reports = second, 0
	end
	record.reports += 1
	if record.reports > REPORTS_PER_SECOND then
		return
	end
	local seconds = math.min(now - record.lastReport, 2) + 0.25
	record.lastReport = now
	local mode = GameMode.of(player)
	-- (Too hungry to sprint: the flag is not believed. Hunger.canSprint, LocalPlayer's rule.)
	local mayRun = not hungerOn() or Hunger.canSprint(record.hunger.food, mode)
	record.sprintingUntil = if report.sprinting and mayRun then now + SPRINT_HOLD else 0
	if humanoidOf(player) and ToughAsNails.affects(mode) then
		local exhaustion = Exertion.exhaustion(Exertion.clamp(report, seconds))
		if thirstOn() then
			Thirst.addExhaustion(record.thirst, exhaustion)
		end
		if hungerOn() then
			Hunger.addExhaustion(record.hunger, exhaustion)
		end
	end
end

-- Plays the drinking gulp for everyone near but the drinker (whose client played it).
local function gulp(player: Player)
	if Sounds.allow(player) then
		Sounds.playAt(player, DRINK, player)
	end
end

local function onDrink(world: WorldServer.World, player: Player, payload: buffer)
	local action, x, y, z = Protocol.decodeDrink(payload)
	local record = records[player]
	local mode = GameMode.of(player)
	if action == nil or record == nil or humanoidOf(player) == nil or GameMode.isSpectator(mode) then
		return
	end
	local actions = Protocol.DrinkAction
	local held = Inventories.heldStack(player)
	local now = os.clock()
	if action == actions.Cancel then
		record.drinking = nil
		UseState.finish(player, Types.USE_DRINK)
	elseif action == actions.Start then
		record.drinking = nil
		UseState.finish(player, Types.USE_DRINK)
		local slot = selectedSlot(player)
		if held and slot and mayDrink(record, held.item, mode) then
			record.drinking = { started = now, slot = slot, item = held.item }
			UseState.begin(player, Types.USE_DRINK, Drinks.USE_TICKS)
		end
	elseif action == actions.Finish then
		local drinking = record.drinking
		record.drinking = nil
		UseState.finish(player, Types.USE_DRINK)
		local drink = Drinks.of(held and held.item)
		if
			drinking == nil
			or held == nil
			or drink == nil
			or held.item ~= drinking.item
			or selectedSlot(player) ~= drinking.slot
			or now - drinking.started < (Drinks.USE_TICKS - FINISH_LEEWAY) * TICK
			or not mayDrink(record, held.item, mode)
		then
			return
		end
		Drinks.apply(if thirstOn() then record.thirst else nil, drink, function(): number
			return random:NextNumber()
		end, if temperatureOn() then record.temperature else nil)
		if drink.effects then
			-- (A potion: PotionItem.finishUsingItem.)
			EffectsServer.giveAll(player, drink.effects)
		end
		if Drinks.manaOf(drink) > 0 then
			-- (Terraria's mana potions: the mana and Mana Sickness, Players/Mana.)
			ManaServer.potion(player, Drinks.manaOf(drink))
		end
		local newHeld, give = Drinks.afterDrinking(held, GameMode.instabuild(mode))
		if newHeld ~= held then
			Inventories.setHeld(player, newHeld)
		end
		if give then
			Inventories.give(player, give)
		end
		gulp(player)
	elseif action == actions.Hand or action == actions.Fill then
		if
			y >= Config.WorldHeight
			or not inReach(player, x, y, z)
			or not Drinks.isWaterSource(world:peekBlock(x, y, z))
		then
			return
		end
		if action == actions.Hand then
			if
				held ~= nil
				or not Config.ToughAsNails.HandDrinking
				or not thirstOn()
				or not Thirst.canDrink(record.thirst, mode)
				or now - record.lastHand < Drinks.HAND_INTERVAL * TICK
			then
				return
			end
			record.lastHand = now
			Drinks.apply(record.thirst, Drinks.HAND, function(): number
				return random:NextNumber()
			end, if temperatureOn() then record.temperature else nil)
			gulp(player)
		elseif held and Drinks.fills(held) then
			local newHeld, give = Drinks.fill(held, GameMode.instabuild(mode), function(item: number): boolean
				return Inventories.hasItem(player, item)
			end)
			if newHeld ~= held then
				Inventories.setHeld(player, newHeld)
			end
			if give then
				Inventories.give(player, give)
			end
			if Sounds.allow(player) then
				Sounds.playAt(player, FILL)
			end
		end
	end
end

--[[ API ]]

-- Sets Progression's perks (see Perks; nil: none).
function ToughAsNailsServer.setPerks(value: Perks?)
	perks = value
end

--[[
	Sets the regeneration block (nil: none): while `fn(player)` holds, neither thirst's
	regeneration nor the Roblox Health script gives that player health back (see the header). The
	zombie apocalypse's infection sets it (server Apocalypse/Infection).
]]
function ToughAsNailsServer.setRegenBlock(fn: ((player: Player) -> boolean)?)
	regenBlock = fn
end

--[[
	Pauses (or lets run again) `player`'s Roblox Health script where this module's own tick doesn't
	run (thirst, temperature and hunger all off); while it runs, its tick decides through the
	regeneration block and this does nothing.
]]
function ToughAsNailsServer.pauseRegeneration(player: Player, paused: boolean)
	local record = records[player]
	local character = player.Character
	if record == nil or character == nil or thirstOn() or temperatureOn() or hungerOn() then
		return
	end
	pauseRobloxRegeneration(record, character, paused)
end

-- Is `player` sprinting (their client's last movement report said so, within SPRINT_HOLD s)?
function ToughAsNailsServer.sprinting(player: Player): boolean
	local record = records[player]
	return record ~= nil and os.clock() < record.sprintingUntil
end

-- ServerNet's `broke` rule: `player` broke `block` in survival (Minecraft's EXHAUSTION_MINE).
function ToughAsNailsServer.blockBroken(player: Player, _block: number)
	local record = records[player]
	if record and ToughAsNails.affects(GameMode.of(player)) then
		if thirstOn() then
			Thirst.addExhaustion(record.thirst, Thirst.EXHAUSTION.mine)
		end
		if hungerOn() then
			Hunger.addExhaustion(record.hunger, Hunger.EXHAUSTION.mine)
		end
	end
end

-- Server Mobs/Mobs: `player`'s attack landed on a mob (Minecraft's EXHAUSTION_ATTACK, the food
-- bar's only: see the header).
function ToughAsNailsServer.attacked(player: Player)
	local record = records[player]
	if record and hungerOn() and ToughAsNails.affects(GameMode.of(player)) then
		Hunger.addExhaustion(record.hunger, Hunger.EXHAUSTION.attack)
	end
end

-- A player's thirst and temperature (nil before their first character), read only.
function ToughAsNailsServer.state(player: Player): (Thirst.State?, Temperature.State?)
	local record = records[player]
	if record == nil then
		return nil, nil
	end
	return record.thirst, record.temperature
end

-- A player's food bar while hunger is on (nil: off, or before their first character); server
-- Players/Eating reads and fills it.
function ToughAsNailsServer.hunger(player: Player): Hunger.State?
	local record = records[player]
	return if record and hungerOn() then record.hunger else nil
end

--[[ Saving (World/WorldSave) ]]

-- Saved state waiting for a player's next character (their record is made on it).
local restored: { [Player]: { thirst: Thirst.State?, temperature: Temperature.State?, hunger: Hunger.State? } } = {}

-- Copies the fields of `from` that `into` has (numbers only, finite).
local function copyNumbers(into: { [string]: any }, from: { [string]: any }?)
	if from == nil then
		return
	end
	for key, value in into do
		local saved = from[key]
		if type(value) == "number" and type(saved) == "number" and saved == saved and math.abs(saved) ~= math.huge then
			into[key] = saved
		end
	end
end

local function applySaved(record: Record, thirst: Thirst.State?, temperature: Temperature.State?, hunger: Hunger.State?)
	copyNumbers(record.thirst :: any, thirst :: any)
	copyNumbers(record.temperature :: any, temperature :: any)
	copyNumbers(record.hunger :: any, hunger :: any)
	record.thirst.thirst = math.clamp(record.thirst.thirst, 0, Thirst.MAX)
	local food = record.hunger
	food.food = math.clamp(math.round(food.food), 0, Hunger.MAX)
	food.saturation = math.clamp(food.saturation, 0, food.food)
	food.exhaustion = math.clamp(food.exhaustion, 0, Hunger.MAX_EXHAUSTION)
	food.timer = math.max(math.floor(food.timer), 0)
	record.temperature.value = math.clamp(record.temperature.value, Temperature.MIN, Temperature.MAX)
	record.temperature.target = math.clamp(record.temperature.target, Temperature.MIN, Temperature.MAX)
	-- (Health set with it is no hurt.)
	record.health = nil
	record.sent = nil
end

-- A player's thirst, temperature and food bar as a save keeps them (copies; nil before a
-- character).
function ToughAsNailsServer.export(player: Player): (Thirst.State?, Temperature.State?, Hunger.State?)
	local record = records[player]
	if record == nil then
		return nil, nil, nil
	end
	return table.clone(record.thirst), table.clone(record.temperature), table.clone(record.hunger)
end

--[[
	A saved player's thirst, temperature (Climate Clemency left included) and food bar (nil: a
	record from before hunger, a full bar): into their record when their character stands, else
	into their next character's instead of a fresh one.
]]
function ToughAsNailsServer.restore(
	player: Player,
	thirst: Thirst.State?,
	temperature: Temperature.State?,
	hunger: Hunger.State?
)
	local record = records[player]
	if record and player.Character then
		applySaved(record, thirst, temperature, hunger)
	else
		restored[player] = { thirst = thirst, temperature = temperature, hunger = hunger }
	end
end

-- TAN's effects in the status effect list (see the header).
local function registerEffects()
	local id = SharedEffects.id
	local function thirstOf(player: Player): Thirst.State?
		local record = records[player]
		return if record and thirstOn() then record.thirst else nil
	end
	local function temperatureOf(player: Player): Temperature.State?
		local record = records[player]
		return if record and temperatureOn() then record.temperature else nil
	end
	local function clemencyOf(player: Player): Temperature.State?
		local record = records[player]
		return if record then record.temperature else nil
	end
	-- (Thirst's effect and the clemency stand still for creative and spectator players:
	-- Thirst.tick, Temperature.tickEffects. The warmth and chill count down in every mode.)
	local function held(player: Player): boolean
		return GameMode.invulnerable(GameMode.of(player))
	end
	EffectsServer.addExternal(id.Thirst, {
		get = function(player: Player): number?
			local thirst = thirstOf(player)
			return if thirst then thirst.effect else nil
		end,
		paused = held,
		give = function(player: Player, ticks: number)
			local thirst = thirstOf(player)
			if thirst then
				Thirst.giveEffect(thirst, ticks)
			end
		end,
		clear = function(player: Player)
			local thirst = thirstOf(player)
			if thirst then
				thirst.effect = 0
			end
		end,
	})
	EffectsServer.addExternal(id.InternalWarmth, {
		get = function(player: Player): number?
			local temperature = temperatureOf(player)
			return if temperature then temperature.warmth else nil
		end,
		give = function(player: Player, ticks: number)
			local temperature = temperatureOf(player)
			if temperature then
				Temperature.giveWarmth(temperature, ticks)
			end
		end,
		clear = function(player: Player)
			local temperature = temperatureOf(player)
			if temperature then
				temperature.warmth = 0
			end
		end,
	})
	EffectsServer.addExternal(id.InternalChill, {
		get = function(player: Player): number?
			local temperature = temperatureOf(player)
			return if temperature then temperature.chill else nil
		end,
		give = function(player: Player, ticks: number)
			local temperature = temperatureOf(player)
			if temperature then
				Temperature.giveChill(temperature, ticks)
			end
		end,
		clear = function(player: Player)
			local temperature = temperatureOf(player)
			if temperature then
				temperature.chill = 0
			end
		end,
	})
	EffectsServer.addExternal(id.ClimateClemency, {
		get = function(player: Player): number?
			local temperature = clemencyOf(player)
			return if temperature then temperature.clemency else nil
		end,
		paused = held,
		give = function(player: Player, ticks: number)
			local temperature = clemencyOf(player)
			if temperature then
				Temperature.grantClemency(temperature, ticks)
			end
		end,
		clear = function(player: Player)
			local temperature = clemencyOf(player)
			if temperature then
				temperature.clemency = 0
			end
		end,
	})
end

-- Whether the machine at a cell works (its active flag: a generator burning or turning).
local function working(x: number, y: number, z: number): boolean
	local machines = Machines.world()
	local machine = if machines then MachineWorld.machine(machines, x, y, z) else nil
	local data = if machine then machine.container.data else nil
	return data ~= nil and (data[SharedMachines.ACTIVE] or 0) ~= 0
end

-- What the seasons' heater, cooler or stove at a cell delivers (its `heat` field, HU; 0: none).
local function heatOf(x: number, y: number, z: number): number
	local machines = Machines.world()
	local machine = if machines then MachineWorld.machine(machines, x, y, z) else nil
	local container = if machine then machine.container else nil
	local index = if container then SharedMachines.field(container.block, "heat") else nil
	local data = if container then container.data else nil
	local value = if data and index then data[index] else nil
	return if type(value) == "number" and value == value then value else 0
end

-- The heat sources that warm only while they burn or work (see the header).
local function registerHeatSources()
	Climate.addHeatSource(Blocks.id.Furnace, function(x: number, y: number, z: number): boolean
		local container = Containers.peek(x, y, z)
		local data = container and container.data
		return data ~= nil and (data[1] or 0) > 0
	end)
	Climate.addHeatSource(Blocks.id.HeatGenerator, working)
	Climate.addHeatSource(Blocks.id.CombustionGenerator, working)
	-- The seasons' heaters, coolers and stoves: while they deliver heat (or cold); outdoors the
	-- Electric Heater warms within SpaceHeaterRadius and a running fan cools within FanRadius.
	local function heating(x: number, y: number, z: number): boolean
		return heatOf(x, y, z) > 0
	end
	local function cooling(x: number, y: number, z: number): boolean
		return heatOf(x, y, z) < 0
	end
	local heat = Config.Seasons.Heat
	Climate.addHeatSource(Blocks.id.WoodStove, heating, true)
	Climate.addHeatSource(Blocks.id.OilHeater, heating, true)
	Climate.addHeatSource(Blocks.id.ElectricHeater, heating, nil, heat.SpaceHeaterRadius)
	Climate.addColdSource(Blocks.id.AirConditioner, cooling)
	Climate.addColdSource(Blocks.id.ElectricFan, cooling, heat.FanRadius)
end

--[[
	What the machines give a room's air (server Seasons/RoomWorld, through Climate.addRoomSource):
	a lit Furnace, a working generator, the heaters', coolers' and stoves' `heat`. Registered at
	the start whatever thirst and temperature say: rooms run with Tough As Nails off too.
]]
local function registerRoomSources()
	local heat = Config.Seasons.Heat
	Climate.addRoomSource(Blocks.id.Furnace, function(x: number, y: number, z: number): number
		local container = Containers.peek(x, y, z)
		local data = container and container.data
		return if data ~= nil and (data[1] or 0) > 0 then heat.Furnace else 0
	end)
	local function generator(x: number, y: number, z: number): number
		return if working(x, y, z) then heat.Generator else 0
	end
	Climate.addRoomSource(Blocks.id.HeatGenerator, generator)
	Climate.addRoomSource(Blocks.id.CombustionGenerator, generator)
	for _, name in { "WoodStove", "OilHeater", "ElectricHeater", "AirConditioner", "ElectricFan" } do
		Climate.addRoomSource(Blocks.id[name], heatOf)
	end
end

--[[
	Starts thirst, temperature and hunger (nothing ticks when Config.ToughAsNails turns both off and
	Config.Hunger is off). Players/Inventories and Machines must have started.
]]
function ToughAsNailsServer.start(net: ServerNet.ServerNet, world: WorldServer.World)
	assert(not started, "ToughAsNails.start was already called")
	started = true
	local on = thirstOn() or temperatureOn() or hungerOn()
	-- (The rooms' sources whatever thirst and temperature say: rooms run on their own.)
	registerRoomSources()
	if thirstOn() or temperatureOn() then
		registerHeatSources()
		registerEffects()
	end
	worldSeed = (world.generator :: any).seed or 0

	local view: Climate.View = {
		getBlock = function(x: number, y: number, z: number): number?
			return world:peekBlock(x, y, z)
		end,
		column = function(x: number, z: number): (number, number)
			local height, biome = world.generator.column(x, z)
			return height, biome
		end,
		skyOpen = function(x: number, y: number, z: number): boolean
			return SkyCheck.open(world, x, y, z)
		end,
		-- (Seasons: read only while the calendar is on, Climate.environment's `season`.)
		room = function(x: number, y: number, z: number): RoomWorld.Sample?
			return RoomWorld.sample(x, y, z)
		end,
		snowing = function(x: number, y: number, z: number): boolean
			return WeatherServer.snowingAt(x, y, z)
		end,
	}

	local function onCharacter(player: Player, character: Model)
		-- (A new character starts over, as TAN's respawned player, with Climate Clemency: the
		-- long one for the first character since joining, and a full food bar, Minecraft's.)
		local settings = Config.ToughAsNails
		local clemency = if joined[player] then settings.RespawnClemencyTicks else settings.ClemencyTicks
		joined[player] = true
		local record = newRecord(clemency)
		records[player] = record
		local saved = restored[player]
		if saved then
			restored[player] = nil
			applySaved(record, saved.thirst, saved.temperature, saved.hunger)
		end
		if hungerOn() or (thirstOn() and Config.ToughAsNails.ThirstRegeneration) then
			stopRobloxRegeneration(character)
		end
	end
	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			onCharacter(player, character)
		end)
		if player.Character then
			onCharacter(player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		records[player] = nil
		restored[player] = nil
		joined[player] = nil
	end)

	net.on(Protocol.ClientMessage.Exertion, onExertion)
	net.on(Protocol.ClientMessage.Drink, function(player: Player, payload: buffer)
		onDrink(world, player, payload)
	end)
	-- (All three off: drinking potions and filling bottles only, nothing ticks.)
	if not on then
		return
	end

	local accumulator = 0
	local tick = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator = math.min(accumulator + dt, TICK * MAX_TICKS_PER_FRAME)
		while accumulator >= TICK do
			accumulator -= TICK
			tick += 1
			for player, record in records do
				-- (Each player looks around once a second, on a tick of their own.)
				local sample = (tick + player.UserId) % 20 == 0
				tickPlayer(net, view, player, record, sample)
			end
		end
	end)
end

return ToughAsNailsServer
