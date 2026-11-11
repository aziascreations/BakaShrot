# BakaShrot - Python client
Python client for BakaShrot servers, over `BakaShrot_Client.dll`, without dependencies.

The wheel includes the DLLs it needs, nothing else to install or compile. \
Windows 10 or later, 64-bit Python 3.8+.

> [!NOTE]
> The client and the server must come from the same release, any other protocol version refuses the connection.


## Linux
There is no Linux wheel yet.

The Windows wheel bundles `libsodium.dll` next to the client DLL. \
On Linux, libsodium shouldn't be bundled like that, but come from a package instead:
* The distribution's, like the Docker image does (`apt install libsodium23`), the wheel only holding the client's `.so`.
* Or a Python package that provides it, as a dependency of the wheel.

Until then, build the client yourself (see [CLAUDE.md](../../CLAUDE.md)) and point `BAKASHROT_DLL` at it.


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
