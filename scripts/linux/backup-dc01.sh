#!/usr/bin/env bash
#
# backup-dc01.sh — back up DC01's CompanyShare into the local restic repository.
#
# Runs on BKP01 from root's crontab at 02:00 daily.
#
# Publishes Prometheus metrics through the node_exporter textfile collector so
# that a backup which stops running is visible in monitoring rather than
# discovered the next time someone needs a restore.
#
set -uo pipefail

REPO=/var/backups/restic-repo
PASSWORD_FILE=/etc/restic-pass
SHARE_MOUNT=/mnt/dc01-share
STATE_DIR=/var/lib/infralab
TEXTFILE_DIR=/var/lib/prometheus/node-exporter
METRIC_FILE="$TEXTFILE_DIR/infralab_backup.prom"
LAST_SUCCESS_FILE="$STATE_DIR/backup-last-success"

mkdir -p "$STATE_DIR" "$TEXTFILE_DIR"

exit_code=1
mount_ok=0
snapshot_count=0

# shellcheck disable=SC2329  # invoked by the EXIT trap below
publish_metrics() {
    # Runs on every exit path, including failure. Dropping the metrics when a
    # run fails would turn a broken backup into "no data", and an alert that
    # never fires because its series vanished is worse than no alert at all.
    #
    # The last-success timestamp is kept in its own state file precisely so a
    # failed run can still report the true value instead of clearing it.
    local last_success tmp
    last_success=$(cat "$LAST_SUCCESS_FILE" 2>/dev/null || echo 0)
    tmp=$(mktemp "${METRIC_FILE}.XXXXXX")
    cat > "$tmp" <<EOF
# HELP infralab_backup_last_run_exit_code Exit code of the most recent backup run. 0 is success.
# TYPE infralab_backup_last_run_exit_code gauge
infralab_backup_last_run_exit_code ${exit_code}
# HELP infralab_backup_last_run_timestamp_seconds Unix time the most recent backup run finished.
# TYPE infralab_backup_last_run_timestamp_seconds gauge
infralab_backup_last_run_timestamp_seconds $(date +%s)
# HELP infralab_backup_last_success_timestamp_seconds Unix time of the most recent successful backup.
# TYPE infralab_backup_last_success_timestamp_seconds gauge
infralab_backup_last_success_timestamp_seconds ${last_success}
# HELP infralab_backup_snapshot_count Snapshots currently in the repository.
# TYPE infralab_backup_snapshot_count gauge
infralab_backup_snapshot_count ${snapshot_count}
# HELP infralab_backup_mount_ok 1 if the CIFS share was mounted and readable at backup time.
# TYPE infralab_backup_mount_ok gauge
infralab_backup_mount_ok ${mount_ok}
EOF
    chmod 0644 "$tmp"
    # Atomic rename: node_exporter must never read a half-written file.
    mv "$tmp" "$METRIC_FILE"
}
trap publish_metrics EXIT

export RESTIC_REPOSITORY="$REPO"
export RESTIC_PASSWORD_FILE="$PASSWORD_FILE"

# The share must be mounted AND non-empty. An unmounted CIFS mountpoint is just
# an empty directory, and backing that up produces a perfectly valid, entirely
# empty snapshot that then satisfies every freshness check while protecting
# nothing.
if ! mountpoint -q "$SHARE_MOUNT"; then
    echo "ERROR: $SHARE_MOUNT is not mounted" >&2
    exit_code=1
    exit 1
fi
if [ -z "$(find "$SHARE_MOUNT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    echo "ERROR: $SHARE_MOUNT is mounted but empty or unreadable" >&2
    exit_code=1
    exit 1
fi
mount_ok=1

echo "==> Backing up $SHARE_MOUNT"
if ! restic backup "$SHARE_MOUNT" --tag dc01-share; then
    echo "ERROR: restic backup failed" >&2
    exit_code=1
    exit 1
fi

echo "==> Applying retention policy"
if ! restic forget --tag dc01-share \
        --keep-daily 7 --keep-weekly 4 --keep-monthly 6 \
        --prune; then
    echo "ERROR: restic forget/prune failed" >&2
    exit_code=1
    exit 1
fi

# Structure is checked every run. On top of that one rotating seventh of the
# pack data is re-read each day, so the whole repository is verified once a week
# without re-reading all of it daily.
echo "==> Checking repository integrity (data subset $(date +%u)/7)"
if ! restic check --read-data-subset="$(date +%u)/7"; then
    echo "ERROR: restic check failed" >&2
    exit_code=1
    exit 1
fi

snapshot_count=$(restic snapshots --tag dc01-share --json 2>/dev/null \
                 | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)

exit_code=0
date +%s > "$LAST_SUCCESS_FILE"
echo "Backup completed successfully. Snapshots in repository: $snapshot_count"
exit 0
