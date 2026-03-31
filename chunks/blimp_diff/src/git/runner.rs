use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

use crate::state::file_state::GitCommand;

const TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Debug)]
pub struct GitRunner {
    repo_path: PathBuf,
}

#[derive(Debug)]
pub enum GitError {
    CommandFailed { stderr: String, code: Option<i32> },
    Timeout,
    Io(std::io::Error),
}

impl std::fmt::Display for GitError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            GitError::CommandFailed { stderr, code } => {
                write!(f, "git failed (exit {:?}): {}", code, stderr)
            }
            GitError::Timeout => write!(f, "git command timed out"),
            GitError::Io(e) => write!(f, "io error: {}", e),
        }
    }
}

impl From<std::io::Error> for GitError {
    fn from(e: std::io::Error) -> Self {
        GitError::Io(e)
    }
}

type Result<T> = std::result::Result<T, GitError>;

impl GitRunner {
    pub fn new(repo_path: PathBuf) -> Self {
        Self { repo_path }
    }

    pub fn status(&self) -> Result<String> {
        self.run(&["status", "--porcelain=v1", "-u"])
    }

    pub fn diff(&self) -> Result<String> {
        self.run(&["diff"])
    }

    pub fn diff_staged(&self) -> Result<String> {
        self.run(&["diff", "--staged"])
    }

    pub fn diff_untracked(&self, file: &str) -> Result<String> {
        // git diff --no-index returns exit code 1 when there are differences
        self.run_with_expected_exits(&["diff", "--no-index", "/dev/null", file], &[0, 1])
    }

    pub fn branch(&self) -> Result<String> {
        let output = self.run(&["rev-parse", "--abbrev-ref", "HEAD"])?;
        Ok(output.trim().to_string())
    }

    pub fn log_oneline(&self) -> Result<String> {
        self.run(&["log", "--oneline", "-50"])
    }

    pub fn log_show(&self, hash: &str) -> Result<String> {
        self.run(&["show", hash, "--stat", "--format=full"])
    }

    pub fn log_diff(&self, hash: &str) -> Result<String> {
        self.run(&["show", hash, "--format="])
    }

    pub fn stage(&self, path: &str) -> Result<()> {
        self.run(&["add", path])?;
        Ok(())
    }

    pub fn unstage_rm_cached(&self, path: &str) -> Result<()> {
        self.run(&["rm", "--cached", path])?;
        Ok(())
    }

    pub fn unstage_restore(&self, path: &str) -> Result<()> {
        self.run(&["restore", "--staged", path])?;
        Ok(())
    }

    pub fn commit(&self, message: &str) -> Result<()> {
        self.run(&["commit", "-m", message])?;
        Ok(())
    }

    pub fn commit_amend(&self, message: &str) -> Result<()> {
        self.run(&["commit", "--amend", "-m", message])?;
        Ok(())
    }

    pub fn exec_git_command(&self, cmd: &GitCommand) -> Result<()> {
        match cmd {
            GitCommand::Add(path) => self.stage(path),
            GitCommand::RmCached(path) => self.unstage_rm_cached(path),
            GitCommand::RestoreStaged(path) => self.unstage_restore(path),
        }
    }

    pub fn open_editor(&self, file: &str) -> Result<()> {
        let editor = std::env::var("EDITOR").unwrap_or_else(|_| "vim".to_string());
        let file_path = self.repo_path.join(file);
        Command::new(&editor)
            .arg(&file_path)
            .spawn()?;
        Ok(())
    }

    fn run(&self, args: &[&str]) -> Result<String> {
        self.run_with_expected_exits(args, &[0])
    }

    fn run_with_expected_exits(&self, args: &[&str], expected: &[i32]) -> Result<String> {
        let output = Command::new("git")
            .args(args)
            .current_dir(&self.repo_path)
            .output()?;

        let code = output.status.code();
        if let Some(c) = code {
            if expected.contains(&c) {
                return Ok(String::from_utf8_lossy(&output.stdout).to_string());
            }
        }

        Err(GitError::CommandFailed {
            stderr: String::from_utf8_lossy(&output.stderr).to_string(),
            code,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::git::status::parse_status;
    use crate::git::diff::parse_diff;
    use crate::git::log::parse_log;
    use crate::types::Status;
    use std::fs;

    fn temp_repo() -> (tempfile::TempDir, GitRunner) {
        let dir = tempfile::tempdir().unwrap();
        let runner = GitRunner::new(dir.path().to_path_buf());

        // Init repo with initial commit
        Command::new("git")
            .args(["init"])
            .current_dir(dir.path())
            .output()
            .unwrap();
        Command::new("git")
            .args(["config", "user.email", "test@test.com"])
            .current_dir(dir.path())
            .output()
            .unwrap();
        Command::new("git")
            .args(["config", "user.name", "Test"])
            .current_dir(dir.path())
            .output()
            .unwrap();

        // Initial commit so HEAD exists
        fs::write(dir.path().join("README.md"), "# test\n").unwrap();
        Command::new("git")
            .args(["add", "README.md"])
            .current_dir(dir.path())
            .output()
            .unwrap();
        Command::new("git")
            .args(["commit", "-m", "initial commit"])
            .current_dir(dir.path())
            .output()
            .unwrap();

        (dir, runner)
    }

    #[test]
    fn status_clean_repo() {
        let (_dir, runner) = temp_repo();
        let output = runner.status().unwrap();
        assert!(output.is_empty());
    }

    #[test]
    fn status_with_modified_file() {
        let (dir, runner) = temp_repo();
        fs::write(dir.path().join("README.md"), "# changed\n").unwrap();

        let output = runner.status().unwrap();
        let entries = parse_status(&output);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path, "README.md");
        assert_eq!(entries[0].unstaged, Status::Modified);
    }

    #[test]
    fn status_with_untracked_file() {
        let (dir, runner) = temp_repo();
        fs::write(dir.path().join("new.txt"), "hello\n").unwrap();

        let output = runner.status().unwrap();
        let entries = parse_status(&output);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].unstaged, Status::Untracked);
    }

    #[test]
    fn diff_shows_changes() {
        let (dir, runner) = temp_repo();
        fs::write(dir.path().join("README.md"), "# changed\n").unwrap();

        let output = runner.diff().unwrap();
        let diffs = parse_diff(&output);
        assert_eq!(diffs.len(), 1);
        assert_eq!(diffs[0].path, "README.md");
        assert!(diffs[0].additions > 0 || diffs[0].deletions > 0);
    }

    #[test]
    fn diff_staged_after_add() {
        let (dir, runner) = temp_repo();
        fs::write(dir.path().join("README.md"), "# staged change\n").unwrap();
        runner.stage("README.md").unwrap();

        let unstaged = runner.diff().unwrap();
        assert!(unstaged.is_empty()); // nothing unstaged

        let staged = runner.diff_staged().unwrap();
        let diffs = parse_diff(&staged);
        assert_eq!(diffs.len(), 1);
    }

    #[test]
    fn branch_name() {
        let (_dir, runner) = temp_repo();
        let branch = runner.branch().unwrap();
        // Default branch is "main" or "master" depending on git config
        assert!(!branch.is_empty());
    }

    #[test]
    fn log_has_initial_commit() {
        let (_dir, runner) = temp_repo();
        let output = runner.log_oneline().unwrap();
        let entries = parse_log(&output);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].message, "initial commit");
    }

    #[test]
    fn stage_and_commit() {
        let (dir, runner) = temp_repo();
        fs::write(dir.path().join("new.rs"), "fn main() {}\n").unwrap();
        runner.stage("new.rs").unwrap();
        runner.commit("add new.rs").unwrap();

        let output = runner.log_oneline().unwrap();
        let entries = parse_log(&output);
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].message, "add new.rs");
    }

    #[test]
    fn commit_amend() {
        let (dir, runner) = temp_repo();
        fs::write(dir.path().join("fix.rs"), "fix\n").unwrap();
        runner.stage("fix.rs").unwrap();
        runner.commit("wip").unwrap();
        runner.commit_amend("fix: proper message").unwrap();

        let output = runner.log_oneline().unwrap();
        let entries = parse_log(&output);
        assert_eq!(entries.len(), 2); // still 2 (initial + amended)
        assert_eq!(entries[0].message, "fix: proper message");
    }

    #[test]
    fn unstage_rm_cached() {
        let (dir, runner) = temp_repo();
        fs::write(dir.path().join("new.txt"), "hi\n").unwrap();
        runner.stage("new.txt").unwrap();

        // Verify staged
        let status = runner.status().unwrap();
        let entries = parse_status(&status);
        assert_eq!(entries[0].staged, Status::Added);

        // Unstage
        runner.unstage_rm_cached("new.txt").unwrap();
        let status = runner.status().unwrap();
        let entries = parse_status(&status);
        assert_eq!(entries[0].staged, Status::None);
        assert_eq!(entries[0].unstaged, Status::Untracked);
    }

    #[test]
    fn unstage_restore() {
        let (dir, runner) = temp_repo();
        fs::write(dir.path().join("README.md"), "# modified\n").unwrap();
        runner.stage("README.md").unwrap();

        // Verify staged
        let status = runner.status().unwrap();
        let entries = parse_status(&status);
        assert_eq!(entries[0].staged, Status::Modified);

        // Restore staged
        runner.unstage_restore("README.md").unwrap();
        let status = runner.status().unwrap();
        let entries = parse_status(&status);
        assert_eq!(entries[0].staged, Status::None);
        assert_eq!(entries[0].unstaged, Status::Modified);
    }

    #[test]
    fn exec_git_command_add() {
        let (dir, runner) = temp_repo();
        fs::write(dir.path().join("x.rs"), "x\n").unwrap();
        let cmd = GitCommand::Add("x.rs".into());
        runner.exec_git_command(&cmd).unwrap();

        let status = runner.status().unwrap();
        let entries = parse_status(&status);
        assert_eq!(entries[0].staged, Status::Added);
    }

    #[test]
    fn log_show_and_diff() {
        let (dir, runner) = temp_repo();
        fs::write(dir.path().join("a.rs"), "a\n").unwrap();
        runner.stage("a.rs").unwrap();
        runner.commit("add a").unwrap();

        let log = runner.log_oneline().unwrap();
        let entries = parse_log(&log);
        let hash = &entries[0].hash;

        let show = runner.log_show(hash).unwrap();
        assert!(show.contains("add a"));

        let diff = runner.log_diff(hash).unwrap();
        let diffs = parse_diff(&diff);
        assert_eq!(diffs.len(), 1);
        assert_eq!(diffs[0].path, "a.rs");
    }

    #[test]
    fn diff_untracked_file() {
        let (dir, runner) = temp_repo();
        let file_path = dir.path().join("brand_new.rs");
        fs::write(&file_path, "fn new() {}\n").unwrap();

        let output = runner.diff_untracked(file_path.to_str().unwrap()).unwrap();
        // Should contain the file content as additions
        assert!(output.contains("+fn new() {}"));
    }
}
