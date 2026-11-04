#!/bin/bash
# Source on a trusted Actions runner; do not print credential values.
: "${DEPLOY_HOST:?}" "${DEPLOY_USER:?}" "${DEPLOY_SSH_KEY:?}" "${DEPLOY_KNOWN_HOSTS:?}"
ssh_dir="${RUNNER_TEMP:?}/mint-ssh"
install -m 700 -d "$ssh_dir"
printf '%s\n' "$DEPLOY_SSH_KEY" > "$ssh_dir/key"
chmod 600 "$ssh_dir/key"
printf '%s\n' "$DEPLOY_KNOWN_HOSTS" > "$ssh_dir/known_hosts"
SSH=(ssh -T -i "$ssh_dir/key" -o BatchMode=yes -o StrictHostKeyChecking=yes
 -o "UserKnownHostsFile=$ssh_dir/known_hosts" -o ConnectTimeout=15
 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
REMOTE="$DEPLOY_USER@$DEPLOY_HOST"
