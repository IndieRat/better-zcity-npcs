-- Persistent mouth blood for Better Z-City horror zombies.
-- This small world-space smear/drop supplements Z-City's native wound particles.
if not CLIENT then return end

local mouthBlood = Material("sprites/light_glow02_add")
local scanList = {}

local function IsHorrorZombie(ent)
    return IsValid(ent) and not ent:IsPlayer() and ent.GetNW2Bool
        and ent:GetNW2Bool("BZCNZombieMouthBlood", false)
end

timer.Create("BZCN_ZombieMouthBloodScan", 1, 0, function()
    local nextList = {}
    for _, ent in ipairs(ents.GetAll()) do
        if IsHorrorZombie(ent) then nextList[#nextList + 1] = ent end
    end
    scanList = nextList
end)

local function GetBloodHead(ent)
    local body = IsValid(ent.FakeRagdoll) and ent.FakeRagdoll
        or (IsValid(ent.BZCNNPCRagdoll) and ent.BZCNNPCRagdoll or nil)
    if not IsValid(body) and ent.GetNWEntity then
        for _, key in ipairs({"FakeRagdoll", "ragdoll"}) do
            local ok, result = pcall(ent.GetNWEntity, ent, key)
            if ok and IsValid(result) and result:GetClass() == "prop_ragdoll" then
                body = result
                break
            end
        end
    end
    if not IsValid(body) then body = ent end
    if not IsValid(body) or not body.LookupBone then return nil end
    if body.SetupBones then pcall(body.SetupBones, body) end

    local bone = body:LookupBone("ValveBiped.Bip01_Head1")
    if not isnumber(bone) or bone < 0 then bone = body:LookupBone("ValveBiped.Bip01_Neck1") end
    if not isnumber(bone) or bone < 0 then return nil end

    if body.GetBoneMatrix then
        local matrix = body:GetBoneMatrix(bone)
        if matrix then
            local position, angle = matrix:GetTranslation(), matrix:GetAngles()
            return position + angle:Forward() * 3.5 - angle:Up() * 2.5, angle
        end
    end
    if body.GetBonePosition then
        local position, angle = body:GetBonePosition(bone)
        if isvector(position) and isangle(angle) and position ~= vector_origin then
            return position + angle:Forward() * 3.5 - angle:Up() * 2.5, angle
        end
    end
    return nil
end

hook.Add("PostDrawTranslucentRenderables", "BZCN_ZombieMouthBlood", function(depth, skybox)
    if skybox then return end
    local viewer = EyePos()
    for _, ent in ipairs(scanList) do
        if not IsValid(ent) or not IsHorrorZombie(ent) then continue end
        local position, angle = GetBloodHead(ent)
        if not isvector(position) or viewer:DistToSqr(position) > 1800 * 1800 then continue end

        render.SetMaterial(mouthBlood)
        render.DrawSprite(position, 4, 3.5, Color(92, 3, 5, 225))
        local drip = position - (angle and angle:Up() or vector_up) * 3.5
        render.DrawSprite(drip, 1.9, 4.5, Color(70, 0, 2, 215))
    end
end)
