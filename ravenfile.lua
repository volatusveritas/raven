local PROGRAM_NAME = 'raven'
local BUILD_PATH = 'build'

runf(
    "odin build %s -out:%s/%s_test.exe",
    PROGRAM_NAME,
    BUILD_PATH,
    PROGRAM_NAME
)

function cmd.testfunc(args)
    print("Test function called with")

    for _, arg in ipairs(args) do
        print(arg)
    end
end
