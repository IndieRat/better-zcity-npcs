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

local function DispatchNPCContext(npc, body, trace)
    local org = MirrorOrganism(npc)
    if not org then return end

    local name = npc:GetNW2String("BZCNDisplayName", npc:GetNWString("PlayerName", "NPC"))
    local internalClass = npc:GetNW2String("BZCNClass", "NPC")
    local downed = npc:GetNW2Bool("BZCNNPCDowned", false)
    local crawling = npc:GetNW2Bool("BZCNNPCCrawling", false)
    local gettingUp = npc:GetNW2Bool("BZCNNPCGettingUp", false)
    local context = {
        npc = npc,
        target = body,
        trace = trace,
        actor = {
            Name = name,
            -- Keep class metadata available to integrations, but never render
            -- the internal or display class as a second HUD label.
            ClassName = internalClass,
            InternalClass = internalClass,
            PlayerClassName = npc:GetNW2String("PlayerClassName", internalClass),
            Health = org.health,
            MaxHealth = org.maxHealth,
            Model = npc:GetModel(),
            Faction = npc:GetNW2String("BZCNFaction", ""),
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

    -- Z-City-style identifier: one name at the looked-at body's world position.
    -- The legacy bottom-right diagnostic panel and duplicate class line are gone.
    local screen = trace.HitPos:ToScreen()
    local size = math.max(math.min(1 - (trace.Fraction or 1), 1), 0.1)
    local alpha = math.floor(255 * math.Clamp(size * 1.5, 0.15, 1))
    local colorVector = npc:GetNWVector("PlayerColor", Vector(0.65, 0.78, 0.9))
    local nameColor = Color(
        math.Clamp(colorVector.x * 255, 0, 255),
        math.Clamp(colorVector.y * 255, 0, 255),
        math.Clamp(colorVector.z * 255, 0, 255), alpha
    )
    local label = npc:GetNW2String("BZCNDisplayName", npc:GetNWString("PlayerName", "NPC"))
    draw.SimpleTextOutlined(label, "HomigradFontLarge", screen.x, screen.y + 30,
        nameColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, Color(0, 0, 0, alpha))

    DispatchNPCContext(npc, body, trace)
end)

-- Progress display for a furry player assimilating a managed NPC. Z-City's
-- native bar expects a Player-owned carryent, while managed NextBot ragdolls
-- use the explicit bridge above; use replicated progress as the common signal.
hook.Add("HUDPaint", "BZCN_PlayerAssimilationProgress", function()
    local ply = LocalPlayer()
    if not IsValid(ply) or not ply:Alive()
        or not ply:GetNW2Bool("BZCNAssimilationActive", false) then return end

    local progress = math.Clamp(ply:GetNW2Float("BZCNAssimilation", 0), 0, 1)
    local width, height = math.min(ScrW() * 0.3, 420), 16
    local x, y = (ScrW() - width) * 0.5, ScrH() * 0.77

    draw.SimpleTextOutlined("Assimilating...", "BZCN_NPCHudTitle",
        ScrW() * 0.5, y - 26, Color(180, 205, 255),
        TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, Color(0, 0, 0, 220))
    draw.RoundedBox(5, x, y, width, height, Color(12, 15, 20, 225))
    draw.RoundedBox(4, x + 2, y + 2, (width - 4) * progress, height - 4,
        Color(150, 160, 245, 240))
    draw.SimpleText(math.floor(progress * 100) .. "%", "BZCN_NPCHudBody",
        ScrW() * 0.5, y + height + 3, Color(230, 235, 255),
        TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
end)
