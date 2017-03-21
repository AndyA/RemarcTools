#!/usr/bin/env perl

use v5.10;

use autodie;
use strict;
use warnings;

use File::Find;
use Getopt::Long;
use List::Util qw( min max );
use Path::Class;
use Scalar::Util qw( looks_like_number );
use XML::LibXML::XPathContext;
use XML::LibXML;

use constant POSTER_OFFSET    => 150;
use constant IMAGE_MAX_WIDTH  => 1920;
use constant IMAGE_MAX_HEIGHT => 1080;

use constant USAGE => <<EOT;
Syntax: $0 [options] <dir> ...

Options:
    -h, --help          See this message
    -o, --output=dir    Output files to <dir>
    -w, --watermark=img Watermark with image
EOT

my %O = (
  help      => undef,
  output    => 'output',
  watermark => undef,
);

GetOptions(
  'h|help'        => \$O{help},
  'o|output:s'    => \$O{output},
  'w|watermark:s' => \$O{watermark},
) or die USAGE;

if ( $O{help} ) {
  say USAGE;
  exit;
}

for my $dir (@ARGV) {
  find {
    wanted => sub {
      return unless -f;
      my $infile = file($_);
      return if $infile->basename =~ /^\./;
      my $outfile = file( $O{output}, $infile->relative($dir) );

      return if -f "$outfile" && -M "$infile" >= -M "$outfile";
      say "$infile -> $outfile";

      $outfile->parent->mkpath;

      if ( $infile =~ /\.mp3$/ ) {
        process_mp3( $infile, $outfile );
      }
      elsif ( $infile =~ /\.mp4$/ ) {
        process_mp4( $infile, $outfile, $O{watermark} );
      }
      elsif ( $infile =~ /\.jpg$/ ) {
        process_jpg( $infile, $outfile, $O{watermark} );
      }
      else {
        link_file( $infile, $outfile );
      }
    },
    no_chdir => 1
  }, $dir;
}

sub link_file {
  my ( $from, $to ) = @_;
  my $tmp = "$to.tmp";
  eval { unlink "$tmp" };
  link "$from", "$tmp";
  rename "$tmp", "$to";
}

sub process_jpg {
  my ( $infile, $outfile, $watermark ) = @_;
  my $info = mediainfo($infile);

  my $img = '//Mediainfo/File/track[@type="Image"]';

  my $width  = mi_num( $info, "$img/Width" );
  my $height = mi_num( $info, "$img/Height" );

  my ( $ow, $oh )
   = scale_size( $width, $height, IMAGE_MAX_WIDTH, IMAGE_MAX_HEIGHT );

  my @wm = watermark( $watermark, $ow, $oh );

  if (@wm) {
    ffmpeg( [@wm], "$infile", "$outfile" );
  }
  elsif ( $ow < $width || $oh < $height ) {
    ffmpeg( [-vf => "scale=w=$ow:h=$oh"], "$infile", "$outfile" );
  }
  else {
    link_file( "$infile", "$outfile" );
  }
}

sub process_mp3 {
  my ( $infile, $outfile ) = @_;

  ( my $oggfile = $outfile ) =~ s/\.mp3$/.ogg/;
  ffmpeg( ["-vn", "-c:a", "libvorbis", "-b:a", "192k",],
    "$infile", "$oggfile" );

  link_file( "$infile", "$outfile" );
}

sub process_mp4 {
  my ( $infile, $outfile, $watermark ) = @_;
  my $info = mediainfo($infile);

  my $vid = '//Mediainfo/File/track[@type="Video"]';

  my $bitrate  = mi_num( $info, "$vid/Bit_rate" );
  my $width    = mi_num( $info, "$vid/Width" );
  my $height   = mi_num( $info, "$vid/Height" );
  my $duration = mi_num( $info, "$vid/Duration" );
  my $dar      = mi_num( $info, "$vid/Display_aspect_ratio" );
  my $par      = mi_num( $info, "$vid/Pixel_aspect_ratio" );

  my @wm = watermark( $watermark, $width, $height );

  {
    # poster frame
    my $postertime = min( POSTER_OFFSET, int( $duration / 2000 ) );
    ( my $posterfile = $outfile ) =~ s/\.mp4$/.jpg/;

    ffmpeg(
      [ @wm,
        -ss      => $postertime,
        -vframes => 1,

      ],
      $infile,
      $posterfile
    );
  }

  {
    my $maxrate = max_bit_rate( $width, $height );
    my $rate = $bitrate;

    # h264
    if ( $bitrate > $maxrate * 1.2 || @wm ) {
      $rate = $maxrate;
      ffmpeg(
        [ @wm,
          -async => 1,
          -vsync => 0,
          "-c:a", "aac",     "-b:a", "192k",
          "-c:v", "libx264", "-b:v", $rate
        ],
        "$infile",
        "$outfile"
      );
    }
    else {
      link_file( "$infile", "$outfile" );
    }

    # theora
    ( my $ogvfile = $outfile ) =~ s/\.mp4$/.ogv/;
    ffmpeg(
      [ @wm,
        -async => 1,
        -vsync => 0,
        "-c:a", "libvorbis", "-b:a", "192k",
        "-c:v", "libtheora", "-b:v", int( $rate * 1.5 )
      ],
      "$infile",
      "$ogvfile"
    );
  }
}

sub scale_size {
  my ( $w, $h, $max_w, $max_h ) = @_;
  my $scale = min( 1, $max_w / $w, $max_h / $h );
  return ( round( $w * $scale ), round( $h * $scale ) );
}

sub round {
  my $x = shift;
  return undef unless defined $x;
  return -round( -$x ) if $x < 0;
  return int( $x + 0.5 );
}

sub watermark {
  my ( $img, $w, $h ) = @_;
  my $pad = round( min( $w, $h ) / 20 );
  return overlay( $img, $pad, $pad, $pad * 2, -1, round($w), round($h) );
}

sub overlay {
  my ( $img, $x, $y, $ww, $wh, $sw, $sh ) = @_;

  return unless defined $img;

  return (
    -i              => $img,
    -filter_complex => join( ", ",
      ( defined $sw ? "[0:v]scale=w=$sw:h=$sh [src]" : "[0:v]null [src]" ),
      "[1:v]scale=w=$ww:h=$wh [ovrl]",
      "[src][ovrl]overlay=x=$x:y=$y" )
  );
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
    return $val if looks_like_number($val);
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
