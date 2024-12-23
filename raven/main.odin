package raven

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:os"
import "core:os/os2"
import "core:strings"
import "core:time"
import "core:bufio"

import lua "vendor:lua/5.4"

// TODO(volatus): check for memory leaks using the tracking allocator and fix them

MEASURE_PERFORMANCE :: #config(MEASURE_PERFORMANCE, false)

help :: #load("../help.txt", string)

/* Procedure naming convention

Any CFunction must be preceded by `lua_`.

Any procedure meant to be exported to Lua under the `raven` table must be
preceded by `lua_raven_` (by virtue of also being a Lua CFunction).
*/

Raven_Error :: enum lua.Integer {
    None,
    Permission_Denied,
    Exists,
    Does_Not_Exist,
    Closed,
    Timeout,
    Broken_Pipe,
    No_Size,
    Invalid_File,
    Invalid_Directory,
    Invalid_Path,
    Invalid_Callback,
    Pattern_Has_Separator,
    Unsupported,
    File_Is_Pipe,
    Not_A_Directory,
    EOF,
    Unexpected_EOF,
    Short_Write,
    Invalid_Write,
    Short_Buffer,
    No_Progress,
    Invalid_Whence,
    Invalid_Offset,
    Invalid_Unread,
    Negative_Read,
    Negative_Write,
    Negative_Count,
    Buffer_Full,
    Unknown,
    Empty,
    Out_Of_Memory,
    Invalid_Pointer,
    Invalid_Argument,
    Mode_Not_Implemented,
    Platform_Error,
    Path_Has_Separator,
}

os_error_to_raven :: proc(err: os.Error) -> (raven_err: Raven_Error) {
    if err == nil {
        return .None
    }

    switch e in err {
    case os.General_Error:
        switch e {
        case .None: return .None
        case .Permission_Denied: return .Permission_Denied
        case .Exist: return .Exists
        case .Not_Exist: return .Does_Not_Exist
        case .Timeout: return .Timeout
        case .Broken_Pipe: return .Broken_Pipe
        case .No_Size: return .No_Size
        case .Invalid_File: return .Invalid_File
        case .Invalid_Dir: return .Invalid_Directory
        case .Invalid_Path: return .Invalid_Path
        case .Invalid_Callback: return .Invalid_Callback
        case .Unsupported: return .Unsupported
        case .File_Is_Pipe: return .File_Is_Pipe
        case .Not_Dir: return .Not_A_Directory
        case .Closed: return .Closed
        case .Pattern_Has_Separator: return .Pattern_Has_Separator
        }
    case io.Error:
        switch e {
        case .None: return .None
        case .EOF: return .EOF
        case .Unexpected_EOF: return .Unexpected_EOF
        case .Short_Write: return .Short_Write
        case .Invalid_Write: return .Invalid_Write
        case .Short_Buffer: return .Short_Buffer
        case .No_Progress: return .No_Progress
        case .Invalid_Whence: return .Invalid_Whence
        case .Invalid_Offset: return .Invalid_Offset
        case .Invalid_Unread: return .Invalid_Unread
        case .Negative_Read: return .Negative_Read
        case .Negative_Write: return .Negative_Write
        case .Negative_Count: return .Negative_Count
        case .Buffer_Full: return .Buffer_Full
        case .Unknown: return .Unknown
        case .Empty: return .Empty
        }
    case runtime.Allocator_Error:
        switch e {
        case .None: return .None
        case .Out_Of_Memory: return .Out_Of_Memory
        case .Invalid_Pointer: return .Invalid_Pointer
        case .Invalid_Argument: return .Invalid_Argument
        case .Mode_Not_Implemented: return .Mode_Not_Implemented
        }
    case os.Platform_Error:
        return .Platform_Error
    }

    return nil
}

lua_get_string :: proc "c" (state: ^lua.State, value_index: i32) -> (str: string) {
    value_length: uint
    value_as_cstring := lua.tolstring(state, value_index, &value_length)
    value_as_bytes := (cast([^]byte)value_as_cstring)[:value_length]
    value_as_string := transmute(string)value_as_bytes

    return value_as_string
}

lua_print_stack :: proc "c" (state: ^lua.State) {
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

lua_allocation_function :: proc "c" (user_data, ptr: rawptr, old_size, new_size: uint) -> (new_pointer: rawptr) {
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

lua_atpanic :: proc "c" (state: ^lua.State) -> (result_count: i32) {
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

// Errors if not enough command line arguments were given to the command.
//
// Parameters:
// - amount (integer): the amount of arguments to expect from args
lua_raven_demand_argument_amount :: proc "c" (state: ^lua.State) -> (result_count: i32) {
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

extract_value_parts :: proc(state: ^lua.State, value_index: i32, value_parts: ^[dynamic]string) {
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

expand_value :: proc(state: ^lua.State, value_index: i32) -> (value_parts: [dynamic]string, ok: bool) {
    value_type := lua.type(state, value_index)
    #partial switch value_type {
    case .STRING:
        value_as_string := lua_get_string(state, value_index)
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

// Runs a command.
//
// Parameters:
// - command (expandable): the command to run, built from the expandable's parts.
//
// Returns:
// - [1] (boolean): true if the command succeeded, false otherwise
// - [2] (table): if [1] is true, a table containing the following keys:
//   - exit_code (number): the process' exit code
//   - output (string): the process' captured stdout output
//   - error_output (string): the process' captured stderr output
lua_raven_run :: proc "c" (state: ^lua.State) -> (result_count: i32) {
    context = runtime.default_context()

    error_message: cstring
    error_arg: any

    defer if error_message != nil {
        lua.L_error(state, error_message, error_arg)
    }

    argument_amount := lua.gettop(state)

    if argument_amount < 1 {
        error_message = "missing argument #1 for \"run\": command (expandable)"
        return
    }

    argument1_type := lua.type(state, 1)

    if argument1_type != .TABLE && argument1_type != .STRING {
        error_message = "bad argument #1 for \"run\" (command): expected \"expandable\", got \"%s\""
        error_arg = lua.typename(state, argument1_type)
        return
    }

    command_parts, expand_ok := expand_value(state, 1)

    if !expand_ok {
        error_message = "could not expand argument #1 for \"run\" (command)"
        return
    }

    defer delete(command_parts)

    if len(command_parts) == 0 {
        error_message = "bad argument #1 for \"run\" (command): command is empty"
        return
    }

    {
        printable_process_name: string

        if argument1_type == .TABLE {
            printable_process_name = strings.join(command_parts[:], " ")
        } else {
            command_as_string := lua_get_string(state, 1)
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

// Tests whether some files are older than others.
//
// Parameters:
// - files (expandable): the files to be compared.
// - others (expandable): the files to compare with.
//
// Returns:
// - [1] (boolean): true if any of the items in `files` is older than any of the items in `others`
lua_raven_older :: proc "c" (state: ^lua.State) -> (result_count: i32) {
    context = runtime.default_context()

    error_message: cstring
    error_arg: any

    defer if error_message != nil {
        lua.L_error(state, error_message, error_arg)
    }

    argument_amount := lua.gettop(state)

    if argument_amount < 1 {
        error_message = "missing argument #1 for \"older\": files (expandable)"
        return
    }

    argument1_type := lua.type(state, 1)

    if argument1_type != .TABLE && argument1_type != .STRING {
        error_message = "bad argument #1 for \"older\" (files): expected \"expandable\", got \"%s\""
        error_arg = lua.typename(state, argument1_type)
        return
    }

    if argument_amount < 2 {
        error_message = "missing argument #2 for \"older\": others (expandable)"
        return
    }

    argument2_type := lua.type(state, 2)

    if argument2_type != .TABLE && argument2_type != .STRING {
        error_message = "bad argument #2 for \"older\" (others): expected \"expandable\", got \"%s\""
        error_arg = lua.typename(state, argument2_type)
        return
    }

    files_parts, files_ok := expand_value(state, 1)

    if !files_ok {
        error_message = "could not expand argument #1 for \"older\" (files)"
        return
    }

    defer delete(files_parts)

    others_parts, others_ok := expand_value(state, 2)

    if !others_ok {
        error_message = "could not expand argument #2 for \"older\" (others)"
        return
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
                return 1
            }
        }
    }

    lua.pushboolean(state, false)
    return 1
}

// Expands a glob pattern to a list of items.
//
// Parameters:
// - pattern (string): the grep pattern, according to the syntax of https://pkg.odin-lang.org/core/path/filepath/#match.
// - filter? (integer): one of the following values:
//   - raven.EXPAND_FILTER_ALL (default): collect all kinds of items
//   - raven.EXPAND_FILTER_FILE: collect files only
//   - raven.EXPAND_FILTER_DIRECTORY: collect directory names only
lua_raven_expand :: proc "c" (state: ^lua.State) -> (result_count: i32) {
    context = runtime.default_context()

    error_message: cstring
    error_arg: any

    defer if error_message != nil {
        lua.L_error(state, error_message, error_arg)
    }

    argument_count := lua.gettop(state)

    if argument_count < 1 {
        error_message = "missing argument #1 for \"expand\": pattern (string)"
        return
    }

    argument1_type := lua.type(state, 1)

    if argument1_type != .STRING {
        error_message = "bad argument #1 for \"expand\" (pattern): expected \"string\", got \"%s\""
        error_arg = lua.typename(state, argument1_type)
        return
    }

    lua.len(state, 1)
    argument1_length := lua.tointeger(state, -1)
    lua.pop(state, 1)

    if argument1_length < 1 {
        error_message = "bad argument #1 for \"expand\" (pattern): pattern is empty"
        return
    }

    filter := Expand_Filter.All

    if argument_count >= 2 {
        argument2_type := lua.type(state, 2)

        if argument2_type != .NUMBER {
            error_message = "bad argument #2 for \"expand\" (filter): expected \"expand filter\", got \"%s\""
            error_arg = lua.typename(state, argument2_type)
            return
        }

        filter = Expand_Filter(lua.tointeger(state, 2))

        if int(filter) > len(Expand_Filter) - 1 {
            error_message = "bad argument #2 for \"expand\" (filter): invalid filter type"
            error_arg = lua.typename(state, argument2_type)
            return
        }
    }

    pattern := lua_get_string(state, 1)

    matches, match_ok := expand_path(pattern, filter)

    if !match_ok {
        return 0
    }

    lua.createtable(state, i32(len(matches)), 0)
    matches_table_index := lua.gettop(state)

    for i in 0..<len(matches) {
        match := matches[i]
        lua.pushlstring(state, cstring(raw_data(match)), len(match))
        lua.seti(state, matches_table_index, lua.Integer(i + 1))
    }

    return 1
}

// Creates a new directory.
//
// Parameters:
// - path (string): path to the directory to create.
// - recursive? (boolean): if true, create parent directories if they don't exist.
//
// Returns:
// - [1] (error): operation error, if any.
// - [2]? (string): path for which the error occurred, if any.
lua_raven_create_directory :: proc "c" (state: ^lua.State) -> (result_count: i32) {
    context = runtime.default_context()

    error_message: cstring
    error_arg: any

    defer if error_message != nil {
        lua.L_error(state, error_message, error_arg)
    }

    argument_count := lua.gettop(state)

    if argument_count < 1 {
        error_message = "missing argument #1 for \"create_directory\": path (string)"
        return
    }

    argument1_type := lua.type(state, 1)

    if argument1_type != .STRING {
        error_message = "bad argument #1 for \"create_directory\" (path): expected \"string\", got \"%s\""
        error_arg = lua.typename(state, argument1_type)
        return
    }

    lua.len(state, 1)
    argument1_length := lua.tointeger(state, -1)
    lua.pop(state, 1)

    if argument1_length < 1 {
        error_message = "bad argument #1 for \"create_directory\" (path): path is empty"
        return
    }

    path := lua_get_string(state, 1)

    recursive: b32

    if argument_count > 1 {
        argument2_type := lua.type(state, 2)

        if argument2_type != .BOOLEAN {
            error_message = "bad argument #2 for \"create_directory\" (recursive): expected \"boolean\", got \"%s\""
            error_arg = lua.typename(state, argument2_type)
            return
        }

        recursive = lua.toboolean(state, 2)
    }

    if !recursive {
        make_directory_err := os.make_directory(path)
        lua.pushinteger(state, lua.Integer(os_error_to_raven(make_directory_err)))
        lua.pushlstring(state, cstring(raw_data(path)), len(path))
        return 2
    }

    parts, split_err := strings.split(path, "/")

    if split_err != nil {
        error_message = "could not allocate path parts while recursively creating directory \"%s\""
        error_arg = path
        return
    }

    defer delete(parts)

    for i := 0; i < len(parts); i += 1 {
        partial_path, join_err := strings.join(parts[:i + 1], "/")

        if join_err != nil {
            error_message = "could not allocate partial path while recursively creating directory \"%s\""
            error_arg = path
            return
        }

        defer delete(partial_path)

        if os.is_dir(partial_path) {
            continue
        }

        make_directory_err := os.make_directory(partial_path)

        if make_directory_err != nil {
            lua.pushinteger(state, lua.Integer(os_error_to_raven(make_directory_err)))
            lua.pushlstring(state, cstring(raw_data(partial_path)), len(partial_path))
            return 2
        }
    }

    lua.pushinteger(state, lua.Integer(Raven_Error.None))
    return 1
}

remove_directory_recursively :: proc(path: string) -> (err: os.Error, err_path: string) {
    directory_items: []os.File_Info

    {
        directory, dir_open_err := os.open(path)

        if dir_open_err != nil {
            return dir_open_err, path
        }

        defer os.close(directory)

        read_dir_err: os.Error
        directory_items, read_dir_err = os.read_dir(directory, -1)

        if read_dir_err != nil {
            return read_dir_err, path
        }
    }

    for directory_item in directory_items {
        defer os.file_info_delete(directory_item)

        if directory_item.is_dir {
            remove_err, remove_path := remove_directory_recursively(directory_item.fullpath)

            if remove_err != nil {
                return remove_err, remove_path
            }
        } else {
            file_remove_err := os.remove(directory_item.fullpath)

            if file_remove_err != nil {
                return file_remove_err, directory_item.fullpath
            }
        }
    }

    dir_remove_err := os.remove_directory(path)

    if dir_remove_err != nil {
        return dir_remove_err, path
    }

    return nil, ""
}

// Removes directory at path.
//
// Parameters:
// - path (string): path to the directory to remove.
// - recursive? (boolean): if true, removes the directory recursively.
//
// Returns:
// - [1] (error): operation error, if any.
// - [2]? (string): path for which the error occurred, if any.
lua_raven_remove_directory :: proc "c" (state: ^lua.State) -> (result_count: i32) {
    context = runtime.default_context()

    error_message: cstring
    error_arg: any

    defer if error_message != "" {
        lua.L_error(state, error_message, error_arg)
    }

    argument_count := lua.gettop(state)

    if argument_count < 1 {
        error_message = "missing argument #1 for \"remove_directory\": path (string)"
        return
    }

    argument1_type := lua.type(state, 1)

    if argument1_type != .STRING {
        error_message = "bad argument #1 for \"remove_directory\" (path): expected \"string\", got \"%s\""
        error_arg = lua.typename(state, argument1_type)
        return
    }

    lua.len(state, 1)
    argument1_length := lua.tointeger(state, -1)
    lua.pop(state, 1)

    if argument1_length < 1 {
        error_message = "bad argument #1 for \"remove_directory\" (path): path is empty"
        return
    }

    path := lua_get_string(state, 1)

    recursive: b32

    if argument_count >= 2 {
        argument2_type := lua.type(state, 2)

        if argument2_type != .BOOLEAN {
            error_message = "bad argument #2 for \"remove_directory\" (recursive): expected \"boolean\", got \"%s\""
            error_arg = lua.typename(state, argument2_type)
            return
        }

        recursive = lua.toboolean(state, 2)
    }

    if !os2.is_directory(path) {
        lua.pushinteger(state, lua.Integer(Raven_Error.Not_A_Directory))
        lua.pushlstring(state, cstring(raw_data(path)), len(path))
        return 2
    }

    if recursive {
        remove_err, err_path := remove_directory_recursively(path)

        if remove_err != nil {
            lua.pushinteger(state, lua.Integer(Raven_Error.Not_A_Directory))
            lua.pushlstring(state, cstring(raw_data(err_path)), len(err_path))
            return 2
        }
    } else {
        remove_err := os.remove_directory(path)

        if remove_err != nil {
            lua.pushinteger(state, lua.Integer(os_error_to_raven(remove_err)))
            lua.pushlstring(state, cstring(raw_data(path)), len(path))
            return 2
        }
    }

    lua.pushinteger(state, lua.Integer(Raven_Error.None))
    return 1
}

// Creates a file.
//
// Parameters:
// - path (string): path to the file to create.
//
// Returns:
// - [1] (error): operation error, if any.
lua_raven_create_file :: proc "c" (state: ^lua.State) -> (result_count: i32) {
    context = runtime.default_context()

    error_message: cstring
    error_arg: any

    defer if error_message != "" {
        lua.L_error(state, error_message, error_arg)
    }

    argument_count := lua.gettop(state)

    if argument_count < 1 {
        error_message = "missing argument #1 for \"create_file\": path (string)"
        return
    }

    argument1_type := lua.type(state, 1)

    if argument1_type != .STRING {
        error_message = "bad argument #1 for \"create_file\" (path): expected \"string\", got \"%s\""
        error_arg = lua.typename(state, argument1_type)
        return
    }

    lua.len(state, 1)
    argument1_length := lua.tointeger(state, -1)
    lua.pop(state, 1)

    if argument1_length < 1 {
        error_message = "bad argument #1 for \"create_file\" (path): path is empty"
        return
    }

    path := lua_get_string(state, 1)

    file_handle, create_err := os.open(path, os.O_CREATE)
    os.close(file_handle)

    lua.pushinteger(state, lua.Integer(os_error_to_raven(create_err)))
    return 1
}

Exists_Filter :: enum {
    File,
    Directory,
}

// Checks if a filesystem item exists.
//
// Parameters:
// - path (string): path to the item to search for.
// - filter? (integer): one of the following values:
//   - raven.EXISTS_FILTER_FILE (default): check for a file
//   - raven.EXISTS_FILTER_DIRECTORY: check for a directory
//
// Returns:
// - [1] (boolean): true if the item exists, false otherwise.
lua_raven_exists :: proc "c" (state: ^lua.State) -> (result_count: i32) {
    context = runtime.default_context()

    error_message: cstring
    error_arg: any

    defer if error_message != "" {
        lua.L_error(state, error_message, error_arg)
    }

    argument_count := lua.gettop(state)

    if argument_count < 1 {
        error_message = "missing argument #1 for \"exists\": path (string)"
        return
    }

    argument1_type := lua.type(state, 1)

    if argument1_type != .STRING {
        error_message = "bad argument #1 for \"exists\" (path): expected \"string\", got \"%s\""
        error_arg = lua.typename(state, argument1_type)
        return
    }

    lua.len(state, 1)
    argument1_length := lua.tointeger(state, -1)
    lua.pop(state, 1)

    if argument1_length < 1 {
        error_message = "bad argument #1 for \"exists\" (path): path is empty"
        return
    }

    path := lua_get_string(state, 1)

    filter_type: Exists_Filter

    if argument_count > 1 {
        if !lua.isinteger(state, 2) {
            error_message = "bad argument #2 for \"exists\" (filter): expected \"number\", got \"%s\""
            error_arg = lua.L_typename(state, 2)
            return
        }

        filter_int := lua.tointeger(state, 2)

        if filter_int >= len(Exists_Filter) {
            error_message = "bad argument #2 for \"exists\" (filter): invalid filter type (%d)"
            error_arg = filter_int
            return
        }

        filter_type = Exists_Filter(filter_int)
    }

    switch filter_type {
    case .File:
        lua.pushboolean(state, b32(os2.is_file(path)))
    case .Directory:
        lua.pushboolean(state, b32(os2.is_dir(path)))
    }

    return 1
}

push_raven_table :: proc(state: ^lua.State) -> (index: i32, ok: bool) {
    lua.getglobal(state, "raven")

    if lua.type(state, -1) != .TABLE {
        print_error(.RAVEN, "invalid type for \"raven\": expected table, got %s", lua.L_typename(state, -1))
        return 0, false
    }

    return lua.gettop(state), true
}

main :: proc() {
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

        for arg in os.args[1:] {
            if !strings.starts_with(arg, "-") || arg == "--" {
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

    lua.pushcfunction(state, lua_raven_demand_argument_amount)
    lua.setfield(state, raven_table_index, "demand_argument_amount")

    lua.pushcfunction(state, lua_raven_older)
    lua.setfield(state, raven_table_index, "older")

    lua.pushcfunction(state, lua_raven_expand)
    lua.setfield(state, raven_table_index, "expand")

    lua.pushcfunction(state, lua_raven_create_directory)
    lua.setfield(state, raven_table_index, "create_directory")

    lua.pushcfunction(state, lua_raven_remove_directory)
    lua.setfield(state, raven_table_index, "remove_directory")

    // NOTE(volatus): not needed right now because you can use io.open()
    // lua.pushcfunction(state, lua_raven_create_file)
    // lua.setfield(state, raven_table_index, "create_file")

    lua.pushcfunction(state, lua_raven_exists)
    lua.setfield(state, raven_table_index, "exists")

    lua.pushinteger(state, lua.Integer(Expand_Filter.All))
    lua.setfield(state, raven_table_index, "EXPAND_FILTER_ALL")

    lua.pushinteger(state, lua.Integer(Expand_Filter.File))
    lua.setfield(state, raven_table_index, "EXPAND_FILTER_FILE")

    lua.pushinteger(state, lua.Integer(Expand_Filter.Directory))
    lua.setfield(state, raven_table_index, "EXPAND_FILTER_DIRECTORY")

    lua.pushinteger(state, lua.Integer(Exists_Filter.File))
    lua.setfield(state, raven_table_index, "EXISTS_FILTER_FILE")

    lua.pushinteger(state, lua.Integer(Exists_Filter.Directory))
    lua.setfield(state, raven_table_index, "EXISTS_FILTER_DIRECTORY")

    lua.pushinteger(state, lua.Integer(Raven_Error.None))
    lua.setfield(state, raven_table_index, "ERROR_NONE")

    lua.pushinteger(state, lua.Integer(Raven_Error.Permission_Denied))
    lua.setfield(state, raven_table_index, "ERROR_PERMISSION_DENIED")

    lua.pushinteger(state, lua.Integer(Raven_Error.Exists))
    lua.setfield(state, raven_table_index, "ERROR_EXISTS")

    lua.pushinteger(state, lua.Integer(Raven_Error.Does_Not_Exist))
    lua.setfield(state, raven_table_index, "ERROR_DOES_NOT_EXIST")

    lua.pushinteger(state, lua.Integer(Raven_Error.Closed))
    lua.setfield(state, raven_table_index, "ERROR_CLOSED")

    lua.pushinteger(state, lua.Integer(Raven_Error.Timeout))
    lua.setfield(state, raven_table_index, "ERROR_TIMEOUT")

    lua.pushinteger(state, lua.Integer(Raven_Error.Broken_Pipe))
    lua.setfield(state, raven_table_index, "ERROR_BROKEN_PIPE")

    lua.pushinteger(state, lua.Integer(Raven_Error.No_Size))
    lua.setfield(state, raven_table_index, "ERROR_NO_SIZE")

    lua.pushinteger(state, lua.Integer(Raven_Error.Invalid_File))
    lua.setfield(state, raven_table_index, "ERROR_INVALID_FILE")

    lua.pushinteger(state, lua.Integer(Raven_Error.Invalid_Directory))
    lua.setfield(state, raven_table_index, "ERROR_INVALID_DIRECTORY")

    lua.pushinteger(state, lua.Integer(Raven_Error.Invalid_Path))
    lua.setfield(state, raven_table_index, "ERROR_INVALID_PATH")

    lua.pushinteger(state, lua.Integer(Raven_Error.Invalid_Callback))
    lua.setfield(state, raven_table_index, "ERROR_INVALID_CALLBACK")

    lua.pushinteger(state, lua.Integer(Raven_Error.Pattern_Has_Separator))
    lua.setfield(state, raven_table_index, "ERROR_PATTERN_HAS_SEPARATOR")

    lua.pushinteger(state, lua.Integer(Raven_Error.Unsupported))
    lua.setfield(state, raven_table_index, "ERROR_UNSUPPORTED")

    lua.pushinteger(state, lua.Integer(Raven_Error.File_Is_Pipe))
    lua.setfield(state, raven_table_index, "ERROR_FILE_IS_PIPE")

    lua.pushinteger(state, lua.Integer(Raven_Error.Not_A_Directory))
    lua.setfield(state, raven_table_index, "ERROR_NOT_A_DIRECTORY")

    lua.pushinteger(state, lua.Integer(Raven_Error.EOF))
    lua.setfield(state, raven_table_index, "ERROR_EOF")

    lua.pushinteger(state, lua.Integer(Raven_Error.Unexpected_EOF))
    lua.setfield(state, raven_table_index, "ERROR_UNEXPECTED_EOF")

    lua.pushinteger(state, lua.Integer(Raven_Error.Short_Write))
    lua.setfield(state, raven_table_index, "ERROR_SHORT_WRITE")

    lua.pushinteger(state, lua.Integer(Raven_Error.Invalid_Write))
    lua.setfield(state, raven_table_index, "ERROR_INVALID_WRITE")

    lua.pushinteger(state, lua.Integer(Raven_Error.Short_Buffer))
    lua.setfield(state, raven_table_index, "ERROR_SHORT_BUFFER")

    lua.pushinteger(state, lua.Integer(Raven_Error.No_Progress))
    lua.setfield(state, raven_table_index, "ERROR_NO_PROGRESS")

    lua.pushinteger(state, lua.Integer(Raven_Error.Invalid_Whence))
    lua.setfield(state, raven_table_index, "ERROR_INVALID_WHENCE")

    lua.pushinteger(state, lua.Integer(Raven_Error.Invalid_Offset))
    lua.setfield(state, raven_table_index, "ERROR_INVALID_OFFSET")

    lua.pushinteger(state, lua.Integer(Raven_Error.Invalid_Unread))
    lua.setfield(state, raven_table_index, "ERROR_INVALID_UNREAD")

    lua.pushinteger(state, lua.Integer(Raven_Error.Negative_Read))
    lua.setfield(state, raven_table_index, "ERROR_NEGATIVE_READ")

    lua.pushinteger(state, lua.Integer(Raven_Error.Negative_Write))
    lua.setfield(state, raven_table_index, "ERROR_NEGATIVE_WRITE")

    lua.pushinteger(state, lua.Integer(Raven_Error.Negative_Count))
    lua.setfield(state, raven_table_index, "ERROR_NEGATIVE_COUNT")

    lua.pushinteger(state, lua.Integer(Raven_Error.Buffer_Full))
    lua.setfield(state, raven_table_index, "ERROR_BUFFER_FULL")

    lua.pushinteger(state, lua.Integer(Raven_Error.Unknown))
    lua.setfield(state, raven_table_index, "ERROR_UNKNOWN")

    lua.pushinteger(state, lua.Integer(Raven_Error.Empty))
    lua.setfield(state, raven_table_index, "ERROR_EMPTY")

    lua.pushinteger(state, lua.Integer(Raven_Error.Out_Of_Memory))
    lua.setfield(state, raven_table_index, "ERROR_OUT_OF_MEMORY")

    lua.pushinteger(state, lua.Integer(Raven_Error.Invalid_Pointer))
    lua.setfield(state, raven_table_index, "ERROR_INVALID_POINTER")

    lua.pushinteger(state, lua.Integer(Raven_Error.Invalid_Argument))
    lua.setfield(state, raven_table_index, "ERROR_INVALID_ARGUMENT")

    lua.pushinteger(state, lua.Integer(Raven_Error.Mode_Not_Implemented))
    lua.setfield(state, raven_table_index, "ERROR_MODE_NOT_IMPLEMENTED")

    lua.pushinteger(state, lua.Integer(Raven_Error.Platform_Error))
    lua.setfield(state, raven_table_index, "ERROR_PLATFORM_ERROR")

    lua.pushinteger(state, lua.Integer(Raven_Error.Path_Has_Separator))
    lua.setfield(state, raven_table_index, "ERROR_PATH_HAS_SEPARATOR")

    {
        args_offset := (len(command_args) > 0 && command_args[0] == "--") ? 1 : 0

        lua.createtable(state, i32(len(command_args) - args_offset), 0)
        defer lua.setfield(state, raven_table_index, "args")

        if len(command_args) > args_offset {
            for arg, i in command_args[args_offset:] {
                lua.pushlstring(state, cstring(raw_data(arg)), len(arg))
                lua.seti(state, -2, lua.Integer(i + 1))
            }
        }
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

        writer: bufio.Writer
        bufio.writer_init(&writer, os.stream_from_handle(os.stdout))

        lua.pushnil(state)
        for lua.next(state, commands_index) != 0 {
            lua.pushvalue(state, -2)
            command_name := lua_get_string(state, -1)
            lua.pop(state, 2)
            bufio.writer_write_string(&writer, "- ")
            bufio.writer_write_string(&writer, COLOR_IDENTIFIER)
            bufio.writer_write_string(&writer, command_name)
            bufio.writer_write_string(&writer, COLOR_RESET)
            bufio.writer_write_byte(&writer, '\n')
        }

        bufio.writer_flush(&writer)
    } else if command_args == nil || command_args[0] == "--" {
        raven_table_index, raven_table_ok := push_raven_table(state)

        if !raven_table_ok {
            return
        }

        lua.getfield(state, -1, "default")

        if lua.type(state, -1) == .NIL {
            print_error(.RAVEN, "no default command set")
            return
        }

        if lua.type(state, -1) != .FUNCTION {
            print_error(.RAVEN, "invalid type for raven.default (expected function, got %s)", lua.L_typename(state, -1))
            return
        }

        lua.createtable(state, i32(len(command_args) - 1), 0)

        if len(command_args) > 1 {
            for arg, i in command_args[1:] {
                lua.pushlstring(state, cstring(raw_data(arg)), len(arg))
                lua.seti(state, -2, lua.Integer(i + 1))
            }
        }

        lua.setfield(state, raven_table_index, "cmd_args")

        lua.call(state, 0, 0)
    } else {
        _, raven_table_ok := push_raven_table(state)

        if !raven_table_ok {
            return
        }

        lua.getfield(state, -1, "commands")

        if lua.type(state, -1) != .TABLE {
            print_error(.RAVEN, "invalid type for raven.commands (expected table, got %s)", lua.L_typename(state, -1))
            return
        }

        command_name_cstr := strings.clone_to_cstring(command_args[0])
        lua.getfield(state, -1, command_name_cstr)
        delete(command_name_cstr)

        command_found := lua.type(state, -1) == .FUNCTION

        if !command_found {
            if lua.type(state, -1) != .NIL {
                print_error(.RAVEN, "invalid type for raven command \"%s\" (expected function, got %s)", command_args[0], lua.L_typename(state, -1))
                return
            }

            lua.pop(state, 2)
        }

        cmd_args_offset := command_found ? 1 : 0
        lua.createtable(state, i32(len(command_args) - cmd_args_offset), 0)

        if len(command_args) > cmd_args_offset {
            for arg, i in command_args[cmd_args_offset:] {
                lua.pushlstring(state, cstring(raw_data(arg)), len(arg))
                lua.seti(state, -2, lua.Integer(i + 1))
            }
        }

        lua.setfield(state, raven_table_index, "cmd_args")

        if command_found {
            lua.call(state, 0, 0)
        } else {
            lua.getfield(state, -1, "default")

            #partial switch lua.type(state, -1) {
            case .FUNCTION:
                lua.call(state, 0, 0)
            case .NIL:
                print_error(.RAVEN, "could not find command %s\"%s\"%s", COLOR_IDENTIFIER, command_args[0], COLOR_RESET)
            case:
                print_error(.RAVEN, "invalid type for raven.default (expected function, got %s)", lua.L_typename(state, -1))
            }
        }

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
