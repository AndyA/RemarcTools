#!/usr/bin/env perl

use v5.10;

use autodie;
use strict;
use warnings;

use File::Find;
use Getopt::Long;
use Path::Class;
use XML::LibXML::XPathContext;
use XML::LibXML;

use constant POSTER_OFFSET => 150;

use constant USAGE => <<EOT;
Syntax: $0 [options] <dir> ...

Options:
    -h, --help        See this message
    -o, --output=dir  Output files to <dir>
EOT

my %O = (
  help   => undef,
  output => 'output',
);

GetOptions( 'h|help' => \$O{help}, 'o|output:s' => \$O{output}, )
 or die USAGE;

if ( $O{help} ) {
  say USAGE;
  exit;
}

for my $dir (@ARGV) {
  find {
    wanted => sub {
      return unless -f;
      my $infile = file($_);
      my $outfile = file( $O{output}, $infile->relative($dir) );

      return if -f "$outfile" && -M "$infile" <= -M "$outfile";
      say "$infile -> $outfile";

      $outfile->parent->mkpath;

      if ( $infile =~ /\.mp3$/ ) {
        process_mp3( $infile, $outfile );
      }
      elsif ( $infile =~ /\.mp4$/ ) {
        process_mp4( $infile, $outfile );
      }
      else {
        link "$infile", "$outfile";
      }
    },
    no_chdir => 1
  }, $dir;
}

sub process_mp3 {
  my ( $infile, $outfile ) = @_;

  ( my $oggfile = $outfile ) =~ s/\.mp3$/.ogg/;
  ffmpeg( ["-vn", "-c:a", "libvorbis", "-b:a", "192k",],
    "$infile", "$oggfile" );

  link "$infile", "$outfile";
}

sub process_mp4 {
  my ( $infile, $outfile ) = @_;
  my $info = mediainfo($infile);

  my $vid = '//Mediainfo/File/track[@type="Video"]/';

  my $bitrate  = mi_num( $info, "$vid/Bit_rate" );
  my $width    = mi_num( $info, "$vid/Width" );
  my $height   = mi_num( $info, "$vid/Height" );
  my $duration = mi_num( $info, "$vid/Duration" );

  my $rate = $bitrate;
  my $maxrate = max_bit_rate( $width, $height );

  # poster frame
  my $postertime = int( $duration / 2000 );
  $postertime = POSTER_OFFSET if $postertime > POSTER_OFFSET;
  ( my $posterfile = $outfile ) =~ s/\.mp4$/.jpg/;
  ffmpeg(
    [ -ss      => $postertime,
      -vframes => 1,
    ],
    $infile,
    $posterfile
  );

  # theora
  ( my $ogvfile = $outfile ) =~ s/\.mp4$/.ogv/;
  ffmpeg(
    [ -async => 1,
      -vsync => 0,
      "-c:a", "libvorbis", "-b:a", "192k",
      "-c:v", "libtheora", "-b:v", int( $maxrate * 1.5 )
    ],
    "$infile",
    "$ogvfile"
  );

  # h264
  if ( $bitrate > $maxrate * 1.2 ) {
    ffmpeg(
      [ -async => 1,
        -vsync => 0,
        "-c:a", "aac", "-b:a", "192k", "-c:v", "libx264", "-b:v", $maxrate
      ],
      "$infile",
      "$outfile"
    );
    $rate = $maxrate;
  }
  else {
    link "$infile", "$outfile";
  }

}

sub ffmpeg {
  my ( $extra, $infile, $outfile ) = @_;

  die unless $outfile =~ m{\.([^./]+)$};
  my $ext     = $1;
  my $tmpfile = "$outfile.tmp.$ext";

  my @cmd = (
    'ffmpeg',
    -i => $infile,
    @$extra, -y => $tmpfile
  );

  say join " ", @cmd;
  system @cmd and die $?;
  rename "$tmpfile", "$outfile";
}

sub max_bit_rate {
  my ( $width, $height ) = @_;
  return 800_000  if $height < 400;
  return 1200_000 if $height < 720;
  return 2000_000;
}

sub mi_num {
  my ( $doc, $path ) = @_;
  for my $nd ( $doc->findnodes($path) ) {
    my $val = $nd->textContent;
    return $1 if $val =~ /^\s*(\d+)\s*$/;
  }
  return;
}

sub mediainfo {
  my $file = shift;
  my $xml = run_cmd( 'mediainfo', '--Full', '--Output=XML', $file );
  return XML::LibXML->load_xml( string => $xml );
}

sub run_cmd {
  open my $fh, '-|', @_;
  my $out = do { local $/; <$fh> };
  close $fh;
  return $out;
}

# vim:ts=2:sw=2:sts=2:et:ft=perl

