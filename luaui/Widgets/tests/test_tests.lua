return {
    targetFileName = "widgets/tests.lua",
    test_pattern = function(widget)
        if not (widget.getLocal_pattern() == "[^%s]+") then
            error("Could not access pattern local!")
        end

        Spring.Echo("The pattern is " .. widget.getLocal_pattern())
    end
}