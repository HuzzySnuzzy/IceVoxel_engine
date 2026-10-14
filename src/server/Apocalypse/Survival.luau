--!strict
--[[
	The zombie apocalypse's survival rules on the server (the pure rules: Apocalypse/SurvivalRules
	and Shared/Apocalypse/Infection, tested in Lune; this plays them out). The boot script starts
	it after Players/Eating.

	  Bites      Mobs/Mobs.playerHit: a fresh landed hit (not under the hurt cooldown) by a
	             `zombie` kind on a survival or adventure player rolls the kind's `infect` less the
	             armour's shield, at most once every Infection.RollInterval ticks a player
	             (Apocalypse/Infection.bite), and its `bleed` for Bleeding (at least
	             Bleeding.Ticks, a level up when already bleeding, at most MaxAmplifier:
	             Players/Effects.give; never with Bleeding.Enabled false).
	  Ticks      20 a second (catching up a few a frame), for every player with a living
	             character: a tick alive on their survivor record, the blood moon's watch
	             (SurvivalRules.tickLiving: survived from rise to set), the infection's tick
	             (Apocalypse/Infection.tick), and once a second (players spread over it) a sprint
	             noise of Noise.Sprint blocks at the feet of a sprinting player
	             (Apocalypse/NoiseBus.emit; Players/ToughAsNails.sprinting, or the feet's speed
	             with Tough As Nails off: SurvivalRules.measuredSprint) who makes sounds (not a
	             spectator).
	  Kills      Mobs/Mobs.died with a player the killer and a zombie kind: a kill on their record.
	  Death      the record starts over; an infected player's death (Apocalypse/Infection.died)
	             tells everyone "<name> succumbed to the infection" when it was the infection, and
	             with Zombies.RiseOnDeath raises a Zombie where they fell Zombies.RiseDelay ticks
	             later (Mobs/Mobs.spawn, dressed in the civilian look nearest their torso colour:
	             SurvivalRules.riseVariant) and tells everyone "<name> rose again".
	  Survivor   the player's record goes to them alone (Protocol Survivor) when their character
	             comes (joining, respawning), when a saved record is restored, after a kill or a
	             blood moon survived, and every Survivor.SyncTicks; the client's day counter
	             (Ui/SurvivorHud) shows it.
	  Saved      `export` / `restore`: the record and the infection's progress, the character's
	             (Players/CharacterStore, Save/CharacterCodec), or with Config.Characters off the
	             player's in each world (World/WorldSave, Save/PlayerCodec). A leaving player is
	             forgotten only after every PlayerRemoving handler ran (task.defer), so the saves
	             made as they leave have it.
	With Config.Apocalypse.Enabled false there are no bites, wounds, infection (a saved one is
	dormant: Apocalypse/Infection), noise, blood moons survived or messages (the alive ticks still
	count, and everything is kept, so turning it back on loses nothing).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Accessories = require(Shared.Items.Accessories)
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local MobList = require(Shared.Entities.MobList)
local Protocol = require(Shared.Net.Protocol)
local SharedToughAsNails = require(Shared.ToughAsNails)

local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local WorldServer = require(script.Parent.Parent.World.WorldServer)
local TimeOfDay = require(script.Parent.Parent.World.TimeOfDay)
local Mobs = require(script.Parent.Parent.Mobs.Mobs)
local EffectsServer = require(script.Parent.Parent.Players.Effects)
local GameModeRules = require(script.Parent.Parent.Players.GameModeRules)
local Inventories = require(script.Parent.Parent.Players.Inventories)
local PlayerPositions = require(script.Parent.Parent.Players.PlayerPositions)
local ToughAsNails = require(script.Parent.Parent.Players.ToughAsNails)
local Infection = require(script.Parent.Infection)
local NoiseBus = require(script.Parent.NoiseBus)
local SurvivalRules = require(script.Parent.SurvivalRules)

local TICK = 1 / 20
local MAX_TICKS_PER_FRAME = 4

local Survival = {}

type Record = SurvivalRules.Record
-- Each player's survivor record, and the ticks until their next Survivor message.
local records: { [Player]: Record } = {}
local syncIn: { [Player]: number } = {}
-- Where each player's feet were at their last sprint check (the speed without Tough As Nails).
local lastFeet: { [Player]: { x: number, z: number } } = {}
local net: ServerNet.ServerNet? = nil
local tick = 0
local random = Random.new()

local function apocalypse(): boolean
	return Config.Apocalypse.Enabled
end

local function recordOf(player: Player): Record
	local record = records[player]
	if record == nil then
		record = SurvivalRules.new()
		records[player] = record
	end
	return record
end

-- Sends `player` their record now (see the header).
local function sync(player: Player)
	local network = net
	local record = records[player]
	syncIn[player] = Config.Apocalypse.Survivor.SyncTicks
	if network == nil or record == nil or player.Parent == nil or not apocalypse() then
		return
	end
	network.send(
		player,
		Protocol.ServerMessage.Survivor,
		Protocol.encodeSurvivor(record.alive, record.kills, record.moons)
	)
end

-- A line in everyone's chat (the deaths and risings of the infected).
local function tellEveryone(text: string)
	local network = net
	if network == nil then
		return
	end
	local payload = Protocol.encodeNotice(text)
	for _, player in Players:GetPlayers() do
		network.send(player, Protocol.ServerMessage.Notice, payload)
	end
end

-- The armour points `player` wears (Items/Accessories' sums, as Players/Characters reads them).
local function armorOf(player: Player): number
	local window = Inventories.get(player)
	if window == nil then
		return 0
	end
	local points = Accessories.armorPoints(window.inventory)
	return points
end

--[[ Bites and wounds ]]

local function onHit(player: Player, kindName: string, _damage: number, fresh: boolean, _mobId: number)
	local id = MobList.find(kindName)
	local kind = if id then MobList.get(id) else nil
	if not apocalypse() or not fresh or kind == nil or not kind.zombie then
		return
	end
	if not GameMode.isSurvivalLike(GameMode.of(player)) then
		return
	end
	local function roll(): number
		return random:NextNumber()
	end
	Infection.bite(player, kind.infect or 0, armorOf(player), tick, roll)
	local bleeding = Config.Apocalypse.Bleeding
	local bleed = kind.bleed or 0
	if bleeding.Enabled and bleed > 0 and roll() < bleed then
		local ticks, amplifier = SurvivalRules.bleeding(
			EffectsServer.ticks(player, "Bleeding"),
			EffectsServer.amplifier(player, "Bleeding"),
			bleeding
		)
		EffectsServer.give(player, "Bleeding", ticks, amplifier)
	end
end

--[[ Deaths ]]

-- The player's torso colour (0..255; grey when there is none to read).
local function torsoColour(character: Model?): { number }
	local colour: Color3? = nil
	if character then
		local body = character:FindFirstChildOfClass("BodyColors")
		if body then
			colour = body.TorsoColor3
		else
			local part = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
			if part and part:IsA("BasePart") then
				colour = part.Color
			end
		end
	end
	if colour == nil then
		return { 128, 128, 128 }
	end
	return { colour.R * 255, colour.G * 255, colour.B * 255 }
end

local function onDied(player: Player, character: Model)
	-- (Where they fell, before anything moves the record.)
	local fx, fy, fz = PlayerPositions.feet(player)
	records[player] = SurvivalRules.new()
	local p, succumbed = Infection.died(player)
	if not apocalypse() then
		return
	end
	if succumbed then
		tellEveryone(`{player.DisplayName} succumbed to the infection`)
	end
	local apocalypseSettings = Config.Apocalypse
	if fx == nil or not SurvivalRules.rises(p, apocalypseSettings.Enabled, apocalypseSettings.Zombies.RiseOnDeath) then
		return
	end
	local zombie = MobList.get(MobList.find("Zombie") or 0)
	local looks = if zombie then MobList.looksOf(zombie) else nil
	local variant = if looks
		then SurvivalRules.riseVariant(looks, torsoColour(character), player.UserId % #MobList.SKIN_TONES + 1)
		else nil
	local name = player.DisplayName
	task.delay(Config.Apocalypse.Zombies.RiseDelay * TICK, function()
		if Mobs.spawn("Zombie", fx, fy, fz, variant) ~= 0 then
			tellEveryone(`{name} rose again`)
		end
	end)
end

--[[ Ticking ]]

-- Is `player` sprinting (see the header), at their feet (fx, fz)?
local function sprinting(player: Player, fx: number, fz: number): boolean
	local last = lastFeet[player]
	lastFeet[player] = { x = fx, z = fz }
	if SharedToughAsNails.thirstOn() or SharedToughAsNails.temperatureOn() then
		return ToughAsNails.sprinting(player)
	end
	return last ~= nil and SurvivalRules.measuredSprint(fx - last.x, fz - last.z, SurvivalRules.SPRINT_EVERY * TICK)
end

local function tickPlayer(player: Player, record: Record, dayTime: number)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return
	end
	local mode = GameMode.of(player)
	local survived = SurvivalRules.tickLiving(record, dayTime, apocalypse(), Config.Apocalypse.BloodMoon)
	if apocalypse() then
		Infection.tick(player, mode)
		if (tick + player.UserId) % SurvivalRules.SPRINT_EVERY == 0 then
			local fx, fy, fz = PlayerPositions.feet(player)
			if fx and GameModeRules.makesSounds(mode) and sprinting(player, fx, fz) then
				NoiseBus.emit(fx, fy, fz, Config.Apocalypse.Noise.Sprint)
			end
		end
	end
	local wait = (syncIn[player] or 0) - 1
	syncIn[player] = wait
	if survived or wait <= 0 then
		sync(player)
	end
end

--[[ API ]]

-- `player`'s survivor record and infection as a save keeps them (nil: no record).
function Survival.export(player: Player): SurvivalRules.Saved?
	local record = records[player]
	if record == nil then
		return nil
	end
	return { alive = record.alive, kills = record.kills, moons = record.moons, infection = Infection.export(player) }
end

-- A saved record and infection for `player` (Players/CharacterStore), sent to them at once.
function Survival.restore(player: Player, saved: SurvivalRules.Saved?)
	records[player] = SurvivalRules.fromSaved(saved)
	Infection.restore(player, if saved then saved.infection else 0)
	sync(player)
end

-- `player`'s survivor record (read only; nil before their first character).
function Survival.record(player: Player): Record?
	return records[player]
end

-- Starts the survival rules (see the header). `serverNet` is the ServerNet; `world` the world.
function Survival.start(serverNet: ServerNet.ServerNet, _world: WorldServer.World)
	assert(net == nil, "Survival.start was already called")
	net = serverNet
	Infection.start()
	Mobs.playerHit:Connect(onHit)
	Mobs.died:Connect(function(killer: Player?, kind: string)
		local record = if killer then records[killer] else nil
		if killer and record and SurvivalRules.killed(record, kind) then
			-- (Told at the next tick.)
			syncIn[killer] = 0
		end
	end)

	local function onCharacter(player: Player, character: Model)
		recordOf(player)
		syncIn[player] = 0
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			humanoid.Died:Connect(function()
				onDied(player, character)
			end)
		end
	end
	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			onCharacter(player, character)
		end)
		if player.Character then
			task.spawn(onCharacter, player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		-- (After every other PlayerRemoving handler: a leaving player's character or world record
		-- is saved with the record kept here, as Players/Mana does.)
		task.defer(function()
			records[player] = nil
			syncIn[player] = nil
			lastFeet[player] = nil
		end)
	end)

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator = math.min(accumulator + dt, TICK * MAX_TICKS_PER_FRAME)
		while accumulator >= TICK do
			accumulator -= TICK
			tick += 1
			local dayTime = TimeOfDay.get()
			for player, record in records do
				tickPlayer(player, record, dayTime)
			end
		end
	end)
end

return Survival
