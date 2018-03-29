#!/usr/bin/env perl

use v5.10;

use autodie;
use strict;
use warnings;

use Getopt::Long;
use JSON;
use Path::Class;

use constant THEMES => 10;

use constant USAGE => <<EOT;
Syntax: $0 [options] <dir> ...

Options:
    -h, --help          See this message
    -o, --output=dir    Output media to <dir>
    -d, --database=dir  Output db dump to <dir>
    -p, --prefix=url    URL prefix for resources
EOT

my %O = (
  help     => undef,
  output   => 'datacontent',
  database => 'db',
  prefix   => '/remarc_resources/content',
);

GetOptions(
  'h|help'       => \$O{help},
  'o|output:s'   => \$O{output},
  'd|database:s' => \$O{database},
  'p|prefix:s'   => \$O{prefix},
) or die USAGE;

my $stash = {};
for my $dir (@ARGV) {
  process_dir( $stash, $dir );
}

for my $key ( 'theme', 'decade' ) {
  say "$key:";
  my $stats = $stash->{$key};
  for my $val ( sort { $stats->{$a} <=> $stats->{$b} } keys %$stats ) {
    printf "%5d %s\n", $stats->{$val}, $val;
  }
}

fix_themes($stash);

delete $stash->{decade};

while ( my ( $col, $recs ) = each %$stash ) {
  my $dbfile = file $O{database}, "$col.json";
  say "Writing $dbfile";
  save_mongo( $dbfile, $recs );
}

sub fix_themes {
  my ($stash) = @_;
  my @themes;
  my @names = map { $_ // 'Unused' }
   ( sort keys %{ $stash->{theme} } )[0 .. THEMES - 1];

  for my $theme (@names) {
    push @themes,
     {_id  => mongo_id(),
      name => $theme
     };
  }
  $stash->{theme} = \@themes;
  return $stash;
}

sub save_mongo {
  my ( $file, $recs ) = @_;
  my $outf = file $file;
  $outf->parent->mkpath;
  my $fh   = $outf->openw;
  my $json = JSON->new->canonical;
  for my $rec (@$recs) {
    print $fh $json->encode($rec), "\n";
  }
}

sub process_dir {
  my ( $stash, $dir ) = @_;

  say "Processing $dir";

  my %is_media = map { $_ => 1 } qw( jpg jpeg mp3 mp4 ogg ogv );
  my %ext2key = (
    jpeg => 'imageUrl',
    jpg  => 'imageUrl',
    mp3  => 'mp3ContentUrl',
    mp4  => 'mp4ContentUrl',
    ogg  => 'oggContentUrl',
    ogv  => 'ogvContentUrl',
  );

  my %theme_map = ( TV => "TV and Radio" );

  my @obj = dir($dir)->children;

  my %found = ();
  for my $obj (@obj) {
    if ( $obj->is_dir ) {
      process_dir( $stash, $obj );
      next;
    }

    my ( $base, $ext ) = split /\./, $obj->basename, 2;
    next unless defined $ext && $is_media{$ext};
    $found{$base}{$ext} = "$obj";
  }

  my %by_kind = ();
  for my $id ( sort keys %found ) {
    my $obj  = $found{$id};
    my $kind = asset_kind($obj);
    $by_kind{$kind}++;
    my ( $year, $tag ) = parse_id($id);
    my $decade = 10 * int( $year / 10 );
    my $theme = $theme_map{$tag} // $tag;

    $stash->{theme}{$theme}++;
    $stash->{decade}{$decade}++;

    my $rec = {
      _id    => mongo_id(),
      id     => $id,
      theme  => $theme,
      decade => "${decade}s"
    };

    while ( my ( $ext, $file ) = each %$obj ) {
      my $key = $ext2key{$ext} // die;
      my $url = join '/', $O{prefix}, $kind, "$id.$ext";
      $rec->{$key} = $url;
      my $dst = file $O{output}, $kind, "$id.$ext";
      $dst->parent->mkpath;

      link_file( $file, $dst );
    }
    push @{ $stash->{$kind} }, $rec;
  }

  say '  ', join ', ', map { "$_ = $by_kind{$_}" } sort keys %by_kind;
}

sub parse_id {
  my $id = shift;
  die "Can't parse $id"
   unless $id =~ /^(\d\d\d\d)\d*_(\w+?)_/;
  return ( $1, $2 );
}

sub asset_kind {
  my $obj = shift;
  return 'audio' if exists $obj->{mp3} || exists $obj->{ogg};
  return 'video' if exists $obj->{mp4} || exists $obj->{ogv};
  return 'images';
}

sub mongo_id { { '$oid' => mongo_uuid() } }

sub mongo_uuid {
  my @part = ();
  push @part, sprintf '%04x', int( rand() * 0x10000 ) for 1 .. 6;
  return join '', @part;
}

sub link_file {
  my ( $from, $to ) = @_;
  eval { unlink "$to" };
  link "$from", "$to";
}

# vim:ts=2:sw=2:sts=2:et:ft=perl
