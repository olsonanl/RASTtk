=head1 Find Physically Coupled Categories (e.g. Roles, Families)

    p3-find-couples.pl [options] catCol

This script performes the general function of finding categories of features that tend to be physically coupled,
that is, commonly occurring in close proximity on the contigs. It can be
used to find coupled protein families, coupled roles, coupled functional assignments, or any number of things.
The input (key) column should contain feature IDs. The I<category column> specified as a parameter should identify
the column that contains the feature classification of interest. This could be the feature's role, its global protein
family (or other type of protein family), or anything of importance that groups similar features. The output will
display pairs of these categories that tend to occur phyiscally close together on the chromosome. So, for example,
if the category column contained roles, this program would output role couples. If the category column contained
global protein families, this program would output protein family couples.

The output will be three columns-- the two category IDs and the number of times the couple occurred.

=head2 Parameters

The positional parameter is the index (1-based) or name of the column containing the category information.

The standard input can be overwritten using the options in L<P3Utils/ih_options>.

Additional command-line options are those given in L<P3Utils/col_options> (to specify the column containing
feature IDs) plus the following.

=over 4

=item minCount

The minimum number of times a couple must occur to be considered significant. The default is C<5>.

=item maxGap

The maximum number of base pairs allowed between two features in the same cluster. The default is C<2000>.

=item location

If the feature location is already present in the input file, the name of the column containing the feature location.

=item sequence

If the sequence ID is already present in the input file, the name of the column containing the sequence ID.

=back

=cut

use strict;
use P3DataAPI;
use P3Utils;


# Get the command-line options.
my $opt = P3Utils::script_opts('catCol', P3Utils::delim_options(), P3Utils::col_options(), P3Utils::ih_options(),
        ['minCount|mincount|min|m=i', 'minimum occurrence count', { default => 5 }],
        ['maxGap|maxgap|maxG|maxg|g=i', 'maximum feature gap', { default => 2000 }],
        ['location|loc|l=s', 'index (1-based) or name of column containing feature location (if any)'],
        ['sequence|seq|s=s', 'index (1-based) or name of column containing the ID of the contig containing the feature']
        );
# This is keyed on genomeID:sequenceID and will contain the list of features for each sequence, in the form
# [category, start, end].
my %contigs;
# Get the options.
my $locCol = $opt->location;
my $seqCol = $opt->sequence;
my $maxGap = $opt->maxgap;
my $minCount = $opt->mincount;
# Get the category column.
my ($catCol) = @ARGV;
if (! defined $catCol) {
    die "No category column specified.";
}
# Get access to PATRIC.
my $p3 = P3DataAPI->new();
# Open the input file.
my $ih = P3Utils::ih($opt);
# Read the incoming headers.
my ($outHeaders, $keyCol) = P3Utils::process_headers($ih, $opt);
# Find the location and sequence columns. An undef for either means we need to get its data from the database,
# in which case the field name goes in the select list.
my @selects = 'patric_id';
my $queryNeeded;
if (defined $seqCol) {
    $seqCol = P3Utils::find_column($seqCol, $outHeaders);
} else {
    push @selects, 'sequence_id';
    $queryNeeded = 1;
}
if (defined $locCol) {
    $locCol = P3Utils::find_column($locCol, $outHeaders);
} else {
    push @selects, 'start', 'end';
    $queryNeeded = 1;
}
# Find the category column.
$catCol = P3Utils::find_column($catCol, $outHeaders);
# Form the full header set and write it out.
if (! $opt->nohead) {
    my @headers = ("$outHeaders->[$catCol]1", "$outHeaders->[$catCol]2", 'count');
    P3Utils::print_cols(\@headers);
}
# Loop through the input.
while (! eof $ih) {
    my $couplets = P3Utils::get_couplets($ih, $keyCol, $opt);
    # Do we need to read from the database?
    my %rows;
    if ($queryNeeded) {
        my $inString = '(' . join(',', map { $_->[0] } @$couplets) . ')';
        %rows = map { $_->{patric_id} => $_ } $p3->query(genome_feature => [select => @selects], [in => 'patric_id', $inString]);
    }
    # Now we run through the couplets, putting the [category, start, end] tuples in the hash.
    for my $couplet (@$couplets) {
        my ($fid, $line) = @$couplet;
        my $category = $line->[$catCol];
        my ($start, $end, $sequence);
        my $fidData = $rows{$fid};
        # Here we get the start and end.
        if (defined $locCol) {
            my $loc = $line->[$locCol];
            if ($loc =~ /(\d+)\.\.(d+)/) {
                ($start, $end) = ($1, $2);
            } else {
                die "Invalid location string \'$loc\'.";
            }
        } elsif (! $fidData) {
            die "$fid not found in PATRIC.";
        } else {
            ($start, $end) = ($fidData->{start}, $fidData->{end});
        }
        # Here we get the sequence ID.
        if (defined $seqCol) {
            $sequence = $line->[$seqCol];
        } elsif (! $fidData) {
            die "$fid not found in PATRIC.";
        } else {
            $sequence = $fidData->{sequence_id};
        }
        # Compute the genome ID.
        my ($genomeID) = ($fid =~ /(\d+\.\d+)/);
        # Put the feature in the hash.
        push @{$contigs{"$genomeID:$sequence"}}, [$category, $start, $end];
    }
}
# Now we have category and position data for each feature sorted by sequence.
# For each list, we sort by start position and figure out what qualifies as a couple.
# The couples are counted in this hash, which is keyed by "element1\telement2".
my %couples;
for my $contig (keys %contigs) {
    my @features = sort { $a->[1] <=> $b->[1] } @{$contigs{$contig}};
    # We process one feature at a time, and stop when there are none left
    # to couple with it.
    my $feat = shift @features;
    while (scalar @features) {
        my $cat1 = $feat->[0];
        # Compute the latest start position that qualifies as a couple.
        my $limit = $feat->[2] + $maxGap;
        # Loop through the remaining features until we hit the limit.
        for my $other (@features) { last if $other->[1] > $limit;
            if ($cat1 ne $other->[0]) {
                my $couple = join("\t", sort ($cat1, $other->[0]));
                $couples{$couple}++;
            }
        }
        # Get the next feature.
        $feat = shift @features;
    }
}
# Sort the couples and output them.
my @couples = sort { $couples{$b} <=> $couples{$a} } grep { $couples{$_} >= $minCount } keys %couples;
for my $couple (@couples) {
    print "$couple\t$couples{$couple}\n";
}