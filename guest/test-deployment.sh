#!/bin/bash
# Runs inside the VM (piped in by devvm.sh test-deploy): check out a commit, create
# throwaway secrets and test folders, build and start the test deployment, and wait
# until all containers run and Nextcloud answers.
# Usage: test-deployment.sh REPO_DIR COMMIT [--clean]
set -euo pipefail

REPO=$HOME/$1
COMMIT=$2
CLEAN=${3:-}
SECRETS=/var/local/data-mgmt
CA_IMAGE=iffregistry.fz-juelich.de/weber/data-management-system/ca:latest

cd "$REPO"
git checkout -q --detach "$COMMIT"
git submodule update --init || echo "Warning: not all submodules could be fetched" >&2
cd deploy

if [ "$CLEAN" = --clean ]; then
    docker compose down --volumes --remove-orphans
    (cd testfolder && sudo ./nukefolders.sh)
    sudo rm -rf "$SECRETS"
fi

# Throwaway secrets, only created if missing. Not suitable for production.
sudo install -d -m 755 "$SECRETS"
put() {
    local path=$SECRETS/$1
    if sudo test -e "$path"; then
        cat > /dev/null
    else
        sudo tee "$path" > /dev/null
        sudo chmod "$2" "$path"
    fi
}
random() { head -c 32 /dev/urandom | base64; }

put mgmt_secret.py 644 <<< "SECRET_KEY = '$(random)'"
put modama_session_secret 644 <<< "$(random)"
put externalstorage_pw 644 <<< "$(random)"
put nextcloud-config-secret.json 644 <<< '{"system": {}}'
# No LDAP in the VM: sssd serves the accounts of its own container, logins are not tested
put sssd.conf 600 <<'EOF'
[sssd]
services = nss, pam
domains = local

[domain/local]
id_provider = proxy
proxy_lib_name = files
auth_provider = none
EOF

if ! sudo test -e "$SECRETS/CA/ca"; then
    docker build -f ../modama-rs/Dockerfile-ca-cli ../modama-rs/ -t "$CA_IMAGE"
    ca() { docker run --rm -v "$SECRETS/CA/:/certs/" "$CA_IMAGE" --ca-path=/certs/ --insecure-no-password "$@"; }
    ca initialize-ca
    ca enroll-server smbdrop smbdrop
fi

(cd testfolder && sudo ./preparefolders.sh)

docker compose build
# Returns once every container runs (and passes its healthcheck, where the image has one)
if ! docker compose up --wait --wait-timeout 900; then
    docker compose ps --all
    echo "Not all containers came up" >&2
    exit 1
fi
# Nextcloud installs itself on the first start, which takes a few minutes; status.php
# answers through cloudproxy's published port once that is done
for _ in $(seq 60); do
    if curl -fsS -o /dev/null http://127.0.0.1:1890/nextcloud/status.php; then
        docker compose ps
        echo "Test deployment is up"
        exit 0
    fi
    sleep 10
done
docker compose ps --all
docker compose logs --tail=50 nextcloud
echo "Nextcloud did not come up" >&2
exit 1
