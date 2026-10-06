--[[
	Sounds: the catalogue (Shared/Sounds: Minecraft's event names, block sound types and their
	per action scaling, lookups for chests, armor and falls, override names), the Protocol `Sound`
	message, the server's routing of sounds to the players near them (Audio/Sounds), chest lids
	(Containers' onOpeners, also through InventoryState) and where item pickups sound (EntityWorld).
]]

return function(t, shared, require, server, _client)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Config = require(shared.Config)
	local Protocol = require(shared.Net.Protocol)
	local Sounds = require(shared.Sounds)
	local SoundList = require(shared.Sounds.SoundList)
	local MusicList = require(shared.Sounds.MusicList)
	local ServerSounds = require(server.Audio.Sounds)
	local Containers = require(server.Players.Containers)
	local InventoryState = require(server.Players.InventoryState)
	local EntityWorld = require(server.Entities.EntityWorld)

	local B = Blocks.id
	local I = Items.id

	local function name(index: number?): string?
		local event = if index then Sounds.get(index) else nil
		return if event then event.name else nil
	end

	t.test("sounds: every block sound type has Minecraft's five actions", function()
		t.eq(#Blocks.SOUND_TYPES, 10, "ten types")
		for _, typeName in Blocks.SOUND_TYPES do
			for _, action in Sounds.ACTIONS do
				local event = Sounds.get(`block.{typeName}.{action}`)
				t.ok(event, `block.{typeName}.{action} exists`)
				t.eq(event.category, `block.{action}`, "category")
				t.eq(event.source, "blocks", "source")
			end
		end
		-- Block events come first, in type and action order.
		t.eq(Sounds.events[1].name, "block.stone.break", "first event")
		t.eq(Sounds.events[#Blocks.SOUND_TYPES * #Sounds.ACTIONS + 1].name, SoundList.EVENTS[1].name, "then the list")
		t.eq(Sounds.count, #Blocks.SOUND_TYPES * #Sounds.ACTIONS + #SoundList.EVENTS, "count")
	end)

	t.test("sounds: Minecraft's event names, numbered in order, unknown names fail loudly", function()
		for _, wanted in
			{
				"block.chest.open",
				"block.chest.close",
				"block.furnace.fire_crackle",
				"entity.item.pickup",
				"entity.item.break",
				"entity.player.hurt",
				"entity.player.death",
				"entity.player.small_fall",
				"entity.player.big_fall",
				"entity.generic.splash",
				"entity.generic.swim",
				"item.armor.equip_generic",
				"item.armor.equip_leather",
				"item.armor.equip_chain",
				"item.armor.equip_iron",
				"item.armor.equip_gold",
				"item.armor.equip_diamond",
				"ui.button.click",
				"ambient.cave",
			}
		do
			t.ok(Sounds.find(wanted), `{wanted} exists`)
		end
		for index, event in Sounds.events do
			t.eq(event.index, index, `{event.name} index`)
			t.eq(Sounds.id[event.name], index, `{event.name} id`)
			t.eq(Sounds.get(index), event, "get by number")
			t.eq(Sounds.get(event.name), event, "get by name")
		end
		t.eq(Sounds.find("block.stone.explode"), nil, "find: nil")
		t.eq(Sounds.get("nope"), nil, "get: nil")
		t.eq(Sounds.get(0), nil, "get 0")
		t.ok(not pcall(function()
			return Sounds.id["block.stone.explode"]
		end), "id errors on unknown names")
	end)

	t.test("sounds: every event is well formed and plays a file every client ships", function()
		-- content/sounds in Roblox's file manifest (version 0.741, MaximumADHD/Roblox-Client-Tracker
		-- rbxManifest.txt): every sound file a client has. The classic gear sounds (glassbreak.wav,
		-- snap.wav, button.wav, swordslash.wav, unsheath.wav...) and uuhhh.mp3 are gone.
		local SHIPPED = {
			["action_falling.ogg"] = true,
			["action_footsteps_plastic.mp3"] = true,
			["action_get_up.mp3"] = true,
			["action_jump.mp3"] = true,
			["action_jump_land.mp3"] = true,
			["action_swim.mp3"] = true,
			["impact_explosion_03.mp3"] = true,
			["impact_water.mp3"] = true,
			["oof.ogg"] = true,
			["ouch.ogg"] = true,
			["volume_slider.ogg"] = true,
		}
		local function certain(id: string): boolean
			local file = string.match(id, "^rbxasset://sounds/([^/]+)$")
			return file ~= nil and SHIPPED[file] == true
		end
		-- (The cave moods are the game's own uploads, MusicList.Moods; their fallback ships.)
		local function mood(id: string): boolean
			return table.find(MusicList.Moods, id) ~= nil and string.find(id, "^rbxassetid://%d+$") ~= nil
		end
		for _, id in Sounds.contentIds() do
			t.ok(certain(id) or mood(id), `{id} ships with every client`)
		end
		for _, event in Sounds.events do
			t.ok(
				string.find(event.id, "^rbxasset://sounds/") ~= nil or mood(event.id),
				`{event.name} is a built-in sound`
			)
			t.ok(event.volume > 0 and event.volume <= 2, `{event.name} volume {event.volume}`)
			t.ok(event.pitch > 0.1 and event.pitch < 4, `{event.name} pitch {event.pitch}`)
			t.ok(event.pitchVariance >= 0 and event.pitchVariance < event.pitch, `{event.name} variance`)
			t.ok(event.maxDistance > 0, `{event.name} distance`)
			t.ok(table.find(Sounds.SOURCES, event.source), `{event.name} source`)
			t.ok(table.find(Sounds.SIDES, event.side), `{event.name} side`)
			if event.ui then
				-- (Flat sounds are the local player's alone: the server never sends them.)
				t.eq(event.side, "client", `{event.name}: ui sounds are the client's`)
			end
			local fallback = event.fallback
			if fallback then
				t.ok(certain(fallback.id), `{event.name} falls back on a certain sound`)
				t.ok(fallback.volume > 0 and fallback.pitch > 0, `{event.name} fallback`)
			end
		end
		for _, event in Sounds.events do
			if mood(event.id) then
				t.ok(event.fallback ~= nil, `{event.name} falls back on a sound every client ships`)
			else
				t.ok(certain(event.id), `{event.name} ({event.id}) ships with every client`)
			end
		end
	end)

	t.test("sounds: the cave moods, one event each in the category ambient.cave", function()
		t.eq(#Sounds.MOODS, #MusicList.Moods, "one per mood sound")
		for i, name in Sounds.MOODS do
			local event = Sounds.get(name) :: any
			t.eq(name, `ambient.cave.mood{i}`)
			t.eq(event.id, MusicList.Moods[i])
			t.eq(event.category, "ambient.cave", "a developer's ambient.cave replaces them all")
			t.eq(event.source, "ambient")
			t.eq(event.side, "client")
			t.eq(event.volume, 0.5, "Minecraft's forAmbientMood volume")
			t.eq(event.maxDistance, 16, "heard 16 blocks away, fading linearly")
			t.eq(table.concat(Sounds.lookupNames(name), ","), `{name},ambient.cave`)
		end
		t.ok(Sounds.find("ambient.cave") ~= nil, "the stand-in stays for an empty list")
	end)

	t.test("sounds: the music list (MusicList): audio ids, surface and cave tracks", function()
		t.ok(#MusicList.Surface > 0 and #MusicList.Cave > 0, "both kinds have tracks")
		for kind, tracks in { Surface = MusicList.Surface, Cave = MusicList.Cave } do
			local seen = {}
			for i, track in tracks do
				t.ok(string.find(track.Id, "^rbxassetid://%d+$") ~= nil, `{kind} {i}: {track.Id}`)
				t.eq(type(track.Title), "string", `{kind} {i}: a title ("" for the audio's name)`)
				t.ok(not seen[track.Id], `{kind} {i}: listed once`)
				seen[track.Id] = true
			end
		end
		-- The sheet's ids, written out in full (it stored them in scientific notation).
		t.eq(MusicList.Surface[1].Id, "rbxassetid://113907623876478")
		t.eq(MusicList.Cave[1].Id, "rbxassetid://273398061")
		t.eq(MusicList.Moods[5], "rbxassetid://3231980820")
		t.eq(#MusicList.Surface, 12, "the sheet's 13 rows, one of them a repeat")
		t.eq(#MusicList.Cave, 2)
		t.eq(#MusicList.Moods, 10)
	end)

	t.test("sounds: blocks sound like Minecraft's sound types, by material unless set", function()
		local expected = {
			Stone = "stone",
			Bedrock = "stone",
			Cobblestone = "stone",
			Dirt = "gravel",
			CoarseDirt = "gravel",
			Podzol = "gravel",
			Gravel = "gravel",
			Grass = "grass",
			Mycelium = "grass",
			OakLeaves = "grass",
			Sand = "sand",
			Sandstone = "stone",
			Snow = "snow",
			Ice = "glass",
			PackedIce = "glass",
			BlueIce = "glass",
			Glass = "glass",
			GlowBlock = "glass",
			OakLog = "wood",
			Planks = "wood",
			Chest = "wood",
			CraftingTable = "wood",
			Torch = "wood",
			WallTorchNorth = "wood",
			Furnace = "stone",
			CoalOre = "stone",
			IronBlock = "metal",
			DiamondBlock = "metal",
			Lantern = "metal",
			HangingLantern = "metal",
			Cactus = "wool",
			Water = "water",
			WaterFlow3 = "water",
			WaterFalling = "water",
		}
		for blockName, sound in expected do
			t.eq(Blocks.soundType(B[blockName]), sound, blockName)
			t.eq(Blocks.get(B[blockName]).sound, sound, `{blockName} def`)
		end
		t.eq(Blocks.soundType(B.Air), nil, "air is silent")
		t.eq(Blocks.soundType(B.CaveAir), nil, "cave air is silent")
		t.eq(Blocks.soundType(-1), nil, "negative id")
		t.eq(Blocks.soundType(Blocks.count), nil, "past the end")
		t.eq(Blocks.soundType(1.5), nil, "fraction")
		-- Everything drawn makes a sound.
		for id = 0, Blocks.count - 1 do
			local def = Blocks.get(id)
			if def.kind ~= Blocks.KIND_NONE then
				t.ok(table.find(Blocks.SOUND_TYPES, def.sound), `{def.name} has a sound type`)
			end
			local index = buffer.readu8(Blocks.soundLut, id)
			t.eq(if index > 0 then Blocks.SOUND_TYPES[index] else nil, def.sound, `{def.name} lut`)
		end
	end)

	t.test("sounds: a block's events per action", function()
		t.eq(name(Sounds.block(B.Stone, "break")), "block.stone.break", "stone breaks")
		t.eq(name(Sounds.block(B.Planks, "place")), "block.wood.place", "planks placed")
		t.eq(name(Sounds.block(B.Grass, "step")), "block.grass.step", "grass steps")
		t.eq(name(Sounds.block(B.Dirt, "hit")), "block.gravel.hit", "dirt hit")
		t.eq(name(Sounds.block(B.Sand, "fall")), "block.sand.fall", "sand fallen on")
		t.eq(name(Sounds.block(B.WallTorchEast, "break")), "block.wood.break", "a wall torch")
		t.eq(name(Sounds.block(B.Water, "place")), "block.water.place", "water placed")
		t.eq(Sounds.block(B.Air, "break"), nil, "air")
		t.eq(Sounds.block(B.Stone, "explode"), nil, "unknown action")
		t.eq(Sounds.block(99999, "break"), nil, "unknown block")
	end)

	t.test("sounds: block events scale their clips like Minecraft's actions", function()
		local types = {}
		for _, blockType in SoundList.BLOCK_TYPES do
			types[blockType.name] = blockType
		end
		local function check(typeName: string, action: string, clipName: string, volume: number, pitch: number)
			local blockType = types[typeName]
			local clip = (blockType.actions and blockType.actions[action]) or blockType[clipName]
			local event = Sounds.get(`block.{typeName}.{action}`)
			local v, p = blockType.volume, blockType.pitch
			t.eq(event.id, clip.id, `{typeName} {action} id`)
			t.near(event.volume, (clip.volume or 0.5) * (v * volume[1] + volume[2]), 1e-9, `{typeName} {action} volume`)
			t.near(event.pitch, (clip.pitch or 1) * p * pitch, 1e-9, `{typeName} {action} pitch`)
		end
		for _, typeName in Blocks.SOUND_TYPES do
			-- Minecraft: break / place (v + 1) / 2 and 0.8, hit (v + 1) / 8 and 0.5, step v x 0.15,
			-- fall v x 0.5 and 0.75.
			check(typeName, "break", "dig", { 0.5, 0.5 }, 0.8)
			check(typeName, "place", "dig", { 0.5, 0.5 }, 0.8)
			check(typeName, "hit", "step", { 0.125, 0.125 }, 0.5)
			check(typeName, "step", "step", { 0.15, 0 }, 1)
			check(typeName, "fall", "step", { 0.5, 0 }, 0.75)
		end
		-- Glass shatters when broken, but is placed like stone.
		t.eq(Sounds.get("block.glass.break").id, "rbxasset://sounds/impact_explosion_03.mp3", "glass breaks")
		t.ok(Sounds.get("block.glass.break").duration, "only the explosion's crack")
		t.eq(Sounds.get("block.glass.place").id, Sounds.get("block.stone.place").id, "glass placed")
		local fallback = Sounds.get("block.glass.break").fallback
		t.ok(fallback ~= nil, "glass break falls back")
		t.near(fallback.pitch, 2.2 * 0.8, 1e-9, "the fallback is scaled too")
		-- Materials are told apart by pitch: placed (and broken), each type at least 5% above the
		-- last; glass is placed like stone and water splashes.
		local function placePitch(typeName: string): number
			return Sounds.get(`block.{typeName}.place`).pitch
		end
		local ladder = { "wool", "gravel", "stone", "sand", "wood", "grass", "metal", "snow" }
		for i = 2, #ladder do
			t.ok(placePitch(ladder[i]) >= placePitch(ladder[i - 1]) * 1.05, `{ladder[i]} placed above {ladder[i - 1]}`)
		end
		t.eq(placePitch("glass"), placePitch("stone"), "glass placed like stone")
		-- Walked on too (glass like stone, water swims).
		local stepped: { [number]: string } = {}
		for _, typeName in Blocks.SOUND_TYPES do
			if typeName ~= "glass" then
				local pitch = Sounds.get(`block.{typeName}.step`).pitch
				for other, otherName in stepped do
					t.ok(math.abs(pitch - other) > 0.02, `{typeName} steps unlike {otherName}`)
				end
				stepped[pitch] = typeName
			end
		end
		-- Steps are quieter than breaking, hits in between.
		local stoneStep = Sounds.get("block.stone.step")
		t.ok(stoneStep.volume < Sounds.get("block.stone.hit").volume, "steps quieter than hits")
		t.eq(stoneStep.duration, 0.3, "one footstep of the walking loop")
	end)

	t.test("sounds: who plays what", function()
		local sides = {
			["block.stone.break"] = "predicted",
			["block.stone.place"] = "predicted",
			["block.stone.hit"] = "client",
			["block.stone.step"] = "client",
			["block.stone.fall"] = "predicted",
			["block.chest.open"] = "server",
			["block.chest.close"] = "server",
			["block.furnace.fire_crackle"] = "client",
			["entity.item.pickup"] = "server",
			["entity.item.break"] = "server",
			["entity.player.hurt"] = "server",
			["entity.player.death"] = "server",
			["entity.player.small_fall"] = "predicted",
			["entity.player.big_fall"] = "predicted",
			["entity.generic.splash"] = "client",
			["entity.generic.swim"] = "client",
			["item.armor.equip_iron"] = "server",
			["ui.button.click"] = "client",
			["ambient.cave"] = "client",
		}
		for eventName, side in sides do
			t.eq(Sounds.get(eventName).side, side, eventName)
		end
		t.ok(Sounds.get("ui.button.click").ui, "clicks are flat")
		t.eq(Sounds.get("ui.button.click").source, "ui", "clicks follow the ui volume")
		t.eq(Sounds.get("ambient.cave").source, "ambient", "cave sounds are ambient")
		t.eq(Sounds.get("entity.player.hurt").source, "players", "hurt is a player sound")
		t.ok(not Sounds.get("entity.item.pickup").ui, "pickups are 3D")
	end)

	t.test("sounds: chest lids, armor, falls", function()
		t.eq(name(Sounds.container(B.Chest, true)), "block.chest.open", "chest opens")
		t.eq(name(Sounds.container(B.Chest, false)), "block.chest.close", "chest closes")
		t.eq(Sounds.container(B.Furnace, true), nil, "furnaces have no lid")
		t.eq(Sounds.container(B.CraftingTable, true), nil, "nor crafting tables")
		t.eq(Sounds.container(B.Stone, true), nil, "stone")
		t.eq(Sounds.container(-3, true), nil, "nonsense")

		t.eq(name(Sounds.armorEquip(I.LeatherBoots)), "item.armor.equip_leather", "leather")
		t.eq(name(Sounds.armorEquip(I.ChainmailChestplate)), "item.armor.equip_chain", "chainmail")
		t.eq(name(Sounds.armorEquip(I.IronHelmet)), "item.armor.equip_iron", "iron")
		t.eq(name(Sounds.armorEquip(I.GoldLeggings)), "item.armor.equip_gold", "gold")
		t.eq(name(Sounds.armorEquip(I.DiamondHelmet)), "item.armor.equip_diamond", "diamond")
		t.eq(Sounds.armorEquip(I.Stone), nil, "a block")
		t.eq(Sounds.armorEquip(I.Stick), nil, "a stick")
		t.eq(Sounds.armorEquip(I.IronPickaxe), nil, "a tool")
		for _, def in Items.list do
			if def.armor then
				t.ok(Sounds.armorEquip(def.id), `{def.name} has an equip sound`)
			end
		end

		local iron = { item = I.IronHelmet, count = 1 }
		local diamond = { item = I.DiamondHelmet, count = 1 }
		t.eq(name(Sounds.equip(nil, iron)), "item.armor.equip_iron", "put on")
		t.eq(Sounds.equip(iron, { item = I.IronHelmet, count = 1 }), nil, "the same stack again")
		t.eq(Sounds.equip(iron, nil), nil, "taken off")
		t.eq(name(Sounds.equip(iron, diamond)), "item.armor.equip_diamond", "swapped")
		t.eq(name(Sounds.equip(iron, { item = I.IronHelmet, count = 1, damage = 3 })), "item.armor.equip_iron", "worn")
		t.eq(Sounds.equip(nil, { item = I.IronHelmet, count = 0 }), nil, "empty")

		for halfHearts, expected in { [1] = "small", [4] = "small", [5] = "big", [30] = "big" } do
			t.eq(name(Sounds.fall(halfHearts)), `entity.player.{expected}_fall`, `{halfHearts} half hearts`)
		end
	end)

	t.test("sounds: override names, preloading, pitch variance", function()
		local function joined(list: { string }): string
			return table.concat(list, ",")
		end
		t.eq(joined(Sounds.lookupNames("block.stone.break")), "block.stone.break,block.break", "block")
		t.eq(joined(Sounds.lookupNames(Sounds.id["block.wool.step"])), "block.wool.step,block.step", "by number")
		t.eq(joined(Sounds.lookupNames("item.armor.equip_gold")), "item.armor.equip_gold,item.armor.equip", "armor")
		t.eq(joined(Sounds.lookupNames("entity.item.pickup")), "entity.item.pickup", "no category")
		t.eq(#Sounds.lookupNames("nope"), 0, "unknown")

		local ids = Sounds.contentIds()
		local seen = {}
		for _, id in ids do
			t.ok(not seen[id], `{id} once`)
			seen[id] = true
		end
		for _, event in Sounds.events do
			t.ok(seen[event.id], `{event.name} preloaded`)
			if event.fallback then
				t.ok(seen[event.fallback.id], `{event.name} fallback preloaded`)
			end
		end

		local pickup = Sounds.get("entity.item.pickup")
		t.near(Sounds.pitch(pickup, 0.5), pickup.pitch, 1e-9, "middle roll")
		t.near(Sounds.pitch(pickup, 0), pickup.pitch - pickup.pitchVariance, 1e-9, "lowest")
		t.ok(Sounds.pitch(pickup, 0.999999) <= pickup.pitch + pickup.pitchVariance, "highest")
		local death = Sounds.get("entity.player.death")
		t.eq(Sounds.pitch(death, 0.1), death.pitch, "no variance")
	end)

	t.test("sounds: the Sound message", function()
		local cues = {
			{ sound = 1, x = 10.5, y = 64.5, z = -3.25, volume = 1, pitch = 1 },
			{ sound = Sounds.count, x = -100000, y = 0, z = 5000.5, volume = 0.5, pitch = 1.75 },
			-- Clamped to 0..2.55, nonsense back to 1.
			{ sound = 2, x = 0, y = 0, z = 0, volume = 9, pitch = 0 / 0 },
		}
		local b = Protocol.encodeSounds(cues)
		t.eq(buffer.len(b), 2 + 3 * Protocol.SOUND_BYTES, "size")
		local decoded = Protocol.decodeSounds(b)
		t.ok(decoded, "decodes")
		t.eq(#decoded, 3, "count")
		t.eq(decoded[1].sound, 1, "sound")
		t.eq(decoded[1].x, 10.5, "x")
		t.eq(decoded[1].y, 64.5, "y")
		t.eq(decoded[1].z, -3.25, "z")
		t.eq(decoded[1].volume, 1, "volume")
		t.eq(decoded[1].pitch, 1, "pitch")
		t.eq(decoded[2].sound, Sounds.count, "last event")
		t.eq(decoded[2].x, -100000, "far x")
		t.eq(decoded[2].volume, 0.5, "half volume")
		t.eq(decoded[2].pitch, 1.75, "pitch")
		t.eq(decoded[3].volume, 2.55, "volume clamped")
		t.eq(decoded[3].pitch, 1, "NaN pitch")
		t.eq(#Protocol.decodeSounds(Protocol.encodeSounds({})), 0, "empty")
		t.eq(Protocol.decodeSounds(buffer.create(1)), nil, "too short")
		local cut = buffer.create(buffer.len(b) - 1)
		buffer.copy(cut, 0, b, 0, buffer.len(cut))
		t.eq(Protocol.decodeSounds(cut), nil, "truncated")
		t.eq(Protocol.ServerMessage.Sound, 7, "message number")
	end)

	t.test("sounds: the server sends each sound to the players near it but the one excluded", function()
		local slack = Config.Sounds.BroadcastSlack
		local queue = ServerSounds.newQueue()
		local breakSound = Sounds.id["block.stone.break"]
		queue:add(breakSound, 0.5, 64.5, 0.5, "breaker")
		local listeners = {
			{ key = "breaker", x = 1, y = 64, z = 1 },
			{ key = "near", x = 10, y = 64, z = 0 },
			{ key = "edge", x = 0.5 + 16 + slack - 0.01, y = 64.5, z = 0.5 },
			{ key = "far", x = 0.5 + 16 + slack + 0.01, y = 64.5, z = 0.5 },
			{ key = "above", x = 0.5, y = 64.5 + 30, z = 0.5 },
		}
		local out = queue:route(listeners)
		t.eq(out.breaker, nil, "the breaker heard it already")
		t.eq(out.far, nil, "too far")
		t.eq(out.above, nil, "too far above")
		t.ok(out.near and #out.near == 1, "near")
		t.ok(out.edge and #out.edge == 1, "at the edge")
		local cue = out.near[1]
		t.eq(cue.sound, breakSound, "sound")
		t.eq(cue.x, 0.5, "x")
		t.eq(cue.y, 64.5, "y")
		t.eq(cue.volume, 1, "volume")
		t.eq(cue.pitch, 1, "pitch")
		t.eq(#queue.pending, 0, "the queue empties")
		t.eq(next(queue:route(listeners)), nil, "nothing twice")

		-- Louder sounds carry further (Minecraft: 16 x volume).
		queue:add(breakSound, 0, 0, 0, nil, 2, 0.5)
		local loud = queue:route({ { key = "a", x = 32 + slack - 0.1, y = 0, z = 0 } })
		t.ok(loud.a and loud.a[1].volume == 2 and loud.a[1].pitch == 0.5, "loud sounds carry 32 blocks")
		-- No louder (nor further) than the message carries; nonsense plays at 1.
		queue:add(breakSound, 0, 0, 0, nil, 100)
		local capped = queue:route({
			{ key = "in", x = 16 * 2.55 + slack - 0.1, y = 0, z = 0 },
			{ key = "out", x = 16 * 2.55 + slack + 0.1, y = 0, z = 0 },
		})
		t.ok(capped["in"] and capped["in"][1].volume == 2.55, "the loudest a message carries")
		t.eq(capped.out, nil, "and no further")
		queue:add(breakSound, 0, 0, 0, nil, 0 / 0)
		local nan = queue:route({ { key = "a", x = 16 + slack - 0.1, y = 0, z = 0 } })
		t.ok(nan.a and nan.a[1].volume == 1, "a NaN volume plays at 1")

		-- At most `limit` per player, in the order played.
		for i = 1, 5 do
			queue:add(i, 0, 0, 0)
		end
		local limited = queue:route({ { key = "a", x = 0, y = 0, z = 0 } }, 3)
		t.eq(#limited.a, 3, "limit")
		t.eq(limited.a[1].sound, 1, "first first")
		t.eq(limited.a[3].sound, 3, "order")

		-- Flat (ui) sounds, unknown events and nonsense positions are never sent.
		queue:add(Sounds.id["ui.button.click"], 0, 0, 0)
		queue:add(Sounds.count + 1, 0, 0, 0)
		queue:add(breakSound, 0 / 0, 0, 0)
		queue:add(breakSound, math.huge, 0, 0)
		t.eq(#queue.pending, 0, "refused")

		-- Before the server starts it (and in tests) playing does nothing.
		ServerSounds.play("block.stone.break", 0, 0, 0)
		ServerSounds.playBlock(B.Stone, "break", 0, 0, 0)
		ServerSounds.play(nil, 0, 0, 0)
		t.ok(not pcall(ServerSounds.play, "block.stone.explode", 0, 0, 0), "typos fail loudly")
	end)

	t.test("sounds: what a player's own messages cause has a budget", function()
		local limiter = ServerSounds.newLimiter(4, 8)
		local allowed = 0
		for _ = 1, 20 do
			if limiter:allow("p", 10) then
				allowed += 1
			end
		end
		t.eq(allowed, 8, "a burst, then nothing")
		t.ok(limiter:allow("q", 10), "each player has their own")
		t.ok(not limiter:allow("p", 10.125), "half a sound later: not yet")
		t.ok(limiter:allow("p", 10.25), "a quarter second later (4 a second): one more")
		t.ok(not limiter:allow("p", 10.25), "only one")
		allowed = 0
		for _ = 1, 20 do
			if limiter:allow("p", 100) then
				allowed += 1
			end
		end
		t.eq(allowed, 8, "it refills up to the burst, no more")
		t.ok(Config.Sounds.PlayerRate >= 1, "the game's rate")
		t.ok(ServerSounds.allow("someone"), "the game's budget")
	end)

	t.test("sounds: chest lids open for the first viewer and close after the last", function()
		local store = Containers.new()
		local calls = {}
		store.onOpeners = function(x, y, z, container, opened)
			table.insert(calls, `{x},{y},{z} {container.block} {if opened then "open" else "close"}`)
		end
		local chest = B.Chest
		store:get(1, 2, 3, chest)
		store:addViewer(1, 2, 3, "a")
		t.eq(table.concat(calls, ";"), `1,2,3 {chest} open`, "first viewer")
		store:addViewer(1, 2, 3, "b")
		store:addViewer(1, 2, 3, "a")
		t.eq(#calls, 1, "more viewers: no sound")
		store:removeViewer(1, 2, 3, "a")
		t.eq(#calls, 1, "one left")
		store:removeViewer(1, 2, 3, "a")
		t.eq(#calls, 1, "not a viewer any more")
		store:removeViewer(1, 2, 3, "b")
		t.eq(calls[2], `1,2,3 {chest} close`, "last viewer")
		-- (The empty chest was forgotten; opening it again makes it again.)
		store:get(1, 2, 3, chest)
		store:addViewer(1, 2, 3, "a")
		t.eq(#calls, 3, "opened again")
		-- A chest broken while open closes silently (its break sound plays instead).
		store:take(1, 2, 3)
		t.eq(#calls, 3, "taken: no close")
		-- Without a listener nothing happens.
		local plain = Containers.new()
		plain:get(0, 0, 0, chest)
		plain:addViewer(0, 0, 0, "a")
		plain:removeViewer(0, 0, 0, "a")
	end)

	t.test("sounds: a chest broken while players have it open makes no closing sound", function()
		local store = Containers.new()
		local calls = {}
		store.onOpeners = function(x, y, z, _container, opened)
			table.insert(calls, `{x},{y},{z} {if opened then "open" else "close"}`)
		end
		local state = InventoryState.new(store)
		state:join("a")
		state:join("b")
		state:open("a", 1, 2, 3, B.Chest)
		state:open("b", 1, 2, 3, B.Chest)
		state:window("a").container.slots[1] = { item = I.Dirt, count = 3 }
		t.eq(table.concat(calls, ";"), "1,2,3 open")
		-- Broken (Players/Inventories.removeContainer): its viewers' windows close, silently.
		local contents = state:removeContainer(1, 2, 3)
		t.eq(table.concat(calls, ";"), "1,2,3 open", "no lid closing")
		t.eq(#contents, 1, "its contents still drop")
		t.eq(state:openPosition("a"), nil, "closed for a")
		t.eq(state:openPosition("b"), nil, "and for b")
		t.eq(state:window("b").id, 0)
		t.eq(store.count, 0)
		-- Closed by its last viewer, a chest still closes with a sound.
		state:open("a", 4, 5, 6, B.Chest)
		state:close("a")
		t.eq(table.concat(calls, ";"), "1,2,3 open;4,5,6 open;4,5,6 close")
	end)

	t.test("sounds: pickups are heard at the item", function()
		local function getBlock(_x, y, _z)
			return if y < 0 then B.Stone else B.Air
		end
		local world = EntityWorld.new(getBlock, { maxItems = 100, lifetimeTicks = 6000 })
		world:spawnItem(I.Stone, 3, 2.5, 0, 4.5, 0, 0, 0, 0)
		local where = nil
		world:tick({ { key = "p", x = 2.5, y = 0, z = 4.5 } }, function(_key, _item, count, _damage, x, y, z)
			where = { x, y, z }
			return count
		end)
		t.ok(where, "picked up")
		t.near(where[1], 2.5, 1e-6, "x")
		t.ok(where[2] > 0 and where[2] < 0.25, "the middle of the item's box")
		t.near(where[3], 4.5, 1e-6, "z")
	end)
end
