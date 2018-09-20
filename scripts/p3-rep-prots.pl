=head1 Create Representative Genome Server Directory

    p3-rep-prots.pl [options] outDir

This script processes a list of genome IDs to create a directory suitable for use by the L<RepresentativeGenomes> server.
It will extract all the instances of the specified seed protein (default is Phenylanyl synthetase alpha chain). The list of genome IDs and
names will go in the output file C<complete.genomes> and a FASTA of the seed proteins in C<6.1.1.20.fasta>.

=head2 Parameters

The positional parameter is the name of the output directory. If it does not exist, it will be created.

The standard input can be overriddn using the options in L<P3Utils/ih_options>.

Additional command-line options are those given in L<P3Utils/col_options> plus the following
options.

=over 4

=item clear

Clear the output directory if it already exists. The default is to leave existing files in place.

=item prot

Role name of the protein to use. The default is C<Phenylalanyl-tRNA synthetase alpha chain>.

=item resume

Resume an interrupted run. The current files will be read into memory and written back out, then
only new genomes will be added. Mutually exclusive with C<--clear>.

=item dna

If specified, a C<6.1.1.20.dna.fasta> file will be produced in addition to the others, containing
the DNA sequences of the proteins.

=back

=cut

use strict;
use P3DataAPI;
use P3Utils;
use Stats;
use File::Copy::Recursive;
use RoleParse;
use Time::HiRes;
use Math::Round;
use FastA;

$| = 1;
# Get the command-line options.
my $opt = P3Utils::script_opts('outDir', P3Utils::col_options(), P3Utils::ih_options(),
        ['clear', 'clear the output directory if it exists'],
        ['prot=s', 'name of the protein to use', { default => 'Phenylalanyl-tRNA synthetase alpha chain' }],
        ['resume', 'finish an interrupted run'],
        ['dna', 'produce a DNA FASTA file in addition to the default files']
        );
# Verify the mutually exclusive options.
my $resume = $opt->resume;
if ($opt->clear && $resume) {
    die "Cannot clear when resuming.";
}
# Get the output directory name.
my ($outDir) = @ARGV;
if (! $outDir) {
    die "No output directory specified.";
} elsif (! -d $outDir) {
    print "Creating directory $outDir.\n";
    File::Copy::Recursive::pathmk($outDir) || die "Could not create $outDir: $!";
} elsif ($opt->clear) {
    print "Erasing directory $outDir.\n";
    File::Copy::Recursive::pathempty($outDir) || die "Error clearing $outDir: $!";
}
# Check for DNA mode.
my $dnaFile;
if ($opt->dna) {
    $dnaFile = "$outDir/6.1.1.20.dna.fasta";
}
# Create the statistics object.
my $stats = Stats->new();
# Check for resume mode and create a hash of the genomes already in the files.
my %previous;
if ($resume) {
    open(my $gh, "<$outDir/complete.genomes") || die "Could not re-open complete.genomes: $!";
    my %pNames;
    while (! eof $gh) {
        my $line = <$gh>;
        if ($line =~ /^(\d+\.\d+)\t(.+)/) {
            $pNames{$1} = $2;
            $stats->Add(previousName => 1);
        }
    }
    my $fh = FastA->new("$outDir/6.1.1.20.fasta");
    while ($fh->next) {
        my $id = $fh->id;
        $stats->Add(previousProt => 1);
        if ($pNames{$id}) {
            $previous{$id} = [$pNames{$id}, $fh->left];
            $stats->Add(previousStored => 1);
        }
    }
    if ($dnaFile) {
        $fh = FastA->new($dnaFile);
        while ($fh->next) {
            my $id = $fh->id;
            if ($previous{$id}) {
                $stats->Add(previousDna => 1);
                push @{$previous{$id}}, $fh->left;
            }
        }
    }
}
# Create a filter from the protein name.
my $protName = $opt->prot;
my @filter = (['eq', 'product', $protName]);
# Save the checksum for the seed role.
my $roleCheck = RoleParse::Checksum($protName);
# Create a list of the columns we want.
my @cols = qw(genome_name patric_id aa_sequence product);
if ($dnaFile) {
    push @cols, 'na_sequence';
}
# Open the output files.
print "Setting up files.\n";
open(my $gh, '>', "$outDir/complete.genomes") || die "Could not open genome output file: $!";
open(my $fh, '>', "$outDir/6.1.1.20.fasta") || die "Could not open FASTA output file: $!";
my $nh;
if ($dnaFile) {
    open($nh, '>', $dnaFile) || die "Could not open DNA output file: $!";
}
# Get access to PATRIC.
my $p3 = P3DataAPI->new();
# Open the input file.
my $ih = P3Utils::ih($opt);
# Read the incoming headers.
my ($outHeaders, $keyCol) = P3Utils::process_headers($ih, $opt);
# Count the batches of input.
my $start0 = time;
my $gCount = 0;
# Loop through the input.
while (! eof $ih) {
    my $couplets = P3Utils::get_couplets($ih, $keyCol, $opt);
    # Filter out the genomes we already have. We will store ID-only couplets in here.
    my @couples;
    # This will store the stuff we're keeping.
    my %proteins;
    # Initial couplet loop for filtering.
    for my $couplet (@$couplets) {
        my $genome = $couplet->[0];
        if ($previous{$genome}) {
            $proteins{$genome} = [$previous{$genome}];
            $stats->Add(genomePreviousUsed => 1);
        } else {
            push @couples, [$genome, [$genome]];
            $stats->Add(genomeNew => 1);
        }
        $gCount++;
    }
    if (@couples) {
        # Get the features of interest for the new genomes.
        my $protList = P3Utils::get_data($p3, feature => \@filter, \@cols, genome_id => \@couples);
        # Collate them by genome ID, discarding the nulls.
        for my $prot (@$protList) {
            my ($genome, $name, $fid, $sequence, $product, $dna) = @$prot;
            if ($fid) {
                # We have a real feature, check the function.
                my $check = RoleParse::Checksum($product // '');
                if ($check ne $roleCheck) {
                    $stats->Add(funnyProt => 1);
                } else {
                    push @{$proteins{$genome}}, [$name, $sequence, $dna];
                    $stats->Add(protFound => 1);
                }
            }
        }
    }
    # Process the genomes one at a time.
    for my $genome (keys %proteins) {
        my @prots = @{$proteins{$genome}};
        $stats->Add(genomeFound => 1);
        if (scalar @prots > 1) {
            # Skip if we have multiple proteins.
            $stats->Add(multiProt => 1);
        } else {
            # Get the genome name and sequence.
            my ($name, $seq, $dna) = @{$prots[0]};
            print $gh "$genome\t$name\n";
            print $fh ">$genome\n$seq\n";
            if ($nh && $dna) {
                print $nh ">$genome\n$dna\n";
                $stats->Add(dnaOut => 1);
            }
            $stats->Add(genomeOut => 1);
        }
    }
    print "$gCount genomes processed at " . Math::Round::nearest(0.01, (time - $start0) / $gCount) . " seconds/genome.\n";
}
print "All done.\n" . $stats->Show();
