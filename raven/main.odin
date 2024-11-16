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

help :: #load("../help.txt", string)

MEASURE_PERFORMANCE :: #config(MEASURE_PERFORMANCE, false)

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
        print_error(.LUA, "could not allocate (out of memory)")
    case .Invalid_Pointer:
        print_error(.LUA, "could not allocate (invalid pointer)")
    case .Invalid_Argument:
        print_error(.LUA, "could not allocate (invalid argument)")
    case .Mode_Not_Implemented:
        print_error(.LUA, "could not allocate (mode not implemented)")
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

lua_extract_command_parts :: proc "c" (
    state: ^lua.State,
    command_parts: ^[dynamic]string,
    part_index: i32,
) -> (
) {
    context = runtime.default_context()

    part_type := lua.type(state, part_index)

    switch part_type {
    case .NONE, .NIL:
        // Do nothing
    case .NUMBER, .STRING:
        part_as_cstring := lua.tostring(state, part_index)
        part_as_string := string(part_as_cstring)
        append(command_parts, part_as_string)
    case .BOOLEAN:
        part_as_bool := lua.toboolean(state, part_index)
        append(command_parts, part_as_bool ? "true" : "false")
    case .FUNCTION:
        lua.call(state, 0, 1)
        result_index := lua.gettop(state)
        lua_extract_command_parts(state, command_parts, result_index)
        lua.pop(state, 1)
    case .TABLE:
        lua.len(state, part_index)
        subparts_length := lua.tointeger(state, -1)
        lua.pop(state, 1)

        for i in 1..=subparts_length {
            lua.geti(state, part_index, i)
            subpart_index := lua.gettop(state)

            lua_extract_command_parts(state, command_parts, subpart_index)

            lua.remove(state, subpart_index)
        }
    case .USERDATA, .THREAD, .LIGHTUSERDATA:
        part_type_name := lua.typename(state, part_type)
        lua.L_error(state, "bad argument #1 (command) for run: invalid command subcomponent of type %s", part_type_name)
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

    command_parts := make([dynamic]string)
    defer delete(command_parts)

    lua_extract_command_parts(state, &command_parts, 1)

    if len(command_parts) == 0 {
        lua.L_error(state, "bad argument #1 (command) for run: command is empty")
        return 0
    }

    {
        printable_process_name := strings.join(command_parts[:], " ")
        defer delete(printable_process_name)

        print_msg(.RAVEN, "Running %s%s%s", COLOR_IDENTIFIER, printable_process_name, COLOR_RESET)
    }

    process_exit_code, process_output, process_error_output, process_ok := run(command_parts[:])

    if !process_ok {
        lua.pushboolean(state, false)
        return 1
    }

    if process_exit_code == 0 {
        print_msg(.RAVEN, "%sSuccess%s", COLOR_SUCCESS, COLOR_RESET)
    } else {
        print_msg(.RAVEN, "%sFailure (code Hex %X, Dec %d)%s", COLOR_ERROR, process_exit_code, process_exit_code, COLOR_RESET)
    }

    lua.pushboolean(state, true)
    lua.createtable(state, 0, 4)
    lua.pushinteger(state, lua.Integer(process_exit_code))
    lua.setfield(state, -2, "exit_code")
    lua.pushlstring(state, cstring(raw_data(process_output)), len(process_output))
    lua.setfield(state, -2, "output")
    lua.pushlstring(state, cstring(raw_data(process_error_output)), len(process_error_output))
    lua.setfield(state, -2, "error_output")

    delete(process_output)
    delete(process_error_output)

    return 2
}

main :: proc(
) -> (
) {
    when MEASURE_PERFORMANCE {
        total_duration_milliseconds: f64 = 0.0
        base_time := time.now()
    }

    when MEASURE_PERFORMANCE {
        file_verification_duration := time.duration_milliseconds(time.since(base_time))
        fmt.printfln("Verifying if ravenfile.lua exists took %fms.", file_verification_duration)
        total_duration_milliseconds += file_verification_duration
        base_time = time.now()
    }

    command_args: []string
    list_commands := false
    ravenfile_path := "ravenfile.lua"
    display_help := false

    if len(os.args) > 1 {
        command_section_start := 1

        for arg, i in os.args[1:] {
            if !strings.starts_with(arg, "-") {
                break
            }

            if arg == "-list" {
                list_commands = true
            } else if arg == "-help" {
                display_help = true
            } else if strings.starts_with(arg, "-use=") {
                if len(arg) < (len("-use=") + 1) {
                    print_error(.RAVEN, "missing value for option %suse%s", COLOR_IDENTIFIER, COLOR_RESET)
                    return
                }

                ravenfile_path = arg[len("-use="):]
            } else {
                print_error(.RAVEN, "could not handle option %s%s%s (unknown option)", COLOR_IDENTIFIER, arg, COLOR_RESET)
                return
            }

            command_section_start += 1
        }

        if command_section_start < len(os.args) {
            command_args = os.args[command_section_start:]
        }
    }

    if display_help {
        fmt.print(help)
        return
    }

    if !os.exists(ravenfile_path) {
        print_error(.RAVEN, "could not find ravenfile at %s%s%s", COLOR_PATH, ravenfile_path, COLOR_RESET)
        return
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

    lua.newtable(state)
    lua.setfield(state, raven_table_index, "commands")

    if !list_commands {
        lua.pushcfunction(state, lua_raven_run)
        lua.setfield(state, raven_table_index, "run")

        lua.pushcfunction(state, lua_raven_demand_argument_amount)
        lua.setfield(state, raven_table_index, "demand_argument_amount")

        lua.createtable(state, i32(len(os.args) - 2), 0)

        if len(command_args) > 1 {
            for arg, i in command_args[1:] {
                lua.pushlstring(state, cstring(raw_data(arg)), len(arg))
                lua.seti(state, -2, lua.Integer(i + 1))
            }
        }

        lua.setfield(state, raven_table_index, "args")
    }

    lua.setglobal(state, "raven")

    when MEASURE_PERFORMANCE {
        raven_setup_duration := time.duration_milliseconds(time.since(base_time))
        fmt.printfln("Setting up raven table took %fms.", raven_setup_duration)
        total_duration_milliseconds += raven_setup_duration
        base_time = time.now()
    }

    {
        ravenfile_path_cstr := strings.clone_to_cstring(ravenfile_path)
        defer delete(ravenfile_path_cstr)

        #partial switch lua.L_loadfile(state, ravenfile_path_cstr) {
        case .OK:
            // Do nothing
        case .ERRRUN:
            print_error(.LUA, "could not load ravenfile (runtime error)")
            return
        case .ERRMEM:
            print_error(.LUA, "could not load ravenfile (memory error)")
            return
        case .ERRERR:
            print_error(.LUA, "could not load ravenfile (message handler error)")
            return
        case .ERRSYNTAX:
            print_error(.LUA, "could not load ravenfile (syntax error)")
            return
        case .ERRFILE:
            print_error(.LUA, "could not load ravenfile (could not open or find file)")
            return
        }
    }

    lua.call(state, 0, 0)

    when MEASURE_PERFORMANCE {
        ravenfile_execution_duration := time.duration_milliseconds(time.since(base_time))
        fmt.printfln("Running ravenfile.lua took %fms.", ravenfile_execution_duration)
        total_duration_milliseconds += ravenfile_execution_duration
        base_time = time.now()
    }

    if list_commands {
        lua.getglobal(state, "raven")
        lua.getfield(state, -1, "commands")
        commands_index := lua.gettop(state)

        print_msg(.RAVEN, "Commands in ravenfile:")

        lua.pushnil(state)
        for lua.next(state, commands_index) != 0 {
            lua.pushvalue(state, -2)
            command_name := lua.tostring(state, -1)
            lua.pop(state, 2)
            fmt.printfln("- %s%s%s", COLOR_IDENTIFIER, command_name, COLOR_RESET)
        }
    } else if command_args != nil {
        {
            lua.getglobal(state, "raven")
            raven_index := lua.gettop(state)
            defer lua.remove(state, raven_index)

            lua.getfield(state, -1, "commands")
            raven_commands_index := lua.gettop(state)
            defer lua.remove(state, raven_commands_index)

            command_name_cstr := strings.clone_to_cstring(command_args[0])
            defer delete(command_name_cstr)

            lua.getfield(state, raven_commands_index, command_name_cstr)
        }

        if lua.type(state, -1) != .FUNCTION {
            print_error(.RAVEN, "could not find command %s\"%s\"%s", COLOR_IDENTIFIER, command_args[0], COLOR_RESET)
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
