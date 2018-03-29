#!/usr/bin/env perl

use v5.10;

use autodie;
use strict;
use warnings;

use Getopt::Long;
use JSON;
use Path::Class;
use List::Util qw( min max );

use constant THEMES     => 10;
use constant MIN_DECADE => 1930;
use constant MAX_DECADE => 2000;

use constant USAGE => <<EOT;
Syntax: $0 [options] <dir> ...

Options:
    -h, --help          See this message
    -o, --output=dir    Output media to <dir>
    -d, --database=dir  Output db dump to <dir>
    -p, --prefix=url    URL prefix for resources
    -m, --merge=dir     Merge db files from <dir> into output
EOT

my %O = (
  help     => undef,
  output   => 'datacontent',
  database => 'db',
  prefix   => '/remarc_resources/content',
  merge    => [],
);

GetOptions(
  'h|help'       => \$O{help},
  'o|output:s'   => \$O{output},
  'd|database:s' => \$O{database},
  'p|prefix:s'   => \$O{prefix},
  'm|merge:s'    => $O{merge},
) or die USAGE;

my $stash = {
  audio  => [],
  video  => [],
  images => [],
};

# Read, merge any old data
while ( my ( $col, $recs ) = each %$stash ) {
  my $base = "$col.json";

  for my $merge ( @{ $O{merge} } ) {
    my $dbsrc = file $merge, $base;
    next unless -e $dbsrc;
    say "Reading $dbsrc";
    push @$recs, @{ load_mongo($dbsrc) };
  }
}

# Find new data
for my $dir (@ARGV) {
  process_dir( $stash, $dir );
}

# Survey
my %stats = ();
while ( my ( $col, $recs ) = each %$stash ) {
  for my $rec (@$recs) {
    for my $key ( 'decade', 'theme' ) {
      my $kv = $rec->{$key};
      $stats{$key}{$kv}++;
    }
  }
}

# Show stats
for my $key ( sort keys %stats ) {
  say "$key:";
  my $info  = $stats{$key};
  my $total = 0;
  for my $kv ( sort { $info->{$a} <=> $info->{$b} } keys %$info ) {
    printf "%8d : %s\n", $info->{$kv}, $kv;
    $total += $info->{$kv};
  }
  printf "%8d : %s\n\n", $total, "TOTAL";
}

while ( my ( $col, $recs ) = each %$stash ) {
  my $base = "$col.json";
  my $dbfile = file $O{database}, $base;

  say "Writing $dbfile";
  save_mongo( $dbfile, $recs );
}

my $dbfile = file $O{database}, "theme.json";
say "Writing $dbfile";
save_mongo( $dbfile, make_themes( $stats{theme} ) );

sub make_themes {
  my $stats = shift;
  my @themes;
  my @names
   = map { $_ // 'Unused' } ( sort keys %$stats )[0 .. THEMES - 1];

  for my $theme (@names) {
    push @themes,
     {_id  => mongo_id(),
      name => $theme
     };
  }

  return \@themes;
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

  my %theme_map = (
    TV      => "TV and Radio",
    Lesiure => "Leisure",
  );

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
    my $decade
     = min( max( MIN_DECADE, 10 * int( $year / 10 ) ), MAX_DECADE );
    my $theme = $theme_map{$tag} // $tag;

    #    $stash->{theme}{$theme}++;

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

sub load_mongo {
  my $fh   = file( $_[0] )->openr;
  my $json = JSON->new;
  my @out  = ();
  while (<$fh>) {
    my $rec = $json->decode($_);
    push @out, $rec;
  }
  return \@out;
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
