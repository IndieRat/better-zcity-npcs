-- Server-authoritative toggles for Better ZCity NPC gameplay rules.
if SERVER then AddCSLuaFile() end
BZCN = BZCN or {}

local RULES = {
    furry_grabs = {
        label = "Furry grabs and assimilation",
        help = "Allow furries to grab, carry, and assimilate victims.",
        default = "1"
    },
    furry_tackles = {
        label = "Furry pounce / ragdoll tackle",
        help = "Allow furry pounces and their fake-ragdoll tackle impact.",
        default = "1"
    },
    ragdoll_sitting = {
        label = "Ragdoll sitting",
        help = "Allow NPCs to use the physical ragdoll sitting task.",
        default = "1"
    },
    door_interaction = {
        label = "NPC door interactions",
        help = "Allow NPCs to open doors while navigating.",
        default = "1"
    },
    armed_civilian_bravery = {
        label = "Armed civilians resist fleeing",
        help = "Civilians with a weapon or ranged loadout do not use the normal flee behavior.",
        default = "1"
    },
    furry_pounce_build_up = {
        label = "Furry pounce build-up ragdoll",
        help = "Give furry pounces a short upright launch boost before entering fake-ragdoll control.",
        default = "1"
    },
    headcrab_pounce = {
        label = "Headcrab leap attacks",
        help = "Let managed headcrabs use charged hops to close on targets.",
        default = "1"
    },
    headcrab_infection = {
        label = "Headcrab infection and zombification",
        help = "A successful headcrab pounce can start Z-City's infection timer and eventually turn victims into zombies.",
        default = "1"
    },
    npc_squad_tactics = {
        label = "Combine / Rebel squad tactics",
        help = "Enable squad grouping, role selection, and coordinated combat positions.",
        default = "1"
    },
    zombie_horde_mind = {
        label = "Zombie horde mind",
        help = "Experimental: zombie NPCs and headcrabs can form loose shared horde squads.",
        default = "0"
    },
    civilian_panic_spread = {
        label = "Civilian panic spreads",
        help = "Nearby civilians may flee too when they see a civilian panic in response to a furry threat.",
        default = "1"
    }
}

BZCN.GameRules = RULES

if SERVER then
    for name, rule in pairs(RULES) do
        CreateConVar("bzcn_rule_" .. name, rule.default,
            bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY),
            rule.help, 0, 1)
    end

    function BZCN.RuleEnabled(name)
        local convar = GetConVar("bzcn_rule_" .. tostring(name or ""))
        return convar and convar:GetBool() or false
    end

    util.AddNetworkString("bzcn_gamerule_set")
    net.Receive("bzcn_gamerule_set", function(_, ply)
        if not IsValid(ply) or not ply:IsAdmin() then return end
        local name = net.ReadString()
        local enabled = net.ReadBool()
        if not RULES[name] then return end
        RunConsoleCommand("bzcn_rule_" .. name, enabled and "1" or "0")
    end)
else
    function BZCN.RuleEnabled(name)
        local convar = GetConVar("bzcn_rule_" .. tostring(name or ""))
        if convar then return convar:GetBool() end
        return true
    end

    hook.Add("PopulateToolMenu", "BZCN_GameRulesOptions", function()
        spawnmenu.AddToolMenuOption("Utilities", "User", "BZCN_GameRules",
            "Better ZCity NPCs", "", "", function(panel)
                panel:ClearControls()
                panel:Help("Server-authoritative gameplay rules. Changes require admin permissions.")
                local names = {}
                for name in pairs(RULES) do names[#names + 1] = name end
                table.sort(names)
                for _, name in ipairs(names) do
                    local rule = RULES[name]
                    local control = panel:CheckBox(rule.label)
                    control:SetTooltip(rule.help)
                    local convar = GetConVar("bzcn_rule_" .. name)
                    control:SetChecked(not convar or convar:GetBool())
                    control.OnChange = function(_, checked)
                        net.Start("bzcn_gamerule_set")
                        net.WriteString(name)
                        net.WriteBool(checked and true or false)
                        net.SendToServer()
                    end
                end
                panel:Help("Rule changes apply to the server and are replicated to clients.")
            end)
    end)
end
