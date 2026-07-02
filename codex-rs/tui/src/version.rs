use std::borrow::Cow;

/// The current Codex CLI version as embedded at compile time.
pub const CODEX_CLI_VERSION: &str = env!("CARGO_PKG_VERSION");

#[cfg(not(test))]
const CODEX_CLI_DISPLAY_VERSION_ENV_VAR: &str = "CODEX_CLI_DISPLAY_VERSION";

/// Returns the CLI version string shown in user-facing TUI surfaces.
///
/// Dev shims can override the display value without changing the Cargo package
/// version that is used for update checks, telemetry, and protocol metadata.
pub(crate) fn codex_cli_display_version() -> &'static str {
    #[cfg(test)]
    {
        // Keep snapshots deterministic even when the developer shell has an
        // override exported for manual codex-dev testing.
        CODEX_CLI_VERSION
    }

    #[cfg(not(test))]
    {
        static DISPLAY_VERSION: std::sync::OnceLock<String> = std::sync::OnceLock::new();

        DISPLAY_VERSION
            .get_or_init(|| {
                let override_version = std::env::var(CODEX_CLI_DISPLAY_VERSION_ENV_VAR).ok();
                resolve_codex_cli_display_version(override_version.as_deref()).into_owned()
            })
            .as_str()
    }
}

fn resolve_codex_cli_display_version(override_version: Option<&str>) -> Cow<'_, str> {
    match override_version
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        Some(version) => Cow::Borrowed(version),
        None => Cow::Borrowed(CODEX_CLI_VERSION),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn display_version_falls_back_to_compiled_version_when_override_is_missing_or_empty() {
        assert_eq!(
            resolve_codex_cli_display_version(/*override_version*/ None).as_ref(),
            CODEX_CLI_VERSION
        );
        assert_eq!(
            resolve_codex_cli_display_version(Some("  ")).as_ref(),
            CODEX_CLI_VERSION
        );
    }

    #[test]
    fn display_version_uses_trimmed_override_when_present() {
        assert_eq!(
            resolve_codex_cli_display_version(Some(" 0.141.0-dev ")).as_ref(),
            "0.141.0-dev"
        );
    }
}
