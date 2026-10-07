--!strict
--[[
	Eating on the server (Protocol Eat; the rules are Shared/Items/Foods, the client's hold is
	Interaction/Eating): Minecraft's 32 tick use of a food, as Tough As Nails' drinking
	(Players/ToughAsNails) does it for drinks.

	  start   the held item is a food the player may eat now (Foods.canEat: hurt, or creative; not
	          a spectator, not dead): the time, the hotbar slot and the item are noted;
	  finish  the same item in the same slot, held at least Foods.USE_TICKS - FINISH_LEEWAY ticks
	          since `start`, and still edible: the food heals at once (its half hearts scaled to
	          the Humanoid's MaxHealth, as every hurt is), rolls its effect (Tough As Nails'
	          Thirst effect for raw chicken and rotten flesh, when thirst is on:
	          Shared/ToughAsNails/Thirst.giveEffect on the player's state) and is used up (one
	          item, not in creative); everyone else hears the burp (entity.player.burp: the eater's
	          client plays its own bites and burp);
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

-- May the player eat `item` now?
local function mayEat(player: Player, humanoid: Humanoid, item: number?): boolean
	return Foods.isFood(item) and Foods.canEat(humanoid.Health, humanoid.MaxHealth, GameMode.of(player))
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
		if
			holding == nil
			or held == nil
			or held.item ~= holding.item
			or selectedSlot(player) ~= holding.slot
			or now - holding.started < (Foods.USE_TICKS - FINISH_LEEWAY) * TICK
			or not mayEat(player, humanoid, held.item)
		then
			return
		end
		local food = Foods.of(held.item) :: Foods.Food
		local heal, effectTicks = Foods.eat(food, function(): number
			return random:NextNumber()
		end)
		humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + heal / HEALTH * humanoid.MaxHealth)
		if effectTicks > 0 and food.effect and food.effect.kind == "thirst" then
			local thirst = ToughAsNails.state(player)
			if thirst and SharedToughAsNails.thirstOn() then
				Thirst.giveEffect(thirst, effectTicks)
			end
		end
		if not GameMode.instabuild(GameMode.of(player)) then
			Inventories.setHeld(player, if held.count > 1 then Items.withCount(held, held.count - 1) else nil)
		end
		if Sounds.allow(player) then
			Sounds.playAt(player, Foods.BURP, player)
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
