--!strict
--[[
	Radiation on the server (Mekanism's, simplified): every living player's exposure and dose (the
	rules are Shared/Radiation and Players/RadiationRules, pure and tested; this plays them out),
	the Radiation Sickness it gives, and the rate the client's Geiger counter clicks at.
	Config.Radiation.Enabled false: nothing ticks or is published, and a saved dose is kept as it
	is.

	  Looks      once every Config.Radiation.Interval seconds a player (the players spread over it on
	             a 20 Hz count, as Players/ToughAsNails' looks around), for every living player in
	             the world: RadiationRules.look with the server's loaded blocks (World/WorldServer
	             .peekBlock: an unloaded cell is nothing, never generated for this), their feet
	             (Players/PlayerPositions), game mode and what they carry (Players/Inventories: the
	             inventory, and the open window's own crafting grid: the inventory screen's 2 x 2
	             or a crafting table's 3 x 3, results left out), over the seconds since their last
	             look (at most MAX_SECONDS). Creative and spectator players are never exposed;
	             their dose only decays.
	  Sickness   through Players/Effects (`give`, read back with `amplifier` and `ticks`): Radiation
	             Sickness at the dose's level, Hunger and Nausea with the higher ones, renewed while
	             the dose holds (Radiation.renewal), so they lapse Sickness.Ticks after it falls.
	  Published  player attributes (they replicate to the clients by themselves, as Inventory/
	             Types.USE_ATTRIBUTE does): Radiation.RATE_ATTRIBUTE the exposure rate (Sv/h) and
	             DOSE_ATTRIBUTE the dose (Sv), each to two significant figures (Radiation.round, so
	             they change only when that does) and absent at 0. Client Audio/Geiger clicks from
	             the rate, F3 shows both.
	  Death      a new character starts with no dose (and its rate at 0); a dead one stops being
	             looked at and its rate goes at once.
	  Saved      a saved player's dose comes back on their first character, or the one standing
	             (`restore`: World/WorldSave's player record, Save/PlayerCodec version 5; with
	             characters Players/CharacterStore's, Save/CharacterCodec version 4), and `export`
	             gives it to save. A leaving player is forgotten only after every PlayerRemoving
	             handler ran (task.defer), so the saves made as they leave read it.

	API (server modules):
	  start(world)                  once, after Players/Effects and Inventories.
	  export(player) -> number?     the dose (Sv) to save; nil before their first character.
	  restore(player, dose)         a saved dose (see Saved).
	  rate(player) -> number        the last look's rate (Sv/h; 0 none).
	  dose(player) -> number        the dose now (Sv; 0 none).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Protocol = require(Shared.Net.Protocol)
local Radiation = require(Shared.Radiation)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local Effects = require(script.Parent.Effects)
local Inventories = require(script.Parent.Inventories)
local PlayerPositions = require(script.Parent.PlayerPositions)
local RadiationRules = require(script.Parent.RadiationRules)

local TICK = 1 / 20
local MAX_TICKS_PER_FRAME = 4
-- The longest a look may count (seconds): a stall or a long death isn't all exposure.
local MAX_SECONDS = 5
local RATE = Radiation.RATE_ATTRIBUTE
local DOSE = Radiation.DOSE_ATTRIBUTE

type Record = {
	state: RadiationRules.State,
	-- os.clock() of the last look (nil: none yet this character).
	last: number?,
}

local RadiationServer = {}

local records: { [Player]: Record } = {}
-- Saved doses waiting for a player's next character.
local restored: { [Player]: number } = {}
local started = false

-- Sets `player`'s attribute `name` to `value` rounded (absent at 0), when that changes it.
local function publish(player: Player, name: string, value: number)
	local shown = Radiation.round(value)
	local now: number? = if shown > 0 then shown else nil
	if player:GetAttribute(name) ~= now then
		player:SetAttribute(name, now)
	end
end

local function show(player: Player, state: RadiationRules.State)
	publish(player, RATE, state.rate)
	publish(player, DOSE, state.dose)
end

-- The stacks of the open window's own crafting grid (nil: none open): the inventory screen's or
-- a crafting table's (slot 1, the result, left out).
local function grid(window: any): { [number]: Items.Stack? }?
	local container = window and window.container
	if container == nil or (container.kind ~= "inventory" and container.kind ~= "crafting") then
		return nil
	end
	local stacks: { [number]: Items.Stack? } = {}
	for slot, stack in container.slots do
		if slot ~= 1 then
			stacks[slot] = stack
		end
	end
	return stacks
end

-- The hooks that give `player` their symptoms (Players/Effects).
local function hooksOf(player: Player): RadiationRules.Hooks
	return {
		current = function(effect: number): (number?, number)
			return Effects.amplifier(player, effect), Effects.ticks(player, effect)
		end,
		give = function(effect: number, ticks: number, amplifier: number)
			Effects.give(player, effect, ticks, amplifier)
		end,
	}
end

-- One look at a living `player` (see the header).
local function look(getBlock: (x: number, y: number, z: number) -> number?, player: Player, record: Record)
	local fx, fy, fz = PlayerPositions.feet(player)
	if
		fx == nil
		or not (math.abs(fx) <= Protocol.MAX_COORDINATE)
		or not (math.abs(fy) <= Protocol.MAX_COORDINATE)
		or not (math.abs(fz) <= Protocol.MAX_COORDINATE)
	then
		return
	end
	local now = os.clock()
	local seconds = if record.last then math.clamp(now - record.last, 0, MAX_SECONDS) else Config.Radiation.Interval
	record.last = now
	local window = Inventories.get(player)
	RadiationRules.look(record.state, getBlock, {
		x = fx,
		y = fy,
		z = fz,
		mode = GameMode.of(player),
		inventory = if window then window.inventory else nil,
		extra = grid(window),
	}, seconds, hooksOf(player))
	show(player, record.state)
end

local function alive(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

--[[ API ]]

-- The dose (Sv) a save keeps; nil before the player's first character (nothing kept yet), and the
-- waiting saved one before it stands.
function RadiationServer.export(player: Player): number?
	local record = records[player]
	if record then
		return record.state.dose
	end
	return restored[player]
end

-- A saved player's dose (Sv; checked): into the character standing, else their next one.
function RadiationServer.restore(player: Player, dose: number?)
	local state = RadiationRules.new(dose)
	local record = records[player]
	if record and player.Character then
		record.state.dose = state.dose
		show(player, record.state)
	else
		restored[player] = state.dose
	end
end

-- The last look's rate at `player` (Sv/h; 0 none).
function RadiationServer.rate(player: Player): number
	local record = records[player]
	return if record then record.state.rate else 0
end

-- `player`'s dose (Sv; 0 none).
function RadiationServer.dose(player: Player): number
	local record = records[player]
	return if record then record.state.dose else 0
end

--[[
	Starts radiation (see the header): every character's record, and with Config.Radiation on the
	looks. Players/Effects and Players/Inventories must have started.
]]
function RadiationServer.start(world: WorldServer.World)
	assert(not started, "Radiation.start was already called")
	started = true
	local function onCharacter(player: Player, character: Model)
		-- (Death clears the dose; a saved one comes back on the first character.)
		local record: Record = { state = RadiationRules.new(restored[player]), last = nil }
		restored[player] = nil
		records[player] = record
		show(player, record.state)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			humanoid.Died:Connect(function()
				if records[player] == record then
					record.state.rate = 0
					publish(player, RATE, 0)
				end
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
	Players.PlayerRemoving:Connect(function(player: Player)
		-- (After every other PlayerRemoving handler: the saves made as they leave read the dose.)
		task.defer(function()
			records[player] = nil
			restored[player] = nil
		end)
	end)
	if not Config.Radiation.Enabled then
		return
	end

	local function getBlock(x: number, y: number, z: number): number?
		return world:peekBlock(x, y, z)
	end
	local every = math.max(1, math.round(Config.Radiation.Interval / TICK))
	local accumulator = 0
	local tick = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator = math.min(accumulator + dt, TICK * MAX_TICKS_PER_FRAME)
		while accumulator >= TICK do
			accumulator -= TICK
			tick += 1
			for player, record in records do
				-- (Each player is looked at on a tick of their own.)
				if (tick + player.UserId) % every == 0 and player.Parent and alive(player) then
					look(getBlock, player, record)
				end
			end
		end
	end)
end

return RadiationServer
