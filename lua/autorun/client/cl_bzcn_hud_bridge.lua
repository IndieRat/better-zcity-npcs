-- Client-side mirror of the server adapter data for Z-City HUD/render hooks.
-- Never changes LocalPlayer or pretends a NextBot is a real Player entity.
if not CLIENT then return end

BZCN = BZCN or {}

surface.CreateFont("BZCN_NPCHudTitle", {
    font = "Bahnschrift",
    size = 18,
    weight = 700,
    antialias = true
})
surface.CreateFont("BZCN_NPCHudBody", {
    font = "Bahnschrift",
    size = 15,
    weight = 500,
    antialias = true
})

local function IsManaged(ent)
    return IsValid(ent) and ent.GetNW2Bool and ent:GetNW2Bool("BZCNManaged", false)
end

local function ResolveNPC(raw)
    if not IsValid(raw) then return nil end
    if IsManaged(raw) then return raw, raw end

    local owner = raw.GetNW2Entity and raw:GetNW2Entity("BZCNNPCOwner")
    if IsManaged(owner) then return owner, raw end
    owner = raw.GetNWEntity and raw:GetNWEntity("BZCNNPCOwner")
    if IsManaged(owner) then return owner, raw end
    return nil
end

local function ReadNumber(ent, key, fallback)
    local value = ent:GetNW2Float(key, fallback or 0)
    if not isnumber(value) then return fallback or 0 end
    return value
end

local function MirrorOrganism(npc)
    if not IsManaged(npc) then return nil end
    if not isstring(npc.PlayerClassName) or npc.PlayerClassName == "" then
        npc.PlayerClassName = npc:GetNW2String("PlayerClassName", npc:GetNW2String("BZCNClass", "default"))
    end
    if BZCN.InstallAdapter and not isfunction(npc.PlayerClassEvent) then
        BZCN.InstallAdapter(npc)
    end

    local health = ReadNumber(npc, "BZCNNPCHealth", npc:Health())
    local maxHealth = ReadNumber(npc, "BZCNNPCMaxHealth", npc:GetMaxHealth())
    local org = npc.BZCNClientOrganism or {}
    org.owner = npc
    org.alive = health > 0
    org.entindex = npc:EntIndex()
    org.health = health
    org.maxHealth = math.max(maxHealth, 1)
    org.blood = ReadNumber(npc, "BZCNNPCBlood", 5000)
    org.maxBlood = math.max(ReadNumber(npc, "BZCNNPCMaxBlood", 5000), 1)
    org.bloodtype = npc:GetNW2String("BZCNNPCBloodType", "unknown")
    org.pain = ReadNumber(npc, "BZCNNPCPain", 0)
    org.shock = ReadNumber(npc, "BZCNNPCShock", 0)
    org.skull = ReadNumber(npc, "BZCNNPCPart_head", 0)
    org.brain = ReadNumber(npc, "BZCNNPCBrain", 0)
    org.chest = ReadNumber(npc, "BZCNNPCPart_chest", 0)
    org.stomach = ReadNumber(npc, "BZCNNPCPart_abdomen", 0)
    org.pelvis = ReadNumber(npc, "BZCNNPCPart_pelvis", 0)
    org.larm = ReadNumber(npc, "BZCNNPCPart_leftarm", 0)
    org.rarm = ReadNumber(npc, "BZCNNPCPart_rightarm", 0)
    org.lleg = ReadNumber(npc, "BZCNNPCPart_leftleg", 0)
    org.rleg = ReadNumber(npc, "BZCNNPCPart_rightleg", 0)
    org.spine1 = ReadNumber(npc, "BZCNNPCSpine1", 0)
    org.spine2 = ReadNumber(npc, "BZCNNPCSpine2", 0)
    org.spine3 = ReadNumber(npc, "BZCNNPCSpine3", 0)
    org.heart = ReadNumber(npc, "BZCNNPCHeart", 0)
    org.liver = ReadNumber(npc, "BZCNNPCLiver", 0)
    org.intestines = ReadNumber(npc, "BZCNNPCIntestines", 0)
    org.lungsL = {
        ReadNumber(npc, "BZCNNPCLungsL1", 0),
        ReadNumber(npc, "BZCNNPCLungsL2", 0)
    }
    org.lungsR = {
        ReadNumber(npc, "BZCNNPCLungsR1", 0),
        ReadNumber(npc, "BZCNNPCLungsR2", 0)
    }
    org.otrub = npc:GetNW2Bool("BZCNNPCDowned", false)
    org.fake = npc:GetNW2Bool("BZCNNPCGettingUp", false)
    org.canmove = not (org.otrub or org.fake)
    org.wounds = org.wounds or {}
    org.arterialwounds = org.arterialwounds or {}
    org.dmgstack = org.dmgstack or {}

    npc.BZCNClientOrganism = org
    npc.BZCN_Organism = org
    -- On clients only, restore the familiar field shape for HUD and visual
    -- hooks. The server deliberately leaves this field unset for damage safety.
    npc.organism = org
    return org
end

hook.Add("Think", "BZCN_ClientOrganismMirror", function()
    if (BZCN.NextClientMirror or 0) > CurTime() then return end
    BZCN.NextClientMirror = CurTime() + 0.25

    for _, ent in ipairs(ents.GetAll()) do
        local npc = ResolveNPC(ent)
        if IsValid(npc) then
            MirrorOrganism(npc)
            if ent ~= npc and ent:IsRagdoll() then
                ent.BZCNClientOrganism = ent.BZCNClientOrganism or {}
                local ragOrg = ent.BZCNClientOrganism
                for key, value in pairs(npc.organism or {}) do ragOrg[key] = value end
                ragOrg.owner = npc
                ent.organism = ragOrg
                ent.BZCN_Organism = ragOrg
            end
        end
    end
end)

local function DrawNPCPanel(npc, body, trace)
    local org = MirrorOrganism(npc)
    if not org then return end

    local className = npc:GetNW2String("BZCNClass", "NPC")
    local name = npc:GetNW2String("BZCNDisplayName", className)
    local downed = npc:GetNW2Bool("BZCNNPCDowned", false)
    local crawling = npc:GetNW2Bool("BZCNNPCCrawling", false)
    local gettingUp = npc:GetNW2Bool("BZCNNPCGettingUp", false)
    local health = org.health
    local maxHealth = org.maxHealth
    local blood = org.blood
    local pain = org.pain
    local shock = org.shock
    local x, y, w, h = ScrW() - 326, ScrH() - 204, 306, 174

    draw.RoundedBox(6, x, y, w, h, Color(12, 15, 20, 225))
    surface.SetDrawColor(95, 170, 225, 230)
    surface.DrawOutlinedRect(x, y, w, h, 1)
    draw.SimpleText(name, "BZCN_NPCHudTitle", x + 12, y + 9, Color(225, 238, 250), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    draw.SimpleText(className .. "  ·  #" .. npc:EntIndex(), "BZCN_NPCHudBody", x + 12, y + 32, Color(145, 185, 215), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    local healthFraction = math.Clamp(health / math.max(maxHealth, 1), 0, 1)
    draw.RoundedBox(3, x + 12, y + 58, w - 24, 9, Color(45, 50, 58, 255))
    draw.RoundedBox(3, x + 12, y + 58, (w - 24) * healthFraction, 9, Color(115, 205, 145, 255))
    draw.SimpleText("HP  " .. math.floor(health) .. " / " .. math.floor(maxHealth), "BZCN_NPCHudBody", x + 12, y + 72, Color(235, 240, 245), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    draw.SimpleText("Blood  " .. math.floor(blood) .. " / " .. math.floor(org.maxBlood), "BZCN_NPCHudBody", x + 12, y + 93, Color(235, 175, 175), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    draw.SimpleText("Pain  " .. math.floor(pain) .. "     Shock  " .. math.floor(shock), "BZCN_NPCHudBody", x + 12, y + 114, Color(225, 215, 185), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    local parts = string.format("Head %.0f  Chest %.0f  Arms %.0f/%.0f  Legs %.0f/%.0f",
        org.skull, org.chest, org.larm, org.rarm, org.lleg, org.rleg)
    draw.SimpleText(parts, "BZCN_NPCHudBody", x + 12, y + 135, Color(200, 210, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    local state = downed and "DOWNED" or gettingUp and "RECOVERING" or crawling and "CRAWLING" or "ACTIVE"
    draw.SimpleText(state, "BZCN_NPCHudBody", x + w - 12, y + 9, downed and Color(255, 135, 120) or Color(180, 220, 190), TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP)

    local context = {
        npc = npc,
        target = body,
        trace = trace,
        actor = {
            Name = name,
            ClassName = className,
            PlayerClassName = npc:GetNW2String("PlayerClassName", className),
            Health = health,
            MaxHealth = maxHealth,
            Model = npc:GetModel(),
            Faction = npc:GetNW2String("BZCNFaction", className),
            EngineIsPlayer = false,
            IsPlayerLike = true
        },
        organism = org,
        downed = downed,
        crawling = crawling,
        gettingUp = gettingUp
    }

    if isfunction(npc.PlayerClassEvent) then
        pcall(npc.PlayerClassEvent, npc, "HUDPaint", context)
    end
    hook.Run("BZCN_NPCClientHUDPaint", npc, context)
end

hook.Add("HUDPaint", "BZCN_ClientHUDBridge", function()
    local ply = LocalPlayer()
    if not IsValid(ply) or not ply:Alive() then return end

    local trace = ply:GetEyeTrace()
    if not trace or not trace.Hit or not IsValid(trace.Entity) then return end
    local npc, body = ResolveNPC(trace.Entity)
    if not IsValid(npc) then return end
    if ply:GetPos():DistToSqr(body:GetPos()) > 1600 * 1600 then return end

    DrawNPCPanel(npc, body, trace)
end)
