package raven

import "core:unicode/utf16"
import "core:unicode/utf8"
import "core:sys/windows"

spawn_process :: proc(cmd: string) {
    wide_cmd_buf := make([]u16, utf8.rune_count(cmd))
    // TODO(volatus): check if this returns the right amount of chars
    utf16.encode_string(wide_cmd_buf, cmd)

    process_info: windows.PROCESS_INFORMATION
    startup_info: windows.STARTUPINFOW

    windows.GetStartupInfoW(&startup_info)

    // TODO(volatus): treat error
    windows.CreateProcessW(
        nil,
        &wide_cmd_buf[0],
        nil,
        nil,
        false,
        0,
        nil,
        nil,
        &startup_info,
        &process_info,
    )
}
