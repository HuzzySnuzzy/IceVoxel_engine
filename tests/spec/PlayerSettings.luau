--[[
	The player settings schema (Shared/PlayerSettings): ids, ranges and defaults, clamping, the LOD
	balance rule (checked against LodTree's selections for every slider combination), presets and
	the device default, what the values mean (LodTree's distances, caves, lights, brightness,
	FOV), the text on the buttons, the wire format and the saved record.
]]

return function(t, shared, require, _server, client)
	local Config = require(shared.Config)
	local Coords = require(shared.World.Coords)
	local LodTree = require(shared.World.LodTree)
	local PlayerSettings = require(shared.PlayerSettings)
	local Protocol = require(shared.Net.Protocol)

	local ENTRIES = PlayerSettings.ENTRIES
	local Profile = PlayerSettings.Profile

	local function onStep(entry, value: number): boolean
		local steps = (value - entry.min) / entry.step
		return math.abs(steps - math.floor(steps + 0.5)) < 1e-9
	end

	--[[ Schema ]]

	t.test("player settings: ids are 1..n and unique, keys unique, defaults in range and on the step", function()
		local KeyBindings = require(shared.KeyBindings)
		local keys = {}
		local order = {}
		for _, effect in PlayerSettings.EFFECT_ORDER do
			order[effect] = true
		end
		-- Plain settings 1..n, then the key bindings from KEY_BASE (128) in the actions' order.
		local plain = PlayerSettings.PLAIN_COUNT
		t.eq(#ENTRIES, plain + #KeyBindings.ACTIONS, "a setting per key binding")
		t.ok(plain < KeyBindings.KEY_BASE, "plain ids stay below the key bindings'")
		for i, entry in ENTRIES do
			local id = if i <= plain then i else KeyBindings.KEY_BASE + i - plain - 1
			t.eq(entry.id, id, `id of {entry.key}`)
			t.eq(entry.kind == "key", i > plain, `{entry.key} in its block`)
			if entry.kind == "key" then
				local action = KeyBindings.ACTIONS[i - plain]
				t.eq(entry.key, "key." .. action.id, "key bindings are key.<action>")
				t.eq(entry.default, KeyBindings.defaultCode(action.id), `{entry.key}'s default`)
				t.eq(entry.page, "keybinds")
			end
			t.ok(keys[entry.key] == nil, `duplicate {entry.key}`)
			keys[entry.key] = true
			t.eq(PlayerSettings.byId[id], entry, "byId")
			t.eq(PlayerSettings.byKey[entry.key], entry, "byKey")
			t.ok(entry.id >= 1 and entry.id <= 255, "ids fit a byte")
			t.ok(entry.min < entry.max and entry.step > 0, `range of {entry.key}`)
			for _, value in { entry.default, entry.mobileDefault } do
				t.ok(value >= entry.min and value <= entry.max, `default of {entry.key} in range`)
				t.ok(onStep(entry, value), `default of {entry.key} on its step`)
			end
			if entry.kind == "toggle" then
				t.ok(entry.min == 0 and entry.max == 1 and entry.step == 1, `{entry.key} is 0 / 1`)
			end
			-- Every effect runs in a known order (the preset itself takes none).
			t.ok(entry.effect == "preset" or order[entry.effect], `effect {entry.effect} of {entry.key} is ordered`)
			for _, also in entry.also or {} do
				t.ok(order[also], `effect {also} is ordered`)
			end
			-- Steps survive the wire's f32 exactly.
			local b = buffer.create(4)
			buffer.writef32(b, 0, entry.step)
			t.eq(buffer.readf32(b, 0), entry.step, `{entry.key}'s step is exact in f32`)
		end
		for effect in PlayerSettings.EXPENSIVE do
			t.ok(order[effect], `costly effect {effect} is ordered`)
		end
		t.ok(#ENTRIES >= 33, "every setting of the contract is there")
		for _, key in
			{
				"renderDistance",
				"detailFalloff",
				"fullDetail",
				"caveView",
				"plants",
				"shadows",
				"farShadows",
				"fog",
				"textures",
				"lichenLights",
				"brightness",
				"preferDistance",
				"farMeshes",
				"buildBudget",
				"skipHidden",
				"swapFrames",
				"masterVolume",
				"blocksVolume",
				"playersVolume",
				"ambientVolume",
				"uiVolume",
				"footsteps",
				"interfaceClicks",
				"caveRumble",
				"fov",
				"fovEffects",
				"toggleSprint",
				"scrollHotbar",
				"touchButtons",
				"minimap",
				"waila",
				"guiScale",
				"preset",
			}
		do
			t.ok(keys[key], `setting {key}`)
		end
		t.ok(not pcall(PlayerSettings.entry, "nope"), "unknown keys error")
		-- Far Materials: id 34 (the next free one), a Video toggle restyled like Textures.
		local far = PlayerSettings.entry("farMaterials")
		t.eq(far.id, 34)
		t.eq(far.kind, "toggle")
		t.eq(far.page, "video")
		t.eq(far.effect, "textures")
		t.eq(far.default, if Config.Render.FarMaterials then 1 else 0)
		t.eq(far.preset, false)
	end)

	t.test("player settings: clamp snaps to the step, clamps to the range and the phone limit", function()
		t.eq(PlayerSettings.clamp("renderDistance", 1000), 1024, "snapped to 256s")
		t.eq(PlayerSettings.clamp("renderDistance", 100000), 4096, "max")
		t.eq(PlayerSettings.clamp("renderDistance", -5), 256, "min")
		t.eq(PlayerSettings.clamp("renderDistance", 4096, true), 1024, "phones stop at 1024")
		t.eq(PlayerSettings.clamp("detailFalloff", 2.7), 2.5, "half steps")
		t.eq(PlayerSettings.clamp("detailFalloff", 2.76), 3, "half steps up")
		t.eq(PlayerSettings.clamp("fullDetail", 1.1), 1.5, "full detail's minimum")
		t.eq(PlayerSettings.clamp("shadows", 0.7), 1, "toggles round")
		t.eq(PlayerSettings.clamp("fov", 0 / 0), 70, "NaN is the default")
		t.eq(PlayerSettings.clamp("masterVolume", math.huge), 100, "infinity is the default")
		t.eq(
			PlayerSettings.clamp("farMeshes", 0 / 0, true),
			PlayerSettings.byKey.farMeshes.mobileDefault,
			"phone default"
		)
		-- 0.1 steps of float noise never leak into values.
		t.eq(PlayerSettings.clamp("detailFalloff", 2 + 0.5 + 1e-12), 2.5)
	end)

	--[[ The balance rule ]]

	-- The leaf level covering level 0 cell (cx, cz) in a selection.
	local function leafAt(selection, cx: number, cz: number): number?
		for level = 0, LodTree.MAX_LEVEL do
			local f = bit32.lshift(1, level)
			if selection[Coords.nodeKey(level, cx // f, cz // f)] then
				return level
			end
		end
		return nil
	end

	-- The largest level jump between side neighbours of a full detail chunk.
	local function fullDetailJump(selection): number
		local worst = 0
		for key, level in selection do
			if level == 0 then
				local _, cx, cz = Coords.decodeNodeKey(key)
				for _, d in { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } } do
					local other = leafAt(selection, cx + d[1], cz + d[2])
					if other then
						worst = math.max(worst, other)
					end
				end
			end
		end
		return worst
	end

	t.test("player settings: the balance rule keeps LodTree 2:1 at full detail for every slider", function()
		local falloff = PlayerSettings.byKey.detailFalloff
		local full = PlayerSettings.byKey.fullDetail
		local cave = PlayerSettings.byKey.caveView
		local values = PlayerSettings.defaults(false, 0)
		values.renderDistance = 1024
		local checked = 0
		local split = falloff.min
		while split <= falloff.max do
			local l1 = full.min
			while l1 <= full.max do
				for _, reach in { cave.min, 112, cave.max } do
					values.detailFalloff, values.fullDetail, values.caveView = split, l1, reach
					PlayerSettings.balance(values)
					t.ok(values.fullDetail <= split + 1, "full detail clamped")
					local view, s, l, underground = PlayerSettings.lod(values)
					t.eq(view, 1024)
					t.ok(s >= 2, "split at least 2")
					t.ok(l <= s + 1 and underground <= s + 1, "full detail within split + 1")
					t.ok(underground >= l, "underground at least the normal full detail")
					LodTree.configure(view, s, l, underground)
					for _, ug in { false, true } do
						local selection = LodTree.select(37, -21, nil, ug)
						-- Walk 40 blocks with hysteresis too (the research's check).
						selection = LodTree.select(77, -21, selection, ug, ug)
						t.ok(fullDetailJump(selection) <= 1, `split {s}, L1 {l}, underground {ug}: 2:1`)
						checked += 1
					end
				end
				l1 += full.step
			end
			split += falloff.step
		end
		t.ok(checked >= 5 * 8 * 3 * 2, "every combination")
		-- Without the rule (L1 = split + 1.5) the jump is two levels: the check can fail.
		LodTree.configure(1024, 2, 3.5, 3.5)
		t.eq(fullDetailJump(LodTree.select(37, -21)), 2, "control: unbalanced without the rule")
		local lod = Config.Lod
		LodTree.configure(lod.ViewDistance, lod.SplitDistance, lod.SplitDistanceL1, lod.UndergroundSplitDistanceL1)
	end)

	t.test("player settings: the underground split follows the cave view, within the rule", function()
		local values = PlayerSettings.defaults(false, 0)
		values.detailFalloff, values.fullDetail = 3, 3
		local expect = { [64] = 3, [96] = 3, [112] = 3.5, [128] = 4, [144] = 4, [176] = 4 }
		for reach, split in expect do
			values.caveView = reach
			local _, _, _, underground = PlayerSettings.lod(values)
			t.eq(underground, split, `cave view {reach}`)
		end
		values.detailFalloff, values.fullDetail, values.caveView = 4, 2, 80
		local _, _, l1, underground = PlayerSettings.lod(values)
		t.eq(l1, 2)
		t.eq(underground, 2.5, "80 blocks: 2.5 node sizes")
		-- Falloff lowered under full detail: the rule clamps full detail.
		values.fullDetail = 5
		values.detailFalloff = 2
		t.eq(PlayerSettings.balance(values)[1], "fullDetail")
		t.eq(values.fullDetail, 3)
	end)

	--[[ Presets ]]

	t.test("player settings: High is Config's view, Low its phone view, presets keep the rule", function()
		local high = PlayerSettings.defaults(false, 0, PlayerSettings.HIGH)
		local view, split, l1, underground = PlayerSettings.lod(high)
		t.eq(view, Config.Lod.ViewDistance, "view")
		t.eq(split, Config.Lod.SplitDistance, "split")
		t.eq(l1, Config.Lod.SplitDistanceL1, "full detail")
		t.eq(underground, Config.Lod.UndergroundSplitDistanceL1, "underground: today's cave view")
		t.eq(PlayerSettings.foliageDistance(high), Config.Lod.FoliageDistance, "plants")
		t.eq(PlayerSettings.on(high, "shadows"), Config.Render.Shadows)
		t.eq(PlayerSettings.on(high, "farShadows"), Config.Render.FarShadows)
		t.eq(PlayerSettings.lichenLightDistance(high), Config.Caves.LichenLightDistance, "lichen lights: all")
		local tunnels, caverns = PlayerSettings.revealRadii(high)
		t.eq(tunnels, Config.Caves.RevealRadius, "tunnels")
		t.eq(caverns, Config.Caves.RevealRadiusMax, "caverns")

		local low = PlayerSettings.defaults(true, 0)
		t.eq(low.preset, PlayerSettings.LOW, "phones start on Low")
		view, split, l1, underground = PlayerSettings.lod(low)
		local mobile = Config.Lod.Mobile
		t.eq(view, mobile.ViewDistance)
		t.eq(split, mobile.SplitDistance)
		t.eq(l1, mobile.SplitDistance, "phones' full detail is their split (as configure(..., nil))")
		t.eq(underground, mobile.UndergroundSplitDistanceL1, "phones' cave view")
		tunnels, caverns = PlayerSettings.revealRadii(low)
		t.eq(tunnels, Config.Caves.Mobile.RevealRadius)
		t.eq(caverns, Config.Caves.Mobile.RevealRadiusMax)
		t.eq(low.plants, Config.Lod.Mobile.FoliageDistance, "phones' plants")
		t.eq(low.shadows, 0, "Low: no shadows")
		t.eq(low.skipHidden, 1, "Low: hidden terrain skipped")
		t.eq(PlayerSettings.lichenLightDistance(low), Config.Caves.Mobile.LichenLightDistance, "phones' lichen lights")
		t.eq(low.farMeshes, if Config.Render.FarMeshes.Mobile then 1 else 0, "phones' far meshes")

		for index, preset in PlayerSettings.PRESETS do
			t.ok(preset.fullDetail <= preset.detailFalloff + 1, `{PlayerSettings.PRESET_NAMES[index]} keeps the rule`)
			for key, value in preset do
				t.eq(PlayerSettings.clamp(key, value), value, `{key} of preset {index} is a slider value`)
			end
		end
		local ultra = PlayerSettings.defaults(false, 0, PlayerSettings.ULTRA)
		t.eq(ultra.renderDistance, 4096)
		t.eq(ultra.farShadows, 1)
		local medium = PlayerSettings.defaults(false, 5)
		t.eq(medium.preset, PlayerSettings.MEDIUM)
		t.eq(medium.renderDistance, 1024)
	end)

	t.test("player settings: the default preset follows Roblox's quality level; Custom after a change", function()
		t.eq(PlayerSettings.defaultPreset(0), PlayerSettings.HIGH, "Automatic")
		for level = 1, 3 do
			t.eq(PlayerSettings.defaultPreset(level), PlayerSettings.LOW, `quality {level}`)
		end
		for level = 4, 6 do
			t.eq(PlayerSettings.defaultPreset(level), PlayerSettings.MEDIUM, `quality {level}`)
		end
		for level = 7, 10 do
			t.eq(PlayerSettings.defaultPreset(level), PlayerSettings.HIGH, `quality {level}`)
		end
		t.eq(PlayerSettings.defaultPreset(10, true), PlayerSettings.LOW, "phones")

		local values = PlayerSettings.defaults(false, 0)
		t.eq(PlayerSettings.presetOf(values), PlayerSettings.HIGH)
		values.renderDistance = 1536
		t.eq(PlayerSettings.presetOf(values), nil, "Custom")
		-- Settings no preset sets don't make it Custom.
		values = PlayerSettings.defaults(false, 0)
		values.fov, values.masterVolume, values.fog = 90, 20, 0
		t.eq(PlayerSettings.presetOf(values), PlayerSettings.HIGH)
		-- Applying a preset reports what changed and matches it.
		local changed = PlayerSettings.applyPreset(values, PlayerSettings.LOW)
		t.ok(table.find(changed, "renderDistance") and table.find(changed, "preset"), "changed keys")
		t.eq(PlayerSettings.presetOf(values), PlayerSettings.LOW)
		-- On phones High's 2048 blocks are 1024, and still read as High.
		local phone = PlayerSettings.defaults(true, 0, PlayerSettings.HIGH)
		t.eq(phone.renderDistance, 1024)
		t.eq(PlayerSettings.presetOf(phone, true), PlayerSettings.HIGH)
	end)

	t.test("player settings: load applies the saved preset, then the saved choices", function()
		local values, chosen = PlayerSettings.load({}, false, 0)
		t.eq(values.preset, PlayerSettings.HIGH, "nothing saved: the device default")
		t.eq(next(chosen), nil, "nothing chosen")
		values, chosen = PlayerSettings.load({ preset = PlayerSettings.ULTRA, fov = 95 }, false, 2)
		t.eq(values.renderDistance, 4096, "Ultra's view, whatever the quality level")
		t.eq(values.fov, 95)
		t.ok(chosen.preset and chosen.fov and not chosen.renderDistance, "chosen keys")
		values = PlayerSettings.load({ renderDistance = 768, fullDetail = 5 }, false, 0)
		t.eq(values.renderDistance, 768, "a chosen value over the preset")
		t.eq(values.fullDetail, values.detailFalloff + 1, "balanced")
		values = PlayerSettings.load({ renderDistance = 4096 }, true, 0)
		t.eq(values.renderDistance, 1024, "phone limit")
	end)

	--[[ Meanings and text ]]

	t.test("player settings: brightness, FOV effects, volumes, lights and the build budget", function()
		local values = PlayerSettings.defaults(false, 0)
		local base = Config.Lighting.CaveAmbient
		local moody = PlayerSettings.caveAmbient(values, base)
		t.eq(moody[1], base[1])
		t.eq(moody[3], base[3])
		values.brightness = 100
		local bright = PlayerSettings.caveAmbient(values, base)
		t.ok(bright[1] >= 90 and bright[3] >= 100, "Bright")
		values.brightness = 50
		local half = PlayerSettings.caveAmbient(values, base)
		t.ok(half[1] > moody[1] and half[1] < bright[1], "between")
		t.near(PlayerSettings.fovModifier(1.15, values), 1.15, 1e-9, "100%")
		values.fovEffects = 0
		t.eq(PlayerSettings.fovModifier(1.15, values), 1, "off")
		values.fovEffects = 50
		t.near(PlayerSettings.fovModifier(1.1, values), 1.05, 1e-9, "half")
		values.masterVolume = 40
		t.near(PlayerSettings.volume(values, "masterVolume"), 0.4, 1e-9)
		values.lichenLights = 48
		t.eq(PlayerSettings.lichenLightDistance(values), 48)
		values.lichenLights = PlayerSettings.ALL_LIGHTS
		t.eq(PlayerSettings.lichenLightDistance(values), math.huge, "All")
		values.buildBudget = 0
		t.eq(PlayerSettings.buildBudget(values), nil, "Auto")
		values.buildBudget = 6
		t.eq(PlayerSettings.buildBudget(values), 6)
		local effects = PlayerSettings.effectsOf("renderDistance")
		t.ok(table.find(effects, "lod") and table.find(effects, "fog"), "the view moves the fog too")
		t.ok(table.find(PlayerSettings.effectsOf("caveView"), "lod"), "the cave view moves full detail")
	end)

	t.test("player settings: button texts read like Minecraft's and fit a 150 pixel button", function()
		t.eq(PlayerSettings.text("renderDistance", 2048), "Render Distance: 2048")
		t.eq(PlayerSettings.text("fullDetail", 3), "Full Detail: 96")
		t.eq(PlayerSettings.text("detailFalloff", 2.5), "Detail Falloff: 2.5")
		t.eq(PlayerSettings.text("plants", 0), "Plant Distance: OFF")
		t.eq(PlayerSettings.text("lichenLights", PlayerSettings.ALL_LIGHTS), "Lichen Lights: All")
		t.eq(PlayerSettings.text("buildBudget", 0), "Build Budget: Auto")
		t.eq(PlayerSettings.text("buildBudget", 5), "Build Budget: 5 ms")
		t.eq(PlayerSettings.text("shadows", 1), "Shadows: ON")
		t.eq(PlayerSettings.text("fov", 70), "FOV: Normal")
		t.eq(PlayerSettings.text("fov", 110), "FOV: Quake Pro")
		t.eq(PlayerSettings.text("brightness", 0), "Brightness: Moody")
		t.eq(PlayerSettings.text("brightness", 40), "Brightness: 40%")
		t.eq(PlayerSettings.text("toggleSprint", 1), "Sprint: Toggle")
		t.eq(PlayerSettings.text("skipHidden", 1), "Hidden Terrain: Skip")
		t.eq(PlayerSettings.text("guiScale", 0), "GUI Scale: Auto")
		t.eq(PlayerSettings.text("guiScale", 2), "GUI Scale: 2")
		t.eq(PlayerSettings.text("toggleSneak", 0), "Sneak: Hold")
		t.eq(PlayerSettings.text("sensitivity", 100), "Sensitivity: 100%")
		t.eq(PlayerSettings.text("sensitivity", 0), "Sensitivity: *yawn*")
		t.eq(PlayerSettings.text("scrollSensitivity", 0), "Scroll Sensitivity: 1.00")
		t.eq(PlayerSettings.text("scrollSensitivity", -200), "Scroll Sensitivity: 0.01")
		t.eq(PlayerSettings.text("scrollSensitivity", 100), "Scroll Sensitivity: 10.00")
		t.eq(PlayerSettings.text("attackIndicator", 1), "Attack Indicator: Crosshair")
		t.eq(PlayerSettings.text("damageTilt", 0), "Damage Tilt: OFF")
		t.eq(PlayerSettings.valueText("key.forward", 119), "W")
		t.eq(PlayerSettings.valueText("key.attack", 1018), "Left Button")
		t.eq(PlayerSettings.valueText("key.attack", 0), "Not Bound")
		-- The pixel font is 8 pixels a character; buttons shrink text down to 6 for 24 of them.
		-- (Key bindings show their name and their key apart: the key on a 100 pixel button, at
		-- most 15 characters at size 6, "[ ... ]" around it when it conflicts at size 5.)
		local longest, which = 0, ""
		local KeyBindings = require(shared.KeyBindings)
		for _, key in KeyBindings.KEYS do
			t.ok(#key.text <= 15, `{key.text} fits the key button`)
		end
		-- (Settings on a whole row, 310 pixels: Minecraft's longer texts, "Sensitivity:
		-- HYPERSPEED!!!", "Attack Indicator: Crosshair", get 48.)
		local Pages = require(client.Settings.Pages)
		local wide: { [string]: boolean } = {}
		for _, page in Pages.list do
			for _, item in page.items do
				if item.kind == "setting" and item.wide then
					wide[item.id] = true
				end
			end
		end
		local longestWide = 0
		for _, entry in ENTRIES do
			if entry.kind == "key" then
				continue
			end
			local value = entry.min
			while value <= entry.max do
				local text = PlayerSettings.text(entry.key, value)
				if wide[entry.key] then
					longestWide = math.max(longestWide, #text)
				elseif #text > longest then
					longest, which = #text, text
				end
				value += entry.step
			end
		end
		t.ok(longest <= 24, `longest text "{which}" ({longest} characters)`)
		t.ok(longestWide <= 48, "whole row texts")
	end)

	--[[ Wire and saving ]]

	t.test("player settings: encode / decode round trip, unknown ids and NaN dropped, clamped", function()
		local values = PlayerSettings.defaults(false, 0)
		values.renderDistance, values.detailFalloff, values.fov, values.masterVolume = 3072, 2.5, 93, 37
		local b = Protocol.encodeSettings(Profile.Desktop, values)
		t.eq(buffer.len(b), 3 + #ENTRIES * 5, "5 bytes a setting")
		local profile, decoded = Protocol.decodeSettings(b)
		t.eq(profile, Profile.Desktop)
		for key, value in values do
			t.eq((decoded :: any)[key], value, key)
		end
		-- Only what is given is sent.
		local _, partial =
			PlayerSettings.decode(PlayerSettings.encode(Profile.Touch, { renderDistance = 4096, fov = 80 }))
		t.eq((partial :: any).renderDistance, 1024, "a touch profile is clamped to the phone limit")
		t.eq((partial :: any).fov, 80)
		t.eq((partial :: any).shadows, nil, "not sent, not there")
		-- Unknown id, NaN and out of range.
		local raw = buffer.create(3 + 3 * 5)
		buffer.writeu8(raw, 0, PlayerSettings.VERSION)
		buffer.writeu8(raw, 1, Profile.Console)
		buffer.writeu8(raw, 2, 3)
		buffer.writeu8(raw, 3, 250)
		buffer.writef32(raw, 4, 1)
		buffer.writeu8(raw, 8, PlayerSettings.byKey.fov.id)
		buffer.writef32(raw, 9, 0 / 0)
		buffer.writeu8(raw, 13, PlayerSettings.byKey.masterVolume.id)
		buffer.writef32(raw, 14, 1e9)
		local p, odd = PlayerSettings.decode(raw)
		t.eq(p, Profile.Console)
		t.eq((odd :: any).fov, nil, "NaN dropped")
		t.eq((odd :: any).masterVolume, 100, "clamped")
		local count = 0
		for _ in odd :: any do
			count += 1
		end
		t.eq(count, 1, "unknown id dropped")
		-- Malformed: version, profile, length.
		local function corrupt(offset: number, value: number)
			local copy = buffer.create(buffer.len(b))
			buffer.copy(copy, 0, b)
			buffer.writeu8(copy, offset, value)
			return copy
		end
		t.eq((PlayerSettings.decode(corrupt(0, 2))), nil, "version")
		t.eq((PlayerSettings.decode(corrupt(1, 0))), nil, "profile 0")
		t.eq((PlayerSettings.decode(corrupt(1, 4))), nil, "profile 4")
		t.eq((PlayerSettings.decode(corrupt(2, 200))), nil, "count beyond the payload")
		t.eq((PlayerSettings.decode(buffer.create(2))), nil, "too short")
		local empty = PlayerSettings.encode(Profile.Desktop, {})
		t.eq(buffer.len(empty), 3)
		local _, none = PlayerSettings.decode(empty)
		t.eq(next(none :: any), nil, "an empty profile")
	end)

	t.test("player settings: the saved record keeps one profile per device class", function()
		local profiles = {
			[Profile.Desktop] = { renderDistance = 3072, preset = 4 },
			[Profile.Touch] = { renderDistance = 768 },
		}
		local record = PlayerSettings.toRecord(profiles)
		t.eq(record.v, 1)
		t.eq(record.desktop[tostring(PlayerSettings.byKey.renderDistance.id)], 3072, "keys are id strings")
		t.eq(record.console, nil, "no empty profiles")
		local back = PlayerSettings.fromRecord(record)
		t.eq(back[Profile.Desktop].renderDistance, 3072)
		t.eq(back[Profile.Desktop].preset, 4)
		t.eq(back[Profile.Touch].renderDistance, 768)
		t.eq(back[Profile.Console], nil)
		-- Malformed records lose only what is malformed.
		local odd = PlayerSettings.fromRecord({ desktop = { ["2"] = "far", ["999"] = 1, ["26"] = 200 }, touch = 5 })
		t.eq(odd[Profile.Desktop].renderDistance, nil)
		t.eq(odd[Profile.Desktop].fov, 110, "clamped")
		t.eq(next(odd[Profile.Touch]), nil)
		t.eq(next(PlayerSettings.fromRecord("junk")), nil)
		t.eq(next(PlayerSettings.fromRecord(nil)), nil)
	end)
end
