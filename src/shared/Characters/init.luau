--!strict
--[[
	Characters: Terraria's players (Config.Characters). Each Roblox user keeps up to MAX of them;
	one is chosen on the title screen before the world (client Ui/MainMenu), and it carries its look
	(Characters/Appearance), name, difficulty, inventory and equipment, health, mana, status
	effects, Tough As Nails and progression from world to world (server Save/CharacterCodec,
	Players/CharacterStore). Pure: the shared rules both sides and the specs read.

	  Difficulty  fixed when the character is made (Terraria's):
	                Classic     keeps everything on death (Terraria's softcore drops half its coins;
	                            the game has no coins). The default for new characters.
	                Mediumcore  drops everything on death: Minecraft's rule, the game's until now
	                            (the character a returning player's old progress becomes).
	                Hardcore    drops everything and dies for good: a spectator for the rest of the
	                            session, then shown dead in the list (it can only be deleted).
	              The keepInventory game rule keeps everything for every difficulty (Inventories
	              .setKeepRule). Terraria's Journey is not offered (creative is a game mode here).
	  Names       1..MAX_NAME characters (Terraria's 20) once trimmed, runs of spaces made one,
	              control characters and invalid UTF-8 refused (`cleanName`); the server filters
	              them as everyone sees them (TextService, the nametag).
	  Summary     what a character list shows (and the index keeps): id, name, difficulty, dead,
	              legacy (made from a returning player's old progress), created and last played
	              (os.time) and seconds played (`formatPlayed`: Terraria's "h:mm").
]]

local Config = require(script.Parent.Config)

export type Summary = {
	id: number,
	name: string,
	difficulty: number,
	dead: boolean,
	legacy: boolean,
	created: number,
	lastPlayed: number,
	played: number,
}

local Characters = {}

-- Difficulty ids (saved and sent: never renumber).
Characters.Difficulty = table.freeze({ Classic = 1, Mediumcore = 2, Hardcore = 3 })
-- Names by id, the list's colour (Terraria's: white, light blue, red) and a line explaining it.
Characters.DIFFICULTIES = table.freeze({ "Classic", "Mediumcore", "Hardcore" })
Characters.DIFFICULTY_COLORS = table.freeze({
	table.freeze({ 255, 255, 255 }),
	table.freeze({ 140, 170, 255 }),
	table.freeze({ 255, 92, 92 }),
})
Characters.DIFFICULTY_TEXT = table.freeze({
	"Keeps everything when it dies",
	"Drops everything when it dies",
	"Drops everything and dies for good",
})

-- Most characters a user keeps, characters (code points) in a name and the bytes that can take.
Characters.MAX = math.clamp(math.floor(Config.Characters.MaxPerUser), 1, 255)
Characters.MAX_NAME = math.clamp(math.floor(Config.Characters.NameLength), 1, 64)
Characters.MAX_NAME_BYTES = Characters.MAX_NAME * 4

-- The difficulty id named `name` (any case), nil for none.
function Characters.difficultyOf(name: string): number?
	local lower = string.lower(name)
	for id, difficulty in Characters.DIFFICULTIES do
		if string.lower(difficulty) == lower then
			return id
		end
	end
	return nil
end

-- A new character's difficulty (Config.Characters.DefaultDifficulty; Classic when unknown).
Characters.DEFAULT_DIFFICULTY = Characters.difficultyOf(Config.Characters.DefaultDifficulty)
	or Characters.Difficulty.Classic

function Characters.isDifficulty(value: unknown): boolean
	return type(value) == "number" and Characters.DIFFICULTIES[value] ~= nil
end

-- Does a character of `difficulty` keep its inventory when it dies (besides keepInventory)?
function Characters.keepsInventory(difficulty: number): boolean
	return difficulty == Characters.Difficulty.Classic
end

-- Does a character of `difficulty` die for good?
function Characters.diesForGood(difficulty: number): boolean
	return difficulty == Characters.Difficulty.Hardcore
end

--[[
	`text` as a character's name (see the header), or nil when nothing of it is left, it holds a
	control character or invalid UTF-8, or it has more than MAX_NAME characters.
]]
function Characters.cleanName(text: unknown): string?
	if type(text) ~= "string" or #text > Characters.MAX_NAME_BYTES * 4 or utf8.len(text) == nil then
		return nil
	end
	if string.find(text, "%c") then
		return nil
	end
	local name = string.match(text, "^%s*(.-)%s*$") :: string
	name = (string.gsub(name, "%s+", " "))
	local length = utf8.len(name) :: number
	if length < 1 or length > Characters.MAX_NAME then
		return nil
	end
	return name
end

-- Seconds played as Terraria's list shows them: "h:mm" ("0:00" for under a minute).
function Characters.formatPlayed(seconds: number): string
	local minutes = if seconds == seconds and seconds > 0 then math.floor(seconds / 60) else 0
	return string.format("%d:%02d", minutes // 60, minutes % 60)
end

-- Is `summary` well formed (ids whole and positive, a clean name, a known difficulty, times)?
function Characters.validSummary(summary: unknown): boolean
	if type(summary) ~= "table" then
		return false
	end
	local s = summary :: { [string]: any }
	local function time(value: any): boolean
		return type(value) == "number" and value == value and value >= 0 and value < math.huge
	end
	return type(s.id) == "number"
		and s.id >= 1
		and s.id == math.floor(s.id)
		and s.id < 2 ^ 32
		and Characters.cleanName(s.name) == s.name
		and Characters.isDifficulty(s.difficulty)
		and type(s.dead) == "boolean"
		and type(s.legacy) == "boolean"
		and time(s.created)
		and time(s.lastPlayed)
		and time(s.played)
end

-- `summaries` sorted for the list: last played first, then the newest made, then by id.
function Characters.sort(summaries: { Summary })
	table.sort(summaries, function(a: Summary, b: Summary): boolean
		if a.lastPlayed ~= b.lastPlayed then
			return a.lastPlayed > b.lastPlayed
		elseif a.created ~= b.created then
			return a.created > b.created
		end
		return a.id < b.id
	end)
end

return Characters
