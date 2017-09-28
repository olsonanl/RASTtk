=head1 Small File Multi-Column Sort

    p3-sort.pl [options] col1 col2 ... colN

This is a sort script variant that sorts a single small file in memory with the ability to specify multiple columns.
It assumes the file has a header, and the columns are tab-delimited. If no columns are specified, it sorts by the
first column only.

=head2 Parameters

The positional parameters are the indices (1-based) or names of the key columns. Columns to be sorted numerically
are indicated by a slash-n (C</n>) at the end of the column index or name. So,

    p3-sort genome.genome_id feature.start/n

Would indicate two key columns, the second of which is to be sorted numerically.

The standard input can be overriddn using the options in L<P3Utils/ih_options>.

The following additional options are suppported.

=over 4

=item count

If specified, the output will consist only of the key fields with a count column added.

=item nonblank

If specified, records with at least one empty key field will be discarded.

=item unique

Only include one output line for each key value.

=back

=cut

use strict;
use P3Utils;

# Get the command-line options.
my $opt = P3Utils::script_opts('col1 col2 ... colN', P3Utils::ih_options(),
        ['count|K', 'count instead of sorting'],
        ['nonblank|V', 'discard records with empty keys'],
        ['unique|u', 'remove duplicate keys'],
        );
# Verify the parameters. We need to separate the column names from the sort types.
my @sortCols;
my @sortTypes;
if (! @ARGV) {
    # No sort key. Sort by first column.
    @sortCols = 1;
    @sortTypes = 0;
} else {
    for my $sortCol (@ARGV) {
        if ($sortCol =~ /^(.+)\/n$/) {
            push @sortCols, $1;
            push @sortTypes, 1;
        } else {
            push @sortCols, $sortCol;
            push @sortTypes, 0;
        }
    }
}
# Get the options.
my $count = $opt->count;
my $valued = $opt->nonblank;
my $unique = $opt->unique;
# Open the input file.
my $ih = P3Utils::ih($opt);
# Read the incoming headers and compute the key columns.
my ($headers, $cols) = P3Utils::find_headers($ih, 'sort input' => @sortCols);
# Write out the headers.
if ($count) {
    my @sortHeaders = P3Utils::get_cols($headers, $cols);
    P3Utils::print_cols([@sortHeaders, 'count']);
} else {
    P3Utils::print_cols($headers);
}
# We will use this hash to facilitate the sort. It is keyed on the tab-delimited sort columns.
my %sorter;
# Loop through the input.
while (! eof $ih) {
    my $line = <$ih>;
    my @fields = P3Utils::get_fields($line);
    # Form the key.
    my @key = map { $fields[$_] } @$cols;
    if (! $valued || ! scalar grep { $_ eq '' } @key) {
        my $key1 = join("\t", @key);
        push @{$sorter{$key1}}, $line;
    }
}
# Now process each group.

for my $key (sort { tab_cmp($a, $b) } keys %sorter) {
    # Sort the items.
    my $subList = $sorter{$key};
    if ($unique) {
        # Print the first item.
        print $subList->[0];
    } elsif (! $count) {
        # Print all the sorted items.
        print @$subList;
    } else {
        # Count the items for each key combination and print them.
        my $count = scalar @$subList;
        print "$key\t$count\n";
    }
}

# Compare two lists.
sub tab_cmp {
    my ($a, $b) = @_;
    my @a = split /\t/, $a;
    my @b = split /\t/, $b;
    my $n = scalar @a;
    my $retVal = 0;
    for (my $i = 0; $i < $n && ! $retVal; $i++) {
        if ($sortTypes[$i]) {
            $retVal = $a[$i] <=> $b[$i];
        } else {
            $retVal = $a[$i] cmp $b[$i];
        }
    }
    return $retVal;
}
