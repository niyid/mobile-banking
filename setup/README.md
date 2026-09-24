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
| 35 | `35-verify-sms-wiring.sh` | Reports whether SMS is actually wired end-to-end (bridge config + Cyclos admin-UI steps below). Never fails the run - the admin-UI step is normally still pending after a first run. Safe to re-run any time. |
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

**This step is not automated, and finishing `run-all.sh` does not mean it's done.** Cyclos 4 has its
own SMS channel, and the bridge is built to plug into it, but Cyclos does not expose any API for
configuring that channel - only the admin UI does (confirmed against Cyclos's own web-services
reference, which explicitly documents "SMS operation" as a channel a gateway calls, not something
a REST client can configure). So stages 00-30 only get the bridge and the phone ready; the Cyclos
side below always has to be done by hand, and it's easy to skip without noticing since nothing
about the earlier stages fails if you do. Run `./35-verify-sms-wiring.sh` any time to check the
current status instead of assuming it from a clean `run-all.sh` run.

1. Admin: *System management > System configuration > Configurations* > your configuration > *Channels* > **SMS**: enable it.
2. **Outbound** - set the gateway URL to the bridge, using the recipient/message variables that Cyclos lists next to that field:
   `http://127.0.0.1:5000/cgi-bin/sendsms?username=cyclos&password=<SENDSMS_PASS>&to=<recipient variable>&text=<message variable>`
   `SENDSMS_PASS` is in `~/.cyclos/phone-gateway.env` (generated during stage 20).
3. **Inbound** - Cyclos displays an **Inbound SMS URL** on that page. Put it in `~/.cyclos/phone-gateway.env` as `CYCLOS_SMS_RECEIVE_URL=...`, then `sudo systemctl restart cyclos-bridge`. If Cyclos expects other parameter names or GET, set `CYCLOS_SMS_FROM_PARAM`, `CYCLOS_SMS_TEXT_PARAM`, `CYCLOS_SMS_METHOD` in the same file.
4. Verify: `./35-verify-sms-wiring.sh` checks the bridge is ready on both ends (send password set, inbound URL copied in from step 3) and prints the exact outbound URL and admin-UI path for steps 1-2 as a reminder. It cannot see into the Cyclos UI itself, so a clean result there still isn't proof steps 1-2 were actually done in Cyclos - only that the bridge side is ready for them. Once it's green, send a real test message to the gateway phone number and watch `sudo journalctl -u cyclos-bridge -f`; the admin "SMS messages" overview in Cyclos also shows send/receive status.

## Security notes

* The bridge listens on **127.0.0.1 only** and refuses to send unless `SENDSMS_PASS` is set (earlier versions defaulted to `changeme` and listened on all interfaces).
* SMS text is never written to the bridge log (it can contain PINs). Phone numbers are masked.
* Secrets live in `~/.cyclos/` (mode 700/600) and are excluded from the git commit.
* The password in the Cyclos outbound URL will appear in Cyclos's own logs; this is local-only traffic, but rotate `SENDSMS_PASS` if the machine is shared.

## Things this does not do

* **USSD** cannot be received by a phone plugged into a laptop: it is a live session with the carrier's USSD gateway. For `*code#` menus you need a short code and an aggregator (for example Africa's Talking or Termii), which can also handle SMS delivery without a phone.
* A stock Android phone cannot act as a Kannel AT modem over USB, which is why the SMS Gateway app + `adb` tunnel is used instead.
* The adb tunnels only survive while the phone stays connected; run `./phone-tunnel.sh` after re-plugging.
