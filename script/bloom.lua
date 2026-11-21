
-- =========================================================
-- SPIRITS HUNTER HUB ULTIMATE (DIMENSIUI EDITION)
-- UI: DimensiUI | Theme: Dimensi (Dark Purple)
-- Author / Credit: telatnakal
-- =========================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local VirtualUser = game:GetService("VirtualUser")
local Lighting = game:GetService("Lighting")
local VirtualInputManager = game:GetService("VirtualInputManager")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local DimensiUI = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/telatnakal/DimensiUI/main/dist/main.lua"
))()

local Spirits = workspace:WaitForChild("Spirits", 30)
local Orbs = workspace:FindFirstChild("SparkOrbs") or workspace:FindFirstChild("Orbs")

if not Spirits then
    warn("Folder Spirits tidak ditemukan.")
    return
end

-- =========================================================
-- CONFIGURATION
-- =========================================================

local CONFIG = {
    Speed = 35,
    NormalSpeed = 16,

    MoveInterval = 0.12,
    MoveOrderInterval = 0.15,

    OrbReached = 5,
    SpiritReached = 5,

    OrbZoneSize = 120,
    OrbCooldown = 20,
    OrbBlockedTime = 10,

    OrbJumpHeight = 2.5,
    OrbJumpDistance = 24,
    OrbJumpCooldown = 0.9,

    StuckLimit = 7,
    StuckCheckInterval = 1,
    StuckMinMovement = 1.2,
}

local CONFIG_FARM = {
    InteractDistance = 3.5,
    ScanInterval = 0.5,
    PotDelay = 0.8,
    PlantRetryDelay = 1,
    PlantRetries = 2,
    BaseReturnDistance = 25,
    MoveOrderInterval = 0.65,
    KeyPressDuration = 0.25,
}

local CONFIG_ALLIN = {
    MinEnergyThreshold = 100,     -- Batas bawah: Di bawah 100 mulai cari Orb/Spirit
    TargetEnergy = 2000,          -- Batas atas: Jika sudah >= 2000, kembali ke Auto Farm
    SwitchInterval = 240,         -- Interval 240 detik (4 menit) switch & refresh Orb/Spirit
}

-- =========================================================
-- STATE
-- =========================================================

local State = {
    playerESP = true,
    spiritESP = true,

    autoSpirit = false,
    autoOrb = false,

    speedBoost = false,
    noClip = false,
    manualNoClip = false,
    autoNoClip = false,

    fpsBoost = false,
    antiAFK = false,
    unloaded = false,

    currentSpirit = nil,
    currentOrb = nil,

    visitedOrbs = {},
    blockedOrbs = {},
    zoneHistory = {},

    lastMove = 0,
    lastMoveOrder = 0,
    lastJump = 0,

    stuckCheckPosition = nil,
    stuckCheckTime = 0,
    stuckTime = 0,

    originalLighting = {},
    originalCollisions = {},
}

local StateFarm = {
    autoFarmToggle = false,
    lastBaseTeleport = 0,
    currentBedNumber = 1,
    nextActionAllowedTime = 0,
    nextScanTime = 0,
    lastMoveOrder = 0,
    activePlot = nil,
    busy = false,
}

local StateAllIn = {
    autoAllInToggle = false,
    mode = "IDLE",                -- "IDLE", "SEARCHING", atau "FARMING"
    searchType = "ORB",           -- "ORB" atau "SPIRIT"
    timerStart = 0,
}

local PACE = {
    boost = CONFIG.Speed,
    normal = CONFIG.NormalSpeed,
}

local Connections = {}
local speedHooked
local speedConn

local function trackConnection(conn)
    if conn then
        table.insert(Connections, conn)
    end
    return conn
end

-- =========================================================
-- TIER CONFIGURATION
-- =========================================================

local TierNames = {
    [1] = "COMMON",
    [2] = "UNCOMMON",
    [3] = "RARE",
    [4] = "EPIC",
    [5] = "MYTHIC",
}

local TierColors = {
    MYTHIC = Color3.fromRGB(255, 215, 0),
    EPIC = Color3.fromRGB(217, 70, 239),
    RARE = Color3.fromRGB(57, 139, 255),
    UNCOMMON = Color3.fromRGB(57, 217, 138),
    COMMON = Color3.fromRGB(209, 213, 219),
    UNKNOWN = Color3.fromRGB(255, 140, 66),
}

local PlayerESPColor = Color3.fromRGB(255, 140, 0)

local TierFilter = {
    MYTHIC = true,
    EPIC = true,
    RARE = true,
    UNCOMMON = false,
    COMMON = false,
}

-- =========================================================
-- ESP STORAGE
-- =========================================================

local ESPFolder = Instance.new("Folder")
ESPFolder.Name = "SpiritsHunterESP"
ESPFolder.Parent = PlayerGui

local PlayerCache = {}
local SpiritCache = {}

-- =========================================================
-- GENERAL FUNCTIONS
-- =========================================================

local function notify(title, content)
    if State.unloaded then return end
    pcall(function()
        DimensiUI:Notify({
            Title = title,
            Content = content,
            Duration = 3,
        })
    end)
end

local function getRoot()
    local character = LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
    local character = LocalPlayer.Character
    return character and character:FindFirstChildOfClass("Humanoid")
end

local function getAnchor(object)
    if not object then return nil end
    if object:IsA("BasePart") then return object end
    if object:IsA("Model") then
        return object.PrimaryPart or object:FindFirstChildWhichIsA("BasePart", true)
    end
    return object:FindFirstChildWhichIsA("BasePart", true)
end

local function getTier(object)
    local raw = object:GetAttribute("Tier")
    if type(raw) == "number" then
        return TierNames[raw] or "UNKNOWN"
    end
    if type(raw) == "string" then
        local tier = string.upper(raw)
        if TierColors[tier] then return tier end
    end
    return "UNKNOWN"
end

local function isTierAllowed(object)
    return TierFilter[getTier(object)] == true
end

local function getSpiritName(object)
    return object:GetAttribute("Species") or object.Name
end

local function getEnergy()
    local energyAttr = LocalPlayer:GetAttribute("Energy")
    if energyAttr ~= nil then
        return tonumber(energyAttr) or 0
    end
    return 0
end

-- =========================================================
-- ESP CREATION & UPDATE
-- =========================================================

local function makeESP(name, color)
    local billboard = Instance.new("BillboardGui")
    billboard.Name = name
    billboard.Size = UDim2.fromOffset(230, 38)
    billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
    billboard.AlwaysOnTop = true
    billboard.LightInfluence = 0
    billboard.MaxDistance = 2500

    local label = Instance.new("TextLabel")
    label.Name = "Label"
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamBold
    label.TextSize = 13
    label.TextColor3 = color
    label.TextStrokeTransparency = 0.25
    label.TextWrapped = true
    label.RichText = true
    label.Parent = billboard

    billboard.Parent = ESPFolder
    return billboard, label
end

local function destroyPlayerESP(targetPlayer)
    local entry = PlayerCache[targetPlayer]
    if entry then
        if entry.gui then entry.gui:Destroy() end
        PlayerCache[targetPlayer] = nil
    end
end

local function updatePlayerESP()
    if State.unloaded then return end
    for _, targetPlayer in ipairs(Players:GetPlayers()) do
        if targetPlayer ~= LocalPlayer then
            local character = targetPlayer.Character
            local targetRoot = character and character:FindFirstChild("HumanoidRootPart")

            if State.playerESP and targetRoot then
                local entry = PlayerCache[targetPlayer]
                if not entry then
                    local gui, label = makeESP("PlayerESP", PlayerESPColor)
                    entry = { gui = gui, label = label }
                    PlayerCache[targetPlayer] = entry
                end
                entry.gui.Adornee = targetRoot
                entry.label.Text = targetPlayer.DisplayName
            else
                destroyPlayerESP(targetPlayer)
            end
        end
    end
end

local function destroySpiritESP(object)
    local entry = SpiritCache[object]
    if entry then
        if entry.gui then entry.gui:Destroy() end
        SpiritCache[object] = nil
    end
end

local function updateSpiritESP()
    if State.unloaded or not Spirits or not Spirits.Parent then return end
    for _, object in ipairs(Spirits:GetChildren()) do
        local anchor = getAnchor(object)
        if anchor then
            local tier = getTier(object)
            local allowed = State.spiritESP and TierFilter[tier] == true

            if allowed then
                local entry = SpiritCache[object]
                if not entry then
                    local gui, label = makeESP("SpiritESP", TierColors[tier] or TierColors.UNKNOWN)
                    entry = { gui = gui, label = label }
                    SpiritCache[object] = entry
                end
                entry.gui.Adornee = anchor
                entry.label.TextColor3 = TierColors[tier] or TierColors.UNKNOWN
                entry.label.Text = string.format("[%s] %s", tier, tostring(getSpiritName(object)))
            else
                destroySpiritESP(object)
            end
        end
    end
end

-- =========================================================
-- AUTO FARM SYSTEM
-- =========================================================

local function resetFarmState()
    StateFarm.currentBedNumber = 1
    StateFarm.nextActionAllowedTime = 0
    StateFarm.nextScanTime = 0
    StateFarm.lastMoveOrder = 0
    StateFarm.busy = false
end

local function getPlotDistance(plot, root)
    local nearest = math.huge
    for _, obj in ipairs(plot:GetDescendants()) do
        if obj:GetAttribute("PotV7") == true then
            local point = obj:FindFirstChild("SeedPoint") or obj:FindFirstChildWhichIsA("BasePart")
            if point then
                nearest = math.min(nearest, (root.Position - point.Position).Magnitude)
            end
        end
    end
    return nearest
end

local function getOwnedPlot()
    local groves = workspace:FindFirstChild("Groves")
    local root = getRoot()
    if not groves or not root then return nil end

    local selected, shortest = nil, math.huge
    for _, plot in ipairs(groves:GetChildren()) do
        local owner = plot:GetAttribute("Owner")
        if owner ~= nil and tostring(owner) == tostring(LocalPlayer.UserId) then
            local distance = getPlotDistance(plot, root)
            if distance < shortest then
                selected = plot
                shortest = distance
            end
        end
    end
    return selected
end

local function getPlayerPots(plot)
    local pots = {}
    if not plot then return pots end

    local nursery = plot:FindFirstChild("Nursery")
    if not nursery then return pots end

    for _, obj in ipairs(nursery:GetChildren()) do
        if obj:GetAttribute("PotV7") == true then
            local bedNum = tonumber(obj:GetAttribute("Bed"))
            local seedPoint = obj:FindFirstChild("SeedPoint")

            if seedPoint and seedPoint:IsA("BasePart") and bedNum and bedNum >= 1 then
                table.insert(pots, {
                    Model = obj,
                    BedNumber = bedNum,
                    SeedType = obj:GetAttribute("SeedPot"),
                    TargetPart = seedPoint,
                })
            end
        end
    end

    table.sort(pots, function(a, b)
        return a.BedNumber < b.BedNumber
    end)
    return pots
end

local function getSeedForBed(plot, bedNumber)
    local blooms = plot and plot:FindFirstChild("Blooms")
    if not blooms then return nil end

    for _, seed in ipairs(blooms:GetChildren()) do
        if seed:GetAttribute("IsSeed") == true
            and tonumber(seed:GetAttribute("Bed")) == bedNumber then
            return seed
        end
    end
    return nil
end

local function getSeedPrompt(seed)
    if not seed then return nil end
    for _, obj in ipairs(seed:GetDescendants()) do
        if obj:IsA("ProximityPrompt") and string.lower(obj.ActionText) == "harvest" then
            return obj
        end
    end
    return nil
end

local function getBedStatus(plot, pot)
    local seed = getSeedForBed(plot, pot.BedNumber)
    if seed then
        local prompt = getSeedPrompt(seed)
        local readyAt = tonumber(seed:GetAttribute("ReadyAt"))
        local readyLabel = false

        for _, obj in ipairs(seed:GetDescendants()) do
            if obj:IsA("TextLabel") and string.lower((obj.Text or "")) == "ready" then
                readyLabel = true
                break
            end
        end

        local timeReady = (readyAt ~= nil and readyAt <= os.time())
        if prompt and prompt.Enabled and (readyLabel or timeReady) then
            return "READY", seed, prompt
        end
        return "GROWING", seed, prompt
    end

    return "EMPTY", nil, nil
end

local function sendKey(keyCode, duration)
    local pressed = pcall(function()
        VirtualInputManager:SendKeyEvent(true, keyCode, false, game)
    end)

    if not pressed then return false end

    task.wait(duration or CONFIG_FARM.KeyPressDuration)

    pcall(function()
        VirtualInputManager:SendKeyEvent(false, keyCode, false, game)
    end)

    return true
end

local function pressKeyF()
    sendKey(Enum.KeyCode.F, CONFIG_FARM.KeyPressDuration)
end

local function holdKeyE(prompt)
    local hold = prompt and tonumber(prompt.HoldDuration) or 0.3
    sendKey(Enum.KeyCode.E, math.clamp(hold + 0.12, 0.2, 1.5))
end

local function advanceFarmBed(pots, currentBed)
    for _, pot in ipairs(pots) do
        if pot.BedNumber > currentBed then
            return pot.BedNumber
        end
    end
    return pots[1] and pots[1].BedNumber or 1
end

local function findCurrentPot(pots, bedNumber)
    for _, pot in ipairs(pots) do
        if pot.BedNumber == bedNumber then
            return pot
        end
    end
    return nil
end

local function updateAutoFarm()
    if State.unloaded or StateFarm.busy then return end

    local root = getRoot()
    local humanoid = getHumanoid()
    if not root or not humanoid or humanoid.Health <= 0 then return end

    local now = os.clock()
    if now < StateFarm.nextActionAllowedTime or now < StateFarm.nextScanTime then
        return
    end
    StateFarm.nextScanTime = now + CONFIG_FARM.ScanInterval

    local plot = getOwnedPlot()
    if not plot then
        if now - StateFarm.lastBaseTeleport >= 8 then
            StateFarm.lastBaseTeleport = now
            task.spawn(function() sendKey(Enum.KeyCode.G, 0.08) end)
        end
        return
    end

    StateFarm.activePlot = plot
    local pots = getPlayerPots(plot)
    if #pots == 0 then
        if now - StateFarm.lastBaseTeleport >= 8 then
            StateFarm.lastBaseTeleport = now
            task.spawn(function() sendKey(Enum.KeyCode.G, 0.08) end)
        end
        return
    end

    local pot = findCurrentPot(pots, StateFarm.currentBedNumber)
    if not pot then
        StateFarm.currentBedNumber = advanceFarmBed(pots, StateFarm.currentBedNumber)
        pot = findCurrentPot(pots, StateFarm.currentBedNumber)
        if not pot then return end
    end

    local status, _, prompt = getBedStatus(plot, pot)

    if status == "GROWING" or status == "UNKNOWN" then
        StateFarm.currentBedNumber = advanceFarmBed(pots, pot.BedNumber)
        StateFarm.nextActionAllowedTime = now + CONFIG_FARM.PotDelay
        return
    end

    local target = pot.TargetPart
    local offset = root.Position - target.Position
    local horizontalDistance = Vector2.new(offset.X, offset.Z).Magnitude
    local verticalDistance = math.abs(offset.Y)

    if horizontalDistance > (CONFIG_FARM.InteractDistance + 1.25) or verticalDistance > 7 then
        if now - StateFarm.lastMoveOrder >= CONFIG_FARM.MoveOrderInterval then
            humanoid:MoveTo(target.Position)
            StateFarm.lastMoveOrder = now
        end
        return
    end

    StateFarm.busy = true
    StateFarm.lastMoveOrder = 0
    humanoid:MoveTo(root.Position)

    task.spawn(function()
        local actionOK, actionError = pcall(function()
            if not StateFarm.autoFarmToggle or State.unloaded then return end

            if status == "EMPTY" then
                local planted = false
                for attempt = 1, CONFIG_FARM.PlantRetries + 1 do
                    pressKeyF()
                    task.wait(CONFIG_FARM.PlantRetryDelay)

                    if getSeedForBed(plot, pot.BedNumber) then
                        planted = true
                        break
                    end

                    if attempt <= CONFIG_FARM.PlantRetries then
                        task.wait(0.15)
                    end
                end

                if planted then
                    StateFarm.currentBedNumber = advanceFarmBed(pots, pot.BedNumber)
                    StateFarm.nextActionAllowedTime = os.clock() + CONFIG_FARM.PotDelay
                else
                    StateFarm.currentBedNumber = pot.BedNumber
                    StateFarm.nextActionAllowedTime = os.clock() + CONFIG_FARM.PlantRetryDelay
                end

            elseif status == "READY" and prompt and prompt.Parent and prompt.Enabled then
                holdKeyE(prompt)
                StateFarm.currentBedNumber = advanceFarmBed(pots, pot.BedNumber)
                StateFarm.nextActionAllowedTime = os.clock() + CONFIG_FARM.PotDelay
            end
        end)

        if not actionOK then
            warn("[Auto Farm] Bed " .. tostring(pot.BedNumber) .. " error: " .. tostring(actionError))
            StateFarm.currentBedNumber = pot.BedNumber
            StateFarm.nextActionAllowedTime = os.clock() + CONFIG_FARM.PlantRetryDelay
        end

        StateFarm.busy = false
    end)
end

-- =========================================================
-- MOVEMENT, ORB & SPIRIT SYSTEMS
-- =========================================================

local connectOrbEvents

local function ensureOrbsFolder()
    if not Orbs or not Orbs.Parent then
        local found = workspace:FindFirstChild("SparkOrbs") or workspace:FindFirstChild("Orbs")
        if found and found ~= Orbs then
            Orbs = found
            connectOrbEvents()
        elseif found then
            Orbs = found
        end
    end
    return Orbs
end

local function clearOrbCache()
    table.clear(State.visitedOrbs)
    table.clear(State.blockedOrbs)
    table.clear(State.zoneHistory)
    State.currentOrb = nil
end

local function clearSpiritCache()
    State.currentSpirit = nil
end

local function getNearestSpirit()
    local root = getRoot()
    if not root or not Spirits or not Spirits.Parent then return nil end
    local nearest, shortest = nil, math.huge

    for _, object in ipairs(Spirits:GetChildren()) do
        local anchor = getAnchor(object)
        if anchor and isTierAllowed(object) then
            local distance = (root.Position - anchor.Position).Magnitude
            if distance < shortest then
                shortest = distance
                nearest = object
            end
        end
    end
    return nearest
end

local function getOrbZone(position)
    local size = CONFIG.OrbZoneSize
    return tostring(math.floor(position.X / size)) .. ":" .. tostring(math.floor(position.Z / size))
end

local function getNextOrb()
    local orbFolder = ensureOrbsFolder()
    if not orbFolder then return nil end
    local root = getRoot()
    if not root then return nil end

    local now = os.clock()
    local zones = {}

    for _, object in ipairs(orbFolder:GetChildren()) do
        local anchor = getAnchor(object)
        if anchor then
            local visitedAt = State.visitedOrbs[object]
            local blockedUntil = State.blockedOrbs[object]

            if visitedAt and now - visitedAt >= CONFIG.OrbCooldown then
                State.visitedOrbs[object] = nil
                visitedAt = nil
            end
            if blockedUntil and now >= blockedUntil then
                State.blockedOrbs[object] = nil
                blockedUntil = nil
            end

            if not visitedAt and not blockedUntil then
                local zone = getOrbZone(anchor.Position)
                zones[zone] = zones[zone] or {
                    objects = {},
                    history = State.zoneHistory[zone] or 0,
                    distance = math.huge,
                }
                local distance = (root.Position - anchor.Position).Magnitude
                table.insert(zones[zone].objects, { object = object, distance = distance })
                zones[zone].distance = math.min(zones[zone].distance, distance)
            end
        end
    end

    local chosenZone, oldestHistory, shortestDistance = nil, math.huge, math.huge
    for zone, data in pairs(zones) do
        if data.history < oldestHistory or (data.history == oldestHistory and data.distance < shortestDistance) then
            chosenZone = zone
            oldestHistory = data.history
            shortestDistance = data.distance
        end
    end

    if not chosenZone then return nil end

    local selected
    for _, item in ipairs(zones[chosenZone].objects) do
        if not selected or item.distance < selected.distance then
            selected = item
        end
    end

    if selected then
        State.zoneHistory[chosenZone] = now
        return selected.object
    end
    return nil
end

local function resetMovement()
    State.currentSpirit = nil
    State.currentOrb = nil
    State.stuckCheckPosition = nil
    State.stuckCheckTime = 0
    State.stuckTime = 0
    State.lastMove = 0
    State.lastMoveOrder = 0
    State.lastJump = 0
end

local setNoClip

local function stopMovement()
    State.autoSpirit = false
    State.autoOrb = false
    StateFarm.autoFarmToggle = false
    StateAllIn.autoAllInToggle = false
    StateAllIn.mode = "IDLE"
    State.autoNoClip = false
    if setNoClip then setNoClip(State.manualNoClip) end

    resetMovement()

    local humanoid = getHumanoid()
    local root = getRoot()
    if humanoid and root then
        humanoid:MoveTo(root.Position)
    end
end

local function enforceSpeed(humanoid)
    if not humanoid or humanoid.WalkSpeed == PACE.boost then return end
    pcall(function() humanoid.WalkSpeed = PACE.boost end)
end

local function watchSpeed(humanoid)
    if speedHooked == humanoid then return end
    if speedConn then
        speedConn:Disconnect()
        speedConn = nil
    end
    speedHooked = humanoid
    if not humanoid then return end

    local ok, connection = pcall(function()
        return humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
            if State.speedBoost and not State.unloaded then
                enforceSpeed(humanoid)
            end
        end)
    end)
    if ok then speedConn = connection end
end

local function setSpeedBoost(value)
    State.speedBoost = value
    local humanoid = getHumanoid()
    if value then
        watchSpeed(humanoid)
        enforceSpeed(humanoid)
        return
    end
    watchSpeed(nil)
    if humanoid then
        pcall(function() humanoid.WalkSpeed = PACE.normal end)
    end
end

local function jumpTowardOrb(humanoid, root, anchor)
    local offset = anchor.Position - root.Position
    local horizontalDistance = Vector3.new(offset.X, 0, offset.Z).Magnitude
    local verticalDifference = offset.Y

    if verticalDifference < CONFIG.OrbJumpHeight then return end
    if horizontalDistance > CONFIG.OrbReached then return end
    if humanoid.FloorMaterial == Enum.Material.Air then return end
    if os.clock() - State.lastJump < CONFIG.OrbJumpCooldown then return end

    State.lastJump = os.clock()
    humanoid.Jump = true

    pcall(function()
        humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
    end)
end

local function getOrbMovePosition(root, anchor)
    local offset = anchor.Position - root.Position
    if offset.Y > CONFIG.OrbJumpHeight then
        return Vector3.new(anchor.Position.X, root.Position.Y, anchor.Position.Z)
    end
    return anchor.Position
end

local function checkMovementProgress(root, humanoid, target, anchor, isOrb)
    local now = os.clock()
    if not State.stuckCheckPosition then
        State.stuckCheckPosition = root.Position
        State.stuckCheckTime = now
        return
    end

    if now - State.stuckCheckTime < CONFIG.StuckCheckInterval then return end
    local moved = (root.Position - State.stuckCheckPosition).Magnitude
    State.stuckCheckPosition = root.Position
    State.stuckCheckTime = now

    if humanoid.FloorMaterial == Enum.Material.Air then
        State.stuckTime = 0
        return
    end

    local remaining = (anchor.Position - root.Position).Magnitude
    local reached = isOrb and CONFIG.OrbReached or CONFIG.SpiritReached

    if moved < CONFIG.StuckMinMovement and remaining > reached then
        State.stuckTime += CONFIG.StuckCheckInterval
        if isOrb then
            jumpTowardOrb(humanoid, root, anchor)
            humanoid:MoveTo(getOrbMovePosition(root, anchor))
        else
            humanoid:MoveTo(anchor.Position)
        end

        State.lastMoveOrder = now

        if State.stuckTime >= CONFIG.StuckLimit then
            if isOrb then
                State.blockedOrbs[target] = now + CONFIG.OrbBlockedTime
                State.currentOrb = nil
            else
                State.currentSpirit = nil
            end
            State.stuckTime = 0
            State.stuckCheckPosition = nil
            State.stuckCheckTime = 0
            State.lastMoveOrder = 0
        end
    else
        State.stuckTime = 0
    end
end

local function updateMovement()
    if State.unloaded then return end
    local root = getRoot()
    local humanoid = getHumanoid()
    if not root or not humanoid or humanoid.Health <= 0 then return end
    if not State.autoSpirit and not State.autoOrb then return end

    local now = os.clock()
    if now - State.lastMove < CONFIG.MoveInterval then return end
    State.lastMove = now

    local target
    local isOrbTarget = false

    if State.autoOrb and not State.autoSpirit then
        if not State.currentOrb or not State.currentOrb.Parent then
            State.currentOrb = getNextOrb()
            State.stuckTime = 0
            State.stuckCheckPosition = nil
        end
        target = State.currentOrb
        isOrbTarget = true
    elseif State.autoSpirit and not State.autoOrb then
        if not State.currentSpirit or not State.currentSpirit.Parent or not isTierAllowed(State.currentSpirit) then
            State.currentSpirit = getNearestSpirit()
            State.stuckTime = 0
            State.stuckCheckPosition = nil
        end
        target = State.currentSpirit
        isOrbTarget = false
    end

    if not target then return end
    local anchor = getAnchor(target)
    if not anchor then
        if isOrbTarget then State.currentOrb = nil else State.currentSpirit = nil end
        State.stuckCheckPosition = nil
        State.stuckTime = 0
        return
    end

    local fullDistance = (anchor.Position - root.Position).Magnitude
    local reachedDistance = isOrbTarget and CONFIG.OrbReached or CONFIG.SpiritReached

    if fullDistance <= reachedDistance then
        if isOrbTarget then
            State.visitedOrbs[target] = now
            State.currentOrb = nil
        else
            State.currentSpirit = nil
        end
        State.stuckCheckPosition = nil
        State.stuckTime = 0
        State.lastMoveOrder = 0
        return
    end

    local movePosition = anchor.Position
    if isOrbTarget then
        jumpTowardOrb(humanoid, root, anchor)
        movePosition = getOrbMovePosition(root, anchor)
    end

    if now - State.lastMoveOrder >= CONFIG.MoveOrderInterval then
        humanoid:MoveTo(movePosition)
        State.lastMoveOrder = now
    end

    checkMovementProgress(root, humanoid, target, anchor, isOrbTarget)
end

local farmToggle, orbToggle, spiritToggle, allInToggle, allInStatusParagraph
local syncingAutoToggles = false

local function syncAutoToggleUI(active)
    if syncingAutoToggles or State.unloaded then return end
    syncingAutoToggles = true

    pcall(function()
        if farmToggle then farmToggle:SetValue(active == "Farm") end
        if orbToggle then orbToggle:SetValue(active == "Orb") end
        if spiritToggle then spiritToggle:SetValue(active == "Spirit") end
        if allInToggle then allInToggle:SetValue(active == "AllIn") end
    end)

    syncingAutoToggles = false
end

local function refreshAllInTargets()
    ensureOrbsFolder()
    clearOrbCache()
    clearSpiritCache()
    resetMovement()
end

local function updateAllInStatusUI()
    if State.unloaded or not allInStatusParagraph then return end
    local energy = getEnergy()
    local elapsed = math.max(0, os.clock() - StateAllIn.timerStart)
    local remaining = math.max(0, math.ceil(CONFIG_ALLIN.SwitchInterval - elapsed))

    local text
    if not StateAllIn.autoAllInToggle then
        text = string.format(
            "Status: OFF | Energi: %d (Cari < %d, Farm >= %d)",
            energy,
            CONFIG_ALLIN.MinEnergyThreshold,
            CONFIG_ALLIN.TargetEnergy
        )
    elseif StateAllIn.mode == "FARMING" then
        text = string.format(
            "Mode: AUTO FARM | Energi: %d / %d (Cari lagi jika < %d)",
            energy,
            CONFIG_ALLIN.TargetEnergy,
            CONFIG_ALLIN.MinEnergyThreshold
        )
    elseif StateAllIn.mode == "SEARCHING" then
        text = string.format(
            "Mode: CARI %s | Energi: %d / %d | Refresh/Switch: %ds",
            StateAllIn.searchType,
            energy,
            CONFIG_ALLIN.TargetEnergy,
            remaining
        )
    else
        text = string.format("Mode: IDLE | Energi: %d", energy)
    end

    pcall(function()
        allInStatusParagraph:SetDesc(text)
    end)
end

local function updateAutoAllIn()
    if State.unloaded or not StateAllIn.autoAllInToggle then return end

    local currentEnergy = getEnergy()
    local now = os.clock()

    if StateAllIn.mode == "IDLE" or StateAllIn.mode == "FARMING" then
        if currentEnergy < CONFIG_ALLIN.MinEnergyThreshold then
            StateAllIn.mode = "SEARCHING"
            StateAllIn.searchType = "ORB"
            StateAllIn.timerStart = now

            State.autoOrb = true
            State.autoSpirit = false
            StateFarm.autoFarmToggle = false

            State.autoNoClip = true
            setNoClip(true)
            refreshAllInTargets()
            notify(
                "Auto All-In",
                string.format(
                    "Energi di bawah %d (%d). Mulai Cari Orb & Refresh tiap %ds.",
                    CONFIG_ALLIN.MinEnergyThreshold,
                    currentEnergy,
                    CONFIG_ALLIN.SwitchInterval
                )
            )
        else
            if StateAllIn.mode ~= "FARMING" then
                StateAllIn.mode = "FARMING"
                resetFarmState()
            end
            State.autoOrb = false
            State.autoSpirit = false
            StateFarm.autoFarmToggle = true
            State.autoNoClip = true
            setNoClip(true)
        end

    elseif StateAllIn.mode == "SEARCHING" then
        if currentEnergy >= CONFIG_ALLIN.TargetEnergy then
            StateAllIn.mode = "FARMING"
            State.autoOrb = false
            State.autoSpirit = false
            StateFarm.autoFarmToggle = true

            resetFarmState()
            State.autoNoClip = true
            setNoClip(true)
            resetMovement()
            notify(
                "Auto All-In",
                string.format("Target %d Energi tercapai! Kembali ke Auto Farm.", CONFIG_ALLIN.TargetEnergy)
            )
        elseif now - StateAllIn.timerStart >= CONFIG_ALLIN.SwitchInterval then
            StateAllIn.timerStart = now
            refreshAllInTargets()

            if StateAllIn.searchType == "ORB" then
                StateAllIn.searchType = "SPIRIT"
                State.autoOrb = false
                State.autoSpirit = true
                notify(
                    "Auto All-In",
                    string.format("Interval %ds: Refresh Orb & Spirit -> Beralih ke Cari Spirit.", CONFIG_ALLIN.SwitchInterval)
                )
            else
                StateAllIn.searchType = "ORB"
                State.autoOrb = true
                State.autoSpirit = false
                notify(
                    "Auto All-In",
                    string.format("Interval %ds: Refresh Orb & Spirit -> Beralih ke Cari Orb.", CONFIG_ALLIN.SwitchInterval)
                )
            end
        end
    end

    updateAllInStatusUI()
end

local function applyNoClipToCharacter()
    if State.unloaded or not State.noClip then return end
    local character = LocalPlayer.Character
    if not character then return end
    for _, part in ipairs(character:GetDescendants()) do
        if part:IsA("BasePart") then
            if State.originalCollisions[part] == nil then
                State.originalCollisions[part] = part.CanCollide
            end
            part.CanCollide = false
        end
    end
end

setNoClip = function(enabled)
    State.noClip = (enabled == true) and not State.unloaded
    if State.noClip then
        applyNoClipToCharacter()
    else
        for part, original in pairs(State.originalCollisions) do
            if part and part.Parent and part:IsA("BasePart") then
                part.CanCollide = original
            end
        end
        table.clear(State.originalCollisions)
    end
end

local function setFPSBoost(enabled)
    State.fpsBoost = enabled
    if enabled then
        if State.originalLighting.GlobalShadows == nil then
            State.originalLighting.GlobalShadows = Lighting.GlobalShadows
        end
        if State.originalLighting.FogEnd == nil then
            State.originalLighting.FogEnd = Lighting.FogEnd
        end
        Lighting.GlobalShadows = false
        Lighting.FogEnd = 100000
        pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
    else
        if State.originalLighting.GlobalShadows ~= nil then
            Lighting.GlobalShadows = State.originalLighting.GlobalShadows
        end
        if State.originalLighting.FogEnd ~= nil then
            Lighting.FogEnd = State.originalLighting.FogEnd
        end
    end
end

local function serverHop()
    notify("Server Hop", "Mencari server lain...")

    local servers = {}
    local success = pcall(function()
        local url = "https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100"
        servers = HttpService:JSONDecode(game:HttpGet(url))
    end)

    if success and servers and servers.data then
        local targetServer = nil
        local currentJobId = game.JobId
        for _, s in ipairs(servers.data) do
            if type(s) == "table" and s.playing and s.maxPlayers and s.playing < s.maxPlayers and s.id ~= currentJobId then
                targetServer = s.id
                break
            end
        end

        if targetServer then
            notify("Server Hop", "Berpindah ke server baru...")
            TeleportService:TeleportToPlaceInstance(game.PlaceId, targetServer, LocalPlayer)
        else
            notify("Server Hop", "Tidak ditemukan server lain, mencoba rejoin...")
            TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
        end
    else
        notify("Server Hop", "Gagal mengambil daftar server!")
    end
end

-- =========================================================
-- DIMENSIUI WINDOW & UI SETUP
-- =========================================================

local Window = DimensiUI:CreateWindow({
    Title = "SPIRITS HUNTER HUB",
    SubTitle = "Ultimate Edition | telatnakal",
    Theme = "Dimensi",
    Size = UDim2.fromOffset(500, 380),
    TabWidth = 150,
    Acrylic = false,
    MinimizeKey = Enum.KeyCode.RightControl,
})

local EspTab = Window:AddTab({ Title = "ESP", Icon = "eye" })
local MovementTab = Window:AddTab({ Title = "Movement", Icon = "move" })
local AutoFarmTab = Window:AddTab({ Title = "Auto Farm", Icon = "sprout" })
local SmartTab = Window:AddTab({ Title = "Misc", Icon = "brain" })
local SettingsTab = Window:AddTab({ Title = "Settings", Icon = "settings" })

Window:SelectTab(1)

-- ESP TAB
local PlayerESPSection = EspTab:AddSection("Player ESP")
PlayerESPSection:AddToggle("Toggle1", {
    Title = "Player ESP",
    Default = State.playerESP,
    Callback = function(value)
        State.playerESP = value
        if not value then
            for targetPlayer in pairs(PlayerCache) do destroyPlayerESP(targetPlayer) end
        else
            updatePlayerESP()
        end
    end,
})

local SpiritESPSection = EspTab:AddSection("Spirit ESP")
SpiritESPSection:AddToggle("Toggle2", {
    Title = "Spirit ESP",
    Default = State.spiritESP,
    Callback = function(value)
        State.spiritESP = value
        if not value then
            for object in pairs(SpiritCache) do destroySpiritESP(object) end
        else
            updateSpiritESP()
        end
    end,
})

SpiritESPSection:AddDropdown("Dropdown1", {
    Title = "Spirit Tier Filter",
    Values = { "MYTHIC", "EPIC", "RARE", "UNCOMMON", "COMMON" },
    Default = { "MYTHIC", "EPIC", "RARE" },
    Multi = true,
    AllowNone = true,
    Callback = function(values)
        table.clear(TierFilter)
        if type(values) == "table" then
            for key, value in pairs(values) do
                if type(key) == "number" and type(value) == "string" then
                    TierFilter[string.upper(value)] = true
                elseif value == true and type(key) == "string" then
                    TierFilter[string.upper(key)] = true
                end
            end
        elseif type(values) == "string" then
            TierFilter[string.upper(values)] = true
        end
        if State.currentSpirit and not isTierAllowed(State.currentSpirit) then
            State.currentSpirit = nil
            State.stuckTime = 0
        end
        updateSpiritESP()
    end,
})

-- AUTO FARM TAB
AutoFarmTab:AddSection("Pot Management")

farmToggle = AutoFarmTab:AddToggle("Toggle3", {
    Title = "Auto Farm Pots",
    Value = false,
    Callback = function(value)
        if syncingAutoToggles or State.unloaded then return end
        StateFarm.autoFarmToggle = value
        resetFarmState()

        if value then
            StateAllIn.autoAllInToggle = false
            StateAllIn.mode = "IDLE"
            State.autoSpirit = false
            State.autoOrb = false
            syncAutoToggleUI("Farm")
            State.autoNoClip = true
            setNoClip(true)
            resetMovement()
            updateAllInStatusUI()
            notify("Auto Farm", "Auto Farm Pots: ON")
        else
            State.autoNoClip = State.autoSpirit or State.autoOrb
            setNoClip(State.autoNoClip or State.manualNoClip)
            local humanoid = getHumanoid()
            local root = getRoot()
            if humanoid and root and not State.autoSpirit and not State.autoOrb then
                humanoid:MoveTo(root.Position)
            end
            updateAllInStatusUI()
            notify("Auto Farm", "Auto Farm Pots: OFF")
        end
    end,
})

local AutomationSection = AutoFarmTab:AddSection("Automation")
orbToggle = AutomationSection:AddToggle("Toggle4", {
    Title = "Auto Collect Orbs",
    Value = false,
    Callback = function(value)
        if syncingAutoToggles or State.unloaded then return end
        if value then
            StateAllIn.autoAllInToggle = false
            StateAllIn.mode = "IDLE"
            State.autoOrb = true
            State.autoSpirit = false
            StateFarm.autoFarmToggle = false
            syncAutoToggleUI("Orb")
            State.autoNoClip = true
            setNoClip(true)
            resetMovement()
            updateAllInStatusUI()
            notify("Orb", "Auto Collect Orbs Activated")
        else
            State.autoOrb = false
            State.autoNoClip = State.autoSpirit or StateFarm.autoFarmToggle
            setNoClip(State.autoNoClip or State.manualNoClip)
            if not State.autoSpirit and not StateFarm.autoFarmToggle then
                stopMovement()
            end
            updateAllInStatusUI()
            notify("Orb", "Auto Collect Orbs Stopped")
        end
    end,
})

spiritToggle = AutomationSection:AddToggle("Toggle5", {
    Title = "Auto Hunt Spirits",
    Value = false,
    Callback = function(value)
        if syncingAutoToggles or State.unloaded then return end
        if value then
            StateAllIn.autoAllInToggle = false
            StateAllIn.mode = "IDLE"
            State.autoSpirit = true
            State.autoOrb = false
            StateFarm.autoFarmToggle = false
            syncAutoToggleUI("Spirit")
            State.autoNoClip = true
            setNoClip(true)
            resetMovement()
            updateAllInStatusUI()
            notify("Spirit", "Auto Hunt Spirits Activated")
        else
            State.autoSpirit = false
            State.autoNoClip = State.autoOrb or StateFarm.autoFarmToggle
            setNoClip(State.autoNoClip or State.manualNoClip)
            if not State.autoOrb and not StateFarm.autoFarmToggle then
                stopMovement()
            end
            updateAllInStatusUI()
            notify("Spirit", "Auto Hunt Spirits Stopped")
        end
    end,
})

local AllInSection = AutoFarmTab:AddSection("Auto All-In System")
allInToggle = AllInSection:AddToggle("Toggle6", {
    Title = "Auto All-In (Energy Loop)",
    Value = false,
    Callback = function(value)
        if syncingAutoToggles or State.unloaded then return end
        StateAllIn.autoAllInToggle = value
        if value then
            StateAllIn.mode = "IDLE"
            StateAllIn.timerStart = os.clock()
            State.autoOrb = false
            State.autoSpirit = false
            StateFarm.autoFarmToggle = false
            syncAutoToggleUI("AllIn")
            updateAutoAllIn()
            notify("Auto All-In", "Fitur Auto All-In diaktifkan.")
        else
            StateAllIn.mode = "IDLE"
            State.autoOrb = false
            State.autoSpirit = false
            StateFarm.autoFarmToggle = false
            syncAutoToggleUI(nil)
            stopMovement()
            updateAllInStatusUI()
            notify("Auto All-In", "Fitur Auto All-In dimatikan.")
        end
    end,
})

allInStatusParagraph = AllInSection:AddParagraph("Paragraph1", {
    Title = "Auto All-In Status",
    Content = "Status: OFF",
})

-- MOVEMENT TAB
local CharacterSection = MovementTab:AddSection("Character")
CharacterSection:AddToggle("Toggle7", {
    Title = "Speed Boost (35)",
    Default = State.speedBoost,
    Callback = setSpeedBoost,
})
CharacterSection:AddToggle("Toggle8", {
    Title = "Noclip",
    Default = State.manualNoClip,
    Callback = function(value)
        State.manualNoClip = value
        setNoClip(value or State.autoNoClip)
    end,
})

-- MISC / SMART TAB
local ControlsSection = SmartTab:AddSection("Controls")
ControlsSection:AddButton("Button1", {
    Title = "Stop All",
    Icon = "square",
    Callback = function()
        stopMovement()
        syncAutoToggleUI(nil)
        updateAllInStatusUI()
    end,
})
ControlsSection:AddButton("Button2", {
    Title = "Reset Orb & Spirit Cache",
    Icon = "refresh-ccw",
    Callback = function()
        refreshAllInTargets()
        notify("Misc", "Orb & Spirit cache has been reset.")
    end,
})

-- SETTINGS TAB
local PerformanceSection = SettingsTab:AddSection("Performance")
PerformanceSection:AddToggle("Toggle9", {
    Title = "FPS Boost",
    Default = State.fpsBoost,
    Callback = setFPSBoost,
})
PerformanceSection:AddToggle("Toggle10", {
    Title = "Anti-AFK",
    Default = State.antiAFK,
    Callback = function(value)
        State.antiAFK = value
    end,
})

local SessionSection = SettingsTab:AddSection("Session")

SessionSection:AddButton("Button3", {
    Title = "Server Hop",
    Icon = "globe",
    Callback = function()
        serverHop()
    end,
})

SessionSection:AddButton("Button4", {
    Title = "Rejoin Server",
    Icon = "refresh-cw",
    Callback = function()
        TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
    end,
})

local function unloadHub()
    if State.unloaded then return end
    State.unloaded = true

    stopMovement()
    State.manualNoClip = false
    State.autoNoClip = false
    setNoClip(false)
    setSpeedBoost(false)
    setFPSBoost(false)
    State.antiAFK = false

    for _, conn in ipairs(Connections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(Connections)

    for targetPlayer in pairs(PlayerCache) do destroyPlayerESP(targetPlayer) end
    for object in pairs(SpiritCache) do destroySpiritESP(object) end

    if ESPFolder then
        pcall(function() ESPFolder:Destroy() end)
    end

    if Window then
        pcall(function() Window:Destroy() end)
    end
end

SessionSection:AddButton("Button5", {
    Title = "Unload Hub",
    Icon = "power",
    Callback = unloadHub,
})

-- =========================================================
-- LOOPS & EVENT CONNECTIONS
-- =========================================================

local espTimer = 0
local movementTimer = 0
local farmTimer = 0
local allInTimer = 0

trackConnection(RunService.Heartbeat:Connect(function(dt)
    if State.unloaded then return end

    if State.speedBoost then
        local humanoid = getHumanoid()
        if humanoid then
            watchSpeed(humanoid)
            enforceSpeed(humanoid)
        end
    end

    espTimer += dt
    movementTimer += dt
    farmTimer += dt
    allInTimer += dt

    if espTimer >= 0.2 then
        espTimer = 0
        updatePlayerESP()
        updateSpiritESP()
    end

    if movementTimer >= 0.05 then
        movementTimer = 0
        updateMovement()
    end

    if farmTimer >= 0.1 then
        farmTimer = 0
        if StateFarm.autoFarmToggle then
            updateAutoFarm()
        end
    end

    if allInTimer >= 1.0 then
        allInTimer = 0
        if StateAllIn.autoAllInToggle then
            updateAutoAllIn()
        else
            updateAllInStatusUI()
        end
    end
end))

trackConnection(RunService.Stepped:Connect(function()
    if State.unloaded then return end
    applyNoClipToCharacter()
end))

trackConnection(LocalPlayer.Idled:Connect(function()
    if State.unloaded or not State.antiAFK then return end
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new(0, 0))
    end)
end))

trackConnection(Players.PlayerRemoving:Connect(destroyPlayerESP))

local function bindPlayerCharacter(targetPlayer)
    trackConnection(targetPlayer.CharacterAdded:Connect(function()
        task.wait(0.5)
        if not State.unloaded then
            updatePlayerESP()
        end
    end))
end

trackConnection(Players.PlayerAdded:Connect(function(targetPlayer)
    bindPlayerCharacter(targetPlayer)
    updatePlayerESP()
end))

for _, targetPlayer in ipairs(Players:GetPlayers()) do
    if targetPlayer ~= LocalPlayer then
        bindPlayerCharacter(targetPlayer)
    end
end

trackConnection(Spirits.ChildRemoved:Connect(function(object)
    destroySpiritESP(object)
    if State.currentSpirit == object then
        State.currentSpirit = nil
    end
end))

trackConnection(Spirits.ChildAdded:Connect(function()
    if State.unloaded then return end
    if State.autoSpirit then
        State.currentSpirit = nil
    end
end))

local orbEventsConnectedFor
connectOrbEvents = function()
    local folder = ensureOrbsFolder()
    if not folder or orbEventsConnectedFor == folder then return end
    orbEventsConnectedFor = folder

    trackConnection(folder.ChildRemoved:Connect(function(object)
        State.visitedOrbs[object] = nil
        State.blockedOrbs[object] = nil
        if State.currentOrb == object then
            State.currentOrb = nil
        end
    end))

    trackConnection(folder.ChildAdded:Connect(function()
        if State.unloaded then return end
        if State.autoOrb and (not State.currentOrb or not State.currentOrb.Parent) then
            State.currentOrb = nil
        end
    end))
end

connectOrbEvents()

trackConnection(workspace.ChildAdded:Connect(function(child)
    if State.unloaded then return end
    if child.Name == "SparkOrbs" or child.Name == "Orbs" then
        Orbs = child
        orbEventsConnectedFor = nil
        connectOrbEvents()
    end
end))

trackConnection(LocalPlayer.CharacterAdded:Connect(function(character)
    if State.unloaded then return end
    watchSpeed(nil)
    resetFarmState()
    resetMovement()

    task.spawn(function()
        local humanoid = character:WaitForChild("Humanoid", 10)
        if State.unloaded then return end
        if humanoid and State.speedBoost then
            watchSpeed(humanoid)
            enforceSpeed(humanoid)
        end
        if State.noClip then
            table.clear(State.originalCollisions)
            applyNoClipToCharacter()
        end
        updatePlayerESP()
        updateSpiritESP()
    end)
end))

updatePlayerESP()
updateSpiritESP()
updateAllInStatusUI()

notify("SPIRITS HUNTER HUB", "Loaded successfully! Press RightControl to open/close UI.")
print("SPIRITS HUNTER HUB ULTIMATE PRO LOADED")
