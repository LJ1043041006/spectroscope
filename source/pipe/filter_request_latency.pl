#! /usr/bin/perl -w

# $cmuPDL: filter_request_latency.pl,v 1.1.2.1 2010/04/25 17:52:48 lianghon Exp $v

##
# This program calculates the cluster distribution within a specific request 
# latency range. Given the minimum and maximum request latency, it counts 
# the number of requests falling into this range for each cluster. The input 
# file is located in output_dir/convert_data/global_ids_to_cluster_ids, each 
# line of which is a mapping from global id to the cluster id it belongs to. 
#
# An output file cluster_distribution.dat is generated as input for the matlab
# program cluster_distribution.m, which plots the histogram of the cluster distribution. 
##

#### Package declarations ###############################

use strict;
use Test::Harness::Assert;
use Getopt::Long;

use lib '../lib';

$ENV{'PATH'} = "$ENV{'PATH'}" . ":../lib/";

##### Global variables ####

my $g_output_dir;
my $min_latency = 0;
my $max_latency = 100000;
my $input_file;
my $output_file;
my $rank_by_latency_file;
my $rank_by_frequency_file;
my %frequency_hash = ();
my %latency_hash = ();

##### Functions ########

##
# Prints usage options
##
sub print_usage {
    
    print "filter_request_latency.pl --output_dir --min --max\n";
    print "\t--output_dir: Spectroscope output directory\n";
    print "\t--min: minimum request latency\n";
    print "\t--max: maximum request latency\n";
}


##
# Collects command line parameters
##
sub parse_options {
    
    GetOptions("output_dir=s" => \$g_output_dir,
	       "min:f"        => \$min_latency,
	       "max:f"        => \$max_latency);
    
    if(!defined $g_output_dir) {
        print_usage();
        exit(-1);
    }
}


parse_options();

$input_file = "$g_output_dir/convert_data/global_ids_to_cluster_ids.dat";
$output_file = "cluster_distribution.dat";
$rank_by_latency_file = "cluster_rank_by_latency.dat";
$rank_by_frequency_file = "cluster_rank_by_frequency.dat";

open(my $input_fh, "<$input_file")
    or die("Could not open $input_file\n");
open(my $output_fh, ">$output_file")
    or die("Could not open $output_file\n");
open(my $latency_fh, ">$rank_by_latency_file")
    or die("Could not open $rank_by_latency_file\n");
open(my $frequency_fh, ">$rank_by_frequency_file")
    or die("Could not open $rank_by_frequency_file\n");

while(<$input_fh>) {
    chomp;

    if(/(\d+) (\d+) ([0-9\.]+)/) {
	my $global_id = $1;
	my $cluster_id = $2;
	my $req_latency = $3;

	if($req_latency >= $min_latency &&
	   $req_latency <= $max_latency) {

	    if(!defined $frequency_hash{$cluster_id}) {
		$frequency_hash{$cluster_id} = 1;
	    } else {
		$frequency_hash{$cluster_id}++;
	    }

	    if(!defined $latency_hash{$cluster_id}) {
		$latency_hash{$cluster_id} = $req_latency;
	    } else {
		$latency_hash{$cluster_id} += $req_latency;
	    }
	}
    }
}

# calculate average request latency for each cluster
for my $cid (keys %latency_hash) {
    $latency_hash{$cid} /= $frequency_hash{$cid};
}

# output file ranked by cluster IDs
for my $key (sort {$a<=>$b} keys %frequency_hash) {
    printf $output_fh "$key $frequency_hash{$key}\n";
}

# output file ranked by latency
for my $key (sort {$latency_hash{$a}<=>$latency_hash{$b}} keys %latency_hash) {
    printf $latency_fh "$key $latency_hash{$key}\n";
}

# output file ranked by frequency
for my $key (sort {$frequency_hash{$a}<=>$frequency_hash{$b}} keys %frequency_hash) {
    printf $frequency_fh "$key $frequency_hash{$key}\n";
}

close($input_fh);
close($output_fh);
