# BakaShrot - Docker
Docker image for the server, built on the PureBasic images from `git.nibblepoker.lu`.

> [!NOTE]
> The PureBasic images are licensed, building requires a login to their registry. \
> The final image only holds the compiled server, libsodium and SQLite.


## Running
Fill in [Server/server.ini](Server/server.ini), then, from `Docker/Server/`:
```shell
docker compose up -d --build
```

See [Server/docker-compose.yml](Server/docker-compose.yml) and the [Dockerfile](Server/Dockerfile) for more.


## Building
From the repository's root:
```shell
git submodule update --init --recursive
docker login git.nibblepoker.lu
docker build -t bakashrot-server -f Docker/Server/Dockerfile .
```


## Uploading
Tag and push the image to both registries, with the version and as `latest`:

### Gitea
```shell
docker login git.nibblepoker.lu
docker tag bakashrot-server git.nibblepoker.lu/aziascreations/bakashrot-server:0.0.1
docker tag bakashrot-server git.nibblepoker.lu/aziascreations/bakashrot-server:latest
docker push git.nibblepoker.lu/aziascreations/bakashrot-server:0.0.1
docker push git.nibblepoker.lu/aziascreations/bakashrot-server:latest
```

### GitHub
Requires a [personal access token](https://github.com/settings/tokens) with the `write:packages` scope as the password.
```shell
docker login ghcr.io -u aziascreations
docker tag bakashrot-server ghcr.io/aziascreations/bakashrot-server:0.0.1
docker tag bakashrot-server ghcr.io/aziascreations/bakashrot-server:latest
docker push ghcr.io/aziascreations/bakashrot-server:0.0.1
docker push ghcr.io/aziascreations/bakashrot-server:latest
```

The package then has to be linked to the repository, and made public if needed, in its settings on GitHub.
