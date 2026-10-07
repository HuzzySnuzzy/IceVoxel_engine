--!strict
--[[
	Tough As Nails on the server: every player's thirst and body temperature (the rules are
	Shared/ToughAsNails, pure and tested; this plays them out). Config.ToughAsNails turns each on
	and off; with both off nothing here ticks, but drinking still listens: potions are drunk
	whatever TAN does, and bottles fill at water for brewing them.

	  Ticks      20 a second (catching up a few per frame), for every living player:
	               * a hurt that landed since the last tick (health went down, not by this
	                 module) costs Thirst.EXHAUSTION.hurt;
	               * water touching the standing box (Players/Burning.touching) makes them wet;
	               * once a second (players spread over the second) the surroundings
	                 (Players/Climate, with the armor's insulation: Climate.insulation) set the
	                 temperature's target, with the player's effects and Climate Clemency
	                 (Temperature.target(env, state));
	               * Temperature.tick (the countdowns, the drift, hypothermia, hyperthermia; with
	                 temperature off only its countdowns, Temperature.tickEffects, for the
	                 clemency's sake), then Thirst.tick (with the HOT zone's sweating:
	                 Config.ToughAsNails.HotExhaustion; at half the drain under the clemency;
	                 no regeneration while fully frozen or overheated) and
	                 what they cost or give back: Humanoid:TakeDamage (half hearts scaled to
	                 MaxHealth, as Players/Characters does; it respects the ForceField of creative
	                 players, who are spared anyway) and regeneration;
	               * the player's Survival message when what it says changed, at most every
	                 SEND_TICKS ticks (and at once for a new character).
	  Health     with thirst on and Config.ToughAsNails.ThirstRegeneration, health comes back only
	             by thirst's rule: the character's Roblox "Health" script (its regeneration) is
	             removed as it appears. Otherwise that script stays, but is disabled while the
	             body is fully frozen or overheated, as thirst's regeneration waits then
	             (Temperature.stopsRegeneration: its half heart every 5 s would undo the
	             extremes' hurts).
	  Clemency   TAN's Climate Clemency: a player's first character since joining gets
	             Config.ToughAsNails.ClemencyTicks of it (5 minutes), every later one (a respawn)
	             RespawnClemencyTicks (a minute). Nothing is saved between visits, so every visit
	             starts afresh and gets the long one.
	  Death      a new character starts over (full thirst, neutral, dry), as TAN resets on respawn.
	  Exertion   the client's movement reports (Protocol Exertion, ToughAsNails/Exertion), bounded
	             by the time since the last one, cost exhaustion; their sprint flag counts as
	             sprinting for SPRINT_HOLD seconds. Breaking a block costs Thirst.EXHAUSTION.mine
	             (ServerNet's `broke` rule, `blockBroken`).
	  Drinking   Protocol Drink (Shared/ToughAsNails/Drinks): a living player who is not a
	             spectator, the item really in their hand.
	               start / finish  a bottle or canteen held from `start` to `finish` for at
	                               least Drinks.USE_TICKS - FINISH_LEEWAY ticks, the same item in
	                               the same slot, while they may drink it (Drinks.drinkable:
	                               thirsty with thirst on, Thirst.canDrink; a tea whenever
	                               temperature is on): drunk (its water only with thirst on),
	                               the Thirst effect rolled, Internal Warmth or Chill given (a
	                               drink's `warmth` / `chill`), a potion's status effects given
	                               (Players/Effects.giveAll), the bottle or sip used up
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
	             (Climate.addHeatSource), besides Config.ToughAsNails.HeatingBlocks.
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
local Protocol = require(Shared.Net.Protocol)
local PlayerPhysics = require(Shared.Movement.PlayerPhysics)
local Rig = require(Shared.Movement.Rig)
local SharedMachines = require(Shared.Machines)
local ToughAsNails = require(Shared.ToughAsNails)

local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local WorldServer = require(script.Parent.Parent.World.WorldServer)
local TimeOfDay = require(script.Parent.Parent.World.TimeOfDay)
local Sounds = require(script.Parent.Parent.Audio.Sounds)
local SkyCheck = require(script.Parent.Parent.Machines.SkyCheck)
local MachineWorld = require(script.Parent.Parent.Machines.MachineWorld)
local Machines = require(script.Parent.Parent.Machines.Machines)
local Burning = require(script.Parent.Burning)
local Characters = require(script.Parent.Characters)
local EffectsServer = require(script.Parent.Effects)
local Climate = require(script.Parent.Climate)
local Containers = require(script.Parent.Containers)
local Inventories = require(script.Parent.Inventories)

local Thirst = require(Shared.ToughAsNails.Thirst)
local Temperature = require(Shared.ToughAsNails.Temperature)
local Drinks = require(Shared.ToughAsNails.Drinks)
local Exertion = require(Shared.ToughAsNails.Exertion)

local BLOCK = Config.BlockSize
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
	}
end

-- Is thirst / temperature on?
local function thirstOn(): boolean
	return ToughAsNails.thirstOn()
end
local function temperatureOn(): boolean
	return ToughAsNails.temperatureOn()
end

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		return humanoid
	end
	return nil
end

-- Is block (x, y, z) within the player's reach (as ItemUse checks)?
local function inReach(player: Player, x: number, y: number, z: number): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return false
	end
	local center = Vector3.new((x + 0.5) * BLOCK, (y + 0.5) * BLOCK, (z + 0.5) * BLOCK)
	return (root.Position - center).Magnitude <= (Config.Interaction.Reach + 2) * BLOCK
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
	local thirst, temperature = record.thirst, record.temperature
	return {
		thirstOn = thirstOn(),
		temperatureOn = temperatureOn(),
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

-- One tick of one player (see the header). `sample`: look at the surroundings this tick.
local function tickPlayer(net: ServerNet.ServerNet, view: Climate.View, player: Player, record: Record, sample: boolean)
	local character = player.Character
	local humanoid = humanoidOf(player)
	local feet = if character then Rig.feet(character) else nil
	if
		character == nil
		or humanoid == nil
		or feet == nil
		or not (math.abs(feet.X) <= Protocol.MAX_COORDINATE)
		or not (math.abs(feet.Y) <= Protocol.MAX_COORDINATE)
		or not (math.abs(feet.Z) <= Protocol.MAX_COORDINATE)
	then
		return
	end
	local mode = GameMode.of(player)
	local maxHealth = humanoid.MaxHealth
	if maxHealth <= 0 then
		return
	end
	local health = humanoid.Health / maxHealth * HEALTH
	local thirst, temperature = record.thirst, record.temperature
	if thirstOn() and record.health and health < record.health - 1e-3 and ToughAsNails.affects(mode) then
		Thirst.addExhaustion(thirst, Thirst.EXHAUSTION.hurt)
	end

	local damage, heal = 0, 0
	if temperatureOn() then
		local touching = Burning.touchingAt(view.getBlock, feet.X, feet.Y, feet.Z, BODY.width, BODY.height)
		if Burning.has(touching, Fluids.WATER) then
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
			local env = Climate.environment(view, feet.X, feet.Y, feet.Z, TimeOfDay.get(), {
				wet = Temperature.isWet(temperature),
				sprinting = os.clock() < record.sprintingUntil,
				burning = character:GetAttribute(Characters.ON_FIRE) == true,
				armorWarmth = warmth,
				armorCooling = cooling,
			})
			temperature.target = Temperature.target(env, temperature)
		end
		damage += Temperature.tick(temperature, mode, freezeImmune)
	else
		Temperature.tickEffects(temperature, mode)
	end
	-- (Fully frozen or overheated: no health comes back, by thirst's rule or Roblox's.)
	local stopped = temperatureOn() and Temperature.stopsRegeneration(temperature)
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
			stopped,
			if perks then perks.thirstRate(player) else nil
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
	record.sprintingUntil = if report.sprinting then now + SPRINT_HOLD else 0
	if thirstOn() and humanoidOf(player) and ToughAsNails.affects(GameMode.of(player)) then
		Thirst.addExhaustion(record.thirst, Exertion.exhaustion(Exertion.clamp(report, seconds)))
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
	elseif action == actions.Start then
		record.drinking = nil
		local slot = selectedSlot(player)
		if held and slot and mayDrink(record, held.item, mode) then
			record.drinking = { started = now, slot = slot, item = held.item }
		end
	elseif action == actions.Finish then
		local drinking = record.drinking
		record.drinking = nil
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

-- ServerNet's `broke` rule: `player` broke `block` in survival (Minecraft's EXHAUSTION_MINE).
function ToughAsNailsServer.blockBroken(player: Player, _block: number)
	local record = records[player]
	if record and thirstOn() and ToughAsNails.affects(GameMode.of(player)) then
		Thirst.addExhaustion(record.thirst, Thirst.EXHAUSTION.mine)
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
	EffectsServer.addExternal(id.Thirst, {
		get = function(player: Player): number?
			local thirst = thirstOf(player)
			return if thirst then thirst.effect else nil
		end,
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

-- The heat sources that warm only while they burn or work (see the header).
local function registerHeatSources()
	Climate.addHeatSource(Blocks.id.Furnace, function(x: number, y: number, z: number): boolean
		local container = Containers.peek(x, y, z)
		local data = container and container.data
		return data ~= nil and (data[1] or 0) > 0
	end)
	local function working(x: number, y: number, z: number): boolean
		local machines = Machines.world()
		local machine = if machines then MachineWorld.machine(machines, x, y, z) else nil
		local data = if machine then machine.container.data else nil
		return data ~= nil and (data[SharedMachines.ACTIVE] or 0) ~= 0
	end
	Climate.addHeatSource(Blocks.id.HeatGenerator, working)
	Climate.addHeatSource(Blocks.id.CombustionGenerator, working)
end

--[[
	Starts thirst and temperature (nothing when Config.ToughAsNails turns both off). Players/
	Inventories and Machines must have started.
]]
function ToughAsNailsServer.start(net: ServerNet.ServerNet, world: WorldServer.World)
	assert(not started, "ToughAsNails.start was already called")
	started = true
	local on = thirstOn() or temperatureOn()
	if on then
		registerHeatSources()
		registerEffects()
	end

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
	}

	local function onCharacter(player: Player, character: Model)
		-- (A new character starts over, as TAN's respawned player, with Climate Clemency: the
		-- long one for the first character since joining.)
		local settings = Config.ToughAsNails
		local clemency = if joined[player] then settings.RespawnClemencyTicks else settings.ClemencyTicks
		joined[player] = true
		records[player] = newRecord(clemency)
		if thirstOn() and Config.ToughAsNails.ThirstRegeneration then
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
		joined[player] = nil
	end)

	net.on(Protocol.ClientMessage.Exertion, onExertion)
	net.on(Protocol.ClientMessage.Drink, function(player: Player, payload: buffer)
		onDrink(world, player, payload)
	end)
	-- (Both off: drinking potions and filling bottles only, nothing ticks.)
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
