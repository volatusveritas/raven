package raven

import "core:os/os2"
import "core:path/filepath"

Expand_Filter :: enum {
    All,
    File,
    Directory,
}

path_has_expand_char :: proc(path: string) -> (has_expand_char: bool) {
    for i := 0; i < len(path); i += 1 {
        switch path[i] {
        case '\\':
            i += 1
        case '*', '?', '[':
            return true
        }
    }

    return false
}

path_split_last_component :: proc(path: string) -> (dirname: string, leaf: string) {
    for i := len(path) - 1; i >= 0; i -= 1 {
        if path[i] == '/' {
            if i > 0 && path[i - 1] == '\\' {
                continue
            }

            return path[:i+1], path[i+1:]
        }
    }

    return "", path
}

expand_path_collect_matches :: proc(dirname: string, pattern: string, filter := Expand_Filter.All, match_list: ^[dynamic]string) -> (ok: bool) {
    search_directory, open_dir_err := os2.open(dirname)

    if open_dir_err != nil {
        return
    }

    defer os2.close(search_directory)

    {
        search_directory_file_info, search_dir_info_err := os2.fstat(search_directory, context.allocator)

        if search_dir_info_err != nil {
            return
        }

        defer os2.file_info_delete(search_directory_file_info, context.allocator)

        if search_directory_file_info.type != .Directory {
            return
        }
    }

    file_info_list, read_dir_err := os2.read_directory(search_directory, -1, context.allocator)

    if read_dir_err != nil {
        return
    }

    defer {
        for file_info in file_info_list {
            os2.file_info_delete(file_info, context.allocator)
        }

        delete(file_info_list)
    }

    expected_file_type: os2.File_Type

    switch filter {
    case .All:
        // Do nothing
    case .File:
        expected_file_type = .Regular
    case .Directory:
        expected_file_type = .Directory
    }

    for file_info in file_info_list {
        if filter != .All && file_info.type != expected_file_type {
            continue
        }

        file_matches_pattern, match_err := filepath.match(pattern, file_info.name)

        if match_err != nil {
            return false
        }

        if file_matches_pattern {
            append(match_list, filepath.join({dirname, file_info.name}))
        }
    }

    return true
}

expand_path :: proc(pattern: string, filter := Expand_Filter.All) -> (matches: []string, ok: bool) {
    if !path_has_expand_char(pattern) {
        matches = make([]string, 1)
        matches[0] = pattern
        return matches, true
    }

    dirname, leaf := path_split_last_component(pattern)

    switch dirname {
    case "":
        dirname = "."
    case "/":
        // Do nothing
    case:
        dirname = dirname[:len(dirname) - 1]
    }

    match_list: [dynamic]string

    if !path_has_expand_char(dirname) {
        expand_path_collect_matches(dirname, leaf, filter, &match_list) or_return
        return match_list[:], true
    }

    parent_matches := expand_path(dirname, .Directory) or_return
    defer delete(parent_matches)

    for search_directory in parent_matches {
        expand_path_collect_matches(search_directory, leaf, filter, &match_list) or_return
    }

    return match_list[:], true
}
