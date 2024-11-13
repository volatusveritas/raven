package raven

import "core:os"
import "core:os/os2"
import "core:strings"

PIPE_BUFFER_SIZE :: 4096

run :: proc(
    command_parts: []string,
) -> (
    process_exit_code: int,
    stdout: []byte,
    stderr: []byte,
    ok: bool,
) {
    assert(len(command_parts) > 0, "Command parts should have at least one item")

    stdout_read_handle, stdout_write_handle, stdout_pipe_err := os2.pipe()
    if stdout_pipe_err != nil {
        print_error(.RAVEN, "could not create process stdout pipe")
        ok = false
        return
    }
    defer os2.close(stdout_read_handle)
    stderr_read_handle, stderr_write_handle, stderr_pipe_err := os2.pipe()
    if stderr_pipe_err != nil {
        print_error(.RAVEN, "could not create process stderr pipe")
        ok = false
        return
    }
    defer os2.close(stderr_read_handle)
    stdin_read_handle, stdin_write_handle, stdin_pipe_err := os2.pipe()

    process_handle: os2.Process
    {
        defer os2.close(stdout_write_handle)
        defer os2.close(stderr_write_handle)

        process_desc := os2.Process_Desc {
            command = command_parts,
            stdout = stdout_write_handle,
            stderr = stderr_write_handle,
            stdin = os2.stdin,
        }

        process_err: os2.Error
        process_handle, process_err = os2.process_start(process_desc)
        if process_err != nil {
            print_error(.RAVEN, "could not start process")
            ok = false
            return
        }
    }

    stdout_builder, stdout_builder_err := strings.builder_make()

    if stdout_builder_err != .None {
        print_error(.RAVEN, "could not allocate string builder for program stdout")
        ok = false
        return
    }

    stderr_builder, stderr_builder_err := strings.builder_make()

    if stderr_builder_err != .None {
        print_error(.RAVEN, "failed to allocate string builder for program stderr")
        ok = false
        return
    }

    stdout_done := false
    stderr_done := false
    err := false

    read_buffer: [PIPE_BUFFER_SIZE]byte

    for !err && !(stdout_done && stderr_done) {
        if !stdout_done {
            has_data, has_data_err := os2.pipe_has_data(stdout_read_handle)

            if has_data_err == .Broken_Pipe {
                stdout_done = true
            } else if has_data_err != nil {
                print_error(.RAVEN, "could not query process stdout data availability (%v)", has_data_err)
                err = true
                break
            }

            if has_data {
                read_amount, read_err := os2.read(stdout_read_handle, read_buffer[:])

                if read_err != nil {
                    stdout_done = true
                } else {
                    new_content := read_buffer[:read_amount]
                    strings.write_bytes(&stdout_builder, new_content)
                    _, console_write_err := os2.write(os2.stdout, new_content)

                    if console_write_err != nil {
                        print_error(.RAVEN, "could not write process stdout to console")
                        err = true
                        break
                    }
                }
            }
        }

        if !stderr_done {
            has_data, has_data_err := os2.pipe_has_data(stderr_read_handle)

            if has_data_err == .Broken_Pipe {
                stderr_done = true
            } else if has_data_err != nil {
                print_error(.RAVEN, "could not query process stderr data availability")
                err = true
                break
            }

            if has_data {
                read_amount, read_err := os2.read(stderr_read_handle, read_buffer[:])

                if read_err != nil {
                    stderr_done = true
                } else {
                    new_content := read_buffer[:read_amount]
                    strings.write_bytes(&stderr_builder, new_content)
                    _, console_write_err := os2.write(os2.stderr, new_content)

                    if console_write_err != nil {
                        print_error(.RAVEN, "could not write process stderr to console")
                        err = true
                        break
                    }
                }
            }
        }
    }

    if err {
        state, _ := os2.process_wait(process_handle, 0)

        if !state.exited {
            _ = os2.process_kill(process_handle)
            ok = false
            return
        }
    }

    state, state_err := os2.process_wait(process_handle)

    if state_err != nil {
        print_error(.RAVEN, "could not query process state")
        strings.builder_destroy(&stdout_builder)
        strings.builder_destroy(&stderr_builder)
        ok = false
        return
    }

    process_exit_code = state.exit_code
    stdout = stdout_builder.buf[:]
    stderr = stderr_builder.buf[:]
    ok = true

    return
}
