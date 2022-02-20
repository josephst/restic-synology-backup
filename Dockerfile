FROM restic/restic:0.12.1 as restic

FROM mcr.microsoft.com/powershell:alpine-3.14

COPY --from=restic /usr/bin/restic /usr/bin/restic

RUN apk add --update --no-cache ca-certificates fuse openssh-client tzdata

# RESTIC_REPOSITORY may be /mnt/restic or a remote repo (such as B2 or S3)
ENV RESTIC_REPOSITORY="/mnt/restic"
ENV RESTIC_PASSWORD=""

# B2 config
ENV B2_ACCOUNT_ID="id"
ENV B2_ACCOUNT_KEY="key"

# local restic repo (Repo2) is copied to remote restic repo
ENV RESTIC_REPOSITORY2="/mnt/copy"
ENV RESTIC_PASSWORD2=""
ENV COPY_LOCAL_REPO="Y"

ENV RESTIC_TAG=""
ENV NFS_TARGET=""
ENV BACKUP_CRON="5 0 * * *"
ENV RESTIC_INIT_ARGS=""

# default to random delay 0-60 seconds for backups
ENV RANDOM_DELAY="60"

# Maintenance
ENV RESTIC_MAINT_INTERVAL=7
ENV RESTIC_MAINT_DAYS=30
# download and check 5gb of backed up data, every 90 days
ENV RESTIC_DEEP_MAINT="Y"
ENV RESTIC_DEEP_MAINT_DAYS=90
# supports restic's --read-data-subset options; 100% to read whole repo
ENV RESTIC_DEEP_MAINT_SIZE="10%"

# Healthcheck
ENV USE_HEALTHCHECK="N"
ENV HC_PING=""

# /data is the dir where you have to put the data to be backed up
VOLUME /data

# /mnt/copy contains an existing restic repo to copy from
VOLUME /mnt/copy

# /etc/backup contains configuration files for backup and CSV files from backups
# COPY src/config/config.ps1 /etc/backup/
# COPY src/config/local.exclude /etc/backup/
VOLUME /etc/backup/

COPY src/script/ /bin/backup/
COPY src/entry.ps1 /entry.ps1
COPY src/100-delete-backup-logs.sh /etc/periodic/monthly/

WORKDIR "/"

ENTRYPOINT [ "/entry.ps1" ]
CMD ["tail", "-fn0", "/var/log/cron.log"]
