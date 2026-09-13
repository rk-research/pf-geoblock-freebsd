#!/bin/sh
#
# update-pf-geoblock.sh
#
# Copyright (c) 2026, Richard Knuchel
# Licensed under the BSD 2-Clause License. See LICENSE in the project root.
#
# Update the PF country blocklist tables (IPv4 and IPv6) from the IPdeny
# aggregated country CIDR datasets.
#
# Designed for FreeBSD base /bin/sh, run as root from cron once every 24 hours.
# See the appendix at the bottom of this file for cron, pf.conf and
# installation notes.
#
# Design principles (the whole script is built around these):
#
#   * Fail closed.  The currently active blocklist is the known-good state.
#     If anything at all goes wrong - a missing dependency, a failed download,
#     an HTML error page, a malformed CIDR, a pfctl parse error - the script
#     aborts and attempts to preserve or restore the previous known-good state.
#     A temporarily unreachable IPdeny must never result in an empty or partial
#     blocklist.
#   * One logical transaction.  IPv4 and IPv6 are updated together, or not at
#     all.  Every download and every validation for both families must succeed
#     before the first production file is touched.
#   * Atomic installation.  Candidate data is built in a private temporary
#     directory, then written into the destination directory as a temporary
#     file and renamed over the target with mv(1), so readers (and pfctl)
#     never observe a half written file.
#   * A signal is not a special case.  HUP/INT/TERM can arrive after the
#     production files have been renamed or after one of the two PF tables
#     has been replaced, so the handler consults the transaction state and
#     runs the same rollback an ordinary failure would; only before the
#     commit point does it simply clean up and exit.
#   * pfctl is the authoritative parser.  Shell-side checks only catch the
#     obvious garbage; the real syntax verdict comes from pfctl parsing a
#     throw-away ruleset in no-action mode (-n), which cannot modify the
#     running firewall.
#
# Exit codes (consistent, see EX_* below):
#   0 success, 1 prerequisite/config error, 2 lock held, 3 download failure,
#   4 validation failure, 5 production file installation failure,
#   6 PF table replacement failure, 7 rollback failure (state may be mixed),
#   8 interrupted by a signal (HUP/INT/TERM).
#

# Fail on use of an unset variable: a typo in a variable name must not silently
# expand to the empty string and, for example, turn a path into "/".
set -u

# cron provides a minimal environment.  Pin PATH so every base utility and
# pfctl are found regardless of how the job was invoked, and pin the locale so
# that sort(1) ordering and character classes are byte-deterministic instead of
# depending on the administrator's locale settings.
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

###############################################################################
# CONFIGURATION
#
# This is the only section an administrator normally needs to edit.
###############################################################################

# Countries to block.
#
# Space separated list of ISO 3166-1 alpha-2 codes in LOWER CASE, exactly as
# IPdeny names its files (for example "cn" for China, "ru" for Russia).
#
# To add a country:    append its two letter code, e.g. COUNTRIES="cn ru kp"
# To remove a country: delete its code from the list.
#
# Both an IPv4 and an IPv6 dataset must exist at IPdeny for every code listed
# here; a country whose dataset is missing (HTTP 404) aborts the run by design
# (see "fail closed" above).  Verify a new code by hand once, for example:
#   fetch -o /dev/null https://www.ipdeny.com/ipv6/ipaddresses/aggregated/kp-aggregated.zone
# Example only. Choose countries according to your own access policy.
COUNTRIES="cn ru ua ir iq om"

# Production files consumed by PF.  These paths must match the "file" argument
# of the table declarations in /etc/pf.conf.
IPV4_TARGET="/etc/pf.IPv4_geo_block"
IPV6_TARGET="/etc/pf.IPv6_geo_block"

# Names of the PF tables declared in /etc/pf.conf.  They must already exist;
# this script never creates tables and never rewrites pf.conf.
PF_TABLE_V4="geo_block_v4"
PF_TABLE_V6="geo_block_v6"

# IPdeny aggregated dataset locations (HTTPS only) and the common file suffix.
IPV4_BASE_URL="https://www.ipdeny.com/ipblocks/data/aggregated"
IPV6_BASE_URL="https://www.ipdeny.com/ipv6/ipaddresses/aggregated"
ZONE_SUFFIX="-aggregated.zone"

# Per-request timeout in seconds handed to fetch(1), and the pause inserted
# between two consecutive requests so the run stays polite towards IPdeny.
FETCH_TIMEOUT=30
REQUEST_DELAY=1

# Minimum number of entries a merged candidate must contain to be considered
# plausible.  This is a truncation/garbage guard, not a policy knob, so the
# default is deliberately low: a single small country can legitimately have
# only a handful of aggregated ranges, and an over-tuned threshold would break
# such a configuration.  Raise it if you know roughly how large your own list
# is (for example a "cn ru" list has several thousand IPv4 ranges); a candidate
# below the threshold aborts the run and keeps the previous data.
MIN_IPV4_ENTRIES=1
MIN_IPV6_ENTRIES=1

# Mutual exclusion between concurrent runs (created atomically with mkdir).
LOCK_DIR="/var/run/pf-geo-block.lock"

# Parent directory for the private temporary workspace.  Set explicitly rather
# than relying on TMPDIR, which cron may not define (or may define oddly).
WORK_PARENT="/var/tmp"

# Ownership and mode of the installed production files.  They hold no secrets,
# but they must not be modifiable by unprivileged users because PF reads them.
FILE_OWNER="root:wheel"
FILE_MODE="0644"

# External commands the script depends on.  All of these are FreeBSD base
# system utilities; nothing outside base (and no bash) is required.
REQUIRED_COMMANDS="fetch pfctl awk grep sort wc mktemp mv cp rm chmod chown
                   sleep mkdir rmdir id date cat"

###############################################################################
# END OF CONFIGURATION - no edits needed below this line
###############################################################################

# Symbolic exit codes, so every failure path is easy to grep for in cron mail.
EX_PREREQ=1
EX_LOCKED=2
EX_FETCH=3
EX_VALIDATE=4
EX_INSTALL=5
EX_PFLOAD=6
EX_ROLLBACK=7
EX_SIGNAL=8

###############################################################################
# Logging helpers
#
# The script runs unattended, so every line is timestamped and self contained:
# cron mail or a log file must be understandable without knowing when or why
# the job ran.  Progress goes to stdout, problems to stderr, and individual
# CIDR entries are never logged - only counts.
###############################################################################

_timestamp() {
	date '+%Y-%m-%d %H:%M:%S%z'
}

log_info() {
	printf '[%s] %s: %s\n' "$(_timestamp)" "$PROG" "$*"
}

log_error() {
	printf '[%s] %s: ERROR: %s\n' "$(_timestamp)" "$PROG" "$*" >&2
}

# die <exit-code> <message...> - log and terminate; the EXIT trap performs the
# cleanup, so there is exactly one cleanup implementation.
die() {
	_rc="$1"
	shift
	log_error "$*"
	exit "$_rc"
}

PROG="${0##*/}"

###############################################################################
# State tracked for cleanup and rollback
#
# These are set as the run progresses so that the cleanup trap and the rollback
# path know precisely which resources exist and must be released or restored.
#
# TX_STATE is the transaction state machine.  It exists because an error is not
# the only way out of this script: a signal can arrive at any point, including
# between the two file renames or between the two PF table replacements, and
# the handler has to know how much of the production state may already have
# changed.  The value is always set BEFORE the operation it describes, so a
# state is "this may have happened", never "this definitely finished":
#
#   precommit        nothing outside the workspace has been modified
#   committing_files the file renames are in progress (V4_STAGED/V6_STAGED
#                    tell which ones already went through)
#   files_committed  both production files are new, no PF table touched yet
#   loading_v4       the IPv4 table replacement may have taken effect
#   v4_table_loaded  the IPv4 table is new, the IPv6 table is not
#   loading_v6       the IPv6 table replacement may have taken effect
#   complete         both files and both tables are new and consistent
###############################################################################

WORK_DIR=""		# private temporary workspace (mktemp -d)
CAND_V4=""		# merged IPv4 candidate inside the workspace
CAND_V6=""		# merged IPv6 candidate inside the workspace
LOCK_HELD=0		# 1 only if *this* process created the lock directory
V4_STAGED=""		# temporary file next to $IPV4_TARGET, "" once renamed
V6_STAGED=""		# temporary file next to $IPV6_TARGET, "" once renamed
V4_BACKUP=""		# copy of the previous $IPV4_TARGET, "" once consumed
V6_BACKUP=""		# copy of the previous $IPV6_TARGET, "" once consumed
TX_STATE="precommit"	# transaction state, see above
BACKUPS_DISPOSABLE=0	# 1 only when the backups are provably not needed
ROLLBACK_DONE=0		# 1 once rollback_transaction has run
ROLLBACK_RC=0		# result of that rollback, for idempotent re-entry

###############################################################################
# Cleanup and signal handling
#
# A single cleanup function releases the workspace and the lock on every exit
# path.  The EXIT trap is disarmed and the signals are set to "ignore" on
# entry, so neither an error inside cleanup nor a second signal arriving during
# cleanup can re-enter it recursively.
#
# Cleanup deliberately does NOT decide anything about the transaction: it only
# removes resources that are provably unnecessary.  In particular the rollback
# backups are removed only when $BACKUPS_DISPOSABLE says so (see below), so a
# signal that arrives mid-transaction can never destroy the last copy of the
# previous known-good blocklists.
###############################################################################

cleanup() {
	trap - EXIT
	trap '' HUP INT TERM

	# Remove all candidate data.  Nothing in here is needed once we are
	# done: the production files were either installed or intentionally
	# left untouched.
	if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
		rm -rf "$WORK_DIR"
	fi

	# Remove staged-but-not-renamed production files; a leftover dotfile in
	# /etc would only confuse the next administrator who looks.
	[ -n "$V4_STAGED" ] && rm -f "$V4_STAGED"
	[ -n "$V6_STAGED" ] && rm -f "$V6_STAGED"

	# The backups may be deleted only in three provably safe situations:
	#
	#   * precommit - the production files were never touched, so the
	#     backups are exact copies of what is still in place;
	#   * complete  - the new state is live and consistent, so the previous
	#     state is no longer wanted;
	#   * BACKUPS_DISPOSABLE=1 - a rollback ran and fully succeeded.
	#
	# In every other case (including "a signal hit us mid-transaction and
	# the rollback did not fully succeed") the backups are the last copy of
	# the known-good data and are kept, with their paths logged.
	if [ "$TX_STATE" = "precommit" ] || [ "$TX_STATE" = "complete" ] ||
	    [ "$BACKUPS_DISPOSABLE" -eq 1 ]; then
		[ -n "$V4_BACKUP" ] && rm -f "$V4_BACKUP"
		[ -n "$V6_BACKUP" ] && rm -f "$V6_BACKUP"
	else
		_keep4=""
		_keep6=""
		[ -n "$V4_BACKUP" ] && [ -f "$V4_BACKUP" ] && _keep4="$V4_BACKUP"
		[ -n "$V6_BACKUP" ] && [ -f "$V6_BACKUP" ] && _keep6="$V6_BACKUP"
		if [ -n "$_keep4" ] || [ -n "$_keep6" ]; then
			log_error "previous known-good data kept for manual recovery (transaction state: $TX_STATE):"
			[ -n "$_keep4" ] &&
				log_error "  cp -p $_keep4 $IPV4_TARGET && pfctl -t $PF_TABLE_V4 -T replace -f $IPV4_TARGET"
			[ -n "$_keep6" ] &&
				log_error "  cp -p $_keep6 $IPV6_TARGET && pfctl -t $PF_TABLE_V6 -T replace -f $IPV6_TARGET"
		fi
	fi

	# Release the lock only if this process owns it.  Never remove a lock
	# that belongs to another, possibly still running, instance.
	if [ "$LOCK_HELD" -eq 1 ]; then
		rm -f "$LOCK_DIR/pid"
		rmdir "$LOCK_DIR" 2>/dev/null ||
			log_error "Could not remove lock directory $LOCK_DIR"
	fi
}

# Signal handler.
#
# A signal is not automatically harmless: HUP/INT/TERM can arrive after the
# production files have been renamed or after one of the two PF tables has
# been replaced, and simply cleaning up would then leave IPv4 and IPv6 in a
# mixed state.  The handler therefore consults TX_STATE and runs the very same
# rollback that an ordinary failure would run.
#
# The shell runs a trap handler only between commands, so TX_STATE is never
# observed half-assigned; and because every state is set before the operation
# it covers, the handler always errs on the side of "this may already have
# happened".
on_signal() {
	_sig="$1"

	# Stop reacting to signals right away.  This protects the rollback and
	# the cleanup from being cut short, and because children inherit
	# SIG_IGN it also keeps the mv and pfctl processes started below alive
	# when the signal was sent to the whole process group (Ctrl-C, or a
	# shutdown killing the cron job).
	trap '' HUP INT TERM

	case "$TX_STATE" in
	precommit)
		# Nothing outside the workspace has been modified, so aborting
		# is all that is needed - and this is the only case in which it
		# is honest to say the production state is unchanged.
		log_error "SIG$_sig received before the commit point - aborting; production files and PF tables unchanged"
		cleanup
		exit "$EX_SIGNAL"
		;;
	complete)
		# The update was finished and consistent; only the final log
		# line was still missing.
		log_error "SIG$_sig received after the update had already completed - the new blocklists are live and consistent"
		cleanup
		exit "$EX_SIGNAL"
		;;
	esac

	log_error "SIG$_sig received at transaction state '$TX_STATE' - production state may already be partially updated; rolling back"
	rollback_transaction
	_sig_rc=$?
	if [ "$_sig_rc" -ne 0 ]; then
		log_error "ROLLBACK INCOMPLETE after SIG$_sig - inspect $IPV4_TARGET, $IPV6_TARGET and both PF tables manually"
		cleanup
		exit "$EX_ROLLBACK"
	fi
	log_error "interrupted by SIG$_sig; the previous known-good state is active again"
	cleanup
	exit "$EX_SIGNAL"
}

trap cleanup EXIT
trap 'on_signal HUP' HUP
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

###############################################################################
# Prerequisite checks
#
# Everything that can be checked without side effects is checked before the
# first byte is downloaded and long before any file or table is modified.
###############################################################################

# Running as root is required to read/write files in /etc and to talk to
# /dev/pf.  Checking explicitly turns a confusing pile of permission errors
# half way through the run into one clear message before anything happens.
require_root() {
	if [ "$(id -u)" -ne 0 ]; then
		die "$EX_PREREQ" "must run as root (current uid $(id -u)); nothing was downloaded or changed"
	fi
}

# Verify every external dependency up front.  On a stripped down or broken
# system it is much better to abort here than to discover a missing tool after
# the production files have been replaced.
require_commands() {
	_missing=""
	for _cmd in $REQUIRED_COMMANDS; do
		if ! command -v "$_cmd" >/dev/null 2>&1; then
			_missing="$_missing $_cmd"
		fi
	done
	if [ -n "$_missing" ]; then
		die "$EX_PREREQ" "required command(s) not found:$_missing"
	fi
}

# Sanity-check the configuration itself.  A typo in a country code would
# otherwise show up as a puzzling download failure.
check_config() {
	if [ -z "$COUNTRIES" ]; then
		die "$EX_PREREQ" "COUNTRIES is empty - nothing to do"
	fi
	for _cc in $COUNTRIES; do
		case "$_cc" in
		[a-z][a-z]) ;;
		*)
			die "$EX_PREREQ" "invalid country code '$_cc': expected two lower case letters (ISO 3166-1 alpha-2)"
			;;
		esac
	done

	# The production files are installed by renaming a temporary file that
	# lives in the same directory, so that directory has to exist.
	for _path in "$IPV4_TARGET" "$IPV6_TARGET"; do
		_dir="${_path%/*}"
		[ -n "$_dir" ] || _dir="/"
		if [ ! -d "$_dir" ]; then
			die "$EX_PREREQ" "destination directory $_dir for $_path does not exist"
		fi
	done

	if [ "$IPV4_TARGET" = "$IPV6_TARGET" ]; then
		die "$EX_PREREQ" "IPV4_TARGET and IPV6_TARGET must differ - IPv4 and IPv6 data must never share a file"
	fi
}

# PF must be usable and both tables must already be declared in pf.conf.
# Creating a missing table here would paper over a configuration error: the
# table would exist but no rule would reference it, so the administrator would
# believe traffic is blocked while it is not.
check_pf() {
	if ! pfctl -si >/dev/null 2>&1; then
		die "$EX_PREREQ" "cannot query PF with pfctl -si (is the pf module loaded?)"
	fi

	_status=$(pfctl -si 2>/dev/null | awk '/^Status:/ { print $2; exit }')
	log_info "PF status: ${_status:-unknown}"
	if [ "$_status" = "Disabled" ]; then
		log_info "note: PF is currently disabled; tables will still be updated"
	fi

	for _tbl in "$PF_TABLE_V4" "$PF_TABLE_V6"; do
		if ! pf_table_exists "$_tbl"; then
			die "$EX_PREREQ" "PF table <$_tbl> does not exist; declare it in /etc/pf.conf and reload - no files were modified"
		fi
	done
	log_info "PF tables <$PF_TABLE_V4> and <$PF_TABLE_V6> are present"
}

# Exact-match lookup in the list of loaded tables (pfctl -sT prints one table
# name per line); a substring match would confuse geo_block_v4 with, say,
# geo_block_v4_old.
pf_table_exists() {
	pfctl -s Tables 2>/dev/null |
		awk -v want="$1" '
			{ gsub(/[ \t]/, ""); if ($0 == want) { found = 1 } }
			END { exit(found ? 0 : 1) }
		'
}

###############################################################################
# Concurrency lock
#
# mkdir(2) is atomic and fails if the directory exists, which makes it a
# dependency-free mutex in /bin/sh.  A second instance (for example a manual
# run while the cron job is active) exits immediately instead of racing over
# the same temporary files and PF tables.
#
# A stale lock left behind by a crashed run is NOT removed automatically: doing
# so would risk deleting the lock of a live process.  The message tells the
# administrator how to clear it after checking.
###############################################################################

acquire_lock() {
	if ! mkdir "$LOCK_DIR" 2>/dev/null; then
		_owner=""
		[ -f "$LOCK_DIR/pid" ] && _owner=$(cat "$LOCK_DIR/pid" 2>/dev/null)
		log_error "lock $LOCK_DIR exists - another run is probably active (pid ${_owner:-unknown})"
		die "$EX_LOCKED" "if no such process exists, remove the lock manually: rm -rf $LOCK_DIR"
	fi
	LOCK_HELD=1
	printf '%s\n' "$$" > "$LOCK_DIR/pid"
}

###############################################################################
# Temporary workspace
#
# Every download and every candidate file is built here, never in /etc, so the
# production data stays untouched until all validation has passed.  mktemp -d
# creates the directory with mode 0700, which keeps unprivileged users from
# reading or, more importantly, tampering with candidate data.
###############################################################################

make_workspace() {
	WORK_DIR=$(mktemp -d "$WORK_PARENT/pf-geoblock.XXXXXXXXXX") ||
		die "$EX_PREREQ" "could not create a temporary directory under $WORK_PARENT"
	chmod 0700 "$WORK_DIR"
	CAND_V4="$WORK_DIR/candidate.v4"
	CAND_V6="$WORK_DIR/candidate.v6"
	log_info "workspace: $WORK_DIR"
}

###############################################################################
# Downloading
#
# FreeBSD fetch(1) is used with an explicit timeout and quiet output; it exits
# non-zero on HTTP errors, connection failures and timeouts.  A successful exit
# status alone is not trusted, however - see validate_raw() and the pfctl
# validation step, which also reject HTML error pages and malformed data.
#
# At least one second passes between two consecutive requests.  The delay is
# inserted *before* each request except the first, which yields the required
# spacing (also across the IPv4 -> IPv6 and country -> country transitions)
# without a pointless sleep after the final download.
###############################################################################

REQUESTS_MADE=0

fetch_dataset() {
	_url="$1"
	_out="$2"

	if [ "$REQUESTS_MADE" -gt 0 ]; then
		sleep "$REQUEST_DELAY"
	fi
	REQUESTS_MADE=$((REQUESTS_MADE + 1))

	log_info "fetching $_url"
	if ! fetch -q -T "$FETCH_TIMEOUT" -o "$_out" "$_url"; then
		log_error "download failed: $_url"
		return 1
	fi
	return 0
}

###############################################################################
# Raw data validation
#
# Applied to every single downloaded file before it is merged into anything.
# The goal is to catch the failure modes that still return HTTP 200: empty
# bodies, captive portal or proxy error pages, and HTML "not found" pages.
###############################################################################

validate_raw() {
	_file="$1"
	_label="$2"

	if [ ! -f "$_file" ]; then
		log_error "$_label: downloaded file is missing"
		return 1
	fi
	if [ ! -s "$_file" ]; then
		log_error "$_label: downloaded file is empty"
		return 1
	fi
	# Anchored match: real zone files start with digits or hex, so a line
	# that begins with a markup tag can only be a web error page.
	if grep -q -i -E '^[[:space:]]*<(!doctype|html|head|body|\?xml)' "$_file"; then
		log_error "$_label: content looks like an HTML/XML error page, not a zone file"
		return 1
	fi
	return 0
}

###############################################################################
# Cleaning, normalization and address-family separation
#
# One awk pass per downloaded file: strip CR, comments and surrounding
# whitespace, drop blank lines, and verify that what remains is a CIDR entry of
# the *expected* address family.  This is deliberately a lightweight format
# check (pfctl later has the final word), but it is strict about the family, so
# IPv4 data can never leak into the IPv6 candidate or vice versa.
#
# An unusable line aborts the run rather than being silently discarded: if the
# dataset does not look like what we expect, we do not know what we would be
# installing.  Only the first few offending lines are logged so cron mail stays
# readable.
###############################################################################

normalize_file() {
	_family="$1"
	_in="$2"
	_out="$3"
	_label="$4"

	awk -v fam="$_family" -v label="$_label" '
		function valid4(s,    parts, octets, i) {
			if (s !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/)
				return 0
			split(s, parts, "/")
			if (split(parts[1], octets, ".") != 4)
				return 0
			for (i = 1; i <= 4; i++) {
				if (length(octets[i]) > 3 || octets[i] + 0 > 255)
					return 0
			}
			if (length(parts[2]) > 2 || parts[2] + 0 > 32)
				return 0
			return 1
		}
		function valid6(s,    parts) {
			# Hex groups and colons only: a dot here would mean an
			# IPv4 (or IPv4-mapped) entry in the IPv6 dataset.
			if (s !~ /^[0-9A-Fa-f:]+\/[0-9]+$/)
				return 0
			split(s, parts, "/")
			if (parts[1] !~ /:/)
				return 0
			if (length(parts[2]) > 3 || parts[2] + 0 > 128)
				return 0
			return 1
		}
		{
			line = $0
			sub(/\r$/, "", line)		# tolerate CRLF input
			sub(/[#;].*$/, "", line)	# drop comments
			gsub(/^[ \t]+|[ \t]+$/, "", line)
			if (line == "")
				next
			if (fam == "4" ? valid4(line) : valid6(line)) {
				print line
				good++
			} else {
				bad++
				if (bad <= 3)
					printf("%s: line %d is not a valid IPv%s network: %s\n",
					    label, FNR, fam, line) > "/dev/stderr"
			}
		}
		END {
			if (bad > 0) {
				printf("%s: %d unusable line(s)\n", label, bad) > "/dev/stderr"
				exit 1
			}
			if (good + 0 == 0) {
				printf("%s: no usable IPv%s network entries\n", label, fam) > "/dev/stderr"
				exit 1
			}
		}
	' "$_in" > "$_out" || return 1

	return 0
}

# Download and vet both address families for every configured country.  Any
# failure aborts the whole run: an incomplete country set must never be
# installed, and the previous blocklist is a better answer than a partial one.
download_and_normalize() {
	for _cc in $COUNTRIES; do
		fetch_dataset "$IPV4_BASE_URL/$_cc$ZONE_SUFFIX" "$WORK_DIR/raw.v4.$_cc" ||
			die "$EX_FETCH" "aborting: IPv4 dataset for '$_cc' could not be downloaded; production files and PF tables left unchanged"
		validate_raw "$WORK_DIR/raw.v4.$_cc" "$_cc/IPv4" ||
			die "$EX_VALIDATE" "aborting: IPv4 dataset for '$_cc' failed raw validation; production files and PF tables left unchanged"
		normalize_file 4 "$WORK_DIR/raw.v4.$_cc" "$WORK_DIR/clean.v4.$_cc" "$_cc/IPv4" ||
			die "$EX_VALIDATE" "aborting: IPv4 dataset for '$_cc' failed format validation; production files and PF tables left unchanged"

		fetch_dataset "$IPV6_BASE_URL/$_cc$ZONE_SUFFIX" "$WORK_DIR/raw.v6.$_cc" ||
			die "$EX_FETCH" "aborting: IPv6 dataset for '$_cc' could not be downloaded; production files and PF tables left unchanged"
		validate_raw "$WORK_DIR/raw.v6.$_cc" "$_cc/IPv6" ||
			die "$EX_VALIDATE" "aborting: IPv6 dataset for '$_cc' failed raw validation; production files and PF tables left unchanged"
		normalize_file 6 "$WORK_DIR/raw.v6.$_cc" "$WORK_DIR/clean.v6.$_cc" "$_cc/IPv6" ||
			die "$EX_VALIDATE" "aborting: IPv6 dataset for '$_cc' failed format validation; production files and PF tables left unchanged"
	done
	log_info "all datasets downloaded and pre-validated ($REQUESTS_MADE requests)"
}

# Merge the per-country files of one family into a single deterministic
# candidate: sort -u under LC_ALL=C gives byte-stable output and removes
# duplicates that overlap between neighbouring countries' datasets.
#
# IPdeny already publishes aggregated ranges, so no CIDR re-aggregation is
# attempted here - that is not a job for a shell script.
build_candidate() {
	_family="$1"
	_candidate="$2"
	_min="$3"

	cat "$WORK_DIR"/clean.v"$_family".* | sort -u > "$_candidate" ||
		die "$EX_VALIDATE" "could not build the IPv$_family candidate list"

	if [ ! -s "$_candidate" ]; then
		die "$EX_VALIDATE" "IPv$_family candidate list is empty; keeping previous data"
	fi

	# Re-run the family check over the merged result.  Cheap insurance that
	# the file handed to PF really contains one family only.
	normalize_file "$_family" "$_candidate" /dev/null "IPv$_family candidate" ||
		die "$EX_VALIDATE" "IPv$_family candidate failed the final address-family check; keeping previous data"

	_count=$(wc -l < "$_candidate" | awk '{ print $1 }')
	log_info "IPv$_family candidate: $_count entries"
	if [ "$_count" -lt "$_min" ]; then
		die "$EX_VALIDATE" "IPv$_family candidate has only $_count entries, minimum is $_min; keeping previous data"
	fi

	# Export the counts for the final summary line.
	if [ "$_family" = "4" ]; then
		COUNT_V4="$_count"
	else
		COUNT_V6="$_count"
	fi
}

###############################################################################
# PF validation
#
# pfctl is the only authority on what PF accepts, so the candidate files are
# handed to it *before* the production files are replaced - but in a way that
# cannot touch the running firewall:
#
#   pfctl -n -f <throw-away ruleset>
#
# The throw-away ruleset declares the tables with "file" pointing at the
# candidates and mirrors the blocking rules.  pfctl reads and parses every
# address in those files while parsing the ruleset, and -n (no action) makes it
# stop before loading anything into the kernel: no table is created, flushed or
# replaced, and the active ruleset is untouched.
#
# Note on what is NOT used here:
#   * "pfctl -t <table> -T replace -f <file>" against the production table
#     would validate by destroying the current contents - the exact outcome
#     this script exists to prevent.
#   * "pfctl -t <table> -T test -f <file>" is not a validation mode at all: it
#     tests whether addresses are matched by an existing table, which is
#     unrelated to import syntax checking.
###############################################################################

validate_with_pfctl() {
	_conf="$WORK_DIR/validate.pf.conf"

	cat > "$_conf" <<EOF
# Throw-away ruleset used only with "pfctl -n -f" to parse the candidate
# network lists.  It is never loaded.
table <$PF_TABLE_V4> persist file "$CAND_V4"
table <$PF_TABLE_V6> persist file "$CAND_V6"

block in quick inet  from <$PF_TABLE_V4> to any
block in quick inet6 from <$PF_TABLE_V6> to any
EOF

	log_info "validating both candidate lists with pfctl -n -f (no ruleset or table changes)"
	if ! pfctl -n -f "$_conf"; then
		die "$EX_VALIDATE" "pfctl rejected the candidate lists; production files and PF tables left unchanged"
	fi
	log_info "pfctl accepted both candidate lists"
}

###############################################################################
# Atomic production file installation
#
# Installation is split into "stage" and "commit" so that IPv4 and IPv6 really
# behave as one transaction.  Everything that can fail (copying, ownership,
# permissions, disk space) happens during staging, while both production files
# are still untouched.  Only afterwards are the two renames performed, one
# immediately after the other.
#
# Staging one family:
#   1. copy the current file aside as a backup, in the same directory, so that
#      a rollback is a rename and cannot itself fail half way through;
#   2. copy the candidate to a temporary name in the destination directory -
#      same filesystem, which is what makes the later rename atomic;
#   3. set ownership and mode on that temporary file, so the data is never
#      visible under the final name with wrong permissions.
#
# Committing: mv(1) renames each staged file over its target.  A reader (or
# pfctl) sees either the complete old file or the complete new one, never a
# truncated one, because the active files are never opened for writing in
# place.  If the second rename fails, the first is undone from its backup.
###############################################################################

stage_candidate() {
	_candidate="$1"
	_target="$2"
	_family="$3"

	_dir="${_target%/*}"
	[ -n "$_dir" ] || _dir="/"
	_name="${_target##*/}"
	_staged="$_dir/.$_name.new.$$"
	_backup="$_dir/.$_name.bak.$$"

	# Keep the previous contents for the rollback paths.  The tracking
	# variable is set immediately after the copy so the cleanup trap always
	# knows about a backup that exists on disk.
	if [ -f "$_target" ]; then
		cp -p "$_target" "$_backup" ||
			die "$EX_INSTALL" "could not back up $_target; aborting with no changes made"
		if [ "$_family" = "4" ]; then
			V4_BACKUP="$_backup"
		else
			V6_BACKUP="$_backup"
		fi
	else
		log_info "no existing $_target (first run) - no rollback copy available for IPv$_family"
	fi

	rm -f "$_staged"
	if [ "$_family" = "4" ]; then
		V4_STAGED="$_staged"
	else
		V6_STAGED="$_staged"
	fi

	cp "$_candidate" "$_staged" ||
		die "$EX_INSTALL" "could not stage the IPv$_family list in $_dir"
	chown "$FILE_OWNER" "$_staged" ||
		die "$EX_INSTALL" "could not set ownership $FILE_OWNER on $_staged"
	chmod "$FILE_MODE" "$_staged" ||
		die "$EX_INSTALL" "could not set mode $FILE_MODE on $_staged"

	log_info "staged IPv$_family list for $_target ($FILE_OWNER $FILE_MODE)"
}

commit_staged() {
	# Entering the transaction.  The state is raised BEFORE the first
	# rename, because from this instant on both an error and a signal must
	# assume that a production file may already have been replaced.
	TX_STATE="committing_files"

	if ! mv "$V4_STAGED" "$IPV4_TARGET"; then
		# V4_STAGED is still set, so rollback_transaction knows that
		# nothing was committed and cleanup removes the staged file.
		abort_with_rollback "$EX_INSTALL" - "could not install $IPV4_TARGET"
	fi
	V4_STAGED=""
	log_info "installed $IPV4_TARGET"

	if ! mv "$V6_STAGED" "$IPV6_TARGET"; then
		abort_with_rollback "$EX_INSTALL" - "could not install $IPV6_TARGET"
	fi
	V6_STAGED=""
	log_info "installed $IPV6_TARGET"

	TX_STATE="files_committed"
}

###############################################################################
# Loading the new data into the live PF tables
#
# Only the table contents change: "pfctl -T replace" swaps the addresses of an
# existing table in one operation, which is far safer than reloading the whole
# ruleset with "pfctl -f /etc/pf.conf" (that would also re-apply unrelated,
# possibly hand-edited or newer, ruleset changes and briefly disturb state).
#
# If the second replacement fails after the first succeeded - or a signal
# arrives in between - IPv4 and IPv6 would be out of sync, so the previous
# files and table contents are restored from the backups taken during staging.
# That is the job of rollback_transaction() below, which is driven by TX_STATE
# and is shared by the error paths and the signal handler.
###############################################################################

replace_table() {
	_table="$1"
	_file="$2"

	log_info "replacing contents of PF table <$_table> from $_file"
	if ! pfctl -t "$_table" -T replace -f "$_file" >/dev/null; then
		log_error "pfctl failed to replace PF table <$_table>"
		return 1
	fi
	return 0
}

# Restore one family's production file from its backup, and optionally reload
# the live table from the restored file.
#
# "pfctl -T replace" is a single transaction in the kernel, so a failed table
# replacement leaves the table's previous contents in place.  That is why the
# table only has to be reloaded for a family whose replacement may already
# have taken effect ($_reload_table = yes).
#
# With no backup (first run) the target file is deliberately left alone rather
# than deleted: pf.conf declares the tables with "file", and removing the file
# would make the next "pfctl -f /etc/pf.conf" fail outright.
#
# Return: 0 restored, 1 restore failed, 2 nothing to restore (first run).
restore_family() {
	_backup="$1"
	_target="$2"
	_table="$3"
	_family="$4"
	_reload_table="$5"

	if [ -z "$_backup" ] || [ ! -f "$_backup" ]; then
		log_error "no backup of $_target exists (first run?) - the previous IPv$_family data cannot be restored"
		return 2
	fi

	if ! mv "$_backup" "$_target"; then
		log_error "could not restore $_target from $_backup"
		return 1
	fi
	# The rename consumed the backup: stop tracking it so the cleanup trap
	# neither tries to delete it nor reports it as a recoverable copy.  A
	# backup whose restore FAILED stays tracked and is therefore preserved.
	if [ "$_family" = "4" ]; then
		V4_BACKUP=""
	else
		V6_BACKUP=""
	fi
	log_info "restored previous $_target"

	if [ "$_reload_table" = "yes" ]; then
		if ! pfctl -t "$_table" -T replace -f "$_target" >/dev/null; then
			log_error "could not restore contents of PF table <$_table> from $_target"
			return 1
		fi
		log_info "restored previous contents of PF table <$_table>"
	fi
	return 0
}

# Undo as much of the transaction as TX_STATE says may have been applied.
#
# This is the single rollback implementation: the ordinary failure paths
# (abort_with_rollback) and the signal handler both call it, which is what
# makes a SIGTERM arriving mid-transaction behave exactly like a failed pfctl.
#
# Return: 0 fully restored (or nothing to undo), 1 the previous state is not
# fully back, 2 nothing to restore but the live tables were never touched.
rollback_transaction() {
	# A rollback must run to completion: ignore signals so that neither
	# this shell nor the mv/pfctl children it starts can be killed part
	# way through putting the old state back.
	trap '' HUP INT TERM

	# Idempotent.  An ordinary failure path may already have rolled back
	# when a signal arrives (or vice versa), and undoing an undo would
	# corrupt exactly the state we are protecting.
	if [ "$ROLLBACK_DONE" -eq 1 ]; then
		return "$ROLLBACK_RC"
	fi
	ROLLBACK_DONE=1
	ROLLBACK_RC=0

	if [ "$TX_STATE" = "precommit" ]; then
		return 0
	fi

	# Which live tables may already hold the new data?  The "loading_*"
	# states are ambiguous by nature - a signal may have arrived before or
	# after the ioctl took effect - so they are treated pessimistically.
	# Reloading a table from the restored file is idempotent, so an
	# unnecessary reload costs nothing but a syscall.  (When pfctl itself
	# reported the failure the state is narrowed first; see
	# abort_with_rollback.)
	_reload4=no
	_reload6=no
	case "$TX_STATE" in
	loading_v4|v4_table_loaded)
		_reload4=yes
		;;
	loading_v6|complete)
		_reload4=yes
		_reload6=yes
		;;
	esac

	log_error "rolling back from transaction state '$TX_STATE'"

	# A family whose staged file is still on disk was never renamed into
	# place, so there is nothing to restore for it; cleanup discards the
	# staged copy.
	_rb4=0
	_rb6=0
	# A staged path variable can still be non-empty for the brief interval after
	# mv(1) has successfully renamed the file but before commit_staged() clears
	# V4_STAGED/V6_STAGED.  A signal delivered in exactly that interval must not
	# make rollback mistake an already-committed file for an uncommitted staged
	# file.  Therefore the on-disk existence of the staged file is authoritative:
	# if the variable is empty OR the staged file no longer exists, the rename may
	# already have happened and the production file must be restored from backup.
	if [ -z "$V4_STAGED" ] || [ ! -f "$V4_STAGED" ]; then
		restore_family "$V4_BACKUP" "$IPV4_TARGET" "$PF_TABLE_V4" 4 "$_reload4" || _rb4=$?
	fi
	if [ -z "$V6_STAGED" ] || [ ! -f "$V6_STAGED" ]; then
		restore_family "$V6_BACKUP" "$IPV6_TARGET" "$PF_TABLE_V6" 6 "$_reload6" || _rb6=$?
	fi

	if [ "$_rb4" -eq 1 ] || [ "$_rb6" -eq 1 ]; then
		# A restore step actually failed.
		ROLLBACK_RC=1
	elif [ "$_rb4" -eq 2 ] || [ "$_rb6" -eq 2 ]; then
		# Nothing to restore (first run).  That is only a real problem
		# if a live table may already carry the new data, because then
		# the two families are out of sync and we cannot fix it.
		if [ "$_reload4" = "yes" ] || [ "$_reload6" = "yes" ]; then
			ROLLBACK_RC=1
		else
			ROLLBACK_RC=2
		fi
	fi

	if [ "$ROLLBACK_RC" -eq 0 ]; then
		# Everything is back where it was, so the backup copies have
		# served their purpose and cleanup may remove them.
		BACKUPS_DISPOSABLE=1
		log_info "rollback complete: the previous known-good state is active again"
	fi
	return "$ROLLBACK_RC"
}

# Roll back and terminate.  Used by every failure inside the transaction so
# that the exit code reflects what actually happened to the production state.
#
# abort_with_rollback <exit-code> <narrowed-state|-> <message...>
#
# The second argument lets a caller narrow TX_STATE when the failing command
# proved that its change did NOT take effect - "pfctl -T replace" is a single
# kernel transaction, so a pfctl that exits non-zero on its own leaves the
# table contents alone.  Without that knowledge the rollback would try to
# "restore" a table that never changed, and if that attempt failed for the same
# underlying reason (a table removed from pf.conf, for instance) it would
# report a mixed state that does not exist.
#
# The narrowing happens inside this function on purpose: a pending signal is
# delivered before the call, so the handler still sees the pessimistic state
# and cannot be fooled by a narrowing that a killed pfctl did not justify.
abort_with_rollback() {
	_ar_rc="$1"
	_ar_state="$2"
	shift 2
	log_error "$*"

	if [ "$_ar_state" != "-" ]; then
		TX_STATE="$_ar_state"
	fi

	rollback_transaction
	_ar_rb=$?
	if [ "$_ar_rb" -eq 1 ]; then
		die "$EX_ROLLBACK" "ROLLBACK INCOMPLETE - the IPv4 and IPv6 blocklists may be out of sync; inspect $IPV4_TARGET, $IPV6_TARGET and both PF tables manually"
	fi
	if [ "$_ar_rb" -eq 2 ]; then
		log_error "note: a new list file is in place while the live table still holds the previous data (no backup existed); the next successful run resolves this"
	fi
	die "$_ar_rc" "aborted at transaction state '$TX_STATE'; the previous known-good state is active"
}

load_tables() {
	# As in commit_staged, each state is raised before the operation it
	# describes: once pfctl has been started we can no longer know whether
	# the replacement took effect.
	TX_STATE="loading_v4"
	if ! replace_table "$PF_TABLE_V4" "$IPV4_TARGET"; then
		# pfctl failed by itself, so neither table was changed: only the
		# two production files have to go back.
		abort_with_rollback "$EX_PFLOAD" "files_committed" \
			"IPv4 table replacement failed"
	fi
	TX_STATE="v4_table_loaded"

	TX_STATE="loading_v6"
	if ! replace_table "$PF_TABLE_V6" "$IPV6_TARGET"; then
		# The IPv4 table is live and the IPv6 one was not changed, so
		# the files plus the IPv4 table contents have to go back.
		abort_with_rollback "$EX_PFLOAD" "v4_table_loaded" \
			"IPv6 table replacement failed after the IPv4 table had already been replaced"
	fi

	# Both tables are live and consistent with the installed files.  The
	# transaction is closed here, which is also what tells cleanup that the
	# backups may finally be discarded.
	TX_STATE="complete"
	log_info "both PF tables replaced successfully"
}

###############################################################################
# Main
###############################################################################

COUNT_V4=0
COUNT_V6=0

log_info "=== geo-blocking update started ==="
log_info "countries: $COUNTRIES"
log_info "targets: $IPV4_TARGET (<$PF_TABLE_V4>), $IPV6_TARGET (<$PF_TABLE_V6>)"

require_root
require_commands
check_config
check_pf
acquire_lock
make_workspace

download_and_normalize
build_candidate 4 "$CAND_V4" "$MIN_IPV4_ENTRIES"
build_candidate 6 "$CAND_V6" "$MIN_IPV6_ENTRIES"
validate_with_pfctl

# Staging still changes nothing the firewall or any reader can see; it only
# prepares both files next to their targets and takes the rollback copies.
stage_candidate "$CAND_V4" "$IPV4_TARGET" 4
stage_candidate "$CAND_V6" "$IPV6_TARGET" 6

# Point of no return: from here on production state changes, and every failure
# path below restores the previous known-good data.
commit_staged
load_tables

log_info "=== geo-blocking update completed successfully: $COUNT_V4 IPv4 and $COUNT_V6 IPv6 entries ==="
exit 0

###############################################################################
# APPENDIX A - cron
#
# Run once every 24 hours.  Pick a minute that is not on the hour so the whole
# internet does not hit IPdeny at 00:00.
#
# In /etc/crontab (system crontab) the user field is required:
#
#   17 4 * * * root /usr/local/sbin/update-pf-geoblock.sh
#
# In root's personal crontab ("crontab -e" as root) there is NO user field -
# the job already runs as that user:
#
#   17 4 * * * /usr/local/sbin/update-pf-geoblock.sh
#
# Adding the "root" field to a personal crontab makes cron try to execute a
# command literally named "root" and the job fails.
#
# Output handling: cron mails stdout and stderr to the crontab owner.  To log
# to a file instead:
#
#   17 4 * * * root /usr/local/sbin/update-pf-geoblock.sh >> /var/log/pf-geoblock.log 2>&1
#
#
# APPENDIX B - /etc/pf.conf (example; this script never edits pf.conf)
#
#   table <geo_block_v4> persist file "/etc/pf.IPv4_geo_block"
#   table <geo_block_v6> persist file "/etc/pf.IPv6_geo_block"
#
#   block in quick inet  from <geo_block_v4> to any
#   block in quick inet6 from <geo_block_v6> to any
#
# The table names and file paths must match PF_TABLE_V4/PF_TABLE_V6 and
# IPV4_TARGET/IPV6_TARGET in the configuration section above.
#
#
# APPENDIX C - installation
#
#   1. Install the script:
#        install -o root -g wheel -m 0700 update-pf-geoblock.sh \
#            /usr/local/sbin/update-pf-geoblock.sh
#      0700 is the most restrictive choice. 0750 may be used if members of the
#      owning group should also be allowed to execute the script.
#
#   2. Create the two table files if they do not exist yet, because pf.conf
#      declares tables with "file" and a missing file makes the ruleset fail
#      to load:
#        : > /etc/pf.IPv4_geo_block
#        : > /etc/pf.IPv6_geo_block
#        chown root:wheel /etc/pf.IPv4_geo_block /etc/pf.IPv6_geo_block
#        chmod 0644 /etc/pf.IPv4_geo_block /etc/pf.IPv6_geo_block
#
#   3. Add the table declarations and block rules from Appendix B to
#      /etc/pf.conf, then check and load the ruleset:
#        pfctl -n -f /etc/pf.conf      # parse only, changes nothing
#        pfctl -f  /etc/pf.conf        # load
#
#   4. Run the updater manually once before enabling cron, and read the output:
#        /usr/local/sbin/update-pf-geoblock.sh
#
#   5. Enable the cron job from Appendix A.
#
#   6. Inspect the live tables:
#        pfctl -t geo_block_v4 -T show | wc -l
#        pfctl -t geo_block_v6 -T show | wc -l
#        pfctl -t geo_block_v4 -T show
#        pfctl -t geo_block_v6 -T show
###############################################################################
