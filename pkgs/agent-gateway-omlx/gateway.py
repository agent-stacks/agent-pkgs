"""agent-gateway-omlx: oMLX behind the agent-gateway contract
(agent-stacks spec proposal 0002, section 7).

The contract itself is agent_gateway.py, shared with the other
agent-gateway-* packages; this is what is particular to oMLX.
"""

import json
import os
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agent_gateway as ag  # noqa: E402
from agent_gateway import Skip  # noqa: E402

# Filled in by the package build.
OMLX = "@omlx@"
MLX_PYTHON = "@mlxPython@"
VERSION = "@version@"
PLATFORMS = json.loads("""@platforms@""")

NAME = "agent-gateway-omlx"
SERVER = "oMLX"
# oMLX's GGUF support is a separate engine (Splash) that is not packaged.
FORMATS = ["mlx"]
# What oMLX serves itself, at these paths under /v1.
PROTOCOLS = ["anthropic-messages", "openai-chat-completions", "open-responses"]
DEFAULT_PORT = 8000
# MLX >= 0.29.2 needs macOS 15 (oMLX's README and packaging notes).
MINIMUM_MACOS = "15.0"
DESCRIBE_EXTRA = {"minimumMacOS": MINIMUM_MACOS}
# 503 while pinned models preload, 200 once requests are served.
HEALTH_PATH = "/health"
# The layouts whose entry is a model directory oMLX can be pointed at.
LAYOUTS = ["plain", "hf-cache"]


def macos_version():
    if os.environ.get("AGENT_GATEWAY_MACOS_VERSION"):
        return os.environ["AGENT_GATEWAY_MACOS_VERSION"]
    import platform
    return platform.mac_ver()[0] or None


def version_tuple(v):
    return tuple(int(p) for p in v.split(".") if p.isdigit())


_limit = None


def memory_limit():
    """Bytes of weights Metal will keep resident: its recommended
    working set, asked of oMLX's own MLX. The flat rule where MLX
    cannot answer."""
    global _limit
    if _limit is not None:
        return _limit
    _limit = ag.memory_override()
    if _limit is None:
        probe = ("import mlx.core as mx\n"
                 "info = mx.device_info() if hasattr(mx, 'device_info') else mx.metal.device_info()\n"
                 "print(info['max_recommended_working_set_size'])")
        try:
            r = subprocess.run([MLX_PYTHON, "-I", "-c", probe], capture_output=True, text=True, timeout=60)
            _limit = int(r.stdout.strip()) if r.returncode == 0 else 0
        except (OSError, ValueError, subprocess.TimeoutExpired):
            _limit = 0
    if not _limit:
        _limit = ag.memory_fraction_limit()
    return _limit


def check_files(d, m, mid):
    ag.check_format_and_platform(m)
    mv = macos_version()
    if mv and version_tuple(mv) < version_tuple(MINIMUM_MACOS):
        raise Skip("host", f"oMLX needs macOS {MINIMUM_MACOS} or later, this is {mv}")
    layout = m.get("layout", "plain")
    if layout not in LAYOUTS:
        raise Skip("weights", f"layout {layout!r} cannot be handed to oMLX ({', '.join(LAYOUTS)})")
    entry = m.get("entry")
    if not isinstance(entry, str) or not entry:
        raise Skip("weights", "model.json names no entry")
    ep = d / entry
    if not ep.exists():  # follows every link, so a dangling one is caught
        raise Skip("weights", f"entry {entry} is missing")
    if not ep.is_dir():
        raise Skip("weights", f"entry {entry} is not an MLX model directory")
    try:
        cfg = json.loads((ep / "config.json").read_text())
    except FileNotFoundError:
        raise Skip("weights", f"entry {entry} has no config.json")
    except (OSError, ValueError) as e:
        raise Skip("weights", f"cannot read {entry}config.json: {e}")
    tensors = sorted(p for p in ep.glob("*.safetensors") if p.is_file())
    if not tensors:
        raise Skip("weights", f"entry {entry} has no .safetensors weights")
    index = ep / "model.safetensors.index.json"
    if index.is_file():
        try:
            shards = set((json.loads(index.read_text()).get("weight_map") or {}).values())
        except (OSError, ValueError) as e:
            raise Skip("weights", f"cannot read {index.name}: {e}")
        missing = sorted(s for s in shards if not (ep / s).is_file())
        if missing:
            raise Skip("weights", f"{len(missing)} shard(s) the index names are missing, e.g. {missing[0]}")
    weights = ag.check_listed_files(ep, m)
    if weights is None:
        weights = sum(p.stat().st_size for p in tensors)
    check_quantization(m, cfg)
    ag.check_memory(weights, memory_limit())
    return {"id": mid, "entry": ep}


def check_quantization(m, cfg):
    """model.json's config.quantization against config.json's. Whether
    MLX loads that quantization only shows when it loads the model."""
    declared = (m.get("config") or {}).get("quantization")
    if not isinstance(declared, dict) or "bits" not in declared:
        return
    actual = cfg.get("quantization") or cfg.get("quantization_config")
    if not isinstance(actual, dict):
        raise Skip("weights", f"model.json says {declared['bits']}-bit, config.json is not quantized")
    for ours, theirs in (("bits", "bits"), ("groupSize", "group_size")):
        if ours in declared and declared[ours] != actual.get(theirs):
            raise Skip("weights", f"model.json says {ours} {declared[ours]}, config.json says {actual.get(theirs)}")


def api_key(server_args):
    """The key oMLX was given, to call its admin API with."""
    for i, a in enumerate(server_args):
        if a == "--api-key" and i + 1 < len(server_args):
            return server_args[i + 1]
        if a.startswith("--api-key="):
            return a.split("=", 1)[1]
    return os.environ.get("OMLX_API_KEY") or None


def prepare(state, models, host, server_args):
    """state/models: one link per model, named by its ID, to its model
    directory; oMLX names a model by its directory. state/base: oMLX's
    base path. state/home: the HOME it runs with."""
    links = state / "models"
    if links.exists():
        shutil.rmtree(links)
    links.mkdir()
    for mid, m in models.items():
        (links / mid).symlink_to(m["entry"].absolute(), target_is_directory=True)
    (state / "home").mkdir(exist_ok=True)
    base = state / "base"
    if not base.exists():
        base.mkdir()
        # Reloading is an admin call. On loopback without a key, let it
        # through without one, as oMLX's own setting does; with a key
        # (required off loopback) the gateway sends it.
        skip = ag.is_loopback(host) and not api_key(server_args)
        (base / "settings.json").write_text(json.dumps({"version": "1.0", "auth": {"skip_api_key_verification": skip}}))


def command(state, host, port, server_args):
    env = dict(os.environ)
    # The Hugging Face cache stays the user's, wherever HOME points.
    if not env.get("HF_HOME"):
        env["HF_HOME"] = str(Path.home() / ".cache" / "huggingface")
    env["HOME"] = str(state / "home")
    # The gateway decides these; oMLX would let them override it.
    for k in ("OMLX_BASE_PATH", "OMLX_MODEL_DIR", "OMLX_HOST", "OMLX_PORT"):
        env.pop(k, None)
    return [OMLX, "serve", "--model-dir", str(state / "models"), "--base-path", str(state / "base"),
            "--host", host, "--port", str(port)] + server_args, env


def auth_headers(key):
    return {"Authorization": f"Bearer {key}"} if key else {}


def reload(base, state, server_args):
    req = urllib.request.Request(f"{base}/admin/api/reload", data=b"", method="POST",
                                 headers=auth_headers(api_key(server_args)))
    with urllib.request.urlopen(req, timeout=120) as r:
        body = json.load(r)
    if body.get("success") is False:
        raise ValueError(body.get("message") or body)


def status(base):
    h = auth_headers(os.environ.get("OMLX_API_KEY"))
    listed = ag.get_json(f"{base}/v1/models", h).get("data", [])
    detail = {s["id"]: s for s in ag.get_json(f"{base}/v1/models/status", h).get("models", [])}
    out = []
    for e in listed:
        s = detail.get(e["id"], {})
        out.append({
            "id": e["id"],
            "loaded": bool(s.get("loaded")),
            # The window oMLX enforces: a per-model or policy limit, else
            # what the model's config.json says.
            "contextLength": s.get("max_context_window") or s.get("model_context_length"),
        })
    return out


if __name__ == "__main__":
    ag.main(sys.modules[__name__])
