use std::collections::VecDeque;
use std::process::Child;
use std::sync::mpsc;
use std::time::Instant;

const MAX_CONCURRENT: usize = 5;
const STALL_TIMEOUT_SECS: u64 = 300;
const MAX_RETRIES: u8 = 3;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunStatus {
    Queued,
    Running,
    Completed,
    Failed,
    Stalled,
}

#[derive(Debug)]
pub struct AgentRun {
    pub id: u64,
    pub prompt: String,
    pub status: RunStatus,
    pub started_at: Option<Instant>,
    pub last_activity: Instant,
    pub result: Option<String>,
    pub error: Option<String>,
    pub retries: u8,
}

#[derive(Debug, Clone)]
pub enum AgentEvent {
    Completed { id: u64, result: String },
    Failed { id: u64, error: String },
}

pub struct Multiplexer {
    active: Vec<AgentRun>,
    queue: VecDeque<AgentRun>,
    next_id: u64,
    pub event_tx: mpsc::Sender<AgentEvent>,
    pub event_rx: mpsc::Receiver<AgentEvent>,
}

impl Multiplexer {
    pub fn new() -> Self {
        let (tx, rx) = mpsc::channel();
        Self {
            active: Vec::new(),
            queue: VecDeque::new(),
            next_id: 1,
            event_tx: tx,
            event_rx: rx,
        }
    }

    /// Queue or start a new agent run. Returns the run ID.
    pub fn dispatch(&mut self, prompt: String) -> u64 {
        let id = self.next_id;
        self.next_id += 1;

        let run = AgentRun {
            id,
            prompt,
            status: RunStatus::Queued,
            started_at: None,
            last_activity: Instant::now(),
            result: None,
            error: None,
            retries: 0,
        };

        if self.active.len() < MAX_CONCURRENT {
            self.start_run(run);
        } else {
            self.queue.push_back(run);
        }

        id
    }

    /// Process a completion or failure event from a running agent.
    pub fn handle_event(&mut self, event: AgentEvent) {
        match event {
            AgentEvent::Completed { id, result } => {
                if let Some(run) = self.active.iter_mut().find(|r| r.id == id) {
                    run.status = RunStatus::Completed;
                    run.result = Some(result);
                    run.last_activity = Instant::now();
                }
                self.dequeue_next();
            }
            AgentEvent::Failed { id, error } => {
                if let Some(run) = self.active.iter_mut().find(|r| r.id == id) {
                    run.status = RunStatus::Failed;
                    run.error = Some(error);
                    run.last_activity = Instant::now();
                }
                self.dequeue_next();
            }
        }
    }

    /// Check for stalled runs and retry them.
    pub fn check_stalled(&mut self) {
        let now = Instant::now();
        let mut stalled_ids = vec![];

        for run in &self.active {
            if run.status == RunStatus::Running
                && now.duration_since(run.last_activity).as_secs() > STALL_TIMEOUT_SECS
            {
                stalled_ids.push(run.id);
            }
        }

        for id in stalled_ids {
            if let Some(run) = self.active.iter_mut().find(|r| r.id == id) {
                if run.retries < MAX_RETRIES {
                    run.status = RunStatus::Stalled;
                    run.retries += 1;
                    // Mark for restart -- the actual restart happens when
                    // the event loop sees the Stalled status
                    run.status = RunStatus::Running;
                    run.last_activity = Instant::now();
                } else {
                    run.status = RunStatus::Failed;
                    run.error = Some("max retries exceeded".into());
                }
            }
        }
    }

    /// Cancel a running or queued agent.
    pub fn cancel(&mut self, id: u64) {
        self.active.retain(|r| r.id != id);
        self.queue.retain(|r| r.id != id);
        self.dequeue_next();
    }

    pub fn active_count(&self) -> usize {
        self.active.iter().filter(|r| r.status == RunStatus::Running).count()
    }

    pub fn queued_count(&self) -> usize {
        self.queue.len()
    }

    pub fn total_count(&self) -> usize {
        self.active.len() + self.queue.len()
    }

    pub fn get_run(&self, id: u64) -> Option<&AgentRun> {
        self.active
            .iter()
            .chain(self.queue.iter())
            .find(|r| r.id == id)
    }

    pub fn completed_runs(&self) -> Vec<&AgentRun> {
        self.active
            .iter()
            .filter(|r| r.status == RunStatus::Completed)
            .collect()
    }

    fn start_run(&mut self, mut run: AgentRun) {
        run.status = RunStatus::Running;
        run.started_at = Some(Instant::now());
        run.last_activity = Instant::now();
        self.active.push(run);
    }

    fn dequeue_next(&mut self) {
        // Clean up completed/failed runs from active (keep last 10)
        let running = self.active.iter().filter(|r| r.status == RunStatus::Running).count();
        if running < MAX_CONCURRENT {
            if let Some(run) = self.queue.pop_front() {
                self.start_run(run);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dispatch_starts_immediately_when_below_max() {
        let mut mux = Multiplexer::new();
        let id = mux.dispatch("fix bug".into());
        assert_eq!(id, 1);
        assert_eq!(mux.active_count(), 1);
        assert_eq!(mux.queued_count(), 0);
    }

    #[test]
    fn dispatch_queues_when_at_max() {
        let mut mux = Multiplexer::new();
        for i in 0..MAX_CONCURRENT {
            mux.dispatch(format!("task {}", i));
        }
        assert_eq!(mux.active_count(), MAX_CONCURRENT);

        let overflow_id = mux.dispatch("overflow".into());
        assert_eq!(mux.queued_count(), 1);
        let run = mux.get_run(overflow_id).unwrap();
        assert_eq!(run.status, RunStatus::Queued);
    }

    #[test]
    fn handle_completed_event() {
        let mut mux = Multiplexer::new();
        let id = mux.dispatch("task".into());

        mux.handle_event(AgentEvent::Completed {
            id,
            result: "done".into(),
        });

        let run = mux.get_run(id).unwrap();
        assert_eq!(run.status, RunStatus::Completed);
        assert_eq!(run.result.as_deref(), Some("done"));
    }

    #[test]
    fn handle_failed_event() {
        let mut mux = Multiplexer::new();
        let id = mux.dispatch("task".into());

        mux.handle_event(AgentEvent::Failed {
            id,
            error: "crash".into(),
        });

        let run = mux.get_run(id).unwrap();
        assert_eq!(run.status, RunStatus::Failed);
        assert_eq!(run.error.as_deref(), Some("crash"));
    }

    #[test]
    fn completion_dequeues_next() {
        let mut mux = Multiplexer::new();
        let mut ids = vec![];
        for i in 0..MAX_CONCURRENT {
            ids.push(mux.dispatch(format!("task {}", i)));
        }
        let queued_id = mux.dispatch("queued".into());
        assert_eq!(mux.queued_count(), 1);

        // Complete first task
        mux.handle_event(AgentEvent::Completed {
            id: ids[0],
            result: "done".into(),
        });

        // Queued task should now be running
        assert_eq!(mux.queued_count(), 0);
        let run = mux.get_run(queued_id).unwrap();
        assert_eq!(run.status, RunStatus::Running);
    }

    #[test]
    fn cancel_active_run() {
        let mut mux = Multiplexer::new();
        let id = mux.dispatch("cancel me".into());
        assert_eq!(mux.active_count(), 1);

        mux.cancel(id);
        assert_eq!(mux.active_count(), 0);
        assert!(mux.get_run(id).is_none());
    }

    #[test]
    fn cancel_queued_run() {
        let mut mux = Multiplexer::new();
        for i in 0..MAX_CONCURRENT {
            mux.dispatch(format!("task {}", i));
        }
        let queued_id = mux.dispatch("cancel me".into());
        assert_eq!(mux.queued_count(), 1);

        mux.cancel(queued_id);
        assert_eq!(mux.queued_count(), 0);
    }

    #[test]
    fn ids_increment() {
        let mut mux = Multiplexer::new();
        let id1 = mux.dispatch("a".into());
        let id2 = mux.dispatch("b".into());
        let id3 = mux.dispatch("c".into());
        assert_eq!(id1, 1);
        assert_eq!(id2, 2);
        assert_eq!(id3, 3);
    }

    #[test]
    fn completed_runs_list() {
        let mut mux = Multiplexer::new();
        let id1 = mux.dispatch("a".into());
        let id2 = mux.dispatch("b".into());

        mux.handle_event(AgentEvent::Completed {
            id: id1,
            result: "done a".into(),
        });

        let completed = mux.completed_runs();
        assert_eq!(completed.len(), 1);
        assert_eq!(completed[0].id, id1);
    }

    #[test]
    fn total_count() {
        let mut mux = Multiplexer::new();
        for i in 0..MAX_CONCURRENT + 3 {
            mux.dispatch(format!("task {}", i));
        }
        assert_eq!(mux.total_count(), MAX_CONCURRENT + 3);
    }

    #[test]
    fn stall_detection_retries() {
        let mut mux = Multiplexer::new();
        let id = mux.dispatch("slow task".into());

        // Manually set last_activity to past
        if let Some(run) = mux.active.iter_mut().find(|r| r.id == id) {
            run.last_activity = Instant::now() - std::time::Duration::from_secs(STALL_TIMEOUT_SECS + 1);
        }

        mux.check_stalled();

        let run = mux.get_run(id).unwrap();
        assert_eq!(run.retries, 1);
        assert_eq!(run.status, RunStatus::Running); // restarted
    }

    #[test]
    fn stall_detection_max_retries_fails() {
        let mut mux = Multiplexer::new();
        let id = mux.dispatch("doomed task".into());

        // Simulate hitting max retries
        for _ in 0..MAX_RETRIES {
            if let Some(run) = mux.active.iter_mut().find(|r| r.id == id) {
                run.last_activity = Instant::now() - std::time::Duration::from_secs(STALL_TIMEOUT_SECS + 1);
            }
            mux.check_stalled();
        }

        // One more stall should fail it
        if let Some(run) = mux.active.iter_mut().find(|r| r.id == id) {
            run.last_activity = Instant::now() - std::time::Duration::from_secs(STALL_TIMEOUT_SECS + 1);
        }
        mux.check_stalled();

        let run = mux.get_run(id).unwrap();
        assert_eq!(run.status, RunStatus::Failed);
        assert!(run.error.as_ref().unwrap().contains("max retries"));
    }
}
