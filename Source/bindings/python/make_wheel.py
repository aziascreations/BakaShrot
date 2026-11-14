"""Builds the bakashrot wheel: bakashrot.py with the client library in it,
so `pip install` is all a Python app needs, nothing to compile.

    python make_wheel.py <library> <out_dir> [license files...]

<library> is bakashrot.dll (Windows x64) or libbakashrot.so (Linux x86-64),
from `cargo build --release`; the license files go in the wheel's
dist-info/licenses/ (release.py gives LICENSE and THIRD-PARTY.txt). Prints
the wheel's path.

The wheel is bakashrot-<version>-py3-none-<platform>.whl, the version
being bakashrot.py's __version__ (release.py checks it's the workspace's):
win_amd64, or manylinux_<glibc>_x86_64 with the glibc it was built
against (a Rust library only needs libc, libm and libgcc_s, which
manylinux allows). Inside, bakashrot.py is bakashrot/__init__.py with the
library next to it, where it looks first. Only the standard library, and
the same inputs give the same wheel (fixed timestamps).
"""

import base64
import hashlib
import os
import platform
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
NAME = "bakashrot"
# Zip entries' timestamp, so the wheel only changes when its content does.
FIXED_TIME = (2026, 1, 1, 0, 0, 0)

DESCRIPTION = """\
# bakashrot

Python client for [BakaShrot](https://github.com/aziascreations/BakaShrot)
servers: push messages and attachments, read them back, list names, query.

The client library is included: nothing else to install or build. 64-bit
Python 3.8+ (`Client.from_file()` needs 3.11+). The server must speak the
same protocol: use the release this package comes from.

```python
from bakashrot import Client

with Client.from_file("client.toml") as client:
    message_id = client.push({"temperature": 21.5}, "logs")
    for message in client.get_messages("logs", "kitchen", after=0).messages:
        print(message.id, message.data)
```

See the module's docstring (`help(bakashrot)`) for the rest.
"""


def version():
    with open(os.path.join(HERE, "bakashrot.py"), encoding="utf-8") as file:
        match = re.search(r'^__version__ = "([^"]+)"', file.read(), re.MULTILINE)
    if not match:
        sys.exit("No __version__ in bakashrot.py")
    return match.group(1)


def platform_tag(library):
    """The wheel's platform, from the library's kind."""
    with open(library, "rb") as file:
        magic = file.read(4)
    if magic[:2] == b"MZ":
        return "win_amd64", "Operating System :: Microsoft :: Windows"
    if magic == b"\x7fELF":
        libc, glibc = platform.libc_ver()
        if libc != "glibc":
            sys.exit("Built against another libc than glibc: no manylinux tag")
        major, minor = glibc.split(".")[:2]
        return f"manylinux_{major}_{minor}_x86_64", "Operating System :: POSIX :: Linux"
    sys.exit(f"{library}: neither a Windows DLL nor a Linux shared object")


def record_line(path, data):
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode("ascii")
    return f"{path},sha256={digest},{len(data)}"


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    library, out_dir, licenses = sys.argv[1], sys.argv[2], sys.argv[3:]
    tag, classifier = platform_tag(library)
    tag = f"py3-none-{tag}"
    dist_info = f"{NAME}-{version()}.dist-info"

    def read(path):
        with open(path, "rb") as file:
            return file.read()

    files = [
        (f"{NAME}/__init__.py", read(os.path.join(HERE, "bakashrot.py"))),
        (f"{NAME}/{os.path.basename(library)}", read(library)),
    ]
    # Metadata 2.4 (PEP 639): the license files, no expression (the
    # library bundles its dependencies' code, THIRD-PARTY.txt lists them).
    metadata = "\n".join([
        "Metadata-Version: 2.4",
        f"Name: {NAME}",
        f"Version: {version()}",
        "Summary: Python client for BakaShrot servers, with the client library included",
        "Author: Herwin Bozet (NibblePoker)",
    ] + [f"License-File: {os.path.basename(path)}" for path in licenses] + [
        "Project-URL: GitHub, https://github.com/aziascreations/BakaShrot",
        f"Classifier: {classifier}",
        "Classifier: Programming Language :: Python :: 3",
        "Requires-Python: >=3.8",
        "Description-Content-Type: text/markdown",
        "",
        DESCRIPTION,
    ])
    files.append((f"{dist_info}/METADATA", metadata.encode("utf-8")))
    wheel = f"Wheel-Version: 1.0\nGenerator: BakaShrot make_wheel.py\nRoot-Is-Purelib: false\nTag: {tag}\n"
    files.append((f"{dist_info}/WHEEL", wheel.encode("utf-8")))
    for path in licenses:
        files.append((f"{dist_info}/licenses/{os.path.basename(path)}", read(path)))
    record = [record_line(path, data) for path, data in files] + [f"{dist_info}/RECORD,,", ""]
    files.append((f"{dist_info}/RECORD", "\n".join(record).encode("utf-8")))

    os.makedirs(out_dir, exist_ok=True)
    wheel_path = os.path.join(out_dir, f"{NAME}-{version()}-{tag}.whl")
    with zipfile.ZipFile(wheel_path, "w", zipfile.ZIP_DEFLATED) as archive:
        for path, data in files:
            info = zipfile.ZipInfo(path, FIXED_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o755 if path.endswith(".so") else 0o644) << 16
            archive.writestr(info, data)
    print(wheel_path)


if __name__ == "__main__":
    main()
