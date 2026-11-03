#!/bin/bash
# The cloud-init user-data that create generates
# shellcheck disable=SC1090,SC2034
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

# user-data as create writes it, to $TMP/user-data
make_user_data() {
    ssh-keygen -q -t ed25519 -N '' -C "host key" -f "$HOSTKEY"
    plan_mounts
    { render "$ROOT/cloud-init/user-data.tmpl"; user_data_extra; } > "$TMP/user-data"
}

# A value from the user-data: python expression on the parsed YAML, d
yaml_get() {
    python3 -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' \
        "$TMP/user-data" "$1"
}

test_user_data() {
    python3 -c 'import yaml' 2> /dev/null || skip "no python3-yaml"
    # A key comment with characters that are special in YAML and in sed replacements
    echo "ssh-ed25519 AAAAC3Nz it's a|b&c\\d #x" > "$TMP/key.pub"
    mkdir .devvm
    echo 'echo provisioned' > .devvm/provision.sh
    . "$DEVVM"
    DEVVM_PACKAGES="git build-essential"
    DEVVM_MOUNTS=source=cache,target=/cache,type=volume
    make_user_data
    assert_not_contains "$(grep -o '@[A-Z_]*@' "$TMP/user-data" || true)" @
    head -1 "$TMP/user-data" | grep -qx '#cloud-config' || fail "no #cloud-config header"
    assert_eq "$(yaml_get 'd["users"][0]["ssh_authorized_keys"][0]')" "$(cat "$TMP/key.pub")" "public key"
    assert_eq "$(yaml_get 'd["users"][0]["name"]')" dev
    # adm: the user reads /var/log, e.g. cloud-init-output.log, without sudo
    assert_eq "$(yaml_get 'sorted(d["users"][0]["groups"])')" "['adm', 'docker', 'sudo']"
    assert_eq "$(yaml_get 'd["packages"]')" "['git', 'build-essential']"
    assert_eq "$(yaml_get 'd["ssh_keys"]["ed25519_public"]')" "$(cat "$HOSTKEY.pub")"
    assert_eq "$(yaml_get 'd["ssh_keys"]["ed25519_private"]')" "$(cat "$HOSTKEY")"
    assert_contains "$(yaml_get 'd["runcmd"]')" /usr/local/lib/devvm/provision.sh
    # The generated guest script is valid bash and sets up the share and the volume
    yaml_get '[f["content"] for f in d["write_files"] if f["path"].endswith("setup.sh")][0]' |
        base64 -d > "$TMP/setup.sh"
    bash -n "$TMP/setup.sh"
    assert_contains "$(cat "$TMP/setup.sh")" "mount_fs devvm-ws /workspaces/repo"
    assert_contains "$(cat "$TMP/setup.sh")" "mount_vol cache /cache"
    yaml_get '[f["content"] for f in d["write_files"] if f["path"].endswith("provision.sh")][0]' |
        base64 -d > "$TMP/provision.sh"
    assert_eq "$(cat "$TMP/provision.sh")" "echo provisioned"
}

test_user_data_schema() {
    command -v cloud-init > /dev/null || skip "no cloud-init"
    . "$DEVVM"
    make_user_data
    cloud-init schema -c "$TMP/user-data" > "$TMP/schema" 2>&1 ||
        fail "cloud-init schema: $(cat "$TMP/schema")"
}

test_invalid_packages() {
    . "$DEVVM"
    DEVVM_PACKAGES='git; rm -rf /'
    assert_fails user_data_extra
    assert_contains "$(cat "$TMP/out")" "Invalid DEVVM_PACKAGES"
}

run_tests
