# Upkeep 1.9.4

Fixes from a full run of 1.9.3. That run finished in 4 minutes, but it updated nothing through winget with 9 packages pending, and topgrade and the skills step went red.

## winget's list is read right

The winget step reads `winget upgrade`'s table by column position, taken from the header. It split the header on two or more spaces. winget pads a column with a single space when its widest value is exactly as long as the label. In that run the widest available version was `2.0.7.890`, as long as "Available", so the header read `Available Source`. That became one column, every row's version read like `1.0.111   winget`, every row was dropped, and the step reported "0 package(s) have upgrades available". Whether this hit depended on which packages were pending: the run before had Chrome's `157.0.8103.79` in that column and read fine.

The header labels are one word each, so the step now takes the five words as the columns. A table whose rows all come out with a space in the version now stops the step with an error, instead of reporting that nothing is pending.

## Skills have one owner

Two tools were updating the same Claude Code skills:

- `gh skill install mattpocock/skills engineering/domain-modeling` (run by the skills step) records the skill in the `skills` CLI's lock (`~\.agents\.skill-lock.json`) under `engineering/domain-modeling`. topgrade's Skills step runs `skills update`, which looks skills up by their name, `domain-modeling`. It failed with "No matching skills found" for 6 skills, and the topgrade row went red.
- For skills the `skills` CLI did update, it rewrote `SKILL.md` without gh's metadata. On the next run the skills step saw the skill as untracked, backed it up and reinstalled it with gh. This happened to officecli on every run.

Now the skills step renames those lock entries to the skill's name. It also leaves any skill in that lock to topgrade's Skills step, and the log says so. Those skills also no longer show up as "no source set".

## Access to the skills folder

graphify's skill had a `references` folder that the account couldn't open with its normal permissions. An elevated process had written it during a run on 2026-11-07. `graphify install --platform claude` failed with "Access is denied" on every run since. Before handing over to the normal user, the elevated part of the skills step now looks for anything under the skills folder the account can't read. It takes ownership of each one, resets its permissions to the folder's defaults, and logs it.

## Validation

- 190 PowerShell tests pass under Windows PowerShell 5.1. New tests cover a winget table whose last two labels are one space apart (the real table from that run; it fails without the fix), and a skill tracked by the `skills` CLI (lock entry renamed, written without a BOM, skill left alone).
- Against this PC's winget, the fixed step reads all 6 pending packages that 1.9.3 dropped.
