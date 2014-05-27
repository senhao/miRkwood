#!/usr/bin/perl

use strict;
use warnings;

use Test::More qw/no_plan/;
use Test::File;

use FindBin;
require File::Spec->catfile( $FindBin::Bin, 'Funcs.pl' );

BEGIN {
    use_ok('PipelineMiRNA::Clusters');
}
require_ok('PipelineMiRNA::Clusters');

my $bamfile = input_file('Clusters.reads-Athaliana_167-ChrC.bam');
file_exists_ok($bamfile);

my $genome_file = input_file('Clusters.Athaliana_167-ChrC.fa');
file_exists_ok($genome_file);

my $faidx_file = $genome_file . '.fai';
file_exists_ok($faidx_file);

## get_islands() ##

ok(
    my @get_islands_output =
      PipelineMiRNA::Clusters->get_islands( $bamfile, 20, $faidx_file ),
    'Can call get_islands()'
);
my @get_islands_expected =
  ( 'ChrC:6-77', 'ChrC:292-318', 'ChrC:448-478', 'ChrC:487-515' );
is_deeply( \@get_islands_output, \@get_islands_expected,
    'get_islands returns the correct values' );

## merge_clusters() ##

ok(
    my @merge_clusters_output = PipelineMiRNA::Clusters->merge_clusters(
        \@get_islands_output, 100, $genome_file
    ),
    'Can call merge_clusters()'
);
my @merge_clusters_expected = ( 'ChrC:6-77', 'ChrC:292-515' );
is_deeply( \@merge_clusters_output, \@merge_clusters_expected,
    'merge_clusters returns the correct values' );
