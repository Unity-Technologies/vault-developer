#!/usr/bin/dumb-init /bin/sh
set -e

# Note above that we run dumb-init as PID 1 in order to reap zombie processes
# as well as forward signals to all processes in its session. Normally, sh
# wouldn't do either of these functions so we'd leak zombies as well as do
# unclean termination of all our sub-processes.

# Prevent core dumps
ulimit -c 0

rm -f /opt/healthcheck

# Delete any existing vault.env to get a clean start
rm -f /vaultenv/vault.env

VAULT_CONFIG_DIR=/vault/config
VAULT_SECRETS_FILE=${VAULT_SECRETS_FILE:-"/tmp/secrets.json"}

# You can also set the VAULT_LOCAL_CONFIG environment variable to pass some
# Vault configuration JSON without having to bind any volumes.
if [ -n "$VAULT_LOCAL_CONFIG" ]; then
    echo "$VAULT_LOCAL_CONFIG" > "$VAULT_CONFIG_DIR/local.json"
fi

vault server \
        -config="$VAULT_CONFIG_DIR" \
        -dev-root-token-id="${VAULT_DEV_ROOT_TOKEN_ID:-root}" \
        -dev-listen-address="${VAULT_DEV_LISTEN_ADDRESS:-"0.0.0.0:8200"}" \
        -dev "$@" &

# Wait for Vault to come up
sleep 1

# Create a new secrets engine with the name provided in environment var VAULT_SECRETS_ENGINE_NAME if it's set
if [[ -n "${VAULT_SECRETS_ENGINE_NAME}" ]]; then
    vault secrets enable -path="$VAULT_SECRETS_ENGINE_NAME" -version=2 kv
fi

# Add secrets from the secrets.json file to pre-populate vault with some secrets
# If VAULT_SECRETS_ENGINE_NAME has been defined the secrets will be created in that engine rather than default /secret
if [[ -f "$VAULT_SECRETS_FILE" ]]; then
    echo "secrets.json found - writing secrets..."
    if [[ -n "${VAULT_SECRETS_ENGINE_NAME}" ]]; then
        echo "$VAULT_SECRETS_ENGINE_NAME was found"
        vault kv put $VAULT_SECRETS_ENGINE_NAME/project01 "@${VAULT_SECRETS_FILE}"
    else
        vault kv put secret/project01 "@${VAULT_SECRETS_FILE}"
    fi
else
  echo "$VAULT_SECRETS_FILE not found, skipping"
fi

vault auth enable approle

# Write a policy that gives full permission to secret/* as well as an additional secrets engine if specified in $VAULT_SECRETS_ENGINE_NAME
echo "{\"path\":{\"secret/*\":{\"capabilities\":[\"create\",\"read\",\"update\",\"delete\",\"list\",\"sudo\"]},\"$VAULT_SECRETS_ENGINE_NAME/*\":{\"capabilities\":[\"create\",\"read\",\"update\",\"delete\",\"list\",\"sudo\"]}}}" | vault policy write developer -

vault write auth/approle/role/developer \
    secret_id_ttl=60m \
    token_num_uses=100 \
    token_ttl=60m \
    token_max_ttl=120m \
    secret_id_num_uses=80 \
    policies="default,developer"

# Write out the vault URI as well as a roleID and secretID so applications can talk to Vault by reading in the env file.
cat <<EOT >> /vaultenv/vault.env
VAULT_BASE_URI=http://$(hostname -i):8200/v1
VAULT_ROLE_ID=$(vault read -field=role_id auth/approle/role/developer/role-id)
VAULT_SECRET_ID=$(vault write -field=secret_id -f auth/approle/role/developer/secret-id)
EOT

# Docker healthcheck - see Dockerfile for more into
touch /opt/healthcheck

# Block forever so we keep running the vault process
tail -f /dev/null
