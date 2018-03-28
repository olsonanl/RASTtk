#!/usr/bin/env perl
#
# Copyright (c) 2003-2015 University of Chicago and Fellowship
# for Interpretations of Genomes. All Rights Reserved.
#
# This file is part of the SEED Toolkit.
#
# The SEED Toolkit is free software. You can redistribute
# it and/or modify it under the terms of the SEED Toolkit
# Public License.
#
# You should have received a copy of the SEED Toolkit Public License
# along with this program; if not write to the University of Chicago
# at info@ci.uchicago.edu or the Fellowship for Interpretation of
# Genomes at veronika@thefig.info or download a copy from
# http://www.theseed.org/LICENSE.TXT.
#


use strict;
use warnings;
use FIG_Config;
use ScriptUtils;
use GenomeTypeObject;
use File::Copy::Recursive;
use Stats;
use GtoChecker;
use Math::Round;

=head1 Check Completeness and Contamination for One or More GTOs

    check_gto.pl [ options ] outDir gto1 gto2 gto3 ... gtoN

This script takes as input a list of L<GenomeTypeObject> files. For each, it examines the features to determine
completeness and contamination.  In addition, a file of the marker roles will be written out so that the problematic
roles can be determined.

=head2 Parameters

The positional parameters are the name of the output directory followed by the names of all the GTO files to examine.
If a directory is specified for a GTO name, all I<*>C<.gto> files in the directory will be processed.

The command-line options are the following.

=over 4

=item roleFile

The name of the file containing the role ID mappings. This file is headerless and contains in each record (0) a role ID,
(1) a role checksum, and (2) the role name. The default is C<roles.in.subsystems> in the global data directory.

=item workDir

The name of the directory containing the C<roles.tbl> and C<taxon_map.tbl> files produced by the data generation scripts
(see L<GtoChecker>). The default is C<CheckG> in the global data directory.

=item missing

If specified, only GTOs without output files in the output directory will be processed.

=item packages

If specified, each directory name will be presumed to by a genome package directory, and all the genome packages in it
will be processed.

=back

=head2 Output Files

For each GTO, two output files will be produced, both tab-delimited with headers and named after the GTO's genome ID.
I<genome>C<.out> will contain the completeness, contamination, and relevant taxonomic group for the genome. I<genome>C<.tbl>
will contain a table of marker roles and the number of times each role was found. Roles with a count of C<0> are missing.
Roles with a count greater than C<1> indicate contamination. Note the file name matches the genome ID, so a GTO with a genome
ID of C<100226.10> will produce files named C<100226.10.out> and C<100226.10.tbl>.

=cut

$| = 1;
# Get the command-line parameters.
my $opt = ScriptUtils::Opts('outDir gto1 gto2 gto3 ... gtoN', ScriptUtils::ih_options(),
        ['roleFile|roles|R=s', 'role-mapping file', { default => "$FIG_Config::global/roles.in.subsystems" }],
        ['workDir=s', 'directory containing data files', { default => "$FIG_Config::global/CheckG" }],
        ['missing|m', 'only process new GTOs'],
        ['packages', 'directory inputs contain genome packages'],
        );
# Get the statistics object.
my $stats = Stats->new();
# Verify the parameters.
my ($outDir, @gtos) = @ARGV;
if (! $outDir) {
    die "No output directory specified.";
} elsif (! -d $outDir) {
    print "Creating $outDir.\n";
    File::Copy::Recursive::pathmk($outDir) || die "Could not create output directory: $!";
}
if (! @gtos) {
    die "No input GTOs specified.";
}
# Get the options.
my $missing = $opt->missing;
my $packages = $opt->packages;
my $workDir = $opt->workdir;
my $roleFile = $opt->rolefile;
# If there are any packages, this hash saves the (complete, contam, taxon) triples found.
my %packageQH;
# Now we create a list of all the GTOs.
print "Gathering input.\n";
my @inputs;
# Now we loop through the GTOs.
for my $gtoName (@gtos) {
    if (-d $gtoName) {
        opendir(my $dh, $gtoName) || die "Could not open $gtoName: $!";
        my @files;
        if ($packages) {
            print "Collecting genome packages in $gtoName.\n";
            my @dirs = grep { substr($_,0,1) ne '.' && -d "$gtoName/$_" } readdir $dh;
            for my $dir (@dirs) {
                my $fileName = "$gtoName/$dir/bin.gto";
                if (-s $fileName) {
                    push @files, $fileName;
                    if (-s "$gtoName/$dir/quality.tbl") {
                        open(my $qh, "<$gtoName/$dir/quality.tbl") || die "Could not open quality.tbl for $dir: $!";
                        my @fields = ScriptUtils::get_line($qh);
                        $packageQH{$fileName} = [ @fields[13, 14, 15] ];
                    }
                }
            }
            print scalar(@files) . " packages found.\n";
        } else {
            print "Collecting GTO files in $gtoName.\n";
            @files = map { "$gtoName/$_" } grep { $_ =~ /\.gto$/ } readdir $dh;
            print scalar(@files) . " GTO files found.\n";
        }
        push @inputs, @files;
        closedir $dh;
    } else {
        push @inputs, $gtoName;
    }
}
my $total = scalar @inputs;
print "$total GTO files found.\n";
print "Creating GTO Checker object.\n";
my $checker = GtoChecker->new($workDir, stats => $stats, roleFile => $roleFile, logH => \*STDOUT);
# Loop through the GTO files.
my $count = 0;
for my $gtoFile (@inputs) {
    $count++;
    print "Processing $gtoFile ($count of $total).\n";
    # Read this GTO.
    my $gto = GenomeTypeObject->create_from_file($gtoFile);
    $stats->Add(gtoRead => 1);
    # Get the genome ID.
    my $genomeID = $gto->{id};
    # If the output exists and MISSING is on, then skip.
    if (-s "$outDir/$genomeID.out" && $missing) {
        print "Output already in $outDir-- skipping.\n";
        $stats->Add(gtoSkipped => 1);
    } else {
        # Check the genome.
        my $resultH = $checker->Check($gto);
        my $complete = $resultH->{complete};
        if (! defined $complete) {
            print "Genome is from an unsupported taxonomic grouping.\n";
            $stats->Add(gtoFail => 1);
        } else {
            $complete = nearest(0.01, $complete);
            my $contam = nearest(0.01, $resultH->{contam});
            my $roleHash = $resultH->{roleData};
            my $group = $resultH->{taxon};
            print "Producing output for $genomeID in $outDir.\n";
            open(my $rh, ">$outDir/$genomeID.tbl") || die "Could not open $genomeID.tbl: $!";
            print $rh "Role\tCount\tName\n";
            for my $role (sort keys %$roleHash) {
                my $name = $checker->role_name($role);
                print $rh "$role\t$roleHash->{$role}\t$name\n";
            }
            close $rh;
            open(my $oh, ">$outDir/$genomeID.out") || die "Could not open $genomeID.out: $!";
            print $oh "Completeness\tContamination\tGroup\n";
            print $oh "$complete\t$contam\t$group\n";
            my ($groupWord) = split /\s/, $group;
            $stats->Add("gto-$groupWord" => 1);
            # If there is a package quality tuple, put it into the trace message.
            my $tuple = $packageQH{$gtoFile};
            if ($tuple) {
                $complete .= " ($tuple->[0])";
                $contam   .= " ($tuple->[1])";
                $group    .= " ($tuple->[2])";
            }
            print "Completeness $complete contamination $contam using $group.\n";
        }
    }
}
print "All done.\n" . $stats->Show();
