"""Builds the bakashrot wheel: bakashrot.py with the DLLs it needs, so that
`pip install` is all a Python app needs, nothing to compile.

    python make_wheel.py <BinDir> [OutDir]

BinDir holds BakaShrot_Client.dll and libsodium.dll (a release folder, or
Build\\). OutDir defaults to the current directory. Release.ps1 runs it.
Prints the wheel's path.

Licenses: BakaShrot is CC0-1.0, libsodium ISC, which asks for its notice
in every copy: both are in the wheel's dist-info/licenses/ (LICENSE, and
Libs/libsodium/LICENSE), the metadata says "CC0-1.0 AND ISC".
vcruntime140.dll, which libsodium.dll needs, isn't in it: every CPython on
Windows has loaded its own already, and that's the one used.

The wheel is bakashrot-<version>-py3-none-win_amd64.whl, the version being
bakashrot.py's __version__. Inside it, bakashrot.py is bakashrot/__init__.py,
the DLLs next to it, where bakashrot.py looks first. Only the standard
library: no setuptools, no build step, and the same inputs give the same
wheel (fixed timestamps).
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
TAG = "py3-none-win_amd64"
DLLS = ["BakaShrot_Client.dll", "libsodium.dll"]
# In the wheel's dist-info/licenses/, from the repository's root.
LICENSES = {"LICENSE": "LICENSE", "libsodium/LICENSE": "Libs/libsodium/LICENSE"}
LICENSE_EXPRESSION = "CC0-1.0 AND ISC"
# Zip entries' timestamp, so the wheel only changes when its content does.
FIXED_TIME = (2026, 1, 1, 0, 0, 0)

SUMMARY = "Python client for BakaShrot servers, with the client DLL included"
DESCRIPTION = """\
# bakashrot

Python client for [BakaShrot](https://github.com/aziascreations/BakaShrot)
servers: push messages and attachments, read them back, resolve names, query.

Includes `BakaShrot_Client.dll` and `libsodium.dll`: nothing else to install
or build. Windows 10 or later, 64-bit Python 3.8+. The server must speak the
same protocol: use the release this package comes from.

BakaShrot is CC0-1.0 (public domain). The included libsodium is Frank
Denis's, under the ISC license: its notice is in this package's
`licenses/libsodium/LICENSE`.

```python
from bakashrot import Client

with Client.from_ini("client.ini") as client:
    message_id = client.push({"temperature": 21.5})
    for message in client.get_messages("logs", "kitchen", after=0).messages:
        print(message.id, message.data)
```

See the module's docstring (`help(bakashrot)`) for the rest.
"""


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
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    bin_dir = sys.argv[1]
    out_dir = sys.argv[2] if len(sys.argv) == 3 else os.getcwd()

    module_path = os.path.join(HERE, "bakashrot.py")
    version = read_version(module_path)
    dist_info = f"{NAME}-{version}.dist-info"

    files = []  # (path in the wheel, bytes)
    with open(module_path, "rb") as file:
        files.append((f"{NAME}/__init__.py", file.read()))
    for dll in DLLS:
        path = os.path.join(bin_dir, dll)
        if not os.path.isfile(path):
            sys.exit(f"Missing {path}")
        with open(path, "rb") as file:
            files.append((f"{NAME}/{dll}", file.read()))

    # Metadata 2.4 (PEP 639): an SPDX expression and the license files,
    # without license classifiers (not allowed with an expression).
    metadata = "\n".join([
        "Metadata-Version: 2.4",
        f"Name: {NAME}",
        f"Version: {version}",
        f"Summary: {SUMMARY}",
        "Author: Herwin Bozet (NibblePoker)",
        f"License-Expression: {LICENSE_EXPRESSION}",
    ] + [f"License-File: {name}" for name in LICENSES] + [
        "Project-URL: GitHub, https://github.com/aziascreations/BakaShrot",
        "Project-URL: Gitea, https://git.nibblepoker.lu/aziascreations/BakaShrot",
        "Classifier: Operating System :: Microsoft :: Windows :: Windows 10",
        "Classifier: Programming Language :: Python :: 3",
        "Requires-Python: >=3.8",
        "Description-Content-Type: text/markdown",
        "",
        DESCRIPTION,
    ]).encode("utf-8")
    files.append((f"{dist_info}/METADATA", metadata))
    files.append((f"{dist_info}/WHEEL", "\n".join([
        "Wheel-Version: 1.0",
        "Generator: BakaShrot make_wheel.py",
        "Root-Is-Purelib: false",
        f"Tag: {TAG}",
        "",
    ]).encode("utf-8")))
    for name, source in LICENSES.items():
        path = os.path.join(ROOT, source)
        if not os.path.isfile(path):
            sys.exit(f"Missing {path}")
        with open(path, "rb") as file:
            files.append((f"{dist_info}/licenses/{name}", file.read()))

    record = "\n".join([record_line(path, data) for path, data in files] + [f"{dist_info}/RECORD,,", ""])
    files.append((f"{dist_info}/RECORD", record.encode("utf-8")))

    os.makedirs(out_dir, exist_ok=True)
    wheel_path = os.path.join(out_dir, f"{NAME}-{version}-{TAG}.whl")
    with zipfile.ZipFile(wheel_path, "w", zipfile.ZIP_DEFLATED) as wheel:
        for path, data in files:
            info = zipfile.ZipInfo(path, FIXED_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            wheel.writestr(info, data)
    print(wheel_path)


if __name__ == "__main__":
    main()
