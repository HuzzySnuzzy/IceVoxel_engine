--!strict
--[[
	Minecraft 1.20.1's debug keys (KeyboardHandler.keyPress and handleDebugKeys), for what the game
	has. Pure: keys are Enum.KeyCode names ("F3", "N"...), so the tests run it; Debug/DebugOverlay
	feeds it the keyboard and does what it answers.

	  F3 alone   toggles the debug screen when it is let go (not when pressed), unless a combination
	             ran while it was held (Minecraft's handledDebugKey) or a screen is open.
	  F3 + N     spectator <-> the previous game mode (Creative when there is none): "gamemode
	             spectator", or back.
	  F3 + F4    opens the game mode switcher (Ui/GameModeSwitcher).
	  F3 + Q     lists these combinations in the chat.

	Combinations only run while no screen is open (Minecraft: screen == null; the switcher is a
	screen too, and takes F4 itself). N and F4 need the permission to change one's own game mode
	(Minecraft's permission level 2; here GameMode.mayChangeOwn): without it they only say so.
	A key that ran a combination does nothing else (Minecraft does not click its key mapping: F3 + Q
	throws nothing).

	Chat lines come back as `feedback` (shown after Minecraft's "[Debug]:" prefix, yellow and bold:
	debugFeedbackTranslated) and `lines` (plain chat lines after it).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)

local DebugKeys = {}

-- Minecraft's texts (en_us: debug.*).
DebugKeys.PREFIX = "[Debug]:"
DebugKeys.NO_PERMISSION_MODE = "Unable to switch game mode; no permission"
DebugKeys.NO_PERMISSION_SWITCHER = "Unable to open game mode switcher; no permission"
DebugKeys.HELP_TITLE = "Key bindings:"
-- F3 + Q's list, in Minecraft's order (the combinations the game has).
DebugKeys.HELP = table.freeze({
	"F3 + N = Cycle previous gamemode <-> spectator",
	"F3 + Q = Show this list",
	"F3 + F4 = Open game mode switcher",
})

-- What is going on around the keys when one is pressed or let go.
export type Context = {
	-- A screen is open (an inventory, a panel, the switcher) or the player types in the chat.
	screenOpen: boolean,
	-- The player's game mode, previous mode (nil: none yet) and whether they may change it.
	mode: string,
	previous: string?,
	mayChange: boolean,
}

--[[
	What to do:
	  toggle    show / hide the debug screen
	  setMode   ask the server for game mode `mode` (Protocol SetGameMode)
	  switcher  open the game mode switcher
	  chat      show `feedback` after the "[Debug]:" prefix, then `lines`
]]
export type Action = {
	kind: "toggle" | "setMode" | "switcher" | "chat",
	mode: string?,
	feedback: string?,
	lines: { string }?,
}

export type State = {
	-- F3 is held (its press reached the game).
	f3Down: boolean,
	-- A combination ran since F3 went down (handledDebugKey): letting go of F3 toggles nothing.
	handled: boolean,
}

function DebugKeys.new(): State
	return { f3Down = false, handled = false }
end

-- The mode F3 + N switches to: spectator, or from spectator the previous mode (else Creative).
function DebugKeys.cycleTarget(mode: string, previous: string?): string
	if not GameMode.isSpectator(mode) then
		return GameMode.SPECTATOR
	end
	return previous or GameMode.CREATIVE
end

local function chat(feedback: string, lines: { string }?): Action
	return { kind = "chat", feedback = feedback, lines = lines }
end

--[[
	`key` (a KeyCode name) went down. Returns what to do, and whether the key ran a combination (so
	it must do nothing else).
]]
function DebugKeys.press(state: State, key: string, context: Context): (Action?, boolean)
	if key == "F3" then
		state.f3Down = true
		state.handled = false
		return nil, false
	end
	if not state.f3Down or context.screenOpen then
		return nil, false
	end
	if key == "N" then
		state.handled = true
		if not context.mayChange then
			return chat(DebugKeys.NO_PERMISSION_MODE), true
		end
		return { kind = "setMode", mode = DebugKeys.cycleTarget(context.mode, context.previous) }, true
	elseif key == "F4" then
		state.handled = true
		if not context.mayChange then
			return chat(DebugKeys.NO_PERMISSION_SWITCHER), true
		end
		return { kind = "switcher" }, true
	elseif key == "Q" then
		state.handled = true
		return chat(DebugKeys.HELP_TITLE, table.clone(DebugKeys.HELP)), true
	end
	return nil, false
end

--[[
	`key` (a KeyCode name) was let go. Letting go of F3 toggles the debug screen, unless a
	combination ran meanwhile or a screen is open (Minecraft handles the release only without a
	screen). Either way the next F3 starts afresh.
]]
function DebugKeys.release(state: State, key: string, context: Context): Action?
	if key ~= "F3" or not state.f3Down then
		return nil
	end
	local handled = state.handled
	state.f3Down = false
	state.handled = false
	if handled or context.screenOpen then
		return nil
	end
	return { kind = "toggle" }
end

-- F3 is no longer held without a release reaching the game (the window lost the focus).
function DebugKeys.reset(state: State)
	state.f3Down = false
	state.handled = false
end

return DebugKeys
