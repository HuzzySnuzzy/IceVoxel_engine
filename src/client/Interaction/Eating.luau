--!strict
--[[
	Eating and medicine on this player's client, for Interaction/BlockInteraction: a right click
	with a food in hand (Shared/Items/Foods: the meat mobs drop, cooked or raw, rotten flesh, the
	ruins' tins and treats, and the zombie apocalypse's medical supplies), when no block's menu
	takes the click, starts Minecraft's hold of the use button, as Interaction/Drinking does for
	drinks:

	  start   Eat start, then while the use button stays down (`stop` when it is let go), the same
	          item in the same hotbar slot, no screen open and the player alive, the food's
	          Foods.useTicks (32 for Minecraft's food) count at 20 a second; at the end, Eat
	          finish and the burp (entity.player.burp). Anything else cancels it (Eat cancel).
	          While it lasts the eating loop plays at the player (Audio/UseSounds, from
	          `useLength`; Minecraft's bites, entity.generic.eat every 4 ticks from the 7th, only
	          when the loop's recording fails to load). Medicine (Foods.isMedical) plays its own
	          sound (Foods `sound`: item.bandage.apply, item.medkit.use, item.pills.swallow) as
	          the use starts, instead of the loop and the burp; the server plays it to everyone
	          else when it finishes.
	Only when the player may use it (Foods.canUse, with the effects this client was told of,
	Player/EffectState, and the food bar, Player/SurvivalState, while Minecraft's hunger is on: a
	food while the bar isn't full; with hunger off hurt; bleeding for a bandage, infected for
	antibiotics or a poultice, hurt for the rest of medicine, any time for a treat with effects,
	creative whenever; never a spectator). Nothing is predicted: the server's inventory snapshot
	brings the used item, the food bar comes back in the next Survival message and the health with
	the character's.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Effects = require(Shared.Effects)
local Foods = require(Shared.Items.Foods)
local Items = require(Shared.Items)
local Protocol = require(Shared.Net.Protocol)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local EffectState = require(script.Parent.Parent.Player.EffectState)
local SurvivalState = require(script.Parent.Parent.Player.SurvivalState)
local MovementController = require(script.Parent.Parent.Player.MovementController)
local Screens = require(script.Parent.Parent.Ui.Screens)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)

local Eating = {}

local TICK = 1 / 20
-- The sounds medicine plays here (Foods `sound`): checked against the table as this loads, so a
-- food naming a sound this client doesn't play fails at once.
local MEDICINE_SOUNDS: { [string]: boolean } = {
	["item.bandage.apply"] = true,
	["item.medkit.use"] = true,
	["item.pills.swallow"] = true,
}
for item, food in Foods.ITEMS do
	assert(food.sound == nil or MEDICINE_SOUNDS[food.sound], `Food {item}'s sound {food.sound} is not played here`)
end

type Holding = { slot: number, item: number, elapsed: number, ticks: number, length: number, food: Foods.Food }
local holding: Holding? = nil
local started = false

-- Plays `sound` at this player's mouth (the drawn hull's feet, world blocks: MovementController).
local function play(sound: string)
	local view = MovementController.current
	if view then
		SoundPlayer.play(sound, view.feetX, view.feetY + 1.5, view.feetZ)
	end
end

local function cancel()
	if holding then
		holding = nil
		ClientNet.send(Protocol.ClientMessage.Eat, Protocol.encodeEat(Protocol.EatAction.Cancel))
	end
end

-- Is the player eating?
function Eating.isEating(): boolean
	return holding ~= nil
end

-- The ticks the food being eaten lasts while it sounds like eating (the loop, Audio/UseSounds),
-- nil when nothing is eaten or it is medicine (which plays its own sound).
function Eating.useLength(): number?
	local current = holding
	if current == nil or Foods.isMedical(current.food) then
		return nil
	end
	return current.length
end

-- How far the food has got (0..1), nil when none.
function Eating.progress(): number?
	local current = holding
	return if current then math.min(current.ticks / current.length, 1) else nil
end

-- Is `stack` food?
function Eating.handles(stack: Items.Stack?): boolean
	return stack ~= nil and Foods.isFood(stack.item)
end

-- Has this player effect `name` (as the server last said)?
local function has(name: string): boolean
	local id = Effects.id[name]
	return id ~= nil and (EffectState.get(id)) ~= nil
end

-- May the player use `food` now (their character's health, game `mode`)?
local function mayEat(food: Foods.Food, mode: string): boolean
	local character = Players.LocalPlayer.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid == nil or humanoid.Health <= 0 then
		return false
	end
	return Foods.canUse(food, humanoid.Health, humanoid.MaxHealth, mode, has, SurvivalState.foodLevel())
end

-- A right click with `stack` in game `mode`: starts eating it. Returns whether it did.
function Eating.use(stack: Items.Stack?, mode: string): boolean
	local food = if stack then Foods.of(stack.item) else nil
	if holding or stack == nil or food == nil or not mayEat(food, mode) then
		return false
	end
	holding = {
		slot = ClientInventory.selected(),
		item = stack.item,
		elapsed = 0,
		ticks = 0,
		length = Foods.useTicks(food),
		food = food,
	}
	ClientNet.send(Protocol.ClientMessage.Eat, Protocol.encodeEat(Protocol.EatAction.Start))
	if Foods.isMedical(food) and food.sound then
		play(food.sound)
	end
	return true
end

-- The use button was let go: a food not finished yet is put away.
function Eating.stop()
	cancel()
end

-- Is this player's character alive?
local function alive(): boolean
	local character = Players.LocalPlayer.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	return humanoid ~= nil and humanoid.Health > 0
end

local function update(dt: number)
	local current = holding
	if current == nil then
		return
	end
	local stack = ClientInventory.selectedStack()
	if
		Screens.isOpen()
		or ClientInventory.selected() ~= current.slot
		or stack == nil
		or stack.item ~= current.item
		or not alive()
	then
		cancel()
		return
	end
	local medical = Foods.isMedical(current.food)
	current.elapsed += dt
	while current.ticks < current.length and current.elapsed >= (current.ticks + 1) * TICK do
		current.ticks += 1
		if current.ticks == current.length then
			holding = nil
			ClientNet.send(Protocol.ClientMessage.Eat, Protocol.encodeEat(Protocol.EatAction.Finish))
			if not medical then
				play("entity.player.burp")
			end
			return
		end
	end
end

function Eating.start()
	if started then
		return
	end
	started = true
	RunService.Heartbeat:Connect(update)
end

return Eating
