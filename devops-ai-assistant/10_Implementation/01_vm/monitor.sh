#!/bin/bash

URL="http://localhost:5000/health"
LOG_FILE="/opt/training-app/monitor.log"
STATE_FILE="/opt/training-app/.monitor_state"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

if [ ! -f "$STATE_FILE" ]; then
    echo "0" > "$STATE_FILE"
fi

FAILURES=$(cat "$STATE_FILE")
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$URL")

if [ "$HTTP_CODE" = "200" ]; then
    echo "[$TIMESTAMP] INFO: Service is healthy (HTTP 200)" >> "$LOG_FILE"
    echo "0" > "$STATE_FILE"
else
    echo "[$TIMESTAMP] ERROR: Service returned HTTP $HTTP_CODE" >> "$LOG_FILE"

    FAILURES=$((FAILURES + 1))
    echo "$FAILURES" > "$STATE_FILE"

    if [ "$FAILURES" -ge 3 ]; then
        echo "[$TIMESTAMP] [ALERT] Service failed $FAILURES times in a row! Requires investigation." >> "$LOG_FILE"
    fi
fi