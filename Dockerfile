FROM restic/restic:0.12.1 as restic

FROM mcr.microsoft.com/powershell:alpine-3.14

COPY --from=restic /usr/bin/restic /usr/bin/restic

RUN apk add --update --no-cache ca-certificates fuse openssh-client tzdata

ENV RESTIC_REPOSITORY=""
ENV RESTIC_PASSWORD=""

# local restic repo (Repo2) is copied to remote restic repo
ENV RESTIC_REPOSITORY2=""
ENV RESTIC_PASSWORD2=""
ENV COPY_LOCAL_REPO="$false"

ENV RESTIC_TAG=""
ENV NFS_TARGET=""
ENV BACKUP_CRON="0 */6 * * *"
ENV RESTIC_INIT_ARGS=""
ENV RESTIC_FORGET_ARGS=""
ENV RESTIC_JOB_ARGS=""

# Healthcheck
ENV USE_HEALTHCHECK="$true"
ENV HC_PING=""

# /data is the dir where you have to put the data to be backed up
VOLUME /data

WORKDIR "/"

CMD ["pwsh"]
