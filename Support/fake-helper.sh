#!/bin/bash
# Fake xd-vpn-helper for `XDVPN --selftest`: mimics openconnect's output
# without needing root. Password "secret" succeeds, anything else fails auth.
PIDFILE="${XDVPN_FAKE_PIDFILE:-/tmp/xd-vpn-fake.pid}"
case "$1" in
    version) echo 1 ;;
    connect)
        server="$2"
        IFS= read -r pw
        echo "POST https://$server/"
        echo "Connected to 203.0.113.10:8443" >&2
        echo "SSL negotiation with ${server%%:*}" >&2
        echo "Connected to HTTPS on ${server%%:*} with ciphersuite (TLS1.3)-(ECDHE-SECP256R1)-(RSA-PSS-RSAE-SHA256)-(AES-256-GCM)" >&2
        echo "XML POST enabled" >&2
        echo "Please enter your username and password." >&2
        printf 'Password:' >&2
        sleep 0.2
        if [ "$pw" != "secret" ]; then
            echo "Login failed." >&2
            echo "Failed to complete authentication" >&2
            exit 1
        fi
        echo "POST https://$server/" >&2
        echo "Got CONNECT response: HTTP/1.1 200 OK" >&2
        echo "CSTP connected. DPD 30, Keepalive 20" >&2
        echo "Connected as 10.8.0.23, using SSL, with DTLS in progress" >&2
        echo "Configured as 10.8.0.23, with SSL connected and DTLS in progress" >&2
        echo $$ > "$PIDFILE"
        trap 'echo "Got pause command" >&2; echo "Caller paused the connection" >&2; sleep 0.3; echo "CSTP connected. DPD 30, Keepalive 20" >&2; echo "Connected as 10.8.0.23, using SSL, with DTLS in progress" >&2' USR2
        trap 'echo "User cancelled (SIGINT); exiting." >&2; rm -f "$PIDFILE"; exit 0' INT
        trap 'echo "Session terminated by server; exiting." >&2; rm -f "$PIDFILE"; exit 1' TERM
        while true; do sleep 0.2; done
        ;;
    reconnect)
        pid=$(cat "$PIDFILE" 2>/dev/null)
        [ -n "$pid" ] && kill -USR2 "$pid" 2>/dev/null
        ;;
    disconnect)
        pid=$(cat "$PIDFILE" 2>/dev/null)
        [ -n "$pid" ] && kill -INT "$pid" 2>/dev/null
        rm -f "$PIDFILE"
        ;;
    *) echo "fake-helper: bad command $1" >&2; exit 64 ;;
esac
