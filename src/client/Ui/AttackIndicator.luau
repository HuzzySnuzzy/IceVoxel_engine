--!strict
--[[
	Minecraft's attack indicator (the Attack Indicator setting: OFF, Crosshair, Hotbar): how far
	the held weapon has recovered since the last hit, Shared/Entities/Combat.strength (1.9's
	attack strength: a sword 12.5 ticks, an axe 20-25, the hand 5), shown only while it is below
	full, as Minecraft's Gui.renderCrosshair / renderHotbar do.

	  Crosshair  a 16 x 4 bar 9 GUI pixels under where the player aims (the screen centre, or the
	             mouse while it is free: Interaction/BlockInteraction's aim), its light part
	             (strength x 17) growing to the right, scaled like the HUD.
	  Hotbar     an 18 x 18 square right of the hotbar filling from the bottom (Ui/Hud.
	             setAttackIndicator).

	The recovery starts over as the server's does (server Mobs: a hit that lands, a change of the
	held item): at each attack sent (`attacked`, from BlockInteraction) and when the selected
	stack's item changes. Nothing for spectators, with a screen open or the HUD hidden.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Combat = require(Shared.Entities.Combat)
local GameMode = require(Shared.GameMode)

local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local Hud = require(script.Parent.Hud)
local Screens = require(script.Parent.Screens)
local UiScale = require(script.Parent.UiScale)

local AttackIndicator = {}

AttackIndicator.OFF, AttackIndicator.CROSSHAIR, AttackIndicator.HOTBAR = 0, 1, 2

local TICKS_PER_SECOND = 20
-- Minecraft's crosshair indicator: 16 x 4, its top 9 GUI pixels under the aim (height / 2 - 7 +
-- 16 from the screen's top, the crosshair being 15 tall), filled (strength x 17) pixels.
local BAR_W, BAR_H, BAR_BELOW = 16, 4, 9
local BACKGROUND = Color3.fromRGB(60, 60, 60)
local FILL = Color3.fromRGB(230, 230, 230)

local mode = AttackIndicator.CROSSHAIR
local started = false
-- os.clock() of the last attack and of the last change of the held item, and that item.
local attackedAt = -math.huge
local changedAt = -math.huge
local heldItem: number? = nil

-- The Attack Indicator setting (OFF, CROSSHAIR or HOTBAR).
function AttackIndicator.setMode(value: number)
	mode = value
	if value ~= AttackIndicator.HOTBAR then
		Hud.setAttackIndicator(nil)
	end
end

-- An attack was sent: the weapon starts recovering.
function AttackIndicator.attacked()
	attackedAt = os.clock()
end

-- The held weapon's recovery now (0..1).
function AttackIndicator.strength(): number
	local since = math.max(attackedAt, changedAt)
	local _, speed = Combat.attackOf(heldItem)
	return Combat.strength((os.clock() - since) * TICKS_PER_SECOND, speed)
end

function AttackIndicator.start()
	if started then
		return
	end
	started = true
	-- (The whole screen: the aim is in viewport pixels, as the crosshair's centre.)
	local gui =
		UiScale.screenGui("IceVoxelAttackIndicator", "AttackBar", { inset = true, full = true, kind = "scaled" })
	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.BorderSizePixel = 0
	bar.BackgroundColor3 = BACKGROUND
	bar.BackgroundTransparency = 0.2
	bar.Visible = false
	bar.Parent = gui
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BorderSizePixel = 0
	fill.BackgroundColor3 = FILL
	fill.Parent = bar
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local lastFill = -1
	RunService.RenderStepped:Connect(function()
		local stack = ClientInventory.selectedStack()
		local item = if stack then stack.item else nil
		if item ~= heldItem then
			heldItem = item
			changedAt = os.clock()
		end
		local shown = mode ~= AttackIndicator.OFF
			and not Screens.isOpen()
			and not GameMode.isSpectator(ClientInventory.mode())
		local strength = if shown then AttackIndicator.strength() else 1
		local recovering = strength < 1

		Hud.setAttackIndicator(if mode == AttackIndicator.HOTBAR and recovering then strength else nil)

		local onCrosshair = mode == AttackIndicator.CROSSHAIR and recovering
		if bar.Visible ~= onCrosshair then
			bar.Visible = onCrosshair
		end
		if not onCrosshair then
			return
		end
		local viewport = UiScale.viewport()
		local scale = UiScale.base()
		-- The aim: the mouse while it is free and the input, else the centre (as BlockInteraction).
		local aim = Vector2.new(viewport.X / 2, viewport.Y / 2)
		if
			UserInputService.PreferredInput == Enum.PreferredInput.KeyboardAndMouse
			and UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter
		then
			aim = UserInputService:GetMouseLocation()
		end
		local w, h = BAR_W * scale, BAR_H * scale
		bar.Size = UDim2.fromOffset(w, h)
		bar.Position = UDim2.fromOffset(math.floor(aim.X - w / 2), math.floor(aim.Y + BAR_BELOW * scale))
		local filled = math.min(BAR_W, math.floor(strength * 17))
		if filled ~= lastFill then
			lastFill = filled
			fill.Size = UDim2.fromScale(filled / BAR_W, 1)
		end
	end)
end

return AttackIndicator
