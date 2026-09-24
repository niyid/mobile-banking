# Cyclos 4 + phone-as-SMS-gateway setup (Ubuntu)

Sets up:

1. **Cyclos 4.16.x** on Tomcat 9 + PostgreSQL/PostGIS, using the free licence (up to 300 users) from license.cyclos.org.
2. Your Android phone, plugged in by USB, as an **SMS gateway** (open-source *SMS Gateway for Android* app + a small local bridge).
3. Optionally, a commit of the non-secret config into `~/git/mobile-banking`.

## Quick start

```bash
cd ~/Downloads/cyclos_setup/mobile-banking-setup      # wherever you extracted this
./run-all.sh --until 10        # prerequisites + Cyclos only  (do this first)
# open http://localhost:8080/ and activate the licence (see below)
./run-all.sh --from 20         # phone gateway, bridge, systemd service, git commit
```

`./run-all.sh` with no options runs everything; `--skip-phone` skips stage 20; `--with-kannel` adds the optional Kannel stage.
Every stage is also a standalone script and is safe to re-run.

| Stage | Script | What it does |
|------|--------|--------------|
| 00 | `00-install-prereqs.sh` | Java 17, PostgreSQL + PostGIS, Tomcat 9 (reuses `~/tomcat` if it is 9.x, else installs `~/tomcat9`), adb, git, python3 |
| 10 | `10-install-cyclos.sh` | Finds `~/cyclos-4.16.20` (or the zip), creates DB `cyclos4` + extensions, deploys `web/` as Tomcat's ROOT app, writes `cyclos.properties` and `bin/setenv.sh`, frees ports 8080/8005, starts Tomcat, waits until Cyclos answers |
| 20 | `20-setup-phone-gateway.sh` | Pairs the phone via adb, asks for the phone app's credentials, writes `~/.cyclos/phone-gateway.env` |
| 25 | `25-setup-bridge-venv.sh` | Python venv for the bridge (rebuilt automatically if the folder was moved) |
| 30 | `30-install-bridge-service.sh` | Installs/starts the `cyclos-bridge` systemd service with the correct paths |
| 35 | `35-verify-sms-wiring.sh` | Reports whether SMS is actually wired end-to-end: bridge config, plus a direct read of Cyclos's own `sms_enabled`/`sms_gateway_url` DB columns when reachable. Never fails the run - normally still pending after a first run. Safe to re-run any time. |
| 36 | `36-configure-cyclos-sms.sh` | Optional, not run by `run-all.sh`. Sets the outbound SMS gateway directly on Cyclos's `configurations` table and restarts Tomcat - see "Wiring SMS into Cyclos" for what it does and doesn't cover. |
| 40 | `40-install-kannel.sh` | Optional. Kannel is not needed for Cyclos 4 |
| 50 | `git-init-commit.sh` | Commits scripts/templates (never `~/.cyclos`) into `~/git/mobile-banking` |

Helpers: `cyclosctl.sh start|stop|restart|status|logs` (Tomcat) and `phone-tunnel.sh` (re-create the adb tunnels after unplugging the phone).

## Cyclos 4 notes

* **Download** `cyclos-4.16.20.zip` from https://license.cyclos.org (login required, so it cannot be fetched by a script). Extract it to `~/cyclos-4.16.20`, or leave the zip in `~`, `~/Downloads` or `~/build`, or set `CYCLOS_ZIP=/path/to/zip`.
* **Requirements** (from the Cyclos 4.16 reference): Tomcat 9.0 (Tomcat 10+ is not compatible), Java 11+, PostgreSQL with PostGIS and the `cube`, `earthdistance`, `unaccent`, `pgcrypto` extensions. Tomcat is pinned to Java 17 in `setenv.sh`; override with `CYCLOS_JAVA_HOME` in `~/.cyclos/setup.env` if needed.
* **Licence activation**: on the first start Cyclos asks for your license.cyclos.org user ID and password. Enter them in the browser only.
* **First start is slow** (schema creation): the script waits up to 15 minutes. Logs: `./cyclosctl.sh logs`.
* **If the first start failed halfway**, wipe the database and retry: `RESET_DB=1 ./10-install-cyclos.sh` (destroys all Cyclos data).
* Cyclos is served from the root path: `http://localhost:8080/` (not `/cyclos/`).
* `cyclos.properties`: the script edits the `cyclos.datasource.*` url/username/password lines of the template shipped as `WEB-INF/classes/cyclos-release.properties`. It prints the resulting lines (password masked); if it had to append keys because the template used different names it prints a warning - check that case.

## Wiring SMS into Cyclos

**Finishing `run-all.sh` does not by itself mean this is done** - stages 00-30 only get the
bridge and the phone ready. Cyclos does not expose a REST *API* for configuring the SMS
channel (system-management settings are explicitly excluded from the REST API per Cyclos's
own web-services reference), so there's no supported way to script it end-to-end. But two
things from that same reference doc are worth knowing, because they let most of this be
checked - and the outbound half even set - without touching the admin UI:

* The channel's settings live in plain columns on the `configurations` table
  (`sms_enabled`, `sms_gateway_url`, `sms_username`, `sms_password`, `sms_headers`) - visible
  in the doc's own example for scrubbing secrets before sharing a DB dump, which nulls out
  exactly these columns. That's an undocumented implementation detail, not a supported API,
  but it's real and it's how `./36-configure-cyclos-sms.sh` (new, optional) sets the outbound
  side directly, then restarts Tomcat so Cyclos reloads it.
* Cyclos's *default* outbound sender authenticates with **HTTP Basic Auth**, not Kannel-style
  `?username=..&password=..` query params - the scripting reference's own outbound-SMS example
  scripts read `configuration.outboundSmsConfiguration` and call
  `headers.setBasicAuth(user, pwd)`. `bridge.py` now accepts both, so it works either way.

What's still genuinely unconfirmed against a live 4.16.20: the exact placeholder syntax Cyclos
substitutes into the gateway URL for the phone number/message (`36-configure-cyclos-sms.sh`
guesses `{phoneNumber}` / `{message}`, matching the scripting reference's bound-variable names,
but the admin UI's own field labels are the source of truth), whether per-user "channel access"
or per-phone "SMS enabled" flags also need setting, and the Inbound SMS URL - there's no
matching column in `configurations`, so it looks like a fixed/computed endpoint rather than
something to write, and it still has to be copied from the UI by hand.

1. **Outbound** - either run `./36-configure-cyclos-sms.sh` (writes `sms_enabled`/
   `sms_gateway_url`/`sms_username`/`sms_password` directly and restarts Tomcat), or do it by
   hand: Admin *System management > System configuration > Configurations* > your
   configuration > *Channels* > **SMS** > enable it, and set the gateway URL to
   `http://127.0.0.1:5000/cgi-bin/sendsms?to=<recipient variable>&text=<message variable>`
   using whatever placeholder syntax that field actually shows. Either way, check the field
   afterwards - if the placeholder syntax turns out to differ, fix it there.
2. **Inbound** - Cyclos displays an **Inbound SMS URL** on that same page. Put it in
   `~/.cyclos/phone-gateway.env` as `CYCLOS_SMS_RECEIVE_URL=...`, then
   `sudo systemctl restart cyclos-bridge`. If Cyclos expects other parameter names or GET, set
   `CYCLOS_SMS_FROM_PARAM`, `CYCLOS_SMS_TEXT_PARAM`, `CYCLOS_SMS_METHOD` in the same file.
3. Verify: `./35-verify-sms-wiring.sh` now reads `sms_enabled`/`sms_gateway_url` back from the
   database directly (when it can reach it) instead of just telling you to go check by hand,
   plus the bridge-side checks from before. Once it's green, send a real test message to the
   gateway phone number and watch `sudo journalctl -u cyclos-bridge -f`; the admin "SMS
   messages" overview in Cyclos also shows send/receive status.

## Security notes

* The bridge listens on **127.0.0.1 only** and refuses to send unless `SENDSMS_PASS` is set (earlier versions defaulted to `changeme` and listened on all interfaces).
* SMS text is never written to the bridge log (it can contain PINs). Phone numbers are masked.
* Secrets live in `~/.cyclos/` (mode 700/600) and are excluded from the git commit.
* If Cyclos ends up sending the password in the outbound URL's query string rather than as HTTP Basic Auth (worth checking once it's wired up), it will appear in Cyclos's own logs; this is local-only traffic either way, but rotate `SENDSMS_PASS` if the machine is shared.
* `36-configure-cyclos-sms.sh` writes straight to Cyclos's `configurations` table over the same DB role `10-install-cyclos.sh` created - not a documented API, just the same schema Cyclos's own docs use to scrub these columns before sharing a DB dump. Read it before running it.

## Things this does not do

* **USSD** cannot be received by a phone plugged into a laptop: it is a live session with the carrier's USSD gateway. For `*code#` menus you need a short code and an aggregator (for example Africa's Talking or Termii), which can also handle SMS delivery without a phone.
* A stock Android phone cannot act as a Kannel AT modem over USB, which is why the SMS Gateway app + `adb` tunnel is used instead.
* The adb tunnels only survive while the phone stays connected; run `./phone-tunnel.sh` after re-plugging.
