--!strict
--[[
	Burning players as this player sees them (Minecraft's EntityRenderDispatcher.renderFlame and
	ScreenEffectRenderer.renderFire): the server marks a burning character with the attribute
	ON_FIRE (server Players/Characters: lava set it burning for 15 s, water puts it out), and every
	burning character gets flames (a Fire on its root part). The local player, in first person,
	also sees fire at the bottom of the screen (Minecraft's fire overlay), which in third person
	the flames on the body replace.

	Polled a few times a second over the players (a handful), so nothing is connected per
	character. `onFire` is pure (tests/spec/LavaOilClient). No flames for a player whose character
	isn't shown here (Player/RemotePlayers.shown: with the server's own positions, one this client
	isn't sent, parked far away).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local RemotePlayers = require(script.Parent.RemotePlayers)

local BurningView = {}

-- The character attribute the server sets while a player burns (server Players/Characters.ON_FIRE).
BurningView.ON_FIRE = "IceVoxelOnFire"
-- Seconds between two looks at the players.
local POLL = 0.1
-- The flames' size (studs, Fire.Size) and the overlay's height (share of the screen) and colours.
local FLAME_SIZE = 5
local OVERLAY_HEIGHT = 0.35
local FLAME_COLOUR = { 255, 140, 30 }
local FLAME_GLOW = { 255, 220, 90 }
-- The camera this close to the head counts as first person (studs).
local FIRST_PERSON = 1

-- Does the attribute value say the character burns?
function BurningView.onFire(value: any): boolean
	return value == true
end

local function colour(rgb: { number }): Color3
	return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

local function rootOf(character: Model): BasePart?
	local root = character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- Minecraft's fire overlay: a flickering orange glow rising from the bottom of the screen.
local function newOverlay(): (ScreenGui, Frame)
	-- (Screen-relative, over the whole screen, under everything else. Required here: the tests load
	-- this module without Roblox's instances.)
	local UiScale = require(script.Parent.Parent.Ui.UiScale)
	local gui: ScreenGui = UiScale.screenGui(
		"IceVoxelFireOverlay",
		"Fire",
		{ inset = true, full = true, kind = "screen", enabled = false }
	)
	local frame = Instance.new("Frame")
	frame.BorderSizePixel = 0
	frame.AnchorPoint = Vector2.new(0, 1)
	frame.Position = UDim2.fromScale(0, 1)
	frame.Size = UDim2.fromScale(1, OVERLAY_HEIGHT)
	frame.BackgroundColor3 = Color3.new(1, 1, 1)
	frame.Parent = gui
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 270
	gradient.Color = ColorSequence.new(colour(FLAME_COLOUR), colour(FLAME_GLOW))
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(0.6, 0.7),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = frame
	return gui, frame
end

function BurningView.start()
	local localPlayer = Players.LocalPlayer
	local flames: { [Model]: Fire } = {}
	local gui, overlay = newOverlay()
	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	local elapsed = 0
	local selfBurning = false
	RunService.Heartbeat:Connect(function(dt: number)
		elapsed += dt
		if elapsed >= POLL then
			elapsed = 0
			local seen: { [Model]: boolean } = {}
			selfBurning = false
			for _, player in Players:GetPlayers() do
				local character = player.Character
				if character and (player == localPlayer or RemotePlayers.shown(player)) then
					local burning = BurningView.onFire(character:GetAttribute(BurningView.ON_FIRE))
					local root = rootOf(character)
					if burning and root then
						seen[character] = true
						if player == localPlayer then
							selfBurning = true
						end
						local fire: Fire? = flames[character]
						if not fire or fire.Parent ~= root then
							if fire then
								fire:Destroy()
							end
							local made = Instance.new("Fire")
							made.Name = "IceVoxelFlames"
							made.Size = FLAME_SIZE
							made.Heat = 6
							made.Color = colour(FLAME_COLOUR)
							made.SecondaryColor = colour(FLAME_GLOW)
							made.Parent = root
							flames[character] = made
						end
					end
				end
			end
			for character, fire in flames do
				if not seen[character] then
					fire:Destroy()
					flames[character] = nil
				end
			end
		end
		-- The overlay only in first person (the camera at the head); it flickers a little.
		local camera = workspace.CurrentCamera
		local character = localPlayer.Character
		local head = character and character:FindFirstChild("Head")
		local firstPerson = camera ~= nil
			and head ~= nil
			and head:IsA("BasePart")
			and (camera.CFrame.Position - head.Position).Magnitude < FIRST_PERSON
		gui.Enabled = selfBurning and firstPerson
		if gui.Enabled then
			overlay.BackgroundTransparency = 0.15 + 0.1 * math.sin(os.clock() * 12)
		end
	end)
end

return BurningView
