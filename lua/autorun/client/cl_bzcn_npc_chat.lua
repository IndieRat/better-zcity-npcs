-- Display the short authored sentences broadcast by managed Z-City NPCs.
if not CLIENT then return end

BZCN = BZCN or {}

local FACTION_COLORS = {
    civilian = Color(230, 205, 160),
    Combine = Color(100, 215, 225),
    Rebel = Color(230, 160, 75),
    furry = Color(175, 150, 255),
    zombie = Color(120, 185, 105),
    headcrab = Color(140, 195, 100)
}

net.Receive("BZCN_NPCChat", function()
    local ent = net.ReadEntity()
    local message = net.ReadString()
    local faction = net.ReadString()
    if not isstring(message) or message == "" then return end

    local name = IsValid(ent) and ent:GetNW2String("BZCNDisplayName", "") or ""
    if name == "" and IsValid(ent) then
        name = ent:GetNWString("PlayerName", "")
    end
    if name == "" then name = IsValid(ent) and ent:GetClass() or "NPC" end

    local color = FACTION_COLORS[faction] or Color(220, 220, 220)
    chat.AddText(color, name, color_white, ": ", message)
end)
