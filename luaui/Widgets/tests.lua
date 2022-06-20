function widget:GetInfo()
	return {
		name	= "Tests",
		desc	= "Provides commands for running tests",
		author	= "MasterBel2",
		date	= "June 2022",
        version = 1,
		layer	= 0,
		enabled	= false
	}
end

local wordPattern = "[^%s]+"
local pathPattern = "[^%s:]+"


local function ForAllFiles(fileTree, action)
    for fileName, table in pairs(fileTree) do

        if not type(table) == "table" then break end -- Let people put functions in there - like this one!

        if table.type == "file" then
            action(fileName)
        elseif table.type == "subDir" then
            ForAllFiles(table.fileTree, action)
        end
    end
end
local function FileTree(directoryName)
    local files = {}

    for _, fileName in ipairs(VFS.DirList(directoryName), "*", VFS.RAW_FIRST) do
        files[fileName] = {
            type = "file"
        }
    end
    for _, subDir in ipairs(VFS.SubDirs(directoryName), "*", VFS.RAW_FIRST) do
        Spring.Echo("subDir: " .. subDir)
        files[subDir] = {
            type = "subDir",
            fileTree = FileTree(directoryName .. subDir)
        }
    end

    return files
end

local function TestFileTree(luaEnvDirectoryName)
    return FileTree(luaEnvDirectoryName .. "tests")
end

local function TestsInFile(path)
    Spring.Echo("Loading test file: " .. path)

    local testFile = VFS.LoadFile(path)
    local chunk, _error = loadstring(testFile)

    if not chunk or _error then
        Spring.Echo("Failed to compile test file: " .. path .. " - " .. _error)
        return
    end

    local testEnvironment = {
        error = error,
        Spring = {
            Echo = Spring.Echo
        },
        VFS = VFS
    }
    testEnvironment.testEnvironment = testEnvironment
    setfenv(chunk, testEnvironment)
    local resultSuccess, resultValue = pcall(chunk)
    
    if not resultSuccess then
        Spring.Echo("Failed to call test file: " .. fileName .." - " .. resultValue)
        return
    end

    return resultValue
end

local function RunTests(testSet)
    Spring.Echo("Loading target file: " .. testSet.targetFileName)
    local targetFile = VFS.LoadFile(testSet.targetFileName)

    targetFileLocalVariableDecoder = targetFile .. [[
        local i = 1
        while true do
            local name, _ = debug.getlocal(1, i)
            if not name then break end

            local _i = i

            table.insert(targetFileEnvironment.localVariableRegister, name)

            i = i + 1
        end
    ]]

    local chunk, _error = loadstring(targetFileLocalVariableDecoder)

    if not chunk or _error then
        Spring.Echo("Failed to compile target file: " .. fileName .. _error)
        return
    end

    local targetFileEnvironment = {
        gadget = {},
        widget = {},
        debug = debug,
        math = math,
        table = table,
        string = string,
        error = function(...) error(...) end,
        Spring = Spring,

        localVariableRegister = {}
    }
    targetFileEnvironment.targetFileEnvironment = targetFileEnvironment

    setfenv(chunk, targetFileEnvironment)
    local resultSuccess, _error = pcall(chunk)

    if not resultSuccess then
        Spring.Echo("Failed to generate local variables for target file: " .. fileName .. _error)
        return
    end

    local localVariableCaptureInjection = ""
    for _, localVariableName in ipairs(targetFileEnvironment.localVariableRegister) do
        local newString = [[
            function getLocal_##() return ## end
            function setLocal_##(newValue) ## = newValue end
            function callLocal_##(...) return ##(...) end
        ]]

        localVariableCaptureInjection = localVariableCaptureInjection .. newString:gsub("##", localVariableName)
    end

    targetFileEnvironment.localVariableRegister = nil

    for key, value in pairs(testSet) do
        if key:sub(1, 4) == "test" and type(value) == "function" then
            Spring.Echo("Loading test: " .. key)

            local chunk, _error = loadstring(targetFile .. localVariableCaptureInjection)

            if not chunk or _error then
                Spring.Echo("Failed to compile target file: " .. fileName .. _error)
                return -- we'll return instead of breaking here, because if the file failed to load for this test, it's gonna fail to load for all tests relying on this file
            end

            setfenv(chunk, targetFileEnvironment)
            local resultSuccess, _error = pcall(chunk)

            if not resultSuccess then
                Spring.Echo("Failed to pre-load target file: " .. fileName .. _error)
                return -- we'll return instead of breaking here, because if the file failed to load for this test, it's gonna fail to load for all tests relying on this file
            end

            Spring.Echo("Starting test: " .. key)

            local startTimer = Spring.GetTimer()
            local succeeded, _error = pcall(value, targetFileEnvironment)
            local duration = Spring.DiffTimers(Spring.GetTimer(), startTimer)
            
            if not succeeded then
                if type(_error) == "string" then
                    Spring.Echo("Test failed! (Duration " .. duration .. "s) " .. key .. _error)
                else
                    Spring.Echo("Test failed! (Duration " .. duration .. "s) No description available")
                end
                break
            end

            Spring.Echo("Test succeeded! Duration: " .. duration .. " s")
        end
    end
end


local function RunAllTestsInFile(path)
    local testsInFile = TestsInFile(path)
    if testsInFile then
        RunTests(testsInFile)
    else
        Spring.Echo("Failed to load tests from " .. path)
    end
end

function widget:TextCommand(command)
    local start, _end = command:find(wordPattern)
    if not start or not _end then return end
    local commandName = command:sub(start, _end)
    
    if commandName ~= "test" then return false end
    Spring.Echo(command:sub(_end + 2))

    start, _end = command:find(pathPattern, _end + 2)
    if start and _end then
        local path = command:sub(start, _end)
        if VFS.FileExists(path) then

            local tests = TestsInFile(path)
            if not tests then
                Spring.Echo("Could not load tests from " .. path)
                return
            end

            local start, _end = command:find(wordPattern, _end + 2)
            if start and _end then
                local testName = command:sub(start, _end)

                local test = tests[testName]
                if not test then
                    Spring.Echo("Could not find test \"" .. testName .. "\" in file ")
                end

                RunTests({ targetFileName = tests.targetFileName, [testName] = test })
            else
                RunTests(tests)
            end
        elseif #VFS.DirList(path) > 0 or #VFS.SubDirs(path) > 0 then
            ForAllFiles(FileTree(path), RunAllTestsInFile)
        else
            Spring.Echo("Could not find any test files at " .. path)
        end
    else
        Spring.Echo("Running all tests in " .. LUAUI_DIRNAME .. "widgets/tests/")
        ForAllFiles(TestFileTree(LUAUI_DIRNAME .. "widgets/"), RunAllTestsInFile)
        ForAllFiles(TestFileTree("luarules/gadgets/"), RunAllTestsInFile)
        ForAllFiles(TestFileTree("luaintro/"), RunAllTestsInFile)
    end

    return true
end