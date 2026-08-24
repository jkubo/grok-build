//! Allowlist for hook-emitted terminal escape sequences.
//!
//! Claude Code writes `hookSpecificOutput.terminalSequence` itself (never
//! `/dev/tty` from the hook). Grok does the same: the hook returns a string,
//! this module admits only OSC 0/1/2 (title), OSC 9/99/777 (notify), and BEL.
//! OSC 52 (clipboard), CSI, DCS, and nested ESC are rejected.

/// Max bytes of a hook-emitted sequence. Titles and notify bodies are short;
/// a 512-byte cap stops a hook flooding the TTY.
pub const MAX_TERMINAL_SEQUENCE_BYTES: usize = 512;

/// Admit a hook `terminalSequence` or return `None`.
///
/// Accepted forms (one sequence, one terminator):
/// - BEL (`\x07`)
/// - `ESC ] 0|1|2 ; <title> BEL` or ST (`ESC \`)
/// - `ESC ] 9 ; <msg> BEL` (iTerm2/WezTerm notify)
/// - `ESC ] 99 ; ... ST` (Kitty notify)
/// - `ESC ] 777 ; notify ; ... ST|BEL` (Ghostty/VTE notify)
pub fn sanitize_terminal_sequence(raw: &str) -> Option<String> {
    if raw.is_empty() || raw.len() > MAX_TERMINAL_SEQUENCE_BYTES {
        return None;
    }
    if raw == "\u{07}" {
        return Some(raw.to_string());
    }
    let rest = raw.strip_prefix("\u{1b}]")?;
    let payload = if let Some(p) = rest.strip_suffix('\u{07}') {
        p
    } else if let Some(p) = rest.strip_suffix("\u{1b}\\") {
        p
    } else {
        return None;
    };
    if payload.contains('\u{1b}') || payload.contains('\u{07}') {
        return None;
    }
    let ps = payload.split(';').next().unwrap_or("");
    match ps {
        "0" | "1" | "2" | "9" | "99" | "777" => Some(raw.to_string()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn admits_bel_and_title_osc() {
        assert_eq!(sanitize_terminal_sequence("\u{07}").as_deref(), Some("\u{07}"));
        assert_eq!(
            sanitize_terminal_sequence("\u{1b}]0;parked-arx-console\u{07}").as_deref(),
            Some("\u{1b}]0;parked-arx-console\u{07}")
        );
        assert!(sanitize_terminal_sequence("\u{1b}]2;hi\u{1b}\\").is_some());
        assert!(sanitize_terminal_sequence("\u{1b}]9;done\u{07}").is_some());
        assert!(sanitize_terminal_sequence("\u{1b}]99;i=grok;done\u{1b}\\").is_some());
        assert!(sanitize_terminal_sequence("\u{1b}]777;notify;Grok;done\u{07}").is_some());
    }

    #[test]
    fn rejects_clipboard_csi_nested_esc_and_overlong() {
        assert!(sanitize_terminal_sequence("\u{1b}]52;c;QUFB\u{07}").is_none());
        assert!(sanitize_terminal_sequence("\u{1b}[31mred").is_none());
        assert!(sanitize_terminal_sequence("\u{1b}]0;evil\u{1b}]52;c;x\u{07}\u{07}").is_none());
        assert!(sanitize_terminal_sequence("not-an-osc").is_none());
        assert!(sanitize_terminal_sequence("").is_none());
        let huge = format!("\u{1b}]0;{}\u{07}", "x".repeat(MAX_TERMINAL_SEQUENCE_BYTES));
        assert!(sanitize_terminal_sequence(&huge).is_none());
    }
}
