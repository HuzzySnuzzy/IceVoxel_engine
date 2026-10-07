--!strict
--[[
	The status effects' icons (Ui/EffectHud): 9 x 9 pixel art glyphs, one per EffectList `icon`,
	drawn 2 GUI pixels a pixel (18 x 18, Minecraft's effect sprite size) in the effect's colour.
	Pure data and colour maths (no Roblox APIs but Color3), so the tests check every effect has a
	glyph of the right size.

	Characters: K outline, C the effect's colour, L a lighter shade of it, D a darker one, W white,
	"." nothing. A dark effect (Blindness, Wither) still shows: the glyphs sit on Minecraft's light
	grey effect background.
]]

local EffectIcons = {}

EffectIcons.SIZE = 9

EffectIcons.GLYPHS = table.freeze({
	speed = {
		".........",
		"KK..KK...",
		"KCK.KCK..",
		".KCK.KCK.",
		"..KLK.KLK",
		".KCK.KCK.",
		"KCK.KCK..",
		"KK..KK...",
		".........",
	},
	slowness = {
		".........",
		"..KKKKK..",
		"..KCCCK..",
		"...KCK...",
		"..KLCCK..",
		".KLCCCCK.",
		"KCCCCCCDK",
		"KKKKKKKKK",
		".........",
	},
	pickaxe = {
		".KKKKKK..",
		"KLCCCCCK.",
		".KKK.KCK.",
		"....KCDK.",
		"...KDKK..",
		"..KDK....",
		".KDK.....",
		"KDK......",
		".K.......",
	},
	sword = {
		".......KK",
		"......KLK",
		".....KLK.",
		"....KLK..",
		"K..KCK...",
		"KK.KK....",
		".KDK.....",
		"KDKKK....",
		"KK..K....",
	},
	heart = {
		".KK...KK.",
		"KLCK.KCCK",
		"KLCCKCCCK",
		"KCCCCCCCK",
		".KCCCCCK.",
		"..KCCCK..",
		"...KCK...",
		"....K....",
		".........",
	},
	broken = {
		".KK...KK.",
		"KLCK.KCCK",
		"KLCK.KCCK",
		"KCCK..KCK",
		".KCK.KCK.",
		"..KK.KK..",
		"...K.K...",
		".........",
		".........",
	},
	jump = {
		"....K....",
		"...KLK...",
		"..KLCCK..",
		".KCCCCCK.",
		"KKKCCCKKK",
		"..KCCCK..",
		"..KCCCK..",
		"..KCCDK..",
		"..KKKKK..",
	},
	spiral = {
		".KKKKKK..",
		"KLCCCCCK.",
		"KCKKKKCK.",
		"KCKCCKCK.",
		"KCKCKKCK.",
		"KCKKKCCK.",
		"KCCCCCK..",
		".KKKKK...",
		".........",
	},
	shield = {
		"KKKKKKKKK",
		"KLCCCCCCK",
		"KLCCCCCCK",
		"KCCCCCCCK",
		"KCCCCCCDK",
		".KCCCCDK.",
		"..KCCDK..",
		"...KDK...",
		"....K....",
	},
	flame = {
		"....K....",
		"...KCK...",
		"...KCCK..",
		"..KCCCK.K",
		".KCCLCCKK",
		".KCLLLCCK",
		"KCCLWLCCK",
		"KCCLLLCK.",
		".KKKKKKK.",
	},
	eye = {
		"..KKKKK..",
		".KWWWWWK.",
		"KWWKKKWWK",
		"KWKCCCKWK",
		"KWKCLCKWK",
		"KWKCCCKWK",
		"KWWKKKWWK",
		".KWWWWWK.",
		"..KKKKK..",
	},
	drop = {
		"....K....",
		"...KCK...",
		"..KCCCK..",
		".KLCCCCK.",
		".KLCCCCK.",
		"KLLCCCCCK",
		"KLCCCCCDK",
		".KCCCCDK.",
		"..KKKKK..",
	},
	skull = {
		"..KKKKK..",
		".KLCCCCK.",
		"KLCCCCCCK",
		"KCKKCKKCK",
		"KCKKCKKCK",
		"KCCCKCCCK",
		".KCCCCCK.",
		"..KCKCK..",
		"..KKKKK..",
	},
	star = {
		"....K....",
		"...KCK...",
		"KKKKCKKKK",
		"KCCCLCCCK",
		".KCCLCCK.",
		"..KCCCK..",
		".KCCKCCK.",
		".KCK.KCK.",
		".KK...KK.",
	},
	snowflake = {
		".........",
		".C..C..C.",
		"..C.C.C..",
		"...CCC...",
		".CCCWCCC.",
		"...CCC...",
		"..C.C.C..",
		".C..C..C.",
		".........",
	},
})

-- The glyph named `icon` (the drop for an unknown one).
function EffectIcons.glyph(icon: string): { string }
	return EffectIcons.GLYPHS[icon] or EffectIcons.GLYPHS.drop
end

-- The palette of an effect of colour `rgb` (0..255): K, C, L, D and W.
function EffectIcons.palette(rgb: { number }): { [string]: Color3 }
	-- (Made here, not at load, so the tests can read the glyphs without Roblox's types.)
	local colour = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
	local white = Color3.new(1, 1, 1)
	return {
		K = Color3.fromRGB(24, 24, 24),
		C = colour,
		L = colour:Lerp(white, 0.45),
		D = colour:Lerp(Color3.new(0, 0, 0), 0.4),
		W = white,
	}
end

return EffectIcons
