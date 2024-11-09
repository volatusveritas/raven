package raven

import "base:runtime"
import "core:encoding/ansi"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "core:c/libc"

import lua "vendor:lua/5.4"

MEASURE_PERFORMANCE :: #config(MEASURE_PERFORMANCE, false)

ContextType :: enum {
    RAVEN,
    LUA,
}

message_context_get_name :: proc(
    context_type: ContextType,
) -> (
    context_name: string
) {
    switch context_type {
    case .RAVEN:
        return "Raven"
    case .LUA:
        return "Lua"
    case:
        return "Unknown"
    }
}

print_msg :: proc(
    message_context: ContextType,
    message: string,
    args: ..any,
) -> (
) {
    context_name := message_context_get_name(message_context)

    formatted_message := fmt.aprintf(message, ..args)
    defer delete(formatted_message)

    fmt.printfln(
        "%s(%s) %s%s",
        (ansi.CSI + ansi.FG_BRIGHT_YELLOW + ansi.SGR),
        context_name,
        (ansi.CSI + ansi.RESET + ansi.SGR),
        formatted_message,
    )
}

print_error :: proc(
    error_context: ContextType,
    message: string,
    args: ..any,
) -> (
) {
    error_context_name := message_context_get_name(error_context)

    formatted_error_message := fmt.aprintf(message, ..args)
    defer delete(formatted_error_message)

    fmt.eprintfln(
        "%s(%s) %sError %s:: %s%s%s",
        (ansi.CSI + ansi.FG_BRIGHT_YELLOW + ansi.SGR),
        error_context_name,
        (ansi.CSI + ansi.FG_BRIGHT_RED + ansi.SGR),
        (ansi.CSI + ansi.RESET + ansi.SGR),
        (ansi.CSI + ansi.FG_BRIGHT_RED + ansi.SGR),
        formatted_error_message,
        (ansi.CSI + ansi.RESET + ansi.SGR),
    )
}

lua_print_stack :: proc "c" (
    state: ^lua.State,
) -> (
) {
    stack_length := lua.gettop(state)

    context = runtime.default_context()

    for i in 1..=stack_length {
        fmt.printf("- %d (%s) ", i, lua.L_typename(state, i))
        #partial switch lua.type(state, i) {
        case .NUMBER:
            fmt.printf("%d\n", lua.tonumber(state, i))
        case .STRING:
            fmt.printf("%s\n", lua.tostring(state, i))
        case .BOOLEAN:
            fmt.printf("%t\n", lua.toboolean(state, i) ? "true" : "false")
        case .NIL:
            fmt.print("nil\n")
        case:
            fmt.printf("<%v>\n", lua.topointer(state, i))
        }
    }
}

lua_allocation_function :: proc "c" (
    user_data: rawptr,
    ptr: rawptr,
    old_size: uint,
    new_size: uint,
) -> (
    new_pointer: rawptr,
) {
    context = runtime.default_context()

    resize_err: runtime.Allocator_Error
    new_pointer, resize_err = mem.resize(ptr, int(old_size), int(new_size))

    switch resize_err {
    case .None:
        // Do nothing
    case .Out_Of_Memory:
        print_error(.LUA, "allocation error (out of memory)")
    case .Invalid_Pointer:
        print_error(.LUA, "allocation error (invalid pointer)")
    case .Invalid_Argument:
        print_error(.LUA, "allocation error (invalid argument)")
    case .Mode_Not_Implemented:
        print_error(.LUA, "allocation error (mode not implemented)")
    }

    return new_pointer
}

lua_atpanic :: proc "c" (
    state: ^lua.State,
) -> (
    result_count: i32,
) {
    context = runtime.default_context()

    switch lua.type(state, -1) {
    case .NONE, .NIL:
        print_error(.LUA, "nil")
    case .BOOLEAN:
        print_error(.LUA, "%t", lua.toboolean(state, -1))
    case .NUMBER:
        print_error(.LUA, "%f", f64(lua.tonumber(state, -1)))
    case .STRING:
        print_error(.LUA, "%s", lua.tostring(state, -1))
    case .LIGHTUSERDATA:
        print_error(.LUA, "light userdata <%v>", lua.topointer(state, -1))
    case .USERDATA:
        print_error(.LUA, "userdata <%v>", lua.topointer(state, -1))
    case .TABLE:
        print_error(.LUA, "table <%v>", lua.topointer(state, -1))
    case .THREAD:
        print_error(.LUA, "thread <%v>", lua.topointer(state, -1))
    case .FUNCTION:
        print_error(.LUA, "function <%v>", lua.topointer(state, -1))
    case:
        print_error(.LUA, "unknown")
    }

    return 0
}

lua_raven_demand_argument_amount :: proc "c" (
    state: ^lua.State,
) -> (
    result_count: i32,
) {
    argument_amount := lua.gettop(state)

    if argument_amount < 1 {
        lua.L_error(state, "missing argument #1 for demand_argument_amount: amount (number)")
        return 0
    }

    argument_1_type := lua.type(state, 1)

    if argument_1_type != .NUMBER {
        argument_1_type_name := lua.typename(state, argument_1_type)
        lua.L_error(state, "bad argument #1 (amount) for demand_argument_amount: expected number, got %s", argument_1_type_name)
        return 0
    }

    if !lua.isinteger(state, 1) {
        argument_1_float := lua.tonumber(state, 1)
        lua.L_error(state, "bad argument #1 (amount) for demand_argument_amount: expected integer, got float (%d)", argument_1_float)
        return 0
    }

    target_amount := lua.tointeger(state, 1)

    lua.getglobal(state, "raven")
    lua.getfield(state, -1, "args")
    lua.len(state, -1)
    args_length := lua.tointeger(state, -1)
    lua.pop(state, 3)

    if args_length < target_amount {
        missing_argument_amount := target_amount - args_length
        lua.L_error(state, "missing %d arguments for demand_argument_amount", missing_argument_amount)
    }

    return 0
}

lua_collect_command_part :: proc "c" (
    state: ^lua.State,
    command_parts: ^[dynamic]cstring,
    part_index: i32,
    part_type: lua.Type,
) -> (
) {
    context = runtime.default_context()

    switch part_type {
    case .NONE, .NIL:
        // Do nothing
    case .NUMBER, .STRING:
        part_as_string := lua.tostring(state, part_index)
        append(command_parts, part_as_string)
    case .BOOLEAN:
        part_as_bool := lua.toboolean(state, part_index)
        append(command_parts, part_as_bool ? "true" : "false")
    case .FUNCTION:
        lua.call(state, 0, 1)
        result_index := lua.gettop(state)
        result_type := lua.type(state, result_index)
        lua_collect_command_part(state, command_parts, result_index, result_type)
        lua.pop(state, 1)
    case .TABLE:
        lua_collect_command_parts_from_table(state, command_parts, part_index)
    case .USERDATA, .THREAD, .LIGHTUSERDATA:
        part_type_name := lua.typename(state, part_type)
        lua.L_error(state, "bad argument #1 (command) for run: invalid command subcomponent of type %s", part_type_name)
    }
}

lua_collect_command_parts_from_table :: proc "c" (
    state: ^lua.State,
    command_parts: ^[dynamic]cstring,
    parts_index: i32,
) -> (
) {
    lua.len(state, parts_index)
    parts_length := lua.tointeger(state, -1)
    lua.pop(state, 1)

    for i in 0..<parts_length {
        part_type := lua.Type(lua.geti(state, parts_index, i + 1))
        part_index := lua.gettop(state)

        lua_collect_command_part(state, command_parts, part_index, part_type)

        lua.remove(state, part_index)
    }
}

lua_raven_run :: proc "c" (
    state: ^lua.State,
) -> (
    result_count: i32,
) {
    context = runtime.default_context()

    argument_amount := lua.gettop(state)

    if argument_amount < 1 {
        lua.L_error(state, "missing argument #1 for run: command (table)")
        return 0
    }

    argument_1_type := lua.type(state, 1)

    if argument_1_type != .TABLE {
        argument_1_type_name := lua.typename(state, argument_1_type)
        lua.L_error(state, "bad argument #1 (command) for run: expected table, got %s", argument_1_type_name)
        return 0
    }

    command_parts := make([dynamic]cstring)
    defer delete(command_parts)

    lua_collect_command_parts_from_table(state, &command_parts, 1)

    if len(command_parts) == 0 {
        lua.L_error(state, "bad argument #1 (command) for run: command is empty")
        return 0
    }

    print_msg(.RAVEN, "Running process %v", command_parts)

    // spawn_and_run_process(command_parts[:])

    return 0
}

main :: proc(
) -> (
) {
    when MEASURE_PERFORMANCE {
        total_duration_milliseconds: f64 = 0.0
        base_time := time.now()
    }

    if !os.exists("ravenfile.lua") {
        fmt.eprintln("Error (Raven): ravenfile.lua not found")
        return
    }

    when MEASURE_PERFORMANCE {
        file_verification_duration := time.duration_milliseconds(time.since(base_time))
        fmt.printfln("Verifying if ravenfile.lua exists took %fms.", file_verification_duration)
        total_duration_milliseconds += file_verification_duration
        base_time = time.now()
    }

    state := lua.newstate(lua_allocation_function, nil)

    if state == nil {
        fmt.eprintln("Error (Lua): unable to create Lua state, insufficient memory")
        return
    }

    when MEASURE_PERFORMANCE {
        lua_state_creation_duration := time.duration_milliseconds(time.since(base_time))
        fmt.printfln("Initializing Lua state took %fms.", lua_state_creation_duration)
        total_duration_milliseconds += lua_state_creation_duration
        base_time = time.now()
    }

    lua.atpanic(state, lua_atpanic)

    lua.L_openlibs(state)

    when MEASURE_PERFORMANCE {
        lua_environment_setup_duration := time.duration_milliseconds(time.since(base_time))
        fmt.printfln("Setting up Lua environment (initializing base libs, etc.) took %fms.", lua_environment_setup_duration)
        total_duration_milliseconds += lua_environment_setup_duration
        base_time = time.now()
    }

    lua.newtable(state)
    raven_table_index := lua.gettop(state)

    lua.pushcfunction(state, lua_raven_run)
    lua.setfield(state, raven_table_index, "run")

    lua.pushcfunction(state, lua_raven_demand_argument_amount)
    lua.setfield(state, raven_table_index, "demand_argument_amount")

    lua.createtable(state, i32(len(os.args) - 2), 0)

    if len(os.args) > 2 {
        for arg, i in os.args[2:] {
            lua.pushstring(state, strings.clone_to_cstring(arg))
            lua.seti(state, -2, lua.Integer(i + 1))
        }
    }

    lua.setfield(state, raven_table_index, "args")

    lua.setglobal(state, "raven")

    lua.newtable(state)
    lua.setglobal(state, "command")

    when MEASURE_PERFORMANCE {
        raven_setup_duration := time.duration_milliseconds(time.since(base_time))
        fmt.printfln("Setting up Raven environment (raven, raven.args, command) took %fms.", raven_setup_duration)
        total_duration_milliseconds += raven_setup_duration
        base_time = time.now()
    }

    switch lua.L_loadfile(state, "ravenfile.lua") {
    case .OK:
        // Do nothing
    case .ERRRUN:
        print_error(.LUA, "error while loading ravenfile.lua: runtime error")
        return
    case .ERRMEM:
        print_error(.LUA, "error while loading ravenfile.lua: memory error")
        return
    case .ERRERR:
        print_error(.LUA, "error while loading ravenfile.lua: message handler error")
        return
    case .ERRSYNTAX:
        print_error(.LUA, "error while loading ravenfile.lua: syntax error")
        return
    case .YIELD:
        print_error(.LUA, "error while loading ravenfile.lua: execution context yielded")
        return
    case .ERRFILE:
        print_error(.LUA, "error while loading ravenfile.lua: could not open or find file")
        return
    }

    lua.call(state, 0, 0)

    when MEASURE_PERFORMANCE {
        ravenfile_execution_duration := time.duration_milliseconds(time.since(base_time))
        fmt.printfln("Running ravenfile.lua took %fms.", ravenfile_execution_duration)
        total_duration_milliseconds += ravenfile_execution_duration
        base_time = time.now()
    }

    if len(os.args) > 1 {
        lua.getglobal(state, "command")
        command_index := lua.gettop(state)
        lua.getfield(state, command_index, strings.clone_to_cstring(os.args[1]))
        lua.remove(state, command_index)
        command_field_index := lua.gettop(state)

        if lua.type(state, command_field_index) != .FUNCTION {
            print_error(.RAVEN, "command not found (%s)", os.args[1])
            return
        }

        lua.call(state, 0, 0)

        when MEASURE_PERFORMANCE {
            issued_command_duration := time.duration_milliseconds(time.since(base_time))
            fmt.printfln("Running issued command took %fms.", issued_command_duration)
            total_duration_milliseconds += issued_command_duration
            base_time = time.now()
        }
    }

    when MEASURE_PERFORMANCE {
        fmt.printfln("Raven took %fms to run.", total_duration_milliseconds)
    }
}
