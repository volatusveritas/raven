local PROGRAM_NAME = 'raven'
local BUILD_PATH = 'build'

run(string.format(
    "odin build %s -out:%s/%s.exe",
    PROGRAM_NAME,
    BUILD_PATH,
    PROGRAM_NAME
))
