--!strict
--[[
	Who may use Minecraft's operator blocks: structure blocks, structure voids and jigsaws (BlockList
	`creativeOnly`). Pure, so the tests can run it; Structures/StructureBlocks asks it with the
	player's ownership worked out ahead (a group game's owner takes a web call).

	As Minecraft's Player.canUseGameMasterBlocks (creative and an operator):
	  * creative players only, always;
	  * of those, Config.Structures.Permission decides: a list of user ids (by default none),
	    true = every one, false = nobody;
	  * the game's owner, Config.Gameplay.Admins (who may change others' game modes and the time:
	    the operators) and Studio sessions always may.
	It covers placing and breaking these blocks (Network/ServerNet), opening their screens and
	every request from them (SAVE, LOAD, DETECT, a jigsaw's Generate), and uploading pasted
	structure data.
]]

local Permission = {}

-- What a player who may not is told when they right click a structure block or jigsaw.
Permission.DENIED = "Only creative players with permission can use structure blocks and jigsaws"

--[[
	May user `userId`, in creative mode or not, use creative only blocks? `rule` is
	Config.Structures.Permission (a list of user ids, true or false), `admins`
	Config.Gameplay.Admins.
]]
function Permission.allowed(
	userId: number,
	rule: boolean | { number },
	creative: boolean,
	isOwner: boolean,
	isStudio: boolean,
	admins: { number }?
): boolean
	if not creative then
		return false
	elseif isOwner or isStudio or (type(admins) == "table" and table.find(admins, userId) ~= nil) then
		return true
	elseif type(rule) == "table" then
		return table.find(rule, userId) ~= nil
	end
	return rule == true
end

return Permission
