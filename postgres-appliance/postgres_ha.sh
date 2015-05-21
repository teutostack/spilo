#!/bin/bash

PATH=$PATH:/usr/lib/postgresql/${PGVERSION}/bin
WALE_ENV_DIR=/home/postgres/etc/wal-e.d/env

SSL_CERTIFICATE="/home/postgres/dummy.crt"
SSL_PRIVATE_KEY="/home/postgres/dummy.key"
BACKUP_INTERVAL=3600

function write_postgres_yaml
{
  aws_private_ip=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
  cat >> postgres.yml <<__EOF__
loop_wait: 10
etcd:
  scope: $SCOPE
  ttl: 30
  host: 127.0.0.1:2379
postgresql:
  name: postgresql_${HOSTNAME}
  listen: 0.0.0.0:5432
  connect_address: ${aws_private_ip}:5432
  data_dir: $PGDATA
  replication:
    username: standby
    password: standby
    network: 0.0.0.0/0
  superuser:
    password: zalando
  admin:
    username: admin
    password: admin
  wal_e:
    env_dir: $WALE_ENV_DIR
    threshold_megabytes: ${WALE_BACKUP_THRESHOLD_MEGABYTES}
    threshold_backup_size_percentage: ${WALE_BACKUP_THRESHOLD_PERCENTAGE}
  parameters:
    archive_mode: "on"
    wal_level: hot_standby
    archive_command: "envdir ${WALE_ENV_DIR} wal-e --aws-instance-profile wal-push \"%p\" -p 1"
    max_wal_senders: 5
    wal_keep_segments: 8
    archive_timeout: 1800s
    max_replication_slots: 5
    hot_standby: "on"
    ssl: "on"
    ssl_cert_file: "/home/postgres/dummy.crt"
    ssl_key_file: "/home/postgres/dummy.key"
  recovery_conf:
    restore_command: "envdir ${WALE_ENV_DIR} wal-e --aws-instance-profile wal-fetch \"%f\" \"%p\" -p 1"
__EOF__
}

function write_archive_command_environment
{
  mkdir -p ${WALE_ENV_DIR}
  echo "s3://${WAL_S3_BUCKET}/spilo/${SCOPE}/wal/" > ${WALE_ENV_DIR}/WALE_S3_PREFIX
}

# get governor code
git clone https://github.com/zalando/governor.git

write_postgres_yaml

write_archive_command_environment

# start etcd proxy
# for the -proxy on TDB the url of the etcd cluster
[ "$DEBUG" -eq 1 ] && exec /bin/bash

# resurrect etcd if it's gone
(
  while true
  do
    etcd -name "proxy-$SCOPE" -proxy on  --data-dir=etcd -discovery-srv $ETCD_DISCOVERY_URL
  done
) &

# run wal-e s3 backup periodically
# XXX: for debugging purposes, it's running every 5 minutes
(
  INITIAL=1
  RETRY=0
  LAST_BACKUP_TS=0
  while true
  do
    sleep 5

    CURRENT_TS=$(date +%s)
    CURRENT_HOUR=$(date +%H)
    pg_isready >/dev/null 2>&2 || continue
    IN_RECOVERY=$(psql -tqAc "select pg_is_in_recovery()")

    [[ $IN_RECOVERY != "f" ]] && echo "still in recovery" && continue
    # during initial run, count the number of backup lines. If there are
    # no backup (only line with backup-list header is returned), or there
    # is an error, try to produce a backup. Otherwise, stick to the regular
    # schedule, since we might run the backups on a freshly promoted replica.
    if [[ $INITIAL = 1 ]]
    then
      BACKUPS_LINES=$(envdir ${WALE_ENV_DIR} wal-e --aws-instance-profile  backup-list 2>/dev/null|wc -l)
      [[ $PIPESTATUS[0] = 0 ]] && [[ $BACKUPS_LINES -ge 2 ]] && INITIAL=0
    fi
    # produce backup only at a given hour, unless it's set to *, which means
    # that only backup_interval is taken into account. We also skip all checks
    # when the backup is forced because of previous attempt's failure or because
    # it's going to be a very first backup, in which case we create it unconditionally.
    if [[ $RETRY = 0 ]] && [[ $INITIAL = 0 ]]
    then
      # check that enough time has passed since the previous backup
      [[ $BACKUP_HOUR != '*' ]] && [[ $CURRENT_HOUR != $BACKUP_HOUR ]] && continue
      # get the time since the last backup. Do it only one when the hour
      # matches the backup hour.
      [[ $LAST_BACKUP_TS = 0 ]] && LAST_BACKUP_TS=$(envdir ${WALE_ENV_DIR} wal-e --aws-instance-profile  backup-list LATEST 2>/dev/null | tail -n1 | awk '{print $2}' | xargs date +%s --date)
      # LAST_BACKUP_TS will be empty on error.
      if [[ -z $LAST_BACKUP_TS ]]
      then
        LAST_BACKUP_TS=0
        echo "could not obtain latest backup timestamp"
      fi

      ELAPSED_TIME=$((CURRENT_TS-LAST_BACKUP_TS))
      [[ $ELAPSED_TIME -lt $BACKUP_INTERVAL ]] && continue
    fi
    # leave only 2 base backups before creating a new one
    envdir ${WALE_ENV_DIR} wal-e --aws-instance-profile delete --confirm retain 2
    # push a new base backup
    echo "producing a new backup at $(date)"
    envdir ${WALE_ENV_DIR} wal-e --aws-instance-profile backup-push ${PGDATA}
    RETRY=$?
    # re-examine last backup timestamp if a new backup has been created
    if [[ $RETRY = 0 ]]
    then
      INITIAL=0
      LAST_BACKUP_TS=0
    fi
  done
) &

exec governor/governor.py "/home/postgres/postgres.yml"



