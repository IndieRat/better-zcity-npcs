# Better ZCity NPCs

A Z-City / Homigrad-compatible scripted NextBot addon with vanilla-style classes, player-like inventory data, a bidirectional player-data adapter chain, a shared organism/injury table, knockdown ragdolls, recovery, and crawling.

## Starter classes

- `npc_bzcn_default` — civilian / default class.
- `npc_bzcn_combine` — Combine soldier.
- `npc_bzcn_rebel` — Resistance fighter.
- `npc_bzcn_furry` — adapted from Z-City's own `furry` player class.

The furry profile uses the model from Z-City's `lua/homigrad/playerclass/classes/furry/sh_furry.lua` (`models/eradium/protogen_player.mdl`), the claw model used by `weapon_hands_sh`, the `c-` blood type, and the `protovisor` head-armor entry. It does **not** call the player's conversion, UI, or role callbacks, because those require a real Player entity.

## Install

Copy this repository into `garrysmod/addons/better-zcity-npcs` and restart the server or reload the addon. The furry model and hand model are provided by Z-City content; ensure those assets are mounted.

## Spawn and test

Spawn them from the Entities tab under **Better ZCity NPCs**, or use server console:

```text
ent_create npc_bzcn_default
ent_create npc_bzcn_combine
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

The class-switch command accepts `default`, `Combine`, `Rebel`, or `furry`. `down` tests ragdoll/recovery, `crawl` simulates a serious leg injury, and `reset` clears injuries. The dump command reports the effective class, inventory, fake weapon, organism data and the engine's actual `IsPlayer()` result.

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

Injury updates are read back from Z-City's real organism table, including blood, pain, shock, body-part damage and wounds. A temporary knockdown ragdoll shares the live organism/owner reference so Z-City-side visual systems can recognize it. On death, the ragdoll gets its own registered organism with `owner = ragdoll`, `alive = false`, and `fakePlayer = true`, following the pattern in Z-City's `CreateEntityRagdoll` conversion. Native `GetNetVar/SetNetVar` are preserved and bridged with BZCN's smaller metadata fields so wound/armor/name replication remains available to Z-City addons such as Project Homogen.

The client HUD bridge mirrors health, blood, pain, shock and body-part state for inspection when aiming at a living managed NPC or its temporary knockdown ragdoll.

## Animation, civilian appearance, and ally AI

Movement asks `hg.IXAnims.GetModelClass(model)` and uses the corresponding `hg.IXAnims` activity table for idle, walk, run, crouch-walk and weapon hold type. Attacks consult the same table's attack activity before falling back to available model sequences. This lets supported Z-City animation classes work without running Player-only `CalcMainActivity`/Player animation callbacks on a NextBot.

The `default` civilian first tries Z-City's `hg.Appearance.GetRandomAppearance()` and `hg.Appearance.ForceApplyAppearance()` path, which supplies its civilian model/clothing/bodygroups. If that API is unavailable or fails, it falls back to a random standard Group03 male/female civilian model and skin.

Managed NPCs classify native Z-City Combine/civilian NPCs, establish entity relationships, and use a shared sensing context to follow visible allies. If a nearby ally or player has recently been attacked, their next visible hostile is prioritized as a help target. The behaviour is cooperative for the managed NPCs; it cannot take over a real player's controls or guarantee that unrelated native NPC AI will actively follow the scripted NextBot.

## Compatibility approach and limits

NPCs expose Z-City-style fields such as `PlayerClassName`, `Inventory.Weapons/Items/Armor`, `armors`, `armors_health`, `organism`, `GetNetVar`, and `SetNetVar`. Entity-valued netvars and ragdoll ownership links are mirrored for systems that inspect them.

Garry's Mod does not permit an NPC to become a real `Player` userdata: `IsPlayer()`, player enumeration, client ownership, and Player-only engine functions remain unchanged. The adapter passes normalized player-shaped data and a sense context to hooks; it does not blindly invoke Player-only callbacks on a NextBot.

Inventory entries and held models are fake weapon proxies. Combine, Rebel, and civilian shooting uses a lightweight NPC trace/damage implementation, not the original SWEP firing/reload implementation. Ragdoll, crawl, and get-up animations still depend on the model's available sequences. Static checks do not replace a live Z-City/Garry's Mod runtime test.

## Source reference

Z-City furry class: https://github.com/uzelezz123/Z-City/tree/main/lua/homigrad/playerclass/classes/furry
