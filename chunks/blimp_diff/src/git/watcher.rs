use std::path::PathBuf;
use std::sync::mpsc;
use std::time::Duration;

use notify_debouncer_mini::new_debouncer;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WatchEvent {
    RepoChanged,
}

#[derive(Debug)]
pub enum WatchError {
    Notify(notify::Error),
    Io(std::io::Error),
}

impl From<notify::Error> for WatchError {
    fn from(e: notify::Error) -> Self {
        WatchError::Notify(e)
    }
}

impl std::fmt::Display for WatchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            WatchError::Notify(e) => write!(f, "notify error: {}", e),
            WatchError::Io(e) => write!(f, "io error: {}", e),
        }
    }
}

pub struct RepoWatcher {
    _debouncer: notify_debouncer_mini::Debouncer<notify::RecommendedWatcher>,
}

impl RepoWatcher {
    pub fn new(
        repo_path: PathBuf,
        sender: mpsc::Sender<WatchEvent>,
    ) -> Result<Self, WatchError> {
        let debouncer = new_debouncer(
            Duration::from_millis(200),
            move |res: Result<Vec<notify_debouncer_mini::DebouncedEvent>, notify::Error>| {
                if let Ok(events) = res {
                    if !events.is_empty() {
                        let _ = sender.send(WatchEvent::RepoChanged);
                    }
                }
            },
        )?;

        let mut watcher = RepoWatcher {
            _debouncer: debouncer,
        };

        // Watch the working tree
        watcher.watch(&repo_path)?;

        // Watch .git internals
        let git_dir = repo_path.join(".git");
        if git_dir.exists() {
            let _ = watcher.watch(&git_dir.join("index"));
            let _ = watcher.watch(&git_dir.join("HEAD"));
            let refs_dir = git_dir.join("refs");
            if refs_dir.exists() {
                let _ = watcher.watch(&refs_dir);
            }
        }

        Ok(watcher)
    }

    fn watch(&mut self, path: &PathBuf) -> Result<(), WatchError> {
        use notify::RecursiveMode;
        self._debouncer
            .watcher()
            .watch(path, RecursiveMode::Recursive)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::process::Command;

    fn temp_repo() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
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
        fs::write(dir.path().join("init.txt"), "init\n").unwrap();
        Command::new("git")
            .args(["add", "init.txt"])
            .current_dir(dir.path())
            .output()
            .unwrap();
        Command::new("git")
            .args(["commit", "-m", "init"])
            .current_dir(dir.path())
            .output()
            .unwrap();
        dir
    }

    #[test]
    fn watcher_fires_on_file_change() {
        let dir = temp_repo();
        let (tx, rx) = mpsc::channel();

        let _watcher = RepoWatcher::new(dir.path().to_path_buf(), tx).unwrap();

        // Give watcher time to initialize
        std::thread::sleep(Duration::from_millis(100));

        // Modify a file
        fs::write(dir.path().join("init.txt"), "changed\n").unwrap();

        // Wait for event (with timeout)
        let event = rx.recv_timeout(Duration::from_secs(5));
        assert!(event.is_ok(), "watcher should have fired");
        assert_eq!(event.unwrap(), WatchEvent::RepoChanged);
    }

    #[test]
    fn watcher_fires_on_new_file() {
        let dir = temp_repo();
        let (tx, rx) = mpsc::channel();

        let _watcher = RepoWatcher::new(dir.path().to_path_buf(), tx).unwrap();

        std::thread::sleep(Duration::from_millis(100));

        fs::write(dir.path().join("new_file.txt"), "new\n").unwrap();

        let event = rx.recv_timeout(Duration::from_secs(5));
        assert!(event.is_ok(), "watcher should have fired on new file");
    }

    #[test]
    fn watcher_debounces_rapid_changes() {
        let dir = temp_repo();
        let (tx, rx) = mpsc::channel();

        let _watcher = RepoWatcher::new(dir.path().to_path_buf(), tx).unwrap();

        std::thread::sleep(Duration::from_millis(100));

        // Rapid writes
        for i in 0..10 {
            fs::write(dir.path().join("init.txt"), format!("change {i}\n")).unwrap();
        }

        // Wait for debounce to settle
        std::thread::sleep(Duration::from_millis(500));

        // Drain all events
        let mut count = 0;
        while rx.try_recv().is_ok() {
            count += 1;
        }

        // Should be significantly fewer than 10 events due to debouncing
        assert!(count < 10, "expected debouncing, got {} events", count);
        assert!(count >= 1, "expected at least 1 event, got {}", count);
    }
}
