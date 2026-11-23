local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local VirtualUser = game:GetService("VirtualUser")
local Lighting = game:GetService("Lighting")
local VirtualInputManager = game:GetService("VirtualInputManager")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local DIMENSIUI_URL = "https://raw.githubusercontent.com/eko-sulistyawan/DimensiUI/refs/heads/main/dist/main.lua"
local function loadDimensiUI()
    local source = game:HttpGet(DIMENSIUI_URL)
    local compiler = loadstring
    assert(type(compiler) == "function", "Executor does not support loadstring")
    local chunk, compileError = compiler(source)
    assert(type(chunk) == "function", tostring(compileError or "Unable to compile DimensiUI"))
    return chunk()
end
local DimensiUI = loadDimensiUI()

local Spirits = workspace:WaitForChild("Spirits", 30)
local Orbs = workspace:FindFirstChild("SparkOrbs") or workspace:FindFirstChild("Orbs")

if not Spirits then
    warn("Folder Spirits tidak ditemukan.")
    return
end

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
    MinEnergyThreshold = 100,
    TargetEnergy = 2000,
    SwitchInterval = 240,
}

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
    mode = "IDLE",
    searchType = "ORB",
    timerStart = 0,
}

local PACE = {
    boost = CONFIG.Speed,
    normal = CONFIG.NormalSpeed,
}

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
        logActivity("ERROR", tostring(moduleName) .. ": " .. tostring(results[2]))
        warn("[DIMENSI-HUB][" .. tostring(moduleName) .. "] " .. tostring(results[2]))
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

function MovementLock:Acquire(owner)
    owner = tostring(owner or "IDLE")
    if self.Owner ~= owner then
        self.Owner = owner
        self.Generation += 1
    end
    return true
end

function MovementLock:Allows(owner)
    if self.Owner == owner then return true end
    if self.Owner == "ALL_IN" and owner == "ALL_IN" then return true end
    return false
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

local DEFAULT_SETTINGS = {
    Speed = 35,
    NormalSpeed = 16,
    PlayerESP = false,
    SpiritESP = false,
    SpeedBoost = false,
    ManualNoClip = false,
    FPSBoost = false,
    AntiAFK = false,
    TierFilter = {
        MYTHIC = true,
        EPIC = true,
        RARE = true,
        UNCOMMON = false,
        COMMON = false,
    },
    Movement = {
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
    },
    Farm = {
        InteractDistance = 3.5,
        ScanInterval = 0.5,
        PotDelay = 0.8,
        PlantRetryDelay = 1,
        PlantRetries = 2,
        BaseReturnDistance = 25,
        MoveOrderInterval = 0.65,
        KeyPressDuration = 0.25,
    },
    AllIn = {
        MinEnergyThreshold = 100,
        TargetEnergy = 2000,
        SwitchInterval = 240,
    },
}

local ConfigLanguage = "en"
local ActivityLog = {}
local ACTIVITY_LOG_LIMIT = 80

logActivity = function(category, message)
    local entry = {
        Time = os.date("%H:%M:%S"),
        Category = tostring(category or "SYSTEM"),
        Message = tostring(message or ""),
    }
    table.insert(ActivityLog, 1, entry)
    while #ActivityLog > ACTIVITY_LOG_LIMIT do
        table.remove(ActivityLog)
    end
    print(string.format("[DIMENSI-HUB][%s][%s] %s", entry.Time, entry.Category, entry.Message))
end

local function getActivityLogText(limit)
    local lines = {}
    local count = math.min(#ActivityLog, limit or 18)
    for index = 1, count do
        local entry = ActivityLog[index]
        lines[#lines + 1] = string.format("[%s] [%s] %s", entry.Time, entry.Category, entry.Message)
    end
    if #lines == 0 then
        return ConfigLanguage == "id" and "Belum ada aktivitas." or "No activity recorded."
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
    table.clear(State.zoneHistory)
    ConfigLanguage = "en"

    logActivity("CONFIG", "Configuration reset to defaults.")
end

local CONFIG_FOLDER = "/workspace/DimensiHUB/Bloom"
local CONFIG_FILE = CONFIG_FOLDER .. "/setting.json"
local ConfigReady = false
local ConfigLoaded = false
local ConfigSaveToken = 0
local ConfigDirty = false
local LastSavedConfig = nil
local TEXT = {
    en = {
        Home = "Home", Farming = "Farming", Visual = "Visual", Misc = "Misc", About = "About",
        CharacterProfile = "Character Profile", PlayerLabel = "Player", SystemOverview = "System Overview",
        SystemStatusLabel = "System Status", PlayerESPSection = "Player ESP", SpiritESPSection = "Spirit ESP",
        PlayerESPLabel = "Player ESP", SpiritESPLabel = "Spirit ESP", SpiritTierLabel = "Spirit Tier Filter",
        PotManagement = "Pot Management", OrbSpiritSection = "Orb & Spirit", AllInSection = "Auto All-In System",
        AutoFarmLabel = "Auto Farm Pots", AutoOrbLabel = "Auto Collect Orbs", AutoSpiritLabel = "Auto Hunt Spirits",
        AutoAllInLabel = "Auto All-In", AutoAllInStatus = "Auto All-In Status", CharacterSection = "Character",
        SpeedBoostLabel = "Speed Boost", NoclipLabel = "Noclip", PerformanceSection = "Performance",
        FPSBoostLabel = "FPS Boost", AntiAFKLabel = "Anti-AFK", SessionSection = "Session",
        ServerHopLabel = "Server Hop", RejoinLabel = "Rejoin Server", HubControlsLabel = "Hub Controls",
        StopAllLabel = "Stop All", ResetConfigLabel = "Reset Configuration", UnloadLabel = "Unload Hub",
        Language = "Language", Configuration = "Configuration", AboutDescription = "Version 1.0.1\nAuthor: telatnakal",
        SchedulerLabel = "Automation Monitor", ScannerStatusLabel = "Target Scanner",
        ActivityLogLabel = "Recent Activity", NoActivity = "No activity recorded.",
        TargetRefreshLabel = "Target Refresh", EnergyLabel = "Energy", RecoveriesLabel = "Recoveries",
        OwnerLabel = "Owner", HealthLabel = "Health", PositionLabel = "Position", SchedulerShort = "Scheduler",
        ScansLabel = "Scans", OrbLabel = "Orb", SpiritLabel = "Spirit", MemoryLabel = "Memory",
        LoadingCharacter = "Loading character...", Unavailable = "Unavailable", None = "None",
        StatusOff = "Status: OFF | Energy: %d (Search < %d, Farm >= %d)",
        AllInFarmingStatus = "Mode: AUTO FARM | Energy: %d / %d (Search again below %d)",
        AllInSearchingStatus = "Mode: SEARCH %s | Energy: %d / %d | Refresh/Switch: %ds",
        AllInIdleStatus = "Mode: IDLE | Energy: %d",
        NotifyLoaded = "Loaded successfully. Press RightControl to toggle the interface.",
        NotifyFarmOn = "Auto Farm Pots enabled.", NotifyFarmOff = "Auto Farm Pots disabled.",
        NotifyOrbOn = "Auto Collect Orbs enabled.", NotifyOrbOff = "Auto Collect Orbs disabled.",
        NotifySpiritOn = "Auto Hunt Spirits enabled.", NotifySpiritOff = "Auto Hunt Spirits disabled.",
        NotifyAllInOn = "Auto All-In enabled.", NotifyAllInOff = "Auto All-In disabled.",
        NotifyCacheRefreshed = "Target cache refreshed.", NotifyReset = "Configuration reset to defaults.",
        NotifySearchingServers = "Searching for another server...", NotifySwitchingServer = "Joining another server...",
        NotifyNoServer = "No other server found. Trying to rejoin...", NotifyServerFailed = "Unable to retrieve the server list.",
        AllInLowEnergy = "Energy below %d (%d). Searching for Orbs; refresh every %ds.",
        AllInReached = "Energy target %d reached. Returning to Auto Farm.",
        AllInSwitchSpirit = "Interval %ds: refreshed targets; switching to Spirit search.",
        AllInSwitchOrb = "Interval %ds: refreshed targets; switching to Orb search.",
        AutoFarm = "Auto Farm", Orb = "Orb", Spirit = "Spirit", AutoAllIn = "Auto All-In",
        ServerHop = "Server Hop", Targets = "Targets", ConfigurationTitle = "Configuration",
    },
    id = {
        Home = "Beranda", Farming = "Farming", Visual = "Visual", Misc = "Lainnya", About = "Tentang",
        CharacterProfile = "Profil Karakter", PlayerLabel = "Pemain", SystemOverview = "Ringkasan Sistem",
        SystemStatusLabel = "Status Sistem", PlayerESPSection = "ESP Pemain", SpiritESPSection = "ESP Spirit",
        PlayerESPLabel = "ESP Pemain", SpiritESPLabel = "ESP Spirit", SpiritTierLabel = "Filter Tier Spirit",
        PotManagement = "Pengelolaan Pot", OrbSpiritSection = "Orb & Spirit", AllInSection = "Sistem Auto All-In",
        AutoFarmLabel = "Auto Farm Pot", AutoOrbLabel = "Auto Kumpulkan Orb", AutoSpiritLabel = "Auto Berburu Spirit",
        AutoAllInLabel = "Auto All-In", AutoAllInStatus = "Status Auto All-In", CharacterSection = "Karakter",
        SpeedBoostLabel = "Peningkat Kecepatan", NoclipLabel = "Noclip", PerformanceSection = "Performa",
        FPSBoostLabel = "Peningkat FPS", AntiAFKLabel = "Anti-AFK", SessionSection = "Sesi",
        ServerHopLabel = "Pindah Server", RejoinLabel = "Masuk Ulang Server", HubControlsLabel = "Kontrol Hub",
        StopAllLabel = "Hentikan Semua", ResetConfigLabel = "Reset Konfigurasi", UnloadLabel = "Tutup Hub",
        Language = "Bahasa", Configuration = "Konfigurasi", AboutDescription = "Versi 1.0.1\nAuthor: telatnakal",
        SchedulerLabel = "Monitor Otomatisasi", ScannerStatusLabel = "Pemindai Target",
        ActivityLogLabel = "Aktivitas Terbaru", NoActivity = "Belum ada aktivitas.",
        TargetRefreshLabel = "Penyegaran Target", EnergyLabel = "Energi", RecoveriesLabel = "Pemulihan",
        OwnerLabel = "Pengendali", HealthLabel = "Kesehatan", PositionLabel = "Posisi", SchedulerShort = "Scheduler",
        ScansLabel = "Pemindaian", OrbLabel = "Orb", SpiritLabel = "Spirit", MemoryLabel = "Memori",
        LoadingCharacter = "Memuat karakter...", Unavailable = "Tidak tersedia", None = "Tidak ada",
        StatusOff = "Status: OFF | Energi: %d (Cari < %d, Farm >= %d)",
        AllInFarmingStatus = "Mode: AUTO FARM | Energi: %d / %d (Cari lagi jika < %d)",
        AllInSearchingStatus = "Mode: CARI %s | Energi: %d / %d | Refresh/Switch: %ds",
        AllInIdleStatus = "Mode: IDLE | Energi: %d",
        NotifyLoaded = "Berhasil dimuat. Tekan RightControl untuk membuka atau menutup antarmuka.",
        NotifyFarmOn = "Auto Farm Pot diaktifkan.", NotifyFarmOff = "Auto Farm Pot dinonaktifkan.",
        NotifyOrbOn = "Auto Kumpulkan Orb diaktifkan.", NotifyOrbOff = "Auto Kumpulkan Orb dinonaktifkan.",
        NotifySpiritOn = "Auto Berburu Spirit diaktifkan.", NotifySpiritOff = "Auto Berburu Spirit dinonaktifkan.",
        NotifyAllInOn = "Auto All-In diaktifkan.", NotifyAllInOff = "Auto All-In dinonaktifkan.",
        NotifyCacheRefreshed = "Cache target diperbarui.", NotifyReset = "Konfigurasi dikembalikan ke pengaturan awal.",
        NotifySearchingServers = "Mencari server lain...", NotifySwitchingServer = "Beralih ke server lain...",
        NotifyNoServer = "Server lain tidak ditemukan. Mencoba masuk ulang...", NotifyServerFailed = "Gagal mengambil daftar server.",
        AllInLowEnergy = "Energi di bawah %d (%d). Mencari Orb; refresh setiap %ds.",
        AllInReached = "Target energi %d tercapai. Kembali ke Auto Farm.",
        AllInSwitchSpirit = "Interval %ds: target diperbarui; beralih mencari Spirit.",
        AllInSwitchOrb = "Interval %ds: target diperbarui; beralih mencari Orb.",
        AutoFarm = "Auto Farm", Orb = "Orb", Spirit = "Spirit", AutoAllIn = "Auto All-In",
        ServerHop = "Pindah Server", Targets = "Target", ConfigurationTitle = "Konfigurasi",
    }
}
local function T(key)
    return (TEXT[ConfigLanguage] and TEXT[ConfigLanguage][key]) or (TEXT.en and TEXT.en[key]) or key
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
    if type(data.TierFilter) == "table" then
        for key in pairs(TierFilter) do
            if type(data.TierFilter[key]) == "boolean" then TierFilter[key] = data.TierFilter[key] end
        end
    end
    return true
end

local function ensureConfigFolder()
    if type(isfolder) ~= "function" or type(makefolder) ~= "function" then return false end
    pcall(function() if not isfolder("/workspace/DimensiHUB") then makefolder("/workspace/DimensiHUB") end end)
    pcall(function() if not isfolder(CONFIG_FOLDER) then makefolder(CONFIG_FOLDER) end end)
    return true
end

local function loadConfig()
    if type(isfile) ~= "function" or type(readfile) ~= "function" then return false end
    local ok, result = pcall(function()
        if not isfile(CONFIG_FILE) then return false end
        local decoded = HttpService:JSONDecode(readfile(CONFIG_FILE))
        return applyConfigSnapshot(decoded)
    end)
    if ok and result then
        ConfigLoaded = true
        LastSavedConfig = HttpService:JSONEncode(getConfigSnapshot())
        ConfigDirty = false
        return true
    end
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
    local saved = pcall(function() writefile(CONFIG_FILE, encoded) end)
    if saved then
        LastSavedConfig = encoded
        ConfigDirty = false
    end
    return saved
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

local ESPFolder = Instance.new("Folder")
ESPFolder.Name = "SpiritsHunterESP"
ESPFolder.Parent = PlayerGui

local PlayerCache = {}
local SpiritCache = {}

local NotificationManager = {}
local NotificationAliases = {
    ["DIMENSI-HUB | BLOOM"] = "DIMENSI-HUB | BLOOM",
    ["Auto Farm"] = "AutoFarm", ["Orb"] = "Orb", ["Spirit"] = "Spirit",
    ["Auto All-In"] = "AutoAllIn", ["Server Hop"] = "ServerHop",
    ["Targets"] = "Targets", ["Configuration"] = "ConfigurationTitle",
    ["Auto Farm Pots: ON"] = "NotifyFarmOn", ["Auto Farm Pots: OFF"] = "NotifyFarmOff",
    ["Auto Collect Orbs Activated"] = "NotifyOrbOn", ["Auto Collect Orbs Stopped"] = "NotifyOrbOff",
    ["Auto Hunt Spirits Activated"] = "NotifySpiritOn", ["Auto Hunt Spirits Stopped"] = "NotifySpiritOff",
    ["Fitur Auto All-In diaktifkan."] = "NotifyAllInOn", ["Fitur Auto All-In dimatikan."] = "NotifyAllInOff",
    ["Target cache refreshed."] = "NotifyCacheRefreshed", ["Configuration reset to defaults."] = "NotifyReset",
    ["Mencari server lain..."] = "NotifySearchingServers", ["Berpindah ke server baru..."] = "NotifySwitchingServer",
    ["Tidak ditemukan server lain, mencoba rejoin..."] = "NotifyNoServer", ["Gagal mengambil daftar server!"] = "NotifyServerFailed",
}
function NotificationManager:Resolve(value)
    local key = NotificationAliases[value]
    return key and T(key) or value
end
local function notify(title, content)
    if State.unloaded then return end
    pcall(function()
        DimensiUI:Notify({
            Title = NotificationManager:Resolve(title),
            Content = NotificationManager:Resolve(content),
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
    if MovementLock.Owner ~= "FARM" and not (MovementLock.Owner == "ALL_IN" and StateAllIn.mode == "FARMING") then return end

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
    scheduleConfigSave()
    logActivity("SETTING", "Speed boost " .. (value and "enabled" or "disabled"))
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

local TargetManager

local function updateMovement()
    if State.unloaded then return end
    if MovementLock.Owner ~= "ORB" and MovementLock.Owner ~= "SPIRIT" and MovementLock.Owner ~= "ALL_IN" then return end
    if MovementLock.Owner == "ALL_IN" and StateAllIn.mode ~= "SEARCHING" then return end
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
        if target then TargetManager:Remember(target, "ORB") end
        isOrbTarget = true
    elseif State.autoSpirit and not State.autoOrb then
        if not State.currentSpirit or not State.currentSpirit.Parent or not isTierAllowed(State.currentSpirit) then
            State.currentSpirit = getNearestSpirit()
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

local function refreshAllInTargets()
    ensureOrbsFolder()
    clearOrbCache()
    clearSpiritCache()
    resetMovement()
    if TargetManager then
        TargetManager.LastRefresh = os.clock()
    end
end

TargetManager = {
    RefreshInterval = 60,
    ValidationInterval = 0.5,
    LastRefresh = 0,
    LastValidation = 0,
    Memory = setmetatable({}, { __mode = "k" }),
    ScanCount = 0,
}

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
        logActivity("TARGET", "Orb target invalidated; rescan requested.")
    end

    if State.autoSpirit and State.currentSpirit and not self:IsValid(State.currentSpirit, "SPIRIT") then
        self.Memory[State.currentSpirit] = nil
        State.currentSpirit = nil
        State.stuckTime = 0
        State.stuckCheckPosition = nil
        logActivity("TARGET", "Spirit target invalidated; rescan requested.")
    end
end

function TargetManager:Refresh(reason)
    refreshAllInTargets()
    self.LastRefresh = os.clock()
    self.ScanCount += 1
    logActivity("TARGET", "Orb/Spirit targets refreshed (" .. tostring(reason or "scheduled") .. ").")
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
        self:Refresh("60-second interval")
    end
end

local Scheduler = {
    Current = "IDLE",
    LastChange = 0,
    Priority = {
        STOP_ALL = 100,
        ALL_IN = 90,
        FARM = 70,
        ORB = 50,
        SPIRIT = 40,
        IDLE = 0,
    },
}

function Scheduler:Resolve()
    if StateAllIn.autoAllInToggle then return "ALL_IN" end
    if StateFarm.autoFarmToggle then return "FARM" end
    if State.autoOrb then return "ORB" end
    if State.autoSpirit then return "SPIRIT" end
    return "IDLE"
end

function Scheduler:Step()
    if State.unloaded then return end
    local requested = self:Resolve()

    if requested ~= self.Current then
        local previous = self.Current
        self.Current = requested
        self.LastChange = os.clock()
        logActivity("SCHEDULER", previous .. " -> " .. requested)
    end
    MovementLock:Acquire(requested)

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
            logActivity("WATCHDOG", "Character unavailable for 20 seconds; automation remains paused.")
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
            logActivity("WATCHDOG", "Invalid target cleared; scanner will reacquire.")
            return
        end

        if now - self.LastProgressAt >= 18 then
            if targetType == "ORB" then
                State.blockedOrbs[target] = now + CONFIG.OrbBlockedTime
                State.currentOrb = nil
            else
                State.currentSpirit = nil
            end
            resetMovement()
            self.LastProgressAt = now
            self.RecoveryCount += 1
            logActivity("WATCHDOG", "No movement progress; target released for recovery #" .. self.RecoveryCount .. ".")
        end
    end
end

ModuleManager:Register("EventManager", EventManager)
ModuleManager:Register("ErrorHandler", ErrorHandler)
ModuleManager:Register("MovementLock", MovementLock)
ModuleManager:Register("TargetManager", TargetManager)
ModuleManager:Register("Scheduler", Scheduler)
ModuleManager:Register("Watchdog", Watchdog)

local function updateMonitorUI()
    if State.unloaded then return end
    if schedulerStatusParagraph then
        pcall(function()
            schedulerStatusParagraph:SetDesc(
                T("OwnerLabel") .. ": " .. Scheduler.Current
                .. " | " .. T("TargetRefreshLabel") .. ": " .. tostring(math.max(0, math.ceil(TargetManager.RefreshInterval - (os.clock() - TargetManager.LastRefresh))) .. "s")
                .. " | " .. T("RecoveriesLabel") .. ": " .. tostring(Watchdog.RecoveryCount)
            )
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
    local position = root and string.format("%.1f, %.1f, %.1f", root.Position.X, root.Position.Y, root.Position.Z) or "Unavailable"
    if homeProfileParagraph then
        pcall(function()
            homeProfileParagraph:SetDesc(
                LocalPlayer.Name .. " | " .. T("HealthLabel") .. ": " .. health .. "/" .. maxHealth
                .. " | " .. T("PositionLabel") .. ": " .. position
            )
        end)
    end
    if homeStatusParagraph then
        pcall(function()
            homeStatusParagraph:SetDesc(
                T("SchedulerShort") .. ": " .. Scheduler.Current
                .. " | " .. T("EnergyLabel") .. ": " .. tostring(getEnergy())
                .. " | " .. T("RecoveriesLabel") .. ": " .. tostring(Watchdog.RecoveryCount)
            )
        end)
    end
    if targetStatusParagraph then
        local orbName = State.currentOrb and State.currentOrb.Name or T("None")
        local spiritName = State.currentSpirit and State.currentSpirit.Name or T("None")
        pcall(function()
            targetStatusParagraph:SetDesc(
                T("ScansLabel") .. ": " .. tostring(TargetManager.ScanCount)
                .. " | " .. T("OrbLabel") .. ": " .. orbName
                .. " | " .. T("SpiritLabel") .. ": " .. spiritName
                .. " | " .. T("MemoryLabel") .. ": " .. tostring((function() local n = 0 for _ in pairs(TargetManager.Memory) do n += 1 end return n end)())
            )
        end)
    end
end

local function stopAllAutomation(reason)
    if State.unloaded and reason ~= "unload" then return end

    State.autoSpirit = false
    State.autoOrb = false
    StateFarm.autoFarmToggle = false
    StateFarm.busy = false
    StateAllIn.autoAllInToggle = false
    StateAllIn.mode = "IDLE"
    StateAllIn.searchType = "ORB"
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

    logActivity("CONTROL", "STOP ALL executed" .. (reason and (": " .. tostring(reason)) or "."))
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
            StateAllIn.searchType,
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
            logActivity("AUTOMATION", "Auto Orb enabled")
            StateFarm.autoFarmToggle = false

            State.autoNoClip = true
            setNoClip(true)
            refreshAllInTargets()
            notify(
                "Auto All-In",
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
                "Auto All-In",
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
                    "Auto All-In",
                    string.format(T("AllInSwitchSpirit"), CONFIG_ALLIN.SwitchInterval)
                )
            else
                StateAllIn.searchType = "ORB"
                State.autoOrb = true
                State.autoSpirit = false
                notify(
                    "Auto All-In",
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
    logActivity("SETTING", "FPS boost " .. (enabled and "enabled" or "disabled"))
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

buildUI = function()
    syncingAutoToggles = true
    syncingSettingToggles = true

    if Window then
        pcall(function() DimensiUI:Destroy() end)
        DimensiUI = loadDimensiUI()
    end

    Window = DimensiUI:CreateWindow({
        Title = "DIMENSI-HUB | BLOOM | V.1.0.1 | telatnakal",
        SubTitle = "",
        Theme = "Dimensi",
        Size = UDim2.fromOffset(590, 470),
        TabWidth = 138,
        Acrylic = false,
        MinimizeKey = Enum.KeyCode.RightControl,
    })

    local HomeTab = Window:AddTab({ Title = T("Home"), Icon = "home" })
    local FarmingTab = Window:AddTab({ Title = T("Farming"), Icon = "sprout" })
    local VisualTab = Window:AddTab({ Title = T("Visual"), Icon = "eye" })
    local MiscTab = Window:AddTab({ Title = T("Misc"), Icon = "settings" })
    local AboutTab = Window:AddTab({ Title = T("About"), Icon = "info" })

    local CharacterSection = HomeTab:AddSection(T("CharacterProfile"))
    homeProfileParagraph = CharacterSection:AddParagraph({
        Title = T("PlayerLabel"),
        Content = LocalPlayer.Name .. " | " .. T("LoadingCharacter"),
    })
    local OverviewSection = HomeTab:AddSection(T("SystemOverview"))
    homeStatusParagraph = OverviewSection:AddParagraph({
        Title = T("SystemStatusLabel"),
        Content = T("SchedulerShort") .. ": IDLE | " .. T("EnergyLabel") .. ": 0",
    })
    targetStatusParagraph = OverviewSection:AddParagraph({
        Title = T("ScannerStatusLabel"),
        Content = T("ScansLabel") .. ": 0 | " .. T("OrbLabel") .. ": " .. T("None") .. " | " .. T("SpiritLabel") .. ": " .. T("None"),
    })
    local MonitorSection = HomeTab:AddSection(T("SchedulerLabel"))
    schedulerStatusParagraph = MonitorSection:AddParagraph({
        Title = T("SchedulerLabel"), Content = T("OwnerLabel") .. ": IDLE",
    })
    activityLogParagraph = MonitorSection:AddParagraph({
        Title = T("ActivityLogLabel"), Content = T("NoActivity"),
    })

    local FarmSection = FarmingTab:AddSection(T("PotManagement"))
    farmToggle = FarmSection:AddToggle("AutoFarm", {
        Title = T("AutoFarmLabel"), Default = StateFarm.autoFarmToggle,
        Callback = function(value)
            if syncingAutoToggles or State.unloaded then return end
            StateFarm.autoFarmToggle = value
            scheduleConfigSave()
            resetFarmState()
            logActivity("AUTOMATION", "Auto Farm " .. (value and "enabled" or "disabled"))
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

    local OrbSpiritSection = FarmingTab:AddSection(T("OrbSpiritSection"))
    orbToggle = OrbSpiritSection:AddToggle("AutoOrb", {
        Title = T("AutoOrbLabel"), Default = State.autoOrb,
        Callback = function(value)
            if syncingAutoToggles or State.unloaded then return end
            State.autoOrb = value
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
    spiritToggle = OrbSpiritSection:AddToggle("AutoSpirit", {
        Title = T("AutoSpiritLabel"), Default = State.autoSpirit,
        Callback = function(value)
            if syncingAutoToggles or State.unloaded then return end
            State.autoSpirit = value
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
    local AllInSection = FarmingTab:AddSection(T("AllInSection"))
    allInToggle = AllInSection:AddToggle("AutoAllIn", {
        Title = T("AutoAllInLabel"), Default = StateAllIn.autoAllInToggle,
        Callback = function(value)
            if syncingAutoToggles or State.unloaded then return end
            StateAllIn.autoAllInToggle = value
            scheduleConfigSave()
            logActivity("AUTOMATION", "Auto All-In " .. (value and "enabled" or "disabled"))
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
        Default = selectedTiers(), Multi = true, AllowNull = true,
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

    local CharacterSettings = MiscTab:AddSection(T("CharacterSection"))
    speedBoostToggle = CharacterSettings:AddToggle("SpeedBoost", {
        Title = T("SpeedBoostLabel") .. " (35)", Default = State.speedBoost,
        Callback = function(value) if not syncingSettingToggles then setSpeedBoost(value) end end,
    })
    manualNoClipToggle = CharacterSettings:AddToggle("ManualNoClip", {
        Title = T("NoclipLabel"), Default = State.manualNoClip,
        Callback = function(value)
            if syncingSettingToggles then return end
            State.manualNoClip = value
            scheduleConfigSave()
            logActivity("SETTING", "Manual noclip " .. (value and "enabled" or "disabled"))
            setNoClip(value or State.autoNoClip)
        end,
    })
    local PerformanceSection = MiscTab:AddSection(T("PerformanceSection"))
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
            logActivity("SETTING", "Anti-AFK " .. (value and "enabled" or "disabled"))
        end,
    })
    local SessionSection = MiscTab:AddSection(T("SessionSection"))
    SessionSection:AddButton({ Title = T("ServerHopLabel"), Description = "", Callback = serverHop })
    SessionSection:AddButton({
        Title = T("RejoinLabel"), Description = "",
        Callback = function() TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer) end,
    })
    local ConfigurationSection = MiscTab:AddSection(T("Configuration"))
    ConfigurationSection:AddDropdown("Language", {
        Title = T("Language"), Values = { "EN", "ID" },
        Default = string.upper(ConfigLanguage), AllowNull = false,
        Callback = function(value) if setLanguage then setLanguage(value) end end,
    })
    ConfigurationSection:AddButton({
        Title = T("ResetConfigLabel"), Description = "",
        Callback = function()
            stopAllAutomation("configuration reset")
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
            notify(T("ConfigurationTitle"), T("NotifyReset"))
            task.defer(buildUI)
        end,
    })
    local HubControlsSection = MiscTab:AddSection(T("HubControlsLabel"))
    HubControlsSection:AddButton({
        Title = T("StopAllLabel"), Description = "",
        Callback = function() stopAllAutomation("manual request") end,
    })
    HubControlsSection:AddButton({
        Title = T("UnloadLabel"), Description = "",
        Callback = function() if unloadHub then unloadHub() end end,
    })

    local AboutSection = AboutTab:AddSection(T("About"))
    AboutSection:AddParagraph({
        Title = "DIMENSI-HUB | BLOOM", Content = T("AboutDescription"),
    })

    Window:SelectTab(1)
    syncingAutoToggles = false
    syncingSettingToggles = false
end

onModuleError = function(moduleName)
    if moduleName == "Movement" then
        stopAllAutomation("movement error")
        return
    elseif moduleName == "AutoFarm" then
        StateFarm.autoFarmToggle = false
        StateFarm.busy = false
        resetFarmState()
    elseif moduleName == "AutoAllIn" then
        StateAllIn.autoAllInToggle = false
        StateAllIn.mode = "IDLE"
        State.autoOrb = false
        State.autoSpirit = false
        StateFarm.autoFarmToggle = false
        resetMovement()
    else
        return
    end

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
    logActivity("SETTING", "Language changed to " .. string.upper(language))
    task.defer(buildUI)
end

buildUI()
ConfigReady = true

if ConfigLoaded then
    task.defer(function()
        if State.unloaded then return end
        if State.speedBoost then setSpeedBoost(true) end
        if State.fpsBoost then setFPSBoost(true) end
        if State.manualNoClip then setNoClip(true) end
        if State.playerESP then updatePlayerESP() end
        if State.spiritESP then updateSpiritESP() end
        if StateFarm.autoFarmToggle or State.autoOrb or State.autoSpirit then
            State.autoNoClip = true
            setNoClip(true)
            resetFarmState()
            resetMovement()
        elseif StateAllIn.autoAllInToggle then
            StateAllIn.mode = "IDLE"
            StateAllIn.timerStart = os.clock()
            ErrorHandler.Run("AutoAllIn", updateAutoAllIn)
        end
        syncAutoToggleUI(StateAllIn.autoAllInToggle and "AllIn" or StateFarm.autoFarmToggle and "Farm" or State.autoOrb and "Orb" or State.autoSpirit and "Spirit" or nil)
    end)
end

unloadHub = function()
    if State.unloaded then return end
    ConfigDirty = true
    saveConfig()
    stopAllAutomation("unload")
    State.unloaded = true
    stopMovement()
    State.manualNoClip = false
    State.autoNoClip = false
    setNoClip(false)
    setSpeedBoost(false)
    setFPSBoost(false)
    State.antiAFK = false
    EventManager:DisconnectAll()
    for targetPlayer in pairs(PlayerCache) do destroyPlayerESP(targetPlayer) end
    for object in pairs(SpiritCache) do destroySpiritESP(object) end
    if ESPFolder then pcall(function() ESPFolder:Destroy() end) end
  if Window then
    pcall(function() Window:Destroy() end)
    Window = nil
end

if DimensiUI then
    pcall(function() DimensiUI:Destroy() end)
end
end

local espTimer = 0
local movementTimer = 0
local farmTimer = 0
local allInTimer = 0
local systemsTimer = 0
local monitorTimer = 0

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
    MovementLock:Acquire("IDLE")
    Scheduler.Current = "IDLE"
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
        if StateFarm.autoFarmToggle or State.autoOrb or State.autoSpirit or StateAllIn.autoAllInToggle then
            State.autoNoClip = true
            setNoClip(true)
            resetFarmState()
            resetMovement()
            logActivity("RECOVERY", "Character ready; active automation resumed.")
        end
    end)
end))

if State.speedBoost then setSpeedBoost(true) end
if State.manualNoClip then setNoClip(true) end
if State.fpsBoost then setFPSBoost(true) end

updatePlayerESP()
updateSpiritESP()
updateAllInStatusUI()
logActivity("SYSTEM", "Hub initialized with modular scheduler and watchdog.")
updateMonitorUI()

notify("DIMENSI-HUB | BLOOM", T("NotifyLoaded"))
print("DIMENSI-HUB | BLOOM | V.1.0.1 | telatnakal")
