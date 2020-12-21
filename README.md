Simple heroku app with a bash script for capturing heroku database backups and copying to your s3 bucket.  Deploy this as a separate app within heroku and schedule the script to backup your production databases which exist within another heroku project.

Now using [aws cli v2](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2-linux.html) - works with both `heroku-18` and `heroku-20` stacks.

Backup script and instructions updated, based on https://pawelurbanek.com/heroku-postgresql-s3-backup.

## Installation

First, clone this project, then change directory into the newly created directory:

```
git clone https://github.com/kbaum/heroku-database-backups.git
cd heroku-database-backups
```

Create a project on heroku.

```
heroku create my-database-backups --buildpack heroku-community/cli --region eu
```

Add another buildpack to enable AWS CLI access from within the script.

```
heroku buildpacks:add heroku-community/awscli -a my-database-backups
```

Next push this project to your heroku projects git repository.

```
heroku git:remote -a my-database-backups
git push heroku master
```

Now we need to set some environment variables in order to get the heroku cli working properly using the [heroku-buildpack-cli](https://github.com/heroku/heroku-buildpack-cli).

Create a long-lived authorization token:

```
heroku config:add HEROKU_API_KEY=`heroku authorizations:create -S -d my-database-backups` -a my-database-backups
```

Next we need to add the amazon key and secret from the IAM user that you are using:

```
heroku config:add AWS_ACCESS_KEY_ID=123456 -a my-database-backups
heroku config:add AWS_DEFAULT_REGION=eu-central-1 -a my-database-backups
heroku config:add AWS_SECRET_ACCESS_KEY=132345verybigsecret -a my-database-backups
```

And we'll need to also set the bucket and path where we would like to store our database backups:

```
heroku config:add S3_BUCKET_PATH=my-db-backup-bucket/backups -a my-database-backups
```
Be careful when setting the S3_BUCKET_PATH to leave off a trailing forward slash.  Amazon console s3 browser will not be able to locate your file if your directory has "//" (S3 does not really have directories.).

Finally, we need to add heroku scheduler and call [backup.sh](https://github.com/kbaum/heroku-database-backups/blob/master/bin/backup.sh) on a regular interval with the appropriate database and app.

```
heroku addons:create scheduler:standard -a my-database-backups
```

Now open it up, in your browser with:

```
heroku addons:open scheduler -a my-database-backups
```

And add the following command to run as often as you like:

```
APP=your-app DATABASE=HEROKU_POSTGRESQL_NAVY_URL /app/bin/backup.sh
```

In the above command, APP is the name of your app within heroku that contains the database.  DATABASE is the name of the database you would like to capture and backup.  In our setup, DATABASE actually points to a follower database to avoid any impact to our users.  Both of these environment variables can also be set within your heroku config rather than passing into the script invocation.

### Optional

**Encrypt backups**

You can set up a secure password that will be used to encrypt the database dump files before uploading them to S3. You can use OpenSSL for that:

```
heroku config:add GPG_PASSPHRASE=$(openssl rand -base64 32) -a my-database-backups
```

Just make sure to save this password somewhere safe.

**Do not capture a new backup**

If you are using [heroku's scheduled backups](https://devcenter.heroku.com/articles/heroku-postgres-backups#scheduling-backups) you might only want to archive the latest
backup to S3 for long-term storage. Set the `ONLY_CAPTURE_TO_S3` variable when running the command:

```
ONLY_CAPTURE_TO_S3=true APP=your-app DATABASE=HEROKU_POSTGRESQL_NAVY_URL /app/bin/backup.sh
```

Note: to schedule Heroku backup:

```
heroku pg:backups:schedule DATABASE_URL --at '01:00'
```

You might also want to consider adding a [bucket lifecycle rule](https://docs.aws.amazon.com/AmazonS3/latest/user-guide/create-lifecycle.html) to remove the older files and optimize storage costs.

**Heartbeat**

You can add a `HEARTBEAT_URL` to the script so a request gets sent every time a backup is made.
Open an account on https://healthchecks.io/, create a new check, and add its URL as a config variable like:

```
heroku config:add HEARTBEAT_URL=https://hearbeat.url -a my-database-backups
```

## How to restore Heroku S3 PostgreSQL backup

### AWS CLI configuration

AWS CLI will be needed to restore the backup. You can install it locally by following [this tutorial](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-install.html).

Now authenticate the AWS CLI by running:

```
aws configure
```

and inputting your IAM user `AWS Access Key ID` and `AWS Secret Access Key`. You can just press ENTER when asked to provide `Default region name` and `Default output format`.

When it’s it up and running you can now generate a short-lived  download URL for your encrypted backup file. Let’s assume that its S3 path is `s3://heroku-secondary-backups/heroku-backup-2019-06-25_01.30.gpg`. You can download it with the following command:

```
wget $(aws s3 presign s3://heroku-secondary-backups/heroku-backup-2019-06-25_01.30.gpg --expires-in 5) -O backup.gpg
```

Once you have it on your local disc you can decrypt it by running:

```
gpg --batch --yes --passphrase=$GPG_PASSPHRASE -d backup.gpg | gunzip --to-stdout > backup.sql
```



Now you have to upload the decrypted version of a backup back to S3 bucket, use it to restore Heroku database and remove it from the bucket right after its been used. We will start with testing it out on a newly provisioned database add-on:

```
heroku addons:create heroku-postgresql:hobby-dev
aws s3 cp backup.sql s3://heroku-secondary-backups/backup.sql
heroku pg:backups:restore $(aws s3 presign s3://heroku-secondary-backups/backup.sql --expires-in 60) HEROKU_POSTGRESQL_GRAY_URL -a app-name
aws s3 rm s3://heroku-secondary-backups/backup.sql
```

Remember to replace `HEROKU_POSTGRESQL_GRAY_URL` with the URL of your newly provisioned database add-on. You can check out the [Heroku docs](https://devcenter.heroku.com/articles/heroku-postgres-import-export) if you run into trouble



You can now check if the content of your database looks correct by logging into it and running some queries:

```
heroku pg:psql HEROKU_POSTGRESQL_GRAY_URL
```

If everything looks OK you can now restore the backup file to your production database:

```
aws s3 cp backup.sql s3://heroku-secondary-backups/backup.sql
heroku pg:backups:restore $(aws s3 presign s3://heroku-secondary-backups/backup.sql --expires-in 60) DATABASE_URL -a app-name
aws s3 rm s3://heroku-secondary-backups/backup.sql
```

Alternatively, you could promote the new database add-on as your new primary database:

```
heroku pg:promote HEROKU_POSTGRESQL_GRAY_URL
```
