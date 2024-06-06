package raven

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

import lua "vendor:lua/5.4"

error :: proc(msg: string, args: ..any) {
    full_msg := fmt.aprintf(msg, ..args)
    defer delete(full_msg)

    fmt.eprintfln("Error: %s.\n", full_msg)
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

lua_spawn_and_return_process :: proc "c" (state: ^lua.State, cmd: cstring, args: ..cstring) -> i32 {
    context = runtime.default_context()

    success, exit_code, output, error_output := spawn_and_run_process(cmd, ..args)

    lua.createtable(state, 0, 4)

    lua.pushboolean(state, b32(success))
    lua.setfield(state, -2, "success")

    lua.pushinteger(state, lua.Integer(exit_code))
    lua.setfield(state, -2, "exit_code")

    lua.pushstring(state, output)
    lua.setfield(state, -2, "output")

    lua.pushstring(state, error_output)
    lua.setfield(state, -2, "error_output")

    return 1
}

lua_run :: proc "c" (state: ^lua.State) -> i32 {
    if !lua_expect_argument_amount(state, 1, "run") do return 0
    if !lua_expect_string_strict(state, 1, "run") do return 0
    if !lua_expect_not_empty(state, 1, "run") do return 0

    return lua_spawn_and_return_process(state, lua.tostring(state, 1))
}

lua_runf :: proc "c" (state: ^lua.State) -> i32 {
    if !lua_expect_argument_amount(state, 1, "runf") do return 0
    if !lua_expect_string_strict(state, 1, "runf") do return 0
    if !lua_expect_not_empty(state, 1, "runf") do return 0

    args_amount := lua.gettop(state)

    lua.getglobal(state, "string")
    lua.getfield(state, -1, "format")
    lua.remove(state, -2)
    lua.rotate(state, 1, 1)
    lua.call(state, args_amount, 1)

    return lua_spawn_and_return_process(state, lua.tostring(state, 1), nil)
}

lua_runa :: proc "c" (state: ^lua.State) -> i32 {
    if !lua_expect_argument_amount(state, 1, "runa") do return 0

    args_amount := lua.gettop(state)

    for i in 1..=args_amount {
        if !lua_expect_string_strict(state, i, "runa") do return 0
        if !lua_expect_not_empty(state, i, "runa") do return 0
    }

    cmd := lua.tostring(state, 1)

    context = runtime.default_context()

    args := make([]cstring, args_amount - 1)

    if args_amount > 1 {
        for i in 2..=args_amount {
            args[i - 2] = lua.tostring(state, i)
        }
    }

    return lua_spawn_and_return_process(state, cmd, ..args)
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
    case:
        error("[Lua] unknown error")
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

    lua.pushcfunction(state, lua_runa)
    lua.setglobal(state, "runa")

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
