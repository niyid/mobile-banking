#!/usr/bin/env python3
"""
cyclos-bridge: makes your phone (running "SMS Gateway for Android",
https://github.com/capcom6/android-sms-gateway, reached over USB with adb forward/reverse)
look like a simple HTTP SMS gateway that Cyclos can talk to.

Outbound: Cyclos -> GET/POST /cgi-bin/sendsms?username=..&password=..&to=..&text=..
          -> this bridge -> phone app -> carrier
Inbound:  carrier -> phone app -> POST /webhook -> this bridge
          -> Cyclos's "Inbound SMS URL" (CYCLOS_SMS_RECEIVE_URL)

Settings come from environment variables, falling back to ~/.cyclos/phone-gateway.env
(written by 20-setup-phone-gateway.sh; chmod 600, never committed to git):

  PHONE_GATEWAY_URL / PHONE_GATEWAY_USER / PHONE_GATEWAY_PASS   the phone app's local API
  GATEWAY_PHONE_NUMBER                                          the phone's own number (informational)
  SENDSMS_USER / SENDSMS_PASS                                   credentials Cyclos must present (required)
  CYCLOS_SMS_RECEIVE_URL                                        the "Inbound SMS URL" shown by Cyclos
  CYCLOS_SMS_METHOD / _FROM_PARAM / _TEXT_PARAM / _TO_PARAM     how inbound SMS is posted to Cyclos
  BRIDGE_HOST (default 127.0.0.1) / BRIDGE_PORT (default 5000)

SMS bodies can contain PINs and payment details, so message text is never written to the log.
"""
import hmac
import logging
import os
from pathlib import Path

import requests
from flask import Flask, Response, jsonify, request

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("cyclos-bridge")

ENV_FILE = Path.home() / ".cyclos" / "phone-gateway.env"


def load_env(path: Path) -> dict:
    env = {}
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


CFG = load_env(ENV_FILE)


def cfg(name: str, default: str = "") -> str:
    value = os.environ.get(name)
    if value is None:
        value = CFG.get(name, default)
    return value


PHONE_URL = cfg("PHONE_GATEWAY_URL", "http://127.0.0.1:18080").rstrip("/")
PHONE_USER = cfg("PHONE_GATEWAY_USER")
PHONE_PASS = cfg("PHONE_GATEWAY_PASS")
GATEWAY_NUMBER = cfg("GATEWAY_PHONE_NUMBER")

SENDSMS_USER = cfg("SENDSMS_USER", "cyclos")
SENDSMS_PASS = cfg("SENDSMS_PASS")  # no default on purpose: an unset password disables sending

CYCLOS_URL = cfg("CYCLOS_SMS_RECEIVE_URL")
CYCLOS_METHOD = cfg("CYCLOS_SMS_METHOD", "POST").upper()
FROM_PARAM = cfg("CYCLOS_SMS_FROM_PARAM", "from")
TEXT_PARAM = cfg("CYCLOS_SMS_TEXT_PARAM", "text")
TO_PARAM = cfg("CYCLOS_SMS_TO_PARAM", "")  # empty = don't send a "to" parameter

app = Flask(__name__)


def mask(number: str) -> str:
    number = number or ""
    return number[:4] + "..." + number[-3:] if len(number) > 8 else "***"


def same(a: str, b: str) -> bool:
    return hmac.compare_digest((a or "").encode(), (b or "").encode())


def send_via_phone(to: str, text: str) -> None:
    """Send through the phone app. Newer app versions use /messages, older ones /message."""
    auth = (PHONE_USER, PHONE_PASS)
    resp = requests.post(
        f"{PHONE_URL}/messages", auth=auth, timeout=15,
        json={"textMessage": {"text": text}, "phoneNumbers": [to]},
    )
    if resp.status_code in (404, 405):
        resp = requests.post(
            f"{PHONE_URL}/message", auth=auth, timeout=15,
            json={"message": text, "phoneNumbers": [to]},
        )
    resp.raise_for_status()


@app.route("/cgi-bin/sendsms", methods=["GET", "POST"])
def sendsms():
    """Kannel-style sendsms endpoint: ?username=..&password=..&to=..&text=..

    Also accepts the credentials as HTTP Basic Auth instead of query params: Cyclos's
    built-in GatewaySmsSender authenticates via applyAuthentication(), and the scripting
    reference's own outbound-SMS examples read configuration.outboundSmsConfiguration and
    call headers.setBasicAuth(user, pwd) - i.e. Cyclos's default (non-scripted) sender is
    HTTP Basic Auth, not Kannel-style query params. Accepting both means this endpoint works
    whichever way Cyclos (or a manual curl test) actually sends it.
    """
    if not SENDSMS_PASS:
        log.error("SENDSMS_PASS is not set in %s - refusing to send", ENV_FILE)
        return Response("Bridge not configured: SENDSMS_PASS missing", status=500)

    args = request.values
    auth = request.authorization
    authorized = (
        same(args.get("username", ""), SENDSMS_USER) and same(args.get("password", ""), SENDSMS_PASS)
    ) or (
        auth is not None and same(auth.username or "", SENDSMS_USER) and same(auth.password or "", SENDSMS_PASS)
    )
    if not authorized:
        return Response("Authorization failed", status=403)

    raw_to = args.get("to") or ""
    # An unencoded '+' in a query string arrives as a space; restore it.
    to = ("+" + raw_to.strip()) if raw_to.startswith(" ") else raw_to.strip()
    text = args.get("text")
    if not to or text is None:
        return Response("Missing 'to' or 'text'", status=400)

    if not PHONE_USER or not PHONE_PASS:
        log.error("PHONE_GATEWAY_USER/PASS not set in %s", ENV_FILE)
        return Response("Bridge not configured: phone app credentials missing", status=500)

    try:
        send_via_phone(to, text)
    except requests.RequestException as exc:
        log.error("Send via phone gateway failed: %s", exc)
        return Response(f"Send failed: {exc}", status=502)

    log.info("Outbound SMS to %s accepted by phone gateway (%d chars)", mask(to), len(text))
    return Response("0: Accepted for delivery", status=200, mimetype="text/plain")


@app.route("/webhook", methods=["POST"])
def webhook():
    """Receives events pushed by the phone app and forwards inbound SMS to Cyclos."""
    event = request.get_json(silent=True) or {}
    event_type = event.get("event")
    log.info("Webhook event: %s", event_type)

    if event_type == "sms:received":
        payload = event.get("payload", {}) or {}
        sender = payload.get("phoneNumber", "")
        text = payload.get("message", "")

        if not CYCLOS_URL:
            log.warning("Inbound SMS from %s NOT forwarded: CYCLOS_SMS_RECEIVE_URL is empty in %s",
                        mask(sender), ENV_FILE)
            return jsonify({"status": "ok", "forwarded": False})

        params = {FROM_PARAM: sender, TEXT_PARAM: text}
        if TO_PARAM:
            params[TO_PARAM] = GATEWAY_NUMBER
        try:
            if CYCLOS_METHOD == "GET":
                resp = requests.get(CYCLOS_URL, params=params, timeout=10)
            else:
                resp = requests.post(CYCLOS_URL, data=params, timeout=10)
            log.info("Forwarded inbound SMS from %s to Cyclos: HTTP %s", mask(sender), resp.status_code)
        except requests.RequestException as exc:
            log.error("Forwarding inbound SMS to Cyclos failed: %s", exc)
            return jsonify({"status": "error", "forwarded": False}), 502

    return jsonify({"status": "ok"})


@app.route("/health", methods=["GET"])
def health():
    return jsonify({
        "status": "ok",
        "phone_gateway": PHONE_URL,
        "sendsms_configured": bool(SENDSMS_PASS),
        "phone_credentials_configured": bool(PHONE_USER and PHONE_PASS),
        "cyclos_inbound_url_configured": bool(CYCLOS_URL),
    })


if __name__ == "__main__":
    if not ENV_FILE.exists():
        log.warning("%s not found - run 20-setup-phone-gateway.sh first", ENV_FILE)
    app.run(host=cfg("BRIDGE_HOST", "127.0.0.1"), port=int(cfg("BRIDGE_PORT", "5000")))
