"""Builds the bakashrot wheel: bakashrot.py with the client library it
needs, so that `pip install` is all a Python app needs, nothing to compile.

    python make_wheel.py <BinDir> [OutDir] [--linux]

BinDir holds BakaShrot_Client.dll and libsodium.dll (a release folder, or
Build\\). OutDir defaults to the current directory. Release.ps1 runs it.
Prints the wheel's path.

--linux: the Linux wheel instead, from a Linux build's BakaShrot_Client.dll
(the .so, named as on Windows: bakashrot.py and the tools look for that
name). libsodium isn't in it: it comes from the system (Debian/Ubuntu:
libsodium23), and the wheel needs glibc 2.34+. Tagged linux_x86_64, not
manylinux: manylinux doesn't allow depending on libsodium. Build the .so on
an old enough glibc (the Docker compiler image, Debian 13, needs 2.34).

Licenses: BakaShrot is CC0-1.0, libsodium ISC, which asks for its notice
in every copy: both are in the Windows wheel's dist-info/licenses/ (LICENSE,
and Libs/libsodium/LICENSE), the metadata says "CC0-1.0 AND ISC". The Linux
wheel only has LICENSE, "CC0-1.0", libsodium not being in it.
vcruntime140.dll, which libsodium.dll needs, isn't in the Windows wheel:
every CPython on Windows has loaded its own already, and that's the one used.

The wheel is bakashrot-<version>-py3-none-win_amd64.whl (or
-linux_x86_64.whl), the version being bakashrot.py's __version__. Inside
it, bakashrot.py is bakashrot/__init__.py, the libraries next to it, where
bakashrot.py looks first. Only the standard library: no setuptools, no
build step, and the same inputs give the same wheel (fixed timestamps).
"""

import base64
import hashlib
import os
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))

NAME = "bakashrot"
# Zip entries' timestamp, so the wheel only changes when its content does.
FIXED_TIME = (2026, 1, 1, 0, 0, 0)

USAGE_EXAMPLE = """\
```python
from bakashrot import Client

with Client.from_ini("client.ini") as client:
    message_id = client.push({"temperature": 21.5})
    for message in client.get_messages("logs", "kitchen", after=0).messages:
        print(message.id, message.data)
```

See the module's docstring (`help(bakashrot)`) for the rest.
"""

WINDOWS = {
    "tag": "py3-none-win_amd64",
    "libraries": ["BakaShrot_Client.dll", "libsodium.dll"],
    # In the wheel's dist-info/licenses/, from the repository's root.
    "licenses": {"LICENSE": "LICENSE", "libsodium/LICENSE": "Libs/libsodium/LICENSE"},
    "license_expression": "CC0-1.0 AND ISC",
    "classifier": "Operating System :: Microsoft :: Windows :: Windows 10",
    "summary": "Python client for BakaShrot servers, with the client DLL included",
    "description": """\
# bakashrot

Python client for [BakaShrot](https://github.com/aziascreations/BakaShrot)
servers: push messages and attachments, read them back, resolve names, query.

Includes `BakaShrot_Client.dll` and `libsodium.dll`: nothing else to install
or build. Windows 10 or later, 64-bit Python 3.8+. The server must speak the
same protocol: use the release this package comes from.

BakaShrot is CC0-1.0 (public domain). The included libsodium is Frank
Denis's, under the ISC license: its notice is in this package's
`licenses/libsodium/LICENSE`.

""" + USAGE_EXAMPLE,
}

LINUX = {
    "tag": "py3-none-linux_x86_64",
    "libraries": ["BakaShrot_Client.dll"],
    "licenses": {"LICENSE": "LICENSE"},
    "license_expression": "CC0-1.0",
    "classifier": "Operating System :: POSIX :: Linux",
    "summary": "Python client for BakaShrot servers, with the client library included",
    "description": """\
# bakashrot

Python client for [BakaShrot](https://github.com/aziascreations/BakaShrot)
servers: push messages and attachments, read them back, resolve names, query.

Includes the client library (`BakaShrot_Client.dll`, a Linux shared object
named as on Windows). Needs libsodium from the system, nothing else to build:
`apt install libsodium23` on Debian and Ubuntu. Linux x86-64 with glibc 2.34+
(Debian 12, Ubuntu 22.04 or later), 64-bit Python 3.8+. The server must speak
the same protocol: use the release this package comes from.

BakaShrot is CC0-1.0 (public domain).

""" + USAGE_EXAMPLE,
}


def read_version(module_path):
    with open(module_path, encoding="utf-8") as file:
        match = re.search(r'^__version__ = "([^"]+)"', file.read(), re.MULTILINE)
    if not match:
        sys.exit(f"No __version__ in {module_path}")
    return match.group(1)


def record_line(path, data):
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode("ascii")
    return f"{path},sha256={digest},{len(data)}"


def main():
    args = sys.argv[1:]
    platform = WINDOWS
    if "--linux" in args:
        args.remove("--linux")
        platform = LINUX
    if len(args) not in (1, 2):
        sys.exit(__doc__)
    bin_dir = args[0]
    out_dir = args[1] if len(args) == 2 else os.getcwd()
    tag = platform["tag"]

    module_path = os.path.join(HERE, "bakashrot.py")
    version = read_version(module_path)
    dist_info = f"{NAME}-{version}.dist-info"

    files = []  # (path in the wheel, bytes)
    with open(module_path, "rb") as file:
        files.append((f"{NAME}/__init__.py", file.read()))
    for library in platform["libraries"]:
        path = os.path.join(bin_dir, library)
        if not os.path.isfile(path):
            sys.exit(f"Missing {path}")
        with open(path, "rb") as file:
            data = file.read()
        # A Windows DLL starts with "MZ", a Linux .so with "\x7fELF": a
        # library from the other platform would only fail once imported.
        if platform is LINUX and not data.startswith(b"\x7fELF"):
            sys.exit(f"{path} isn't a Linux shared object (build it on Linux, or drop --linux)")
        if platform is WINDOWS and data.startswith(b"\x7fELF"):
            sys.exit(f"{path} is a Linux shared object (add --linux)")
        files.append((f"{NAME}/{library}", data))

    # Metadata 2.4 (PEP 639): an SPDX expression and the license files,
    # without license classifiers (not allowed with an expression).
    metadata = "\n".join([
        "Metadata-Version: 2.4",
        f"Name: {NAME}",
        f"Version: {version}",
        f"Summary: {platform['summary']}",
        "Author: Herwin Bozet (NibblePoker)",
        f"License-Expression: {platform['license_expression']}",
    ] + [f"License-File: {name}" for name in platform["licenses"]] + [
        "Project-URL: GitHub, https://github.com/aziascreations/BakaShrot",
        "Project-URL: Gitea, https://git.nibblepoker.lu/aziascreations/BakaShrot",
        f"Classifier: {platform['classifier']}",
        "Classifier: Programming Language :: Python :: 3",
        "Requires-Python: >=3.8",
        "Description-Content-Type: text/markdown",
        "",
        platform["description"],
    ]).encode("utf-8")
    files.append((f"{dist_info}/METADATA", metadata))
    files.append((f"{dist_info}/WHEEL", "\n".join([
        "Wheel-Version: 1.0",
        "Generator: BakaShrot make_wheel.py",
        "Root-Is-Purelib: false",
        f"Tag: {tag}",
        "",
    ]).encode("utf-8")))
    for name, source in platform["licenses"].items():
        path = os.path.join(ROOT, source)
        if not os.path.isfile(path):
            sys.exit(f"Missing {path}")
        with open(path, "rb") as file:
            files.append((f"{dist_info}/licenses/{name}", file.read()))

    record = "\n".join([record_line(path, data) for path, data in files] + [f"{dist_info}/RECORD,,", ""])
    files.append((f"{dist_info}/RECORD", record.encode("utf-8")))

    os.makedirs(out_dir, exist_ok=True)
    wheel_path = os.path.join(out_dir, f"{NAME}-{version}-{tag}.whl")
    with zipfile.ZipFile(wheel_path, "w", zipfile.ZIP_DEFLATED) as wheel:
        for path, data in files:
            info = zipfile.ZipInfo(path, FIXED_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            # The shared object must stay executable for some loaders.
            info.external_attr = (0o755 if path.endswith(".dll") and platform is LINUX else 0o644) << 16
            wheel.writestr(info, data)
    print(wheel_path)


if __name__ == "__main__":
    main()
