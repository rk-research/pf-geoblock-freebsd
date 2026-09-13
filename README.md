# FreeBSD PF geo-blocking updater

Updates the IPv4 and IPv6 country blocklist tables of the PF firewall from the
[IPdeny](https://www.ipdeny.com/) aggregated country CIDR datasets, once a day
from cron.

| File | Purpose |
| --- | --- |
| `update-pf-geoblock.sh` | the updater, FreeBSD `/bin/sh`, run as root |
| `pf.conf.example` | table declarations and block rules to merge into `/etc/pf.conf` |

Example country list: `cn ru ua ir iq om` (edit `COUNTRIES` in the
configuration section at the top of the script).

## License

This project is licensed under the BSD 2-Clause License.
See [LICENSE](LICENSE) for details.

Copyright (c) 2026 Richard Knuchel

## Data source

Country network data is retrieved at runtime from
[IPdeny](https://www.ipdeny.com/).

IPdeny datasets are not included in or distributed with this project.
Use of the external data source is subject to IPdeny's own terms and policies.

## Disclaimer

This software modifies firewall tables and may affect network connectivity.
Review the configuration and test it in your environment before enabling
automated updates. Use at your own risk.

## Installation

1. **Install the script** (`root:wheel`, mode `0700`):

   `0700` is the most restrictive choice. `0750` may be used if members of the
   owning group should also be allowed to execute the script.

   ```sh
   install -o root -g wheel -m 0700 update-pf-geoblock.sh \
       /usr/local/sbin/update-pf-geoblock.sh
   ```

2. **Review the configuration section** at the top of the installed script:
   countries, target file paths, table names, fetch timeout, and the minimum
   entry thresholds.

3. **Create the two table files** if they do not exist yet. `pf.conf` declares
   the tables with `file "..."`, and a missing file makes the whole ruleset
   fail to load:

   ```sh
   : > /etc/pf.IPv4_geo_block
   : > /etc/pf.IPv6_geo_block
   chown root:wheel /etc/pf.IPv4_geo_block /etc/pf.IPv6_geo_block
   chmod 0644 /etc/pf.IPv4_geo_block /etc/pf.IPv6_geo_block
   ```

4. **Add the tables and rules** from `pf.conf.example` to `/etc/pf.conf`, then
   check the syntax before loading (the script never touches `pf.conf`):

   ```sh
   pfctl -n -f /etc/pf.conf      # parse only, changes nothing
   pfctl -f  /etc/pf.conf        # load
   ```

   Both tables must be present afterwards — the updater refuses to run
   otherwise:

   ```sh
   pfctl -s Tables
   ```

5. **Run the updater manually once** and read its output before automating it:

   ```sh
   /usr/local/sbin/update-pf-geoblock.sh; echo "exit=$?"
   ```

6. **Enable the cron job.** In `/etc/crontab` the user field is required:

   ```cron
   17 4 * * * root /usr/local/sbin/update-pf-geoblock.sh
   ```

   In the personal crontab of root (`crontab -e` as root) there is **no** user
   field — the job already runs as that user; leaving `root` in would make cron
   try to execute a command literally named `root`:

   ```cron
   17 4 * * * /usr/local/sbin/update-pf-geoblock.sh
   ```

   cron mails stdout and stderr to the crontab owner. To log to a file
   instead, append `>> /var/log/pf-geoblock.log 2>&1`.

7. **Inspect the active tables:**

   ```sh
   pfctl -t geo_block_v4 -T show | wc -l
   pfctl -t geo_block_v6 -T show | wc -l
   pfctl -t geo_block_v4 -T show
   pfctl -t geo_block_v6 -T show
   ```

## Validation and rollback strategy

The guiding rule is that **the currently active blocklist is the known-good
state**, and it is only ever replaced by data that has passed every check.

### Validation, in order

1. **Prerequisites, before any download:** running as root, every required
   base utility present, country codes well formed, destination directories
   present, PF reachable via `pfctl -si`, and both configured tables already
   declared. A missing table is an error, never silently created.
2. **Per download:** `fetch` must exit successfully (HTTPS, explicit timeout),
   and its output must be a non-empty file that does not look like an HTML or
   XML error page — the failure mode that still returns HTTP 200.
3. **Per file, strict address family:** one `awk` pass strips CRs, comments,
   blank lines and stray whitespace, then requires every remaining line to be
   a CIDR entry of the expected family (dotted quad with a `/0-32` prefix for
   IPv4; hex groups with colons and a `/0-128` prefix for IPv6). An unusable
   line aborts the run rather than being silently dropped, so IPv4 data can
   never leak into the IPv6 list or vice versa.
4. **Per merged candidate:** the family check is repeated on the merged,
   `LC_ALL=C sort -u` output, the entry count is logged, and a count below
   `MIN_IPV4_ENTRIES` / `MIN_IPV6_ENTRIES` (default 1, i.e. "not empty"; raise
   it if you know your own list size) aborts the run.
5. **PF as the authoritative parser:** a throw-away ruleset that declares both
   tables with `file` pointing at the candidates, plus the matching block
   rules, is handed to `pfctl -n -f`. pfctl parses every address in both files
   while parsing that ruleset, and `-n` (no action) stops before anything is
   loaded, so no table is created, flushed or replaced and the live ruleset is
   untouched.

   Deliberately **not** used: replacing the production table to "see if it
   works" (that destroys the very data being protected), and
   `pfctl -t <table> -T test -f <file>`, which only tests whether addresses are
   matched by an existing table and is not an import syntax check.

Any failure in steps 1–5 exits non-zero with the production files and both live
tables completely untouched.

### Installation, as one transaction

IPv4 and IPv6 are treated as a single logical update; a run never leaves one
family updated and the other stale on purpose.

1. **Stage** (nothing observable changes yet): the current file is copied aside
   as a backup in the same directory, the candidate is copied to a temporary
   name in that same directory — same filesystem, which is what makes the later
   rename atomic — and ownership (`root:wheel`) and mode (`0644`) are set while
   the file is still invisible under its final name. Both families are staged
   before anything is committed, so the errors that can realistically occur
   (permissions, disk space) happen while both production files are intact.
2. **Commit:** `mv` renames each staged file over its target, back to back. A
   reader — including pfctl — sees either the complete old file or the complete
   new one, never a truncated one, because the live files are never opened for
   writing in place.
3. **Load:** `pfctl -t <table> -T replace -f <file>` swaps the contents of each
   existing table. Only table contents change; the ruleset is never reloaded
   with `pfctl -f /etc/pf.conf`, which would also re-apply unrelated (possibly
   half-edited or newer) ruleset changes.

### Rollback

The backups taken during staging are kept until the transaction is closed.

A single `rollback_transaction()` implements the undo, driven by an explicit
transaction state (`TX_STATE`) that is always raised *before* the operation it
describes — so every state means "this may already have happened", never "this
definitely finished":

| `TX_STATE` | Meaning | What a rollback undoes |
| --- | --- | --- |
| `precommit` | nothing outside the workspace was modified | nothing |
| `committing_files` | the two renames are in progress | restores whichever file was already renamed |
| `files_committed` | both files new, no table touched | restores both files |
| `loading_v4` | the IPv4 replacement may have taken effect | restores both files, reloads the IPv4 table |
| `v4_table_loaded` | IPv4 table new, IPv6 not | restores both files, reloads the IPv4 table |
| `loading_v6` | the IPv6 replacement may have taken effect | restores both files, reloads both tables |
| `complete` | both files and both tables new and consistent | nothing (never called) |

Reloading a table from the restored file is idempotent, so the ambiguous
`loading_*` states are handled pessimistically at the cost of one extra
syscall. When `pfctl` itself reports the failure the state is narrowed first
(`pfctl -T replace` is a single kernel transaction, so a pfctl that exits
non-zero on its own did not change the table); that narrowing happens inside
the abort helper, after the point where a pending signal would be delivered, so
a killed `pfctl` cannot trick the handler into skipping a restore.

Resulting exit codes:

| Failure point | Live tables at that moment | Action |
| --- | --- | --- |
| IPv6 file rename | both still old | rename the IPv4 file back; exit 5 |
| IPv4 table replace | both still old | restore both files; exit 6 |
| IPv6 table replace | IPv4 new, IPv6 old | restore both files **and** reload the IPv4 table; exit 6 |
| HUP/INT/TERM before the commit point | both still old | clean up only; exit 8 |
| HUP/INT/TERM after the commit point | per the table above | the same rollback as an error; exit 8 |

If a rollback step itself fails, the script says so explicitly, keeps the backup
copies instead of deleting them, prints ready-to-paste recovery commands, and
exits 7. On a first run there is no previous file to restore; that case is
logged as such rather than reported as a successful rollback.

### Signals

A signal is not treated as a harmless "stop now": `HUP`, `INT` and `TERM` can
arrive after the files have been renamed or after one of the two tables has
been replaced, and simply cleaning up would leave IPv4 and IPv6 in a mixed
state. The handler therefore looks at `TX_STATE` and runs the *same* rollback
an ordinary failure would, and it only claims that the production state is
unchanged when `TX_STATE` is still `precommit`.

Three further properties matter for correctness:

- **The rollback cannot be interrupted.** The handler and
  `rollback_transaction()` set `HUP INT TERM` to *ignore* on entry. Children
  inherit `SIG_IGN`, so the `mv` and `pfctl` processes started while restoring
  survive a signal sent to the whole process group (Ctrl-C, or a shutdown
  killing the cron job). The rollback is also guarded by a done-flag, so the
  error path and the handler can never run it twice.
- **Cleanup never decides anything.** It removes the backups only when the
  transaction is provably safe without them: `precommit` (the files were never
  touched), `complete` (the new state is live), or after a rollback that fully
  succeeded. In every other case the backups are the last copy of the
  known-good data and are kept, with their paths logged.
- **State is never observed half-assigned.** The shell runs a trap handler only
  between commands, so `TX_STATE` is always a complete value when the handler
  reads it.

The `EXIT` trap removes the temporary workspace, any staged file that was never
renamed, and the lock directory on every exit path. Concurrent runs are
prevented by atomically creating `/var/run/pf-geo-block.lock` with `mkdir`; a
lock left behind by a crashed run is reported with removal instructions but
never deleted automatically, because that could remove the lock of a live
process.

### Recovering from a hard kill

`SIGKILL`, a panic or a power loss cannot be trapped, so that is the one case
the script cannot clean up after itself. Nothing is corrupted — each file is
either the complete old or the complete new one — but three leftovers are
possible, and the first one blocks the next cron run on purpose:

```sh
rm -rf /var/run/pf-geo-block.lock         # stale lock: check with "ps ax" first
rm -f /etc/.pf.IPv[46]_geo_block.new.*    # never-renamed staged copies
rm -rf /var/tmp/pf-geoblock.*             # abandoned workspaces
```

A leftover `/etc/.pf.IPv[46]_geo_block.bak.*` is the previous known-good list.
Compare it against the live file before deleting it; the recovery commands the
script logs when a rollback fails are exactly the ones to use:

```sh
cp -p /etc/.pf.IPv4_geo_block.bak.NNN /etc/pf.IPv4_geo_block
pfctl -t geo_block_v4 -T replace -f /etc/pf.IPv4_geo_block
```

If the files and the live tables disagree after such an event, the next
successful run puts both back in sync.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | complete success — both files installed and both tables replaced |
| 1 | prerequisite or configuration error (not root, missing command, missing table, …) |
| 2 | another run holds the lock |
| 3 | a dataset could not be downloaded |
| 4 | validation failure (empty, HTML, malformed, wrong family, below threshold, rejected by pfctl) |
| 5 | production file installation failed |
| 6 | PF table replacement failed; previous state restored |
| 7 | rollback failed — manual inspection required, backups are kept and logged |
| 8 | interrupted by HUP/INT/TERM (after the commit point: rolled back first) |

## Notes and limits

- Every configured country must have **both** an IPv4 and an IPv6 dataset at
  IPdeny. A 404 for either one aborts the run by design (fail closed). If
  IPdeny has no IPv6 file for a country you want, remove that country or host a
  mirror; do not weaken the failure policy.
- One second passes between consecutive HTTP requests, including the IPv4 to
  IPv6 and country to country transitions.
- IPdeny already publishes aggregated ranges; no CIDR re-aggregation is
  attempted in shell.
- The datasets are country-level allocations and are neither perfectly accurate
  nor stable over time. Blocking a country also blocks VPN exits, CDNs and mail
  relays located there.
