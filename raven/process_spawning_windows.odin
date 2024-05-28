package raven

import "core:fmt"
import "core:math"
import "core:slice"
import "core:sys/windows"
import "core:unicode/utf16"
import "core:unicode/utf8"

PIPE_BUFFER_SIZE :: 4096

print_last_error_message :: proc() {
    error_message_flags: u32 = (
        windows.FORMAT_MESSAGE_FROM_SYSTEM
        | windows.FORMAT_MESSAGE_IGNORE_INSERTS
        | windows.FORMAT_MESSAGE_ALLOCATE_BUFFER
        | windows.FORMAT_MESSAGE_MAX_WIDTH_MASK
    )

    p: rawptr
    message_length := windows.FormatMessageW(error_message_flags, nil, windows.GetLastError(), 0, (^u16)(&p), 0, nil)

    if message_length == 0 || p == nil {
        error("Raven was unable to format a Windows error message (FormatMessageW error, code %d)", windows.GetLastError())
        return
    }

    error_message := slice.from_ptr((^u16)(p), int(message_length))
    error("[Windows] %s", windows.utf16_to_utf8(error_message))
}

spawn_and_run_process :: proc(cmd: string) {
    wide_cmd_buf := make([]u16, utf8.rune_count(cmd))
    utf16.encode_string(wide_cmd_buf, cmd)

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

    fmt.println(cmd)

    if !windows.CreateProcessW(
        nil,
        &wide_cmd_buf[0],
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

    read_buffer := make([]byte, PIPE_BUFFER_SIZE)
    amount_read: u32

    if !windows.ReadFile(
        stdout_read_handle,
        raw_data(read_buffer),
        PIPE_BUFFER_SIZE,
        &amount_read,
        nil,
    ) {
        print_last_error_message()
        return
    }

    fmt.println(transmute(string)read_buffer[:amount_read])
}
