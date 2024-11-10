package raven

import "base:runtime"
import "core:encoding/ansi"
import "core:fmt"
import "core:strings"
import "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention="system")
foreign kernel32 {
    PeekNamedPipe :: proc(
        hNamedPipe: windows.HANDLE,
        lpBuffer: rawptr,
        nBufferSize: u32,
        lpBytesRead: ^u32,
        lpTotalBytesAvail: ^u32,
        lpBytesLeftThisMessage: ^u32,
    ) -> windows.BOOL ---
}

EXIT_CODE_STILL_ACTIVE :: 259
PIPE_BUFFER_SIZE :: 4096

print_last_error_message :: proc() {
    error_message_flags: u32 = (
        windows.FORMAT_MESSAGE_FROM_SYSTEM
        | windows.FORMAT_MESSAGE_IGNORE_INSERTS
        | windows.FORMAT_MESSAGE_ALLOCATE_BUFFER
        | windows.FORMAT_MESSAGE_MAX_WIDTH_MASK
    )

    error_code := windows.GetLastError()

    p: rawptr
    message_length := windows.FormatMessageW(error_message_flags, nil, error_code, 0, (^u16)(&p), 0, nil)

    if message_length == 0 || p == nil {
        fmt.eprintfln("Raven was unable to format a Windows error message (FormatMessageW error, code %d)", windows.GetLastError())
        return
    }

    fmt.eprintfln("[Windows, ERR %d] %s", error_code, ([^]u16)(p))
}

quote_cstring :: proc(cstr: cstring) -> string {
    cstr_len := len(cstr)
    builder := strings.builder_make(0, cstr_len * 2 + 2)

    strings.write_byte(&builder, '\"')

    for i := 0; i < cstr_len; i += 1 {
        char := (transmute([^]u8)cstr)[i]

        if char == '"' {
            strings.write_string(&builder, "\\\"")
        } else {
            strings.write_byte(&builder, char)
        }
    }

    strings.write_byte(&builder, '\"')

    return strings.to_string(builder)
}

create_child_output_pipe :: proc(security_attributes: ^windows.SECURITY_ATTRIBUTES) -> (read_handle, write_handle: windows.HANDLE, success: bool) {
    if !windows.CreatePipe(&read_handle, &write_handle, security_attributes, 0) {
        print_last_error_message()
        return nil, nil, false
    }

    if !windows.SetHandleInformation(read_handle, windows.HANDLE_FLAG_INHERIT, 0) {
        print_last_error_message()
        return nil, nil, false
    }

    return read_handle, write_handle, true
}

get_standard_handle :: proc(standard_handle_number: u32) -> (handle: windows.HANDLE, success: bool) {
    handle = windows.GetStdHandle(standard_handle_number)

    if handle == nil {
        fmt.eprintfln("[Raven] application context has no associated standard output handle")
        return nil, false
    }

    if handle == windows.INVALID_HANDLE_VALUE {
        print_last_error_message()
        return nil, false
    }

    return handle, true
}

close_handle :: proc(handle: windows.HANDLE) -> bool {
    if !windows.CloseHandle(handle) {
        print_last_error_message()
        return false
    }

    return true
}

make_child_output_builder :: proc() -> (builder: strings.Builder, success: bool) {
    builder_err: runtime.Allocator_Error

    builder, builder_err = strings.builder_make(0, PIPE_BUFFER_SIZE)

    if builder_err != .None {
        fmt.eprintfln("[Raven] unable to allocate string builder for child process output")
        return {}, false
    }

    return builder, true
}

is_pipe_content_available :: proc(handle: windows.HANDLE) -> (is_available, success: bool) {
    bytes_available: u32

    if !PeekNamedPipe(handle, nil, 0, nil, &bytes_available, nil) {
        print_last_error_message()
        return false, false
    }

    return bytes_available > 0, true
}

get_process_exit_code :: proc(handle: windows.HANDLE) -> (exit_code: u32, success: bool) {
    if !windows.GetExitCodeProcess(handle, &exit_code) {
        print_last_error_message()
        return 0, false
    }

    return exit_code, true
}

redirect_and_capture_pipe :: proc(read_handle, write_handle: windows.HANDLE, read_buffer: [^]byte, capture_builder: ^strings.Builder) -> bool {
    amount_read: u32

    if !windows.ReadFile(read_handle, read_buffer, PIPE_BUFFER_SIZE, &amount_read, nil) {
        print_last_error_message()
        return false
    }

    strings.write_bytes(capture_builder, read_buffer[:amount_read])

    if !windows.WriteFile(write_handle, read_buffer, amount_read, nil, nil) {
        print_last_error_message()
        return false
    }

    return true
}

spawn_and_run_process :: proc(
    command_parts: []cstring,
) -> (
    process_success: bool,
    process_exit_code: u32,
    process_output: cstring,
    process_error_output: cstring,
    success: bool,
) {
    assert(len(command_parts) > 0)

    security_attributes := windows.SECURITY_ATTRIBUTES {
        nLength = size_of(windows.SECURITY_ATTRIBUTES),
        lpSecurityDescriptor = nil,
        bInheritHandle = true,
    }

    console_stdout_handle := get_standard_handle(windows.STD_OUTPUT_HANDLE) or_return
    console_stderr_handle := get_standard_handle(windows.STD_ERROR_HANDLE) or_return
    console_input_handle := get_standard_handle(windows.STD_INPUT_HANDLE) or_return

    stdout_read_handle, stdout_write_handle := create_child_output_pipe(&security_attributes) or_return
    stderr_read_handle, stderr_write_handle := create_child_output_pipe(&security_attributes) or_return

    process_info: windows.PROCESS_INFORMATION

    startup_info := windows.STARTUPINFOW {
        cb = size_of(windows.STARTUPINFOW),
        hStdOutput = stdout_write_handle,
        hStdError = stderr_write_handle,
        hStdInput = console_input_handle,
        dwFlags = windows.STARTF_USESTDHANDLES,
    }

    command_line: []u16

    { // Build command line
        arena_temp := runtime.default_temp_allocator_temp_begin()
        defer runtime.default_temp_allocator_temp_end(arena_temp)

        heap_alloc := context.allocator
        context.allocator = context.temp_allocator

        quoted_args := make([]string, len(command_parts))
        defer delete(quoted_args)

        for command_part, i in command_parts {
            quoted_args[i] = quote_cstring(command_part)
        }

        joined_quoted_args := strings.join(quoted_args, " ")

        command_line = windows.utf8_to_utf16(joined_quoted_args, heap_alloc)
    }

    if !windows.CreateProcessW(nil, raw_data(command_line), nil, nil, true, 0, nil, nil, &startup_info, &process_info) {
        print_last_error_message()
        success = false
        return
    }

    close_handle(stdout_write_handle) or_return
    close_handle(stderr_write_handle) or_return

    stdout_builder := make_child_output_builder() or_return
    stderr_builder := make_child_output_builder() or_return

    read_buffer := make([]byte, PIPE_BUFFER_SIZE)

    for {
        process_exit_code = get_process_exit_code(process_info.hProcess) or_return

        if process_exit_code != EXIT_CODE_STILL_ACTIVE {
            break
        }

        stdout_content_available := is_pipe_content_available(stdout_read_handle) or_return
        stderr_content_available := is_pipe_content_available(stderr_read_handle) or_return

        if stdout_content_available {
            redirect_and_capture_pipe(stdout_read_handle, console_stdout_handle, raw_data(read_buffer), &stdout_builder) or_return
        }

        if stderr_content_available {
            redirect_and_capture_pipe(stderr_read_handle, console_stderr_handle, raw_data(read_buffer), &stderr_builder) or_return
        }
    }

    close_handle(stdout_read_handle) or_return
    close_handle(stderr_read_handle) or_return

    process_success = process_exit_code == 0
    process_output = strings.to_cstring(&stdout_builder)
    process_error_output = strings.to_cstring(&stderr_builder)
    success = true

    return
}
