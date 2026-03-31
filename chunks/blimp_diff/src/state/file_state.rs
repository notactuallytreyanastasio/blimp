use crate::types::{FileEntry, Status};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileState {
    Untracked,
    StagedNew,
    UnstagedModified,
    StagedModified,
    PartialModified,
    UnstagedDeleted,
    StagedDeleted,
    StagedRenamed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GitCommand {
    Add(String),
    RmCached(String),
    RestoreStaged(String),
}

pub fn classify(entry: &FileEntry) -> FileState {
    match (entry.staged, entry.unstaged) {
        (Status::None, Status::Untracked) => FileState::Untracked,
        (Status::Added, Status::None) => FileState::StagedNew,
        (Status::None, Status::Modified) => FileState::UnstagedModified,
        (Status::Modified, Status::None) => FileState::StagedModified,
        (Status::Modified, Status::Modified) => FileState::PartialModified,
        (Status::None, Status::Deleted) => FileState::UnstagedDeleted,
        (Status::Deleted, Status::None) => FileState::StagedDeleted,
        (Status::Renamed, _) => FileState::StagedRenamed,
        (Status::Added, Status::Modified) => FileState::PartialModified,
        _ => FileState::Untracked,
    }
}

pub fn stage_command(state: FileState, path: &str) -> Option<GitCommand> {
    match state {
        FileState::Untracked
        | FileState::UnstagedModified
        | FileState::UnstagedDeleted
        | FileState::PartialModified => Some(GitCommand::Add(path.to_string())),
        FileState::StagedNew
        | FileState::StagedModified
        | FileState::StagedDeleted
        | FileState::StagedRenamed => None,
    }
}

pub fn unstage_command(state: FileState, path: &str) -> Option<GitCommand> {
    match state {
        FileState::StagedNew => Some(GitCommand::RmCached(path.to_string())),
        FileState::StagedModified
        | FileState::StagedDeleted
        | FileState::StagedRenamed
        | FileState::PartialModified => Some(GitCommand::RestoreStaged(path.to_string())),
        FileState::Untracked | FileState::UnstagedModified | FileState::UnstagedDeleted => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(staged: Status, unstaged: Status) -> FileEntry {
        FileEntry {
            path: "test.rs".into(),
            orig_path: None,
            staged,
            unstaged,
        }
    }

    // -- classify tests --

    #[test]
    fn classify_untracked() {
        assert_eq!(classify(&entry(Status::None, Status::Untracked)), FileState::Untracked);
    }

    #[test]
    fn classify_staged_new() {
        assert_eq!(classify(&entry(Status::Added, Status::None)), FileState::StagedNew);
    }

    #[test]
    fn classify_unstaged_modified() {
        assert_eq!(classify(&entry(Status::None, Status::Modified)), FileState::UnstagedModified);
    }

    #[test]
    fn classify_staged_modified() {
        assert_eq!(classify(&entry(Status::Modified, Status::None)), FileState::StagedModified);
    }

    #[test]
    fn classify_partial_modified() {
        assert_eq!(classify(&entry(Status::Modified, Status::Modified)), FileState::PartialModified);
    }

    #[test]
    fn classify_unstaged_deleted() {
        assert_eq!(classify(&entry(Status::None, Status::Deleted)), FileState::UnstagedDeleted);
    }

    #[test]
    fn classify_staged_deleted() {
        assert_eq!(classify(&entry(Status::Deleted, Status::None)), FileState::StagedDeleted);
    }

    #[test]
    fn classify_staged_renamed() {
        assert_eq!(classify(&entry(Status::Renamed, Status::None)), FileState::StagedRenamed);
    }

    // -- stage_command tests --

    #[test]
    fn stage_untracked_adds() {
        assert_eq!(
            stage_command(FileState::Untracked, "test.rs"),
            Some(GitCommand::Add("test.rs".into()))
        );
    }

    #[test]
    fn stage_unstaged_modified_adds() {
        assert_eq!(
            stage_command(FileState::UnstagedModified, "test.rs"),
            Some(GitCommand::Add("test.rs".into()))
        );
    }

    #[test]
    fn stage_unstaged_deleted_adds() {
        assert_eq!(
            stage_command(FileState::UnstagedDeleted, "test.rs"),
            Some(GitCommand::Add("test.rs".into()))
        );
    }

    #[test]
    fn stage_already_staged_is_noop() {
        assert_eq!(stage_command(FileState::StagedNew, "test.rs"), None);
        assert_eq!(stage_command(FileState::StagedModified, "test.rs"), None);
        assert_eq!(stage_command(FileState::StagedDeleted, "test.rs"), None);
        assert_eq!(stage_command(FileState::StagedRenamed, "test.rs"), None);
    }

    #[test]
    fn stage_partial_adds() {
        assert_eq!(
            stage_command(FileState::PartialModified, "test.rs"),
            Some(GitCommand::Add("test.rs".into()))
        );
    }

    // -- unstage_command tests --

    #[test]
    fn unstage_staged_new_rm_cached() {
        assert_eq!(
            unstage_command(FileState::StagedNew, "test.rs"),
            Some(GitCommand::RmCached("test.rs".into()))
        );
    }

    #[test]
    fn unstage_staged_modified_restores() {
        assert_eq!(
            unstage_command(FileState::StagedModified, "test.rs"),
            Some(GitCommand::RestoreStaged("test.rs".into()))
        );
    }

    #[test]
    fn unstage_staged_deleted_restores() {
        assert_eq!(
            unstage_command(FileState::StagedDeleted, "test.rs"),
            Some(GitCommand::RestoreStaged("test.rs".into()))
        );
    }

    #[test]
    fn unstage_staged_renamed_restores() {
        assert_eq!(
            unstage_command(FileState::StagedRenamed, "test.rs"),
            Some(GitCommand::RestoreStaged("test.rs".into()))
        );
    }

    #[test]
    fn unstage_not_staged_is_noop() {
        assert_eq!(unstage_command(FileState::Untracked, "test.rs"), None);
        assert_eq!(unstage_command(FileState::UnstagedModified, "test.rs"), None);
        assert_eq!(unstage_command(FileState::UnstagedDeleted, "test.rs"), None);
    }

    #[test]
    fn unstage_partial_restores() {
        assert_eq!(
            unstage_command(FileState::PartialModified, "test.rs"),
            Some(GitCommand::RestoreStaged("test.rs".into()))
        );
    }
}
