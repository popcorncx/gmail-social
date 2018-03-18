#!/usr/bin/perl -w

use strict;
use warnings;

use autodie;

use Data::Dumper; $Data::Dumper::Indent = 1;
use Config::Tiny;

use File::Basename qw{ dirname };
use Time::ParseDate qw{ parsedate };
use HTML::Entities qw{ encode_entities };
use MIME::Entity;
use Mail::IMAPClient;
use Digest::MD5 qw{ md5_hex };
use Encode qw{ encode };
use Net::Twitter;

my $CONFIG_FILE = dirname($0) . '/twitter.ini';

my $config = Config::Tiny->read($CONFIG_FILE)
	or die Config::Tiny->errstr();

my $twitter = Net::Twitter->new(
	'traits'          => [ 'API::RESTv1_1', 'OAuth' ],
	'consumer_key'    => $config->{'twitter'}->{'consumer_key'},
	'consumer_secret' => $config->{'twitter'}->{'consumer_secret'},
	'ssl'             => 1,
);

$twitter->access_token( $config->{'twitter'}->{'access_token'} );
$twitter->access_token_secret( $config->{'twitter'}->{'access_token_secret'} );

my @updates = ();

my $statuses = eval {
	$twitter->home_timeline({
		'since_id' => $config->{'_'}->{'high_water'},
		'count'    => 1000,
	});
};

die Dumper $@ if $@;

ITEM: foreach my $item ( @{ $statuses } )
{
	my $update = {};

	$update->{'id'} = $item->{'id'};

	$update->{'link'}
		= 'http://twitter.com/'
		. $item->{'user'}->{'screen_name'}
		. '/status/'
		. $item->{'id'}
	;

	$update->{'time'} = parsedate( $item->{'created_at'} );

	$update->{'user'} = $item->{'user'}->{'name'};
	$update->{'text'} = $item->{'text'};

	$update->{'html'} = encode_entities($update->{'text'});
	$update->{'html'} =~ s{ \s [#] ([a-z\d]+) }{ <a href="http://twitter.com/search?q=%23$1">#$1</a>}smxgi;

	push @updates, $update;
}

exit if not @updates;

###################

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
		'<p>', encode('UTF-8', $update->{'html'}), '</p>',
		'<p>URL: <a href="', encode_entities($update->{'link'}), '">',
			encode_entities($update->{'link'}), '</a></p>',
	);

	my $message_id = md5_hex(
		time(), $update->{'time'}, $content, rand(),
	) . '.' . $config->{'imap'}->{'address'};

	my $entity = MIME::Entity->build(
		'From'       => encode('MIME-Header', $update->{'user'}) . ' <' . $config->{'imap'}->{'address'} . '>',
		'To'         => $config->{'imap'}->{'address'},
		'Subject'    => encode('MIME-Header', $update->{'text'}),
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

	if ( $update->{'id'} > $config->{'_'}->{'high_water'} )
	{
		$config->{'_'}->{'high_water'} = $update->{'id'};
		$config->write($CONFIG_FILE);
	}
}

