use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=KOLLYWOOD_CLI_GIT_SHA");
    println!("cargo:rerun-if-changed=../../.git/HEAD");

    let git_sha = std::env::var("KOLLYWOOD_CLI_GIT_SHA")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .or_else(read_git_sha)
        .unwrap_or_else(|| "unknown".to_string());

    println!("cargo:rustc-env=KOLLYWOOD_CLI_GIT_SHA={git_sha}");
}

fn read_git_sha() -> Option<String> {
    let output = Command::new("git")
        .args(["rev-parse", "--short=8", "HEAD"])
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let value = String::from_utf8(output.stdout).ok()?;
    let trimmed = value.trim();

    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}
