--!strict
--[[
	The title screen's rules (Minecraft's TitleScreen and SplashRenderer) without the Roblox parts
	(Ui/MainMenu), so the tests can run them.

	  Splash    the yellow line by the logo: one of SPLASHES picked at random each time the title
	            screen is built, or the day's, on Minecraft's dates (SplashManager: December 24-26
	            "Merry X-mas!", January 1 "Happy new year!", October 31 "OOoooOOOoooo! Spooky!").
	  Pulse     SplashRenderer: 1.8 - |sin(2 pi t)| x 0.1 with t the second's fraction, then x 100 /
	            (text width + 32) so a long splash is drawn smaller; turned -20 degrees, centred 90
	            GUI pixels right of the screen's middle, 70 down.
	  Buttons   what the screen offers (`buttons`): Join World once the world exists, Create World
	            and Load World for an operator while there is none (`operator`: the Player
	            attribute WorldSettings.OPERATOR_ATTRIBUTE; Load World only where worlds can be
	            saved, `saves`: the server's WorldSave state, World/WorldSave), Options...
	            always; and the status line under them (`status`), from the server's MenuState
	            (Protocol.MenuState; nil before the first one arrives), with a load's progress
	            ("Loading world: 12 / 40") while a world loads.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Protocol = require(Shared.Net.Protocol)

local TitleRules = {}

TitleRules.SPLASHES = table.freeze({
	"Now with operators!",
	"Ask the operator!",
	"Voxels all the way down!",
	"1024 blocks tall!",
	"Greedy meshing!",
	"Parallel Luau!",
	"Generated on your device!",
	"Seeds are just numbers!",
	"Try the Underlands!",
	"Mind the creepers!",
	"Boil your water!",
	"Stay hydrated!",
	"Lava hurts!",
	"Mekanism inside!",
	"Pipes and cables!",
	"Also try Minecraft!",
	"Not an official Minecraft product!",
	"Made of ice!",
	"Cold as ice!",
	"Mine, craft, repeat!",
	"Now with world types!",
	"Pick a seed, any seed!",
	"Look out for ravines!",
	"Oil is not water!",
	"Watch the far mountains!",
	"Thirsty?",
	"Every Age has its tools!",
	"Knowledge is power!",
	"Structure blocks!",
	"Jigsaws!",
	"Server-authoritative!",
	"No terrain over the wire!",
	"Day and night!",
	"Glow lichen!",
	"Punch a tree!",
	"Do not dig straight down!",
	"Creative or survival?",
	"Spectators float!",
	"Torches on walls!",
	"Bring a bucket!",
})

--[[
	The splash for a day (`month` 1..12, `day` 1..31): the date's own, else SPLASHES[`pick`]
	(`pick` 1..#SPLASHES, chosen at random by the caller).
]]
function TitleRules.splash(month: number, day: number, pick: number): string
	if month == 12 and day >= 24 and day <= 26 then
		return "Merry X-mas!"
	elseif month == 1 and day == 1 then
		return "Happy new year!"
	elseif month == 10 and day == 31 then
		return "OOoooOOOoooo! Spooky!"
	end
	local splashes = TitleRules.SPLASHES
	return splashes[math.clamp(pick, 1, #splashes)]
end

-- The splash's scale `seconds` into its pulse, for a text `width` GUI pixels wide.
function TitleRules.splashScale(seconds: number, width: number): number
	local t = seconds % 1
	local pulse = 1.8 - math.abs(math.sin(t * 2 * math.pi)) * 0.1
	return pulse * 100 / (width + 32)
end

export type Buttons = {
	join: boolean,
	create: boolean,
	load: boolean,
	options: boolean,
}

-- Which buttons work in MenuState `state` (nil: none heard yet); `saves`: worlds can be saved
-- and loaded here.
function TitleRules.buttons(state: number?, operator: boolean, saves: boolean?): Buttons
	local MenuState = Protocol.MenuState
	return {
		join = state == MenuState.Ready,
		create = operator and state == MenuState.Waiting,
		load = operator and state == MenuState.Waiting and saves == true,
		options = true,
	}
end

-- The status line: its text and whether it is a warning (Minecraft's red) or news (yellow).
function TitleRules.status(
	state: number?,
	operator: boolean,
	operatorName: string,
	worldName: string,
	loading: string?
): (string, "plain" | "news" | "warning")
	local MenuState = Protocol.MenuState
	if state == MenuState.Creating and loading then
		return loading, "plain"
	end
	if state == nil then
		return "Connecting to the server...", "plain"
	elseif state == MenuState.Waiting then
		if operator then
			return "You are the operator: create the world to start", "news"
		elseif operatorName ~= "" then
			return `Waiting for {operatorName} to create the world...`, "plain"
		end
		return "Waiting for the operator to create the world...", "plain"
	elseif state == MenuState.Creating then
		return "The world is being created...", "plain"
	elseif state == MenuState.Ready then
		return `"{worldName}" is ready`, "news"
	end
	return "The world could not be created. The server needs a restart", "warning"
end

return TitleRules
