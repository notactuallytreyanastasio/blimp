use std::sync::Mutex;
use std::time::Duration;
use tauri::Manager;
use tauri_plugin_shell::ShellExt;
use tauri_plugin_shell::process::CommandChild;

struct SidecarState(Mutex<Option<CommandChild>>);

async fn wait_for_server(port: u16, timeout: Duration) -> bool {
    let start = std::time::Instant::now();
    let url = format!("http://localhost:{}", port);
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(1))
        .build()
        .unwrap();

    while start.elapsed() < timeout {
        if client.get(&url).send().await.is_ok() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    false
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(SidecarState(Mutex::new(None)))
        .setup(|app| {
            let handle = app.handle().clone();

            tauri::async_runtime::spawn(async move {
                // Spawn the Phoenix sidecar
                let shell = handle.shell();
                let command = shell
                    .sidecar("binaries/term_diff")
                    .expect("failed to create sidecar command");

                let (mut rx, child) = command.spawn().expect("failed to spawn sidecar");

                // Store the child process so we can kill it on exit
                let state = handle.state::<SidecarState>();
                *state.0.lock().unwrap() = Some(child);

                // Log sidecar output
                tauri::async_runtime::spawn(async move {
                    use tauri_plugin_shell::process::CommandEvent;
                    while let Some(event) = rx.recv().await {
                        match event {
                            CommandEvent::Stdout(line) => {
                                let s = String::from_utf8_lossy(&line);
                                eprintln!("[phoenix:stdout] {}", s);
                            }
                            CommandEvent::Stderr(line) => {
                                let s = String::from_utf8_lossy(&line);
                                eprintln!("[phoenix:stderr] {}", s);
                            }
                            CommandEvent::Terminated(status) => {
                                eprintln!("[phoenix] terminated with {:?}", status);
                                break;
                            }
                            _ => {}
                        }
                    }
                });

                // Wait for Phoenix to be ready
                eprintln!("[tauri] waiting for Phoenix on port 4123...");
                if wait_for_server(4123, Duration::from_secs(30)).await {
                    eprintln!("[tauri] Phoenix is ready!");
                    // Navigate the main window to the Phoenix URL
                    if let Some(window) = handle.get_webview_window("main") {
                        let _ = window.navigate("http://localhost:4123".parse().unwrap());
                    }
                } else {
                    eprintln!("[tauri] ERROR: Phoenix failed to start within 30s");
                }
            });

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app, event| {
            if let tauri::RunEvent::ExitRequested { .. } = event {
                // Kill the sidecar on exit
                let child = app.state::<SidecarState>().0.lock().unwrap().take();
                if let Some(child) = child {
                    eprintln!("[tauri] killing Phoenix sidecar...");
                    let _ = child.kill();
                }
            }
        });
}
