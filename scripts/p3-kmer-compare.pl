=head1 Perform a Kmer Comparison for Two Genomes

    p3-kmer-compare.pl [options] genome1 genome2 ... genomeN

This script compares genomes based on DNA kmers. It outputs the number of kmers the two genomes have in common, the number appearing
only in the first genome, and the number appearing only in the second. It then produces a ratio from 0 to 1 indicating the DNA similarity.
A value of 1 indicates the genomes are effectively identical.

=head2 Parameters

The positional parameters are the two genomes to compare. Each genome can be either (1) a PATRIC genome ID, (2) the name of a DNA FASTA file, or
(3) the name of a L<GenomeTypeObject> file.

There is no standard input.

The command-line options are as follows.

=over 4

=item kmerSize

The size of a kmer. The default is C<15>.

=back

=cut

use strict;
use P3DataAPI;
use P3Utils;
use KmerDb;

# Get the command-line options.
my $opt = P3Utils::script_opts('genome1 genome2 ... genomeN',
        ['kmerSize|kmersize|kmer|k=i', 'kmer size', { default => 15 }]
        );
# Extract the options.
my $kmerSize = $opt->kmersize;
# Get access to PATRIC.
my $p3 = P3DataAPI->new();
# Get the two genomes.
my @genomes = @ARGV;
# Create the kmer database. Each genome will be a group.
my $kmerDb = KmerDb->new(kmerSize => $kmerSize, maxFound => 0);
for my $genome (@genomes) {
    if ($genome =~ /^\d+\.\d+$/) {
        print STDERR "Processing PATRIC genome $genome.\n";
        ProcessPatric($kmerDb, $genome);
    } elsif (-s $genome) {
        # Here the genome is a file.
        open(my $gh, "<$genome") || die "Could not open genome file $genome: $!";
        # Read the first line.
        my $line = <$gh>;
        if ($line =~ /^>(\S+)/) {
            # Process the FASTA file starting with the contig whose header we just read.
            print STDERR "Processing FASTA file $genome.\n";
            ProcessFasta($kmerDb, $genome, $1, $gh);
        } elsif ($line =~ /\{/) {
            # Read the file into memory and convert to a GTO.
            print STDERR "Reading GTO file $genome.\n";
            my $gto = ReadGto($line, $gh);
            # Close the file and release the line variable in case it's a one-line GTO.
            close $gh;
            undef $line;
            # Process the GTO's contigs.
            print STDERR "Processing GTO file $genome.\n";
            ProcessGto($kmerDb, $genome, $gto);
        } else {
            die "$genome is not a recognizable GTO or FASTA file.";
        }
    } else {
        die "Invalid genome specifier $genome.";
    }
}
# Compute the cross-reference matrix.
print STDERR "Creating cross-reference matrix.\n";
my $xref = $kmerDb->xref();
# Print out the matrix.
P3Utils::print_cols(['genome', 'name', @genomes]);
for my $genomeI (@genomes) {
    my @row = ($genomeI, $kmerDb->name($genomeI));
    for my $genomeJ (@genomes) {
        # If the genomes are identical, use a dummy.
        if ($genomeI eq $genomeJ) {
            push @row, '100.0/0.0';
        } else {
            # There is only one entry for this genome pair. If it's not the one we expect,
            # we use its dual.
            my $list = $xref->{$genomeI}{$genomeJ};
            if (! $list) {
                $list = [reverse @{$xref->{$genomeJ}{$genomeI}}];
            }
            my $complete = $list->[1] * 100 / ($list->[1] + $list->[2]);
            my $contam = $list->[0] * 100 / ($list->[0] + $list->[1]);
            push @row, sprintf("%.1f/%1.f", $complete, $contam);
        }
    }
    P3Utils::print_cols(\@row);
}

## Read a GenomeTypeObject file. We don't bless it or anything, because we just need the contigs.
## Doing this in a subroutine cleans up the very memory-intensive intermediate variables.
sub ReadGto {
    my ($line, $gh) = @_;
    my @lines = <$gh>;
    my $string = join("", $line, @lines);
    my $retVal = SeedUtils::read_encoded_object(\$string);
    return $retVal;
}

## Process a PATRIC genome. The genome's contigs will be put into the Kmer database.
sub ProcessPatric {
    my ($kmerDb, $genome) = @_;
    # Get the genome's contigs.
    my $results = P3Utils::get_data($p3, contig => [['eq', 'genome_id', $genome]], ['genome_name', 'sequence']);
    # Process the sequence kmers.
    for my $result (@$results) {
        $kmerDb->AddSequence($genome, $result->[1], $result->[0]);
    }
}

## Process a FASTA genome. The FASTA sequences will be put into the Kmer database. Note we ignore the labels.
sub ProcessFasta {
    my ($kmerDb, $genome, $label, $gh) = @_;
    # We will accumulate the current sequence in here.
    my @chunks;
    # This will be TRUE if we read end-of-file.
    my $done;
    # Loop through the file.
    while (! $done) {
        my $chunk = <$gh>;
        if (! $chunk || $chunk =~ /^>/) {
            # Here we are at the end of a sequence.
            my $line = join("", @chunks);
            $kmerDb->AddSequence($genome, $line, "$genome FASTA file");
            $done = ! $chunk;
        } else {
            # Here we have part of a sequence.
            push @chunks, $chunk;
        }
    }
}

## Process a GTO genome. The contigs will be put into the Kmer database.
sub ProcessGto {
    my ($kmerDb, $genome, $gto) = @_;
    # Get the genome name.
    my $name = $gto->{scientific_name};
    # Loop through the contigs.
    my $contigsL = $gto->{contigs};
    for my $contig (@$contigsL) {
        $kmerDb->AddSequence($genome, $contig->{dna}, $name);
    }
}