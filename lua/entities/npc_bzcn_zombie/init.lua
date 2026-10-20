AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

function ENT:SpawnFunction(ply, trace, className)
    if not trace or not trace.Hit then return end
    local ent = ents.Create(className or "npc_bzcn_zombie")
    if not IsValid(ent) then return end
    ent:SetPos(trace.HitPos + Vector(0, 0, 8))
    ent:Spawn()
    ent:Activate()
    return ent
end
