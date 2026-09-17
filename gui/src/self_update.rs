//! Read-only checks of published stable GitHub releases. Never executes downloads.
use std::{cmp::Ordering, time::Duration};

pub const RELEASES_URL: &str = "https://github.com/joaovgaraujo/Upkeep/releases";

const CHECK_SCRIPT: &str = r#"
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri 'https://api.github.com/repos/joaovgaraujo/Upkeep/releases/latest' -Headers @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' } -UserAgent 'Upkeep-release-checker' -TimeoutSec 20
    $release = $response.Content | ConvertFrom-Json
    @{ release = @{ tag_name = $release.tag_name; draft = $release.draft; prerelease = $release.prerelease } } | ConvertTo-Json -Compress
} catch {
    $status = 0
    if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    if ($status -eq 404) { '{"release":null}' }
    elseif ($status -eq 403 -or $status -eq 429) { @{ error = "GitHub HTTP $status (request limit or access denied). Retry later." } | ConvertTo-Json -Compress }
    else { @{ error = "GitHub check failed (HTTP $status): $($_.Exception.Message)" } | ConvertTo-Json -Compress }
}
"#;

#[derive(Debug, Clone)]
pub struct ReleaseCheck {
    pub version: String,
    /// The published release compared with this executable.
    pub relation: Ordering,
    pub url: String,
}

#[derive(serde::Deserialize)]
struct Response {
    release: Option<Release>,
    error: Option<String>,
}

#[derive(serde::Deserialize)]
struct Release {
    tag_name: String,
    draft: bool,
    prerelease: bool,
}

fn version(value: &str) -> Result<[u64; 3], String> {
    let value = value.strip_prefix('v').unwrap_or(value);
    let parts: Vec<_> = value.split('.').collect();
    if parts.len() != 3
        || parts
            .iter()
            .any(|p| p.is_empty() || !p.bytes().all(|b| b.is_ascii_digit()))
    {
        return Err(format!("Unrecognized stable version: {value}"));
    }
    let mut parsed = [0; 3];
    for (index, part) in parts.iter().enumerate() {
        parsed[index] = part
            .parse()
            .map_err(|_| format!("Invalid version: {value}"))?;
    }
    Ok(parsed)
}

fn parse_response(text: &str, current: &str) -> Result<Option<ReleaseCheck>, String> {
    let value: serde_json::Value = serde_json::from_str(text.trim_start_matches('\u{feff}'))
        .map_err(|e| format!("Invalid GitHub response: {e}"))?;
    if value.get("release").is_none() && value.get("error").is_none() {
        return Err("GitHub response is missing release information".into());
    }
    let response: Response = serde_json::from_str(text.trim_start_matches('\u{feff}'))
        .map_err(|e| format!("Invalid GitHub response: {e}"))?;
    if let Some(error) = response.error {
        return Err(error);
    }
    let Some(release) = response.release else {
        return Ok(None);
    };
    if release.draft || release.prerelease {
        return Err("GitHub returned a non-stable release".into());
    }
    let relation = version(&release.tag_name)?.cmp(&version(current)?);
    Ok(Some(ReleaseCheck {
        version: release.tag_name.trim_start_matches('v').into(),
        relation,
        // Construct only a trusted repository URL using the validated numeric tag.
        url: format!("{RELEASES_URL}/tag/{}", release.tag_name),
    }))
}

pub fn check() -> Result<Option<ReleaseCheck>, String> {
    let text = crate::system::run_hidden(
        "powershell.exe",
        &["-NoProfile", "-NonInteractive", "-Command", CHECK_SCRIPT],
        Duration::from_secs(25),
    )?;
    parse_response(&text, env!("CARGO_PKG_VERSION"))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn response(tag: &str) -> String {
        serde_json::json!({"release":{"tag_name":tag,"draft":false,"prerelease":false}}).to_string()
    }
    #[test]
    fn compares_versions_numerically_and_never_offers_a_downgrade() {
        for (published, current, expected) in [
            ("v1.10.0", "1.9.9", Ordering::Greater),
            ("v1.5.8", "1.5.8", Ordering::Equal),
            ("v1.5.3", "1.5.8", Ordering::Less),
        ] {
            let check = parse_response(&response(published), current)
                .unwrap()
                .unwrap();
            assert_eq!(check.relation, expected);
            assert_eq!(check.url, format!("{RELEASES_URL}/tag/{published}"));
        }
    }
    #[test]
    fn rejects_unstable_invalid_or_untrusted_tags() {
        for tag in [
            "v1.6.0-beta.1",
            "../other",
            "https://example.com",
            "1.5",
            "1.5.8/extra",
            "1.5.-8",
        ] {
            assert!(parse_response(&response(tag), "1.5.8").is_err());
        }
        for flag in ["draft", "prerelease"] {
            let mut data: serde_json::Value = serde_json::from_str(&response("v9.0.0")).unwrap();
            data["release"][flag] = true.into();
            assert!(parse_response(&data.to_string(), "1.5.8").is_err());
        }
    }
    #[test]
    fn distinguishes_no_release_from_connection_and_response_failures() {
        assert!(parse_response(r#"{"release":null}"#, "1.5.8")
            .unwrap()
            .is_none());
        assert!(parse_response(r#"{"error":"HTTP 403"}"#, "1.5.8")
            .unwrap_err()
            .contains("403"));
        assert!(parse_response("", "1.5.8").is_err());
        assert!(parse_response("{}", "1.5.8").is_err());
        assert!(parse_response("<html>offline</html>", "1.5.8").is_err());
    }
    #[test]
    #[ignore = "Explicit live GitHub integration check"]
    fn live_github_release_check() {
        println!("{:?}", check().expect("GitHub release check failed"));
    }
}
