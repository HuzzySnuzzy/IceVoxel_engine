# Studio probes

Developer tools that measure what Lune cannot: engine-side costs that only a real Roblox client
shows. They are **not in the Rojo tree** (`default.project.json` never sees `tools/`), so they never
ship with the place. Copy them into a test place by hand, run, read the Output or the Developer
Console (F9), and delete them again.

| Probe | Measures | Decides |
| --- | --- | --- |
| `RebaseProbe.client.luau` | One floating-origin move: the Luau gather, `workspace:BulkMoveTo` and the frames after it, at 17k, 35k, 80k and 140k parts | `Config.Origin.RebaseDistance` / `SoftDistance` and whether far meshes start at level 1 (below) |
| `UnionProbe.client.luau` + `UnionProbeSections.luau` | `GeometryService:UnionAsync` on real terrain sections: time, worst frame, triangles, a one-block edit's re-union, memory by category, draw calls by eye | Whether CSG unions could ever beat parts plus far meshes for chunk rendering (today: no) |
| `ZombieRigProbe.client.luau` | 60 zombies round the player drawn as the game draws them (R15 rigs, `MobRigPool`): the rig update's Lua time a frame (MicroProfiler label `IceVoxelZombieRigs`), frame times, parts moved and made, against the same zombies as two boxes each | `Config.Mobs.Rig` (MaxRigs, MaxFull, distances, ShadowParts) on low-end devices |

Run each on a PC **and on one phone**: phones are where these costs matter.

## RebaseProbe

The floating origin (`Shared/World/Origin`, client `Rendering/Rebase`) moves every client part on
screen in one `BulkMoveTo` when the camera gets `RebaseDistance` studs from the render origin.
The Luau side was measured in Lune (about 0.08 µs a part); the engine side (each part's CFrame
read, the move, the next frame's broadphase, render clusters and lighting) can only be measured
here.

1. Play in Studio (or a published test place), with nothing else heavy on screen.
2. Put `RebaseProbe.client.luau` in `StarterPlayer.StarterPlayerScripts` as a LocalScript (or
   paste its body into the command bar while playing).
3. It builds anchored parts like the terrain's (boxes 3-48 studs, about half CanCollide and
   CanQuery, 70% casting shadows) over the default view, looks over them from a fixed camera,
   lets them settle, and moves them and the camera together (as the game's `Rebase` does, so the
   frames after draw the same scene). It prints one line per count:

   ```
   [RebaseProbe] parts | gather ms | BulkMoveTo ms | before mean/max | after: 1st, 2nd, rest max | hitch ms
   ```

   The **hitch** is what the first two frames after the move took beyond the mean before. The
   gather and `BulkMoveTo` run inside a RenderStepped, so the first frame after already holds
   them (don't add them again); the second holds what the engine left for later. The two
   columns before it show the Luau and engine split. In the game itself, F3's `origin` line
   shows the same split for real moves (`gathered in`, `BulkMoveTo`).

**Decision rule** (the hitch at 35k parts, about the default view in the mountains or at the
spawn without far meshes):

| Hitch at 35k on PC | Action |
| --- | --- |
| ≤ 20 ms | Keep `Origin.RebaseDistance = 8192` and `SoftDistance = 3072` |
| 20-50 ms | `RebaseDistance = 16384` (still within 1/512 stud near the camera); keep soft moves; keep far meshes on by default |
| > 50 ms | Also start far meshes at level 1 (`Render.FarMeshes.MinLevel = 1`: about 47% fewer parts on screen); a hard move may then cover the screen for 2 frames so the hitch reads as a blink, not a stutter |

Phones get their own overrides if they need them (a `Config.Origin.Mobile` table, read the way
`Render.FarMeshes.Mobile` is).

## UnionProbe

The evaluation of CSG unions for chunks found them not worth building: they would cut the part
count 15-31x on levels 0-1, but each union is its own mesh (no part instancing, so likely more
draw calls), every block edit would wait on an asynchronous CSG job, and streaming would need
20-110 `UnionAsync` calls a second. Stable far terrain is already merged better by far meshes
(`Rendering/MeshOverlay`). The probe settles the estimates that rest on no published numbers.

1. `UnionProbeSections.luau` → a ModuleScript `ReplicatedStorage.UnionProbeSections` (8 real
   mountain sections, seed 12345 near (3200, -14600), 48-140 boxes each, by look).
2. `UnionProbe.client.luau` → a LocalScript in `StarterPlayer.StarterPlayerScripts` (CSG on the
   client needs client-made parts), in a copy of the IceVoxel place so `MaterialService.IceVoxel`
   exists.
3. Play, open the Developer Console and read the `[UnionProbe]` lines: per section and look the
   union time, the worst frame during it and its TriangleCount; one look re-unioned with a box
   removed (what a block edit would cost); client memory by category (Instances, BaseParts,
   GraphicsParts, GraphicsSolidModels, GeometryCSG, PhysicsCollision) with and without the parts.
   The parts stay on the left (x < 0) and the unions on the right: compare draw calls with
   Shift+F2 and check by eye whether textures still tile one per block on the unions.

Revisit unions only if a probe surprises: unions under about 5 ms each **and** their draw calls
batched. Even then, try far meshes from level 1 first (`Render.FarMeshes.MinLevel = 1`), which
does the same job with code that exists.

## ZombieRigProbe

Zombies near the player are Roblox R15 bodies of anchored parts posed in code (client
`Entities/MobRig`, `MobRigPool`, `MobRenderer`): at most 16 full rigs (17 parts) within 16 blocks
and 24 reduced rigs (8 parts) to 40 blocks, the rest two boxes each, so at most 464 rig parts
move a frame in the one `BulkMoveTo`. Lune measures the Luau side without the engine's
(`tests/spec/MobRigPool`'s cost test: the glides, tiers and poses of 60 zombies, every rig posed
every frame, about 0.17 ms native and 0.97 ms interpreted a frame); this probe adds `CFrame.new`,
the move, shadows and drawing, on the device. It draws with the game's own parts code
(`Entities/MobParts`: MobRenderer's part factory, flames and `BulkMoveTo`), and
`tests/spec/ZombieRigProbe` runs it whole in Lune on Lune's Roblox instances (a stand-in clock,
RenderStepped and `BulkMoveTo`), so it is known to finish and count right before a device run;
there it prints `450 parts moved | 16 / 24 rigs | 0 parts made after the warm-up | 0 flames lost`
(rigs) and `120 parts moved | 0 / 0 rigs | 0 | 0` (boxes), with no times.

1. Play a copy of the IceVoxel place (the probe requires the game's own modules from
   `ReplicatedStorage.IceVoxel` and `PlayerScripts.IceVoxel`), on open ground.
2. Put `ZombieRigProbe.client.luau` in `StarterPlayer.StarterPlayerScripts` as a LocalScript.
3. Stand still. After 5 s it runs two passes of 10 s warm-up and 30 s measured, 60 zombies of
   every kind and look circling the player in its own folder (beside whatever the game draws),
   and prints one line each:

   ```
   [ZombieRigProbe] pass | Lua ms median / p90 / max | frame ms mean / p90 | parts moved | full / reduced rigs | parts made after the warm-up | flames lost
   ```

   `rigs` uses `Config.Mobs.Rig` as it is; `boxes` draws every zombie as two boxes (MaxRigs 0),
   the old drawing. The frame columns' difference is what the rigs cost the engine. Parts moved
   is the most in one frame and the rigs are that frame's (reduced rigs take what is left of
   MaxRigs 40, so 24 when 16 are full). Open the MicroProfiler (Ctrl+F6; on a phone, the
   Developer Console) to see `IceVoxelZombieRigs`.

**Decision rule** (on the lowest device the game targets):

| Lua median (rigs) | frame mean, rigs minus boxes | Action |
| --- | --- | --- |
| ≤ 1.2 ms | ≤ 2 ms | Keep `Config.Mobs.Rig` |
| > 1.2 ms | any | `MaxRigs = 24`, `MaxFull = 8` (a phone override, as `Render.FarMeshes.Mobile`); if still over, `MobRigPool.REDUCED_EVERY = 2` (reduced rigs posed every other frame: about 0.15 ms less interpreted, but their limbs then step up to 0.58 studs every other frame, twice `MobRig.LIMB_SPEED`'s 0.29 a frame) |
| ≤ 1.2 ms | > 2 ms | `ShadowParts = 1` (heads only), then `ReducedDistance = 28` |

Parts made after the warm-up must be 0 in both passes (the pools hold every rig). Every sixth
zombie burns (a `Fire` that `MobRigPool` moves to the part its tier burns on and takes off a rig
before letting it go); `flames lost` must be 0 too, and no "Parent property of Fire is locked"
error may appear in the Output.

