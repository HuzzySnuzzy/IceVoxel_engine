--!strict
--[[
	Minecraft's /save-all, /save-off and /save-on (its SaveAllCommand, SaveOffCommand,
	SaveOnCommand), without the Roblox parts (World/WorldSave runs them), so the specs run them.

	    /save-all [flush]   saves the world now: "Saving the game (this may take a moment!)",
	                        then "Saved the game" (or why not); `flush` is accepted as Minecraft's
	                        and changes nothing here (every save is written out before it says so)
	    /save-off           turns automatic saving off (Minecraft's level.noSave): no autosaves and
	                        no save on shutdown, until /save-on; /save-all still saves
	    /save-on            turns it back on

	Who may: operators only (Players/Operators.isOperator, Minecraft's permission level 4; Allow
	Commands is not enough: saving touches every player's world). The answers are Minecraft's
	("Automatic saving is now disabled", "Saving is already turned off"...).
]]

export type Context = {
	-- An operator typed it.
	operator: boolean,
	-- Automatic saving is on now.
	autosave: boolean,
	-- The world can be saved at all (a store, the world's lock, nothing refused it).
	available: boolean,
	-- Why not, when it can't.
	reason: string?,
}

export type Result = {
	-- "save" (save now), "off", "on" or nil (nothing to do but the feedback).
	action: ("save" | "off" | "on")?,
	feedback: { string },
}

local SaveCommand = {}

SaveCommand.SAVE_ALL = "/save-all"
SaveCommand.SAVE_OFF = "/save-off"
SaveCommand.SAVE_ON = "/save-on"
SaveCommand.ALIASES = { SaveCommand.SAVE_ALL, SaveCommand.SAVE_OFF, SaveCommand.SAVE_ON }
SaveCommand.DENIED = "Only operators can save the world"
SaveCommand.SAVING = "Saving the game (this may take a moment!)"
SaveCommand.SAVED = "Saved the game"
SaveCommand.OFF = "Automatic saving is now disabled"
SaveCommand.ON = "Automatic saving is now enabled"
SaveCommand.ALREADY_OFF = "Saving is already turned off"
SaveCommand.ALREADY_ON = "Saving is already turned on"
SaveCommand.USAGE_ALL = "Usage: /save-all [flush]"

local function words(text: string): { string }
	local list: { string } = {}
	for word in string.gmatch(text, "%S+") do
		table.insert(list, string.lower(word))
	end
	return list
end

-- Is `text` one of the three commands?
function SaveCommand.matches(text: string): boolean
	local first = words(text)[1]
	return first ~= nil and table.find(SaveCommand.ALIASES, first) ~= nil
end

-- What `text` does with `context` (nil: not one of these commands).
function SaveCommand.run(text: string, context: Context): Result?
	local list = words(text)
	local command = list[1]
	if command == nil or table.find(SaveCommand.ALIASES, command) == nil then
		return nil
	end
	if not context.operator then
		return { action = nil, feedback = { SaveCommand.DENIED } }
	end
	if command == SaveCommand.SAVE_ALL then
		if #list > 2 or (list[2] ~= nil and list[2] ~= "flush") then
			return { action = nil, feedback = { SaveCommand.USAGE_ALL } }
		elseif not context.available then
			return {
				action = nil,
				feedback = { `Unable to save the game: {context.reason or "saving is not available"}` },
			}
		end
		return { action = "save", feedback = { SaveCommand.SAVING } }
	elseif command == SaveCommand.SAVE_OFF then
		if not context.autosave then
			return { action = nil, feedback = { SaveCommand.ALREADY_OFF } }
		end
		return { action = "off", feedback = { SaveCommand.OFF } }
	end
	if context.autosave then
		return { action = nil, feedback = { SaveCommand.ALREADY_ON } }
	end
	return { action = "on", feedback = { SaveCommand.ON } }
end

return SaveCommand
