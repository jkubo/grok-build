use std::time::Duration;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HookDecision {
    Allow,
    Ask {
        hook_name: String,
        reason: Option<String>,
    },
    Defer {
        hook_name: String,
    },
    Deny {
        hook_name: String,
        reason: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PromptDecision {
    Allow,
    Block { reason: String, hook_name: String },
}

/// Side effects a hook may request without gating the event.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HookEffects {
    pub session_title: Option<String>,
    pub terminal_sequence: Option<String>,
}

impl HookEffects {
    pub fn is_empty(&self) -> bool {
        self.session_title.is_none() && self.terminal_sequence.is_none()
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct StopHookOutcome {
    pub block_reason: Option<String>,
    pub additional_context: Option<String>,
    pub force_stop: Option<StopOverride>,
    pub session_title: Option<String>,
    pub terminal_sequence: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct StopOverride {
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReplacementKind {
    Builtin,
    Mcp,
}

impl ReplacementKind {
    pub fn wire_field(self) -> &'static str {
        match self {
            Self::Builtin => "updatedToolOutput",
            Self::Mcp => "updatedMCPToolOutput",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct OutputReplacement {
    pub kind: ReplacementKind,
    pub hook_name: String,
    pub value: serde_json::Value,
}

impl OutputReplacement {
    pub fn wire_field(&self) -> &'static str {
        self.kind.wire_field()
    }
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct PostToolUseHookOutcome {
    pub block_reason: Option<String>,
    pub additional_context: Option<String>,
    pub output_replacement: Option<OutputReplacement>,
}

impl PostToolUseHookOutcome {
    pub fn is_empty(&self) -> bool {
        self.block_reason.is_none()
            && self.additional_context.is_none()
            && self.output_replacement.is_none()
    }
}

impl StopHookOutcome {
    pub fn is_empty(&self) -> bool {
        self.block_reason.is_none()
            && self.additional_context.is_none()
            && self.force_stop.is_none()
            && self.session_title.is_none()
            && self.terminal_sequence.is_none()
    }
}

#[derive(Debug, Clone)]
pub struct HttpInfo {
    pub expanded_url: String,
    pub source_url: Option<String>,
    pub status: Option<u16>,
    pub response_preview: Option<String>,
}

#[derive(Debug)]
pub enum HookRunResult {
    Success {
        hook_name: String,
        elapsed: Duration,
        http_info: Option<HttpInfo>,
        system_message: Option<String>,
        session_title: Option<String>,
        terminal_sequence: Option<String>,
    },
    Skipped {
        hook_name: String,
    },
    Blocked {
        hook_name: String,
        detail: String,
        elapsed: Duration,
        http_info: Option<HttpInfo>,
        system_message: Option<String>,
    },
    Failed {
        hook_name: String,
        error: String,
        elapsed: Duration,
        http_info: Option<HttpInfo>,
        system_message: Option<String>,
    },
}

impl HookRunResult {
    pub fn success(hook_name: String, elapsed: Duration, http_info: Option<HttpInfo>) -> Self {
        Self::with_message(hook_name, elapsed, http_info, None)
    }

    pub fn with_message(
        hook_name: String,
        elapsed: Duration,
        http_info: Option<HttpInfo>,
        system_message: Option<String>,
    ) -> Self {
        Self::Success {
            hook_name,
            elapsed,
            http_info,
            system_message,
            session_title: None,
            terminal_sequence: None,
        }
    }

    pub fn observe_effects(&self) -> HookEffects {
        match self {
            Self::Success {
                session_title,
                terminal_sequence,
                ..
            } => HookEffects {
                session_title: session_title.clone(),
                terminal_sequence: terminal_sequence.clone(),
            },
            _ => HookEffects::default(),
        }
    }
}

