gmail-social
============

Scripts to query Mastodon/Twitter for new posts and then inject those
posts via IMAP into a Gmail account as individual messages. Can then
deal with these at the same time as my other email messages.

Cobbled together a number of years ago, mostly working unmodified since
then.

Scripts are intended to be run from cron every few hours. They get config
from an ini file and also update that ini file with the latest post so
they know where to resume.

