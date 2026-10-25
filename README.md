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
  and nobody has a character. Operators (`/op`, `/deop`) may use the cheat commands, and Load
  World opens a saved world (below).
- **Characters, as Terraria's.** Before the world, each player picks one of their characters (up to
  10 per Roblox account, with a 3D preview of each) or makes one: an R15 avatar editor starts from
  your own Roblox avatar (skin colours for every part or one, hue and brightness, height, width,
  depth, head, body type and proportion within Roblox's avatar rules, each of your own accessories,
  clothes, body parts and animations on or off, the Classic and Natural presets), a name and a
  difficulty: **Classic** keeps everything when it dies, **Mediumcore** drops everything
  (Minecraft's rule), **Hardcore** drops everything and dies for good (a spectator for the rest of
  the visit, then shown dead in the list). A character carries its look, inventory and equipment,
  health, mana and Mana Crystals, status effects (a zombie bite's infection among them), its food
  bar, thirst and temperature, its days survived, zombies killed and blood moons lived through, and its Knowledge,
  Ages and skills from world to world and server to server; each world keeps only where it stood and
  its game mode. It spawns with its own look and its name on the nametag, and the list's preview
  shows it in the armor, vanity and accessories it wears. What it gains only travels from a fair
  visit: in a world with Allow Commands, a superflat or debug world, or once you went into creative,
  it leaves with the things (and progress) it had then, so nothing made in creative reaches another
  world (Terraria keeps Journey characters apart); you are told. Characters are saved in a DataStore
  with a lock each (one server at a time: one still saving it is waited for, up to 30 seconds),
  every minute, when you leave and at shutdown; a list that could not be read is never written over,
  and in Studio without API access characters last for the session (the list says so). A returning
  player's old progress becomes their first character (a Mediumcore "legacy" one), and the first of
  their characters to enter an old saved world takes in what they had there (only a character that
  is saved, in a world that saves progress; the world remembers it once the character was saved with
  it).
- **Saving and loading worlds.** Worlds are saved in a DataStore, as Minecraft saves its level:
  every block anyone changed (each chunk's edits, in regions of 32 × 32 chunks a key), chests,
  furnaces still cooking, machines with their energy, tanks and slots, Mekanism pipes (side modes,
  colours, the fluid in them), Fluid Tanks, items in transporters, structure blocks and jigsaws,
  generated chests already looted, dropped items, farm animals, block updates still due (water
  that was flowing flows on), the clock and doDaylightCycle, the weather (its clock,
  doWeatherCycle and a `/weather` override with its time left: storms go on where they were),
  the world's operators, and each
  player's place, facing, health, game mode, inventory and armor, food bar, thirst and temperature
  and status effects (with characters the character carries all of that but where it stood and its
  game mode, above; without them progress is kept per player for every world). Autosave every 5
  minutes writes only what changed (a house and a tunnel, a chest, a furnace, a battery, pipes,
  an item and a cow: about 1.3 KB of a key); `/save-all`, `/save-off` and `/save-on` as
  Minecraft's; and the world is saved when the server shuts down. While a save is in flight a
  little grass block bobs in the bottom right corner ("Saving..."), and operators get a toast:
  "World saved — 1.4 MB of 64 MB (largest region 0.3 / 4 MB)"; the chat warns them when the world
  nears its most (`Save.MaxWorldBytes`). The title screen's Load World lists your saved worlds
  (name, type, last played, size), loads one ("Loading world: 12 / 40"), renames or deletes it
  (after Minecraft's "Are you sure you want to delete this world?"). A world is its creator's:
  only they (and the game's own people: `Gameplay.Admins`, the owner, Studio, who also see the
  worlds made with the title screen off) can see, load, rename or delete it, so whoever is first
  into an empty server can't touch anyone else's; each list holds 200 worlds, and a new one past
  that is refused, never an old one dropped. One server opens a world at a time (a lock renewed
  while it loads and before every save, that goes stale 3 minutes after a crash), a world that
  can't be read whole is never started or written over, a player who leaves from the title
  screen keeps their saved place, and Studio without API access says so on the title screen and
  in the chat (worlds then last for the session; `/save-on` doesn't pretend otherwise). Saves
  keep names, not ids, so content can change between versions: each region, player record and
  character lists once the names of the blocks, items, fluids, mobs and effects it holds (and
  those inside machines and items: a miner's ore, a gun's rounds, a tank's fluid), so content
  added, reordered or renamed (with a `RENAMED` line) loads just as it was saved. A name this
  version doesn't know loads as air or is left out, never refusing the world; each record also
  keeps the place version that wrote it, which says what the name is: content removed since (in
  a record this version or an older one wrote) is simply gone, the world, player or character
  saves as usual and the server's output names what went ("removed content left out of world
  "Island": 12 OldBlock, 3 OldItem"); content of a newer version (Roblox runs old and new servers
  side by side during an update, or the version is unknown, as in Studio) leaves that world,
  player or character played but not saved, so nothing a newer version wrote is ever lost.
  Worlds, players and characters saved
  before names were kept are not read: such a world's terrain and chests start afresh from its
  seed (its name, seed, settings and clock stay), a player starts afresh, and a character keeps
  its name, look and progress but not its things; each says so.
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
  Lava open to the air pops, and the nearest bubbles in a long loop. A Lava Bucket picks it up and burns 20,000 ticks in a
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
  **Gunpowder** (soldier zombies drop it too, and police stations and bunkers keep some): black
  powder, two Saltpetre, a Sulfur and a coal or charcoal, makes four, and a coal or charcoal and a
  flint still make two; TNT is Minecraft's recipe (5 gunpowder in an X, 4 sand).
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
  mushroom cloud, hears the boom and feels a long shake. Eight TNT around a Block of Uranium.
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
- **Hunger (Minecraft's).** Minecraft 1.20.1's food bar: 20 points (the FOOD status icon at the
  bottom right, emptying from the top as they go: see The inventory and the HUD below), and
  saturation that goes first, drained by exhaustion (sprinting 0.1 a metre, swimming 0.01, a jump
  0.05, a sprint jump 0.2, a block broken 0.005, a hurt or an attack that lands 0.1). Food fills it
  with Minecraft's numbers (a steak 8 points and 12.8 saturation, raw beef 3, rotten flesh 4 with an
  80% chance of the Hunger effect, the ruins' tins and rations their own: see Mobs and the zombie
  apocalypse); you can eat whenever the bar isn't full (the Chocolate Bar any time, creative
  whenever). Health comes back from the bar alone (Roblox's own regeneration is off): with a full
  bar and saturation half a heart's worth every 0.5 s, burning the saturation; at 18 or more half a
  heart every 4 s for 6 exhaustion; at 0 you starve, half a heart every 4 s down to half a heart. At
  6 or less you can't sprint. Minecraft's **Hunger** effect (raw chicken 30%, rotten flesh 80%, 30
  s; `/effect give @s hunger`) drains the bar faster (0.005 exhaustion a tick a level): the FOOD
  icon shows two falling arrows and a Hunger badge (one falling arrow with no saturation left, where
  Minecraft's shanks jitter). With thirst on (below) health only comes back while thirst is 18 or
  more too (Tough As Nails: both bars high), and nothing heals while frozen or overheated through or
  once an infection reaches stage III. Death gives a full bar back (20 points, 5 saturation); worlds
  and characters keep it. Creative and spectator players are untouched. `Config.Hunger` turns it off
  (foods then heal health at once, as before, and thirst rules regeneration).
- **Thirst and body temperature (Tough As Nails).** The Tough As Nails mod's survival, after its
  1.20 version. Thirst is Minecraft's hunger with water: 20 points (the THIRST status icon) and
  hydration that goes first, drained by exhaustion (the same as hunger's but for attacks, plus
  sweating while hot). At 0 you lose half a heart every 6 s down to half a heart, and health only
  comes back with 18 or more (with hunger on as a condition of hunger's regeneration; with it off by
  thirst's own: half a heart every 4 s, for 6 exhaustion; Roblox's own regeneration is off). Drink
  from a water source with an empty hand (1 point), fill a Glass Bottle (three glass in a V make
  three) or a Canteen (an iron nugget over three iron ingots in a cup; three sips) at a water
  source, and hold use 1.6 s to drink: dirty water gives 4 points with a 50% chance of the Thirst
  effect (15 s of extra exhaustion: two falling arrows on THIRST and a Thirst badge), purified water
  (smelt the dirty bottle or canteen in a furnace) 6 and hydration with no risk. Body temperature is
  a number from -10 to 10 in five zones (icy -10..-8, cold, neutral -2..2, warm, hot 8..10) that
  steps towards what the place says, a step every 7 s (3.5 s back towards neutral): the biome
  (tundra -10, taiga -4, plains 0, jungle 7, desert 9), colder high up and outdoors at night, milder
  under a roof (towards neutral, day and night: a taiga house is -2), neutral deep underground;
  being wet cools 3 steps, sprinting warms 2, lava, fire, a campfire, a lit furnace or a working
  generator within 5 blocks warm 3 (5 within 2 blocks), ice and snow cool 3 (not that close to a
  fire; with the seasons, the ice winter freezes over ponds doesn't: the winter is cold enough), and
  armor insulates (leather and straw warm a step a piece towards neutral, leather stops freezing
  too; leaves cool a step). Icy for 20 s freezes you (half a heart every 5 s, and no health comes
  back meanwhile, whatever you drink), hot overheats you the same way and makes you sweat, so the
  harshest cold takes about 3 minutes to kill from neutral; a drink can give Internal Warmth or
  Chill, which hold the cold or the heat off. Joining gives 5 minutes of Climate Clemency (a respawn
  1): the temperature stays neutral, thirst drains at half the rate and doesn't hurt (hunger is
  untouched by it, as in Tough As Nails). Frost or heat closes in from the screen's edges, and the
  TEMPERATURE status icon fills with the temperature, coloured by zone (blues on the cold side,
  yellow then red on the hot), blinking while you freeze or overheat, with an arrow towards where it
  is going; the clemency's time left and the effects are status effect icons in the top right.
  Creative and spectator players are untouched. `Config.ToughAsNails` turns thirst or temperature
  off.
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
  in the hand reads the body temperature and where it is going (each in its zone's colour, an
  arrow between) in the item box over the quickbar, and makes the TEMPERATURE icon's arrows say
  how fast it changes (one to three).
- **Mobs.** Minecraft 1.20.1's farm animals as simple boxes moving about (a body in the kind's
  colour and a head on the side it faces), and the apocalypse's zombies (below): **cows** (0.9 ×
  1.4 blocks, 10 health), **sheep** (0.9 × 1.3, 8; white, now and then black, grey, brown or
  pink), **pigs** (0.9 × 0.9, 10) and **chickens** (0.4 × 0.7, 4; they flap down slowly and take
  no fall damage) wander, stand about and run off when hurt. No block can be placed inside a mob.
  Mobs walk at Minecraft's speeds (a zombie 2.3 blocks a second), jump up blocks, never walk off
  a drop of more than 3 blocks or into lava, fire, oil or fuel, swim up in water, take fall,
  fire, lava and explosion damage (TNT and fuel hurt and throw them), flash red when hurt, tip
  over when they die and drop Minecraft's loot a second later: **Leather** and **Raw Beef**,
  **White Wool** and **Raw Mutton**, **Raw Porkchop**, **Feathers** and **Raw Chicken**, and a
  zombie's **Rotten Flesh**, a **Bone** one time in four (now and then an iron ingot) and what
  its kind carries; meat drops cooked when the mob died burning. Raw meat cooks in a furnace;
  leather makes leather armor, four string a block of wool (which burns like Minecraft's).
  **Food:** hold right click 1.6 s with meat to eat it when your food bar isn't full (Minecraft's
  nutrition and saturation: steak and cooked porkchop 8 points and 12.8 saturation, cooked mutton
  6 and 9.6, cooked chicken 6 and 7.2, raw beef and porkchop 3, raw mutton and chicken 2, rotten
  flesh 4 and 0.8; raw chicken (30%) and rotten flesh (80%) may give Minecraft's Hunger for 30 s).
  With hunger off it heals instead when you are hurt (steak and cooked porkchop 2 hearts, cooked
  mutton and chicken 1.5, raw meat less) and the risk is Tough As Nails' Thirst effect. **Fighting:** a left click on a mob in reach (3 blocks, 6 in
  creative) hits it with Minecraft's weapon damage (the hand 1, swords 4-7, axes 7-9...; Strength
  adds 3 a level and Weakness takes 4) and 1.9's attack recovery (a sword hits at full strength
  every 0.6 s), knocks it back and wears the weapon (the melee weapons' light and heavy attacks,
  guard and finishers, and firearms: see Weapons); WAILA names the mob and its health. A kill
  is knowledge: the first of each kind 10 points, then 2 an animal and 4-10 a zombie (a crawler
  4, a brute 10). Creatures spawn on grass in the light 24-44 blocks from players (10 at most
  around each), zombies as below; monsters vanish far from everyone (Minecraft's 128 and 32
  block rules, those frozen out of reach too). Mobs only move within the simulated chunks around
  players and freeze beyond (a frozen mob that dies still goes). `/summon <kind> [x y z]` and
  `/kill @e[type=<kind>]` for operators (kinds in snake case: `cow`, `zombie_brute`).
  `Config.Mobs` sets the caps and turns spawning or mobs off.
- **Zombies.** The world is overrun. Ten kinds of zombie share one set of rules: the ordinary
  **Zombie** (0.6 × 1.95 blocks, 20 health, armor 2, hits 3, chases at 2.3 blocks a second), the
  **Runner** (12 health, hits 2, chases at 5 blocks a second: only a sprinting player gets away),
  the **Brute** (60 health, armor 4, hits 7, slow, breaks blocks three times as fast and shrugs
  off knockback), the legless **Crawler** (0.75 × 0.6: it fits under anything a block high and
  through an open door), the **Screamer** (it shrieks when it spots a player, and every zombie
  within 48 blocks comes to look), and the **Soldier** (armor 10, hits 4, gunpowder),
  **Police**, **Firefighter** (fire can't hurt it), **Construction** (it breaks blocks twice as
  fast; nails and scrap) and **Doctor** zombies (bandages, pills, antibiotics). None of them
  burns in the sun.
  - **Hunting:** they notice survival and adventure players they can see within 24 blocks
    (runners and screamers 32, crawlers 16), chase them and hit within Minecraft's reach every
    second with a knockback; out of sight for 3 seconds they lose you.
  - **Noise** draws them: sprinting, breaking and placing blocks, glass, doors and the bunker
    hatch, chests, fighting, getting hurt and explosions each make a noise with a radius
    (`Config.Apocalypse.Noise`: a sprint 8 blocks, a block broken 10, glass 16, a blast 24 + 12 a
    power), a quarter louder at night and muffled by rain. Every zombie without a target in
    reach walks over to look (spread out round the spot) and looks for players at once.
  - **Walls don't stop them.** A zombie pushing against a wall towards a player it is after
    (within 8 blocks and level with it: from a block below its feet to two above, judged
    standing on the ground, or afloat, so a player on a cliff three blocks up is safe from
    digging; 16 for a blood moon's hunters) stands and hits the block, swimming too: a moat or a
    pool at a wall's foot only slows them (afloat, a zombie has three blocks to break where it
    has two on the ground). A closed door gives way in 12 seconds (a
    brute 4, two zombies together about 6), glass in 3, leaves and wool in 6, dirt and fences in
    15, planks and logs in 30, a **Barricade** in 45, stone and bricks in 2 minutes, a
    **Reinforced Barricade** in 150 seconds, concrete in 5 minutes. The damage is shared by
    everyone hitting the block and fades after 5 idle seconds, and it belongs to that block:
    break a hammered plank and put a new one, or a barricade, and the zombies start over; iron,
    ores, chests and machines and the bunker hatch never break. Both halves of a door go and
    nothing drops, with a crash every zombie within 10 blocks hears. They never dig down or up
    towards a player.
  - **Day and night:** at night 20 zombies at most round each player spawn in the dark as
    monsters do; by day 7, only on floors under the open sky and never where a torch's light
    reaches (13 blocks); 1.75 times that where the player stands in a city, where police and
    firefighters turn up too, in the streets and the buildings' ground floors but never on an
    upper floor or a roof they could not come down from. Packs of 1-5 (by kind) spawn 24-44
    blocks out. At dawn, and every 30 s by day, the zombies over a player's day cap with nothing
    to chase walk off, the furthest first, and go once 24 blocks away and out of sight, so a
    crowd round a shelter thins out.
  - **Blood moons** (every third night from the third: see Survival): waves of 8 zombies a
    player (10, 12... at later moons) every 30 seconds, 28-44 blocks out on the ground under the
    open sky (never on a roof they could not climb down from), up to 28 round each player (4 more
    each moon, 60 at most); runners and brutes come more often each moon, and every zombie within
    44 blocks hunts the nearest player, seen or not. Natural spawning waits meanwhile. At the
    moon's end the hunts stop and the surplus leaves.
  - **Crowds:** zombies keep a little room between each other, so a crowd spreads round its
    target instead of standing in one spot, and squeeze through a doorway or an open door one at
    a time; a shut bunker hatch is ground they walk over.
  - **They look the part.** Zombies are drawn as Roblox **R15** bodies (head, upper and lower
    torso, upper and lower arms, hands, upper and lower legs, feet), posed in code: arms reaching
    forward (higher when they have a target), a shambling walk whose stride follows how fast
    they really move, heads lolling to one side, a swing of both arms when they hit, both fists
    hammering while they break a block, the head thrown back and arms flung wide when a screamer
    shrieks. Each kind moves its own way: runners sprint, leaning in with pumping arms; brutes
    are drawn 2.3 blocks tall and half again as broad, splay-legged and hunched; crawlers drag
    themselves along on their arms, flat on the ground; screamers lurch and twitch.
  - **Many variants:** every zombie wears one of its kind's outfits (32 in all: civilians in
    tees, hoodies, flannel, office shirts, overalls and beanies; joggers and tracksuits; prison
    orange, mechanics and the shirtless; hospital gowns; woodland, desert and urban soldiers with
    vests and helmets; police in patrol and summer uniforms with caps; firefighters in turnout
    gear with reflective bands and helmets; construction workers in hi-vis vests and hard hats;
    doctors in white coats and scrubs) in one of six dead skin tones (192 looks), its clothes
    torn and bloodied in places of its own, so no two look alike; every player sees each zombie
    the same. Near zombies groan now and then (only the nearest eight within earshot, one at a
    time), a brute lower, a screamer higher. Within 16 blocks up to 16 zombies are drawn in full,
    out to 40 blocks a simpler body (8 boxes), further away two boxes, so a horde round the
    player costs a phone little (F3's `mobs` line counts them).
  - **Commands and switches:** `/summon zombie_brute` and `/kill @e[type=zombie_runner]` work as
    for any mob, and kills, loot and knowledge too. `Config.Apocalypse.Enabled` false turns the
    director, noise, breaking, blood moons and the survival below off (zombies then just hunt what
    they see).
- **Surviving the apocalypse.** A zombie's hit may wound or infect.
  - **Infection:** a bite's infection (the Infection effect, its stage shown as its level) runs four
    stages over two in-game days (40 real minutes): nothing at first, then Weakness (and thirst
    draining faster), then Slowness, spells of Nausea and no natural health coming back, then
    Slowness II and a half heart every 5 s that never takes the last one; untreated it kills exactly
    48000 ticks after the bite, never before, and an infected player who dies **rises as a zombie**
    where they fell, dressed like them (the chat says "<name> succumbed to the infection", then
    "<name> rose again"). At most one roll every 5 s a player (a horde's hits don't stack), and
    armor shields up to 75% of the chance (3.75% a point). A bite while infected takes it 2 minutes
    on. **Antibiotics** (pharmacies, medicine cabinets, bunkers, doctor zombies) cure it at any
    stage, with a minute of Weakness after a late one; a **Herbal Poultice** (Mint Leaves, a Ginger
    Root and a Rag) takes it back a stage but never cures it. Creative and spectator players are
    never wounded or infected, and an infection they carry stands still.
  - **Bleeding** (a zombie's wound: 20 s, a half heart every 4 s, every 2 s when hit again)
    stops at the last half heart; a **Bandage** (two Rags make two; a Rag is torn from wool) or
    a **Medkit** stops it.
  - **Medicine and the ruins' food** are used like food, by holding the use button (each its own
    time and sound): the Bandage (2 s), Medkit (4 s, with Regeneration), Painkillers
    (Regeneration), Antibiotics, the Herbal Poultice (medicine heals health, hunger or not), and
    the food: Canned Beans (6 food, 7.2 saturation), Canned Peaches (4, 2.4), Crackers (2, 0.4;
    you will want water: a 30% chance of the Thirst effect), the Chocolate Bar (3, 1.8; Speed,
    eaten any time) and the Military Ration (8, 12.8; with hunger off they heal 3, 2, 1, 1.5 and
    4 hearts); Bottled
    Water is purified water whose bottle is kept, Soda a little water and Speed. The ruins and
    bunkers hold most of it (`/locate poi medicine_cabinet`); rags, bandages, medkits and
    poultices are crafted.
  - **Building against them:** Nails (two Iron Nuggets make four), **Barricades** (three planks
    over Nails make four; a zombie takes half again as long as on a plank) and **Reinforced
    Barricades** (a Barricade, two Scrap Metal and Nails: 150 seconds), and the scavenger's
    weapons: the **Baseball Bat**, the **Spiked Bat**, the **Machete**, the **Crowbar** and the
    **Fire Axe** (found, never crafted: fire stations, bunker armories, firefighters; heavy
    attacks and a guard: see Weapons).
  - **Blood moons:** every third night (nights 3, 6, 9...) the sky turns red, the moon grows and
    the hordes come (see Zombies); the HUD warns the day before ("Blood Moon tomorrow", "Blood
    Moon tonight") and toasts its rise ("The Blood Moon rises", with a deep boom) and, for a
    character that lived through it from its rise, its set ("You survived the Blood Moon").
    `/time set` moves the blood moons with the clock.
  - **The day counter** under the minimap's coordinates (under the Map button on touch screens,
    in the corner without either) reads "Day 4 · Survived 2 days": the world's day and the days
    this character has lived since it last died; where the corner is too narrow for the warning
    on the same line (an iPad, a 1024 × 768 window) the warning goes on a line of its own under
    it. The Day Counter setting (HUD) hides it. Each character also counts the zombies it killed
    and the blood moons it survived, saved with it (and with characters off, in each world's
    player record), and keeps its infection from world to world.
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
  doubling a level) and Glowing (an outline everyone sees through walls); the apocalypse adds
  Bleeding and the Infection (see Surviving the apocalypse), uranium Radiation Sickness (see
  Radiation). They stack and refresh
  as Minecraft's (a stronger effect wins, a weaker longer one waits underneath and comes back), run
  on the server, and the client's movement and mining prediction use the same numbers as the
  server's checks. Creative and spectator players get them too, but nothing hurts them. Death
  clears them; they are not saved. Icons on dark squares in the top right, under the minimap and
  the toasts, or beside them on small phones (beneficial in the top row, the rest below, longest
  first, blinking out over their last 10 s; hover one, or tap it on a touch screen, for its name,
  level and time), and Minecraft's list of names and times beside an open inventory; F3 lists
  them too. Bleeding, the Infection, Poison, Wither, Hunger, Thirst and Nausea show as badges over
  the status icons instead (see The inventory and the HUD). Minecraft's Hunger is one of them
  (the food bar's, from raw chicken and rotten flesh). Tough As Nails' Thirst, Internal Warmth,
  Internal Chill and Climate Clemency are listed with them (the status icons' badges show the last
  three only with `Config.Effects.Hud` off; the Thirst effect and the clemency wait in creative
  and spectator, their times standing still on the icons). `/effect give
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
- **Radiation.** Uranium is radioactive, Mekanism's way simplified: Uranium Ore, the Block of Raw
  Uranium and the Block of Uranium near you, and the uranium you carry (Raw Uranium, ingots, nuggets
  and those blocks, by the count in your inventory, armor slots, hand and crafting grid; not what is
  in a chest) give an exposure rate in Sv/h. It falls off with the square of the distance (out to 8
  blocks), and blocks between shield it: half through each block of rock, earth or wood, nearly
  nothing through a Block of Lead; glass and water let it through. The refined metal is far hotter
  than the ore: a lump of Raw Uranium is 0.3 Sv/h, an ingot 12, a Block of Uranium 108. The rate
  builds a dose (Sv) that halves every 10 minutes once you are away, and the dose brings **Radiation
  Sickness** (Mekanism's bands): I from 0.1 Sv (a half heart every 15 s, through armor), II from 1
  Sv (every 7.5 s, with Hunger), III from 10 Sv (every 3.75 s, with Hunger II and Nausea), and it
  kills. It lasts up to 30 s after your dose falls below its band. Mining a uranium vein bare
  skinned for a few minutes makes you mildly sick, a stack of Raw Uranium carried for several
  minutes sick, standing next to a Block of Uranium is dangerous, and a vein a few blocks into the
  rock is safe.
  The **Hazmat suit** (lead and wool) keeps it out: the mask a quarter, the gown two fifths, the
  pants a fifth, the boots the rest, the whole suit all of it. While you are exposed you hear a
  Geiger counter click, faster the stronger it is (up to 16 clicks a second), which also finds a vein
  hidden in the rock nearby. Creative and spectator players are never exposed. Death clears the
  dose; a saved world and a character keep it. F3 shows the rate and the dose (`Config.Radiation`).
- **Potions.** Brewed in a crafting grid (the game has no brewing stand): a Purified Water Bottle
  with an ingredient makes a potion, the potion with Glow Dust (the game's glowstone) its level II
  and with a coal or charcoal its long variant, Minecraft's durations: Swiftness (Mint Leaves),
  Leaping (Cornflower), Strength (Gunpowder), Healing (Gold Nugget), Harming (Red Mushroom), Poison
  (Lily of the Valley), Regeneration (Oxeye Daisy), Fire Resistance (Ginger Root), Night Vision
  (Glow Dust), Weakness (any tulip), and this game's Haste (Gold Ingot) and Resistance (Iron
  Ingot): 29 potions. Bottles of the effect's colour, stacking to 1; hold use 1.6 s to drink one
  (whatever your thirst, Tough As Nails on or off) and the Glass Bottle comes back. The tooltip
  lists the effect, its level and time, blue or red. Brewing is the Iron Age's, levels II and the
  long potions the Industrial Age's.
- **Mana and magic (Terraria).** Mana works as in Terraria 1.4.4:
  - **Capacity:** 20 to start. Each **Mana Crystal** (five Fallen Stars in the grid) adds 20 for
    good, up to nine (200). A Band of Starpower adds 20 more, and the cap is 400.
  - **Regeneration:** Terraria's rule. Spending starts a delay of 0.5 s at full mana to 3.3 s
    empty, then mana comes back faster when it's nearly full and much faster standing still
    (20 max: about 7.5 a second standing, 1.7 walking; standing still means a fifth of a second
    without moving or casting).
  - **HUD:** the MANA status icon empties as mana is spent (yellow under a quarter, red under a
    tenth). It is lit while you hold a magic weapon, while mana isn't full and for 3 s after it
    changes, dimmed otherwise, and blinks after a cast the server refused.
  - **Potions:** the **Lesser Mana Potion** (50) and **Mana Potion** (100) are drunk like
    potions. Each adds 5 s of Mana Sickness, up to 10 s, which cuts magic damage by 5% for each
    second left.
  - **Weapons:** hold use to cast every use time along your aim. The **Wand of Sparking** (2 mana,
    an arcing spark that sets mobs burning half the time) is found in mineshaft chests. The
    **Emerald Staff** (6 mana, a straight bolt reaching 30 blocks) is crafted, Iron Age. The
    **Water Bolt** (10 mana, bounces off five walls and goes through a mob) is a rare mineshaft
    find.
  - **Projectiles:** the server flies them and decides every hit (each shot hits a mob once, and
    every shot lands: magic doesn't wait for Minecraft's hurt cooldown). Your own shot flies at
    once, and other clients fly the same path from three small messages; a cast the server
    refuses (too soon, too many flying, no mana) is taken back on your screen.
  - **Fallen Stars:** they fall at night near every player, about five a night, glowing as they
    come down. The ones left on the ground vanish at dawn.
  - **Tooltips:** a magic weapon says its damage, mana a cast and fire chance; a mana potion the
    mana it restores; a Mana Crystal its +20; F3 shows your mana and the projectiles flying.
  - **Saved:** mana and the crystals used go with the character (with characters off, with the
    world's player record).
  - **Off:** `Config.Mana` turns all of it off.
- **The inventory and the HUD, in a survival game's look.** The inventory, the creative picker,
  JEI, the quickbar, the status icons, item tooltips and the carried stack are drawn after DayZ's
  inventory and HUD (its shapes, colours and layout only, none of its art): flat dark panels with
  hairlines, grey and black headers with faint gradients, Roboto text, our own anti-aliased
  silhouettes, item pictures a little darker than in the world. Other screens (the Options menu,
  the skill tree, the title screen, chat, maps, WAILA) keep Minecraft's look.
  - **The inventory** (`E`) has three columns over a band. On the left, **VICINITY**: a GROUND strip
    with the dropped items within 4 blocks (up to 9; `Config.Ui.GroundRadius`; walk over one to pick
    it up), then **CRAFTING** (the 2 × 2 grid) or the open block's section (a chest with its count,
    "CHEST (12/27)", a crafting table, a furnace or a machine with its gauges), then **ITEMS**, the
    JEI list. In the middle, the player (turning towards the pointer) over **HANDS**: the held item
    large, its name, a condition dot and word and one detail line (durability, sips, a stack's
    count, energy). On the right, **EQUIPMENT** (its gear opens the Options menu): the armor over
    the seven accessory slots with their eyes and padlocks, then **BACKPACK (n/27)** and **VANITY**.
    The band holds the hotbar slots as the quickbar, every running effect as a row of icons beside
    it (harmful ones first, closer together when there are many) and, in survival and adventure, the
    status icons at its right. Where three columns would have to shrink below GUI scale 2 (1.5 on touch; the
    screen's own scale when that is smaller) only the side columns show. Behind it the world blurs
    on a PC (`Config.Ui.InventoryBlur`) under a vignette.
  - **Cells:** one dark slab per grid with faint lines between the cells; empty cells are clear,
    full ones faintly lit, with a black count box in the corner and, on a damaged item, a thin bar
    in its condition's colour; empty armor and accessory slots show a faint silhouette of what
    goes there.
  - **Collapsing sections:** click the bar of CRAFTING, the block's section, ITEMS, BACKPACK or
    VANITY (the minus or plus at its right end) to fold it to its bar and back. A folded section's
    slots take no clicks, its title still counts what it holds, and its room goes to ITEMS and the
    player. VANITY starts folded on touch screens; the rest is remembered for the session.
  - **The recipe view** (`R` or `U` over an item) shows over the middle and right columns; VICINITY
    stays beside it, still live (a furnace keeps cooking on screen, the GROUND strip keeps
    updating) but taking no clicks or gamepad selection until the view closes (its bars and
    buttons show no tooltip meanwhile). The running effects stay in sight in a row under
    VICINITY while the view hides the quickbar.
  - **Throwing:** drag a stack onto the GROUND strip (outlined in white while you carry one, "Drop
    here" while it is empty) or let go of it outside the screen to throw it; anywhere else in the
    screen (headers, gaps, the player, the band) nothing happens. On touch a tap on the strip with
    nothing carried does not close the inventory. `Q` still drops the hovered stack.
  - **Dragging:** only outlines change colour, the carried stack's and the slot's under it: green
    where it fits, red where it can't go, light blue to swap, orange to stack.
  - **The quickbar** at the bottom centre (lifted 5 % of the screen's height on a PC, none on
    touch): nine flat grey cells, the selected one olive under a white outline, each key in a black
    box at the cell's top right over an item (a faint box in the middle of an empty cell; none on
    touch or while too small to read), and the held item's name in a grey box above for 2 s after
    it changes (or for as long as a Thermometer is held, with its reading). It never fades unless
    `Config.Ui.QuickbarFadeAfter` says so.
  - **The status icons** at the bottom right, on the quickbar's line where they fit: THIRST, FOOD,
    TEMPERATURE, a divider, MANA, ARMOR and HEALTH (each while its feature is on), white
    silhouettes that empty from the top as the stat drops. They turn yellow, then red, then blink
    red and white, the whole silhouette (its emptied part fainter), so an empty stomach still
    blinks red: health at 6, 3 and 1.5 hearts, food and thirst at 6, 3 and 0 points, mana under
    a quarter and a tenth (no blink), the temperature by zone (blues on the cold side, blinking
    while freezing or overheating); armor stays white and fills with its points. Full mana with no
    magic weapon held shows faint but whole, never like an empty star. Up to three
    arrows above an icon mean its stat is rising, below it falling: health falls one for each of
    bleeding, poison, wither, starving and dehydration (else one for 2 s after a hit) and rises
    while it regenerates; food and thirst fall two under the Hunger or Thirst effect and one with
    no saturation or hydration left; the temperature points towards where it is going (a held
    Thermometer says how fast); mana moves for a second after it changes. Conditions (Bleeding,
    the Infection, Poison, Wither, Hunger, Thirst, Nausea) are small badges in rows of five above
    the icons, with their level from II (the infection its stage); the knowledge level and its bar
    sit under them. No numbers by default (`Config.Ui.StatusValues`). With the inventory open the
    six icons alone sit in its band.
- **Weapons, in the manner of DayZ.** Firearms with magazines, chambers, attachments, condition
  and jams, raised and aimed over the shoulder or down the sights, every shot traced and checked
  by the server; and a melee rework with light and heavy attacks, a guard and knife finishers.
  Nothing makes a gun, a magazine or a round (the ruins and bunkers hide them), but the crossbow's
  bolts and the improvised suppressor are crafted.
  - **Firearms:** the **9mm Pistol** (a 15-round magazine), the **Revolver** (.357, five in its
    cylinder, never jams), the **SMG** (9mm, a 30-round magazine, single shots or automatic at 700
    rounds a minute), the **Pump Shotgun** (12 gauge, five in the tube; it racks after every
    shot), the **Double-Barrel Shotgun** (12 gauge, two shots, never jams), the **Bolt-Action
    Rifle** (7.62, four in it, a bolt worked after every shot), the **Semi-Auto Rifle** (7.62, ten
    in it), the **Assault Rifle** (5.56, a 30-round magazine, single or automatic at 700), the
    **Hunting Rifle** (.308, a 5-round magazine and a built-in 4 x scope), the **Small-Bore
    Rifle** (.22, a 10-round magazine, quiet) and the **Crossbow** (one bolt at a time, almost
    silent, never jams; a bolt that hit a block is found again 70 % of the time, one that hit a
    mob half as often). Every gun also holds a round in its chamber (a revolver 5 + 1).
  - **Ammunition, magazines and attachments:** 9mm, .357, 12 Gauge Buckshot (eight pellets) and
    Slugs, .22, 5.56, 7.62 and .308 rounds, Crossbow Bolts; the 9mm Pistol Magazine, the SMG
    Magazine, the Assault Rifle Magazine (30), the Hunting Rifle Magazine (5) and the .22 Magazine
    (10), each with its own condition; the **Red Dot Sight** (a red dot, 1.4 x), the **Rifle
    Scope** (4 x: a scope's black circle and cross instead of the gun), the **Suppressor** (a
    quarter of the noise, no muzzle flash, tracers without their glow), the **Improvised
    Suppressor** (a Glass Bottle and Duct Tape: less quiet, Ruined and muffling nothing after 32
    shots) and the **Weapon Flashlight** (a beam 24 blocks long from under the barrel, on and off
    with `L`). Tooltips say what fits what; HANDS and the quickbar's count boxes show a gun's
    rounds.
  - **Loading by combining:** as in DayZ, in the inventory. Drop rounds on a magazine (left
    click: all that fit, right click: one) or on a gun with an internal magazine (the chamber
    first), one on a magazine gun with an empty chamber to chamber it by hand; drop a magazine on
    its gun (the one in it comes back onto the cursor) and an attachment on a gun it fits. Loading
    the gun in your hand this way lowers it and takes as long as `R` would (a magazine's time, a
    round chambered, a round at a time into a tube) before it fires. Where it would combine the
    outline is orange, where it can't (another calibre, full) red. A right click with nothing
    carried takes one thing out of a gun: the magazine, else its rounds and the chambered one,
    else the muzzle device, the optic, the light; out of a magazine its rounds.
    HANDS shows the held gun's parts as chips beside it (MAG and OPTIC left, MUZZLE and LIGHT
    right); a click on one takes it off.
  - **Raising and firing:** hold right click with a gun to raise it (a block with a menu still
    opens unless you sneak): over the right shoulder in third person, with a small dot at the
    centre, or down the sights in first person; `V` goes down the sights from third person and
    back. A raised gun walks at 65 % (50 % in the sights), never sprints, and fires after 0.3 s up:
    left click shoots (a semi-automatic once a click, an automatic while held), an empty gun clicks
    dry. Shots leave from the eyes towards what the crosshair covers, with the gun's spread (wider
    over the shoulder, moving, narrower crouching), recoil that kicks the view up and partly comes
    back (automatic fire climbs), a sway that grows when moving or hurt, and bullet drop beyond
    each gun's zero. Hold the sprint key in the sights to hold your breath: 3 s of a steady aim,
    then 3 s out of breath. A lowered gun bashes a mob in reach (3 or 4 damage) and never mines.
  - **Reloading and the fire mode:** `R` puts in the fullest magazine you carry (if it holds more
    than the one in) and chambers a round (the assault rifle 2.5 s and 0.6 s), or only chambers when
    there is no better magazine; a gun with an internal magazine loads a round at a time until it
    is full, the rounds run out or you press the trigger. `F` switches single shots and automatic.
    While a reload, a round, a jam or the fire mode is seen to, the gun doesn't fire (RELOADING,
    LOADING or CLEARING over the held item's box, the progress in a thin bar under it; else a
    two-mode gun's SEMI or AUTO, and JAMMED while it is jammed).
  - **Condition and jams:** every shot wears the gun, its magazine and its muzzle device. A gun
    goes Pristine, Worn, Damaged, Badly damaged and Ruined (a fifth of its durability left: it
    never fires again, and nothing repairs it yet); the worse its condition and its magazine's,
    the more often a round jams (0.2 % a shot when Worn, 1 % Damaged, 4 % Badly damaged, each
    part's added). A jammed gun clicks; `R` clears it in 2 s and the stuck round is lost. The
    revolver, the double-barrel and the crossbow never jam.
  - **Hits:** a head shot does three times the damage to a zombie (1.8 times through a helmet,
    hard hat or fire helmet) and through no armour, twice to any other mob or player; one head
    shot kills an ordinary zombie with any gun but the SMG and the .22 (two), three 9mm rounds in
    its body. A head is hit where it is drawn (a brute's up at its 2.3 blocks, a crawler's and an
    animal's in front of them); a shot into the back hits the back. Damage falls off beyond each
    round's range; buckshot's pellets add up; glass shatters and the bullet goes on with 70 %
    (only for players who may build), leaves let it by, and every other block stops it.
  - **Noise:** every shot is a noise the infected hear and come to: the pistol 48 blocks, the
    shotguns 72, the assault rifle 80, the hunting and bolt-action rifles 96 (a quarter more at
    night, less in the rain), the .22 24 and the crossbow 6; a suppressor cuts it to a quarter (an
    improvised one to under half), and a shot landing 8 blocks or more away is heard there too.
    Others hear your shots within 256 blocks (far off as a low rumble), your reloads near you.
  - **Players:** with `Config.Weapons.PvP` on (the default) bullets hurt players: twice as much
    in the head (through the helmet's armour alone), all the armour worn on the body, and half
    the hits open Bleeding. Off, bullets fly through them. Spectators can't fire; creative fires
    without rounds or wear and never jams.
  - **Melee weapons:** the **Kitchen Knife**, the **Hunting Knife**, the **Machete**, the
    **Baseball Bat** and **Spiked Bat**, the **Crowbar**, the **Fire Axe**, the **Pipe Wrench**
    and the **Sledgehammer**. A click lands a light attack when you let go (on the mob in reach
    then); held 0.45 s and let go, a heavy attack: about twice the damage (a bat 10 for 5), twice
    the knockback and three times the food. Hold right click to guard: a zombie's hit from the
    front is cut by the weapon's share (a knife 30 %, the bats, crowbar, axe and wrench 60 %, the
    sledgehammer 70 %), and you walk at half speed without sprinting. A knife from behind kills
    a zombie that hasn't noticed anyone outright (30 health at most: never a brute). Swords, tools
    and the hand hit on the click as before. On touch a tap is a light attack and a finger held
    still on the mob for about 0.75 s a heavy one; there is no guard.
  - **Where they are found:** police stations (pistols, revolvers, pump shotguns, 9mm, .357 and
    12 gauge, pistol magazines, the weapon flashlight), bunker armories (assault rifles, SMGs, the
    rifles, the hunting rifle, their magazines and rounds, suppressors, sights and scopes), now and
    then a house (a double-barrel, a .22 rifle, a revolver or a crossbow, rounds, bolts, knives),
    bunker storerooms and cars (rounds), hardware stores, fire stations and groceries (the
    wrench, the sledgehammer, knives). Guns come worn and empty. Police zombies carry 9mm rounds
    and now and then a pistol magazine, soldiers 5.56 rounds and a rifle magazine, construction
    workers rarely a pipe wrench. Crossbow Bolts are crafted (an Iron Nugget over a Stick over a
    Feather make four, in the Iron Age), the Improvised Suppressor from a Glass Bottle and Duct
    Tape; the Ammo Press (below) presses 9mm, 5.56 and .308 rounds from brass, lead and gunpowder.
  - **Off:** `Config.Weapons.Enabled = false` keeps guns as clubs that never fire;
    `Config.Weapons.Melee.Enabled = false` puts melee back as it was.
- **Four game modes.** Minecraft's survival, creative, adventure and spectator, switched with
  `/gamemode <mode>` (`/gm s`, `c`, `a`, `sp`, or `0`–`3`) in the chat, `F3` + `N` (spectator and
  back) or the `F3` + `F4` game mode switcher.
  - **Survival:** blocks take Minecraft's time to mine, by hand or with tools, cracking as they
    go, and drop as items that bob on the ground until someone walks over them. Stone and ores need
    a pickaxe of the right tier to drop anything (iron, osmium, copper, lead and zinc ore a stone
    pickaxe, diamonds and uranium an iron one),
    and tools wear out. Placing uses items up. Players have a Minecraft inventory: 36 slots, armor,
    a 2 × 2 crafting grid and Terraria's equipment (below), laid out in a survival game's columns
    (see The inventory and the HUD); chests, crafting tables and furnaces open in its VICINITY
    column. Clicks work as in Minecraft: shift-click, number keys, dragging to spread, double
    click. Items drop on death.
  - **Creative:** an "Item selection" picker with a search bar (in the inventory's dark look),
    instant breaking, flying (double tap jump), and nothing hurts.
  - **Adventure:** survival without building: blocks can't be broken or placed and items can't be
    used on them (buckets, the Configurator), and no block is outlined; chests, furnaces, crafting
    tables and machines still open. Health, falls, pickups, the inventory and death drops are
    survival's.
  - **Spectator:** always flies, through blocks and water, from the bottom of the world to 64
    blocks above its top (the mouse wheel sets the flying speed); nothing hurts. Players who don't
    spectate neither see nor hear a spectator (other spectators see a translucent floating head).
    Spectators pick up and change nothing, look into chests, furnaces and machines read only, and
    keep their inventory if they die. Instead of the quickbar, a number key or the middle click
    opens Minecraft's spectator menu: `1` "Teleport to Player" lists the other players' heads (7
    on the first page, then 6 a page), a player's number pressed twice teleports there, `9`
    closes it. A left click on a player looks through their eyes until you sneak. With the
    server's own positions (`Players.ServerPositions`) both reach only the players you see
    (within `Interest.PlayerDistance`); teleporting to anyone else takes the operators'
    permission, as `/tp` to a player does (in Minecraft only operators become spectators).
    Switching from spectator to survival or adventure inside a block suffocates you (half a heart
    every half second) until you get out, as in Minecraft.
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
- **Just Enough Items.** In the inventory's ITEMS section (with a chest, crafting table, furnace or
  machine open too) and beside the creative picker, a JEI-style list of every item, a page at a
  time, with a search box. Click an item, or press `R` over any item (in the list, a slot, the
  quickbar or a recipe), to
  see how it is made; right click or `U` shows what it is used for: crafting recipes on a 3 × 3
  grid (an ingredient any planks will do for cycles through them), smelting with its 10 seconds,
  and fuels with how many items they smelt. On a crafting table, a furnace, a Heat Generator or an
  Electric Furnace, `U` also lists every recipe made in it (JEI's catalysts). Items inside a recipe
  open their own recipes (shown over the inventory's middle and right columns), `Backspace` goes
  back and `E` or `Escape` returns to the inventory. The
  `+` beside a crafting recipe moves its ingredients from the inventory into the open crafting grid
  (`Shift`: as many sets as you have); when it is greyed out, hovering it says why and shows what is
  missing. In creative, `Shift` + click gives a full stack. Three more categories show fluids as
  fluid stacks (a slot in the fluid's colour, "Oil" and "1,000 mB" on hover), standing for their
  bucket and block in lookups: refining (a bucket of oil into fuel in 5 s for 20 kJ), the Heat
  Generator's lava ("Makes 4 MJ", "200 J/t for 1000 s") and the Combustion Generator's fuel ("Makes
  10 MJ", "2.5 kJ/t for 200 s"); `U` on an Oil Refinery or a Combustion Generator lists theirs.
  And two machine categories: the Metal Miner's Duplicating and the Ammo Press's Pressing.
- **Item tooltips.** Hovering any item (a slot, the creative picker, JEI; a quarter of a second
  with a mouse) shows a dark tooltip with everything the game knows about it: a header with the
  name, the condition of a durable item (a coloured dot and Pristine, Worn, Damaged, Badly damaged
  or Ruined) and the count, the item's picture on the left, a cyan pill naming the water or a
  bucket's fluid, what the stack holds (a tank's fluid, a battery's charge), a line of lore in
  grey saying what the item is for ("Allows the holder to double jump", "Purify it in a furnace,
  on a campfire or with mint"), then
  - **tools:** harvest level and the best blocks a pickaxe harvests ("Harvest level: Iron",
    "Harvests up to: Gold Ore, Diamond Ore, Emerald Ore"), mining speed, and Minecraft's "When in
    Main Hand:" block in light grey (" 6 Attack Damage", " 1.6 Attack Speed": the real combat
    numbers), then "Durability: 200 / 250";
  - **armor:** "When on Head:", "+2 Armor", "+2 Armor Toughness" and Tough As Nails' insulation
    ("+1 Warmth", "+1 Cooling", "Keeps you from freezing");
  - **food and drinks:** "When eaten: Restores 8 hunger, +12.8 Saturation" (with hunger off
    "Heals 2 hearts"), rotten flesh's "80% chance: Hunger (0:30)" in red, "When drunk: Restores 6
    thirst, +4.8 Hydration", dirty water's "50% chance: Thirst (0:15)" in red, a tea's Internal Warmth, a
    potion's effects, a canteen's "Sips: 2 / 3";
  - **fuel:** "Burns for 80 s, smelts 8 items" and what a Heat or Combustion Generator makes of it;
  - **blocks:** the tool they need ("Needs a Stone Pickaxe or better", "Best tool: Axe"), light,
    falling, climbable, slippery, flammable, warming or cooling you, a chest's slots, and a
    Mekanism block's store, tank, pipe or cable numbers, and a turret's range, rate, rounds held
    and calibre;
  - **Terraria's** accessories ("When worn:") and mana items, and in survival with the recipe gate
    on, "Crafting requires the Iron Age" in red when your Age can't make it yet.
  Every item has its lore in `Shared/Items/LoreList` (one line each, easy to edit; a test checks
  none is missing).
- **Knowledge, Ages and a skill tree.** Knowledge is this game's experience: Minecraft's curve (2L +
  7 points a level to 15, 5L - 38 to 30, 9L - 158 above), shown as a thin bar with the level under
  the status icons (survival and adventure). It comes from first times above all: a block kind mined
  5 points, an item crafted 8, a result smelted 10, a biome visited 20, a mob kind killed 10, an Age
  reached 50 to 200; and a little again and again: ores (coal 1 .. diamond 5), logs (0.25), each
  item smelted (Minecraft's furnace experience: an iron ingot 0.7), each craft (0.1), each mob (an
  animal 2, a zombie 4-10 by kind). Repeats wear off (a repeat of the same thing within a minute
  gives three quarters of the last), all repeats give at most 20 points a minute (perks included),
  and blocks a player placed give nothing at all, so farms dry up. What a furnace pushes into a
  chest beside it, or a pipe pulls out, counts as smelted by whoever last used the furnace.
  Knowledge opens five **Ages**, each at a level and one or two milestones: the **Stone Age** (where
  everyone starts: wood, stone tools, the crafting table, furnace, chests, torches, glass, iron
  smelting, copper, Sulfur and Saltpetre, Tough As Nails' basics, cooked meat, leather armor and
  wool), the **Iron Age** (level 5, a Furnace crafted and an Iron Ingot smelted: iron and gold tools
  and armor, the Bucket, Shears, Flint and Steel, the Lantern, the Canteen, the Thermometer, gold,
  osmium, lead and zinc smelting, brass, the Hazmat suit, potions),
  the **Industrial Age** (level 15, an Osmium Ingot and a Bucket: diamond gear, Mekanism's basic and
  advanced pipes, transporters and tanks, the Configurator, the Heat Generator, gunpowder and TNT,
  uranium smelting, potions II and long potions), the **Electric Age** (level 25, a Heat Generator: cables, the
  Electric Furnace, Batteries, upgrade cards, the Oil Refinery, the Combustion Generator, elite
  pipes) and the **Atomic Age** (level 40, an Oil Refinery and a Battery: the Solar Panel, the
  ultimate tiers, uranium's nuggets and blocks, the Nuke). A later Age's crafting results stay out of the grid (shown greyed with
  "Requires the Iron Age"; JEI puts a padlock on them) and furnaces take nothing that would smelt
  into one; reaching an Age is automatic, with a banner, a fanfare and a line in everyone's chat.
  Each level is a **skill point** for the skill tree (`K`): 18 small perks in three branches across
  the Ages, 1 to 5 points each: Forager (+10% knowledge from discoveries), Quarrying (stone tools
  mine 10% faster), Hardy (thirst drains 10% slower), Firekeeper (campfires boil twice as fast),
  Smithing (tools wear 15% slower), Prospector (ores give twice the knowledge), Insulation (a step
  of warmth and cooling), Ironworking, Demolition (unlocks gunpowder and TNT), Scholar, Tempering,
  Diamond Cutting, Thermoregulation, Endurance, Polymath, Fission (unlocks the Nuke), Mastery and
  Enlightenment. Progress is saved (DataStore "IceVoxelProgress_v1") and survives death; in a
  superflat or debug world, or one with Allow Commands, what is earned stays on that server.
  Creative players have every recipe and earn nothing. `/knowledge` and `/age` set it for testing.
- **Accessories and vanity (Terraria).** The inventory's EQUIPMENT column holds Terraria's
  equipment: under the armor, 7 accessory slots (5 open; the Industrial Age opens a 6th and the
  Atomic Age a 7th, a padlock until then), and in VANITY 4 vanity armor slots and 7 vanity
  accessory slots. An accessory goes in
  one accessory slot at a time (shift-click wears it, as it does armor and vanity pieces); what the
  accessory slots wear works, what the vanity slots wear only shows. Each accessory row and armor
  slot has an eye that hides its look and keeps its effect. The early-game accessories:
  **Hermes Boots** (sprinting on the ground builds to 1.4 times the speed over a second), **Cloud
  in a Bottle** (a second jump in the air, about a block, with a puff of cloud; its fall counts
  from where it took off), **Shiny Red Balloon** (jumps higher: the air jump then reaches 1.5
  blocks; like Jump Boost I it takes a block off a fall), **Lucky Horseshoe** (no fall
  damage), **Aglet** and **Anklet of the Wind** (+5% and +10% speed), **Band of Regeneration** (a
  half heart every 10 s), **Band of Starpower** (+20 mana), **Obsidian Skull** (campfires don't
  hurt, +1 armor), **Flipper** (swims twice as fast), **Cobalt Shield** (no knockback, +1 armor)
  and **Feral Claws** (the attack bar fills 12% faster). Every character draws what it wears,
  vanity over armor (armor and vanity armor as Minecraft-like layers on the R15 or R6 body,
  accessories as small models on the feet, hand, back, waist or face), the same in the
  inventory's middle column; the tooltip says what each does ("When worn:"). The server checks the
  faster movement (its move check allows the worn speed) and applies knockback, regeneration,
  attack speed, fall damage and campfires itself.
- **Day and night.** Minecraft's 20 minute day (24000 ticks: sunrise 0, noon 6000, sunset 12000,
  midnight 18000), with the sun at Minecraft's angle for the time and light that always matches the
  sun on screen. Roblox's Future lighting with shadows replaces the old fullbright look: warm
  sunrises and sunsets, dark blue nights you can still find your way in (Minecraft's night sky
  light of 4), and caves and closed rooms that stay dark at any time of day unless you light them.
  A tunnel dug into a hillside darkens with the distance from its mouth, not the depth of the rock
  above it. `/time` and `/gamerule doDaylightCycle` work as in Minecraft. The distance fades into
  the sky through Roblox's Atmosphere instead of the old distance fog: a light haze that thickens
  with the distance until the edge of the view distance melts into the sky behind it (90% hazed
  there, the far LOD terrain past it more; 6% at a fortieth of the way), in Minecraft's fog colour
  along the horizon, warm at sunrise and sunset, dark at night (Minecraft's night fog), and
  thinning out deep underground so cave walls never fade into a daylit sky (the view out of a
  tunnel's mouth stays hazed). Water, lava, oil, fuel and Blindness keep Minecraft's exact short
  fogs (the Atmosphere steps aside while they show).
- **Seasons, as Don't Starve's.** Autumn, Winter, Spring and Summer, 8 days each (a year of 32
  days, about 10.7 hours of play), a new world starting on Autumn's first day; every change blends
  over the two days around a turn, so nothing steps.
  - **The season clock:** a dial beside the minimap shows the year's seasons, today's day, dusk
    and night segments, the day number and "WINTER · 3 DAYS LEFT" (or "LAST DAY OF AUTUMN",
    "HEAT WAVE"); a toast and a low boom mark each season's turn and each heat wave. Options >
    HUD > Season Clock hides the dial.
  - **The sun and the climate:** winter's days are shorter (about 9 of the 20 minutes are day)
    and summer's longer (12.7), the clock itself unchanged; winter's light is cooler, autumn's
    warmer, a heat wave's glaring. Each season shifts the temperature (Tough As Nails: winter
    nights freeze, a summer day may be a heat wave), the weather (more rain in spring, little in
    summer, no thunder in winter; a winter plain snows) and how fast plants grow (not at all in
    winter, half in autumn, one and a half times in spring). With the seasons on, clothes slow
    freezing but never stop it, and shivering costs food.
  - **Snow:** in winter snow piles up in layers wherever it snows (up to 6 in cold biomes, 3 in
    temperate ones, 1 in tropical ones and none in deserts, more on high ground) and melts a layer
    at a time when it warms, or when the season turns (a taiga's snow goes in spring with the
    distant landscape's); deep snow slows walking, and it never grows under anyone standing on it;
    fire and warm rooms melt it; still water freezes from its edges (never beside a fire) and thaws
    back in spring, a player's pond too. The Snow Layer (three Snow blocks make six) stacks onto a
    layer, and n layers drop n Snowballs. Falling snow muffles zombies. A melted winter leaves
    nothing in the save.
  - **Foliage:** grass, leaves, tinted plants and vines turn through the year: autumn's reds,
    oranges and browns, winter's bare and snow-dusted colours, spring's fresh green, dry grass
    yellowing in summer; evergreens and jungles keep theirs, and so do the vines in mineshafts.
    The distant terrain turns with them, each chunk by its own biome.
  - **Rooms and heating:** walls, a roof and a floor around you make a room (up to 1,024 cells, 32
    blocks across, a few openings: a missing roof block leaks like a broken window, and so does a
    ladder shaft at its foot, however deep the base it goes down to) whose air has its own
    temperature: warmed by campfires, lit furnaces, working generators, players and the heaters
    below, and lost through its walls by their insulation (Insulated Planks hold heat best,
    Insulated Glass and the Insulated Door far better than glass and a door; glass and metal lose
    it; an open door leaks; furniture loses nothing, and a cable through a wall leaves it shut).
    The thermometer reads "Room +1 · Out -9", and WAILA a heater's room. The **Wood Stove** burns
    furnace fuel four times as long for 30 HU, anywhere; the **Oil Heater** burns Oil or Fuel; the
    **Electric Heater** (up to 40 HU) and the **Air Conditioner** (down to -40) hold a room at
    their set point on electricity; the **Electric Fan** cools a little. Their panels have "-",
    "+" and On / Off buttons; working, their windows glow and they hum, crackle or whirr.
- **Weather.** Regional, not Minecraft's one switch for the whole world: storms a few hundred to a
  few thousand blocks across drift over the world with a wind that slowly turns (about 1 to 3
  blocks a second), grow and die out, and leave clear stretches between them, so you can see one
  coming and walk out of it. Everyone computes the same storms from the seed and a weather clock
  of its own (`/time set` never moves a storm), so the weather costs no traffic. What falls
  follows Minecraft's rules for the place: rain, or snow where the biome is cold (snowy plains,
  groves, the peaks) and on high ground (it gets colder with height, so a mountain top snows
  while its valley rains), and nothing in deserts and savannas. Measured on a seed: it rains at a
  place about 23% of the time, a spell of rain lasts 17 minutes on average (2 minutes to a couple
  of hours), clear weather about 50, and the heaviest storms thunder (13% of the rainy time).
  Rain puts out fires under the open sky and keeps them from spreading, makes players wet (Tough
  As Nails), and muffles noise, so zombies hear less of what is done in it (0.7 of a noise's
  reach). Lightning strikes near players in thunderstorms (every 20 s or so
  under the heaviest), at the highest block or a living thing near it, setting fires (with
  doFireTick) and hurting the living within 3 blocks (5 half hearts and 8 s of fire, which the
  rain it strikes in puts out at once: Minecraft's), on a tower or a pillar too. Rain puts out
  any burning player or mob, as water does. Players together share their sky: eight at one base
  see the strikes one would, not eight times as many, and every player sees and hears those
  strikes from as far as their view reaches.
  `/weather clear|rain|thunder [duration]` blends the whole world into that weather over 5 s
  (from whatever it was, however quickly the commands come), and
  `/gamerule doWeatherCycle false` stops the storms where they are, as in Minecraft. A saved world
  keeps its weather: loaded again, the same storms are where they were and an override has the
  time it had left; a new world starts with a clear sky over spawn.
- **Rain, snow, clouds and lightning.** Rain and snow fall around you as Minecraft draws them: a
  streak in every block column within 10 blocks (5 on Fast), only above the highest block that
  stops rain, so never indoors, under a tree or in a cave, rain or snow by each column's biome and
  height (a snow line cuts through a storm on a mountainside), fainter at a storm's edge. You hear
  it land around you (on a roof over you, muffled), the sky and the light darken by Minecraft's
  amounts (5/16 for rain, as much again for thunder; caves stay as they are), the picture greys
  and the haze thickens (as a view 0.6 as far in rain, 0.4 in snow, 0.45 in thunder) and darkens,
  greying the horizon over. Clouds reach the render distance at y 320 in rings of detail (16-block
  boxes near you, bigger ones far off): scattered white ones in fair weather, a grey deck over
  rain, near-black towers over thunderstorms with grey rain shafts under them, so a storm shows
  on the horizon long before it arrives, and they drift with its wind. Lightning is Minecraft's
  bolt (128 blocks of zigzag with two branches, flashing one to three times), with a flash of the
  sky, a crack where it strikes and thunder that comes later the farther it struck (343 blocks a
  second). The Clouds and Weather settings (Options > Weather...: OFF, Fast, Fancy) choose how
  much is drawn; F3 shows the weather where you stand. Measured on seed 12345: about 200 cloud
  parts at the default view (at most ~390, a third of them rain shafts), ~40 on a phone (Low:
  Fast, 512 blocks), placed at most 48 a frame.
- **Distant storms.** A thunderstorm far off is seen and heard, not only the one you stand in
  (Minecraft has no weather far off). Its towers flicker as lightning lights them from inside, and
  bolts reach from its cloud base to the ground (about 3 in 10 flashes, only where rain falls),
  drawn about two pixels wide and bright enough to show through the haze out to the render
  distance, with a fainter flash of the sky (fainter still by day). Thunder rolls in later the
  farther it is (6 s from 2 km), quieter, lower, longer and muffled (an equalizer takes the highs
  first, as the air does) out to 2048 blocks (1024 on phones); past that a storm on Ultra's
  4096-block view flickers silently, as heat lightning. Every client works the flashes out from
  the seed, the weather and the server's clock, so everyone sees the same lightning with nothing
  sent (in a sky busy enough to hit the cap below, clients with another view distance or Fast
  clouds thin it differently and share most of their flashes, not all): 12 flashes a minute per
  km² of full thunder (a typical storm in view flashes every 10 to 15 s, a big one every few
  seconds), at most 24 a minute in all (one every 2.5 s; 12 on Fast clouds, none with clouds
  Off), never a bolt within 64 blocks of a player or near one standing in thunder (the server's
  real strikes are there). Rain falling nearby but not on you is heard as a soft, muffled hiss
  from its side that gives way to the rain's own sound as it arrives, quieter and duller under a
  roof. F3 shows the flashes a minute in reach, those shown and the distant sounds playing. Cost:
  each 2 s of flashes is worked out during the 2 s before, a few rows of a 35 × 35 grid of the
  weather a frame (67 × 67 on Ultra), about 0.1-0.2 ms a frame interpreted, and ready in time at
  any frame rate (fewer frames, bigger bands).
- **The weather map.** `B` (or the cloud button on the minimap or the world map, the way in on a
  touch screen) lays the weather over both maps: rain in blue, snow in white, thunderstorms purple
  with yellow lightning, clouds as a grey veil, the wind with an arrow. The world map forecasts:
  its buttons show the weather in 2, 5, 10 and 20 minutes (the storms are worked out from the
  seed, so a forecast is the real weather then, `/weather` included).
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
- **Mineshafts.** Minecraft 1.20.1's abandoned mineshafts, grown from its own piece grammar
  (MineshaftPieces: a room, then corridors, crossings and stairs, depth first, at most 8 steps and
  80 blocks from the room): rooms with a domed roof, 3 × 3 corridors 10-20 blocks long with a
  support every 5 blocks (an oak plank beam on two oak fence posts; a quarter of them broken to their
  end planks), a rough ceiling, rails in a third of the corridors (with gaps), cobwebs in the
  corners and whole corridors full of them (Minecraft's spider corridors, with no spawner), a
  rare wall torch, plank bridges with oak log pillars where a corridor crosses a cave, crossings
  (some two floors tall) and stairs going down, and a chest now and then (1 in 100 per section
  side) with Minecraft's mineshaft loot on this game's items (an iron pickaxe, ingots, raw ores,
  a diamond, coal, porkchops, glow dust, herbs and straw; rails, torches and rope). About 9-16
  per km², fewer where a seed has more sea (Minecraft's 1 in 250 chunks would be 15), each
  typically 60-150 pieces over some 130 × 130 blocks; the room's floor lies 28-64 blocks under the
  surface, every piece keeps 6 blocks of ground over it, none goes below y 16 (the lava seas) or
  near a lake, puddle, lava lake, oil well or library structure (nor under a city or a road), so
  they never flood. In humid
  biomes they are **overgrown** (as one running into Minecraft's lush caves; jungles 72%, birch
  forests and mushroom fields 80%, old growth taigas 56%, forests and taigas 32%, never in dry
  biomes): moss on the rock around (floors, walls and ceilings; the woodwork stays wood), moss
  carpets, vines hanging from the walls, hanging roots, glow lichen and fewer cobwebs. About half
  of the overgrown ones under dry land have an **entrance** (none under the sea or a beach, so a
  fifth to a half of all of them, by the seed): a 3 × 3 shaft open to the sky on dry, level
  ground (never by water, a cave entrance, a lake or the spawn), framed by a mossy cobblestone
  collar, an oak log beam on two fence posts three blocks over it, and a **rope hanging all the
  way down** from the beam to the floor of the room or corridor 20-65 blocks below (now and then
  as much as 85; planks under it where a cave crosses that floor): jump onto it from the collar
  and let go to slide down (a rope never hurts), or sneak to hold on; hold jump to climb back up,
  and at the top, where your head meets the beam, walk off across the beam onto the collar. Vines
  run down its walls from the collar's top (they climb out too); no tree grows by one. A mineshaft is written
  into the full detail chunks only, as cave air and cave twins of its rails, posts, cobwebs,
  torches and plants, so while caves are hidden it costs nothing to draw until you find it (the
  entrance shaft is open air like a cave entrance's pit); mobs spawn in its dark like any cave
  (never on its rails, as in Minecraft; an overgrown one's glow lichen keeps most of it lit).
  Generate Structures (and `Config.Structures.Generate`, `Config.Mineshafts.Enabled`) turns them
  off. Worlds saved before mineshafts existed get them too, wherever nobody changed the blocks
  (terrain comes from the seed; every edit stays): mostly under ground, but an entrance's pit,
  collar and headframe can also open in untouched ground there, even in the natural floor of a
  house built before (its walls and roof stay; the pit is 20-85 blocks deep). The All Structures
  debug world shows a sample of each.
- **Overgrown cities and roads.** The zombie apocalypse's ruins: towns and cities of a world that
  ended years ago, and the roads between them. One candidate per 1024 × 1024 block cell (kept
  with `Config.Cities.Chance`), tried at up to four spots, stands where the land is fit to build
  on (hills or plains, dry, above the sea, not frozen and not in the mountains): about 6-11 per
  100 km² on land worlds, most of them small towns (70-200 blocks across), now and then a city
  with a downtown (up to about 450). The ground under a city is levelled to one plateau (cut and
  fill, blended back to the terrain over 24 blocks), so the map, the far terrain and every chunk
  agree.
  - **Streets:** a grid of 7 block wide streets every 32 blocks: asphalt with a dashed yellow
    centre line and white crosswalks at the crossings, concrete sidewalks, cracked patches,
    potholes of gravel, and the green taking them back: a fifth to two fifths of the asphalt
    (more of the sidewalks) gone to grass and moss in patches, tall grass and ferns on the
    grass, and trees growing out of the streets' grass, the parks and the plazas (a few even in a
    plains town, whose own biome grows next to none; a desert town's green grows dead bushes and
    next to no trees, as the desert does).
  - **Buildings**, by their distance from the centre: offices up to 12 floors with glass bands
    downtown, apartments of 3-6 floors, shops (a grocery, a pharmacy, a hardware store or an
    office), rows of four houses, parks (grass, trees), plazas, parking lots full of wrecks and
    lots of rubble; every town has a police station, a fire station and a pharmacy. Buildings are
    ruins: their tops collapse in a jagged line, walls are blown out, cracked and mossy, slabs
    hole into rubble on the floor below, and the green takes them back (curtains of vines down
    the walls, low on the towers, moss on the roofs, moss carpets on the floors, grass and moss
    in the ground floors, cobwebs in the corners; more of it in wet biomes, a jungle's twice a
    desert's). The first four floors are open
    rooms with a ladder up a corner, doors (or a gap where a door was) and windows; higher floors
    are a facade over a ring of rooms around a solid core. Rusted cars stand in the streets and on
    the roads, whose asphalt greens and grows plants like the streets'.
  - **Loot** waits in chests, **Supply Crates** and **Medicine Cabinets** against the inside walls
    (house, grocery, pharmacy, hardware, police, fire station, office and car tables: food,
    water, bandages, painkillers, antibiotics, tools, nails, gunpowder): a big city holds about 15
    antibiotics on average and every town at least one medicine cabinet. One or two small plank
    sheds per town stand over a bunker's hatch (see Bunkers).
  - **Roads** (5 blocks of asphalt with gravel shoulders, graded to at most 1 in 6, wobbling
    gently, raised on causeways over short stretches of water) link each city to the nearest in
    every quarter within two cells; links that would cross long water, climb into the mountains
    or cut or fill more than 24 blocks are dropped.
  - **From afar and on the map:** buildings show as their massing to LOD level 4 and roads to
    level 2; the map paints cities as grey squares (their street grid darker at 8 blocks a pixel)
    and roads as dark lines from 8 blocks a pixel out, and closer in the streets block by block.
  - **Around them:** no lake, well, lava lake, outpost, mineshaft, cave entrance, ravine or tree
    lands on a street, a road or a building lot. The spawn lands 150-400 blocks outside the
    nearest city within 3 km of where it would be, so one is in sight. `/locate structure city`
    finds the nearest (`#ruins`: a city or a bunker).
  - **Switches:** the world's **Ruins** setting (Customize on Default, Single Biome and Large
    Biomes; on by default for new worlds), Generate Structures, `Config.Structures.Generate` and
    `Config.Cities.Enabled` turn them off (`Config.Cities.Roads.Enabled` the roads alone). A world
    saved before the ruins existed stays without them unless `Config.Cities.OldWorlds`. The All
    Structures debug world shows a sample town with one parcel of every kind.
- **Bunkers.** Hidden hideouts from before the fall: a steel **Bunker Hatch** lying flush in the
  ground (a collar of concrete and mossy concrete around it, grass and ferns hiding it) over a
  ladder shaft 9-16 blocks deep into an **airlock**, a 3-wide **corridor** and 3-6 concrete rooms
  off it (2-6 under a city's shed, where room is short).
  - **Rooms:** always a **bunk room** (three Planks-and-wool bunks along each wall) and a
    **storeroom** (3-5 Supply Crates and a Chest), then medical rooms (two Medicine Cabinets on
    the wall, a cot), a generator room (an iron and rusty-metal machine, a Furnace, coal blocks, a
    crate), an armory (two Chests and an iron rack) or a mess (two Crafting Tables, a crate).
  - **Loot:** the storerooms hold cans, rations, water, torches, coal, gunpowder, rope, nails and
    iron; the medical rooms medkits, bandages, antibiotics, painkillers and potions; the armories
    machetes, fire axes, crowbars, iron swords and armor, gunpowder, TNT, a Cobalt Shield or Feral
    Claws now and then; the generator rooms coal, fuel and oil, scrap metal, iron and a bucket.
  - **Lit or not:** four in five are lit (Ceiling Lamps every five blocks of corridor, one or two
    a room); the rest are dark, and zombies may spawn in them. About one in seven is **overrun**:
    mossy walls, cobwebs under the ceilings, half its lamps gone and bones and rotten flesh among
    the loot.
  - **The hatch:** right click it to open or shut it (from inside too; it thuds, and zombies
    hear it as a door). Climb out pressed against the ladder: the open hatch stands up on the far
    side of the shaft. A shut hatch is a safe haven: zombies never break it and never dig down
    (they walk over it). It is crafted too (four Iron Ingots), to seal a shelter of your own.
  - **Where:** in the wild about one per 768 × 768 cell kept with 35%: 0.4-0.6 per km² (fewer
    where a seed has more sea), on dry, level ground, never by water, a lake, a well, an outpost,
    a city, next to a mineshaft (a deeper one may run underneath) or within 64 blocks of the
    spawn; and 1-2 under each town, below a shed in its house lots (the outer ones first).
    `/locate structure bunker` stands you on the nearest hatch and shows its y; `/locate poi
    bunker_hatch`, `supply_crate` and `medicine_cabinet` find what is near.
  - **Cost:** a bunker is written into the full detail chunks only, as cave air with cave-twin
    lamps and cobwebs, so while caves are hidden it costs nothing to draw until you climb down
    (the shaft is open like a mineshaft entrance's). Bunkers follow the Ruins setting and Generate
    Structures (`Config.Bunkers.Enabled` turns them off alone). The All Structures debug world
    shows a sample with every kind of room.
- **World types.** Minecraft's world presets, each with its own options: **Default**;
  **Superflat**, layers from a preset line in this game's names (`Bedrock,2*Dirt,Grass;Plains`;
  Minecraft's own strings such as `minecraft:bedrock,2*minecraft:dirt,minecraft:grass_block` paste
  too) or Minecraft's presets whose blocks exist (Classic Flat, Tunnelers' Dream, Water World,
  Overworld, Snowy Kingdom, Bottomless Pit, Desert, Redstone Ready), trees and plants optional, a
  bad preset falling back to Classic Flat with the reason; **The Void**, a 33 × 33 stone platform
  at y 64 over nothing; **Single Biome**, the Default's mountains with one biome everywhere (sand
  up the peaks of a desert world); **Large Biomes**, the Default with climate four times as wide;
  and three debug worlds: **All Blocks** (Minecraft's Debug Mode: every block once, variants and
  fluid levels included (not the cave twins, which look exactly like theirs), at y 70 on a grid
  with a gap between, nothing ticks so nothing flows or falls, spectator suggested), **All
  Structures** (every template of the structure library and every generated structure on a grass
  floor, the sample mineshafts, bunker and town among them, each with a structure block name tag
  that WAILA reads and F3 outlines) and **All Biomes**
  (a 16 block strip of every biome's ground, trees and plants). The void and the debug worlds
  spawn no mobs. The server publishes the type and its options with the seed, so every client and
  worker builds the same world; the far terrain, the map, WAILA's biome, Tough As Nails, safe
  spawning and sky checks all follow it.
  The Create World screen offers every type (the debug worlds last) with its Customize screen
  (Default, Single Biome and Large Biomes have the **Ruins** setting: cities, roads and bunkers);
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
- **Caves always shown.** The Caves video setting (Hidden Until Seen by default,
  `Caves.AlwaysShow`) can draw every cave of every full detail chunk instead, wherever you are:
  looking into an entrance or a ravine from above shows the caves it leads to instead of a stone
  cap, with their lichen and lava lit as in a revealed cave (caves still end in stone where full
  detail ends). It is heavy (its tooltip says so): about 4 × the parts of full detail terrain, and
  a few hundred more PointLights (lichen and lava; the Lichen Lights setting limits the lichen's).
  Seed 12345 at Config's view (`lune run tests/bench`), full detail terrain only:

  | Where (full detail chunks)    | Hidden until seen | Always shown               | Lights |
  | ----------------------------- | ----------------- | -------------------------- | ------ |
  | spawn, hills (160)            | 9.5k parts        | 35.7k parts (3.8 ×, +26k)  | +226   |
  | spawn, underground split (256) | 14.1k parts      | 49.2k parts (3.5 ×, +35k)  | +307   |
  | mountains (164)               | 19.5k parts       | 82.3k parts (4.2 ×, +63k)  | +364   |
  | mountains, underground (264)  | 31.9k parts       | 136.3k parts (4.3 ×, +104k) | +615  |

  so a whole view (34k / 81k parts with far terrain) grows by about 75%. Far terrain has no caves
  at either setting (entrances and ravines are cut into it as open air either way). Switching
  generates nothing again and remeshes only the full detail sections that hold terrain, through
  the workers like any cave reveal: on real terrain each once going back to hidden, 1.45 times on
  average going to always shown (a cap reopens where two groups of sections met). The workers
  skip buried rock with no cave in it, so meshing a view always shown costs 4-8 × the time of
  hidden caves, not 15 × (the mountains: 2,161 sections meshed instead of 5,689).
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
  end of the quickbar on touch screens): a graphics preset (Low, Medium, High, Ultra) and every
  view, performance, sound, control, HUD and chat setting, applied while you play and saved per
  player and kind of device. See [Settings menu](#settings-menu).
- **Chat.** Minecraft 1.20.1's chat instead of Roblox's window and bar: lines at the bottom left
  above the quickbar in the pixel font with a shadow and a dark background, fading 10 s after they
  arrive (all of them back while the box is open), 100 kept and scrolled with the wheel. `T`
  opens the box (`/` with "/" typed; both are key bindings): `Enter` sends, `Escape` closes, `Up` /
  `Down` bring back what you sent, `Tab` completes command names, `/locate`'s arguments and
  players' names, and command names (and `/locate`'s arguments) are suggested as you type them
  (only the commands you may use: `/op` and `/deop` for operators, `/effect`, `/summon`,
  `/kill`, `/locate` and `/tp` for operators or with Allow Commands, `/gamemode`
  when you may change your own mode). Players' messages read "<Name> message", joins and leaves are yellow ("Alex
  joined the game"), command answers and the server's messages white, errors red. Everything
  players type goes through Roblox's TextChatService, so Roblox filters it (and an account that
  may not chat is told so). Commands (`/time`, `/gamemode`, `/summon`, `/effect`, `/knowledge`,
  `/age`, Roblox's `/whisper`, `/team`, `/e`...) run without being shown to anyone; a command
  nobody knows is not sent but answered with Minecraft's red "Unknown or incomplete command, see
  below for error". Chat Settings: Chat (Shown, Commands Only, Hidden), text and background
  opacity, text size, line spacing, chat delay, width, focused and unfocused height, command
  suggestions. On touch screens a speech bubble over the `…` button opens and closes it. On a PC
  the chat rises with the quickbar (5 % of the screen's height), so it stays clear of it; the
  title screen has no chat (Roblox's is off from the start).
- **Finding things: `/locate` and `/tp`.** Minecraft 1.20.1's `/locate structure | biome | poi`
  for operators (or everyone with Allow Commands): `/locate structure outpost` answers "The
  nearest outpost is at [1142, ~, 582] (1281 blocks away)" in true world coordinates (F3's).
  Structures are the library's (outposts) and the built-in `mineshaft`, `mineshaft_overgrown`,
  `mineshaft_entrance`, `oil_geyser`, `oil_deposit`, `lava_lake`, `lake`, `cave_entrance`,
  `ravine`, `city` and `bunker`, or a tag (`#mineshaft`, `#oil_well`, `#lake`, `#cave`, `#ruins`:
  a city or a bunker, `#library`); biomes by id (`birch_forest`, `minecraft:jungle`) or tag
  (`#is_forest`, `#is_snowy`, `#band_peaks`...); points of interest (chests, crafting tables,
  furnaces, campfires, the machines, batteries, tanks, structure blocks, jigsaws, TNT and Nukes,
  supply crates, medicine cabinets and bunker hatches; `#workstation`, `#machine`, `#container`,
  `#scavenge`...) within 256 blocks, placed ones and generated ones (an outpost's chests, a
  mineshaft's, a ruin's or a bunker's crates and cabinets) alike.
  A structure or biome search generates no chunk: it reads the generators' plans cell by cell,
  nearest first, and answers the true nearest (Minecraft's sometimes answers a farther one); a
  poi search checks each generated candidate by generating its chunk on the search's own
  generator (never the world's). Underground things show their y (a mineshaft's room, an
  entrance's collar, a bunker's hatch, a point of interest's block, where Minecraft shows `~`),
  surface ones `~`;
  distances are horizontal. Searches run on the server a slice of each frame (3 ms, just before
  the chunk preload's slice), so a long one (no outpost for 100 regions, a rare biome: about a
  second of work) never stalls it. The coordinates are green: click them with the chat open and
  `/tp @s x y z` is typed for you. `/tp` (`/teleport`) moves you or others to coordinates (`~`
  relative) or to a player. Survival players land on safe ground: a `~` height on the column's
  safe top, a written one at the safe spot nearest it in the column (within 16 blocks, so a
  small move in a cave stays in the cave), else the nearest column with safe ground within 24
  blocks (a lake's, lava lake's, geyser's, ravine's or cave entrance's middle has none), else
  afloat on open water; the answer says where they landed.
- **Mekanism pipes.** Mekanism 10's transmitters, for what the game has. A transmitter is aimed
  at and collides by its core and the arms it joins (Mekanism's shapes; a pipe on the floor is
  0.75 high: jump over it), not its whole block. Logistical Transporters
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
- **Turrets.** SMG, Rifle and Sniper turrets in the transmitters' four tiers (Basic, Advanced, Elite,
  Ultimate) shoot zombies with the 9mm, 5.56 or .308 rounds a Logistical Transporter feeds them,
  on Mekanism energy. Each tier reaches further, turns and fires faster and holds a few more rounds:
  SMG 16 / 20 / 24 / 32 blocks at 90 / 150 / 240 / 360 rounds a minute holding 2 / 3 / 4 / 6; Rifle
  24 / 32 / 40 / 48 at 45 / 75 / 120 / 180 holding 1 / 2 / 3 / 4; Sniper 40 / 48 / 56 / 64 at 15 /
  20 / 30 / 40 holding 1 / 1 / 2 / 2 (`Config.Turrets`). The belt feeder runs at the speed of the
  transporter that feeds it: a turret fires at most the rate of its type at the best transporter
  tier next to it that brings it rounds (a Basic transporter caps an Ultimate SMG at 90 a minute;
  a dead stub, a transporter of another colour or a line passing by with other items doesn't
  count), so its full rate needs a transporter of its tier or better; fed through one it holds
  that rate, and each further transporter costs its trip. A line into a full turret waits for
  room instead of backing off, looking at the turret and its chest alone (a turret placed on the
  line or another calibre put in the chest is seen within 3 ticks), so it costs no more than a backoff
  (Mekanism's backoff is unchanged for chests, furnaces and every other machine), and a line
  branching to several turrets feeds them all, taking turns when it cannot keep up. Filled by
  hand (no transporter) a turret fires its buffer at its own rate, then shows "No ammo". Energy:
  20 / 40 / 80 / 160 kJ stores, 4 / 8 / 12 / 16 J a tick idle, twice that while tracking, and 30
  (SMG), 80 (rifle) or 300 (sniper) J a shot: power is a requirement, ammo the real cost. Its panel
  has the ammo, optic and muzzle slots (outlined while empty), the status ("No target",
  "Targeting", "Firing", "No ammo", "No power", "Blocked", "Disabled"), "Range 24 · 240 rpm" (with
  its optic: a scoped Advanced rifle says "Range 40"), the feed ("Feed: Elite", "Feed: Basic → 90
  rpm", "Feed: by hand"), the rounds arriving ("In: 2.4/s"),
  the Lure and its button, and the energy bar; WAILA shows the status. Transporters reach only the
  ammo slot (through every side but the top, where the gun sits) and never take anything out; a
  block, a transporter or deep snow over a turret blocks it (one layer of snow, a torch or water
  don't), and nothing rests on its top. Attachments: a Laser Sight (turrets only: a hand-held gun
  takes none) halves the cone and finds targets sooner, a Rifle Scope on a rifle or sniper reaches
  a quarter further (up to 80 blocks) and lets a sniper aim at heads, a suppressor or an improvised
  one quiets it; none of them wear on a turret, and a Ruined one does nothing. Recipes: the parts
  (a Servo Motor, a Belt Feeder, a Receiver, a Targeting Module and a barrel for each type) from
  iron, osmium, leather, nails, scrap, glass, glow dust, cables and diamonds; a Basic turret from
  its barrel, a servo, a receiver, a belt feeder, osmium and a targeting module; each next tier
  around the one below, with gold, diamonds or emeralds in the corners (as the transmitters'
  upgrades), keeping its energy and its Lure. The parts, the Laser Sight and the Basic to Elite
  turrets are the Electric Age's, the Ultimates the Atomic Age's. Broken with a pickaxe a turret
  keeps its energy and its Lure. Its tooltip says "Range 24 · 240 rpm · holds 4 · 9mm" (its own
  range, without an optic). A turret
  shoots only zombies (any monster: never a player or an animal, which its shots fly through). It
  looks for the nearest it can see, with a little weight on how far it must turn: each scan six,
  best first, of those it has not yet looked at in vain (and the three best again every second
  scan), so a zombie in sight next to it is taken at the next scan or the one after however many
  hide behind a wall, and before one in sight further off; it keeps its target until it dies,
  leaves its range or stays hidden half a second. It turns at its tier's rate (SMG 180–360 degrees
  a second, rifle 120–240, sniper 60–120) and fires once on target. Glass and leaves hide a zombie from it, torches
  and water don't, and a zombie more than 60 degrees below an SMG or a rifle, 51 below a sniper
  (whose longer barrel would meet its own block), is safe: hugging the foot of a 2-high wall it
  stands on, within 1.8 blocks of the gun sideways (a sniper's 2.5). Shots are traced like a
  player's but never shatter glass or break a block, and a kill credits nobody (no Knowledge, no
  kill count, no player-only loot), as an iron golem's. A scoped sniper aims at heads. Gunfire
  draws zombies (SMG 36 blocks, rifle 60, sniper 72; a suppressor a quarter of that, an improvised
  one under half) at most once a second. At night or in a blood moon an armed turret with no target
  lures them: a 24-block noise every 30 s, one in each 48 × 48 area (the Lure button turns it off;
  a suppressor doesn't quiet it). The gun turns on its base (the barrel by type, bands in the
  tier's colour, what is mounted: a laser's red beam to the first block or the target, a scope, a
  suppressor's can), with a faint servo while it turns and a dry click when it runs out (never
  while it waits on a slow line); WAILA shows its rounds, feed and fittings.
- **Metal Miner.** A machine that copies the ore block under it forever, for power, and pushes the
  drop out into the chests and transporters next to it: Coal Ore gives Coal every 30 s at 800 J a
  tick (never more energy than the coal burns for), Iron and Osmium Ore their raw ore every 20 s at
  200 J a tick, Gold Ore every 40 s at 300, Emerald Ore an Emerald every 3 minutes and Diamond Ore
  a Diamond every 4 minutes at 800; the new ores too: Copper, Lead and Zinc Ore their raw metal
  every 20 s at 200, Sulfur and Saltpetre Ore a Sulfur or a Saltpetre every 30 s at 200 (so
  gunpowder, and with it ammo, can be automated), Uranium Ore Raw Uranium every 3 minutes at 800
  (`Config.Miner`), faster with Speed Upgrades and cheaper with
  Energy Upgrades (Mekanism's maths; coal never under its floor, and cards put in or taken out
  mid-item keep the share made, so no swap makes a coal cheaper). It needs a real ore block where it
  lies (ores can't be moved) and keeps mining with nobody near. Its panel: the output, the arrow,
  the status ("Mining Diamond Ore", "No power", "Output full", "No ore below"), two lines ("Makes
  Diamond", "4:00 an item"), the upgrade slots and the energy bar (200 kJ). Recipe: osmium around
  a Universal Cable, over Blocks of Iron around an Electric Furnace, over diamonds around a
  Diamond Pickaxe (the Electric Age's). While it works its grille glows yellow-orange and it
  hums heavily. JEI's "Duplicating" lists each ore, its drop, time and energy (`U` on the miner).
- **Ammo Press.** Presses a Brass Ingot (the cases), a Lead Ingot (the bullets) and a Gunpowder
  into 16 9mm, 10 5.56 or 5 .308 rounds in 10 seconds at 50 J a tick (`Config.AmmoPress`), the
  calibre picked by its Calibre button (kept in its item), with upgrade cards (swapped
  mid-operation they keep the share done); the rounds are pushed out on their own. Its row reads
  brass, lead, gunpowder, then the arrow and the rounds; each slot takes only its item, by hand,
  shift-click or a transporter through any side. Gunpowder needs the Demolition skill, so ammo
  stays the real cost of defence. Recipe: iron around a Servo Motor, over osmium around an
  Electric Furnace, over iron around a Block of Iron (the Electric Age's). Its status says "Using
  50 J/t", what it lacks while it holds some of the three ("No lead", "No brass or gunpowder"),
  "Output full" or "No power"; taking any input away starts the operation over, switching the
  calibre keeps the progress. A press from a world saved before lead and brass keeps its slots
  (the lead's is new and empty); its Iron Ingots stay in the brass slot, pressing nothing, until you
  take them out. While it works its window glows and it hums. JEI's "Pressing" lists its three
  calibres, each from the three inputs (`U` on the press).
- **Osmium.** Mekanism's metal: Osmium Ore (blue-grey speckled stone, hardness 3) needs a stone
  pickaxe or better and drops Raw Osmium, which smelts into an Osmium Ingot (the ore smelts too).
  Nine nuggets make an ingot, nine ingots a Block of Osmium and nine raw osmium a Block of Raw
  Osmium (both hardness 7.5, as in Mekanism), and each unpacks again. The ore generates in small
  veins in all rock, plus Mekanism's "middle" veins concentrated around y 100: about as much as
  iron below y 197 and about half as much in the mountains above.
- **Copper, lead, zinc and brass.** Copper Ore (orange-specked stone), Lead Ore (dull blue-grey)
  and Zinc Ore (pale grey-green), hardness 3, need a stone pickaxe and drop Raw Copper, Raw Lead
  and Raw Zinc, which smelt into ingots (the ores smelt too). Each metal has its nuggets (nine to
  an ingot), its Block (nine ingots; copper's hardness 3, the others 5) and its Block of Raw metal
  (nine raw, hardness 5), all unpacking again. Brass is an alloy: three Copper Ingots and a Zinc
  Ingot in any slots make four Brass Ingots, with Brass Nuggets and a Block of Brass. Copper is
  the Stone Age's; lead, zinc and brass the Iron Age's. Brass makes the Ammo Press's cases and lead
  its bullets.
- **Sulfur and saltpetre.** Sulfur Ore (yellow crusts) and Saltpetre Ore (white crusts) drop one
  Sulfur or one Saltpetre with any pickaxe, as Coal Ore does (and smelt into it). Two Saltpetre, a
  Sulfur and a coal or charcoal make four Gunpowder (behind the Industrial Age and Demolition, as
  gunpowder is). The Metal Miner copies both.
- **Uranium.** Uranium Ore (green-specked stone) needs an iron pickaxe and drops Raw Uranium, which
  smelts into a Uranium Ingot from the Industrial Age (the Age of the transporters, which feed
  furnaces whoever's Age it is), with Uranium Nuggets, a Block of Uranium (the Nuke's core) and a
  Block of Raw Uranium in the Atomic Age. The **Hazmat suit** (Mekanism's Hazmat Mask, Gown,
  Pants and Boots: lead ingots in White Wool padding, the mask with a glass visor; Leather's
  armor points) is the Iron Age's.
- **Where the newer ores are found.** Each follows its mod's numbers, mapped onto this taller
  world (Minecraft's ground under the sea is y 5-197 here):
  - **Copper Ore** (Minecraft's: 16 veins of 10 a chunk) at middle heights, from y 48 to 304 and
    thickest around y 176, under hills: more than iron there (2.4 times around y 130-230), less
    deep down.
  - **Lead Ore** (Mekanism's: 8 veins of 9) low to middle, from bedrock to y 197, thickest around
    y 83: a little less than osmium; none in the mountains.
  - **Zinc Ore** (Create's veins of 12) anywhere from y 5 to 197, about as common as gold.
  - **Uranium Ore** (Mekanism's small and buried veins, a quarter as many) deep: near bedrock and
    in the deep caves up to y 133, never in the mountains; rare (about half as common as iron
    below y 50, four times the diamonds), and mostly buried in the rock: three in four of its
    buried veins' cells that would face a cave stay stone (about three in five of all its own).
  - **Sulfur Ore** where it is volcanic: in the rock of the cave lava's band (bedrock to y 33), in
    crusts on the stone rim of every lava lake (about 20 a surface lake, 35 one sunk into a cave
    floor), and in the rock around oil deposits (20-30 around a small well, 35-70 a medium one,
    85-210 a large one).
  - **Saltpetre Ore** under dry land: 4 to 36 blocks below the surface of deserts, savannas and
    windswept savannas (the biomes where it never rains; never under wetter land beside them or
    the sea), about 24 a chunk, as much as coal there.
- **Item data.** Items carry a little data of their own, Minecraft's item NBT kept flat: up to 16
  named numbers, strings or flags. A Fluid Tank broken in survival keeps its fluid in its item
  ("Lava: 12,000 mB" under its name in the inventory) and gets it back when placed again, as in
  Mekanism, and so do machines their energy and their fluid tanks; in creative, placing a tank item
  that holds a fluid fills the new tank too. Items with different data never stack, and wherever a
  stack goes (clicks, chests, furnaces, transporters, the ground, death drops) its data goes with
  it.
- **Items drawn in 3D.** Every icon (quickbar, inventory, creative picker) is a small 3D model in a
  ViewportFrame with the same look as the block in the world (a little darker in the inventory and
  the quickbar). Dropped items and the item in a
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
  joining, then every 10 to 20 minutes), surface tracks above ground by day, night tracks there at
  night (the game's own night: the sky dark enough that zombies come out) and cave tracks in caves;
  going underground fades a surface or night track out and a cave track follows (and the other way
  back up), so surface music never plays underground. Dusk and dawn never cut a track: the next
  one follows the time. A "Now Playing" toast slides in at the top right with the track's title
  for five seconds. The tracks are in `src/shared/Sounds/MusicList.luau`.
- **Cave moods.** Minecraft's cave mood: every tick a random block within 8 blocks of you makes
  the mood grow in the dark (1/6000; dark open cave counts 4 times, so bigger caves bring it
  sooner) and shrink in daylight or by torches; at 100% one of the cave mood sounds plays a couple
  of blocks beyond a dark spot and it starts over: about five minutes in a narrow tunnel, two and a
  half in a big cavern, one and a half in the Underlands, never in daylight (F3 shows "mood N%").
- **Sounds.** Minecraft's sound events for everything that should make a sound: breaking, placing
  and mining blocks (by material: stone, wood, gravel, grass, sand, glass, snow, metal, wool,
  water), footsteps every 1.67 blocks (yours and other players'), hurting landings, splashing and
  swimming, chest lids, the furnace you are using crackling while it burns, items picked up, tools
  breaking, armor put on, getting hurt and dying, interface clicks and Minecraft's cave moods; lava
  popping and bubbling, hissing where water hardens it, the sizzle of burning and its hiss when
  water puts it out, buckets of lava and oil (thicker than water's) and Combustion Generators
  crackling; fire crackling, hissing when punched out, and flint and steel striking; mobs hurt and
  dying (each kind its own pitch: a brute low, a screamer high), zombies groaning, bashing at a
  block and breaking it through, a screamer's shriek, the bunker hatch, bandages, medkits and pills,
  a blood moon rising, players' hits (strong and weak), eating and drinking. Only water and fuel
  splash and make swimming sounds. Most are stand-ins made from the sounds every Roblox client
  ships, told apart by pitch, so nothing has to be uploaded, and players hear what others do within
  16 blocks. The game ships real recordings for the rest: the weather (thunder, rain, wind), the
  zombies' groans, growl and deaths (every kind, at its own pitch), a block broken and placed (every
  material, at its own pitch and volume), a loop while a player eats or drinks, heard by the
  players near as long as the food or drink is held, a hit landing (players' and bullets'), the
  9mm, 5.56 and .308 shots and their silenced ones (the other calibres keep their gun class's),
  lava's bubbling, the machines' hum (the Electric Furnace, heater, air conditioner and Ammo
  Press; the Metal Miner and Oil Refinery a heavier one) and a Geiger counter's click while you are
  exposed to radiation (each with the stand-in as its fallback should it fail to load). Each one can be replaced by your own sound (see Extending).
- **Server-authoritative interaction.** Mining, placing and every inventory click are predicted on
  the client and validated by the server: timing, reach, what the player holds. Block updates power
  falling sand and gravel (which break into an item on a torch or a flower, Minecraft's torch
  trick), flowing water, lava, oil and fuel (Minecraft rules, including water's infinite sources
  and lava hardening against water), lava and burning, fire spreading and burning out, grass turning
  into dirt and plants popping off when their soil goes; random ticks spread grass, decay leaves,
  grow saplings and let lava light fires. The server keeps the chunks around every player
  generated on a generator of its own, a few milliseconds of each frame, closest first: no more
  frames lost to a whole chunk at once, and joins, teleports and flyers catch up about twice as
  fast (`/genstats` shows it).
- **Minecraft movement.** Players are a 0.6 × 1.8 block hull moved through the block data with
  Minecraft Java Edition's physics, tick for tick at 20 ticks per second: walking, sprinting
  (Ctrl toggles it, or is held with the Sprint setting on Hold; or double tap forward) with
  Minecraft's widening field of view (FOV and FOV Effects are settings) and view bobbing, sneaking
  (held, or toggled with the Sneak setting) that never walks off edges, crouching and crawling under low ceilings, 1.25-block jumps, sprint jumping, slippery
  ice, swimming (sprint under water or fuel, steered by the view), currents, wading through lava
  and oil (Minecraft's lava physics), hopping out of a fluid and fall damage. Steps up to just over
  a block are walked up without jumping, so the steep terrain is walkable
  (`Config.Movement.StepHeight`; Minecraft's is 0.6). The Roblox character is purely cosmetic: it is
  drawn on the hull (interpolated) and never collides with anything.
- **A camera in the manner of DayZ, and your own body in first person.** Third person looks over the
  right shoulder (or the left: the Shoulder setting) from a distance that follows what you do:
  closer with a weapon raised, further sprinting, closer in crouching, crawling, swimming or
  climbing, eased over DayZ's own blend times, the view lagging a jump. It never goes into a block,
  nor does the screen's near edge cut into one (sized from the camera itself: 0.1 studs ahead on a
  computer, up to 0.5 on a phone): a wall pulls it in at once and it eases back out, a wall beside
  it (a one-block tunnel) moves it off just enough, and from the eyes it comes back from a wall it
  would see through. `F5` (gamepad D-pad up, the touch VIEW button) puts the view at your eyes and
  back, never while a weapon is raised or a guard is up (DayZ's rule); `V` with a gun raised looks
  down the sights from the eyes in either view. The body faces where you aim, the upper body leading
  a turn on the spot, the legs twisting up to 45 degrees into a strafe and walking backwards for a
  backpedal, the feet stepping round on a quick turn (every client draws this for every player;
  nothing more is sent). Hold `Left Alt` (R3, the touch LOOK button) to freelook: the view turns up
  to 160 degrees each way (100 from the eyes: the head, then the waist) while you keep walking and
  aiming the same way, with no crosshair, mining, use or firing meanwhile, and swings back when you
  let go; a click or press as it swings back counts as soon as the view is within 2 degrees of your
  aim. Hold `Z` to focus your eyes (a 45-degree view, 70 sprinting; not raised). In first person you
  see your own body: the chest's edge, legs and feet when you look down (the eyes lean out past the
  chest, as a head does), the head, hair, hats, helmet, face and neck pieces hidden, and both your
  hands on a gun, as in DayZ: lowered, it is held on the body (a rifle across it, its muzzle to the
  left; a pistol low ahead on the right); raised, your cheek goes to the stock, the sights a few
  inches from your eye with their line on the view's axis, the upper body leaning in, both hands
  under the gun below its sights (a pistol two-handed too); a hand that can't reach, or whose arm
  would block the sights, lets go and its arm hangs. Tools, blocks, food and a punch swing in the
  right hand, both hands on a guarded weapon; an arm the camera would cut is hidden whole, never a
  hand alone; a scope hides the gun and the arms; an item that would reach into a wall is pulled
  back, then lifted (DayZ's weapon lift). Over the shoulder the crosshair (shown with the mouse
  locked too) picks only what your eyes can see: a block seen past a pillar picks the pillar, and a
  mob behind cover isn't hit; reach and the server are unchanged. The mouse wheel no longer zooms
  and there is no shift lock. On a touch screen VIEW and LOOK sit with Sprint, Sneak and a gun's
  FIRE, AIM and RELOAD, each in a place of its own round the jump button, on phones and tablets
  alike. First-Person Body OFF keeps Minecraft's hand; `Config.Camera.Enabled = false` puts back
  Roblox's camera as it was (shift lock included, the crosshair a gamepad's only).
- **Ladders, rope and climbing.** Minecraft 1.20.1's ladders and vines and Supplementaries' rope.
  A **Ladder** (seven sticks make three; it burns in a furnace like planks) goes on the wall you
  click, else the first wall the way you look; one clicked on the front of a ladder goes nowhere.
  Walk into a ladder or a vine to climb it at Minecraft's 2.35 blocks a second, let go to slide
  down at 3 a second without any fall damage, sneak to hold still (pushing on still climbs), and
  step off onto the ledge at the top. **Vines** (found, taken with Shears) climb the same; a vine
  also hangs under the same vine. **Rope** (three Straw in a column, or three String on a
  diagonal, make three) hangs under a solid ceiling or another rope: hold jump to climb it, let go
  to slide down in free fall that never hurts (Supplementaries' rope slide), sneak to hold on.
  Right click a rope holding Rope to let one more down from the bottom of the column, however far
  down that is (into air, plants or vines, never into water or a block); right click one with an
  empty hand to pull the bottom rope back up into your inventory (creative uses and gains
  nothing; adventure and spectator do neither). `Shift` + right click places Rope against the
  clicked face like any block. Breaking a rope (or burning it: it burns fast) brings every rope
  below it down, a block a tick, each dropping itself. **Cobwebs** hold whatever is in them: a
  quarter of the speed across, a twentieth up and down, momentum lost every tick and the fall
  forgotten (Minecraft's makeStuckInBlock); a sword cuts one quickly for String, Shears take the
  cobweb, a bare hand gets nothing; no player spawns or teleports into one (mobs may, as in
  Minecraft). Mobs climb ladders, vines and rope they
  walk into and get caught in webs.
  Climbing makes the ladder's, vine's or rope's own step sound every 1.67 blocks, the climb
  animation plays, and the `F3` overlay shows "climbing" and "stuck". Also: **Rails** (six iron
  ingots and a stick make 16, from the Iron Age) lie along the way you face; the **Oak Fence**
  (planks and sticks) is a post that reaches rails out to the fences and solid blocks beside it,
  changing as they come and go, and collides with its post and rails 1.5 blocks high as in
  Minecraft: you walk right up to a lone post, but nobody (you, mobs) gets through or jumps over a
  fence line, so pens hold their animals; **Moss Block**, **Moss Carpet** (two moss make three), **Hanging
  Roots** and **Mossy Cobblestone** (cobblestone and a vine or moss).
- **Doors.** Minecraft's wooden doors in oak, spruce, birch, jungle and acacia (six planks of a wood
  in two columns make three; 200 ticks of furnace fuel). A door is two blocks tall and goes on a
  sturdy block with room above. It faces the way you look, and its hinge goes against the side with
  more walls beside it, else away from a door already beside it, else on the half of the block you
  clicked (Minecraft's rules). Right click either half to open or close it, in every game mode but
  spectator (adventure players open doors, as in Minecraft); sneaking with an item in hand places
  instead. **Double doors:** two doors side by side facing the same way, hinged on their outer sides
  (place the second beside the first and it takes the other hinge), open and close together when you
  use either, as long as both are open or both closed. Doors of different woods pair too. A door is
  a 3 pixel panel: you bump into it closed and walk past it open, as mobs and dropped items do, and
  mobs can't see (or follow) you through a closed one, nor an explosion reach you behind it (zombies
  break one down in 12 s: see Zombies). Breaking either half breaks both and drops one door; a door
  whose block underneath goes pops off. Each wood has its own windows (oak two, birch four, jungle
  two small ones, acacia one, spruce none), drawn from boxes, see-through. Opening plays
  `block.wooden_door.open` and closing `block.wooden_door.close` (swap them like any sound below).
  Structures turn doors with them (a mirror swaps the hinge).
- **Water that finds the way down.** Like Minecraft, water spreads only towards the nearest drop
  up to 5 blocks away, so it runs down slopes instead of flooding the ground around it. Flowing
  water steps down level by level, and its current pushes the player downstream. Lava and oil head
  for a drop only up to 3 blocks away, fuel as far as water.
- **Minimap and world map.** Painted straight from the generator, so the map shows the whole world,
  oil geysers as black dots. Right click the map to add waypoints (saved between sessions),
  teleport, or center the view. The Minimap setting hides the minimap, which then costs nothing (on
  touch screens a small "Map" button takes its corner, to open the world map). `B` shows the
  weather over both (see The weather map). The minimap follows the GUI Scale setting like the rest
  of the HUD (see GUI scale).
- **GUI scale, Minecraft's way.** One scale for the whole interface: Auto is the largest scale that
  still leaves 320 x 240 GUI pixels on the screen (4 at 1920 x 1080, 6 at 2560 x 1440, 9 on a 4K
  window; eighths on touch screens: 1.5 on a small phone), and the GUI Scale button offers Auto
  and 1 up to that largest, so every choice looks different. The HUD, the quickbar, the inventory
  (a step smaller where its three columns need the room: 5 at 2560 x 1440, 8 on a 4K window)
  and every screen, the chat, the minimap (56 GUI pixels square: 224 pixels at 1080p, 84 on a
  phone) with its coordinates line, the toasts, the status effect icons, the saving icon, WAILA,
  the crosshair (Minecraft's plus) and the title screen all follow it; F3, the world map's bar and
  menus and the waypoint labels keep their 1080p look and grow on bigger screens. The top right
  corner is laid out as a whole (the minimap, then the toasts, then the effect icons; the saving
  icon above Roblox's jump button by its real size; on touch screens the effect icons stay out of
  the movement thumbstick's corner, the Map and cloud buttons take a finger-sized tap, and a toast
  with no room waits for it), so nothing there overlaps on phones and tablets, and the title
  screen keeps clear of Roblox's top bar (its pages keep the full scale while they fit: Auto 3 on
  a 1366 × 768 window).
- **Other players as the server tells them** (`Players.ServerPositions`, on). Each client
  draws only the players the server sends it (within `Interest.PlayerDistance`, spectators only to
  spectators), 0.1 s behind (`Interest.InterpolationDelay`) and gliding between their poses, a
  teleport as a jump; everyone else's character stays parked far above the world (a player who
  leaves your interest is put back there on your client too), hidden whole, with no name, held
  item, flames, glow or minimap dot. A dead player tips over as in Minecraft and is gone after a
  second. Your own moves go to the server 20 times a second; its teleports and
  corrections snap you as before. F3 shows the true coordinates and, under them, the render
  origin (`origin` line: where it is, its moves and the last one's cost) and the players tracked.
  Off, other players are their characters, as before.
- **Safe spawns.** Spawns and teleports never land in water, lava, oil, fuel or fire, on leaves or
  next to cacti, lava or fire; the rules live in `SpawnUnsafeBlocks`.
- **A texture pack.** Every block texture is in one module, `src/shared/TexturePack.luau`, like a
  Minecraft resource pack: 512 × 512 images, one per 3-stud block face, drawn as MaterialVariants
  and face images that take each block's own colour (one bark image for every log, each in its
  wood's colour), plants as crossed images. The 53 textures made so far are in (the roads,
  concrete, aged bricks, stones, moss, vines, the supply crate and the medicine cabinet the latest),
  and 82 blank entries wait for the rest (the apocalypse's rusty metal, bunker hatch and items
  among them, blank on purpose).
  Distant chunks take the colour each block averages to on screen, so they match the textured
  terrain near you, or keep their materials and textures with the Far Materials setting. See
  Block textures.
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
- The project puts an `Atmosphere` and a `Sky` in Lighting (a new place's template has both, under
  the same names, so `rojo serve` updates them). IceVoxel drives the first Atmosphere in Lighting
  (it makes "IceVoxelAtmosphere", and "IceVoxelSky", when there is none; a second Atmosphere is
  taken out). Roblox ignores an Atmosphere without a Sky, and ignores `FogStart` / `FogEnd` while
  an Atmosphere is in Lighting. The project's Atmosphere carries the attribute `IceVoxel` = true:
  with `Lighting.Enabled` false the client takes that one out (an unmarked one is the place's own
  and stays). Judge the haze in the Roblox player too: F3's `fog` line shows the Atmosphere's
  density and how far it hazes things 90%.
- How far parts are drawn is up to the engine, not the script: it depends on the graphics quality
  level and how many objects are on screen. Studio ignores that limit, so judge long views in the
  Roblox player with a high graphics level. Phones draw far less (a few hundred studs), which is why
  they start on the Low preset, with a shorter view distance (`Lod.Mobile`).

## Controls

Every key and mouse button in the "Mouse / keyboard" column is a key binding, as in Minecraft:
Options (`P`) > Controls > Key Binds changes them (see Settings menu); the table shows the
defaults. Escape, `Shift` / `Ctrl` with clicks, the mouse on inventory slots, the second key of the
`F3` combinations and every gamepad and touch control are fixed.

| Action        | Mouse / keyboard            | Gamepad | Touch      |
| ------------- | --------------------------- | ------- | ---------- |
| Break block   | Hold left click (survival mines, creative breaks at once; adventure and spectator break nothing) | R2 | Hold |
| Attack a mob  | Left click a mob in reach (3 blocks, creative 6; it hides the block behind it): one hit a click, with the held weapon (a melee weapon of the Weapons: the hit lands when you let go; a lowered firearm bashes) | R2 | Tap the mob (a firearm's tap does nothing) |
| Heavy attack (melee weapon) | Hold left click on a mob 0.45 s or more, then let go: a heavy attack (twice the knockback, three times the food) | Hold R2 | Hold still on the mob (about 0.75 s) |
| Guard (melee weapon) | Hold right click with a melee weapon (not on a block with a menu, unless sneaking): a zombie's hit from the front is cut by the weapon's share; half speed, no sprint, no attacks | Hold L2 | |
| Raise a firearm | Hold right click with a firearm (not on a block with a menu, unless sneaking): over the shoulder in third person (closer in), down the sights in first person; let go to lower | Hold L2 | AIM (toggles) |
| Fire          | Left click with a raised firearm, once it has been up about 0.3 s: a semi-automatic once a click, an automatic while held; empty: a dry click, jammed or Ruined: a jam click | R2 | FIRE (hold) |
| Sights        | `V` (the Toggle Sights key binding) with a firearm raised in third person: down the sights and back | R3 | |
| Hold breath   | Hold the sprint key in the sights: 3 s of a steady aim, then 3 s out of breath | L3 | |
| Reload / clear a jam | `R` (the Reload / Clear Jam key binding): the fullest magazine you carry and a round chambered, or a round at a time into an internal magazine; a jammed gun's stuck round out | X | RELOAD |
| Fire mode     | `F` (Fire Mode): single shots or automatic (the SMG, the Assault Rifle) | D-pad right | |
| Weapon light  | `L` (Weapon Light): the mounted Weapon Flashlight on or off | D-pad left | |
| Load a weapon (inventory) | Drop rounds on a magazine or a gun (left click all that fit, right click one), a magazine or an attachment on its gun; right click a gun or a magazine with nothing carried to take one thing out; click a chip beside HANDS to take that part off (the gun in hand comes down, and loading it takes as long as `R`) | A / X | tap / long press |
| Eat / use medicine | Hold right click with food or medicine (meat and tins 1.6 s, crackers and the chocolate bar 1.2 s, the Bandage 2 s, the Medkit 4 s, pills 1.2-1.6 s, the ration 2.4 s) when it would do something: food while the food bar isn't full (hurt, with hunger off), medicine when hurt, bleeding or infected (the Chocolate Bar any time; creative: any time); letting go stops | L2 | Tap |
| Place / use   | Right click (opens chests, crafting tables, furnaces, machines; adventure and spectator only open them) | L2 | Tap |
| Open a door   | Right click either half (and a double door's other door opens with it); `Shift` + right click with an item places instead | L2 | Tap |
| Open a hatch  | Right click a Bunker Hatch, from above or from the ladder below, to open or shut it (every game mode but spectator; zombies hear it) | L2 | Tap |
| Select slot   | `1`–`9`, mouse wheel (unless the Scroll Wheel setting is Zoom, which zooms nothing with the DayZ camera: the wheel never zooms), or click a slot while the mouse is free (with the DayZ camera the mouse is locked while you play, so with the chat open; spectator: the spectator menu) | L1 / R1 | Tap a slot |
| Place a torch / lantern | Right click: the top of a block stands it, a side hangs a wall torch, the underside hangs a lantern | L2 | Tap |
| Climb         | Walk into a ladder or vine, or hold `Space` on a rope or a hanging vine (2.35 blocks a second); let go to slide down (a rope: a fast slide that never hurts); hold `Shift` to hold still | stick / A; B holds | move / Jump; Sneak holds |
| Rope          | Right click a rope with Rope: one more at the bottom of it, however far down; with an empty hand: pull the bottom one up (held, it repeats); `Shift` + right click with Rope places it against the face | L2 | Tap |
| Configure a pipe | Right click a transmitter's arm or core face with the Configurator: normal → push → pull → none (Universal Cables only tell none apart); `Shift` + right click a transporter: next colour | L2 | Tap |
| Flint and Steel | Right click a face: fire in front of it where fire can burn; break a fire (left click) to put it out | L2 | Tap |
| Buckets       | Right click a source (water, lava, oil, fuel), a Fluid Tank or a machine with a bucket to fill it; right click a block, tank or machine with a full bucket to empty it (a machine whose tanks can't take or give a bucket opens its screen; `Shift`: into the world, past tanks and machines) | L2 | Tap |
| Structure / jigsaw block (creative) | Right click: its screen; `E` / `Escape` close it (Cancel), Done keeps the fields; click the saved data box, then `Ctrl` + `C` (`Cmd` + `C`) copies it | L2; B closes | Tap |
| Place a jigsaw | Right click a face: the jigsaw faces out of it (on a top or bottom face, its top points back at you) | L2 | Tap |
| Drink / fill  | Right click a water source with an empty hand: a sip; with a Glass Bottle, a Bowl or a canteen: fill it; hold right click with a filled bottle, bowl or canteen, a tea or a potion for 1.6 s: drink it (letting go cancels; Tough As Nails) | L2 | Tap |
| Boil water    | Right click a Campfire with a dirty water bottle, bowl or canteen: one boils clean (not sneaking; Tough As Nails) | L2 | Tap |
| Cast magic    | Hold right click with a magic weapon (Wand of Sparking, Emerald Staff, Water Bolt): a cast every use time along the crosshair, while you have the mana (creative: free); a block with a menu still opens first | Hold L2 | Tap, or hold on the target |
| Mana Crystal  | Right click with a Mana Crystal: +20 max mana for good (nine at most) | L2 | Tap |
| Pick block    | Middle click (spectator: the spectator menu) |  |      |
| Drop item     | `Q` (`Ctrl` + `Q`: the whole stack; not while `F3` is held) | D-pad down |    |
| Inventory     | `E` (creative: the item picker; spectator: none) | Y   | `…` button |
| Fly (creative) | Double tap `Space`; `Space` / `Shift` up / down | double tap A | double tap jump |
| Fly (spectator) | Always, through blocks; `Space` / `Shift` up / down, sprinting (`Ctrl`) twice as fast; mouse wheel (spectator menu closed): flying speed | A / B | Jump / Sneak |
| Spectator menu | `1`–`9` or middle click open it, then a number selects and the same number again (or middle click) uses; the wheel moves the selection | L1 / R1 open and move, D-pad up uses | `…` button; tap a slot |
| Spectate a player (spectator) | Left click them; `Shift` leaves | R2; B leaves | Hold on them; Sneak button leaves |
| Chat          | `T` opens the chat, `/` opens it with "/" typed (the Open Chat and Open Command key bindings); `Enter` sends, `Escape` closes, `Up` / `Down` what you sent (or the highlighted suggestion), `Tab` completes command names, `/locate`'s arguments and players' names (`Shift` + `Tab` back), the wheel (`Shift`: a line at a time), `Page Up` / `Page Down` scroll; click `/locate`'s green coordinates to type their `/tp` | | Speech bubble over the `…` button; tap the coordinates |
| Game mode     | `/gamemode survival` / `creative` / `adventure` / `spectator` (or `/gm s` / `c` / `a` / `sp`, `0`–`3`) in the chat; `F3` + `N`: spectator ↔ the previous mode | | |
| Game mode switcher | Hold `F3`, press `F4` (each further `F4`: the next mode; or point at one), let go of `F3` to switch; `Escape` cancels | | |
| Sprint        | `Ctrl` turns it on / off (held instead with the Sprint setting on Hold), or double tap `W` | L3 (stick press) | Sprint button (toggle) |
| Sneak         | Hold `Shift` (never walks off edges; turned on / off instead with the Sneak setting on Toggle) | B | Sneak button (toggle) |
| Jump          | `Space` (hold to keep jumping) | A    | Jump button |
| Swim up / down | Hold `Space` / `Shift` in water or fuel (in lava and oil `Space` rises slowly; there is no swimming) | A / B | Jump / Sneak |
| Swim fast     | Sprint under water or fuel; look where to go | L3 | Sprint button |
| Climb out     | Swim (or wade) at a ledge just above the surface | stick | move |
| In the inventory | Left / right click, `Shift` + click, `1`–`9` swap with the quickbar, `Q` drop, double click to collect, drag to spread; drop a carried stack on the GROUND strip or outside the screen to throw it; click a section's bar (CRAFTING, the block's, ITEMS, BACKPACK, VANITY) to fold or unfold it | A / X / Y, B closes | tap / long press; tap a section's bar |
| Equipment (inventory) | `Shift` + click an accessory, armor or vanity piece to wear it; click an eye to hide or show that look | Y on a piece; A on an eye | Tap (the eyes have finger-sized buttons) |
| Air jump      | `Space` again in mid-air, wearing a Cloud in a Bottle | A | Jump button |
| Recipes / uses (JEI) | Click / right click an item in the list, or `R` / `U` over any item; `Backspace` back, `E` / `Escape` back to the inventory | A / X on a list item, B leaves the recipes | Tap / long press |
| Move a recipe (JEI) | `+` beside a crafting recipe (`Shift`: as many as possible) | A | Tap |
| Full stack (JEI, creative) | `Shift` + click or middle click an item in the list | Y | |
| World map     | `M`, or click the minimap   |         | Tap minimap (or the Map button while the Minimap setting is off) |
| Weather map   | `B` (the Weather Map key binding), or the ☁ button on the minimap or the world map: the weather over both maps; on the world map, Now / +2 / +5 / +10 / +20 min along its bottom forecast it | | Tap ☁ on the minimap or the world map |
| Map menu      | Right click the map         | R3      | Long press |
| Minimap zoom  | `-` / `=`                   |         |            |
| Options menu  | `P` (`P` again, `E`, `Escape` or Done close it), or the gear in the inventory's EQUIPMENT header | D-pad right; B closes | Gear at the left end of the quickbar |
| Walk          | `W` / `S` / `A` / `D` (Roblox's arrow keys no longer walk: bind them if you like) | left stick | thumbstick |
| Toggle Perspective | `F5` (the Toggle Perspective key binding): the view over the shoulder or from your eyes; not while a weapon is raised or a guard is up, nor for spectators (always from the eyes). Shift lock is gone with the DayZ camera: the mouse is locked while you play and freed by every screen | D-pad up | VIEW (not for spectators) |
| Freelook      | Hold `Left Alt` (the Freelook key binding; with the Freelook setting on Toggle, press it to start and again to stop): the view turns up to 160° each way (100° from the eyes) while you walk and aim the same way; no crosshair, mining, use or firing meanwhile; let go and it swings back, and a click or press made as it does acts once the view is within 2° of your aim. Not in the sights | Hold R3 (while nothing is raised: R3 is the sights then) | Hold LOOK (not for spectators) |
| Focus         | Hold `Z` (the Focus key binding): the eyes focus, a 45° view (70° sprinting) and a slower mouse; not while a weapon is raised or guarding | | |
| Chat / command | `T` / `/` (the Open Chat and Open Command bindings) | | |
| Skill tree    | `K` (`K` again, `E`, `Escape` or Done close it): click a skill, then Unlock; hover an Age's name for what it takes | D-pad left; A selects, B closes | The button over the gear |
| Debug overlay | `F3`, when let go (also WAILA's extended view); not after a combination such as `F3` + `N` | | |
| Debug keys    | `F3` + `Q` lists them in the chat (`F3` + `N`, `F3` + `Q`, `F3` + `F4`) | | |
| Time          | `/time set day` (`noon`, `night`, `midnight`, `6000`, `0.5d`), `/time add 1000`, `/time query daytime`; `/gamerule doDaylightCycle false` stops the clock (operators). `/time set` keeps the season; `/time add 8d` moves it on | | |
| Seasons       | `/season query` (anyone): "It is Winter, day 3 of 8 (6 days left), year 1"; `/season set winter 3` (`autumn` or `fall`, `winter`, `spring`, `summer`, an optional day) keeps the time of day; `/gamerule doSeasonCycle false` holds the season (operators) | | |
| Thermostat    | Right click an Electric Heater, Air Conditioner, Electric Fan or Oil Heater: `-` / `+` move its set point (-5..5, "Set +1"), On / Off switches it; the Wood Stove's On / Off holds its fuel | A on a button | Tap a button |
| Weather       | `/weather clear`, `/weather rain`, `/weather thunder` with an optional duration (`300s`, `0.5d`, `6000` ticks; default Minecraft's random one: rain 10-20 minutes, thunder 3-13, clear 10-150), everywhere, blending in over 5 s (operators); `/weather query` (anyone) says what it is doing where you stand; `/gamerule doWeatherCycle false` stops the storms and holds the override's time (operators) | | |
| Mobs          | `/summon zombie` (at your feet) or `/summon zombie_brute ~ ~ ~5`: every kind in snake case (`cow`, `sheep`, `pig`, `chicken`, `zombie`, `zombie_runner`, `zombie_brute`, `zombie_crawler`, `zombie_screamer`, `zombie_soldier`, `zombie_police`, `zombie_firefighter`, `zombie_worker`, `zombie_doctor`); `/kill @e[type=zombie_brute]`, `/kill @e` (every mob) (operators) | | |
| Locate        | `/locate structure outpost` (or `city`, `bunker`, `#ruins`, `#mineshaft`, `mineshaft_entrance`, `oil_geyser`, `lava_lake`, `ravine`...), `/locate biome jungle` (or `#is_forest`...), `/locate poi chest` (or `medicine_cabinet`, `supply_crate`, `bunker_hatch`, `#scavenge`, `#machine`...) (operators); the answer's green coordinates type their `/tp` when clicked | | |
| Teleport      | `/tp 100 64 -20`, `/tp ~ ~ ~10`, `/tp <player>`, `/tp <players> <x> <y> <z>`, `/tp <players> <player>` (also `/teleport`; players are names, their start, `@s` or `@a`) (operators) | | |
| Status effects | `/effect give @s speed 60 1` (`<player>` a name, `@s`, `@p` or `@a`; seconds 1-1000000 or `infinite`, default 30; amplifier 0-255), `/effect clear [player] [effect]` (operators); the apocalypse's: `/effect give @s bleeding 20`, `/effect give @s infection 60` (starts an infection, or takes one 60 s on), `/effect clear @s infection` (cures it); hover or tap an effect icon for its name and time | | Tap an icon |
| Knowledge and Ages | `/knowledge add\|set <player> <amount> [points\|levels]` (also `/xp`), `/knowledge query <player> [levels]`, `/age set <player> <age>` (`iron`, `Iron Age`, `2`), `/age query <player>`; players are names, `@s` or `@a`; changing needs an operator, as `/time` (where progress is saved for every server: `Gameplay.Admins`, the owner or Studio) | | |
| Generation    | `/genstats` (operators): the server's background chunk generation over the last 10 s (chunks/s, ms/s, the worst frame), the backlog and the chunks generated inline | | |
| Saving        | `/save-all` (save now: "Saving the game (this may take a moment!)", then "Saved the game"), `/save-off` (no automatic saves until `/save-on`; shutdown still saves), `/save-on` (operators only); the saving icon shows bottom right while the world saves | | |
| Operators     | `/op <player>`, `/deop <player>` (operators only; a name, its start, `@s` or `@a`). Until the world exists (with the title screen and `MainMenu.AutoOperator`) the first player to join is the operator, and when the last operator here leaves the player here longest becomes one (`/deop` never takes the last one here then); after that nobody becomes one by being here (the first operator stays one). `Gameplay.Admins`, the game's owner and everyone in Studio always are. With the world's Allow Commands on, everyone may use the operators' commands (`/gamemode` for others, `/time`, `/gamerule`, `/effect`, `/summon`, `/kill`, `/knowledge`, `/age`, structure blocks) | | |
| Title screen  | Click the buttons (Play, Options...; then Join World, Create World, Load World once a character is chosen; with `Characters.Enabled` off the title has those at once); `Escape` goes back a screen (the character list, the avatar editor, the world page, Create World, Customize, Load World, its Delete and Rename, Options); in Select Character click a character to see it, double click to play it; in the avatar editor drag the character to turn it; in Load World click a world to select it, double click to play it | A; B goes back | Tap; drag to turn |

## Settings menu

`P` opens Minecraft's Options screen (gamepad: D-pad right; touch: the gear at the left end of the
quickbar; anywhere: the gear in the inventory's EQUIPMENT header). Changes
apply while you play: cheap ones at the next frame, costly ones (view, caves, plants, shadows,
textures, far materials, far meshes) 0.4 s after a slider stops (`Settings.ApplyDelay`), so
dragging a slider rebuilds the world once. Sliders move by dragging, clicking, the D-pad (left /
right) or A; buttons cycle their values. Done (on a sub-page: back to the page it came from), `P`,
`E`, `Escape` or gamepad B close it, which applies whatever still waits and saves.

| Page            | Settings |
| --------------- | -------- |
| Options         | Graphics (the preset: Low / Medium / High / Ultra, "Custom" once a value it sets is changed), FOV (30-110, Minecraft's 70 "Normal" by default); the pages below; Reset (the current preset's values again), Defaults (every setting back to this device's defaults, key bindings included) |
| Video Settings  | Render Distance (256-4096 blocks, phones at most 1024), Detail Falloff (2-4), Full Detail (48-160 blocks, at most what the falloff allows), Cave View (64-176 blocks), Plant Distance (OFF, 8-64), Lichen Lights (16-128 blocks or All), Shadows, Far Shadows, Fog (Atmosphere / OFF), Textures (when the texture pack has a filled texture), Far Materials (where far meshes run), Brightness (Moody to Bright), Prefer (Distance / Lighting), Caves (Hidden Until Seen / Always Shown) |
| Performance     | Far Meshes (with their state), Build Budget (Auto or 1-12 ms), Hidden Terrain (Draw / Skip), Swap Frames (0-3) |
| Music & Sounds  | Master Volume, Music, Blocks, Players, Ambient, Interface (0-100%); Footsteps, Interface Clicks, Cave Moods, Music Toasts |
| Controls        | Mouse Settings..., Key Binds... (the two pages below), Sneak (Hold / Toggle), Sprint (Toggle / Hold), Camera (Third Person / First Person), First-Person Body (ON / OFF), Shoulder (Right / Left), Freelook (Hold / Toggle), Touch Buttons (touch screens; Sprint and Sneak after rejoining, the camera's VIEW and LOOK at once) |
| Mouse Settings  | Sensitivity (0-200%: "*yawn*" to "HYPERSPEED!!!", 100% Roblox's own feel), Scroll Sensitivity (0.01-10.00), Invert Mouse, Discrete Scrolling, Scroll Wheel (Hotbar / Zoom: nothing with the DayZ camera, which has no zoom); with a mouse |
| Key Binds       | Every key binding (below): click its key, then press a key or a mouse button; Reset (per row), Reset Keys (all); with a keyboard |
| HUD             | Minimap, WAILA, Day Counter (the day, the days survived and the blood moon's warnings under the minimap), Season Clock (the year's dial beside the minimap), Attack Indicator (OFF / Crosshair / Hotbar), GUI Scale (Auto, 1 .. the largest this screen allows: 4 at 1920 x 1080, 9 on a 4K window; Auto is always the largest, as in Minecraft) |
| Chat Settings   | Chat (Shown / Commands Only: no players' messages, and none sent / Hidden: no chat at all), Chat Text Opacity (10-100%), Text Background (0-100%), Text Size (OFF, 1-100%), Line Spacing (0-100%), Chat Delay (None, 0.5-6 s: other players' messages come out one per delay), Width (40-320 GUI pixels), Focused Height and Unfocused Height (20-180), Command Suggestions |
| Accessibility Settings | View Bobbing, Distortion Effects (0-100%), FOV Effects (0-100%), Damage Tilt (0-100%) |
| Weather         | Clouds (OFF / Fast / Fancy), Weather (rain and snow: OFF / Fast / Fancy) |

Key Binds is Minecraft's list: a row per action under its category, the action's name, its key
and Reset (back to the default, greyed when it is). Clicking a key shows `> W <` in yellow and
waits: the next key or mouse button pressed becomes the binding (clicking anywhere binds that
mouse button, as in Minecraft); Escape makes it "Not Bound" (Minecraft's; Roblox opens its menu
too, close it again); a gamepad's B leaves it as it was. A key used by two actions that can
happen at the same time shows red in brackets (`[ Q ]`), Minecraft's warning: only one of them
may act on it (Sprint and Sneak take their key from every other action, and Sprint and Sneak on
one key leave just one of them); keys that only work in different places don't clash (JEI's
keys work in the inventory, the movement keys outside it). The wheel or the bar on the right
scrolls the list. Bindings are saved with the other settings (only those changed from their
default).

| Category | Key binding (default) |
| -------- | --------------------- |
| Movement | Jump (`Space`), Sneak (`Left Shift`), Sprint (`Left Control`), Strafe Left (`A`), Strafe Right (`D`), Walk Backwards (`S`), Walk Forwards (`W`) |
| Gameplay | Attack/Destroy (left button), Fire Mode (`F`), Focus (`Z`), Freelook (`Left Alt`), Pick Block (middle button), Reload / Clear Jam (`R`), Toggle Sights (`V`), Use Item/Place Block (right button), Weapon Light (`L`) |
| Inventory | Drop Selected Item (`Q`), Hotbar Slot 1-9 (`1`-`9`), Open/Close Inventory (`E`) |
| Multiplayer | Open Chat (`T`), Open Command (`/`) |
| Miscellaneous | Debug Screen (`F3`; its combinations become that key + `N` / `Q` / `F4`), Options (`P`), Skill Tree (`K`), Toggle Perspective (`F5`) |
| Map | Minimap Zoom In (`=`), Minimap Zoom Out (`-`), Weather Map (`B`), World Map (`M`) |
| Just Enough Items | Recipe Back (`Backspace`), Show Recipe (`R`), Show Uses (`U`) |

The other new options, each Minecraft's:
- Sensitivity scales the mouse's turning with Minecraft's curve ((0.6 s + 0.2)³ × 8, so 100% is
  Roblox's own speed, on top of Roblox's camera sensitivity). Invert Mouse turns the mouse's
  vertical look round (not a gamepad's stick or a touch drag); it needs Roblox's camera scripts,
  and the page says so when they are missing.
- Scroll Sensitivity and Discrete Scrolling: the wheel's turns add up (scaled; Discrete: a notch
  is a notch, however fine the wheel or trackpad) and each whole step moves the quickbar one slot
  (also the spectator menu and flying speed); open screens scroll by the scaled turn.
- View Bobbing: the camera sways and dips while walking on the ground (Minecraft's bob, about a
  tenth of a block). Damage Tilt: the camera tilts up to 14° for half a second when hurt.
  Distortion Effects: how much of Nausea's wobble shows (squared, as Minecraft's: 50% is a
  quarter); FOV Effects now only scales the flying, sprinting and Speed widening.
- Attack Indicator: while the held weapon recovers after a hit (its attack speed: a sword in 0.6
  s, an axe in 1-1.25 s), a bar under the crosshair (or the mouse, while it is free) or a quickbar
  cell left of the quickbar (right of the `…` button on touch) fills up.
- Sneak: Hold (Minecraft's default) or Toggle.
- Clouds and Weather (Minecraft keeps Clouds on its Video Settings, which is full here, and draws
  rain and snow by its Graphics setting): Fancy clouds are boxes with storm towers and rain
  shafts, Fast a flat layer of bigger cells; Fancy rain and snow fall within 10 blocks, Fast
  within 5. OFF draws none; the sounds, the darker light and the haze stay. Distant storms'
  lightning follows Clouds: Fast caps them at half as many a minute (12, which only a busy sky
  reaches) and shows fewer bolts at once, OFF none (the server's real strikes still show). The Low preset (phones) sets both to Fast, the others
  to Fancy.
- Toggle Perspective is Minecraft's key (`F5`) on DayZ's two views (over the shoulder and from
  the eyes; the sights are `V`). The camera's own settings, on Controls, are DayZ's: Camera (the
  view you start in; `F5` switches it while you play), First-Person Body (ON: your body, arms and
  what you hold in first person; OFF: Minecraft's hand), Shoulder (the side the third-person
  camera looks over) and Freelook (Hold, or Toggle: DayZ's Lock Freelook).
- Not here: Auto-Jump (the 1 1/16-block step height already walks up blocks without jumping),
  Hide GUI (the game has no such key), Show Subtitles.

Status lines say what the terrain is doing ("Updating terrain: 120 queued, 34 building") and, on
the Performance page, the far meshes' state. A few notes on what the settings do:
- Full Detail is held at most at the detail falloff plus one (96 blocks with a falloff of 2, 128
  with 3), so the levels of detail stay 2:1 balanced; lowering the falloff pulls it down.
- Cave View is how far big caverns are seen; tunnels follow in proportion (88 blocks at 128, 64
  at 96, 96 at 144), and so does full detail underground (about the cave view, at most what the
  falloff allows).
- Caves: Hidden Until Seen draws a cave once you can see into it from underground (above);
  Always Shown draws every cave within full detail, about 4 × the parts of nearby terrain (see
  Caves always shown in Features). No preset changes it.
- Every setting has a tooltip (what it does, its cost: "May lower performance" on the heavy
  ones), and every other menu button a description: rest the pointer on it, select it with a
  gamepad, or hold a finger on it on a touch screen (`client/Ui/HoverTip`; the texts are in
  `client/Ui/ButtonHelp`, easy to edit).
- Fog: Atmosphere fades the far land and clouds into the sky (much thicker in rain, snow and storms, with a
  haze along the horizon); OFF clears the Atmosphere (density and haze 0), a clear view to the
  edge. Water, lava, oil, fuel and Blindness keep their fog either way. In a place that keeps its
  own lighting (`Lighting.Enabled` false) with its own Atmosphere it reads "Place's Own"; without
  one (the project's is taken out then) it switches the old view fog.
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
| Low    | 512 / 2 / 64 blocks             | 96        | plants 24, no shadows, hidden terrain skipped, Fast clouds and weather | 13.8k (9.1k + 14 meshes) | 29.0k (16.6k + 16)  |
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

With characters (`Characters.Enabled`, the default) the title has **Play** and **Options...**;
Play opens **Select Character** (Terraria's player select, in Minecraft's widgets):

- **The list**: your characters, last played first, each with its name in its difficulty's
  colour (white Classic, blue Mediumcore, red Hardcore, gray once dead) and its difficulty, time
  played and the day it was last played. Click one to see it on the right (drag it to turn it);
  double click plays it. A red line says when characters last for this session only.
- **Play Selected Character** loads it (another server that still has it open is waited for up to
  30 seconds, then "open on another server") and goes on to the world page. A dead Hardcore
  character can't be played, only deleted.
- **Create New Character** opens the avatar editor: your own avatar on the left (drag to turn
  it), tabs **Skin** (the part to paint, twelve skin tones, hue and brightness, Randomise),
  **Body** (height, width, depth, head, body type, proportion; Reset), **Clothing** ("Blocky
  body" and a toggle for each of your own accessories, clothes, body parts and animations) and
  **Presets** (Classic, Natural, My Avatar), then the name (1 to 20 characters, filtered as
  everyone sees it) and the difficulty (Classic, Mediumcore, Hardcore). **Create** makes it and
  goes on to the world page. Only your own avatar's things can be worn: the server keeps its own
  copy of your avatar and never takes an item from the client.
- **Rename** and **Delete** (after "Are you sure you want to delete this character?"), **Back**.

The world page says "Playing as <name>" over the buttons below (and Back to the list). Once you
enter a world your character is yours for the visit: to play another, leave and rejoin.

- **Join World** enters the world once it exists; the terrain then loads around the spawn as on
  any join.
- **Create World** is the operator's (the first player to join the server), while no world exists.
  Everyone else reads "Waiting for <operator> to create the world..." until it does. Its two tabs,
  as Minecraft 1.20's: **Game** (World Name; Game Mode: Survival, Creative or Adventure, the mode
  new players get; Difficulty: Peaceful spawns no monsters, harder ones spread fire a little
  faster; Allow Commands: everyone may use the operators' commands, switched on with Creative
  unless you set it yourself) and **World** (World Type: every world type the game has, the
  debug worlds last, with its description, and **Customize** when the type declares settings:
  Single Biome's biome, Superflat's preset with Minecraft's flat presets on a button and what is
  wrong with a preset typed in shown in red, its Trees and Plants, and Ruins (overgrown cities,
  roads and bunkers; on) for Default, Single Biome and Large Biomes; the seed: a number is used as
  it is, any other text becomes Minecraft's number for it (Java's `String.hashCode`, so "glacier"
  is 108181935), blank is random; Generate Structures, greyed out for types without library
  structures). Picking a debug world picks its game mode too (All Blocks: Spectator, as
  Minecraft's debug world; All Structures and All Biomes: Creative), and the mode you had comes
  back on the other types unless you chose one meanwhile. **Create New World** sends it to
  the server, which checks it again (only the operator, only once, known types and modes, at most
  32 characters of name and seed; the name goes through Roblox's text filter, as everyone sees
  it), creates the world and puts you in it.
- **Load World** is the operator's too, while no world exists, where worlds can be saved (a red
  line under the buttons says why not: Studio without API access, saving off): Minecraft's
  Select World screen lists your saved worlds (the ones you created; the game's own people see
  the game's too), last played first, three lines each (the name; its
  type and when it was last played; its game mode and size). Click one to select it (double click
  plays it), then **Play Selected World** ("Loading world: 12 / 40" on every title screen while
  its keys are read; then everyone may join), **Rename** (the name goes through the text filter)
  or **Delete** (after Minecraft's "Are you sure you want to delete this world?" / "'Name' will be
  lost forever! (A long time!)"). A world another server has open can't be loaded or deleted; one
  that can't be read whole says why and is left as it was. A created world is saved at once, so
  it is in the list from then on. Joining a saved world puts each player back where they left,
  with what they had; a player new to it starts at the spawn.
- **Options...** opens the Options menu (the same as `P` in the game); Done comes back.

The world's name, type, difficulty and seed show in `F3`. Without the title screen
(`MainMenu.Enabled = false`) the server makes the world at once from `World` and `Seed` (and the
world type's own game mode, if it has one). The world type's hints apply when the world starts:
the void and the debug worlds spawn no mobs, All Blocks and All Structures have no block updates
or random ticks; Peaceful spawns no monsters in any world.

## Project layout

```
src/shared   -> ReplicatedStorage.IceVoxel          (used by server, client and worker actors)
  Config                    every tunable setting
  Content/                  content packs: the loader (discovery, order, ids, overrides, kind
                            folders, every check), Schema (each kind's fields and types), Define
                            (the helpers packs share: models, tools and armor, fluids, plants,
                            doors, recipes, metal()), Packs/ (Core, Minecraft, Mekanism,
                            Survival, Terraria, Apocalypse, Turrets, Ores: every block, item,
                            recipe, texture and loot table)
  Blocks/  BlockList        the block registry (BlockList: the packs' blocks, merged) -> ids,
                            appearances, lookup tables (hardness, tools, drops, menus, how long
                            zombies take to break them), plants (soil sets, tall halves, foliage
                            tints), each block's textures per face from the pack
                            (`variantTexture`, `alignLut`); Toggles (blocks a use swaps: the
                            bunker hatch)
  TexturePack               the texture pack: every block texture (maps, Material, Tint, Average)
                            and the texture of each block's faces, from the packs' textures
  Items/                    the item registry, stacks and item data (validation, tooltip lines,
                            Mekanism's energy and fluid formats, what a full bucket leaves);
                            ItemList (the packs' items that are not blocks, merged); Tooltip
                            (every line of an item's tooltip) and LoreList (the lore lines no
                            entry carries yet)
  Fluids/  FluidList        the fluid registry: water, lava, oil and fuel by id (0 none .. 4 fuel),
                            their blocks and cave twins, buckets, colour, light, movement, harm,
                            furnace fuel, fog and bucket sounds
  Fire                      fire's shared rules (Minecraft's FireBlock): survival, ignite odds,
                            the sides it clings to, its outline and planes, the animation frames
  Rope                      using rope on rope (Supplementaries): the column's bottom, where one
                            more goes, which one an empty hand pulls up, what a use does
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
                            Combustion, the Combustion Generator; the seasons' Stove, the Wood
                            Stove; OilHeater; Heater, the Electric Heater; Cooler, the Air
                            Conditioner and the Electric Fan; Turret, the twelve turrets; Miner,
                            the Metal Miner; AmmoPress, the Ammo Press), MinerRules (the Metal
                            Miner's ores, their drops and numbers, its state code)
  Crafting/                 Recipes (the packs' recipes, merged: shaped, shapeless, smelting and
                            fuel; a recipe may keep an ingredient's data), Crafting (grid
                            matching), Smelting (the furnace tick; the Lava Bucket's burn time)
  Inventory/                Types (inventory, window, action shapes; Terraria's equipment stores
                            and hide bits), Menu (Minecraft's inventory clicks and the equipment
                            slots' rules, used by the server and for client prediction)
  Structures/               structure blocks' data and jigsaw structures: Template (the IVS1
                            text, SAVE's capture, ASCII tables), Settings (structure block and
                            jigsaw fields, ranges, wire format), Transform (rotation and mirror),
                            Jigsaw (Minecraft's JigsawPlacement), Library (templates, pools and
                            generated structures from the modules below and the place)
  StructureLibrary/         the structure library: Templates/ (IVS1 modules; Outpost, the
                            example), Pools (explicit template pools), Structures (what generates)
  Entities/ItemPhysics      dropped item movement (server and client; floating in water and fuel,
                            in lava and oil)
  Entities/MobList          mob kinds: the farm animals and the ten zombie kinds (Minecraft's
                            boxes, health, speeds, loot, spawn weights in the wild, in cities and
                            in hordes, sounds, the zombies' abilities, their R15 rigs and looks);
                            MobShape (where a kind is drawn: the R15 proportions and stances the
                            rigs are drawn and bullets' head boxes sized by);
                            MobPhysics (a mob's movement tick: walking, jumping, fluids, ladders
                            and walls, cobwebs, falls);
                            Combat (players hitting mobs: weapon damage, attack strength, reach,
                            knockback, wear)
  Items/Foods               food and medicine (Minecraft's nutrition and saturation, healing
                            with hunger off and for medicine, use times, cures, effects, the
                            Hunger and Thirst effects' odds, who may use one, what finishing one
                            does), raw to cooked
  Hunger                    Minecraft's food bar, pure (FoodData: food, saturation, exhaustion,
                            eating, the fast and slow regeneration, starvation, the Hunger
                            effect's drain, the sprint rule; Minecraft's shanks and jitter,
                            specced, though the HUD shows the FOOD status icon)
  Apocalypse/               the zombie apocalypse's shared rules, pure: BloodMoon (the horde
                            nights' schedule from the day time), Infection (a bite's progress,
                            stages, symptoms, bites, cures, dormancy), NoiseRules (which sounds
                            zombies hear, and how far)
  GameMode, Mining          the four game modes and what each allows, mining times by hand and
                            with tools (and status effects' Haste and Mining Fatigue)
  Effects/  EffectList      status effects (Minecraft's MobEffects, Oil Coated, Fuel Soaked, Tough
                            As Nails' four, Mana Sickness, Bleeding, the Infection, Minecraft's
                            Hunger and Radiation Sickness): the
                            registry, the modifiers movement, mining, combat and burning read,
                            ticking rules, the HUD's order and flashing;
            PotionList      the potions (ingredients, levels, durations: items, recipes, drinks)
  ToughAsNails/             Tough As Nails, pure: Thirst (thirst, hydration, exhaustion,
                            dehydration, regeneration, the Thirst effect), Temperature (-10..10
                            in five zones, the target, the drift, hypothermia and hyperthermia,
                            Internal Warmth and Chill, Climate Clemency), Drinks (water sources,
                            the container tables: bottles, canteens, bowls; the teas), Exertion
                            (movement that costs thirst and food), Boiling (dirty water boiled clean on a
                            campfire)
  Radiation/                Mekanism's radiation, pure: the sources (uranium's blocks and items),
                            the falloff, the shielding and the scan, the Hazmat suit, the dose,
                            Radiation Sickness's bands and renewal, the Geiger counter's click rate
  Mana/                     Terraria's mana, pure: init (capacity, 1.4.4's regeneration at 20 Hz,
                            spending, Mana Sickness), StarFall (when and where Fallen Stars fall)
  Magic/                    Projectiles (the spark, bolt and water kinds, the deterministic step
                            both sides fly), Casting (a HeldUse's checks and the cast cadence)
  Weapons/                  firearms and the melee rework, pure: init (the registry: firearms,
                            rounds, magazines, attachments and melee weapons by item id) with
                            WeaponList (their numbers and looks), WeaponState (what a gun or a
                            magazine holds in its item data; firing a round), Handling (cadence,
                            spread, recoil, sway, breath, jams, noise, zoom, how long a weapon
                            action locks the gun), Ballistics (a shot's flight), Loading
                            (combining in the inventory, the weapon actions), Melee (heavy
                            attacks, the guard, finishers), Describe (their tooltip lines)
  Turrets/                  turrets, pure: init (the registry: twelve Specs by block, the feeder
                            rule's rate, the slots, the packed state, the cell over the gun,
                            optics, slot outlines), TurretRules (aim, turning, the exact cadence,
                            spread, range, noise, score, feed rate; both sides), Types (the
                            Order, Outcome and Service the machine kind and the simulation share)
  Progression/              knowledge, Ages and skills, pure: Knowledge (Minecraft's experience
                            curve, the sources and their numbers, fatigue and the budget), Ages
                            (what each opens and needs), Skills (the tree and its perks), init
                            (the state: awards, discoveries, advancing, unlocking, the recipe
                            gate, perks, death, the saved record, the client's status)
  Sounds/  SoundList        sound events (Minecraft's names) -> built-in sounds, block sound types
           MusicList        the music (surface, night and cave tracks) and the cave mood sounds
  DayCycle                  Minecraft's day: celestial angle, sky light, isDay and the sun's
                            brightness (solar panels), /time arguments, lighting blends
  Weather/ init             the weather clock, /weather's overrides and their blending, the
                            published attributes, the save, what falls where (biome, altitude),
                            Minecraft's darkening, sky / cloud / fog colours, fog distance, the
                            rain's sound and thunder's delay
           WeatherModel     the storms: a field of noise drifting with a slowly turning wind
                            (closed form), precipitation, thunder and cloud cover anywhere at any
                            time, a grid sampler (minimap, far clouds) and forecasts
  Seasons/                  the seasons' rules, all pure: Calendar (the calendar from the day
                            time and one offset, blending, the sun's warp, the save), SeasonClimate
                            (biome classes, the season's temperature shift, heat waves, snow caps
                            and melting), Rooms (the flood fill, insulation, the air's step, the
                            thermostat), SnowLayers (piling and melting a tile), Foliage (the
                            foliage palettes through the year), HeatStates (the heaters' states)
  Biomes/  BiomeList        biome definitions and altitude bands (and Minecraft's temperature and
                            precipitation for the weather)
  Generation/
    TerrainGenerator        biomes, surfaces, filling chunks at any LOD
    Relief                  terrain heights (JJThunder To The Max style)
    Noise                   seeded noise on top of math.noise
    Caves, Ores             full detail only (Ores: every ore feature, Mekanism's osmium and the
                            newer ores included, and the sulfur vents on lava lakes and oil)
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
    Mineshafts              Minecraft's mineshafts (piece grammar, overgrown ones, entrance
                            shafts with a rope, chest loot; full detail only)
    Cities                  the overgrown cities and roads: where they stand, the wrapped relief
                            (cut and fill), the streets' surface, `blocked` for the planners,
                            caches, the spawn's shift, writing them (levels 0-4); CityLayout
                            (a city's parcels, buildings, ruin, overgrowth, cars and loot;
                            pure), Roads (a road's line, grading and surface; pure)
    Bunkers                 hidden bunkers: wild and city sites, layouts, writing (full detail
                            only), loot and POIs
    ScavengeLoot            the ruins' and bunkers' loot tables
    CaveDecor               glow lichen on cave walls (full detail only)
    Foliage                 ground plants by biome (full detail only)
    WorldTypes              the world types (registry, options and settings, hints, the
                            WorldType / WorldOptions / Seed attributes)
    LayeredGenerator        a whole generator from layer stacks, placed blocks and a structure
                            placer (flat, void and debug worlds; every LOD level)
    Superflat               superflat preset lines, Minecraft's presets
    DebugWorlds             the debug worlds' grids (all blocks, all structures with the sample
                            mineshafts, bunker and town, all biomes)
    Locate                  /locate's searches: ids and tags, ring searches over the
                            generators' cell grids (cheap probes, exact verifies), the biome
                            rings (pure; the generators' `locateKinds` probe their own cells)
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
                            rule, the wire and DataStore formats, the mouse and scroll math
  KeyBindings               Minecraft's key mappings: every action, its default and category,
                            the bindable keys (Roblox's KeyCode values), conflicts, the list order
  WorldSettings             the world's settings (Create World): seeds as Minecraft reads them,
                            checking a request, a world type's options, publishing them;
                            commands' permission and argument attributes
  Poi                       /locate poi's types and tags (chests, furnaces, machines, supply
                            crates, medicine cabinets, bunker hatches...): the blocks of each, a
                            lookup table by block id
  SaveText                  the words and sizes of saved worlds (the toast, the list, the chat)
  Movement/                 Hull (box vs blocks collision), PlayerPhysics (Minecraft movement
                            tick, spectators' flight through blocks), Rig (hull <-> cosmetic
                            character)
  Net/                      Protocol (buffer encoding), Remotes, WeaponSync (the weapons' Fire,
                            Weapon and Shots messages)
  Util/Hash                 deterministic hashing and RNG

src/textures -> generated from the texture pack by tests/build_textures (never edit by hand)
  Materials.model.json      MaterialService.IceVoxel: a MaterialVariant IV_<name> per filled texture
  Images.model.json         ReplicatedStorage.IceVoxelTextures: a Texture prototype of the same name

src/sounds   -> SoundService.IceVoxelSounds: the game's own recordings, Sounds named like the
                events they replace (edit a SoundId to swap one)
  Weather.model.json        thunder near and far, the rain loop, the wind loop
  Zombies.model.json        the zombies' groans, growl and deaths, Sounds per voice event

src/server   -> ServerScriptService.IceVoxel
  IceVoxel_Server           boot: operators, settings and the title screen first, then
                            startWorld (world, ticker, network, players...) once it is created
  Api                       require this from your own server scripts
  World/                    WorldServer (chunks + edits), BlockTicker, RandomTicker, Skylight,
                            Simulation (chunks kept generated around players, /genstats),
                            GenQueue (which, in what order, a slice of a frame at a time; pure),
                            TimeOfDay (the day clock, published as workspace attributes),
                            SeasonClock (the calendar's offset and hold, published the same way;
                            the save's "seasons" section),
                            WeatherServer (the weather clock and /weather's overrides, published
                            the same way; rain for fire, players and mobs; lightning near
                            players; the save's encode / decode), WeatherRules (where rain falls:
                            Level.isRainingAt; pure), Lightning (strikes: rate, target, fires,
                            reach; pure),
                            WorldInfo (the world's settings once created; creating it once),
                            WorldSave (saving and loading worlds: the DataStore, autosave,
                            /save-all, players' records, the title screen's Load World),
                            Explosions (blasts in the world, fuel going off, per-tick cost
                            bounds, the primer hook for explosive blocks), FuelBlast (fuel
                            catching, measuring a body, power, chained blasts; pure), Nuke (the
                            Nuke's crater: ragged sphere, scorching, fire, a budget a tick),
                            PoiSearch (/locate poi: edits and the plans' points; pure)
  Behaviours/               Gravity, Fluid (water, lava, oil and fuel; lava hardening against
                            water), Grass (dying and spreading), Leaves (decay), Sapling, Herb
                            (mint and wild ginger spreading), Attached (torches and lanterns need
                            support),
                            Plant (plants need their soil and their other half), Fire
                            (spreading, burning blocks away, burning out, ages; lava lighting
                            fires; flint and steel), Tnt (lit TNT and Nukes: lighting, the fuse,
                            falling, blowing up), SnowLayer (a layer whose support goes),
                            Drops (block update logic)
  Seasons/                  RoomWorld (the rooms: seeds, the budgeted fills, the cache, the air's
                            step, the machines' climate, the snow's lookup), SnowWorld (snowfall,
                            thaw, heat melting and ice on the active chunks, the season's growth)
  Save/                     saved worlds, pure: SaveCodec (bytes, stacks, base85 text),
                            RegionCodec (a region's edits and block state), PlayerCodec,
                            WorldMeta (records, keys, sizes), SaveLock, SaveScheduler (requests
                            within the budgets and the 6 s a key), WorldSnapshot (the world's
                            state to regions and back), WorldStore (save, load, delete, rename),
                            SaveCommand (/save-all, /save-off, /save-on); characters, pure:
                            CharacterCodec (the record, its value and the user's index),
                            WorldCharacterCodec (what a world keeps of one), CharacterSaves (the
                            store's rules: create, select with the lock, save, delete, rename),
                            CharacterMigration (old progress and per-world records into them)
  Audio/Sounds              plays sounds to the players near them (Sound messages)
  Network/ServerNet         edit lists, edit validation (EditRules: mining time, tools, drops,
                            sustained data hooks, both halves of tall plants), replication;
                            LobbyNet (messages before the world exists)
  Entities/                 EntityWorld (item rules: pickup, merging, despawn, burning in lava,
                            blasts),
                            Entities (spawning, replication)
  Mobs/                     MobWorld (mobs' rules: ticks, hurts, death and loot, blasts, despawn,
                            players' attacks, blocks zombies break; pure), MobAI (wander, panic,
                            hunt, melee; the zombies' noise, breaking, blood moon hunts, leaving
                            and screams; pure), MobCrowd (zombies kept apart; pure), MobSpawning
                            (natural spawning by light, ground and caps, by day on open ground,
                            packs; pure), ZombieDirector (caps by day, night and city, blood moon
                            waves and hunts, leave rounds; pure), MobTracking (what each client
                            is told: spawns, moves, states, removes; pure), SummonCommand
                            (/summon, /kill; pure), Mobs (20 Hz ticks, replication, attacks,
                            commands, breaking blocks, the `died` and `playerHit` events and
                            other scripts' hooks)
  Apocalypse/               the zombie apocalypse on the server: NoiseBus (the tick's noises:
                            sounds played, explosions, sprints, screams), Infection (each
                            player's infection and its external effect), SurvivalRules (bites,
                            wounds, the survivor record, the blood moon watch, rising; pure),
                            Survival (bites, kills, deaths, rising, sprint noise, the Survivor
                            message)
  Weapons/                  firearms on the server: FireRules (a shot's checks, flight, targets,
                            damage, noise and record; pure), Firing (a Fire message played out),
                            WeaponActions (raising and guarding; the weapon actions' locks and
                            sounds), init (the glue)
  Turrets/                  turrets on the server: TurretWorld (the simulation every turret's
                            machine tick asks: targets, shots, noise, the lure, records; pure),
                            Turrets (the glue: the service handed to the machines, records,
                            shots)
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
                            campfire) used on blocks (UseItem); ToggleUse (the bunker hatch
                            opened and shut)
  Players/PlayerPositions   where every player is, for all server code (feet in blocks, doubles;
                            reach, teleports): the characters, or with
                            Config.Players.ServerPositions the server's own, from checked client
                            moves: PositionStore (records, teleport epochs, spectating; pure),
                            MoveCheck (speed buckets per game mode; pure), Interest (who sees
                            whom, chunk lists and edits by distance; pure), PlayerRelay (other
                            players' poses only to those who may see them)
  Players/                  Operators + OperatorList (Minecraft's ops: the first player, /op,
                            /deop, the check every operators' command asks; pure), WorldMenu (the
                            title screen's server side: creating the world, characters only in
                            it, spawned with their look), CharacterStore (Terraria's characters:
                            the lists, the title screen's requests, locks, saving, entering a
                            world, Hardcore deaths, the migration), CharacterLooks (the R15 look:
                            the user's avatar read, HumanoidDescriptions, preview rigs), GameModes + GameModeCommand (/gamemode, the switcher's requests,
                            permissions, the previous mode), GameModeRules (what each mode may
                            do on the server; pure), TimeCommands + TimeCommand (/time,
                            /gamerule), SeasonCommands + SeasonCommand (/season; pure),
                            WeatherCommands + WeatherCommand (/weather; pure),
                            Inventories + InventoryState (authoritative inventories),
                            Containers (chests, furnaces, generated structures' chests),
                            Characters (cosmetic characters: collision group, teleports, fall
                            damage, invulnerability, suffocation, lava and burning, explosions),
                            Burning (lava, fire and campfires hurting and burning players and
                            items, the hurt cooldown explosions share; pure), ToughAsNails
                            (thirst, body temperature and Minecraft's food bar: ticks, drinking,
                            exertion, the HUD's state) + Climate (the surroundings: biome, roof, heat and cold
                            sources; pure), Effects (status effects: the API, sending, Glowing,
                            /effect) + EffectRules (giving, ticking, the fluids' effects, the
                            sync rule; pure) + EffectCommand (/effect; pure),
                            Spawning,
                            SafeSpot + SpawnUnsafeBlocks (safety rules), Teleport (map,
                            spectators), TeleportCommands + TeleportCommand (/tp; pure),
                            LocateCommands + LocateCommand (/locate: parsing, answers and their
                            links, the searches' budgeted queue; pure),
                            WaypointStore and SettingsStore (DataStores: waypoints, player
                            settings), Eating (food held 32 ticks: the food bar filled, or
                            healing, used up),
                            UseState (who eats or drinks: the player attribute every client
                            plays the loops from),
                            Progression + ProgressionCommand + ProgressStore (knowledge, Ages and
                            skills: earning, the windows' recipe gate, perks for the parts above,
                            /knowledge and /age, the DataStore),
                            Mana (each player's mana: regeneration, the Mana message, potions,
                            crystals), Magic (casts and the projectiles' flights and hits),
                            FallenStars (stars at night, gone at dawn),
                            Radiation + RadiationRules (each player's exposure, dose and Radiation
                            Sickness once a second, the attributes the clicks follow, saving; the
                            look pure)

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
                            settings; which fog shows), LightingController (day, night and cave
                            lighting, the Atmosphere), AtmosphereModel (the Atmosphere's haze
                            from the view, weather, time and depth; which fog shows; pure),
                            SkyExposure (how much sky light reaches the camera), FluidFog (the
                            view from inside a fluid: fog and tint), MeshOverlay + MeshRegions
                            (far meshes), TextureLooks (every look of the texture pack: variants,
                            tints, images, sprites, far and plain looks, far mesh looks; checks
                            the ids and measures averages), Rebase (moves the floating origin
                            and everything placed in its frame, in one frame)
  Settings/                 the player's settings: State (values and choices), Schedule (when
                            changes apply), Pages (the menu's layout, the Key Binds list and its
                            scrolling), saving them on the server; Keybinds (what every input
                            site asks: matches, isDown, hotbar slots, key names)
  Interaction/              BlockInteraction (mining, placing, using), CrackOverlay, TankUse
                            (does a bucket on a machine act on its tanks or open its screen),
                            Drinking (Tough As Nails: filling, sipping, holding a drink), Eating
                            (holding food), Casting (magic weapons and Mana Crystals, predicted);
                            hitting mobs (BlockInteraction)
  Inventory/                ClientInventory + Prediction (predicted inventory)
  Ui/                       Screens (opening, clicks, drag feedback, tooltips, JEI's place),
                            Theme (the survival look's tokens and rules; pure) + Style (Minecraft's
                            look, and Style.Dayz: the survival look's builders) + Masks (anti-
                            aliased masks from vector shapes; pure) + Silhouettes (the look's own
                            drawings; pure), Hud (the HUD canvas, the item-in-hands box, the
                            touch buttons) + Quickbar (the quickbar) + StatusCluster (the status
                            icons, badges and knowledge bar) with StatusLayout and StatusGlyphs
                            (their rules and silhouettes; pure) and StatusDock (their place in the
                            open inventory), SurvivalHud (frost and heat at the screen's edges),
                            ManaStars (when mana counts as shown; pure), InventoryScreen (the
                            three columns) with InventoryColumns (its layout and scale; pure),
                            SlotWidgets (its slots, eyes and padlocks), ContainerPanel (the open
                            block's section: MenuLayout's panels, gauges and tanks), GroundStrip
                            (dropped items nearby, the throw place) and PlayerPreview (the
                            player), CreativeScreen, ItemTooltip, DragGhost (the carried stack),
                            Backdrop (the blur and vignette behind open screens), ItemIcon
                            (viewport icons, count boxes, condition and energy bars), SlotClicks
                            (Minecraft clicks), Waila + WailaInfo (what the crosshair
                            points at), Jei/ (Just Enough Items: item list, recipe view, recipe
                            transfer), StructureScreen + StructureForm (the structure block and
                            jigsaw screens and their model), FormWidgets (Minecraft's fields and
                            buttons), SpectatorGui + SpectatorMenu (the spectator menu and its
                            model), GameModeSwitcher + ModeSwitch (the F3 + F4 switcher and its
                            model), SettingsScreen (the Options menu), UiScale (the GUI scale on
                            this screen, every ScreenGui, the HUD's corner) + GuiScale and
                            HudLayout (Minecraft's scale and the corner's layout; pure),
                            MusicToast (Now Playing),
                            EffectHud + EffectIcons (status effect icons in the top right, the
                            row in the open inventory's band and the list beside other open
                            screens, their glyphs), SkillTreeScreen (the skill
                            tree, K), AgeToast (a new Age's banner), AttackIndicator (the
                            weapon's recovery under the crosshair or beside the quickbar), MainMenu
                            (the title screen, Create World and Load World) + TitleRules +
                            CreateWorldForm + WorldListRules (their rules; pure),
                            CharacterSelect (the character list) + AvatarEditor (the R15 editor)
                            + CharacterPreview (a server-built rig in a viewport) +
                            CharacterRules (their rules; pure), SaveIndicator
                            (the saving icon and the "World saved" toast), Chat/ (the chat in place of Roblox's: ChatLog
                            the lines, ChatInput the box's rules: sending, history, Tab;
                            ChatFormat the messages' looks; all pure), HoverTip (every menu
                            button's tooltip) + ButtonHelp (their texts) + TooltipLayout
                            (wrapping and placement; pure), SurvivorHud (the day counter
                            and the HUD's toast queue: the blood moon's, the seasons') +
                            SurvivorLine (their texts, widths and timing; pure), SeasonHud (the
                            season clock beside the minimap and its toasts) + SeasonClock (the
                            dial's face) + SeasonLine (its caption and toasts; both pure)
  Audio/                    SoundPlayer (pooled 3D / interface sounds, the server's Sound messages,
                            overrides), MovementSounds (footsteps, swimming, landings), Ambience
                            (furnaces, Heat and Combustion Generators crackling, lava, the cave
                            mood), CaveMood (Minecraft's mood, pure), Music + MusicRules (the
                            background music; when and which, surface, night or cave, pure),
                            SoundRules (the pure rules), UseSounds + UseSoundRules (eating and
                            drinking loops, every player's; the rules pure), Geiger (the Geiger
                            counter's clicks while exposed to radiation)
  Entities/EntityRenderer   dropped items; MobRenderer (mobs: boxes, zombies' R15 rigs, flames,
                            groans), MobParts (the mobs' Parts, Fire and BulkMoveTo, shared with
                            the Studio probe), MobModel (the pure glide, move-op baseline,
                            stride and aim), MobRig (the R15 part tables and pose maths, pure),
                            ZombieLooks (outfit colours, pure), MobRigPool (rig tiers and pools,
                            pure), ZombieVoices (who groans when, pure)
  Map/                      MapLayer (EditableImage ring), MapView, Minimap, WorldMap,
                            Waypoints, ContextMenu, WeatherLayer (the weather mode over both
                            maps, painted a band a frame) + WeatherMap (its colours, grids, cache,
                            forecast steps and wind; pure)
  Weather/                  the weather on this client: init (starts it, the picture's grading and
                            haze, F3's lines), WeatherState (the server's state, this frame's
                            moment, the weather over the camera smoothed, columns' biomes),
                            PrecipitationView + Precipitation (rain and snow strips around the
                            camera stopping at roofs, the rain's sound; Minecraft's rules, pure),
                            CloudView + CloudLod (clouds in rings of detail to the view distance,
                            drifting with the wind; rings, looks and merging, pure),
                            LightningView + LightningBolt (the server's lightning: bolt, flash,
                            thunder; Minecraft's shape and timing, pure), WeatherSky (what the
                            weather does to the light, pure; Rendering/LightingController applies
                            it)
  Net/ClientNet             routes server messages; Notices shows server messages in the chat;
                            StructureNet (structure blocks' and jigsaws' messages and screens)
  Player/                   MovementController (the hull, input, the cosmetic character,
                            spectating a player), CharacterAnimator (avatar animations from the
                            hull), HeldItems, SpectatorView + SpectatorRules (who sees, hears and
                            aims at spectators), BurningView (flames on burning players, the fire
                            overlay in first person), SurvivalState (Tough As Nails' state from
                            the server), Exertion (reports sprinting, swimming and jumps),
                            EffectState (status effects from the server, counted down),
                            ManaState (Terraria's mana from the server, casts predicted),
                            ProgressionState (knowledge, the Age and skills from the server; the
                            recipe gate and perks the client predicts with), ViewBob (Minecraft's
                            view bobbing and hurt tilt, pure), MouseLook (mouse sensitivity and
                            Invert Mouse on Roblox's camera), RemotePlayers + RemoteMotion (where
                            the other players are: their characters, or the server's relay drawn
                            0.1 s behind; the interpolation is pure), LocalPosition (this player's
                            moves to the server and its teleports, with
                            Config.Players.ServerPositions; pure core), EquipmentLooks (armor,
                            vanity and accessories drawn on every character and the inventory's
                            preview; air jump puffs), AirJumps (other players' air jumps told
                            from their poses, pure)
  Rendering/ExplosionView   explosions: the blast drawn, the knockback, a camera shake
  Rendering/EffectView      Night Vision, Blindness and Nausea on the view
  Rendering/BloodMoonSky    the blood moon's red sky and bigger moon (the tint pure)
  Rendering/SeasonSky       the season's light: winter's cool, autumn's warm, a heat wave's glare
  Rendering/SeasonTint      the foliage colours through the year: the palettes to ChunkRenderer's
                            budgeted sweep and the far meshes, the biome class of each chunk
  Player/SurvivorState      the server's Survivor record, the alive ticks counted on between
                            messages
  Rendering/FireRenderer    fire's and campfires' animated flames (SurfaceGui planes, one shared
                            animation step)
  Rendering/FuseView        lit TNT and Nukes flashing
  Rendering/ProjectileView  magic projectiles flown with the server's pure step (neon balls,
                            lights, trails), this player's casts predicted and adopted
  Rendering/TransmitterRenderer  Mekanism pipes, cables and machines: arms, fluids in pipes and
                            tanks, items moving through transporters, the windows of working
                            generators, Electric Furnaces and Oil Refineries, Batteries' charge
                            gauges, machines' records (WAILA, Ambience, buckets); TransmitterModel
                            (their geometry, aiming, item paths, fluid colours)
  Rendering/ItemModels      3D models of items (icons, drops, hands); BlockDecor (the faces of
                            chests, crafting tables, furnaces, Mekanism's machines, the turrets'
                            bases, the Metal Miner and the Ammo Press, structure blocks and
                            jigsaws)
  Rendering/StructureBoxes  structure blocks' outlines, names and air markers
  Interaction/Firearms      a firearm in hand: raising, the sights, the trigger, reloading, the
                            fire mode, the light; MeleeInput (the melee rework's light and heavy
                            attacks and the guard); AttackRules (what the attack button breaks
                            and a tap does with a weapon in hand; pure)
  Player/AimRules           the aim's pure rules (posture, trigger, timed actions, recoil, zoom,
                            poses); AimCamera (the shoulder, the locked mouse, zoom, sway,
                            recoil); WeaponPoses (every character's arms for a gun, a guard, a
                            wind-up)
  Rendering/ShotView        shots seen and heard: flashes, tracers, impacts, fire sounds (by the
                            pure ShotRules)
  Rendering/TurretView      the turrets' guns turning on their bases as the server's records say,
                            their lasers and servos; TurretModel (the guns' boxes by type, tier
                            and mounts, and where a drawn gun turns; pure)
  Ui/WeaponHud              the shoulder dot, the red dot, the scope, the held gun's word and bar;
                            WeaponButtons (the touch AIM, FIRE and RELOAD)
  Debug/DebugOverlay        F3 stats, time of day and weather, the mobs and their rigs, the
                            turrets (also WAILA's extended view); DebugKeys (Minecraft's debug
                            keys: F3 when let go, F3 + N, F3 + F4, F3 + Q)

tests/       Lune scripts: unit tests, benchmark, terrain preview, structure (structure data on the
             command line), build_structures (the example outpost's builder), build_textures (the
             texture pack -> src/textures; logic in lib/TextureBuild), content (the content packs'
             checker, lists, pages and new packs; logic in lib/ContentTool and lib/ContentGame)
tools/probes Studio probes, never in the place: RebaseProbe (what a floating-origin move costs),
             UnionProbe (CSG unions of real terrain sections), ZombieRigProbe (what posing and
             moving the zombies' rigs costs on a device); how to run them in their README
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
| `Caves.AlwaysShow`        | false   | The Caves setting's default: true draws every cave of every full detail chunk ("Always Shown", about 4 × their parts), false only those the camera can see into. |
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
| `Mineshafts.Enabled`      | true    | Mineshafts (Generation/Mineshafts); they also follow Generate Structures and `Structures.Generate`. |
| `Mineshafts.Grid` / `Chance` | 128 / 0.25 | One candidate start room per 128 × 128 blocks, kept with `Chance` (about 15 per km², Minecraft's 1 in 250 chunks). |
| `Mineshafts.Depth`        | { 28, 64 } | The start room's floor this many blocks under its centre column's surface (fewest, most). |
| `Mineshafts.MinY` / `Cover` | 16 / 6 | No mineshaft block below y 16; 6 blocks of ground kept over every piece. |
| `Mineshafts.MaxDepth` / `Extent` | 8 / 80 | Minecraft's grammar: pieces at most 8 steps from the room, starting within 80 blocks of its corner. |
| `Mineshafts.OvergrownHumidity` / `OvergrownChance` | { 0.1, 0.6 } / 0.8 | Overgrown with a chance rising from 0 at biome humidity 0.1 to 0.8 at 0.6 and above. |
| `Mineshafts.EntranceChance` | 0.5  | The chance an overgrown mineshaft has an entrance shaft with a rope (when a dry, level spot passes: none under the sea or a beach). |
| `Mineshafts.SpawnClearance` | 32   | No entrance this close to the spawn (blocks). |
| `Cities.Enabled` | true | Overgrown cities and their roads (Generation/Cities); they also follow the Ruins setting, Generate Structures and `Structures.Generate`. |
| `Cities.OldWorlds` | false | true: worlds saved before the ruins existed get them too, in ground nobody edited (off by default: cut and fill next to an old world's edited chunks would leave cliffs at the seams). |
| `Cities.Grid` / `Chance` / `Tries` / `Accept` | 1024 / 0.36 / 4 / 21 | One candidate per 1024 × 1024 blocks kept with `Chance`, up to `Tries` spots (a size and a centre) tried until one fits: `Accept` of 25 lattice samples over the footprint fit to build on. |
| `Cities.MinRadius` / `MaxRadius` / `Margin` | 48 / 224 / 24 | Footprint half-widths (most cities are small towns), and the margin blended back to the terrain. |
| `Cities.Block` / `Street` | 32 / 7 | A street every 32 blocks, 7 wide (sidewalk, 5 of asphalt, sidewalk). |
| `Cities.MaxFloors` / `FullFloors` / `FloorHeight` | 12 / 4 / 4 | Floors at most; full interiors (rooms, ladders, loot) up to floor 4, above it a ring of rooms around a solid core; 4 blocks a floor. |
| `Cities.MaxSlope` / `MinAboveSea` | 10 / 3 | A footprint's fit samples span at most 1.5 × 10 blocks of height; the plateau at least 3 over the sea. |
| `Cities.LodLevels` | 4 | Buildings drawn at LOD levels 0-4 (massing beyond full detail), none beyond. |
| `Cities.Ruin` / `Overgrowth` / `Cars` | 0.55 / 0.8 / 0.08 | How ruined a building is on average, how overgrown (times the biome's humidity factor, at least `OvergrowthFloor`: a city's o is 0.4-0.8, jungles most), and the chance of a wreck per lane of a street stretch. |
| `Cities.OvergrowthFloor` | 0.5 | The least humidity factor of a city's overgrowth: a desert or plains town greens half as much as a jungle one. |
| `Cities.Trees` | 0.5 | A vegetation spot on a city's grass (parks, plazas, the streets' grass patches) grows a tree at least `Trees` × o of the time, whatever its biome's own chance. |
| `Cities.Bunkers` | { 1, 2 } | Bunker sheds per city (Generation/Bunkers puts a hatch in each). |
| `Cities.Caches` | Cells 1024, Sites 32, Links 64, Tiles 512 | Plan caches per generator (each worker its own). |
| `Cities.Roads.Enabled` | true | Roads between cities. |
| `Cities.Roads.Width` / `Shoulder` / `Blend` | 5 / 1 / 8 | Asphalt width, gravel shoulder each side, blend into the terrain. |
| `Cities.Roads.LinkCells` / `Wobble` / `Step` / `MaxGrade` | 2 / 48 / 8 / 1/6 | Links to the nearest city per quarter within 2 cells; the line wobbles up to 48 blocks, sampled every 8, graded to at most 1 in 6. |
| `Cities.Roads.MaxCut` / `MaxFill` / `MaxWater` | 24 / 24 / 48 | A link is dropped where it would cut or fill more, or cross a longer run of water. |
| `Cities.Roads.SurfaceLevels` / `CutLevels` | 2 / 3 | Roads are drawn at LOD 0-2 and level the ground at 0-3. |
| `Cities.Roads.Cracks` / `Overgrown` / `Potholes` / `Cars` | 0.25 / 0.55 / 0.02 / 0.004 | Asphalt decay (cracked patches, grass and moss patches on `Overgrown` × o of the asphalt and half again of the sidewalks, potholes) and wrecks per road block. |
| `Bunkers.Enabled` | true | Hidden bunkers (Generation/Bunkers); they also follow the world's Ruins setting, Generate Structures and `Structures.Generate`. |
| `Bunkers.Grid` / `Chance` | 768 / 0.35 | One wild candidate per 768 × 768 blocks, kept with `Chance` (0.38-0.61 per km² measured on five seeds; 0.59 at most on dry land). |
| `Bunkers.Candidates` | 24 | Hatch columns tried per kept cell (dry, level ground; the first that passes). |
| `Bunkers.Depth` | { 9, 16 } | The floor this many blocks under the hatch (fewest, most); a city's bunker is 12 under its shed. |
| `Bunkers.Rooms` | { 3, 6 } | Rooms along the corridor (a bunk room and a storeroom always among them; a city's shed drops some, down to those two, when its town has no room for them). |
| `Bunkers.Lit` / `Overrun` | 0.8 / 0.15 | Shares lit (ceiling lamps) and overrun (moss, cobwebs, half the lamps gone, bones in the loot). |
| `Bunkers.SpawnClearance` | 64 | No bunker within this many blocks of the spawn. |
| `StructureMaxLevel`       | 2       | Highest LOD level that still shows trees and library structures.   |
| `Structures.Permission`   | {}      | Who may use structure blocks and jigsaws in creative besides operators (the owner, `Gameplay.Admins` and Studio among them): user ids, or true (anyone in creative) / false. |
| `Structures.MaxSize` / `MaxOffset` | 48 / 48 | A structure block's largest size and relative position per axis (Minecraft's). |
| `Structures.DetectRange`  | 80      | How far DETECT looks for Corner blocks of the same name.            |
| `Structures.LoadBlocksPerFrame` | 2000 | Blocks LOAD and Generate place per frame (and at most 6 ms of it). |
| `Structures.MaxDataChars` | 200000  | Longest structure text saved or pasted (what a StringValue holds).  |
| `Structures.DataPieceChars` | 16000 | Structure text travels in pieces of this many characters, `DataPiecesPerSecond` (20) a second. |
| `Structures.Generate`     | true    | Library structures generate in the world; false: none do.          |
| `Locate.BudgetMs` / `TimeoutSeconds` / `Queue` | 3 / 20 / 8 | `/locate`'s searches: milliseconds of each server frame, how long one may run before answering not found, how many may wait. |
| `Locate.StructureRings` / `Radius` | 100 / per kind | How far structures are searched: rings of placement regions (Minecraft's 100), and blocks for the built-in kinds (`mineshaft` 4096, `oil` 16384, `lake` 4096, `cave` 3072, `ravine` 6144, `city` 24576, `bunker` 6144). |
| `Locate.BiomeRadius` / `BiomeStep` | 6400 / 32 | Minecraft's biome search (times the world's climate scale, at most 2: Large Biomes). |
| `Locate.PoiRadius` / `PoiGeneratedNear` | 256 / false | Points of interest within this many blocks (3D); true: generated ones only in loaded chunks. |
| `Render.Textures`         | true    | Draw the texture pack's textures (the Textures setting); false: every block in its plain material and colour. |
| `Render.FarMaterials`     | false   | Materials and textures on merged far chunks, a far mesh per look (the Far Materials setting), instead of plain colours. |
| `Textures.OddBoxes`       | false   | Odd-sized boxes (in blocks) for textured cubes at full detail, for variants that tile from a face's centre (see Block textures): 14-18% more parts near the player. |
| `Textures.BottomFaces` / `SideImages` | false / false | Draw bottoms (grass's dirt) as images, one more instance per part / the sides as upright images over the top's variant, four more. |
| `Textures.Sprites`        | true    | Plants, rope, cobwebs and hanging roots with a filled `Sprite` are two crossed images instead of their boxes. |
| `Textures.MeasureAverages` / `ValidateIds` | true / true | Measure the averages the pack lacks and print them to paste / check every image id once at startup and name each one that fails. |
| `Render.FarMeshes`        | on (PC) | Merge stable far regions into meshes (see Far meshes below).        |
| `Render.FarMeshes.MaxBuildSpeed` / `SpeedWindow` | 2 / 2 | No mesh builds while the camera moved faster than this many blocks a second, averaged over this many seconds. |
| `Render.FarMeshes.LookMinShare` / `MaxLooks` | 0.05 / 4 | With Far Materials: a look gets MeshParts of its own in a region when it covers this share of its area, at most this many looks (the largest). |
| `Render.FarMeshes.LookRemainder` | "plain" | The other quads: "plain" (SmoothPlastic in the colour they average to) or "largest" (joined to the largest opaque look, tinted to that colour). |
| `Render.FarMeshes.UvStuds` | 3      | Studs per texture tile in far mesh UVs (one block face).            |
| `Map.Teleport`            | true    | Who may teleport from the map: everyone, nobody, or a user id list. |
| `UiScale.MaxScale`        | 12      | The largest GUI scale (a sanity cap: Minecraft has none; a 4K window's Auto is 9). |
| `UiScale.ReferenceScale` / `MinReference` | 4 / 0.75 | Widgets drawn in fixed pixels (F3, the world map's bar and menus, waypoint and structure labels) look as drawn at this GUI scale (1080p's Auto) and keep at least this share of their size. |
| `UiScale.Minimap`         | 56      | The minimap's side in GUI pixels (its picture stays `Map.MinimapSize` map pixels, 384 blocks). |
| `Map.SaveWaypoints`       | true    | Keep waypoints between sessions (DataStore).                        |
| `Origin.Enabled`          | true    | The floating origin (see "Far from the origin" below); a kill switch, off only together with `Players.ServerPositions`. |
| `Origin.RebaseDistance` / `SoftDistance` / `Snap` | 8192 / 3072 / 768 | Studs from the render origin that move it at once / at a hidden moment (teleports, screens, menus); its steps. |
| `Players.ServerPositions` | true    | "Fake coords": characters parked on the server, true positions from checked client moves, relayed by interest; off: read from the characters as before. |
| `Players.MoveCheck` / `MoveSlack` | "correct" / 2 | Too fast moves: "correct" (sent back), "log" or "off"; seconds of movement at `Players.MoveLimits` (blocks a second per game mode) the checks allow at once. |
| `Interest.PlayerDistance` / `PlayerHysteresis` | 256 / 16 | Players are told about others this near (blocks, horizontal), and until this much farther. |
| `Interest.EditChunkRadius` / `EditSendRadius` | 14 / 14 | Chunks (x 16 blocks, from the feet to the chunk's nearest point): a chunk's edit list and records are sent this near the player (else deferred), live edits this near. An edit within 14 was made by someone within `PlayerDistance`; the client's lists reach 195 blocks at most. |
| `Interest.LightningDistance` | 184 | Blocks: server lightning strikes are sent this near (strikes fall within 64 of a player, so only of players within `PlayerDistance`). |
| `Gameplay.DefaultGameMode` | Survival | Game mode of players when they join: Survival, Creative, Adventure or Spectator. |
| `Gameplay.GameModeCommand` | true   | Who may change their own game mode (`/gamemode`, `F3` + `N`, `F3` + `F4`): everyone, nobody, or a user id list (operators always may). |
| `Gameplay.Admins`         | {}      | User ids who are always operators (as the game's owner and everyone in Studio): other players' game modes, `/time set\|add`, `/gamerule`, `/effect`, `/summon`, `/kill`, `/knowledge`, `/age`, `/op`, `/deop`, structure blocks. |
| `MainMenu.Enabled`        | true    | The title screen: the first player (the operator) creates the world from it, everyone joins it from it; nobody has a character before. false: the world is made at once from `World` and `Seed`, players join straight in, and only `Gameplay.Admins`, the owner, Studio and those they `/op` are operators. |
| `MainMenu.AutoOperator`   | true    | Until the world exists, the first player to join (and the one here longest when the last operator leaves) becomes an operator so someone can create it; no more after that. false: only `Gameplay.Admins`, the owner and Studio may create the world (a private game). |
| `MainMenu.Version` / `Credits` | "IceVoxel (Minecraft 1.20.1 style)" / "Not an official Minecraft product" | The title screen's bottom corners. |
| `Characters.Enabled`      | true    | Terraria's characters: chosen (or made in the avatar editor) on the title screen before the world, carrying their look, inventory, equipment, health, mana, effects, Tough As Nails and progress between worlds. false: no character pages, inventories in each world's player records and progress per player, as before. With `MainMenu.Enabled` off each player plays their most recently played character (one made from their avatar if they have none). |
| `Characters.StoreName`    | "IceVoxelCharacters_v1" | The DataStore: an index per user (`u<UserId>`) and a key per character (`u<UserId>/c<id>`, its lock inside). Needs `Save.Enabled` (and API access in Studio); otherwise characters last for the session. |
| `Characters.MaxPerUser` / `NameLength` | 10 / 20 | Most characters a user keeps; characters in a name. |
| `Characters.DefaultDifficulty` | "Classic" | A new character's difficulty in the editor (and with the title screen off): Classic keeps everything on death, Mediumcore drops it, Hardcore drops it and dies for good. |
| `Characters.SaveInterval` / `LockWait` | 60 / 30 | Seconds between saves of the selected character (also its lock's heartbeat; and on leaving, at shutdown and on `/save-all`); seconds a selection waits for another server still saving that character. |
| `Characters.Scales` / `MaxAssets` / `PreviewDelay` | Roblox's avatar rules / 40 / 0.5 | What a body may be (height 0.90-1.05, width and depth 0.70-1, head 0.95-1, body type and proportion 0-1); things of the user's own avatar a character keeps; seconds the server waits after an edit before rebuilding the editor's preview. |
| `Characters.SnapshotTries` / `SnapshotBackoff` / `SnapshotRetrySeconds` | 3 / 1 / 30 | Reading your own avatar: tries, and seconds before the second (doubled before each next). An avatar read is kept for the session; one that failed every try gives the plain look for 30 s only, and making a character reads again at once. |
| `Characters.Migrate`      | true    | A returning player's old progress becomes their first character (Mediumcore, "legacy"), and the first of their characters to enter an old saved world takes in what they had there (once; the old records stay as a backup). |
| `World.Name` / `Type`     | "New World" / "default" | The world made at once without the title screen, and the Create World screen's first choices (a `Generation/WorldTypes` id; its game mode is `Gameplay.DefaultGameMode`, or the type's own: Spectator for All Blocks, Creative for the other debug worlds). |
| `World.Options`           | {}      | The world type's options without the title screen (its `settings` keys, see below). |
| `World.Difficulty`        | "Normal" | Peaceful (no monsters spawn), Easy, Normal or Hard (fire spreads a little faster on harder ones: `Server.Fire.Difficulty`). |
| `World.AllowCommands` / `Structures` | false / true | Everyone may use the operators' commands (Minecraft's Allow Cheats) / library structures generate. |
| `Gameplay.KeepInventory`  | false   | Keep the inventory on death instead of dropping it (spectators always keep theirs). |
| `Accessories.Slots` / `ExtraSlotAges` | 5 / {"industrial", "atomic"} | Accessory slots every character has open, and the Ages that open one more each (7 at most). |
| `Accessories.RunDelay` / `RunRamp` | 10 / 12 | Hermes Boots: ticks of sprinting on the ground before the speed builds, then ticks to its full boost. |
| `Accessories.AirJumpPower` | 0.36   | A Cloud in a Bottle's take-off speed (blocks a tick; 0.36 rises 0.96 blocks, a ground jump's 0.42 rises 1.25). |
| `Hunger.Enabled`          | true    | Minecraft's food bar: the FOOD status icon, foods filling it (Minecraft's nutrition and saturation), regeneration from it, starvation, no sprint at 6 or less, the Hunger effect. false: no FOOD icon, foods heal health at once (as before), thirst rules regeneration. |
| `Hunger.NaturalRegeneration` | true | Minecraft's naturalRegeneration rule: a full bar with saturation heals half a heart's worth every 10 ticks (for up to 6 exhaustion), 18 or more half a heart every 80 ticks (for 6); replaces Roblox's regeneration. false: no natural regeneration at all. |
| `Hunger.StarvationFloor`  | 1       | Starvation (food 0) hurts half a heart every 80 ticks while health is above this many half hearts (Minecraft's normal difficulty: 1; easy 10; 0 = to death, hard). |
| `Hunger.EffectExhaustion` | 0.005   | Food exhaustion a tick of Minecraft's Hunger effect, per level (rotten flesh's 30 s: 3, most of a point). |
| `ToughAsNails.Thirst` / `Temperature` | true / true | Tough As Nails' thirst and body temperature (each off: no stats, no THIRST or TEMPERATURE status icon, no damage). |
| `ToughAsNails.ThirstRegeneration` | true | Health comes back only with thirst 18+: with hunger on as a condition of hunger's regeneration (both bars high), with it off by thirst's own (half a heart every 80 ticks for 6 exhaustion), replacing Roblox's regeneration; false: thirst has no say (hunger off: Roblox's stays). Nothing heals while fully frozen or overheated. |
| `ToughAsNails.DehydrationFloor` | 1 | Half hearts dehydration (a hurt every 120 ticks) stops at (Minecraft's normal difficulty; 0: to death). |
| `ToughAsNails.HandDrinking` / `HotExhaustion` | true / 0.005 | Sipping from water sources with an empty hand; thirst exhaustion a tick while hot. |
| `ToughAsNails.Grading` | Enabled, -0.5 / 0.5, 1 s | The picture's Saturation as the extremes build (Rendering/TemperatureGrade): down by up to 0.5 while freezing to death, up by up to 0.5 while overheating, in proportion to how far hypothermia / hyperthermia has got, eased over 1 s. |
| `ToughAsNails.ChangeTicks` / `RecoverTicks` | 140 / 70 | Ticks per step of the body temperature (-10..10) away from neutral / back towards it (neutral to icy: 56 s in the coldest place). |
| `ToughAsNails.ClemencyTicks` / `RespawnClemencyTicks` | 6000 / 1200 | Climate Clemency on joining / respawning: the temperature held neutral, half the thirst drain, no dehydration (0: none). |
| `ToughAsNails.WetTicks` | 100 | Ticks a player stays wet out of water (3 steps colder). |
| `ToughAsNails.ColdExhaustion` / `LeatherFreezeImmunity` | 0.005 / false | With the seasons on: food exhaustion a tick in the COLD zone and below (shivering: a food point every 40 s), and whether a leather piece still stops hypothermia (false: clothes slow freezing but never stop it, as Don't Starve's; without seasons a piece always does). |
| `ToughAsNails.ProximityRadius` / `HeatingBlocks` / `CoolingBlocks` | 5 / none / none | Heat sources within that many blocks warm 3 steps (5 within 2 blocks, where cold sources no longer cool), cold sources cool 3 (fluid or block names; unknown names are skipped with a warning). The packs' entries say which blocks are sources: the lava, fire and campfire `heats`, the ice, packed ice, blue ice and snow `cools`. |
| `Progression.Enabled` / `GateRecipes` | true / true | Knowledge, Ages and the skill tree at all (off: no bar, no gates, no perks); a later Age's (or a skill's) crafting and smelting results locked. |
| `Progression.Save` / `SaveInterval` | true / 120 | Keep progress between sessions (DataStore "IceVoxelProgress_v1"; Studio needs API access); seconds between saves of changed progress (and on leaving and shutdown). |
| `Progression.RepeatBudget` | 20 | Points a minute at most from repeated actions together (ores, logs, smelting, crafting, mobs; the knowledge perks included); discoveries are not limited. |
| `Progression.DeathLoss` | 0 | Share of the progress into the current level lost on death (levels, the Age and skills never are). |
| `Progression.BiomeInterval` | 2 | Seconds between looks at the biome a player stands in (a first visit is a discovery). |
| `Progression.Key` / `GamepadButton` | K / DPadLeft | Open and close the skill tree (the key: the Skill Tree key binding's default). |
| `Entities.ItemLifetime`   | 300     | Seconds before a dropped item disappears.                           |
| `Entities.MaxItems`       | 1000    | Most dropped items at once (the oldest go first).                   |
| `Mobs.Enabled` / `Spawning` | true / true | Mobs at all (false: none spawn, tick or are sent) / natural spawning (`/summon` still works). |
| `Mobs.MaxMobs` / `MaxPassive` / `MaxHostile` | 320 / 120 / 200 | Most mobs in the world, creatures and zombies among them (360 / 260 while a blood moon is up: `Apocalypse.BloodMoon.MaxMobs` / `MaxHostile`). |
| `Mobs.PassiveCap` / `HostileCap` | 10 / 20 | Most creatures / zombies within 128 blocks of a player for spawning to go on; the zombies' is the night's (by day × `Apocalypse.Zombies.DayFactor`: 7; in a city × `CityFactor`: 35 and 12; a blood moon's cap instead through one; 0, as Peaceful: no zombies and no waves). |
| `Mobs.HostileInterval` / `PassiveInterval` / `Attempts` | 20 / 400 / 3 | Ticks between spawning rounds of monsters and creatures; packs tried per player a round. |
| `Mobs.SpawnDistance`      | 24, 44  | Blocks from a player a pack spawns (never within 24 of anyone).     |
| `Mobs.ForgetTicks`        | 6000    | A creature with no player within 128 blocks this long is dropped (memory). |
| `Mobs.TrackingDistance` / `SyncTicks` | 64 / 2 | Players see mobs this close; their state is sent every SyncTicks ticks while it changes. |
| `Mobs.AttacksPerSecond`   | 10      | Attacks a player may send a second.                                 |
| `Mobs.Rig.MaxRigs` / `MaxFull` | 40 / 16 | Most zombies drawn as R15 bodies, and as full ones (the rest of the nearest 40 as the simpler 8-box body, everyone else as two boxes). |
| `Mobs.Rig.FullDistance` / `ReducedDistance` | 16 / 40 | Blocks from where the player hears and sees (the camera, kept within 4 blocks of the eyes) within which a zombie is drawn in full / as the simpler body. |
| `Mobs.Rig.Hysteresis` | 4 | Blocks past a distance before a zombie's drawing changes back (and how much nearer a newcomer must be to take a capped place), so zombies at an edge don't flicker. |
| `Mobs.Rig.SpareFull` / `SpareReduced` | 12 / 16 | Bodies of each kind kept for reuse when zombies go (none are made while a horde comes and goes). |
| `Mobs.Rig.ShadowParts` | 3 | How many of the head, upper torso and lower torso cast shadows (the simpler body: of the head and torso); 0 for none. |
| `Apocalypse.Enabled` | true | The zombie apocalypse's rules: false turns off the director, noise, breaking, blood moons, bites, wounds, sprint noise, the day counter and its toasts (zombies then just hunt what they see; a saved infection is kept but dormant: nothing shows, grows, hurts or holds regeneration back, so turning it on again loses nothing). |
| `Apocalypse.Zombies.DaySpawning` / `DayFactor` / `DayLightBudget` | true / 0.35 / 2048 | Zombies spawn by day on floors under the open sky with no block light, the cap times DayFactor (the light search's cell budget: 2048 sees as far as a torch's light reaches on open ground, 13 blocks). |
| `Apocalypse.Zombies.CityFactor` | 1.75 | Caps times this while the player stands in a city. |
| `Apocalypse.Zombies.Separation` | 0.1 | Extra room (blocks) zombies keep from each other. |
| `Apocalypse.Zombies.ThinDistance` / `SightInterval` | 32 / 3 | An idle zombie this far from every player thinks every 4th tick; a chasing one checks its line of sight every 3 ticks. |
| `Apocalypse.Zombies.BreakReach` / `HuntBreakReach` | 8 / 16 | Zombies break blocks only this near (horizontally) what they go for / the player they hunt. |
| `Apocalypse.Zombies.HuntRadius` / `HuntKeep` | 44 / 56 | Blood moon: zombies this near a player hunt them, and keep on while this near. |
| `Apocalypse.Zombies.Leave` | Interval 600, Ticks 600, Distance 24, StuckTicks 400 | Leave rounds every Interval ticks by day; a zombie sent away walks off for Ticks and goes once Distance blocks from everyone and unseen; a hunter that got no closer in StuckTicks gives up. |
| `Apocalypse.Zombies.RiseOnDeath` / `RiseDelay` | true / 100 | An infected player's death raises a Zombie this many ticks later, where they fell. |
| `Apocalypse.Noise` | Sprint 8, Break 10, Glass 16, Place 6, Door 10, Container 6, Hit 8, Hurt 10, explosions 24 + 12 a power (56 at most), Scream 48 | Noise radii (blocks); × `NightFactor` 1.25 at night, × `RainFactor` 0.7 where it rains, × `SnowFactor` 0.85 where it snows; a zombie investigates for `InvestigateTicks` 400; at most `MaxPerTick` 32 a tick, merged within `Merge` 4; `Enabled = false`: none. |
| `Apocalypse.Breaking` | Enabled, Decay 100, HitInterval 20 | Zombies breaking blocks; damage fades after Decay idle ticks; a thud every HitInterval ticks. |
| `Apocalypse.Infection` | 12000 × 4 stages | `StageTicks`, `Stages` (death at their product), `BiteAdvance` (2400: a bite while infected), `RollInterval` (100: one roll a player), `ArmorShield` / `ArmorShieldMax` (0.0375 a point, at most 0.75), `DamageInterval` (100: stage IV's half heart); `Enabled = false`: no bite infects. |
| `Apocalypse.Bleeding` | 400 ticks, amplifier ≤ 1 | `Ticks` a wound gives at least, `MaxAmplifier`; `Enabled = false`: no wounds. |
| `Apocalypse.BloodMoon` | Every 3, First 3, Start 12500, End 23500, Ramp 600 | Blood moons: every Every-th night from the First, Start to End ticks into the day, ramping in and out over Ramp; `Enabled = false`: none. |
| `Apocalypse.BloodMoon` waves | WaveInterval 600, WaveBase 6, WavePerMoon 2, CapBase 24, CapPerMoon 4, CapMax 60, HuntInterval 100 | Waves of WaveBase + WavePerMoon × k a player every WaveInterval ticks into a cap of CapBase + CapPerMoon × k (at most CapMax), k the moon's number; hunts given out every HuntInterval ticks; the world's limits `MaxMobs` / `MaxHostile` 360 / 260 meanwhile. |
| `Apocalypse.BloodMoon.Tint` / `TintStrength` / `MoonSize` | {170, 28, 28} / 0.55 / 1.6 | The red sky: the light's and haze's tint at full strength, the moon's size (times the place's). |
| `Apocalypse.Survivor` | DayCounter true, SyncTicks 1200 | The day counter for everyone (false hides it whatever the setting says); how often the server sends each player their record. |
| `Mana.Enabled`            | true    | Terraria's mana: the MANA status icon, regeneration, magic weapons, mana potions' mana and Fallen Stars (false: none of it; the store still saves what a character has). |
| `Mana.Base` / `PerCrystal` / `MaxCrystals` / `Max` | 20 / 20 / 9 / 400 | Mana to start with, per Mana Crystal used, crystals usable (200 with nine), and the most with accessories. |
| `Mana.SicknessSeconds` / `SicknessMax` / `SicknessDamage` | 5 / 10 / 0.05 | Mana Sickness: seconds each mana potion adds, the most, and the share of magic damage cut per second left. |
| `Mana.HudLinger`          | 3       | Seconds the MANA status icon stays lit after mana changed (it is also lit while a magic weapon is held or mana isn't full; dimmed otherwise). |
| `Mana.Stars`              | PerNight 5, 16..48 blocks, 40 high | Fallen Stars: about PerNight a night for each player, onto the top block of a column MinDistance..MaxDistance blocks away, from FallHeight above it, between NightStart 13000 and NightEnd 23000 (the ones on the ground vanish at NightEnd); `Enabled = false`: none. |
| `Weapons.Enabled` | true | Firearms fire (Shared/Weapons); false: they bash like clubs and no shot is sent or taken. |
| `Weapons.PvP` | true | Bullets, pellets and bolts hurt players (false: they fly through them). |
| `Weapons.ZombieHead` / `MobHead` / `PlayerHead` / `HelmetShare` | 3 / 2 / 2 / 0.6 | A head hit's damage factor on zombies, other mobs and players; a zombie whose look wears a helmet, hard hat or fire helmet takes HelmetShare of its head factor. A mob's head takes no armour, a player's only the helmet's. |
| `Weapons.Gravity` / `MaxRange` / `SegmentSeconds` | 9.8 / 256 / 0.05 | A shot's flight: gravity (blocks/s²), the longest flight (a round's range × 2.5, at most this), seconds of flight a traced segment. |
| `Weapons.ShatterGlass` / `ShatterBlocks` / `GlassShare` / `PassLeaves` | true / { "Glass" } / 0.7 / true | Glass shatters under a shot (only for a shooter who may build) and the bullet goes on with GlassShare of its damage; leaves let it by. |
| `Weapons.BulletKnockback` / `PelletKnockback` | 0.1 / 0.05 | Knockback of a bullet and of each pellet that hits (a shot's pellets 0.4 at most). |
| `Weapons.BleedChance` | 0.5 | A firearm's hit on a player opens Bleeding this often (the apocalypse's Bleeding rules). |
| `Weapons.ShoulderSpread` / `MovingSpread` / `CrouchSpread` | 1.8 / 2 / 0.8 | The gun's spread times these: raised over the shoulder (not in the sights), moving, crouching. |
| `Weapons.MovingSway` / `CrouchSway` / `HurtSway` / `ShoulderSway` | 2.5 / 0.6 / 1.5 / 1.3 | The sway times these: moving, crouching, under half health, not in the sights. |
| `Weapons.HoldBreathSeconds` / `OutOfBreathSeconds` / `HoldBreathSway` / `OutOfBreathSway` | 3 / 3 / 0.15 / 1.5 | Holding breath in the sights (the sprint key): how long it steadies the aim, how long the player is out of breath after, and the sway's factor in each. |
| `Weapons.RecoilRecover` / `RecoilRecoverSeconds` / `CrouchRecoil` / `ShoulderRecoil` | 0.6 / 0.25 / 0.8 / 1.2 | The share of each kick that comes back and over how long; recoil times these crouching and over the shoulder. |
| `Weapons.JamChance` | { 0, 0.002, 0.01, 0.04, 1 } | A shot's jam chance by condition (Pristine, Worn, Damaged, Badly damaged, Ruined), the gun's and its magazine's added. |
| `Weapons.RaiseTicks` / `UnjamTicks` / `ModeTicks` | 6 / 40 / 4 | Ticks a raised gun waits before its first shot, clearing a jam takes and switching the fire mode takes (a reload's, a chambering's and a round's are each gun's own in Weapons/WeaponList). |
| `Weapons.RaisedSpeed` / `SightsSpeed` / `GuardSpeed` | 0.65 / 0.5 / 0.5 | Walking speed raised, in the sights and guarding with a melee weapon (no sprinting in any). |
| `Weapons.IronSightsZoom` | 1.15 | The field of view is divided by this in iron sights (an optic's or a built-in scope's own zoom instead). |
| `Weapons.ShoulderOffset` / `ShoulderDot` | { 1.6, 0.4, 0 } / true | Raised in third person: the camera over the right shoulder (studs right, up, back; only with `Camera.Enabled = false`, the DayZ camera's `Camera.Profiles` have their own) and the centre dot. |
| `Weapons.ImpactNoise` / `SuppressedMinNoise` | 8 / 8 | The noise (blocks) where a shot lands this far or more from the shooter, and the least a suppressed shot makes (a gun's own noise is WeaponList's). |
| `Weapons.OriginSlack` / `DirectionSlack` / `ShotsPerSecond` / `LagCompMax` | 2.5 / 0.01 / 20 / 2 | The server's checks: the claimed eyes' distance from its own, the aim's slack from a unit vector, shots a player may fire a second (bursts of twice that), and how far a mob's last-sent position may be from where it is to count for lag compensation. |
| `Weapons.ShotBroadcast` / `FarSound` | 256 / 64 | Who is sent a shot (blocks from the muzzle, horizontally), and beyond what distance its far rumble plays instead. |
| `Weapons.Tracers` / `TracerSeconds` | true / 0.06 | Tracers, and how long they show. |
| `Weapons.BoltRecover` | 0.7 | A crossbow bolt that stopped in a block drops as an item this often, one that hit a mob or a player half as often. The one chance: WeaponList's `recover` only says which rounds may be found again. |
| `Weapons.Melee.Enabled` | true | The melee rework (light attacks on release, heavy attacks, the guard, finishers); false: every attack as before. |
| `Weapons.Melee.HeavyHold` / `HeavyKnockback` / `HeavyExhaustion` | 0.45 / 0.8 / 3 | Seconds held for a heavy attack, its knockback, and its food (times a light hit's exhaustion). |
| `Weapons.Melee.GuardCone` / `FinisherCone` / `FinisherMaxHealth` | 0.5 / 0.5 / 30 | The guard's front cone and the finisher's back cone (cosines: 120 degrees each), and the most health a zombie may have to die to a finisher. |
| `Turrets.Enabled` | true | Turrets (Shared/Turrets): false makes the game as before: turrets tick inert ("Disabled", no energy taken), no recipes or Ages for turrets, their parts or the Laser Sight (the Servo Motor's stays while the Ammo Press is on), no simulation, no Turrets messages, no line waits for a turret (the blocks and items stay registered). |
| `Turrets.Types` | smg, rifle, sniper | Per type: its round and stand-in gun (`ammo`, `firearm`: the fire sound, the noise, a muzzle device's effects), `damageScale`, J a `shot`, the most degrees off its aim it fires at (`settle`), the barrel's length, the lowest pitch it aims at (`pitchMin`: the lowest whole degree at which its drawn gun clears its own block, every tier, mount and yaw, never under PitchMin: SMG and rifle -60, sniper -51), and per tier (Basic, Advanced, Elite, Ultimate) `range`, `rpm` (whole rounds a minute), `buffer` (rounds its ammo slot holds), `turn` (degrees a second) and `spread` (the cone's half angle). SMG 16-32 blocks, 90-360 rpm, 2-6 rounds; rifle 24-48, 45-180, 1-4; sniper 40-64, 15-40, 1-2. |
| `Turrets.Capacity` / `IdleJoules` / `TrackingJoules` | {20, 40, 80, 160} kJ / {4, 8, 12, 16} / {8, 16, 24, 32} | Per tier: the energy store (also what the network may put in a tick), and J a tick idle and while tracking a target. |
| `Turrets.Optics` / `Muzzles` | Laser Sight, Rifle Scope / both suppressors | The optic slot's items: the Laser Sight (every type: the cone × 0.5, a rescan every 5 ticks), the Rifle Scope (rifle and sniper: the range × 1.25, a sniper aims at heads). The muzzle slot's: their WeaponList numbers apply (on every type). |
| `Turrets.NoiseScale` / `ShotNoiseTicks` | 0.75 / 20 | Gunfire's noise: the stand-in gun's (with its muzzle device) times this, at most once every ShotNoiseTicks a turret. |
| `Turrets.Lure` | Enabled, Noise 24, Ticks 600, Cell 48 | The lure: a powered, armed turret with no target and its Lure on makes a Noise-block noise (more at night) every Ticks while it is night or a blood moon, at most one a Cell × Cell blocks. |
| `Turrets.ScanTicks` / `SightTicks` / `LoseTicks` / `MaxSightChecks` | 10 / 4 / 10 / 6 | Targeting: a scan every ScanTicks (a Laser Sight's own 5), the target's sight checked every SightTicks and lost after LoseTicks unseen, at most MaxSightChecks candidates looked at a scan: best first, those not yet looked at in vain in the scans' pass down the ranking (the best three again every second scan), so zombies hidden behind a wall never hide one in sight next to the gun for more than a scan or two, nor one further down for long. |
| `Turrets.MaxScansPerTick` / `MaxShotsPerTick` | 16 / 32 | Every turret together a tick (a scan over it waits a tick; a shot over it waits a tick, losing none). Those waiting go first, the longest waiting first, so none starves and every turret gets its share. |
| `Turrets.MinRange` / `PitchMin` / `PitchMax` / `ExtraFlight` / `MaxRange` / `FiringTicks` | 1.5 / -60 / 75 / 16 / 80 / 10 | Nothing nearer than MinRange; the gun's pitch limits (degrees: PitchMin the lowest any type aims at, each type its own `pitchMin` at or over it, below which is a dead zone); a shot flies ExtraFlight past the turret's range; no range beyond MaxRange (a scope's included); "Firing" shows FiringTicks after a shot. |
| `Turrets.FeedTicks` / `FeedRateTicks` | 20 / 100 | The feeder rule's look at the transporters around a turret every FeedTicks; the panel's "In: x/s" averages arrivals over FeedRateTicks. |
| `Turrets.RecordRange` / `RecordTicks` / `RecordAngle` / `RecordRefresh` | 224 / 2 / 3 / 20 | Turrets messages: to players within RecordRange blocks sideways (as far as edit lists go: past every chunk a client keeps records for, 207 blocks at the highest Full Detail; where a player was last seen while respawning), at most every RecordTicks a turret, when its target, flags or rounds change or its aim moved RecordAngle degrees, and every RecordRefresh ticks while it tracks. |
| `Turrets.Client` | DrawDistance 96, MaxDrawn 48, MaxParts 720, BeamLength 24, ServoLoops 4 | The client: turrets drawn within DrawDistance of the camera, at most MaxDrawn from MaxParts pooled parts; a Laser Sight's beam at most BeamLength; the servo loop at the ServoLoops nearest turning turrets. |
| `Miner.Enabled` / `Capacity` | true / 200000 | The Metal Miner: false makes it inert with no recipe; its energy store (J, before Energy Upgrades). |
| `Miner.Ores` | none | Per ore block: ticks an item takes and J a tick (Speed and Energy Upgrades change both, Mekanism's maths), and the least J an item costs whatever the cards (`floor`: coal never makes more energy than it took). For ores whose pack entry has no `miner` of its own; every ore's entry carries its own: coal 600 at 800 J/t with a 400 kJ floor, iron and osmium 400 at 200, gold 800 at 300, emerald 3600 at 800, diamond 4800 at 800, the new metals 400 at 200, sulfur and saltpetre 600 at 200, uranium 3600 at 800. |
| `AmmoPress.Enabled` / `Capacity` / `Ticks` / `Joules` | true / 20000 / 200 / 50 | The Ammo Press: false makes it inert with no recipe; its store; an operation's ticks and J a tick (before upgrade cards). |
| `AmmoPress.Calibres` | 16 9mm, 10 5.56, 5 .308 | What a Brass Ingot, a Lead Ingot and a Gunpowder make, by the Calibre button's choice (in order). |
| `Camera.Enabled` | true | The DayZ camera (client `Player/CameraRig`): over the shoulder or from the eyes, freelook, focus, the body facing the aim and drawn in first person. false: Roblox's camera exactly as before (its zoom; shift lock, which the server gives back through `Player.DevEnableMouseLock`; `Weapons.ShoulderOffset` while raised; the body turning where it walks at `Movement.TurnSpeed`; Minecraft's hand; the crosshair for a gamepad only). |
| `Camera.DefaultView` / `FirstPersonBody` / `FreelookToggle` | "third" / true / false | The Camera, First-Person Body and Freelook settings' defaults. |
| `Camera.Profiles` | standing { 4.8, 0.9, 0.25, 0 } | The third-person camera by what the body does: { distance behind the pivot, shoulder, height above the eyes, forward } in studs (DayZ's third-person cameras, × 3): `standing`, `sprinting`, `crouching`, `lying` (crawling, swimming), `climbing`, `flying`, `raised` (a firearm: 2.4 behind, 1.5 to the side), `raisedHands` (a melee guard), `crouchRaised`; a change eases over DayZ's blend times. |
| `Camera.FreelookYaw` / `FreelookYawFirst` / `SnapBackSeconds` | 160 / 100 / 0.14 | How far freelook turns the view from the aim each way (degrees; from the eyes the neck's 70 and the waist's 30), and the smooth time it swings back in (DayZ's). |
| `Camera.Margin` / `EaseOut` | 0.3 / 6 | Blocks and the third-person camera: the gap kept behind it (studs) and how fast (per second) a camera pulled in eases back out. The near plane kept out of blocks is measured from the camera every frame (its `NearPlaneZ`, field of view and screen), not configured. |
| `Camera.FirstForward` / `FirstDownPush` | 0.15 / 0.75 | The first-person eye point this far ahead of the hull's eyes, and this much more looking straight down (times the sine of the pitch: past the chest's front from 60° down, so its edge, the legs and the feet show, not the torso's top; back where a wall would cut the near plane) (a body part the camera's near plane would cut in view is hidden: Player/FirstPersonRules.clips). |
| `Camera.IdleTurnSeconds` / `IdleTurnMaxLag` / `IdleTurnSpeed` | 0.12 / 60 / 0.5 | Standing, the body turns to the aim over this smooth time and at most this many degrees behind; faster than this (blocks a second) it turns at once (and the legs twist into a strafe). |
| `Camera.FocusFov` / `FocusSprintFov` / `FocusSeconds` | 45 / 70 / 0.1 | Focus: the field of view (never wider than the FOV setting's), the one sprinting, and the smooth time of the change. |
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
| `Effects.Hud` | true | The status effect icons in the top right corner, the row in the open inventory's band and the list beside the other open screens (off: the status icons' badges show Climate Clemency, Internal Warmth and Chill too). |
| `Effects.NauseaRoll` / `NauseaFov` | 7 / 0.1 | Nausea's wobble at full strength: the camera's roll (degrees) and the field of view's sway (a share), times the Distortion Effects setting squared (Minecraft's screenEffectScale). |
| `Effects.NightVisionAmbient` | 150 | Night Vision raises the ambient light of caves and nights to this grey (0-255). |
| `Radiation.Enabled` | true | Uranium is radioactive: exposure, the dose, Radiation Sickness and the Geiger counter's clicks (false: none of it; a saved dose is kept). |
| `Radiation.Sources` | (none) | Sv/h a block or an item gives a block away or nearer (carried: times the count; a block's item as the block), by name, for content whose pack entry has no `radiation` of its own. Uranium's are on its Ores pack entries: Ore 1, Raw Uranium 0.3, Ingot 12, Nugget 1.33, Block of Raw Uranium 2.7, Block of Uranium 108. |
| `Radiation.Radius` / `Shielding` / `MaxRays` | 8 / Solid 0.5 / 32 | Blocks are looked for within the radius (inverse square, fading to 0 there); the share each block between lets through (any full solid block `Solid`; others by name, or their entry's `radiationShield`: the Block of Lead 0.02, the Block of Raw Lead 0.1); the nearest sources traced for shielding in one look (the rest take their octant's mean, unshielded where none was traced). |
| `Radiation.Hazmat` | (none) | The share of radiation a piece of armor worn keeps out, by name, for armor whose entry has no `shielding`. The Hazmat pieces carry theirs: 0.25 / 0.4 / 0.2 / 0.15 (Mekanism's: the whole suit all of it). |
| `Radiation.HalfLife` / `MinRate` / `Interval` | 600 / 0.0005 / 1 | Seconds for a dose to halve; the rate (Sv/h) below which there is none; seconds between two looks at a player. |
| `Radiation.Sickness` | Bands 0.1 / 1 / 10, Ticks 600, HungerFrom 2, NauseaFrom 3 | The doses (Sv) of Radiation Sickness I, II and III; ticks it lasts after the dose falls below its band; the levels Hunger and Nausea come with. |
| `Radiation.Clicks` | PerSvh 2.5, Max 16 | The Geiger counter: clicks a second at 1 Sv/h (with the rate's square root), and the most a second. |
| `Server.GenerationBudgetMs` / `UrgentGenerationBudgetMs` | 4 / 8 | Milliseconds a frame the server spends generating the chunks around players (a second generator, sliced: World/GenQueue); the urgent budget while a player's own chunk or one next to it is missing or more than `UrgentBacklog` (49) chunks wait. |
| `Server.FrameBudgetMs` / `MinGenerationBudgetMs` | 12 / 1 | The slice never takes the frame's work so far past FrameBudgetMs, but is always at least MinGenerationBudgetMs. |
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
| `Seasons.Enabled`         | true    | Don't Starve's seasons: Autumn, Winter, Spring, Summer (false: the game as without them; the debug worlds have none either). A world starts on Autumn's first day, and so does a world saved before the seasons or only ever played without them, the next time it is loaded with them on; one that had them comes back on the calendar day it was saved on, however long it was played without them. |
| `Seasons.Lengths` / `BlendDays` | 8, 8, 8, 8 / 2 | Days each season lasts (a year of 32 days, about 10.7 hours of play); every season quantity blends over BlendDays centred on each turn (at most the shortest season). |
| `Seasons.DaylightScale`   | 1, 0.8, 1, 1.2 | The sun's day share per season: winter's days are shorter (about 9 of 20 minutes) and summer's longer (12.7), the day length itself unchanged. |
| `Seasons.Climate`         | see Config | Per season (Autumn, Winter, Spring, Summer): DayShift -0.1 / -0.4 / -0.05 / +0.3 and NightDrop 0.3 / 0.35 / 0.3 / 0.25 (Tough As Nails' climate units, times a biome class's Amplitude: cold 1, temperate 1, dry 0.75, tropical 0.5); WeatherShift -0.2 / -0.8 / -0.1 / +0.2 on Minecraft's temperature (a winter plain snows); WetBias 0 / +0.02 / +0.06 / -0.08 and ThunderBias 0 / -1 / +0.04 / +0.02 (rain about 23 % / 26 % / 31 % / 14 % of the time, no thunder in winter); Growth 0.5 / 0 / 1.5 / 1 (plants' random ticks); HeatWave: a summer day is one with Chance 0.3 (never two in a row), +0.3 from 09:00 to 18:00. |
| `Seasons.Snow`            | see Config | Snow layers: each chunk near a player is visited 1 tick in 250 (TileChance; at most MaxTilesPerTick 8 visits a tick), one 4 x 4 tile that rises a layer evenly where it snows (chance: the precipitation) up to its cap (cold 6, temperate 3, tropical 1, dry 0; +1 every 64 blocks above y 160, a drift of one) and melts a layer at a time where it is warm (MeltChance 0.5 a visit, x MeltClear 2 on a clear day, MeltRain 2 in rain, MeltNight 0.5 at night), each column by the weather at its own top; the season's own snow also melts once the distant landscape's does (a taiga's spring), and snow never grows under a player or a mob (only their column waits); fire beside snow and a room at RoomMelt 3 or warmer melt it at every visit, heat sources within HeatMeltRadius 2 every HeatMeltSeconds 5 (each in turn, however many); `Ice`: still water freezes from its edges where it is cold enough to snow (never beside heat) and the weather's ice thaws back to the water it froze when warm (beside heat, or in spring; a player's pond too; ice a player places never thaws). Deep snow slows walking (0.9 / 0.8 / 0.75 from 3 / 5 / 7 layers); the Snow Layer stacks onto a layer; plants grow by the season (Climate.Growth); falling snow muffles zombies (Apocalypse.Noise.SnowFactor 0.85). |
| `Seasons.Rooms`           | see Config | Enclosed, insulated rooms: at most MaxVolume 1024 cells, 32 blocks across and 6 openings; FillsPerFrame 2 and FillMs 2 a frame. |
| `Seasons.Heat`            | see Config | Heat units a second each source gives a room (Campfire 20, Fire 15, Lava 10, lit Furnace 8, a working generator 10, a player 1, Wood Stove 30, Oil Heater 35, Electric Heater 40, Fan -10, Air Conditioner -40), the stove's StoveBurnFactor 4, the oil heater's tank and burn rates, the electric ones' J a tick per HU and the thermostats' -5..5. |
| `Seasons.Foliage` / `Clock` | see Config | Foliage colours through the year (keyframes per class, the snow dust, the sweep's budget: SweepWrites 1,500 colours and SweepMs 0.75 a frame; far meshes rebuilt when their palette moved past FarDeltaE 6) and the season clock beside the minimap (`Clock.Enabled`; Options > HUD > Season Clock; `Clock.Toasts`: the turns' and heat waves' toasts). |
| `Weather.Enabled`         | true    | false: always clear (no clouds, rain, snow or lightning; the debug worlds have none either). |
| `Weather.Cycle`           | true    | Minecraft's doWeatherCycle (false: the storms stand still and an override never runs out). |
| `Weather.Speed`           | 1       | How fast the weather clock runs (2: storms drift and change twice as fast). |
| `Weather.BlendSeconds`    | 5       | Seconds a `/weather` override blends in and out (Minecraft's 5).    |
| `Weather.ClearStartSeconds` | 300   | A new world's weather starts where its spawn stays dry this long.   |
| `Weather.Lightning.Enabled` / `MeanSeconds` / `Radius` | true / 20 / 64 | Strikes near players in thunderstorms: one every MeanSeconds at full thunder, within Radius blocks. |
| `Weather.Lightning.Damage` / `BurnSeconds` / `Distance` | 5 / 8 / 4096 | Half hearts and seconds of fire for the living within 3 blocks of a strike; clients within Distance are told (they see it within their view and hear it within `Distant.Hearing`). |
| `Weather.Fog.Rain` / `Snow` / `Thunder` | 0.6 / 0.4 / 0.45 | The fog at full rain, snow and thunder: the old view fog's distance this share as far; the Atmosphere's density for a view this share to `Lighting.Atmosphere.WeatherPower` as far. |
| `Weather.SoundSpeed`      | 343     | Blocks a second thunder travels (a strike is heard that much later). |
| `Weather.Precipitation.Radius` | 5 / 10 | Blocks around the camera rain and snow fall in on Fast / Fancy (Minecraft's). `Rain` / `Snow`: the image (rain rbxassetid://75812216912065, snow rbxassetid://12003098335), Length, Width, Speed, Color, Transparency. The strips are Beams, which lay an image's width along the fall: an upright image (streaks top to bottom) must be uploaded turned 90° counter-clockwise. `Sound`: the near rain loop's Volume, Hold, Smoothing, RoofMuffle. |
| `Weather.Wind` | on | The wind loop: Volume, Calm, PerSpeed (per block a second of wind), Storm, Altitude (From / To / Gain), Max, Roofed, RoofMuffle, Smoothing. |
| `Weather.Precipitation.Smoothing` / `ScansPerFrame` | 0.8 / 64 | Seconds the rain drawn takes to follow the weather; block columns whose roof is looked up per frame. |
| `Weather.Clouds.Altitude` / `Thickness` / `Cell` / `Cells` | 320 / 6 / 16 / 24 | Cloud base (blocks), fair-weather thickness, the nearest ring's cell and cells across a ring (Fast: cells twice as big, `FastCells` across, a block thick). |
| `Weather.Clouds.Drop` / `RainThickness` / `Tower` | 32 / 28 / 160 | Rain lowers a cloud's base and thickens it; thunder raises a tower. |
| `Weather.Clouds.CoverBase` / `Wavelength` | 0.22 / 96 | Share of a clear sky with clouds; a fair-weather cloud's size (blocks). |
| `Weather.Clouds.ShaftLevel` / `ShaftMin` | 1 / 0.4 | Rain shafts from this ring out, under this much precipitation. |
| `Weather.Clouds.PartsPerFrame` / `RefreshSeconds` | 48 / 4 | Cloud parts placed or removed per frame at most; seconds before the nearest ring is planned again (twice that for each ring further out). |
| `Weather.Clouds.Color` / `Dark` / `ShaftColor` / `Transparency` | white / near black / grey / 0.12 | Fair-weather and full-thunder colours (shades between), the shafts' colour, the clouds' see-through. |
| `Weather.Sky.CoverSun` / `Saturation` / `ThunderSaturation` / `Contrast` / `Tint` / `Smoothing` | 0.3 / 0.28 / 0.18 / 0.08 / cool / 1.5 | The sun hidden at full cover; the picture's greying, flattening and tint in rain and thunder; seconds the light takes to follow. |
| `Weather.Sky.Haze` / `ThunderHaze` | 1.8 / 1 | Atmosphere Haze added at full rain or snow, and more at full thunder (the horizon greys over). |
| `Weather.Bolt.Color` / `Glow` / `Flash` / `LightRange` | pale blue / 0.75 / 0.45 / 60 | The bolt's colour and glow, the sky's flash, the struck point's light (studs). |
| `Weather.Distant.Enabled` / `Rate` / `MinThunder` / `GroundShare` | true / 12 / 0.15 / 0.3 | Distant storms' lightning: flashes a minute per km² of full thunder (none below MinThunder), the share that are bolts to the ground (the rest light the cloud). |
| `Weather.Distant.PerMinute` / `FastPerMinute` | 24 / 12 | Most distant flashes a minute in reach (Fancy / Fast clouds; Off: none). |
| `Weather.Distant.Cell` / `Period` / `CellsPerFrame` / `MaxReach` | 128 / 2 / 128 / 4096 | The schedule's cells (blocks) and periods (s), the fewest grid cells sampled or rolled a frame (more when the frames are few, so a period is ready before it starts), the farthest a flash is made. |
| `Weather.Distant.MinDistance` / `Margin` / `Near` | 64 / 32 / 256 | No distant bolt within MinDistance of anyone or `Lightning.Radius` + Margin of a player in thunder; strikes farther than Near are drawn and heard as distant ones. |
| `Weather.Distant.Bolts` / `FastBolts` / `Glows` / `GlowParts` / `GlowRadius` / `Glow` | 3 / 2 / 4 / 6 / 96 / 0.85 | Far bolts and distant flashes at once; cloud parts a flash lights, within how many blocks, and how far towards the bolt's colour. |
| `Weather.Distant.PixelWidth` / `MaxBrightness` / `DayFlash` / `InCloudFlash` | 0.0026 / 20 / 0.3 / 0.5 | A far bolt's width per block away (about 2 pixels at 1080p), its most Beam.Brightness against the haze; the sky's flash by day (from Near on; nearer, less of a cut) and for an in-cloud flash. |
| `Weather.Distant.Hearing` / `MobileHearing` / `HalfVolume` / `InCloudVolume` / `Deepen` | 2048 / 1024 / 700 / 0.7 / 0.25 | How far distant thunder is heard, where it is half as loud, an in-cloud flash's share, how much lower at the edge. |
| `Weather.Distant.High` / `HighFloor` / `Mid` / `MidFloor` / `Low` / `Echo` | 10 / 40 / 2.5 / 15 / 2 / from 768 | Its muffling: dB less every 256 blocks past Near (highs, mids, down to their floors), dB more lows by 1024; one echo from Echo.From blocks. |
| `Weather.Distant.Voices` / `MobileVoices` | 3 / 2 | Distant sounds at once (the quietest gives way). |
| `Weather.Distant.Rain` | 4 rings to 168 blocks, 8 directions, volume 0.6 | The hiss of rain nearby: where it is listened for, Half (blocks at which it counts half), Volume, Muffle (dB), Smoothing, Interval; under a roof Roofed (0.5) of it, muffled by RoofMuffle. |
| `Weather.Map.MiniCells` / `WorldCells` / `RefreshSeconds` / `CellsPerFrame` | 48 / 96 / 3 / 1536 | The weather map's cells across (minimap, world map), seconds before a picture is drawn again, cells painted a frame. |
| `Lighting.CaveAmbient`    | 26, 26, 32 | How dark caves are; raise it like Minecraft's Brightness slider. |
| `Lighting.Enabled`        | true    | false leaves Lighting to the place, its own Atmosphere and Sky too (only the sun moves; the music and cave moods still follow the light). The project's Atmosphere (attribute `IceVoxel`) is taken out then, so the old view fog follows the view, the weather and the Fog setting. |
| `Render.Fog`              | true    | The Fog setting's default; false: no haze at all. |
| `Lighting.Atmosphere.Edge` / `Scale` | 0.1 / 0.1 | The light left at the view distance (0.1: 90% hazed) and the Atmosphere's Scale x Density^4 per stud (Roblox publishes no formula; calibrate it in Studio, see Config). Density 0.247 at 2048 blocks, 0.294 at 1024, 0.350 at 512, 0.208 at 4096. |
| `Lighting.Atmosphere.WeatherPower` | 1/3 | Rain, snow and thunder haze it as for a view `Weather.Fog`'s factor to this power as far (1/3 keeps the storm clouds overhead at most half hazed from 1024 blocks of view up; 1 would wash them out). |
| `Lighting.Atmosphere.RainDensity` / `ThunderDensity` | 0.44 / 0.667 | The Density the weather itself brings outdoors, rising with the rain to RainDensity and with a storm (or full snow) to ThunderDensity; the denser of this and the view's edge rule shows. At Scale 0.1 rain hazes things half at about 62 blocks, a full storm at about 12 (the clouds overhead and far lightning fade into it). 0 turns it off. |
| `Lighting.Atmosphere.ThinBelow` | 0.4 | Under this much sky exposure the haze thins out, by (exposure / ThinBelow)^2, so deep cave walls never fade into a daylit sky; the view out of a tunnel stays hazed for its first 9 blocks. |
| `Lighting.Atmosphere.Offset` / `ColorFloor` | 0.05 / 0 | How sharp a sky the haze fades into (low: the edge melts into it; high: silhouettes, LOD changes show); the time of day's haze colour raised to this at its brightest channel before the weather darkens it (0: Minecraft's own; raise it only if the night horizon looks black in the Roblox player). |
| `Lighting.Day` / `Night` / `Dusk` `.Haze` / `Glare` / `Decay` | 0.25 / 0.2 / 0.8, glare 0 / 0 / 0.4 | The Atmosphere's haze along the horizon, glow round the sun and colour away from it, blended like the light (the dusk glare only while the sun is above the horizon); its Color is `FogColor` (Minecraft's fog colours). |
| `Settings.Save`           | true    | Keep players' settings between sessions (DataStore, one profile per kind of device). |
| `Save.Enabled` / `StoreName` | true / "IceVoxelWorlds_v1" | Save worlds at all, and the DataStore they go in (a new name starts afresh; Studio needs API access). |
| `Save.Interval`           | 300     | Seconds between automatic saves (Minecraft's 5 minutes), each writing only what changed; 0: only `/save-all` and shutdown. |
| `Save.MaxWorldBytes` / `WarnShare` | 64 MB / 0.8 | The most a world may take in the store (a save past it is refused and operators are told); the chat warns operators past this share of it (again every 5% more). |
| `Save.KeyLimit` / `MaxKeyBytes` | 4194304 / 4000000 | Roblox's limit per key, and the text a region's key is filled to before it goes on in another part. |
| `Save.RegionChunks`       | 32      | Chunks per region side (512 × 512 blocks a key, Minecraft's region files). |
| `Save.LockTimeout`        | 180     | Seconds after which a world whose server stopped renewing its lock (a crash) may be opened elsewhere; the lock is renewed every third of it. |
| `Save.Items` / `Mobs`     | true / true | Also save dropped items, and farm animals (monsters are never kept). |
| `Save.LoadLatest`         | true    | With `MainMenu.Enabled` off, open the world played last (no other server having it) instead of making a new one. |
| `Settings.Key` / `GamepadButton` | P / DPadRight | Open and close the Options menu (the key: the Options key binding's default). |
| `Settings.ApplyDelay`     | 0.4     | Seconds after the last change before costly ones apply (view, caves, plants, shadows, textures, far meshes). |
| `Settings.SaveDelay` / `LoadWait` | 1.5 / 1 | Seconds before changes are sent to the server; seconds a joining client waits for its saved settings. |
| `Ui.QuickbarFadeAfter` / `QuickbarFadeTo` / `QuickbarFadeTime` | 0 / 0.6 / 0.6 | The quickbar's fade: seconds without hotbar activity before it fades (0: never, the default), the transparency it fades to, and how long the fade takes. |
| `Ui.InventoryBlur`        | 8       | How much the world behind an open inventory or creative screen blurs (BlurEffect.Size; 0: off); never on touch screens. |
| `Ui.GroundRadius` / `GroundRefresh` | 4 / 0.25 | The GROUND strip lists dropped items within this many blocks (0: none; the strip stays as the place to throw), looked up this often (seconds). |
| `Ui.StatusValues`         | false   | Numbers under the status icons (half hearts, points, the temperature, mana, armor); false: icons, colours and arrows only. |

Lighting comes from `default.project.json`: Future technology, shadows, a dark ambient light, an
Atmosphere (its daytime values: tests/spec/Atmosphere checks they match what the client writes)
and a Sky. With `rojo serve` into an existing place, check that `Lighting.Technology` is Future (or
LightingStyle Realistic in newer Studios). IceVoxel drives the Atmosphere and keeps a Sky you add
(its skybox colours the haze: the haze fades distant things into the sky behind them), and
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

**Far from the origin: the floating origin and "fake coords"** (`Origin`, `Players`, `Interest`).
There is no playable-area limit any more. Float precision used to make parts and characters
jitter beyond about ±16,000 studs (±5,000 blocks); now every client-made part is placed at world
studs minus a render origin that follows the camera (Shared/World/Origin, client Rendering/Rebase),
so near the camera parts stay within 8192 studs of 0 anywhere in the world (1/1024 stud). The
origin moves in steps of `Origin.Snap` (768 studs, 16 chunks): at once when the camera is
`Origin.RebaseDistance` (8192 studs) away along X or Z, and earlier, beyond `SoftDistance` (3072),
at a moment a hitch can't be seen (a teleport, a respawn, terrain loading, the world map, an
inventory screen or a menu). A move moves only what is on screen, in one `BulkMoveTo` (terrain,
far meshes, pipes, fire, lit TNT, structure outlines, rain, lightning, clouds, the crack overlay,
waypoint beacons); terrain kept out of the workspace under far meshes is moved a node at a time
when it is shown again. The Luau side of a move costs about 2 ms for the 17k parts on screen at
the default view with far meshes and about 6.5 ms for 80k (Lune, interpreted), plus the engine's
part reads and `BulkMoveTo`: F3's `origin` line shows both for real moves, and
`tools/probes/RebaseProbe` measures them in Studio (its README has the rule that picks the
distances). Every logic, message, save and command keeps true world coordinates (F3, `/locate`,
`/tp`, the maps); only drawing converts.

The server has no origin, and it no longer trusts or replicates where characters are. With
`Players.ServerPositions` every character stands parked and anchored at `Players.ParkPosition` on
the server, which is all Roblox replicates of it ("fake coords"): each client places its own
character from its hull and the others from what the server tells it. The server keeps where each
player is from their client's moves (20 a second), checked against `Players.MoveLimits` (blocks a
second per game mode, `MoveSlack` seconds of slack, knockback allowed for; `MoveCheck = "correct"`
sends a too fast player back as Minecraft's "moved too quickly", `"log"` only warns, `"off"`
trusts), and tells each player only about others within `Interest.PlayerDistance` (256 blocks,
kept until 16 more; spectators only to spectators, the spectated player always). Teleports go
privately to the player teleported. Edits reach players within `Interest.EditSendRadius` (14)
chunks (from the feet to the chunk's nearest point), a chunk's edit list and records (machines,
pipes, structure blocks) only come within `EditChunkRadius` (14, else the request waits until the
player comes near), and server lightning within `LightningDistance` (184 blocks; far storms are
the client's own): an edit or a strike that reaches you was made by, or fell next to, someone
within `PlayerDistance`, so building, digging and storms farther off tell nobody where anyone is.
A spectator follows, or without the operators' permission teleports to, only players they see.
Both switches are kill switches, and go off together: off, positions are read from the
characters, everything is sent as before and the origin stays at 0 (and the ±16,000 studs limit
is back).

**Studio checklist for the floating origin** (two players on a local server; what the Lune specs
can't see):

- **Park:** in the server's Explorer, A's HumanoidRootPart is at the park spot and anchored (in
  client B's only while A is out of B's interest, more than 272 blocks away: within it B draws A
  where A is), and on the server `Humanoid.Died` still fires for a parked character (else the
  HealthChanged fallback kills it).
- **Movement:** A walks, sprints, swims and flies; B sees A smoothly 0.1 s behind, at the right
  place, with animations playing on the anchored rig. Walk more than 272 blocks apart: A vanishes
  (no name, held item, flames, glow or minimap dot); back within 256: A reappears.
- **No rubber-banding** with `MoveCheck = "correct"` at a sprint, on ice, in creative flight and
  with Speed; an explosion's or a mob's push is not corrected (use `"log"` while tuning).
- **Spectators** are invisible to non-spectators; spectating a far target streams the chunks
  around it (the deferred requests), and the camera follows it.
- **Teleports:** `/tp`, `/locate`'s green coordinates, the map's teleport and a spectator's
  teleport snap the player with no flash of the park spot (0, 20000, 0); F3's `moves epoch` rises.
- **Death and rejoin:** the death tilt, the body hidden after a second, the terrain around the
  body staying until the respawn (dying far from the spawn), a clean respawn; a rejoin restores
  the saved position.
- **Spectating far players** (a published test place: in Studio everyone is an operator): a
  non-operator spectator's "Teleport to Player" to someone more than 256 blocks away answers
  "That player is too far away to teleport to", to someone near it works.
- **A forced move** (fly about 2,700 blocks: half a minute as a spectator; or, in a test copy,
  lower `Origin.RebaseDistance` to 300 and `SoftDistance` to 150, so every 100 blocks of walking
  moves it): no terrain seams, far meshes in place, no camera swing; clouds, rain,
  lightning, thunder, fire, pipes, transporter items, structure outlines, the crack overlay, debris
  and waypoints where they were; positioned sounds not jumping, the Nuke's cloud riding through it,
  no one-frame flash where shown nodes and far-mesh members are moved after parenting; F3's
  `origin` line updates.
- **The cost:** run `tools/probes/RebaseProbe.client.luau` on a PC and a phone and apply its rule
  (`tools/probes/README.md`) to `Origin.RebaseDistance` / `SoftDistance` and far meshes.

**Studio checklist for the zombie apocalypse** (still to take: the Lune specs, ApocalypseGlue
among them, play every rule out on a real world server, but only Studio shows how it looks, sounds
and costs on a device):

- **The rigs' cost:** run `tools/probes/ZombieRigProbe.client.luau` on a PC and on the lowest
  target phone (both passes, rigs and boxes), note its line (Lua ms median / p90 / max, frame ms,
  parts moved, rigs, parts made after the warm-up: 0, flames lost: 0) and apply the decision
  table in `tools/probes/README.md` to `Config.Mobs.Rig`; until then the rigs' cost on a low-end
  device is only Lune's (0.17 ms native, 0.97 ms interpreted a frame for 60 zombies).
- **The rigs' look:** every kind walking, running, crawling, hitting, hammering at a door and
  shrieking; a brute at a doorway and on a ladder; `/summon zombie_brute` and the other kinds.
- **A bite:** infection through a Herbal Poultice and Antibiotics (Weakness after a late cure),
  bleeding stopped by a Bandage, and an infected death rising as a zombie in the player's clothes.
- **A blood moon:** `/time set 61000` on day 3's night: the red sky, the bigger moon, the boom and
  toasts, waves of hunters on the ground (none on roofs); `/time set day` and `maxMobs` is back to
  320; zombies round a player sealed in a bunker walk off at dawn.
- **A horde breaking in:** a door, a plank wall and a Barricade of a city building giving way.
- **Hunger:** the sprint refused at 6 food with a real controller (the FOOD status icon is in the
  inventory and HUD checklist below).
- **The survival HUD:** the day line wrapping on an iPad (1180 × 820) the day before a moon, the
  toasts' widths, no "You survived" toast after dying under the moon; the regeneration pause with
  Tough As Nails' thirst and temperature and Minecraft's hunger all off; with `Characters.Enabled` off, the survivor
  record and an infection kept in the world's player record.
- **The bunkers:** the hatch by right click from above and below and its sound heard by the user,
  climbing out with the real controller, the caves revealed in the airlock.
- **The ruins:** city chunks, far massing and the map's overlay on a real client; the first
  wrapped column of a new city or road region on the client's main thread (1.6-2.2 ms median in
  Lune, up to about 5) in the MicroProfiler.
- **Old worlds and commands:** a world saved before the ruins (no `ruins` key) loads without them;
  `/locate structure #ruins`, `city` and `bunker`; `/locate poi medicine_cabinet`.

**Studio checklist for the inventory and HUD** (the survival look; the Lune specs check its layout,
rules and layers, not how it looks): at 1920 × 1080, 1366 × 768, 667 × 375 touch emulation and
568 × 320:

- **The inventory:** `E` opens three columns (two on a narrow phone); every click, shift-click,
  drag, double click, number key and `Q` works on every section and on the band's quickbar;
  folded sections take no clicks (and a folded BACKPACK or chest still counts what it holds); a
  chest, a crafting table, a furnace and each machine show in VICINITY with working gauges (a
  folded machine's energy bar and tanks give no tooltip); the grid lines and hairlines at
  fractional scales; the 360 px tall phones (800 × 360, 740 × 360) with the screen under the top
  bar and its band just above the bottom.
- **JEI and creative:** JEI docks in ITEMS and its `+` fills the 2 × 2 and the 3 × 3; the recipe
  view shows over the middle and right columns; creative's tabs switch, its grid scrolls and its
  thumb drags; the creative and recipe title bars beside the inventory's section bars, Back and
  close still clickable over them.
- **Equipment:** the eyes hide looks; closed accessory slots say when they open; HANDS follows the
  selected slot (and reads at UIScale 1.5); the player preview's camera, held item and looks.
- **Throwing:** a stack thrown on the GROUND strip and outside the screen, nowhere else; a touch
  tap on the strip does not close; the strip's items within 4 blocks, its polling cost.
- **The quickbar:** its numbers boxed over real item pictures (over, not under them; on the HUD
  and in the inventory's band, and after rebinding a key), the selection, no fade by default (and the fade with `Config.Ui.QuickbarFadeAfter` above 0); the
  attack indicator's cell; the spectator menu drawn on it; the creative row's clicks and hover;
  the touch buttons' hit areas and art; the chat's lines and "Chat disabled in client options."
  above the lifted quickbar at GUI Scale 1-3.
- **The status icons:** in the HUD (levels, blinking, arrows, badges and their numbers, the
  knowledge bar, the placement on each screen; starving, dehydrated, near death and freezing read
  as a red or blue blinking silhouette, and full idle mana as a faint whole star) and docked in the
  inventory's band while it is open (in the right place at its scale); the effect icons' row in
  the band beside the quickbar (every effect, squeezed when many); the Thermometer reading in the
  item-in-hands box; the frost and heat edges; the effect icons leaving the badges' effects out.
- **The recipe view:** VICINITY beside it keeps updating (a furnace's gauges, the GROUND strip)
  and takes no click, gamepad selection or tooltip (its bars, the creative "items" button, its
  slots); the effect icons' row moves under VICINITY, clear of the view, on each screen.
- **The look:** the tooltip's delay, picture, liquid pill and a count changing under the pointer;
  the drag outlines' colours; Roboto's weights (does Light exist?); UIStroke thickness under
  UIScale (`Theme.STROKE_FOLLOWS_UISCALE`); the silhouettes drawn through EditableImages and the
  blocky fallback without them; the vignette and blur (and the blur without the vignette);
  gamepad selection order and Focus red; ViewportFrame cost on a low-end device; Options, WAILA
  and the skill tree unchanged.

**Studio checklist for the weapons** (the Lune specs play the rules out: loading, every weapon
op's lock on both sides, the server's checks and traces, the client's aim, recoil, poses and shot
effects as pure rules; only Studio shows the camera, the models and the feel; two players on a
local server):

- **Loot and loading:** loot a city's police station and a bunker armory; load a 9mm magazine
  by dropping rounds on it (the orange outline; red on a .357 round), attach it to the pistol,
  take it off with a right click and with the MAG chip; the quickbar's and HANDS' round counts;
  swaps, partial loads and the unload order; the chips' readability at GUI scales 2-4 and with a
  gamepad; the tooltips' wrapping.
- **Raising and shooting:** raise with right click (the shoulder offset, the mouse locked to the
  centre with the default PlayerModule, the crosshair swapped for the dot), shoot a zombie in the
  head (it dies) and in the body (3 shots); the sights in first person and with `V` in third
  person, lined up at fields of view 30, 70 and 110 and with the sprint FOV; recoil through the
  camera hook (and its fallback); the sway, holding breath; the poses of R15 and R6 characters,
  the local player's and a remote one's raised and lowered, and the guns' size in the hand.
- **Reloading and modes:** `R` swaps to the fullest magazine and chambers (the bar, RELOADING);
  only chambering with no better magazine; empty the pistol (the dry click); the pump shotgun
  loads round by round and stops when fired; the assault rifle's `F` to automatic and recoil
  climbing; firing at 700 rpm costs little (tracers, flashes, the MicroProfiler).
- **Attachments:** mount a suppressor (the sound changes, zombies come from nearer), wear an
  improvised one out to Ruined (loud again); the Hunting Rifle's scope overlay; the red dot; the
  weapon light at night (`L`), on the held model in first and third person.
- **Condition and jams:** damage a gun to Badly damaged and see it jam (the jam click, JAMMED),
  clear it with `R`; a Ruined gun never fires.
- **Noise and others:** a shot heard from 100 blocks by the second client (the far rumble) and
  zombies converging on it; the second client hears the first's reload and chambering; glass
  shattered by a shot seen by both; a crossbow bolt found again and picked up.
- **Players:** a PvP hit and the Bleeding it opens (head and body, with and without a helmet);
  `Config.Weapons.PvP = false` lets bullets through; the aim dropped on death and respawn;
  spectators can't fire; creative fires without rounds.
- **Melee:** bash a zombie with a lowered rifle; a light hit on release, a heavy bat attack (the
  wind-up drawn back in first and third person), the guard (the weapon across the chest, half
  speed, no sprint; a zombie's hit from the front cut, item.melee.block heard), a knife finisher
  from behind on an unaware zombie; the feel of light attacks landing on release.
- **Touch and gamepad:** the AIM, FIRE and RELOAD buttons (their places beside the jump button,
  AIM's toggle), L2 / R2 / X / D-pad / R3 / L3 on a controller; a touch heavy attack.
- **The season clock:** the dial beside the minimap (and the Map button on touch screens) on a
  phone, a tablet and a PC at every GUI scale: crisp rotated bars, the disc, the pixel day number,
  the caption's real width (it drops before the dial shrinks on an iPad and a 1024 x 768 window);
  `/season set autumn 8`, `/time set 23400` and a minute's wait for sunrise: the toast and the
  boom (a jump of more than 600 ticks toasts nothing), with a blood moon's toast waiting its
  turn; the winter grading on snow by day, fading at dusk and gone at night (beside the blood
  moon's).
- **Snow:** a winter in a taiga and a plain (`/season set winter`, `/weather rain`, which snows
  where it is cold): layers piling evenly on roofs and ground, walking slowed in deep snow, a
  campfire and a warm room melting it, ponds freezing at their edges; a spring thaw leaving the
  save no bigger.
- **Foliage:** a year at speed (`/time add 2d` steps): grass, oak and birch leaves, vines and
  plants turning without a visible sweep or long frames (F3's foliage line: writes and frames per
  sweep; tune `Seasons.Foliage.SweepWrites` / `SweepMs`), far meshes rebuilding in waves through
  autumn (tune `FarDeltaE`), autumn leaves through the "leaves" texture (a warning names it if it
  is too dark to tint) and the grass tops and vine decals under the real MaterialVariants.
- **Rooms and heaters:** a planks house in winter with a campfire, then an Electric Heater: the
  thermometer's "Room +1 · Out -9", WAILA's room line, the panel's "-", "+" and On / Off buttons
  with the mouse, touch and a gamepad, "Set +1", no energy bar on the stove; the stove's and oil
  heater's glow and light, the loops (at most 6) and the click; the room fills' cost on a big
  build and in a cave (the 2 ms budget).

**Studio checklist for the turrets and the Metal Miner** (the Lune specs play the rules out: the
feed on the real pipes, the cadence, the kinds' energy and slots, the simulation, the guns' boxes,
the codecs; only Studio shows the look, the sound, the feel and the cost on a device):

- **Turret views:** TurretView's per-frame BulkMoveTo of about 600 parts with 30-48 turning guns on
  a low-end phone; the heads at each tier (the Basic band, the barrels) and no z-fighting between
  the turntable and the base's decor top; the barrel at steep pitches (never into the base at any
  pitch its type allows; near a diagonal the tracers under about −50° and an SMG's or a rifle's
  beam under −55° cross the base's corner); the laser beam by day and night, resized every frame;
  the servo loop not restarting; parked heads never seen in the workspace.
- **Shots:** the flash and tracer starting at the drawn barrel while the client is still turning;
  a suppressed turret's tracers plain; turret fire heard at the right class and far sound; shots
  with no shooter in ShotView; the server's mob ids matching the client's mob records.
- **Cost:** the server's tick on a Roblox server (not Lune) in a blood moon with 10-50 turrets and
  the real director (bursts of up to 4 machine ticks in one frame); Shots + Turrets + Machines
  bandwidth to a player beside a turret wall (a firing turret's Machines record changes every
  tick: 4 a second each).
- **Panels:** the turret's three outlined slots in a row, four lines and the Lure button at every
  GUI scale and on touch (the lines' width beside the energy bar: "Feed: Advanced → 150 rpm"); the
  miner's two lines and the press's line beside the energy bar, the press's Calibre button and its
  row of three inputs over the cards; JEI's "240 s, 3.84 MJ" in its 72 pixels, Pressing's three
  inputs and "10 s, 10 kJ" in its 54, the Duplicating and Pressing tab icons.
- **The Metal Miner:** on a diamond ore in an unloaded chunk (and after a server restart) it keeps
  mining and its chest fills; its grille's glow; transporters taking its output.
- **Sounds:** the miner's and press's hums and the servo (Ambience's nearest-loops cap) and their
  overrides from `SoundService.IceVoxelSounds`.
- **The lure:** zombies drawn by the lure and gunfire at night feel like "the turrets protect the
  base", not like a swarm: tune `Turrets.NoiseScale`, `Lure` and the rates from play.
- **Now:** a Basic Rifle Turret fed from a chest through one Basic transporter fills to its one
  round and the line keeps it full; with rounds it shoots a zombie walking up, never a cow or a
  player in the line, and draws zombies at night; a block over it shows "Blocked", a torch or one
  snow layer doesn't; the Lure button and a broken turret keeping its Lure off; the bases' decor at
  each tier.

`Seed = nil` gives every server a random world; set a number for a fixed one. With the title
screen off, `World.Type` picks the world type (`"default"`, `"superflat"`, `"void"`,
`"singleBiome"`, `"largeBiomes"`, `"debugBlocks"`, `"debugStructures"`, `"debugBiomes"`) and
`World.Options` its options, e.g.
`{ preset = "Bedrock,59*Stone,3*Dirt,Grass;Plains", decoration = true }` for superflat or
`{ biome = "Desert" }` for a single biome.

## Extending

**Content packs.** Blocks, items, recipes, tags, textures, loot tables, ore features, the Ages and
lore lines come from content packs, folders under `src/shared/Content/Packs/` that the game finds
and checks as it loads, like Minecraft's data packs (docs/ARCHITECTURE.md, "Content packs"). A
pack is a `pack` manifest (`{ order = 300, description = "..." }`) and any of `blocks`, `items`,
`recipes`, `tags`, `textures`, `loot`, `ores`, `ages` and `lore`, each a Luau module (its data, or
a function of `define`, the helpers in `Content/Define`) or a `.json` file. An entry carries what
other registries used to keep in tables of their own: `lore`, `texture`, `icon`, `age`, `skill`,
`knowledge`, `miner`, `radiation`, `fuel`, `tags`, `sounds`, `loot`... (`Content/Schema` lists
them all, and a misspelt field is an error naming the pack and the entry). Ids are given at load
in pack order, so content may be added anywhere; `override = true` patches another pack's entry.
A kind may also be a folder of files merged in name order (`Minecraft/blocks/terrain.luau`,
`blocks/plants.luau`...: a file a feature), so adding content may be adding a file. The game's
content is feature packs: Core (air, the Ages, the base tags), Minecraft, Mekanism, Survival
(Tough As Nails and the seasons), Terraria, Apocalypse, Turrets and Ores; each `pack` manifest
says what is in which file and where its code lives, and the examples below go in any of them.
`Content/Packs/Ores` is a whole feature (the new ores, the Hazmat suit) in a pack of its own, the
worked example.
`lune run tests/content new <Pack>` starts a pack with an example of each kind, and
`lune run tests/content` says what a pack is missing (the content tool, under Development).

**A block.** Add an entry to a pack's blocks: a file of the Minecraft pack's `src/shared/Content/
Packs/Minecraft/blocks/` (`building.luau` for a building block), or a pack of your own (above;
ids are given at load, so it may go anywhere):

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
told apart by pitch (the weather's too: `weather.rain` and `weather.rain.above` are the wind
pitched into a hiss, `entity.lightning_bolt.thunder` and `entity.lightning_bolt.impact` the
explosion pitched down; the distant storms' `entity.lightning_bolt.thunder.far` (a Sound named
`entity.lightning_bolt.thunder` serves it too) and `weather.rain.far` (looped) the same, lower
and muffled; each client plays them by itself). The weather ships real sounds this way:
`src/sounds/Weather.model.json` becomes SoundService.IceVoxelSounds.Weather, with four near and
ten distant thunder variants (picked at random), a minute-long rain loop (near rain and the
distant hiss play it looped, duller under a roof) and a wind loop (`weather.wind`: outdoors,
louder in a strong wind, a storm and high up, silent underground; Config.Weather.Wind). The
loops heard from all around (the rain on the player, the wind) play flat, so turning the camera
never pans them; the distant hiss is heard from the storm's side. Roblox's Doppler shift is off
(SoundService.DopplerScale 0). Edit that file to swap them. The zombies' voices ship the same way,
in `src/sounds/Zombies.model.json` (SoundService.IceVoxelSounds.Zombies): three groans
(`entity.zombie.ambient`, one at random, at the gait's pitch), a growl for every zombie voice's
hurt and two deaths for every voice's death. Each voice has its own Sounds, named by the event
(`entity.zombie.hurt` for most kinds, `entity.zombie_runner.hurt`, `entity.zombie_brute.hurt`,
`entity.zombie_screamer.hurt` and the same `.death`s), never by their category `entity.mob.hurt`,
which would make the cows growl too; their PlaybackSpeed keeps the kinds apart (brute 0.65,
zombie 1, runner 1.3, screamer 1.6), and each still varies by its event's pitch variance (as a
share of the event's pitch: about ±13% for the zombie's hurt, ±22% the brute's), never into its
neighbour's range, as the stand-ins never did. Swap a recording by editing its SoundId there;
delete a Sound and its event plays the stand-in again, as it does when a shipped Sound's file
fails to load (the game warns and leaves it out). To use your own, add a Folder named
`IceVoxelSounds` to SoundService (or ReplicatedStorage) and put Sound instances in it, named like
the event they replace:

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
`volume` and `pitch` in SoundList: block types have a `dig` clip and a `step` clip (walking, mining
hits, falls), scaled per action like Minecraft. Breaking and placing play the data sheet's
recordings (`GENERIC_BREAK`, `GENERIC_PLACE` in SoundList, given to every type at its `dig`
volume, pitch and variance, so each material still sounds its own), with the `dig` thud as their
fallback should one fail to load; glass keeps its shatter for breaking and water its splash. Swap
them there, or override one type (`block.stone.break`) or all (`block.break`, `block.place`) with
a Sound. A block's sound type is its entry's `sound` (`sound = "metal"`), else its
material's.

Eating and drinking loop the data sheet's recordings (`entity.generic.eating` and
`entity.generic.drinking`, their ids in SoundList; a Sound of either name replaces it and loops too)
while the use button is held on a food (medicine keeps its own sound) or a drink: the eater hears it
at once from their own client, other players near hear it too (the server sets the `IceVoxelUse`
player attribute while the use lasts), and it stops the moment the use ends (finished, cancelled,
another slot, death, leaving). Should a recording fail to load, Minecraft's clicks every 4 ticks
(`entity.generic.eat`, `entity.generic.drink`) play instead, never both; the burp after a food and
the last gulp after a drink stay either way. The apocalypse's sounds are events like the rest, so a
Sound of the same name replaces each: `entity.zombie.ambient` (a groan, played by each client;
shipped, as above), `entity.zombie.attack_wooden_door` and `.break_wooden_door` (a zombie bashing a
block and breaking it through), `entity.zombie_screamer.scream`, the voices' `entity.zombie.hurt` /
`.death` (and the runner's, brute's and screamer's own), `block.bunker_hatch.open` / `.close`,
`item.bandage.apply`, `item.medkit.use`, `item.pills.swallow` and `ambient.blood_moon.rise`. Server
scripts can play any event to the players near a point:

```lua
local Sounds = require(game.ServerScriptService.IceVoxel.Audio.Sounds)
Sounds.play("block.glass.break", x + 0.5, y + 0.5, z + 0.5) -- block coordinates
```

The fifth data sheet's recordings are events like the rest. `entity.player.attack.strong` /
`.weak` and `entity.bullet.flesh` play "Entity Hit"; a gun of a calibre with its own recording
plays `item.firearm.<calibre>.fire` (`9mm`, `556`, `308`) and `item.firearm.<calibre>.suppressed`
through a suppressor (Rendering/ShotRules.fireSound), heard as far as its class's shot, and every
other calibre keeps its class's (`item.firearm.<class>.fire`, `item.firearm.suppressed`); one Sound
named `item.firearm.fire` or `item.firearm.suppressed` still replaces them all. Lava's
`block.lava.ambient` is one loop at the nearest lava open to the air the client has sampled
(within 16 blocks). The working machines loop their hum: category `machine.hum` for the Electric
Furnace, Electric Heater, Air Conditioner and Ammo Press, `machine.heavy_hum` for the Metal Miner
and Oil Refinery (a Sound of either name replaces its group). `ambient.radiation.click` is the
Geiger counter's click, played flat while the player is exposed to radiation (client Audio/Geiger).

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
Surface = { { Id = "rbxassetid://...", Title = "" }, ... },  -- above ground by day
Night = { { Id = "rbxassetid://...", Title = "" }, ... },    -- above ground at night
Cave = { { Id = "rbxassetid://...", Title = "" }, ... },     -- in caves, day or night
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
- **Night:** on the surface at night (the game's own rule, `DayCycle.isDay` false at the server's
  clock: from a little before sunset to a little after sunrise, as the sky, the mobs and the
  zombies have it) a track comes from `Night`, by day from `Surface`. The time is read when a
  track is picked, so dusk and dawn never cut one. An empty `Night` list (or one whose tracks all
  failed to load) leaves the surface its `Surface` tracks at night too.
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
- **F3:** a `music` line shows the list (surface, night or cave), the track playing (or the time
  to the next) and the mood.
- **New data sheets:** `tests/spec/DataSheet.luau` lists every id the latest sheet brought and
  where each one is used (pack entries, music lists, shipped Sounds, catalogue events); copy its
  table for the next sheet so the same checks run on it.

**Pipes and tanks.** A transmitter is a block with `transmitter = { kind = "item" | "fluid", tier =
1..4, restrictive = true? }` and a tank one with `tank = { tier, capacity }` on its entry; the
per-tier numbers are Mekanism's, in `src/shared/Transmitters/Tiers.luau`. Any block with
`container` slots is an inventory transporters connect to (all slots from every side, unless it is
a furnace, `menu = "Furnace"`). Pipes and tanks carry every fluid of `Shared/Fluids` whose record
says `carriable`.

**A fluid.** Append it to `src/shared/Fluids/FluidList.luau` (ids are list positions, sent and
saved in items: at the end, and at most 255), its blocks with `define.fluid("<Name>", { color,
material, ... }, tickDelay)` in a pack's blocks (the same colour and light as its record), its
full bucket in the pack's items, and its flow rules to `RULES` in `src/server/Behaviours/Fluid.luau`
(slope distance, drop off, infinite sources, whether what it washes away burns). The registry and
the flow rules check they agree when the game loads. Its record decides the rest: `color` (pipes,
tanks, gauges, JEI), `light` (a lit fluid gets sparse lights and glows in pipes), `physics` /
`drag` / `push` / `swim` (players and dropped items), `damage` / `burnSeconds` / `extinguishes`
(lava's hurt and burning), `furnaceFuel` (its bucket's burn time), `fogColor` / `fogStart` /
`fogEnd` (the view from inside it) and its bucket sounds.

**A machine.** A machine is a block with `machine = { kind = "name" }` and `energy = { capacity =
J, input = J/t?, output = J/t? }` on its entry (output only: a generator; input only: a machine
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

**A plant.** Add it through Content/Define's `plant()` helper with `plant = { soil = "dirt" }` (or
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
`placeable = false` on its entry and named by that item's `places` (Minecraft's
ItemNameBlockItem): the item places it, is its drop and is what pick block takes, and keeps its
own model (the Survival pack's Mint and MintLeaves). A plant that spreads by itself gets a
behaviour of its own that keeps Plant's `onTick` and adds `onRandomTick` (`Behaviours/Herb`).
Generation grows it from a biome's `foliage` lists (`plants`, `flowers`, or `herbs` for rare
patches of their own; BiomeList).

**An item.** Items that are not blocks (armor, tools, materials) are a pack's `items` (the
Minecraft pack's `items/tools.luau`, `items/materials.luau`...). They are drawn from boxes measured
in pixels (1/16 block), so icons, dropped items and hands show them without any assets.

**A recipe.** A pack's `recipes` list them by item name, like Minecraft's data files (the
Minecraft pack's `recipes/` folder, a file a feature; a function-form module gets the helpers as
`define.shaped`, `define.shapeless` and `define.smelting`):

```lua
define.shaped({ "##", "##" }, { ["#"] = "Marble" }, "MarbleBricks", 4) -- anywhere in the grid
define.shapeless({ "Marble", "Coal" }, "DarkMarble")
define.smelting("Marble", "SmoothMarble")                               -- furnace
```

**A zombie kind (or any mob).** Append a kind to `src/shared/Entities/MobList.luau` (ids are list
positions, sent as a u8: at the end); everything else follows from its record. Zombie kinds are
data: an archetype is one `zombie({ ... })` call, the helper filling in what every zombie shares
(`hostile`, the apocalypse's rules, `follow` 24, `infect` 0.04, `bleed` 0.15, the zombie's
voice), the record its numbers, its R15 rig and its looks:

```lua
table.insert(list, zombie({
	name = "ZombieMiner", displayName = "Miner Zombie",
	width = 0.6, height = 1.95, eye = 1.74, health = 26, speed = 0.22,
	armor = 4, attack = 4, breakPower = 2.5,                     -- hits, and digs walls faster
	drops = { FLESH, BONE, { item = "Coal", min = 1, max = 3, chance = 0.4 } },
	spawn = { weight = 3, cityWeight = 1, hordeWeight = 2, group = { 1, 2 } }, -- wild, city, horde
	rig = { kind = "R15", gait = "shamble", width = 0.85 }, -- shamble, run, brute, crawl or lurch
	looks = wardrobe({                                           -- outfits, one picked by weight
		{ name = "Overalls", weight = 10, shirt = { 90, 80, 70 }, pants = { 50, 60, 90 },
			shoes = { 60, 44, 30 }, vest = { 50, 60, 90 },
			hat = { kind = "helmet", color = { 220, 190, 60 } } },
		{ name = "Shirtless", weight = 4, pants = { 60, 60, 66 }, legs = "shorts", torn = 0.4 },
	}),
	parts = standing(0.6, 1.95, { 90, 80, 70 }),                 -- far stand-in, WAILA's colour
}))
```

- **Abilities** are fields MobAI's zombie rules read, so no server code names a kind: `breakPower`
  (progress a tick on a block's `zombieBreak`), `hearing` (times a noise's radius), `scream = {
  radius, cooldown }` (a screamer's shriek), `fireImmune`, `knockbackResist` (0..1), `infect` and
  `bleed` (a landed hit's chances, before armor), `follow` and `chase`; `spawn.hordeGrowth` makes
  it more common each blood moon.
- **A look** is a row of `looks` (or `looksFrom = "Zombie"` to wear another kind's): `shirt` (nil:
  shirtless), `pants`, `shoes` (nil: barefoot), `sleeves` ("long", "short" or "none"), `legs`
  ("long" or "shorts"), `gloves`, at most two of `vest`, `stripes` and `hat` (`cap`, `helmet`,
  `hardhat`, `firehelmet` or `beanie`), and the `torn` and `blood` odds. Up to 31 looks a kind fit
  the variant byte with the skin tones, and every client dresses a zombie the same from its
  variant and id, so nothing more is sent. A new gait is a profile in client `Entities/MobRig`
  (`GAITS`) and a stance in `Shared/Entities/MobShape.GAITS` (its lean and droop: where bullets
  find its head); a new kind of motion is code in its `angles`.
- **Its voice:** the zombie's, or one of its own: a line in SoundList's `MOB_VOICES` (`{ kind =
  "zombie_miner", hurt = 0.9, death = 0.85 }` makes `entity.zombie_miner.hurt` and `.death`, which
  `sounds = { hurt = ..., death = ... }` names; swap them like any sound). Its knowledge goes in
  `Progression/Knowledge.MOBS` (else 3 a kill); `/summon zombie_miner` finds it by itself.

A creature (`hostile = false`, no `zombie`) is a plain record with Minecraft's numbers: `wander`
and `panic` speeds, `spawn = { weight, group }` (on grass, in the light), and at most 2 `parts`
boxes (+Z forward; `variants` recolour the first, as sheep's wool). From a server script:

```lua
local Mobs = require(game.ServerScriptService.IceVoxel.Mobs.Mobs)
local id = Mobs.spawn("ZombieMiner", x + 0.5, y, z + 0.5)     -- feet (blocks); a variant may follow
Mobs.damage(id, 4, nil, x, z)                                 -- half hearts, knocked back from (x, z)
for _, mob in Mobs.near(x, y, z, 16) do print(mob.kind, mob.health) end
Mobs.died:Connect(function(killer: Player?, kind: string, x, y, z, id)
	if killer then print(killer.Name, "killed a", kind) end
end)
Mobs.playerHit:Connect(function(player: Player, kind: string, damage: number, fresh: boolean, id)
	-- a zombie's hit landed (Apocalypse/Survival rolls its bites and wounds here)
end)
```

**Food and medicine.** An item's `food`, on its entry, is what using it does (Minecraft 1.20.5's
food component; `src/shared/Items/Foods.luau` reads every pack's): `food = { heal = 4, nutrition =
8, saturation = 0.8 }` (Minecraft's FoodProperties: food points and the saturation modifier, what it
does with hunger on; `heal` in half hearts with it off, and medicine's, which has no nutrition) with
an optional `effect = { kind = "hunger", chance = 0.3, ticks = 600 }` (Minecraft's Hunger; Tough As
Nails' Thirst with hunger off, or always with kind "thirst"), and for the apocalypse's tins and
medicine `useTicks` (the hold, 32 by default), `cures` (effect names: Bleeding, Infection),
`effects` (`{ effect = "Regeneration", ticks = 200, amplifier = 0 }`, given when it finishes;
amplifier 0 by default), `aftermath` (an effect after curing an infection that had reached a
`stage`: Antibiotics' Weakness), `setback` (the Herbal Poultice), `sound` and `burp`:

```lua
-- The Apocalypse pack's items/supplies
{
	name = "Bandage",
	-- ... its model, lore and icon
	food = { heal = 2, useTicks = 40, cures = { "Bleeding" }, sound = "item.bandage.apply", burp = false },
},
```

Any item with a `food` is used with its hold and no other change; `Foods.canUse` decides when (a
food bar under 20 for food, hurt for medicine and for food with hunger off, or something it cures,
or any time for a food with effects). The game refuses to load a food naming an unknown effect, one
with nutrition out of 1..20 and one that does nothing, naming the pack and the entry. The Minecraft
pack's `items/mobs` (the meat, Minecraft's numbers) and the Apocalypse pack's `items/supplies` (the
tins and medicine) list theirs in their headers.

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
lichen, ladders, rails and vines (the face looking away from what it hangs on or lies on) and for
doors (both sides of the panel: `OakDoor` covers a door's lower halves, `OakDoorTop` its upper
halves; the same picture serves both hinges, and the windows are wherever the picture is
see-through; give the item a whole-door picture in `Icons` too, as its model draws the boxes) and
`Sprite` for plants, rope, cobwebs and hanging roots (two crossed images). An entry also covers
the block's cave twin and the other blocks of its variant group (the six glow lichen sides, the
four ladders and vines, both rails, a tall plant's top half unless it has its own). A filled
texture changes some shapes: a ladder or rail with a `Front` image draws only that flat picture
(its rails and rungs, or iron bars, give way to it, as Minecraft draws a single textured quad),
and rope with a `Sprite` becomes two crossed images instead of its thin post; shaped blocks given
cube faces draw their boxes in that texture (the oak fence post takes `planks`, the moss carpet
`moss block`). Fluids, air, torches and
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

**Blank entries.** `Color = ""` means "not made yet": 82 textures wait for you (`--list` names
them; the apocalypse's rusty metal and bunker hatch among them, and its items' `Icons` are blank
too). While a
block's sides and top are blank it keeps its plain Roblox material and colour, as
without textures. A part takes one MaterialVariant on all six faces, so once its sides' texture is
filled in (or its top's, when the bottom has no other filled texture) its blank faces show that
one: a log's ends show the bark until `"log top"` is filled, cut sandstone's blank sides show the
sandstone top. A filled top that differs from the sides is drawn over the top face as an image.
`ShowMissing = true` draws the missing texture (`"missing texture"`) in place of blank textures, so
you can see in game what is left to make: on every face of a block whose sides are blank (unless
its filled top stands in for them), on blank tops, and on blank plant sprites and glow lichen. A
blank bottom, or blank sides under a filled top, show the block's texture as above unless they are
drawn as images of their own: bottoms with `Config.Textures.BottomFaces`, sides with `SideImages`.

**Tint** makes a texture take the voxel colour (the block's `color`):
- `true` (the default): the colour of the block it is drawn on, so one light image serves every
  wood: `"log"`, `"planks"` and `"leaves"` show oak, birch, spruce, acacia and jungle each in its
  own colour, and dry grass shows the grass top in its own colour;
- `false`: the image's own colours (ores, the grass side, glow lichen, flowers and mushrooms);
- a block name: that block's colour wherever it is drawn (`"dirt"` is `Tint = "Dirt"`, so the dirt
  under grass is dirt coloured, not grass coloured; `"asphalt"` is `Tint = "Asphalt"`, so a road
  line's sides stay as dark as the road beside them).

Several entries may share one image (the data sheets do it on purpose): cracked and mossy bricks
are the bricks' picture and cracked and mossy concrete concrete's, each tinted with its own voxel
colour (darker, greener), and the road lines' paint is asphalt's picture tinted white or yellow
until a painted line is made. Keep a road line's top filled: a blank top shows the sides' texture,
and the line would vanish into the asphalt.

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
- **Plants**, rope, cobwebs and hanging roots with a filled `Sprite` (`Config.Textures.Sprites`):
  two crossed see-through planes along the cell's diagonals carrying the image on both sides,
  offset and turned like the boxes; grass and ferns take their soil's foliage colour. Blank
  sprites keep their boxes.
- **Glow lichen, ladders, rails and vines** with their `Front` texture: the plate goes see-through
  and shows the image on its face away from the wall (or up, for a rail), and only the plate is
  drawn: a ladder's rails and rungs and a rail's iron bars give way to the picture (draw them into
  the image); the lichen's glowing speck stays. A blank Front keeps the boxes.
- **Shaped blocks with cube faces** (the oak fence post's `planks`, the moss carpet's `moss
  block`): their boxes take that texture's material and variant near you, without images.
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
- the fourth sheet's rows are named loosely: "Concrete" is `"concrete"`; "crate" fills the supply
  crate's `"supply crate side"` and `"supply crate top"`, and "cabinet" the medicine cabinet's
  two, each pair with one picture; "moss" ("All things moss") is `"moss block"`, which the moss
  block and the moss carpet share;
- cracked asphalt uses andesite's maps (the sheet: "Yes uses andesite textures"), and asphalt
  polished andesite's, as the sheet gives them; cracked and mossy bricks keep the bricks' maps,
  tinted by their own colours ("maybe darker tint", "maybe greener tint");
- not on the sheet, by decision: cracked and mossy concrete take concrete's maps and the two
  road-line tops asphalt's, all tinted by their own colours (so the lines' white and yellow paint
  shows; a blank top would show the asphalt sides' picture and the line would vanish);
- the vine's normal map (`97312068579996`) is kept in the pack but never drawn: the vine is a
  plate, whose picture is a Decal, and a Decal takes no normal map.

**Spawn safety.** `src/server/Players/SpawnUnsafeBlocks.luau` lists what a player must not stand on
(`Floor`), stand in (`Body`, fluids by name) or touch (`Hazards`), plus the headroom and search
radius. Spawns and map teleports search outward for the closest spot that passes, and never put
players below the natural surface (caves), nor at the bottom of a pit or a ravine (the floor at
the natural surface must be solid); the generator's spawn also skips columns a surface cave
opens.

**The map.** The minimap and world map draw terrain with EditableImage. That API works in Studio
right away, but **published games** need the experience owner to be 13+ and ID verified and to turn
on *Enable Mesh / Image APIs* (Creator Dashboard, experience settings). Without it the maps still
show players and waypoints, and the right click menu still works (the weather mode needs it too:
without it only its wind and buttons show). Teleporting is controlled by `Config.Map.Teleport` and
checked by the server.

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
next id (ids are saved and sent: never reuse or renumber one; plain settings stay below 128, where
the key bindings' ids start), its kind, range, step, default,
page and the effect key that applies it; put it on its page in `src/client/Settings/Pages.luau`;
and register what the effect does in the client script (`Settings.register("myEffect", fn)`, `fn`
taking the values table). Costly effects also go in `PlayerSettings.EXPENSIVE` (they wait until a
slider stops), and `EFFECT_ORDER` says in which order effects run. Settings marked `preset` take
their value from each of the `PRESETS`. Worker actors keep their own Config, so anything a worker
needs travels in its jobs.

**A key binding.** Append an action to `ACTIONS` in `src/shared/KeyBindings.luau` (its place is
its settings id from 128: never reorder) with Minecraft's name, a category, its default (an
`Enum.KeyCode` name or `MouseButton1`..`3`) and a context ("game": in the world; "screen": in the
inventory screens; "universal": both, which decides what conflicts). It shows on the Key Binds
list by itself. Where the input is handled, ask `Keybinds.matches("myAction", input)` (a press or
release) or `Keybinds.isDown("myAction")` (held), never a KeyCode; `Keybinds.name("myAction")`
gives the key's name for hints.

**A chat command.** Make a `TextChatCommand` on the server with its alias (`PrimaryAlias =
"/mycommand"`, a `SecondaryAlias` too if you like), connect `Triggered` (it gets the sender's
TextSource and the text) and parent it to TextChatService, as `Players/TimeCommands` does; answer
with `Notice` messages (`Protocol.encodeNotice`), which show in the chat in white. The chat (client
`Ui/Chat`) completes its name with `Tab`, suggests it while it is typed and sends it to
TextChatService, which runs it and shows it to no one; a command no TextChatCommand has is never
sent. Who may use it is yours to check on the server: the operators' permission is
`Players/Operators.permitted(player)` (operators, or everyone with Allow Commands; `isOperator`
for operators only). Mark the command with that rule (`instance:SetAttribute(WorldSettings
.COMMAND_ATTRIBUTE, WorldSettings.COMMAND_PERMITTED)`, or `COMMAND_OPERATOR`) and the chat offers
it only to players who may use it. Pure parsing (see `Players/TimeCommand`) keeps it testable.
With the legacy chat, read `Player.Chatted` instead (the game's chat needs TextChatService and
leaves Roblox's in place there).

**State saved with the world.** Something of your own that a saved world should keep (a clock, a
round's scores) registers a section with the server's `World/WorldSave`:
```lua
WorldSave.registerSection("arena", function()
	return { round = Arena.round(), scores = Arena.scores() } -- small, JSON-able
end, function(value)
	Arena.restore(value) -- once, when a saved world with it starts
end)
```
`encode` runs at every save (keep it cheap: it runs in the save's frame) and goes in the world's
record; `decode` runs once when a saved world starts, after every part of the server started and
before anyone is in, or at once if you register later. A section the world never saved gets no
call. Names are the world's: "time" (the day clock) and "weather" (`World/WeatherServer`'s
`encode` / `decode`) are taken. Block state belongs to the blocks instead: it is in the edits, or in `Players/Containers`
like a chest's (see `Save/WorldSnapshot` for what else regions carry).

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

**A flammable block.** Give its entry `flammable = { ignite = 5, burn = 20 }` (Minecraft's
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
can go into `HeatingBlocks` before it exists (the Campfire's entry says `heats = true` instead).

**Drinks and containers (Tough As Nails).** An item's `drink`, on its entry, is what drinking it
gives (`Shared/ToughAsNails/Drinks` reads every pack's): `thirst` points and the `hydration`
modifier, dirty water's `chance` of TAN's Thirst effect for `effectTicks`, `warmth` / `chill`
ticks, `effects` (by name, as a food's), `mana`, the `empty` container it leaves (an item name;
none: it is used up) and `sips` for a canteen (its `durability` is its sips). Numbers left out are
0. Two tables in Drinks tie the containers together: `FILLS` (an empty container and the dirty
water it fills with at a water source) and `PURIFIED_OF` (dirty water and its purified twin). A
new container is two entries' `drink`, a line in each table and its recipes, as the bowls are:

```lua
-- The Survival pack's items/drinks
{ name = "DirtyWaterBowl", --[[ ... ]] drink = { thirst = 4, hydration = 0.3, chance = 0.5, effectTicks = 300, empty = "Bowl" } },
{ name = "PurifiedWaterBowl", --[[ ... ]] drink = { thirst = 7, hydration = 0.45, empty = "Bowl" } },
-- Drinks.FILLS
[I.Bowl] = I.DirtyWaterBowl,
-- Drinks.PURIFIED_OF
[I.DirtyWaterBowl] = I.PurifiedWaterBowl,
-- The Survival pack's recipes: the furnace and mint
define.smelting("DirtyWaterBowl", "PurifiedWaterBowl")
define.shapeless({ "DirtyWaterBowl", "MintLeaves" }, "PurifiedWaterBowl")
```

A drink of its own (the teas, a juice) is only an entry's `drink` with the container it leaves
(Mint Tea's is `{ thirst = 7, hydration = 0.6, chill = 2400, empty = "Bowl" }`); `warmth` /
`chill` ticks give TAN's Internal Warmth / Internal Chill, which move the temperature target 5
steps towards neutral without pushing it past neutral. Status effects or mana make a drink a
potion, drunk any time (the Apocalypse pack's Soda, the Terraria pack's mana potions). Drinks
with the same numbers are one drink, so bottled water is purified water (the tooltip's "Water"
pill too). Every `PURIFIED_OF` pair also boils clean on a Campfire (`ToughAsNails/Boiling`) and
shows in JEI's Campfire tab, with nothing more to add.

**Insulating armor (Tough As Nails).** An armor piece's `tan = { warmth = n, cooling = n,
freezeImmune = true }` on its entry: `warmth` steps pull a cold target up towards 0, `cooling`
steps pull a hot one down, never past it; `freezeImmune` stops hypothermia (leather has it). A
full set at 2 a piece keeps a tundra (-10) neutral (-2); straw (warmth 1) and leaf (cooling 1)
sets are made the same way, by Content/Define's `armorSet` in the Survival pack's
`items/gear.luau` (a material: name, colour, material, points, toughness and `tan`).

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
ingredient; the potion with Glow Dust or a coal) and the drinks (each item's `drink`: the effect
given when the 32 tick drink finishes, the Glass Bottle back), with nothing else to
add. Leave `seconds` out for an instant effect (`strong = true` for its II).

**A fluid's effects.** A fluid's `effects` in FluidList lists what touching it gives: `{ effect =
"Slowness", seconds = 1, amplifier = 1, when = "in" }` (refreshed every tick while in it), `when =
"head"` (the eyes in it), `when = "left"` (given on leaving it) and `after = 3` (only after 3 s in
it without a break). Effects with `washOff` come off in a fluid that `extinguishes` (water).

**Blast resistance.** A block's `blastResistance` is Minecraft's explosion resistance; leave it
out and it is the block's hardness (unbreakable blocks 3,600,000). Minecraft's values that differ
from the hardness are on those entries (the stone family 6, obsidian 1200...). A fluid other
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
lune run tests/servergen <scenario>   # the server's preloading: frame times, chunks/s, backlog
lune run tests/preview [seed] [blocksPerPixel] [pixels]   # top-down map in tests/out/preview.ppm
lune run tests/structure decode <file | IVS1:... | -> [--lua t.luau]   # structure data, as ASCII
lune run tests/structure encode t.luau [--out file] [--module]        # an edited table to IVS1
lune run tests/build_structures [--check] [--print]   # rebuild (or check) the example outpost
lune run tests/build_textures [--check] [--list]     # the texture pack's Rojo files; blanks (--list)
lune run tests/content [check] [--strict]     # the content packs: each pack, then what it lacks
lune run tests/content list [kind] [pack]     # entries with their ids and packs
lune run tests/content show <name>            # an entry, its pack and patches, what it became
lune run tests/content new <Pack> [--order n] # a new pack, an example of each kind in it
```


`lune run tests/run` runs the whole suite: 2,420 tests, all passing (the zombie apocalypse has
Apocalypse (its registries and shared rules), Zombies (the server's zombies, the director, tracking
and their costs), MobRig, MobRigPool, ZombieVoices and ZombieRigProbe (the rigs), Infection, Medical
and Survivor (survival), Cities, Bunkers and, where they all meet on a real world server,
ApocalypseGlue; lava and oil have LavaOil, LavaOilServer, LavaOilClient, LavaGeneration, OilWells,
Refinery and Combustion; the texture pack has TexturePack, TextureLooks and FarLooks; the data
sheets' assets have DataSheet, the eating and drinking loops UseSounds, the music MusicMood, the
zombies' voices ZombieVoices; fire has Fire;
Tough As Nails has ToughAsNails, Herbs and SurvivalGear; mobs have Mobs and MobsClient; status
effects and potions have Effects; knowledge, Ages and skills have Progression; where those three
meet, Crossover; the floating origin and "fake coords" have Origin, Rebase, PlayerSync,
PositionStore, MoveCheck, Interest, RemoteMotion and LocalPosition; the server's preloading has
ServerGeneration; `/locate` has Locate, LocateCommand and LocatePoi; the DayZ camera has
CameraRules, FirstPerson, BodyRules, TargetRules, CameraFade, TouchButtons and, where they meet,
CameraIntegration).

**Content tool.** `lune run tests/content` loads the content packs as the game does (the
registries too: a load error names its pack, kind and entry, and exits 1), prints each pack's
order and what it holds, then a line per finding, pack by pack, and the counts. Warnings: a block
or item without a lore line, a block that can carry a texture without texture-pack faces, an item
without an icon entry (a blank `""` counts), a texture no block uses, a result no Age names that
survival can only make in a later Age (a result no Age names is the Stone Age's, which is fine
alone), a crafting recipe whose own grid an earlier recipe takes. Info: items survival never gives
(no recipe, chest, drop, mob, structure or fill reaches them). `--strict` fails on a warning.
`show <name>` gives an entry's merged fields, id, pack, the packs that patched it, its lore,
faces or icon, Age, how survival gets it and the recipes making and using it; `new <Pack>` writes
`src/shared/Content/Packs/<Pack>/` (never over a folder) with a commented block, item, shaped and
smelting recipe, texture and loot table that load and pass the check as written. The workings are
`tests/lib/ContentTool` (`tests/spec/ContentTool` runs them on `tests/fixtures/content/tool`) and
`tests/lib/ContentGame` (what the game makes of the packs).

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
and hidden terrain). `tests/spec/SurvivalLookGlue` runs the real inventory screen, Style and
HoverTip on a fake Roblox client (`tests/lib/FakeClient`: instances with events, Destroying and
UIScale-aware absolute positions, and a `task` whose delays run when a test says), for what only
glue does: the recipe view's live but inert VICINITY column (no clicks, no tooltips through
HoverTip's real mouse path), the effects' place in the band and under the view, tooltip entries
freed with their objects, outlines following their screen's scale and masks drawn within a
frame's budget.

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
- **More combat and mobs.** Players hurt each other only with firearms (`Config.Weapons.PvP`),
  there are no bows, grenades, critical hits, sweeps or enchantments, nothing repairs a gun, and
  melee hits have no head zone; more kinds (wolves, villagers, other survivors), breeding
  and taming, mob light levels by biome, baby mobs, sheep shearing and dyes. Animals don't push
  each other apart (zombies do).
- **Hordes that find their way.** Zombies and blood moon hordes steer straight at what they go
  for: no path finding. A wall between a zombie and the player it is after is broken through if
  the zombie can break it, never walked round, and against one it can't break (iron, a chest) it
  stands until it loses interest; a hunter that gets no closer for 20 seconds (and breaks nothing)
  gives up and leaves.
  They never dig down or up towards a player (only from a block below their feet to two above),
  never break a block more than 8 blocks (16 for hunters) from what they go for, and an idle
  zombie more than 32 blocks from every player thinks every 4th tick, so far crowds wander a
  little slower.
- **Zombies' bodies.** They are anchored boxes posed in code, not Humanoids: no clothing images,
  faces, layered accessories or Roblox animations, no ragdoll (a dying zombie tips over like any
  mob), hats are single boxes without brims. The drawn bodies are bigger than the hitboxes in
  places (a brute's shoulders and head go through door frames and lintels, a crawler's head and
  arms reach past its 0.8 block box and its hands press into the ground as it claws); hits and
  collisions use the boxes. Limbs never move faster than 17.4 studs a second, so a runner's feet
  slide a little at full sprint and a swing in mid-stride takes a few frames longer.
- **The ruins.** Old worlds stay without them: a world saved before the apocalypse has no Ruins
  setting and reads it as off, so no city levels the ground next to its edited chunks
  (`Config.Cities.OldWorlds = true` opts such worlds in: the ruins then appear only in ground
  nobody edited, and may leave a cliff against an edited chunk). Beyond full detail a building is
  its massing (levels 1-2 its decayed envelope, 3-4 one height per building), none past level 4;
  roads are drawn to level 2. Roads link only cities within two cells, never bridge more than 48
  blocks of water and never tunnel. Floors above the fourth are shells (a facade, a ring of rooms
  and a solid core, no ladder up): in a city's footprint a spawn or teleport never lands above the
  last full floor. Bunkers are full detail only (a hatch appears when its chunk does), and a
  city's needs room inside the footprint: a shed 10-14 blocks inside a town's north edge keeps
  3-5 rooms, and two sheds close together may leave one only its bunk room and storeroom. The All
  Structures sample town's shed has no bunker under it.
- **Survival's corners.** With thirst, temperature and hunger all off the server guesses sprinting from
  the feet's speed (over 5 blocks a second), so a fast fall or a push may count as a noise. The
  blood moon's sky follows the camera's sky exposure (caves keep their colour), and with
  `Lighting.Enabled = false` the place keeps its own sky. `/effect clear` cures an infection
  without the antibiotics' Weakness; Resistance V makes a player immune to the infection's last
  tick. A `/time set` past a blood moon's end counts the moon without its "You survived" toast.
- **More of lava and oil.** Basalt, water aquifers,
  BuildCraft's oil springs and its refinery's heat and by-products, fire-resistant items, lava
  particles, and lava's lights in far chunks (they carry none: a far lava lake is unlit Neon).
- **Block orientation.** Blocks have no facing yet, so furnaces and chests show their fronts on
  every side and furnaces don't light up while burning.
- **More plants.** Saplings (dropped by leaves, growing into the existing tree builders), bone
  meal, sugar cane, seagrass and kelp, lily pads, vines, sweet berry bushes, and wheat, so grass
  can drop seeds. Plants are drawn only within `Lod.FoliageDistance`; Minecraft draws them to the
  render distance, which would need them merged into far fewer parts or meshes.
- **More of the texture pack.** The 82 blank textures and every texture's Average; see-through
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
- **Parallel server generation.** The server generates the chunks around players on its main
  thread, a slice of each frame (`World/GenQueue`); an Actor pool only pays once servers get
  several Parallel Luau threads (20-30+ players) with many flyers, or the generator runs
  interpreted (see ARCHITECTURE, Server chunk generation).
- **Mesher.** Try both X-first and Z-first growth and keep the smaller result; cap the size of
  water and glass boxes, so an edit in a lake replaces less of its surface (while old and new
  surfaces overlap for `Render.SwapFrames` frames, the water looks darker there).
