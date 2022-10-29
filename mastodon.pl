#!/usr/bin/perl -w

use strict;
use warnings;
use autodie;

use Data::Dumper; $Data::Dumper::Indent = 1;
use Config::Tiny;
use File::Basename qw{ dirname };
use LWP::UserAgent;
use JSON qw{ decode_json };
use DateTime::Format::RFC3339;
use HTML::Strip;
use HTML::Entities qw{ encode_entities };
use MIME::Entity;
use Mail::IMAPClient;
use Digest::MD5 qw{ md5_hex };
use Encode qw{ encode };

my $CONFIG_FILE = dirname($0) . '/mastodon.ini';

# at least two ways to get an token to access your account:
# 1. follow the API guide to get an application/client set up and then login:
#    https://docs.joinmastodon.org/client/token/
#    https://docs.joinmastodon.org/client/authorized/
# 2. create application via instance UI which will also set up an authenticated
#    access token for your account
#    https://aus.social/settings/applications

my $config = Config::Tiny->read($CONFIG_FILE)
	or die Config::Tiny->errstr();

##

# directly hit the endpoint to get JSON of timeline

my $ua = LWP::UserAgent->new('agent' => 'popcorncx-imap-gateway/0.1');
$ua->default_header('Authorization' => 'Bearer ' . $config->{'mastodon'}->{'access_token'});

my $hs = HTML::Strip->new('emit_spaces' => 0);
my $dtf = DateTime::Format::RFC3339->new();

##

# limit of 1000 should be way over the top for checking every few hours
my $url = sprintf('https://%s/api/v1/timelines/home?limit=1000', $config->{'mastodon'}->{'instance'});

if ( $config->{'_'}->{'since_id'} )
{
	$url .= sprintf('&since_id=%s', $config->{'_'}->{'since_id'});
}

my $response = $ua->get($url);

if ( not $response->is_success() )
{
	die $url . q{: } . $response->status_line();
}

my $timeline = eval {
	decode_json( $response->decoded_content() )
};

if ( my $error = $@ )
{
	die "Cannot parse JSON: $@";
}

my @updates = ();

POST: foreach my $post ( @{$timeline} )
{
	my $update = {
		'id'      => $post->{'id'},
		'name'    => ( $post->{'account'}->{'display_name'} || $post->{'account'}->{'username'} ),
		'content' => $post->{'content'},
		'url'     => $post->{'url'},
		'time'    => $dtf->parse_datetime( $post->{'created_at'} )->epoch(),
	};

	if ( my $reblog = $post->{'reblog'} )
	{
		$update->{'name'} .= ' / ' . ( $reblog->{'account'}->{'display_name'} || $reblog->{'account'}->{'username'} );

		$update->{'content'} = $reblog->{'content'};
		$update->{'url'}     = $reblog->{'url'};
	}

	push @updates, $update;
}

exit if not @updates;

##

my $imap = Mail::IMAPClient->new(
	'Server'   => $config->{'imap'}->{'server'},
	'Port'     => 993,
	'Ssl'      => 1,
	'User'     => $config->{'imap'}->{'username'},
	'Password' => $config->{'imap'}->{'password'},
) or die $@;

POST: foreach my $update ( sort { $a->{'id'} <=> $b->{'id'} } @updates )
{
	my $content = join( q{},
		encode('UTF-8', $update->{'content'}),
		'<hr />',
		'<p>URL: <a href="', encode_entities($update->{'url'}), '">',
			encode_entities($update->{'url'}), '</a></p>',
	);

	my $message_id = md5_hex(
		time(), $update->{'time'}, $content, rand(),
	) . '.' . $config->{'imap'}->{'address'};

	my $subject = $hs->parse( $update->{'content'} );
	if ( length($subject) > 72 )
	{
		$subject = substr($subject, 0, 72) . '...';
	}

	my $entity = MIME::Entity->build(
		'From'       => encode('MIME-Header', $update->{'name'}) . ' <' . $config->{'imap'}->{'address'} . '>',
		'To'         => $config->{'imap'}->{'address'},
		'Subject'    => encode('MIME-Header', $subject),
		'Date'       => Mail::IMAPClient->Rfc822_date( $update->{'time'} ),
		'Message-Id' => $message_id,
		'Data'       => [ split "\n", $content ],
		'Type'       => 'text/html',
		'Encoding'   => '-SUGGEST',
		'Charset'    => 'UTF-8',
	);

	foreach my $folder ( split( ',', $config->{'imap'}->{'folder'} ) )
	{
		$imap->append_string(
			$folder,
			$entity->as_string(),
			undef,
			Mail::IMAPClient->Rfc3501_datetime( $update->{'time'} ),
		) or die $imap->LastError();
	}

	if ( $update->{'id'} > $config->{'_'}->{'since_id'} )
	{
		$config->{'_'}->{'since_id'} = $update->{'id'};
		$config->write($CONFIG_FILE);
	}
}

