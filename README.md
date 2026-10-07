# IceVoxel

A fast, Minecraft-style voxel engine for Roblox.

- **Client-side generation in parallel.** Terrain is generated from the world seed on every
  client, inside a pool of Actors (Parallel Luau). The server never sends terrain, only edits.
- **Level of detail.** A quadtree of chunk sizes gives a default view distance of 2048 blocks
  (128 chunks). Far chunks use cells up to 64 blocks wide (but at most 16 tall, so mountains keep
  their shape). LOD changes swap in place without holes or flicker.
- **Greedy box meshing.** Blocks become as few Parts as possible; blocks you can never see are
  merged into neighbouring boxes for free, and caves are only meshed where an underground camera
  can see into them.
- **No flicker on edits.** Placing or breaking a block swaps only the parts that changed (a median
  of 1 part built, where ~300 were rebuilt before), every section the edit touches (in both
  chunks of a border too) goes live in the same frame, and the old geometry stays two frames under
  the new one (`Render.SwapFrames`; water and glass too), so an edit never shows the sky through
  the terrain. Edits have their own lane in the workers and the renderer and never wait behind
  loading.
- **A title screen, operators and creating the world.** Minecraft's title screen greets every
  player (a pixel logo, a pulsing yellow splash, a slowly sliding sky of clouds and hills): the
  first player to join a server becomes its operator and creates the world from Minecraft 1.20's
  Create World screen (World Name, Game Mode, Difficulty, Allow Commands; World Type with a
  generic Customize screen for a type's settings, the seed read as Minecraft reads it, Generate
  Structures), and everyone joins it with Join World. Until then the world doesn't exist at all
  and nobody has a character. Operators (`/op`, `/deop`) may use the cheat commands; Load World
  waits for saves, which are for later.
- **Loading what you see first.** Terrain loads in the order you need it: the ground under you,
  then what is in front of the camera, then what is just behind, then the rest, and terrain hidden
  behind mountains last; after a teleport 90% of the view is there 15-40% sooner. A teleport drops
  the old area at once instead of keeping it until the new one is built: you can move 16-31 frames
  after landing instead of 33-274, no frame puts more than ~700 parts into the workspace (it was up
  to 22,600), and the old area leaves at most 3,000 parts a frame (a far teleport used to destroy
  25,000-131,000 in one frame). Part building adapts to the frame time (2-8 ms a frame, 12 ms while
  you wait for the ground), and far meshes are not built while you move or terrain loads. (Measured
  in Lune with the real streamer and renderer on fake instances.)
- **Terrain like JJThunder To The Max.** A 1024 block tall world in the style of the Minecraft
  datapack: mountain ranges up to ~900 blocks high with snowy peaks, eroded flanks and plateau
  hills, plains, wide river valleys and enclosed seas with islands. Its height functions are ported
  directly and scaled to fit. 18 biomes are picked by altitude band (lowland, forest, highland,
  meadow, alpine, snowy slopes, peaks), then by climate.
- **Caves, ores and structures.** Dry caves that grow with depth, from tunnels to huge stratified
  caverns, and the Underlands: a cavern hundreds of blocks tall under the highest mountains. Ores and
  stone varieties by altitude, and a deterministic structure system (trees and cacti, and jigsaw
  structures from the structure library: see Generated structures) that lets anything cross chunk
  borders.
- **Cave entrances and ravines.** Minecraft's cave and canyon carvers, adapted: air carved into
  the surface after the caves. Entrances are winding tunnels 3-7 blocks wide that open as pits on
  flat ground and as mouths in steep mountain flanks, lead 15-60 blocks down and end in a small
  chamber; a third of them fork once, and they steer towards the deep caves, so most (55-65%) run
  into the cave network. Ravines are rarer cuts 60-160 blocks long, up to about 12 blocks wide and
  20-45 deep in the middle, with jagged walls and always open to the sky, often down into a
  cavern. About 50-70 entrances and 1-6 ravines per km² of land: walking with ~30 blocks of view
  to either side you pass an entrance every 200-250 blocks. None opens under water, at the shore,
  by a river or within 2 blocks of a library structure, no tree stands over one and no spawn lands
  in one; grass and snow grow back on a pit's floor. Far ravines and pits show as cuts up to about
  400 blocks away (LOD levels 1-2).
- **Lava.** Minecraft 1.20.1's lava. Every cave below y 11 (`Caves.LavaLevel`) is flooded, so the
  deepest caves and the Underlands' floor under the highest mountains are lava seas (a cave
  entrance or ravine cut that deep ends in lava too); one in 3-6 cave-rich chunks has a lava lake
  with a stone rim sunk into a cave floor 30 or more blocks down; and rare lava lakes lie on the
  surface (Minecraft's lake_lava_surface, about 0.7-1.6 per km²) on dry land, never in snowy or wet
  biomes, by water, a structure, an oil lake or the spawn. Generated lava lies still until
  something next to it changes. It flows 3 blocks, a block every 1.5 s (no infinite sources),
  gives light 15 and glows, and hardens where water touches it, with a hiss: a source into
  **obsidian** (hardness 50: only a diamond pickaxe gets it, in 9.4 s), flowing lava into
  cobblestone, and lava pouring down into water turns the water into stone. Torches and plants it
  flows over burn without a drop. It hurts: 4 half hearts every half second in it (armor softens
  that), then burning for 15 s after you leave it, half a heart a second, unless water puts you
  out; burning players show flames, and in first person you see fire at the bottom of the screen.
  Creative and spectator players never burn. Dropped items burn up in it. You wade through it with
  Minecraft's lava physics (0.78 blocks a second, 40% of water's, sinking slowly, jump to rise; a
  fall into it hurts less), and with your eyes in it the view closes in to a block of orange fog.
  Lava open to the air pops and bubbles. A Lava Bucket picks it up and burns 20,000 ticks in a
  furnace (100 items; the empty bucket stays in the fuel slot). One PointLight per 16 × 16 × 16
  blocks of its drawn surface lights its surroundings (about one a chunk on a lava sea; those more
  than 96 blocks away, `Caves.LavaLightDistance`, 48 on phones, switch off but still glow), and the
  lava of hidden caves costs nothing until you go in.
- **Oil wells, oil and fuel.** BuildCraft's oil wells: one candidate per 512 × 512 blocks, about
  one well per km² of desert, savanna and plains (0.9-1.1), a quarter of that on other land, and
  small pockets under the sea floor (about 0.3 per km² of sea). A well is a buried sphere of oil
  20-40 blocks down (radius 8-12, 5-7 or 3-4 for large, medium and small wells: some 4,800, 900 or
  190 buckets), kept out of the caves. Large and medium wells on land have a geyser: a column of
  oil from the deposit up through a black oil lake (radius up to 10, 1-3 deep; smaller and ragged on
  rough ground or near water) to 16 or 6 blocks into the air, seen from afar and on the map as a
  black dot (0.2-0.3 geysers per km²). Generated oil lies still until something next to it changes:
  break into a geyser and it pours out. **Oil** is black, glossy and thick: it flows 7 blocks, a
  block a second, heading for a drop only up to 3 blocks away; you wade through it as through lava,
  but it doesn't hurt (it slows and coats you: see Oil and fuel on the skin), and it is no furnace
  fuel. The Oil Refinery turns it into **fuel**, amber and
  thin: it flows like water (without infinite sources), you swim in it, and the Combustion Generator
  burns it. With your eyes in oil you see 2 blocks, in fuel 32 (and under water the view now fogs
  over too, 96 blocks once your eyes are used to it). Oil and Fuel Buckets carry them. A buried
  deposit costs nothing to draw while caves are hidden.
- **Fuel explodes.** Fuel that touches fire or lava (any level, flowing or poured, the cave lava
  too) blows up, the harder the more of it is connected: the whole connected body (up to 4,096
  cells) goes off, a bucket as hard as TNT, 8 buckets twice that, 27 at the cap of power 12 (blast
  reach grows with the cube root of the charge; the thin film of a spread puddle counts little).
  A big pool is not one blast but a chain: one per 4 × 4 × 4 cube of it, rippling out from where
  it caught at 1.5 blocks a tick, and every blast is fiery, so a 16 × 16 × 4 tank's worth is a few
  dozen blasts of power 6 to 12 over a second or two that leave the crater burning. Only sources
  explode: spilt, flowing fuel burns like a fuse, each cell turning to fire 4 ticks after flame
  or lava reaches it (5 blocks a second), so a trail lit at its end burns back to its source,
  which goes off. Explosions are
  Minecraft 1.20.1's: 1352 rays losing strength to each block's blast resistance (stone 6, dirt
  0.5, obsidian 1200, water and lava 100: a blast in water breaks nothing), a block's drop with
  chance 1 / power, damage by distance and how much of you is in the open (TNT at point blank:
  57 half hearts, through armor and the hurt cooldown, none in creative and spectator), knockback
  that throws you (not in spectator or creative flight), items blown away or destroyed, the boom
  (`entity.generic.explode`, heard 64 blocks away), a flash and a short camera shake. Crude oil
  is no explosive.
- **TNT.** Minecraft 1.20.1's TNT: red with a white band, breaks at once, burns like it (15 / 100).
  Light it with flint and steel (on any face; the tool wears), by fire burning it (lava lights
  that fire), or with a blast: then it lights with a short fuse of 10-29 ticks, so a pile goes off
  in a ripple. Lit, it glows, flashes white, hisses (`entity.tnt.primed`), falls as Minecraft's
  primed TNT does (speeding up, through air, fire, plants and fluids, which it gives back), can't
  be broken, and 4 s later explodes with power 4 and no fire (in water it breaks nothing).
  **Gunpowder** (creepers drop it too, see Mobs): a coal or charcoal and a flint make two; TNT is
  Minecraft's recipe (5 gunpowder in an X, 4 sand).
- **The Nuke** (for fun, a mod's nuke). A dark casing with hazard stripes and the radiation sign,
  lit like TNT: it glows red, flashes and beeps every second for 10 s, then digs a crater no ray
  explosion could: a ragged sphere of radius 24 (± 20%, smooth noise and a block of crumble; the
  same place digs the same crater) where a block goes if its blast resistance is under 60 × (1 −
  distance / radius) (dirt to the rim, stone to 0.9 of it, obsidian, bedrock and fluids never: the
  sea pours in, an obsidian bunker stands), with no drops; around it to 40 blocks grass scorches to
  dirt and coarse dirt, leaves, plants, glass and snow are blown away and one spot in six catches
  fire; TNT and Nukes it reaches are lit. It grows outwards from the centre at 500 edits a tick
  (about 33,000 edits over 3-4 s on open ground), never into unloaded chunks. Players: Minecraft's
  explosion damage at power 28, deadly in the open within about 50 blocks, walls and hills
  shielding; everyone within 256 blocks sees a white flash, a fireball, a shock ring and a rising
  mushroom cloud, hears the boom and feels a long shake. Eight TNT around a block of diamond.
- **Fire.** Minecraft 1.20.1's fire. It burns on top of a block, or clings to the sides of
  flammable blocks when there is no floor, and spreads: every 1.5-2 s (30 + rand(10) ticks) it may
  burn a neighbour away (Minecraft's burn odds: leaves and plants fast, logs and coal blocks
  slowly), sometimes leaving fire in its place, and catch the air around it (1 block sideways, 1
  below, up to 4 above) next to anything flammable, with Minecraft's ignite odds (planks 5 / 20,
  logs 5 / 5, leaves 30 / 60, grass, ferns and flowers 60 / 100, glow lichen 15 / 100, blocks of
  coal 5 / 5; not saplings, mushrooms or stone). It ages and burns out: on stone or with nothing
  left to burn it goes out within seconds. Light it with **Flint and Steel** (an iron ingot and
  flint; 64 uses; gravel drops flint one time in 10) on any face where fire can burn; lava sets
  flammable blocks near it alight on its random ticks; burning fuel leaves it behind. Put it out
  by punching it (it breaks at once, with a hiss), with water, or by placing a block into it.
  Standing in it costs half a heart every half second (armor softens it) and sets you burning for
  8 s after a second in it; dropped items burn up in it. Spawns avoid it. The flames are the
  animated fire texture (8 frames, 0.8 s a loop, all fires in step) on Minecraft's planes: four
  leaning planes and the four sides of the cell on the floor, a plane on each burning wall
  otherwise, glowing at night as by day, drawn within 48 blocks; one light per 8 × 8 × 8 blocks of
  fire (like glow lichen) keeps a forest fire to a few lights. It crackles. Its age stays on the
  server (`Config.Server.Fire`: the doFireTick rule and the difficulty).
- **Lakes and puddles.** Minecraft's water lakes (lake_water, from before 1.18): the lava lakes'
  irregular basin of blobs, water 1-3 deep in its lower half and the bowl above it dug out, on
  dry land, never by the sea, a river, a structure, an oil well or a lava lake (0.3-0.6 per km²,
  rarer than lava lakes); frozen over with ice in snowy biomes, with a sand or gravel floor where
  the biome's water has one, else patches of sand, gravel and dirt (about 40 / 30 / 30 %), and
  patches of sand and gravel along the water's edge (about half the shore; the rest of the rim
  stays grass). Puddles lie in natural dips: water in place of the top block of 3-20 columns
  (median 10-15) at the bottom of a hollow, most in jungles, mushroom fields and forests (50-120
  per km²), fewer on plains and meadows (45-55), rare in savannas and deserts (2-25) and none in
  frozen biomes. Both are still water sources held in on every side and below, so nothing flows
  until you dig next to them; no tree or plant stands in them and no cave entrance opens under
  them. Far terrain shows the lakes (LOD levels 1-2) and the map paints both (lakes up to 8
  blocks a pixel, puddles up to 2); puddles are drawn near the player only.
- **Thirst and body temperature (Tough As Nails).** The Tough As Nails mod's survival, after its
  1.20 version. Thirst is Minecraft's hunger with water: 20 points (10 droplets on the right above
  the hotbar) and hydration that goes first, drained by exhaustion (sprinting 0.1 a metre,
  swimming 0.01, a jump 0.05, a sprint jump 0.2, a block broken 0.005, a hurt 0.1, sweating while
  hot). At 0 you lose half a heart every 6 s down to half a heart, and health only comes back
  with 18 or more (half a heart every 4 s, for 6 exhaustion; Roblox's own regeneration is off).
  Drink from a water source with an empty hand (1 point), fill a Glass Bottle (three glass in a
  V make three) or a Canteen (an iron nugget over three iron ingots in a cup; three sips) at a
  water source, and hold use 1.6 s to drink: dirty water gives 4 points with a 50% chance of the
  Thirst effect (15 s of extra exhaustion, the droplets turn green), purified water (smelt the
  dirty bottle or canteen in a furnace) 6 and hydration with no risk. Body temperature is a
  number from -10 to 10 in five zones (icy -10..-8, cold, neutral -2..2, warm, hot 8..10) that
  steps towards what the place says, a step every 7 s (3.5 s back towards neutral): the biome
  (tundra -10, taiga -4, plains 0, jungle 7, desert 9), colder high up and outdoors at night,
  milder under a roof (towards neutral, day and night: a taiga house is -2), neutral deep
  underground; being wet cools 3 steps, sprinting warms 2,
  lava, fire, a campfire, a lit furnace or a working generator within 5 blocks warm 3 (5 within
  2 blocks), ice and snow cool 3 (not that close to a fire), and armor insulates (leather and
  straw warm a step a piece towards neutral, leather stops freezing too; leaves cool a step).
  Icy for 20 s freezes you (half a heart every 5 s, and no health comes back meanwhile, whatever
  you drink), hot overheats you the same way and makes you sweat, so the harshest cold takes
  about 3 minutes to kill from neutral; a drink can give Internal Warmth or Chill, which hold
  the cold or the heat off. Joining gives 5 minutes of
  Climate Clemency (a respawn 1): the temperature stays neutral, thirst drains at half the rate
  and doesn't hurt. Frost or heat closes in from the screen's edges, and a thermometer over the
  droplets shows the temperature, coloured by zone, with an arrow for where it is going; the
  clemency's time left and the effects are status effect icons in the top right. Creative and
  spectator players are untouched.
  `Config.ToughAsNails` turns thirst or temperature off.
- **Herbs, bowls and teas (Tough As Nails).** Two herbs grow wild in rare small patches (about 4
  plants, some 30 blocks apart on open ground): **Mint** on plains, in meadows and jungles, and
  **Wild Ginger** under the trees of forests, birch forests and taigas, so the cold biomes have a
  warming herb. Breaking one gives Mint Leaves or Ginger Root, which plant it back on grass or dirt
  (one for one); left alone, a herb spreads to a spot next to it every 9 minutes or so, up to 5 in
  a 9 × 3 × 9 area (Minecraft's mushroom spreading), so a few planted together make a garden.
  **Bowls** (Minecraft's: three planks in a V make four) fill at water like bottles: a Dirty Water
  Bowl gives 4 thirst (the same 50% risk of the Thirst effect), a Purified Water Bowl 7, and
  drinking gives the bowl back. **Mint cures dirty water** without a furnace: a dirty bottle, bowl
  or canteen with Mint Leaves in a crafting grid (the inventory's 2 × 2 too) makes purified water
  (a canteen keeps its sips); the furnace purifies bowls as well. **Teas** are a Purified Water
  Bowl with a herb (stack 1, like stews): Mint Tea (7 thirst, more hydration, 2 minutes of
  Internal Chill: a desert's heat stays warm, never hot), Ginger Tea (2 minutes of Internal
  Warmth: a tundra's cold stays cold, never icy) and Herbal Tea with both herbs (8 thirst, a
  minute of each). A tea can be drunk when you aren't thirsty, and with thirst turned off, for its
  warmth or chill. Everything shows in JEI, WAILA and the creative inventory.
- **Gear for the cold and the heat (Tough As Nails).** The **Campfire** (Minecraft's: three sticks
  round a coal or charcoal over three logs) is always lit: light 15, glowing embers under fire's
  animated flames, crackling. It warms 3 steps within 5 blocks and 5 within 2, and that close it
  outweighs the snow and ice around (a tundra's -10 is -5 by the fire, cold but safe); walking
  into it costs half a heart every half second (armor softens it) without setting you alight. It
  drops itself (no Silk Touch here), so it can be moved. Right click it with dirty water to boil
  it clean, a bottle, bowl or canteen a click and one every 3 s (it burns no fuel, so the water
  takes its time: hold the button to boil the next when it is ready; mint is the quick cure; a
  canteen keeps its sips; JEI lists it as "Campfire").
  **Straw** comes from grass broken without Shears (short grass half the time, tall grass always)
  and makes **Straw armor** in the armor shapes (24 for a set), a step of warmth a piece: a full
  set holds a tundra at -6 by day and by night, out of the ice (three pieces just about). **Leaf
  armor** (any leaves, which Shears harvest) cools a step a piece: a desert's 9 becomes 5. Both
  have leather's armor points. A **Thermometer** (an iron nugget over glass over glow dust) held
  in the hand reads the body temperature and where it is going as numbers over the gauge.
- **Mobs.** Minecraft 1.20.1's farm animals and classic monsters as simple boxes moving about (a
  body in the kind's colour and a head on the side it faces): **cows** (0.9 × 1.4 blocks, 10
  health), **sheep** (0.9 × 1.3, 8; white, now and then black, grey, brown or pink), **pigs**
  (0.9 × 0.9, 10) and **chickens** (0.4 × 0.7, 4; they flap down slowly and take no fall damage)
  wander, stand about and run off when hurt; **zombies** (0.6 × 1.95, 20, armor 2) and
  **spiders** (1.4 × 0.9, 16; they climb walls, leap, and only hunt in the dark) hunt survival
  and adventure players they can see within 16 blocks and hit them (3 and 2 half hearts every
  second, through the armor, Resistance and the hurt cooldown, with a knockback); **skeletons** (0.6 × 1.99,
  20) shoot within 15 blocks every 3 s (3-5 an arrow; the arrows are hitscan, seen flying);
  **creepers** (0.6 × 1.7, 20) walk up, hiss within 3 blocks and 1.5 s later explode with power 3,
  unless you get 7 blocks away. Zombies and skeletons burn in daylight under the open sky (a
  tree's leaves shade them, glass doesn't). No block can be placed inside a mob. Mobs
  walk at Minecraft's speeds (a zombie 2.3 blocks a second), jump up blocks, never walk off a drop
  of more than 3 blocks or into lava, fire, oil or fuel, swim up in water, take fall, fire, lava
  and explosion damage (TNT, fuel and creepers hurt and throw them), flash red when hurt, tip
  over when they die and drop Minecraft's loot a second later: **Leather** and **Raw Beef**,
  **White Wool** and **Raw Mutton**, **Raw Porkchop**, **Feathers** and **Raw Chicken**, **Rotten
  Flesh** (and now and then an iron ingot), **Bones**, **String**, **Gunpowder**; meat drops
  cooked when the mob died burning. Raw meat cooks in a furnace; leather makes leather armor,
  four string a block of wool (which burns like Minecraft's). **Food:** hold right click 1.6 s
  with meat to eat it when hurt (steak and cooked porkchop heal 2 hearts, cooked mutton and
  chicken 1.5, raw meat less; raw chicken and rotten flesh may give Tough As Nails' Thirst
  effect). **Fighting:** a left click on a mob in reach (3 blocks, 6 in creative) hits it with
  Minecraft's weapon damage (the hand 1, swords 4-7, axes 7-9...; Strength adds 3 a level and
  Weakness takes 4) and 1.9's attack recovery (a sword hits at full strength every 0.6 s), knocks
  it back and wears the weapon; WAILA names the mob and its health. A kill is knowledge: the first
  of each kind 10 points, then 2 an animal, 5 a monster, 6 a creeper. Creatures spawn on grass in the light 24-44 blocks from players (10 at most
  around each, counting the monsters in the simulated chunks), monsters on solid ground in the
  dark, at night or in caves (15 at most; never by torchlight, as far as a torch's light reaches,
  13 blocks, however big the room), from the same light estimate WAILA shows; monsters vanish far
  from everyone (Minecraft's 128 and 32 block rules, those frozen out of reach too). Mobs only
  move within the simulated chunks around players and freeze beyond (a frozen mob that dies
  still goes). `/summon <kind> [x y z]` and `/kill @e[type=<kind>]` for operators.
  `Config.Mobs` sets the caps and turns spawning or mobs off.
- **Status effects.** Minecraft 1.20.1's MobEffects with their numbers: Speed (+20% ground speed a
  level) and Slowness (-15%), Haste (+20% mining speed a level) and Mining Fatigue (x 0.3, 0.09,
  0.0027...), Strength (+3 melee a level) and Weakness (-4, on hits on mobs), Jump Boost
  (+0.1 jump and a block less fall damage a level), Regeneration (half a heart every 50 >> amp
  ticks), Poison (every 25 >> amp, never the last half heart, through armor) and Wither (every
  40 >> amp, and it kills), Fire Resistance (no fire, lava, campfire or burning hurts), Resistance
  (20% of every hurt a level, mobs' and Tough As Nails' freezing and heatstroke too, not
  dehydration, which is starvation's; V: nothing), Night Vision (caves and nights lit, flickering in
  its last 10 s), Blindness (fog closing in to 5 blocks, no sprinting), Nausea (the camera rolls and
  the view sways, building up over 8 s), Instant Health and Instant Damage (4 and 6 half hearts,
  doubling a level) and Glowing (an outline everyone sees through walls). They stack and refresh
  as Minecraft's (a stronger effect wins, a weaker longer one waits underneath and comes back), run
  on the server, and the client's movement and mining prediction use the same numbers as the
  server's checks. Creative and spectator players get them too, but nothing hurts them. Death
  clears them; they are not saved. Icons in Minecraft's frames in the top right, under the minimap
  and the music toast (beneficial in the top row, the rest below, longest first, blinking out over
  their last 10 s; hover one, or tap it on a touch screen, for its name, level and time), and
  Minecraft's list of names and times beside any open screen; F3 lists them too. Tough As Nails'
  Thirst, Internal Warmth, Internal Chill and Climate Clemency are listed with them (its own
  status row over the hotbar shows only with `Config.Effects.Hud` off; the Thirst effect and the
  clemency wait in creative and spectator, their times standing still on the icons). `/effect give
  <player> <effect> [seconds | infinite] [amplifier]` and `/effect clear [player] [effect]` with
  Minecraft's ids and wording (operators, as `/time`).
- **Oil and fuel on the skin.** Wading in crude oil is Slowness II, and leaving it leaves you **Oil
  Coated** for 30 s: still slower (Slowness I's -15%), and anything that sets you burning burns
  twice as long and a half heart harder. Fuel's fumes make you sick (Nausea, 8 s after the last
  whiff) and, after 3 s in it, poison you (Poison I while in it, a half heart every 1.25 s, and
  up to 5 s after); it soaks you (**Fuel
  Soaked**, 20 s after leaving): fire catches at once, burning lasts three times as long, and a
  blast that reaches you sets you alight. A swim washes both off. The fluids' effects are data
  (`FluidList` `effects`), and `Config.Effects.FluidEffects` turns them off.
- **Potions.** Brewed in a crafting grid (the game has no brewing stand): a Purified Water Bottle
  with an ingredient makes a potion, the potion with Glow Dust (the game's glowstone) its level II
  and with a coal or charcoal its long variant, Minecraft's durations: Swiftness (Mint Leaves),
  Leaping (Cornflower), Strength (Gunpowder: creepers drop it), Healing (Gold Nugget), Harming (Red Mushroom), Poison
  (Lily of the Valley), Regeneration (Oxeye Daisy), Fire Resistance (Ginger Root), Night Vision
  (Glow Dust), Weakness (any tulip), and this game's Haste (Gold Ingot) and Resistance (Iron
  Ingot): 29 potions. Bottles of the effect's colour, stacking to 1; hold use 1.6 s to drink one
  (whatever your thirst, Tough As Nails on or off) and the Glass Bottle comes back. The tooltip
  lists the effect, its level and time, blue or red. Brewing is the Iron Age's, levels II and the
  long potions the Industrial Age's.
- **Four game modes.** Minecraft's survival, creative, adventure and spectator, switched with
  `/gamemode <mode>` (`/gm s`, `c`, `a`, `sp`, or `0`–`3`) in the chat, `F3` + `N` (spectator and
  back) or the `F3` + `F4` game mode switcher.
  - **Survival:** blocks take Minecraft's time to mine, by hand or with tools, cracking as they
    go, and drop as items that bob on the ground until someone walks over them. Stone and ores need
    a pickaxe of the right tier to drop anything (iron and osmium ore a stone pickaxe, diamonds an iron one),
    and tools wear out. Placing uses items up. Players have a Minecraft inventory: 36 slots, armor
    slots on the left and a 2 × 2 crafting grid at the top right; chests, crafting tables and
    furnaces open above it. Clicks work as in Minecraft: shift-click, number keys, dragging to
    spread, double click. Items drop on death.
  - **Creative:** an old-school "Item selection" picker with a search bar, instant breaking, flying
    (double tap jump), and nothing hurts.
  - **Adventure:** survival without building: blocks can't be broken or placed and items can't be
    used on them (buckets, the Configurator), and no block is outlined; chests, furnaces, crafting
    tables and machines still open. Health, falls, pickups, the inventory and death drops are
    survival's.
  - **Spectator:** always flies, through blocks and water, from the bottom of the world to 64
    blocks above its top (the mouse wheel sets the flying speed); nothing hurts. Players who don't
    spectate neither see nor hear a spectator (other spectators see a translucent floating head).
    Spectators pick up and change nothing, look into chests, furnaces and machines read only, and
    keep their inventory if they die. Instead of the hotbar, a number key or the middle click
    opens Minecraft's spectator menu: `1` "Teleport to Player" lists the other players' heads (7
    on the first page, then 6 a page), a player's number pressed twice teleports there, `9`
    closes it. A left click on a player looks through their eyes until you sneak. Switching from
    spectator to survival or adventure inside a block suffocates you (half a heart every half
    second) until you get out, as in Minecraft.
- **Game mode switcher and debug keys.** Minecraft's `F3` + `F4` switcher: hold `F3`, press `F4`
  to step through Creative, Survival, Adventure and Spectator (or point at one) and let go of `F3`
  to switch. `F3` + `N` toggles spectator and the previous mode, `F3` + `Q` lists the keys in the
  chat, and `F3` alone opens the debug overlay when let go. Who may switch is
  `Gameplay.GameModeCommand`, as for `/gamemode`; without the permission the keys say so
  ("[Debug]: Unable to open game mode switcher; no permission").
- **Crafting and smelting.** Minecraft's recipes for everything the game has: planks, sticks,
  crafting tables, chests, furnaces, wooden to diamond tools, shears, iron, gold and diamond armor,
  storage blocks, stone bricks and polished stones. Shaped recipes fit anywhere in the grid and
  mirrored, shift-click crafts as many as possible, and two worn tools repair into one. Furnaces
  smelt raw ores, sand, cobblestone and logs with Minecraft's fuel times, and keep cooking while
  nobody watches.
- **Just Enough Items.** Next to every inventory screen (the inventory, chests, crafting tables,
  furnaces, the creative picker), a JEI-style list of every item, a page at a time, with a search
  box. Click an item, or press `R` over any item (in the list, a slot, the hotbar or a recipe), to
  see how it is made; right click or `U` shows what it is used for: crafting recipes on a 3 × 3
  grid (an ingredient any planks will do for cycles through them), smelting with its 10 seconds,
  and fuels with how many items they smelt. On a crafting table, a furnace, a Heat Generator or an
  Electric Furnace, `U` also lists every recipe made in it (JEI's catalysts). Items inside a recipe
  open their own recipes, `Backspace` goes back and `E` or `Escape` returns to the inventory. The
  `+` beside a crafting recipe moves its ingredients from the inventory into the open crafting grid
  (`Shift`: as many sets as you have); when it is greyed out, hovering it says why and shows what is
  missing. In creative, `Shift` + click gives a full stack. Three more categories show fluids as
  fluid stacks (a slot in the fluid's colour, "Oil" and "1,000 mB" on hover), standing for their
  bucket and block in lookups: refining (a bucket of oil into fuel in 5 s for 20 kJ), the Heat
  Generator's lava ("Makes 4 MJ", "200 J/t for 1000 s") and the Combustion Generator's fuel ("Makes
  10 MJ", "2.5 kJ/t for 200 s"); `U` on an Oil Refinery or a Combustion Generator lists theirs.
- **Knowledge, Ages and a skill tree.** Knowledge is this game's experience: Minecraft's curve (2L +
  7 points a level to 15, 5L - 38 to 30, 9L - 158 above) and its green bar over the hotbar with the
  level over it (survival and adventure). It comes from first times above all: a block kind mined 5
  points, an item crafted 8, a result smelted 10, a biome visited 20, a mob kind killed 10, an Age
  reached 50 to 200; and a little again and again: ores (coal 1 .. diamond 5), logs (0.25), each
  item smelted (Minecraft's furnace experience: an iron ingot 0.7), each craft (0.1), each mob (an
  animal 2, a monster 5, a creeper 6). Repeats wear off (a repeat of the same thing within a minute
  gives three quarters of the last), all repeats give at most 20 points a minute (perks included),
  and blocks a player placed give nothing at all, so farms dry up. What a furnace pushes into a
  chest beside it, or a pipe pulls out, counts as smelted by whoever last used the furnace.
  Knowledge opens five **Ages**, each at a level and two milestones: the **Stone Age** (where
  everyone starts: wood, stone tools, the crafting table, furnace, chests, torches, glass, iron
  smelting, Tough As Nails' basics, cooked meat, leather armor and wool), the **Iron Age** (level 5,
  a Furnace crafted and an Iron Ingot smelted: iron and gold tools and armor, the Bucket, Shears,
  Flint and Steel, the Lantern, the Canteen, the Thermometer, gold and osmium smelting, potions),
  the **Industrial Age** (level 15, an Osmium Ingot and a Bucket: diamond gear, Mekanism's basic and
  advanced pipes, transporters and tanks, the Configurator, the Heat Generator, gunpowder and TNT,
  potions II and long potions), the **Electric Age** (level 25, a Heat Generator and 6 biomes:
  cables, the Electric Furnace, Batteries, upgrade cards, the Oil Refinery, the Combustion
  Generator, elite pipes) and the **Atomic Age** (level 40, an Oil Refinery and a Battery: the Solar
  Panel, the ultimate tiers, the Nuke). A later Age's crafting results stay out of the grid (shown
  greyed with "Requires the Iron Age"; JEI puts a padlock on them) and furnaces take nothing that
  would smelt into one; reaching an Age is automatic, with a banner, a fanfare and a line in
  everyone's chat. Each level is a **skill point** for the skill tree (`K`): 18 small perks in three
  branches across the Ages, 1 to 5 points each: Forager (+10% knowledge from discoveries), Quarrying
  (stone tools mine 10% faster), Hardy (thirst drains 10% slower), Firekeeper (campfires boil twice
  as fast), Smithing (tools wear 15% slower), Prospector (ores give twice the knowledge), Insulation
  (a step of warmth and cooling), Ironworking, Demolition (unlocks gunpowder and TNT), Scholar,
  Tempering, Diamond Cutting, Thermoregulation, Endurance, Polymath, Fission (unlocks the Nuke),
  Mastery and Enlightenment. Progress is saved (DataStore "IceVoxelProgress_v1") and survives death.
  Creative players have every recipe and earn nothing. `/knowledge` and `/age` set it for testing.
- **Day and night.** Minecraft's 20 minute day (24000 ticks: sunrise 0, noon 6000, sunset 12000,
  midnight 18000), with the sun at Minecraft's angle for the time and light that always matches the
  sun on screen. Roblox's Future lighting with shadows replaces the old fullbright look: warm
  sunrises and sunsets, dark blue nights you can still find your way in (Minecraft's night sky
  light of 4), and caves and closed rooms that stay dark at any time of day unless you light them.
  A tunnel dug into a hillside darkens with the distance from its mouth, not the depth of the rock
  above it. `/time` and `/gamerule doDaylightCycle` work as in Minecraft.
- **Torches, lanterns and the Glow Block.** Light sources for the dark: torches (light 14) stand on
  blocks or hang on walls, leaning out like Minecraft's; lanterns (15) stand on a block or hang
  under one; the Glow Block (15, the game's blue stand-in for glowstone) is a glowing full block.
  Each gives off a Roblox PointLight. With `Config.Render.Shadows` on, a torch's or lantern's light
  stops at walls; the Glow Block casts a shadow like any full block (a roof of them keeps the sun
  out), so its own light has none and reaches
  through a wall within its range. Torches and lanterns need a sturdy block to hang on, as in
  Minecraft (not leaves, a chest or a cactus), pop off and drop when that block goes, and flowing
  water washes torches away (flowing lava burns them). Players walk through lanterns (in
  Minecraft they bump into them), but a lantern can't be placed inside a player. Recipes: 4
  torches from coal or charcoal over a stick, a lantern from 8 iron nuggets around a torch, a Glow
  Block from 4 Glow Dust (it breaks into 4 again). **Glow Dust** is the game's blue glowing dust, in
  place of Minecraft's glowstone dust (the game has no Nether): glow lichen in caves drops it.
- **Foliage.** Minecraft 1.20.1's ground plants: short grass, ferns, tall grass and large ferns,
  dead bushes, twelve flowers (dandelion, poppy, blue orchid, allium, azure bluet, four tulips,
  oxeye daisy, cornflower, lily of the valley), four two-block tall flowers (sunflower, lilac,
  rose bush, peony) and brown and red mushrooms. Biomes grow them in full detail chunks as
  Minecraft's vegetal decoration does: patches of grass with clearings between them, ferns and
  large ferns in taigas, savanna grass tinted dry, flower patches of one or two species (plains,
  forests, meadows; blue orchids in jungles, as there are no swamps), dead bushes in deserts and
  mushrooms on mycelium and in old growth taigas. They stand on Minecraft's soils (grass, dirt,
  podzol, mycelium...; dead bushes also on sand; mushrooms on mycelium, podzol or any solid opaque
  block), break at once, pop off with their drops when their soil goes and wash away in flowing
  water; grass, ferns and dead bushes can be built over (but Short Grass clicked on short grass
  goes beside it). A tall plant needs room for its top and is placed and broken whole, with one
  drop. By hand grass and ferns drop nothing and a dead bush drops a stick; flowers and mushrooms
  drop themselves. Shears (2 iron ingots on a diagonal, 238 uses) harvest grass, ferns, dead
  bushes and leaves (tall grass gives 2 short grass, a large fern 2 ferns), cut leaves at once and
  wear on every block they break, once per tall plant.
  A plant whose sprite is in the texture pack (short grass and tall grass so far) is drawn as
  Minecraft draws it, two crossed images (2 parts); the others are a few thin boxes (at most 4
  parts): splayed blades and fronds in shades of green, or a stem with a head in Minecraft's
  colours. Grass and ferns take a savanna yellow-green on dry grass, sprites too. Plants are drawn
  a few pixels off their cell's centre and turned, by a hash of their position, so fields don't
  look like grids (both halves of a tall plant alike; the sunflower always faces east); the
  outline stays on the cell. Every box or image plane is a part, so plants are drawn
  within 40 blocks (24 on phones; the Plant Distance setting): about 1,000-3,000 parts on
  grassland, at most 6,000. `Config.Render.Foliage = false` (or the setting at OFF) stops drawing
  them on slow devices; they are still there to aim at and break. Left out: Minecraft's light
  check for mushrooms, seeds from grass (there is no wheat) and the plants the game has no blocks
  for (sugar cane, berry bushes, lily pads, vines, seagrass); plants are sparser than in
  Minecraft, to keep the part count down.
- **Random ticks, grass, leaves and saplings.** Minecraft's random ticks: each tick 3 random
  blocks of every 16-block section of the chunks within 3 of a player get a tick
  (`Config.Server.RandomTickSpeed`, 0 turns them off). Grass, dry grass and mycelium under the open
  sky spread onto dirt next to them (one block sideways, three down, one up) that has the open sky
  above it; podzol doesn't spread, and grass under an opaque block turns to dirt. Leaves with no
  log within 6 blocks through other leaves decay fast (0.2-0.6 s after their neighbour changes,
  `Config.Server.LeafDecay`): fell a trunk and its canopy falls within seconds. Leaves you placed
  never decay. Leaves drop their sapling one time in 20 (jungle 40) or 1-2 sticks one in 50, when
  they decay and when broken without shears. The five saplings (oak, birch, spruce, acacia,
  jungle) are drawn as a crossed sprite tinted their wood's green, need dirt or grass under them
  and grow into their tree under the open sky (about one random tick in 14, a few minutes) when
  the trunk has room.
- **Structure blocks.** Minecraft 1.20.1's structure blocks, to save what you build as text and
  place it again. They, structure voids and jigsaw blocks are operator blocks: only creative players
  may place, use and break them, and only operators (the game's owner, `Gameplay.Admins` and
  Studio sessions among them; everyone with the world's Allow Commands) and the user ids in
  `Config.Structures.Permission` (none by default); survival players can't mine them
  and they never drop. Right click opens Minecraft's screen, whose mode button cycles Save, Load,
  Corner and Data; the block is its mode (its faces show the mode's sigil), so everyone sees it.
  **Save** has a name (`mything/houses/hut`: letters, digits and `_ . / : -`), a relative position
  (-48..48 from the block, default 0, 1, 0), a size (up to 48 × 48 × 48) and "Show Invisible Blocks"
  (blue markers on the region's air); the region is outlined, with the name over the block. DETECT
  fits the region between two Corner blocks of the same name within 80 blocks (the inside of their
  box); SAVE captures it: air is saved as air (it clears the world where the structure goes), a
  **structure void** (a small translucent cube, not solid, saved as "keep") leaves whatever is
  there, Data blocks become data markers with their string, jigsaws keep their settings, blocks with
  slots their items (item data, such as a tank's fluid, is not kept), and cave air and generated
  glow lichen, lava and oil are saved as their surface forms. **Load** places a structure by name
  (saved this session, or in the structure library) or from data pasted into its screen, with a
  rotation (0, 90, 180, 270), a mirror, an integrity (the share of blocks placed, drawn from a seed;
  0 picks one) and "Show Bounding Box". As in Minecraft the first LOAD of a template of another size
  only sets the size ("position prepared": the outline shows where it goes) and the next places it,
  a couple of thousand blocks a frame, turning torches, lichen and jigsaws with it. **Corner** is a
  name, **Data** a marker string. Unlike Minecraft the screen stays open after DETECT, SAVE and LOAD
  and repeats the answer on its status line; Done keeps the fields and closes, Cancel, `Escape` and
  `E` drop them. Outlines and labels show only in creative. WAILA names a structure block's mode and
  name.
- **Structure data.** SAVE turns a structure into compact text, "IVS1:" and base64url (letters,
  digits, `-` and `_`), which pastes into chat and into a Luau string as it is: the palette by block
  name (so it survives new blocks; an unknown name loads as air, with a warning), the cells as runs
  or bit-packed, jigsaws, data markers, container items and a checksum, so a cut or damaged paste
  says so ("The structure data is cut off: ... Copy all of it"). A 7 × 5 × 7 hut is about 250
  characters, a 16 × 10 × 16 house about 1,150, and any 48 × 48 × 48 structure fits a StringValue
  (~150,000 at most; `Structures.MaxDataChars`). The chat says "Saved structure '<name>' (N blocks,
  M characters)" and the text appears in a read only box in the Save screen: click it and press
  `Ctrl` + `C` (`Cmd` + `C`) to copy it (Roblox scripts can't write the clipboard). Long data comes
  in parts of 16,000 characters ("part 2 of 9"), copied in order. Each save is also kept for the
  session by name (256 saves, 32 MB at most) and, while kept, as a StringValue named after it in
  `ServerStorage.IceVoxelSavedStructures`, to copy during a Studio playtest. Text pasted into a Load
  screen is checked as you paste (its name, size and block count, or what is wrong with it) and
  uploaded in pieces. `lune run tests/structure decode` prints any data as ASCII layers (see
  Extending).
- **Jigsaw blocks.** Minecraft's jigsaw blocks join structure pieces. One faces out of the clicked
  face (a jigsaw facing up or down has its top towards the player); its front shows the puzzle piece
  with its knob towards the top, the face towards the top a bar (the lock) and the other three faces
  around the front arrows pointing at it, so the orientation reads from any side. Its screen sets
  the target pool (where the pieces attached here come from), its name, the target name (the jigsaw
  of a piece that attaches here), "Turns into" (the block it becomes once generated, default air)
  and, for vertical fronts, the joint (rollable or aligned). Generate builds from the pool right
  there, Minecraft's JigsawPlacement up to Levels (0..7) deep, and Keep Jigsaws (on by default, as
  in Minecraft) leaves the jigsaws in place; pieces saved minutes ago are already in their pools.
  Pools need no code: pieces named `mything/houses/a` and `mything/houses/b` make the pool
  `mything/houses`. Data made to waste time stops with "the structure is too big". WAILA names a
  jigsaw's name, target and pool.
- **Generated structures.** Templates in the structure library (`src/shared/StructureLibrary/`, or
  StringValues in the place's `ReplicatedStorage.IceVoxelStructures` folder) generate in the world
  as Minecraft's jigsaw structures do: one start per region of `spacing` × `spacing` chunks, at
  least `separation` apart (random_spread), kept when the start piece's centre is in one of the
  structure's biomes and on dry land that is not bare rock, then assembled from its pools: the start
  piece stands on the ground at its centre, rigid pieces line up with the jigsaw they attach to,
  terrain matching ones (paths) follow the ground column by column, and air or water under a rigid
  piece's floor becomes a foundation of the ground's filler (12 blocks at most). Like trees they are
  stateless and cross chunk borders, show from afar up to `Config.StructureMaxLevel`, keep trees out
  of their way, clear the ground with their air and leave it where they hold structure voids; their
  chests start with the template's items (filled the first time they are opened, read by a pipe or
  broken). The example **outpost** is a watchtower plaza (or its overgrown ruin, with a forgotten
  chest) with lantern posts, paths that follow the ground and end in a lamp post or fade out, and
  along them a hut, a storehouse with a chest of supplies, an open forge and a woodpile: at most one
  per 896 × 896 blocks, in plains, savannas, meadows and forests. With `Config.Structures.Generate`
  false none generate.
- **World types.** Minecraft's world presets, each with its own options: **Default**;
  **Superflat**, layers from a preset line in this game's names (`Bedrock,2*Dirt,Grass;Plains`;
  Minecraft's own strings such as `minecraft:bedrock,2*minecraft:dirt,minecraft:grass_block` paste
  too) or Minecraft's presets whose blocks exist (Classic Flat, Tunnelers' Dream, Water World,
  Overworld, Snowy Kingdom, Bottomless Pit, Desert, Redstone Ready), trees and plants optional, a
  bad preset falling back to Classic Flat with the reason; **The Void**, a 33 × 33 stone platform
  at y 64 over nothing; **Single Biome**, the Default's mountains with one biome everywhere (sand
  up the peaks of a desert world); **Large Biomes**, the Default with climate four times as wide;
  and three debug worlds: **All Blocks** (Minecraft's Debug Mode: every block once, variants and
  fluid levels included, at y 70 on a grid with a gap between, nothing ticks so nothing flows or
  falls, spectator suggested), **All Structures** (every template of the structure library and
  every generated structure on a grass floor, each with a structure block name tag that WAILA
  reads and F3 outlines) and **All Biomes** (a 16 block strip of every biome's ground, trees and
  plants). The void and the debug worlds spawn no mobs. The server publishes the type and its
  options with the seed, so every client and worker builds the same world; the far terrain, the
  map, WAILA's biome, Tough As Nails, safe spawning and sky checks all follow it.
  The Create World screen offers every type (the debug worlds last) with its Customize screen;
  without the title screen `Config.World.Type` and `Config.World.Options` pick it.
- **Glow lichen.** Minecraft's glow lichen grows in patches on cave walls and ceilings 13 blocks or
  more below the surface (about 3% of them, some 20 per chunk), with light 7 in a cool yellow green.
  Each is a thin plate on its face (showing the texture pack's glow lichen image) with a glowing
  Neon speck: 2 parts. One lichen per 8 × 8 × 8 blocks carries a PointLight, which shines at any
  distance, so a revealed cave holds a few hundred lights instead of thousands (the Lichen Lights
  setting, or `Caves.LichenLightDistance`, can switch far ones off on slow devices).
  It drops 2 Glow Dust (by hand or with any tool; an axe breaks it fastest), or itself with Shears;
  it is replaceable, washes away in flowing water, and placed by hand it lies on the floor or hangs
  on a ceiling or wall like a torch (one face per block). Generated lichen counts as cave air while
  caves are hidden, so a cave's lichen costs nothing until you are in it.
- **Seeing caves further.** Underground, caves are drawn where you can see into them: a search
  through connected cave air from the camera's 16 × 16 × 16 section (Minecraft's advanced cave
  culling) reveals tunnels 88 blocks away (the old reveal sphere: 80) and big caverns such as the
  Underlands up to 144, for about the parts the sphere cost (0.96 × over 29 caves, median), and
  caves behind rock cost nothing. A tunnel running out of what is revealed ends in a stone cap,
  never in the void. Full detail chunks, the only ones with caves, reach about 128 blocks instead of
  96 while the camera is shut in below the surface (in a cave or under rock, not at the open bottom
  of a pit or a ravine) and for 5 seconds after (`Lod.UndergroundSplitDistanceL1`), so walking in
  and out of a cave mouth doesn't rebuild the chunks around it. The Cave View setting scales all of
  it (phones, on the Low preset: tunnels 64 blocks, caverns 112, full detail about 96). F3 shows
  how far caves are revealed and how many lichen and lava lights there are.
- **From the surface into the caves.** Cave entrances and ravines are surface terrain: drawn from
  above like any hillside and lit by the sky (an entrance is lit at its mouth and dark about 30
  blocks in, a ravine's floor is under the open sky, the caves beyond stay dark). Where one runs
  into a cave you are not in, the cave is drawn as a stone cap (so is the bottom of a shaft dug
  into a cave), never the void. Walk down an entrance or into a ravine and the cave view comes on
  as soon as your eyes are more than a block below the ground: its search follows the entrance
  down into the caves it leads to but never out into the sky (23-34 sections from a mouth, at most
  ~200 on the way down, where following every pocket of air would visit 180-560), and the cave
  beyond shows a few frames later. Full detail only reaches further once you are shut in (in the
  cave or under rock), not at the open bottom of a pit or a ravine, where it would load 70-100%
  more full detail chunks for a view of the surface.
- **Terrain behind mountains.** Every generated chunk carries a small summary of its lowest ground
  and highest top (kept up to date as players dig and build), and about once a second while you
  move a worker works out which far chunks nearer terrain hides from the camera, with a margin
  (16 blocks higher and to every side). Those load last, and with Skip hidden terrain (the Hidden
  Terrain setting; on in the Low preset) they draw no parts until you could see them. In the
  mountains 45% of the parts on screen are hidden; skipping them keeps a third fewer parts while
  walking (84k parts become 49k after loading, at the default view with far meshes off).
- **Settings menu.** Minecraft's Options screen (`P`, gamepad D-pad right, or the gear at the left
  end of the hotbar on touch screens): a graphics preset (Low, Medium, High, Ultra) and every view,
  performance, sound, control and HUD setting, applied while you play and saved per player and
  kind of device. See [Settings menu](#settings-menu).
- **Mekanism pipes.** Mekanism 10's transmitters, for what the game has. Logistical Transporters
  (Basic, Advanced, Elite, Ultimate) carry items between chests, furnaces and machines, and you see
  them move: a side set to pull with the Configurator takes 1 / 16 / 32 / 64 items every half
  second, which travel at 1 / 2 / 4 / 10 blocks a second along the cheapest route (faster
  transporters cost less) to an inventory that takes them. Furnaces and machines follow Mekanism's
  machine rules on every side: transporters put ore and fuel in through any side (what smelts into
  the input, fuel into the fuel slot, logs into the input first and then the fuel; nothing else
  goes in) and only ever take the results out (and an empty bucket left in a fuel slot), never the
  ore or fuel you put in. Furnaces and machines push their results out on their own every half
  second, a stack at a time (Mekanism's ejector): into a chest next to them, or into a transporter
  next to them whose side is normal or pull (never push or none), which only takes them when they
  have somewhere to go (never back in) and colours them; never straight into another furnace or
  machine, though transporters can lead them there. Restrictive Transporters are only used when
  there is no other way. Transporters coloured with the Configurator (Minecraft's 16 dyes) only
  join their own colour or uncoloured ones, and the items they pull keep their colour: they travel
  through uncoloured transporters and ones of their colour only (items pulled by an uncoloured
  transporter stay off coloured ones), to keep lines apart. Mechanical Pipes move water, lava, oil
  and fuel between Fluid Tanks (32 000 to 256 000 mB) and machines' fluid tanks at Mekanism's
  rates, one fluid per network (pipes holding different fluids stay apart, so fluids never mix),
  and Minecraft's buckets (the Bucket and the Water, Lava, Oil and Fuel Buckets) carry each of
  them to and from tanks, machines and the world. Machines with fluid tanks (the Heat Generator's
  lava, the Oil Refinery's oil and fuel, the Combustion Generator's fuel) take pipes on every
  side: pipes fill their input tanks, a pull side drains their output tanks, and they push their
  outputs out on their own into the Fluid Tanks next to them and into pipes that lead somewhere
  for them (never back into the pipe or tank that feeds them). A full bucket pours into a
  machine's input tank with room for all of it, an empty one takes 1000 mB from an output tank,
  else from an input tank; when it can do neither, the machine's screen opens instead. The
  Configurator cycles a side between normal, push,
  pull and none (right click) and a transporter's colour (sneak + right click). Recipes follow
  Mekanism's shapes with the game's materials (gold, diamond and emerald stand for its alloys).
  Players walk through transmitters, as through lanterns; their state and the tanks' fluids live in
  memory, like chests. Pressurized Tubes and Thermodynamic Conductors are not included: the game
  has no gas or heat (Universal Cables: see Electricity).
  Items that no inventory takes go back to the one they came from (a furnace's or machine's results
  never do), or wait in their transporter until one turns up; a broken transporter drops what is in
  it. Pipes join into networks that share their fluid (breaking a pipe loses its share), and both
  keep working where no player is, like furnaces.
  You see how they are set: transmitters grow arms towards what they connect to, ending in a
  collar between two of them and in a plate on a chest, furnace, tank or machine; where a side
  pulls from or pushes into one of those the arm has a blue (pull) or orange (push) band, and
  coloured transporters are tinted their colour. Items glide through the transporters; pipes and
  tanks show their fluid in its colour (lava glowing). The Configurator acts on the arm you point
  at (or the face of the core); WAILA names that side's mode, a transporter's colour and the items
  inside it, and the fluid in a pipe or tank ("Lava: ~4,000 / 8,000 mB").
- **Electricity.** Mekanism's energy, counted in joules (J, kJ, MJ, GJ). Universal Cables (Basic,
  Advanced, Elite, Ultimate) join machines into energy networks; a network moves at most the sum
  of its cables' capacities a tick (8 kJ, 128 kJ, 1.02 MJ and 8.19 MJ per cable, Mekanism's
  numbers), and machines that touch each other need no cable at all. Every tick, generators give
  what they hold up to their output rate, shared out evenly among the machines that need it (up
  to their input rates, Mekanism's even split); what is left over charges batteries, and when the
  generators fall short the batteries cover the rest: backup power. Energy is counted exactly and
  never made or lost on the way. The Configurator cuts a cable's side (none) as on pipes; push and
  pull act as normal (WAILA says "Push (as Normal)"). Right click opens a machine's panel with
  Mekanism's energy bar (red when empty to green when full, full only when it is, "stored /
  capacity" on hover); WAILA shows a machine's energy and what it is doing ("Producing 200 J/t",
  "Using 50 J/t", "No power", "Night") and a cable's capacity. A machine broken in survival keeps
  its energy in its item ("Energy: 1.2 MJ") and gets it back when placed; its slots drop like a
  chest's. The Creative Energy Cube (creative only, no recipe) gives infinite energy for trying
  machines out.
  Recipes: 8 Basic Universal Cables from an osmium ingot, glow dust and an osmium ingot in a
  row (Mekanism: steel, redstone, steel); 8 cables around a gold ingot, a diamond or an emerald
  make 8 of the next tier. Like chests, energy lives in memory.
- **Heat Generator.** Mekanism Generators' Heat Generator burns furnace fuel and lava for
  electricity: put coal, charcoal, wood or anything else a furnace burns in its fuel slot (by hand,
  shift-click or a transporter, through any side) and for as long as the item would burn in a
  furnace it makes 200 J a tick (Mekanism's numbers), so a coal is 320 kJ and a plank 60 kJ. Lava
  goes into its 24,000 mB lava tank (Mekanism's) from pipes and buckets, or from Lava Buckets put
  in the fuel slot, poured in once all 1000 mB fit (the empty bucket stays in the slot, where a
  transporter may take it out; transporters never take fuel out). A mB of lava burns for 20 ticks
  at 200 J/t, so a Lava Bucket is 4 MJ, 12.5 coal, as in a furnace (Mekanism's own ratio of lava
  to coal); the tank's lava burns before the next item lights. Every side touching lava adds
  30 J/t, with fuel or without (Mekanism's bonus: up to 180 J/t, so 380 J/t in all). It stores
  160 kJ and gives up to 400 J/t to the cables and machines around it. It burns only as much as it
  has room for, so a machine using less than 200 J/t still gets all of each item's energy; full,
  it stops, keeping what is left burning, and goes on as soon as energy is taken. Its panel shows
  the lava gauge, the fuel slot under a flame (the burn time left), "Producing 200 J/t" or
  "Idle", and the energy bar; WAILA says the same and shows its lava, and while it burns the window
  on its sides glows and it crackles like a lit furnace. Broken with a pickaxe it keeps its energy,
  what is left burning and its lava in its item ("Energy: 80 kJ", "Fuel: 60 s", "Lava: 5,000 mB").
  Recipe: Mekanism's with iron for its copper, three iron ingots over planks, an osmium ingot and
  planks, over iron, a furnace and iron. JEI lists every fuel under its uses, and its lava.
  Mekanism's nether bonus and heat model (heat capacity, losses) don't apply.
- **Electric Furnace.** Mekanism's Energized Smelter, named the Electric Furnace, smelts what a
  furnace smelts on electricity instead of fuel: 50 J a tick for 200 ticks an item (Mekanism's
  numbers), so an item takes a furnace's 10 seconds and costs 10 kJ, and a coal burnt in a Heat
  Generator smelts 32. It stores 20 kJ and takes as much as its network gives it in a tick (as
  fast as the cables carry). It works only with a whole tick's energy: without power, or with no
  room in its output, it stops where it is and goes on when that changes; taking its input out,
  or putting something else in, starts the item over. What smelts goes into its input by hand,
  shift-click or a transporter through any side, and the results come out of its output by hand,
  shift-click or a transporter pulling from any side, and it pushes them out on its own into a
  chest or transporter next to it (Mekanism's machine rules, as furnaces have them). Its panel
  shows the input, the arrow, the output and the energy bar with "Using 50
  J/t", "No power", "Output full" or "Idle"; WAILA says the same. While it smelts the heating
  chamber on its sides glows, steadily even when too little power makes it stop and start
  (Mekanism's 3-second deactivation delay). Broken with a pickaxe it keeps its energy in its
  item ("Energy: 12 kJ"); its slots drop. Recipe: Mekanism's shape with glow dust for the
  redstone, osmium ingots for the control circuits and a furnace for the steel casing: glow
  dust, an osmium ingot and glow dust, over glass, a furnace and glass, over the top row
  again. JEI lists every smelting recipe under its uses. It takes Speed and Energy Upgrades (below).
- **Oil Refinery.** BuildCraft's refinery on Mekanism's electricity turns oil into fuel, 1 mB into
  1 mB, 10 mB a tick for 200 J a tick: a bucket in 5 s for 20 kJ. Oil goes into its 10,000 mB oil
  tank by pipe or Oil Bucket, and fuel comes out of its 10,000 mB fuel tank by pipe or empty
  bucket; it also pushes its fuel out on its own into the Fluid Tanks and pipes next to it that
  lead somewhere that takes fuel, so the line bringing its oil never fills up with fuel. Short of
  oil or room for fuel it refines what it can, for that share of the energy. It stores 40 kJ
  (cables may fill it in a tick) and takes Speed and Energy Upgrades with Mekanism's maths: a
  bucket takes 100 x 10^(-n/8) ticks (74 with one Speed Upgrade, 10 with 8: 100 mB a tick for
  20 kJ/t). Its panel shows the oil gauge, an arrow (the bucket's progress), the fuel gauge, "Using
  200 J/t", "No power", "Output full" or "Idle", the upgrade slots and the energy bar; WAILA says
  the same and shows both tanks, and its heater window glows while it works. Broken with a pickaxe
  it keeps its energy and both tanks in its item. Recipe: iron, glass and iron, over an osmium
  ingot, a furnace and an osmium ingot, over iron, a bucket and iron (BuildCraft's gears and
  engine parts aren't in the game).
- **Combustion Generator.** BuildCraft's combustion engine as a Mekanism generator: it burns fuel
  for 2,500 J a tick, a mB every 4 ticks, so a Fuel Bucket burns for 200 s and makes 10 MJ, the
  strongest fuel there is: 2.5 Lava Buckets or about 31 coal in a Heat Generator, and 500 times
  the 20 kJ refining it cost (one refinery keeps 40 of them going). Its fuel tank holds 10,000 mB
  (pipes and Fuel Buckets fill it; nothing takes fuel back out of it but an empty bucket); it
  stores 1 MJ and gives up to 5 kJ/t to the cables and machines around it. Like the Heat
  Generator it burns only what it has room for, keeping what is left of a mB burning. Its panel
  shows the fuel gauge, "Producing 2.5 kJ/t" or "Idle" and the energy bar; WAILA says the same and
  shows its fuel, and while it burns its chamber glows and crackles. Broken with a pickaxe it keeps
  its energy and fuel. Recipe: an osmium ingot, a bucket and an osmium ingot, over iron, a furnace
  and iron, over an osmium ingot, glow dust and an osmium ingot.
- **Solar Panel.** Mekanism Generators' Solar Generator, named the Solar Panel: a thin panel of four
  dark blue cells on a short post (no full cube, as Mekanism's; players walk through it, as through
  a cable). While nothing opaque stands anywhere above it (glass, torches, cables, other panels and,
  unlike Minecraft, water let the sun through; leaves and ice don't) and it is day on the server's
  clock (Minecraft's isDay: from a little after sunrise to a little before sunset), it makes up to
  50 J a tick, scaled by how high the sun stands (Mekanism's sun brightness: all of it from mid
  morning to mid afternoon, a little under half just before night), about 620 kJ a day. It stores
  96 kJ and gives up to 100 J/t to the cables and machines around it. Its panel and WAILA say
  "Producing 50 J/t", "Full", "Night" or "No sky"; its panel also has its upgrade slots. Broken
  with a pickaxe it keeps its energy in its item. Recipe: Mekanism's shape with glass for the
  solar cells, gold ingots for the alloy, osmium ingots for the osmium dust and glow dust for
  the energy tablet: three glass, over a gold ingot, an iron ingot and a gold ingot, over an osmium
  ingot, glow dust and an osmium ingot. Mekanism's biome and rain factors don't apply (the
  game has no weather).
- **Upgrade cards.** Mekanism's Speed Upgrade and Energy Upgrade, which stack to 8 here (the most a
  machine takes of each; Mekanism's stack to 64). Recipes: Mekanism's shape with the ingots for its
  dusts and gold for its alloy: glass, over a gold ingot, an osmium ingot (speed) or a gold ingot
  (energy) and a gold ingot, over glass. The Electric Furnace and the Solar Panel take up to 8 of
  each in two slots at the lower left of their panels (the Oil Refinery at the lower right), by
  hand or shift-click (transporters never touch them); an empty slot shows the card's outline. The
  Oil Refinery's maths is the Electric Furnace's with a bucket of oil for an item (above).
  Mekanism's maths: with n Speed and e Energy Upgrades an Electric Furnace takes 200 x 10^(-n/8)
  ticks an item (149 with one card, 20 with 8) at 50 x 10^((2n - e)/8) J a tick and stores 20 kJ x
  10^(e/8), so 8 Speed Upgrades smelt ten times as fast for ten times the energy an item, and 8 of
  each ten times as fast for the usual 10 kJ. A Solar Panel (Mekanism's take none) makes and gives
  out 10^(n/8) times as much (8 cards: 500 J/t in full sun) and stores 96 kJ x 10^(e/8) (8 cards:
  960 kJ). Taking cards out applies at once: energy over a smaller store is lost. The cards drop
  when the machine is broken (Mekanism keeps them in its item), so a machine placed again holds at
  most its base store.
- **Batteries.** Mekanism's Energy Cubes, named Batteries: Basic, Advanced, Elite and Ultimate
  store 4, 16, 64 and 256 MJ and take in and give out up to 4, 16, 64 and 256 kJ a tick
  (Mekanism's numbers). They are the backup power: every tick, what the generators have left after
  the machines took what they need charges the batteries on the network, and when the generators
  fall short (a Heat Generator out of fuel, a Solar Panel at night) the batteries cover what the
  machines still need, so an Electric Furnace on a battery smelts on through the night and the
  battery charges again when the sun comes up or the generator gets fuel. Batteries never charge
  each other. Joined like any machine, by Universal Cables or touching (a network moves no more a
  tick than its cables carry together: on a single Basic cable a battery charges at 8 kJ/t at
  most). Its panel shows the energy bar with "Charging 150 J/t", "Discharging 50 J/t", "Full",
  "Empty" or "Idle" and what went in and out last tick; WAILA says the same, and the gauge on each
  of its sides fills with its charge, red when nearly empty to green when full. Broken with a
  pickaxe it keeps its charge in its item ("Energy: 1.23 MJ", and an energy bar where a tool's
  durability bar goes), so batteries stack to 1, and placed again it has it back. Recipes:
  Mekanism's shapes with glow dust for the redstone, Glow Blocks for the energy tablets, a
  block of iron for the steel casing and gold ingots, diamonds and emeralds for the alloys: the
  Basic Battery is glow dust, a Glow Block and glow dust, over an iron ingot, a block of
  iron and an iron ingot, over the top row again; each next tier puts the tier below in the
  middle, Glow Blocks above and below it, osmium ingots, gold ingots or diamonds beside it and gold
  ingots, diamonds or emeralds in the corners, and keeps its charge (Mekanism's upgrade recipes
  do). Mekanism's charge and discharge slots and side configuration are not in.
- **Osmium.** Mekanism's metal: Osmium Ore (blue-grey speckled stone, hardness 3) needs a stone
  pickaxe or better and drops Raw Osmium, which smelts into an Osmium Ingot (the ore smelts too).
  Nine nuggets make an ingot, nine ingots a Block of Osmium and nine raw osmium a Block of Raw
  Osmium (both hardness 7.5, as in Mekanism), and each unpacks again. The ore generates in small
  veins in all rock, plus Mekanism's "middle" veins concentrated around y 100: about as much as
  iron below y 197 and about half as much in the mountains above.
- **Item data.** Items carry a little data of their own, Minecraft's item NBT kept flat: up to 16
  named numbers, strings or flags. A Fluid Tank broken in survival keeps its fluid in its item
  ("Lava: 12,000 mB" under its name in the inventory) and gets it back when placed again, as in
  Mekanism, and so do machines their energy and their fluid tanks; in creative, placing a tank item
  that holds a fluid fills the new tank too. Items with different data never stack, and wherever a
  stack goes (clicks, chests, furnaces, transporters, the ground, death drops) its data goes with
  it.
- **Items drawn in 3D.** Every icon (hotbar, inventory, creative picker) is a small 3D model in a
  ViewportFrame with the same look as the block in the world. Dropped items and the item in a
  character's hand are drawn the same way.
- **WAILA (What Am I Looking At).** A panel at the top of the screen names what the crosshair
  points at, like the Jade mod: the block's icon and name, the tool and tier it needs with a
  green check or red cross for the item in hand ("Requires Iron Pickaxe"), the mining progress
  as a line along its bottom edge, and "IceVoxel" as the mod name. It also names dropped items,
  mobs (health), other players (health, game mode) and fluids when no block is in reach (lava
  says "Light 15"), and the fluid tanks of machines ("Oil: 3,000 / 10,000 mB"). Blocks and fluids
  show a "Light level" line: Minecraft's 0-15 light where a mob would stand on the block (on top
  of it, or in the cell of a see-through block), the larger of the block light from torches,
  lava, glow lichen and the like and the sky light, estimated from the loaded blocks (the block
  light the same estimate the server's mob spawning uses). Red: no block light and little sky
  (monsters could spawn there at any time); yellow: no block light under the sky (at night); green:
  lit. While `F3` is open it adds both parts, and shows everything
  the game knows about the block: id, position and chunk, biome, hardness, tool, drops with the held
  item and by hand, break time, light, fluid level, render kind, friction and menu.
- **Music.** Minecraft's background music: a track now and then (the first a few seconds after
  joining, then every 10 to 20 minutes), surface tracks above ground and cave tracks in caves; going
  underground fades a surface track out and a cave track follows (and the other way back up), so
  surface music never plays underground. A "Now Playing" toast slides in at the top right with the
  track's title for five seconds. The tracks are in `src/shared/Sounds/MusicList.luau`.
- **Cave moods.** Minecraft's cave mood: every tick a random block within 8 blocks of you makes
  the mood grow in the dark (1/6000; dark open cave counts 4 times, so bigger caves bring it
  sooner) and shrink in daylight or by torches; at 100% one of the cave mood sounds plays a couple
  of blocks beyond a dark spot and it starts over: about five minutes in a narrow tunnel, two and a
  half in a big cavern, one and a half in the Underlands, never in daylight (F3 shows "mood N%").
- **Sounds.** Minecraft's sound events for everything that should make a sound: breaking, placing
  and mining blocks (by material: stone, wood, gravel, grass, sand, glass, snow, metal, wool,
  water), footsteps every 1.67 blocks (yours and other players'), hurting landings, splashing and
  swimming, chest lids, the furnace you are using crackling while it burns, items picked up, tools
  breaking, armor put on, getting hurt and dying, interface clicks and Minecraft's cave moods;
  lava popping and bubbling, hissing where water hardens it, the sizzle of burning and its hiss
  when water puts it out, buckets of lava and oil (thicker than water's) and Combustion Generators
  crackling; fire crackling, hissing when punched out, and flint and steel striking; mobs hurt
  and dying (each kind its own pitch), a creeper's hiss, a skeleton's bow and its arrows
  striking, players' hits (strong and weak) and eating. Only water and fuel splash and make swimming sounds. They are stand-ins made from the
  sounds every Roblox client ships, told apart by pitch, so nothing has to be uploaded, and players
  hear what others do within 16 blocks. Each one can be replaced by your own sound (see
  Extending).
- **Server-authoritative interaction.** Mining, placing and every inventory click are predicted on
  the client and validated by the server: timing, reach, what the player holds. Block updates power
  falling sand and gravel (which break into an item on a torch or a flower, Minecraft's torch
  trick), flowing water, lava, oil and fuel (Minecraft rules, including water's infinite sources
  and lava hardening against water), lava and burning, fire spreading and burning out, grass turning
  into dirt and plants popping off when their soil goes; random ticks spread grass, decay leaves,
  grow saplings and let lava light fires.
- **Minecraft movement.** Players are a 0.6 × 1.8 block hull moved through the block data with
  Minecraft Java Edition's physics, tick for tick at 20 ticks per second: walking, sprinting
  (Ctrl toggles it, or is held with the Sprint setting on Hold; or double tap forward) with
  Minecraft's widening field of view (FOV and FOV Effects are settings), sneaking that never walks
  off edges, crouching and crawling under low ceilings, 1.25-block jumps, sprint jumping, slippery
  ice, swimming (sprint under water or fuel, steered by the view), currents, wading through lava
  and oil (Minecraft's lava physics), hopping out of a fluid and fall damage. Steps up to just over
  a block are walked up without jumping, so the steep terrain is walkable
  (`Config.Movement.StepHeight`; Minecraft's is 0.6). The Roblox character is purely cosmetic: it is
  drawn on the hull (interpolated) and never collides with anything.
- **Water that finds the way down.** Like Minecraft, water spreads only towards the nearest drop
  up to 5 blocks away, so it runs down slopes instead of flooding the ground around it. Flowing
  water steps down level by level, and its current pushes the player downstream. Lava and oil head
  for a drop only up to 3 blocks away, fuel as far as water.
- **Minimap and world map.** Painted straight from the generator, so the map shows the whole world,
  oil geysers as black dots. Right click the map to add waypoints (saved between sessions),
  teleport, or center the view. The Minimap setting hides the minimap, which then costs nothing (on
  touch screens a small "Map" button takes its corner, to open the world map).
- **Safe spawns.** Spawns and teleports never land in water, lava, oil, fuel or fire, on leaves or
  next to cacti, lava or fire; the rules live in `SpawnUnsafeBlocks`.
- **A texture pack.** Every block texture is in one module, `src/shared/TexturePack.luau`, like a
  Minecraft resource pack: 512 × 512 images, one per 3-stud block face, drawn as MaterialVariants
  and face images that take each block's own colour (one bark image for every log, each in its
  wood's colour), plants as crossed images. The 32 textures made so far are in, and 61 blank
  entries wait for the rest. Distant chunks take the colour each block averages to on screen, so
  they match the textured terrain near you, or keep their materials and textures with the Far
  Materials setting. See Block textures.
- **Far meshes.** Regions of distant chunks that stopped changing are merged into a few MeshParts
  built with EditableMesh ("superchunks"), replacing thousands of parts: at the default view,
  81k parts become 35k parts + 90 meshes in the mountains. Parts stay the fallback, so nothing breaks
  where the Mesh APIs are unavailable. Meshes are not built while the camera moves faster than 2
  blocks a second (averaged over 2 s), while terrain loads or after a teleport; parts draw
  meanwhile. The Far Meshes setting switches them off; on again, they are rebuilt from what was
  kept, with nothing generated again. Far Materials splits them by look (a mesh per material).

## Getting started

1. Install the toolchain with [Rokit](https://github.com/rojo-rbx/rokit) (Rojo 7.7.1, Lune,
   StyLua, Selene), and the matching Rojo Studio plugin (a plugin older than 7.7 cannot connect to
   this Rojo):
   ```sh
   rokit install
   rojo plugin install
   ```
2. Either live-sync into Studio:
   ```sh
   rojo serve
   ```
   and connect with the Rojo Studio plugin, or build a place file and open it:
   ```sh
   rojo build -o IceVoxel.rbxlx
   ```
3. Press Play. The title screen comes up: as the first player you are the operator, so Create
   World, pick its settings and Create New World (Studio: every player is an operator). Set
   `MainMenu.Enabled = false` in `src/shared/Config.luau` to skip the title screen and start
   straight in a world made from `World` and `Seed`.

Studio tips:
- Delete the template's `Baseplate`; the world starts at y = 0 and the baseplate only sits under it.
- New places come with an `Atmosphere` in Lighting, which adds haze to the far LOD chunks. Without
  one, IceVoxel uses distance fog at the edge of the view distance instead.
- How far parts are drawn is up to the engine, not the script: it depends on the graphics quality
  level and how many objects are on screen. Studio ignores that limit, so judge long views in the
  Roblox player with a high graphics level. Phones draw far less (a few hundred studs), which is why
  they start on the Low preset, with a shorter view distance (`Lod.Mobile`).

## Controls

| Action        | Mouse / keyboard            | Gamepad | Touch      |
| ------------- | --------------------------- | ------- | ---------- |
| Break block   | Hold left click (survival mines, creative breaks at once; adventure and spectator break nothing) | R2 | Hold |
| Attack a mob  | Left click a mob in reach (3 blocks, creative 6; it hides the block behind it): one hit a click, with the held weapon | R2 | Tap the mob |
| Eat           | Hold right click 1.6 s with food (meat, cooked or raw, rotten flesh) while hurt (creative: any time); letting go stops | L2 | Tap |
| Place / use   | Right click (opens chests, crafting tables, furnaces, machines; adventure and spectator only open them) | L2 | Tap |
| Select slot   | `1`–`9`, mouse wheel (unless the Scroll Wheel setting is Zoom), or click a slot (spectator: the spectator menu) | L1 / R1 | Tap a slot |
| Place a torch / lantern | Right click: the top of a block stands it, a side hangs a wall torch, the underside hangs a lantern | L2 | Tap |
| Configure a pipe | Right click a transmitter's arm or core face with the Configurator: normal → push → pull → none (Universal Cables only tell none apart); `Shift` + right click a transporter: next colour | L2 | Tap |
| Flint and Steel | Right click a face: fire in front of it where fire can burn; break a fire (left click) to put it out | L2 | Tap |
| Buckets       | Right click a source (water, lava, oil, fuel), a Fluid Tank or a machine with a bucket to fill it; right click a block, tank or machine with a full bucket to empty it (a machine whose tanks can't take or give a bucket opens its screen; `Shift`: into the world, past tanks and machines) | L2 | Tap |
| Structure / jigsaw block (creative) | Right click: its screen; `E` / `Escape` close it (Cancel), Done keeps the fields; click the saved data box, then `Ctrl` + `C` (`Cmd` + `C`) copies it | L2; B closes | Tap |
| Place a jigsaw | Right click a face: the jigsaw faces out of it (on a top or bottom face, its top points back at you) | L2 | Tap |
| Drink / fill  | Right click a water source with an empty hand: a sip; with a Glass Bottle, a Bowl or a canteen: fill it; hold right click with a filled bottle, bowl or canteen, a tea or a potion for 1.6 s: drink it (letting go cancels; Tough As Nails) | L2 | Tap |
| Boil water    | Right click a Campfire with a dirty water bottle, bowl or canteen: one boils clean (not sneaking; Tough As Nails) | L2 | Tap |
| Pick block    | Middle click (spectator: the spectator menu) |  |      |
| Drop item     | `Q` (`Ctrl` + `Q`: the whole stack; not while `F3` is held) | D-pad down |    |
| Inventory     | `E` (creative: the item picker; spectator: none) | Y   | `…` button |
| Fly (creative) | Double tap `Space`; `Space` / `Shift` up / down | double tap A | double tap jump |
| Fly (spectator) | Always, through blocks; `Space` / `Shift` up / down, sprinting (`Ctrl`) twice as fast; mouse wheel (spectator menu closed): flying speed | A / B | Jump / Sneak |
| Spectator menu | `1`–`9` or middle click open it, then a number selects and the same number again (or middle click) uses; the wheel moves the selection | L1 / R1 open and move, D-pad up uses | `…` button; tap a slot |
| Spectate a player (spectator) | Left click them; `Shift` leaves | R2; B leaves | Hold on them; Sneak button leaves |
| Game mode     | `/gamemode survival` / `creative` / `adventure` / `spectator` (or `/gm s` / `c` / `a` / `sp`, `0`–`3`) in the chat; `F3` + `N`: spectator ↔ the previous mode | | |
| Game mode switcher | Hold `F3`, press `F4` (each further `F4`: the next mode; or point at one), let go of `F3` to switch; `Escape` cancels | | |
| Sprint        | `Ctrl` turns it on / off (held instead with the Sprint setting on Hold), or double tap `W` | L3 (stick press) | Sprint button (toggle) |
| Sneak         | Hold `Shift` (never walks off edges) | B | Sneak button (toggle) |
| Jump          | `Space` (hold to keep jumping) | A    | Jump button |
| Swim up / down | Hold `Space` / `Shift` in water or fuel (in lava and oil `Space` rises slowly; there is no swimming) | A / B | Jump / Sneak |
| Swim fast     | Sprint under water or fuel; look where to go | L3 | Sprint button |
| Climb out     | Swim (or wade) at a ledge just above the surface | stick | move |
| In the inventory | Left / right click, `Shift` + click, `1`–`9` swap with the hotbar, `Q` drop, double click to collect, drag to spread | A / X / Y, B closes | tap / long press |
| Recipes / uses (JEI) | Click / right click an item in the list, or `R` / `U` over any item; `Backspace` back, `E` / `Escape` back to the inventory | A / X on a list item, B leaves the recipes | Tap / long press |
| Move a recipe (JEI) | `+` beside a crafting recipe (`Shift`: as many as possible) | A | Tap |
| Full stack (JEI, creative) | `Shift` + click or middle click an item in the list | Y | |
| World map     | `M`, or click the minimap   |         | Tap minimap (or the Map button while the Minimap setting is off) |
| Map menu      | Right click the map         | R3      | Long press |
| Minimap zoom  | `-` / `=`                   |         |            |
| Options menu  | `P` (`P` again, `E`, `Escape` or Done close it), or the gear in the inventory | D-pad right; B closes | Gear at the left end of the hotbar |
| Skill tree    | `K` (`K` again, `E`, `Escape` or Done close it): click a skill, then Unlock; hover an Age's name for what it takes | D-pad left; A selects, B closes | The button over the gear |
| Debug overlay | `F3`, when let go (also WAILA's extended view); not after a combination such as `F3` + `N` | | |
| Debug keys    | `F3` + `Q` lists them in the chat (`F3` + `N`, `F3` + `Q`, `F3` + `F4`) | | |
| Time          | `/time set day` (`noon`, `night`, `midnight`, `6000`, `0.5d`), `/time add 1000`, `/time query daytime`; `/gamerule doDaylightCycle false` stops the clock (operators) | | |
| Mobs          | `/summon zombie` (at your feet) or `/summon cow ~ ~ ~5`; `/kill @e[type=zombie]`, `/kill @e` (every mob) (operators) | | |
| Status effects | `/effect give @s speed 60 1` (`<player>` a name, `@s`, `@p` or `@a`; seconds 1-1000000 or `infinite`, default 30; amplifier 0-255), `/effect clear [player] [effect]` (operators); hover or tap an effect icon for its name and time | | Tap an icon |
| Knowledge and Ages | `/knowledge add\|set <player> <amount> [points\|levels]` (also `/xp`), `/knowledge query <player> [levels]`, `/age set <player> <age>` (`iron`, `Iron Age`, `2`), `/age query <player>`; players are names, `@s` or `@a`; changing needs an operator, as `/time` | | |
| Operators     | `/op <player>`, `/deop <player>` (operators only; a name, its start, `@s` or `@a`). The first player to join is the operator; when the last operator here leaves, the player here longest becomes one; `/deop` never takes the last one here. `Gameplay.Admins`, the game's owner and everyone in Studio always are. With the world's Allow Commands on, everyone may use the operators' commands (`/gamemode` for others, `/time`, `/gamerule`, `/effect`, `/summon`, `/kill`, `/knowledge`, `/age`, structure blocks) | | |
| Title screen  | Click the buttons (Join World, Create World, Options...); `Escape` goes back a screen (Create World, Customize, Options) | A; B goes back | Tap |

## Settings menu

`P` opens Minecraft's Options screen (gamepad: D-pad right; touch: the gear at the left end of the
hotbar; anywhere: the gear in the inventory, where Minecraft's recipe book button is). Changes
apply while you play: cheap ones at the next frame, costly ones (view, caves, plants, shadows,
textures, far materials, far meshes) 0.4 s after a slider stops (`Settings.ApplyDelay`), so
dragging a slider rebuilds the world once. Sliders move by dragging, clicking, the D-pad (left /
right) or A; buttons cycle their values. Done (on a sub-page: back to Options), `P`, `E`, `Escape`
or gamepad B close it, which applies whatever still waits and saves.

| Page            | Settings |
| --------------- | -------- |
| Options         | Graphics (the preset: Low / Medium / High / Ultra, "Custom" once a value it sets is changed), FOV (30-110); the pages below; Reset (the current preset's values again), Defaults (every setting back to this device's defaults) |
| Video Settings  | Render Distance (256-4096 blocks, phones at most 1024), Detail Falloff (2-4), Full Detail (48-160 blocks, at most what the falloff allows), Cave View (64-176 blocks), Plant Distance (OFF, 8-64), Lichen Lights (16-128 blocks or All), Shadows, Far Shadows, Fog, Textures (when the texture pack has a filled texture), Far Materials (where far meshes run), Brightness (Moody to Bright), Prefer (Distance / Lighting) |
| Performance     | Far Meshes (with their state), Build Budget (Auto or 1-12 ms), Hidden Terrain (Draw / Skip), Swap Frames (0-3) |
| Music & Sounds  | Master Volume, Music, Blocks, Players, Ambient, Interface (0-100%); Footsteps, Interface Clicks, Cave Moods, Music Toasts |
| Controls        | FOV Effects (0-100%), Sprint (Toggle / Hold), Scroll Wheel (Hotbar / Zoom), Touch Buttons (touch screens; after rejoining) |
| HUD             | Minimap, WAILA, GUI Scale (Auto, 1-3) |

Status lines say what the terrain is doing ("Updating terrain: 120 queued, 34 building") and, on
the Performance page, the far meshes' state. A few notes on what the settings do:
- Full Detail is held at most at the detail falloff plus one (96 blocks with a falloff of 2, 128
  with 3), so the levels of detail stay 2:1 balanced; lowering the falloff pulls it down.
- Cave View is how far big caverns are seen; tunnels follow in proportion (88 blocks at 128, 64
  at 96, 96 at 144), and so does full detail underground (about the cave view, at most what the
  falloff allows).
- Build Budget: Auto adapts the milliseconds a frame spends building parts to the frame time
  (`Render.AutoBudget`); a number fixes them.
- Prefer Distance tells Roblox to lower lighting quality before draw distance
  (`Lighting.PrioritizeLightingQuality`); Brightness lightens caves from Config's darkness
  (Moody) towards Minecraft's Bright (`Lighting.CaveAmbient`).
- Far Meshes off puts every merged region back to parts; on again, the meshes are rebuilt from
  what was kept, with nothing generated again. Where meshes are off from the start of the session
  (phones, a failed probe, `Render.FarMeshes`) they can't be switched on, and the status says why.
- Textures off draws every block in its plain Roblox material and colour, and plants as boxes.
  Far Materials (off by default, `Render.FarMaterials`) keeps materials and textures on the
  merged far chunks, about 200 blocks away and further, with a far mesh per look, instead of
  plain colours (see Far meshes in Extending); without far meshes far chunks keep them anyway, so
  it is offered only where far meshes run. Either one rebuilds the chunks it changes in the
  background.

Presets (seed 12345, parts at the spawn / in the mountains, with far meshes in brackets; without
skipping hidden terrain):

| Preset | View / falloff / full detail    | Cave view | Also                                          | Spawn                    | Mountains           |
| ------ | ------------------------------- | --------- | --------------------------------------------- | ------------------------ | ------------------- |
| Low    | 512 / 2 / 64 blocks             | 96        | plants 24, no shadows, hidden terrain skipped | 13.8k (9.1k + 14 meshes) | 29.0k (16.6k + 16)  |
| Medium | 1024 / 2 / 96 blocks            | 96        | plants 24                                     | 18.2k (11.5k + 29)       | 43.2k (23.5k + 37)  |
| High   | 2048 / 3 / 96 blocks (Config's) | 128       | plants 40                                     | 33.5k (16.7k + 88)       | 81.5k (34.8k + 90)  |
| Ultra  | 4096 / 3 / 96 blocks            | 144       | plants 64, far shadows                        | 45.6k (20.6k + 187)      | 97.5k (39.5k + 191) |

Phones and tablets start on Low (Config's `Lod.Mobile` and `Caves.Mobile` values, now without
shadows); other devices by Roblox's graphics quality: 1-3 Low, 4-6 Medium, 7-10 or Automatic
High. Only what a player changed is saved, so everything else keeps following the preset (and
Roblox's quality level), one profile per kind of device (desktop, touch, console), in the
DataStore "IceVoxelSettings_v1" (`Settings.Save`). A joining client waits up to a second
(`Settings.LoadWait`) for them, so the first terrain it loads is already the player's view.

## Title screen and creating the world

Every player sees Minecraft's title screen when they join, over everything: nothing else of the
game has started yet (no terrain loads, no key does anything), and the server gives nobody a
character before they enter the world.

- **Join World** enters the world once it exists; the terrain then loads around the spawn as on
  any join.
- **Create World** is the operator's (the first player to join the server), while no world exists.
  Everyone else reads "Waiting for <operator> to create the world..." until it does. Its two tabs,
  as Minecraft 1.20's: **Game** (World Name; Game Mode: Survival, Creative or Adventure, the mode
  new players get; Difficulty: Peaceful spawns no monsters, harder ones spread fire a little
  faster; Allow Commands: everyone may use the operators' commands, switched on with Creative
  unless you set it yourself) and **World** (World Type, from the world types the game has, with
  its description, and **Customize** when the type declares settings; the seed: a number is used
  as it is, any other text becomes Minecraft's number for it (Java's `String.hashCode`, so
  "glacier" is 108181935), blank is random; Generate Structures). **Create New World** sends it to
  the server, which checks it again (only the operator, only once, known types and modes, at most
  32 characters of name and seed; the name goes through Roblox's text filter, as everyone sees
  it), creates the world and puts you in it.
- **Load World** is greyed out: worlds aren't saved yet (the server keeps one world for its
  lifetime); loading a saved world is for the future.
- **Options...** opens the Options menu (the same as `P` in the game); Done comes back.

The world's name, type, difficulty and seed show in `F3`. Without the title screen
(`MainMenu.Enabled = false`) the server makes the world at once from `World` and `Seed`.

## Project layout

```
src/shared   -> ReplicatedStorage.IceVoxel          (used by server, client and worker actors)
  Config                    every tunable setting
  Blocks/  BlockList        block definitions -> ids, appearances, lookup tables (hardness, tools,
                            drops, menus), plants (soil sets, tall halves, foliage tints), each
                            block's textures per face from the pack (`variantTexture`, `alignLut`)
  TexturePack               the texture pack: every block texture (maps, Material, Tint, Average)
                            and the texture of each block's faces; hand-edited, pure data
  Items/                    the item registry, stacks and item data (validation, tooltip lines,
                            Mekanism's energy and fluid formats, what a full bucket leaves);
                            ItemList (items that are not blocks)
  Fluids/  FluidList        the fluid registry: water, lava, oil and fuel by id (0 none .. 4 fuel),
                            their blocks and cave twins, buckets, colour, light, movement, harm,
                            furnace fuel, fog and bucket sounds
  Fire                      fire's shared rules (Minecraft's FireBlock): survival, ignite odds,
                            the sides it clings to, its outline and planes, the animation frames
  Transmitters/             Mekanism pipes and cables: Tiers (Mekanism's numbers), sides,
                            connection modes, colours, the connection rule, route costs,
                            Inventories (sided slots, insert / extract, what furnaces and
                            machines push out)
  Machines/                 Mekanism machines: Core (kinds, the machine container and its data,
                            slot rules, panels and their lines, energy maths and the even split,
                            state codes, sustained data, fluid tanks and their gauges),
                            Upgrades (Mekanism's upgrade cards: their slots and maths), Kinds/ (a
                            module per kind: Creative, the Creative Energy Cube; Generator, the
                            Heat Generator; Smelter, the Electric Furnace; Solar, the Solar
                            Panel; Battery, the Batteries; Refinery, the Oil Refinery;
                            Combustion, the Combustion Generator)
  Crafting/                 Recipes (Minecraft's and Mekanism's recipes, smelting and fuel; a
                            recipe may keep an ingredient's data), Crafting (grid matching),
                            Smelting (the furnace tick; the Lava Bucket's burn time)
  Inventory/                Types (inventory, window, action shapes), Menu (Minecraft's inventory
                            clicks, used by the server and for client prediction)
  Structures/               structure blocks' data and jigsaw structures: Template (the IVS1
                            text, SAVE's capture, ASCII tables), Settings (structure block and
                            jigsaw fields, ranges, wire format), Transform (rotation and mirror),
                            Jigsaw (Minecraft's JigsawPlacement), Library (templates, pools and
                            generated structures from the modules below and the place)
  StructureLibrary/         the structure library: Templates/ (IVS1 modules; Outpost, the
                            example), Pools (explicit template pools), Structures (what generates)
  Entities/ItemPhysics      dropped item movement (server and client; floating in water and fuel,
                            in lava and oil)
  Entities/MobList          mob kinds (Minecraft's boxes, health, speeds, loot, spawn weights,
                            sounds, how the client draws them); MobPhysics (a mob's movement
                            tick: walking, jumping, fluids, climbing, falls); Combat (players
                            hitting mobs: weapon damage, attack strength, reach, knockback, wear)
  Items/Foods               what eating meat does (healing, the Thirst effect's odds), raw to
                            cooked
  GameMode, Mining          the four game modes and what each allows, mining times by hand and
                            with tools (and status effects' Haste and Mining Fatigue)
  Effects/  EffectList      status effects (Minecraft's MobEffects, Oil Coated, Fuel Soaked, Tough
                            As Nails' four): the registry, the modifiers movement, mining, combat
                            and burning read, ticking rules, the HUD's order and flashing;
            PotionList      the potions (ingredients, levels, durations: items, recipes, drinks)
  ToughAsNails/             Tough As Nails, pure: Thirst (thirst, hydration, exhaustion,
                            dehydration, regeneration, the Thirst effect), Temperature (-10..10
                            in five zones, the target, the drift, hypothermia and hyperthermia,
                            Internal Warmth and Chill, Climate Clemency), Drinks (water sources,
                            the container tables: bottles, canteens, bowls; the teas), Exertion
                            (movement that costs thirst), Boiling (dirty water boiled clean on a
                            campfire)
  Progression/              knowledge, Ages and skills, pure: Knowledge (Minecraft's experience
                            curve, the sources and their numbers, fatigue and the budget), Ages
                            (what each opens and needs), Skills (the tree and its perks), init
                            (the state: awards, discoveries, advancing, unlocking, the recipe
                            gate, perks, death, the saved record, the client's status)
  Sounds/  SoundList        sound events (Minecraft's names) -> built-in sounds, block sound types
           MusicList        the music (surface and cave tracks) and the cave mood sounds
  DayCycle                  Minecraft's day: celestial angle, sky light, isDay and the sun's
                            brightness (solar panels), /time arguments, lighting blends
  Biomes/  BiomeList        biome definitions and altitude bands
  Generation/
    TerrainGenerator        biomes, surfaces, filling chunks at any LOD
    Relief                  terrain heights (JJThunder To The Max style)
    Noise                   seeded noise on top of math.noise
    Caves, Ores             full detail only (Ores: every ore feature, Mekanism's osmium included)
    SurfaceCaves            cave entrances and ravines (worms carved as air; full detail and LOD
                            levels 1-2)
    Lava                    lava below LavaLevel (levels 0-2), Minecraft's lava lakes
                            (underground: full detail; surface: point-sampled up to
                            StructureMaxLevel)
    OilWells                BuildCraft's oil wells: deposits, geysers and their lakes, undersea
                            pockets (point-sampled up to StructureMaxLevel; the map's dots)
    Lakes                   water lakes (Minecraft's lake_water; point-sampled up to
                            StructureMaxLevel) and puddles in dips (full detail only)
    Structures/             placement + Trees (builders) + Writer (clipping, LOD)
    StructureGen            library structures in chunks (random_spread starts, assembly cache,
                            pieces, foundations, generated chests)
    CaveDecor               glow lichen on cave walls (full detail only)
    Foliage                 ground plants by biome (full detail only)
    WorldTypes              the world types (registry, options and settings, hints, the
                            WorldType / WorldOptions / Seed attributes)
    LayeredGenerator        a whole generator from layer stacks, placed blocks and a structure
                            placer (flat, void and debug worlds; every LOD level)
    Superflat               superflat preset lines, Minecraft's presets
    DebugWorlds             the debug worlds' grids (all blocks, all structures, all biomes)
  Meshing/GreedyMesher      blocks -> boxes (parts; odd boxes for textures with OddBoxes)
  Meshing/Scatter           plants' offset and turn per position (Minecraft's OffsetType)
  Meshing/QuadMesher        blocks -> faces (meshes); MeshGeometry: faces -> mesh arrays (split by
                            look, with UVs, for Far Materials)
  Map/MapPainter            map tile colours from the generator, oil geysers' dots (runs in the
                            workers)
  World/                    ChunkLayout, Coords, LodTree, VoxelRaycast, FluidFlow, SectionGraph
                            (cave visibility: which sections connect, the search from the
                            camera), Horizon (far terrain hidden behind nearer terrain),
                            Explosion (Minecraft's explosion: rays, blast resistance, seen
                            percent, damage, knockback, fire), LightEstimate (block and sky light
                            from the blocks, Minecraft's monster and animal spawn light tests;
                            mob spawning, WAILA and the cave mood)
  PlayerSettings            the Options menu's settings: ids, ranges, presets, the LOD balance
                            rule, the wire and DataStore formats
  WorldSettings             the world's settings (Create World): seeds as Minecraft reads them,
                            checking a request, a world type's options, publishing them
  Movement/                 Hull (box vs blocks collision), PlayerPhysics (Minecraft movement
                            tick, spectators' flight through blocks), Rig (hull <-> cosmetic
                            character)
  Net/                      Protocol (buffer encoding), Remotes
  Util/Hash                 deterministic hashing and RNG

src/textures -> generated from the texture pack by tests/build_textures (never edit by hand)
  Materials.model.json      MaterialService.IceVoxel: a MaterialVariant IV_<name> per filled texture
  Images.model.json         ReplicatedStorage.IceVoxelTextures: a Texture prototype of the same name

src/server   -> ServerScriptService.IceVoxel
  IceVoxel_Server           boot: operators, settings and the title screen first, then
                            startWorld (world, ticker, network, players...) once it is created
  Api                       require this from your own server scripts
  World/                    WorldServer (chunks + edits), BlockTicker, RandomTicker, Skylight,
                            Simulation, TimeOfDay (the day clock, published as workspace attributes),
                            WorldInfo (the world's settings once created; creating it once),
                            Explosions (blasts in the world, fuel going off, per-tick cost
                            bounds, the primer hook for explosive blocks), FuelBlast (fuel
                            catching, measuring a body, power, chained blasts; pure), Nuke (the
                            Nuke's crater: ragged sphere, scorching, fire, a budget a tick)
  Behaviours/               Gravity, Fluid (water, lava, oil and fuel; lava hardening against
                            water), Grass (dying and spreading), Leaves (decay), Sapling, Herb
                            (mint and wild ginger spreading), Attached (torches and lanterns need
                            support),
                            Plant (plants need their soil and their other half), Fire
                            (spreading, burning blocks away, burning out, ages; lava lighting
                            fires; flint and steel), Tnt (lit TNT and Nukes: lighting, the fuse,
                            falling, blowing up), Drops (block update logic)
  Audio/Sounds              plays sounds to the players near them (Sound messages)
  Network/ServerNet         edit lists, edit validation (EditRules: mining time, tools, drops,
                            sustained data hooks, both halves of tall plants), replication;
                            LobbyNet (messages before the world exists)
  Entities/                 EntityWorld (item rules: pickup, merging, despawn, burning in lava,
                            blasts),
                            Entities (spawning, replication)
  Mobs/                     MobWorld (mobs' rules: ticks, hurts, death and loot, blasts, despawn,
                            players' attacks; pure), MobAI (wander, panic, hunt, melee, a
                            creeper's fuse, a skeleton's bow; pure), MobSpawning (natural spawning
                            by light, ground and caps; pure), SummonCommand (/summon, /kill;
                            pure), Mobs (20 Hz ticks, replication, attacks, commands, the `died`
                            event and other scripts' hooks)
  Transmitters/             Mekanism pipes on the server: TransmitterWorld (states, networks, tanks;
                            pure), Transport (items in transporters), Fluids (every fluid in
                            pipes, machines' fluid tanks, the fluid ejector),
                            Eject (furnaces and machines push their results into chests; pure),
                            UseRules (buckets, Configurator), Transmitters (ticks, replication)
  Machines/                 Mekanism machines and energy on the server: MachineWorld (machines,
                            their ticks, sustained data, records, the cached sky look; pure),
                            EnergyNet (energy networks over Universal Cables and touching
                            machines; pure), SkyCheck (does a cell see the sky: loaded chunks,
                            else edits over the generator's ground, never generating; pure),
                            Machines (20 Hz ticks, viewers' snapshots, replication)
  Structures/               structure blocks and jigsaws: StructureBlocks (messages, rate limits,
                            replication, ServerStorage), StructureServer (SAVE, LOAD, DETECT,
                            Generate; pure), StructureStore (their settings), Placement (LOAD and
                            Generate plans, placed over frames), Permission (who may use them)
  Players/ItemUse           the Configurator, buckets, flint and steel and dirty water (on a
                            campfire) used on blocks (UseItem)
  Players/                  Operators + OperatorList (Minecraft's ops: the first player, /op,
                            /deop, the check every operators' command asks; pure), WorldMenu (the
                            title screen's server side: creating the world, characters only in
                            it), GameModes + GameModeCommand (/gamemode, the switcher's requests,
                            permissions, the previous mode), GameModeRules (what each mode may
                            do on the server; pure), TimeCommands + TimeCommand (/time,
                            /gamerule), Inventories + InventoryState (authoritative inventories),
                            Containers (chests, furnaces, generated structures' chests),
                            Characters (cosmetic characters: collision group, teleports, fall
                            damage, invulnerability, suffocation, lava and burning, explosions),
                            Burning (lava, fire and campfires hurting and burning players and
                            items, the hurt cooldown explosions share; pure), ToughAsNails
                            (thirst and body temperature: ticks, drinking, exertion, the HUD's
                            state) + Climate (the surroundings: biome, roof, heat and cold
                            sources; pure), Effects (status effects: the API, sending, Glowing,
                            /effect) + EffectRules (giving, ticking, the fluids' effects, the
                            sync rule; pure) + EffectCommand (/effect; pure),
                            Spawning,
                            SafeSpot + SpawnUnsafeBlocks (safety rules), Teleport (map,
                            spectators),
                            WaypointStore and SettingsStore (DataStores: waypoints, player
                            settings), Eating (food held 32 ticks: healing, used up),
                            Progression + ProgressionCommand + ProgressStore (knowledge, Ages and
                            skills: earning, the windows' recipe gate, perks for the parts above,
                            /knowledge and /age, the DataStore)

src/client   -> StarterPlayerScripts.IceVoxel
  IceVoxel_Client           boot
  World/ClientWorld         nearby block data, edit lists, prediction
  World/StructureRecords    structure blocks' and jigsaws' settings, their regions, pasted data
                            going out and SAVE's data coming back
  Streaming/                ChunkStreamer (LOD + scheduling, the cave view, teleports),
                            WorkerPool, ChunkWorker (actor: generation, meshing, cave graphs,
                            horizon verdicts, map tiles), CaveReach (revealed sections, caps),
                            LoadPriority (load order), RemeshQueue (remeshes and their commit
                            groups), SwapUnits (LOD swaps), TeleportMode, HiddenTerrain (horizon
                            jobs and verdicts)
  Rendering/                ChunkRenderer (boxes -> parts), RenderSchedule (build lanes, commit
                            groups), SectionDiff (in-place remesh), FrameBudget (adaptive build
                            budget), PartPool, ViewSettings (the view from the player's
                            settings), LightingController (day, night and cave lighting),
                            SkyExposure (how much sky light reaches the camera), FluidFog (the
                            view from inside a fluid: fog and tint), MeshOverlay + MeshRegions
                            (far meshes), TextureLooks (every look of the texture pack: variants,
                            tints, images, sprites, far and plain looks, far mesh looks; checks
                            the ids and measures averages)
  Settings/                 the player's settings: State (values and choices), Schedule (when
                            changes apply), Pages (the menu's layout), saving them on the server
  Interaction/              BlockInteraction (mining, placing, using), CrackOverlay, TankUse
                            (does a bucket on a machine act on its tanks or open its screen),
                            Drinking (Tough As Nails: filling, sipping, holding a drink), Eating
                            (holding food); hitting mobs (BlockInteraction)
  Inventory/                ClientInventory + Prediction (predicted inventory)
  Ui/                       Screens, Hud (hotbar, hearts; SurvivalHud: thirst droplets, the
                            temperature gauge, frost and heat at the edges), InventoryScreen (with the crafting,
                            chest, furnace and machine panels laid out by MenuLayout, machines'
                            energy bar and fluid gauges, empty armor and upgrade slots'
                            outlines), CreativeScreen,
                            ItemIcon (viewport icons, durability and energy bars), SlotClicks
                            (Minecraft clicks), Style, Waila + WailaInfo (what the crosshair
                            points at), Jei/ (Just Enough Items: item list, recipe view, recipe
                            transfer), StructureScreen + StructureForm (the structure block and
                            jigsaw screens and their model), FormWidgets (Minecraft's fields and
                            buttons), SpectatorGui + SpectatorMenu (the spectator menu and its
                            model), GameModeSwitcher + ModeSwitch (the F3 + F4 switcher and its
                            model), SettingsScreen (the Options menu), MusicToast (Now Playing),
                            EffectHud + EffectIcons (status effect icons in the top right, the
                            list beside open screens, their glyphs), SkillTreeScreen (the skill
                            tree, K), AgeToast (a new Age's banner), MainMenu (the title screen
                            and Create World) + TitleRules + CreateWorldForm (their rules; pure)
  Audio/                    SoundPlayer (pooled 3D / interface sounds, the server's Sound messages,
                            overrides), MovementSounds (footsteps, swimming, landings), Ambience
                            (furnaces, Heat and Combustion Generators crackling, lava, the cave
                            mood), CaveMood (Minecraft's mood, pure), Music + MusicRules (the
                            background music; when and which, pure), SoundRules (the pure rules)
  Entities/EntityRenderer   dropped items; MobRenderer + MobModel (mobs: boxes gliding between
                            updates, hurt flashes, creepers' fuses, flames, arrows; the pure pose
                            and aim)
  Map/                      MapLayer (EditableImage ring), MapView, Minimap, WorldMap,
                            Waypoints, ContextMenu
  Net/ClientNet             routes server messages; Notices shows server messages in the chat;
                            StructureNet (structure blocks' and jigsaws' messages and screens)
  Player/                   MovementController (the hull, input, the cosmetic character,
                            spectating a player), CharacterAnimator (avatar animations from the
                            hull), HeldItems, SpectatorView + SpectatorRules (who sees, hears and
                            aims at spectators), BurningView (flames on burning players, the fire
                            overlay in first person), SurvivalState (Tough As Nails' state from
                            the server), Exertion (reports sprinting, swimming and jumps),
                            EffectState (status effects from the server, counted down),
                            ProgressionState (knowledge, the Age and skills from the server; the
                            recipe gate and perks the client predicts with)
  Rendering/ExplosionView   explosions: the blast drawn, the knockback, a camera shake
  Rendering/EffectView      Night Vision, Blindness and Nausea on the view
  Rendering/FireRenderer    fire's and campfires' animated flames (SurfaceGui planes, one shared
                            animation step)
  Rendering/FuseView        lit TNT and Nukes flashing
  Rendering/TransmitterRenderer  Mekanism pipes, cables and machines: arms, fluids in pipes and
                            tanks, items moving through transporters, the windows of working
                            generators, Electric Furnaces and Oil Refineries, Batteries' charge
                            gauges, machines' records (WAILA, Ambience, buckets); TransmitterModel
                            (their geometry, aiming, item paths, fluid colours)
  Rendering/ItemModels      3D models of items (icons, drops, hands); BlockDecor (the faces of
                            chests, crafting tables, furnaces, Mekanism's machines, structure
                            blocks and jigsaws)
  Rendering/StructureBoxes  structure blocks' outlines, names and air markers
  Debug/DebugOverlay        F3 stats and time of day (also WAILA's extended view); DebugKeys
                            (Minecraft's debug keys: F3 when let go, F3 + N, F3 + F4, F3 + Q)

tests/       Lune scripts: unit tests, benchmark, terrain preview, structure (structure data on the
             command line), build_structures (the example outpost's builder), build_textures (the
             texture pack -> src/textures; logic in lib/TextureBuild)
docs/        ARCHITECTURE.md (how everything fits together)
```

How the pieces work together is described in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Configuration

Everything lives in `src/shared/Config.luau`. Players change the view and performance settings for
themselves in the Options menu (see [Settings menu](#settings-menu)); Config gives the defaults and
the presets (High is Config's own view, Low its `Mobile` values). The settings that matter most
for performance:

| Setting                   | Default | Effect                                                              |
| ------------------------- | ------- | ------------------------------------------------------------------- |
| `Lod.ViewDistance`        | 2048    | How far terrain is drawn (blocks; the High preset).                 |
| `Lod.Mobile`              | 512 / 2 / 24 / 3 | View / split / foliage / underground split distance of the Low preset, which phones and tablets start on. |
| `Lod.SplitDistance`       | 3       | Detail falloff. LOD 0 radius is roughly `2 × SplitDistance` chunks. |
| `Lod.SplitDistanceL1`     | 3       | Same for full detail only; 2 = ~12% fewer parts in mountains.       |
| `Lod.UndergroundSplitDistanceL1` | 4 | `SplitDistanceL1` while the camera is shut in underground (in a cave or under rock, not at the open bottom of a pit or a ravine; phones 3): full detail, and so caves, reach ~128 blocks. |
| `Lod.UndergroundSeconds`  | 5       | How long that lasts after the camera comes up (no rebuilding at cave mouths). |
| `Lod.Levels`              | 7       | Coarsest level covers `16 × 2^(Levels-1)` blocks per chunk.         |
| `Lod.MaxVerticalStep`     | 16      | Tallest LOD cell in blocks (keeps far mountains shaped).            |
| `Lod.FoliageDistance`     | 40      | How far plants are drawn (blocks; every box or image plane of a plant is a part). |
| `Workers.Count`           | 6       | Actors generating / meshing in parallel.                            |
| `Streaming.TeleportDistance` | 128  | A jump this far (blocks) drops the old area at once (teleport mode). |
| `Streaming.TeleportTimeout` / `TeleportSettle` | 10 / 16 | Teleport mode (and the first load: far meshes and map tiles wait) ends once the 3 × 3 chunks under the player are shown and at most this many nodes and builds are left, or after this many seconds. |
| `Streaming.RemeshJobs`    | 4       | Cave, seam and plant remeshes in flight while terrain loads (edits are never limited). |
| `Streaming.RevealGroupSections` | 96 | A cave reveal pass goes live in groups of at most this many sections, nearest first (a cap opening and the tunnel behind it together). |
| `Streaming.RetryDelay` / `RetryMax` | 0.5 / 8 | Seconds before a failed chunk is generated again (doubling); the old terrain stays meanwhile. |
| `Streaming.BusyJobs` / `BusyBuilds` | 8 / 24 | Far meshes wait while more chunks than this wait for generation / sections for the renderer. |
| `Render.BuildBudgetMs`    | 4       | Main thread time per frame spent creating parts; with `AutoBudget` the base of an adaptive budget. |
| `Render.AutoBudget`       | true    | Adapt the build budget to the frame time: lower when frames run long, up to 8 ms while work waits and frames have room, 12 ms while the player waits for the ground. |
| `Render.EditBudgetMs`     | 2       | Main thread time per frame for edits, ahead of everything else.     |
| `Render.SwapFrames`       | 2       | Frames old geometry stays under its replacement (edits, LOD swaps, far meshes; 0: same frame). |
| `Render.UnparentPartsPerFrame` | 3000 | Parts taken out of the workspace per frame (old nodes, teleports). |
| `Render.SwapPartsPerFrame` | 6000   | Parts per frame put in or taken out by LOD swaps and far meshes together. |
| `Render.ReleaseBudgetMs`  | 1.5     | Main thread time per frame giving parts back to the pool (or destroying them once it is full). |
| `Render.Shadows`          | true    | Shadows on full detail chunks and of torch and lantern light (far chunks never cast shadows). |
| `Render.Foliage`          | true    | Draw plants (up to 4 parts each); false saves those parts, plants can still be aimed at and broken. |
| `Caves.RevealReach`       | 88      | How far along tunnels an underground camera sees caves (blocks; the Cave View setting scales it). |
| `Caves.RevealRadius` / `RevealRadiusMax` | 64 / 128 | Big caverns: the open space around the camera sets a radius between these, and caves show to it plus 16 (phones 48 / 96: `Caves.Mobile`). |
| `Caves.RevealBudget`      | 1500    | Sections revealed at most, nearest first (the Underlands' giant caverns). |
| `Caves.RevealHold`        | 2       | Seconds a section stays revealed after the camera stopped seeing into it. |
| `Caves.LichenLightDistance` | math.huge | Glow lichen's lights shine at any distance; a number switches off those farther from the camera (the lichen still glows). |
| `Caves.Entrances`         | Spacing 96, Chance 0.6 | Cave entrances: one candidate per 96 × 96 blocks, taken with `Chance`; `Radius` 1.5-3.5 blocks, `Length` 48-140 steps of a block, `Depth` 15-60 blocks below the surface, `Branch` 0.35 (the chance of a side tunnel); `Enabled = false`: none. |
| `Caves.Ravines`           | Spacing 384, Chance 0.5 | Ravines: one candidate per 384 × 384 blocks; half width `Radius` 1.5 at the ends to up to 6 in the middle, `Length` 60-160 steps, `Depth` 20-45 blocks in the middle (8 at the ends). |
| `Caves.LavaLevel`         | 11      | Cave air below this y is lava (CaveLava; surface caves cut that deep get Lava; Minecraft: below y -54, 10 above its floor); 0: none. |
| `Caves.LavaLakes`         | Underground Rarity 1, Tries 8, Depth 30; Surface Rarity 200 | Lava lakes sunk into cave floors (one chunk in `Rarity` of those with caves tries `Tries` spots, at least `Depth` blocks below the surface) and on the surface (one candidate per `Rarity` chunks of area), none within `SpawnClearance` (128) blocks of the spawn; `Enabled = false`: none of that kind. |
| `Caves.OilWells`          | Spacing 512, Chance 0.12 | Oil wells: one candidate per 512 × 512 blocks, a well with `Chance`, its biome's chance in `Biomes` (Desert 0.6, Savanna and Windswept Savanna 0.5, Plains 0.45) or `Sea` (0.15) under the sea (pockets of `SeaSize`, Small, no geyser); `Sizes` (share, deposit radius, lake radius, spout height: Large 25%, 8-12, 7-10, 16; Medium 50%, 5-7, 4-7, 6; Small 25%, 3-4, no geyser), `Depth` 20-40, `LakeDepth` 1-3, none within `SpawnClearance` (256) blocks of the spawn; `Enabled = false`: none. |
| `Caves.LavaLightDistance` | 96      | Lava's lights within this many blocks of the camera are on (phones 48: `Caves.Mobile`); the lava still glows. |
| `Lakes.Water`             | Rarity 600 | Water lakes: one candidate per `Rarity` chunks of area, kept with its biome's weight in `Biomes` (Desert 0.3, Savanna 0.6, Windswept Savanna 0.5; others 1); `Enabled = false`: none. |
| `Lakes.Puddles`           | Spacing 32, Chance 0.05 | Puddles: one candidate per 32 × 32 blocks, a puddle with its biome's chance in `Biomes` (Jungle 0.14 ... Desert 0.005) or `Chance`, none in frozen or snowy biomes; `Size` 3-20 columns, `Radius` 1.5-3.5 blocks; `Enabled = false`: none. |
| `Lakes.SpawnClearance`    | 24      | No water lake or puddle this close to the spawn (blocks). |
| `StructureMaxLevel`       | 2       | Highest LOD level that still shows trees and library structures.   |
| `Structures.Permission`   | {}      | Who may use structure blocks and jigsaws in creative besides operators (the owner, `Gameplay.Admins` and Studio among them): user ids, or true (anyone in creative) / false. |
| `Structures.MaxSize` / `MaxOffset` | 48 / 48 | A structure block's largest size and relative position per axis (Minecraft's). |
| `Structures.DetectRange`  | 80      | How far DETECT looks for Corner blocks of the same name.            |
| `Structures.LoadBlocksPerFrame` | 2000 | Blocks LOAD and Generate place per frame (and at most 6 ms of it). |
| `Structures.MaxDataChars` | 200000  | Longest structure text saved or pasted (what a StringValue holds).  |
| `Structures.DataPieceChars` | 16000 | Structure text travels in pieces of this many characters, `DataPiecesPerSecond` (20) a second. |
| `Structures.Generate`     | true    | Library structures generate in the world; false: none do.          |
| `Render.Textures`         | true    | Draw the texture pack's textures (the Textures setting); false: every block in its plain material and colour. |
| `Render.FarMaterials`     | false   | Materials and textures on merged far chunks, a far mesh per look (the Far Materials setting), instead of plain colours. |
| `Textures.OddBoxes`       | false   | Odd-sized boxes (in blocks) for textured cubes at full detail, for variants that tile from a face's centre (see Block textures): 14-18% more parts near the player. |
| `Textures.BottomFaces` / `SideImages` | false / false | Draw bottoms (grass's dirt) as images, one more instance per part / the sides as upright images over the top's variant, four more. |
| `Textures.Sprites`        | true    | Plants with a filled `Sprite` are two crossed images instead of their boxes. |
| `Textures.MeasureAverages` / `ValidateIds` | true / true | Measure the averages the pack lacks and print them to paste / check every image id once at startup and name each one that fails. |
| `Render.FarMeshes`        | on (PC) | Merge stable far regions into meshes (see Far meshes below).        |
| `Render.FarMeshes.MaxBuildSpeed` / `SpeedWindow` | 2 / 2 | No mesh builds while the camera moved faster than this many blocks a second, averaged over this many seconds. |
| `Render.FarMeshes.LookMinShare` / `MaxLooks` | 0.05 / 4 | With Far Materials: a look gets MeshParts of its own in a region when it covers this share of its area, at most this many looks (the largest). |
| `Render.FarMeshes.LookRemainder` | "plain" | The other quads: "plain" (SmoothPlastic in the colour they average to) or "largest" (joined to the largest opaque look, tinted to that colour). |
| `Render.FarMeshes.UvStuds` | 3      | Studs per texture tile in far mesh UVs (one block face).            |
| `Map.Teleport`            | true    | Who may teleport from the map: everyone, nobody, or a user id list. |
| `Map.SaveWaypoints`       | true    | Keep waypoints between sessions (DataStore).                        |
| `Gameplay.DefaultGameMode` | Survival | Game mode of players when they join: Survival, Creative, Adventure or Spectator. |
| `Gameplay.GameModeCommand` | true   | Who may change their own game mode (`/gamemode`, `F3` + `N`, `F3` + `F4`): everyone, nobody, or a user id list (operators always may). |
| `Gameplay.Admins`         | {}      | User ids who are always operators (as the game's owner and everyone in Studio): other players' game modes, `/time set\|add`, `/gamerule`, `/effect`, `/summon`, `/kill`, `/knowledge`, `/age`, `/op`, `/deop`, structure blocks. |
| `MainMenu.Enabled`        | true    | The title screen: the first player (the operator) creates the world from it, everyone joins it from it; nobody has a character before. false: the world is made at once from `World` and `Seed`, players join straight in. |
| `MainMenu.Version` / `Credits` | "IceVoxel (Minecraft 1.20.1 style)" / "Not an official Minecraft product" | The title screen's bottom corners. |
| `World.Name` / `Type`     | "New World" / "default" | The world made at once without the title screen, and the Create World screen's first choices (a `Generation/WorldTypes` id; its game mode is `Gameplay.DefaultGameMode`, or the type's own: Spectator for All Blocks, Creative for the other debug worlds). |
| `World.Options`           | {}      | The world type's options without the title screen (its `settings` keys, see below). |
| `World.Difficulty`        | "Normal" | Peaceful (no monsters spawn), Easy, Normal or Hard (fire spreads a little faster on harder ones: `Server.Fire.Difficulty`). |
| `World.AllowCommands` / `Structures` | false / true | Everyone may use the operators' commands (Minecraft's Allow Cheats) / library structures generate. |
| `Gameplay.KeepInventory`  | false   | Keep the inventory on death instead of dropping it (spectators always keep theirs). |
| `ToughAsNails.Thirst` / `Temperature` | true / true | Tough As Nails' thirst and body temperature (each off: no stats, no HUD, no damage). |
| `ToughAsNails.ThirstRegeneration` | true | Health comes back only with thirst 18+ (half a heart every 80 ticks for 6 exhaustion), replacing Roblox's regeneration; false keeps Roblox's. Neither heals while fully frozen or overheated. |
| `ToughAsNails.DehydrationFloor` | 1 | Half hearts dehydration (a hurt every 120 ticks) stops at (Minecraft's normal difficulty; 0: to death). |
| `ToughAsNails.HandDrinking` / `HotExhaustion` | true / 0.005 | Sipping from water sources with an empty hand; thirst exhaustion a tick while hot. |
| `ToughAsNails.ChangeTicks` / `RecoverTicks` | 140 / 70 | Ticks per step of the body temperature (-10..10) away from neutral / back towards it (neutral to icy: 56 s in the coldest place). |
| `ToughAsNails.ClemencyTicks` / `RespawnClemencyTicks` | 6000 / 1200 | Climate Clemency on joining / respawning: the temperature held neutral, half the thirst drain, no dehydration (0: none). |
| `ToughAsNails.WetTicks` | 100 | Ticks a player stays wet out of water (3 steps colder). |
| `ToughAsNails.ProximityRadius` / `HeatingBlocks` / `CoolingBlocks` | 5 / Lava, Fire, Campfire / ice, snow | Heat sources within that many blocks warm 3 steps (5 within 2 blocks, where cold sources no longer cool), cold sources cool 3 (fluid or block names; unknown names are skipped with a warning). |
| `Progression.Enabled` / `GateRecipes` | true / true | Knowledge, Ages and the skill tree at all (off: no bar, no gates, no perks); a later Age's (or a skill's) crafting and smelting results locked. |
| `Progression.Save` / `SaveInterval` | true / 120 | Keep progress between sessions (DataStore "IceVoxelProgress_v1"; Studio needs API access); seconds between saves of changed progress (and on leaving and shutdown). |
| `Progression.RepeatBudget` | 20 | Points a minute at most from repeated actions together (ores, logs, smelting, crafting, mobs; the knowledge perks included); discoveries are not limited. |
| `Progression.DeathLoss` | 0 | Share of the progress into the current level lost on death (levels, the Age and skills never are). |
| `Progression.BiomeInterval` | 2 | Seconds between looks at the biome a player stands in (a first visit is a discovery). |
| `Progression.Key` / `GamepadButton` | K / DPadLeft | Open and close the skill tree. |
| `Entities.ItemLifetime`   | 300     | Seconds before a dropped item disappears.                           |
| `Entities.MaxItems`       | 1000    | Most dropped items at once (the oldest go first).                   |
| `Mobs.Enabled` / `Spawning` | true / true | Mobs at all (false: none spawn, tick or are sent) / natural spawning (`/summon` still works). |
| `Mobs.MaxMobs` / `MaxPassive` / `MaxHostile` | 300 / 120 / 160 | Most mobs in the world, creatures and monsters among them.  |
| `Mobs.PassiveCap` / `HostileCap` | 10 / 15 | Most creatures / monsters within 128 blocks of a player for spawning to go on. |
| `Mobs.HostileInterval` / `PassiveInterval` / `Attempts` | 20 / 400 / 3 | Ticks between spawning rounds of monsters and creatures; packs tried per player a round. |
| `Mobs.SpawnDistance`      | 24, 44  | Blocks from a player a pack spawns (never within 24 of anyone).     |
| `Mobs.ForgetTicks`        | 6000    | A creature with no player within 128 blocks this long is dropped (memory). |
| `Mobs.TrackingDistance` / `SyncTicks` | 64 / 2 | Players see mobs this close; their state is sent every SyncTicks ticks while it changes. |
| `Mobs.AttacksPerSecond`   | 10      | Attacks a player may send a second.                                 |
| `Explosions.BucketPower` / `MinPower` / `MaxPower` | 4 / 1 / 12 | Burning fuel: a blast's power is BucketPower × the cube root of its buckets, within these. |
| `Explosions.FlowingShare` | 1/16    | What a flowing fuel cell counts, times its fill (a source is a bucket). |
| `Explosions.MaxCells` / `ClusterSize` / `MinBlastVolume` | 4096 / 4 / 0.5 | Fuel one ignition sets off at most; a blast per cube this wide; cubes with less fuel (buckets) just flash into fire. |
| `Explosions.ChainBlocksPerTick` | 1.5 | How fast the chain runs through a body of fuel (blocks a tick). |
| `Explosions.FuseTicks` | 4 | Flowing fuel burns like a fuse: ticks before a touched cell turns to fire and lights the next. |
| `Explosions.MaxIgnitionsPerTick` / `MaxBlastsPerTick` / `RayBudget` | 4 / 8 / 60000 | Cost bounds per server tick (a power 12 blast reads about 26,000 blocks; the first blast always goes). |
| `Explosions.EffectDistance` / `ShakeDistance` | 64 / 4 | Players this close see and feel a blast; the camera shakes within ShakeDistance × power. |
| `Tnt.FuseTicks` / `Power` | 80 / 4 | Lit TNT's fuse (a blast lights it with rand(fuse / 4) + fuse / 8) and its blast. |
| `Nuke.FuseTicks` / `AlarmTicks` | 200 / 20 | The lit Nuke's fuse (the same short fuse rule when a blast lights it) and its beeps. |
| `Nuke.Radius` / `Strength` / `Ragged` / `RaggedScale` | 24 / 60 / 0.2 / 9 | The crater: a block goes where its blast resistance is under Strength × (1 − distance / radius); the radius wanders by Ragged of itself (noise of this wavelength). |
| `Nuke.ScorchRadius` / `ScorchResistance` / `FireOdds` | 40 / 0.45 / 6 | Around it: grass to dirt, blocks resisting less than this blown away; one air spot over an opaque block in FireOdds catches fire. |
| `Nuke.EditsPerTick` / `ReadsPerTick` | 500 / 16000 | Cost bounds per server tick (each edit is 12 bytes to every client). |
| `Nuke.Power` / `EffectDistance` / `LookPower` | 28 / 256 / 16 | Players and items: Minecraft's damage and push at this power; who sees it; blasts this strong get the nuke's look. |
| `Effects.FluidEffects` | true | Oil and fuel give their effects (Slowness II and Oil Coated; Nausea, Poison and Fuel Soaked); off, they leave players be (potions and `/effect` still work). |
| `Effects.Hud` | true | The status effect icons in the top right corner and the list beside open screens (off: Tough As Nails' status row over the hotbar shows Climate Clemency, Internal Warmth and Chill). |
| `Effects.NauseaRoll` / `NauseaFov` | 7 / 0.1 | Nausea's wobble at full strength: the camera's roll (degrees) and the field of view's sway (a share), times the FOV Effects setting. |
| `Effects.NightVisionAmbient` | 150 | Night Vision raises the ambient light of caves and nights to this grey (0-255). |
| `Server.Fire.Tick`  | true    | Minecraft's doFireTick: off, fire neither spreads, burns blocks nor goes out by itself, and lava lights nothing. |
| `Server.Fire.Difficulty` | 2  | The world's difficulty for fire (0 peaceful .. 3 hard): fire spreads a little faster on harder ones (+ 7 × difficulty on the ignite odds). |
| `Server.HerbSpread` | 1/8 | Chance per random tick that a herb (mint, wild ginger) spreads next to it while fewer than 5 grow within 4 blocks: a try every 9 minutes or so (Minecraft's mushrooms: 1/25). |
| `Sounds.Enabled`          | true    | false turns every sound off (server and clients).                   |
| `Sounds.Volume`           | 1       | Master volume; `Sounds.Sources` per kind (blocks, players, ambient, ui, music). |
| `Sounds.PlayerRate`       | 8       | Sounds a player's inventory clicks and chest opening may cause per second (anti-spam). |
| `Sounds.OverrideFolder`   | IceVoxelSounds | Folder (SoundService / ReplicatedStorage) of replacement Sounds. |
| `Sounds.Sources`          | 1 each  | Volume of blocks, players, ambient and ui sounds and the music.     |
| `Sounds.Footsteps`        | true    | Footsteps of everyone (swimming and splashes still play).           |
| `Sounds.Interface`        | true    | Clicks of buttons and tabs.                                         |
| `Sounds.Ambient`          | true    | Minecraft's cave moods.                                             |
| `Music.Enabled`           | true    | The background music (tracks: `Sounds/MusicList`).                  |
| `Music.Volume`            | 0.5     | A track's Sound.Volume, times the master and music volumes.         |
| `Music.FirstDelay` / `MinDelay` / `MaxDelay` | 5 / 600 / 1200 | Seconds to the first track, and between tracks (Minecraft's 10 to 20 minutes). |
| `Music.CaveExposure` / `SurfaceExposure` / `SwitchSeconds` | 0.2 / 0.5 / 5 | In a cave below this sky exposure (F3), on the surface again above the other, each for SwitchSeconds. |
| `Music.FadeSeconds` / `SwitchDelay` | 4 / 3 | A track of the other kind fades out; the new kind's starts within SwitchDelay seconds. |
| `Music.Toast` / `ToastSeconds` | true / 5 | The Now Playing toast and how long it stays.                    |
| `Time.DayLength`          | 1200    | Real seconds per in-game day (Minecraft's 20 minutes).              |
| `Time.StartTime`          | 1000    | Day time when the server starts (ticks; 6000 noon, 13000 night).    |
| `Time.Cycle`              | true    | Minecraft's doDaylightCycle (false: the time stands still).         |
| `Lighting.CaveAmbient`    | 26, 26, 32 | How dark caves are; raise it like Minecraft's Brightness slider. |
| `Lighting.Enabled`        | true    | false leaves Lighting to the place (only the sun moves; the music and cave moods still follow the light). |
| `Settings.Save`           | true    | Keep players' settings between sessions (DataStore, one profile per kind of device). |
| `Settings.Key` / `GamepadButton` | P / DPadRight | Open and close the Options menu.                 |
| `Settings.ApplyDelay`     | 0.4     | Seconds after the last change before costly ones apply (view, caves, plants, shadows, textures, far meshes). |
| `Settings.SaveDelay` / `LoadWait` | 1.5 / 1 | Seconds before changes are sent to the server; seconds a joining client waits for its saved settings. |

Lighting comes from `default.project.json`: Future technology, shadows and a dark ambient light. With
`rojo serve` into an existing place, check that `Lighting.Technology` is Future (or LightingStyle
Realistic in newer Studios). An Atmosphere or Sky you add is left alone, and
`Lighting.GeographicLatitude` sets how high the sun climbs; the lighting follows the sun wherever
Roblox draws it.

Part count depends on the terrain: flat land costs ~35 parts per full detail chunk, steep
mountains ~110. Most parts are near the player; doubling the view distance adds comparatively
few. Measured views (`lune run tests/bench <seed> <viewDistance> [splitDistance] [splitL1] [x z]`,
seed 12345; "mountains" is inside a range at 3200, -14600):

| View from         | 512 (mobile) | 1024 | 2048 (default) | 4096 |
| ----------------- | ------------ | ---- | -------------- | ---- |
| spawn (hills)     | 14k          | 28k  | 34k            | 46k  |
| mountains         | 29k          | 68k  | 81k            | 97k  |

With far meshes, once every region near the player has settled (the bench prints this too):

| View from         | 2048 (default)          | 4096                     |
| ----------------- | ----------------------- | ------------------------ |
| spawn (hills)     | 16.7k parts + 88 meshes | 20.6k parts + 187 meshes |
| mountains         | 34.8k parts + 90 meshes | 39.5k parts + 191 meshes |

What remains are the near levels (full detail and level 1), which stay parts. In the mountains,
`Lod.SplitDistanceL1 = 2` or a shorter view on weaker devices brings that down.

Plants add parts of their own, only within `Lod.FoliageDistance`: about 1,000-3,000 on grassland,
at most 6,000 (half that on phones); `Render.Foliage = false` saves them.

Keep the playable area within about ±16,000 studs (±5,000 blocks) of the origin: further out,
float precision makes parts and characters jitter.

`Seed = nil` gives every server a random world; set a number for a fixed one. With the title
screen off, `World.Type` picks the world type (`"default"`, `"superflat"`, `"void"`,
`"singleBiome"`, `"largeBiomes"`, `"debugBlocks"`, `"debugStructures"`, `"debugBiomes"`) and
`World.Options` its options, e.g.
`{ preset = "Bedrock,59*Stone,3*Dirt,Grass;Plains", decoration = true }` for superflat or
`{ biome = "Desert" }` for a single biome.

## Extending

**A block.** Append an entry to `src/shared/Blocks/BlockList.luau` (at the end: ids are list
positions and saved edits depend on them):

```lua
table.insert(list, { name = "Marble", color = { 235, 235, 230 }, material = "Marble" })
```

It is immediately an item: it shows up in the creative picker, and survival players get it by
mining it (`hardness = 1.5` for stone-like mining time, `tool = "pickaxe"` and `toolLevel = 0` to
need a pickaxe to drop anything, `drops = "Cobblestone"` or `false` to drop something else or
nothing, `container = 27, menu = "Chest"` for a chest-like block, `maxStack = 1` for an item that
doesn't stack). Blocks that look identical share one part template. `color` and `material` are
its plain look (and the colour a tinted texture takes); its texture goes in the texture pack (see
Block textures below).

**Sounds.** Every sound is a Minecraft sound event (`block.stone.break`, `entity.item.pickup`,
`ui.button.click`...; the full list is `src/shared/Sounds/SoundList.luau`) played with one of the
sounds every Roblox client ships (`rbxasset://sounds/...`: the character's footsteps, landing,
get-up rustle (chest lids, armor), free-fall wind (a cave mood that fails to load), swimming and splash, the
explosion, `oof`, `ouch` and the volume slider's tick; the jump sound is unused), as stand-ins
told apart by pitch. To use your own, add a Folder named `IceVoxelSounds` to SoundService
(or ReplicatedStorage) and put Sound instances in it, named like the event they replace:

```
SoundService
  IceVoxelSounds            Folder
    block.stone.break       Sound (SoundId = rbxassetid://...)
    block.stone.break       another Sound: a variant, one is picked at random
    block.break             every other block type's break sound
    item.armor.equip        every armor material
    entity.item.pickup
```

A Sound named like the event wins; otherwise one named like its category, the event with the
variant left out (`block.break` for every `block.<type>.break`, `item.armor.equip` for every
`item.armor.equip_<material>`). Several Sounds with one name are Minecraft's variants. They play
with their own Volume and PlaybackSpeed (times the volume settings, varied a little like the
built-in ones), heard as far as the event (16 blocks). To change the defaults instead, edit `id`,
`volume` and `pitch` in SoundList: block types have a `dig` clip (breaking, placing) and a `step`
clip (walking, mining hits, falls), scaled per action like Minecraft. A block's sound type is its
`sound` in BlockList (`sound = "metal"`), else its material's. Server scripts can play any event
to the players near a point:

```lua
local Sounds = require(game.ServerScriptService.IceVoxel.Audio.Sounds)
Sounds.play("block.glass.break", x + 0.5, y + 0.5, z + 0.5) -- block coordinates
```

Client scripts can play any event for the local player alone:

```lua
local SoundPlayer = require(game.Players.LocalPlayer.PlayerScripts.IceVoxel.Audio.SoundPlayer)
SoundPlayer.play("entity.generic.splash", x, y, z) -- blocks
SoundPlayer.click()                                -- ui.button.click
```

Sounds are heard from the camera, but never more than 4 blocks from the player's eyes
(`SoundRules.LISTENER_REACH`, Minecraft's third person distance), so zooming out does not
silence the world; a Scriptable camera hears from where it is.

**Music and cave moods.** `src/shared/Sounds/MusicList.luau` holds the game's own audio, like the
texture pack holds the textures:

```lua
Surface = { { Id = "rbxassetid://...", Title = "" }, ... },  -- above ground
Cave = { { Id = "rbxassetid://...", Title = "" }, ... },     -- in caves
Moods = { "rbxassetid://...", ... },                         -- Minecraft's ambient.cave
```

- **Titles:** a track's `Title` is what the Now Playing toast shows; `""` uses the audio's own name
  on Roblox (looked up once).
- **Tracks:** Minecraft's MusicManager timing (Config.Music): the first about five seconds after
  joining, then one at random every 10 to 20 minutes, never the same twice in a row.
- **Surface or cave:** where the player is comes from the sky light reaching the camera (F3's
  `exposure`): under 0.2 for 5 seconds is a cave, over 0.5 for 5 seconds the surface again. A track
  of the wrong kind fades out over 4 seconds and one of the new kind starts within 3; nothing new
  starts while the light says the other place. A track that fails to load is skipped with a warning.
- **Moods:** each becomes the event `ambient.cave.mood<N>` (category `ambient.cave`, so a Sound named
  `ambient.cave` in the override folder replaces them all), played at Minecraft's volume 0.5,
  heard 16 blocks away. The mood itself is Minecraft's
  (`BiomeAmbientSoundsHandler`, `AmbientMoodSettings.LEGACY_CAVE_SETTINGS`):
  - every game tick one block within 8 blocks of the eyes (each axis) is picked;
  - with sky light s > 0 the mood drops s/15 × 0.001;
  - in the dark it changes by (1 − block light) / 6000, and a dark open (cave air) block counts
    4 times (`CaveMood.OPEN_WEIGHT`), so bigger caves fill it sooner: 5 minutes / (1 + 3 × the
    share of open cave around you) — this game's own addition;
  - at 1 a mood sound plays 2 blocks beyond that block and the mood starts over.

  The light is estimated from the blocks, since the engine has no light map: sky light 15 under
  the open sky, one less per step from it along a few rays into tunnels; block light from the
  light sources through open cells, one less per block (a few blocks around in big caverns).
- **Settings:** Music & Sounds has the Music volume, Cave Moods and Music Toasts.
- **F3:** a `music` line shows surface or cave, the track playing (or the time to the next) and
  the mood.

**Pipes and tanks.** A transmitter is a block with `transmitter = { kind = "item" | "fluid", tier =
1..4, restrictive = true? }` and a tank one with `tank = { tier, capacity }` in BlockList; the
per-tier numbers are Mekanism's, in `src/shared/Transmitters/Tiers.luau`. Any block with
`container` slots is an inventory transporters connect to (all slots from every side, unless it is
a furnace, `menu = "Furnace"`). Pipes and tanks carry every fluid of `Shared/Fluids` whose record
says `carriable`.

**A fluid.** Append it to `src/shared/Fluids/FluidList.luau` (ids are list positions, sent and
saved in items: at the end, and at most 255), its blocks with `fluid("<Name>", { color, material,
... }, tickDelay)` at the end of BlockList (the same colour and light as its record), its full
bucket at the end of ItemList, and its flow rules to `RULES` in `src/server/Behaviours/Fluid.luau`
(slope distance, drop off, infinite sources, whether what it washes away burns). The registry and
the flow rules check they agree when the game loads. Its record decides the rest: `color` (pipes,
tanks, gauges, JEI), `light` (a lit fluid gets sparse lights and glows in pipes), `physics` /
`drag` / `push` / `swim` (players and dropped items), `damage` / `burnSeconds` / `extinguishes`
(lava's hurt and burning), `furnaceFuel` (its bucket's burn time), `fogColor` / `fogStart` /
`fogEnd` (the view from inside it) and its bucket sounds.

**A machine.** A machine is a block with `machine = { kind = "name" }` and `energy = { capacity =
J, input = J/t?, output = J/t? }` in BlockList (output only: a generator; input only: a machine
that uses energy; both: a battery). Its kind is a module in `src/shared/Machines/Kinds/`,
required from `Machines/init.luau`:

    return Core.define("generator", {
        slots = { { x = 80, y = 53, accepts = function(item) return Smelting.fuel(item) > 0 end } },
        fields = { "burnTime", "burnTotal" },            -- data after energy and the shared header
        keep = { "burnTime" },                           -- kept in the item with its energy
        panel = { flame = { x = 80, y = 36, value = "burnTime", total = "burnTotal" } },
        tick = function(container, ctx) ... Core.produce(container, 200) ... end,
    })

The server ticks it 20 times a second, joins it to cables and touching machines, keeps its energy
in its item and replicates it; the client draws its panel (slots, gauges, energy bar) and WAILA
lines. Tests bind test-only kinds to spare blocks with `Machines.bind`.
The Heat Generator (`src/shared/Machines/Kinds/Generator.luau`) is the complete version of this
example; the Electric Furnace (`Kinds/Smelter.luau`) is a machine that uses energy, with a
progress arrow, sided slots for transporters, a `rates` override and a `state` field: a code
saying why it is idle ("No power") that Machines records carry to WAILA.
The Solar Panel (`Kinds/Solar.luau`) reads the server's day time and whether its cell sees the sky
from its tick context (`ctx.dayTime`, `ctx.sky(x, y, z)`: cached, never generating terrain), and
`Machines/Upgrades` gives any kind Mekanism's upgrade slots (`Upgrades.slots(x, y)`) and maths
(`ticks`, `energyPerTick`, `capacity`, `production`, `setCapacity`).
Batteries (`Kinds/Battery.luau`) are storage: the same `input` and `output`, no slots and no tick;
EnergyNet does the rest. A kind with fluid tanks gives `tanks = { { name = "oil", capacity = mB,
fluids = { Fluids.OIL }, role = "input" | "output", gauge = { x, y } } }`: the amounts live in its
data after its fields, and pipes, buckets, the ejector, the panel's gauges, WAILA and its item
follow from the role (`insertFluid` / `extractFluid`, `pourBucket` / `fillBucket`, `gauges`,
`tankContents`, `save` / `restore`); its tick uses `tankInsert` / `tankExtract`, and `info` gives
JEI its numbers. The Oil Refinery (`Kinds/Refinery.luau`) and the Combustion Generator
(`Kinds/Combustion.luau`) are the examples. A kind's `lines(view)` adds lines under its status
line (`panel.lines = { x, y }`), and a shaped recipe's `keep` (a key character used once) makes its
result take that ingredient's item data, as a battery's tier upgrade keeps its charge (a shapeless
recipe's `keep` names an ingredient listed once; a result that wears takes its wear too, as the
mint cure keeps a canteen's sips).

**Item data.** A stack may carry `data`, a flat table: at most 16 keys (letters, digits, `_`), values
numbers, strings up to 64 bytes or booleans. Data tables are frozen and shared by copies, so make
a new stack instead of changing one: `Items.withData(stack, { energy = 5000 })`; read it back with
`Items.dataNumber(stack.data, "energy")`. A data key gets a tooltip line with a describer:

```lua
Items.addDescriber("charge", function(data) return `Charge: {data.charge}%` end)
```

A block that keeps its state in its item when broken (Mekanism's sustained data) registers hooks
with the server, the way the Fluid Tank does (`TransmitterWorld.blockDataHooks`):

```lua
serverNet.addBlockData({
	save = function(x, y, z, block) return { energy = 5000 } end, -- just before a survival break
	placed = function(player, x, y, z, block, stack) end, -- right after placing; stack.data intact
})
```

**A light or a shaped block.** `light = 0..15` gives a block one PointLight; `shape = { { size,
offset, rotation?, color?, material?, glow? } }` (pixels from the cell's centre) draws it from
boxes, and `bounds` is the box players aim at. `support = "Down"` (or "Up", "North"...) makes it
need a sturdy block there, and with `behaviour = "Attached"` it pops off and drops when that block
goes; `brokenByFluid = true` lets flowing water wash it away. `item = "Torch"` with `placeable =
false` makes it a variant placed by and dropping another item (the name must be a block item:
checked at load); without `placeable = false` it is an item of its own and drops itself.
`obstructs = true` keeps a block that is not `solid` (a lantern) from being placed inside a
player and lets falling sand land on it; `sturdy = false` keeps torches and lanterns off a solid
cube (leaves, chests, cactus).

**A plant.** Add it through BlockList's `plant()` helper with `plant = { soil = "dirt" }` (or
`"deadbush"`, `"mushroom"`: the soil set it stands on, `Blocks.mayPlaceOn`); the helper fills in
the rest (not solid, instant, grass sounds, `support = "Down"`, `brokenByFluid`, `behaviour =
"Plant"`, `scatter`). A tall plant is two entries: the lower half with `plant = { soil = "dirt",
top = "MyPlantTop" }`, the upper with `plant = { bottom = "MyPlant" }`, which the helper makes the
lower half's variant (no item, no drops, not placeable); give both halves full block `bounds`, as
DoublePlantBlock has. `tinted = true` colours its boxes by the soil's `foliageColor`;
`shearDrops = true` (or an item name, with `shearCount`) is what Shears harvest. Keep the shape
to 4 boxes inside the outline whichever way it turns: tests/spec/Plants checks it. Give it a
`Sprite` in the texture pack (each half of a tall plant its own) and, once filled, it is drawn as
two crossed images instead of its boxes. From your own
server scripts place a tall plant with `EditRules.setPlaced(world, x, y, z, block)`:
`world:setBlock` sets only the half you give it, and a half alone pops on the next tick. A plant
planted by an item that is not itself (seeds, berries, the herbs' leaves and roots) is
`placeable = false` in BlockList and named by that item's `places` in ItemList (Minecraft's
ItemNameBlockItem): the item places it, is its drop and is what pick block takes, and keeps its
own model (BlockList Mint and ItemList MintLeaves). A plant that spreads by itself gets a
behaviour of its own that keeps Plant's `onTick` and adds `onRandomTick` (`Behaviours/Herb`).
Generation grows it from a biome's `foliage` lists (`plants`, `flowers`, or `herbs` for rare
patches of their own; BiomeList).

**An item.** Items that are not blocks (armor, tools, materials) live in
`src/shared/Items/ItemList.luau` (again appended at the end). They are drawn from boxes measured
in pixels (1/16 block), so icons, dropped items and hands show them without any assets.

**A recipe.** `src/shared/Crafting/Recipes.luau` lists them by item name, like Minecraft's data
files:

```lua
shape({ "##", "##" }, { ["#"] = "Marble" }, "MarbleBricks", 4) -- shaped, anywhere in the grid
mix({ "Marble", "Coal" }, "DarkMarble")                       -- shapeless
smelt("Marble", "SmoothMarble")                               -- furnace
```

**A mob.** Append a kind to `src/shared/Entities/MobList.luau` (ids are list positions, sent as a
u8: at the end) with Minecraft's numbers; everything else follows from its record:

```lua
table.insert(list, {
	name = "Goat", hostile = false,
	width = 0.9, height = 1.3, eye = 1.1, health = 10, speed = 0.2,
	wander = 1, panic = 1.25,                                  -- speed modifiers
	drops = { { item = "Leather", min = 0, max = 1 } },        -- loot (chance?, byPlayer?)
	spawn = { weight = 5, group = { 2, 3 } },                  -- creatures: on grass, in the light
	sounds = { hurt = "entity.goat.hurt", death = "entity.goat.death" }, -- SoundList events
	parts = {                                                  -- at most 2 boxes, +Z forward
		{ size = { 0.9, 0.9, 0.9 }, offset = { 0, 0.75, 0 }, color = { 220, 214, 200 } },
		{ size = { 0.4, 0.45, 0.4 }, offset = { 0, 1.0, 0.55 }, color = { 200, 190, 170 } },
	},
	color = { 220, 214, 200 },                                 -- WAILA's icon
})
```

A monster (`hostile = true`) hunts players within `follow` blocks and hits for `attack` half
hearts; `burnsInDaylight`, `climbs`, `darkOnly`, `leap`, `fuse = { ticks, power, start, cancel }`
(a creeper) and `bow = { range, draw, interval, min, max }` (a skeleton) give it Minecraft's
behaviours (`server/Mobs/MobAI`). Add its two sound events at the end of SoundList. From a server
script:

```lua
local Mobs = require(game.ServerScriptService.IceVoxel.Mobs.Mobs)
local id = Mobs.spawn("Zombie", x + 0.5, y, z + 0.5)            -- feet position (blocks)
Mobs.damage(id, 4, nil, x, z)                                 -- half hearts, knocked back from (x, z)
for _, mob in Mobs.near(x, y, z, 16) do print(mob.kind, mob.health) end
Mobs.died:Connect(function(killer: Player?, kind: string, x, y, z, id)
	if killer then print(killer.Name, "killed a", kind) end
end)
```

**Food.** `src/shared/Items/Foods.luau` lists what eating an item does: `[Items.id.CookedBeef] =
{ heal = 4 }` (half hearts) with an optional `effect = { kind = "thirst", chance, ticks }`; any item
in the table is eaten with the 32 tick hold, with no other change.

**Ages, skills and knowledge.** A new result belongs to the Stone Age (open to everyone) unless
an Age names it: add its name to that Age's `recipes` in `src/shared/Progression/Ages.luau` (a
spec checks every name is an item a recipe makes). An Age is `{ id, name, level, milestones,
reward, recipes, color }`; milestones are discoveries, `{ category = "craft", key = "Furnace",
text = ... }` or `{ category = "biome", count = 6, text = ... }`; ids are what saves keep, so
Ages may be renamed or inserted. A skill is an entry at the end of `SPECS` in
`Progression/Skills.luau` (the protocol numbers them): `{ id, row, icon, name, description,
age, requires, perk, recipes }`, its cost its Age's number, its `perk` one of the kinds there
(knowledge, mining, wear, thirst, insulation, boiling), `recipes` results it unlocks besides
their Age. Knowledge numbers are tables in `Progression/Knowledge.luau` (DISCOVERY, ORES,
SMELTED, MOBS). From server code, `Players/Progression`: `award(player, points, reason)`,
`discover(player, category, key)` (true when it was new), `killed(player, mobName)`, `state(player)`,
`allows(player, item)`.

**Block textures (the texture pack).** Every block texture is in one hand-edited module,
`src/shared/TexturePack.luau`, like a Minecraft resource pack. Its `Textures` table lists the
images by name, lower case with spaces (`"grass top"`, `"log"`, `"packed mud"`...):

```lua
["log"] = {
	Color = "rbxassetid://120423551204729",  -- the colour map ("" = not made yet)
	Normal = "rbxassetid://109169967309613", -- optional, like Roughness and Metalness
	Material = "Wood",                       -- the Roblox material the MaterialVariant is based on
	Tint = true,                             -- take the voxel colour (below)
	-- Average = { r, g, b },                -- the image's average colour (below)
},
```

`Material` is what the textured parts take, so pick the material closest to the picture (a block
keeps its own sounds); Neon, Glass, ForceField, Air and Water cannot take a MaterialVariant.
`Align = false` marks a noisy texture (leaves) that never needs odd boxes (see the tiling check
below). The pack's `Blocks` table says which texture each block shows on each face: `All`,
`Sides`, `Top` and `Bottom` (a face given nothing falls back to All, then Sides), `Front` for glow
lichen (the face looking away from what it hangs on) and `Sprite` for plants (two crossed images).
An entry also covers the block's cave twin and the other blocks of its variant group (the six
glow lichen sides, a tall plant's top half unless it has its own). Fluids, air, torches and
lanterns, pipes, cables and tanks, machines and the solar panel, structure blocks and jigsaws and
the Glow Block (Neon) are never textured. One tile covers one block face (`StudsPerTile = 3`): a
512 × 512 image per 3-stud face. Blocks checks the pack when it loads and fails naming the mistake
(an unknown block, face or texture, a material that cannot take a variant, an entry for a cave
twin), so a typo fails loudly in Studio and in the tests.

To fill in a texture:

1. Upload the image and paste its **Image** id into the entry: `Color = "rbxassetid://<number>"`
   (and `Normal`, `Roughness`, `Metalness`). A Decal id is a different number, which Studio
   converts when you paste it into a property but nothing converts here (see the checks below).
2. Run `lune run tests/build_textures`. It writes `src/textures/Materials.model.json` (a
   MaterialVariant `IV_<name>` per filled texture, spaces as `_`, e.g. `IV_grass_top`, in
   `MaterialService.IceVoxel`) and `src/textures/Images.model.json` (a Texture of the same name per
   filled texture, in `ReplicatedStorage.IceVoxelTextures`: the game clones these for face images,
   sprites and item cubes, since a clone keeps the normal, roughness and metalness maps that game
   scripts cannot set). Game scripts cannot make MaterialVariants either, which is why they are
   made here. Never edit the two files, nor the variants in the Material Manager: the next run and
   sync overwrite them.
3. Rojo syncs them into Studio while `rojo serve` runs (`rojo build` puts them in the place file).
   Save or publish the place so they ship.

`lune run tests/build_textures --list` prints the blank textures with the blocks waiting on each,
then the filled ones still without an Average; `--check` exits 1 when the files are out of date
(the TexturePack spec in the test suite fails then too). Every run ends with a note while filled
textures have no Average. The generator writes nothing for a pack with errors (ids that are not
`"rbxassetid://<number>"`, unknown fields, bad averages, and whatever Blocks refuses) and warns
about a normal map that repeats its colour map and about filled textures no block uses.

**Blank entries.** `Color = ""` means "not made yet": 60 entries wait for you (`--list` names
them). While a block's sides and top are blank it keeps its plain Roblox material and colour, as
without textures. A part takes one MaterialVariant on all six faces, so once its sides' texture is
filled in (or its top's, when the bottom has no other filled texture) its blank faces show that
one: a log's ends show the bark until `"log top"` is filled, cut sandstone's blank sides show the
sandstone top. A filled top that differs from the sides is drawn over the top face as an image.
`ShowMissing = true` draws the missing texture (`"missing texture"`) in place of blank textures, so
you can see in game what is left to make: on every face of a block whose sides are blank (unless
its filled top stands in for them), on blank tops, and on blank plant sprites and glow lichen. A
blank bottom, or blank sides under a filled top, show the block's texture as above unless they are
drawn as images of their own: bottoms with `Config.Textures.BottomFaces`, sides with `SideImages`.

**Tint** makes a texture take the voxel colour (BlockList `color`):
- `true` (the default): the colour of the block it is drawn on, so one light image serves every
  wood: `"log"`, `"planks"` and `"leaves"` show oak, birch, spruce, acacia and jungle each in its
  own colour, and dry grass shows the grass top in its own colour;
- `false`: the image's own colours (ores, the grass side, glow lichen, flowers and mushrooms);
- a block name: that block's colour wherever it is drawn (`"dirt"` is `Tint = "Dirt"`, so the dirt
  under grass is dirt coloured, not grass coloured).

A tint can only **darken**: a part shows its texture times its Color, which Roblox stores in 8 bits
and stops at white. So a texture shared by tinted blocks should be light, ideally greyscale, and at
least as light as the lightest block using it (birch logs are far lighter than spruce ones). Images
(face images, sprites, item cubes) are not clamped and can also brighten. Once a texture's Average
is known, a block it would leave more than 4 (of 255) too dark draws it as tinted images over the
variant up close (more instances) and in its plain colour far away, so the block still takes its
colour; see-through blocks just draw it darker. One warning lists them, worst first:
`[IceVoxel] textures darker than the blocks they tint (by how much, 0-255): ...`. A lighter image
keeps the plain variant.

**Average** (`{ r, g, b }`, 0-255) is the image's average colour (the mean in linear light, written
as sRGB). With it the tint is exact (voxel colour / average per channel, in linear light, so the
block averages exactly its voxel colour), and distant chunks take the colour each block really
shows on screen. Without it the colour is simply multiplied in and distant chunks guess (the
voxel colour). No texture has one yet. With `Config.Textures.MeasureAverages` the game measures
every texture without one shortly after joining, in the background, and prints a block to the
output (Studio's Output, or F9 in game):

```
[IceVoxel] Texture averages (paste into TexturePack.Textures[...].Average):
	Average = { 121, 85, 58 }, -- ["dirt"]
```

Paste each line into the entry the comment names, so it is never measured again (until then the
world is restyled once per session when the averages come in). Textures it could not measure are
named, with the reason.

**How textures are drawn** (`Rendering/TextureLooks` decides every look; with the Textures
setting off every block is drawn in its plain material and colour, plants as boxes):
- **Near** (full detail): a cube's parts take one MaterialVariant on every face, in its texture's
  Material and tint: the sides' texture, else the top's when it stands alone. A different filled
  top (grass, sandstone, cactus) is a Texture image over the top face; `BottomFaces` adds the
  bottom as an image, `SideImages` draws the sides as images over the top's variant. Chests,
  crafting tables and furnaces keep their decorated faces over their texture.
- **Far** (LOD levels the far meshes never merge: level 1 and the widest nodes; and the merged
  ones while Far Materials is on or far meshes are off): one variant per part and no images: the
  top's texture, which dominates from afar, else the sides'.
- **Plain** (the merged levels 2-5, about 200 blocks away and further, while far meshes run and
  Far Materials is off): SmoothPlastic in the colour the block's top averages to on screen,
  texture and tint included. The far meshes take the same colours, so distant terrain keeps the
  colours of the textured terrain near you (once the averages are known).
- **Plants** with a filled `Sprite` (`Config.Textures.Sprites`): two crossed see-through planes
  along the cell's diagonals carrying the image on both sides, offset and turned like the boxes;
  grass and ferns take their soil's foliage colour. Blank sprites keep their boxes.
- **Glow lichen** with its `Front` texture: the plate goes see-through and shows the image on its
  face away from the wall; the glowing speck stays.
- **Items**: a textured block's item is a cube with one image per textured face, one tile per
  face, in its tint (untextured faces keep the block's material and colour); a plant's item is its
  sprite on an upright plane. Item icons build their models again a few per frame when looks change.
- **The missing texture** (`IV_missing_texture`) is drawn for blank textures with ShowMissing, for
  a texture whose id failed to load, and for one whose MaterialVariant is not in MaterialService
  (the generator was not run, or Rojo is older than 7.7; the output names it and the fix).

Looks drawn before the startup checks finish are provisional: when averages come in, an id
fails, or the Textures or Far Materials setting changes, only the chunks whose look changed are
rebuilt, off-screen in the background within the frame budget, and swapped in.

**Rojo 7.7.1.** The generated files use properties Rojo 7.4 does not know (`ColorMapContent`,
`TextureContent`...), so `rokit.toml` now pins Rojo 7.7.1. Once:
1. `rokit install`;
2. `rojo plugin install` (or update the plugin from the Creator Store): a 7.4 Studio plugin cannot
   talk to a 7.7 server;
3. delete any `IV_...` MaterialVariants you made by hand in MaterialService (the old way to add
   textures): one with the same name and base material as a generated one leaves Roblox to use
   either. Rojo manages only `MaterialService.IceVoxel`, so other variants are left alone.

**Check once in Studio:**
- **Image ids.** Every id must be an Image id. To check one, paste it into a Decal's Texture
  property: if Studio turns it into another number, that number is the Image id. With
  `Config.Textures.ValidateIds` the game loads every id once at startup and names each one that
  fails (`[IceVoxel] texture "..." (rbxassetid://..., used by ...) failed to load ... Most likely
  it is a Decal id`): a failed colour map draws the missing texture, a failed normal, roughness or
  metalness map leaves the texture without it. Check the missing texture's own id, `925810526`,
  first: it is an old, short id that may be a Decal id, and if it fails, ShowMissing and failed
  textures show the plain block instead.
- **Tiling** (`Config.Textures.OddBoxes`). A part most likely tiles a MaterialVariant from a corner
  of each face, so boxes of any size show whole tiles. Place parts 3, 6 and 9 studs long (3 × 3
  across) side by side on the block grid, all in the same variant (e.g. Material Slate,
  MaterialVariant `IV_stone`). If the tile lines on the 6-stud part fall in the middle of its
  blocks, tiles are centred: set `OddBoxes = true`. Every box of a textured cube is then an odd
  number of blocks along each axis at full detail (leaves are left out), for 14-18% more parts
  near the player (up to 49% on flat plains) and no measurable meshing time. Far levels never use
  it.
- **Grass sides** (`Config.Textures.SideImages`). Look at a grass block from the side: the green
  fringe of `"grass side"` must be along the top. If the variant's sides come out turned, set
  `SideImages = true`: the four sides are then drawn as upright images over the top's variant
  (four more instances per part).
- **Averages.** Measuring needs "Enable Mesh / Image APIs" (Game Settings > Security, or the
  Creator Dashboard) and images the place's owner owns; otherwise the output names the textures
  it could not measure and why. Paste the printed averages, so players never need it.
- **Far Materials**, if you use it: a far MeshPart should show one tile per block, sides upright,
  tinted by the block colours; if not, adjust `Config.Render.FarMeshes.UvStuds`.

**The sheet's oddities**, as transcribed:
- leaves: the normal map repeated the colour map's id, so leaves have no normal map;
- packed mud ("darker dirt"): dirt's colour map, and its normal map repeated that id too, so it
  uses dirt's normal map (`72051511434165`). It is tinted with PackedMud's colour, now
  `{ 97, 68, 46 }`, darker than Dirt in every channel (it was lighter), so river beds and the
  outpost's paths are darker than before, textures on or off;
- calcite uses stone's normal map, as the sheet gives it;
- the missing texture's size is unknown, and its id may be a Decal id (above);
- dry grass shares grass's top, in its own colour, but its sides are a blank `"dry grass side"`
  of their own (the grass side's green fringe would not suit it): until you fill it they keep
  dry grass's plain material and colour;
- the crafting table's bottom falls back to its sides (Minecraft's is planks: `Bottom =
  "planks"`, seen only with BottomFaces), and smooth sandstone is the sandstone top on every face,
  as in Minecraft.

**Spawn safety.** `src/server/Players/SpawnUnsafeBlocks.luau` lists what a player must not stand on
(`Floor`), stand in (`Body`, fluids by name) or touch (`Hazards`), plus the headroom and search
radius. Spawns and map teleports search outward for the closest spot that passes, and never put
players below the natural surface (caves), nor at the bottom of a pit or a ravine (the floor at
the natural surface must be solid); the generator's spawn also skips columns a surface cave
opens.

**The map.** The minimap and world map draw terrain with EditableImage. That API works in Studio
right away, but **published games** need the experience owner to be 13+ and ID verified and to turn
on *Enable Mesh / Image APIs* (Creator Dashboard, experience settings). Without it the maps still
show players and waypoints, and the right click menu still works. Teleporting is controlled by
`Config.Map.Teleport` and checked by the server.

**Far meshes (EditableMesh superchunks).** Distant terrain (LOD level 2 and up, about 200 blocks
and further) is merged per region of 4 × 4 chunks into MeshParts once the region has not changed
for 2 seconds. About the "8 EditableMesh limit": it is not a count but a memory budget. A PC
client gets 80 MiB for editable objects and every growable EditableMesh is charged a flat 10 MiB,
whatever it holds. IceVoxel therefore keeps one EditableMesh for the whole session as a scratch
buffer: each region is written into it, *baked* into static content with
`AssetService:CreateDataModelContentAsync` (which does not count against that budget), cleared,
and shown with `CreateMeshPartAsync`. So any number of regions can be merged.

- Like EditableImage, it needs the Mesh / Image APIs enabled for published games (see The map).
- A few seconds after joining, a probe builds a few test meshes and times them against the usual
  frame time; press **F3** to see the status, how many regions and chunks are merged, and how long
  builds take. Meshes stay off (parts only, with their normal look) when the Mesh APIs are
  unavailable, the probe fails, or building makes frames more than `MaxBlockingMs` longer.
- Merged levels use a plain look for their parts too: SmoothPlastic in the colour each block
  averages to on screen (its texture and tint included), water opaque, so swapping between parts
  and a mesh is invisible and distant terrain keeps the colours of the textured terrain near you.
- **Far Materials** (Options, Video; `Config.Render.FarMaterials`, off by default) keeps materials
  and textures on the merged levels instead. Their parts take the far look (one MaterialVariant
  per block, the top's), and each region's mesh is split by look (material + variant +
  transparency + reflectance), since a MeshPart has one material:
  - a look covering at least `FarMeshes.LookMinShare` (5%) of the region gets MeshParts of its
    own, at most `MaxLooks` (4) looks, the largest;
  - the rest is drawn plain (`LookRemainder = "plain"`), or joins the largest opaque look
    (`"largest"`), its vertex colour set so that look's texture averages to the colour it replaces;
  - textured meshes get UVs from world positions, one tile per `UvStuds` (3) studs, so tiles line
    up with the blocks at every level, and their vertex colours carry the tints.

  That is about 2-5 MeshParts per region instead of 1-2, so meshes take longer to catch up;
  switching rebuilds the merged levels in the background. F3's meshes line then counts the
  MeshParts in a material: "N parts (M with materials)". The probe also builds a mesh in a
  material; if that fails, the output says `[IceVoxel] Far Materials off: ...` and meshes stay
  plain whatever the setting. Not checked in Studio yet: whether a far MeshPart's material follows
  the written UVs (one tile per block, sides upright; adjust `UvStuds` if not) and whether vertex
  colours tint it.
- Phones keep parts by default (`FarMeshes.Mobile`).
- Builds wait while the camera moves (`MaxBuildSpeed` blocks a second over `SpeedWindow`
  seconds: walking, 70 builds a minute became ~3), while the streamer has much to do and after
  teleports; a build already running stops between MeshParts. Players can switch meshes off in the
  Options menu (Performance).
- Not yet measured on live servers: how long builds take on real clients, whether baked content
  is reclaimed over long sessions (a bake that hits the engine's storage limit switches meshes
  off; meshes in the world are capped at `MaxLiveTriangles`), and how far the engine then
  actually draws. Check F3 and the MicroProfiler in a published test place before relying on it.

**A player setting.** Append an entry to `ENTRIES` in `src/shared/PlayerSettings.luau` with the
next id (ids are saved and sent: never reuse or renumber one), its kind, range, step, default,
page and the effect key that applies it; put it on its page in `src/client/Settings/Pages.luau`;
and register what the effect does in the client script (`Settings.register("myEffect", fn)`, `fn`
taking the values table). Costly effects also go in `PlayerSettings.EXPENSIVE` (they wait until a
slider stops), and `EFFECT_ORDER` says in which order effects run. Settings marked `preset` take
their value from each of the `PRESETS`. Worker actors keep their own Config, so anything a worker
needs travels in its jobs.

**A biome.** Add an entry to `src/shared/Biomes/BiomeList.luau` with the altitude bands it appears
in, a climate position (temperature, humidity), surface blocks (optionally patches of another
block and a block for steep slopes) and vegetation. The terrain shape comes from `Relief`, so a
biome only decides what grows and what the ground is made of. Its ground plants are `foliage`: an
average `density`, the share of the ground in patches (`cover`), weighted `plants` and optional
`flowers` (see the BiomeList header); keep within the parts budget tests/spec/FoliageGeneration
checks.

**A world type.** Register it in `src/shared/Generation/WorldTypes.luau` (or from your own module
before the world is created) with an id, a name, a description and `create(seed, options)`
returning a generator built only from the seed and the options (every client and worker builds it
too). A flat or laid-out world is a few lines with `Generation/LayeredGenerator`: a stack of
layers (`LayeredGenerator.stack({ { block = Blocks.id.Stone, count = 60 }, ... })`), one
everywhere or per column, blocks laid over it and an optional structure placer; it answers
everything the server, the streamer, the far terrain and the map ask, at every level. Declare
its options in `settings` (toggles, choices, texts) for the Create World screen, and the hints
`mobs = false`, `ticks = false` or `gameMode` when it needs them. To try one without the menu,
set `Config.World.Type` and `Config.World.Options` with `Config.MainMenu.Enabled = false`. A new
superflat preset is a line in
`Superflat.PRESETS`.

**A tree or another small feature.** Write a builder in `Generation/Structures/` (see
`Trees.luau`), register it in `Structures.registry` with the blocks it may grow on, and list it in
a biome's `features`. Builders write in world coordinates; chunk clipping, cross-chunk consistency
and LOD are handled for you.

**A structure**, from building it to seeing it generate. Structure blocks and jigsaws need
creative and permission: an operator (the game's owner, Studio, `Gameplay.Admins`, `/op`) or a
user id in `Config.Structures.Permission`.

1. **Build it** in creative. Air you leave inside the region is saved as air and clears whatever
   is there when the structure is placed; put a Structure Void (creative picker) where the world
   should stay as it is instead (around a ruin, under a path). For a piece of a bigger structure,
   put Jigsaw blocks where other pieces attach (step 5).
2. **Mark the region.** Place a Structure Block (it starts in Save mode) and right click it. Give
   it a name with slashes, Minecraft style: `mything/houses/hut` (the part before the last slash
   is its pool, step 5). Set the relative position (from the block to the region's lowest
   north-west corner, default one block above it) and the size; the outline shows the box. Or put
   two Corner structure blocks named alike at opposite corners just outside the region and press
   DETECT.
3. **Save** (SAVE). The chat says `Saved structure 'mything/houses/hut' (N blocks, M characters)`
   and the data, `IVS1:...`, appears in the box under the size: click it and press `Ctrl` + `C`
   (`Cmd` + `C`). Long data comes in parts of 16,000 characters ("part 2 of 9"): copy every part in
   order and put them together.
4. **Keep it**, any of these ways:
   - **Send it to Claude** in a chat message (words around it are fine): it goes into
     `src/shared/StructureLibrary/Templates/` as a module.
   - **Put it in the repo yourself**: a ModuleScript (any name, any folder depth) in
     `src/shared/StructureLibrary/Templates/` returning the text, or a list of texts:
     ```lua
     return "IVS1:..."
     ```
     A `.txt` file holding the text works too (Rojo makes it a StringValue). The name inside the
     data counts, not the module's.
   - **Keep it in the place**: during a Studio playtest every save is a StringValue named after the
     structure in `ServerStorage.IceVoxelSavedStructures`. Copy it, stop the playtest and paste it
     into a Folder named `IceVoxelStructures` in ReplicatedStorage (make it; Folders inside are
     fine). Saves only last for the session: nothing is written anywhere else.

   To place it again by hand, use a Structure Block in Load mode with its name (this session's
   saves and the library), or paste the data into Paste Data: a LOAD whose size differs from the
   structure's only sets the size (the outline shows where it goes), the next places it, turned
   and mirrored as set. The library is read once when the server and each client start (every
   machine must generate the same structures), so new templates are seen from the next start or
   playtest on.
5. **Join pieces with jigsaws** for a structure like a Minecraft village:
   - Name the pieces by pool: `mything/centres/plaza`, `mything/houses/a`, `mything/houses/b`,
     `mything/streets/straight`... A pool needs no code: `mything/houses` is every template named
     `mything/houses/...` (weight 1, rigid), and a pool named like one template is that template.
   - On a piece, a jigsaw whose front faces out of it marks where a child attaches: its **target
     pool** is where the child comes from, its **target name** the name of the child's jigsaw that
     attaches here, and **Turns into** what it becomes once generated (air, or `Planks` to close a
     wall). On the child, a jigsaw facing out with that **name**. Two jigsaws attach when they face
     each other, the names match and, for jigsaws facing up or down, their tops match unless the
     source's joint is rollable. Each child must fit beside what is already there.
   - Try it at once: a jigsaw's Generate builds from its pool right there, Levels deep, and this
     session's saves are already in their pools (Keep Jigsaws leaves the jigsaws to look at).
   - `src/shared/StructureLibrary/Pools.luau` adds weights (1..150), empty elements (a plot left
     empty), a fallback pool (tried after the elements, and alone at the last level: end caps) and
     terrain matching pieces, which follow the ground column by column (paths). In the place, the
     attribute `TerrainMatching = true` on a StringValue makes its templates terrain matching in
     the pools made from their names.
6. **Make it generate.** In the repo, add an entry to `src/shared/StructureLibrary/Structures.luau`
   (its header lists the fields: `name`, `startPool`, `size` (jigsaw depth 0..7), `maxDistance`,
   `biomes`, `spacing` / `separation`, `salt`, `startHeight`, `projectToHeightmap`, `onLand`,
   `foundation`). In the place, set the attribute `Generate = true` on the StringValue whose
   (first) template is the start, and optionally `Biomes` (`"plains, forest"`: BiomeList names;
   case, spaces, underscores and `minecraft:` are ignored), `Spacing` and `Separation` (one start
   per Spacing × Spacing chunks, at least Separation apart; default 34 / 8, Minecraft's villages),
   `Size`, `Foundation`, `OnLand`, `StartHeight` and `MaxDistance`. Problems (an unknown pool,
   biome or block, a bad attribute) are warned in the output as `[Structures] ...` and skipped;
   nothing errors.
7. **See it.** Structures generate in terrain nobody has edited, wherever a start lands: while
   testing, a small spacing (`Spacing = 4`: one start per 64 × 64 blocks) finds one quickly. From a
   server script, every generated structure with a piece in a rectangle:
   ```lua
   local IceVoxel = require(game.ServerScriptService.IceVoxel.Api)
   local world = IceVoxel.waitForWorld()
   for _, s in world.generator.structures(-1000, -1000, 1000, 1000) do
       print(s.name, s.x, s.z) -- the start position (blocks)
   end
   ```
8. **Look inside the data** without the game:
   `lune run tests/structure decode <file | IVS1:... | ->` prints every structure in a file (a
   pasted chat message, a library module) or the text given: name, size, palette, every y layer as
   ASCII, jigsaws, data markers, containers. `--lua hut.luau` writes an editable table ("." air,
   " " keep), and `lune run tests/structure encode hut.luau --module` turns it back into a library
   module.

The example outpost is a complete jigsaw structure to copy: its pieces are built in code by
`tests/build_structures.luau` into `Templates/Outpost.luau` (`lune run tests/build_structures`;
`--check` tells whether that file is up to date, `--print` shows every piece), its pools are in
`Pools.luau` and its entry in `Structures.luau`.

**A block behaviour.** Create a module in `src/server/Behaviours/` (see `Grass.luau`) with
`onTick(world, ticker, x, y, z, block)` (scheduled after a neighbour changes, `tickDelay` ticks
later) and/or `onRandomTick(world, ticker, x, y, z, block, random)` (random ticks) and set
`behaviour = "YourModule"` on the block.

**A flammable block.** Give it `flammable = { ignite = 5, burn = 20 }` in BlockList (Minecraft's
FireBlock odds: wooden blocks 5 / 20, wool 30 / 60, plants 60 / 100); fire then clings to it,
spreads next to it, burns it away and lava sets it alight. From a server script, `Fire.ignite(world,
x, y, z)` (`ServerScriptService.IceVoxel.Behaviours.Fire`) lights a fire anywhere, and
`world:setBlock(x, y, z, Blocks.id.Fire)` does the same (it goes out the next tick where nothing holds
it: `Shared/Fire.canSurvive`).

**Server-side world access** from your own scripts:

```lua
local IceVoxel = require(game.ServerScriptService.IceVoxel.Api)
local Blocks = require(game.ReplicatedStorage.IceVoxel.Blocks)

local world = IceVoxel.waitForWorld()
world:setBlock(10, 80, 10, Blocks.id.Stone) -- replicated to every client, triggers block updates
print(world:getBlock(10, 80, 10))
IceVoxel.explode(10.5, 82, 10.5, 4) -- a TNT-sized blast on the next tick (true as a fifth argument sets fire)
```

**A heat or cold source (Tough As Nails).** Name a block or fluid in
`Config.ToughAsNails.HeatingBlocks` / `CoolingBlocks`, or, for one that warms only in some state,
register it from a server script with a check (lit furnaces and working generators are done this
way in `Players/ToughAsNails`):

```lua
local Climate = require(game.ServerScriptService.IceVoxel.Players.Climate)
Climate.addHeatSource("Brazier", function(x, y, z, block)
	return isLit(x, y, z)
end)
Climate.addColdSource("PowderSnow")
```

A source counts within `ProximityRadius` blocks of the player's feet (a cube), checked once a
second, and warms 3 steps (5 when one is within 2 blocks, and then cold sources don't cool) or
cools 3, however many there are. A name no block has yet is skipped with a warning, so a block
can go into `HeatingBlocks` before it exists (the Campfire is listed there).

**Drinks and containers (Tough As Nails).** `Shared/ToughAsNails/Drinks` reads three tables:
`ITEMS` (a full item: its drink, the empty container it leaves, `sips` for a canteen), `FILLS` (an
empty container and the dirty water it fills with at a water source) and `PURIFIED_OF` (dirty
water and its purified twin). A new container is four entries there and its recipes, as the
bowls are:

```lua
-- Drinks.ITEMS
[I.DirtyWaterBowl] = table.freeze({ drink = Drinks.DIRTY_BOWL, empty = I.Bowl }),
[I.PurifiedWaterBowl] = table.freeze({ drink = Drinks.PURIFIED_BOWL, empty = I.Bowl }),
-- Drinks.FILLS
[I.Bowl] = I.DirtyWaterBowl,
-- Drinks.PURIFIED_OF
[I.DirtyWaterBowl] = I.PurifiedWaterBowl,
-- Crafting/Recipes: the furnace and mint
smelt("DirtyWaterBowl", "PurifiedWaterBowl")
mix({ "DirtyWaterBowl", "MintLeaves" }, "PurifiedWaterBowl")
```

A drink of its own (the teas, a juice) is an `ITEMS` entry with a `Drink` and the container it
leaves (`[I.MintTea] = table.freeze({ drink = Drinks.MINT_TEA, empty = I.Bowl })`); `warmth` /
`chill` ticks give TAN's Internal Warmth / Internal Chill, which move the temperature target 5
steps towards neutral without pushing it past neutral (`Drinks.MINT_TEA` has `chill = 2400`).
Every `PURIFIED_OF` pair also boils clean on a Campfire (`ToughAsNails/Boiling`) and shows in
JEI's Campfire tab, with nothing more to add.

**Insulating armor (Tough As Nails).** An armor piece's `tan = { warmth = n, cooling = n,
freezeImmune = true }` in ItemList: `warmth` steps pull a cold target up towards 0, `cooling`
steps pull a hot one down, never past it; `freezeImmune` stops hypothermia (leather has it). A
full set at 2 a piece keeps a tundra (-10) neutral (-2); straw (warmth 1) and leaf (cooling 1)
sets are made the same way, from `INSULATING_ARMOR` at the end of ItemList (a material entry:
name, colour, material, points, toughness and `tan`; new materials go there, never into the
`ARMOR` table at the top, whose ids must not move).

**A status effect.** Append it to `src/shared/Effects/EffectList.luau` (ids are list positions,
sent in the Effects message: at the end) with its name, `/effect` id, colour, category and HUD
glyph (`icon`, one of `client/Ui/EffectIcons`' 9 × 9 glyphs; add one there for a new look), and
what it does as data: `speed` / `mining` / `jump` / `melee` / `resistance` per level (the movement,
mining, combat and hurt paths read them through `Shared/Effects`), `interval` with `heal` or
`damage` (ticked on the server), `fireImmune`, `burnFactor`, `burnBonus`, `ignites`, `washOff`,
`noSprint`, or a client `view`. It then works with `/effect`, potions, the HUD and F3:

```lua
{ name = "Haste", command = "haste", color = { 217, 192, 67 }, category = "beneficial", icon = "pickaxe", mining = 0.2 },
```

Server code gives and reads effects through `Players/Effects`: `Effects.give(player, "Speed",
600, 1)` (ticks, amplifier; `Effects.INFINITE` for good), `giveAll`, `remove`, `clear`, `has`,
`amplifier`, `levels`; combat changes a hit's half hearts with Strength and Weakness
(`Effects.meleeDamage(player, base)`; the mobs' MobWorld.attack takes the player's `levels`), and
any hurt goes through `Effects.incomingDamage(player, amount)` (Resistance) before `TakeDamage`
(Players/Characters does for lava, fire, blasts, falls, walls, mobs' hits and the effects' own
hurts). A player's mining speed is `Mining.playerFactor(levels, progress, tool)`: the effects'
times the Progression perks', on the client and the server alike. A mob could keep an `EffectRules` state of its own: `EffectRules.give`
/ `tick` (the hurt and healing per tick) / `levels`, and `Shared/Effects`' modifiers on those
levels. An effect kept elsewhere (Tough As Nails' four) is `external = true` and registered with
`Effects.addExternal(id, { get, give, clear })`, so it is listed with the rest.

**A potion.** Append it to `src/shared/Effects/PotionList.luau` (item ids follow its order: at the
end): `{ name = "Swiftness", ingredient = "MintLeaves", effect = "Speed", seconds = 180, strong =
90, long = 480 }` makes the items (`PotionOfSwiftness`, `StrongPotionOfSwiftness` "Potion of
Swiftness II", `LongPotionOfSwiftness`), their recipes (a Purified Water Bottle with the
ingredient; the potion with Glow Dust or a coal) and the drinks (`Drinks.ITEMS` with `effects`:
the effect given when the 32 tick drink finishes, the Glass Bottle back), with nothing else to
add. Leave `seconds` out for an instant effect (`strong = true` for its II).

**A fluid's effects.** A fluid's `effects` in FluidList lists what touching it gives: `{ effect =
"Slowness", seconds = 1, amplifier = 1, when = "in" }` (refreshed every tick while in it), `when =
"head"` (the eyes in it), `when = "left"` (given on leaving it) and `after = 3` (only after 3 s in
it without a break). Effects with `washOff` come off in a fluid that `extinguishes` (water).

**Blast resistance.** A block's `blastResistance` in BlockList is Minecraft's explosion resistance;
leave it out and it is the block's hardness (unbreakable blocks 3,600,000). Minecraft's values
that differ from the hardness are in `BLAST_RESISTANCE` at the end of BlockList. A fluid other
than fuel resists 100, so blasts in it break nothing. What else sets fuel off is
`World/FuelBlast.isHot` (fire and lava).

**Explosive blocks.** What a blast does to a block it reaches goes through
`Explosions.setPrimer` (`Behaviours/Tnt` sets it: TNT and Nukes are lit with a short fuse, lit ones
stay). A new explosive adds its unlit and lit ids to `LIT_OF` and `FUSE_OF` there and says what it
does when its fuse runs out in `detonate`; `Tnt.prime(world, x, y, z)` lights one from a server
script, and `Nuke.detonate(world, x, y, z)` (`World/Nuke`) sets off a crater anywhere.

## Development

The engine's core is pure Luau, so most of it runs and is tested outside Roblox with
[Lune](https://github.com/lune-org/lune):

```sh
lune run tests/run [Spec]             # unit tests and simulations (Spec: only specs with it in their name)
lune run tests/bench [seed]           # generation / meshing speed and part count estimate
lune run tests/preview [seed] [blocksPerPixel] [pixels]   # top-down map in tests/out/preview.ppm
lune run tests/structure decode <file | IVS1:... | -> [--lua t.luau]   # structure data, as ASCII
lune run tests/structure encode t.luau [--out file] [--module]        # an edited table to IVS1
lune run tests/build_structures [--check] [--print]   # rebuild (or check) the example outpost
lune run tests/build_textures [--check] [--list]     # the texture pack's Rojo files; blanks (--list)
```

`lune run tests/run` runs the whole suite: 1,399 tests, all passing (lava and oil have LavaOil,
LavaOilServer, LavaOilClient, LavaGeneration, OilWells, Refinery and Combustion; the texture pack
has TexturePack, TextureLooks and FarLooks; fire has Fire; Tough As Nails has ToughAsNails, Herbs
and SurvivalGear; mobs have Mobs and MobsClient; status effects and potions have Effects; knowledge,
Ages and skills have Progression; where those three meet, Crossover).

The test loader (`tests/lib/Loader`) passes `script`, `require` and `game` to each module as
arguments rather than through an environment table, so Luau's fast builtins stay on and Lune
timings match Roblox's (they were 1.3-2.6 × slow before). Modules run with native code by default;
`NOCODEGEN=1` measures the interpreter, which Roblox clients may be limited to (generation is
about 2.5-4 × slower there). The client's streaming and rendering run in Lune too:
`tests/spec/RenderPipeline` drives the real ChunkRenderer, PartPool and MeshOverlay against fake
instances (checking every frame for gaps, doubled lights and parts reused in the frame they were
released; textured terrain with MaterialService and the prototypes loaded from the generated
`src/textures` files), and `tests/spec/Streaming` the real ChunkStreamer and ClientWorld with a
fake worker pool, renderer and network (checking every frame that no ground goes uncovered, no
two levels overlap and no tunnel opens onto the void, through loading, edits, teleports, caves
and hidden terrain).

Formatting, linting and type checking:

```sh
stylua src tests
selene src
rojo sourcemap default.project.json -o sourcemap.json
luau-lsp analyze --platform=roblox --sourcemap=sourcemap.json \
    --definitions=@roblox=path/to/globalTypes.d.luau src
```

(`globalTypes.d.luau` comes from the [luau-lsp repository](https://github.com/JohnnyMorganz/luau-lsp/tree/main/scripts).)

## Roadmap

Natural next steps, roughly in order:

- **Persistence.** Edits, inventories and chest contents live in memory (`WorldServer.edits`,
  `Players/InventoryState`, `Players/Containers`), as do transmitter states, network fluids, tank
  contents and items in transit (`Transmitters/TransmitterWorld`), structure blocks' and jigsaws'
  settings and the session's saved structures (`Structures/StructureStore`, `StructureServer`);
  save them to DataStores (edits per region of 32 × 32 chunks, see "regions" in
  docs/ARCHITECTURE.md).
- **More of Mekanism.** Machines on the machine framework, side configuration for machines, energy
  items and the Energy Cubes' charge slots, gases (Pressurized Tubes), heat (Thermodynamic
  Conductors) and the Logistical Sorter.
- **More combat and mobs.** Players can't hurt each other yet (PvP), there are no bows, critical
  hits, sweeps or enchantments, mobs steer straight at their goal (no path finding: a wall with a
  door in it stops them) and don't push each other apart; skeletons' arrows are hitscan, not
  projectiles; more kinds (endermen, slimes, wolves, villagers), breeding and taming, mob light
  levels by biome, baby mobs, sheep shearing and dyes.
- **More of lava and oil.** Basalt, water aquifers,
  BuildCraft's oil springs and its refinery's heat and by-products, fire-resistant items, lava
  particles, and lava's lights in far chunks (they carry none: a far lava lake is unlit Neon).
- **Block orientation.** Blocks have no facing yet, so furnaces and chests show their fronts on
  every side and furnaces don't light up while burning.
- **More plants.** Saplings (dropped by leaves, growing into the existing tree builders), bone
  meal, sugar cane, seagrass and kelp, lily pads, vines, sweet berry bushes, and wheat, so grass
  can drop seeds. Plants are drawn only within `Lod.FoliageDistance`; Minecraft draws them to the
  render distance, which would need them merged into far fewer parts or meshes.
- **More of the texture pack.** The 61 blank textures and every texture's Average; see-through
  leaves and glass once Roblox turns MaterialVariant cut-outs (`AlphaMode`) on for game clients
  (off as of October 2026, so block textures are opaque, and sprites are Decals on thin parts);
  the Studio checks above (tiling, grass sides, far mesh UVs).
- **Edits in LOD chunks and on the map.** Far chunks and the map show generated terrain only; player
  builds appear once in full detail range.
- **Cave caps without cracks.** While the side between two sections switches between open and
  capped across two commit groups, thin see-through cracks can show at a tunnel's rim for a few
  frames. The mesher could stop a cap from turning the cave air beyond it into stone.
- **Measure on real clients.** The flicker, teleport and frame budget numbers come from Lune with
  fake instances; whether the engine draws new parts a frame late, what parenting and building
  really cost and how far it then draws need checking with the MicroProfiler in a published place.
- **Surface caves from afar.** From above ground an entrance ends in a stone cap where it meets a
  cave (Minecraft lets you look in; here the cave shows once your eyes are below the surface).
  Ravines don't show on the map (it paints the generator's column heights) or beyond LOD level 2
  (~400 blocks), and the far terrain culling's summaries leave pits and ravines out (they never
  lower a tile's ground).
- **The Underlands at a distance.** Caves only exist in full detail chunks, so a big cavern ends
  where they do (~128 blocks underground, `Lod.UndergroundSplitDistanceL1`). Carving the
  Underlands (mostly an analytic interval per column, cheap at any level) into far chunks and
  meshing those with caves visible while the camera is inside would show them whole.
- **More structures.** Villages and dungeons for the structure library; loot tables for generated
  chests (they hold their template's items); Minecraft's beard terrain adaptation instead of the
  foundations; structure sets and exclusion zones, so different structures keep apart; glow
  lichen on several faces of a block, as Minecraft's multiface block.
- **Parallel server generation.** The server generates chunks on its main thread (one per frame).
- **Mesher.** Try both X-first and Z-first growth and keep the smaller result; cap the size of
  water and glass boxes, so an edit in a lake replaces less of its surface (while old and new
  surfaces overlap for `Render.SwapFrames` frames, the water looks darker there).
- **Floating origin** for play far beyond ±16k studs, where float precision starts to show.
