--!strict
--[[
	Each player's mana (Terraria's: Config.Mana, Shared/Mana), kept by the server as health is.

	For now only the store and the API the rest of the game is written against: a player's mana and
	the Mana Crystals they used, which a character carries from world to world (server
	Players/CharacterStore: `export` into the record, `restore` from it). Regeneration, the HUD's
	message, casting and the crystals' use come with the mana itself (MANA: Shared/Mana,
	Players/Magic, Players/FallenStars).

	  start     forgets players who leave (call once, with the world's net).
	  export    { mana, crystals } to save.
	  restore   a saved character's mana and crystals (clamped: 0..max, 0..Config.Mana.MaxCrystals).
	  get       mana and max mana (Config.Mana.Base + PerCrystal x crystals, at most Config.Mana.Max;
	            accessories add to it once they work).
	  spend     takes `amount` if there is that much (whether it did).
	  add       gives up to the max.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)

type State = { mana: number, crystals: number }

local Mana = {}

local states: { [Player]: State } = {}

local function maxOf(state: State): number
	return math.min(Config.Mana.Base + Config.Mana.PerCrystal * state.crystals, Config.Mana.Max)
end

local function stateOf(player: Player): State
	local state = states[player]
	if state == nil then
		state = { mana = Config.Mana.Base, crystals = 0 }
		states[player] = state
	end
	return state
end

function Mana.start(_net: any)
	Players.PlayerRemoving:Connect(function(player: Player)
		states[player] = nil
	end)
end

function Mana.export(player: Player): { mana: number, crystals: number }
	local state = stateOf(player)
	return { mana = state.mana, crystals = state.crystals }
end

function Mana.restore(player: Player, mana: number, crystals: number)
	local state = stateOf(player)
	state.crystals = if crystals == crystals then math.clamp(math.floor(crystals), 0, Config.Mana.MaxCrystals) else 0
	state.mana = if mana == mana then math.clamp(mana, 0, maxOf(state)) else maxOf(state)
end

function Mana.get(player: Player): (number, number)
	local state = stateOf(player)
	return state.mana, maxOf(state)
end

function Mana.spend(player: Player, amount: number): boolean
	local state = stateOf(player)
	if amount ~= amount or amount < 0 or state.mana < amount then
		return false
	end
	state.mana -= amount
	return true
end

function Mana.add(player: Player, amount: number)
	local state = stateOf(player)
	if amount == amount and amount > 0 then
		state.mana = math.min(state.mana + amount, maxOf(state))
	end
end

return Mana
