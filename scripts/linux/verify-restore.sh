#!/usr/bin/env bash
#
# verify-restore.sh — prove the backup can actually be restored.
#
# Restores the latest snapshot to a temporary directory and compares a SHA-256
# checksum of every restored file against the live share. This is the manual
# disaster-recovery test that was done once by hand, automated so it keeps
# happening after everyone has stopped thinking about it.
#
# Runs weekly on BKP01 from root's crontab.
#
# On comparing against the live share: the share changes between the snapshot
# and the comparison, so a file legitimately edited since the backup will show
# as a mismatch. In this lab the test data is static, so any difference is a
# real fault. Against a changing dataset this would instead compare two restores
# of the same snapshot.
#
set -uo pipefail

REPO=/var/backups/restic-repo
PASSWORD_FILE=/etc/restic-pass
SHARE_MOUNT=/mnt/dc01-share
STATE_DIR=/var/lib/infralab
TEXTFILE_DIR=/var/lib/prometheus/node-exporter
METRIC_FILE="$TEXTFILE_DIR/infralab_restore_test.prom"
LAST_SUCCESS_FILE="$STATE_DIR/restore-test-last-success"

mkdir -p "$STATE_DIR" "$TEXTFILE_DIR"

success=0
files_checked=0
mismatches=0
RESTORE_DIR=""
SRC_SUMS=""
DST_SUMS=""

# shellcheck disable=SC2329  # invoked by cleanup(), which runs from the EXIT trap
publish_metrics() {
    local last_success tmp
    last_success=$(cat "$LAST_SUCCESS_FILE" 2>/dev/null || echo 0)
    tmp=$(mktemp "${METRIC_FILE}.XXXXXX")
    cat > "$tmp" <<EOF
# HELP infralab_restore_test_success 1 if the most recent restore verification passed, 0 otherwise.
# TYPE infralab_restore_test_success gauge
infralab_restore_test_success ${success}
# HELP infralab_restore_test_files_checked Files compared in the most recent restore verification.
# TYPE infralab_restore_test_files_checked gauge
infralab_restore_test_files_checked ${files_checked}
# HELP infralab_restore_test_mismatches Checksum mismatches in the most recent restore verification.
# TYPE infralab_restore_test_mismatches gauge
infralab_restore_test_mismatches ${mismatches}
# HELP infralab_restore_test_last_success_timestamp_seconds Unix time of the most recent passing restore verification.
# TYPE infralab_restore_test_last_success_timestamp_seconds gauge
infralab_restore_test_last_success_timestamp_seconds ${last_success}
EOF
    chmod 0644 "$tmp"
    mv "$tmp" "$METRIC_FILE"
}

# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup() {
    [ -n "$RESTORE_DIR" ] && rm -rf "$RESTORE_DIR"
    [ -n "$SRC_SUMS" ] && rm -f "$SRC_SUMS"
    [ -n "$DST_SUMS" ] && rm -f "$DST_SUMS"
    publish_metrics
}
trap cleanup EXIT

export RESTIC_REPOSITORY="$REPO"
export RESTIC_PASSWORD_FILE="$PASSWORD_FILE"

if ! mountpoint -q "$SHARE_MOUNT"; then
    echo "ERROR: $SHARE_MOUNT is not mounted, nothing to compare against" >&2
    exit 1
fi

RESTORE_DIR=$(mktemp -d /var/tmp/infralab-restore.XXXXXX)
echo "==> Restoring latest snapshot to $RESTORE_DIR"
if ! restic restore latest --tag dc01-share --target "$RESTORE_DIR"; then
    echo "ERROR: restic restore failed" >&2
    exit 1
fi

# restic recreates the full absolute source path underneath --target.
RESTORED_ROOT="${RESTORE_DIR}${SHARE_MOUNT}"
if [ ! -d "$RESTORED_ROOT" ]; then
    echo "ERROR: expected the restored tree at $RESTORED_ROOT, not found" >&2
    exit 1
fi

SRC_SUMS=$(mktemp)
DST_SUMS=$(mktemp)

# Paths are taken relative to each tree root so the two lists are comparable.
( cd "$SHARE_MOUNT"   && find . -type f -exec sha256sum {} + ) 2>/dev/null | sort -k2 > "$SRC_SUMS"
( cd "$RESTORED_ROOT" && find . -type f -exec sha256sum {} + ) 2>/dev/null | sort -k2 > "$DST_SUMS"

files_checked=$(wc -l < "$SRC_SUMS")

if diff_output=$(diff "$SRC_SUMS" "$DST_SUMS"); then
    mismatches=0
else
    # Counts added, removed and changed lines, so a missing file, an extra file
    # and a corrupted file all register.
    mismatches=$(printf '%s\n' "$diff_output" | grep -c '^[<>]' || true)
    echo "==> Differences between the live share and the restored tree:" >&2
    printf '%s\n' "$diff_output" >&2
fi

if [ "$mismatches" -ne 0 ]; then
    echo "Restore verification FAILED"
    echo "Files checked:   $files_checked"
    echo "Mismatch count:  $mismatches"
    exit 1
fi

success=1
date +%s > "$LAST_SUCCESS_FILE"
echo "Restore verification successful"
echo "Files checked:   $files_checked"
echo "Mismatch count:  0"
exit 0
