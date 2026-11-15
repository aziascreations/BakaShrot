#!/bin/sh
# Smoke-tests a server image, as CI does before pushing it: certificates by
# its bakashrot-cert, its server started with them, its bakashrot pushing
# and reading back over a Docker network, then `docker stop`, which must
# end it cleanly (exit code 0, "stopped").
# Usage: docker/test.sh <image>
set -eu
image=$1
name=bakashrot-test-$$
work=$(mktemp -d)
# The image's user (10001) writes the certificates there.
chmod 777 "$work"

cleanup() {
	docker rm -f -v "$name" >/dev/null 2>&1 || true
	docker network rm "$name" >/dev/null 2>&1 || true
	rm -rf "$work"
}
trap cleanup EXIT
fail() {
	echo "FAILED: $1"
	docker logs "$name" 2>&1 || true
	exit 1
}
tool() {
	docker run --rm -v "$work:/w" -w /w --network "$name" "$image" "$@"
}

docker network create "$name" >/dev/null
tool bakashrot-cert ca --name "Image test CA"
tool bakashrot-cert issue --name server-1 --server
tool bakashrot-cert issue --name tester --role tester
cat >"$work/server.toml" <<EOF
[server]
listen = "0.0.0.0:7000"
ca = "ca.crt"
certificate = "server-1.crt"
key = "server-1.key"
database = "/var/lib/bakashrot/test.sqlite"
topics = ["imagetest"]

[roles.tester]
push_topics = ["imagetest"]
read_topics = ["*"]
EOF
cat >"$work/client.toml" <<EOF
server = "$name:7000"
ca = "ca.crt"
certificate = "tester.crt"
key = "tester.key"
EOF

docker run -d --name "$name" --network "$name" -v "$work:/etc/bakashrot:ro" "$image" >/dev/null
tries=0
until docker logs "$name" 2>&1 | grep -q "listening on"; do
	tries=$((tries + 1))
	[ "$tries" -lt 100 ] || fail "the server isn't listening"
	[ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] || fail "the server exited"
	sleep 0.2
done

tool bakashrot push imagetest '{"image":"test"}' | grep -q "message #1" || fail "push"
tool bakashrot messages imagetest tester | grep -q '"image":"test"' || fail "messages"

docker stop "$name" >/dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "$name")" = 0 ] || fail "the server's exit code"
docker logs "$name" 2>&1 | grep -q "stopped" || fail "no clean stop"
echo "The image: certificates, the server, a push read back, a clean stop: OK"
