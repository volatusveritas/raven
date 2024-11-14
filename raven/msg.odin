package raven

import "core:encoding/ansi"
import "core:fmt"

/*
Error message convention:

- Error messages use a context to convey from which environment they come from,
  appended to the start of each error message in parenthesis.

- Prefer the form "could not <attempted action> [(specific reason)]"
*/

COLOR_RESET :: ansi.CSI + ansi.RESET + ansi.SGR
COLOR_ERROR :: ansi.CSI + ansi.FG_BRIGHT_RED + ansi.SGR
COLOR_SUCCESS :: ansi.CSI + ansi.FG_BRIGHT_GREEN + ansi.SGR
COLOR_IDENTIFIER :: ansi.CSI + ansi.FG_BRIGHT_BLUE + ansi.SGR
COLOR_CONTEXT :: ansi.CSI + ansi.FG_BRIGHT_YELLOW + ansi.SGR

MessageContext :: enum {
    RAVEN,
    LUA,
}

message_context_get_name :: proc(
    message_context: MessageContext,
) -> (
    context_name: string
) {
    switch message_context {
    case .RAVEN:
        return "Raven"
    case .LUA:
        return "Lua"
    case:
        return "Unknown"
    }
}

print_msg :: proc(
    message_context: MessageContext,
    message: string,
    args: ..any,
) -> (
) {
    context_name := message_context_get_name(message_context)

    formatted_message := fmt.aprintf(message, ..args)
    defer delete(formatted_message)

    fmt.printfln("%s(%s) %s%s", COLOR_CONTEXT, context_name, COLOR_RESET, formatted_message)
}

print_error :: proc(
    message_context: MessageContext,
    message: string,
    args: ..any,
) -> (
) {
    message_context_name := message_context_get_name(message_context)

    formatted_error_message := fmt.aprintf(message, ..args)
    defer delete(formatted_error_message)

    fmt.eprintfln(
        "%s(%s) %sError %s:: %s",
        COLOR_CONTEXT,
        message_context_name,
        COLOR_ERROR,
        COLOR_RESET,
        formatted_error_message,
    )
}

