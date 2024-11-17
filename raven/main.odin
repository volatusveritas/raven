package raven

import "base:runtime"
import "core:c/libc"
import "core:encoding/ansi"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:os/os2"
import "core:strings"
import "core:time"

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

extract_value_parts :: proc(
    state: ^lua.State,
    value_index: i32,
    value_parts: ^[dynamic]string,
) -> (
) {
    value_type := lua.type(state, value_index)

    switch value_type {
    case .NONE, .NIL:
        // Do nothing
    case .NUMBER, .STRING:
        value_as_cstring := lua.tostring(state, value_index)
        value_as_string := string(value_as_cstring)
        append(value_parts, value_as_string)
    case .BOOLEAN:
        value_as_bool := lua.toboolean(state, value_index)
        append(value_parts, value_as_bool ? "true" : "false")
    case .FUNCTION:
        lua.call(state, 0, 1)
        result_index := lua.gettop(state)
        extract_value_parts(state, result_index, value_parts)
        lua.pop(state, 1)
    case .TABLE:
        lua.len(state, value_index)
        subparts_length := lua.tointeger(state, -1)
        lua.pop(state, 1)

        for i in 1..=subparts_length {
            lua.geti(state, value_index, i)
            subvalue_index := lua.gettop(state)

            extract_value_parts(state, subvalue_index, value_parts)

            lua.remove(state, subvalue_index)
        }
    case .USERDATA, .THREAD, .LIGHTUSERDATA:
        value_type_name := lua.typename(state, value_type)
        lua.L_error(state, "bad argument #1 (command) for run: invalid command subcomponent of type %s", value_type_name)
    }
}

expand_value :: proc(
    state: ^lua.State,
    value_index: i32,
) -> (
    value_parts: [dynamic]string,
    ok: bool,
) {
    value_type := lua.type(state, value_index)
    #partial switch value_type {
    case .STRING:
        value_length: uint
        value_as_cstring := lua.tolstring(state, value_index, &value_length)
        value_as_bytes := (transmute([^]byte)value_as_cstring)[:value_length]
        value_as_string := transmute(string)value_as_bytes
        parts, alloc_err := strings.split(value_as_string, " ")
        defer delete(parts)

        if alloc_err != .None {
            print_error(.RAVEN, "could not allocate space for parts while expanding value")
            return nil, false
        }

        value_parts = make([dynamic]string, 0, len(parts))

        for part in parts {
            append(&value_parts, part)
        }
    case .TABLE:
        extract_value_parts(state, value_index, &value_parts)
    case:
        print_error(.RAVEN, "invalid type provided to expand_value (expected string or table, got %s)", lua.typename(state, value_type))
        return nil, false
    }

    return value_parts, true
}

lua_raven_run :: proc "c" (
    state: ^lua.State,
) -> (
    result_count: i32,
) {
    context = runtime.default_context()

    error_message: cstring
    error_arg: any

    defer if error_message != nil {
        lua.L_error(state, error_message, error_arg)
    }

    argument_amount := lua.gettop(state)

    if argument_amount < 1 {
        error_message = "missing argument #1 for run: command (table)"
        return
    }

    argument1_type := lua.type(state, 1)

    if argument1_type != .TABLE && argument1_type != .STRING {
        error_message = "bad argument #1 (command) for run: expected \"string expandable\", got \"%s\""
        error_arg = lua.typename(state, argument1_type)
        return
    }

    command_parts, expand_ok := expand_value(state, 1)

    if !expand_ok {
        return 0
    }

    defer delete(command_parts)

    if len(command_parts) == 0 {
        error_message = "bad argument #1 (command) for run: command is empty"
        return
    }

    {
        printable_process_name: string

        if argument1_type == .TABLE {
            printable_process_name = strings.join(command_parts[:], " ")
        } else {
            command_length: uint
            command_as_cstring := lua.tolstring(state, 1, &command_length)
            command_as_bytes := (transmute([^]byte)command_as_cstring)[:command_length]
            command_as_string := transmute(string)command_as_bytes
            printable_process_name = command_as_string
        }

        defer if argument1_type == .TABLE {
            delete(printable_process_name)
        }

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

lua_raven_older :: proc "c" (
    state: ^lua.State,
) -> (
    result_count: i32,
) {
    context = runtime.default_context()

    error_message: cstring
    error_arg: any

    defer if error_message != nil {
        lua.L_error(state, error_message, error_arg)
    }

    argument_amount := lua.gettop(state)

    if argument_amount < 1 {
        error_message = "missing argument #1 for older: files (string expandable)"
        return
    }

    argument1_type := lua.type(state, 1)

    if argument1_type != .TABLE && argument1_type != .STRING {
        error_message = "bad argument #1 (files) to older: expected \"string expandable\", got \"%s\""
        error_arg = lua.typename(state, argument1_type)
        return
    }

    if argument_amount < 2 {
        error_message = "missing argument #2 for older: others (string expandable)"
        return
    }

    argument2_type := lua.type(state, 2)

    if argument2_type != .TABLE && argument2_type != .STRING {
        error_message = "bad argument #2 (others) to older: expected \"string expandable\", got \"%s\""
        error_arg = lua.typename(state, argument2_type)
        return
    }

    files_parts, files_ok := expand_value(state, 1)

    if !files_ok {
        return 0
    }

    defer delete(files_parts)

    others_parts, others_ok := expand_value(state, 2)

    if !others_ok {
        return 0
    }

    defer delete(others_parts)

    files_modification_times := make([dynamic]time.Time, len(files_parts))
    defer delete(files_modification_times)

    for file_name, i in files_parts {
        file_info, alloc_err := os2.stat(file_name, context.allocator)

        if alloc_err == .Not_Exist {
            files_modification_times[i] = time.Time { _nsec = 0.0 }
        } else if alloc_err != nil {
            error_message = "could not allocate memory for file information (%s)"
            error_arg = file_name
            return
        }

        files_modification_times[i] = file_info.modification_time
    }

    others_modification_times := make([dynamic]time.Time, len(others_parts))
    defer delete(others_modification_times)

    for file_name, i in others_parts {
        file_info, alloc_err := os2.stat(file_name, context.allocator)

        if alloc_err == .Not_Exist {
            others_modification_times[i] = time.Time { _nsec = 0.0 }
        } else if alloc_err != nil {
            error_message = "could not allocate memory for file information (%s)"
            error_arg = file_name
            return
        }

        others_modification_times[i] = file_info.modification_time
    }

    for file_modification_time in files_modification_times {
        for other_modification_time in others_modification_times {
            if time.diff(file_modification_time, other_modification_time) >= 0.0 {
                lua.pushboolean(state, true)
                lua.pushboolean(state, true)
                return 2
            }
        }
    }

    lua.pushboolean(state, false)
    lua.pushboolean(state, true)
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

    lua.pushcfunction(state, lua_raven_run)
    lua.setfield(state, raven_table_index, "run")

    lua.pushcfunction(state, lua_raven_older)
    lua.setfield(state, raven_table_index, "older")

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
