#!/bin/bash

set -o errexit
set -o xtrace

LIB_PATH='/usr/lib/pxc'
. ${LIB_PATH}/check-version.sh
. ${LIB_PATH}/vault.sh

INSECURE_ARG=""
if [ -n "$VERIFY_TLS" ] && [[ $VERIFY_TLS == "false" ]]; then
  INSECURE_ARG="--insecure"
fi

{ set +x; } 2>/dev/null
echo "+ mc -C /tmp/mc ${INSECURE_ARG} config host add dest "${ENDPOINT:-https://s3.amazonaws.com}" ACCESS_KEY_ID SECRET_ACCESS_KEY"
mc -C /tmp/mc ${INSECURE_ARG} config host add dest "${ENDPOINT:-https://s3.amazonaws.com}" "$ACCESS_KEY_ID" "$SECRET_ACCESS_KEY"
set -x
mc -C /tmp/mc ${INSECURE_ARG} ls "dest/${S3_BUCKET_URL}"

rm -rf /datadir/*
tmp=$(mktemp --directory /datadir/pxc_sst_XXXX)
xbcloud get "s3://${S3_BUCKET_URL}.sst_info" --parallel=10 ${INSECURE_ARG} | xbstream -x -C $tmp --parallel=$(grep -c processor /proc/cpuinfo)
xbcloud get "s3://${S3_BUCKET_URL}" --parallel=10 ${INSECURE_ARG} | xbstream -x -C $tmp --parallel=$(grep -c processor /proc/cpuinfo)

set +o xtrace
transition_key=$(vault_get $tmp/sst_info)
if [[ -n $transition_key && $transition_key != null ]]; then
    MYSQL_VERSION=$(parse_ini 'mysql-version' "$tmp/sst_info")
    if ! check_for_version "$MYSQL_VERSION" '5.7.29' &&
        [[ $MYSQL_VERSION != '5.7.28-31-57.2' ]]; then
         transition_key="\$transition_key"
    fi

    transition_option="--transition-key=$transition_key"
    master_key_options="--generate-new-master-key"
    echo transition-key exists
fi

echo "+ xtrabackup ${XB_USE_MEMORY+--use-memory=$XB_USE_MEMORY} --prepare --binlog-info=ON --rollback-prepared-trx \
    --xtrabackup-plugin-dir=/usr/lib64/xtrabackup/plugin --target-dir=$tmp"

innobackupex ${XB_USE_MEMORY+--use-memory=$XB_USE_MEMORY}  --parallel=$(grep -c processor /proc/cpuinfo) --decompress $tmp
xtrabackup ${XB_USE_MEMORY+--use-memory=$XB_USE_MEMORY} --prepare --binlog-info=ON $transition_option --rollback-prepared-trx \
    --xtrabackup-plugin-dir=/usr/lib64/xtrabackup/plugin --target-dir=$tmp

echo "+ xtrabackup --defaults-group=mysqld --datadir=/datadir --move-back --binlog-info=ON \
    --force-non-empty-directories $master_key_options \
    --keyring-vault-config=/etc/mysql/vault-keyring-secret/keyring_vault.conf --early-plugin-load=keyring_vault.so \
    --xtrabackup-plugin-dir=/usr/lib64/xtrabackup/plugin --target-dir=$tmp"

xtrabackup --defaults-group=mysqld --datadir=/datadir --move-back --binlog-info=ON \
    --force-non-empty-directories $transition_option $master_key_options \
    --keyring-vault-config=/etc/mysql/vault-keyring-secret/keyring_vault.conf --early-plugin-load=keyring_vault.so \
    --xtrabackup-plugin-dir=/usr/lib64/xtrabackup/plugin --target-dir=$tmp

rm -rf $tmp

