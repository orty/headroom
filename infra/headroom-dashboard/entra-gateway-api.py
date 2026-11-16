#!/usr/bin/env python3
"""Additive changes to the SHARED Entra app registration for the Headroom gateway.

The registration (APP_ID in .env.local) also signs in W.A.L.T.E.R.'s dashboard
and serves its connector, OBO and app roles. This script only ADDS what the
gateway needs and never removes or edits anything that is already there:

- an App ID URI, only if the registration has none (else the existing one is used);
- delegated scope GATEWAY_SCOPE (default access_as_user) for people;
- app role GATEWAY_APP_ROLE (default Headroom.Proxy, Application members) for
  managed identities (W.A.L.T.E.R., later);
- public-client redirect URIs for MSAL on laptops (Windows broker + loopback);
- the Easy Auth callback of GATEWAY_HOST, if set;
- a requiredResourceAccess entry for its own scope, so one admin consent covers it;
- Azure CLI (04b07795-...) pre-authorized for that scope, so `az account
  get-access-token --scope <App ID URI>/access_as_user` works without a consent
  prompt (tests, scripts). GATEWAY_PREAUTHORIZE_AZ_CLI=0 skips it. Graph refuses a
  pre-authorization for a scope created in the same PATCH, so --apply runs a
  second round for it;
- the display name, only if NEW_DISPLAY_NAME is set: on the registration AND on
  its service principal (the Enterprise application), which Entra does not
  rename along with the registration.

It never touches: secrets/certificates, token version, isFallbackPublicClient,
existing scopes/roles/URIs, optional claims, owners, or any other service
principal setting (assignment required, app role assignments).

Default is a dry run that prints the Graph PATCH body. --apply sends it.
--from-file app.json runs the merge on a saved `GET /applications/{id}` (tests).

Usage: python3 entra-gateway-api.py [--apply] [--from-file app.json]
Needs: az (signed in as an owner of the registration), .env.local.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
AZURE_CLI = "04b07795-8ddb-461a-bbee-02f9e1bf7b46"
SELECT = ("id,appId,displayName,identifierUris,api,appRoles,publicClient,web,"
          "requiredResourceAccess,isFallbackPublicClient")


def load_env() -> dict[str, str]:
    env = {}
    path = HERE / ".env.local"
    if path.exists():
        for line in path.read_text().splitlines():
            m = re.match(r"^([A-Z_][A-Z0-9_]*)=(.*)$", line.strip())
            if m:
                env[m.group(1)] = m.group(2).strip().strip('"')
    env.update({k: v for k, v in os.environ.items() if k in env or k.startswith(("GATEWAY_", "NEW_DISPLAY"))})
    return env


def az(*args: str) -> str:
    return subprocess.run(["az", *args], check=True, capture_output=True, text=True).stdout.replace("\r", "")


def plan(app: dict, env: dict[str, str]) -> tuple[dict, list[str]]:
    """Return (PATCH body, human-readable changes). Pure: no I/O."""
    app_id = app["appId"]
    scope_value = env.get("GATEWAY_SCOPE", "access_as_user")
    role_value = env.get("GATEWAY_APP_ROLE", "Headroom.Proxy")
    patch: dict = {}
    changes: list[str] = []

    uris = list(app.get("identifierUris") or [])
    if not uris:
        uris = [f"api://{app_id}"]
        patch["identifierUris"] = uris
        changes.append(f"identifierUris: add {uris[0]}")

    api = dict(app.get("api") or {})
    scopes = [dict(s) for s in api.get("oauth2PermissionScopes") or []]
    scope = next((s for s in scopes if s.get("value") == scope_value), None)
    if scope is None:
        scope = {
            "id": str(uuid.uuid4()), "value": scope_value, "type": "Admin", "isEnabled": True,
            "adminConsentDisplayName": "Use the Headroom proxy",
            "adminConsentDescription": "Lets the app call the Headroom proxy gateway as the signed-in user.",
            "userConsentDisplayName": "Use the Headroom proxy",
            "userConsentDescription": "Lets the app call the Headroom proxy gateway as you.",
        }
        scopes.append(scope)
        # Graph needs the whole api object's collection; other api fields are left out
        # of the PATCH, so they stay as they are.
        patch["api"] = {"oauth2PermissionScopes": scopes}
        changes.append(f"api.oauth2PermissionScopes: add {scope_value} (existing kept: "
                       f"{', '.join(s['value'] for s in scopes[:-1]) or 'none'})")
    elif not scope.get("isEnabled", True):
        raise SystemExit(f"scope {scope_value} exists but is disabled: decide by hand, nothing changed")
    elif env.get("GATEWAY_PREAUTHORIZE_AZ_CLI", "1") != "0":
        pre = [dict(x) for x in api.get("preAuthorizedApplications") or []]
        cli = next((x for x in pre if x.get("appId") == AZURE_CLI), None)
        if cli is None or scope["id"] not in (cli.get("delegatedPermissionIds") or []):
            if cli is None:
                cli = {"appId": AZURE_CLI, "delegatedPermissionIds": []}
                pre.append(cli)
            cli["delegatedPermissionIds"] = list(cli.get("delegatedPermissionIds") or []) + [scope["id"]]
            patch["api"] = {"preAuthorizedApplications": pre}
            changes.append(f"api.preAuthorizedApplications: Azure CLI for {scope_value} "
                           f"(existing kept: {len(pre) - 1} other app(s))")

    roles = [dict(r) for r in app.get("appRoles") or []]
    if not any(r.get("value") == role_value for r in roles):
        roles.append({
            "id": str(uuid.uuid4()), "value": role_value, "allowedMemberTypes": ["Application"],
            "displayName": "Headroom proxy (service)", "isEnabled": True,
            "description": "Lets a service (managed identity) call the Headroom proxy gateway.",
        })
        patch["appRoles"] = roles
        changes.append(f"appRoles: add {role_value} (existing kept: "
                       f"{', '.join(r['value'] for r in roles[:-1]) or 'none'})")

    pc = list((app.get("publicClient") or {}).get("redirectUris") or [])
    want_pc = [f"ms-appx-web://microsoft.aad.brokerplugin/{app_id}", "http://localhost"]
    add_pc = [u for u in want_pc if u not in pc]
    if add_pc:
        patch["publicClient"] = {"redirectUris": pc + add_pc}
        changes.append(f"publicClient.redirectUris: add {', '.join(add_pc)}")

    host = env.get("GATEWAY_HOST")
    if host:
        web = list((app.get("web") or {}).get("redirectUris") or [])
        cb = f"https://{host}/.auth/login/aad/callback"
        if cb not in web:
            patch["web"] = {"redirectUris": web + [cb]}
            changes.append(f"web.redirectUris: add {cb}")

    rra = [dict(r) for r in app.get("requiredResourceAccess") or []]
    own = next((r for r in rra if r.get("resourceAppId") == app_id), None)
    if own is None:
        own = {"resourceAppId": app_id, "resourceAccess": []}
        rra.append(own)
    if not any(a.get("id") == scope["id"] for a in own["resourceAccess"]):
        own["resourceAccess"] = list(own["resourceAccess"]) + [{"id": scope["id"], "type": "Scope"}]
        patch["requiredResourceAccess"] = rra
        changes.append(f"requiredResourceAccess: add own scope {scope_value} (admin consent needed)")

    new_name = env.get("NEW_DISPLAY_NAME")
    if new_name and new_name != app.get("displayName"):
        patch["displayName"] = new_name
        changes.append(f"displayName: {app.get('displayName')} -> {new_name}")

    return patch, changes


def sp_rename(app_id: str, env: dict[str, str], apply: bool) -> None:
    """Give the service principal (Enterprise application) the new display name too."""
    new_name = env.get("NEW_DISPLAY_NAME")
    if not new_name:
        return
    sp = json.loads(az("rest", "--method", "get", "--url",
                       f"https://graph.microsoft.com/v1.0/servicePrincipals(appId='{app_id}')?$select=id,displayName"))
    if sp.get("displayName") == new_name:
        print(f"service principal {sp['id']}: already named {new_name}")
        return
    print(f"service principal {sp['id']}: displayName {sp.get('displayName')} -> {new_name}")
    if not apply:
        return
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump({"displayName": new_name}, f)
    try:
        az("rest", "--method", "patch", "--url", f"https://graph.microsoft.com/v1.0/servicePrincipals/{sp['id']}",
           "--headers", "Content-Type=application/json", "--body", f"@{f.name}")
    finally:
        os.unlink(f.name)
    print("applied (service principal)")


def main() -> int:
    args = sys.argv[1:]
    env = load_env()
    if "--from-file" in args:
        app = json.loads(Path(args[args.index("--from-file") + 1]).read_text())
    else:
        for k in ("SUB", "TENANT", "APP_ID"):
            if not env.get(k):
                print(f"{k} is empty in .env.local", file=sys.stderr)
                return 1
        app = json.loads(az("rest", "--method", "get", "--url",
                            f"https://graph.microsoft.com/v1.0/applications(appId='{env['APP_ID']}')?$select={SELECT}"))
    consent = False
    # Round 2 only adds what Graph refuses in the same PATCH as a new scope.
    for round_no in (1, 2):
        patch, changes = plan(app, env)
        if not changes:
            print("nothing to change" if round_no == 1 else "round 2: nothing more to change")
            break
        print(f"registration {app['appId']} ({app.get('displayName')}), round {round_no}:")
        for c in changes:
            print("  " + c)
        print("PATCH body:\n" + json.dumps(patch, indent=2))
        if "--apply" not in args:
            if any(c.startswith("api.oauth2PermissionScopes") for c in changes):
                print("(round 2 after --apply: pre-authorize Azure CLI for the new scope)")
            if "--from-file" not in args:
                sp_rename(app["appId"], env, apply=False)
            print("dry run: re-run with --apply to send it")
            return 0
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(patch, f)
        try:
            az("rest", "--method", "patch", "--url", f"https://graph.microsoft.com/v1.0/applications/{app['id']}",
               "--headers", "Content-Type=application/json", "--body", f"@{f.name}")
        finally:
            os.unlink(f.name)
        print("applied")
        consent = consent or any(c.startswith("requiredResourceAccess") for c in changes)
        if "--from-file" in args:
            break
        app = json.loads(az("rest", "--method", "get", "--url",
                            f"https://graph.microsoft.com/v1.0/applications/{app['id']}?$select={SELECT}"))
    if "--from-file" not in args:
        sp_rename(app["appId"], env, apply="--apply" in args)
    if consent:
        print("admin consent needed (Fabien): https://login.microsoftonline.com/"
              f"{env.get('TENANT', '<tenant>')}/adminconsent?client_id={app['appId']}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
