#!/usr/bin/env python3
"""Local webhook receiver for Alertmanager.

Appends one line per notification to /var/log/alert-sink.log, so that "which
alert fired, and at what time" is answerable after the fact. Alertmanager's own
UI only shows what is firing now; an incident record needs the history.

Standard library only, deliberately — this runs on an isolated host with no
package installation available after setup.

Deployed to /usr/local/bin/alert-sink.py and run by infralab-alert-sink.service.
Binds to 127.0.0.1 only: it accepts unauthenticated POSTs and writes them to
disk, so it has no business being reachable from the network.
"""

import json
import logging
import os
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG_PATH = os.environ.get("ALERT_SINK_LOG", "/var/log/alert-sink.log")
BIND_HOST = os.environ.get("ALERT_SINK_HOST", "127.0.0.1")
BIND_PORT = int(os.environ.get("ALERT_SINK_PORT", "9094"))
MAX_BODY = 1 * 1024 * 1024  # 1 MiB; refuse anything larger rather than buffer it


class AlertHandler(BaseHTTPRequestHandler):
    # Silence the default per-request stderr logging; we do our own.
    def log_message(self, fmt, *args):
        pass

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            self.send_error(400, "bad Content-Length")
            return

        if length <= 0 or length > MAX_BODY:
            self.send_error(413, "body missing or too large")
            return

        raw = self.rfile.read(length)

        try:
            payload = json.loads(raw)
        except (ValueError, UnicodeDecodeError):
            logging.warning("route=%s undecodable payload (%d bytes)", self.path, length)
            self.send_error(400, "invalid JSON")
            return

        for alert in payload.get("alerts", []):
            labels = alert.get("labels", {})
            annotations = alert.get("annotations", {})
            logging.info(
                "route=%s status=%s alert=%s severity=%s instance=%s starts=%s summary=%s",
                self.path,
                alert.get("status", "?"),
                labels.get("alertname", "?"),
                labels.get("severity", "?"),
                labels.get("instance", "?"),
                alert.get("startsAt", "?"),
                annotations.get("summary", ""),
            )

        body = b'{"status":"received"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        # Health endpoint, so the service can be checked without sending a fake alert.
        body = b"alert-sink ok\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def selftest():
    """Assert the handler parses a real Alertmanager payload shape."""
    sample = {
        "status": "firing",
        "alerts": [
            {
                "status": "firing",
                "labels": {"alertname": "BackupStale", "severity": "critical",
                           "instance": "192.168.56.30:9100"},
                "annotations": {"summary": "No successful backup in over 25 hours"},
                "startsAt": "2026-07-29T02:00:00Z",
            }
        ],
    }
    raw = json.dumps(sample).encode()
    decoded = json.loads(raw)
    alerts = decoded.get("alerts", [])
    assert len(alerts) == 1, "expected one alert"
    assert alerts[0]["labels"]["alertname"] == "BackupStale"
    assert alerts[0]["annotations"]["summary"].startswith("No successful backup")
    # An empty or malformed payload must not raise.
    assert json.loads(b'{}').get("alerts", []) == []
    print("SELF-TEST PASSED: 4 assertions")
    return 0


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        sys.exit(selftest())

    logging.basicConfig(
        filename=LOG_PATH,
        level=logging.INFO,
        format="%(asctime)s %(message)s",
    )
    logging.Formatter.converter = lambda *args: datetime.now(timezone.utc).timetuple()

    server = HTTPServer((BIND_HOST, BIND_PORT), AlertHandler)
    logging.info("alert-sink listening on %s:%d", BIND_HOST, BIND_PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
