#! /usr/bin/perl -w

# cmuPDL: ConvertRequests.pm, $

##
# This Perl module generates indices for files containing DOT graphs.  It also
# extracts edge latencies and places them in their own files.  The specific files
# created are listed below: 
# 
# global_req_edge_latencies.dat: Each row corresponds to the edge latencies seen
# for a request in snapshot0 or snapshot1.  Columns represent edges seen in
# both snapshots and are ordered uniquely.  Row 1 corresponds to global ID 1
# and so on.  Each row looks like
# <request latency> <edge latency 1> .... <edge latency N>
#
# global_req_edge_columns.dat: The edge names of each column in
# global_req_edge_latencies.dat.  Each row looks like:
# <column number> <edge name>.  column numbers are one-indexed.
#
# global_edge_based_avg_latencies.dat: This file contains the average edge latency
# and repeat count for each unique edge seen in each snapshot.  Each row
# of the file looks like: 
# <edge name> <s0 avg. latency, s0 repeat count, s1 avg. latency, s1 repeat count>
#
# s0_edge_based_edge_latencies.dat: This file contains a MATLAB-compatible sparse
# matrix containing all of the edge latencies seen for each edge in snapshot 0.  The
# format is as follows: 
#    <row number> <column number> <edge latency>
# Row numbers correspond to the column number in global_req_edge_columns.dat.  Row 1
# is the request latency.
#
# s1_edge_based_edge_latencies.dat: This file contains a MATLAB-compatible sparse
# matrix containing all of the edge latencies seen for each edge in snapshot 1.  The
# format is the same as that for s0_edge_based_edge_latencies.dat.
#
#  s0_request_index.dat: 
#    Used to map <local id -> offset of request in the snapshot0 file
#
#  s1_request_index.dat:
#    Used to map <local id -> offset of request in the snapshot1 file
#
#  global_id_to_local_ids.dat: Maps <global id -> local id and dataset>  
#
# All files are placed in the output directory specified by the caller.
#
# NOTE!!!!!: GLOBAL IDs are always guaranteed to start at one and increment
# sequentially.  If there are two snapshots, global ids are generated by
# combining both snapshots as (s0, s1) and incrementing sequentially.  Other
# modules may use this invariant freely.
##

package ParseRequests;

use strict;
use warnings;
use Test::Harness::Assert;
use ParseDot::DotHelper;


# Global variables ########################


### Internal functions ####################

#
# Prints the column orderings of $self->{GLOBAL_EDGE_LATENCIES_FILE}
# to $self->{GLOBAL_EDGE_LATENCIES_COLUMNS_FILE}.  The output format is:
# <column number> <edge name>.  Note that columns are one-indexed!
#
# @param $self: The object-container.
#

##
my $_print_ordered_edges = sub {
    my $self = shift;
    
	open(my $ordered_edges_fh, ">$self->{GLOBAL_REQ_EDGE_LATENCIES_COLUMN_FILE}")
        or die("Could not open $self->{GLOBAL_REQ_EDGE_LATENCIES_COLUMN_FILE}\n");
    
    my $ordered_edge_hash = $self->{ORDERED_REQ_EDGE_HASH};
	
    # Specify that this is a NUMERICAL sort!
	foreach my $key (sort {$ordered_edge_hash->{$a} <=> $ordered_edge_hash->{$b}}
					 keys %$ordered_edge_hash) {
		printf $ordered_edges_fh "%-10u %s\n", ($ordered_edge_hash->{$key}, $key);
	}
    
    close($ordered_edges_fh);
};


##
# Prints output to the file specified in $self->{GLBOAL_REQ_EDGE_LATENCIES_FILE}.
# Each row of this file corresponds to a request (ordered by global id):
# <request latency> <edge latency 1> <edge latency 2> ... <edge latency N>.
# The edge latencies are globally ordered.
# 
# @param $self: The object-container
##
my $_print_ordered_req_edge_latencies = sub {
    my $self = shift;
    
	my $request_latency = shift;
	my $edge_latencies_hash = shift;
    
	open(my $edge_latencies_fh, ">>$self->{GLOBAL_REQ_EDGE_LATENCIES_TEMP_FILE}");
    
	printf $edge_latencies_fh "%-9.4f ", $request_latency;
    my $previous_column_id = $self->{REQ_EDGE_LATENCIES_STARTING_COLUMN_ID};
    
    # Specify that this is a NUMERICAL sort!
	foreach my $key (sort {$a <=> $b} keys %$edge_latencies_hash) {
        # This request may not have seen an edge that other requests saw.
        # The file must order edges in a globally consistent fashion, so
        # fill in this "hole" with zeroes.        
        if( $key != $previous_column_id + 1) {
            for(my $i = $previous_column_id + 1; $i < $key; $i++) {
                printf $edge_latencies_fh  "-%9.3f %-5d  ", 0, 0;
            }
        }
        
		my @edge_info = split(/,/, $edge_latencies_hash->{$key});
		printf $edge_latencies_fh "%-9.4f %-5d  ", @edge_info;
        
        $previous_column_id = $key;
	}

	print $edge_latencies_fh "\n";
	close($edge_latencies_fh);
};


##
# Normalizes the length of each of the req-based edge latency rows
# so that all are of equal length.  This is done by reading
# $self->{GLBOAL_REQ_EDGE_LATENCIES_TEMP_FILE} and for each row,
# appending a number of zeroes equal to $self->{MAX_COLUMN_COUNTER} -
# number of elements in the row
#
# @param self: The object container
##
my $_normalize_req_edge_latencies = sub {
    my $self = shift;

    open(my $edge_latencies_in_fh, "<$self->{GLOBAL_REQ_EDGE_LATENCIES_TEMP_FILE}");
    open(my $edge_latencies_out_fh, ">$self->{GLOBAL_REQ_EDGE_LATENCIES_FILE}");

    while(<$edge_latencies_in_fh>) {
        chomp;
        my @req_edge_data = split(/\s+/, $_);
        my $num_edges = ($#req_edge_data + 1)/2;

        print $edge_latencies_out_fh $_;
        
        for (my $i = $num_edges + 1;
             $i < $self->{REQ_EDGE_LATENCIES_COLUMN_COUNTER};
             $i++) {

            printf $edge_latencies_out_fh "%-9.3f %-5d  ", 0, 0;
        }
        printf $edge_latencies_out_fh "\n";
    }

    close($edge_latencies_in_fh);
    close($edge_latencies_out_fh);
};


##
# Prints output to the file specified in $self->{EDGE_BASED_LATENCES_FILE}
# Each row of the file looks like:
#  <edge name> <avg. latency in s0, count in s0, avg. latency in s1, count in s1>
#
# @param self: The object-container
##
my $_print_edge_based_latencies = sub {
    my $self = shift;
    
    my $edge_based_latencies_hash = $self->{GLOBAL_EDGE_BASED_AVG_LATENCIES_HASH};
    
    open(my $edge_based_latencies_fh, ">$self->{GLOBAL_EDGE_BASED_AVG_LATENCIES_FILE}")
        or die("Could not open $self->{GLOBAL_EDGE_BASED_AVG_LATENCIES_FILE}\n");
    
    foreach my $key (keys %$edge_based_latencies_hash) {
        my @edge_info = split(/,/, $edge_based_latencies_hash->{$key});
        printf $edge_based_latencies_fh "-40s ", $key;
        printf $edge_based_latencies_fh "-%9.5f %-5d", @edge_info;
        printf $edge_based_latencies_fh "\n";
    }
    
    close($edge_based_latencies_fh);
};


##
# This functions adds the nodes of the current request (in DOT format)
# to the $node_name_hash passed in.  The hash format is:
# <node id> -> <node name>
#
# @param $self: The name of the object
# @param in_data_fh: The filehandle of the snapshot file.  The
# offset is set to the start of the nodes of the current request.
##



##
# This function helps create a hash-table ($eq_edge_latency_hash) for 
# each request that stores the following mapping for each request: 
# <edge latencies of request> -> <avg. latency of edge in request, count>
#
# The above information will be printed out as a row for each request in 
# $self->{GLOBAL_REQ_EDGE_LATENCIES_FILE}.  For rows in this file 
# to be comparable, the ordering of edges across rows must be consistent.  
# This function appends to a $self->{ORDERED_REQ_HASH} to enable this 
# consistency.  This hash stores the mapping <edge name> -> <column number>, 
# which is used to order the columns of $self->{GLOBAL_REQ_EDGE_LATENCIES_FILE}.
# 
# @param self: The object container
# @param src_node_name: The source node name
# @param dest_node_name: The dest node name
# @param edge_latency: The latency of this edge
# @param req_edge_latency_hash: A hash mapping 
# <edge name> -> <avg. latency, count> for the current request
##
my $_add_to_req_edge_hash = sub {
    my $self = shift;
    
	my $src_node_name = shift;
	my $dest_node_name = shift;
    my $edge_latency = shift;
	my $req_edge_latency_hash = shift;
	my $edge_latency_key;
    
    my $ordered_req_edge_hash = $self->{ORDERED_REQ_EDGE_HASH};
    
	my $key = "$src_node_name->$dest_node_name";
    
	if(!defined $ordered_req_edge_hash->{$key}) {
		$edge_latency_key = $self->{REQ_EDGE_LATENCIES_COLUMN_COUNTER};
		$ordered_req_edge_hash->{$key} = $self->{REQ_EDGE_LATENCIES_COLUMN_COUNTER};
		$self->{REQ_EDGE_LATENCIES_COLUMN_COUNTER}++;
	}
	else {
		$edge_latency_key = $ordered_req_edge_hash->{$key};
	}
	
	if(!defined $req_edge_latency_hash->{$edge_latency_key}) {
		$req_edge_latency_hash->{$edge_latency_key} = join(',', (0, 0));
	}
    
    my @edge_info = split(/,/, $req_edge_latency_hash->{$edge_latency_key});

    # Re-calculate the avg. latency
    $edge_info[0] = ($edge_info[0]*$edge_info[1] + $edge_latency)/($edge_info[1] + 1);
    
    # Re-calculate the repeat count
    $edge_info[1] = $edge_info[1] + 1;
    
    $req_edge_latency_hash->{$edge_latency_key} = join(',', @edge_info);
};


##
# This function adds an edge's latency to $self->{GLOBAL_EDGE_BASED_AVG_LATENCIES_HASH},
# which stores a mapping from:
#  <edge name> -> <avg. latency in s0, count in s0, avg. latency in s1, count in s1>
#
# @param self: The object container
# @param src_node_name: The source node
# @param dest_node_name: The destination node name
# @param edge_latency: The latency of this edge
# @param snapshot: The snapshot to which the edge belongs
##
my $_add_to_edge_based_avg_latencies_hash = sub {
    my $self = shift;
    
    my $src_node_name = shift;
    my $dest_node_name = shift;
    my $edge_latency = shift;
    my $snapshot = shift;
    
    my $edge_based_latency_hash = $self->{GLOBAL_EDGE_BASED_AVG_LATENCIES_HASH};
    
    my $key = "$src_node_name->$dest_node_name";
    if(!defined $edge_based_latency_hash->{$key}) {
        $edge_based_latency_hash->{$key} = join(',', 0, 0, 0, 0);
    }
    
    my @edge_info = split(/,/, $edge_based_latency_hash->{$key});
    
    # Re-Calculate average edge latency for this edge
    $edge_info[$snapshot] = ($edge_info[$snapshot]*$edge_info[$snapshot+1] 
                             + $edge_latency)/($edge_info[$snapshot+1] + 1);
    
    # Re-Calculate total repeat count for this edge
    $edge_info[$snapshot+1] += 1;
    
    $edge_based_latency_hash->{$key} = join(',', @edge_info);
};


##
# Prints out the edge latency to the s0_indiv_edge_latencies_file or
# the s1_indiv_edge_latencies_file.  The file format is a MATLAB-compatible
# sparse matrix.  That is, the file contains three columns <row number>
# <column number> <edge latency>.  The row numbers correspond to the
# ordering specified in $self->{GLOBAL_REQ_EDGE_LATENCIES_COLUMN_FILE}
#
# @note: This function assumes that $self->{GLOBAL_REQ_EDGE_LATENCIES_COLUMN_FILE}
# has already been populated with the appropriate information.
#
# @param self: The object-container
# @param src_node_name: The name of the source node
# @param dest_node_name: The name of the destination node
# @param edge_latency: The edge latency value for this edge
# @param snapshot: The snapshot to which this edge belongs
##
my $_print_indiv_edge_latencies = sub {
    my $self = shift;

    my $src_node_name = shift;
    my $dest_node_name = shift;
    my $edge_latency = shift;
    my $snapshot = shift;
    
    my $out_fh;

    if($edge_latency == 0) {
        # Sparse matrices should not contain 0s
        return;
    }

    if($snapshot == 0) {
        open($out_fh, ">>$self->{S0_EDGE_BASED_INDIV_LATENCIES_FILE}")
            or die("Could not open $self->{S0_EDGE_BASED_INDIV_LATENCIES_FILE}");
    } else {
        assert($snapshot == 1);
        open($out_fh, ">>$self->{S1_EDGE_BASED_INDIV_LATENCIES_FILE}")
            or die("Could not open $self->{S1_EDGE_BASED_INDIV_LATENCIES_FILE}");
    }

    my $edge_row_hash = $self->{ORDERED_REQ_EDGE_HASH};
    my $edge_name = "$src_node_name->$dest_node_name";
    my $edge_row = $edge_row_hash->{$edge_name};

    my $edge_num_values_seen_hash = $self->{NUM_EDGE_VALUES_SEEN_HASH};
    if(!defined $edge_num_values_seen_hash->{$edge_name}) {
        $edge_num_values_seen_hash->{$edge_name} = join(',', (0, 0));
    }

    my @num_values_seen = split(/,/, $edge_num_values_seen_hash->{$edge_name});
    $num_values_seen[$snapshot]++;
    $edge_num_values_seen_hash->{$edge_name} = join(',', @num_values_seen);
        
    printf $out_fh "%-10d %-10d %f\n", $edge_row, $num_values_seen[$snapshot], $edge_latency;

    close($out_fh);
};


##
# This function is called for each edge seen.  It accumulates the information
# necessary to print out the data for the REQ_EDGE_LATENCIES_FILE and the
# GLOBAL_EDGE_BASED_AVG_LATENCIES_FILE.
#
# @param self: The object container
# @param in_data_fh: The filehandle of the snapshot currently being processed.
# it's offset is set to the first edge of some request.
# @param node_name_hash: A hash of node names -> uinque ids for this req.
# @param req_edg_latency_hash: A hash of edges-><avg. latency, count> for this req.
# @param request_latency: The response-time of this request
# @param snapshot: 0 if this edge belongs to s0, 1 otherwise.
#
##
my $_handle_edges = sub {
    my $self = shift;
    
	my $in_data_fh = shift;
	my $node_name_hash = shift;
	my $req_edge_latency_hash = shift;
	my $request_latency = shift;
	my $snapshot = shift;

	while(<$in_data_fh>) {

		if(/(\d+)\.(\d+) \-> (\d+)\.(\d+) \[label=\"R: ([0-9\.]+) us\".*\]/) {

			my $src_node_id = "$1.$2";
			my $dest_node_id = "$3.$4";
            
			my $edge_latency = $5;
			
			my $src_node_name = $node_name_hash->{$src_node_id};
			my $dest_node_name = $node_name_hash->{$dest_node_id};

			$self->$_add_to_req_edge_hash($src_node_name, 
                                          $dest_node_name, 
                                          $edge_latency, 
                                          $req_edge_latency_hash); 
            
            $self->$_add_to_edge_based_avg_latencies_hash($src_node_name,
                                                          $dest_node_name,
                                                          $edge_latency,
                                                          $snapshot);

            $self->$_print_indiv_edge_latencies($src_node_name,
                                                $dest_node_name,
                                                $edge_latency,
                                                $snapshot);
        } else {

            $self->$_print_ordered_req_edge_latencies($request_latency, 
                                                      $req_edge_latency_hash);
			last;
		}
    }
};


##
# Removes files generated by this class from the output directory
#
# @param self: The object container
##
my $_remove_existing_files = sub {
    my $self = shift;
    
    if (-e $self->{S0_REQUEST_INDEX_FILE}) {
        print("Deleting old $self->{S0_REQUEST_INDEX_FILE}\n");
        system("rm -f $self->{S0_REQUEST_INDEX_FILE}") == 0
            or die("Could not delete old $self->{S0_REQUEST_INDEX_FILE}");
    }
    
    if (-e $self->{S1_REQUEST_INDEX_FILE}) {
        print("Deleting old $self->{S1_REQUEST_INDEX_FILE}\n");
        system("rm -f $self->{S1_REQUEST_INDEX_FILE}") == 0
            or die("Could not delete old $self->{S1_REQUEST_INDEX_FILE}");
    }
    
	if (-e $self->{GLOBAL_REQ_EDGE_LATENCIES_FILE}) {
		print("Deleting old $self->{GLOBAL_REQ_EDGE_LATENCIES_FILE}\n");
		system("rm -f $self->{GLOBAL_REQ_EDGE_LATENCIES_FILE}") == 0
			or die("Could not delete old $self->{GLOBAL_REQ_EDGE_LATENCIES_FILE}");
    }

    if (-e $self->{GLOBAL_REQ_EDGE_LATENCIES_TEMP_FILE}) {
        print ("Deleting old $self->{GLOBAL_REQ_EDGE_LATENCIES_TEMP_FILE}");
        system ("rm -f $self->{GLOBAL_REQ_EDGE_LATENCIES_TEMP_FILE}") == 0
            or die("Could not delete old $self->{GLOBAL_REQ_EDGE_LATENCIES_TEMP_FILE}");
    }

	if (-e $self->{GLOBAL_REQ_EDGE_LATENCIES_COLUMN_FILE}) {
		print("Deleting old $self->{GLOBAL_REQ_EDGE_LATENCIES_COLUMN_FILE}\n");
		system("rm -f $self->{GLOBAL_REQ_EDGE_LATENCIES_COLUMN_FILE}") == 0
			or die("Could not delete old $self->{GLOBAL_REQ_EDGE_LATENCIES_COLUMN_FILE}\n");
	}

    if(-e $self->{GLOBAL_EDGE_BASED_AVG_LATENCIES_FILE}) {
        print("Deleting old $self->{GLOBAL_EDGE_BASED_AVG_LATENCIES_FILE}\n");
        system("rm -f $self->{GLOBAL_EDGE_BASED_AVG_LATENCIES_FILE}") == 0
            or die("Could not delete old $self->{GLOBAL_EDGE_BASED_AVG_LATENCIES_FILE}\n");
    }

    if(-e $self->{S0_EDGE_BASED_INDIV_LATENCIES_FILE}) {
        print("Deleting old $self->{S0_EDGE_BASED_INDIV_LATENCIES_FILE}\n");
        system("rm -f $self->{S0_EDGE_BASED_INDIV_LATENCIES_FILE}") == 0
            or die("Could not delete old $self->{S0_EDGE_BASED_INDIV_LATENCIES_FILE}\n");
    }

    if(-e $self->{S1_EDGE_BASED_INDIV_LATENCIES_FILE}) {
        print("Deleting old $self->{S1_EDGE_BASED_INDIV_LATENCIES_FILE}\n");
        system("rm -f $self->{S1_EDGE_BASED_INDIV_LATENCIES_FILE}") == 0
            or die("Could not delete old $self->{S1_EDGE_BASED_INDIV_LATENCIES_FILE}\n");
    }

	if (-e $self->{GLOBAL_IDS_TO_LOCAL_IDS_FILE}) {
		print "Deleting old $self->{GLOBAL_IDS_TO_LOCAL_IDS_FILE}\n";
		system("rm -f $self->{GLOBAL_IDS_TO_LOCAL_IDS_FILE}") == 0
			or die("could not delete old $self->{GLOBAL_IDS_TO_LOCAL_IDS_FILE}\n");
	}    
};


## 
# Iterates through requests in the snapshot specified and calls
# functions necessary to accumulate and print the indices and
# edge latencies.
#
# @param self: The object container
# @param snapshot_file: The file containing requests from s0 or s1
# @param index_file: The file to which to write the file mapping
# <request local ids> -> <offset in the snapshot file>
# @param snapshot: (0 or 1)
##
my $_handle_requests = sub {
    my $self = shift;
    my $snapshot_file = shift;
    my $index_file = shift;
    my $snapshot = shift;

    assert($snapshot == 0 || $snapshot == 1);

    #
    # Open appropriate files for reading from the
    # snapshot request file, for writing the snapshot
    # request index, and the map from global ids to local ids
    #
    open(my $snapshot_fh, "<$snapshot_file") 
        or die("Could not open $snapshot_file");
    open(my $snapshot_idx_fh, ">$index_file")
        or die("Could not open $index_file");
    open(my $gid_to_lid_idx_fh, ">>$self->{GLOBAL_IDS_TO_LOCAL_IDS_FILE}")
        or die("could not open $self->{GLOBAL_IDS_TO_LOCAL_IDS_FILE}\n");
    
    # Iterate through requests
    my $old_byte_offset = 0;
    while(<$snapshot_fh>) {
        my %req_edge_latency_hash;
        my %node_name_hash;
        my $request_latency;
        my $local_id;

        if(/\# (\d+)  R: ([0-9\.]+)/) {
            $local_id = $1;
            $request_latency = $2;
        } else {
            $old_byte_offset = tell($snapshot_fh);
            next;
        }

        #generate the snapshot index and global id to local id mapping
        printf $snapshot_idx_fh "$local_id $old_byte_offset\n";
        printf $gid_to_lid_idx_fh "$self->{GLOBAL_ID} $local_id $snapshot\n";

        # Skip the Begin Digraph { line
        $_ = <$snapshot_fh>;

        parse_nodes_from_file($snapshot_fh, 1, \%node_name_hash);
        $self->$_handle_edges($snapshot_fh, \%node_name_hash, \%req_edge_latency_hash,
                             $request_latency, $snapshot);

        $self->{GLOBAL_ID}++;
    }
     

    close($snapshot_fh);
    close($gid_to_lid_idx_fh);
};



### API Functions #########################


##
# Constructor for this class
##
sub new {
    my $proto = shift;
    my $snapshot0_file;
    my $snapshot1_file;
    my $output_dir;

    # Get constructor parameters
    $snapshot0_file = shift;
    if($#_ == 1) {
        $snapshot1_file = shift;
        $output_dir = shift;
    } elsif ($#_ == 0) {
        $output_dir = shift;
    } else {
        print "Invalid instantiation of this object!\n";
        assert(0);
    }

    my $class = ref($proto) || $proto;

    my $self = {};

    $self->{SNAPSHOT0_FILE} = "$snapshot0_file";
    if(defined $snapshot1_file) {
        $self->{SNAPSHOT1_FILE} = "$snapshot1_file";
    } else {
        $self->{SNAPSHOT1_FILE} = undef;
    }


    # Output file names and hashes for this class
    $self->{S0_REQUEST_INDEX_FILE} = "$output_dir/s0_request_index.dat";

    $self->{GLOBAL_REQ_EDGE_LATENCIES_FILE} = "$output_dir/global_req_edge_latencies.dat";
    $self->{GLOBAL_REQ_EDGE_LATENCIES_TEMP_FILE} = "$output_dir/global_req_temp_latencies.dat";
    $self->{ORDERED_REQ_EDGE_HASH} = {};
    $self->{GLOBAL_REQ_EDGE_LATENCIES_COLUMN_FILE} = "$output_dir/global_req_edge_columns.dat";
    $self->{REQ_EDGE_LATENCIES_STARTING_COLUMN_ID} = 2; # 2 because the first column is reserved for the request latency
    $self->{REQ_EDGE_LATENCIES_COLUMN_COUNTER} = $self->{REQ_EDGE_LATENCIES_STARTING_COLUMN_ID};
    
    $self->{GLOBAL_EDGE_BASED_AVG_LATENCIES_FILE} = "$output_dir/global_edge_based_avg_latencies.dat";
    $self->{GLOBAL_EDGE_BASED_AVG_LATENCIES_HASH} = {};

    $self->{S0_EDGE_BASED_INDIV_LATENCIES_FILE} = "$output_dir/s0_edge_based_indiv_latencies.dat";

    $self->{NUM_EDGE_VALUES_SEEN_HASH} = {};
    
    $self->{GLOBAL_IDS_TO_LOCAL_IDS_FILE} = "$output_dir/global_ids_to_local_ids.dat";
    $self->{STARTING_GLOBAL_ID} = 1;
    $self->{GLOBAL_ID} = $self->{STARTING_GLOBAL_ID};

    # Output files generated only if a snapshot1 file is provided
    if(defined $self->{SNAPSHOT1_FILE}) {
        $self->{S1_EDGE_BASED_INDIV_LATENCIES_FILE} = "$output_dir/s1_edge_based_indiv_latencies.dat";
        $self->{S1_REQUEST_INDEX_FILE} = "$output_dir/s1_request_index.dat";
    } else {
        $self->{S1_EDGE_BASED_INDIV_LATENCIES_FILE} = undef;
        $self->{S1_REQUEST_INDEX_FILE} = undef;
    }
        
    
    bless($self, $class);
    return $self;
}


##
# Checks if the output files created by this class already
# exist.
#
# @param self: The object-container
##
sub do_output_files_exist {
    my $self = shift;
    
    if(-e $self->{S0_REQUEST_INDEX_FILE} &&
       -e $self->{GLOBAL_REQ_EDGE_LATENCIES_FILE} &&
       -e $self->{GLOBAL_REQ_EDGE_LATENCIES_COLUMN_FILE} &&
       -e $self->{GLOBAL_EDGE_BASED_AVG_LATENCIES_FILE} &&
       -e $self->{S0_EDGE_BASED_INDIV_LATENCIES_FILE}) {
        
        if(defined $self->{SNAPSHOT1_FILE}) {       
            # Must also check to see if output files specific to
            # snapshot 1 already exist
            if(-e $self->{S1_REQUEST_INDEX_FILE} &&
               -e $self->{S1_EDGE_BASED_INDIV_LATENCIES_FILE}) {
                # All output files for snapshot1 and snapshot1 exist
                return 1;
            } 
            # Output files for snapshot1 do not exist
            return 0;
        }
        # No snapshot1 file; output files for snapshot0 exist
        return 1;
    }

    # Output files for snapshot0 do not exist
    return 0;
}


##
# Iterates through requests in the snapshot files seperates and translates
# these into files that can be piped into MATLB or an equivalent problem.
##
sub parse_requests {
    my $self = shift;
    my %edge_name_hash;
    my %req_edge_hash;
    my %edge_based_hash;

    $self->$_remove_existing_files();

    $self->$_handle_requests($self->{SNAPSHOT0_FILE},
                            $self->{S0_REQUEST_INDEX_FILE},
                            0);
    if(defined $self->{SNAPSHOT1_FILE}) {
        $self->$_handle_requests($self->{SNAPSHOT1_FILE},
                               $self->{S1_REQUEST_INDEX_FILE},
                               1);
    }

    # print out key edge latency information
    $self->$_normalize_req_edge_latencies();
    $self->$_print_ordered_edges();
    $self->$_print_edge_based_latencies();

}


1;


 



   

    

    
