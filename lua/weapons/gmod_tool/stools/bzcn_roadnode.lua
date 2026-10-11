TOOL.Category = "Better ZCity"
TOOL.Name = "#tool.bzcn_roadnode.name"
TOOL.Command = nil
TOOL.ConfigName = ""
TOOL.Information = {
    {name = "left", stage = 0, text = "#tool.bzcn_roadnode.left"},
    {name = "right", stage = 0, text = "#tool.bzcn_roadnode.right"},
    {name = "reload", stage = 0, text = "#tool.bzcn_roadnode.reload"}
}

if CLIENT then
    language.Add("tool.bzcn_roadnode.name", "BZCN Road Nodes")
    language.Add("tool.bzcn_roadnode.desc", "Place and link map-specific NPC vehicle routes.")
    language.Add("tool.bzcn_roadnode.left", "Place a road node (auto-links the nearest node)")
    language.Add("tool.bzcn_roadnode.right", "Select a node, then right-click another to toggle a link")
    language.Add("tool.bzcn_roadnode.reload", "Remove the nearest road node")

    local graph = {nodes = {}}
    local matNode = Material("sprites/light_glow02_add")
    net.Receive("BZCN_RoadNodes", function()
        local raw = net.ReadString()
        local decoded = util.JSONToTable(raw or "")
        if istable(decoded) then graph = decoded end
    end)

    hook.Add("PostDrawTranslucentRenderables", "BZCN_DrawRoadNodesTool", function()
        local ply = LocalPlayer()
        if not IsValid(ply) or not IsValid(ply:GetActiveWeapon())
            or ply:GetActiveWeapon():GetClass() ~= "gmod_tool"
            or ply:GetInfo("gmod_toolmode") ~= "bzcn_roadnode" then return end

        local byID = {}
        for _, node in ipairs(graph.nodes or {}) do
            if isnumber(node.id) and isnumber(node.x) and isnumber(node.y) and isnumber(node.z) then
                byID[node.id] = node
            end
        end

        render.SetMaterial(matNode)
        for _, node in pairs(byID) do
            local pos = Vector(node.x, node.y, node.z)
            render.DrawSprite(pos, 13, 13, Color(90, 220, 255, 230))
            for _, linkedID in ipairs(node.links or {}) do
                local linked = byID[linkedID]
                if linked and node.id < linked.id then
                    render.DrawLine(pos, Vector(linked.x, linked.y, linked.z), Color(90, 220, 255, 210), true)
                end
            end
        end
    end)
end

function TOOL:LeftClick(trace)
    if CLIENT then return true end
    local ply = self:GetOwner()
    if not IsValid(ply) or not ply:IsAdmin() then return false end
    if not trace.Hit then return false end
    if not BZCNRoads then
        ply:ChatPrint("[BZCN Roads] Road system is not loaded.")
        return false
    end
    local position = trace.HitPos + trace.HitNormal * 2
    -- Cache the nearest old node before insertion, because AddNode returns the
    -- new node as the nearest result once it has been inserted.
    local nearest, distance = BZCNRoads:Nearest(position, 1500)
    local node = BZCNRoads:AddNode(position, ply)
    if node and nearest and nearest.id ~= node.id and distance and distance >= 90
        and not table.HasValue(node.links or {}, nearest.id) then
        BZCNRoads:Connect(node.id, nearest.id, false)
    end
    return true
end

function TOOL:RightClick(trace)
    if CLIENT then return true end
    local ply = self:GetOwner()
    if not IsValid(ply) or not ply:IsAdmin() then return false end
    if not trace.Hit or not BZCNRoads then return false end
    BZCNRoads:SelectOrConnect(ply, trace.HitPos)
    return true
end

function TOOL:Reload(trace)
    if CLIENT then return true end
    local ply = self:GetOwner()
    if not IsValid(ply) or not ply:IsAdmin() then return false end
    if not trace.Hit or not BZCNRoads then return false end
    BZCNRoads:RemoveNearest(trace.HitPos, ply)
    return true
end
