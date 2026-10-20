#!/usr/bin/env python3
"""Build the plugin audit dashboard: one self-contained HTML page with
every plugin package's audit.json embedded. Called by the page job of
.github/workflows/audit-plugins.yml, whose publish job deploys it to
GitHub Pages; runnable by hand the same way. Described in
docs/reference/plugin-audit.md.

    audit-dashboard.py <pkgs dir> <template> <out> --rev REV [--rev-date DATE]

  <pkgs dir>  the package directories, pkgs in this repository
  <template>  scripts/audit-dashboard.html; its /*__DATA__*/null
              placeholder is replaced with the data
  <out>       the page to write
  --rev       the agent-pkgs commit the packages were read at, which
              the page links audit.json files at
  --rev-date  that commit's date, shown on the page

A package is a directory named agent-plugin-* holding a default.nix.
One with no audit.json is listed as not audited yet. Each finding
keeps its file relative to its skill's directory, so the page can
link it at the skill's upstream path (source.json's `skills`) in the
upstream repository at the audited revision. Rules are kept once, as
(id, severity, message): one id can carry several of each.
"""
import argparse
import json
import os
from datetime import datetime, timezone

SEV = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3}
PLACEHOLDER = "/*__DATA__*/null"


def read_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pkgs")
    ap.add_argument("template")
    ap.add_argument("out")
    ap.add_argument("--rev", required=True)
    ap.add_argument("--rev-date", default="")
    ap.add_argument("--repo", default="agent-stacks/agent-pkgs")
    args = ap.parse_args()

    rules, rule_ix = [], {}
    plugins, unaudited = [], []
    for pkg in sorted(os.listdir(args.pkgs)):
        d = os.path.join(args.pkgs, pkg)
        if not pkg.startswith("agent-plugin-") or not os.path.isfile(os.path.join(d, "default.nix")):
            continue
        audit = read_json(os.path.join(d, "audit.json"))
        if audit is None:
            unaudited.append(pkg)
            continue
        src = read_json(os.path.join(d, "source.json"), {})
        s = src.get("src") or {}
        tool = audit.get("tool") or {}
        p = {
            "p": pkg,
            "s": audit.get("score"),
            "st": audit.get("status"),
            "v": src.get("version"),
            "gh": f'{s["owner"]}/{s["repo"]}' if s.get("owner") and s.get("repo") else None,
            "rev": s.get("rev"),
            "tool": tool.get("version"),
            "osv": (tool.get("osv") or {}).get("checkedAt"),
            "k": [],
        }
        if audit.get("audited") is False:
            p["why"] = audit.get("reason")
        skills = src.get("skills") or {}
        for plugin in audit.get("plugins") or []:
            for c in plugin.get("components") or []:
                path = (c.get("path") or "").rstrip("/")
                name = path.split("/", 1)[1] if path.startswith("skills/") else path
                prefix = path + "/"
                findings = []
                for fd in c.get("findings") or []:
                    key = (fd.get("id"), fd.get("severity"), fd.get("message") or "")
                    if key not in rule_ix:
                        rule_ix[key] = len(rules)
                        rules.append(list(key))
                    file = fd.get("file") or ""
                    # A leading / marks a file outside the skill, which
                    # the page shows without a link.
                    rel = file[len(prefix):] if file.startswith(prefix) else "/" + file
                    findings.append([rule_ix[key], rel, fd.get("line") or 0])
                findings.sort(key=lambda f: (SEV.get(rules[f[0]][1], 9), rules[f[0]][0], f[1], f[2]))
                p["k"].append({
                    "n": name,
                    "up": skills.get(name),
                    "s": c.get("score"),
                    "st": c.get("status"),
                    "cov": c.get("coverage"),
                    "part": bool(c.get("partial")),
                    "f": findings,
                    "x": [[e.get("reason"), e.get("path"), e.get("line") or 0]
                          for e in c.get("exceptions") or []],
                })
        plugins.append(p)

    data = {
        "repo": args.repo,
        "rev": args.rev,
        "revDate": args.rev_date,
        "built": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "rules": rules,
        "plugins": plugins,
        "unaudited": unaudited,
    }
    with open(args.template) as f:
        template = f.read()
    if template.count(PLACEHOLDER) != 1:
        raise SystemExit(f"{args.template}: expected one {PLACEHOLDER}")
    # Inside <script>, so no "<" may survive: "</script>" would end the
    # script, and "<!--<script>" would keep it from ending where it should.
    blob = json.dumps(data, separators=(",", ":")).replace("<", "\\u003c")
    html = template.replace(PLACEHOLDER, blob)
    with open(args.out, "w") as f:
        f.write(html)
    n = sum(len(k["f"]) for p in plugins for k in p["k"])
    print(f"{len(plugins)} plugins, {n} findings, {len(rules)} rules, "
          f"{len(unaudited)} not audited yet; {len(html) // 1024} KiB written to {args.out}")


if __name__ == "__main__":
    main()
