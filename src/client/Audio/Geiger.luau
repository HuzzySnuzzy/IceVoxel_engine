--!strict
--[[
	The Geiger counter's clicks (the fifth data sheet's ambient.radiation.click, "heard without an
	item"): while the server says this player is exposed (Shared/Radiation.RATE_ATTRIBUTE on the
	player: the rate in Sv/h after the Hazmat suit, from server Players/Radiation), one click at a
	random moment now and then, more often the higher the rate: a Poisson process, each frame
	clicking with the chance Radiation.clickRate(rate) x the frame's seconds (Radiation.clicks: at
	most one a frame, at most Config.Radiation.Clicks.Max a second). Flat, as the player's own
	(SoundPlayer.playFlat: the event is an interface one, `ui`), at the ambient sounds' volume.
	Nothing while the rate is absent: no exposure, creative or spectator, dead, radiation off.

	`rate()` is the rate as published (F3 shows it with the dose: `dose()`).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Radiation = require(Shared.Radiation)

local SoundPlayer = require(script.Parent.SoundPlayer)

local CLICK = "ambient.radiation.click"

local Geiger = {}

local function attribute(name: string): number
	local player = Players.LocalPlayer
	local value = if player then player:GetAttribute(name) else nil
	return if type(value) == "number" and value > 0 then value else 0
end

-- The exposure rate the server published (Sv/h; 0: none).
function Geiger.rate(): number
	return attribute(Radiation.RATE_ATTRIBUTE)
end

-- The dose the server published (Sv; 0: none).
function Geiger.dose(): number
	return attribute(Radiation.DOSE_ATTRIBUTE)
end

-- Starts the clicks.
function Geiger.start()
	local random = Random.new()
	RunService.Heartbeat:Connect(function(dt: number)
		local rate = Geiger.rate()
		if rate > 0 and Radiation.clicks(rate, dt, random:NextNumber()) then
			SoundPlayer.playFlat(CLICK)
		end
	end)
end

return Geiger
