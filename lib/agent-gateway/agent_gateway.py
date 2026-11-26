"""The agent-gateway contract (agent-stacks spec proposal 0002, section
7), shared by the agent-gateway-* packages.

  agent-gateway-<name> describe
  agent-gateway-<name> check <model dir | model.json>...
  agent-gateway-<name> serve [--listen <host:port>] [<models dir>...] [-- <server args>]
  agent-gateway-<name> status --url <url>

Results go to standard output, everything else (the server's log
included) to standard error. Standard library only.

Each package's gateway.py is a backend: what its server loads, how the
models are handed to it, the command that starts it, how it reloads,
and where it reports what it serves. Everything the contract fixes is
here, so that every gateway answers the same way. A backend is a
module with:

  NAME, SERVER, VERSION, PLATFORMS, FORMATS, PROTOCOLS, DEFAULT_PORT
  DESCRIBE_EXTRA          more describe fields ({} for none)
  HEALTH_PATH             answers 200 once the server takes requests
  check_files(d, m, mid)  -> {"id": mid, ...}, or raise Skip
  prepare(state, models, host, server_args)
                          writes what the server reads into state
  command(state, host, port, server_args) -> (argv, env or None)
  reload(base, state, server_args)
                          makes the running server re-read state
  status(base)            -> [{"id", "loaded", "contextLength"}]
"""

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
import urllib.request
from pathlib import Path

# The model ID is a file name or a section name: no '/', ':' or space.
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
READY_TIMEOUT = 120
# Where nothing better is known, Metal wires about three quarters of
# unified memory by default, and a model bigger than that does not
# load or swaps.
MEMORY_FRACTION = 0.75

B = None  # the backend, set by main()


def log(msg):
    print(f"{B.NAME}: {msg}", file=sys.stderr, flush=True)


def host_platform():
    import platform
    if os.environ.get("AGENT_GATEWAY_PLATFORM"):
        return os.environ["AGENT_GATEWAY_PLATFORM"]
    arch = {"arm64": "aarch64"}.get(platform.machine(), platform.machine())
    return f"{arch}-{'darwin' if sys.platform == 'darwin' else 'linux'}"


def memory_override():
    """AGENT_GATEWAY_MEMORY_BYTES, for tests; None when unset."""
    v = os.environ.get("AGENT_GATEWAY_MEMORY_BYTES")
    return int(v) if v else None


def memory_fraction_limit():
    """Bytes of weights this host can load by the flat rule, or 0."""
    if memory_override() is not None:
        return memory_override()
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
        self.name = None


def check_listed_files(base, m):
    """Every file in model.json's files[] exists under base with its
    size. Returns the bytes of the weights files, or None when files[]
    names none."""
    weights = None
    for f in m.get("files") or []:
        fp = base / f.get("path", "")
        if not fp.is_file():
            raise Skip("weights", f"{f.get('path')} is missing")
        size = fp.stat().st_size
        if "size" in f and size != f["size"]:
            raise Skip("weights", f"{f['path']} is {size} bytes, model.json says {f['size']}")
        if f.get("role") == "weights":
            weights = (weights or 0) + size
    return weights


def check_memory(weights, limit):
    if limit and weights > limit:
        raise Skip("memory", f"weights are {gib(weights)}, more than the {gib(limit)} this host can load")


def check_format_and_platform(m):
    fmt = m.get("format")
    if fmt not in B.FORMATS:
        raise Skip("format", f"{B.SERVER} loads {', '.join(B.FORMATS)}, not {fmt!r}")
    plat = host_platform()
    if plat not in B.PLATFORMS:
        raise Skip("platform", f"{B.SERVER} is not built for {plat} ({', '.join(B.PLATFORMS)})")


def check_model(arg):
    """One model directory (or its model.json) against this gateway.

    Returns (name, model) where model is what the backend's check_files
    returned, or raises Skip with the name in .name."""
    p = Path(arg)
    d = p.parent if p.name == "model.json" else p
    try:
        return d.name, _check(d)
    except Skip as e:
        e.name = e.name or d.name
        raise


def _check(d):
    mj = d / "model.json"
    if not mj.is_file():
        if (d / "endpoint.json").is_file():
            raise Skip("endpoint", "the model has an endpoint (endpoint.json); launch talks to it directly")
        raise Skip("other", f"no model.json in {d}")
    try:
        m = json.loads(mj.read_text())
    except (OSError, ValueError) as e:
        raise Skip("other", f"cannot read {mj}: {e}")
    if not isinstance(m, dict):
        raise Skip("other", f"{mj} is not a JSON object")
    mid = m.get("id", d.name)
    if not isinstance(mid, str) or not ID_RE.match(mid):
        raise Skip("other", f"id {mid!r} cannot be a model ID: use letters, digits, '.', '_' and '-'")
    try:
        if "endpoint" in m:
            if "files" in m:
                raise Skip("other", "model.json has both files and an endpoint")
            raise Skip("endpoint", f"the model has an endpoint ({(m['endpoint'] or {}).get('url')}); launch talks to it directly")
        return B.check_files(d, m, mid)
    except Skip as e:
        e.name = mid
        raise


def cmd_describe(args):
    if args:
        die_usage("describe takes no arguments")
    print(json.dumps({
        "formats": B.FORMATS,
        "platforms": B.PLATFORMS,
        "version": B.VERSION,
        "protocols": B.PROTOCOLS,
        "defaultPort": B.DEFAULT_PORT,
        **B.DESCRIBE_EXTRA,
    }, indent=2))


def cmd_check(args):
    if not args:
        die_usage("check needs a model directory or model.json")
    for a in args:
        try:
            name, _ = check_model(a)
            print(f"{name} ok", flush=True)
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
                _, model = check_model(d)
            except Skip as e:
                log(f"warning: {e.name} skip {e.code} {e.message}")
                continue
            if model["id"] in kept:
                log(f"warning: {model['id']} in {d} is already served from {kept[model['id']]['dir']}; skipped")
                continue
            model["dir"] = d
            kept[model["id"]] = model
    return kept


def parse_listen(s):
    m = re.match(r"^\[([^\]]+)\]:(\d+)$", s) or re.match(r"^([^:]*):(\d+)$", s)
    if not m or not 0 < int(m.group(2)) < 65536:
        raise ValueError(f"--listen takes <host>:<port>, got {s!r}")
    return m.group(1) or "127.0.0.1", int(m.group(2))


def is_loopback(host):
    return host in ("localhost", "::1") or host.startswith("127.")


def emit_error(code, msg):
    print(f"error {code} {msg}", flush=True)
    sys.exit(1)


def cmd_serve(args):
    listen = f"127.0.0.1:{B.DEFAULT_PORT}"
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

    state = Path(tempfile.mkdtemp(prefix=f"{B.NAME}."))
    try:
        serve(state, dirs, host, port, server_args)
    finally:
        shutil.rmtree(state, ignore_errors=True)


def serve(state, dirs, host, port, server_args):
    models = scan(dirs)
    B.prepare(state, models, host, server_args)
    log(f"serving {len(models)} model(s) from {', '.join(dirs) or 'no models directory'}"
        f"{': ' + ', '.join(models) if models else ''}; borrowed models from the Hugging Face cache too")
    argv, env = B.command(state, host, port, server_args)
    # In this process group, so that a service manager or a terminal
    # stopping the group stops the server and the models it runs too.
    proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=sys.stderr, env=env)
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
                B.prepare(state, models, host, server_args)
                try:
                    B.reload(base, state, server_args)
                    log(f"reloaded: {', '.join(models) or 'no carried models'}")
                except (OSError, ValueError, urllib.error.URLError) as e:
                    log(f"warning: reload failed: {e}")
            elif sig != signal.SIGHUP and not stopping:
                stopping = True
                proc.terminate()
        if not ready and not stopping:
            try:
                with urllib.request.urlopen(f"{base}{B.HEALTH_PATH}", timeout=2) as r:
                    ready = r.status == 200
            except (OSError, urllib.error.URLError):
                pass
            if ready:
                print("ready", flush=True)
            elif time.monotonic() > deadline:
                proc.terminate()
                stopping = True
                print(f"error other {B.SERVER} did not answer at {base} within {READY_TIMEOUT}s", flush=True)
    if stopping:
        sys.exit(0 if ready else 1)
    if not ready:
        emit_error("other", f"{B.SERVER} exited with status {code} before it was ready")
    log(f"{B.SERVER} exited with status {code}")
    sys.exit(code or 1)


def get_json(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=10) as r:
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
        out = B.status(base)
    except (OSError, ValueError, urllib.error.URLError) as e:
        log(f"cannot ask {base}/v1/models: {e}")
        sys.exit(1)
    print(json.dumps({"models": out}, indent=2))


def die_usage(msg):
    log(msg)
    print(__doc__.split("\n\n")[1].replace("<name>", B.NAME.removeprefix("agent-gateway-")), file=sys.stderr)
    sys.exit(2)


def main(backend):
    global B
    B = backend
    commands = {"describe": cmd_describe, "check": cmd_check, "serve": cmd_serve, "status": cmd_status}
    if len(sys.argv) < 2 or sys.argv[1] not in commands:
        die_usage(f"unknown command {sys.argv[1]!r}" if len(sys.argv) > 1 else "no command")
    commands[sys.argv[1]](sys.argv[2:])
