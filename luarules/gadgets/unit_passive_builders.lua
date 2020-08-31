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

local stallMarginInc = 0.2
local stallMarginSto = 0.01

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
local spGetTeamList = Spring.GetTeamList
local spGetUnitDefID = Spring.GetUnitDefID
local spSetUnitRulesParam = Spring.SetUnitRulesParam
local spSetUnitBuildSpeed = Spring.SetUnitBuildSpeed
local spGetUnitIsBuilding = Spring.GetUnitIsBuilding
local spValidUnitID = Spring.ValidUnitID
local simSpeed = Game.gameSpeed

local min = math.min
local max = math.max
local floor = math.floor

local teams = {}
local builders = {}
local targets = {}
local idealExpenses = {}

local passiveConstructorSpeedFactor = 0

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
    Spring.Echo("Setting " .. unitID .. " passive. Buildspeed was " .. teams[teamID].builders[unitID].buildSpeed)
    Spring.Echo("Passive constructor speed factor: " .. passiveConstructorSpeedFactor)
    teams[teamID].builders[unitID].isPassive = true
end

local function SetActive(teamID, unitID)
    local builder = teams[teamID].builders[unitID]
    Spring.Echo("Setting " .. unitID .. " active. Buildspeed was " .. builder.buildSpeed)
    Spring.Echo("Passive constructor speed factor: " .. passiveConstructorSpeedFactor)
    spSetUnitBuildSpeed(unitID, builder.unitDef.buildSpeed)
    builder.isPassive = false
    builder.buildSpeed = builder.unitDef.buildSpeed
end

function Team(buildersNotBuilding)
    local newTeam = {}
    newTeam.builders = {}
    return newTeam
end

function GetResources(teamID)
    local currentMetal = spGetTeamResources(teamID, "metal")
    local currentEnergy = spGetTeamResources(teamID, "energy") 
    return Expense(currentMetal, currentEnergy)
end

function UnitDef(unitID)
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

function RemoveBuilder(teamID, builderID)
    teams[teamID].builders[builderID] = nil
end 

function Copy(expense)
    return Expense(expense.metal, expense.energy)
end
function Expense(metal, energy)
    local newExpense = {}
    newExpense.metal = metal
    newExpense.energy = energy
    return newExpense
end

function Add(expense, otherExpense)
    expense.metal = expense.metal + otherExpense.metal
    expense.energy = expense.energy + otherExpense.energy
end
function Subtract(expense, otherExpense, cap)
    expense.metal = expense.metal - otherExpense.metal
    expense.energy = expense.energy - otherExpense.energy
end
function Multiply(expense, number)
    expense.metal = expense.metal * number
    expense.energy = expense.energy * number
end
function Divide(expense, number)
    expense.metal = expense.metal / number
    expense.energy = expense.energy / number
end

function BuildTarget(unitID)
    local newTarget = {}
    newTarget.unitDef = UnitDef(unitID)
    
    return newTarget
end

function MinExpense(expense1, expense2)
    return Expense(min(expense1.metal, expense2.metal), min(expense1.energy, expense2.energy))
end

function IdealExpense(buildTarget, builder)
    local cached = idealExpenses[builder.unitDef][buildTarget]
    if cached then
        return cached
    end
    local idealExpense = Expense(buildTarget.unitDef.metalCost, buildTarget.unitDef.energyCost)
    local rate = builder.unitDef.buildSpeed / buildTarget.unitDef.buildTime
    Multiply(idealExpense, rate)
    idealExpenses[builder.unitDef][buildTarget] = idealExpense
    return idealExpense
end

-- MARK: Helpers

function Clamp(number, lowerBound, upperBound)
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

function gadget:GameFrame(n)
    for teamID,team in pairs(teams) do

        local passiveConstructorExpense = Expense(0, 0)
        local remainingExpense = GetResources(teamID)

        for builderID,builder in pairs(team.builders) do
            if not spValidUnitID(builderID) then
                team.builders[builderID] = nil
                Spring.Echo(builderID .. " was not a valid builder!")
                break
            end

            local targetID = spGetUnitIsBuilding(builderID)
            if not targetID then break end
            local target = targets[targetID]
            if not target then
                target = BuildTarget(targetID)
                targets[targetID] = target
            end
            local builderExpense = IdealExpense(target, builder)
            if builder.isPassive then
                spSetUnitBuildSpeed(builderID, builder.unitDef.buildSpeed * passiveConstructorSpeedFactor)
                Add(passiveConstructorExpense, builderExpense)
            else
                Subtract(remainingExpense, builderExpense)
            end
        end
        
        -- Calculate how much passive builders must be slowed by; this will be applied next frame (for performance reasons)

        passiveConstructorSpeedFactor = min(remainingExpense.metal / passiveConstructorExpense.metal, remainingExpense.energy / passiveConstructorExpense.energy)
        passiveConstructorSpeedFactor = Clamp(passiveConstructorSpeedFactor, 0, 1)
    end
end