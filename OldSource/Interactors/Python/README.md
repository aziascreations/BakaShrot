# BakaShrot - Python client
Python client for BakaShrot servers, over `BakaShrot_Client.dll`, without dependencies.

The wheel includes the DLLs it needs, nothing else to install or compile. \
Windows 10 or later, 64-bit Python 3.8+.

> [!NOTE]
> The client and the server must come from the same release, any other protocol version refuses the connection.


## Linux
The Linux wheel (`bakashrot-<version>-py3-none-linux_x86_64.whl`) holds only the client library,
libsodium comes from the system: `apt install libsodium23` on Debian and Ubuntu. \
Linux x86-64 with glibc 2.34+ (Debian 12, Ubuntu 22.04 or later), 64-bit Python 3.8+.

It's tagged `linux_x86_64`, not `manylinux`: manylinux doesn't allow depending on libsodium,
so it goes on Gitea, not PyPI.

Building it: compile the client in the Docker compiler image (Debian 13, so glibc 2.34 is enough),
named `BakaShrot_Client.dll` as the repository does on Linux, then `make_wheel.py --linux`:
```shell
docker run --rm -v "$PWD":/src:ro -v "$PWD/dist":/out -w /src git.nibblepoker.lu/packages/purebasic:6.41-linux3-trixie-slim \
  sh -c 'apt-get update -qq && apt-get install -y -qq libsodium-dev >/dev/null && pbcompilerc -t --optimizer Client/BakaShrot_Client.pbi -so /out/BakaShrot_Client.dll'
python3 Interactors/Python/make_wheel.py dist dist --linux
```


## Installing
From Gitea:
```shell
pip install --index-url https://git.nibblepoker.lu/api/packages/aziascreations/pypi/simple/ bakashrot
```

From a GitHub release, or a release folder:
```shell
pip install https://github.com/aziascreations/BakaShrot/releases/download/v0.0.1/bakashrot-0.0.1-py3-none-win_amd64.whl
pip install python\bakashrot-0.0.1-py3-none-win_amd64.whl
```

Usage is in [bakashrot.py](bakashrot.py)'s docstring, and in [example.py](example.py).


## Building
`Release.ps1` builds the wheel into `Release\<version>\python\`, and checks it once installed by pip.

By hand, from the DLLs of a release folder or of `Build\`:
```shell
python Interactors/Python/make_wheel.py Release/<version> dist
```

The version comes from `__version__` in [bakashrot.py](bakashrot.py).


## Licenses
The wheel's license is `CC0-1.0 AND ISC`:
* BakaShrot is in the public domain ([CC0](../../LICENSE)).
* The included `libsodium.dll` is under the [ISC license](../../Libs/libsodium/LICENSE),
  whose notice must ship with it: it's in the wheel's `dist-info/licenses/`.

`vcruntime140.dll`, which libsodium needs, isn't included: Python already loads its own.


## Uploading

### Gitea
Requires [twine](https://pypi.org/project/twine/) 6.1+ (for the license metadata), and your Gitea login or an access token with the `write:package` scope.
```shell
pip install twine
twine upload --repository-url https://git.nibblepoker.lu/api/packages/aziascreations/pypi -u aziascreations dist/bakashrot-0.0.1-py3-none-win_amd64.whl
```

### GitHub
GitHub has no Python registry, the wheel is attached to the release instead.

Requires the [GitHub CLI](https://cli.github.com/), logged in with `gh auth login`.
```shell
gh release create v0.0.1 --repo aziascreations/BakaShrot --title "0.0.1" dist/bakashrot-0.0.1-py3-none-win_amd64.whl
```

Or, if the release already exists:
```shell
gh release upload v0.0.1 --repo aziascreations/BakaShrot dist/bakashrot-0.0.1-py3-none-win_amd64.whl
```
