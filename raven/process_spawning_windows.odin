package raven

import "core:fmt"
import "core:strings"
import "core:sys/windows"
import "base:runtime"

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
        error("Raven was unable to format a Windows error message (FormatMessageW error, code %d)", windows.GetLastError())
        return
    }

    error("[Windows, ERR %d] %s", error_code, ([^]u16)(p))
}

// TODO(volatus): fix usage of this in spawn_process
escape_command_arg :: proc(arg: string) -> string {
    builder := strings.builder_make(0, len(arg)*2)

    escaped := false

    for i := 0; i < len(arg); i += 1 {
        char := arg[i]

        if char == '"' {
            strings.write_string(&builder, "\\\"")
            escaped = true
        // } else if char == '\\' && i < len(arg) - 1 {
        //     i += 1
        //     strings.write_byte(&builder, arg[i])
        } else {
            strings.write_byte(&builder, char)
        }
    }

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
        error("[Raven] application context has no associated standard output handle")
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
        error("[Raven] unable to allocate string builder for child process output")
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

spawn_and_run_process :: proc(cmd: cstring, args: ..cstring) -> (
    process_success: bool,
    process_exit_code: u32,
    process_output: cstring,
    process_error_output: cstring,
    success: bool,
) {
    security_attributes := windows.SECURITY_ATTRIBUTES {
        nLength = size_of(windows.SECURITY_ATTRIBUTES),
        lpSecurityDescriptor = nil,
        bInheritHandle = true,
    }

    stdout_read_handle, stdout_write_handle := create_child_output_pipe(&security_attributes) or_return
    stderr_read_handle, stderr_write_handle := create_child_output_pipe(&security_attributes) or_return

    process_info: windows.PROCESS_INFORMATION

    startup_info := windows.STARTUPINFOW {
        cb = size_of(windows.STARTUPINFOW),
        hStdOutput = stdout_write_handle,
        hStdError = stderr_write_handle,
        dwFlags = windows.STARTF_USESTDHANDLES,
    }

    cmdline_components := make([]string, len(args) + 1)
    cmdline_components[0] = (len(args) > 0) ? escape_command_arg(string(cmd)) : string(cmd)

    for arg, i in args {
        cmdline_components[i + 1] = escape_command_arg(string(arg))
    }

    command_line := windows.utf8_to_utf16(strings.join(cmdline_components, " "))

    fmt.printfln("[Raven] running command: %s", command_line)

    if !windows.CreateProcessW(nil, raw_data(command_line), nil, nil, true, 0, nil, nil, &startup_info, &process_info) {
        print_last_error_message()
        success = false
        return
    }

    close_handle(stdout_write_handle) or_return
    close_handle(stderr_write_handle) or_return

    stdout_builder := make_child_output_builder() or_return
    stderr_builder := make_child_output_builder() or_return

    console_stdout_handle := get_standard_handle(windows.STD_OUTPUT_HANDLE) or_return
    console_stderr_handle := get_standard_handle(windows.STD_ERROR_HANDLE) or_return

    read_buffer := make([]byte, PIPE_BUFFER_SIZE)
    amount_read: u32

    out_handle_closed := false
    err_handle_closed := false

    for {
        process_exit_code = get_process_exit_code(process_info.hProcess) or_return

        if process_exit_code != EXIT_CODE_STILL_ACTIVE {
            break
        }

        if out_handle_closed && err_handle_closed {
            break
        }

        if !out_handle_closed && (is_pipe_content_available(stdout_read_handle) or_return) {
            if !windows.ReadFile(stdout_read_handle, raw_data(read_buffer), PIPE_BUFFER_SIZE, &amount_read, nil) {
                if windows.GetLastError() != windows.ERROR_BROKEN_PIPE {
                    print_last_error_message()
                    success = false
                    return
                }

                // Write handle has been closed, abort reading operations
                out_handle_closed = true
                close_handle(stdout_read_handle) or_return
            } else {
                strings.write_bytes(&stdout_builder, read_buffer[:amount_read])

                if !windows.WriteFile(console_stdout_handle, raw_data(read_buffer), amount_read, nil, nil) {
                    print_last_error_message()
                    success = false
                    return
                }
            }
        }

        if !err_handle_closed && (is_pipe_content_available(stderr_read_handle) or_return) {
            if !windows.ReadFile(stderr_read_handle, raw_data(read_buffer), PIPE_BUFFER_SIZE, &amount_read, nil) {
                if windows.GetLastError() != windows.ERROR_BROKEN_PIPE {
                    print_last_error_message()
                    success = false
                    return
                }

                // Write handle has been closed, abort reading operations
                err_handle_closed = true
                close_handle(stderr_read_handle) or_return
            } else {
                strings.write_bytes(&stderr_builder, read_buffer[:amount_read])

                if !windows.WriteFile(console_stderr_handle, raw_data(read_buffer), amount_read, nil, nil) {
                    print_last_error_message()
                    success = false
                    return
                }
            }
        }
    }

    process_success = process_exit_code == 0
    success = true

    return
}
