--!strict
--[[
	Status effects on the server: every living player's effects (the rules are Players/
	EffectRules, pure and tested; this keeps one state per character, sends it and runs /effect),
	and the API the rest of the game calls.

	  Ticks      Players/Characters drives them at 20 a second with lava and burning, for every
	             living player: `touchFluids` (the fluids' effects: oil, fuel, water washing),
	             then `fireRules` for Players/Burning, then `tick` (Regeneration, Poison, Wither,
	             the instant effects, the countdown), whose hurt and healing Characters applies
	             (the hurt through its cooldown, without armor, with Resistance: `incomingDamage`).
	             `tick` also reads the external effects (`addExternal`), puts the Glowing outline
	             on or off and sends the player their effects when the client's view is off
	             (EffectRules.needsSync: Protocol Effects).
	  Death      a new character starts with none (Minecraft's respawned player), and the client
	             is told at once.
	  Saved      a saved world keeps each player's running effects (`export`) and gives them back
	             on the returning player's character (`restore`, World/WorldSave), as Minecraft
	             keeps them in the player's data.
	  Glowing    a Highlight ("IceVoxelGlowing", outline only, seen through walls) in the character
	             while it lasts: Roblox replicates it to everyone, as Minecraft's glowing outline.
	  /effect    Players/EffectCommand's rules with the operators' permission (Players/Operators,
	             as /time); answers go to the chat as Notice messages. With TextChatService a
	             TextChatCommand, else Player.Chatted.

	API (server modules; `effect` is an Effects id or a name Effects.find knows, "Speed",
	"jump_boost"):
	  give(player, effect, ticks, amplifier?, ambient?) -> boolean   (MobEffectInstance.update)
	  giveAll(player, { { effect, ticks, amplifier? } })   a potion's or a drink's effects
	  remove(player, effect) -> boolean,  clear(player) -> number
	  has(player, effect) -> boolean,  amplifier(player, effect) -> number?
	  ticks(player, effect) -> number   ticks left (0: none), a status effect's own (Mana Sickness)
	  levels(player) -> Effects.Levels (read only)
	  meleeDamage(player, base) -> number   a melee hit with Strength and Weakness (combat)
	  incomingDamage(player, amount) -> number   what Resistance lets through of a hurt
	  fireRules(player) -> Effects.FireRules?   Players/Burning's
	  fallReduction(player) -> number   blocks of fall Jump Boost takes off before fall damage
	  miningFactor(player) -> number   Haste and Mining Fatigue (ServerNet's mining check)
	  addExternal(effect, adapter)   an effect kept elsewhere (Tough As Nails), see External
	Non-player entities (mobs) can use the same rules: an EffectRules state each, ticked with
	EffectRules.tick, and Shared/Effects' modifiers on EffectRules.levels; nothing here is tied to
	players but the sending.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local WorldSettings = require(Shared.WorldSettings)
local Effects = require(Shared.Effects)
local Protocol = require(Shared.Net.Protocol)

local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local EffectCommand = require(script.Parent.EffectCommand)
local EffectRules = require(script.Parent.EffectRules)
local Operators = require(script.Parent.Operators)

--[[
	An effect kept by another module (Effects `external`): `get` its ticks left for a player (0 or
	nil: none; read every tick), `paused` whether the owner holds it for now (it doesn't count
	down: the client is told to keep its time), `give` it for at least `ticks` (/effect give; the
	owner's own rule, a longer one stays), `clear` it (/effect clear). Only `get` is needed.
]]
export type Adapter = {
	get: (player: Player) -> number?,
	paused: ((player: Player) -> boolean)?,
	give: ((player: Player, ticks: number) -> ())?,
	clear: ((player: Player) -> ())?,
}

local EffectsServer = {}

-- The Highlight a glowing character carries.
EffectsServer.GLOWING = "IceVoxelGlowing"

local states: { [Player]: EffectRules.State } = {}
local adapters: { [number]: Adapter } = {}
local net: ServerNet.ServerNet? = nil
local EMPTY: Effects.Levels = table.freeze({})
local GLOWING = Effects.id.Glowing

-- The effect id `effect` names (an id, or a name Effects.find knows).
local function idOf(effect: number | string): number?
	if type(effect) == "number" then
		return if Effects.isValid(effect) then effect else nil
	end
	return Effects.find(effect)
end

local function stateOf(player: Player): EffectRules.State
	local state = states[player]
	if state == nil then
		state = EffectRules.new()
		states[player] = state
	end
	return state
end

local function send(player: Player, state: EffectRules.State)
	local network = net
	if network == nil or player.Parent == nil then
		return
	end
	local entries = EffectRules.entries(state)
	EffectRules.markSent(state, entries)
	network.send(player, Protocol.ServerMessage.Effects, Protocol.encodeEffects(entries))
end

-- The Glowing outline on or off (see the header).
local function updateGlowing(player: Player, state: EffectRules.State)
	local character = player.Character
	if character == nil then
		return
	end
	local glowing = EffectRules.has(state, GLOWING)
	local highlight = character:FindFirstChild(EffectsServer.GLOWING)
	if glowing and highlight == nil then
		local new = Instance.new("Highlight")
		new.Name = EffectsServer.GLOWING
		new.FillTransparency = 1
		new.OutlineColor = Color3.new(1, 1, 1)
		new.OutlineTransparency = 0
		new.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		new.Parent = character
	elseif not glowing and highlight then
		highlight:Destroy()
	end
end

--[[ API ]]

--[[
	Gives `player` effect `effect` for `ticks` (Effects.INFINITE: for good) at `amplifier`
	(default 0, level I). Returns whether it took (a new effect, or MobEffectInstance.update
	changed the running one). An external effect goes to its owner (`give` of its adapter).
]]
function EffectsServer.give(
	player: Player,
	effect: number | string,
	ticks: number,
	amplifier: number?,
	ambient: boolean?
): boolean
	local id = idOf(effect)
	local def = if id then Effects.get(id) else nil
	if id == nil or def == nil then
		return false
	end
	if def.external then
		local adapter = adapters[id]
		local giveExternal = adapter and adapter.give
		if giveExternal == nil or not (ticks > 0 or ticks == Effects.INFINITE) then
			return false
		end
		local before = adapter.get(player) or 0
		giveExternal(player, if ticks == Effects.INFINITE then 2 ^ 31 - 1 else ticks)
		return (adapter.get(player) or 0) ~= before
	end
	return EffectRules.give(stateOf(player), id, ticks, amplifier, ambient)
end

-- Gives every effect of `list` ({ effect, ticks, amplifier? }: a potion's, Shared/ToughAsNails/
-- Drinks `effects`). Returns how many took.
function EffectsServer.giveAll(player: Player, list: { { effect: number, ticks: number, amplifier: number? } }): number
	local count = 0
	for _, given in list do
		if EffectsServer.give(player, given.effect, given.ticks, given.amplifier) then
			count += 1
		end
	end
	return count
end

-- Takes effect `effect` off `player`. Returns whether they had it.
function EffectsServer.remove(player: Player, effect: number | string): boolean
	local id = idOf(effect)
	local def = if id then Effects.get(id) else nil
	if id == nil or def == nil then
		return false
	end
	if def.external then
		local adapter = adapters[id]
		local had = adapter ~= nil and (adapter.get(player) or 0) ~= 0
		if had and adapter.clear then
			adapter.clear(player)
			return true
		end
		return false
	end
	local state = states[player]
	return state ~= nil and EffectRules.remove(state, id)
end

-- Takes every effect off `player` (the external ones too, where their owners allow). Returns how
-- many there were.
function EffectsServer.clear(player: Player): number
	local state = states[player]
	local count = if state then EffectRules.clear(state) else 0
	for id, adapter in adapters do
		if (adapter.get(player) or 0) ~= 0 and adapter.clear then
			adapter.clear(player)
			count += 1
			if state then
				EffectRules.setExternal(state, id, 0)
			end
		end
	end
	return count
end

-- Has `player` effect `effect` (an external one too)?
function EffectsServer.has(player: Player, effect: number | string): boolean
	return EffectsServer.amplifier(player, effect) ~= nil
end

-- The amplifier of `player`'s effect `effect` (nil: they haven't it).
function EffectsServer.amplifier(player: Player, effect: number | string): number?
	local id = idOf(effect)
	if id == nil then
		return nil
	end
	local adapter = adapters[id]
	if adapter then
		return if (adapter.get(player) or 0) ~= 0 then 0 else nil
	end
	local state = states[player]
	return if state then EffectRules.amplifier(state, id) else nil
end

-- Ticks left of `player`'s effect `effect` (0: they haven't it; Effects.INFINITE: for good). Not
-- for external effects (their owners keep the time). Players/Mana reads Mana Sickness's.
function EffectsServer.ticks(player: Player, effect: number | string): number
	local id = idOf(effect)
	local state = states[player]
	local instance = if id and state then EffectRules.get(state, id) else nil
	return if instance then instance.ticks else 0
end

-- The levels in force for `player` (read only).
function EffectsServer.levels(player: Player): Effects.Levels
	local state = states[player]
	return if state then EffectRules.levels(state) else EMPTY
end

-- A melee hit of `base` half hearts by `player`, with their Strength and Weakness.
function EffectsServer.meleeDamage(player: Player, base: number): number
	return Effects.meleeDamage(base, EffectsServer.levels(player))
end

-- What `player`'s Resistance lets through of a hurt of `amount` half hearts.
function EffectsServer.incomingDamage(player: Player, amount: number): number
	return Effects.incomingDamage(amount, EffectsServer.levels(player))
end

-- How fire treats `player` (Players/Burning; nil: as anyone).
function EffectsServer.fireRules(player: Player): Effects.FireRules?
	return Effects.fireRules(EffectsServer.levels(player))
end

-- Blocks of a fall `player`'s Jump Boost takes off before fall damage counts.
function EffectsServer.fallReduction(player: Player): number
	local _, fall = Effects.jumpBoost(EffectsServer.levels(player))
	return fall
end

-- `player`'s mining speed multiplier (Haste, Mining Fatigue).
function EffectsServer.miningFactor(player: Player): number
	return Effects.miningFactor(EffectsServer.levels(player))
end

-- Registers the owner of external effect `effect` (see Adapter).
function EffectsServer.addExternal(effect: number, adapter: Adapter)
	local def = Effects.get(effect)
	assert(def and def.external, `Effect {effect} is not external`)
	adapters[effect] = adapter
end

--[[ Ticks (Players/Characters) ]]

-- The fluids' effects for one tick (EffectRules.touchFluids: `touching` and `eyes` are
-- Players/Burning masks).
function EffectsServer.touchFluids(player: Player, touching: number, eyes: number, mode: string)
	if Config.Effects.FluidEffects then
		EffectRules.touchFluids(stateOf(player), touching, eyes, mode)
	end
end

--[[
	One tick of `player`'s effects in game `mode` with `health` of `maxHealth` half hearts (see
	the header). Returns the half hearts their effects hurt and heal.
]]
function EffectsServer.tick(player: Player, mode: string, health: number, maxHealth: number): (number, number)
	local state = stateOf(player)
	local damage, heal = EffectRules.tick(state, mode, health, maxHealth)
	for id, adapter in adapters do
		local paused = adapter.paused
		EffectRules.setExternal(state, id, adapter.get(player) or 0, paused ~= nil and paused(player))
	end
	updateGlowing(player, state)
	if EffectRules.needsSync(state) then
		send(player, state)
	end
	return damage, heal
end

--[[ /effect ]]

local function notify(player: Player, text: string)
	local network = net
	if network and player.Parent then
		network.send(player, Protocol.ServerMessage.Notice, Protocol.encodeNotice(text))
	end
end

local function run(player: Player, text: string)
	if not EffectCommand.matches(text) then
		return
	end
	if player.Parent == nil then
		return
	end
	local mayUse = Operators.permitted(player)
	local candidates: { EffectCommand.Candidate } = {}
	local source: EffectCommand.Candidate? = nil
	for _, other in Players:GetPlayers() do
		local candidate = { key = other, name = other.Name, displayName = other.DisplayName }
		table.insert(candidates, candidate)
		if other == player then
			source = candidate
		end
	end
	if source == nil then
		return
	end
	local result = EffectCommand.run(text, {
		source = source,
		players = candidates,
		mayUse = mayUse,
		give = function(key: any, effect: number, ticks: number, amplifier: number): boolean
			local target = key :: Player
			local character = target.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			-- (Minecraft gives nothing to the dead.)
			if humanoid == nil or humanoid.Health <= 0 then
				return false
			end
			return EffectsServer.give(target, effect, ticks, amplifier)
		end,
		clear = function(key: any, effect: number?): number
			local target = key :: Player
			if effect then
				return if EffectsServer.remove(target, effect) then 1 else 0
			end
			return EffectsServer.clear(target)
		end,
	})
	if result then
		for _, message in result.feedback do
			notify(player, message)
		end
	end
end

local function listen()
	if TextChatService.ChatVersion == Enum.ChatVersion.LegacyChatService then
		local function onPlayer(player: Player)
			player.Chatted:Connect(function(message: string)
				run(player, message)
			end)
		end
		Players.PlayerAdded:Connect(onPlayer)
		for _, player in Players:GetPlayers() do
			onPlayer(player)
		end
		return
	end
	local command = Instance.new("TextChatCommand")
	command.Name = "IceVoxelEffect"
	command.PrimaryAlias = EffectCommand.ALIASES[1]
	-- (The operators' permission: the chat suggests it to those who have it.)
	command:SetAttribute(WorldSettings.COMMAND_ATTRIBUTE, WorldSettings.COMMAND_PERMITTED)
	command.Triggered:Connect(function(source: TextSource, text: string)
		local player = Players:GetPlayerByUserId(source.UserId)
		if player then
			run(player, text)
		end
	end)
	-- Commands work when parented to TextChatService (replicated, so clients sink the message).
	command.Parent = TextChatService
end

--[[ Saving (World/WorldSave) ]]

export type Saved = { effect: number, amplifier: number, ticks: number, ambient: boolean }

-- Effects waiting for a player's next character (a saved player's).
local restored: { [Player]: { Saved } } = {}

-- The running effects a save keeps (not the external ones: their owners keep those); nil when
-- the player has no character's effects (gone, or not in the world yet).
function EffectsServer.export(player: Player): { Saved }?
	local state = states[player]
	if state == nil then
		return nil
	end
	local list: { Saved } = {}
	for id, instance in state.active do
		if Effects.list[id].instant == nil then
			table.insert(
				list,
				{ effect = id, amplifier = instance.amplifier, ticks = instance.ticks, ambient = instance.ambient }
			)
		end
	end
	return list
end

local function giveSaved(player: Player, list: { Saved })
	local state = stateOf(player)
	for _, saved in list do
		if Effects.isValid(saved.effect) and not (Effects.get(saved.effect) :: any).external then
			EffectRules.give(state, saved.effect, saved.ticks, saved.amplifier, saved.ambient)
		end
	end
	send(player, state)
end

-- A saved player's effects: on the standing character, else on their next one.
function EffectsServer.restore(player: Player, list: { Saved })
	if player.Character and states[player] then
		giveSaved(player, list)
	else
		restored[player] = list
	end
end

--[[
	Starts the effects: new characters start clean (and their clients are told), leaving players
	are forgotten, and /effect listens.
]]
function EffectsServer.start(serverNet: ServerNet.ServerNet)
	assert(net == nil, "Effects.start was already called")
	net = serverNet
	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function()
			-- (Death clears every effect: a new character starts with none.)
			local state = EffectRules.new()
			states[player] = state
			send(player, state)
			-- (A saved player's effects come back on their first character.)
			local saved = restored[player]
			if saved then
				restored[player] = nil
				giveSaved(player, saved)
			end
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
		restored[player] = nil
	end)
	listen()
end

return EffectsServer
