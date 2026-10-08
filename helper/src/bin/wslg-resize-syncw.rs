//! Windowless build for the logon task: same program, GUI subsystem, so no
//! console window appears. Use `--log FILE` (stderr goes nowhere here).
#![windows_subsystem = "windows"]

#[path = "../app.rs"]
mod app;

fn main() {
    app::main()
}
