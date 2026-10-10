# Better ZCity NPCs

A Garry's Mod addon that gives NPC/NextBot entities a ZCity-style class and inventory compatibility layer, shared injury state, knockdown ragdolls, recovery animations, crawling, and held-weapon visuals.

## Included starter classes

- `npc_bzcn_goober` — Goober-like melee hunter, class key `goober`.
- `npc_bzcn_humanityforces` — human combat archetype, class key `humanityForces`.
- `npc_bzcn_traitor` — hostile human archetype, class key `traitor`.
- `npc_bzcn_base` — reusable NextBot base for further classes.

The class compatibility is deliberately an adapter, not an attempt to turn an engine NPC into a real `Player` userdata. `IsPlayer()`, `player.GetAll()`, client ownership and player-only engine features cannot be overridden by Lua. NPCs expose commonly used class-facing fields and helpers instead: `PlayerClassName`, `GetNetVar/SetNetVar`, an `Inventory` table with ZCity-style `Weapons` and `Items` subtables, an organism-like injury table, and inventory/weapon helper methods. The addon does not blindly execute arbitrary `player.RegClass(...).On` callbacks, since those may call player-only APIs.

## Install

Copy this repository into `garrysmod/addons/better-zcity-npcs`, then restart the server or reload the addon.

## Quick test

Spawn each starter class from the Entities tab under **Better ZCity NPCs**. They can also be spawned from server console:

```text
ent_create npc_bzcn_goober
ent_create npc_bzcn_humanityforces
ent_create npc_bzcn_traitor
```

Aim at an NPC or its temporary ragdoll and run:

```text
bzcn_npc_health
```

Use `bzcn_npc_health <entity-index>` from server console when needed. To swap an existing NPC between the three class profiles, run `bzcn_npc_set_class <entity-index> <goober|humanityForces|traitor>`. Check that the NPC reports one health/injury state through both its standing entity and ragdoll, recovers without spawning a duplicate, and resumes AI. Strong hits and severe leg injuries trigger downed/crawl states; model animation names vary, so a model without a crawl sequence uses slowed locomotion instead.

For repeatable mechanics tests (run as admin or from server console):

```text
bzcn_npc_test <entity-index> down
bzcn_npc_test <entity-index> crawl
bzcn_npc_test <entity-index> reset
bzcn_npc_dump <entity-index>
```

`down` forces the shared ragdoll/recovery flow; `crawl` simulates a severe leg injury; `reset` clears injuries and recovers a downed NPC. The dump command reports class, inventory keys, active fake weapon, health, organism fields, and the engine's true `IsPlayer()` status.

## Adding a class

Create a new scripted entity that inherits `npc_bzcn_base`, then set `ENT.BZCNClass` to one of the registered profile keys or register a profile through `BZCN.RegisterClass`. Do not call the player class's original `On` method unless that class has been explicitly adapted to operate on NPC entities.

## Limitations

- This is not a full Player replacement. Player-only APIs, player hooks and player ownership still require explicit NPC-aware adapters.
- Inventory weapons are adapter entries with hand-held model proxies. The Humanity Forces and Traitor profiles use simple NPC raycast shooting, not the weapon SWEP's player-only firing/reload implementation.
- Get-up/crawl animations depend on each model's available sequences.
- Live Garry's Mod/ZCity runtime testing is required before considering every model or class fully validated.
