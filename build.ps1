Remove-Item -Recurse -Force "./test/remoteRepo"
New-Item -ItemType Directory "./test/remoteRepo"

docker build --rm -t restic-synology-backup .
