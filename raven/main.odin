package raven

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

import lua "vendor:lua/5.4"

error :: proc(msg: string, args: ..any) {
    full_msg := (len(args) > 0) ? fmt.aprintf(msg, args) : msg
    defer delete(full_msg)

    fmt.eprintf("Error: %s.", full_msg)
}

lua_expect_argument_amount :: proc "c" (state: ^lua.State, amount: i32, method_name: string) -> bool {
    args_amount := lua.gettop(state)

    if args_amount < amount {
        lua.L_error(state, "bad argument #%d to '%s' (value expected)", args_amount + 1, method_name)
        return false
    }

    return true
}

lua_expect_string_strict :: proc "c" (state: ^lua.State, index: i32, method_name: string) -> bool {
    if lua.isnumber(state, index) || !lua.isstring(state, index) {
        lua.L_error(state, "bad argument #%d to '%s' (string expected)", index, method_name)
        return false
    }

    return true
}

lua_expect_not_empty :: proc "c" (state: ^lua.State, index: i32, method_name: string) -> bool {
    if lua.L_len(state, index) == 0 {
        lua.L_error(state, "bad argument #%d to '%s' (empty value)", index, method_name)
        return false
    }

    return true
}

lua_run :: proc "c" (state: ^lua.State) -> i32 {
    context = runtime.default_context()

    if !lua_expect_argument_amount(state, 1, "run") do return 0
    if !lua_expect_string_strict(state, 1, "run") do return 0
    if !lua_expect_not_empty(state, 1, "run") do return 0

    spawn_and_run_process(string(lua.tostring(state, 1)))

    return 0
}

lua_runf :: proc "c" (state: ^lua.State) -> i32 {
    args_amount := lua.gettop(state)

    if !lua_expect_argument_amount(state, 1, "runf") do return 0
    if !lua_expect_string_strict(state, 1, "runf") do return 0
    if !lua_expect_not_empty(state, 1, "runf") do return 0

    lua.getglobal(state, "string")
    lua.getfield(state, -1, "format")
    lua.remove(state, -2)
    lua.rotate(state, 1, 1)
    lua.call(state, args_amount, 1)

    lua_run(state)

    return 0
}

lua_atpanic :: proc "c" (state: ^lua.State) -> i32 {
    context = runtime.default_context()

    switch lua.type(state, -1) {
    case .NONE, .NIL:
        error("[Lua] unknown error")
    case .BOOLEAN:
        error("[Lua] %t", lua.toboolean(state, -1))
    case .NUMBER:
        error("[Lua] %f", f64(lua.tonumber(state, -1)))
    case .STRING:
        error("[Lua] %s", lua.tostring(state, -1))
    case .LIGHTUSERDATA:
        error("[Lua] light userdata <%v>", lua.topointer(state, -1))
    case .USERDATA:
        error("[Lua] userdata <%v>", lua.topointer(state, -1))
    case .TABLE:
        error("[Lua] table <%v>", lua.topointer(state, -1))
    case .THREAD:
        error("[Lua] thread <%v>", lua.topointer(state, -1))
    case .FUNCTION:
        error("[Lua] function <%v>", lua.topointer(state, -1))
    }

    return 0
}

lua_allocation_function :: proc "c" (ud, ptr: rawptr, old_size, new_size: uint) -> rawptr {
    context = runtime.default_context()

    if new_size == 0 {
        mem.free(ptr)
        return nil
    }

    new_ptr, resize_err := mem.resize(ptr, (ptr == nil) ? 0 : int(old_size), int(new_size))

    if resize_err != .None {
        error("Lua allocation error (%v)", resize_err)
        return nil
    }

    return new_ptr
}

start_lua_environment :: proc() -> ^lua.State {
    state := lua.newstate(lua_allocation_function, nil)

    if state == nil {
        error("unable to create Lua state due to insufficient memory")
        return nil
    }

    lua.atpanic(state, lua_atpanic)
    lua.L_openlibs(state)

    // Expose global functions
    lua.pushcfunction(state, lua_run)
    lua.setglobal(state, "run")

    lua.pushcfunction(state, lua_runf)
    lua.setglobal(state, "runf")

    // Explose global cmd table
    lua.newtable(state)
    lua.setglobal(state, "cmd")

    // Explose the args table
    lua.createtable(state, i32(len(os.args) - 2), 0)

    if len(os.args) > 2 {
        for arg, i in os.args[2:] {
            lua.pushstring(state, strings.clone_to_cstring(arg))
            lua.seti(state, -2, lua.Integer(i + 1))
        }
    }

    lua.setglobal(state, "args")

    return state
}

main :: proc() {
    lua_state := start_lua_environment()

    if lua_state == nil {
        return
    }

    // Execute the ravenfile
    lua.L_loadfile(lua_state, "ravenfile.lua")
    lua.call(lua_state, 0, 0)

    if len(os.args) > 1 {
        // Attempt to call the subcommand
        lua.getglobal(lua_state, "cmd")
        lua.getfield(lua_state, -1, strings.clone_to_cstring(os.args[1]))
        lua.remove(lua_state, -2)
        lua.getglobal(lua_state, "args")
        lua.call(lua_state, 1, 0)
    }
}
