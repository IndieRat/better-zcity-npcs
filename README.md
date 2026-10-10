# Better ZCity NPCs

A Z-City / Homigrad-compatible scripted NextBot addon with vanilla-style classes, player-like inventory data, a bidirectional player-data adapter chain, a shared organism/injury table, knockdown ragdolls, recovery, and crawling.

## Starter classes

- \`npc_bzcn_default\` — civilian / default class.
- \`npc_bzcn_combine\` — Combine soldier.
- \`npc_bzcn_rebel\` — Resistance fighter.
- \`npc_bzcn_furry\` — adapted from Z-City's own \`furry\` player class.

The furry profile uses the model from Z-City's \`lua/homigrad/playerclass/classes/furry/sh_furry.lua\` (\`models/eradium/protogen_player.mdl\`), the claw model used by \`weapon_hands_sh\`, the \`c-\` blood type, and the \`protovisor\` head-armor entry. It does **not** call the player's conversion, UI, or role callbacks, because those require a real Player entity.

## Install

Copy this repository into \`garrysmod/addons/better-zcity-npcs\` and restart the server or reload the addon. The furry model and hand model are provided by Z-City content; ensure those assets are mounted.

## Spawn and test

Spawn them from the Entities tab under **Better ZCity NPCs**, or use server console:

\`\`\`text
ent_create npc_bzcn_default
ent_create npc_bzcn_combine
ent_create npc_bzcn_rebel
ent_create npc_bzcn_furry
\`\`\`

Aim at a managed NPC or its temporary ragdoll and run \`bzcn_npc_health\`. Use \`bzcn_npc_health <entity-index>\` from server console to query a specific entity.

For repeatable injury tests (admin or server console):

\`\`\`text
bzcn_npc_dump <entity-index>
bzcn_npc_test <entity-index> down
bzcn_npc_test <entity-index> crawl
bzcn_npc_test <entity-index> reset
bzcn_npc_set_class <entity-index> furry
\`\`\`

The class-switch command accepts \`default\`, \`Combine\`, \`Rebel\`, or \`furry\`. \`down\` tests ragdoll/recovery, \`crawl\` simulates a serious leg injury, and \`reset\` clears injuries. The dump command reports the effective class, inventory, fake weapon, organism data and the engine's actual \`IsPlayer()\` result.

## Adapter chain

The server runs a lightweight adapter cycle every 0.20 seconds for managed NPCs:

\`\`\`text
Player-shaped data
    -> NPC senses (visible players + managed NPCs, distance, class/faction, hostility)
    -> translated player-shaped context
    -> class/hook callbacks
    -> validated writeback to NPC state
\`\`\`

The chain lives in \`lua/autorun/server/sv_bzcn_adapter_chain.lua\`. It feeds the same visible-target/hostility observations into NPC target selection, so AI perception and the compatibility hooks no longer use separate target scans. A writeback cannot change engine identity, position, velocity, or arbitrary entity references.

Useful server commands (admin or server console):

\`\`\`text
bzcn_npc_adapter_dump <entity-index>
bzcn_npc_import_player <npc-index> <player-userid>
\`\`\`

The adapter dump shows the actor snapshot, visible targets, hostiles, and fields written back. Player import is explicit; it copies the selected player's class only when it matches a registered BZCN class, then imports supported data such as inventory, health, speed, ammo, organism and faction. It does not run automatically.

### Hook contract

- \`BZCN.CapturePlayerData(entity)\` returns a copied player-shaped snapshot.
- \`BZCN.SenseNPC(npc)\` returns visible target records, including player-shaped data per target.
- \`BZCN.AdapterCycle(npc)\` runs the complete sense/translation/writeback loop; \`BZCN.GetLastAdapterContext(npc)\` reads the latest context.
- \`BZCN_NPCPlayerClassEvent\` receives the legacy-compatible \`"Sense"\` event with the translated context.
- \`BZCN_NPCSenseTranslated(npc, context)\` and \`BZCN_NPCAdapterCycle(npc, context)\` may edit \`context.actor\`, call \`context:Set(field, value)\`, write approved values to \`context.writeback\`, or set \`context.intent.Target\` / call \`context:SetIntent(action, target)\`.
- \`BZCN_NPCAdapterCycleComplete(npc, context)\` runs after the chain and writeback.
- \`BZCN_NPCWritebackApplied(npc, patch, reason, changedFields)\` reports a successful state change.

The normalized actor exposes fields like \`PlayerClassName\`, \`Health\`, \`MaxHealth\`, \`Speed\`, \`Inventory\`, \`Armor\`, \`Ammo\`, \`SelectedWeapon\`, and \`Organism\`. Target records are available as \`context.sense.Targets\`; player-shaped records are available as \`context.players\`. Only approved data fields are reflected back onto the NPC.

## Compatibility approach and limits

NPCs expose Z-City-style fields such as \`PlayerClassName\`, \`Inventory.Weapons/Items/Armor\`, \`armors\`, \`armors_health\`, \`organism\`, \`GetNetVar\`, and \`SetNetVar\`. Entity-valued netvars and ragdoll ownership links are mirrored for systems that inspect them.

Garry's Mod does not permit an NPC to become a real \`Player\` userdata: \`IsPlayer()\`, player enumeration, client ownership, and Player-only engine functions remain unchanged. The adapter passes normalized player-shaped data and a sense context to hooks; it does not blindly invoke Player-only callbacks on a NextBot.

Inventory entries and held models are fake weapon proxies. Combine, Rebel, and civilian shooting uses a lightweight NPC trace/damage implementation, not the original SWEP firing/reload implementation. Ragdoll, crawl, and get-up animations still depend on the model's available sequences. Static checks do not replace a live Z-City/Garry's Mod runtime test.

## Source reference

Z-City furry class: https://github.com/uzelezz123/Z-City/tree/main/lua/homigrad/playerclass/classes/furry
