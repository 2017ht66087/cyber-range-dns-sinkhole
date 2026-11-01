#!/bin/sh
# Thin Samba AD DC for the corp lab.
#   DC_ROLE=primary  -> provision the domain on first start and seed demo users
#   DC_ROLE=replica  -> join JOIN_SERVER as an additional DC on first start
# State lives in /var/lib/samba (PVC), so restarts keep the domain and replication.
set -eu

REALM="${REALM:-CORP.LAB}"
DOMAIN="${DOMAIN:-CORP}"
DC_ROLE="${DC_ROLE:-primary}"
DC_NAME="${DC_NAME:-$(hostname -s)}"
DNS_FORWARDER="${DNS_FORWARDER:-10.43.0.10}"
JOIN_SERVER="${JOIN_SERVER:-dc01.corp.lab}"
STATE=/var/lib/samba
CONF_COPY="$STATE/smb.conf.persist"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD must be set (from the corp-credentials Secret)}"

log() { echo "[corp-samba-dc:$DC_NAME] $*"; }
realm_lc="$(echo "$REALM" | tr 'A-Z' 'a-z')"

: "${SERVICE_IP:?SERVICE_IP must be set (the DC's fixed Service ClusterIP)}"

# Low-memory defaults: one worker per prefork service, no printing.
# xattr_tdb keeps NT ACLs in a tdb so the pod doesn't need CAP_SYS_ADMIN
# (security.* xattrs are not writable in an unprivileged container).
# Pod IPs change on restart, so the DC registers its fixed Service ClusterIP in
# DNS and pins DCE/RPC (DRS replication, netlogon) to ports the Service exposes.
COMMON_OPTS="--option=dns forwarder = $DNS_FORWARDER
--option=dns update command = /usr/sbin/samba_dnsupdate --current-ip=$SERVICE_IP
--option=rpc server port = 49152
--option=rpc server port:netlogon = 49153
--option=vfs objects = dfs_samba4 acl_xattr xattr_tdb
--option=xattr_tdb:file = $STATE/private/xattr.tdb
--option=prefork children = 1
--option=load printers = no
--option=printing = bsd
--option=printcap name = /dev/null
--option=disable spoolss = yes
--option=log level = 1"

run_tool() {
  # samba-tool with the common options split on newlines (values contain spaces).
  OLDIFS="$IFS"; IFS='
'
  # shellcheck disable=SC2086
  set -- "$@" $COMMON_OPTS
  IFS="$OLDIFS"
  samba-tool "$@"
}

mkuser() {
  # Positional passwords break when they start with '-', so set it via --newpassword=.
  name="$1"; pw="$2"; shift 2
  samba-tool user create "$name" --random-password "$@" >/dev/null || return 0
  samba-tool user setpassword "$name" --newpassword="$pw" >/dev/null
  log "user $name created"
}

seed_users() {
  log "seeding demo groups/users"
  samba-tool group add IT-Admins   --description="Corp IT administrators" || true
  samba-tool group add Finance     --description="Finance department" || true
  samba-tool group add SQL-Service --description="Database service accounts" || true

  mkuser alice "$ALICE_PASSWORD" --given-name=Alice --surname=Anders \
    --department=IT --job-title="Systems Administrator" --mail-address="alice@$realm_lc"
  mkuser bob "$BOB_PASSWORD" --given-name=Bob --surname=Brown \
    --department=Finance --job-title="Accountant" --mail-address="bob@$realm_lc"
  mkuser svc-sql "$SVC_SQL_PASSWORD" --description="db01 PostgreSQL service account"
  samba-tool user setexpiry svc-sql --noexpiry || true
  # Service principal on a user account = a classic Kerberoasting target.
  samba-tool spn add "postgres/db01.$realm_lc" svc-sql || true
  mkuser da-test "$DA_TEST_PASSWORD" --description="Domain Admins test account"

  samba-tool group addmembers IT-Admins alice || true
  samba-tool group addmembers Finance bob || true
  samba-tool group addmembers SQL-Service svc-sql || true
  samba-tool group addmembers "Domain Admins" da-test || true
}

if [ ! -f "$STATE/private/sam.ldb" ]; then
  rm -f /etc/samba/smb.conf
  if [ "$DC_ROLE" = "primary" ]; then
    : "${ALICE_PASSWORD:?}" "${BOB_PASSWORD:?}" "${SVC_SQL_PASSWORD:?}" "${DA_TEST_PASSWORD:?}"
    log "provisioning new domain $REALM ($DOMAIN)"
    run_tool domain provision --server-role=dc --use-rfc2307 --dns-backend=SAMBA_INTERNAL \
      --realm="$REALM" --domain="$DOMAIN" --host-name="$DC_NAME" --host-ip="$SERVICE_IP" \
      --adminpass="$ADMIN_PASSWORD"
    seed_users
  else
    log "waiting for $JOIN_SERVER to answer LDAP/DNS ..."
    i=0
    until host -t SRV "_ldap._tcp.$realm_lc" >/dev/null 2>&1 && \
          ldapsearch -x -H "ldap://$JOIN_SERVER" -s base -b "" defaultNamingContext >/dev/null 2>&1; do
      i=$((i + 1)); [ "$i" -gt 120 ] && { log "primary DC not reachable"; exit 1; }
      sleep 5
    done
    log "joining $REALM as additional DC via $JOIN_SERVER"
    run_tool domain join "$realm_lc" DC --server="$JOIN_SERVER" --dns-backend=SAMBA_INTERNAL \
      -U "$DOMAIN\\Administrator" --password="$ADMIN_PASSWORD"
  fi
  cp /etc/samba/smb.conf "$CONF_COPY"
else
  log "existing domain state found, starting"
  cp "$CONF_COPY" /etc/samba/smb.conf
fi

cp "$STATE/private/krb5.conf" /etc/krb5.conf

# Once samba is up, drop any A record for this DC that is not SERVICE_IP
# (the join registers the then-current pod IP, which goes stale on restart).
(
  i=0
  until samba-tool dns query 127.0.0.1 "$realm_lc" "$DC_NAME" A -P >/tmp/a.txt 2>/dev/null; do
    i=$((i + 1)); [ "$i" -gt 60 ] && exit 0; sleep 5
  done
  for ip in $(sed -n 's/.*A: \([0-9.]*\).*/\1/p' /tmp/a.txt); do
    [ "$ip" = "$SERVICE_IP" ] && continue
    samba-tool dns delete 127.0.0.1 "$realm_lc" "$DC_NAME" A "$ip" -P >/dev/null 2>&1 && \
      log "removed stale DNS A record $DC_NAME -> $ip"
  done
) &

log "starting samba"
exec samba --foreground --no-process-group --debug-stdout
