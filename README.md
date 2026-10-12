# Better ZCity NPCs

A Z-City / Homigrad-compatible scripted NextBot addon with vanilla-style classes, player-like inventory data, a bidirectional player-data adapter chain, a shared organism/injury table, knockdown ragdolls, recovery, and crawling.

## Starter classes

- `npc_bzcn_default` — civilian / default class.
- `npc_bzcn_combine` — Combine soldier; logical `Combine` faction/team label and hostile to non-Combine player classes.
- `npc_bzcn_metrocop` — Metro Police; shares the Combine faction and allied disposition.
- `npc_bzcn_rebel` — Resistance fighter.
- `npc_bzcn_furry` — adapted from Z-City's own `furry` player class; can grab nearby non-furry players or managed NPCs and apply Z-City-style assimilation.

The furry profile uses the model from Z-City's `lua/homigrad/playerclass/classes/furry/sh_furry.lua` (`models/eradium/protogen_player.mdl`), the claw model used by `weapon_hands_sh`, the `c-` blood type, and the `protovisor` head-armor entry. It does **not** call the player's conversion, UI, or role callbacks, because those require a real Player entity.

## Install

Copy this repository into `garrysmod/addons/better-zcity-npcs` and restart the server or reload the addon. The furry model and hand model are provided by Z-City content; ensure those assets are mounted.

## Spawn and test

Spawn them from the Entities tab under **Better ZCity NPCs**, or use server console:

```text
ent_create npc_bzcn_default
ent_create npc_bzcn_combine
ent_create npc_bzcn_metrocop
ent_create npc_bzcn_rebel
ent_create npc_bzcn_furry
```

Aim at a managed NPC or its temporary ragdoll and run `bzcn_npc_health`. Use `bzcn_npc_health <entity-index>` from server console to query a specific entity.

For repeatable injury tests (admin or server console):

```text
bzcn_npc_dump <entity-index>
bzcn_npc_test <entity-index> down
bzcn_npc_test <entity-index> crawl
bzcn_npc_test <entity-index> reset
bzcn_npc_set_class <entity-index> furry
```

The class-switch command accepts `default`, `Combine`, `Metrocop`, `Rebel`, or `furry`. `down` tests ragdoll/recovery, `crawl` simulates a serious leg injury, and `reset` clears injuries. The dump command reports the effective class, inventory, fake weapon, organism data and the engine's actual `IsPlayer()` result.

Combine and MetroCop use the shared `Combine` faction/role label and consider players outside that faction hostile; the logical `TeamName` is exposed through the NPC adapter because a NextBot cannot join a real Player team index. The furry NPC keeps Z-City's hands SWEP lowered for grabbing, carries the target ragdoll through `weapon_hands_sh:SetCarrying()`, and holds simulated RMB+LMB so the real Z-City assimilation code can run. Conversion calls `hg.Furrify()` for real players or switches a managed NPC to the furry class.

## Adapter chain

The server runs a lightweight adapter cycle every 0.20 seconds for managed NPCs:

```text
Player-shaped data
    -> NPC senses (visible players + managed NPCs, distance, class/faction, hostility)
    -> translated player-shaped context
    -> class/hook callbacks
    -> validated writeback to NPC state
```

The chain lives in `lua/autorun/server/sv_bzcn_adapter_chain.lua`. It feeds the same visible-target/hostility observations into NPC target selection, so AI perception and the compatibility hooks no longer use separate target scans. A writeback cannot change engine identity, position, velocity, or arbitrary entity references.

### Gameplay rules menu

Open **Spawn Menu → Utilities → User → Better ZCity NPCs** to toggle the server-side gamerules. The options are server-authoritative and require admin permissions:

- Furry grabs and assimilation
- Furry pounce / ragdoll tackle
- Ragdoll sitting
- NPC door interactions
- Armed civilians resisting fleeing

The matching archived server convars are named `bzcn_rule_furry_grabs`, `bzcn_rule_furry_tackles`, `bzcn_rule_ragdoll_sitting`, `bzcn_rule_door_interaction`, and `bzcn_rule_armed_civilian_bravery`. All default to enabled.

Useful server commands (admin or server console):

```text
bzcn_npc_adapter_dump <entity-index>
bzcn_npc_import_player <npc-index> <player-userid>
```

The adapter dump shows the actor snapshot, visible targets, hostiles, and fields written back. Player import is explicit; it copies the selected player's class only when it matches a registered BZCN class, then imports supported data such as inventory, health, speed, ammo, organism and faction. It does not run automatically.

### Hook contract

- `BZCN.CapturePlayerData(entity)` returns a copied player-shaped snapshot.
- `BZCN.SenseNPC(npc)` returns visible target records, including player-shaped data per target.
- `BZCN.AdapterCycle(npc)` runs the complete sense/translation/writeback loop; `BZCN.GetLastAdapterContext(npc)` reads the latest context.
- `BZCN_NPCPlayerClassEvent` receives the legacy-compatible `"Sense"` event with the translated context.
- `BZCN_NPCSenseTranslated(npc, context)` and `BZCN_NPCAdapterCycle(npc, context)` may edit `context.actor`, call `context:Set(field, value)`, write approved values to `context.writeback`, or set `context.intent.Target` / call `context:SetIntent(action, target)`.
- `BZCN_NPCAdapterCycleComplete(npc, context)` runs after the chain and writeback.
- `BZCN_NPCWritebackApplied(npc, patch, reason, changedFields)` reports a successful state change.

The normalized actor exposes fields like `PlayerClassName`, `Health`, `MaxHealth`, `Speed`, `Inventory`, `Armor`, `Ammo`, `SelectedWeapon`, and `Organism`. Target records are available as `context.sense.Targets`; player-shaped records are available as `context.players`. Z-City inventory weapon entries that refer to live SWEP entities become virtual owned-item flags when copied to NPC state, so the NPC never takes ownership of another player's weapon entity. Class writeback is restricted to registered BZCN classes. Only approved data fields are reflected back onto the NPC.

### Native Z-City organism and ragdolls

The server now follows the same conversion path used by Z-City's own NPC support in `lua/homigrad/sv_npcstuff.lua`: call `hg.organism.Add(ent)`, run `hg.organism.Clear(ent.organism)` once, and set `ent.organism.fakePlayer = true`. The adapter installs an instance-local `IsNPC()` facade for managed NextBots, which is important because Z-City's damage hook ends with an NPC-specific return value. It does not spoof `IsPlayer()`.

Injury updates are read back from Z-City's real organism table, including blood, pain, shock, body-part damage and wounds. A temporary knockdown ragdoll shares the live organism/owner reference and publishes Z-City's expected `rag.ply`, `owner.FakeRagdoll`, and networked `ply` references, so `hg.RagdollOwner(rag)` and other visual/damage consumers can resolve the living body. The addon also dispatches `Ragdoll_Create` for live knockdowns. Hits to this ragdoll pass through Z-City's damage hook and the applied health damage is bounced back to the hidden living NPC. Z-City's Player-only `hg.Fake/hg.FakeUp` calls are adapted for managed NPCs to use this addon’s ragdoll/recovery path instead of calling the player fake-ragdoll implementation. On death, the ragdoll gets its own registered organism with `owner = ragdoll`, `alive = false`, and `fakePlayer = true`, and dispatches Z-City's `RagdollDeath` hook and network-list merge, following the pattern in `lua/homigrad/sv_npcstuff.lua`. Native `GetNetVar/SetNetVar` are preserved and bridged with BZCN's smaller metadata fields so wound/armor/name replication remains available to Z-City addons such as Project Homogen.

The client HUD bridge mirrors health, blood, pain, shock and body-part state for inspection when aiming at a living managed NPC or its temporary knockdown ragdoll.

## Animation, civilian appearance, and ally AI

Managed NPCs now explicitly register each resolved model through `hg.IXAnims.SetModelClass(model, class)`; this works around Z-City's resolver returning the generic `player` class early for most `models/player/...` paths. The addon's model mapper selects `citizen_male`, `citizen_female`, `overwatch`, `metrocop`, or `player` as appropriate, including explicit per-class overrides and hold types for the selected Z-City loadout. The movement state machine publishes `BZCNMovementState` and transitions between `standing`, `walking`, `running`, `crawling`, `climbing`, `grabbing`, `airborne`, `downed`, `getting_up`, and `treating`. It caches each selected weighted sequence per model/hold type/activity instead of reselecting every update, and uses `BodyMoveXY()` for moving states so `move_x`/`move_y` pose parameters are updated while frames advance only once. Crawling tries available crawl sequences before falling back to crouch-walk. Climbing is a bounded small-ledge clamber/jump assist when the upper hull has clearance; it is not unrestricted ladder or wall climbing. Attacks consult the IX animation attack activity without invoking Player-only animation callbacks.

The `default` civilian first tries Z-City's `hg.Appearance.GetRandomAppearance()` and `hg.Appearance.ForceApplyAppearance()` path, which supplies its civilian model/clothing/bodygroups. If that API is unavailable or fails, it falls back to a random standard Group03 male/female civilian model and skin.

Managed NPCs classify native Z-City Combine/civilian NPCs, establish reciprocal entity relationships, and use a shared sensing context to follow visible allies. If a nearby ally or player has recently been attacked, that attacker is promoted to a temporary hostile even if it was normally the same faction, so the NPC can defend the victim. NPCs follow players and other allies when no visible hostile needs attention. This is cooperative AI for the managed NPCs; it cannot take over a real player's controls or guarantee that unrelated native NPC AI will actively follow the scripted NextBot.

### Social phrases, gestures, and furry scanning

The server social bridge observes Z-City voice phrases after they are emitted, including the furry class's native replacement sounds, and lets nearby managed NPCs respond with a suitable phrase and a model-supported gesture. NPCs can also make occasional ambient phrases/gestures while idle near players. The bridge observes animation events and supports common chat/act gesture aliases without rewriting ordinary chat. Furry NPCs run a recurring prey-location scan that tracks hostile players and NPCs even when they are not currently visible; visibility is still required for immediate attack, while pursuit can follow the scanned position.

### Medical assistance

Managed NPCs can use their available medical supplies on nearby allies, including players and managed NPCs. Native Source NPCs that have no usable Z-City organism table can receive basic health-based first aid instead of being ignored by the medical selector. Assistance remains faction-aware and is skipped while the medic is downed, getting up, treating someone already, or holding a furry-grab target.

### BZCN Fancy Patch and Add

The presentation pass gives human-profile NPCs a shared, expanded name pool and mixes Z-City clothing themes across the main outfit, pants, and boots instead of assigning one matching set. The client-side `cl_bzcn_fancy_visuals.lua` bridge invokes the existing Z-City accessory renderer for managed NextBots, including when an appearance changes or the actor is represented by its temporary fake ragdoll.

Human NPCs share the same base movement speed as Z-City's ordinary player walk speed (190 by default). Sprinting follows the live `hg_movement_runspeed` setting when available, with a 320 fallback. Sprint uses the normal run cycle at a playback rate tied to actual movement speed; movement-state thresholds have hysteresis to reduce flicker. During a visible chase, the movement animation keeps its facing aligned with the current target, and chase paths are recomputed less aggressively to reduce stutter steps.

These are compatibility-oriented Lua changes; accessory availability and exact clothing/animation results depend on the relevant Z-City content being mounted and supported by each model.

### BZCN Fancy Patch and Add 2

The second pass adds an upright run-up/boost to furry pounces, followed by a delayed fake-ragdoll handoff. The boost velocity is carried into the ragdoll, and a dedicated contact resolver preserves the impact after the NPC enters its downed state. The **Furry pounce build-up ragdoll** rule can disable the delayed ragdoll stage; **Furry pounce / ragdoll tackle** still controls whether the pounce itself is allowed.

Managed headcrabs now use their own small collision hull, leap attacks, creature movement/attack sequences, and native headcrab sounds. A successful headcrab leap can start Z-City's native infection timer on a player (through the native `AddHeadcrab` path) or start a matching infection timer on a managed NPC. Managed NPC victims transition to the `headcrab_zombie` profile after the infection delay; during the build-up they suffer brain impairment, pain/shock, and bounded twitching. The zombie profile uses Z-City's `models/zcity/player/zombie_classic.mdl`, bodygroup 1, preserved civilian clothing when available (or class-specific fallback materials), slow movement, claw attacks, classic zombie footsteps/foot-slides, and no ordinary social gestures or door interactions. Headcrabs and zombies share the zombie faction.

New options are added automatically to **Utilities → User → Better ZCity NPCs** in the game-rules panel:

- **Headcrab leap attacks** and **Headcrab infection and zombification** control the new headcrab behavior.
- **Combine / Rebel squad tactics** can switch the squad director off.
- **Zombie horde mind** is experimental and defaults off; enabling it allows managed zombies/headcrabs to join loose shared horde squads.
- **Civilian panic spreads** allows nearby civilians to copy a civilian's flight response to a furry threat.
- **Furry pounce build-up ragdoll** toggles the delayed transition after the boost.

The new **Inventory Giver** tool is under **Tools → Better ZCity → Inventory Giver**. Configure comma-separated weapon classes, item IDs, ammo counts (`Pistol:120,SMG1:90`), attachment IDs, and armor assignments (`head=combine_helmet,torso=vest3`). Left-click a player or managed BZCN NPC to apply the setup; right-click copies a target's inventory into the tool fields. Reload clears managed-NPC inventory data. On players, configured missing weapons are given and configured ammo is set, while unrelated physical weapons, live ammo, and worn armor are preserved. The tool is admin-only (except single-player), and only registered SWEPs are given. Existing Z-City virtual inventory entries are preserved when applying player loadouts; reload can clear those extras without stripping physical weapons. Live player ammo is refreshed through Z-City's native inventory API, configured ammo types override those counts, and unspecified ammo remains unchanged. Item/attachment fields update Z-City inventory data; they do not conjure missing content or install attachments onto weapons automatically.

These changes are statically reviewed against the current Z-City source, but still need live multiplayer testing for model/material availability, pounce timing, infection progression, and compatibility with server-side inventory/armor modifications.

## Injury signals and fake-ragdoll compatibility

The injury bridge also uses the public [Z-City NPC Integration (zcnpci)](https://forge.owouw.us/ToasterPanic/zcnpci) addon as a design reference for damage-stage handling and ragdoll compatibility; this addon does not copy its active-ragdoll controller. For managed NextBots, it records available `ScaleNPCDamage` hitgroups and consumes `HomigradDamage` when present, then evaluates Z-City organism state after the damage tick. The incapacity checks include `otrub`, low consciousness, high pain, active stun/light-stun timers, serious leg damage/amputation, fire, and zcnpci-style leg-specific impact thresholds. These are server-side knockdown decisions layered over Z-City's native organism; they do not replace its wound calculation.

The temporary knockdown ragdoll keeps the expected owner links together: `rag.ply`, `owner.FakeRagdoll`, networked `ply`/ `FakeRagdoll`, and the NPC's `GetRagdollEntity()` compatibility accessor. `hg.Fake`, `hg.FakeUp`, `hg.StunPlayer`, and `hg.LightStunPlayer` are adapted only for BZCN-managed actors; calls for real players continue through the installed native/other-addon function. Recovery retries while the temporary ragdoll is held, and the downed copy preserves bodygroups, submaterials, and Citizen-type metadata so appearance-changing addons don't lose their setup. On get-up or death, temporary links are cleared and the death corpse receives its own organism instead of continuing to share the living NPC's.

## Compatibility approach and limits

NPCs expose Z-City-style fields such as `PlayerClassName`, `Inventory.Weapons/Items/Armor`, `armors`, `armors_health`, `organism`, `GetNetVar`, and `SetNetVar`. Entity-valued netvars and ragdoll ownership links are mirrored for systems that inspect them.

Garry's Mod does not permit an NPC to become a real `Player` userdata: `IsPlayer()`, player enumeration, client ownership, and Player-only engine functions remain unchanged. The adapter passes normalized player-shaped data and a sense context to hooks; it does not blindly invoke Player-only callbacks on a NextBot.

The actor remains a NextBot, not a Player. Each managed NPC keeps a hidden runtime entity for its selected Z-City SWEP while the lightweight hand proxy displays that SWEP's world model. Ranged attacks use the selected SWEP's damage, spread, sound and ammo settings through the engine's bullet API, with tracers and a muzzle-flash attempt; this avoids treating a Player-oriented `NPCShoot_Primary` cooldown change as proof that a NextBot actually fired. Civilian/Rebel loadouts use `weapon_glock17` / `weapon_ak74`; Combine uses `weapon_mp7`; the inventory also includes `weapon_hands_sh`, `weapon_medkit_sh`, and `weapon_bandage_sh`. Hands-equipped profiles call the real Z-City fists SWEP for close attacks.

The server-side medical AI checks Z-City organism wounds, blood loss, internal bleeding, shock, pain, and recent health loss for the NPC and nearby allies. It invokes the real `weapon_medkit_sh:Heal()` / `weapon_bandage_sh:Heal()` methods against the native organism instead of maintaining a second healing implementation. This is a best-effort autonomous treatment bridge: player-targeting animations, inventory UI, and every item-specific Player-only behavior are not guaranteed to run on a NextBot. Ragdoll, crawl, climb, and get-up visuals still depend on model sequences and navigation/obstacle geometry. Static checks do not replace a live Z-City/Garry's Mod runtime test.

## Source references

- Z-City furry class: https://github.com/uzelezz123/Z-City/tree/main/lua/homigrad/playerclass/classes/furry
- Z-City NPC Integration (injury/ragdoll design reference): https://forge.owouw.us/ToasterPanic/zcnpci
- Z-City's organism-backed native NPC conversion: https://github.com/uzelezz123/Z-City/blob/main/lua/homigrad/sv_npcstuff.lua
- Z-City's headcrab zombie player class (pinned): https://github.com/uzelezz123/Z-City/blob/6464efc2cd9fcfe0c822195a7102d6afe1d86956/lua/homigrad/playerclass/classes/sh_headcrabzombie.lua

### BZCN Fancy Patch Finishing Pass

The final polish pass makes human NPC names follow the sex metadata of their selected Z-City appearance model, using Z-City's native name generator when available and gender-specific fallback pools otherwise. Accessory rendering normalizes both the stock array of accessory IDs and adapter-provided keyed/slot-style tables. The client bridge also seeds and restores Z-City's existing `CahceModel`/`bSex` cache so its Player-only `GetSubModels()` lookup is not called on a NextBot.

The medical inventory checker now type-checks weapon entries before calling `IsValid`, because Z-City legitimately stores some virtual inventory entries as boolean `true`. Sprint locomotion follows Z-City's velocity-based walk/run selection: it waits for actual speed to pass the run threshold, prefers a dedicated sprint sequence when a model has one, and eases playback-rate changes rather than scaling the animation directly by speed/base-speed.

