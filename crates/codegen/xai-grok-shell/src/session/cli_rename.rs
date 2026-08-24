//! `grok sessions rename` — persist a manual title (or unpin) without the TUI.
//!
//! Disk write uses the same `update_session_title` / `reset_title_to_auto`
//! path as `x.ai/session/rename`. A running pager still needs the ACP
//! notification to live-update; hook `sessionTitle` covers that for the
//! in-session autoname path. This CLI is for dormant sessions, scripts, and
//! the autoname `--print` + user `/rename` flow.

use std::io;
use std::path::PathBuf;

use crate::session::info::Info;
use crate::session::persistence::{
    MAX_TITLE_SCALARS, sanitize_rename_title,
};
use crate::session::storage::{JsonlStorageAdapter, StorageAdapter};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CliRenameOutcome {
    pub session_id: String,
    pub cwd: String,
    pub title: Option<String>,
    pub reset: bool,
}

#[derive(Debug, thiserror::Error)]
pub enum CliRenameError {
    #[error("title must not be blank")]
    BlankTitle,
    #[error("title too long (max {MAX_TITLE_SCALARS} characters)")]
    TitleTooLong,
    #[error("no session found with id {0}")]
    NotFound(String),
    #[error("failed to list sessions: {0}")]
    List(#[source] io::Error),
    #[error("failed to update session title: {0}")]
    Write(#[source] io::Error),
}

/// Rename (`Some(title)`) or unpin (`None`) the session `id` under `root`.
pub async fn rename_session_in(
    root: PathBuf,
    id: &str,
    title: Option<&str>,
) -> Result<CliRenameOutcome, CliRenameError> {
    let storage = JsonlStorageAdapter::with_root(root);
    let summaries = storage
        .list_sessions(None)
        .await
        .map_err(CliRenameError::List)?;
    let summary = summaries
        .iter()
        .find(|s| s.info.id.0.as_ref() == id)
        .ok_or_else(|| CliRenameError::NotFound(id.to_string()))?;
    let info: Info = summary.info.clone();

    if let Some(raw) = title {
        let cleaned = sanitize_rename_title(raw);
        if cleaned.is_empty() {
            return Err(CliRenameError::BlankTitle);
        }
        if cleaned.chars().count() > MAX_TITLE_SCALARS {
            return Err(CliRenameError::TitleTooLong);
        }
        let title = cleaned.into_owned();
        storage
            .update_session_title(&info, title.clone())
            .await
            .map_err(CliRenameError::Write)?;
        crate::session::storage::search::notify_session_updated(
            None,
            &info.id.to_string(),
            &info.cwd,
        );
        Ok(CliRenameOutcome {
            session_id: id.to_string(),
            cwd: info.cwd,
            title: Some(title),
            reset: false,
        })
    } else {
        let _cleared = storage
            .reset_title_to_auto(&info)
            .await
            .map_err(CliRenameError::Write)?;
        crate::session::storage::search::notify_session_updated(
            None,
            &info.id.to_string(),
            &info.cwd,
        );
        Ok(CliRenameOutcome {
            session_id: id.to_string(),
            cwd: info.cwd,
            title: None,
            reset: true,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::persistence::default_model_id;
    use tempfile::TempDir;

    #[tokio::test]
    async fn rename_pins_manual_title_and_reset_unpins() {
        let temp = TempDir::new().unwrap();
        let adapter = JsonlStorageAdapter::with_root(temp.path().to_path_buf());
        let info = Info {
            id: agent_client_protocol::SessionId::new("cli-rename-1"),
            cwd: "/tmp/cli-rename".into(),
        };
        adapter
            .init_session(&info, default_model_id())
            .await
            .unwrap();

        let out = rename_session_in(
            temp.path().to_path_buf(),
            "cli-rename-1",
            Some("parked-arx-console"),
        )
        .await
        .unwrap();
        assert_eq!(out.title.as_deref(), Some("parked-arx-console"));
        let summary = adapter.load_summary(&info).await.unwrap();
        assert!(summary.title_is_manual);
        assert_eq!(summary.generated_title.as_deref(), Some("parked-arx-console"));

        rename_session_in(temp.path().to_path_buf(), "cli-rename-1", None)
            .await
            .unwrap();
        let summary = adapter.load_summary(&info).await.unwrap();
        assert!(!summary.title_is_manual);

        let err = rename_session_in(temp.path().to_path_buf(), "missing", Some("x"))
            .await
            .unwrap_err();
        assert!(matches!(err, CliRenameError::NotFound(_)));
        let err = rename_session_in(temp.path().to_path_buf(), "cli-rename-1", Some("   "))
            .await
            .unwrap_err();
        assert!(matches!(err, CliRenameError::BlankTitle));
    }
}
