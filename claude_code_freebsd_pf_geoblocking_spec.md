<!--
Copyright (c) 2026, Richard Knuchel
Licensed under the BSD 2-Clause License. See LICENSE in the project root.
-->

# Claude Code Task Specification: FreeBSD PF Geo-Blocking Updater

## Objective

Implement a production-quality shell script for FreeBSD that updates IPv4 and IPv6 country-based blocklists for the PF firewall using IPdeny country CIDR datasets.

The script is intended to run automatically once every 24 hours from cron.

The implementation must prioritize:

- safe failure behavior,
- atomic updates,
- compatibility with FreeBSD `/bin/sh`,
- minimal dependencies,
- clear operational logging,
- and avoiding any situation where a failed download or malformed dataset replaces a currently valid firewall table.

## Target platform

- Operating system: FreeBSD
- Shell: `/bin/sh`
- Firewall: PF
- Intended execution user: `root`
- Intended execution method: cron, once every 24 hours
- Use only FreeBSD base-system utilities where practical.
- Do not require Bash.
- Do not use Bash-specific syntax such as arrays, `[[ ... ]]`, process substitution, or `pipefail`.

## Data source

Use IPdeny aggregated country CIDR datasets.

IPv4 base URL:

```text
https://www.ipdeny.com/ipblocks/data/aggregated/
```

IPv4 country file naming:

```text
<country-code>-aggregated.zone
```

Example:

```text
https://www.ipdeny.com/ipblocks/data/aggregated/cn-aggregated.zone
```

IPv6 base URL:

```text
https://www.ipdeny.com/ipv6/ipaddresses/aggregated/
```

IPv6 country file naming:

```text
<country-code>-aggregated.zone
```

Example:

```text
https://www.ipdeny.com/ipv6/ipaddresses/aggregated/cn-aggregated.zone
```

Use HTTPS only.

## Configuration section

The script must have a clearly marked configuration section near the beginning.

At minimum, define configurable variables for:

```sh
# Example only. Choose countries according to your own access policy.
COUNTRIES="cn ru ua ir iq om"

IPV4_TARGET="/etc/pf.IPv4_geo_block"
IPV6_TARGET="/etc/pf.IPv6_geo_block"

PF_TABLE_V4="geo_block_v4"
PF_TABLE_V6="geo_block_v6"

IPV4_BASE_URL="https://www.ipdeny.com/ipblocks/data/aggregated"
IPV6_BASE_URL="https://www.ipdeny.com/ipv6/ipaddresses/aggregated"
```

The country list must use ISO 3166-1 alpha-2 lowercase country codes.

Add comments explaining how an administrator can add or remove countries.

Do not hard-code the same path, table name, or URL in multiple unrelated places. Reuse configuration variables.

## PF integration assumption

Assume `/etc/pf.conf` contains persistent tables similar to:

```pf
table <geo_block_v4> persist file "/etc/pf.IPv4_geo_block"
table <geo_block_v6> persist file "/etc/pf.IPv6_geo_block"

block in quick inet  from <geo_block_v4> to any
block in quick inet6 from <geo_block_v6> to any
```

The updater script must not rewrite `/etc/pf.conf`.

It only updates the referenced files and replaces the contents of the already configured PF tables.

## Script documentation

Comment every logical section of the shell script.

Comments must explain both:

1. what the section does, and
2. why it is needed.

The script should be understandable to a FreeBSD administrator who did not write it.

Avoid comments that merely restate individual commands without explaining their purpose.

## Root privilege check

At startup, verify that the script is running as root.

If not:

- print a clear error,
- exit non-zero,
- do not download anything,
- do not modify files,
- do not modify PF.

## Required command checks

Before starting the update, verify that required commands exist.

At minimum check for:

```text
fetch
pfctl
awk
grep
sort
wc
mktemp
mv
rm
sleep
mkdir
rmdir
id
```

Use FreeBSD base-system tools where possible.

If a required command is unavailable:

- log the missing command,
- exit non-zero,
- do not modify the existing tables/files.

## Concurrent execution protection

Prevent two instances of the script from running simultaneously.

Implement a simple FreeBSD `/bin/sh` compatible lock, preferably by atomically creating a lock directory with `mkdir`.

For example:

```text
/var/run/pf-geo-block.lock
```

Requirements:

- if the lock already exists, log that another run is probably active and exit non-zero;
- remove the lock during normal exit and error cleanup;
- use a `trap` so temporary resources are cleaned up.

Do not delete another actively running process's lock automatically.

## Temporary workspace

Create a unique temporary directory using `mktemp -d`.

All downloads and generated candidate files must initially live in this temporary directory.

Do not build candidate data directly in `/etc`.

Use a cleanup trap so temporary files and the lock directory are removed on exit.

The existing production files must remain untouched until all relevant validation succeeds.

## Fetch behavior

For every configured country, download:

1. the aggregated IPv4 dataset;
2. the aggregated IPv6 dataset.

Use FreeBSD `fetch`.

After every individual dataset request, wait one second before initiating the next request.

The one-second delay applies between all requests, including the transition from one country's IPv4 file to its IPv6 file or to the next country.

Do not sleep unnecessarily after the final request if that makes the implementation awkward; the important requirement is at least one second between consecutive requests.

Use a sensible fetch timeout and fail on HTTP/download errors.

Do not silently accept an HTTP error page, empty response, or partial failure.

## Failure policy for country downloads

The update must be fail-closed with respect to the existing firewall configuration.

If any requested country dataset fails to download for either address family:

- abort the entire update;
- do not replace either production file;
- do not replace either active PF table;
- retain the previous known-good state;
- return a non-zero exit status.

Do not silently build an incomplete country blocklist.

## Raw data validation

Validate every downloaded file before merging it.

At minimum:

- file must exist;
- file must not be empty;
- it must contain at least one usable CIDR/network entry;
- reject obvious HTML/error pages.

The script should reject suspicious content such as lines beginning with `<html`, `<!DOCTYPE`, or similar obvious web error responses.

## Address-family validation

IPv4 and IPv6 data must stay completely separate.

The final IPv4 candidate must contain IPv4 CIDR/network entries only.

The final IPv6 candidate must contain IPv6 CIDR/network entries only.

Do not combine IPv4 and IPv6 into one PF input file.

Use lightweight format validation appropriate for a shell script.

Do not attempt to implement a full IP parser in shell if PF itself can provide authoritative validation later.

## Cleaning and normalization

For each address family:

- merge all downloaded country files;
- remove comments;
- remove blank lines;
- strip leading/trailing whitespace if necessary;
- sort entries;
- remove duplicates.

Generate deterministic output.

Use `LC_ALL=C` for sorting so the result does not depend on the system locale.

The final output must be suitable for PF table ingestion.

IPdeny already provides aggregated ranges, so do not attempt to re-aggregate CIDRs in shell.

## Minimum sanity checks

Before asking PF to validate the candidate files:

- verify each merged candidate file is non-empty;
- record and log the number of IPv4 and IPv6 entries;
- reject a candidate that contains zero usable entries.

Optionally implement a configurable minimum total entry threshold, but do not choose an excessively high default that could break legitimate small country configurations.

If implementing a threshold, document it clearly.

## PF validation

Use `pfctl` as the authoritative parser for the generated network lists before changing the production state.

The validation step must ensure malformed addresses cannot replace the current production data.

Important: do not use the production PF tables as a destructive "test".

A candidate must first be validated in a way that cannot replace or flush the currently active production tables.

If FreeBSD `pfctl` does not provide a direct no-change validation mode for a standalone table file, construct a temporary PF configuration or use another safe PF parsing technique that validates the file without modifying the active ruleset/table contents.

The implementation must explain this choice in comments.

Do not assume that `pfctl -t <table> -T test -f <file>` validates table-file syntax for import; `-T test` tests whether addresses match a table and is not equivalent to a dry-run import validation.

## Atomic production-file update

Only after both IPv4 and IPv6 candidate files have passed all validations:

1. install the candidate files as the configured production files;
2. do so atomically, using same-filesystem temporary files followed by `mv`.

Do not truncate or overwrite the active files in place.

Recommended approach:

- create temporary files in the same destination directory as the production files;
- set appropriate ownership and restrictive permissions;
- move them into place atomically.

Suggested permissions:

```text
root:wheel
0644
```

The files contain no secrets, but ownership must prevent unprivileged modification.

## Cross-family transaction safety

Treat IPv4 and IPv6 as one logical update.

Do not intentionally leave IPv4 updated and IPv6 stale because a later validation step failed.

All downloads and validations for both families must succeed before production-file replacement starts.

Where practical, retain backup copies of the current production files until both active PF table replacements succeed.

If the second PF table update fails after the first succeeds, attempt to restore the previous production files and active tables from the saved known-good copies.

Log clearly if rollback itself fails.

## Loading the new PF tables

After successful validation and successful production-file installation, replace the PF table contents without reloading the entire PF ruleset.

Use:

```sh
pfctl -t "$PF_TABLE_V4" -T replace -f "$IPV4_TARGET"
pfctl -t "$PF_TABLE_V6" -T replace -f "$IPV6_TARGET"
```

This is preferable to a full `pfctl -f /etc/pf.conf` reload because the task is only to update table contents.

Check the exit status of every `pfctl` command.

Do not report success unless both table replacements succeed.

## Existing table checks

Before modifying the active tables, verify PF is available and the configured tables are present or otherwise explicitly handle their absence.

Prefer requiring the tables to already exist in `/etc/pf.conf`.

If either configured table is missing:

- print a clear error identifying the missing table;
- do not silently create an unexpected table as a substitute for a configuration error;
- do not modify the production files.

## Logging

The script runs from cron, so all output must be useful without interactive context.

Implement small logging helper functions such as:

```sh
log_info()
log_error()
```

Every log message should include a timestamp.

Log at minimum:

- start of update;
- configured countries;
- each dataset being fetched;
- download failure;
- validation failure;
- IPv4 entry count;
- IPv6 entry count;
- production file installation;
- PF table replacement;
- rollback attempts;
- successful completion.

Send normal progress to stdout and errors to stderr.

Do not flood cron output with every individual CIDR.

## Exit codes

Use clear exit behavior:

- `0` only when the entire update succeeds;
- non-zero for any failed prerequisite, fetch, validation, file installation, PF update, or rollback condition.

Exact differentiated exit-code numbers are optional, but consistency is required.

## Signal/error cleanup

Install a trap that cleans up temporary data and releases the lock on normal exit and common termination signals.

At minimum handle:

```text
EXIT
HUP
INT
TERM
```

Be careful not to recursively trigger the cleanup trap.

## Cron usage

At the end of the generated script, include comments showing an example cron entry for running once every 24 hours.

Example:

```cron
17 4 * * * root /usr/local/sbin/update-pf-geoblock.sh
```

If using the user's crontab instead of `/etc/crontab`, do not include the `root` field.

Explain the distinction in the comments.

## PF configuration example

After the shell script, provide a separate example snippet showing the corresponding `/etc/pf.conf` table declarations and blocking rules:

```pf
table <geo_block_v4> persist file "/etc/pf.IPv4_geo_block"
table <geo_block_v6> persist file "/etc/pf.IPv6_geo_block"

block in quick inet  from <geo_block_v4> to any
block in quick inet6 from <geo_block_v6> to any
```

Do not automatically edit `pf.conf`.

## Installation notes

Provide short installation instructions covering:

1. recommended script path:
   `/usr/local/sbin/update-pf-geoblock.sh`
2. ownership:
   `root:wheel`
3. mode:
   `0700` or `0750`
4. initial creation of the two target files if necessary;
5. validation/reload of `/etc/pf.conf`;
6. manual first run before enabling cron;
7. commands to inspect active tables.

Useful verification examples:

```sh
pfctl -t geo_block_v4 -T show | wc -l
pfctl -t geo_block_v6 -T show | wc -l
pfctl -t geo_block_v4 -T show
pfctl -t geo_block_v6 -T show
```

## Security and reliability constraints

The implementation must follow these rules:

- Never erase an existing valid blocklist because IPdeny is temporarily unavailable.
- Never install a partially downloaded country set.
- Never mix IPv4 and IPv6 data.
- Never invoke Bash.
- Never use `eval`.
- Quote all variable expansions where appropriate.
- Do not create world-writable temporary files.
- Do not trust downloaded content merely because `fetch` returned success.
- Do not reload the entire PF ruleset when only table contents need changing.
- Do not modify `/etc/pf.conf`.
- Do not disable PF.
- Do not flush production tables before a replacement dataset is ready.
- Preserve a known-good state on any failure whenever technically possible.

## Deliverables

Generate:

1. the complete FreeBSD `/bin/sh` script;
2. a matching `/etc/pf.conf` example;
3. concise installation instructions;
4. a short explanation of the validation and rollback strategy.

Before presenting the final implementation, review it specifically for:

- FreeBSD `/bin/sh` compatibility;
- correct FreeBSD `fetch` usage;
- correct `pfctl` semantics;
- quoting issues;
- race conditions;
- temporary-file safety;
- cron environment assumptions;
- atomic update behavior;
- IPv4/IPv6 separation;
- preservation of the old active blocklist on failure.

Do not provide pseudocode. Produce an implementation that can be installed and tested on FreeBSD.
