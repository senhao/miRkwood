package miRkwood::ClusterJobSebastien;

use strict;
use warnings;
use POSIX;

use miRkwood;
use miRkwood::MiRnaDuplexDetector;

use miRkwood::Utils;


#~ use List::BinarySearch qw( binsearch  binsearch_pos  binsearch_range );
use List::Util qw(max min);

use constant {
	DUE_TO_SINGLE_SPIKE => 1,
	DUE_TO_TWO_SPIKES => 2,
	
	ISOLATED_SPIKE => 3,
	COUPLE_OF_SPIKES => 4,
	MULTIPLE_SPIKES => 5
};

use miRkwood::Parsers;
use miRkwood::Programs;
use miRkwood::Utils;
use miRkwood::SequenceJob;

use File::Spec;
use File::Basename;
use Log::Message::Simple qw[msg error debug];

=method new

Constructor

 Usage : my $cluster_job = ClusterJob->new($workspace_dir)
 Input : The genome file
 Return: The cunstructed instance

=cut

sub new {
    my ( $class, 
    #~ $workspace_dir, 
    $genome_db ) = @_;
    my $self = bless {
        #~ workspace_dir => $workspace_dir,
        genome_db => $genome_db
    }, $class;
    return $self;
}


sub init_from_clustering {
	my ($this, $clustering) = @_;
	#~ $this->{genome_file} = $clustering->{'genome_file'};
	$this->{chr_info} = $clustering->{'chr_info'};
	$this->{accepting_time} = $clustering->{'accepting_time'};
    return;
}


# gets the sequence. start starts at 0. end is excluded
sub get_sub_sequence {
	my ($this, $chr, $start, $end) = @_;
	# Chr1, 1, 1
	return substr($this->{'genome_db'}{$chr}, $start, $end-$start);
}


# gets the sequence. start starts at 0. end is excluded
# strand is 1 or -1
# if strand == -1, then the reverse complement is returned
sub get_sub_sequence_on_strand {
	my ($this, $chr, $start, $end, $strand) = @_;
	my $seq = $this->get_sub_sequence($chr, $start, $end);
	if ($strand == -1) {
		return miRkwood::Utils::reverse_complement($seq);
	}
	return $seq;
}

sub display_chr_coordinatees {
	my ($chr, $begin, $end) = @_;
	return $chr. ':' . $begin+1 . '-' . $end;
}

sub run {
	my ($this, $sequences_per_chr, $parsed_bed) = @_;
	my $candidates_miRNA = $this->process_window_spikes($sequences_per_chr);
	my $regions = $this->compute_candidate_precursors_from_miRnaPos($candidates_miRNA);
	my $candidate_precursors = $this->apply_structure_criterion($regions, $parsed_bed);
	return $candidate_precursors;
}


sub extract_spike_train {
	my $this = shift;
	my $trains_per_chr = shift;
	
	my %spikes = ();

	foreach my $chr (keys %{ $this->{chr_info} }) {
		$spikes{$chr} = $this->extract_spike_train_per_chr($trains_per_chr->{$chr});
	}
	return \%spikes;
}

sub extract_spike_train_per_chr {
	my $this = shift;
	my $trains_for_chr = shift;
	
	my @spike_array = ();
	foreach my $train (@$trains_for_chr) {
		foreach my $spike (@{$train->{spikes}}) {
			push @spike_array, { 'spike' => $spike };
		}
	}
	
	my $accepting_time = $this->{'accepting_time'};
	my $min_length = 21;
	my $min_length_for_neighbor = 40;
	
	for (my $i = 0, my $e = scalar @spike_array; $i < $e; $i++) {
		my $current_spike = $spike_array[$i]{'spike'};
		my @neighbors = ();
		my $unknown_strand = $current_spike->{'strand'} eq '?';
		
		for (my $j = $i+1; $j < $e; $j++) {
			my $neighbor = $spike_array[$j]{'spike'};
			if ($neighbor->{'begin'} - $current_spike->{'end'} < $accepting_time) {
				if ($unknown_strand || $neighbor->{'strand'} eq $current_spike->{'strand'} || $neighbor->{'strand'} eq '?') {
					push @neighbors, $neighbor;
				}
			}
			else {
				last;
			}
		}
		$spike_array[$i]{'neighbors'} = \@neighbors;
		$spike_array[$i]{'class'} = (scalar(@neighbors) == 0 ? ISOLATED_SPIKE : scalar(@neighbors) == 1 ? COUPLE_OF_SPIKES : MULTIPLE_SPIKES);
	}
	
	return \@spike_array;
}

=method process_window_spikes

Retrieve candidates miRNA from windows spike analysis.

 Usage : my $miRnaPos = $self->process_window_spikes($windows),
 Input : The windows returned by get_windows
 Return: A hash ref {
				chr => [array of miRNA candidates (hash ref) {
					strand => '+' or '-',
					source => DUE_TO_SINGLE_SPIKE or DUE_TO_TWO_SPIKES,
					first => First miRNA candidate (lower chr coordinates). Hash ref {
						begin => start position (1-based)
						end => end position (excluded)
						strand => '+' or '-' #This parameter may be inaccurate, you should rely on the top-level strand key instead
						}
					second => Second miRNA candidate (duplex) (larger chr coordinates). Hash ref {
						begin => start position (1-based)
						end => end position (excluded)
						strand => '+' or '-' #This parameter may be inaccurate, you should rely on the top-level strand key instead
						}
					from_read => miRNA candidate that was deduced from a read spike. Hash ref on 'first' or 'second'. This key exists only if 'source' is DUE_TO_SINGLE_SPIKE
					detected => miRNA candidate that was deduced by folding the sequence. Hash ref on 'first' or 'second'. Doesnt point on the same miRNA than from_read.
						This key exists only if 'source' is DUE_TO_SINGLE_SPIKE
				}]
			}

=cut
sub process_spikes {
	my $this = shift;
	my $spikes_per_chr = shift;
	my %miRnaPos = ();

	$this->{detector} = MiRnaDuplexDetector::MiRnaDetector->new(5000);

	foreach my $chr (keys %{ $this->{chr_info} }) {
		$miRnaPos{$chr} = $this->process_spikes_for_chr($chr, $spikes_per_chr->{$chr});
	}
	return \%miRnaPos;
}

=method __enlarged_spike

Static private helper function. You shouldnt use this function.

=cut
sub __enlarged_spike {
	my ($spike, $min_length, $chr_length) = @_;
	my $spike_length = $spike->{'end'} - $spike->{'begin'};
	if ($spike_length < $min_length) {
		my $new_spike = {begin => $spike->{'begin'}, end => $spike->{'end'}};
		my $length_by2 = int(($min_length - $spike_length)/2);
		$new_spike->{'begin'} = max (0, ($new_spike->{'begin'} - $length_by2));
		$new_spike->{'end'} = min($chr_length, $new_spike->{'begin'} + $min_length);
		$new_spike->{'strand'} = $spike->{'strand'};
		#~ $new_spike->{read_count} = $spike->{read_count};
		#~ $new_spike->{forward_read_count} = $spike->{forward_read_count};
		return $new_spike;
	}
	return $spike;
}


=method __force_spike_size

Static private helper function. You shouldnt use this function.

=cut
sub __force_spike_size {
	my ($spike, $length, $chr_length) = @_;
	my $spike_length = $spike->{'end'} - $spike->{'begin'};
	if ($spike_length < $length) {
		my $new_spike = {begin => $spike->{'begin'}, end => $spike->{'end'}};
		my $length_by2 = int(($length - $spike_length)/2);
		$new_spike->{'begin'} = max (0, ($new_spike->{'begin'} - $length_by2));
		$new_spike->{'end'} = min ($chr_length, $new_spike->{'begin'} + $length);
		$new_spike->{'strand'} = $spike->{'strand'};
		#~ $new_spike->{read_count} = $spike->{read_count};
		#~ $new_spike->{forward_read_count} = $spike->{forward_read_count};
		return $new_spike;
	}
	elsif ($spike_length > $length) {
		my $new_spike = {begin => $spike->{'begin'}, end => $spike->{'end'}};
		my $length_by2 = int(($spike_length - $length)/2);
		$new_spike->{'begin'} = $new_spike->{'begin'} + $length_by2;
		$new_spike->{'end'} = $new_spike->{'begin'} + $length;
		$new_spike->{'strand'} = $spike->{'strand'};
		#~ $new_spike->{read_count} = $spike->{read_count};
		#~ $new_spike->{forward_read_count} = $spike->{forward_read_count};
		return $new_spike;
	}
	return $spike;
}


=method __look_forward

Static private helper function. You shouldnt use this function.

=cut
sub __look_forward {
	my ($detector, $miRnaPos, $genome_seq_beg, $genome_seq_end, $genome_seq, $chr, $chr_length, $enlarged_spike, $window_length) = @_;
	my @candidate_region = (min ($enlarged_spike->{'end'}+15, $chr_length), min ($enlarged_spike->{'end'}+$window_length, $chr_length));
	if ($candidate_region[1] - $candidate_region[0] < $enlarged_spike->{'end'} - $enlarged_spike->{'begin'}) {
		# At the right end of the chromosome
		return 0;
	}

	if ($enlarged_spike->{'begin'} < $genome_seq_beg || $candidate_region[0] < $genome_seq_beg ||
		$enlarged_spike->{'end'} > $genome_seq_end || $candidate_region[1] > $genome_seq_end) {
		debug("Looking forward... Genome seq: ". display_chr_coordinatees($chr, $genome_seq_beg, $genome_seq_end) . "\n", 1);
		debug("Too long to test " . display_chr_coordinatees($chr, $enlarged_spike->{'begin'}, $enlarged_spike->{'end'}) . 
			" against " . display_chr_coordinatees($chr, $candidate_region[0], $candidate_region[1]) . "\n", 1);
		return 0;
	}
	my $results;
	my $strand = $enlarged_spike->{'strand'};
	if ($enlarged_spike->{'strand'} eq '?') {
		$results = $detector->detect_on_strand('+', $genome_seq, $enlarged_spike->{'begin'}-$genome_seq_beg, $enlarged_spike->{'end'}-$genome_seq_beg,
		$candidate_region[0]-$genome_seq_beg, $candidate_region[1]-$genome_seq_beg);
		$strand = '+';
		if ( scalar @{$results} ) {
			my @farthest = @{$results->[0]};
			foreach my $r ( @{$results} ) {
				@farthest = @{$r} if $r->[0] > $farthest[0]; # if begin_sequence of 'r' > begin_sequence of 'farthest'
			}
			my $other = {begin => $candidate_region[0]+$farthest[0], end => $candidate_region[0]+$farthest[1], strand => $enlarged_spike->{'strand'}};
			push @{$miRnaPos}, {strand => $strand, from_read => $enlarged_spike, detected => $other, first => $enlarged_spike, second => $other, source => DUE_TO_SINGLE_SPIKE};
		}
		$results = $detector->detect_on_strand('-', $genome_seq, $enlarged_spike->{'begin'}-$genome_seq_beg, $enlarged_spike->{'end'}-$genome_seq_beg,
		$candidate_region[0]-$genome_seq_beg, $candidate_region[1]-$genome_seq_beg);
		$strand = '-';
	}
	else {
		$results = $detector->detect_on_strand($enlarged_spike->{'strand'}, $genome_seq, $enlarged_spike->{'begin'}-$genome_seq_beg, $enlarged_spike->{'end'}-$genome_seq_beg,
		$candidate_region[0]-$genome_seq_beg, $candidate_region[1]-$genome_seq_beg);
	}
	# $results = [ [[begin_read, end_read], [begin_sequence, end_sequence]], [[begin_read, end_read], [begin_sequence, end_sequence]], ...]
	if ( scalar @{$results} ) {
		my @farthest = @{$results->[0]};
		foreach my $r ( @{$results} ) {
			@farthest = @$r if $r->[0] > $farthest[0]; # if begin_sequence of 'r' > begin_sequence of 'farthest'
		}
		my $other = {begin => $candidate_region[0]+$farthest[0], end => $candidate_region[0]+$farthest[1], strand => $enlarged_spike->{'strand'}};
		push @{$miRnaPos}, {strand => $strand, from_read => $enlarged_spike, detected => $other, first => $enlarged_spike, second => $other, source => DUE_TO_SINGLE_SPIKE};
		return 1;
	}
	return 0;
}


=method __look_backward

Static private helper function. You shouldnt use this function.

=cut
sub __look_backward {
	my ($detector, $miRnaPos, $genome_seq_beg, $genome_seq_end, $genome_seq, $chr, $chr_length, $enlarged_spike, $window_length) = @_;
	my @candidate_region = (max ($enlarged_spike->{'begin'}-$window_length-15, 0), max ($enlarged_spike->{'begin'}-16, 0));
	if ($candidate_region[1] - $candidate_region[0] < $enlarged_spike->{'end'} - $enlarged_spike->{'begin'}) {
		return 0;
	}
	if ($enlarged_spike->{'begin'} < $genome_seq_beg || $candidate_region[0] < $genome_seq_beg ||
		$enlarged_spike->{'end'} > $genome_seq_end || $candidate_region[1] > $genome_seq_end) {
 		debug("Looking backward... Genome seq: ".display_chr_coordinatees($chr, $genome_seq_beg, $genome_seq_end) . "\n", 1);
		debug("Too long to test " . display_chr_coordinatees($chr, $enlarged_spike->{'begin'}, $enlarged_spike->{'end'}) . 
			" against " . display_chr_coordinatees($chr, $candidate_region[0], $candidate_region[1]) . "\n", 1);
		return 0;
	}

	my $results;
	my $strand = $enlarged_spike->{'strand'};
	if ($enlarged_spike->{'strand'} eq '?') {
		$results = $detector->detect_on_strand('+', $genome_seq, $enlarged_spike->{'begin'}-$genome_seq_beg, $enlarged_spike->{'end'}-$genome_seq_beg,
		$candidate_region[0]-$genome_seq_beg, $candidate_region[1]-$genome_seq_beg);
		$strand = '+';
		if (scalar @$results) {
			my @farthest = @{$results->[0]};
			foreach my $r ( @{$results} ) {
				@farthest = @{$r} if $r->[0] < $farthest[0]; # if begin_sequence of 'r' < begin_sequence of 'farthest'
			}
			my $other = {begin => $candidate_region[0]+$farthest[0], end => $candidate_region[0]+$farthest[1], strand => $enlarged_spike->{'strand'}};
			push @{$miRnaPos}, {strand => $strand, from_read => $enlarged_spike, detected => $other, first => $other, second => $enlarged_spike, source => DUE_TO_SINGLE_SPIKE};
		}
		$results = $detector->detect_on_strand('-', $genome_seq, $enlarged_spike->{'begin'}-$genome_seq_beg, $enlarged_spike->{'end'}-$genome_seq_beg,
		$candidate_region[0]-$genome_seq_beg, $candidate_region[1]-$genome_seq_beg);
		$strand = '-';
	}
	else {
		$results = $detector->detect_on_strand($enlarged_spike->{'strand'}, $genome_seq, $enlarged_spike->{'begin'}-$genome_seq_beg, $enlarged_spike->{'end'}-$genome_seq_beg,
		$candidate_region[0]-$genome_seq_beg, $candidate_region[1]-$genome_seq_beg);
	}
	return 0 if scalar @{$results} == 0;
	my @farthest = @{$results->[0]};
	foreach my $r ( @{$results} ) {
		@farthest = @{$r} if $r->[0] < $farthest[0]; # if begin_sequence of 'r' < begin_sequence of 'farthest'
	}
	my $other = {begin => $candidate_region[0]+$farthest[0], end => $candidate_region[0]+$farthest[1], strand => $enlarged_spike->{'strand'}};
	push @{$miRnaPos}, {strand => $strand, from_read => $enlarged_spike, detected => $other, first => $other, second => $enlarged_spike, source => DUE_TO_SINGLE_SPIKE};
	return 1;
}


=method __look_both_ways

Static private helper function. You shouldnt use this function.

=cut
sub __look_both_ways {
	my ($detector, $miRnaPos, $genome_seq_beg, $genome_seq_end, $genome_seq, $chr, $chr_length, $current_spike, $min_length, $window_length) = @_;
	my $result_back = __look_backward($detector, $miRnaPos, $genome_seq_beg, $genome_seq_end, $genome_seq, $chr, $chr_length, $current_spike, $window_length);
	my $result_forw = __look_forward($detector, $miRnaPos, $genome_seq_beg, $genome_seq_end, $genome_seq, $chr, $chr_length, $current_spike, $window_length);
	return $result_back || $result_forw;
}


=method __match_with_neighbor

Static private helper function. You shouldnt use this function.

=cut
sub __match_with_neighbor {
	my ($detector, $miRnaPos, $strand, $genome_seq_beg, $genome_seq_end, $genome_seq, $chr, $chr_length, $current_spike, $neighbor, $min_length) = @_;
	my $enlarged_neighbor = __enlarged_spike($neighbor, $min_length, $chr_length);
	my $spike_len = $current_spike->{'end'} - $current_spike->{'begin'};
	my $neighbor_len = $enlarged_neighbor->{'end'} - $enlarged_neighbor->{'begin'};
	my $results;
	if ($current_spike->{'begin'} < $genome_seq_beg || $enlarged_neighbor->{'begin'} < $genome_seq_beg ||
		$current_spike->{'end'} > $genome_seq_end || $enlarged_neighbor->{'end'} > $genome_seq_end) {
		debug("Matching neighbors... Genome seq: ".display_chr_coordinatees($chr, $genome_seq_beg, $genome_seq_end) . "\n", 1);
		debug("Too long to test " . display_chr_coordinatees($chr, $current_spike->{'begin'}, $current_spike->{'end'}) . 
			" against " . display_chr_coordinatees($chr, $enlarged_neighbor->{'begin'}, $enlarged_neighbor->{'end'}) . "\n", 1);
		return 0;
	}

	if ($spike_len < $neighbor_len) {
		$results = $detector->detect_on_strand($strand, $genome_seq, $current_spike->{'begin'}-$genome_seq_beg,
		$current_spike->{'end'}-$genome_seq_beg, $enlarged_neighbor->{'begin'}-$genome_seq_beg, $enlarged_neighbor->{'end'}-$genome_seq_beg);
		if ( scalar @{$results} ) {
			push @{$miRnaPos}, {strand => $strand, first => $current_spike, second => __force_spike_size($neighbor, $spike_len, $chr_length), source => DUE_TO_TWO_SPIKES};
			return 1;
		}
	}
	else {
		$results = $detector->detect_on_strand($strand, $genome_seq, $enlarged_neighbor->{'begin'}-$genome_seq_beg, $enlarged_neighbor->{'end'}-$genome_seq_beg,
		$current_spike->{'begin'}-$genome_seq_beg, $current_spike->{'end'}-$genome_seq_beg);
		if ( scalar @{$results} ) {
			push @{$miRnaPos}, {strand => $strand, first => $current_spike, second => __force_spike_size($neighbor, $spike_len, $chr_length), source => DUE_TO_TWO_SPIKES};
			return 1;
		}
	}
	return 0;
}


=method process_window_spikes_for_chr

Private helper function. You shouldnt use this function.

=cut
sub process_spikes_for_chr {
	my ($this, $chr, $spikes_for_chr) = @_;

	my $accepting_time = $this->{accepting_time};
	my @miRnaPos = (); # Array of [5p, 3p]
	my $genome = $this->{'genome_db'};
	my $detector = $this->{detector};
	my $min_length = 21;
	my $min_length_for_neighbor = 40;
	my $chr_length = $this->{chr_info}{$chr};
	my $min_length_on_isolated_spike = 21;
	my $window_length = 400;
	my $enlarging = max($window_length, $accepting_time);
	my $min_error_for_single_spike = $detector->miRnaMinErrorsThreshold();
	my $min_error_for_two_spikes = $detector->miRnaMaxErrorsThreshold();
	
	foreach my $current_spike_entry (@{$spikes_for_chr}) {
		my $current_spike = $current_spike_entry->{'spike'};
		my $unknown_strand = $current_spike->{'strand'} eq '?';
		my $enlarged_spike = __force_spike_size($current_spike, $min_length, $chr_length);
		
		my $genome_seq_beg = max($enlarged_spike->{'begin'}-50, 0);
		my $genome_seq_end = min($enlarged_spike->{'end'}+$accepting_time*2+100, $chr_length);
		if ($genome_seq_end-$genome_seq_beg > $detector->admissibleTextLength()) {
			$genome_seq_end = $genome_seq_beg+$detector->admissibleTextLength();
		}
		my $genome_seq = $this->get_sub_sequence($chr, $genome_seq_beg, $genome_seq_end);
		my $has_results = 0;
		
		if ($current_spike_entry->{'class'} != ISOLATED_SPIKE) {
			$detector->setMiRnaMinErrorsThreshold($min_error_for_two_spikes);
			foreach my $neighbor (@{$current_spike_entry->{'neighbors'}}) {
				if ($unknown_strand || $neighbor->{'strand'} eq '?') {
					$has_results = __match_with_neighbor($detector, \@miRnaPos, '+', $genome_seq_beg, $genome_seq_end, $genome_seq,
									$chr, $chr_length, $enlarged_spike, $neighbor, $min_length_for_neighbor);
					my $has_results_2 = __match_with_neighbor($detector, \@miRnaPos, '-', $genome_seq_beg, $genome_seq_end, $genome_seq,
								$chr, $chr_length, $enlarged_spike, $neighbor, $min_length_for_neighbor);
					$has_results = $has_results || $has_results_2;
				}
				else {
					$has_results = __match_with_neighbor($detector, \@miRnaPos, $enlarged_spike->{'strand'}, $genome_seq_beg, $genome_seq_end, $genome_seq,
									$chr, $chr_length, $enlarged_spike, $neighbor, $min_length_for_neighbor);
				}
			}
		}
		if ($has_results == 0) { 
			$detector->setMiRnaMinErrorsThreshold($min_error_for_single_spike);

			$genome_seq_beg = max($enlarged_spike->{'begin'}-$window_length-15, 0);
			$genome_seq_end = min($enlarged_spike->{'end'}+$window_length+15, $chr_length);
			$genome_seq = $this->get_sub_sequence($chr, $genome_seq_beg, $genome_seq_end);

			__look_both_ways($detector, \@miRnaPos, $genome_seq_beg, $genome_seq_end, $genome_seq, $chr, $chr_length, $enlarged_spike,
			$min_length_on_isolated_spike, $window_length);
		}
	}
	$detector->setMiRnaMinErrorsThreshold($min_error_for_single_spike);
	return \@miRnaPos;
}


=method compute_candidate_precursors_from_miRnaPos

Computes candidate precursors based miRNA candidates. This is made by adding 100 nt on both sides of the miRna couple.
Regions that overlap by more than 60% are merged together.

 Usage : my $candidate_precursors = $self->compute_candidate_precursors_from_miRnaPos($miRnas);
 Input : The miRNAs returned by process_window_spikes
 Return: A hash ref {
			chr => [array of precursors {
				begin => start position (1-based)
				end => end position (excluded)
				strand => '+' or '-'
				miRnas => [] Array reference of miRNA candidates contained in the precursor. Picked from $miRnas.
				}]
			}

=cut
sub compute_candidate_precursors_from_miRnaPos {
	my $this = shift;
	my $miRnaPosPerChr = shift;
	my %candidate_region = ();

	foreach my $chr (keys %{ $this->{chr_info} }) {
		my $miRnaPos = $miRnaPosPerChr->{$chr};
		$candidate_region{$chr} = compute_candidate_precursors_from_miRnaPos_for_chr($chr, $miRnaPos, $this->{chr_info}{$chr});
	}
	return \%candidate_region;
}


=method region_intertects

Static private helper function. You shouldnt use this function.

=cut
sub region_intertects {
	my ($a, $b, $ratio) = @_;
	if ($a->{'begin'} <= $b->{'begin'} && $a->{'end'} > $b->{'begin'}) {
		if ($b->{'end'} <= $a->{'end'}) {
			return 1;
		}
		return ($a->{'end'}-$b->{'begin'})/($b->{'end'}-$a->{'begin'}) >= $ratio ? 1 : 0;
	}
	elsif ($b->{'begin'} <= $a->{'begin'} && $b->{'end'} > $a->{'begin'}) {
		if ($a->{'end'} <= $b->{'end'}) {
			return 1;
		}
		return ($b->{'end'}-$a->{'begin'})/($a->{'end'}-$b->{'begin'}) >= $ratio ? 1 : 0;
	}
	return 0;
}


=method raw_regions_intertect

Static private helper function. You shouldnt use this function.

=cut
sub raw_regions_intertect {
	my ($a, $b) = @_;
	if ($a->{'begin'} <= $b->{'begin'} && $a->{'end'} > $b->{'begin'}) {
		return 1;
	}
	elsif ($b->{'begin'} <= $a->{'begin'} && $b->{'end'} > $a->{'begin'}) {
		return 1;
	}
	return 0;
}


=method merge_regions

Static private helper function. You shouldnt use this function.

=cut
# $a and $b must intersect
# the result is merged in $a
sub merge_regions {
	my ($a, $b) = @_;
	if ($a->{'begin'} <= $b->{'begin'}) {
		if ($b->{'end'} > $a->{'end'}) {
			$a->{'end'} = $b->{'end'};
		}
	}
	else {
		if ($b->{'end'} <= $a->{'end'}) {
			$a->{'begin'} = $b->{'begin'};
		}
		else {
			$a->{'begin'} = $b->{'begin'};
			$a->{'end'} = $b->{'end'};
		}
	}
	push @{$a->{'miRnas'}}, @{$b->{'miRnas'}};
    return;
}

sub merge_overlapping_regions {
	my $regions = shift;
	my @sorted_regions = sort {$a->{'begin'} <=> $b->{'begin'}} @$regions;
	
	if (scalar @sorted_regions == 0) {
		return [];
	}
	
	my @stack = ($sorted_regions[0]);
	for (my $i = 1; $i < scalar @sorted_regions; $i++) {
		my $top = $stack[0];
		if ($top->{'end'} < $sorted_regions[$i]{'begin'}) {
			unshift @stack, $sorted_regions[$i];
		}
		elsif ($top->{'end'} < $sorted_regions[$i]{'end'}) {
			$top->{'end'} = $sorted_regions[$i]{'end'};
			push @{$top->{'miRnas'}}, @{$sorted_regions[$i]{'miRnas'}};
			shift @stack;
			unshift @stack, $top;
		}
	}
	
	return \@stack;
}


=method compute_candidate_precursors_from_miRnaPos_for_chr

Static private helper function. You shouldnt use this function.

=cut
sub compute_candidate_precursors_from_miRnaPos_for_chr {
	my $chr = shift;
	my $miRnaPos = shift;
	my $chr_length = shift;

	my $padding = 100;

	if (scalar @{$miRnaPos} == 0) {
		return [];
	}
	my %regions = ('+' => [], '-' => []);

	my $current_miRna = $miRnaPos->[0];
	my %last_region = ('+' => undef, '-' => undef);

	push @{$regions{$current_miRna->{'strand'}}}, 
		{'begin'  => max(0, $current_miRna->{first}{'begin'}-$padding), 
		 'end'    => min($chr_length, $current_miRna->{second}{'end'}+$padding),
		 'strand' => $current_miRna->{'strand'}, 
		 'miRnas' => [$current_miRna],
		 'chr' => $chr
		 };

	for (my $i = 1; $i < scalar @{$miRnaPos}; $i++) {
		my $current_miRna = $miRnaPos->[$i];
		my %region = (
			'begin'  => max(0, $current_miRna->{first}{'begin'}-$padding), 
			'end'    => min($chr_length, $current_miRna->{second}{'end'}+$padding), 
			'strand' => $current_miRna->{'strand'},
			'miRnas' => [$current_miRna],
			'chr' => $chr);
			
		push @{$regions{$current_miRna->{'strand'}}}, \%region;
	}
	
	$regions{'+'} = merge_overlapping_regions($regions{'+'});
	$regions{'-'} = merge_overlapping_regions($regions{'-'});

	my @final_regions = sort {$a->{'begin'} <=> $b->{'begin'}} (@{$regions{'+'}}, @{$regions{'-'}});
	return \@final_regions;
}


=method run_rnalfold

Static private helper function. You shouldnt use this function.

=cut
sub run_rnalfold {
	my $seq_name = shift;
	my $seq = shift;
	my $output_folder = shift;
	my $output_file = shift;
	my $rnalfold_output = File::Spec->catfile($output_folder, $output_file);
    my $temp_file = File::Spec->catfile($output_folder, $output_file . '_sequence.txt');
    miRkwood::Programs::run_rnalfold($seq_name, $seq, $temp_file, $rnalfold_output) or die("Problem when running RNALfold: $!");
    return $rnalfold_output;
}


=method run_rnastemloop

Static private helper function. You shouldnt use this function.

=cut
sub run_rnastemloop {
	my ( $input, $output_stemloop, $output_optimal ) = @_;
	return miRkwood::Programs::run_rnastemloop($input, $output_stemloop, $output_optimal);
}


=method parse_stemloop_output

Static private helper function. You shouldnt use this function.

=cut
# returns an array of {begin, end, sequence, secondary_structure}
sub parse_stemloop_output {
	my $seq_name = shift;
	my $region = shift;
	my $safe_seq_name = quotemeta $seq_name;
	my $input = shift;
	my @results = ();
	open (my $fh, '<', $input) or die "Can't open $input: $!";
	if ($region->{'strand'} eq '+') {
		my $seq_begin = $region->{'begin'};
		while (my $line = <$fh>) {
			chomp $line;
			# if $line starts with ">$seqname" . "__DIGITS-DIGITS"
			if ($line =~ /^>${safe_seq_name}__(\d+)-(\d+)/) {
				my %entry = (begin => $1 + $seq_begin-1, end => $2 + $seq_begin);
				$line = <$fh>;
				chomp $line;
				$entry{sequence} = $line;
				$line = <$fh>;
				chomp $line;
				$entry{secondary_structure} = $line;
				push @results, \%entry;
			}
		}
	}
	else {
		my $seq_begin = $region->{'begin'};
		my $seq_len = $region->{'end'} - $seq_begin;
		while (my $line = <$fh>) {
			chomp $line;
			# if $line starts with ">$seqname" . "__DIGITS-DIGITS"
			if ($line =~ /^>${safe_seq_name}__(\d+)-(\d+)/) {
				my %entry = (begin => ($seq_len - $2 + $seq_begin), end => ($seq_len - $1 +1 + $seq_begin));
				$line = <$fh>;
				chomp $line;
				$entry{sequence} = $line;
				$line = <$fh>;
				chomp $line;
				$entry{secondary_structure} = $line;
				push @results, \%entry;
			}
		}
	}
	return \@results;
}


=method eval_stemloop_output

Static private helper function. You shouldnt use this function.

=cut
sub eval_stemloop_output {
	my $stemloop_results = shift;
	my $miRnaPos = shift;

	my @retained_stemloops = ();

	foreach my $stemloop ( @{$stemloop_results} ) {
		if (eval_single_stemloop($stemloop, $miRnaPos) == 1) {
			push @retained_stemloops, $stemloop;
		}
	}
	return \@retained_stemloops;
}


=method eval_stemloop_output

Static private helper function. You shouldnt use this function.

=cut
sub eval_single_stemloop {
	my $stemloop = shift;
	my $miRnaPos = shift;

	foreach my $miRnas ( @{$miRnaPos} ) {
		if ($miRnas->{source} == DUE_TO_TWO_SPIKES) {
			if (raw_regions_intertect($stemloop, $miRnas->{first}) && raw_regions_intertect($stemloop, $miRnas->{second})) {
				return 1;
			}
		}
		else {
			if (raw_regions_intertect($stemloop, $miRnas->{from_read})) {
				return 1;
			}
		}
	}
	return 0;
}


=method apply_structure_criterion

Runs rnalfold and rnastemloop on the candidate precursors returned by compute_candidate_precursors_from_miRnaPos.
This elimates candidates where no stem loops are possible, or where the detected miRnas fall outside the rnastemloop-predicted precursors.

 Usage : my $retained_regions = $self->apply_structure_criterion($candidate_precursors),
 Input : The candidate precursors returned by compute_candidate_precursors_from_miRnaPos.
 Return: An array reference of candidates

=cut
sub apply_structure_criterion {
	my ($this, $regionsPerChr, $parsed_bed) = @_;
	my @candidates = ();
	foreach my $chr (keys %{ $this->{chr_info} }) {
        debug("Work on chromosome $chr", miRkwood->DEBUG() );
		my $regions = $regionsPerChr->{$chr};
		push @candidates, @ {$this->apply_structure_criterion_per_chr($chr, $regions, $parsed_bed) };
	}
	return \@candidates;
}


=method apply_structure_criterion_per_chr

Private helper function. You shouldnt use this function.

=cut
sub apply_structure_criterion_per_chr {
	my ($this, $chr, $regions, $parsed_bed) = @_;
	my $genome = $this->{'genome_db'};

	my @candidates = ();
    my $already_positioned = {};
	foreach my $region (@$regions) {
		my $strand = $region->{'strand'} eq '+' ? 1 : -1;
		my $seq_id = $chr . '__' . $region->{'begin'} . '-' . ($region->{'end'}-1);
		my $working_dir = File::Spec->catdir($this->{workspace_dir}, $seq_id. $region->{'strand'});
		mkdir $working_dir;

		my $rnalfold_output_filename = 'rnalfold_out';

		my $genomic_seq = $this->get_sub_sequence_on_strand($chr, $region->{'begin'}, $region->{'end'}-1, $strand);

		my $rnalfold_output_filepath = run_rnalfold('miRnaPrecursor', $genomic_seq, $working_dir, $rnalfold_output_filename);

		my $output_stemloop_opt = File::Spec->catfile($working_dir, 'rnastemloop_optimal');
		my $output_stemloop = File::Spec->catfile($working_dir, 'rnastemloop_stemloop');

		run_rnastemloop($rnalfold_output_filepath, $output_stemloop, $output_stemloop_opt);

		my $rnaeval_out_optimal = $this->run_RNAeval_on_RNAstemloop_optimal_output($output_stemloop_opt);
		my $rnaeval_out_stemloop = $this->run_RNAeval_on_RNAstemloop_stemloop_output($output_stemloop);

		my $new_candidates = $this->process_RNAstemloop_on_filenames($output_stemloop, $rnaeval_out_optimal, $rnaeval_out_stemloop,
			$region->{'begin'}, $region->{'end'}-$region->{'begin'}, $chr, $region->{'strand'}, $region->{'miRnas'}, $parsed_bed);

        ($new_candidates, $already_positioned) = filter_candidates_on_position($new_candidates, $already_positioned);

		my @sorted_new_candidates = sort { $a->{start_position} <=> $b->{start_position} } @{$new_candidates};

		my $sequence_job = miRkwood::SequenceJob->new($working_dir, $seq_id, $chr, $genomic_seq);
		my %candidates_hash = $sequence_job->process_raw_candidates(\@sorted_new_candidates);

		@candidates = (@candidates, @{$sequence_job->process_candidates( \%candidates_hash )});
	}
	return \@candidates;
}

sub filter_candidates_on_position {
    my (@args) = @_;
    my $candidates_array = shift @args;
    my $already_positioned = shift @args;
    my $new_candidates_array = [];

    foreach my $candidate ( @{$candidates_array} ){
        my $start = $candidate->{'start_position'};
        my $end   = $candidate->{'end_position'};
        unless ( defined( $already_positioned->{"$start-$end"} ) and $already_positioned->{"$start-$end"} == 1 ){
            $already_positioned->{"$start-$end"} = 1;
            push @{$new_candidates_array}, $candidate;
        }
    }

    return ($new_candidates_array, $already_positioned);

}



=method run_RNAeval_on_RNAstemloop_optimal_output

=cut

sub run_RNAeval_on_RNAstemloop_optimal_output {
    my ($self, @args)  = @_;
    my $rnastemloop_out_optimal = shift @args;
    return $self->run_RNAeval_on_RNAstemloop_output( $rnastemloop_out_optimal, 'optimal' );
}

=method run_RNAeval_on_RNAstemloop_stemloop_output

=cut

sub run_RNAeval_on_RNAstemloop_stemloop_output {
    my ($self, @args)  = @_;
    my $rnastemloop_out_stemloop = shift @args;
    return $self->run_RNAeval_on_RNAstemloop_output( $rnastemloop_out_stemloop, 'stemloop' );
}

=method run_RNAeval_on_RNAstemloop_output


=cut

sub run_RNAeval_on_RNAstemloop_output {
    my ( $self, @args ) = @_;
    my ( $rnastemloop_out, $suffix ) = @args    ;
    my $current_sequence_dir = dirname($rnastemloop_out);
    debug("Processing RNAstemloop output for $suffix $rnastemloop_out", miRkwood->DEBUG() );
    my $rnaeval_out = File::Spec->catfile( $current_sequence_dir, "rnaeval_$suffix.out" );

    debug( "Running RNAeval in $rnaeval_out", miRkwood->DEBUG() );
    miRkwood::Programs::run_rnaeval( $rnastemloop_out, $rnaeval_out ) or die('Problem when running RNAeval');

    return $rnaeval_out;
}

sub process_RNAstemloop_on_filenames {
    my ($self, @args)  = @_;
    my ($rnastemloop_out_stemloop)      = shift @args;
    my ($rnaeval_out_optimal)  = shift @args;
    my ($rnaeval_out_stemloop) = shift @args;
    my ($sequence_begin) = shift @args;
    my ($seq_len) = shift @args;
    my $chr = shift @args;
    my ($strand) = shift @args;
    my ($sequence_miRnas) = shift @args;
    my $parsed_bed = shift @args;

    open( my $STEM_FH, '<', $rnastemloop_out_stemloop ) or die "Error opening $rnastemloop_out_stemloop: $!";
    open( my $EVAL_OPT_FH, '<', $rnaeval_out_optimal ) or die $!;
    open( my $EVAL_STEM_FH, '<', $rnaeval_out_stemloop ) or die $!;
    my $msg = "Processing RNAstemloop ( $rnastemloop_out_stemloop, $rnaeval_out_optimal, $rnaeval_out_stemloop )";
    debug( $msg, miRkwood->DEBUG() );
    my $candidates = $self->process_RNAstemloop($STEM_FH, $EVAL_OPT_FH, $EVAL_STEM_FH, $sequence_begin, $seq_len, $chr, $strand,
    $sequence_miRnas, $parsed_bed);
    close($STEM_FH);
    close($EVAL_OPT_FH);
    close($EVAL_STEM_FH);
    return $candidates;
}

# See std::lower_bound in the C++ standard library
sub lowerbound_binsearch {
	my $arr = shift;
	my $first = shift;
	my $last = shift; # last is excluded, past the last item
	my $val = shift;
	
	my $len = $last - $first;
	while ($len > 0) {
		my $half = $len >> 1;
		my $middle = $first + $half;
		if ($arr->[$middle]{'begin'} < $val) {
			$first = $middle;
			$first++;
			$len = $len - $half - 1;
		}
		else {
			$len = $half;
		}
	}
	return $first;
}

# See std::upper_bound in the C++ standard library
sub upperbound_binsearch {
	my $arr = shift;
	my $first = shift;
	my $last = shift; # last is excluded, past the last item
	my $val = shift;
	
	my $it;
	my ($count, $step);
	$count = $last - $first;
	while ($count > 0)	{
		$it = $first; $step=$count/2; $it += $step;
		if (!($val < $arr->[$it]{'begin'})) {
			$it++;
			$first = $it;
			$count -= $step + 1;
		}
		else {
			$count= $step;
		}
	}
	return $first;
}

sub get_contained_reads {
	my ($parsed_bed, $chr, $region_begin, $region_end, $strand) = @_;
	my $reads = $parsed_bed->{$chr}{$strand};

	my $low = lowerbound_binsearch($reads, 0, scalar @{$reads}, $region_begin);
	my $high = upperbound_binsearch($reads, $low, scalar @{$reads}, $region_end);

	my %result = ();
	if ($low == scalar @{$reads}) {
		return \%result;
	}
	#~ if ($high == scalar @{$reads}) {
		#~ $high--;
	#~ }

	for (my $i = $low; $i < $high; $i++) {
		my $read_begin = $reads->[$i]{'begin'}-1;
		my @read_ends = keys %{$reads->[$i]{'ends'}};
		foreach my $read_end (@read_ends) {
			if ($read_end <= $region_end) {
				$result{"$read_begin-".($read_end-1)} = $reads->[$i]{'ends'}{$read_end};
			}
		}
	}

	return \%result;
}

=method process_RNAstemloop

Process the outputs of RNAstemloop + RNAeval (both optimal and stemloop)
Returns a list of candidates.

=cut

sub process_RNAstemloop {
	my ($self, @args)  = @_;
	my ($STEM_FH)      = shift @args;
	my ($EVAL_OPT_FH)  = shift @args;
	my ($EVAL_STEM_FH) = shift @args;
	my ($seq_begin) = shift @args;
	my ($seq_len) = shift @args;
	my ($chr) = shift @args;
	my ($strand) = shift @args;
	my ($sequence_miRnas) = shift @args;
	my ($parsed_bed) = shift @args;

	my ($line_eval_opt, $line_eval_stem);
	my ($nameSeq, $dna, $structure_stemloop);
	my @candidates_array = ();

	while ( my $stem_line = <$STEM_FH> ) {
		if (miRkwood::Utils::is_fasta_header($stem_line)) {
			$nameSeq = substr ($stem_line, 1, -1);
		}
		elsif (miRkwood::Utils::is_fasta_line_relaxed($stem_line)) {
			$dna = substr $stem_line, 0, -1;
			$line_eval_opt = substr( <$EVAL_OPT_FH>, 0, -1 );    # the sequence as well
			if ( miRkwood::Utils::is_fasta_header( $line_eval_opt ) ) {
				$line_eval_opt = substr( <$EVAL_OPT_FH>, 0, -1 );
			}
			$line_eval_stem = substr( <$EVAL_STEM_FH>, 0, -1 );    # the sequence as well
				if ( miRkwood::Utils::is_fasta_header( $line_eval_stem )) {
				$line_eval_stem = substr( <$EVAL_STEM_FH>, 0, -1 );
			}
			if ( $dna ne $line_eval_opt || $dna ne $line_eval_stem ) {
				warn ('The sequences differ in RNAeval and RNAstemloop output');
			}
		}
		elsif ($stem_line =~ /(.*)/) {
			$structure_stemloop = $1;
			$line_eval_opt = <$EVAL_OPT_FH>;    # the structure as well, and the energy
			$line_eval_stem = <$EVAL_STEM_FH>;

			my ( $structure_optimal, $energy_optimal ) =
				miRkwood::Parsers::parse_Vienna_line($line_eval_opt);
			my ( $structure_stemloop, $energy_stemloop ) =
				miRkwood::Parsers::parse_Vienna_line($line_eval_stem);
			if ($structure_optimal) { # We have a structure
				if ($nameSeq =~ /.*__(\d*)-(\d*)$/) {
					my ($mfei, $amfe) = miRkwood::Utils::compute_mfei_and_amfe($dna, $energy_optimal);
					my ($start, $end);
                    my $stemloop = {};
					if ($strand eq '-') {
						($start, $end) = @{ miRkwood::Utils::get_position_from_opposite_strand( $1, $2, $seq_len) };
                        $stemloop = {begin => $seq_len - $2 + $seq_begin, end => $seq_len - $1 +1 + $seq_begin};
					}
					else {
						($start, $end) = ($1, $2);
                        $stemloop = {begin => $1 + $seq_begin-1, end => $2 + $seq_begin};
					}
					if (eval_single_stemloop($stemloop, $sequence_miRnas) == 1) {
						my $cluster_position = $seq_begin. '-' . ($seq_begin+$seq_len-1);
						my $res = {
							'name' => $nameSeq,
							'strand' => $strand,
							'sequence' => $dna,
							'start_position' => $stemloop->{'begin'},
							'end_position' => $stemloop->{'end'}-1, # includes the end
							'mfei' => $mfei,
							'amfe' => $amfe,
							'structure_optimal' => $structure_optimal,
							'energy_optimal' => $energy_optimal,
							'structure_stemloop' => $structure_stemloop,
							'energy_stemloop' => $energy_stemloop,
							'reads' => get_contained_reads($parsed_bed, $chr, $stemloop->{'begin'}, $stemloop->{'end'}, $strand),
							'cluster' => $cluster_position
						};
						push @candidates_array, $res;
					}
				}
			}
			else {
				warn( "No structure found in $line_eval_opt" );
			}    # if $line2
		}
		else {
			warn( "Unrecognized line " );
		}    #if $line1
	}    #while $line=<IN>
	return \@candidates_array;
}

1;
