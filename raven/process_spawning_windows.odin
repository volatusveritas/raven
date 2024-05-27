package raven

import "core:fmt"
import "core:unicode/utf16"
import "core:unicode/utf8"
import "core:sys/windows"

PIPE_BUFFER_SIZE :: 4096

spawn_and_run_process :: proc(cmd: string) {
    wide_cmd_buf := make([]u16, utf8.rune_count(cmd))
    // TODO(volatus): check if this returns the right amount of chars
    utf16.encode_string(wide_cmd_buf, cmd)

    security_attributes := windows.SECURITY_ATTRIBUTES {
        nLength = size_of(windows.SECURITY_ATTRIBUTES),
        lpSecurityDescriptor = nil,
        bInheritHandle = true,
    }

    child_stdout_handle_read: windows.HANDLE
    child_stdout_handle_write: windows.HANDLE

    // TODO(volatus): handle this error
    windows.CreatePipe(
        &child_stdout_handle_read,
        &child_stdout_handle_write,
        &security_attributes,
        0,
    )

    // TODO(volatus): handle this error
    windows.SetHandleInformation(
        child_stdout_handle_read,
        windows.HANDLE_FLAG_INHERIT,
        0,
    )

    child_stdin_handle_read: windows.HANDLE
    child_stdin_handle_write: windows.HANDLE

    // TODO(volatus): handle this error
    windows.CreatePipe(
        &child_stdin_handle_read,
        &child_stdin_handle_write,
        &security_attributes,
        0,
    )

    // TODO(volatus): handle this error
    windows.SetHandleInformation(
        child_stdin_handle_write,
        windows.HANDLE_FLAG_INHERIT,
        0,
    )

    process_info: windows.PROCESS_INFORMATION

    startup_info := windows.STARTUPINFOW {
        cb = size_of(windows.STARTUPINFOW),
        hStdInput = child_stdin_handle_read,
        hStdOutput = child_stdout_handle_write,
        hStdError = child_stdout_handle_write,
        dwFlags = windows.STARTF_USESTDHANDLES,
    }

    fmt.println(cmd)

    // TODO(volatus): treat error
    windows.CreateProcessW(
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
    )

    windows.CloseHandle(child_stdout_handle_write)
    windows.CloseHandle(child_stdin_handle_read)

    read_buffer := make([]byte, PIPE_BUFFER_SIZE)
    amount_read: u32

    // TODO(volatus): handle possible error
    windows.ReadFile(
        child_stdout_handle_read,
        raw_data(read_buffer),
        PIPE_BUFFER_SIZE,
        &amount_read,
        nil,
    )

    fmt.println(transmute(string)read_buffer[:amount_read])
}
