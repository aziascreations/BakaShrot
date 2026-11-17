"""Builds a BakaShrot release for this machine's platform (Windows or
Linux, x64 or ARM64), checks it works, and archives it:

    python release.py [--skip-test] [--hybrid-crt]

Into target/dist/:
  bakashrot-<version>-<platform>/       the release:
    bakashrot-server, bakashrot                    the programs
    bakashrot.dll / libbakashrot.so                the client library (C)
    include/bakashrot.h                            its C header
    purebasic/*.pbi                                its PureBasic prototypes
    python/bakashrot.py                            the Python client, over it
    python/bakashrot-<version>-*.whl               the same with the library in it
    server.example.toml, client.example.toml       the configs, documented
    docs/                                          docs/
    README.txt                                     what's where, how to start
    LICENSE.txt, THIRD-PARTY.txt                   BakaShrot's (CC0), its dependencies'
  bakashrot-<version>-<platform>.zip (Windows) or .tar.gz (Linux)

No keys or certificates in it: bakashrot cert makes them.

The check (unless --skip-test), in the release folder's _test/ (exes run
from temp folders get blocked by antivirus here), deleted after unless
it failed: a CA and certificates by bakashrot cert, the
server started on a free port with a throwaway database, then the tool
pushing (and an attachment of 3 MB), reading back, listing, querying;
Python through the library, then the wheel installed by pip and used with
no path given; then the server stopped as a service manager would
(SIGTERM, or Ctrl+Break on Windows), which must end cleanly.

--hybrid-crt, on Windows: the C runtime's UCRT from Windows (10 and up)
instead of linked in, about 180 KB less per program, still no Visual C++
redistributable (.cargo/hybrid-crt.toml); README.txt says which.

The version is the workspace's (Cargo.toml), which bakashrot.py's
__version__ must match. Needs Python 3.11+ (tomllib) and cargo (rustup).
"""

import json
import os
import platform
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import tomllib
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
WINDOWS = sys.platform == "win32"
EXE = ".exe" if WINDOWS else ""
LIBRARY = "bakashrot.dll" if WINDOWS else "libbakashrot.so"
# Each built with its profile (Cargo.toml), into target/<profile>/.
PROGRAMS = {"bakashrot-server": "release", "bakashrot": "release-tools"}
CRATES = {"bakashrot-server": "release", "bakashrot-capi": "release", "bakashrot-tools": "release-tools"}

CLIENT_EXAMPLE = """\
# What the bakashrot tool and Python's Client.from_file() read, to connect
# to a server. Paths are relative to this file's folder. See
# docs/client.md.
server = "10.0.0.2:7000"     # host:port, [an IPv6 address]:port
ca = "ca.crt"                # the CA's certificate (bakashrot cert ca)
certificate = "kitchen.crt"  # this node's (bakashrot cert issue --name kitchen ...)
key = "kitchen.key"
# crl = "ca.crl"             # optional: certificates the CA revoked
"""


def fail(why):
    sys.exit(f"release.py: {why}")


def run(command, cwd=HERE, **kwargs):
    """Runs a command, its standard output; fails with its output if it does."""
    done = subprocess.run(command, cwd=cwd, capture_output=True, encoding="utf-8", errors="replace", **kwargs)
    if done.returncode != 0:
        fail(f"{' '.join(map(str, command))} failed ({done.returncode}):\n{done.stdout}{done.stderr}")
    return done.stdout


def version():
    with open(os.path.join(HERE, "Cargo.toml"), "rb") as file:
        version = tomllib.load(file)["workspace"]["package"]["version"]
    with open(os.path.join(HERE, "bindings", "python", "bakashrot.py"), encoding="utf-8") as file:
        python = re.search(r'^__version__ = "([^"]+)"', file.read(), re.MULTILINE)
    if not python or python.group(1) != version:
        fail(f"bakashrot.py's __version__ isn't the workspace's {version}")
    return version


# The release's name for each Rust host it's built on.
PLATFORMS = {
    "x86_64-pc-windows-msvc": "windows-x64",
    "aarch64-pc-windows-msvc": "windows-arm64",
    "x86_64-unknown-linux-gnu": "linux-x64",
    "aarch64-unknown-linux-gnu": "linux-arm64",
}


def platform_name():
    """The release's platform: the Rust toolchain's host, which Python must
    match (the smoke test loads the library into it)."""
    host = next(line.split()[1] for line in run(["rustc", "-vV"]).splitlines()
                if line.startswith("host:"))
    if host not in PLATFORMS:
        fail(f"no release for {host}")
    machine = {"amd64": "x86_64", "arm64": "aarch64"}.get(platform.machine().lower(),
                                                          platform.machine().lower())
    if not host.startswith(machine + "-"):
        fail(f"Python is {platform.machine()}, Rust builds for {host}: use a Python of the same")
    return PLATFORMS[host]


def commit():
    try:
        sha = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=HERE,
                             capture_output=True, text=True).stdout.strip()
        dirty = subprocess.run(["git", "status", "--porcelain", "."], cwd=HERE,
                               capture_output=True, text=True).stdout.strip()
    except OSError:
        return "unknown"
    return (sha or "unknown") + (" (with uncommitted changes)" if dirty else "")


def third_party():
    """Every crate built into the programs and the library (normal
    dependencies, this platform's), with its license files' text."""
    host = re.search(r"^host: (\S+)", run(["rustc", "-vV"]), re.MULTILINE).group(1)
    metadata = json.loads(run(["cargo", "metadata", "--format-version", "1", "--filter-platform", host]))
    packages = {package["id"]: package for package in metadata["packages"]}
    nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
    roots = [id for id, package in packages.items() if package["name"] in CRATES]
    seen, stack = set(), list(roots)
    while stack:
        id = stack.pop()
        if id in seen:
            continue
        seen.add(id)
        for dep in nodes[id]["deps"]:
            if any(kind["kind"] is None for kind in dep["dep_kinds"]):
                stack.append(dep["pkg"])
    workspace = set(metadata["workspace_members"])
    used = sorted((packages[id] for id in seen - workspace), key=lambda p: (p["name"], p["version"]))
    lines = [
        "BakaShrot's programs and client library are built with these crates",
        "(their code is in them). Each one's license, then their license files,",
        "each text once with the crates it comes from.",
        "SQLite (in libsqlite3-sys) is in the public domain.",
        "",
    ]
    lines += [f"{p['name']} {p['version']}: {p['license'] or 'see its files'}" for p in used]
    texts = {}  # a license file's text: the crates' files it is
    for package in used:
        folder = os.path.dirname(package["manifest_path"])
        names = sorted(name for name in os.listdir(folder)
                       if re.match(r"(LICEN[CS]E|COPYING|COPYRIGHT|NOTICE)", name, re.IGNORECASE)
                       and os.path.isfile(os.path.join(folder, name)))
        for name in names:
            with open(os.path.join(folder, name), encoding="utf-8", errors="replace") as file:
                text = file.read().strip()
            texts.setdefault(text, []).append(f"{package['name']} {package['version']} ({name})")
    for text, sources in texts.items():
        lines += ["", "=" * 76, *sources, "=" * 76, "", text]
    return "\n".join(lines) + "\n"


def readme(version, name, hybrid):
    built = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    rustc = run(["rustc", "--version"]).strip()
    crt = ""
    if WINDOWS:
        crt = ("\nThe C runtime: Windows' UCRT (Windows 10 and up), VCRuntime linked in."
               if hybrid else "\nThe C runtime: linked in, nothing to install.")
    return f"""\
BakaShrot {version} ({name})

Built {built}, commit {commit()}, {rustc}.{crt}
Licenses: BakaShrot is CC0 (LICENSE.txt); the crates built into it are
listed in THIRD-PARTY.txt with their licenses.

A message store with replication: servers take messages per topic and node
from clients with certificates of your own CA, store them in SQLite, and
replicate them between servers. docs/ has the details (config.md,
certificates.md, server.md, client.md, protocol.md).

Certificates (bakashrot{EXE} cert, no server needed; docs/certificates.md):
  bakashrot cert ca --name "Home CA"                    ca.crt, ca.key (keep ca.key safe)
  bakashrot cert issue --name server-1 --server         a server's
  bakashrot cert issue --name kitchen --role sensor     a client's: its node, its roles
  bakashrot cert revoke kitchen.crt                     ca.crl

The server (bakashrot-server{EXE} server.toml; docs/config.md, server.md):
  server.example.toml has every setting. It logs to the console
  (BAKASHROT_LOG=debug for more) and stops cleanly on SIGTERM or SIGINT
  (Linux), Ctrl+C, Ctrl+Break or its console closed (Windows): what was
  being written is committed first. No console commands: run it from a
  service manager (systemd, NSSM...) or a terminal.

The tool (bakashrot{EXE}, with a client.toml: client.example.toml;
docs/client.md), --help on each command:
  bakashrot push logs '{{"t":21}}'          bakashrot push logs @file.json -a photo.jpg
  bakashrot latest logs kitchen            bakashrot messages logs kitchen [-f]
  bakashrot attachment logs kitchen 43 copy.jpg
  bakashrot list                           bakashrot query "SELECT * FROM messages"

The client library ({LIBRARY}): the BakaShrot_* exports, include/bakashrot.h
for C, purebasic/ for PureBasic, python/bakashrot.py for Python (no
dependencies; it looks for the library next to itself or in BAKASHROT_DLL).
Or: pip install python/bakashrot-*.whl, the library inside.

Compatibility: protocol 7. Servers and clients must come from the same
release: another version's connection is refused. Nothing from the old
(PureBasic) BakaShrot is read: not its configs, keys or databases.
"""


def build(hybrid):
    """Each profile's crates at once; the folder of a profile's output."""
    print("Building" + (" (the hybrid C runtime)" if hybrid else ""))
    for profile in sorted(set(CRATES.values())):
        command = ["cargo", "build", "--profile", profile, "--locked"]
        if hybrid:
            command += ["--config", os.path.join(".cargo", "hybrid-crt.toml")]
        for crate, its in CRATES.items():
            if its == profile:
                command += ["-p", crate]
        run(command)
    return lambda profile: os.path.join(HERE, "target", profile)


def package(built, version, name, out, hybrid):
    print(f"Packaging {out}")
    for program, profile in PROGRAMS.items():
        shutil.copy2(os.path.join(built(profile), program + EXE), out)
    shutil.copy2(os.path.join(built(CRATES["bakashrot-capi"]), LIBRARY), out)
    bindings = os.path.join(HERE, "bindings")
    os.makedirs(os.path.join(out, "include"))
    shutil.copy2(os.path.join(bindings, "c", "bakashrot.h"), os.path.join(out, "include"))
    shutil.copytree(os.path.join(bindings, "purebasic"), os.path.join(out, "purebasic"))
    os.makedirs(os.path.join(out, "python"))
    shutil.copy2(os.path.join(bindings, "python", "bakashrot.py"), os.path.join(out, "python"))
    shutil.copytree(os.path.join(HERE, "docs"), os.path.join(out, "docs"))
    shutil.copy2(os.path.join(HERE, "crates", "bakashrot-config", "example.toml"),
                 os.path.join(out, "server.example.toml"))
    write(os.path.join(out, "client.example.toml"), CLIENT_EXAMPLE)
    shutil.copy2(os.path.join(HERE, "LICENSE"), os.path.join(out, "LICENSE.txt"))
    write(os.path.join(out, "THIRD-PARTY.txt"), third_party())
    write(os.path.join(out, "README.txt"), readme(version, name, hybrid))
    wheel = run([sys.executable, "-B", os.path.join(bindings, "python", "make_wheel.py"),
                 os.path.join(out, LIBRARY), os.path.join(out, "python"),
                 os.path.join(out, "LICENSE.txt"), os.path.join(out, "THIRD-PARTY.txt")]).strip()
    print(f"Wheel: {os.path.basename(wheel)}")
    return wheel


def write(path, text):
    """A text file, with the platform's line endings."""
    with open(path, "w", encoding="utf-8") as file:
        file.write(text)


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def smoke_test(out, wheel):
    print("Testing the release")
    test = os.path.join(out, "_test")
    os.makedirs(test)
    tool = lambda program, *args: run([os.path.join(out, program + EXE), *args], cwd=test)

    def expect(what, got, pattern):
        if not re.search(pattern, got, re.MULTILINE):
            fail(f"{what}: unexpected output:\n{got}")

    tool("bakashrot", "cert", "ca", "--name", "Release test CA")
    tool("bakashrot", "cert", "issue", "--name", "server-1", "--server")
    tool("bakashrot", "cert", "issue", "--name", "tester", "--role", "tester")
    port = free_port()
    write(os.path.join(test, "server.toml"), f"""\
[server]
listen = "127.0.0.1:{port}"
ca = "ca.crt"
certificate = "server-1.crt"
key = "server-1.key"
database = "test.sqlite"

[roles.tester]
push_topics = ["releasetest"]
read_topics = ["*"]
query = true
""")
    write(os.path.join(test, "client.toml"), f"""\
server = "127.0.0.1:{port}"
ca = "ca.crt"
certificate = "tester.crt"
key = "tester.key"
""")
    write(os.path.join(test, "message.json"), '{"release":"test","value":42}')
    attachment = os.urandom(3 * 1024 * 1024)
    with open(os.path.join(test, "attachment.bin"), "wb") as file:
        file.write(attachment)

    log = open(os.path.join(test, "server.log"), "w")
    # Its own process group on Windows, to be sent Ctrl+Break alone.
    flags = subprocess.CREATE_NEW_PROCESS_GROUP if WINDOWS else 0
    server = subprocess.Popen([os.path.join(out, "bakashrot-server" + EXE), "server.toml"], cwd=test,
                              stdout=log, stderr=subprocess.STDOUT, creationflags=flags)
    try:
        deadline = time.monotonic() + 15
        while True:
            if server.poll() is not None:
                fail(f"the server exited ({server.returncode}):\n{read_log(test)}")
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
                break
            except OSError:
                if time.monotonic() > deadline:
                    fail(f"the server isn't listening on {port}:\n{read_log(test)}")
                time.sleep(0.1)

        expect("push", tool("bakashrot", "push", "releasetest", "@message.json"), r"message #1\b")
        expect("push -a", tool("bakashrot", "push", "releasetest", '{"with":"file"}', "-a", "attachment.bin"),
               r"message #2, with an attachment of 3145728 bytes")
        latest = tool("bakashrot", "latest", "releasetest", "tester")
        expect("latest", latest, r"releasetest:tester#2")
        expect("latest", latest, r"Attachment: 3145728 bytes")
        expect("attachment", tool("bakashrot", "attachment", "releasetest", "tester", "2", "copy.bin"),
               r"Saved 3145728 bytes")
        with open(os.path.join(test, "copy.bin"), "rb") as file:
            if file.read() != attachment:
                fail("the attachment came back different")
        messages = tool("bakashrot", "messages", "releasetest", "tester")
        expect("messages", messages, r'^1\t\{"release":"test","value":42\}$')
        expect("messages", messages, r'^2\t\{"with":"file"\}$')
        expect("list", tool("bakashrot", "list", "nodes", "--json"), r'"names":\["tester"\]')
        expect("query", tool("bakashrot", "query",
                             "SELECT message_data ->> '$.value' AS v FROM messages WHERE topic = 'releasetest' AND message_id = 1"),
               r'"rows":\[\["42"\]\]')
        print("  The tool: certificates made, pushed, an attachment too, read back, listed, queried: OK")

        script = ("import sys; sys.path.insert(0, sys.argv[1]); import bakashrot\n"
                  "with bakashrot.Client.from_file('client.toml', sys.argv[2]) as c:\n"
                  "    print(c.latest('releasetest', 'tester').id, c.get_attachment('releasetest', 'tester', 2)"
                  " == open('attachment.bin', 'rb').read(), c.push({'py': 1}, 'releasetest'))\n")
        got = run([sys.executable, "-B", "-c", script, os.path.join(out, "python"), os.path.join(out, LIBRARY)],
                  cwd=test).strip()
        if got != "2 True 3":
            fail(f"Python through the library: unexpected output: {got}")
        print("  Python, through the library: OK")

        installed = os.path.join(test, "wheel")
        run([sys.executable, "-m", "pip", "install", "--no-index", "--no-deps", "--disable-pip-version-check",
             "--quiet", "--target", installed, wheel])
        script = ("import os, sys; sys.path.insert(0, sys.argv[1]); import bakashrot\n"
                  "with bakashrot.Client.from_file('client.toml') as c:\n"
                  "    inside = os.path.dirname(c._dll.path) == os.path.dirname(bakashrot.__file__)\n"
                  "    print(inside, c.latest('releasetest', 'tester').json()['py'], c.push({'wheel': 1}, 'releasetest'))\n")
        environment = {key: value for key, value in os.environ.items() if key != "BAKASHROT_DLL"}
        got = run([sys.executable, "-B", "-c", script, installed], cwd=test, env=environment).strip()
        if got != "True 1 4":
            fail(f"the wheel: unexpected output: {got}")
        print("  The wheel, installed by pip: OK")

        server.send_signal(signal.CTRL_BREAK_EVENT if WINDOWS else signal.SIGTERM)
        try:
            code = server.wait(timeout=15)
        except subprocess.TimeoutExpired:
            fail(f"the server didn't stop when asked:\n{read_log(test)}")
        if code != 0 or "stopped" not in read_log(test):
            fail(f"the server didn't stop cleanly ({code}):\n{read_log(test)}")
        print("  Stopped cleanly: OK")
    finally:
        if server.poll() is None:
            server.kill()
            server.wait()
        log.close()
    return test


def read_log(test):
    with open(os.path.join(test, "server.log"), encoding="utf-8", errors="replace") as file:
        return file.read()


def archive(out):
    """The release folder in a .zip (Windows) or .tar.gz (Linux, keeping
    the programs executable)."""
    return shutil.make_archive(out, "zip" if WINDOWS else "gztar", *os.path.split(out))


def main():
    args = set(sys.argv[1:])
    if args - {"--skip-test", "--hybrid-crt"}:
        sys.exit(__doc__)
    # rustup's folder isn't on every shell's PATH.
    os.environ["PATH"] = os.path.join(os.path.expanduser("~"), ".cargo", "bin") + os.pathsep + os.environ["PATH"]
    if not shutil.which("cargo"):
        fail("cargo not found (rustup)")
    release, name = version(), platform_name()
    dist = os.path.join(HERE, "target", "dist")
    out = os.path.join(dist, f"bakashrot-{release}-{name}")
    for old in (out, out + ".zip", out + ".tar.gz"):
        if os.path.isdir(old):
            shutil.rmtree(old)
        elif os.path.exists(old):
            os.remove(old)
    os.makedirs(out)
    print(f"BakaShrot {release} for {name}, into {out}")
    hybrid = "--hybrid-crt" in args
    wheel = package(build(hybrid), release, name, out, hybrid)
    if "--skip-test" not in args:
        shutil.rmtree(smoke_test(out, wheel))
    print(f"Archive: {archive(out)}")


if __name__ == "__main__":
    main()
