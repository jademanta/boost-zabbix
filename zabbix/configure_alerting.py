#!/usr/bin/env python3
"""Idempotently configure Zabbix alert delivery through the JSON-RPC API.

Creates/updates:
  - media type "Email": SES SMTP, STARTTLS, HTML
  - media type "Slack": stock webhook media type, bot token filled in
  - user group "IT Alerts" (no frontend access) and user "it-alerts" with
    Email -> ALERT_EMAIL and Slack -> SLACK_CHANNEL media, Warning and above
  - action "Notify IT: problems" (trigger events, severity >= Warning,
    problem + recovery + update messages, suppressed problems paused)

Inputs come from the environment (see apply-alerting.sh):
  ZBX_URL ZBX_TOKEN SMTP_SERVER SMTP_PORT SMTP_FROM SMTP_HELO SMTP_USER
  SMTP_PASS SLACK_BOT_TOKEN SLACK_CHANNEL ALERT_EMAIL
Only stdlib; runs on the Zabbix host with python3.
"""
import json
import os
import secrets
import sys
import urllib.request

URL = os.environ["ZBX_URL"].rstrip("/") + "/api_jsonrpc.php"
TOKEN = os.environ["ZBX_TOKEN"]

SEV_WARNING_AND_UP = 60  # bitmask: warning 4 + average 8 + high 16 + disaster 32


def api(method, params):
    body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode()
    req = urllib.request.Request(
        URL, data=body,
        headers={"Content-Type": "application/json-rpc", "Authorization": f"Bearer {TOKEN}"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        out = json.load(r)
    if "error" in out:
        raise SystemExit(f"{method} failed: {out['error']}")
    return out["result"]


def env(name, default=None):
    v = os.environ.get(name, default)
    if v is None or v == "" or v == "REPLACE_ME":
        raise SystemExit(f"missing {name}")
    return v


def log(msg):
    print(f"[alerting] {msg}")


# --- media type: Email -----------------------------------------------------
def configure_email():
    mt = api("mediatype.get", {"filter": {"name": "Email"}, "output": ["mediatypeid"]})
    fields = {
        "name": "Email",
        "type": 0,
        "smtp_server": env("SMTP_SERVER"),
        "smtp_port": int(env("SMTP_PORT", "587")),
        "smtp_helo": env("SMTP_HELO"),
        "smtp_email": env("SMTP_FROM"),
        "smtp_security": 1,        # STARTTLS
        "smtp_verify_peer": 1,
        "smtp_verify_host": 1,
        "smtp_authentication": 1,  # username/password
        "username": env("SMTP_USER"),
        "passwd": env("SMTP_PASS"),
        "message_format": 1,       # HTML (7.0 name; older releases call it content_type)
        "status": 0,
    }
    if mt:
        try:
            api("mediatype.update", {"mediatypeid": mt[0]["mediatypeid"], **{k: v for k, v in fields.items() if k != "name"}})
        except SystemExit as e:
            if "message_format" not in str(e):
                raise
            fields["content_type"] = fields.pop("message_format")
            api("mediatype.update", {"mediatypeid": mt[0]["mediatypeid"], **{k: v for k, v in fields.items() if k != "name"}})
        log("Email media type updated")
        return mt[0]["mediatypeid"]
    r = api("mediatype.create", fields)
    log("Email media type created")
    return r["mediatypeids"][0]


# --- media type: Slack -----------------------------------------------------
def configure_slack():
    mt = api("mediatype.get", {"filter": {"name": "Slack"}, "output": ["mediatypeid", "status"], "selectParameters": "extend"})
    if not mt:
        raise SystemExit("stock 'Slack' media type not found; import it from the Zabbix media type templates first")
    mtid = mt[0]["mediatypeid"]
    params = mt[0]["parameters"]
    found = False
    for p in params:
        if p["name"] == "bot_token":
            p["value"] = env("SLACK_BOT_TOKEN")
            found = True
    if not found:
        params.append({"name": "bot_token", "value": env("SLACK_BOT_TOKEN")})
    api("mediatype.update", {"mediatypeid": mtid, "parameters": params, "status": 0})
    log("Slack media type updated (bot token set, enabled)")
    return mtid


# --- user group + user -----------------------------------------------------
def configure_user(email_mtid, slack_mtid):
    ug = api("usergroup.get", {"filter": {"name": "IT Alerts"}, "output": ["usrgrpid"]})
    if ug:
        ugid = ug[0]["usrgrpid"]
    else:
        # gui_access 3 = disabled: a notification-only account that cannot log in.
        ugid = api("usergroup.create", {"name": "IT Alerts", "gui_access": 3, "users_status": 0})["usrgrpids"][0]
        log("user group 'IT Alerts' created")

    roles = api("role.get", {"filter": {"name": "Super admin role"}, "output": ["roleid"]})
    roleid = roles[0]["roleid"] if roles else "3"

    medias = [
        {"mediatypeid": email_mtid, "sendto": [env("ALERT_EMAIL")], "active": 0, "severity": SEV_WARNING_AND_UP, "period": "1-7,00:00-24:00"},
        {"mediatypeid": slack_mtid, "sendto": env("SLACK_CHANNEL"), "active": 0, "severity": SEV_WARNING_AND_UP, "period": "1-7,00:00-24:00"},
    ]
    u = api("user.get", {"filter": {"username": "it-alerts"}, "output": ["userid"]})
    if u:
        api("user.update", {"userid": u[0]["userid"], "usrgrps": [{"usrgrpid": ugid}], "roleid": roleid, "medias": medias})
        log("user 'it-alerts' updated")
        return u[0]["userid"]
    r = api("user.create", {
        "username": "it-alerts", "name": "IT", "surname": "Alerts",
        "passwd": secrets.token_urlsafe(24),   # never used: group has no frontend access
        "roleid": roleid, "usrgrps": [{"usrgrpid": ugid}], "medias": medias,
    })
    log("user 'it-alerts' created")
    return r["userids"][0]


# --- action ----------------------------------------------------------------
def configure_action(userid):
    name = "Notify IT: problems"
    a = api("action.get", {"filter": {"name": name}, "output": ["actionid"]})
    spec = {
        "name": name,
        "eventsource": 0,           # trigger events
        "status": 0,
        "esc_period": "1h",
        "pause_suppressed": 1,
        "notify_if_canceled": 1,
        "filter": {
            "evaltype": 0,
            "conditions": [
                {"conditiontype": 4, "operator": 5, "value": "2"},   # trigger severity >= Warning
            ],
        },
        "operations": [{
            "operationtype": 0, "esc_period": "0", "esc_step_from": 1, "esc_step_to": 1,
            "opmessage": {"default_msg": 1, "mediatypeid": "0"},
            "opmessage_usr": [{"userid": userid}],
        }],
        "recovery_operations": [{
            "operationtype": 11,     # notify all involved
            "opmessage": {"default_msg": 1},
        }],
        "update_operations": [{
            "operationtype": 12,     # notify all involved
            "opmessage": {"default_msg": 1},
        }],
    }
    if a:
        api("action.update", {"actionid": a[0]["actionid"], **{k: v for k, v in spec.items() if k not in ("name", "eventsource")}})
        log(f"action '{name}' updated")
    else:
        api("action.create", spec)
        log(f"action '{name}' created")


# --- housekeeping: disable guest ------------------------------------------
def disable_guest():
    g = api("user.get", {"filter": {"username": "guest"}, "output": ["userid"], "selectUsrgrps": ["usrgrpid", "name"]})
    if not g:
        return
    ug = api("usergroup.get", {"filter": {"name": "Disabled"}, "output": ["usrgrpid"]})
    if ug:
        api("user.update", {"userid": g[0]["userid"], "usrgrps": [{"usrgrpid": ug[0]["usrgrpid"]}]})
        log("guest user moved to 'Disabled' group")


def main():
    log(f"connected to {URL}, Zabbix API {api('apiinfo.version', {})}")
    email_mtid = configure_email()
    slack_mtid = configure_slack()
    userid = configure_user(email_mtid, slack_mtid)
    configure_action(userid)
    disable_guest()
    log("done")


if __name__ == "__main__":
    try:
        main()
    except KeyError as e:
        sys.exit(f"missing environment variable {e}")
