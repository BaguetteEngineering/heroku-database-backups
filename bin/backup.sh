#!/bin/bash

# terminate script as soon as any command fails
# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -eo pipefail

if [[ -z "$APP" ]]; then
  echo "Missing APP variable which must be set to the name of your app where the db is located"
  exit 1
fi

if [[ -z "$DATABASE" ]]; then
  echo "Missing DATABASE variable which must be set to the name of the DATABASE you would like to backup"
  exit 1
fi

if [[ -z "$S3_BUCKET_PATH" ]]; then
  echo "Missing S3_BUCKET_PATH variable which must be set the directory in s3 where you would like to store your database backups"
  exit 1
fi

# if the app has heroku pg:backup:schedules, we might just want to just archive the latest backup to S3
# https://devcenter.heroku.com/articles/heroku-postgres-backups#scheduling-backups
#
# set ONLY_CAPTURE_TO_S3 when calling to skip database capture

if [[ -z "$ONLY_CAPTURE_TO_S3" ]]; then
  heroku pg:backups:capture $DATABASE --app $APP
else
  echo " --- Skipping database capture"
fi

# Download the latest backup from Heroku and gzip it
heroku pg:backups:download --output=/tmp/pg_backup.dump --app $APP
gzip /tmp/pg_backup.dump

# Generate backup filename based on the current date
BACKUP_FILE_NAME="heroku-backup_${APP}_${DATABASE}_$(date '+%Y-%m-%d_%H.%M')"
BACKUP_FILE_EXTENSION=".gz"

# Encrypt the gzipped backup file using GPG passphrase
if [[ -n "$GPG_PASSPHRASE" ]]; then
  gpg --yes --batch --passphrase=$GPG_PASSPHRASE -c /tmp/pg_backup.dump.gz
  BACKUP_FILE_EXTENSION=".gz.gpg"
fi

# Upload the file to S3 using AWS CLI
aws s3 cp /tmp/pg_backup.dump$BACKUP_FILE_EXTENSION "s3://${S3_BUCKET_PATH}/${BACKUP_FILE_NAME}${BACKUP_FILE_EXTENSION}"

# Remove the plaintext backup file
rm /tmp/pg_backup.dump.gz

# Remove the encrypted backup file
if [[ -n "$GPG_PASSPHRASE" ]]; then
  rm /tmp/pg_backup.dump.gz.gpg
fi

echo "backup $BACKUP_FILE_NAME$BACKUP_FILE_EXTENSION complete"

if [[ -n "$HEARTBEAT_URL" ]]; then
  echo "Sending a request to the specified HEARTBEAT_URL that the backup was created"
  curl $HEARTBEAT_URL
  echo "heartbeat complete"
fi