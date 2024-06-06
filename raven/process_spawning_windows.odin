package raven

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "core:sys/windows"
import "core:unicode/utf16"
import "core:unicode/utf8"

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

escape_command_arg :: proc(arg: string) -> string {
    quote_count := 0

    for i in 0..<len(arg) {
        if arg[i] == '"' {
            quote_count += 1
        }
    }

    buf := make([]byte, len(arg) + quote_count + 2)

    buf[0] = '"'
    buf[len(buf) - 1] = '"'

    str_buf := buf[1:]

    for i := 0; i < len(arg); i += 1 {
        if arg[i] == '"' {
            str_buf[i] = '\\'
            str_buf[i + 1] = '"'

            i += 1
        } else {
            str_buf[i] = arg[i]
        }
    }

    return string(buf)
}

spawn_and_run_process :: proc(cmd: cstring, args: ..cstring) -> (
    process_success: bool,
    process_exit_code: u32,
    process_output: cstring,
    process_error_output: cstring
) {
    security_attributes := windows.SECURITY_ATTRIBUTES {
        nLength = size_of(windows.SECURITY_ATTRIBUTES),
        lpSecurityDescriptor = nil,
        bInheritHandle = true,
    }

    stdout_read_handle, stdout_write_handle: windows.HANDLE

    if !windows.CreatePipe(&stdout_read_handle, &stdout_write_handle, &security_attributes, 0) {
        print_last_error_message()
        return
    }

    if !windows.SetHandleInformation(stdout_read_handle, windows.HANDLE_FLAG_INHERIT, 0) {
        print_last_error_message()
        return
    }

    stderr_read_handle, stderr_write_handle: windows.HANDLE

    if !windows.CreatePipe(&stderr_read_handle, &stderr_write_handle, &security_attributes, 0) {
        print_last_error_message()
        return
    }

    if !windows.SetHandleInformation(stderr_read_handle, windows.HANDLE_FLAG_INHERIT, 0) {
        print_last_error_message()
        return
    }

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

    fmt.printfln("%s", command_line)

    if !windows.CreateProcessW(
        nil,
        raw_data(command_line),
        nil,
        nil,
        true,
        0,
        nil,
        nil,
        &startup_info,
        &process_info,
    ) {
        print_last_error_message()
        return
    }

    if !windows.CloseHandle(stdout_write_handle) {
        print_last_error_message()
        return
    }

    if !windows.CloseHandle(stderr_write_handle) {
        print_last_error_message()
        return
    }

    for {
        if !windows.GetExitCodeProcess(process_info.hProcess, &process_exit_code) {
            print_last_error_message()
            return
        }

        if process_exit_code != EXIT_CODE_STILL_ACTIVE {
            break
        }
    }

    out_read_buffer := make([]byte, PIPE_BUFFER_SIZE + 1)
    out_amount_read: u32

    if !windows.ReadFile(
        stdout_read_handle,
        raw_data(out_read_buffer),
        PIPE_BUFFER_SIZE,
        &out_amount_read,
        nil,
    ) && windows.GetLastError() != windows.ERROR_BROKEN_PIPE {
        print_last_error_message()
        return
    }

    if out_amount_read > 0 {
        process_output = cstring(raw_data(out_read_buffer))
        fmt.println(process_output)
    }

    err_read_buffer := make([]byte, PIPE_BUFFER_SIZE + 1)
    err_amount_read: u32

    if !windows.ReadFile(
        stderr_read_handle,
        raw_data(err_read_buffer),
        PIPE_BUFFER_SIZE,
        &err_amount_read,
        nil,
    ) && windows.GetLastError() != windows.ERROR_BROKEN_PIPE {
        print_last_error_message()
        return
    }

    if err_amount_read > 0 {
        process_error_output = cstring(raw_data(err_read_buffer))
        fmt.eprintln(process_error_output)
    }

    process_success = process_exit_code == 0

    return
}
