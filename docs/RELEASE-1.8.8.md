# Upkeep 1.8.8

Claude Code skills get updated, G HUB updates again with its updater service disabled, and each run checks for a newer NVIDIA driver.

## Claude Code skills are updated from where they came from

topgrade's "GitHub CLI Skills" step only updates skills whose `SKILL.md` records the GitHub repo they came from. All 13 skills on the PC from these logs had been copied in by hand, so every run skipped them with "has no GitHub metadata", and nothing ever updated them.

The new step `steps\Update-AgentSkills.ps1` runs after topgrade and gives each skill a source:

- **GitHub, through `gh skill`.** `skill-sources.json` lists the known publishers: the six Matt Pocock skills (mattpocock/skills), officecli (iOfficeAI/OfficeCLI) and rossmann-voice (realrossmanngroup/no_ai_slop_writing_rules). A hand-copied skill is reinstalled once with `gh skill install`, which records the repo; topgrade's step updates it after that.
- **Any git repository.** This covers repos `gh skill` cannot read: blader/humanizer keeps `SKILL.md` at its root. It also covers your own skills: list a repo under `AgentSkillRepos` in `settings.json`, and every folder in it with a `SKILL.md` is installed and kept in sync on each PC. A private repo that isn't on GitHub, such as a Gitea server, is read with the `GITEA_TOKEN` environment variable.
- **graphify's own installer.** uv updates the graphify package, but its skill copy stays at the old version until `graphify install --platform claude` runs. The step runs it when the two differ (0.9.97 → 0.9.103 on that PC).

The step replaces a git-synced skill only while it still matches what Upkeep last installed. A skill you have edited is left alone and listed at the end of the run. The first time a skill is taken over, the old copy is backed up to `%LOCALAPPDATA%\Upkeep\Backups\skills`.

Some published skills are usually customized. no-ai-slop is one: the copy on that PC is Rossmann's version with the 24 rules added at the end. For these, `skill-sources.json` names the upstream folder under `_upstreams`. Upkeep never installs it over your copy; it lists the skill when that folder gets a new commit, so you can merge the change.

For a skill with no source, Upkeep searches GitHub (`gh skill search`, at most once a week per skill) and reports repos that publish a skill of the same name. It doesn't install them, because most of the matches are forks.

Confirm updates has a "Claude Code skills" section: a checked skill is updated, an unchecked one is kept as it is. The choice is saved under `AgentSkillKeep`.

## G HUB updates through its own updater

G HUB updates through its updater service (`LGHUBUpdaterService`). The service downloads the next build to `C:\ProgramData\LGHUB` and applies it. winget's Logitech.GHUB installer only starts that process and returns, so winget saw no version change, and 1.8.5 recorded G HUB as an installer that changes nothing. The update actually finished about 35 minutes after the run.

On 2026-11-03 the service was set to Disabled to keep it out of startup. After that nothing applied G HUB's downloaded builds: 2026.7.1011216 had been waiting since 11-04. The new client step `steps\Update-GHub.ps1` starts the service, waits until it has applied any downloaded build, then puts the start type and running state back as they were. On that PC this applied 2026.7.1011216 with G HUB open, and the service went back to Disabled. winget now leaves Logitech.GHUB to this step, and the summary has a G HUB row.

## A newer NVIDIA driver is reported

No step updated the GPU driver, and no run said when NVIDIA had a newer one. The PC from these logs had 621.01 while NVIDIA's newest Game Ready driver was 621.14. `steps\Check-NvidiaDriver.ps1` now asks NVIDIA for the newest driver at the end of each run (a query only, nothing downloaded). When one is newer, it is listed under "Needs a manual update", and the dashboard shows an "Open NVCleanstall" button below the results. Upkeep doesn't install the driver itself: the screen goes blank during the install, and it can need a restart.

## Validation

- 174 PowerShell tests pass under Windows PowerShell 5.1. Seven are new, run against a local git repo: install a missing skill, update an unedited one, leave an edited one alone, back up a hand-copied one on first takeover, honor "keep", list skills as JSON, and skip G HUB when it isn't installed.
- 77 Rust tests pass. The layout test draws the new skills section in both languages at all five window sizes.
- On the PC from these logs, the skills step updated nine skills and backed up each old copy; `gh skill list` now shows eight skills with their repo. The G HUB step's approach applied 2026.7.1011216. The NVIDIA check reported 621.01 → 621.14.
- Building that step, the test against a local repo caught a path-length bug: the clone cache folder was named after the whole URL, which pushed git's pack files past Windows' 260-character limit. It is now `<repo>-<8-character hash>`.
