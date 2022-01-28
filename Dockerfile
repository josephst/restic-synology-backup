FROM restic/restic:0.12.1 as restic

FROM mcr.microsoft.com/powershell:alpine-3.14

COPY --from=restic /usr/bin/restic /usr/bin/restic

RUN apk add --update --no-cache ca-certificates fuse openssh-client tzdata

# RESTIC_REPOSITORY may be /mnt/restic or a remote repo (such as B2 or S3)
ENV RESTIC_REPOSITORY="/mnt/restic"
ENV RESTIC_PASSWORD=""

# local restic repo (Repo2) is copied to remote restic repo
ENV RESTIC_REPOSITORY2="/mnt/copy"
ENV RESTIC_PASSWORD2=""
ENV COPY_LOCAL_REPO="Y"

ENV RESTIC_TAG=""
ENV NFS_TARGET=""
ENV BACKUP_CRON="0 */6 * * *"
ENV RESTIC_INIT_ARGS=""

# Healthcheck
ENV USE_HEALTHCHECK="N"
ENV HC_PING=""

# /data is the dir where you have to put the data to be backed up
VOLUME /data

# /mnt/copy contains an existing restic repo to copy from
VOLUME /mnt/copy

COPY backup.ps1 /bin/backup/backup
COPY entry.ps1 /entry.ps1

# TODO: find better config file locations and move logs into correct folder
COPY secrets.ps1 /etc/backup/secrets.ps1
COPY config.ps1 /etc/backup/config.ps1
COPY local.exclude /etc/backup/local.exclude
RUN mkdir -p /var/log/restic/

WORKDIR "/"

ENTRYPOINT [ "/entry.ps1" ]
CMD ["tail", "-fn0", "/var/log/cron.log"]
