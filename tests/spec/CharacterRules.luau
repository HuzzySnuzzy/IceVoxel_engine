--[[
	The title screen's character pages (client Ui/CharacterRules): the page flow back, the list's
	rows, colours and buttons (Play needs a living highlighted character, Create room), the
	highlight kept across lists, the editor's rules (names, difficulty cycle, body colours by
	part, hue and brightness, scale sliders within the avatar rules, the clothing toggles with one
	of each single kind, the blocky body, presets) and the colour conversions.
]]

return function(t, shared, require, _server, client)
	local Appearance = require(shared.Characters.Appearance)
	local Characters = require(shared.Characters)
	local Config = require(shared.Config)
	local CharacterRules = require(client.Ui.CharacterRules)

	local D = Characters.Difficulty

	local function summary(id: number, overrides: any?): Characters.Summary
		local s: any = {
			id = id,
			name = `Hero {id}`,
			difficulty = D.Classic,
			dead = false,
			legacy = false,
			created = 1000 + id,
			lastPlayed = 2000 + id,
			played = 3725,
		}
		for k, v in overrides or {} do
			s[k] = v
		end
		return s
	end

	local function sampleLook(): Appearance.Appearance
		local look = Appearance.default()
		look.assets = {
			{ kind = Appearance.KIND.Head, id = 1, worn = true, layered = false, order = 0, puffiness = 1 },
			{ kind = Appearance.KIND.Torso, id = 2, worn = true, layered = false, order = 0, puffiness = 1 },
			{ kind = Appearance.KIND.Shirt, id = 3, worn = true, layered = false, order = 0, puffiness = 1 },
			{ kind = Appearance.KIND.Shirt, id = 4, worn = false, layered = false, order = 0, puffiness = 1 },
			{ kind = Appearance.ACCESSORY + 1, id = 5, worn = true, layered = false, order = 0, puffiness = 1 },
			{ kind = Appearance.ACCESSORY + 1, id = 6, worn = true, layered = false, order = 0, puffiness = 1 },
			{ kind = Appearance.ACCESSORY + 2, id = 7, worn = false, layered = false, order = 0, puffiness = 1 },
		}
		return look
	end

	t.test("character pages: back goes title <- characters <- editor / world; dialogs to their list", function()
		t.eq(CharacterRules.back("characters"), "title")
		t.eq(CharacterRules.back("editor"), "characters")
		t.eq(CharacterRules.back("world"), "characters")
		t.eq(CharacterRules.back("rename", "character"), "characters")
		t.eq(CharacterRules.back("confirm", "character"), "characters")
		t.eq(CharacterRules.back("confirm", "world"), "load", "the world list's own")
		t.eq(CharacterRules.back("title"), nil)
	end)

	t.test("character pages: rows, colours and the highlight", function()
		local date = { year = 2026, month = 10, day = 9, hour = 14, min = 3 }
		local first, second = CharacterRules.row(summary(1), date)
		t.eq(first, "Hero 1")
		t.eq(second, "Classic, 1:02, 2026-10-09")
		local _, dead = CharacterRules.row(summary(2, { dead = true, difficulty = D.Hardcore }), date)
		t.eq(dead, "Dead, Hardcore, 1:02, 2026-10-09")
		t.eq(CharacterRules.colour(summary(1, { difficulty = D.Mediumcore }))[1], 140, "Terraria's blue")
		t.eq(CharacterRules.colour(summary(1, { difficulty = D.Hardcore }))[2], 92, "red")
		t.eq(CharacterRules.colour(summary(1, { dead = true }))[1], 128, "gray once dead")
		local list = { summary(3), summary(1), summary(2) }
		t.eq(CharacterRules.keepHighlight(list, 2, 1), 2, "kept while listed")
		t.eq(CharacterRules.keepHighlight(list, 9, 1), 1, "else the selected")
		t.eq(CharacterRules.keepHighlight(list, 9, 7), 3, "else the first")
		t.eq(CharacterRules.keepHighlight({}, 1, 1), nil)
		local question, warning = CharacterRules.deleteQuestion("Steve")
		t.eq(question, "Are you sure you want to delete this character?")
		t.eq(warning, "'Steve' will be lost forever! (A long time!)")
	end)

	t.test("character pages: Play needs a living character and nothing under way; Create needs room", function()
		local list = { summary(1), summary(2, { dead = true }) }
		local ready = CharacterRules.buttons(list, 1, false)
		t.eq(ready.play, true)
		t.eq(ready.create, true)
		t.eq(ready.rename, true)
		t.eq(ready.delete, true)
		t.eq(ready.back, true)
		local dead = CharacterRules.buttons(list, 2, false)
		t.eq(dead.play, false, "a dead character can't be played")
		t.eq(dead.delete, true, "but can be deleted")
		local busy = CharacterRules.buttons(list, 1, true)
		t.eq(busy.play, false)
		t.eq(busy.create, false)
		t.eq(busy.back, true)
		local none = CharacterRules.buttons(list, nil, false)
		t.eq(none.play, false)
		t.eq(none.rename, false)
		t.eq(CharacterRules.buttons({}, nil, false).create, true, "an empty list: only Create and Back")
		local full = {}
		for i = 1, Characters.MAX do
			table.insert(full, summary(i))
		end
		t.eq(CharacterRules.buttons(full, 1, false).create, false, "at the most")
		t.eq(CharacterRules.buttons(full, 1, false, Characters.MAX + 1).create, true, "the server's max")
	end)

	t.test("character pages: names, difficulties and body colours", function()
		t.eq(CharacterRules.nameProblem("Steve"), nil)
		t.ok(CharacterRules.nameProblem("   ") ~= nil)
		t.ok(CharacterRules.nameProblem(string.rep("a", Characters.MAX_NAME + 1)) ~= nil)
		t.eq(CharacterRules.nextDifficulty(D.Classic), D.Mediumcore)
		t.eq(CharacterRules.nextDifficulty(D.Hardcore), D.Classic, "around")
		t.eq(CharacterRules.difficultyLabel(D.Hardcore), "Difficulty: Hardcore")
		local look = Appearance.default()
		local head = CharacterRules.paint(look, 1, 0x123456)
		t.eq(head.colors[1], 0x123456)
		t.eq(head.colors[2], look.colors[2], "only the head")
		t.eq(look.colors[1], Appearance.SKIN_TONES[3], "a copy")
		local all = CharacterRules.paint(look, 0, 0xABCDEF)
		for i = 1, 6 do
			t.eq(all.colors[i], 0xABCDEF)
		end
		local random = CharacterRules.randomSkin(look, function(n: number): number
			return n
		end)
		t.eq(random.colors[4], Appearance.SKIN_TONES[#Appearance.SKIN_TONES])
		t.eq(#CharacterRules.PART_NAMES, #Appearance.PARTS)
		t.eq(CharacterRules.PART_NAMES[2][1], "UpperTorso", "R15's torso")
		t.eq(#CharacterRules.BODY_COLORS, 6)
	end)

	t.test("character pages: hue, saturation and value round trip", function()
		for _, rgb in { 0xFF0000, 0x00FF00, 0x0000FF, 0xEAB892, 0x0D69AC, 0x000000, 0xFFFFFF, 0x7C5C46 } do
			local h, s, v = CharacterRules.toHsv(rgb)
			t.ok(h >= 0 and h < 1 and s >= 0 and s <= 1 and v >= 0 and v <= 1)
			t.eq(CharacterRules.fromHsv(h, s, v), rgb, string.format("0x%06X", rgb))
		end
		local h = CharacterRules.toHsv(0x00FF00)
		t.near(h, 1 / 3, 1e-9, "green's hue")
		t.eq(CharacterRules.fromHsv(1.5, 1, 1), 0x00FFFF, "hue wraps")
	end)

	t.test("character pages: body sliders stay within the avatar rules", function()
		local scales = Config.Characters.Scales :: any
		for _, name in Appearance.SCALES do
			local steps = CharacterRules.scaleSteps(name)
			t.ok(steps >= 1, name)
			t.near(CharacterRules.scaleAt(name, 0), scales[name][1], 1e-9, `{name}'s least`)
			t.near(CharacterRules.scaleAt(name, steps), scales[name][2], 1e-9, `{name}'s most`)
			t.near(CharacterRules.scaleAt(name, steps + 5), scales[name][2], 1e-9, "clamped")
			for step = 0, steps do
				t.eq(CharacterRules.stepOf(name, CharacterRules.scaleAt(name, step)), step)
			end
		end
		t.eq(CharacterRules.scaleSteps("height"), 15, "0.90..1.05 in hundredths")
		t.eq(CharacterRules.scaleSteps("bodyType"), 20, "0..1 in twentieths")
		t.eq(CharacterRules.scaleLabel("height", 1.05), "Height: 105%")
		t.eq(CharacterRules.scaleLabel("bodyType", 0.3), "Body Type: 30%")
	end)

	t.test("character pages: clothing toggles keep one of each single kind; the blocky body; presets", function()
		local look = sampleLook()
		t.eq(CharacterRules.assetLabel(look, 1), "Head")
		t.eq(CharacterRules.assetLabel(look, 3), "Shirt 1")
		t.eq(CharacterRules.assetLabel(look, 4), "Shirt 2")
		t.eq(CharacterRules.assetLabel(look, 5), "Hat 1")
		t.eq(CharacterRules.assetLabel(look, 7), "Hair")
		t.eq(CharacterRules.assetLabel(look, 99), "")
		t.eq(CharacterRules.assetToggleLabel(look, 3), "Shirt 1: ON")
		t.eq(CharacterRules.assetToggleLabel(look, 4), "Shirt 2: OFF")
		local swapped = CharacterRules.toggleAsset(look, 4)
		t.eq(swapped.assets[4].worn, true)
		t.eq(swapped.assets[3].worn, false, "one shirt at a time")
		t.eq(look.assets[4].worn, false, "a copy")
		local hats = CharacterRules.toggleAsset(look, 6)
		t.eq(hats.assets[6].worn, false)
		t.eq(hats.assets[5].worn, true, "accessories are each their own")
		t.eq(CharacterRules.isBlocky(look), false)
		local blocky = CharacterRules.setBlocky(look, true)
		t.eq(CharacterRules.isBlocky(blocky), true)
		t.eq(blocky.assets[3].worn, true, "clothing stays")
		local back = CharacterRules.setBlocky(blocky, false)
		t.eq(back.assets[1].worn, true)
		t.eq(back.assets[2].worn, true)
		t.eq(CharacterRules.isBlocky(Appearance.default()), true, "no parts: blocky")
		local snapshot = sampleLook()
		snapshot.colors[1] = 0x010203
		local classic = CharacterRules.preset(look, snapshot, "Classic")
		t.eq(classic.scales.bodyType, 0)
		t.eq(CharacterRules.isBlocky(classic), true)
		local natural = CharacterRules.preset(look, snapshot, "Natural")
		t.eq(natural.scales.bodyType, 1)
		local mine = CharacterRules.preset(classic, snapshot, "My Avatar")
		t.eq(mine.colors[1], 0x010203, "the snapshot as it is")
		t.ok(mine ~= snapshot, "a copy")
		t.eq(#CharacterRules.PRESETS, 3)
		-- Whatever the editor does, the server keeps only the snapshot's things.
		local edited = CharacterRules.toggleAsset(look, 7)
		table.insert(edited.assets, {
			kind = Appearance.ACCESSORY + 1,
			id = 999,
			worn = true,
			layered = false,
			order = 0,
			puffiness = 1,
		})
		local kept = Appearance.sanitize(edited, snapshot)
		t.eq(#kept.assets, #snapshot.assets, "no asset of the client's own")
		t.eq(kept.assets[7].worn, true, "the hair switched on")
	end)
end
