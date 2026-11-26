"""agent-gateway-llama-cpp: llama.cpp's llama-server behind the
agent-gateway contract (agent-stacks spec proposal 0002, section 7).

  agent-gateway-llama-cpp describe
  agent-gateway-llama-cpp check <model dir | model.json>...
  agent-gateway-llama-cpp serve [--listen <host:port>] [<models dir>...] [-- <server args>]
  agent-gateway-llama-cpp status --url <url>

Results go to standard output, everything else (llama-server's log
included) to standard error. Standard library only.
"""

import glob
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# Filled in by the package build.
LLAMA_SERVER = "@llamaServer@"
VERSION = "@version@"
PLATFORMS = json.loads("""@platforms@""")

NAME = "agent-gateway-llama-cpp"
FORMATS = ["gguf"]
# What llama-server serves itself, at these paths under /v1.
PROTOCOLS = ["anthropic-messages", "openai-chat-completions", "open-responses"]
DEFAULT_PORT = 9931
# The layouts whose entry can be handed to llama-server as one file.
LAYOUTS = ["plain", "hf-cache"]
# Metal wires about three quarters of unified memory by default, and a
# model bigger than that does not load or swaps.
MEMORY_FRACTION = 0.75
# What the spec keeps out of a model ID (proposal 0002, section 2).
ID_FORBIDDEN = "/:"
# The ID is a preset section name, "[<id>]": llama.cpp's ini reader ends
# it at ']', trims no inner blanks, and keeps '*' and 'default' for its
# own sections. The links are named apart from the ID, so a file name
# puts no limit on it.
PRESET_RESERVED = ("*", "default")
SPLIT_RE = re.compile(r"-(\d{5})-of-(\d{5})\.gguf$")
READY_TIMEOUT = 120


def log(msg):
    print(f"{NAME}: {msg}", file=sys.stderr, flush=True)


def host_platform():
    import platform
    if os.environ.get("AGENT_GATEWAY_PLATFORM"):
        return os.environ["AGENT_GATEWAY_PLATFORM"]
    arch = {"arm64": "aarch64"}.get(platform.machine(), platform.machine())
    return f"{arch}-{'darwin' if sys.platform == 'darwin' else 'linux'}"


def memory_limit():
    """Bytes of weights this host can load, or 0 when it is not known."""
    if os.environ.get("AGENT_GATEWAY_MEMORY_BYTES"):
        return int(os.environ["AGENT_GATEWAY_MEMORY_BYTES"])
    try:
        if sys.platform == "darwin":
            total = int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.memsize"]))
        else:
            total = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    except (OSError, ValueError, subprocess.CalledProcessError):
        return 0
    return int(total * MEMORY_FRACTION)


def gib(n):
    return f"{n / 2**30:.1f} GiB"


class Skip(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def check_model(arg):
    """One model directory (or its model.json) against this gateway.

    Returns the model, which holds id and entry, or raises Skip with the
    name check prints in .name: the model's id, or its directory's name
    when model.json cannot be read or its id is unusable."""
    p = Path(arg)
    d = p.parent if p.name == "model.json" else p
    try:
        return _check(d)
    except Skip as e:
        e.name = getattr(e, "name", None) or d.name
        raise


def id_problem(mid):
    """Why mid cannot be a model ID here, or None."""
    if not isinstance(mid, str) or not mid:
        return "is not a non-empty string"
    if any(c in mid for c in ID_FORBIDDEN):
        return "contains '/' or ':'"
    if any(ord(c) < 0x20 or ord(c) == 0x7F for c in mid):
        return "contains a control character"
    if "]" in mid or mid != mid.strip(" \t") or mid in PRESET_RESERVED:
        return "cannot name a llama-server preset section (']', blanks at either end, '*' or 'default')"
    return None


def _check(d):
    mj = d / "model.json"
    if not mj.is_file():
        if (d / "endpoint.json").is_file():
            raise Skip("endpoint", "the model has an endpoint (endpoint.json); launch talks to it directly")
        raise Skip("model-json", f"no model.json in {d}")
    try:
        m = json.loads(mj.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise Skip("model-json", f"cannot read {mj}: {e}")
    if not isinstance(m, dict):
        raise Skip("model-json", f"{mj} is not a JSON object")
    # A model.json with no id is named by its directory.
    mid = m.get("id", d.name)
    problem = id_problem(mid)
    if problem:
        raise Skip("model-json", f"id {mid!r} {problem}")
    try:
        return _check_files(d, m, mid)
    except Skip as e:
        e.name = mid
        raise


# The fields of a model with files; one with an endpoint has none of them.
FILE_FIELDS = ("layout", "format", "entry", "files")


def _check_files(d, m, mid):
    if "endpoint" in m:
        both = [k for k in FILE_FIELDS if k in m]
        if both:
            raise Skip("model-json", f"model.json has both an endpoint and {', '.join(both)}")
        raise Skip("endpoint", f"the model has an endpoint ({(m['endpoint'] or {}).get('url')}); launch talks to it directly")
    fmt = m.get("format")
    if fmt not in FORMATS:
        raise Skip("format", f"llama-server loads {', '.join(FORMATS)}, not {fmt!r}")
    plat = host_platform()
    if plat not in PLATFORMS:
        raise Skip("platform", f"llama-server is not built for {plat} ({', '.join(PLATFORMS)})")
    layout = m.get("layout", "plain")
    if layout not in LAYOUTS:
        raise Skip("layout", f"layout {layout!r} cannot be handed to llama-server ({', '.join(LAYOUTS)})")
    entry = m.get("entry")
    if not isinstance(entry, str) or not entry:
        raise Skip("model-json", "model.json names no entry")
    ep = d / entry
    if not ep.exists():  # follows every link, so a dangling one is caught
        raise Skip("weights", f"entry {entry} is missing")
    if not ep.is_file() or ep.suffix != ".gguf":
        raise Skip("weights", f"entry {entry} is not a .gguf file")
    sm = SPLIT_RE.search(ep.name)
    if sm and sm.group(1) != "00001":
        raise Skip("weights", f"entry {entry} is not the first shard of a split GGUF")
    weights = 0
    files = m.get("files") or []
    if not isinstance(files, list) or not all(isinstance(f, dict) for f in files):
        raise Skip("model-json", "files is not a list of objects")
    for f in files:
        fp = ep.parent / f.get("path", "")
        if not fp.is_file():
            raise Skip("weights", f"{f.get('path')} is missing")
        size = fp.stat().st_size
        if "size" in f and size != f["size"]:
            raise Skip("weights", f"{f['path']} is {size} bytes, model.json says {f['size']}")
        if f.get("role") == "weights":
            weights += size
    if not any(f.get("role") == "weights" for f in files):
        weights = ep.stat().st_size
    limit = memory_limit()
    if limit and weights > limit:
        raise Skip("memory", f"weights are {gib(weights)}, more than the {gib(limit)} this host can load")
    return {"id": mid, "entry": ep}


def cmd_describe(args):
    if args:
        die_usage("describe takes no arguments")
    print(json.dumps({
        "formats": FORMATS,
        "platforms": PLATFORMS,
        "version": VERSION,
        "protocols": PROTOCOLS,
        "defaultPort": DEFAULT_PORT,
    }, indent=2))


def cmd_check(args):
    if not args:
        die_usage("check needs a model directory or model.json")
    # A skip is an answer, not a failure: exit 0 once every model has a
    # line. Only a check that cannot run at all exits non-zero.
    for a in args:
        try:
            model = check_model(a)
            print(f"{model['id']} ok", flush=True)
        except Skip as e:
            print(f"{e.name} skip {e.code} {e.message}", flush=True)


def scan(dirs):
    """Every model in the models dirs this gateway can serve, by ID."""
    kept = {}
    for md in dirs:
        md = Path(md)
        if not md.is_dir():
            log(f"warning: no models directory at {md}")
            continue
        for d in sorted(md.iterdir()):
            if not d.is_dir():
                continue
            try:
                model = check_model(d)
            except Skip as e:
                log(f"warning: {e.name} skip {e.code} {e.message}")
                continue
            if model["id"] in kept:
                log(f"warning: {model['id']} in {d} is already served from {kept[model['id']]['dir']}; skipped")
                continue
            model["dir"] = d
            kept[model["id"]] = model
    return kept


def write_preset(state, models):
    """Links to every entry under state/models, and the preset naming
    them by ID. Links only: llama-server reads through them. Each model's
    links are in a directory of their own, numbered, under names of the
    gateway's choosing, so that neither the ID nor the model's file names
    reach a path the preset holds."""
    links = state / "models"
    if links.exists():
        shutil.rmtree(links)
    links.mkdir()
    ini = ["version = 1", ""]
    for n, (mid, m) in enumerate(models.items(), 1):
        entry = m["entry"]
        sub = links / f"{n:04d}"
        sub.mkdir()
        sm = SPLIT_RE.search(entry.name)
        if sm:
            # llama.cpp finds the other shards by the first one's name.
            stem = entry.name[:sm.start()]
            for f in sorted(entry.parent.glob(f"{glob.escape(stem)}-*-of-{sm.group(2)}.gguf")):
                (sub / f"model{SPLIT_RE.search(f.name).group(0)}").symlink_to(f.absolute())
            model = sub / f"model-00001-of-{sm.group(2)}.gguf"
        else:
            model = sub / "model.gguf"
            model.symlink_to(entry.absolute())
        ini += [f"[{mid}]", f"model = {model}"]
        mmproj = sorted(entry.parent.glob("mmproj*.gguf"))
        if mmproj:
            (sub / "mmproj.gguf").symlink_to(mmproj[0].absolute())
            ini.append(f"mmproj = {sub / 'mmproj.gguf'}")
        ini.append("")
    preset = state / "models.ini"
    tmp = state / "models.ini.new"
    tmp.write_text("\n".join(ini), encoding="utf-8")
    tmp.replace(preset)
    return preset


def parse_listen(s):
    m = re.match(r"^\[([^\]]+)\]:(\d+)$", s) or re.match(r"^([^:]*):(\d+)$", s)
    if not m or not 0 < int(m.group(2)) < 65536:
        raise ValueError(f"--listen takes <host>:<port>, got {s!r}")
    return m.group(1) or "127.0.0.1", int(m.group(2))


def emit_error(code, msg):
    print(f"error {code} {msg}", flush=True)
    sys.exit(1)


def cmd_serve(args):
    listen = f"127.0.0.1:{DEFAULT_PORT}"
    dirs, server_args = [], []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            server_args = args[i + 1:]
            break
        if a == "--listen":
            if i + 1 >= len(args):
                die_usage("--listen needs <host>:<port>")
            listen = args[i + 1]
            i += 2
            continue
        if a.startswith("--listen="):
            listen = a.split("=", 1)[1]
        elif a.startswith("-"):
            die_usage(f"unexpected {a!r}; server arguments go after --")
        else:
            dirs.append(a)
        i += 1
    if not dirs:
        if os.environ.get("AGENT_STACKS_MODELS_DIR"):
            dirs = [p for p in os.environ["AGENT_STACKS_MODELS_DIR"].split(":") if p]
        elif os.environ.get("FLOX_ENV"):
            dirs = [str(Path(os.environ["FLOX_ENV"]) / "share" / "agent-models")]

    try:
        host, port = parse_listen(listen)
    except ValueError as e:
        emit_error("address", str(e))
    try:
        info = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)[0]
        with socket.socket(info[0], socket.SOCK_STREAM) as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(info[4])
            s.listen()
    except OSError as e:
        emit_error("address", f"cannot listen on {listen}: {e.strerror or e}")

    state = Path(tempfile.mkdtemp(prefix=f"{NAME}."))
    try:
        serve(state, dirs, host, port, server_args)
    finally:
        shutil.rmtree(state, ignore_errors=True)


def serve(state, dirs, host, port, server_args):
    models = scan(dirs)
    preset = write_preset(state, models)
    log(f"serving {len(models)} model(s) from {', '.join(dirs) or 'no models directory'}"
        f"{': ' + ', '.join(models) if models else ''}; borrowed models from the Hugging Face cache too")
    cmd = [LLAMA_SERVER, "--models-preset", str(preset), "--host", host, "--port", str(port)] + server_args
    # In this process group, so that a service manager or a terminal
    # stopping the group stops llama-server and the models it runs too.
    proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=sys.stderr)
    events = []
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, lambda s, _f: events.append(s))

    probe = "127.0.0.1" if host in ("", "0.0.0.0") else "::1" if host == "::" else host
    base = f"http://{'[' + probe + ']' if ':' in probe else probe}:{port}"
    ready = False
    deadline = time.monotonic() + READY_TIMEOUT
    stopping = False
    while True:
        try:
            code = proc.wait(timeout=0.1 if not ready else 0.5)
        except subprocess.TimeoutExpired:
            code = None
        if code is not None:
            break
        while events:
            sig = events.pop(0)
            if sig == signal.SIGHUP and ready:
                models = scan(dirs)
                write_preset(state, models)
                try:
                    urllib.request.urlopen(f"{base}/v1/models?reload=1", timeout=30).read()
                    log(f"reloaded: {', '.join(models) or 'no carried models'}")
                except (OSError, urllib.error.URLError) as e:
                    log(f"warning: reload failed: {e}")
            elif sig != signal.SIGHUP and not stopping:
                stopping = True
                proc.terminate()
        if not ready and not stopping:
            try:
                with urllib.request.urlopen(f"{base}/health", timeout=2) as r:
                    ready = r.status == 200
            except (OSError, urllib.error.URLError):
                pass
            if ready:
                print("ready", flush=True)
            elif time.monotonic() > deadline:
                proc.terminate()
                stopping = True
                print(f"error other llama-server did not answer at {base} within {READY_TIMEOUT}s", flush=True)
    if stopping:
        sys.exit(0 if ready else 1)
    if not ready:
        emit_error("other", f"llama-server exited with status {code} before it was ready")
    log(f"llama-server exited with status {code}")
    sys.exit(code or 1)


def get_json(url):
    with urllib.request.urlopen(url, timeout=10) as r:
        return json.load(r)


def cmd_status(args):
    if len(args) == 2 and args[0] == "--url":
        url = args[1]
    elif len(args) == 1 and args[0].startswith("--url="):
        url = args[0].split("=", 1)[1]
    else:
        die_usage("status takes --url <url>")
    base = url.rstrip("/")
    if base.endswith("/v1"):
        base = base[:-3]
    try:
        listed = get_json(f"{base}/v1/models").get("data", [])
    except (OSError, ValueError, urllib.error.URLError) as e:
        log(f"cannot ask {base}/v1/models: {e}")
        sys.exit(1)
    out = []
    for e in listed:
        st = (e.get("status") or {}).get("value")
        # A server started on one model (not a router) reports no status.
        loaded = st == "loaded" if st else True
        ctx = None
        if loaded:
            q = f"?model={urllib.parse.quote(e['id'], safe='')}" if st else ""
            try:
                props = get_json(f"{base}/props{q}")
                ctx = (props.get("default_generation_settings") or {}).get("n_ctx") or props.get("n_ctx")
            except (OSError, ValueError, urllib.error.URLError):
                pass
        if ctx is None:
            ctx = e.get("context_length") or (e.get("meta") or {}).get("n_ctx_train")
        out.append({"id": e["id"], "loaded": loaded, "contextLength": ctx})
    print(json.dumps({"models": out}, indent=2))


def die_usage(msg):
    log(msg)
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    sys.exit(2)


def main():
    commands = {"describe": cmd_describe, "check": cmd_check, "serve": cmd_serve, "status": cmd_status}
    if len(sys.argv) < 2 or sys.argv[1] not in commands:
        die_usage(f"unknown command {sys.argv[1]!r}" if len(sys.argv) > 1 else "no command")
    commands[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
    main()
