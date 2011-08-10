#! /usr/bin/perl -w

# $cmuPDL: ParseClusteringResults.pm,v 1.38.4.1 2011/07/20 18:27:54 rajas Exp $

##
# This Perl module implements routines for parsing the results
# of a clustering operation.  It takes in as input the 
# clustering results and a ranking scheme.  It then prints out
# two files
#  File 1: Ranked cluster info, which contains: 
#   <cluster num>, <num requests in s0>, <num requests in s1>, <avg. latency s0>
#   <avg. latency s1>.
#  File 2: Dot graphs of the cluster representatives, ranked according
#  to the scheme specified.
##

package ParseClusteringResults;

use strict;
use Cwd;
use Test::Harness::Assert;
use Statistics::Descriptive;
use diagnostics;
use Data::Dumper;
use SedClustering::Sed;
use StatisticalTests::HypothesisTest;
use ParseClusteringResults::CreateHypothesisTestInputs 
    qw[add_latency_comparison get_comparison_results];
use ParseClusteringResults::IdentifyMutations
    qw[identify_mutations get_mutation_type is_response_time_change is_structural_mutation
       is_originating_cluster is_mutation];
use List::Util qw(sum);


#### Global constants #############

# Import value of DEBUG if defined
no define DEBUG =>;

my $G_REQS_IN_LARGE_CLUSTERS = 10;

#### Private functions ############

##
# Given an input vector id, this function returns the global ids that map to it
#
# @param self: The object identifier
# @param input_vector_id: The input vector id
#
# @return a pointer to an array of global ids that map to the input
# vector id passed in
##
my $_get_global_ids = sub {
    
    assert(scalar(@_) == 2);

    my $self = shift;
    my $input_vector_id = shift;

    my $input_vec_to_global_ids_hash = $self->{INPUT_VEC_TO_GLOBAL_IDS_HASH};
    my $global_ids_string = $input_vec_to_global_ids_hash->{$input_vector_id};
    my @global_ids = split(/,/, $global_ids_string);
    
    assert(scalar(@global_ids) > 0);

    return \@global_ids;
};


##
# Returns the global IDs of all requests assugned to a cluster
#
# @param self: The object-container
# @param cluster_id: The global IDs of requests that
#  belong to this cluster will be returned
#
# @return A reference to an array of global IDs
##
my $_get_global_ids_of_reqs_in_cluster = sub {
    
    assert(scalar(@_) ==2);
    my ($self, $cluster_id) = @_;
    
    my $cluster_assignment_hash = $self->{CLUSTER_HASH};
    
    my @input_vec_ids = split(/,/, $cluster_assignment_hash->{$cluster_id});
    
    my @global_ids;
    
    # Iterate through the input vectors that are assigned to each cluster
    # and build a list of matching global IDs.
    foreach(@input_vec_ids) {
        
        my $input_vector_id = $_;

        # Get the global IDs that map to this input_vec_id
        my $input_vec_global_ids = $self->$_get_global_ids($input_vector_id);

        # Add global ids to the list of global IDs for this cluster
        @global_ids = (@global_ids, @$input_vec_global_ids);
    }
    
    return \@global_ids;
};


##
# Computes the probability of a cluster in a period
#
# @param $part: Num requests belonging to the 
#  input cluster from the requisite period(s)
# @param $whole: Number of reqs seen in the period(s)
##
my $_compute_cluster_prob = sub {

    assert(scalar(@_) == 3);
    my ($self, $part, $whole) = @_;
    return (($whole == 0)? 0 : ($part/$whole))
};
    

##
# Computes statistics on each cluster and stores them in 
# $self->{CLUSTER_INFO_HASH}.  Specifically, 
# $self->{CLUSTER_INFO_HASH} stores a hash for each cluster
# that is keyed by cluster_id and which contains the following 
# information: 
#
#    \@frequencies: Distribution of requests from s0 and s1 in this cluster.
#    \@avg_latency: The average latency of requests from s0 and s1
#    \@edges: A index showing the edges in this cluster, their average
#             latency in each snaphot, and the result of a statistical test
#             that indicates whether the edge latencies for the edge are
#             statistically different
#
# @param self: The object-container
##
my $_compute_cluster_info = sub {

    assert(scalar(@_) == 2);
    my ($self, $compare_reqs) = @_;

    my $cluster_assignment_hash = $self->{CLUSTER_HASH};
    my $graph_info = $self->{PRINT_GRAPHS_CLASS};
    my %cluster_info_hash;

    # Get the total number of requests in each dataset
    my $total_requests = $graph_info->get_snapshot_frequencies();

    # Create a new hypothesis test object for comparing edge latencies and
    # response times within clusters
    my $latency_comparisons = new HypothesisTest("latency_comparisons", $self->{INTERIM_OUTPUT_DIR});

    foreach my $key (sort {$a <=> $b} keys %$cluster_assignment_hash) {
        print "Processing statistics for Cluster $key...\n";

        my @global_ids = @{$self->$_get_global_ids_of_reqs_in_cluster($key)};
        my $response_times = $graph_info->get_response_times_given_global_ids(\@global_ids);

        # Get frequencies, probabilities, and avg. response times for this cluster
        my @cluster_freqs;
        $cluster_freqs[0] = @{$response_times->{S0_RESPONSE_TIMES}};
        $cluster_freqs[1] = @{$response_times->{S1_RESPONSE_TIMES}};
        my @cluster_probs;
        $cluster_probs[0] = $self->$_compute_cluster_prob($cluster_freqs[0], $total_requests->[0]);
        $cluster_probs[1] = $self->$_compute_cluster_prob($cluster_freqs[1], $total_requests->[1]);

        my $s0_stat = Statistics::Descriptive::Full->new();
        $s0_stat->add_data($response_times->{S0_RESPONSE_TIMES});
        my $s1_stat = Statistics::Descriptive::Full->new();
        $s1_stat->add_data($response_times->{S1_RESPONSE_TIMES});
        
        my @avg_response_times;       
        $avg_response_times[0] = ($cluster_freqs[0] == 0)? 0 : $s0_stat->mean();
        $avg_response_times[1] = ($cluster_freqs[1] == 0)? 0 : $s1_stat->mean();

        my @stddevs;
        $stddevs[0] = ($cluster_freqs[0] == 0)? 0 : sqrt($s0_stat->variance());
        $stddevs[1] = ($cluster_freqs[1] == 0)? 0 : sqrt($s1_stat->variance());
            
        my %this_cluster_info;
        if ($compare_reqs) {
            my %edge_name_to_row_num_hash;
            my %row_num_to_edge_name_hash;
            my $comparison_id = 
                CreateHypothesisTestInputs::add_latency_comparison($key, \@global_ids, $response_times,
                                                                   \%edge_name_to_row_num_hash,
                                                                   \%row_num_to_edge_name_hash,
                                                                   $latency_comparisons, $graph_info);
            $this_cluster_info{COMPARISON_ID} = $comparison_id;
            $this_cluster_info{ROW_NUM_TO_EDGE_NAME_HASH} = \%row_num_to_edge_name_hash;
        }
        $response_times = undef;

        # Fill in the hash describing this cluster
        my $gid = $self->get_global_id_of_cluster_rep($key);
        $this_cluster_info{ROOT_NODE} = $graph_info->get_root_node_given_global_id($gid);
        $this_cluster_info{FREQUENCIES} = \@cluster_freqs;
        $this_cluster_info{LIKELIHOODS} = \@cluster_probs;
        $this_cluster_info{AVG_RESPONSE_TIMES} = \@avg_response_times;           
        $this_cluster_info{STDDEVS} = \@stddevs;
        $this_cluster_info{ID} = $key;        
        $cluster_info_hash{$key} = \%this_cluster_info;
    }

    # Run hypothesis test for comparing latencies and add results to hash
    if ($compare_reqs) {
        $latency_comparisons->run_kstest2();
        foreach my $key (sort {$a <=> $b} keys %cluster_info_hash) {
            
            my $this_cluster_info = $cluster_info_hash{$key};
            my $comparison_stats = 
                CreateHypothesisTestInputs::get_comparison_results($this_cluster_info->{COMPARISON_ID},
                                                                   $this_cluster_info->{ROW_NUM_TO_EDGE_NAME_HASH},
                                                                   $latency_comparisons);
            delete $this_cluster_info->{ROW_NUM_TO_EDGE_NAME_HASH};
            
            $this_cluster_info->{RESPONSE_TIME_STATS} = $comparison_stats->{RESPONSE_TIME_STATS};
            $this_cluster_info->{EDGE_LATENCY_STATS} = $comparison_stats->{EDGE_LATENCY_STATS};
        }
        IdentifyMutations::identify_mutations(\%cluster_info_hash, $self->{SED_CLASS}, 
                                              $self->{INTERIM_OUTPUT_DIR},
                                              $self->{DONT_ENFORCE_ONE_TO_N},
                                              $self->{MUTATION_THRESHOLD},
                                              $total_requests->[0] + $total_requests->[1]);
    }
    $self->{CLUSTER_INFO_HASH} = \%cluster_info_hash;
};


## 
# Extracts clusters that represent just mutations and response-time changes and
# places them in their own hash ($self->{MUTATION_HASH}.  Clusters that
# represent both a response-time change and a structural mutation need to be
# "unrolled."  That is, seperate entries must be created in the mutation hash
# for the portion of structural mutation cost and for the response-time change
# cost.
#
# @param self: The object container
# @param use_weighted_cost: 1 if weighted costs should be used for
#  the cost of structural mutations, 0 otherwise
##
my $_create_mutation_hash = sub {

    assert(scalar(@_) == 2);
    my ($self, $use_weighted_costs) = @_;

    my $cluster_info = $self->{CLUSTER_INFO_HASH};

    # Response-time changes and structural mutations need to be ranked together.
    # We need to build up a hash that contains seperate elements for clusters that are 
    # both response-time changes and structural mutations.  We're essentially 
    # "unrolling" the hash structure.
    my %mutation_hash;
    for my $id (keys %{$cluster_info}) {

        my $this_cluster_info = $cluster_info->{$id};

        if(IdentifyMutations::is_structural_mutation($cluster_info, $id)) {
            my $unrolled_id = $id . "_s";

            my $cost = IdentifyMutations::get_structural_mutation_cost($cluster_info, $id, $use_weighted_costs);            
            my $originators = IdentifyMutations::get_originators($cluster_info, $id, $use_weighted_costs);
            $mutation_hash{$unrolled_id} = { CLUSTER => $this_cluster_info,
                                             COST => $cost,
                                             MUTATION_TYPE => "Structural mutation",
                                             ORIGINATORS => $originators,
                                             ID => $id,
                                         };
        }
        
        if(IdentifyMutations::is_response_time_change($cluster_info, $id)) {
            my $unrolled_id = $id . "_r";
            my $cost = IdentifyMutations::get_response_time_change_cost($cluster_info, $id);
            $mutation_hash{$unrolled_id} = { CLUSTER => $this_cluster_info,
                                             COST => $cost,
                                             MUTATION_TYPE => "Response time change",
                                             ID => $id
                                             };
        }
    }

    return \%mutation_hash;
};


##
# Loads the following input files into hashes for use by
# the other functions in this class: 
#    $self->{CLUSTERS_FILE} is loaded into $self->{CLUSTER_HASH}
#    $self->{INPUT_VEC_TO_GLOBAL_IDS_FILE} is loaded into 
#    $self->{INPUT_VEC_TO_GLOBAL_IDS_HASH}
#
# $self->{CLUSTERS_FILE} contains information about each cluster.  Each
# row represents a cluster and contains INPUT_VECTOR_IDs of the requests
# assigned to that cluster.
#
# Each line of $self->{INPUT_VEC_TO_GLOBAL_IDS_FILE} reprresents a 
# INPUT_VECTOR_ID and the numbers on each line represent the GLOBAL_IDs
# that map to the INPUT_VECTOR_IDs
#
# It is assumed that cluster ids and input vector ids are 1-indexed
#
# @param self: The object-container
##
my $_load_files_into_hashes = sub {
    assert(scalar(@_) == 1);

    my $self = shift;
    
    # Open input file
    open (my $clusters_fh, "<$self->{CLUSTERS_FILE}") 
        or die("Could not open $self->{CLUSTERS_FILE}\n");
    open (my $input_vec_to_global_ids_fh, "<$self->{INPUT_VEC_TO_GLOBAL_IDS_FILE}")
        or die("Could not open $self->{INPUT_VEC_TO_GLOBAL_IDS_FILE}");
    
    # load $self->{CLUSTERS_FILE};
    my %cluster_hash;
    my $cluster_num = 0;
    while(<$clusters_fh>) {
        $cluster_num++;
        chomp;
        my @cluster_items = split(' ', $_);
        my $hash_item = join(',', @cluster_items);
        
        $cluster_hash{$cluster_num} = $hash_item;
    }
    close($clusters_fh);
    $self->{CLUSTER_HASH} = \%cluster_hash;
    $self->{NUM_CLUSTERS} = $cluster_num;

    # load $self->{INPUT_VEC_TO_GLOBAL_IDS_HASH}
    my %input_vec_to_global_ids_hash;
    my $input_vec_num = 1;
    while (<$input_vec_to_global_ids_fh>) {
        chomp;
        my @hash_item = split(/ /, $_);

        $input_vec_to_global_ids_hash{$input_vec_num} = join(',', @hash_item);
        $input_vec_num++;
    }
    close($input_vec_to_global_ids_fh);
    $self->{INPUT_VEC_TO_GLOBAL_IDS_HASH} = \%input_vec_to_global_ids_hash;
    
    
    $self->{INPUT_HASHES_LOADED} = 1;
};


##
# Prints the cluster representative of the cluster specified
#
# @param self: The object-container
# @param cluster_id: The cluster to print
# @param specific_mutation_type: A string indicating the specific mutation type being considered
# @param cost: The cost of this specific mutation type
# @param out_fh: The filehandle to which the graph should be printed
##
my $_print_graph = sub {
    assert(scalar(@_) == 6);
    my ($self, $cluster_id, $specific_mutation_type, $cost, $originators, $out_fh) = @_;

    my $print_graphs_class = $self->{PRINT_GRAPHS_CLASS};
    my $cluster_info = $self->{CLUSTER_INFO_HASH}->{$cluster_id};


    # Get the graph representation of the cluster.  This is the request
    # that corresponds to the first input vector id specified in the
    # cluster hash.
    my $cluster_hash = $self->{CLUSTER_HASH};
    my $input_vec_to_global_ids_hash = $self->{INPUT_VEC_TO_GLOBAL_IDS_HASH};
    my @input_vecs = split(/,/, $cluster_hash->{$cluster_id});
    my @global_ids = split(/,/, $input_vec_to_global_ids_hash->{$input_vecs[0]});


    my $mutation_type_string = $self->get_mutation_type($cluster_id);

    # Create the summary node
    my $summary_node = 
        PrintRequests::create_summary_node($cluster_id,
                                           $cluster_info->{RESPONSE_TIME_STATS},
                                           $cluster_info->{LIKELIHOODS},
                                           $cluster_info->{FREQUENCIES},                             
                                           $specific_mutation_type,
                                           $mutation_type_string,
                                           $cost,
                                           $originators);

    # Print the graph w/overlay info
    my %overlay_hash = (SUMMARY_NODE => $summary_node,
                        EDGE_STATS => $cluster_info->{EDGE_LATENCY_STATS});
    $print_graphs_class->print_global_id_indexed_request($global_ids[0], 
                                                         $out_fh,
                                                         \%overlay_hash);
};



##
# Prints all clusters that are neither response-time changes, structural mutations,
# or originating clusters.  I.e., "Not interesting clusters"
#
# @param self: The object-container
# @param output_file: The file to which to print the graphs
##
my $_print_graphs_of_non_interesting_clusters = sub {
    
    assert(scalar(@_) == 2);
    my ($self, $output_file) = @_;
    
    my $cluster_info_hash_ref = $self->{CLUSTER_INFO_HASH};
    open(my $output_fh, ">$output_file");

    for my $key (sort {$a <=> $b} keys %{$cluster_info_hash_ref}) {
        if(IdentifyMutations::is_mutation($cluster_info_hash_ref, $key)) {
            $self->$_print_graph($key,
                                 "None",
                                 0,
                                 "",
                                 $output_fh);
        }
    }

    close($output_fh);
};


##
# Prints all clusters marked as being of type "RESPONSE_TIME_CHANGE"
#
# @param self: The object-container
# @param mutation_hash_ref: Reference to a hash containing all of the 
# structural mutations and response-time changes and their costs
# @output_file: The file to which to print the grpahs
##
my $_print_graphs_of_clusters_with_response_time_changes = sub {

    assert(scalar(@_) == 3);
    my ($self, $mutation_hash_ref, $output_file) = @_;

    open(my $output_fh, ">$output_file");
    my $cluster_info_hash_ref = $self->{CLUSTER_INFO_HASH};

    # sort in descending order
    for my $key (sort {$mutation_hash_ref->{$b}->{COST} <=> $mutation_hash_ref->{$a}->{COST}}
                 keys %{$mutation_hash_ref}) {

        if ($mutation_hash_ref->{$key}->{MUTATION_TYPE} eq "Response time change") {

            $self->$_print_graph($mutation_hash_ref->{$key}->{ID},
                                 $mutation_hash_ref->{$key}->{MUTATION_TYPE},
                                 $mutation_hash_ref->{$key}->{COST},
                                 "",
                                 $output_fh);
        }
    }
    close($output_fh);
};


##
# Prints all clusters marked as being of type "STRUCTURAL MUTATION"
#
# @param self: The object-container
# @param mutation_hash_ref: Reference to a hash containing all of the structural
#  mutations and tehir response-time changes and their costs
# @param output_file: The file to which to print the graphs
##
my $_print_graphs_of_clusters_with_structural_mutations = sub {

    assert(scalar(@_) == 3);
    my($self, $mutation_hash_ref, $output_file) = @_;

    open(my $output_fh, ">$output_file");
    my $cluster_info_hash_ref = $self->{CLUSTER_INFO_HASH};

    # sort in descending order
    for my $key (sort {$mutation_hash_ref->{$b}->{COST} <=> $mutation_hash_ref->{$a}->{COST}}
                 keys %{$mutation_hash_ref}) {

        if($mutation_hash_ref->{$key}->{MUTATION_TYPE} eq "Structural mutation") {

            $self->$_print_graph($mutation_hash_ref->{$key}->{ID}, 
                                 $mutation_hash_ref->{$key}->{MUTATION_TYPE},
                                 $mutation_hash_ref->{$key}->{COST},
                                 $mutation_hash_ref->{$key}->{ORIGINATORS},
                                 $output_fh);
        }
    }
    close ($output_fh);
};


##
# Prints graphs of all clusters marked as being of type "Structural Mutation"
# or "Response-time Change."  These mutations are ranked together.
#
# @param self: The object container
# @param mutation_hash_ref: Reference to a hash containing all of the
#  structural mutations and response-time changes and their costs
# @param output_file: The file to which to print the graphs
##
my $_print_combined_ranked_graphs_of_mutations = sub {

    assert(scalar(@_) == 3);
    my ($self, $mutation_hash_ref, $output_file) = @_;
    
    my $cluster_info_hash_ref =$self->{CLUSTER_INFO_HASH};
    open(my $output_fh, ">$output_file");

    for my $key (sort {$mutation_hash_ref->{$b}->{COST} <=> $mutation_hash_ref->{$a}->{COST}}
                 keys %{$mutation_hash_ref}) {

        my $originators = (defined $mutation_hash_ref->{$key}->{ORIGINATORS})? 
            $mutation_hash_ref->{$key}->{ORIGINATORS}: "";

        $self->$_print_graph($mutation_hash_ref->{$key}->{ID},
                             $mutation_hash_ref->{$key}->{MUTATION_TYPE},
                             $mutation_hash_ref->{$key}->{COST},
                             $originators,
                             $output_fh);
    }

    close ($output_fh);
};


## 
# Prints graphs of all clusters marked as being of type "Originating Cluster"
#
# @param self: The object container
# @param output_file: The file to which ot print the graphs
##
my $_print_graphs_of_originating_clusters = sub {

    assert(scalar(@_) == 2);
    my ($self, $output_file) = @_;

    open(my $output_fh, ">$output_file");
    my $cluster_info_hash_ref = $self->{CLUSTER_INFO_HASH};

    for my $key (sort {$a <=> $b} keys %{$cluster_info_hash_ref}) {
        
        if(IdentifyMutations::is_originating_cluster($cluster_info_hash_ref,
                                                     $key)) {
            $self->$_print_graph($key,
                                 "Originating cluster",
                                 0,
                                 "",
                                 $output_fh);

            my $this_cluster_info = $cluster_info_hash_ref->{$key};

        }
    }
    close($output_fh);
};


##
# Prints a text-file containing statistics about all clusters.  This version
# assumes request-flow comparison has not been run.
#
# @param self: The object container
##
my $_print_cluster_info = sub {
    assert(scalar(@_) == 1);
    my ($self) = @_;

    my $cluster_info_hash_ref = $self->{CLUSTER_INFO_HASH};
    my $graph_info = $self->{PRINT_GRAPHS_CLASS};

    my $num_small_clusters = 0;
    my $num_reqs_in_small_clusters = 0;
    my $total_reqs = 0;

    open(my $out_fh, ">$self->{CLUSTER_INFO_TEXT_FILE}") or 
        die "ParseClusteringResults: _print_cluster_info(): could not open " .
        "$self->{CLUSTER_INFO_TEXT_FILE}.  $!\n";

    # print the header to the output
    printf $out_fh "%-15s\t%-20s\t%-20s\t%-15s\t%-15s\t%-15s\t%-15s\n",
    "cluster_id", "s0_likelh", "s1_likelh", "s0_avg_lat", 
    "s1_avg_lat", "s0_stddev", "s1_stddev", "s0_freq", "s1_freq";

    for my $key (sort {$a <=> $b} keys %{$cluster_info_hash_ref}) {
        my $this_cluster_hash_ref = $cluster_info_hash_ref->{$key};

        my $likelihoods = $this_cluster_hash_ref->{LIKELIHOODS};
        my $avg_response_times = $this_cluster_hash_ref->{AVG_RESPONSE_TIMES};
        my $stddevs = $this_cluster_hash_ref->{STDDEVS};
        my $freqs = $this_cluster_hash_ref->{FREQUENCIES};
        
        printf $out_fh "%-15d\t%-1.14f\t%-1.14f\t%-12.3f\t%-12.3f\t%-12.3f\t%-12.f\t%-12.3f\t%-12.3f\n",
        $key, $likelihoods->[0], $likelihoods->[1], 
        $avg_response_times->[0], $avg_response_times->[1],
        $stddevs->[0], $stddevs->[1],
        $freqs->[0], $freqs->[1];
    }
    close($out_fh);
};

   
##
# Prints a text-file containing statistics about all clusters.  Assumes
# request-flow comparison has been run to identify mutations.
#
# @param self: The object container
##
my $_print_compared_cluster_info = sub {
    
    assert( scalar(@_) == 1);
    my ($self) = @_;
    
    my $cluster_info_hash_ref = $self->{CLUSTER_INFO_HASH};
    my $graph_info = $self->{PRINT_GRAPHS_CLASS};

    # Information about statistical tests run
    my $num_clusters_kstest_not_run = 0;
    my $num_reqs_kstest_not_run = 0;
    my $num_small_clusters = 0;
    my $num_reqs_in_small_clusters = 0;
    my $total_reqs = 0;

    open (my $out_fh, ">$self->{CLUSTER_INFO_TEXT_FILE}") or 
        die "ParseClusterResults: _compared_cluster_info(): could not open " .
        "$self->{CLUSTER_COMPARISON_INFO_TEXT_FILE}.  $!\n";
    
    # Print the header to the output
    printf $out_fh "%-15s\t%-40s\t%-20s\t%-20s\t%-15s\t%-15s\t%-15s\t%-15s\t%-15s\t%-15s\n",
    "cluster_id", "mutation_type", "s0_likelh", "s1_likelh", "s0_avg_lat", 
    "s1_avg_lat", "s0_stddev", "s1_stddev", "s0_freq", "s1_freq";
    
    for my $key (sort {$a <=> $b} keys %{$cluster_info_hash_ref}) {
        
        my $this_cluster_hash_ref = $cluster_info_hash_ref->{$key};
        
        my $likelihoods = $this_cluster_hash_ref->{LIKELIHOODS};
        my $mutation_type_string  = $self->get_mutation_type($key);        
        my $response_time_stats = $this_cluster_hash_ref->{RESPONSE_TIME_STATS};
        my $freqs = $this_cluster_hash_ref->{FREQUENCIES};
        
        printf $out_fh "%-15d\t%-40s\t%-1.14f\t%-1.14f\t%-12.3f\t%-12.3f\t%-12.3f\t%-12.3f\t%-12.3f\t%-12.3f\n",
        $key, $mutation_type_string, $likelihoods->[0], $likelihoods->[1], 
        $response_time_stats->{AVGS}->[0], $response_time_stats->{AVGS}->[1],
        $response_time_stats->{STDDEVS}->[0], $response_time_stats->{STDDEVS}->[1],
        $freqs->[0], $freqs->[1];


        # Gather information about the statistical tests run
        # these will be printed out in $self->{AGGREGATE_INFO_TEST_FILE}.
        if ($freqs->[0] == 0 || $freqs->[1] == 0 ||
            (($freqs->[0] * $freqs->[1])/($freqs->[0] + $freqs->[1]) < 4)) {
            
            # We assume that lib/StatisticalTests/HypothesisTest.pm runs 
            # a Kolomogrov Smirnov test to identify response-time mutations.
            # Kolomogrov Smirnov tests cannot be run if the conditions in the 
            # above "if" are met.
            $num_clusters_kstest_not_run++;
            $num_reqs_kstest_not_run += $freqs->[0] + $freqs->[1];
        }
        if($freqs->[0] < $G_REQS_IN_LARGE_CLUSTERS || $freqs->[1] < $G_REQS_IN_LARGE_CLUSTERS) {
            $num_small_clusters++;
            $num_reqs_in_small_clusters += $freqs->[0] + $freqs->[1];
        }
        $total_reqs = $freqs->[0] + $freqs->[1];
    }
    close($out_fh);
    
    open ($out_fh, ">$self->{AGGREGATE_INFO_TEST_FILE}") or
        die "ParseClusteringResults: _print_compared_cluster_info(): could not open " .
             "$self->{AGGREGATE_INFO_TEST_FILE}.  $!\n";             
    
    my $num_clusters = keys %{$cluster_info_hash_ref};
    printf $out_fh "Number of clusters for which response-time mutations could not be identified: %d (%3.2f)\n",
    $num_clusters_kstest_not_run, $num_clusters_kstest_not_run/$num_clusters;
    printf $out_fh "Number of requests for which response-time mutation tests could not be run: %d (%3.2f)\n\n",
    $num_reqs_kstest_not_run, $num_reqs_kstest_not_run/$total_reqs;
    printf $out_fh "Number of small clusters (with less than $G_REQS_IN_LARGE_CLUSTERS requests): %d (%3.2f)\n",
    $num_small_clusters, $num_small_clusters/$num_clusters;
    printf $out_fh "Number of reqs in small clusters (with less $G_REQS_IN_LARGE_CLUSTERS requests): %d (%3.2f)\n",
    $num_reqs_in_small_clusters, $num_reqs_in_small_clusters/$total_reqs;

    close($out_fh);

};


#### API functions ################

##
# Constructor for the ParseClusteringResults class
#
# @param proto: The class identifier
#
# @param clusters_file: File containing cluster assignments
# 
# @param input_vector_file: File containing MATLAB compatible
# representations of requests and how many requests from
# each snapshot map to each representation.  Each row
# of this file looks like:
#  <# of s0 reqs> <# of s1 reqs> <MATLAB compatible rep>
#
# @param input_vec_to_global_ids_file: File mapping MATLAB
# compatible representations of requests to the Global IDs
# of those requests
# 
# @param rank_format: One of "req_difference,"
# "avg_latency_difference," or "total_latency_difference"
#
# @param print_graphs_class: The class used to print and
# obtain information about the input request-flow gaphs
#
# @param sed_class: An object that can be used to retrieve edit
#  distances betwee nclusters
#
# @param output_dir: The directory in which the output files 
# should be placed
##
sub new {

    assert(scalar(@_) == 7);

    my ($proto, $convert_data_dir, $print_graphs_class, $sed_class,
        $dont_enforce_one_to_n, $mutation_threshold, $output_dir) = @_;

    my $class = ref($proto) || $proto;
    my $self = {};

    $self->{CLUSTERS_FILE} = "$convert_data_dir/clusters.dat",
    $self->{INPUT_VECTOR_FILE} = "$convert_data_dir/input_vector.dat",
    $self->{INPUT_VEC_TO_GLOBAL_IDS_FILE} = "$convert_data_dir/input_vec_to_global_ids.dat",;
    $self->{OUTPUT_DIR} = $output_dir;
    $self->{PRINT_GRAPHS_CLASS} = $print_graphs_class;

    $self->{SED_CLASS} = $sed_class;
    
    # Hashes that will be maintained.  These hashes
    # are loaded from text files.
    $self->{CLUSTER_HASH} = undef;
    $self->{INPUT_VEC_TO_GLOBAL_IDS_HASH} = undef;
    $self->{INPUT_HASHES_LOADED} = 0;

    $self->{NUM_CLUSTERS} = undef;

    # These hashes are computed by the cluster
    $self->{CLUSTER_INFO_HASH} = undef;

    # Some derived outputs

    $self->{INTERIM_OUTPUT_DIR} = "$output_dir/interim_cluster_data";

    $self->{ORIGINATING_CLUSTERS_GRAPH_FILE} = "$output_dir/originating_clusters.dot";
    $self->{NOT_INTERESTING_GRAPH_FILE} = "$output_dir/not_interesting_clusters.dot";
    $self->{CLUSTER_COMPARISON_INFO_TEXT_FILE} = "$output_dir/cluster_comparison_info.dat";
    $self->{CLUSTER_INFO_TEXT_FILE} = "$output_dir/cluster_info.dat";
    $self->{RESPONSE_TIME_CHANGES_GRAPH_FILE} = "$output_dir/weighted_response_time_changes.dot";
    $self->{AGGREGATE_INFO_TEST_FILE} = "$output_dir/statistical_tests_run_info.dat";

    $self->{UNWEIGHTED_STRUCTURAL_MUTATIONS_GRAPH_FILE} = "$output_dir/unweighted_structural_mutations.dot";
    $self->{UNWEIGHTED_COMBINED_GRAPH_FILE} = "$output_dir/unweighted_combined_ranked_graphs.dot";

    $self->{WEIGHTED_STRUCTURAL_MUTATIONS_GRAPH_FILE} = "$output_dir/weighted_structural_mutations.dot";
    $self->{WEIGHTED_COMBINED_GRAPH_FILE} = "$output_dir/weighted_combined_ranked_graphs.dot";

    $self->{ALL_CLUSTERS_GRAPH_FILE} = "$output_dir/all_clusters.dot";

    $self->{DONT_ENFORCE_ONE_TO_N} = $dont_enforce_one_to_n;
    $self->{MUTATION_THRESHOLD} = $mutation_threshold;

    # Create the interim output directory
    system("mkdir -p $self->{INTERIM_OUTPUT_DIR}") == 0 or 
        die ("ParseClusteringResults.pm: new: Could not create" .
             " $self->{INTERIM_OUTPUT_DIR}.  $!\n");
    
    bless($self, $class);
    
    return $self;
}


##
# Clears this object of any data it has computed
# 
# @param self: The object container
##
sub clear {
    assert(scalar(@_) == 1);

    my $self = shift;

    # Undef hashes of input files
    undef $self->{CLUSTER_HASH};
    undef $self->{INPUT_VEC_TO_GLOBAL_IDS_HASH};
    $self->{INPUT_HASHES_LOADED} = 0;

    undef $self->{NUM_CLUSTERS};

    # undef hashes computed by this cluster
    undef $self->{CLUSTER_INFO_HASH};
}


##
# Compares requests from the non-problem period and problem period.  Identifies
# structural mutations and response-time mutations and ranks them according to
# their contribution to the performance change.
#
# @param self: The object-container
##
sub compare_clusters {
    assert(scalar(@_) == 1);
    
    my ($self) = @_;

    if($self->{INPUT_HASHES_LOADED} == 0) {
        $self->$_load_files_into_hashes();
    }
    if(!defined $self->{CLUSTER_INFO_HASH}) {
        $self->$_compute_cluster_info(1);
    }

    my $unweighted_mutation_hash = 
        $self->$_create_mutation_hash(0);
    my $weighted_mutation_hash = 
        $self->$_create_mutation_hash(1);

    # First print graphs of originators and information
    # all of the clusters
    $self->$_print_compared_cluster_info();

    $self->$_print_graphs_of_originating_clusters($self->{ORIGINATING_CLUSTERS_GRAPH_FILE});
    $self->$_print_graphs_of_non_interesting_clusters($self->{NOT_INTERESTING_GRAPH_FILE});
    $self->$_print_graphs_of_clusters_with_response_time_changes($unweighted_mutation_hash,
                                                                 $self->{RESPONSE_TIME_CHANGES_GRAPH_FILE});
    # Print ranked graphs w/o weights        
    $self->$_print_graphs_of_clusters_with_structural_mutations($unweighted_mutation_hash,
                                                                $self->{UNWEIGHTED_STRUCTURAL_MUTATIONS_GRAPH_FILE});
    $self->$_print_combined_ranked_graphs_of_mutations($unweighted_mutation_hash,
                                                       $self->{UNWEIGHTED_COMBINED_GRAPH_FILE});

    # Print graphs w/weights
    $self->$_print_graphs_of_clusters_with_structural_mutations($weighted_mutation_hash,
                                                                $self->{WEIGHTED_STRUCTURAL_MUTATIONS_GRAPH_FILE});
    $self->$_print_combined_ranked_graphs_of_mutations($weighted_mutation_hash,
                                                       $self->{WEIGHTED_COMBINED_GRAPH_FILE});
}


##
# This function prints out information about the clusters observed.  It does not
# perform request-flow comparison to identify mutations.  Clusters can be ranked
# according to one of several metrics {RESPONSE TIMES, TOTAL COUNT, NON-PROBLEM
# COUNT, PROBLEM COUNT}.
#
# @param self: The object container
##
sub print_clusters {
    assert(scalar(@_) == 1);
    my ($self) = @_;

    if ($self->{INPUT_HASHES_LOADED} == 0) {
        $self->$_load_files_into_hashes();
    }
    if(!defined $self->{CLUSTER_INFO_HASH}) {
        $self->$_compute_cluster_info(0);
    }
    $self->$_print_cluster_info();

    # Print out graph representation of each cluster @rajas: This is a hack.
    # This work should be done in a function.  Also, an overlay should be
    # specified so that information about the cluster is added to a 'header'
    # obove the graph.
    open (my $out_fh, ">$self->{ALL_CLUSTERS_GRAPH_FILE}") or 
        die "print_clusters(): could not open $self->{ALL_CLUSTERS_GRAPH_FILE}.  $!\n";    
    for my $key (sort {$a <=> $b} keys %{$self->{CLUSTER_INFO_HASH}}) {
        my @input_vecs = split(/,/, $self->{CLUSTER_HASH}->{$key});
        my @global_ids = split(/,/, $self->{INPUT_VEC_TO_GLOBAL_IDS_HASH}->{$input_vecs[0]});
        $self->{PRINT_GRAPHS_CLASS}->print_global_id_indexed_request($global_ids[0],
                                                                     $out_fh);
    }
    close($out_fh);
}


##
# Returns the total number of clusters that exist
# 
# @param self: The object-container
#
# @return: The number of clusters managed by this object
##
sub get_num_clusters {

    assert(scalar(@_) == 1);
    my ($self) = @_;

    if($self->{INPUT_HASHES_LOADED} == 0) {
        $self->$_load_files_into_hashes();
    }
    assert(defined $self->{NUM_CLUSTERS});
    return $self->{NUM_CLUSTERS};
}


##
# Returns the total number of requests assigned to a cluster
#
# @param self: The object container
# @param cluster_id: The number of requests belonging to this
#  cluster will be returned
#
# @return: The number of requests belonging to the cluster
##
sub get_num_requests_in_cluster {

    assert(scalar(@_) == 2);
    my ($self, $cluster_id) = @_;

    if($self->{INPUT_HASHES_LOADED} == 0) {
        $self->$_load_files_into_hashes();
    }

    my @global_ids = @{$self->$_get_global_ids_of_reqs_in_cluster($cluster_id)};
    
    return scalar(@global_ids);
}

##
# Returns the cluster representative of a cluster, given its ID
#
# @param cluster_id: [1...N]
#
# @return the global ID of the cluster representative
#
# @note: This function is pretty hacked up; should make it more formal
# $self->{CLUSTER_HASH} should contain the global_id of the cluster rep,
# or if the cluster representative is not a traditional request-flow graph,
# a pointer to a string representative of it.  This functio should return
# a string containing the representative
##
sub get_global_id_of_cluster_rep {

    assert(scalar(@_) == 2);
    my ($self, $cluster_id) = @_;

    if($self->{INPUT_HASHES_LOADED} == 0) {
        $self->$_load_files_into_hashes();
    }

    my $cluster_hash = $self->{CLUSTER_HASH};
    my $input_vec_to_global_ids_hash = $self->{INPUT_VEC_TO_GLOBAL_IDS_HASH};
    my @input_vecs = split(/,/, $cluster_hash->{$cluster_id});
    my @global_ids = split(/,/, $input_vec_to_global_ids_hash->{$input_vecs[0]});

    return $global_ids[0];
}


##
# Returns the cluster representative graph in a string
#
# @param self: The object-container
# @param cluster_id: The cluster whose representative will
#  be returned
#
# @return: A string containing the cluster representative
##
sub get_cluster_representative {
  
    assert(scalar(@_) == 2);
    my ($self, $cluster_id) = @_;

    if($self->{INPUT_HASHES_LOADED} == 0) { 
        $self->$_load_files_into_hashes();
    }

    my $print_graphs = $self->{PRINT_GRAPHS_CLASS};

    my $cluster_rep_id  = get_global_id_of_cluster_rep($self, $cluster_id);
    my $cluster_rep = $print_graphs->get_global_id_indexed_request($cluster_rep_id);
    
    return $cluster_rep;
}
  

##
# Returns the global IDs of requests in a cluster
#
# @param self: The object container
# @param cluster_id: The cluster ID
# @param cookie_ptr: A pointer to an opaque cookie that
# allows the user to call this function iteratively in order
# to get all the global IDs of requests that belong to this cluster.
# Initially, the caller should set this to zero; on further iterations
# the user should pass back the value of the cookie returned by this fn.
#
# @bug: *Needs to be modified for the case where there are multiple input vecs
# per cluster (right now, just one to one mapping)*
#
# @return: The global ID of the next request in this cluster
##
sub get_cluster_requests {
    assert(scalar(@_) == 3);

    my $self = shift;
    my $cluster_id = shift;
    my $cookie_ptr = shift;

    if ($self->{INPUT_HASHES_LOADED} == 0) {
        $self->$_load_files_into_hashes();
    }

    my $cluster_hash = $self->{CLUSTER_HASH};
    my $input_vec_to_global_ids_hash = $self->{INPUT_VEC_TO_GLOBAL_IDS_HASH};
    my @input_vecs = split(/,/, $cluster_hash->{$cluster_id});

    my @global_ids = split(/,/, $input_vec_to_global_ids_hash->{$input_vecs[0]});

    if(${$cookie_ptr} == scalar(@global_ids)) {
        return -1;
    }
    
    my $retval =  $global_ids[${$cookie_ptr}];
    ${$cookie_ptr}++;

    return $retval;
}

##
# Returns the mutation type of a cluster given its ID
#
# @param cluster_id: the cluster ID
#
# @return: a string: 
#   "Structural Mutation"
#   "Candidate Originating Cluster"
#   "Structural Mutation and Response Time Change"
#   "Candidate Originating Cluster" and Response Time Change"
##
sub get_mutation_type {
    assert(scalar(@_) == 2);
    
    my ($self, $cluster_id) = @_;
    
    my $cluster_info_hash_ref = $self->{CLUSTER_INFO_HASH};
    
    IdentifyMutations::get_mutation_type($cluster_info_hash_ref, $cluster_id);
}



1;    


    


            
    
