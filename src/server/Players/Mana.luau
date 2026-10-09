--!strict
--[[
	Each player's mana (Terraria's: Config.Mana, Shared/Mana), kept by the server as health is: the
	authority over what a cast costs, what a potion or a Mana Crystal gives and how it comes back.
	A character carries its mana and the Mana Crystals it used from world to world (server
	Players/CharacterStore: `export` into the record, `restore` from it).

	  Ticks      20 a second (catching up a few per frame), for every player: the max is worked out
	             from the crystals and the accessories worn (Shared/Mana.maxOf on the inventory:
	             a Band of Starpower taken off clamps mana to the new max at once), then a living
	             player's mana comes back by Terraria 1.4.4's rule (Shared/Mana.tick). "Standing
	             still" is the server's own (Shared/Mana.stillness): the feet
	             (Players/PlayerPositions) stayed within STILL 0.01 blocks of where they last moved
	             and nothing was cast, for Shared/Mana.STILL_TICKS 4 ticks running (a tick without
	             a new Move from the client says nothing on its own).
	  Message    the player's Mana message (Net/MagicSync: whole mana, max, flags) when the whole
	             number or the max changed, at most every SEND_TICKS 4 ticks, and at once after a
	             cast (`spend`), a refused cast (flag `refused`: not enough mana; `dropped`, from
	             `dropCast`: Players/Magic refused it for another reason, too soon or too many in
	             flight, so the client takes its prediction back and shows the true mana), a
	             potion, a crystal, a respawn or a restore. Flag `full`: regeneration just filled it
	             (Terraria's chime: the client plays entity.player.mana_full).
	  Respawn    a player's first character since joining keeps the mana it has (a restored
	             character's); every later one (a respawn) starts full, as Terraria's.
	  Sickness   `potion` (a mana potion's finish: Players/ToughAsNails) adds the mana and Mana
	             Sickness (Shared/Mana.sicknessTicks: 5 s more, 10 s at most, through
	             Players/Effects); `damageFactor` is what magic damage is cut to while it lasts.
	  Crystals   `useCrystal` (a Mana Crystal used: Players/Magic's HeldUse) while fewer than
	             Config.Mana.MaxCrystals 9 were used: one more, max + 20 and mana + 20.
	  Off        with Config.Mana.Enabled false nothing ticks or is sent (the store still answers).

	  start       once, with the world's net.
	  export      { mana, crystals } to save.
	  peek        `export`, or nil when nothing is kept for the player (they left, or nothing
	              came yet): what a leaving player's character (Players/CharacterStore) or record
	              (World/WorldSave, characters off) is saved with. A leaving player is forgotten
	              only after every PlayerRemoving handler ran (task.defer).
	  restore     a saved character's mana and crystals (crystals 0..MaxCrystals; mana 0..Max now,
	              and within the character's own max, its accessories once restored too, from the
	              next tick).
	  get         mana and max mana.
	  spend       takes `amount` if there is that much (whether it did); a refusal is told.
	  dropCast    tells the player a cast was refused for another reason (see Message).
	  add         gives up to the max.
	  potion      a mana potion: `add` and Mana Sickness.
	  useCrystal  a Mana Crystal (whether it was used: false at nine).
	  casting     marks a free cast (creative), so the player isn't standing still this tick.
	  damageFactor  magic damage's share left by Mana Sickness (1 without).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local SharedEffects = require(Shared.Effects)
local SharedMana = require(Shared.Mana)
local MagicSync = require(Shared.Net.MagicSync)
local Protocol = require(Shared.Net.Protocol)

local Effects = require(script.Parent.Effects)
local Inventories = require(script.Parent.Inventories)
local PlayerPositions = require(script.Parent.PlayerPositions)

-- Only what Mana uses of ServerNet.ServerNet.
type Net = { send: (player: Player, kind: number, payload: buffer) -> () }

type State = {
	-- The regeneration's state (Shared/Mana: mana, delay) and the crystals used.
	regen: SharedMana.State,
	crystals: number,
	-- The feet where they last moved (nil: none yet), whether something was cast this tick, and
	-- ticks since the last move or cast (Shared/Mana.stillness).
	x: number?,
	y: number,
	z: number,
	cast: boolean,
	quiet: number,
	-- What the client was last told (whole mana, max), the tick it was, and flags to tell.
	sentMana: number,
	sentMax: number,
	sentTick: number,
	refused: boolean,
	full: boolean,
	dropped: boolean,
	-- A character came since the player joined (every later one is a respawn: it starts full).
	joined: boolean,
}

local Mana = {}

local TICK = 1 / 20
local MAX_TICKS_PER_FRAME = 4
-- Ticks between two regeneration messages to one player.
local SEND_TICKS = 4
-- Blocks the feet may move from where they last moved and still stand still.
local STILL = 0.01
local SICKNESS = SharedEffects.id.ManaSickness

local states: { [Player]: State } = {}
local net: Net? = nil
local tickCount = 0

local function stateOf(player: Player): State
	local state = states[player]
	if state == nil then
		state = {
			regen = SharedMana.new(Config.Mana.Base),
			crystals = 0,
			x = nil,
			y = 0,
			z = 0,
			cast = false,
			quiet = 0,
			sentMana = -1,
			sentMax = -1,
			sentTick = -math.huge,
			refused = false,
			full = false,
			dropped = false,
			joined = false,
		}
		-- (Not kept for a player who left: a late look must not bring them back to tick.)
		if player.Parent ~= nil then
			states[player] = state
		end
	end
	return state
end

-- The player's max mana now: the crystals and the accessories worn.
local function maxOf(player: Player, state: State): number
	local window = Inventories.get(player)
	return SharedMana.maxOf(state.crystals, if window then window.inventory else nil)
end

-- Tells the player their mana now (and the flags), and notes what was told.
local function send(player: Player, state: State, max: number)
	local current = net
	if current == nil or not Config.Mana.Enabled or player.Parent == nil then
		return
	end
	local mana = math.min(state.regen.mana, max)
	current.send(
		player,
		Protocol.ServerMessage.Mana,
		MagicSync.encodeMana({
			mana = mana,
			max = max,
			refused = state.refused,
			full = state.full,
			dropped = state.dropped,
		})
	)
	state.sentMana, state.sentMax, state.sentTick = math.floor(mana), max, tickCount
	state.refused, state.full, state.dropped = false, false, false
end

-- Clamps to the max now and tells the player at once.
local function sendNow(player: Player, state: State)
	local max = maxOf(player, state)
	SharedMana.clamp(state.regen, max)
	send(player, state, max)
end

local function tickPlayer(player: Player, state: State)
	local max = maxOf(player, state)
	local x, y, z = PlayerPositions.feet(player)
	local moved = state.cast or x == nil
	if x then
		local lastX = state.x
		local dx, dy, dz = if lastX then x - lastX else math.huge, y - state.y, z - state.z
		if dx * dx + dy * dy + dz * dz > STILL * STILL then
			moved = true
			state.x, state.y, state.z = x, y, z
		end
	end
	state.cast = false
	local still
	state.quiet, still = SharedMana.stillness(state.quiet, moved)
	if PlayerPositions.alive(player) then
		if SharedMana.tick(state.regen, max, still) then
			state.full = true
		end
	else
		SharedMana.clamp(state.regen, max)
	end
	local whole = math.floor(state.regen.mana)
	local changed = whole ~= state.sentMana or max ~= state.sentMax or state.full or state.refused
	if changed and tickCount - state.sentTick >= SEND_TICKS then
		send(player, state, max)
	end
end

--[[ API (see the header) ]]

function Mana.start(serverNet: Net)
	net = serverNet
	local function onCharacter(player: Player)
		local state = stateOf(player)
		if state.joined then
			-- (A respawn: full, as Terraria's.)
			state.regen.mana = maxOf(player, state)
			state.regen.delay = 0
		end
		state.joined = true
		state.x = nil
		sendNow(player, state)
	end
	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function()
			onCharacter(player)
		end)
		if player.Character then
			onCharacter(player)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		-- (After every other PlayerRemoving handler: a leaving player's character and record are
		-- saved with the mana and crystals kept here, a crystal used a moment ago included.)
		task.defer(function()
			states[player] = nil
		end)
	end)
	if not Config.Mana.Enabled then
		return
	end
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator = math.min(accumulator + dt, TICK * MAX_TICKS_PER_FRAME)
		while accumulator >= TICK do
			accumulator -= TICK
			tickCount += 1
			for player, state in states do
				tickPlayer(player, state)
			end
		end
	end)
end

function Mana.export(player: Player): { mana: number, crystals: number }
	local state = stateOf(player)
	return { mana = math.min(state.regen.mana, maxOf(player, state)), crystals = state.crystals }
end

function Mana.peek(player: Player): { mana: number, crystals: number }?
	if states[player] == nil then
		return nil
	end
	return Mana.export(player)
end

function Mana.restore(player: Player, mana: number, crystals: number)
	local state = stateOf(player)
	state.crystals = if crystals == crystals then math.clamp(math.floor(crystals), 0, Config.Mana.MaxCrystals) else 0
	-- (Within the character's own max at the next tick: its accessories may come back after this.)
	state.regen.mana = if mana == mana then math.clamp(mana, 0, Config.Mana.Max) else maxOf(player, state)
	state.regen.delay = 0
	send(player, state, maxOf(player, state))
end

function Mana.get(player: Player): (number, number)
	local state = stateOf(player)
	local max = maxOf(player, state)
	return math.min(state.regen.mana, max), max
end

function Mana.spend(player: Player, amount: number): boolean
	local state = stateOf(player)
	local max = maxOf(player, state)
	SharedMana.clamp(state.regen, max)
	if not SharedMana.spend(state.regen, max, amount) then
		state.refused = true
		send(player, state, max)
		return false
	end
	state.cast = true
	send(player, state, max)
	return true
end

function Mana.dropCast(player: Player)
	local state = stateOf(player)
	state.dropped = true
	sendNow(player, state)
end

function Mana.add(player: Player, amount: number)
	local state = stateOf(player)
	local max = maxOf(player, state)
	SharedMana.clamp(state.regen, max)
	if SharedMana.add(state.regen, max, amount) > 0 then
		send(player, state, max)
	end
end

function Mana.potion(player: Player, amount: number)
	Mana.add(player, amount)
	Effects.give(player, SICKNESS, SharedMana.sicknessTicks(Effects.ticks(player, SICKNESS)))
end

function Mana.useCrystal(player: Player): boolean
	local state = stateOf(player)
	if not SharedMana.canUseCrystal(state.crystals) then
		return false
	end
	state.crystals += 1
	local max = maxOf(player, state)
	SharedMana.add(state.regen, max, Config.Mana.PerCrystal)
	send(player, state, max)
	return true
end

function Mana.casting(player: Player)
	stateOf(player).cast = true
end

function Mana.damageFactor(player: Player): number
	return SharedMana.damageFactor(Effects.ticks(player, SICKNESS))
end

return Mana
