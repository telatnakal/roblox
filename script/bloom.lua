local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local VirtualUser = game:GetService("VirtualUser")
local Lighting = game:GetService("Lighting")
local VirtualInputManager = game:GetService("VirtualInputManager")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local VERSION = "1.0.1"
local HUB_NAME = "DIMENSI-HUB | BLOOM"

local DIMENSIUI_URL = "https://raw.githubusercontent.com/telatnakal/DimensiUI/main/dist/main.lua"

local function patchDimensiUISource(source)
    if type(source) ~= "string" then return source end

    -- Use Right Control as the sole UI visibility hotkey.
    source = source:gsub("Enum%.KeyCode%.LeftControl", "Enum.KeyCode.RightControl")

    local patched, count = source:gsub(
        "local Box = Textbox%.Input",
        "local Box = Textbox.Input\n\tfunction Input:SetEnabled(Enabled)\n\t\tBox.TextEditable = Enabled == true\n\tend",
        1
    )
    if count == 0 then
        warn("[BLOOM] DimensiUI input-lock patch was not applied.")
    end

    local focusPatched, focusCount = patched:gsub(
        "if Input%.Finished then%s*AddSignal%(%s*Box%.FocusLost,%s*function%(enter%)%s*if not enter then%s*return%s*end%s*Input:SetValue%(Box%.Text%)%s*end%)",
        "if Input.Finished then\n\t\tAddSignal(Box.FocusLost, function()\n\t\t\tInput:SetValue(Box.Text)\n\t\tend)"
    )
    if focusCount == 0 then
        warn("[BLOOM] DimensiUI input-focus patch was not applied.")
    end

    return focusPatched
end

local function fetchDimensiUISource()
    local requestFunction
    if type(request) == "function" then
        requestFunction = request
    elseif type(http_request) == "function" then
        requestFunction = http_request
    elseif type(syn) == "table" and type(syn.request) == "function" then
        requestFunction = syn.request
    elseif type(http) == "table" and type(http.request) == "function" then
        requestFunction = http.request
    end

    if requestFunction then
        local ok, response = pcall(function()
            return requestFunction({
                Url = DIMENSIUI_URL,
                Method = "GET"
            })
        end)
        if ok and type(response) == "table" then
            local body = response.Body or response.body
            local status = tonumber(response.StatusCode or response.status_code)
            if type(body) == "string" and body ~= "" and (not status or status >= 200 and status < 300) then
                return patchDimensiUISource(body)
            end
        end
    end

    local ok, body = pcall(function()
        return game:HttpGet(DIMENSIUI_URL)
    end)
    if ok and type(body) == "string" and body ~= "" then
        return patchDimensiUISource(body)
    end

    error("[BLOOM] Could not download DimensiUI. Check your connection and that your executor supports HTTP requests.")
end

local cachedUISource -- downloaded once, reused when the UI is rebuilt (e.g. language switch)

local function loadDimensiUI()
    cachedUISource = cachedUISource or fetchDimensiUISource()
    local compiler = loadstring
    assert(type(compiler) == "function", "[BLOOM] This executor does not support loadstring.")
    local chunk, compileError = compiler(cachedUISource)
    assert(type(chunk) == "function", tostring(compileError or "[BLOOM] DimensiUI failed to compile."))
    return chunk()
end

local DimensiUI = loadDimensiUI()

-- ============================================================================
-- World references
-- ============================================================================

local Spirits = workspace:WaitForChild("Spirits", 30)
local Orbs = workspace:FindFirstChild("SparkOrbs") or workspace:FindFirstChild("Orbs")

if not Spirits then
    warn("[BLOOM] The Spirits folder was not found in Workspace. Make sure you are in the right game.")
    return
end

-- ============================================================================
-- Runtime configuration
-- ============================================================================

local CONFIG = {
    Speed = 35,
    NormalSpeed = 16,

    MoveInterval = 0.12,
    MoveOrderInterval = 0.15,
    TargetScanInterval = 0.35,

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
    MinEnergyThreshold = 100,
    TargetEnergy = 2000,
    SwitchInterval = 240,
}

local DURATIONS = {
    AutoFarmPots = 5,
    AutoCollectOrb = 5,
    AutoCollectSpirit = 5,
    AutoAllIn = 10,
}

-- ============================================================================
-- Automation session & state
-- ============================================================================

local AutomationSession = {
    Owner = nil,
    StartedAt = 0,
}

local function startAutomationSession(owner)
    AutomationSession.Owner = owner
    AutomationSession.StartedAt = os.clock()
end

local function clearAutomationSession(owner)
    if owner == nil or AutomationSession.Owner == owner then
        AutomationSession.Owner = nil
        AutomationSession.StartedAt = 0
    end
end

local State = {
    playerESP = false,
    spiritESP = false,

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
    characterGeneration = 0,

    visitedOrbs = {},
    blockedOrbs = {},
    visitedSpirits = {},
    blockedSpirits = {},
    zoneHistory = {},

    lastMove = 0,
    lastMoveOrder = 0,
    lastJump = 0,
    nextOrbScanAt = 0,
    nextSpiritScanAt = 0,

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
    mode = "IDLE",
    searchType = "ORB",
    timerStart = 0,
}

local resetFarmState
local resetMovement

local AutomationController = {
    Owner = nil,
    Generation = 0,
    Priority = {
        STOP_ALL = 100,
        ALL_IN = 90,
        FARM = 70,
        ORB = 50,
        SPIRIT = 40,
        IDLE = 0,
    },
}

function AutomationController:GetActiveOwner()
    local candidates = {}
    if StateAllIn.autoAllInToggle then table.insert(candidates, "ALL_IN") end
    if StateFarm.autoFarmToggle then table.insert(candidates, "FARM") end
    if State.autoOrb then table.insert(candidates, "ORB") end
    if State.autoSpirit then table.insert(candidates, "SPIRIT") end

    local owner, priority = nil, self.Priority.IDLE
    for _, candidate in ipairs(candidates) do
        local candidatePriority = self.Priority[candidate] or 0
        if candidatePriority > priority then
            owner, priority = candidate, candidatePriority
        end
    end
    return owner
end

function AutomationController:IsRunning(owner)
    return self:GetActiveOwner() == owner
end

function AutomationController:UpdateSession(owner)
    local active = owner or self:GetActiveOwner()
    if active then
        if AutomationSession.Owner ~= active then
            startAutomationSession(active)
        end
    else
        clearAutomationSession()
    end
    self.Owner = active
end

function AutomationController:SetOwner(owner, enabled)
    if owner ~= "FARM" and owner ~= "ORB" and owner ~= "SPIRIT" and owner ~= "ALL_IN" then
        return false
    end

    if enabled then
        StateFarm.autoFarmToggle = owner == "FARM"
        State.autoOrb = owner == "ORB"
        State.autoSpirit = owner == "SPIRIT"
        StateAllIn.autoAllInToggle = owner == "ALL_IN"
        if owner ~= "ALL_IN" then StateAllIn.mode = "IDLE" end
        self.Generation += 1
        self:UpdateSession(owner)
    else
        if owner == "FARM" then StateFarm.autoFarmToggle = false
        elseif owner == "ORB" then State.autoOrb = false
        elseif owner == "SPIRIT" then State.autoSpirit = false
        else
            StateAllIn.autoAllInToggle = false
            StateAllIn.mode = "IDLE"
            State.autoOrb = false
            State.autoSpirit = false
            StateFarm.autoFarmToggle = false
        end
        self.Generation += 1
        self:UpdateSession()
    end
    return true
end

function AutomationController:Switch(owner)
    return self:SetOwner(owner, true)
end

function AutomationController:StopAll()
    State.autoSpirit = false
    State.autoOrb = false
    StateFarm.autoFarmToggle = false
    StateAllIn.autoAllInToggle = false
    StateAllIn.mode = "IDLE"
    StateAllIn.searchType = "ORB"
    StateFarm.busy = false
    self.Generation += 1
    self:UpdateSession()
end

function AutomationController:HandleError(owner)
    if owner == "FARM" then
        self:SetOwner("FARM", false)
        StateFarm.busy = false
        resetFarmState()
    elseif owner == "ALL_IN" then
        self:SetOwner("ALL_IN", false)
        resetMovement()
    elseif owner == "MOVEMENT" then
        self:StopAll()
    else
        return false
    end
    return true
end

local PACE = {
    boost = CONFIG.Speed,
    normal = CONFIG.NormalSpeed,
}

-- ============================================================================
-- Core modules (events, errors, movement lock)
-- ============================================================================

local EventManager = { Connections = {} }
local Connections = EventManager.Connections
local ModuleManager = { Modules = {} }
local ErrorHandler = {}
local onModuleError
local logActivity
local MovementLock = { Owner = "IDLE", Generation = 0 }
local speedHooked
local speedConn

function ErrorHandler.Run(moduleName, callback, ...)
    if type(callback) ~= "function" then return false end
    local args = table.pack(...)
    local traceback = (debug and debug.traceback) or function(message)
        return tostring(message)
    end
    local results = table.pack(xpcall(function()
        return callback(table.unpack(args, 1, args.n))
    end, traceback))
    if not results[1] then
        logActivity("ERROR", "LogModuleError", tostring(moduleName), tostring(results[2]))
        warn("[BLOOM][" .. tostring(moduleName) .. "] " .. tostring(results[2]))
        if onModuleError then pcall(onModuleError, moduleName) end
        return false
    end
    return true, table.unpack(results, 2, results.n)
end

function ModuleManager:Register(name, module)
    if type(name) ~= "string" or type(module) ~= "table" then return false end
    self.Modules[name] = module
    return true
end

function ModuleManager:Get(name)
    return self.Modules[name]
end

function ModuleManager:InitAll()
    for _, name in ipairs({"AutomationController", "EventManager", "ErrorHandler", "MovementLock", "TargetManager", "Scheduler", "Watchdog"}) do
        local module = self.Modules[name]
        if module and type(module.Init) == "function" then
            local ok, err = pcall(module.Init, module)
            if not ok then warn("[BLOOM][INIT] " .. name .. ": " .. tostring(err)) end
        end
    end
end

function ModuleManager:DestroyAll(reason)
    for _, name in ipairs({"Watchdog", "Scheduler", "TargetManager", "MovementLock", "AutomationController", "EventManager"}) do
        local module = self.Modules[name]
        if module and type(module.Destroy) == "function" then
            pcall(module.Destroy, module, reason)
        end
    end
end

function MovementLock:Acquire(owner)
    owner = tostring(owner or "IDLE")
    if self.Owner ~= owner then
        self.Owner = owner
        self.Generation += 1
    end
    return true
end

function MovementLock:Allows(owner)
    return self.Owner == tostring(owner or "IDLE")
end

function MovementLock:Capture(owner)
    if not self:Allows(owner) then return nil end
    return self.Generation
end

function MovementLock:IsCurrent(owner, generation)
    return generation ~= nil and self:Allows(owner) and self.Generation == generation
end

function EventManager:Connect(signal, callback)
    if not signal or type(callback) ~= "function" then return nil end
    local connection = signal:Connect(callback)
    table.insert(self.Connections, connection)
    return connection
end

function EventManager:DisconnectAll()
    for _, connection in ipairs(self.Connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(self.Connections)
end

local function trackConnection(conn)
    if conn then
        table.insert(Connections, conn)
    end
    return conn
end

-- ============================================================================
-- Tier data, defaults, language & activity log
-- ============================================================================

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
    UNCOMMON = true,
    COMMON = true,
}

-- Defaults are cloned from the tables above so they can never drift apart.
local DEFAULT_SETTINGS = {
    Speed = CONFIG.Speed,
    NormalSpeed = CONFIG.NormalSpeed,
    PlayerESP = false,
    SpiritESP = false,
    SpeedBoost = false,
    ManualNoClip = false,
    FPSBoost = false,
    AntiAFK = false,
    TierFilter = table.clone(TierFilter),
    Durations = table.clone(DURATIONS),
    Movement = table.clone(CONFIG),
    Farm = table.clone(CONFIG_FARM),
    AllIn = table.clone(CONFIG_ALLIN),
}

local ConfigLanguage = "en"
local ActivityLog = {}
local ACTIVITY_LOG_LIMIT = 80

local T -- translation lookup, assigned after the text tables below

-- Wraps a translation key so it is resolved when the log is displayed,
-- which keeps old entries in sync with the current language.
local function L(key)
    return { key = key }
end

local ActivityCategoryKeys = {
    SYSTEM = "ActivitySystem",
    SETTING = "ActivitySetting",
    AUTOMATION = "ActivityAutomation",
    TARGET = "ActivityTarget",
    SCHEDULER = "ActivityScheduler",
    WATCHDOG = "ActivityWatchdog",
    CONTROL = "ActivityControl",
    RECOVERY = "ActivityRecovery",
    CONFIG = "ActivityConfig",
    ERROR = "ActivityError",
}

local function resolveLogArg(arg)
    if type(arg) == "table" and arg.key then return T(arg.key) end
    if type(arg) == "number" or type(arg) == "string" then return arg end
    return tostring(arg)
end

local function formatActivityMessage(entry)
    local template = T(entry.Key)
    local args = entry.Args
    if not args or args.n == 0 then return template end

    local resolved = {}
    for index = 1, args.n do
        resolved[index] = resolveLogArg(args[index])
    end
    local ok, text = pcall(string.format, template, table.unpack(resolved, 1, args.n))
    return ok and text or template
end

logActivity = function(category, key, ...)
    local entry = {
        Time = os.date("%H:%M:%S"),
        Category = tostring(category or "SYSTEM"),
        Key = key,
        Args = table.pack(...),
    }
    table.insert(ActivityLog, 1, entry)
    while #ActivityLog > ACTIVITY_LOG_LIMIT do
        table.remove(ActivityLog)
    end
    print(string.format("[BLOOM][%s][%s] %s", entry.Time, entry.Category, formatActivityMessage(entry)))
end

local function getActivityLogText(limit)
    local count = math.min(#ActivityLog, limit or 18)
    if count == 0 then return T("NoActivity") end

    local lines = {}
    for index = 1, count do
        local entry = ActivityLog[index]
        local categoryKey = ActivityCategoryKeys[entry.Category]
        lines[index] = string.format(
            "[%s] [%s] %s",
            entry.Time,
            categoryKey and T(categoryKey) or entry.Category,
            formatActivityMessage(entry)
        )
    end
    return table.concat(lines, "\n")
end

local function resetConfigData()
    PACE.boost = DEFAULT_SETTINGS.Speed
    PACE.normal = DEFAULT_SETTINGS.NormalSpeed

    State.playerESP = DEFAULT_SETTINGS.PlayerESP
    State.spiritESP = DEFAULT_SETTINGS.SpiritESP
    State.speedBoost = DEFAULT_SETTINGS.SpeedBoost
    State.manualNoClip = DEFAULT_SETTINGS.ManualNoClip
    State.fpsBoost = DEFAULT_SETTINGS.FPSBoost
    State.antiAFK = DEFAULT_SETTINGS.AntiAFK

    for key, value in pairs(DEFAULT_SETTINGS.Movement) do CONFIG[key] = value end
    for key, value in pairs(DEFAULT_SETTINGS.Farm) do CONFIG_FARM[key] = value end
    for key, value in pairs(DEFAULT_SETTINGS.AllIn) do CONFIG_ALLIN[key] = value end
    for key, value in pairs(DEFAULT_SETTINGS.Durations) do DURATIONS[key] = value end
    clearAutomationSession()

    table.clear(TierFilter)
    for key, value in pairs(DEFAULT_SETTINGS.TierFilter) do TierFilter[key] = value end

    State.autoOrb = false
    State.autoSpirit = false
    StateFarm.autoFarmToggle = false
    StateAllIn.autoAllInToggle = false
    StateAllIn.mode = "IDLE"
    StateAllIn.searchType = "ORB"
    State.manualNoClip = false
    State.autoNoClip = false
    State.noClip = false
    State.currentOrb = nil
    State.currentSpirit = nil
    table.clear(State.visitedOrbs)
    table.clear(State.blockedOrbs)
    table.clear(State.visitedSpirits)
    table.clear(State.blockedSpirits)
    table.clear(State.zoneHistory)
    State.nextOrbScanAt = 0
    State.nextSpiritScanAt = 0
    -- The interface language is intentionally kept when resetting.

    logActivity("CONFIG", "LogConfigReset")
end

-- ============================================================================
-- Persistent settings & translations
-- ============================================================================

local CONFIG_ROOT = "DimensiHUB"
local CONFIG_FOLDER = CONFIG_ROOT .. "/Bloom"
local CONFIG_FILE = CONFIG_FOLDER .. "/setting.json"
local ConfigReady = false
local ConfigLoaded = false
local ConfigSaveToken = 0
local ConfigDirty = false
local LastSavedConfig = nil
local TEXT = {
    en = {
        -- Tabs & page descriptions
        Home = "Home", Farming = "Automation", Visual = "Visual", Settings = "Settings", About = "About",
        PageHomeDesc = "Character status and recent activity",
        PageFarmingDesc = "Farming, orb collection and spirit hunting in one place",
        PageVisualDesc = "ESP overlays and spirit tier filters",
        PageSettingsDesc = "Character, performance and hub preferences",
        PageAboutDesc = "About this project",

        -- Home
        CharacterProfile = "Character Profile", PlayerLabel = "Player",
        SystemOverview = "Overview", SystemStatusLabel = "System Status", ScannerStatusLabel = "Target Scanner",
        SchedulerLabel = "Automation Monitor", ActivityLogLabel = "Recent Activity", NoActivity = "No activity yet.",
        LoadingCharacter = "Loading character...", Unavailable = "Unavailable", None = "None",
        OwnerLabel = "Active task", TargetRefreshLabel = "Next refresh", RecoveriesLabel = "Recoveries",
        EnergyLabel = "Energy", HealthLabel = "HP", PositionLabel = "Position",
        ScansLabel = "Scans", OrbLabel = "Orb", SpiritLabel = "Spirit", MemoryLabel = "Tracked",

        -- Automation
        PotManagement = "Pot Farming", AutoFarmLabel = "Auto Farm Pots",
        OrbSpiritSection = "Orbs & Spirits", AutoOrbLabel = "Auto Collect Orbs", AutoSpiritLabel = "Auto Hunt Spirits",
        AllInSection = "Auto All-In", AutoAllInLabel = "Auto All-In", AutoAllInStatus = "Status",
        DurationLabel = "Duration (minutes)", TimerLabel = "Timer", TimerReady = "Ready", TimerRemaining = "Remaining",
        StatusOff = "Off  |  Energy: %d  (searches below %d, farms from %d)",
        AllInFarmingStatus = "Farming  |  Energy: %d / %d  (searches again below %d)",
        AllInSearchingStatus = "Searching %s  |  Energy: %d / %d  |  Switches in %ds",
        AllInIdleStatus = "Idle  |  Energy: %d",

        -- Visual
        PlayerESPSection = "Player ESP", PlayerESPLabel = "Player ESP",
        SpiritESPSection = "Spirit ESP", SpiritESPLabel = "Spirit ESP", SpiritTierLabel = "Spirit Tier Filter",

        -- Settings
        CharacterSection = "Character", SpeedBoostLabel = "Speed Boost", NoclipLabel = "Noclip",
        PerformanceSection = "Performance", FPSBoostLabel = "FPS Boost", AntiAFKLabel = "Anti-AFK",
        SessionSection = "Session", ServerHopLabel = "Server Hop", RejoinLabel = "Rejoin Server",
        Preferences = "Preferences", Language = "Language", ResetConfigLabel = "Reset Settings",
        HubControlsLabel = "Hub Controls", StopAllLabel = "Stop All", UnloadLabel = "Unload Hub",

        -- About
        Version = "Version",
        AboutOverview = "Overview",
        AboutDescription = "BLOOM brings farming, orb collection and spirit hunting together in one clean interface.\n\nBuilt for clear controls, adjustable run times and an activity view that is easy to read.",
        AboutCapabilities = "Features",
        AboutCapabilitiesText = "• Automatic pot planting and harvesting\n• Orb collection and spirit hunting\n• Energy-aware Auto All-In\n• Player and spirit ESP with tier filters\n• Saved settings and an activity log",
        AboutCredits = "Project Info",
        AboutCreditsText = "Interface: DimensiUI Midnight\nProject: " .. HUB_NAME .. "\nVersion: " .. VERSION .. "\nAuthor: telatnakal",

        -- Notifications
        NotifyLoaded = "BLOOM is ready. Press Right Ctrl to show or hide the menu.",
        NotifyFarmOn = "Auto Farm Pots is on.", NotifyFarmOff = "Auto Farm Pots is off.",
        NotifyOrbOn = "Auto Collect Orbs is on.", NotifyOrbOff = "Auto Collect Orbs is off.",
        NotifySpiritOn = "Auto Hunt Spirits is on.", NotifySpiritOff = "Auto Hunt Spirits is off.",
        NotifyAllInOn = "Auto All-In is on.", NotifyAllInOff = "Auto All-In is off.",
        NotifyReset = "Settings restored to defaults.",
        NotifySearchingServers = "Looking for another server...",
        NotifySwitchingServer = "Joining a new server...",
        NotifyRejoining = "Rejoining this server...",
        NotifyServerFailed = "Couldn't load the server list. Please try again.",
        NotifyTeleportFailed = "Teleport failed to start. Please try again.",
        NotifyNoPublicServer = "No other public servers are available right now.",
        DurationInvalid = "Please enter a duration between 0.1 and 1440 minutes.",
        DurationCompleted = "Time's up. Automation has stopped.",
        AllInLowEnergy = "Energy is below %d (now %d). Searching for orbs and switching targets every %ds.",
        AllInReached = "Energy reached %d. Back to Auto Farm.",
        AllInSwitchSpirit = "Targets refreshed after %ds. Now searching for spirits.",
        AllInSwitchOrb = "Targets refreshed after %ds. Now searching for orbs.",
        AutoFarm = "Auto Farm", Orb = "Orb", Spirit = "Spirit", AutoAllIn = "Auto All-In",

        -- Task names
        Owner_IDLE = "Idle", Owner_FARM = "Auto Farm", Owner_ORB = "Auto Orb",
        Owner_SPIRIT = "Auto Spirit", Owner_ALL_IN = "Auto All-In",

        -- Reasons
        Reason_manual = "manual request", Reason_config_reset = "settings reset",
        Reason_movement_error = "movement error", Reason_unload = "hub unloaded",
        ReasonInterval = "60-second interval", ReasonScheduled = "scheduled",

        -- Activity categories
        ActivitySystem = "SYSTEM", ActivitySetting = "SETTING", ActivityAutomation = "AUTOMATION",
        ActivityTarget = "TARGET", ActivityScheduler = "SCHEDULER", ActivityWatchdog = "WATCHDOG",
        ActivityControl = "CONTROL", ActivityRecovery = "RECOVERY", ActivityConfig = "CONFIG",
        ActivityError = "ERROR",

        -- Activity messages
        LogHubReady = "Hub ready.",
        LogModuleError = "%s: %s",
        LogConfigReset = "Settings restored to defaults.",
        LogToggleOn = "%s enabled.", LogToggleOff = "%s disabled.",
        LogDurationSet = "%s duration set to %s minutes.",
        LogDurationCompleted = "%s duration finished.",
        LogLanguageChanged = "Language changed to %s.",
        LogOrbInvalid = "Orb target is no longer valid; looking for a new one.",
        LogSpiritInvalid = "Spirit target is no longer valid; looking for a new one.",
        LogTargetsRefreshed = "Orb and spirit targets refreshed (%s).",
        LogSchedulerChange = "%s -> %s",
        LogAllInSearching = "Energy is low; searching for orbs.",
        LogStopAll = "Stop All executed.", LogStopAllReason = "Stop All executed (%s).",
        LogCharacterReady = "Character ready; automation resumed.",
        LogWatchdogMissing = "Character unavailable for 20 seconds; automation stays paused.",
        LogWatchdogInvalid = "Invalid target cleared; the scanner will pick a new one.",
        LogWatchdogRecovery = "No movement progress; target released (recovery #%d).",
    },

    id = {
        -- Tab & deskripsi halaman
        Home = "Beranda", Farming = "Otomatisasi", Visual = "Visual", Settings = "Pengaturan", About = "Tentang",
        PageHomeDesc = "Status karakter dan aktivitas terbaru",
        PageFarmingDesc = "Farming, kumpulkan orb, dan buru spirit dalam satu tempat",
        PageVisualDesc = "Overlay ESP dan filter tier spirit",
        PageSettingsDesc = "Atur karakter, performa, dan preferensi hub",
        PageAboutDesc = "Tentang proyek ini",

        -- Beranda
        CharacterProfile = "Profil Karakter", PlayerLabel = "Pemain",
        SystemOverview = "Ringkasan", SystemStatusLabel = "Status Sistem", ScannerStatusLabel = "Pemindai Target",
        SchedulerLabel = "Monitor Otomatisasi", ActivityLogLabel = "Aktivitas Terbaru", NoActivity = "Belum ada aktivitas.",
        LoadingCharacter = "Memuat karakter...", Unavailable = "Tidak tersedia", None = "Tidak ada",
        OwnerLabel = "Tugas aktif", TargetRefreshLabel = "Refresh berikutnya", RecoveriesLabel = "Pemulihan",
        EnergyLabel = "Energi", HealthLabel = "HP", PositionLabel = "Posisi",
        ScansLabel = "Pemindaian", OrbLabel = "Orb", SpiritLabel = "Spirit", MemoryLabel = "Dilacak",

        -- Otomatisasi
        PotManagement = "Farming Pot", AutoFarmLabel = "Auto Farm Pot",
        OrbSpiritSection = "Orb & Spirit", AutoOrbLabel = "Auto Kumpulkan Orb", AutoSpiritLabel = "Auto Buru Spirit",
        AllInSection = "Auto All-In", AutoAllInLabel = "Auto All-In", AutoAllInStatus = "Status",
        DurationLabel = "Durasi (menit)", TimerLabel = "Timer", TimerReady = "Siap", TimerRemaining = "Sisa",
        StatusOff = "Nonaktif  |  Energi: %d  (cari di bawah %d, farm mulai %d)",
        AllInFarmingStatus = "Farming  |  Energi: %d / %d  (cari lagi jika di bawah %d)",
        AllInSearchingStatus = "Mencari %s  |  Energi: %d / %d  |  Ganti target dalam %d dtk",
        AllInIdleStatus = "Siaga  |  Energi: %d",

        -- Visual
        PlayerESPSection = "ESP Pemain", PlayerESPLabel = "ESP Pemain",
        SpiritESPSection = "ESP Spirit", SpiritESPLabel = "ESP Spirit", SpiritTierLabel = "Filter Tier Spirit",

        -- Pengaturan
        CharacterSection = "Karakter", SpeedBoostLabel = "Speed Boost", NoclipLabel = "Noclip",
        PerformanceSection = "Performa", FPSBoostLabel = "FPS Boost", AntiAFKLabel = "Anti-AFK",
        SessionSection = "Sesi", ServerHopLabel = "Server Hop", RejoinLabel = "Rejoin Server",
        Preferences = "Preferensi", Language = "Bahasa", ResetConfigLabel = "Reset Pengaturan",
        HubControlsLabel = "Kontrol Hub", StopAllLabel = "Hentikan Semua", UnloadLabel = "Tutup Hub",

        -- Tentang
        Version = "Versi",
        AboutOverview = "Ringkasan",
        AboutDescription = "BLOOM menyatukan farming, pengumpulan orb, dan perburuan spirit dalam satu antarmuka yang rapi.\n\nDibuat dengan kontrol yang jelas, durasi yang bisa diatur, dan tampilan aktivitas yang mudah dibaca.",
        AboutCapabilities = "Fitur Utama",
        AboutCapabilitiesText = "• Tanam dan panen pot otomatis\n• Kumpulkan orb dan buru spirit\n• Auto All-In yang menyesuaikan energi\n• ESP pemain dan spirit dengan filter tier\n• Pengaturan tersimpan dan log aktivitas",
        AboutCredits = "Info Proyek",
        AboutCreditsText = "Antarmuka: DimensiUI Midnight\nProyek: " .. HUB_NAME .. "\nVersi: " .. VERSION .. "\nPembuat: telatnakal",

        -- Notifikasi
        NotifyLoaded = "BLOOM siap dipakai. Tekan Right Ctrl untuk membuka atau menyembunyikan menu.",
        NotifyFarmOn = "Auto Farm Pot diaktifkan.", NotifyFarmOff = "Auto Farm Pot dimatikan.",
        NotifyOrbOn = "Auto Kumpulkan Orb diaktifkan.", NotifyOrbOff = "Auto Kumpulkan Orb dimatikan.",
        NotifySpiritOn = "Auto Buru Spirit diaktifkan.", NotifySpiritOff = "Auto Buru Spirit dimatikan.",
        NotifyAllInOn = "Auto All-In diaktifkan.", NotifyAllInOff = "Auto All-In dimatikan.",
        NotifyReset = "Pengaturan dikembalikan ke default.",
        NotifySearchingServers = "Mencari server lain...",
        NotifySwitchingServer = "Pindah ke server baru...",
        NotifyRejoining = "Masuk ulang ke server ini...",
        NotifyServerFailed = "Daftar server gagal dimuat. Silakan coba lagi.",
        NotifyTeleportFailed = "Teleport gagal dimulai. Silakan coba lagi.",
        NotifyNoPublicServer = "Belum ada server publik lain yang tersedia.",
        DurationInvalid = "Masukkan durasi antara 0.1 sampai 1440 menit.",
        DurationCompleted = "Waktu habis. Otomatisasi dihentikan.",
        AllInLowEnergy = "Energi di bawah %d (saat ini %d). Mencari orb dan ganti target tiap %d detik.",
        AllInReached = "Energi mencapai %d. Kembali ke Auto Farm.",
        AllInSwitchSpirit = "Target diperbarui setelah %d detik. Sekarang mencari spirit.",
        AllInSwitchOrb = "Target diperbarui setelah %d detik. Sekarang mencari orb.",
        AutoFarm = "Auto Farm", Orb = "Orb", Spirit = "Spirit", AutoAllIn = "Auto All-In",

        -- Nama tugas
        Owner_IDLE = "Siaga", Owner_FARM = "Auto Farm", Owner_ORB = "Auto Orb",
        Owner_SPIRIT = "Auto Spirit", Owner_ALL_IN = "Auto All-In",

        -- Alasan
        Reason_manual = "diminta manual", Reason_config_reset = "reset pengaturan",
        Reason_movement_error = "error pergerakan", Reason_unload = "hub ditutup",
        ReasonInterval = "interval 60 detik", ReasonScheduled = "terjadwal",

        -- Kategori aktivitas
        ActivitySystem = "SISTEM", ActivitySetting = "PENGATURAN", ActivityAutomation = "OTOMATISASI",
        ActivityTarget = "TARGET", ActivityScheduler = "PENJADWAL", ActivityWatchdog = "PEMANTAU",
        ActivityControl = "KONTROL", ActivityRecovery = "PEMULIHAN", ActivityConfig = "KONFIGURASI",
        ActivityError = "ERROR",

        -- Pesan aktivitas
        LogHubReady = "Hub siap digunakan.",
        LogModuleError = "%s: %s",
        LogConfigReset = "Pengaturan dikembalikan ke default.",
        LogToggleOn = "%s diaktifkan.", LogToggleOff = "%s dimatikan.",
        LogDurationSet = "Durasi %s diatur ke %s menit.",
        LogDurationCompleted = "Durasi %s selesai.",
        LogLanguageChanged = "Bahasa diubah ke %s.",
        LogOrbInvalid = "Target orb sudah tidak valid; mencari target baru.",
        LogSpiritInvalid = "Target spirit sudah tidak valid; mencari target baru.",
        LogTargetsRefreshed = "Target orb dan spirit diperbarui (%s).",
        LogSchedulerChange = "%s -> %s",
        LogAllInSearching = "Energi menipis; mulai mencari orb.",
        LogStopAll = "Hentikan Semua dijalankan.", LogStopAllReason = "Hentikan Semua dijalankan (%s).",
        LogCharacterReady = "Karakter siap; otomatisasi dilanjutkan.",
        LogWatchdogMissing = "Karakter tidak tersedia selama 20 detik; otomatisasi tetap dijeda.",
        LogWatchdogInvalid = "Target tidak valid dibersihkan; pemindai akan mencari yang baru.",
        LogWatchdogRecovery = "Tidak ada pergerakan; target dilepas (pemulihan #%d).",
    },
}

T = function(key)
    return (TEXT[ConfigLanguage] and TEXT[ConfigLanguage][key]) or TEXT.en[key] or key
end

local function getConfigSnapshot()
    return {
        Language = ConfigLanguage,
        Speed = PACE.boost,
        NormalSpeed = PACE.normal,
        PlayerESP = State.playerESP,
        SpiritESP = State.spiritESP,
        SpeedBoost = State.speedBoost,
        ManualNoClip = State.manualNoClip,
        FPSBoost = State.fpsBoost,
        AntiAFK = State.antiAFK,
        AutoFarm = StateFarm.autoFarmToggle,
        AutoOrb = State.autoOrb,
        AutoSpirit = State.autoSpirit,
        AutoAllIn = StateAllIn.autoAllInToggle,
        TierFilter = table.clone(TierFilter),
        Movement = table.clone(CONFIG),
        Farm = table.clone(CONFIG_FARM),
        AllIn = table.clone(CONFIG_ALLIN),
        Durations = table.clone(DURATIONS),
    }
end

local function applyConfigSnapshot(data)
    if type(data) ~= "table" then return false end
    if data.Language == "id" or data.Language == "en" then ConfigLanguage = data.Language end
    if type(data.Speed) == "number" then PACE.boost = math.clamp(data.Speed, 16, 200) end
    if type(data.NormalSpeed) == "number" then PACE.normal = math.clamp(data.NormalSpeed, 1, 100) end
    for key, field in pairs({PlayerESP="playerESP", SpiritESP="spiritESP", SpeedBoost="speedBoost", ManualNoClip="manualNoClip", FPSBoost="fpsBoost", AntiAFK="antiAFK"}) do
        if type(data[key]) == "boolean" then State[field] = data[key] end
    end
    StateFarm.autoFarmToggle = data.AutoFarm == true
    State.autoOrb = data.AutoOrb == true
    State.autoSpirit = data.AutoSpirit == true
    StateAllIn.autoAllInToggle = data.AutoAllIn == true
    if StateFarm.autoFarmToggle then State.autoOrb, State.autoSpirit, StateAllIn.autoAllInToggle = false, false, false end
    if State.autoOrb then State.autoSpirit, StateFarm.autoFarmToggle, StateAllIn.autoAllInToggle = false, false, false end
    if State.autoSpirit then State.autoOrb, StateFarm.autoFarmToggle, StateAllIn.autoAllInToggle = false, false, false end
    if StateAllIn.autoAllInToggle then State.autoOrb, State.autoSpirit, StateFarm.autoFarmToggle = false, false, false end
    for key, value in pairs(type(data.Movement) == "table" and data.Movement or {}) do
        if CONFIG[key] ~= nil and type(value) == "number" then CONFIG[key] = value end
    end
    for key, value in pairs(type(data.Farm) == "table" and data.Farm or {}) do
        if CONFIG_FARM[key] ~= nil and type(value) == "number" then CONFIG_FARM[key] = value end
    end
    for key, value in pairs(type(data.AllIn) == "table" and data.AllIn or {}) do
        if CONFIG_ALLIN[key] ~= nil and type(value) == "number" then CONFIG_ALLIN[key] = value end
    end
    for key, value in pairs(type(data.Durations) == "table" and data.Durations or {}) do
        if DURATIONS[key] ~= nil and type(value) == "number" and value >= 0.1 and value <= 1440 then
            DURATIONS[key] = value
        end
    end
    if type(data.TierFilter) == "table" then
        for key in pairs(TierFilter) do
            if type(data.TierFilter[key]) == "boolean" then TierFilter[key] = data.TierFilter[key] end
        end
    end
    return true
end

local function ensureConfigFolder()
    if type(makefolder) ~= "function" or type(isfolder) ~= "function" then
        warn("[BLOOM] makefolder/isfolder are unavailable; settings will not be saved.")
        return false
    end

    local rootOK = pcall(function()
        if not isfolder(CONFIG_ROOT) then
            makefolder(CONFIG_ROOT)
        end
    end)
    if not rootOK then
        warn("[BLOOM] Could not create folder: " .. CONFIG_ROOT)
        return false
    end

    local folderOK = pcall(function()
        if not isfolder(CONFIG_FOLDER) then
            makefolder(CONFIG_FOLDER)
        end
    end)
    if not folderOK then
        warn("[BLOOM] Could not create folder: " .. CONFIG_FOLDER)
        return false
    end

    local verified, exists = pcall(function()
        return isfolder(CONFIG_ROOT) and isfolder(CONFIG_FOLDER)
    end)
    if not verified or exists ~= true then
        warn("[BLOOM] The settings folder could not be verified.")
        return false
    end

    return true
end

local function loadConfig()
    if not ensureConfigFolder() then return false end
    if type(isfile) ~= "function" or type(readfile) ~= "function" then
        warn("[BLOOM] isfile/readfile are unavailable; saved settings cannot be loaded.")
        return false
    end

    local existsOK, exists = pcall(function()
        return isfile(CONFIG_FILE)
    end)
    if not existsOK then
        warn("[BLOOM] Could not check for the settings file.")
        return false
    end
    if not exists then
        return false
    end

    local ok, result = pcall(function()
        local decoded = HttpService:JSONDecode(readfile(CONFIG_FILE))
        return applyConfigSnapshot(decoded)
    end)
    if ok and result then
        ConfigLoaded = true
        LastSavedConfig = HttpService:JSONEncode(getConfigSnapshot())
        ConfigDirty = false
        return true
    end

    warn("[BLOOM] setting.json could not be read or contains invalid JSON; using default settings.")
    return false
end

local function saveConfig()
    if not ConfigReady or not ConfigDirty or type(writefile) ~= "function" then return false end
    if not ensureConfigFolder() then return false end
    local ok, encoded = pcall(function() return HttpService:JSONEncode(getConfigSnapshot()) end)
    if not ok then return false end
    if encoded == LastSavedConfig then
        ConfigDirty = false
        return true
    end
    local saved = pcall(function()
        writefile(CONFIG_FILE, encoded)
    end)
    if not saved then
        warn("[BLOOM] Could not write setting.json.")
        return false
    end

    local verified, exists = pcall(function()
        return isfile(CONFIG_FILE)
    end)
    if not verified or exists ~= true then
        warn("[BLOOM] setting.json could not be verified after saving.")
        return false
    end

    LastSavedConfig = encoded
    ConfigDirty = false
    return true
end

local function scheduleConfigSave()
    if not ConfigReady then return end
    ConfigDirty = true
    ConfigSaveToken += 1
    local token = ConfigSaveToken
    task.delay(1, function()
        if token == ConfigSaveToken and not State.unloaded then saveConfig() end
    end)
end

loadConfig()

-- ============================================================================
-- ESP, notifications & helpers
-- ============================================================================

local ESPFolder = Instance.new("Folder")
ESPFolder.Name = "SpiritsHunterESP"
ESPFolder.Parent = PlayerGui

local PlayerCache = {}
local SpiritCache = {}

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
                if not entry or not entry.gui or not entry.gui.Parent
                    or not entry.label or not entry.label.Parent then
                    destroyPlayerESP(targetPlayer)
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
    if State.unloaded then return end
    if not Spirits or not Spirits.Parent then
        for object in pairs(SpiritCache) do
            destroySpiritESP(object)
        end
        return
    end

    local seen = {}
    for _, object in ipairs(Spirits:GetChildren()) do
        seen[object] = true
        local anchor
        pcall(function()
            anchor = getAnchor(object)
        end)

        if anchor and anchor.Parent and (anchor == object or anchor:IsDescendantOf(object)) then
            local tier = getTier(object)
            local allowed = State.spiritESP and TierFilter[tier] == true

            if allowed then
                local entry = SpiritCache[object]
                if not entry or not entry.gui or not entry.gui.Parent then
                    destroySpiritESP(object)
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
        else
            destroySpiritESP(object)
        end
    end

    for object in pairs(SpiritCache) do
        if not seen[object] or object.Parent ~= Spirits then
            destroySpiritESP(object)
        end
    end
end

-- ============================================================================
-- Auto Farm
-- ============================================================================

resetFarmState = function()
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
    if not MovementLock:Allows("FARM")
        and not (MovementLock:Allows("ALL_IN") and StateAllIn.mode == "FARMING") then return end

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
    local farmOwner = MovementLock.Owner
    local farmGeneration = MovementLock:Capture(farmOwner)

    task.spawn(function()
        local actionOK, actionError = pcall(function()
            local function canContinue()
                return not State.unloaded
                    and MovementLock:IsCurrent(farmOwner, farmGeneration)
                    and (farmOwner == "ALL_IN" and StateAllIn.mode == "FARMING" or StateFarm.autoFarmToggle)
            end
            if not canContinue() then return end

            if status == "EMPTY" then
                local planted = false
                for attempt = 1, CONFIG_FARM.PlantRetries + 1 do
                    pressKeyF()
                    task.wait(CONFIG_FARM.PlantRetryDelay)
                    if not canContinue() then return end

                    if getSeedForBed(plot, pot.BedNumber) then
                        planted = true
                        break
                    end

                    if attempt <= CONFIG_FARM.PlantRetries then
                        task.wait(0.15)
                        if not canContinue() then return end
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
                if not canContinue() then return end
                holdKeyE(prompt)
                if not canContinue() then return end
                StateFarm.currentBedNumber = advanceFarmBed(pots, pot.BedNumber)
                StateFarm.nextActionAllowedTime = os.clock() + CONFIG_FARM.PotDelay
            end
        end)

        if not actionOK then
            warn("[BLOOM][Auto Farm] Bed " .. tostring(pot.BedNumber) .. " error: " .. tostring(actionError))
            StateFarm.currentBedNumber = pot.BedNumber
            StateFarm.nextActionAllowedTime = os.clock() + CONFIG_FARM.PlantRetryDelay
        end

        StateFarm.busy = false
    end)
end

-- ============================================================================
-- Targets & movement (orbs / spirits)
-- ============================================================================

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
    State.nextOrbScanAt = 0
end

local function clearSpiritCache()
    State.currentSpirit = nil
    State.nextSpiritScanAt = 0
    table.clear(State.visitedSpirits)
    table.clear(State.blockedSpirits)
end

local function getNearestSpirit()
    local root = getRoot()
    if not root or not Spirits or not Spirits.Parent then return nil end

    local now = os.clock()
    local nearest, shortest = nil, math.huge

    for object, visitedAt in pairs(State.visitedSpirits) do
        if not object or not object.Parent or now - visitedAt >= CONFIG.OrbCooldown then
            State.visitedSpirits[object] = nil
        end
    end

    for object, blockedUntil in pairs(State.blockedSpirits) do
        if not object or not object.Parent or now >= blockedUntil then
            State.blockedSpirits[object] = nil
        end
    end

    for _, object in ipairs(Spirits:GetChildren()) do
        local anchor = getAnchor(object)
        local visitedAt = State.visitedSpirits[object]
        local blockedUntil = State.blockedSpirits[object]

        if anchor and isTierAllowed(object)
            and not visitedAt
            and not blockedUntil then
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

resetMovement = function()
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
    scheduleConfigSave()
    logActivity("SETTING", value and "LogToggleOn" or "LogToggleOff", L("SpeedBoostLabel"))
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
                State.blockedSpirits[target] = now + CONFIG.OrbBlockedTime
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

local TargetManager

local function updateMovement()
    if State.unloaded then return end
    local movementOwner = MovementLock.Owner
    if movementOwner ~= "ORB" and movementOwner ~= "SPIRIT" and movementOwner ~= "ALL_IN" then return end
    if movementOwner == "ALL_IN" and StateAllIn.mode ~= "SEARCHING" then return end
    if not MovementLock:Allows(movementOwner) then return end
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
        if State.currentOrb and not State.currentOrb.Parent then
            State.currentOrb = nil
        end
        if not State.currentOrb and now >= State.nextOrbScanAt then
            State.nextOrbScanAt = now + CONFIG.TargetScanInterval
            State.currentOrb = TargetManager and TargetManager:Acquire("ORB") or nil
            State.stuckTime = 0
            State.stuckCheckPosition = nil
        end
        target = State.currentOrb
        if target then TargetManager:Remember(target, "ORB") end
        isOrbTarget = true
    elseif State.autoSpirit and not State.autoOrb then
        if State.currentSpirit and (
            not State.currentSpirit.Parent or not isTierAllowed(State.currentSpirit)
        ) then
            State.currentSpirit = nil
        end
        if not State.currentSpirit and now >= State.nextSpiritScanAt then
            State.nextSpiritScanAt = now + CONFIG.TargetScanInterval
            State.currentSpirit = TargetManager and TargetManager:Acquire("SPIRIT") or nil
            State.stuckTime = 0
            State.stuckCheckPosition = nil
        end
        target = State.currentSpirit
        if target then TargetManager:Remember(target, "SPIRIT") end
        isOrbTarget = false
    end

    if not target then return end
    local anchor = getAnchor(target)
    if not anchor then
        if isOrbTarget then
            State.currentOrb = nil
            State.nextOrbScanAt = now + CONFIG.TargetScanInterval
        else
            State.currentSpirit = nil
            State.nextSpiritScanAt = now + CONFIG.TargetScanInterval
        end
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
            State.visitedSpirits[target] = now
            State.currentSpirit = nil
            State.nextSpiritScanAt = now + CONFIG.TargetScanInterval
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

-- ============================================================================
-- UI references & helpers
-- ============================================================================

local farmToggle, orbToggle, spiritToggle, allInToggle, allInStatusParagraph
local farmDurationInput, orbDurationInput, spiritDurationInput, allInDurationInput
local farmTimerParagraph, orbTimerParagraph, spiritTimerParagraph, allInTimerParagraph
local updateDurationTimerUI
local durationInputSyncing = false
local refreshDurationInputLocks
local schedulerStatusParagraph, activityLogParagraph
local homeProfileParagraph, homeStatusParagraph, targetStatusParagraph
local playerESPToggle, spiritESPToggle
local setFPSBoost, updateAllInStatusUI
local antiAFKToggle, manualNoClipToggle, speedBoostToggle, fpsBoostToggle
local syncingAutoToggles = false
local syncingSettingToggles = false
local syncSettingToggleUI
local Window
local buildUI
local setLanguage
local unloadHub

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

local function setDurationInput(inputObject, value)
    if not inputObject then return end
    durationInputSyncing = true
    pcall(function() inputObject:SetValue(tostring(value)) end)
    durationInputSyncing = false
end

refreshDurationInputLocks = function()
    local owner = AutomationSession.Owner
    pcall(function() if farmDurationInput then farmDurationInput:SetEnabled(owner ~= "FARM") end end)
    pcall(function() if orbDurationInput then orbDurationInput:SetEnabled(owner ~= "ORB") end end)
    pcall(function() if spiritDurationInput then spiritDurationInput:SetEnabled(owner ~= "SPIRIT") end end)
    pcall(function() if allInDurationInput then allInDurationInput:SetEnabled(owner ~= "ALL_IN") end end)
end

local DURATION_LABELS = {
    AutoFarmPots = "AutoFarmLabel",
    AutoCollectOrb = "AutoOrbLabel",
    AutoCollectSpirit = "AutoSpiritLabel",
    AutoAllIn = "AutoAllInLabel",
}

local function updateDuration(key, value, inputObject)
    if durationInputSyncing then return end
    local numeric = tonumber(value)
    local previous = DURATIONS[key]
    local ownerMap = {
        AutoFarmPots = "FARM",
        AutoCollectOrb = "ORB",
        AutoCollectSpirit = "SPIRIT",
        AutoAllIn = "ALL_IN",
    }
    local owner = ownerMap[key]
    if AutomationSession.Owner == owner then
        setDurationInput(inputObject, previous)
        return
    end
    if not numeric or numeric < 0.1 or numeric > 1440 then
        setDurationInput(inputObject, previous)
        notify(T("Settings"), T("DurationInvalid"))
        return
    end
    DURATIONS[key] = math.floor(numeric * 100) / 100
    setDurationInput(inputObject, DURATIONS[key])
    updateDurationTimerUI()
    scheduleConfigSave()
    logActivity("SETTING", "LogDurationSet", L(DURATION_LABELS[key]), DURATIONS[key])
end

local function checkAutomationDuration()
    local owner = AutomationSession.Owner
    if not owner or AutomationSession.StartedAt <= 0 then return end
    local durationKey = ({FARM="AutoFarmPots", ORB="AutoCollectOrb", SPIRIT="AutoCollectSpirit", ALL_IN="AutoAllIn"})[owner]
    local duration = durationKey and DURATIONS[durationKey]
    if not duration then return end
    if os.clock() - AutomationSession.StartedAt < duration * 60 then return end

    clearAutomationSession(owner)
    logActivity("AUTOMATION", "LogDurationCompleted", L("Owner_" .. owner))
    notify(T("Farming"), T("DurationCompleted"))
    if owner == "FARM" and farmToggle then
        farmToggle:SetValue(false)
    elseif owner == "ORB" and orbToggle then
        orbToggle:SetValue(false)
    elseif owner == "SPIRIT" and spiritToggle then
        spiritToggle:SetValue(false)
    elseif owner == "ALL_IN" and allInToggle then
        allInToggle:SetValue(false)
    end
end

local function formatCountdown(seconds)
    seconds = math.max(0, math.ceil(seconds))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    if hours > 0 then
        return string.format("%02d:%02d:%02d", hours, minutes, secs)
    end
    return string.format("%02d:%02d", minutes, secs)
end

updateDurationTimerUI = function()
    if State.unloaded then return end
    local activeOwner = AutomationSession.Owner
    local entries = {
        {owner = "FARM", key = "AutoFarmPots", paragraph = farmTimerParagraph},
        {owner = "ORB", key = "AutoCollectOrb", paragraph = orbTimerParagraph},
        {owner = "SPIRIT", key = "AutoCollectSpirit", paragraph = spiritTimerParagraph},
        {owner = "ALL_IN", key = "AutoAllIn", paragraph = allInTimerParagraph},
    }
    for _, entry in ipairs(entries) do
        if entry.paragraph then
            local remaining
            local status
            if activeOwner == entry.owner and AutomationSession.StartedAt > 0 then
                remaining = DURATIONS[entry.key] * 60 - (os.clock() - AutomationSession.StartedAt)
                status = T("TimerRemaining")
            else
                remaining = DURATIONS[entry.key] * 60
                status = T("TimerReady")
            end
            pcall(function()
                entry.paragraph:SetDesc(status .. "  |  " .. formatCountdown(remaining))
            end)
        end
    end
end

local function refreshAllInTargets()
    ensureOrbsFolder()
    clearOrbCache()
    clearSpiritCache()
    resetMovement()
    if TargetManager then
        TargetManager.LastRefresh = os.clock()
    end
end

-- ============================================================================
-- Target manager, scheduler & watchdog
-- ============================================================================

TargetManager = {
    RefreshInterval = 60,
    ValidationInterval = 0.5,
    LastRefresh = 0,
    LastValidation = 0,
    Memory = setmetatable({}, { __mode = "k" }),
    ScanCount = 0,
}

function TargetManager:Acquire(targetType)
    local target
    if targetType == "ORB" then
        target = getNextOrb()
    elseif targetType == "SPIRIT" then
        target = getNearestSpirit()
    end
    if target and self:IsValid(target, targetType) then
        self:Remember(target, targetType)
        return target
    end
    return nil
end

function TargetManager:Remember(target, targetType)
    if not target then return end
    self.Memory[target] = {
        Type = targetType,
        LastSeen = os.clock(),
        LastPosition = (getAnchor(target) and getAnchor(target).Position) or nil,
    }
end

function TargetManager:IsValid(target, targetType)
    if not target or not target.Parent then return false end
    local anchor = getAnchor(target)
    if not anchor or not anchor.Parent then return false end
    if targetType == "SPIRIT" and not isTierAllowed(target) then return false end
    if targetType == "ORB" then
        local folder = ensureOrbsFolder()
        if not folder or not target:IsDescendantOf(folder) then return false end
    elseif targetType == "SPIRIT" then
        if not Spirits or not Spirits.Parent or not target:IsDescendantOf(Spirits) then return false end
    end
    return true
end

function TargetManager:Validate()
    if State.autoOrb and State.currentOrb and not self:IsValid(State.currentOrb, "ORB") then
        self.Memory[State.currentOrb] = nil
        State.currentOrb = nil
        State.stuckTime = 0
        State.stuckCheckPosition = nil
        logActivity("TARGET", "LogOrbInvalid")
    end

    if State.autoSpirit and State.currentSpirit and not self:IsValid(State.currentSpirit, "SPIRIT") then
        self.Memory[State.currentSpirit] = nil
        State.currentSpirit = nil
        State.stuckTime = 0
        State.stuckCheckPosition = nil
        logActivity("TARGET", "LogSpiritInvalid")
    end
end

function TargetManager:Refresh(reason)
    refreshAllInTargets()
    for target, entry in pairs(self.Memory) do
        local targetType = entry and entry.Type
        if not self:IsValid(target, targetType) then
            self.Memory[target] = nil
        end
    end
    self.LastRefresh = os.clock()
    self.ScanCount += 1
    logActivity("TARGET", "LogTargetsRefreshed", L(reason or "ReasonScheduled"))
end

function TargetManager:Step()
    if State.unloaded then return end
    local now = os.clock()

    if now - self.LastValidation >= self.ValidationInterval then
        self.LastValidation = now
        self:Validate()
    end

    local searching = State.autoOrb or State.autoSpirit
        or (StateAllIn.autoAllInToggle and StateAllIn.mode == "SEARCHING")

    if searching and now - self.LastRefresh >= self.RefreshInterval then
        self:Refresh("ReasonInterval")
    end
end

local Scheduler = {
    Current = "IDLE",
    LastChange = 0,
    Priority = AutomationController.Priority,
}

function Scheduler:Resolve()
    local owner = AutomationController:GetActiveOwner()
    if owner and (self.Priority[owner] or 0) > self.Priority.IDLE then
        return owner
    end
    return "IDLE"
end

function Scheduler:Step()
    if State.unloaded then return end
    local requested = self:Resolve()

    if requested ~= self.Current then
        local previous = self.Current
        self.Current = requested
        self.LastChange = os.clock()
        logActivity("SCHEDULER", "LogSchedulerChange", L("Owner_" .. previous), L("Owner_" .. requested))
    end
    MovementLock:Acquire(requested)
    AutomationController.Owner = requested ~= "IDLE" and requested or nil

    if requested == "ALL_IN" then
        if StateAllIn.mode == "FARMING" then
            State.autoOrb = false
            State.autoSpirit = false
            StateFarm.autoFarmToggle = true
        elseif StateAllIn.mode == "SEARCHING" then
            StateFarm.autoFarmToggle = false
            if StateAllIn.searchType == "ORB" then
                State.autoOrb = true
                State.autoSpirit = false
            else
                State.autoOrb = false
                State.autoSpirit = true
            end
        end
    elseif requested == "FARM" then
        State.autoOrb = false
        State.autoSpirit = false
        StateAllIn.autoAllInToggle = false
        StateAllIn.mode = "IDLE"
    elseif requested == "ORB" then
        State.autoSpirit = false
        StateFarm.autoFarmToggle = false
        StateAllIn.autoAllInToggle = false
        StateAllIn.mode = "IDLE"
    elseif requested == "SPIRIT" then
        State.autoOrb = false
        StateFarm.autoFarmToggle = false
        StateAllIn.autoAllInToggle = false
        StateAllIn.mode = "IDLE"
    end
end

local Watchdog = {
    Interval = 2,
    LastCheck = 0,
    MissingCharacterSince = nil,
    LastProgressAt = os.clock(),
    LastPosition = nil,
    RecoveryCount = 0,
}

function Watchdog:Step()
    if State.unloaded then return end
    local now = os.clock()
    if now - self.LastCheck < self.Interval then return end
    self.LastCheck = now

    local active = Scheduler.Current ~= "IDLE"
    if not active then
        self.MissingCharacterSince = nil
        self.LastPosition = nil
        self.LastProgressAt = now
        return
    end

    local root = getRoot()
    local humanoid = getHumanoid()
    if not root or not humanoid or humanoid.Health <= 0 then
        self.MissingCharacterSince = self.MissingCharacterSince or now
        if now - self.MissingCharacterSince >= 20 then
            logActivity("WATCHDOG", "LogWatchdogMissing")
            self.MissingCharacterSince = now
        end
        return
    end
    self.MissingCharacterSince = nil

    if not self.LastPosition then
        self.LastPosition = root.Position
        self.LastProgressAt = now
        return
    end

    local moved = (root.Position - self.LastPosition).Magnitude
    if moved >= CONFIG.StuckMinMovement then
        self.LastProgressAt = now
    end
    self.LastPosition = root.Position

    local searching = State.autoOrb or State.autoSpirit
    if searching and (State.currentOrb or State.currentSpirit) then
        local target = State.currentOrb or State.currentSpirit
        local targetType = State.currentOrb and "ORB" or "SPIRIT"
        if not TargetManager:IsValid(target, targetType) then
            if targetType == "ORB" then State.currentOrb = nil else State.currentSpirit = nil end
            self.LastProgressAt = now
            logActivity("WATCHDOG", "LogWatchdogInvalid")
            return
        end

        if now - self.LastProgressAt >= 18 then
            if targetType == "ORB" then
                State.blockedOrbs[target] = now + CONFIG.OrbBlockedTime
                State.currentOrb = nil
            else
                State.blockedSpirits[target] = now + CONFIG.OrbBlockedTime
                State.currentSpirit = nil
            end
            resetMovement()
            self.LastProgressAt = now
            self.RecoveryCount += 1
            logActivity("WATCHDOG", "LogWatchdogRecovery", self.RecoveryCount)
        end
    end
end

ModuleManager:Register("AutomationController", AutomationController)
ModuleManager:Register("EventManager", EventManager)
ModuleManager:Register("ErrorHandler", ErrorHandler)
ModuleManager:Register("MovementLock", MovementLock)
ModuleManager:Register("TargetManager", TargetManager)
ModuleManager:Register("Scheduler", Scheduler)
ModuleManager:Register("Watchdog", Watchdog)

function AutomationController:Init()
    self.Owner = self:GetActiveOwner()
end

function AutomationController:Destroy()
    self:StopAll()
end

function EventManager:Init() end
function EventManager:Destroy()
    self:DisconnectAll()
end

function MovementLock:Init()
    self:Acquire("IDLE")
end

function MovementLock:Destroy()
    self:Acquire("IDLE")
end

function TargetManager:Init()
    self.LastRefresh = os.clock()
    self.LastValidation = 0
end

function TargetManager:Destroy()
    table.clear(self.Memory)
end

function Scheduler:Init()
    self.Current = "IDLE"
    self.LastChange = os.clock()
end

function Scheduler:Destroy()
    self.Current = "IDLE"
end

function Watchdog:Init()
    self.LastCheck = 0
    self.LastProgressAt = os.clock()
end

function Watchdog:Destroy()
    self.MissingCharacterSince = nil
    self.LastPosition = nil
end

ModuleManager:InitAll()

local function countTrackedTargets()
    local count = 0
    for _ in pairs(TargetManager.Memory) do count += 1 end
    return count
end

local function updateMonitorUI()
    if State.unloaded then return end

    if schedulerStatusParagraph then
        local refreshIn = math.max(0, math.ceil(TargetManager.RefreshInterval - (os.clock() - TargetManager.LastRefresh)))
        pcall(function()
            schedulerStatusParagraph:SetDesc(string.format(
                "%s: %s  |  %s: %ds  |  %s: %d",
                T("OwnerLabel"), T("Owner_" .. Scheduler.Current),
                T("TargetRefreshLabel"), refreshIn,
                T("RecoveriesLabel"), Watchdog.RecoveryCount
            ))
        end)
    end

    if activityLogParagraph then
        pcall(function()
            activityLogParagraph:SetDesc(getActivityLogText(18))
        end)
    end

    local humanoid = getHumanoid()
    local root = getRoot()
    local health = humanoid and math.floor(humanoid.Health) or 0
    local maxHealth = humanoid and math.floor(humanoid.MaxHealth) or 0
    local position = root
        and string.format("%.1f, %.1f, %.1f", root.Position.X, root.Position.Y, root.Position.Z)
        or T("Unavailable")

    if homeProfileParagraph then
        pcall(function()
            homeProfileParagraph:SetDesc(string.format(
                "%s  |  %s: %d/%d  |  %s: %s",
                LocalPlayer.Name,
                T("HealthLabel"), health, maxHealth,
                T("PositionLabel"), position
            ))
        end)
    end

    if homeStatusParagraph then
        pcall(function()
            homeStatusParagraph:SetDesc(string.format(
                "%s: %s  |  %s: %s  |  %s: %d",
                T("OwnerLabel"), T("Owner_" .. Scheduler.Current),
                T("EnergyLabel"), tostring(getEnergy()),
                T("RecoveriesLabel"), Watchdog.RecoveryCount
            ))
        end)
    end

    if targetStatusParagraph then
        local orbName = State.currentOrb and State.currentOrb.Name or T("None")
        local spiritName = State.currentSpirit and State.currentSpirit.Name or T("None")
        pcall(function()
            targetStatusParagraph:SetDesc(string.format(
                "%s: %d  |  %s: %s  |  %s: %s  |  %s: %d",
                T("ScansLabel"), TargetManager.ScanCount,
                T("OrbLabel"), orbName,
                T("SpiritLabel"), spiritName,
                T("MemoryLabel"), countTrackedTargets()
            ))
        end)
    end
end

local function stopAllAutomation(reason)
    if State.unloaded and reason ~= "unload" then return end

    AutomationController:StopAll()
    if refreshDurationInputLocks then refreshDurationInputLocks() end
    if updateDurationTimerUI then updateDurationTimerUI() end
    State.autoNoClip = false
    State.manualNoClip = false
    State.antiAFK = false

    setSpeedBoost(false)
    setFPSBoost(false)
    if setNoClip then setNoClip(false) end
    resetMovement()
    resetFarmState()

    local humanoid = getHumanoid()
    local root = getRoot()
    if humanoid and root then
        pcall(function() humanoid:MoveTo(root.Position) end)
    end

    Scheduler.Current = "IDLE"
    Scheduler.LastChange = os.clock()
    MovementLock:Acquire("IDLE")
    syncAutoToggleUI(nil)

    if antiAFKToggle then pcall(function() antiAFKToggle:SetValue(false) end) end
    if manualNoClipToggle then pcall(function() manualNoClipToggle:SetValue(false) end) end
    if speedBoostToggle then pcall(function() speedBoostToggle:SetValue(false) end) end
    if fpsBoostToggle then pcall(function() fpsBoostToggle:SetValue(false) end) end
    syncSettingToggleUI()
    scheduleConfigSave()

    if reason then
        logActivity("CONTROL", "LogStopAllReason", L("Reason_" .. reason))
    else
        logActivity("CONTROL", "LogStopAll")
    end
    updateAllInStatusUI()
    updateMonitorUI()
end

updateAllInStatusUI = function()
    if State.unloaded or not allInStatusParagraph then return end
    local energy = getEnergy()
    local elapsed = math.max(0, os.clock() - StateAllIn.timerStart)
    local remaining = math.max(0, math.ceil(CONFIG_ALLIN.SwitchInterval - elapsed))

    local text
    if not StateAllIn.autoAllInToggle then
        text = string.format(
            T("StatusOff"),
            energy,
            CONFIG_ALLIN.MinEnergyThreshold,
            CONFIG_ALLIN.TargetEnergy
        )
    elseif StateAllIn.mode == "FARMING" then
        text = string.format(
            T("AllInFarmingStatus"),
            energy,
            CONFIG_ALLIN.TargetEnergy,
            CONFIG_ALLIN.MinEnergyThreshold
        )
    elseif StateAllIn.mode == "SEARCHING" then
        text = string.format(
            T("AllInSearchingStatus"),
            StateAllIn.searchType == "ORB" and T("Orb") or T("Spirit"),
            energy,
            CONFIG_ALLIN.TargetEnergy,
            remaining
        )
    else
        text = string.format(T("AllInIdleStatus"), energy)
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
            logActivity("AUTOMATION", "LogAllInSearching")
            StateFarm.autoFarmToggle = false

            State.autoNoClip = true
            setNoClip(true)
            refreshAllInTargets()
            notify(
                T("AutoAllIn"),
                string.format(
                    T("AllInLowEnergy"),
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
                T("AutoAllIn"),
                string.format(T("AllInReached"), CONFIG_ALLIN.TargetEnergy)
            )
        elseif now - StateAllIn.timerStart >= CONFIG_ALLIN.SwitchInterval then
            StateAllIn.timerStart = now
            refreshAllInTargets()

            if StateAllIn.searchType == "ORB" then
                StateAllIn.searchType = "SPIRIT"
                State.autoOrb = false
                State.autoSpirit = true
                notify(
                T("AutoAllIn"),
                    string.format(T("AllInSwitchSpirit"), CONFIG_ALLIN.SwitchInterval)
                )
            else
                StateAllIn.searchType = "ORB"
                State.autoOrb = true
                State.autoSpirit = false
                notify(
                T("AutoAllIn"),
                    string.format(T("AllInSwitchOrb"), CONFIG_ALLIN.SwitchInterval)
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

setFPSBoost = function(enabled)
    State.fpsBoost = enabled
    scheduleConfigSave()
    logActivity("SETTING", enabled and "LogToggleOn" or "LogToggleOff", L("FPSBoostLabel"))
    if enabled then
        if State.originalLighting.GlobalShadows == nil then
            State.originalLighting.GlobalShadows = Lighting.GlobalShadows
        end
        if State.originalLighting.FogEnd == nil then
            State.originalLighting.FogEnd = Lighting.FogEnd
        end
        if State.originalLighting.QualityLevel == nil then
            pcall(function()
                State.originalLighting.QualityLevel = settings().Rendering.QualityLevel
            end)
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
        if State.originalLighting.QualityLevel ~= nil then
            pcall(function()
                settings().Rendering.QualityLevel = State.originalLighting.QualityLevel
            end)
        end
    end
end

local function serverHop()
    notify(T("ServerHopLabel"), T("NotifySearchingServers"))

    local currentJobId = game.JobId
    local targetServer = nil
    local cursor = nil
    local requestOK = true
    local pagesChecked = 0

    repeat
        pagesChecked += 1
        local page
        local url = "https://games.roblox.com/v1/games/" .. game.PlaceId
            .. "/servers/Public?sortOrder=Asc&limit=100"
        if cursor and cursor ~= "" then
            url ..= "&cursor=" .. HttpService:UrlEncode(cursor)
        end

        local ok, result = pcall(function()
            return HttpService:JSONDecode(game:HttpGet(url))
        end)
        if not ok or type(result) ~= "table" or type(result.data) ~= "table" then
            requestOK = false
            break
        end
        page = result

        for _, server in ipairs(page.data) do
            if type(server) == "table"
                and type(server.id) == "string"
                and server.id ~= currentJobId
                and type(server.playing) == "number"
                and type(server.maxPlayers) == "number"
                and server.playing < server.maxPlayers then
                targetServer = server.id
                break
            end
        end

        cursor = page.nextPageCursor
    until targetServer or not cursor or cursor == "" or pagesChecked >= 5

    if not requestOK then
        notify(T("ServerHopLabel"), T("NotifyServerFailed"))
        return
    end

    if targetServer then
        notify(T("ServerHopLabel"), T("NotifySwitchingServer"))
        local ok, err = pcall(function()
            TeleportService:TeleportToPlaceInstance(game.PlaceId, targetServer, LocalPlayer)
        end)
        if not ok then
            warn("[BLOOM][SERVER HOP] " .. tostring(err))
            notify(T("ServerHopLabel"), T("NotifyTeleportFailed"))
        end
    else
        notify(T("ServerHopLabel"), T("NotifyNoPublicServer"))
    end
end

local function selectedTiers()
    local values = {}
    for _, tier in ipairs({"MYTHIC", "EPIC", "RARE", "UNCOMMON", "COMMON"}) do
        if TierFilter[tier] then table.insert(values, tier) end
    end
    return values
end

syncSettingToggleUI = function()
    syncingSettingToggles = true
    pcall(function() if playerESPToggle then playerESPToggle:SetValue(State.playerESP) end end)
    pcall(function() if spiritESPToggle then spiritESPToggle:SetValue(State.spiritESP) end end)
    pcall(function() if speedBoostToggle then speedBoostToggle:SetValue(State.speedBoost) end end)
    pcall(function() if manualNoClipToggle then manualNoClipToggle:SetValue(State.manualNoClip) end end)
    pcall(function() if fpsBoostToggle then fpsBoostToggle:SetValue(State.fpsBoost) end end)
    pcall(function() if antiAFKToggle then antiAFKToggle:SetValue(State.antiAFK) end end)
    syncingSettingToggles = false
end

-- ============================================================================
-- User interface
-- ============================================================================

buildUI = function()
    syncingAutoToggles = true
    syncingSettingToggles = true

    if Window then
        pcall(function() DimensiUI:Destroy() end)
        DimensiUI = loadDimensiUI()
    end

    Window = DimensiUI:CreateWindow({
        Title = "BLOOM",
        SubTitle = T("Version") .. " " .. VERSION,
        Theme = "Dimensi",
    })

    local HomeTab = Window:AddTab({
        Title = T("Home"), Icon = "home", Description = T("PageHomeDesc"),
    })
    local FarmingTab = Window:AddTab({
        Title = T("Farming"), Icon = "sprout", Description = T("PageFarmingDesc"),
    })
    local VisualTab = Window:AddTab({
        Title = T("Visual"), Icon = "eye", Description = T("PageVisualDesc"),
    })
    local SettingsTab = Window:AddTab({
        Title = T("Settings"), Icon = "settings-2", Description = T("PageSettingsDesc"),
    })
    local AboutTab = Window:AddTab({
        Title = T("About"), Icon = "info", Description = T("PageAboutDesc"),
    })

    local CharacterSection = HomeTab:AddSection(T("CharacterProfile"))
    homeProfileParagraph = CharacterSection:AddParagraph({
        Title = T("PlayerLabel"),
        Content = LocalPlayer.Name .. " | " .. T("LoadingCharacter"),
    })
    local OverviewSection = HomeTab:AddSection(T("SystemOverview"))
    homeStatusParagraph = OverviewSection:AddParagraph({
        Title = T("SystemStatusLabel"),
        Content = T("OwnerLabel") .. ": " .. T("Owner_IDLE") .. "  |  " .. T("EnergyLabel") .. ": 0",
    })
    targetStatusParagraph = OverviewSection:AddParagraph({
        Title = T("ScannerStatusLabel"),
        Content = T("ScansLabel") .. ": 0 | " .. T("OrbLabel") .. ": " .. T("None") .. " | " .. T("SpiritLabel") .. ": " .. T("None"),
    })
    local MonitorSection = HomeTab:AddSection(T("SchedulerLabel"))
    schedulerStatusParagraph = MonitorSection:AddParagraph({
        Title = T("SchedulerLabel"), Content = T("OwnerLabel") .. ": " .. T("Owner_IDLE"),
    })
    activityLogParagraph = MonitorSection:AddParagraph({
        Title = T("ActivityLogLabel"), Content = T("NoActivity"),
    })

    local FarmSection = FarmingTab:AddSection(T("PotManagement"))
    farmToggle = FarmSection:AddToggle("AutoFarm", {
        Title = T("AutoFarmLabel"), Default = StateFarm.autoFarmToggle,
        Callback = function(value)
            if syncingAutoToggles or State.unloaded then return end
            AutomationController:SetOwner("FARM", value)
            refreshDurationInputLocks()
            updateDurationTimerUI()
            scheduleConfigSave()
            resetFarmState()
            logActivity("AUTOMATION", value and "LogToggleOn" or "LogToggleOff", L("AutoFarmLabel"))
            if value then
                StateAllIn.autoAllInToggle = false
                StateAllIn.mode = "IDLE"
                State.autoSpirit, State.autoOrb = false, false
                syncAutoToggleUI("Farm")
                State.autoNoClip = true
                setNoClip(true)
                resetMovement()
                updateAllInStatusUI()
                notify(T("AutoFarm"), T("NotifyFarmOn"))
            else
                State.autoNoClip = State.autoSpirit or State.autoOrb
                setNoClip(State.autoNoClip or State.manualNoClip)
                local humanoid, root = getHumanoid(), getRoot()
                if humanoid and root and not State.autoSpirit and not State.autoOrb then humanoid:MoveTo(root.Position) end
                updateAllInStatusUI()
                notify(T("AutoFarm"), T("NotifyFarmOff"))
            end
        end,
    })
    farmDurationInput = FarmSection:AddInput("AutoFarmDuration", {
        Title = T("DurationLabel"), Default = tostring(DURATIONS.AutoFarmPots),
        Placeholder = "5", Numeric = true, Finished = true, MaxLength = 7,
        Callback = function(value) updateDuration("AutoFarmPots", value, farmDurationInput) end,
    })
    farmTimerParagraph = FarmSection:AddParagraph({
        Title = T("TimerLabel"),
        Content = (T("TimerReady")) .. "  |  " .. formatCountdown(DURATIONS.AutoFarmPots * 60),
    })

    local OrbSpiritSection = FarmingTab:AddSection(T("OrbSpiritSection"))
    orbToggle = OrbSpiritSection:AddToggle("AutoOrb", {
        Title = T("AutoOrbLabel"), Default = State.autoOrb,
        Callback = function(value)
            if syncingAutoToggles or State.unloaded then return end
            AutomationController:SetOwner("ORB", value)
            logActivity("AUTOMATION", value and "LogToggleOn" or "LogToggleOff", L("AutoOrbLabel"))
            refreshDurationInputLocks()
            updateDurationTimerUI()
            scheduleConfigSave()
            if value then
                StateAllIn.autoAllInToggle = false
                StateAllIn.mode = "IDLE"
                State.autoSpirit = false
                StateFarm.autoFarmToggle = false
                syncAutoToggleUI("Orb")
                State.autoNoClip = true
                setNoClip(true)
                resetMovement()
                updateAllInStatusUI()
                notify(T("Orb"), T("NotifyOrbOn"))
            else
                State.autoNoClip = State.autoSpirit or StateFarm.autoFarmToggle
                setNoClip(State.autoNoClip or State.manualNoClip)
                if not State.autoSpirit and not StateFarm.autoFarmToggle then stopMovement() end
                updateAllInStatusUI()
                notify(T("Orb"), T("NotifyOrbOff"))
            end
        end,
    })
    orbDurationInput = OrbSpiritSection:AddInput("AutoOrbDuration", {
        Title = T("DurationLabel"), Default = tostring(DURATIONS.AutoCollectOrb),
        Placeholder = "5", Numeric = true, Finished = true, MaxLength = 7,
        Callback = function(value) updateDuration("AutoCollectOrb", value, orbDurationInput) end,
    })
    orbTimerParagraph = OrbSpiritSection:AddParagraph({
        Title = T("TimerLabel"),
        Content = (T("TimerReady")) .. "  |  " .. formatCountdown(DURATIONS.AutoCollectOrb * 60),
    })
    spiritToggle = OrbSpiritSection:AddToggle("AutoSpirit", {
        Title = T("AutoSpiritLabel"), Default = State.autoSpirit,
        Callback = function(value)
            if syncingAutoToggles or State.unloaded then return end
            AutomationController:SetOwner("SPIRIT", value)
            logActivity("AUTOMATION", value and "LogToggleOn" or "LogToggleOff", L("AutoSpiritLabel"))
            refreshDurationInputLocks()
            updateDurationTimerUI()
            scheduleConfigSave()
            if value then
                StateAllIn.autoAllInToggle = false
                StateAllIn.mode = "IDLE"
                State.autoOrb = false
                StateFarm.autoFarmToggle = false
                syncAutoToggleUI("Spirit")
                State.autoNoClip = true
                setNoClip(true)
                resetMovement()
                updateAllInStatusUI()
                notify(T("Spirit"), T("NotifySpiritOn"))
            else
                State.autoNoClip = State.autoOrb or StateFarm.autoFarmToggle
                setNoClip(State.autoNoClip or State.manualNoClip)
                if not State.autoOrb and not StateFarm.autoFarmToggle then stopMovement() end
                updateAllInStatusUI()
                notify(T("Spirit"), T("NotifySpiritOff"))
            end
        end,
    })
    spiritDurationInput = OrbSpiritSection:AddInput("AutoSpiritDuration", {
        Title = T("DurationLabel"), Default = tostring(DURATIONS.AutoCollectSpirit),
        Placeholder = "5", Numeric = true, Finished = true, MaxLength = 7,
        Callback = function(value) updateDuration("AutoCollectSpirit", value, spiritDurationInput) end,
    })
    spiritTimerParagraph = OrbSpiritSection:AddParagraph({
        Title = T("TimerLabel"),
        Content = (T("TimerReady")) .. "  |  " .. formatCountdown(DURATIONS.AutoCollectSpirit * 60),
    })
    local AllInSection = FarmingTab:AddSection(T("AllInSection"))
    allInToggle = AllInSection:AddToggle("AutoAllIn", {
        Title = T("AutoAllInLabel"), Default = StateAllIn.autoAllInToggle,
        Callback = function(value)
            if syncingAutoToggles or State.unloaded then return end
            AutomationController:SetOwner("ALL_IN", value)
            refreshDurationInputLocks()
            updateDurationTimerUI()
            scheduleConfigSave()
            logActivity("AUTOMATION", value and "LogToggleOn" or "LogToggleOff", L("AutoAllInLabel"))
            if value then
                StateAllIn.mode = "IDLE"
                StateAllIn.timerStart = os.clock()
                State.autoOrb, State.autoSpirit, StateFarm.autoFarmToggle = false, false, false
                syncAutoToggleUI("AllIn")
                ErrorHandler.Run("AutoAllIn", updateAutoAllIn)
                notify(T("AutoAllIn"), T("NotifyAllInOn"))
            else
                StateAllIn.mode = "IDLE"
                State.autoOrb, State.autoSpirit, StateFarm.autoFarmToggle = false, false, false
                syncAutoToggleUI(nil)
                stopMovement()
                updateAllInStatusUI()
                notify(T("AutoAllIn"), T("NotifyAllInOff"))
            end
        end,
    })
    allInDurationInput = AllInSection:AddInput("AutoAllInDuration", {
        Title = T("DurationLabel"), Default = tostring(DURATIONS.AutoAllIn),
        Placeholder = "10", Numeric = true, Finished = true, MaxLength = 7,
        Callback = function(value) updateDuration("AutoAllIn", value, allInDurationInput) end,
    })
    allInTimerParagraph = AllInSection:AddParagraph({
        Title = T("TimerLabel"),
        Content = (T("TimerReady")) .. "  |  " .. formatCountdown(DURATIONS.AutoAllIn * 60),
    })
    allInStatusParagraph = AllInSection:AddParagraph({
        Title = T("AutoAllInStatus"), Content = T("StatusOff"):format(getEnergy(), CONFIG_ALLIN.MinEnergyThreshold, CONFIG_ALLIN.TargetEnergy),
    })

    local PlayerESPSection = VisualTab:AddSection(T("PlayerESPSection"))
    playerESPToggle = PlayerESPSection:AddToggle("PlayerESP", {
        Title = T("PlayerESPLabel"), Default = State.playerESP,
        Callback = function(value)
            if syncingSettingToggles or State.unloaded then return end
            State.playerESP = value
            scheduleConfigSave()
            if not value then
                for targetPlayer in pairs(PlayerCache) do destroyPlayerESP(targetPlayer) end
            else
                updatePlayerESP()
            end
        end,
    })
    local SpiritESPSection = VisualTab:AddSection(T("SpiritESPSection"))
    spiritESPToggle = SpiritESPSection:AddToggle("SpiritESP", {
        Title = T("SpiritESPLabel"), Default = State.spiritESP,
        Callback = function(value)
            if syncingSettingToggles or State.unloaded then return end
            State.spiritESP = value
            scheduleConfigSave()
            if not value then
                for object in pairs(SpiritCache) do destroySpiritESP(object) end
            else
                updateSpiritESP()
            end
        end,
    })
    SpiritESPSection:AddDropdown("SpiritTierFilter", {
        Title = T("SpiritTierLabel"),
        Values = { "MYTHIC", "EPIC", "RARE", "UNCOMMON", "COMMON" },
        Default = selectedTiers(), Multi = true, AllowNull = false,
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
            scheduleConfigSave()
        end,
    })

    local CharacterSettings = SettingsTab:AddSection(T("CharacterSection"))
    speedBoostToggle = CharacterSettings:AddToggle("SpeedBoost", {
        Title = T("SpeedBoostLabel") .. " (" .. PACE.boost .. ")", Default = State.speedBoost,
        Callback = function(value) if not syncingSettingToggles then setSpeedBoost(value) end end,
    })
    manualNoClipToggle = CharacterSettings:AddToggle("ManualNoClip", {
        Title = T("NoclipLabel"), Default = State.manualNoClip,
        Callback = function(value)
            if syncingSettingToggles then return end
            State.manualNoClip = value
            scheduleConfigSave()
            logActivity("SETTING", value and "LogToggleOn" or "LogToggleOff", L("NoclipLabel"))
            setNoClip(value or State.autoNoClip)
        end,
    })
    local PerformanceSection = SettingsTab:AddSection(T("PerformanceSection"))
    fpsBoostToggle = PerformanceSection:AddToggle("FPSBoost", {
        Title = T("FPSBoostLabel"), Default = State.fpsBoost,
        Callback = function(value) if not syncingSettingToggles then setFPSBoost(value) end end,
    })
    antiAFKToggle = PerformanceSection:AddToggle("AntiAFK", {
        Title = T("AntiAFKLabel"), Default = State.antiAFK,
        Callback = function(value)
            if syncingSettingToggles then return end
            State.antiAFK = value
            scheduleConfigSave()
            logActivity("SETTING", value and "LogToggleOn" or "LogToggleOff", L("AntiAFKLabel"))
        end,
    })
    local SessionSection = SettingsTab:AddSection(T("SessionSection"))
    SessionSection:AddButton({ Title = T("ServerHopLabel"), Description = "", Callback = serverHop })
    SessionSection:AddButton({
        Title = T("RejoinLabel"), Description = "",
        Callback = function()
            notify(T("RejoinLabel"), T("NotifyRejoining"))
            local ok, err = pcall(function()
                TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
            end)
            if not ok then
                warn("[BLOOM][REJOIN] " .. tostring(err))
                notify(T("RejoinLabel"), T("NotifyTeleportFailed"))
            end
        end,
    })
    local ConfigurationSection = SettingsTab:AddSection(T("Preferences"))
    ConfigurationSection:AddDropdown("Language", {
        Title = T("Language"), Values = { "EN", "ID" },
        Default = string.upper(ConfigLanguage), AllowNull = false,
        Callback = function(value) if setLanguage then setLanguage(value) end end,
    })
    ConfigurationSection:AddButton({
        Title = T("ResetConfigLabel"), Description = "",
        Callback = function()
            stopAllAutomation("config_reset")
            resetConfigData()
            setSpeedBoost(false)
            setFPSBoost(false)
            setNoClip(false)
            State.manualNoClip = false
            State.antiAFK = false
            State.playerESP = false
            State.spiritESP = false
            State.autoNoClip = false
            for targetPlayer in pairs(PlayerCache) do destroyPlayerESP(targetPlayer) end
            for object in pairs(SpiritCache) do destroySpiritESP(object) end
            resetMovement()
            resetFarmState()
            if TargetManager then
                table.clear(TargetManager.Memory)
                TargetManager.LastRefresh = 0
            end
            syncAutoToggleUI(nil)
            syncSettingToggleUI()
            updatePlayerESP()
            updateSpiritESP()
            updateMonitorUI()
            ConfigDirty = true
            saveConfig()
            notify(T("Settings"), T("NotifyReset"))
            task.defer(buildUI)
        end,
    })
    local HubControlsSection = SettingsTab:AddSection(T("HubControlsLabel"))
    HubControlsSection:AddButton({
        Title = T("StopAllLabel"), Description = "",
        Callback = function() stopAllAutomation("manual") end,
    })
    HubControlsSection:AddButton({
        Title = T("UnloadLabel"), Description = "",
        Callback = function() if unloadHub then unloadHub() end end,
    })

    local AboutOverviewSection = AboutTab:AddSection(T("AboutOverview"))
    AboutOverviewSection:AddParagraph({
        Title = HUB_NAME,
        Content = T("AboutDescription"),
    })
    local AboutCapabilitiesSection = AboutTab:AddSection(T("AboutCapabilities"))
    AboutCapabilitiesSection:AddParagraph({
        Title = T("AboutCapabilities"),
        Content = T("AboutCapabilitiesText"),
    })
    local AboutCreditsSection = AboutTab:AddSection(T("AboutCredits"))
    AboutCreditsSection:AddParagraph({
        Title = T("AboutCredits"),
        Content = T("AboutCreditsText"),
    })

    refreshDurationInputLocks()
    updateDurationTimerUI()
    Window:SelectTab(1)
    syncingAutoToggles = false
    syncingSettingToggles = false
end

onModuleError = function(moduleName)
    if moduleName == "Movement" then
        AutomationController:HandleError("MOVEMENT")
        stopAllAutomation("movement_error")
        return
    elseif moduleName == "AutoFarm" then
        AutomationController:HandleError("FARM")
    elseif moduleName == "AutoAllIn" then
        AutomationController:HandleError("ALL_IN")
    else
        return
    end

    if refreshDurationInputLocks then refreshDurationInputLocks() end
    if updateDurationTimerUI then updateDurationTimerUI() end
    State.autoNoClip = State.autoOrb or State.autoSpirit or StateFarm.autoFarmToggle
    setNoClip(State.autoNoClip or State.manualNoClip)
    syncAutoToggleUI(StateAllIn.autoAllInToggle and "AllIn" or StateFarm.autoFarmToggle and "Farm" or State.autoOrb and "Orb" or State.autoSpirit and "Spirit" or nil)
    scheduleConfigSave()
    updateAllInStatusUI()
    updateMonitorUI()
end

setLanguage = function(value)
    local language = string.lower(tostring(value or "en"))
    if language ~= "id" then language = "en" end
    if ConfigLanguage == language then return end
    ConfigLanguage = language
    scheduleConfigSave()
    logActivity("SETTING", "LogLanguageChanged", string.upper(language))
    task.defer(function()
        buildUI()
        updateDurationTimerUI()
        updateMonitorUI()
    end)
end

buildUI()
ConfigReady = true

if not ConfigLoaded then
    ConfigDirty = true
    saveConfig()
end

if ConfigLoaded then
    task.defer(function()
        if State.unloaded then return end
        if State.speedBoost then setSpeedBoost(true) end
        if State.fpsBoost then setFPSBoost(true) end
        if State.manualNoClip then setNoClip(true) end
        if State.playerESP then updatePlayerESP() end
        if State.spiritESP then updateSpiritESP() end
        if StateFarm.autoFarmToggle or State.autoOrb or State.autoSpirit then
            AutomationController:UpdateSession()
            refreshDurationInputLocks()
            State.autoNoClip = true
            setNoClip(true)
            resetFarmState()
            resetMovement()
        elseif StateAllIn.autoAllInToggle then
            AutomationController:UpdateSession("ALL_IN")
            refreshDurationInputLocks()
            StateAllIn.mode = "IDLE"
            StateAllIn.timerStart = os.clock()
            ErrorHandler.Run("AutoAllIn", updateAutoAllIn)
        end
        syncAutoToggleUI(StateAllIn.autoAllInToggle and "AllIn" or StateFarm.autoFarmToggle and "Farm" or State.autoOrb and "Orb" or State.autoSpirit and "Spirit" or nil)
    end)
end

unloadHub = function()
    if State.unloaded then return end
    stopAllAutomation("unload")
    ConfigDirty = true
    saveConfig()
    State.unloaded = true
    stopMovement()
    State.manualNoClip = false
    State.autoNoClip = false
    setNoClip(false)
    setSpeedBoost(false)
    setFPSBoost(false)
    State.antiAFK = false
    ModuleManager:DestroyAll("unload")
    EventManager:DisconnectAll()
    for targetPlayer in pairs(PlayerCache) do destroyPlayerESP(targetPlayer) end
    for object in pairs(SpiritCache) do destroySpiritESP(object) end
    if ESPFolder then pcall(function() ESPFolder:Destroy() end) end
    if Window then pcall(function() DimensiUI:Destroy() end) end
end

-- ============================================================================
-- Main loop & event wiring
-- ============================================================================

local espTimer = 0
local movementTimer = 0
local farmTimer = 0
local allInTimer = 0
local systemsTimer = 0
local monitorTimer = 0
local durationTimer = 0
local timerDisplayTimer = 0

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
    systemsTimer += dt
    monitorTimer += dt
    durationTimer += dt
    timerDisplayTimer += dt

    if durationTimer >= 0.25 then
        durationTimer = 0
        checkAutomationDuration()
    end

    if timerDisplayTimer >= 1 then
        timerDisplayTimer = 0
        updateDurationTimerUI()
    end

    if espTimer >= 0.2 then
        espTimer = 0
        updatePlayerESP()
        updateSpiritESP()
    end

    if movementTimer >= 0.05 then
        movementTimer = 0
        ErrorHandler.Run("Movement", updateMovement)
    end

    if farmTimer >= 0.1 then
        farmTimer = 0
        if StateFarm.autoFarmToggle then
            ErrorHandler.Run("AutoFarm", updateAutoFarm)
        end
    end

    if allInTimer >= 1.0 then
        allInTimer = 0
        if StateAllIn.autoAllInToggle then
            ErrorHandler.Run("AutoAllIn", updateAutoAllIn)
        else
            updateAllInStatusUI()
        end
    end

    if systemsTimer >= 0.5 then
        systemsTimer = 0
        ErrorHandler.Run("Scheduler", Scheduler.Step, Scheduler)
        ErrorHandler.Run("TargetManager", TargetManager.Step, TargetManager)
        ErrorHandler.Run("Watchdog", Watchdog.Step, Watchdog)
    end

    if monitorTimer >= 2 then
        monitorTimer = 0
        updateMonitorUI()
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

local PlayerCharacterConnections = {}

local function disconnectPlayerCharacter(targetPlayer)
    local connection = PlayerCharacterConnections[targetPlayer]
    if connection then
        pcall(function() connection:Disconnect() end)
        PlayerCharacterConnections[targetPlayer] = nil
        for index = #Connections, 1, -1 do
            if Connections[index] == connection then
                table.remove(Connections, index)
                break
            end
        end
    end
end

trackConnection(Players.PlayerRemoving:Connect(function(targetPlayer)
    disconnectPlayerCharacter(targetPlayer)
    destroyPlayerESP(targetPlayer)
end))

local function bindPlayerCharacter(targetPlayer)
    disconnectPlayerCharacter(targetPlayer)
    local connection = targetPlayer.CharacterAdded:Connect(function()
        task.wait(0.5)
        if not State.unloaded and targetPlayer.Parent == Players then
            updatePlayerESP()
        end
    end)
    PlayerCharacterConnections[targetPlayer] = connection
    trackConnection(connection)
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
local orbFolderConnections = {}

local function disconnectOrbFolderEvents()
    for _, connection in ipairs(orbFolderConnections) do
        pcall(function() connection:Disconnect() end)
        for index = #Connections, 1, -1 do
            if Connections[index] == connection then
                table.remove(Connections, index)
                break
            end
        end
    end
    table.clear(orbFolderConnections)
    orbEventsConnectedFor = nil
end

connectOrbEvents = function()
    local folder = ensureOrbsFolder()
    if not folder or orbEventsConnectedFor == folder then return end

    disconnectOrbFolderEvents()
    orbEventsConnectedFor = folder

    local removedConnection = trackConnection(folder.ChildRemoved:Connect(function(object)
        State.visitedOrbs[object] = nil
        State.blockedOrbs[object] = nil
        if State.currentOrb == object then
            State.currentOrb = nil
            State.nextOrbScanAt = 0
        end
    end))
    local addedConnection = trackConnection(folder.ChildAdded:Connect(function()
        if State.unloaded then return end
        if State.autoOrb and (not State.currentOrb or not State.currentOrb.Parent) then
            State.currentOrb = nil
            State.nextOrbScanAt = 0
        end
    end))

    if removedConnection then table.insert(orbFolderConnections, removedConnection) end
    if addedConnection then table.insert(orbFolderConnections, addedConnection) end
end

connectOrbEvents()

trackConnection(workspace.ChildRemoved:Connect(function(child)
    if child ~= orbEventsConnectedFor then return end
    disconnectOrbFolderEvents()
    if Orbs == child then Orbs = nil end
    State.currentOrb = nil
    State.nextOrbScanAt = 0
end))

trackConnection(workspace.ChildAdded:Connect(function(child)
    if State.unloaded then return end
    if child.Name == "SparkOrbs" or child.Name == "Orbs" then
        Orbs = child
        connectOrbEvents()
    end
end))

local function isCurrentCharacter(character, generation)
    return not State.unloaded
        and State.characterGeneration == generation
        and LocalPlayer.Character == character
        and character.Parent ~= nil
end

trackConnection(LocalPlayer.CharacterRemoving:Connect(function(character)
    if State.unloaded or LocalPlayer.Character ~= character then return end
    State.characterGeneration += 1
    watchSpeed(nil)
    table.clear(State.originalCollisions)
    resetMovement()
end))

trackConnection(LocalPlayer.CharacterAdded:Connect(function(character)
    if State.unloaded then return end
    State.characterGeneration += 1
    local generation = State.characterGeneration

    MovementLock:Acquire("IDLE")
    Scheduler.Current = "IDLE"
    watchSpeed(nil)
    resetFarmState()
    resetMovement()

    task.spawn(function()
        local humanoid = character:WaitForChild("Humanoid", 10)
        if not isCurrentCharacter(character, generation) then return end
        if humanoid and humanoid.Parent == character and State.speedBoost then
            watchSpeed(humanoid)
            enforceSpeed(humanoid)
        end
        if not isCurrentCharacter(character, generation) then return end
        if State.noClip then
            table.clear(State.originalCollisions)
            applyNoClipToCharacter()
        end
        if not isCurrentCharacter(character, generation) then return end
        updatePlayerESP()
        updateSpiritESP()
        if StateFarm.autoFarmToggle or State.autoOrb or State.autoSpirit or StateAllIn.autoAllInToggle then
            State.autoNoClip = true
            setNoClip(true)
            resetFarmState()
            resetMovement()
            logActivity("RECOVERY", "LogCharacterReady")
        end
    end)
end))

if State.speedBoost then setSpeedBoost(true) end
if State.manualNoClip then setNoClip(true) end
if State.fpsBoost then setFPSBoost(true) end

updatePlayerESP()
updateSpiritESP()
updateAllInStatusUI()
logActivity("SYSTEM", "LogHubReady")
updateMonitorUI()

notify(HUB_NAME, T("NotifyLoaded"))
print(string.format("%s | v%s | telatnakal", HUB_NAME, VERSION))