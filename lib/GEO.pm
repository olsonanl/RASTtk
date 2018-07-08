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


package GEO;

    use strict;
    use warnings;
    use GenomeTypeObject;
    use RoleParse;
    use BasicLocation;
    use P3DataAPI;
    use Stats;
    use P3Utils;
    use SeedUtils;
    use URI::Escape;

=head1 Genome Evaluation Object

This object is used by the genome evaluation libraries-- L<EvalCon>, L<GenomeChecker>, L<BinningReports>, and the various scripts that
use them. Methods are provided to construct the object from a GTO or from web queries to PATRIC itself.

This object has the following fields.

=over 4

=item good_seed

TRUE if the genome has a good seed protein (Phenylalanyl tRNA synthetase alpha chain), else FALSE.

=item roleFids

Reference to a hash that maps each mapped role to a list of the IDs of the features that contain it.

=item id

The ID of the genome in question.

=item name

The name of the genome in question.

=item domain

The domain of the genome in question-- either C<Bacteria> or C<Archaea>.

=item taxon

The taxonomic grouping ID for the genome in question.

=back

The following fields are usually passed in by the client.

=over 4

=item nameMap

Reference to a hash that maps role IDs to role names.

=item checkMap

Reference to a hash that maps role checksums to role IDs.

=back

The following optional fields may also be present.

=over 4

=item lineage

Reference to a list of taxonomic grouping IDs, representing the complete lineage of the genome.
This is only present if the genome was loaded directly from PATRIC.

=item refGeo

Reference to a list of L<GEO> objects for associated reference genomes believed to be close, but of better quality.

=item fidLocs

Reference to a hash that maps each feature belonging to an mapped role to its location.

=item contigs

Reference to a hash that maps each contig ID to the contig length.

=item quality

If the quality results have been processed, a reference to a hash containing genome quality information,
with the following keys.

=item proteins

Reference to a hash that maps each feature to its protein sequence.

=over 8

=item fine_consis

Fine consistency percentage.

=item coarse_consis

Coarse consistency percentage.

=item complete

Completeness percentage.

=item contam

Contamination percentage.

=item taxon

Name of the taxonomic grouping used to compute completeness and contamination.

=item metrics

A reference to a hash of contig length metrics with the following fields.

=over 12

=item N50

The N50 of the contig lengths (see L</n_metric>).

=item N70

The N70 of the contig lengths.

=item N90

The N90 of the contig lengths.

=item totlen

The total DNA length.

=item complete

C<1> if the genome is mostly complete, else C<0>.

=back

=item over_roles

Number of over-represented roles.

=item under_roles

Number of under-represented roles.

=item pred_roles

Number of predicted roles.

=item roles

Reference to a hash that maps the ID of each predicted role to a 3-tuple consisting of (0) the prediction, (1) the
actual count, and (2) a comment.

=item contigs

Reference to a hash that maps the ID of each contig to a list consisting of a count of the good roles followed
by the IDs of the features containing bad roles.

=back

=back

=head2 Special Methods

=head3 CreateFromPatric

    my $gHash = GEO->CreateFromPatric(\@genomes, %options);

Create a set of genome evaluation objects directly from PATRIC.

=over 4

=item genomes

Reference to a list of PATRIC genome IDs.

=item options

A hash containing zero or more of the following keys.

=over 8

=item roleHashes

Reference to a 2-tuple containing reference to role-mapping hashes-- (0) a map of role IDs to names, and (1) a map of role checksums
to IDs. If omitted, the role hashes will be loaded from the global roles.in.subsystems file.

=item p3

Reference to a L<P3DataAPI> object for accessing PATRIC. If omitted, one will be created.

=item stats

Reference to a L<Stats> object for tracking statistical information. If omitted, the statistics will be discarded.

=item detail

Level of detail-- C<0> roles only, C<1> roles and contigs, C<2> roles, contigs, and proteins.

=item logH

Open file handle for status messages. If not specified, no messages will be written.

=back

=item RETURN

Returns a reference to a hash that maps each genome ID to the evaluation object created for it. Genomes that were not found
in PATRIC will not be included.

=back

=cut

sub CreateFromPatric {
    my ($class, $genomes, %options) = @_;
    # This will be the return hash.
    my %retVal;
    # Get the log file.
    my $logH = $options{logH};
    # Get the stats object.
    my $stats = $options{stats} // Stats->new();
    # Process the options.
    my ($nMap, $cMap) = _RoleMaps($options{roleHashes}, $logH, $stats);
    my $p3 = $options{p3} // P3DataAPI->new();
    my $detail = $options{detail};
    # Compute the feature columns for the current mode.
    my @fCols = qw(patric_id product aa_length);
    if ($detail) {
        push @fCols, qw(sequence_id start na_length strand);
        if ($detail > 1) {
            push @fCols, qw(aa_sequence);
        }
    }
    # Now we have everything in place for loading. We start by getting the genome information.
    my $gCount = scalar @$genomes;
    $stats->Add(genomesIn => $gCount);
    _log($logH, "Requesting $gCount genomes from PATRIC.\n");
    my $genomeTuples = P3Utils::get_data_keyed($p3, genome => [], ['genome_id', 'genome_name',
            'kingdom', 'taxon_id', 'taxon_lineage_ids'], $genomes);
    # Loop through the genomes found.
    for my $genomeTuple (@$genomeTuples) {
        my ($genome, $name, $domain, $taxon, $lineage) = @$genomeTuple;
        $retVal{$genome} = { id => $genome, name => $name, domain => $domain, nameMap => $nMap, checkMap => $cMap,
            taxon => $taxon, lineage => ($lineage || []) };
        $stats->Add(genomeFoundPatric => 1);
        # Compute the aa-len limits for the seed protein.
        my ($min, $max) = (209, 405);
        if ($domain eq 'Archaea') {
            ($min, $max) = (293, 652);
        }
        my $seedCount = 0;
        my $goodSeed = 1;
        # Now we need to get the roles. For each feature we need its product (function), ID, and protein length.
        # Depending on the detail level, we also get location and the aa-sequence.
        _log($logH, "Reading features for $genome.\n");
        my $featureTuples = P3Utils::get_data($p3, feature => [['eq', 'genome_id', $genome]],
                \@fCols);
        # Build the role, protein, and location hashes in here.
        my (%roles, %proteins, %locs);
        for my $featureTuple (@$featureTuples) {
            $stats->Add(featureFoundPatric => 1);
            # Note that some of these will be undef if we are at a low detail level.
            my ($fid, $function, $aaLen, $contig, $start, $len, $dir, $prot) = @$featureTuple;
            # Only features with functions matter to us.
            if ($function) {
                my @roles = SeedUtils::roles_of_function($function);
                my $mapped = 0;
                for my $role (@roles) {
                    my $checkSum = RoleParse::Checksum($role);
                    $stats->Add(roleFoundPatric => 1);
                    my $rID = $cMap->{$checkSum};
                    if (! $rID) {
                        $stats->Add(roleNotMapped => 1);
                    } else {
                        $stats->Add(roleMapped => 1);
                        push @{$roles{$rID}}, $fid;
                        $mapped++;
                        if ($rID eq 'PhenTrnaSyntAlph') {
                            $seedCount++;
                            if ($aaLen < $min) {
                                $stats->Add(seedTooShort => 1);
                                $goodSeed = 0;
                            } elsif ($aaLen > $max) {
                                $stats->Add(seedTooLong => 1);
                                $goodSeed = 0;
                            }
                        }
                    }
                }
                if ($detail && $mapped) {
                    # If we are saving details and this feature had an interesting role, we
                    # also need to save the location.
                    $locs{$fid} = BasicLocation->new([$contig, $start, $dir, $len]);
                }
                if ($prot) {
                    # If we have a protein sequence, save that too.
                    $proteins{$fid} = $prot;
                }
            }
        }
        # Store the role map.
        $retVal{$genome}{roleFids} = \%roles;
        # Compute the good-seed flag.
        if (! $seedCount) {
            $stats->Add(seedNotFound => 1);
            $goodSeed = 0;
        } elsif ($seedCount > 1) {
            $stats->Add(seedTooMany => 1);
            $goodSeed = 0;
        }
        $retVal{$genome}{good_seed} = $goodSeed;
        # Check for the optional stuff.
        if ($detail) {
            # Here we also need to store the location map.
            $retVal{$genome}{fidLocs} = \%locs;
            # Finally, we need the contig lengths.
            _log($logH, "Reading contigs for $genome.\n");
            my %contigs;
            my $contigTuples = P3Utils::get_data($p3, contig => [['eq', 'genome_id', $genome]], ['sequence_id', 'length']);
            for my $contigTuple (@$contigTuples) {
                $stats->Add(contigFoundPatric => 1);
                my ($contigID, $len) = @$contigTuple;
                $contigs{$contigID} = $len;
            }
            $retVal{$genome}{contigs} = \%contigs;
            $retVal{$genome}{proteins} = \%proteins;
        }
    }
    # Run through all the objects, blessing them.
    for my $genome (keys %retVal) {
        bless $retVal{$genome}, $class;
    }
    # Return the hash of objects.
    return \%retVal;
}

=head3 CreateFromGtoFiles

    my $gHash = GEO->CreateFromGtoFiles(\@files, %options);

Create a set of genome evaluation objects from L<GenomeTypeObject> files.

=over 4

=item files

Reference to a list of file names, each containing a L<GenomeTypeObject> in JSON form.

=item options

A hash containing zero or more of the following keys.

=over 8

=item roleHashes

Reference to a 2-tuple containing reference to role-mapping hashes-- (0) a map of role IDs to names, and (1) a map of role checksums
to IDs. If omitted, the role hashes will be loaded from the global roles.in.subsystems file.

=item p3

Reference to a L<P3DataAPI> object for accessing PATRIC. If omitted, one will be created.

=item stats

Reference to a L<Stats> object for tracking statistical information. If omitted, the statistics will be discarded.

=item detail

Level of detail-- C<0> roles only, C<1> roles and contigs, C<2> roles, contigs, and proteins.

=item logH

Open file handle for status messages. If not specified, no messages will be written.

=back

=item RETURN

Returns a reference to a hash that maps each genome ID to the evaluation object created for it. Genomes files that were not
found will be ignored.

=back

=cut

sub CreateFromGtoFiles {
    my ($class, $files, %options) = @_;
    # This will be the return hash.
    my %retVal;
    # Get the log file.
    my $logH = $options{logH};
    # Get the stats object.
    my $stats = $options{stats} // Stats->new();
    # Process the options.
    my ($nMap, $cMap) = _RoleMaps($options{roleHashes}, $logH, $stats);
    my $p3 = $options{p3} // P3DataAPI->new();
    my $detail = $options{detail};
    # Loop through the GTO files.
    for my $file (@$files) {
        $stats->Add(genomesIn => 1);
        _log($logH, "Processing genome file $file.\n");
        my $gto = GenomeTypeObject->create_from_file($file);
        if (! $gto) {
            _log($logH, "No genome found in $file.\n");
        } else {
            $stats->Add(genomeFoundFile => 1);
            # Get the basic genome information.
            my $genome = $gto->{id};
            my $name = $gto->{scientific_name};
            my $domain = $gto->{domain};
            my $taxon = $gto->{ncbi_taxonomy_id};
            $retVal{$genome} = { id => $genome, name => $name, domain => $domain, nameMap => $nMap, checkMap => $cMap,
                taxon => $taxon };
            # Compute the aa-len limits for the seed protein.
            my ($min, $max) = (209, 405);
            if ($domain eq 'Archaea') {
                ($min, $max) = (293, 652);
            }
            my $seedCount = 0;
            my $goodSeed = 1;
            # Create the role tables.
            my (%roles, %proteins, %locs);
            _log($logH, "Processing features for $genome.\n");
            for my $feature (@{$gto->{features}}) {
                $stats->Add(featureFoundFile => 1);
                my $fid = $feature->{id};
                my $function = $feature->{function};
                # Only features with functions matter to us.
                if ($function) {
                    my @roles = SeedUtils::roles_of_function($function);
                    my $mapped = 0;
                    for my $role (@roles) {
                        my $checkSum = RoleParse::Checksum($role);
                        $stats->Add(roleFoundFile => 1);
                        my $rID = $cMap->{$checkSum};
                        if (! $rID) {
                            $stats->Add(roleNotMapped => 1);
                        } else {
                            $stats->Add(roleMapped => 1);
                            push @{$roles{$rID}}, $fid;
                            $mapped++;
                            if ($rID eq 'PhenTrnaSyntAlph') {
                                $seedCount++;
                                my $aaLen = length $feature->{protein_translation};
                                if ($aaLen < $min) {
                                    $stats->Add(seedTooShort => 1);
                                    $goodSeed = 0;
                                } elsif ($aaLen > $max) {
                                    $stats->Add(seedTooLong => 1);
                                    $goodSeed = 0;
                                }
                            }
                        }
                    }
                    if ($detail && $mapped) {
                        # If we are NOT abridged and this feature had an interesting role, we
                        # also need to save the location.
                        my $locs = $feature->{location};
                        my $region = shift @$locs;
                        my $loc = BasicLocation->new(@$region);
                        for $region (@$locs) {
                            $loc->Combine(BasicLocation->new(@$region));
                        }
                        $locs{$fid} = $loc;
                    }
                    if ($detail > 1) {
                        $proteins{$fid} = $feature->{protein_translation};
                    }
                }
            }
            # Store the role map.
            $retVal{$genome}{roleFids} = \%roles;
            # Compute the good-seed flag.
            if (! $seedCount) {
                $stats->Add(seedNotFound => 1);
                $goodSeed = 0;
            } elsif ($seedCount > 1) {
                $stats->Add(seedTooMany => 1);
                $goodSeed = 0;
            }
            $retVal{$genome}{good_seed} = $goodSeed;
            # Check for the optional stuff.
            if ($detail) {
                # Here we also need to store the location map.
                $retVal{$genome}{fidLocs} = \%locs;
                # Finally, we need the contig lengths.
                _log($logH, "Reading contigs for $genome.\n");
                my %contigs;
                for my $contig (@{$gto->{contigs}}) {
                    $stats->Add(contigFoundFile => 1);
                    my $contigID = $contig->{id};
                    my $len = length($contig->{dna});
                    $contigs{$contigID} = $len;
                }
                $retVal{$genome}{contigs} = \%contigs;
                $retVal{$genome}{proteins} = \%proteins;
            }
        }
    }
    # Run through all the objects, blessing them.
    for my $genome (keys %retVal) {
        bless $retVal{$genome}, $class;
    }
    # Return the hash of objects.
    return \%retVal;
}

# Good/Bad criteria
sub MIN_CHECKM { return 80; }
sub MIN_SCIKIT { return 87; }
sub MAX_CONTAM { return 10; }

=head3 completeX

    my $ok = GEO::completeX($pct);

Return TRUE if the specified percent complete is sufficient.

=over 4

=item pct

A percent completeness.

=item RETURN

Returns TRUE if the value is high enough, else FALSE.

=back

=cut

sub completeX {
    my ($pct) = @_;
    return ($pct >= MIN_CHECKM);
}

=head3 consistX

    my $ok = GEO::consistX($pct);

Return TRUE if the specified percent fine consistency is sufficient.

=over 4

=item pct

A percent fine consistency.

=item RETURN

Returns TRUE if the value is high enough, else FALSE.

=back

=cut

sub consistX {
    my ($pct) = @_;
    return ($pct >= MIN_SCIKIT);
}

=head3 contamX

    my $ok = GEO::contamX($pct);

Return TRUE if the specified percent contamination is acceptable.

=over 4

=item pct

A percent of genome contamination.

=item RETURN

Returns TRUE if the value is low enough, else FALSE.

=back

=cut

sub contamX {
    my ($pct) = @_;
    return ($pct <= MAX_CONTAM);
}

=head3 qscoreX

    my $score = GEO::qscoreX($coarse, $fine, $complete, $contam);

Return the overall quality score from the basic quality metrics-- coarse consistency, fine consistency, completeness, and contamination.

=over 4

=item coarse

The coarse consistency, in percent.

=item fine

The fine consistency, in percent.

=item complete

The percent completeness.

=item contam

The percent contamination.

=item RETURN

Returns a number from -500 to 209 indicating the relative quality of the genome.

=back

=cut

sub qscoreX {
    my ($coarse, $fine, $complete, $contam) = @_;
    my $retVal = $fine * 1.09 + $complete - 5 * $contam;
    return $retVal;
}

=head3 closest_protein

    my ($id, $score) = GEO::closest_protein($target, \%others, $k);

Use kmers to compute which of the specified other proteins is closest to the target. The ID of the closest protein will be returned, along with its score.

=over 4

=item target

The target protein.

=item others

Reference to a hash mapping IDs to protein sequences.

=item k

The proposed kmer size. The default is C<8>.

=item RETURN

Returns the ID of the closest protein and its kmer similarity score. An undefined ID will be returned if no similarity exists.

=back

=cut

sub closest_protein {
    my ($target, $others, $k) = @_;
    $k //= 8;
    # Create a kmer hash for the target.
    my %kHash;
    my $n = length($target) - $k;
    for (my $i = 0; $i <= $n; $i++) {
        $kHash{substr($target, $i, $k)} = 1;
    }
    # These will be the return values.
    my ($id, $score) = (undef, 0);
    # Test all the other sequences.
    for my $seqID (sort keys %$others) {
        my $sequence = $others->{$seqID};
        my $newScore = 0;
        my $n = length($sequence) - $k;
        for (my $i = 0; $i < $n; $i++) {
            if ($kHash{substr($sequence, $i, $k)}) {
                $newScore++;
            }
        }
        if ($newScore > $score) {
            $id = $seqID;
            $score = $newScore;
        }
    }
    return ($id, $score);
}

=head2 Query Methods

=head3 id

    my $genomeID = $geo->id;

Return the ID of this genome.

=cut

sub id {
    my ($self) = @_;
    return $self->{id};
}

=head3 lineage

    my $lineageL = $geo->lineage;

Return a reference to a list of the IDs in the taxonomic lineage, or C<undef> if the lineage is not available.

=cut

sub lineage {
    my ($self) = @_;
    return $self->{lineage};
}

=head3 roleCounts

    my $roleH = $geo->roleCounts;

Return a hash mapping each role ID to its number of occurrences.

=cut

sub roleCounts {
    my ($self) = @_;
    my $roleMap = $self->{roleFids};
    my %retVal = map { $_ => scalar(@{$roleMap->{$_}}) } keys %$roleMap;
    return \%retVal;
}

=head3 good_seed

    my $seedFlag = $geo->good_seed;

Return TRUE if this genome has a good seed protein, else FALSE.

=cut

sub good_seed {
    my ($self) = @_;
    return $self->{good_seed};
}

=head3 is_good

    my $goodFlag = $geo->is_good;

Return TRUE if this is a good genome, FALSE if it is not good or has not been evaluated.

=cut

sub is_good {
    my ($self) = @_;
    my $retVal = ($self->good_seed && $self->is_consistent && $self->is_complete && $self->is_clean);
    return $retVal;
}

=head3 taxon

    my $taxon = $geo->taxon;

Return the taxonomic ID for this genome.

=cut

sub taxon {
    my ($self) = @_;
    return $self->{taxon};
}

=head3 qscore

    my $score = $geo->qscore;

Return a measure of the quality of this genome. This only works if the quality data has been added by L</AddQuality>.

=cut

sub qscore {
    my ($self) = @_;
    my $retVal = 0;
    my $qHash = $self->{quality};
    if ($qHash) {
        $retVal = $qHash->{fine_consis} * 1.09 + $qHash->{complete} - 5 * $qHash->{contam};
    }
    return $retVal;
}

=head3 metrics

    my $metricsH = $geo->metrics;

Return the contig-length metrics hash from the quality member.

=cut

sub metrics {
    my ($self) = @_;
    return $self->{quality}{metrics};
}

=head3 name

    my $name = $geo->name;

Return the name of the genome.

=cut

sub name {
    my ($self) = @_;
    return $self->{name};
}

=head3 contigCount

    my $count = $geo->contigCount;

Return the number of contigs in the genome. If this object is abridged, it will return C<undef>.

=cut

sub contigCount {
    my ($self) = @_;
    my $retVal;
    my $contigs = $self->{contigs};
    if ($contigs) {
        $retVal = scalar keys %$contigs;
    }
    return $retVal;
}

=head3 refList

    my $refGeoList = $geo->refList;

Return a reference to a list of the reference genome L<GEO> objects. If there are none, an empty list will be returned.

=cut

sub refList {
    my ($self) = @_;
    my $retVal = $self->{refGeo} // [];
    return $retVal;
}

=head3 bestRef

    my $refGeo = $geo->bestRef

Return the best reference genome in the reference genome list (defined as having the closest ID number), or C<undef> if there are no reference genomes.

=cut

sub bestRef {
    my ($self) = @_;
    my $retVal;
    my $base = $self->{id};
    my $refsL = $self->{refGeo} // [];
    my @refs = @$refsL;
    if (scalar @refs) {
        $retVal = pop @refs;
        my $min = abs($base - $retVal->{id});
        for my $ref (@refs) {
            my $dist = abs($base - $ref->{id});
            if ($dist < $min) {
                $min = $dist;
                $retVal = $ref;
            }
        }
    }
    return $retVal;
}

=head3 protein

    my $aaSequence = $geo->protein($fid);

Return the protein sequence for the specified feature, or C<undef> if protein sequences are not available.

=over 4

=item fid

The feature ID of the desired protein.

=item RETURN

Returns the protein sequence for the specified feature, or C<undef> if the protein sequence is not available.

=back

=cut

sub protein {
    my ($self, $fid) = @_;
    return $self->{proteins}{$fid};
}


=head3 roleStats

    my ($over, $under, $predictable) = $geo->roleStats;

Return the number of roles over-represented, under-represented, and for which there are predictions. If no quality data is present, these will all be zero.

=cut

sub roleStats {
    my ($self) = @_;
    my @retVal;
    my $qData = $self->{quality};
    if ($qData) {
        @retVal = ($qData->{over_roles}, $qData->{under_roles}, $qData->{pred_roles});
    } else {
        @retVal = (0, 0, 0);
    }
    return @retVal;
}

=head3 roleReport

    my $roleHash = $geo->roleReport;

Return a hash of all the problematic roles. Each role ID will map to a 3-tuple-- (0) predicted occurrences, (1) actual occurrences, (2) HTML comment.

=cut

sub roleReport {
    my ($self) = @_;
    my $retVal = {};
    my $qData = $self->{quality};
    if ($qData) {
        $retVal = $qData->{roles};
    }
    return $retVal;
}

=head3 contigReport

    my $contigHash = $geo->contigReport;

Returns a hash of all the problematic contigs. Each contig ID will map to a count of good roles followed by a list of the bad ones.

=cut

sub contigReport {
    my ($self) = @_;
    my $retVal = {};
    my $qData = $self->{quality};
    if ($qData) {
        $retVal = $qData->{contigs};
    }
    return $retVal;
}

=head3 contigLen

    my $len = $geo->contigLen($contigID);

Return the length of the specified contig (if known).

=over 4

=item contigID

The ID of a contig in this genome.

=item RETURN

Returns the length of the contig in base pairs, or C<0> if the contig is not found or no contig data is present.

=back

=cut

sub contigLen {
    my ($self, $contigID) = @_;
    my $contigH = $self->{contigs};
    my $retVal = 0;
    if ($contigH) {
        $retVal = $contigH->{$contigID} // 0;
    }
    return $retVal;
}

=head3 roleFids

    my $fidList = $geo->roleFids($role);

Return all the roles for the specified role ID, or an empty list if there are none.

=over 4

=item role

The ID of the role whose feature list is desired.

=item RETURN

Returns a reference to a list of the IDs for the features that implement the role.

=back

=cut

sub roleFids {
    my ($self, $role) = @_;
    my $retVal = $self->{roleFids}{$role} // [];
    return $retVal;
}

=head3 is_consistent

    my $goodFlag = $self->is_consistent;

Return TRUE if this genome's annotations are sufficiently consistent. If the quality data is not present, it will automatically return FALSE.

=cut

sub is_consistent {
    my ($self) = @_;
    my $retVal = 0;
    my $qData = $self->{quality};
    if ($qData) {
        $retVal = consistX($qData->{fine_consis});
    }
    return $retVal;
}

=head3 is_complete

    my $goodFlag = $self->is_complete;

Return TRUE if this genome is sufficiently complete. If the quality data is not present, it will automatically return FALSE.

=cut

sub is_complete {
    my ($self) = @_;
    my $retVal = 0;
    my $qData = $self->{quality};
    if ($qData) {
        $retVal = completeX($qData->{complete});
    }
    return $retVal;
}

=head3 is_clean

    my $goodFlag = $self->is_clean;

Return TRUE if this genome is sufficiently free of contamination. If the quality data is not present, it will automatically return FALSE.

=cut

sub is_clean {
    my ($self) = @_;
    my $retVal = 0;
    my $qData = $self->{quality};
    if ($qData) {
        $retVal = contamX($qData->{contam});
    }
    return $retVal;
}


=head3 scores

    my ($coarse, $fine, $complete, $contam, $group) = $gto->scores;

Return the quality scores for this genome in the form of a list.

=cut

sub scores {
    my ($self) = @_;
    my $qData = $self->{quality};
    my @retVal;
    if (! $qData) {
        @retVal = (0, 0, 0, 100, '');
    } else {
        @retVal = ($qData->{coarse_consis}, $qData->{fine_consis}, $qData->{complete}, $qData->{contam}, $qData->{taxon});
    }
    return @retVal;
}


=head2 Public Manipulation Methods

=head3 AddRefGenome

    $geo->AddRefGenome($geo2);

Store the GEO of a reference genome.

=over 4

=item geo2

The GEO of a close genome of higher quality.

=back

=cut

sub AddRefGenome {
    my ($self, $geo2) = @_;
    push @{$self->{refGeo}}, $geo2;
}


=head3 AddQuality

    $geo->AddQuality($summaryFile);

Add the quality information for this genome to this object, using the data in the specified summary file.
This method fills in the C<quality> member described above.

=over 4

=item summaryFile

The name of the genome summary file produced by L<p3-eval-genomes.pl> for this genome. This contains the role
information and the quality metrics.

=back

=cut

# Commands for processing the summary file headings.
use constant HEADINGS => { 'Fine Consistency' => ['fine_consis', ''],
                           'Coarse Consistency' => ['coarse_consis', ''],
                           'Group' => ['taxon', 'Universal role.'],
                           'Completeness' => ['complete', 'Universal role.'],
                           'Contamination' => ['contam', 'Universal role.']
};

# Maximum length for a short feature.
use constant SHORT_FEATURE => 180;

# Margin at the end of each contig.
use constant CONTIG_EDGE => 5;

sub AddQuality {
    my ($self, $summaryFile) = @_;
    # This will be the quality member.
    my %quality;
    $self->{quality} = \%quality;
    # Get the reference genomes (if any).
    my $refGeoL = $self->{refGeo} // [];
    my $refGeoCount = scalar @$refGeoL;
    # This will be the role prediction hash.
    my %roles;
    $quality{roles} = \%roles;
    # Compute the metrics based on the contig lengths.
    my $contigH = $self->{contigs};
    my @contigLengths = values %$contigH;
    $quality{metrics} = SeedUtils::compute_metrics(\@contigLengths);
    # Now it is time to read the quality file. The following hashes
    # will track over-represented and under-represented roles.
    my (%over, %under, %pred, %good);
    open(my $ih, "<$summaryFile") || die "Could not open quality output file $summaryFile: $!";
    my $comment = '';
    while (! eof $ih) {
        my $line = <$ih>;
        if ($line =~ /^([^\t]+):\s+(.+)/) {
            # Find out what we are supposed to do with this keyword.
            my ($label, $value) = ($1, $2);
            my $command = HEADINGS->{$label};
            if ($command) {
                $quality{$command->[0]} = $value;
                $comment = $command->[1];
            }
        } elsif ($line =~ /^(\S+)\t(\d+)\t(\d+)/) {
            # Here we have a role prediction.
            my ($role, $predicted, $actual) = ($1, $2, $3);
            $pred{$role} = 1;
            if ($predicted != $actual) {
                $roles{$role} = [$predicted, $actual, $comment];
                if ($predicted > $actual) {
                    $over{$role} = 1;
                } elsif ($predicted < $actual) {
                    $under{$role} = 1;
                }
            }
            # The role is good if it is present and is predicted to occur
            # equal or more times. This is a very conservative measure, so
            # it will miss necessary roles.
            if ($predicted >= 1 && $actual >= 1 && $actual <= $predicted) {
                $good{$role} = 1;
            }
        }
    }
    # Compute the over and under numbers.
    $quality{over_roles} = scalar keys %over;
    $quality{under_roles} = scalar keys %under;
    $quality{pred_roles} = scalar keys %pred;
    # Get the role features hash and the feature-locations hash.
    my $roleFids = $self->{roleFids};
    my $fidLocs = $self->{fidLocs};
    # Now compute the number of good roles in each contig.
    my %contigs;
    $quality{contigs} = \%contigs;
    for my $role (keys %good) {
        my $fids = $roleFids->{$role};
        for my $fid (@$fids) {
            my $contig = $fidLocs->{$fid}->Contig;
            $contigs{$contig}[0]++;
        }
    }
    # Memorize the contigs with no good roles and the contigs shorter than
    # the N70.
    my $shortContig = $quality{metrics}{N70};
    my %badContigs;
    for my $contig (keys %$contigH) {
        my $connect = 0;
        if (! $contigs{$contig}) {
            $badContigs{$contig} = 'has no good roles';
            $contigs{$contig} = [0];
            $connect = 1;
        }
        if ($contigH->{$contig} < $shortContig) {
            if ($connect) {
                $badContigs{$contig} .= ' and is short';
            } else {
                $badContigs{$contig} = 'is short';
            }
        }
    }
    # Now we must analyze the features for each problematic role and update the
    # comments.
    for my $role (keys %roles) {
        my ($predicted, $actual, $comment) = @{$roles{$role}};
        # Set up to accumulate comments about the role in here.
        my @roleComments;
        if ($comment) { push @roleComments, $comment; }
        # If there are existing features for the role, we make comments on each one.
        if ($actual >= 1) {
            # We will accumulate proteins in here.
            my %proteins;
            # Process the list of features found.
            my $fids = $roleFids->{$role};
            for my $fid (@$fids) {
                # We will accumulate our comments for each feature in here.
                my @comments;
                # Analyze the location.
                my $loc = $fidLocs->{$fid};
                my $len = $loc->Length;
                if ($len <= SHORT_FEATURE) {
                    push @comments, "is only $len bases long";
                }
                # Form its relationship to the contig.
                my $contigID = $loc->Contig;
                my $contigLen = $contigH->{$contigID};
                my $strand = $loc->Dir;
                my ($left, $right) = ($loc->Left < CONTIG_EDGE,
                                      $loc->Right > $contigLen - CONTIG_EDGE);
                my $position;
                if ($left && $right) {
                    $position = 'fills contig ';
                } elsif ($left && $strand eq '+' || $right && $strand eq '-') {
                    $position = 'starts near the edge of contig ';
                } elsif ($left || $right) {
                    $position = 'ends near the edge of contig ';
                } else {
                    $position = 'is in contig ';
                }
                # Form the contig link.
                $position .= _contig_link($contigID);
                # Add a qualifier.
                if ($badContigs{$contigID}) {
                    $position .= ", which $badContigs{$contigID}";
                }
                push @comments, $position;
                # Now build the feature comment. There will be at least one, but may
                # be more.
                my $fcomment = _cr_link($fid) . ' ' . _format_comments(@comments);
                push @roleComments, $fcomment;
                # If this feature has a protein, save it.
                my $prot = $self->protein($fid);
                $proteins{$fid} = $prot;
                # Finally, we must record this feature as a bad feature for the contig.
                push @{$contigs{$contigID}}, $fid;
            }
            # Now, if we have too many of the feature and we have proteins, we can ask which feature
            # is the best.
            if ($actual > $predicted && $predicted >= 1 && scalar(keys %proteins) > 1) {
                # Check for this role in each reference genome.
                for my $refGeo (@$refGeoL) {
                    my $rFids = $refGeo->{roleFids}{$role};
                    # Loop through the reference genome features.
                    for my $rFid (@$rFids) {
                        my $rProtein = $refGeo->protein($rFid);
                        if ($rProtein) {
                            my ($bestFid, $score) = closest_protein($rProtein, \%proteins);
                            if ($bestFid) {
                                push @roleComments, _fid_link($rFid) . " performs this role in the reference genome, and " .
                                    _cr_link($bestFid) . " is the closest to it, with $score matching kmers.";
                            }
                        }
                    }
                }
            }
        } elsif ($refGeoCount) {
            # The role is missing, but we have a reference genome. Get its instances
            # of the same role.
            my %rProteins;
            for my $refGeo (@$refGeoL) {
                my $fids = $refGeo->{roleFids}{$role};
                if ($fids) {
                    for my $rFid (@$fids) {
                        my $rProtein = $refGeo->protein($rFid);
                        $rProteins{$rFid} = $rProtein;
                    }
                }
            }
            my $genomeWord = ($refGeoCount == 1 ? 'genome' : 'genomes');
            my $fidCount = scalar keys %rProteins;
            if (! $fidCount) {
                push @roleComments, "Role is not present in the reference $genomeWord.";
            } else {
                my $verb = ($fidCount == 1 ? 'performs' : 'perform');
                push @roleComments, _fid_link(sort keys %rProteins) . " $verb this role in the reference $genomeWord.";
                # Get the protein hash for this genome.
                my $ourProteins = $self->{proteins};
                # Find the closest feature for each reference genome protein.
                for my $rFid (sort keys %rProteins) {
                    my $rProtein = $rProteins{$rFid};
                    if ($rProtein) {
                        my ($fid, $score) = closest_protein($rProtein, $ourProteins);
                        if ($fid) {
                            push @roleComments, _cr_link($fid) . " is the closest protein to the reference feature " . _fid_link($rFid) . " with $score kmers in common.";
                        }
                    }
                }
            }
        }
        # Form all the comments for this role.
        $roles{$role}[2] = join('<br />', @roleComments);
    }
}

=head2 Internal Methods

=head3 _format_comments

    my $sentence = _format_comments(@phrases).

Join the phrases together to form a sentence using commas and a conjunction.

=over 4

=item phrases

Zero or more phrases to be joined into a conjunction.

=item RETURN

Returns a string formed from the phrases using commas and a conjunction.

=back

=cut

sub _format_comments {
    my (@phrases) = @_;
    my $retVal = '';
    if (scalar(@phrases) == 1) {
        $retVal = $phrases[0];
    } elsif (scalar(@phrases) == 2) {
        $retVal = join(" and ", @phrases);
    } else {
        my @work = @phrases;
        my $last = pop @work;
        $last = "and $last";
        $retVal = join(", ", @work, $last);
    }
    return $retVal;
}

=head3 _contig_link

    my $html = GTO::_contig_link($contigID);

Return the PATRIC URL and label for the specified contig.

=over 4

=item contigID

The ID of the sequence of interest.

=item RETURN

Returns a hyperlink displaying the contig ID. When clicked, it will show all the proteins in the contig.

=back

=cut

sub _contig_link {
    my ($contigID) = @_;
    my $retVal = qq(<a href ="https://www.patricbrc.org/view/FeatureList/?and(eq(annotation,PATRIC),eq(sequence_id,$contigID),eq(feature_type,CDS))" target="_blank">$contigID</a>);
    return $retVal;
}

=head3 _cr_link

    my $html = GEO::_cr_link($fid);

Produce a labeled hyperlink to a feature's compare regions page.

=over 4

=item fid

The ID of the relevant feature.

=item RETURN

Returns a hyperlink to the feature's compare regions page with the text containing the feature
ID.

=back

=cut

sub _cr_link {
    my ($fid) = @_;
    my $fidInLink = uri_escape($fid);
    my $retVal = qq(<a href="https://www.patricbrc.org/view/Feature/$fidInLink#view_tab=compareRegionViewer" target="_blank">$fid</a>);
    return $retVal;
}

=head3 _fid_link

    my $html = GEO::_fid_link(@fids);

Return a hyperlink for viewing a list of PATRIC features or a single feature.

=over 4

=item fids

A list of feature IDs.

=item RETURN

Returns a hyperlink for viewing a single feature or a list of multiple features.

=back

=cut

sub _fid_link {
    my (@fids) = @_;
    my $retVal;
    if (@fids == 1) {
        my $fid = $fids[0];
        my $fidInLink = uri_escape($fid);
        $retVal = qq(<a href="https://www.patricbrc.org/view/Feature/$fidInLink" target="_blank">$fid</a>);
    } elsif (@fids > 1) {
        my $list = join(",", map { uri_escape(qq("$_")) } @fids);
        my $link = "https://www.patricbrc.org/view/FeatureList/?in(patric_id,($list))";
        my $count = scalar @fids;
        $retVal = qq(<a href="$link" target="_blank">$count features</a>);
    } else {
        $retVal = "0 features";
    }
    return $retVal;
}

=head3 _log

    GEO::_log($lh, $msg);

Write a log message if we have a log file.

=over 4

=item lh

Open file handle for the log, or C<undef> if there is no log.

=item msg

Message to write to the log.

=back

=cut

sub _log {
    my ($lh, $msg) = @_;
    if ($lh) {
        print $lh $msg;
    }
}

=head3 _RoleMaps

    my ($nMap, $cMap) = _RoleMaps($roleHashes, $logH, $stats);

Compute the role ID/name maps. These are either taken from the incoming parameter or they are read from the global
C<roles.in.subsystems> file.

=over 4

=item roleHashes

Either a 2-tuple containing (0) the name map and (1) the checksum map, or C<undef>, indicating the maps should be read
from the global role file.

=item logH

Optional open file handle for logging.

=item stats

A L<Stats> object for tracking statistics.

=back

=cut

sub _RoleMaps {
    my ($roleHashes, $logH, $stats) = @_;
    # These will be the return values.
    my ($nMap, $cMap);
    # Do we have role hashes from the client?
    if ($roleHashes) {
        # Yes. Use them.
        $nMap = $roleHashes->[0];
        $cMap = $roleHashes->[1];
    } else {
        # No. Read from the roles.in.subsystems file.
        $nMap = {}; $cMap = {};
        my $roleFile = "$FIG_Config::global/roles.in.subsystems";
        _log($logH, "Reading roles from $roleFile.\n");
        open(my $rh, '<', $roleFile) || die "Could not open roles.in.subsytems: $!";
        while (! eof $rh) {
            if (<$rh> =~ /^(\S+)\t(\S+)\t(.+)/) {
                $nMap->{$1} = $3;
                $cMap->{$2} = $1;
                $stats->Add(mappableRoleRead => 1);
            }
        }
    }
    return ($nMap, $cMap);
}


1;
