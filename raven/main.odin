package raven

import "base:runtime"
import "core:fmt"

import lua "vendor:lua/5.4"

// NOTE(volatus): This can use better error reporting in general.
// It's very bad. Sorry. :(

// TODO(volatus): attach the process to raven so we can report errors and output.

error :: proc(msg: string, args: ..any) {
    full_msg := (len(args) > 0) ? fmt.aprintf(msg, args) : msg
    defer delete(full_msg)

    fmt.eprintf("Error: %s.", full_msg)
}

run :: proc "c" (state: ^lua.State) -> i32 {
    context = runtime.default_context()

    args_amount := lua.gettop(state)

    if args_amount < 1 {
        lua.L_error(state, "missing argument 'command'")
        return 0
    }

    if !lua.isstring(state, 1) {
        lua.L_error(state, "expected argument 'command' to be a string")
        return 0
    }

    spawn_process(string(lua.tostring(state, 1)))

    return 0
}

main :: proc() {
    lua_state := lua.L_newstate()

    if lua_state == nil {
        error("unable to create Lua state")
        return
    }

    lua.L_openlibs(lua_state)

    // Expose globals
    lua.pushcfunction(lua_state, run)
    lua.setglobal(lua_state, "run")

    // TODO(volatus): runf -> run(string.format(...))

    // Execute ravenfile.lua
    dofile_status := lua.Status(lua.L_dofile(lua_state, "ravenfile.lua"))

    if dofile_status != .OK {
        switch dofile_status {
        case .OK, .YIELD:
            // do nothing
        case .ERRRUN:
            error("runtime error")
        case .ERRMEM:
            error("memory allocation error")
        case .ERRERR:
            error("message handler error")
        case .ERRSYNTAX:
            error("syntax error")
        case .ERRFILE:
            error("file I/O error")
        }

        return
    }
}
