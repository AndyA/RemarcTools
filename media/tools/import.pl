#!/usr/bin/env perl

use v5.10;

use autodie;
use strict;
use warnings;

use File::Find;
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
EOT

my %O = (
  help     => undef,
  output   => 'datacontent',
  database => 'db',
);

GetOptions(
  'h|help'       => \$O{help},
  'o|output:s'   => \$O{output},
  'd|database:s' => \$O{database}
) or die USAGE;

my $stash = {};
for my $dir (@ARGV) {
  find {
    wanted => sub {
      return unless -f;
      return unless /\.properties$/;
      process_props( $stash, $_ );
    },
    no_chdir => 1
  }, $dir;
}

fix_themes($stash);

while ( my ( $col, $recs ) = each %$stash ) {
  my $dbfile = file $O{database}, "$col.json";
  say "Writing $dbfile";
  save_mongo( $dbfile, $recs );
}

sub fix_themes {
  my ($stash) = @_;
  my @themes;
  my @names = map { $_ // 'Unused' }
   ( sort keys %{ delete $stash->{theme} } )[0 .. THEMES - 1];

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

sub process_props {
  my ( $stash, $propfile ) = @_;

  say "Processing $propfile";

  my %is_media = map { $_ => 1 } qw( jpg jpeg mp3 mp4 ogg ogv );
  my %ext2key = (
    jpeg => 'imageUrl',
    jpg  => 'imageUrl',
    mp3  => 'mp3ContentUrl',
    mp4  => 'mp4ContentUrl',
    ogg  => 'oggContentUrl',
    ogv  => 'ogvContentUrl',
  );

  my $props = read_props($propfile);

  # Bodge: app doesn't escape ampersand.
  ( my $theme = $props->{theme} ) =~ s/ & / and /g;
  $stash->{theme}{$theme}++;

  my @obj = file($propfile)->parent->children;

  my %found = ();
  for my $obj (@obj) {
    next unless $obj->basename =~ /^(.+?)\.(.+)$/;
    my ( $base, $ext ) = ( $1, $2 );
    next unless $is_media{$ext};
    $found{$base}{$ext} = "$obj";
  }

  for my $id ( sort keys %found ) {
    my $obj  = $found{$id};
    my $kind = asset_kind($obj);
    my $rec  = {
      _id    => mongo_id(),
      id     => $id,
      theme  => $theme,
      decade => $props->{decade} };
    while ( my ( $ext, $file ) = each %$obj ) {
      my $key = $ext2key{$ext} // die;
      my $url = join '/', '', 'remarc_resources', 'content', $kind, "$id.$ext";
      $rec->{$key} = $url;
      my $dst = file $O{output}, $kind, "$id.$ext";
      $dst->parent->mkpath;

      link_file( $file, $dst );
    }
    push @{ $stash->{$kind} }, $rec;
  }
}

sub asset_kind {
  my $obj = shift;
  return 'audio' if exists $obj->{mp3} || exists $obj->{ogg};
  return 'video' if exists $obj->{mp4} || exists $obj->{ogv};
  return 'images';
}

sub read_props {
  my ($propfile) = @_;
  my $props = {};
  open my $fh, '<', $propfile;
  while (<$fh>) {
    chomp;
    next if /^\s*#/ || /^\s*$/;
    die "Bad properties" unless /^(\w+(?:\.\w+)*)[=:](.+)/;
    $props->{$1} = $2;
  }
  return $props;
}

sub mongo_id { { '$oid' => mongo_uuid() } }

sub mongo_uuid {
  my @part = ();
  push @part, sprintf '%04x', int( rand() * 0x10000 ) for 1 .. 6;
  return join '', @part;
}

sub link_file {
  my ( $from, $to ) = @_;
  my $tmp = "$to.tmp";
  eval { unlink "$tmp" };
  link "$from", "$tmp";
  rename "$tmp", "$to";
}

# vim:ts=2:sw=2:sts=2:et:ft=perl

