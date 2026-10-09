--!strict
--[[
	What every menu button says when it is hovered, selected with a gamepad or long pressed on a
	touch screen (Ui/HoverTip shows it): one table of texts, by button id, so they are easy to
	find and edit. Pure (the tests read it: tests/spec/ButtonHelp).

	  Ids        "<menu>.<button>": title, world, create, load, confirm, rename, characters,
	             avatar, options, skills, inventory, creative, jei, map, hud, spectator,
	             switcher, structure, jigsaw. A menu registers a button with HoverTip.attach(object,
	             "<id>"[, variant]) and the id written out as a string literal, so the spec finds
	             every id the menus use in their sources and checks it is here (and that every
	             text here is used).
	  Variants   an entry is a text, or a table of texts by variant for buttons built in a loop or
	             whose meaning changes (the Options menu's settings by key, the avatar's sliders
	             by scale, the spectator menu's slots by item kind). `default` (when there is
	             one) answers a variant with no text of its own; no text at all shows no tooltip.
	  Generated  the Options menu's settings ("options.setting", by PlayerSettings key: each
	             entry's `tooltip`, the key bindings' from Shared/KeyBindings) and the Key Binds
	             screen's key buttons ("options.keyButton": the action's tooltip and how to
	             change it), so a setting's text lives with the setting.
	Style: Minecraft's option tooltips. What it does first, then its trade-off or what to know
	("May lower performance", "can't be undone"); short sentences, wrapped at TooltipLayout.WIDTH.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Characters = require(Shared.Characters)
local KeyBindings = require(Shared.KeyBindings)
local PlayerSettings = require(Shared.PlayerSettings)
local WorldSettings = require(Shared.WorldSettings)

export type Entry = string | { [string]: string }

local ButtonHelp = {}

local FORECAST = "The weather map's forecast"

local TEXTS: { [string]: Entry } = {
	--[[ Title screen (Ui/MainMenu) ]]
	["title.play"] = "Choose a character, or make a new one, then the world to play in.",
	["title.join"] = "Enter this server's world, where everyone on the server plays.",
	["title.create"] = "Set up a new world for this server: its name, game mode, difficulty, type and "
		.. "seed. Operators only, while no world is running.",
	["title.load"] = "Pick one of your saved worlds to play, rename or delete. Operators only, while no "
		.. "world is running.",
	["title.options"] = "Video, sound, controls, HUD, chat and accessibility settings. They are saved for "
		.. "you, one set per kind of device.",
	["world.back"] = "Back to choosing a character.",

	--[[ Create World ]]
	["create.tabGame"] = "The world's name, game mode, difficulty and commands.",
	["create.tabWorld"] = "The world type and its options, the seed and structures.",
	["create.name"] = `The name the world is saved under (up to {WorldSettings.MAX_NAME} characters). `
		.. "It can be renamed later.",
	["create.gameMode"] = "Survival: gather, craft and survive. Creative: every item, flight, no harm. "
		.. "Adventure: Survival without breaking or placing blocks. Click to cycle.",
	["create.difficulty"] = "Peaceful: no monsters. Easy, Normal and Hard: monsters spawn, and fire spreads "
		.. "faster the harder it is. Click to cycle.",
	["create.commands"] = "Lets players use cheats such as /gamemode and /tp. Creative turns it on, "
		.. "Survival and Adventure off, until you set it yourself.",
	["create.worldType"] = "How the land is generated; the line below says what this type is. Click to " .. "cycle.",
	["create.customize"] = "This world type's own options, such as a flat world's layers.",
	["create.seed"] = "Where the generator starts from: the same seed and type make the same world. Blank: "
		.. "a random seed. Words work too.",
	["create.structures"] = "Villages, mineshafts and the other structures. OFF: only the land.",
	["create.createNow"] = "Make the world with these settings and enter it. The server checks them again.",
	["create.cancel"] = "Back without making a world.",
	["create.customSetting"] = "One of this world type's options; the line under it says more. It is used "
		.. "when the world is made.",
	["create.customDone"] = "Back to Create World, keeping these options.",

	--[[ Select World, deleting and renaming ]]
	["load.row"] = "Click to select this world; double click to play it.",
	["load.play"] = "Load the selected world and enter it. Everyone on the server joins it.",
	["load.rename"] = "Give the selected world a new name.",
	["load.delete"] = "Delete the selected world for good. You are asked first.",
	["load.cancel"] = "Back without loading a world.",
	["confirm.delete"] = "Delete it for good. This can't be undone.",
	["confirm.cancel"] = "Keep it.",
	["rename.name"] = "The new name. Names are filtered by Roblox.",
	["rename.confirm"] = "Save the new name.",
	["rename.cancel"] = "Keep the old name.",

	--[[ Select Character (Ui/CharacterSelect) ]]
	["characters.row"] = "Click to select this character; double click to play it. Drag the figure to " .. "turn it.",
	["characters.play"] = "Play as the selected character, then pick the world. A Hardcore character "
		.. "that died can't play again.",
	["characters.create"] = `Make a new character: its look, name and difficulty (up to {Characters.MAX}).`,
	["characters.rename"] = "Give the selected character a new name.",
	["characters.delete"] = "Delete the selected character and everything it carries, for good. You are "
		.. "asked first.",
	["characters.back"] = "Back to the title screen.",

	--[[ Create New Character (Ui/AvatarEditor) ]]
	["avatar.tab"] = {
		skin = "The skin's colours, part by part.",
		body = "Height, width and the body's shape.",
		clothing = "What of your Roblox avatar the character wears.",
		presets = "Ready-made looks to start from.",
	},
	["avatar.part"] = "The part the tones and sliders paint: all of them, the head, the torso, an arm or "
		.. "a leg. Click to cycle.",
	["avatar.swatch"] = "Paints the chosen part this skin tone.",
	["avatar.hue"] = "The chosen part's hue.",
	["avatar.brightness"] = "How light or dark the chosen part is.",
	["avatar.randomise"] = "One random skin tone for the whole body.",
	["avatar.scale"] = {
		height = "How tall the character is.",
		width = "How broad the character is.",
		depth = "How deep the body is, front to back.",
		head = "The head's size.",
		bodyType = "From the blocky classic body to a more natural one.",
		proportion = "From broad to slender, with Body Type above 0.",
	},
	["avatar.resetBody"] = "Back to your Roblox avatar's own body sizes.",
	["avatar.blocky"] = "ON: the plain blocky body instead of your avatar's body parts.",
	["avatar.asset"] = "Wear this thing of your Roblox avatar, or leave it off.",
	["avatar.preset"] = {
		Classic = "Roblox's classic look: the blocky body in yellow, blue and green.",
		Natural = "A natural body shape, keeping your colours.",
		["My Avatar"] = "Your Roblox avatar as it is.",
	},
	["avatar.name"] = `The character's name: 1 to {Characters.MAX_NAME} characters, filtered by Roblox.`,
	["avatar.difficulty"] = "Classic: keep everything when you die. Mediumcore: drop everything you carry. "
		.. "Hardcore: drop it all and die for good, then spectate. Fixed once made.",
	["avatar.create"] = "Make the character with this look, name and difficulty.",
	["avatar.cancel"] = "Back without making a character.",

	--[[ Options (Ui/SettingsScreen; the settings themselves are generated below) ]]
	["options.page"] = {
		video = "View distance, detail, caves, plants, shadows, textures and brightness.",
		performance = "Far meshes, how much each frame builds, and hidden terrain.",
		sounds = "The music and every sound's volume.",
		controls = "Mouse settings, key binds, and hold or toggle for sneaking and sprinting.",
		hud = "The minimap, WAILA, the attack indicator and the GUI scale.",
		chat = "What the chat shows, and its size and look.",
		accessibility = "Camera motion: view bobbing, distortion, FOV effects and the hurt tilt.",
		weather = "Clouds, rain and snow: Fancy, Fast or off.",
		mouse = "Sensitivity, scrolling and what the mouse wheel does.",
		keybinds = "Which key or mouse button does what.",
	},
	["options.reset"] = "Puts back the current Graphics preset's values.",
	["options.defaults"] = "Every setting back to this device's defaults, the key binds too.",
	["options.done"] = "Saves the settings and goes back; on this page, closes the menu.",
	["options.resetKeys"] = "Every key bind back to its default.",
	["options.keyReset"] = "This key bind back to its default.",
	["options.keyCategory"] = {
		movement = "Walking, jumping, sneaking and sprinting.",
		gameplay = "Attacking, breaking, using and picking blocks.",
		inventory = "The inventory, dropping items and the hotbar's slots.",
		multiplayer = "The chat and commands.",
		misc = "The Options menu, the skill tree and the debug screen.",
		map = "The world map, the minimap's zoom and the weather map.",
		jei = "Just Enough Items: recipes and uses of the item under the pointer.",
	},

	--[[ Skill tree (Ui/SkillTreeScreen: its nodes and Age titles describe themselves) ]]
	["skills.unlock"] = "Spends skill points on the selected skill. It needs its Age, the skills before "
		.. "it and enough points.",
	["skills.done"] = "Closes the skill tree.",

	--[[ Inventory screens (Ui/InventoryScreen, Ui/CreativeScreen) ]]
	["inventory.options"] = "Opens the Options menu.",
	["inventory.close"] = "Closes the inventory.",
	["inventory.itemsTab"] = "Creative's item selection: every item to take.",
	["inventory.eye"] = {
		hideArmor = "Hides this armor piece's look; it still protects you.",
		showArmor = "Shows this armor piece's look again.",
		hideAccessory = "Hides this accessory's look; it still works.",
		showAccessory = "Shows this accessory's look again.",
	},
	["creative.inventoryTab"] = "Your survival inventory: armor, equipment and crafting.",
	["creative.close"] = "Closes the item selection.",

	--[[ Just Enough Items (Ui/Jei) ]]
	["jei.previous"] = "The item list's previous page.",
	["jei.next"] = "The item list's next page.",
	["jei.search"] = "Shows only the items whose name has this text.",
	["jei.back"] = "Back to the recipes shown before.",
	["jei.close"] = "Closes the recipes.",
	["jei.previousPage"] = "The previous page of recipes.",
	["jei.nextPage"] = "The next page of recipes.",
	["jei.tab"] = {
		crafting = "Recipes made at a crafting table or in the inventory's grid.",
		smelting = "Recipes cooked in a furnace.",
		fuel = "What burns in a furnace, and for how long.",
		refining = "What the oil refinery makes.",
		heating = "What a heat generator burns for energy.",
		combustion = "What a combustion generator burns for energy.",
		boiling = "What a campfire boils.",
	},

	--[[ Maps (Map/) ]]
	["map.open"] = "Opens the world map: drag it, zoom it, right click for waypoints.",
	["map.weather"] = "Weather mode: rain, snow, storms and clouds over the map, the wind and a forecast.",
	["map.close"] = "Closes the world map.",
	["map.centre"] = "Centres the map on you, and keeps it following you.",
	["map.zoomIn"] = "Zooms in.",
	["map.zoomOut"] = "Zooms out.",
	["map.forecast"] = {
		["1"] = "The weather as it is now.",
		["2"] = `{FORECAST} two minutes ahead.`,
		["3"] = `{FORECAST} five minutes ahead.`,
		["4"] = `{FORECAST} ten minutes ahead.`,
		["5"] = `{FORECAST} twenty minutes ahead.`,
	},

	--[[ The HUD's touch buttons (Ui/Hud) ]]
	["hud.inventory"] = "Opens your inventory. Spectators: uses the spectator menu's selection.",
	["hud.options"] = "Opens the Options menu.",
	["hud.skills"] = "Opens the skill tree.",
	["hud.chat"] = "Opens the chat.",

	--[[ The spectator menu (Ui/SpectatorGui) ]]
	["spectator.slot"] = {
		teleport = "Lists the players you can teleport to.",
		player = "Teleports you to this player.",
		previous = "The previous page of players.",
		next = "The next page of players.",
		close = "Closes the menu.",
	},

	--[[ The game mode switcher (Ui/GameModeSwitcher) ]]
	["switcher.mode"] = {
		Survival = "Mine, build and survive: health, hunger and damage.",
		Creative = "Every item, instant breaking and flight; nothing hurts you.",
		Adventure = "Survival without breaking or placing blocks.",
		Spectator = "Fly through everything, unseen; touch nothing.",
	},

	--[[ The structure block screen (Ui/StructureScreen), by StructureForm widget id ]]
	["structure.widget"] = {
		name = "The structure's name: what SAVE saves and LOAD loads, and what CORNER blocks pair by.",
		posX = "Where the region starts, east (+) or west (-) of this block.",
		posY = "Where the region starts, above (+) or below (-) this block.",
		posZ = "Where the region starts, south (+) or north (-) of this block.",
		sizeX = "The region's width, west to east (0 to 48).",
		sizeY = "The region's height (0 to 48).",
		sizeZ = "The region's length, north to south (0 to 48).",
		showInvisible = "Marks the air blocks inside the region, so you see what SAVE leaves empty.",
		detect = "Finds the CORNER blocks of this name and fits the region between them.",
		data = "The saved structure as text: select it and copy it to keep or share.",
		previousPart = "The text's previous part (long structures come in parts).",
		nextPart = "The text's next part.",
		save = "Saves the region's blocks under the name, as text you can copy.",
		showBoundingBox = "Draws the region's outline.",
		integrity = "The share of blocks LOAD places, from 0 to 1 (1: every block).",
		seed = "Picks which blocks a partial integrity leaves out. 0: different each time.",
		paste = "Paste a structure's text here to LOAD it instead of the name.",
		rotation0 = "Loads the structure unturned.",
		rotation1 = "Loads the structure turned a quarter clockwise.",
		rotation2 = "Loads the structure turned half way round.",
		rotation3 = "Loads the structure turned a quarter anticlockwise.",
		mirror = "Loads the structure mirrored: none, left to right, or front to back.",
		load = "Places the structure: the first press shows where, the next builds it.",
		metadata = "The marker's name, which the structure's generation reads (a chest's loot, say).",
		mode = "Save, Load, Corner or Data. Click to cycle.",
		done = "Sends the settings and closes the screen.",
		cancel = "Closes the screen without sending changes.",
	},
	["jigsaw.widget"] = {
		pool = "The template pool the next piece is drawn from.",
		name = "This jigsaw's name, which other pieces' Target Name looks for.",
		target = "The name of the jigsaw on the next piece this one joins to.",
		finalState = "The block this jigsaw turns into once the structure is generated.",
		joint = "Rollable: the piece above or below may turn. Aligned: it keeps this jigsaw's facing.",
		levels = "How many pieces deep Generate builds from here.",
		keepJigsaws = "ON: the jigsaw blocks stay after Generate instead of turning into their blocks.",
		generate = "Builds the structure from this jigsaw.",
		done = "Sends the settings and closes the screen.",
		cancel = "Closes the screen without sending changes.",
	},
}

-- Generated: the Options menu's settings (every PlayerSettings entry, the key bindings too) and
-- the Key Binds screen's key buttons.
local settings: { [string]: string } = {}
for _, entry in PlayerSettings.ENTRIES do
	if entry.tooltip then
		settings[entry.key] = entry.tooltip
	end
end
TEXTS["options.setting"] = settings
local keyButtons: { [string]: string } = {}
for _, action in KeyBindings.ACTIONS do
	keyButtons[action.id] = `{action.tooltip} Click, then press a key or mouse button (Escape: Not Bound).`
end
TEXTS["options.keyButton"] = keyButtons

ButtonHelp.TEXTS = TEXTS

-- The text of button `id` (its `variant`'s for a table of variants; `default` when the variant
-- has none), nil when there is none.
function ButtonHelp.text(id: string, variant: string?): string?
	local entry = TEXTS[id]
	if type(entry) == "string" then
		return entry
	elseif type(entry) == "table" then
		return (if variant then entry[variant] else nil) or entry.default
	end
	return nil
end

-- Is there an entry for `id` (a text or variants)?
function ButtonHelp.has(id: string): boolean
	return TEXTS[id] ~= nil
end

return ButtonHelp
