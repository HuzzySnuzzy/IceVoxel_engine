--[[
	A fixture pack replacing and removing the Minecraft pack's recipes by name (tests/spec/Content
	and ContentTool graft it into Content/Packs, after the game's own packs), as Minecraft's data
	packs do by recipe id: Torch's recipe makes eight (an override by its result's name), raw iron
	smelts into two ingots (an override of IronIngotFromRawIron, a name the Minecraft pack gives),
	the Ladder has no recipe (a removal), and three Flint make two Sticks (a second recipe for
	Stick: a name of its own). Its kind folder's files (recipes/a_overrides, recipes/b_new) are what
	`where`, `origin` and the content tool name.
]]
return {
	order = 900,
	description = "Replaces and removes the Minecraft pack's recipes by name, for tests/spec/Content and ContentTool.",
	requires = { "Core", "Minecraft" },
}
