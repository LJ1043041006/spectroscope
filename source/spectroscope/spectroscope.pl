#!/usr/bin/perl -w

#
# Copyright (c) 2013, Carnegie Mellon University.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
# 3. Neither the name of the University nor the names of its contributors
#    may be used to endorse or promote products derived from this software
#    without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
# A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT
# HOLDERS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
# BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS
# OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED
# AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY
# WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
#

# $cmuPDL: spectroscope.pl,v 1.17 2010/04/07 06:35:36 rajas Exp $

##
# @author Raja Sambasivan and Alice Zheng
#
# Type perl spectroscope -h or ./spectroscope for help
##


#### Package declarations #########################

use strict;
use warnings;
use diagnostics;
use Test::Harness::Assert;
use Getopt::Long;

use lib '../lib';
use define DEBUG => 0;

use SedClustering::CreateClusteringInput;
use ParseDot::ParseRequests;
use ParseDot::PrintRequests;
use PassThrough::PassThrough;
use ParseClusteringResults::ParseClusteringResults;
use CompareEdges::CompareIndivEdgeDistributions;

$ENV{'PATH'} = "$ENV{'PATH'}" . ":../lib/SedClustering/";


#### Global variables ############################

# The directory in which output should be placed
my $g_output_dir;

# The directory the output of hte ConvertRequests module should be placed
my $g_convert_reqs_output_dir;

# The file(s) containing DOT requests from the non-problem period(s)
my @g_snapshot0_files;

# The file(s) containing DOT requests from the problem period(s)
my @g_snapshot1_files;

# Allow user to skip re-converting the input DOT files to the
# format required for this program, if this has been done before.
my $g_reconvert_reqs = 0;

# The module for converting requests into MATLAB compatible format
# for use in the clustering algorithm
my $g_create_clustering_input;

# The module for parsing requests
my $g_parse_requests;

# Whether or not to bypass SeD calculation. If bypassed, 
# "fake" SeD values will be inserted and the (actual) SeD calculation
# will not be performed
my $g_bypass_sed = 0;

# The module for computing string-edit distances between unique representations
# of request-flow graphs, or between clusters
my $g_sed;

# Whether or not to pre-compute all edit stances
my $g_calculate_all_distances = 0;

# Whether or not 1-unique n relationship should be maintained
# when calculating string edit distnaces
my $g_dont_enforce_one_to_n = 0;

#
# The default structural mutation threshold
my $g_mutation_threshold = 50;


#### Main routine #########

# Get input arguments
parse_options();

if (defined $g_snapshot1_files[0]) {
    $g_create_clustering_input = new CreateClusteringInput(\@g_snapshot0_files,
                                                           \@g_snapshot1_files,
                                                           $g_convert_reqs_output_dir);

    $g_parse_requests = new ParseRequests(\@g_snapshot0_files,
                                          \@g_snapshot1_files,
                                          $g_convert_reqs_output_dir);
} else {
    $g_create_clustering_input = new CreateClusteringInput(\@g_snapshot0_files,
                                                           $g_convert_reqs_output_dir);

    $g_parse_requests = new ParseRequests(\@g_snapshot0_files,
                                          \@g_snapshot1_files,
                                          $g_convert_reqs_output_dir);
}

##
# Determine whether clustering input and request indices exist already
##
my $clustering_output_files_exist = $g_create_clustering_input->do_output_files_exist();
my $parse_requests_files_exist = $g_parse_requests->do_output_files_exist();
if($clustering_output_files_exist == 0 || 
   $parse_requests_files_exist == 0 ||
   $g_reconvert_reqs == 1) {
    
    print "Re-translating reqs: parse_requests: $parse_requests_files_exist\n" . 
        "clustering files exist: $clustering_output_files_exist\n";
    
    $g_parse_requests->parse_requests();
    $g_create_clustering_input->create_clustering_input();
}    

##
# Free memory occupied by the g_parse_requests
# and g_clustering_input module
##
undef $g_parse_requests = undef;
$g_create_clustering_input = undef;

#
# Create a new Sed module 
$g_sed = new Sed("$g_convert_reqs_output_dir/input_vector.dat",
                  "$g_convert_reqs_output_dir/input_vector_distance_matrix.dat",
                    $g_bypass_sed);
##
# Perform edit distance calculation, if necessary
##
if (($g_calculate_all_distances == 1) && 
    ($g_sed->do_output_files_exist() == 0 || 
     $g_reconvert_reqs == 1)) {
    $g_sed->calculate_all_edit_distances();
}

# Only "Pass through clustering" is currently supported
my $pass_through_module = new PassThrough($g_convert_reqs_output_dir, 
                                          $g_convert_reqs_output_dir, 
                                          $g_sed);    
$pass_through_module->cluster();

##
# We now need Seds between clusters
# The clustering module should have generated the input files to this module
#
# @bug: There is an abstraction violation here; we should not be using
# input_vector directly, but rather a vector of cluster centers generated by the
# clustering algorithm.  In addition, there would need to be another file that
# maps cluster centers to input vectors, so that the graph corresponding to the
# cluster center could be retrieved.
##
$g_sed = new Sed("$g_convert_reqs_output_dir/input_vector.dat",
                 "$g_convert_reqs_output_dir/cluster_distance_matrix.dat",
                  $g_bypass_sed);

my $g_print_requests = new PrintRequests($g_convert_reqs_output_dir,
                                         \@g_snapshot0_files,
                                         \@g_snapshot1_files);


my $g_parse_clustering_results = new ParseClusteringResults($g_convert_reqs_output_dir,
                                                            $g_print_requests,
                                                            $g_sed,
                                                            $g_dont_enforce_one_to_n,
                                                            $g_mutation_threshold,
                                                            $g_output_dir);



print "Initializng parse clustering results\n";
$g_parse_clustering_results->print_ranked_clusters();

   

### Helper functions #######
#
# Parses command line options
#
sub parse_options {

	GetOptions("output_dir=s"              => \$g_output_dir,
			   "snapshot0=s{1,10}"         => \@g_snapshot0_files,
			   "snapshot1:s{1,10}"         => \@g_snapshot1_files,
               "mutation_threshold:i"      => \$g_mutation_threshold,
			   "reconvert_reqs+"           => \$g_reconvert_reqs,
               "bypass_sed+"               => \$g_bypass_sed,
               "calc_all_edit_dists+"      => \$g_calculate_all_distances,
               "dont_enforce_1_to_n+"      => \$g_dont_enforce_one_to_n);

    # These parameters must be specified by the user
    if (!defined $g_output_dir || !defined $g_snapshot0_files[0]) {
        print_usage();
        exit(-1);
    }

    $g_convert_reqs_output_dir = "$g_output_dir/convert_data";
    system("mkdir -p $g_convert_reqs_output_dir");
}

#
# Prints usage for this perl script
#
sub print_usage {
    print "usage: spectroscope.pl --output_dir, --snapshot0, --snapshot1\n" .
		"\t--dont_reconvert_reqs --bypass_sed --calc_all_dists\n"; 
    print "\n";
    print "\t--output_dir: The directory in which output should be placed\n";
    print "\t--snapshot0: The name(s) of the dot graph output containing requests from\n" .
        "\t the non-problem snapshot(s).  Up to 10 non-problem snapshots can be specified\n";
	print "\t--snapshot1: The name(s) of the dot graph output containing requests from\n" . 
        "\t the problem snapshot(s).  Up to 10 problem snapshots can be specified. (OPTIONAL)\n";
    print "\t--reconvert_reqs: Re-indexes and reconverts requests for\n" .
        "\t fast access and MATLAB input (OPTIONAL)\n";
    print "\t--bypass_sed: Whether to bypass SED calculation (OPTIONAL)\n";
    print "\t--calc_all_distances: Whether all edit distances should be pre-computed\n" .
        "\t or calculated on demand (OPTIONAL)\n";
    print "\t--mutation_threshold: Threshold for identifying a cluster as containing mutations\n".
        "or originators\n";
    print "\t--dont_enforce_1_to_n: 1 to N requirement for identifying originators is not enforced\n";
}
