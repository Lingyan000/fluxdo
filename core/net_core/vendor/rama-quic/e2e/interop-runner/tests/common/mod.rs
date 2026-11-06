//! Child processes get explicit runner settings while retaining required OS state.

use std::process::Command;

pub fn endpoint_command(binary: &str) -> Command {
    let mut command = Command::new(binary);
    command.env_clear();
    command.env("NO_COLOR", "1");
    // Winsock provider DLL paths can contain %SystemRoot%. Clearing it prevents
    // provider loading even though the endpoint executable itself starts.
    #[cfg(windows)]
    command.env(
        "SystemRoot",
        std::env::var_os("SystemRoot").expect("Windows supplies SystemRoot for provider loading"),
    );
    command
}
