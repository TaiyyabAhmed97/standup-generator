package main

import "core:fmt"
import "core:os"
import "core:os/os2"
import "core:strings"
import "core:strconv"
import "core:time"
import "core:slice"

// ---------- Time window ----------
Time_Window :: struct {
    start: i64,
    end:   i64,
}

// Parse --since Nh (e.g., 24h). If absent, default to 24h.
parse_since_arg :: proc(args: []string) -> (string, bool) {
    for i := 0; i < len(args); i += 1 {
        if args[i] == "--since" {
            if i + 1 < len(args) {
                return args[i + 1], true
            }
            return "", false
        }
    }
    return "", false
}

resolve_window :: proc(now: i64, since: string, has_since: bool) -> (Time_Window, bool) {
    day :: 24 * 3600
    
    if has_since {
        if len(since) >= 2 && since[len(since) - 1] == 'h' {
            hours, ok := strconv.parse_i64(since[:len(since) - 1])
            if ok {
                return Time_Window{start = now - hours * 3600, end = now}, true
            }
        }
    }
    return Time_Window{start = now - day, end = now}, true
}

// ---------- Git execution (hash + subject per line) ----------
run_git_subject_lines :: proc(tw: Time_Window, allocator := context.allocator) -> (string, bool) {
    // Build git command
    since_buf: [64]byte
    until_buf: [64]byte
    
    since_str := fmt.bprintf(since_buf[:], "@%d", tw.start)
    until_str := fmt.bprintf(until_buf[:], "@%d", tw.end)
    
    args := []string{
        "git",
        "log",
        "--pretty=format:%H\t%s",
        "--no-color",
        "--since",
        since_str,
        "--until",
        until_str,
    }
    
    // Set up process descriptor
    desc := os2.Process_Desc{
        command = args
    }
    
    // Execute git command
    cmd_process, stdout, stderr, err := os2.process_exec(desc, context.allocator)
    if err != nil {
        fmt.println("exec failure")
        return "", false
    }
    
    // Read stdout
    output, alloc_err := strings.clone(string(stdout))
    if alloc_err != nil {
        fmt.println("clone  failure")
        return "", false
    }
    return output, true
}

// ---------- Ticket extraction ----------
// Find a ticket like ABC-123 in the subject:
//  - 2..10 uppercase letters
//  - '-'
//  - 1+ digits
extract_ticket :: proc(subject: string) -> (string, bool) {
    i := 0
    
    for i < len(subject) {
        // Find start of an uppercase run
        if !is_upper(subject[i]) {
            i += 1
            continue
        }
        
        start := i
        // Consume uppercase letters
        for i < len(subject) && is_upper(subject[i]) {
            i += 1
        }
        
        letters_len := i - start
        if letters_len < 2 || letters_len > 10 {
            // Too short/long to be a ticket prefix; continue scanning
            continue
        }
        
        // Require a dash next
        if i >= len(subject) || subject[i] != '-' {
            continue
        }
        i += 1 // skip '-'
        
        num_start := i
        for i < len(subject) && is_digit(subject[i]) {
            i += 1
        }
        
        if i > num_start {
            // Found <UPPER...>-<DIGITS>
            return subject[start:i], true
        }
        
        // Otherwise keep scanning after start
        i = start + 1
    }
    
    return "", false
}

is_upper :: proc(c: byte) -> bool {
    return c >= 'A' && c <= 'Z'
}

is_digit :: proc(c: byte) -> bool {
    return c >= '0' && c <= '9'
}

// ---------- Color helpers ----------
RESET :: "\x1b[0m"
BOLD :: "\x1b[1m"
DIM :: "\x1b[2m"
CYAN :: "\x1b[36m"

// Print one colored line: "[dim hash] [bold-cyan ticket] subject"
print_colored_line :: proc(hash: string, subject: string) {
    short := hash[:min(7, len(hash))]
    
    if ticket, ok := extract_ticket(subject); ok {
        fmt.printf("%s%s%s %s%s%s%s %s\n",
            DIM, short, RESET,
            BOLD, CYAN, ticket, RESET,
            subject)
    } else {
        fmt.printf("%s%s%s %s\n",
            DIM, short, RESET,
            subject)
    }
}

// ---------- Main ----------
main :: proc() {
    // Set up allocator
    context.allocator = context.temp_allocator
    
    // Get command line arguments
    args := os.args[1:] // skip program name
    
    fmt.println("Standup Summarizer—")
    fmt.println("=======================================\n")
    
    // Parse --since Nh (default 24h)
    since_val, has_since := parse_since_arg(args)
    now := i64(time.now()._nsec / 1_000_000_000) // convert to seconds
    window, ok := resolve_window(now, since_val, has_since)
    
    if !ok {
        fmt.eprintln("Error: Failed to resolve time window")
        os.exit(1)
    }
    
    // Get lines: "<hash>\t<subject>"
    stdout, success := run_git_subject_lines(window)
    if !success {
        fmt.eprintln("Error: Git command failed")
        os.exit(1)
    }
    defer delete(stdout)
    fmt.println(window)
    // Iterate and print with ticket + color
    lines := strings.split(stdout, "\n")
    defer delete(lines)
    
    count := 0
    for raw_line in lines {
        line := strings.trim_space(raw_line)
        if len(line) == 0 do continue
        
        // Split once on TAB
        tab_pos := strings.index(line, "\t");
        if  tab_pos != -1 {
            hash := line[:tab_pos]
            subj := line[tab_pos + 1:]
            print_colored_line(hash, subj)
            count += 1
        }
    }
    
    if count == 0 {
        fmt.println("(No commits in window.)")
    }
}