# Better ZCity NPCs

A Z-City / Homigrad-compatible scripted NextBot addon with vanilla-style classes, player-like inventory data, a shared organism/injury table, knockdown ragdolls, recovery, and crawling.

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

For repeatable tests (admin or server console):

```text
bzcn_npc_dump <entity-index>
bzcn_npc_test <entity-index> down
bzcn_npc_test <entity-index> crawl
bzcn_npc_test <entity-index> reset
bzcn_npc_set_class <entity-index> furry
```

The class-switch command accepts `default`, `Combine`, `Rebel`, or `furry`. `down` tests ragdoll/recovery, `crawl` simulates a serious leg injury, and `reset` clears injuries. The dump command reports the effective class, inventory, fake weapon, organism data and the engine's actual `IsPlayer()` result.

## Compatibility approach

NPCs expose Z-City-style fields such as `PlayerClassName`, `Inventory.Weapons/Items/Armor`, `armors`, `armors_health`, `organism`, `GetNetVar`, and `SetNetVar`. Entity-valued netvars and ragdoll ownership links are mirrored for systems that inspect them.

Garry's Mod does not permit an NPC to become a real `Player` userdata: `IsPlayer()`, player enumeration, client ownership, and Player-only engine functions remain unchanged. Class data and inventory calls are adapted locally; player-only Z-City callbacks are not blindly invoked.

Inventory entries and held models are fake weapon proxies. Combine, Rebel, and civilian shooting uses a lightweight NPC trace/damage implementation, not the original SWEP firing/reload implementation. Ragdoll, crawl, and get-up animations still depend on the model's available sequences.

## Source reference

Z-City furry class: https://github.com/uzelezz123/Z-City/tree/main/lua/homigrad/playerclass/classes/furry
