-- OUTLINE:
-- Passive cons build either at their full speed or not at all.
-- The amount of res expense for non-passive cons is calculated (as total expense - passive cons expense) and the remainder is available to the passive cons, if any.
-- We cycle through the passive cons and allocate this expense until it runs out. All other passive cons have their buildspeed set to 0.

-- ACTUALLY:
-- We only do the check every x frames (controlled by interval) and only allow passive con(s) to act if doing so allows them to sustain their expense
--   until the next check, based on current expense allocations.
-- We allow the interval to be different for each team, because normally it would be wasteful to reconfigure every frame, but if a team has a high income and low
--   storage then not doing the check every frame would result in excessing resources that passive builders could have used
-- We also pick one passive con, per build target, and allow it a tiny build speed for 1 frame per interval, to prevent nanoframes that only have passive cons
--   building them from decaying if a prolonged stall occurs.
-- We cache the buildspeeds of all passive cons to prevent constant use of get/set callouts.

-- REASON:
-- AllowUnitBuildStep is damn expensive and is a serious perf hit if it is used for all this.

function gadget:GetInfo()
    return {
        name      = 'Passive Builders v3',
        desc      = 'Builders marked as passive only use resources after others builder have taken their share',
        author    = 'BD, Bluestone',
        date      = 'Why is date even relevant',
        license   = 'GNU GPL, v2 or later',
        layer     = 0,
        enabled   = true
    }
end

----------------------------------------------------------------
-- Synced only
----------------------------------------------------------------
if not gadgetHandler:IsSyncedCode() then
    return false
end

----------------------------------------------------------------
-- Var
----------------------------------------------------------------
local CMD_PASSIVE = 34571

local ruleName = "passiveBuilders"

local cmdPassiveDesc = {
      id      = CMD_PASSIVE,
      name    = 'passive',
      action  = 'passive',
      type    = CMDTYPE.ICON_MODE,
      tooltip = 'Builder Mode: Passive wont build when stalling',
      params  = {0, 'Active', 'Passive'}
}

----------------------------------------------------------------
-- Speedups
----------------------------------------------------------------
local spInsertUnitCmdDesc = Spring.InsertUnitCmdDesc
local spFindUnitCmdDesc = Spring.FindUnitCmdDesc
local spGetUnitCmdDescs = Spring.GetUnitCmdDescs
local spEditUnitCmdDesc = Spring.EditUnitCmdDesc

local spGetTeamResources = Spring.GetTeamResources
local spGetUnitDefID = Spring.GetUnitDefID
local spSetUnitRulesParam = Spring.SetUnitRulesParam
local spSetUnitBuildSpeed = Spring.SetUnitBuildSpeed
local spGetUnitIsBuilding = Spring.GetUnitIsBuilding
local spValidUnitID = Spring.ValidUnitID

local min = math.min
local max = math.max

local teams = {}
local builders = {}
local targets = {}
local idealExpenses = {}

local canPassive = {}
for unitDefID, unitDef in pairs(UnitDefs) do
    canPassive[unitDefID] = ((unitDef.canAssist and unitDef.buildSpeed > 0) or #unitDef.buildOptions > 0)
end

-- MARK: Objects

local function Builder(unitDef)
    local newBuilder = {}
    newBuilder.unitDef = unitDef or UnitDef(unitID)
    newBuilder.isPassive = false
    newBuilder.buildSpeed = unitDef.buildSpeed
    return newBuilder
end

local function SetPassive(teamID, unitID)
    local builder = teams[teamID].builders[unitID]
    -- Spring.Echo("Setting " .. unitID .. " to passive. Was building with speed " .. builder.buildSpeed .. ".")
    teams[teamID].builders[unitID].isPassive = true
end

local function SetActive(teamID, unitID)
    local builder = teams[teamID].builders[unitID]
    spSetUnitBuildSpeed(unitID, builder.unitDef.buildSpeed)
    builder.isPassive = false
    -- Spring.Echo("Setting " .. unitID .. " to active. Was building with speed " .. builder.buildSpeed .. ".")
    builder.buildSpeed = builder.unitDef.buildSpeed
end

local function Team(buildersNotBuilding)
    local newTeam = {}
    newTeam.passiveConstructorSpeedFactor = 0
    newTeam.builders = {}
    return newTeam
end

local function UnitDef(unitID)
    return UnitDefs[spGetUnitDefID(unitID)]
end

local function AddBuilder(builderID, builderUnitDefID, teamID)
    local unitDef = UnitDefs[builderUnitDefID]
    local builder = Builder(unitDef)
    teams[teamID].builders[builderID] = builder
    if not idealExpenses[unitDef] then
        idealExpenses[unitDef] = {}
    end
end

local function RemoveBuilder(teamID, builderID)
    teams[teamID].builders[builderID] = nil
end 

local function Copy(expense)
    return Expense(expense.metal, expense.energy)
end

local function Expense(metal, energy)
    local newExpense = {}
    newExpense.metal = metal
    newExpense.energy = energy
    return newExpense
end

local function Add(expense, otherExpense)
    expense.metal = expense.metal + otherExpense.metal
    expense.energy = expense.energy + otherExpense.energy
end

local function Subtract(expense, otherExpense, cap)
    expense.metal = expense.metal - otherExpense.metal
    expense.energy = expense.energy - otherExpense.energy
end

local function Multiply(expense, number)
    expense.metal = expense.metal * number
    expense.energy = expense.energy * number
end

local function Divide(expense, number)
    expense.metal = expense.metal / number
    expense.energy = expense.energy / number
end

local function BuildTarget(unitID)
    local newTarget = {}
    newTarget.unitDef = UnitDef(unitID)
    
    return newTarget
end

local _idealExpense = Expense(0, 0)
local function IdealExpense(buildTarget, builder)
    local cached = idealExpenses[builder.unitDef][buildTarget]
    if cached then
        return cached
    end
    _idealExpense.metal = buildTarget.unitDef.metalCost 
    _idealExpense.energy = buildTarget.unitDef.energyCost
    local rate = builder.unitDef.buildSpeed / buildTarget.unitDef.buildTime
    Multiply(_idealExpense, rate)
    idealExpenses[builder.unitDef][buildTarget] = _idealExpense
    return _idealExpense
end

-- MARK: Helpers

local function Clamp(number, lowerBound, upperBound)
    return max(min(number, upperBound), lowerBound)
end

----------------------------------------------------------------
-- Callins
----------------------------------------------------------------
function gadget:Initialize()
    for _,teamID in pairs(Spring.GetTeamList()) do
        teams[teamID] = Team()
    end

    for _,unitID in pairs(Spring.GetAllUnits()) do
        gadget:UnitCreated(unitID, spGetUnitDefID(unitID), Spring.GetUnitTeam(unitID))
    end
end

function gadget:UnitCreated(unitID, unitDefID, teamID)
    if canPassive[unitDefID] then
        spInsertUnitCmdDesc(unitID, cmdPassiveDesc)
        AddBuilder(unitID, unitDefID, teamID)
    end
end

function gadget:UnitGiven(unitID, unitDefID, newTeamID, oldTeamID)
    if canPassive[unitDefID] then
        local oldTeam = teams[oldTeamID]
        local newTeam = teams[newTeamID]

        local builder = oldTeam.builders[unitID]
        
        if builder then
            oldTeam.builders[unitID] = nil
            newTeam.builders[unitID] = builder
        end
    end
end

function gadget:UnitTaken(unitID, unitDefID, oldTeamID, newTeamID)
    gadget:UnitGiven(unitID, unitDefID, newTeamID, oldTeamID)
end

function gadget:UnitDestroyed(unitID, unitDefID, teamID)
    if canPassive[unitDefID] then
        RemoveBuilder(teamID, unitID)
    end
end

function gadget:AllowCommand(unitID, unitDefID, teamID, cmdID, cmdParams, cmdOptions, cmdTag, playerID, fromSynced, fromLua)
    -- track which cons are set to passive
    if cmdID == CMD_PASSIVE and canPassive[unitDefID] then
        local cmdIdx = spFindUnitCmdDesc(unitID, CMD_PASSIVE)
        if cmdIdx then
            local cmdDesc = spGetUnitCmdDescs(unitID, cmdIdx, cmdIdx)[1]
            cmdDesc.params[1] = cmdParams[1]
            spEditUnitCmdDesc(unitID, cmdIdx, cmdDesc)
            spSetUnitRulesParam(unitID,ruleName,cmdParams[1])
            if cmdParams[1] == 1 then
                SetPassive(teamID, unitID)
            else
                SetActive(teamID, unitID)
            end
        end
        return false -- Allowing command causes command queue to be lost if command is unshifted
    end
    return true
end

local passiveConstructorExpense = {}
local remainingExpense = {}

function gadget:GameFrame(n)
    for teamID,team in pairs(teams) do

        -- Reset resource data (to avoid creating new tables)
        passiveConstructorExpense.metal = 0
        passiveConstructorExpense.energy = 0
        remainingExpense.metal = spGetTeamResources(teamID, "metal")
        remainingExpense.energy = spGetTeamResources(teamID, "energy")

        for builderID,builder in pairs(team.builders) do
            if not spValidUnitID(builderID) then
                team.builders[builderID] = nil
                -- Spring.Echo(builderID .. " was not a valid builder!")
            else
                -- Spring.Echo(builderID.. " was a valid builder!")
                local targetID = spGetUnitIsBuilding(builderID)
                if targetID then
                    local target = targets[targetID]
                    if not target then
                        target = BuildTarget(targetID)
                        targets[targetID] = target
                    end
                    local builderExpense = IdealExpense(target, builder)
                    if builder.isPassive then
                        -- Apply build slowing from last frame, then 
                        builder.buildSpeed = builder.unitDef.buildSpeed * team.passiveConstructorSpeedFactor
                        -- Spring.Echo("Speed factor: " .. team.passiveConstructorSpeedFactor)
                        -- Spring.Echo("Build speed set to " .. builder.buildSpeed)
                        spSetUnitBuildSpeed(builderID, builder.buildSpeed)
                        Add(passiveConstructorExpense, builderExpense)
                    else
                        -- Spring.Echo("Builder was active!")
                        Subtract(remainingExpense, builderExpense)
                    end
                end
            end
        end
        
        -- Spring.Echo("Previous factor " .. team.passiveConstructorSpeedFactor)
        -- Calculate how much passive builders must be slowed by; this will be applied next frame (for performance reasons)
        team.passiveConstructorSpeedFactor = min(remainingExpense.metal / passiveConstructorExpense.metal, remainingExpense.energy / passiveConstructorExpense.energy)
        -- Spring.Echo("Setting factor " .. team.passiveConstructorSpeedFactor)
        -- Non-zero minimum to prevent the build target from decaying
        team.passiveConstructorSpeedFactor = Clamp(team.passiveConstructorSpeedFactor, 0.01, 1)
        -- Spring.Echo("Setting factor " .. team.passiveConstructorSpeedFactor)
    end
end