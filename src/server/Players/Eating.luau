--!strict
--[[
	Eating and medicine on the server (Protocol Eat; the rules are Shared/Items/Foods, the client's
	hold is Interaction/Eating): Minecraft's use of a food, as Tough As Nails' drinking
	(Players/ToughAsNails) does it for drinks, and the zombie apocalypse's medical supplies used
	the same way.

	  start   the held item is a food the player may use now (Foods.canUse: hurt, bleeding for a
	          bandage, infected for antibiotics or a poultice, any time for a treat with effects,
	          creative whenever; never a spectator, never dead): the time, the hotbar slot and the
	          item are noted;
	  finish  the same item in the same slot, held at least its Foods.useTicks - FINISH_LEEWAY
	          ticks since `start`, and still usable: Foods.finish plays it out here, healing at
	          once (its half hearts scaled to the Humanoid's MaxHealth, as every hurt is), curing
	          (Players/Effects.remove: the Infection goes to its owner, server
	          Apocalypse/Infection.cure), setting an infection back a stage (Infection.setBack:
	          the Herbal Poultice), giving its status effects and Antibiotics' Weakness after a
	          late cure (Players/Effects.give; the stage before the cure is
	          Infection.stage's) and rolling Tough As Nails' Thirst effect for raw chicken,
	          rotten flesh and crackers when thirst is on (Shared/ToughAsNails/Thirst.giveEffect
	          on the player's state); then it is used up (one item, not in creative); everyone
	          else hears the burp (entity.player.burp), or medicine's own sound (Foods `sound`:
	          the user's client played it as the use started);
	  cancel  let go early: forgotten.
	Sounds a player's requests cause use their budget (Audio/Sounds.allow).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Foods = require(Shared.Items.Foods)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Protocol = require(Shared.Net.Protocol)
local SharedToughAsNails = require(Shared.ToughAsNails)
local Thirst = require(Shared.ToughAsNails.Thirst)

local Sounds = require(script.Parent.Parent.Audio.Sounds)
local Infection = require(script.Parent.Parent.Apocalypse.Infection)
local EffectsServer = require(script.Parent.Effects)
local Inventories = require(script.Parent.Inventories)
local ToughAsNails = require(script.Parent.ToughAsNails)

-- Only what Eating uses of ServerNet.ServerNet.
type Net = { on: (kind: number, handler: (player: Player, payload: buffer) -> ()) -> () }

local TICK = 1 / 20
-- Ticks a food may finish early (the client's clock and the network's jitter).
local FINISH_LEEWAY = 4
-- Minecraft players have 20 health points (half hearts).
local HEALTH = 20

local Eating = {}

type Holding = { started: number, slot: number, item: number }
local eating: { [Player]: Holding } = {}
local random = Random.new()

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		return humanoid
	end
	return nil
end

local function selectedSlot(player: Player): number?
	local window = Inventories.get(player)
	return if window then window.inventory.selected else nil
end

-- May the player use `item` now?
local function mayEat(player: Player, humanoid: Humanoid, item: number?): boolean
	local food = Foods.of(item)
	if food == nil then
		return false
	end
	return Foods.canUse(food, humanoid.Health, humanoid.MaxHealth, GameMode.of(player), function(name: string): boolean
		return EffectsServer.has(player, name)
	end)
end

-- Plays out `food` finishing for `player` (Foods.finish's hooks; see the header).
local function finish(player: Player, humanoid: Humanoid, food: Foods.Food)
	Foods.finish(food, {
		heal = function(halfHearts: number)
			humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + halfHearts / HEALTH * humanoid.MaxHealth)
		end,
		cure = function(name: string)
			EffectsServer.remove(player, name)
		end,
		setBack = function()
			Infection.setBack(player)
		end,
		infectionStage = function(): number
			return Infection.stage(player)
		end,
		give = function(effect: number, ticks: number, amplifier: number)
			EffectsServer.give(player, effect, ticks, amplifier)
		end,
		thirst = function(ticks: number)
			local thirst = ToughAsNails.state(player)
			if thirst and SharedToughAsNails.thirstOn() then
				Thirst.giveEffect(thirst, ticks)
			end
		end,
		random = function(): number
			return random:NextNumber()
		end,
	})
end

local function onEat(player: Player, payload: buffer)
	local action = Protocol.decodeEat(payload)
	local humanoid = humanoidOf(player)
	if action == nil or humanoid == nil then
		eating[player] = nil
		return
	end
	local actions = Protocol.EatAction
	local held = Inventories.heldStack(player)
	local now = os.clock()
	if action == actions.Cancel then
		eating[player] = nil
	elseif action == actions.Start then
		eating[player] = nil
		local slot = selectedSlot(player)
		if held and slot and mayEat(player, humanoid, held.item) then
			eating[player] = { started = now, slot = slot, item = held.item }
		end
	else
		local holding = eating[player]
		eating[player] = nil
		local food = Foods.of(held and held.item)
		if
			holding == nil
			or held == nil
			or food == nil
			or held.item ~= holding.item
			or selectedSlot(player) ~= holding.slot
			or now - holding.started < (Foods.useTicks(food) - FINISH_LEEWAY) * TICK
			or not mayEat(player, humanoid, held.item)
		then
			return
		end
		finish(player, humanoid, food)
		if not GameMode.instabuild(GameMode.of(player)) then
			Inventories.setHeld(player, if held.count > 1 then Items.withCount(held, held.count - 1) else nil)
		end
		if Sounds.allow(player) then
			local sound = if Foods.isMedical(food) then food.sound else Foods.BURP
			if sound then
				Sounds.playAt(player, sound, player)
			end
		end
	end
end

function Eating.start(net: Net)
	net.on(Protocol.ClientMessage.Eat, onEat)
	Players.PlayerRemoving:Connect(function(player)
		eating[player] = nil
	end)
end

return Eating
