"""agent-gateway-llama-cpp: llama.cpp's llama-server behind the
agent-gateway contract (agent-stacks spec proposal 0002, section 7).

The contract itself is agent_gateway.py, shared with the other
agent-gateway-* packages; this is what is particular to llama-server.
"""

import json
import os
import re
import shutil
import sys
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agent_gateway as ag  # noqa: E402
from agent_gateway import Skip  # noqa: E402

# Filled in by the package build.
LLAMA_SERVER = "@llamaServer@"
VERSION = "@version@"
PLATFORMS = json.loads("""@platforms@""")

NAME = "agent-gateway-llama-cpp"
SERVER = "llama-server"
FORMATS = ["gguf"]
# What llama-server serves itself, at these paths under /v1.
PROTOCOLS = ["anthropic-messages", "openai-chat-completions", "open-responses"]
DEFAULT_PORT = 9931
DESCRIBE_EXTRA = {}
HEALTH_PATH = "/health"
# The layouts whose entry can be handed to llama-server as one file.
LAYOUTS = ["plain", "hf-cache"]
SPLIT_RE = re.compile(r"-(\d{5})-of-(\d{5})\.gguf$")


def check_files(d, m, mid):
    ag.check_format_and_platform(m)
    layout = m.get("layout", "plain")
    if layout not in LAYOUTS:
        raise Skip("weights", f"layout {layout!r} cannot be handed to llama-server ({', '.join(LAYOUTS)})")
    entry = m.get("entry")
    if not isinstance(entry, str) or not entry:
        raise Skip("weights", "model.json names no entry")
    ep = d / entry
    if not ep.exists():  # follows every link, so a dangling one is caught
        raise Skip("weights", f"entry {entry} is missing")
    if not ep.is_file() or ep.suffix != ".gguf":
        raise Skip("weights", f"entry {entry} is not a .gguf file")
    sm = SPLIT_RE.search(ep.name)
    if sm and sm.group(1) != "00001":
        raise Skip("weights", f"entry {entry} is not the first shard of a split GGUF")
    weights = ag.check_listed_files(ep.parent, m)
    if weights is None:
        weights = ep.stat().st_size
    ag.check_memory(weights, ag.memory_fraction_limit())
    return {"id": mid, "entry": ep}


def prepare(state, models, host, server_args):
    """Links to every entry under state/models, and the preset naming
    them by ID. Links only: llama-server reads through them."""
    links = state / "models"
    if links.exists():
        shutil.rmtree(links)
    links.mkdir()
    ini = ["version = 1", ""]
    for mid, m in models.items():
        entry = m["entry"]
        if SPLIT_RE.search(entry.name) or list(entry.parent.glob("mmproj*.gguf")):
            # Shards and a projector go together in one directory.
            sub = links / mid
            sub.mkdir()
            stem = SPLIT_RE.sub("", entry.name)
            for f in sorted(entry.parent.glob(f"{stem}-*-of-*.gguf")) or [entry]:
                (sub / f.name).symlink_to(f.absolute())
            mmproj = sorted(entry.parent.glob("mmproj*.gguf"))
            for f in mmproj:
                (sub / f.name).symlink_to(f.absolute())
            ini += [f"[{mid}]", f"model = {sub / entry.name}"]
            if mmproj:
                ini.append(f"mmproj = {sub / mmproj[0].name}")
        else:
            link = links / f"{mid}.gguf"
            link.symlink_to(entry.absolute())
            ini += [f"[{mid}]", f"model = {link}"]
        ini.append("")
    tmp = state / "models.ini.new"
    tmp.write_text("\n".join(ini))
    tmp.replace(state / "models.ini")


def command(state, host, port, server_args):
    # Router mode over the preset: every model at one endpoint.
    return [LLAMA_SERVER, "--models-preset", str(state / "models.ini"),
            "--host", host, "--port", str(port)] + server_args, None


def reload(base, state, server_args):
    urllib.request.urlopen(f"{base}/v1/models?reload=1", timeout=30).read()


def status(base):
    out = []
    for e in ag.get_json(f"{base}/v1/models").get("data", []):
        st = (e.get("status") or {}).get("value")
        # A server started on one model (not a router) reports no status.
        loaded = st == "loaded" if st else True
        ctx = None
        if loaded:
            q = f"?model={urllib.parse.quote(e['id'], safe='')}" if st else ""
            try:
                props = ag.get_json(f"{base}/props{q}")
                ctx = (props.get("default_generation_settings") or {}).get("n_ctx") or props.get("n_ctx")
            except (OSError, ValueError):
                pass
        if ctx is None:
            ctx = e.get("context_length") or (e.get("meta") or {}).get("n_ctx_train")
        out.append({"id": e["id"], "loaded": loaded, "contextLength": ctx})
    return out


if __name__ == "__main__":
    ag.main(sys.modules[__name__])
