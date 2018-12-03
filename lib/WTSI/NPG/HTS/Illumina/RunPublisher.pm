package WTSI::NPG::HTS::Illumina::RunPublisher;

use namespace::autoclean;
use Data::Dump qw[pp];
use File::Basename;
use File::Slurp;
use File::Find;
use File::Spec::Functions qw[catdir catfile abs2rel splitdir];
use JSON;
use Moose;
use MooseX::StrictConstructor;
use Try::Tiny;

use WTSI::DNAP::Utilities::Params qw[function_params];
use WTSI::NPG::HTS::BatchPublisher;
use WTSI::NPG::HTS::Illumina::DataObjectFactory;
use WTSI::NPG::HTS::Illumina::ResultSet;
use WTSI::NPG::HTS::Seqchksum;
use WTSI::NPG::HTS::Types qw[AlnFormat];
use WTSI::NPG::iRODS::Metadata;

use npg_tracking::glossary::composition;
use npg_tracking::glossary::moniker;

with qw[
         WTSI::DNAP::Utilities::Loggable
         WTSI::NPG::HTS::Illumina::Annotator
         WTSI::NPG::HTS::Illumina::CompositionFileParser
         WTSI::NPG::HTS::RunPublisher
       ];

our $VERSION = '';

our $DEFAULT_ROOT_COLL    = '/seq';
our $DEFAULT_QC_COLL      = 'qc';

our $NUM_READS_JSON_PROPERTY = 'num_total_reads';

has 'id_run' =>
  (isa           => 'NpgTrackingRunId',
   is            => 'ro',
   required      => 0, # unlike npg_tracking::glossary::run
   predicate     => 'has_id_run',
   documentation => 'The run identifier');

has 'lims_factory' =>
  (is            => 'ro',
   isa           => 'WTSI::NPG::HTS::LIMSFactory',
   required      => 1,
   documentation => 'A factory providing st:api::lims objects');

has 'restart_file' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 1,
   lazy          => 1,
   builder       => '_build_restart_file',
   documentation => 'A file containing a record of files successfully ' .
                    'published');

has 'file_format' =>
  (isa           => AlnFormat,
   is            => 'ro',
   required      => 1,
   lazy          => 1,
   default       => 'cram',
   documentation => 'The format of the file to be published');

has 'run_files' =>
  (isa           => 'ArrayRef[Str]',
   is            => 'ro',
   required      => 1,
   builder       => '_build_run_files',
   lazy          => 1,
   documentation => 'All of the files in the dataset, some or all of which ' .
                    'will be published');

has 'alt_process' =>
  (isa           => 'Maybe[Str]',
   is            => 'ro',
   required      => 0,
   documentation => 'Non-standard process used');

has 'force' =>
  (isa           => 'Bool',
   is            => 'ro',
   required      => 0,
   default       => 0,
   documentation => 'Force re-publication of files that have been published');

has 'max_errors' =>
  (isa       => 'Int',
   is        => 'ro',
   required  => 0,
   predicate => 'has_max_errors',
   documentation => 'The maximum number of errors permitted before ' .
                    'the remainder of a publishing process is aborted');

has 'result_set' =>
  (isa           => 'WTSI::NPG::HTS::Illumina::ResultSet',
   is            => 'ro',
   required      => 1,
   builder       => '_build_result_set',
   lazy          => 1,
   documentation => 'The set of results files in the run');

=head2 publish_collection

  Arg [1]    : None

  Example    : $pub->publish_collection
  Description: Return the collection to which files will be published.
               Its value is the dest_collection, unless another option
               overrides this behaviour e.g. setting alt_process.
  Returntype : Str

=cut

sub publish_collection {
  my ($self) = @_;

  my @colls = ($self->dest_collection);
  if (defined $self->alt_process) {
    push @colls, $self->alt_process
  }

  my $coll = catdir(@colls);
  $self->debug("Publish collection is '$coll'");

  return $coll;
}

=head2 publish_files

  Arg [1]    : None

  Named args : with_spiked_control, Bool. Optional

  Example    : my ($num_files, $num_published, $num_errors) =
                 $pub->publish_files
  Description: Publish all files for all detected composition files to iRODS.
               Return the number of files, the number published and the
               number of errors.
  Returntype : Array[Int]

=cut

{
  my $positional = 1;
  my @named      = qw[with_spiked_control];
  my $params     = function_params($positional, @named);

  sub publish_files {
    my ($self) = $params->parse(@_);

    my ($num_files, $num_processed, $num_errors) = (0, 0, 0);

    my $call = sub {
      my ($fn, $name) = @_;
      try {
        my ($nf, $np, $ne) = $fn->();

        if ($ne > 0 and $name) {
          $self->error("Encountered $ne errors publishing $nf files for $name");
        }

        $num_files     += $nf;
        $num_processed += $np;
        $num_errors    += $ne;
      } catch {
        $num_errors++;
      };
    };

    # Publish any "run-level" data found under the source directory
    $call->(sub { $self->publish_xml_files });
    $call->(sub { $self->publish_interop_files });

    # Publish any "product-level" data found under the source directory
    my @cfiles = $self->result_set->composition_files;
    $self->debug('Found Illumina composition files: ', pp(\@cfiles));

    my $spk = $params->with_spiked_control;
    foreach my $cfile (@cfiles) {
      $call->(sub { $self->publish_alignment_files($cfile, $spk) }, $cfile);
      $call->(sub { $self->publish_index_files($cfile, $spk)     }, $cfile);
      $call->(sub { $self->publish_ancillary_files($cfile, $spk) }, $cfile);
      $call->(sub { $self->publish_genotype_files($cfile, $spk)  }, $cfile);
      $call->(sub { $self->publish_qc_files($cfile, $spk)        }, $cfile);
    }

    return ($num_files, $num_processed, $num_errors);
  }
}

=head2 publish_interop_files

  Arg [1]    : None

  Example    : $pub->publish_interop_files
  Description: Publish run-level InterOp files to iRODS. Return the number of
               files, the number published and the number of errors.
  Returntype : Array[Int]

=cut

sub publish_interop_files {
  my ($self) = @_;

  my $primary_avus = sub {
    my @avus;
    push @avus, $self->make_avu($ID_RUN, $self->id_run);
    #push @avus, $self->make_avu($TARGET, 0);

    #if ($self->alt_process) {
    #  push @avus, $self->make_avu($ALT_PROCESS, $self->alt_process);
    #}

    return @avus;
  };

  my @files = $self->result_set->interop_files;
  $self->debug('Publishing interop files: ', pp(\@files));

  return $self->_publish_run_level_data(\@files, $self->dest_collection,
                                        $primary_avus);
}

=head2 publish_xml_files

  Arg [1]    : None

  Example    : $pub->publish_xml_files
  Description: Publish run-level XML files to iRODS. Return the number of
               files, the number published and the number of errors.
  Returntype : Array[Int]

=cut

sub publish_xml_files {
  my ($self) = @_;

  my $primary_avus = sub {
    my @avus;
    push @avus, $self->make_avu($ID_RUN, $self->id_run);
    #push @avus, $self->make_avu($TARGET, 0);

    #if ($self->alt_process) {
    #  push @avus, $self->make_avu($ALT_PROCESS, $self->alt_process);
    #}

    return @avus;
  };

  my @files = $self->result_set->xml_files;
  $self->debug('Publishing XML files: ', pp(\@files));

  return $self->_publish_run_level_data(\@files, $self->dest_collection,
                                        $primary_avus);
}

=head2 publish_alignment_files

  Arg [1]    : composition file, Str.
  Arg [2]    : with_spiked_control, Bool. Optional.

  Example    : my ($num_files, $num_published, $num_errors) =
                 $pub->publish_alignment_files
  Description: Publish alignment files corresponding to the given
               composition file to iRODS. Return the number of files,
               the number published and the number of errors.
  Returntype : Array[Int]

=cut

sub publish_alignment_files {
  my ($self, $composition_file, $with_spiked_control) = @_;

  my ($name, $directory, $suffix) =
    $self->parse_composition_filename($composition_file);

  my $num_reads        = $self->_find_num_reads($name);
  my $seqchksum_digest = $self->_find_seqchksum_digest($name);

  my $primary_avus = sub {
    my ($obj) = @_;
    return $self->make_primary_metadata
      ($obj->composition,
       alt_process      => $self->alt_process,
       is_aligned       => $obj->is_aligned,
       is_paired_read   => $obj->is_paired_read,
       num_reads        => $num_reads,
       reference        => $obj->reference,
       seqchksum        => $seqchksum_digest);
  };

  my $secondary_avus = sub {
    my ($obj) = @_;
    return $self->make_secondary_metadata
      ($obj->composition, $self->lims_factory,
       with_spiked_control => $with_spiked_control);
  };

  my $format = $self->file_format;
  my @files = grep { m{[.]$format$}msx }
    $self->result_set->alignment_files($name);
  $self->debug("Publishing alignment files for $name: ", pp(\@files));

  # Configure archiving to a custom sub-collection here
  my $collection = $self->publish_collection;
  return $self->_publish_product_level_data(\@files, $collection,
                                            $composition_file,
                                            $primary_avus, $secondary_avus);
}

=head2 publish_alignment_files

  Arg [1]    : composition file, Str.
  Arg [2]    : with_spiked_control, Bool. Optional.

  Example    : my ($num_files, $num_published, $num_errors) =
                 $pub->publish_index_files
  Description: Publish alignment index files corresponding to the given
               composition file to iRODS. Return the number of files,
               the number published and the number of errors.
  Returntype : Array[Int]

=cut

sub publish_index_files {
  my ($self, $composition_file, $with_spiked_control) = @_;

  my ($name, $directory, $suffix) =
    $self->parse_composition_filename($composition_file);

  my $num_reads = $self->_find_num_reads($name);
  if ($num_reads == 0) {
    $self->debug("Skipping index files for $name: no reads");
    return (0, 0, 0);
  }

  my $primary_avus = sub {
    my ($obj) = @_;
    return $self->make_primary_metadata
      ($obj->composition, alt_process => $self->alt_process);
  };

  my $secondary_avus = sub {
    my ($obj) = @_;
    return $self->make_secondary_metadata
      ($obj->composition, $self->lims_factory,
       with_spiked_control => $with_spiked_control);
  };

  my @files = $self->result_set->index_files($name);
  $self->debug("Publishing index files for $name: ", pp(\@files));

  # Configure archiving to a custom sub-collection here
  my $collection = $self->publish_collection;
  return $self->_publish_product_level_data(\@files, $collection,
                                            $composition_file,
                                            $primary_avus, $secondary_avus);
}

=head2 publish_ancillary_files

  Arg [1]    : composition file, Str.
  Arg [2]    : with_spiked_control, Bool. Optional.

  Example    : my ($num_files, $num_published, $num_errors) =
                 $pub->publish_index_files
  Description: Publish ancillary files corresponding to the given
               composition file to iRODS. Return the number of files,
               the number published and the number of errors.
  Returntype : Array[Int]

=cut

sub publish_ancillary_files {
  my ($self, $composition_file, $with_spiked_control) = @_;

  my ($name, $directory, $suffix) =
    $self->parse_composition_filename($composition_file);

  my $primary_avus = sub {
    my ($obj) = @_;
    return $self->make_primary_metadata
      ($obj->composition, alt_process => $self->alt_process);
  };

  my $secondary_avus = sub {
    my ($obj) = @_;
    return $self->make_secondary_metadata
      ($obj->composition, $self->lims_factory,
       with_spiked_control => $with_spiked_control);
  };

  my @files = $self->result_set->ancillary_files($name);
  $self->debug("Publishing ancillary files for $name: ", pp(\@files));

  # Configure archiving to a custom sub-collection here
  my $collection = $self->publish_collection;
  return $self->_publish_product_level_data(\@files, $collection,
                                            $composition_file,
                                            $primary_avus, $secondary_avus);
}

=head2 publish_genotype_files

  Arg [1]    : composition file, Str.
  Arg [2]    : with_spiked_control, Bool. Optional.

  Example    : my ($num_files, $num_published, $num_errors) =
                 $pub->publish_genotype_files
  Description: Publish genotype files corresponding to the given
               composition file to iRODS. Return the number of files,
               the number published and the number of errors.
  Returntype : Array[Int]

=cut

sub publish_genotype_files {
  my ($self, $composition_file, $with_spiked_control) = @_;

  my ($name, $directory, $suffix) =
    $self->parse_composition_filename($composition_file);

  my $primary_avus = sub {
    my ($obj) = @_;
    return $self->make_primary_metadata
      ($obj->composition, alt_process => $self->alt_process);
  };

  my $secondary_avus = sub {
    my ($obj) = @_;
    return $self->make_secondary_metadata
      ($obj->composition, $self->lims_factory,
       with_spiked_control => $with_spiked_control);
  };

  my @files = $self->result_set->genotype_files($name);
  $self->debug("Publishing genotype files for $name: ", pp(\@files));

  # Configure archiving to a custom sub-collection here
  my $collection = $self->publish_collection;
  return $self->_publish_product_level_data(\@files, $collection,
                                            $composition_file,
                                            $primary_avus, $secondary_avus);
}

=head2 publish_qc_files

  Arg [1]    : composition file, Str.
  Arg [2]    : with_spiked_control, Bool. Optional.

  Example    : my ($num_files, $num_published, $num_errors) =
                 $pub->publish_qc_files
  Description: Publish QC files corresponding to the given
               composition file to iRODS. Return the number of files,
               the number published and the number of errors.
  Returntype : Array[Int]

=cut

sub publish_qc_files {
  my ($self, $composition_file, $with_spiked_control) = @_;

  my ($name, $directory, $suffix) =
    $self->parse_composition_filename($composition_file);

  my $primary_avus = sub {
    my ($obj) = @_;
    return $self->make_primary_metadata
      ($obj->composition, alt_process => $self->alt_process);
  };

  my $secondary_avus = sub {
    my ($obj) = @_;
    $self->make_secondary_metadata
      ($obj->composition, $self->lims_factory,
       with_spiked_control => $with_spiked_control);
  };

  my @files = $self->result_set->qc_files($name);
  $self->debug("Publishing QC files for $name: ", pp(\@files));

  # Configure archiving to a custom sub-collection here
  my $collection = catdir($self->publish_collection, $DEFAULT_QC_COLL);
  return $self->_publish_product_level_data(\@files, $collection,
                                            $composition_file,
                                            $primary_avus, $secondary_avus);
}

sub write_restart_file {
  my ($self) = @_;

  $self->batch_publisher->write_state;
  return;
}

sub _publish_run_level_data {
  my ($self, $data_files, $collection,
      $primary_avus_callback, $secondary_avus_callback) = @_;

  $secondary_avus_callback ||= sub { return () };

  my $obj_factory = WTSI::NPG::HTS::Illumina::DataObjectFactory->new
    (ancillary_formats => [$self->hts_ancillary_suffixes],
     genotype_formats  => [$self->hts_genotype_suffixes],
     compress_formats  => [$self->compress_suffixes],
     irods             => $self->irods);

  my $batch_publisher = $self->_make_batch_publisher($obj_factory);
  $self->debug("Publishing run level collection: $collection: ",
               pp($data_files));

  return $batch_publisher->publish_file_batch
    ($data_files, $collection, $primary_avus_callback,
     $secondary_avus_callback);
}

# Publish product level things like alignments and QC
## no critic (Subroutines::ProhibitManyArgs)
sub _publish_product_level_data {
  my ($self, $data_files, $collection, $composition_file,
      $primary_avus_callback, $secondary_avus_callback) = @_;

  $composition_file or
    $self->logconfess('A non-empty composition_file argument is required');
  $secondary_avus_callback ||= sub { return () };

  my $composition = $self->read_composition_file($composition_file);

  my $obj_factory = WTSI::NPG::HTS::Illumina::DataObjectFactory->new
    (composition       => $composition,
     ancillary_formats => [$self->hts_ancillary_suffixes],
     genotype_formats  => [$self->hts_genotype_suffixes],
     compress_formats  => [$self->compress_suffixes],
     irods             => $self->irods);

  my $batch_publisher = $self->_make_batch_publisher($obj_factory);
  $self->debug("Publishing product level collection: $collection, ",
               'composition: ', $composition->freeze2rpt,
               ' :', pp($data_files));

  return $batch_publisher->publish_file_batch
    ($data_files, $collection, $primary_avus_callback,
     $secondary_avus_callback);
}
## use critic

sub _make_batch_publisher {
  my ($self, $obj_factory) = @_;
  my @init_args = (obj_factory => $obj_factory,
                   force       => $self->force,
                   irods       => $self->irods,
                   state_file  => $self->restart_file);
  if ($self->has_max_errors) {
    push @init_args, max_errors  => $self->max_errors;
  }

  return WTSI::NPG::HTS::BatchPublisher->new(@init_args);
}

sub _find_num_reads {
  my ($self, $name) = @_;

  my $file = npg_tracking::glossary::moniker->file_name_full
    ($name, ext => 'bam_flagstats.json');

  my $path = $self->_match_single_file(qr{\Q/$file\E$}msx,
                                       $self->run_files);

  $self->debug("Finding num_reads for '$name' in '$path'");

  my $json = read_file($path, binmode => ':utf8');
  if (not $json) {
    $self->logcroak("Invalid stats file '$path': file is empty");
  }

  my $num_reads;
  try {
    my $stats = decode_json($json);
    $num_reads = $stats->{$NUM_READS_JSON_PROPERTY};
  } catch {
    $self->logcroak('Failed to a parse JSON value from ',
                    "stats file '$path': ", $_);
  };

  return $num_reads;
}

sub _find_seqchksum_digest {
  my ($self, $name) = @_;

  my $file = npg_tracking::glossary::moniker->file_name_full
    ($name, ext => 'seqchksum');

  my $path = $self->_match_single_file(qr{\Q/$file\E$}msx,
                                       $self->run_files);

  $self->debug("Finding seqchksum for '$name' in '$path'");

  my $seqchksum = WTSI::NPG::HTS::Seqchksum->new(file_name => $path);
  my @rg = $seqchksum->read_groups;
  my $num_rg = scalar @rg;
  if ($num_rg == 0) {
    $self->logcroak("Failed to find any read groups in '$path'");
  }

  $self->debug("Creating seqchksum digest from '$path' for $num_rg ",
               'read groups: ', pp(\@rg));

  return $seqchksum->digest($seqchksum->all_group);
}

sub _build_dest_collection  {
  my ($self) = @_;

  my @colls = ($DEFAULT_ROOT_COLL, $self->id_run);

  return catdir(@colls);
}

sub _build_restart_file {
  my ($self) = @_;

  return catfile($self->source_directory, 'published.json');
}

sub _build_run_files {
  my ($self) = @_;

  my $dir = $self->source_directory;
  $self->info("Finding files under '$dir', recursively");

  my @files = grep { -f } $self->list_directory($dir, recurse => 1);

  return \@files;
}

sub _build_result_set {
  my ($self) = @_;

  return WTSI::NPG::HTS::Illumina::ResultSet->new
    (result_files => $self->run_files)
}

sub _match_single_file {
  my ($self, $pattern, $files) = @_;

  my @files = grep { m{$pattern}msx } @{$files};
  my $num_files = scalar @files;

  if ($num_files != 1) {
    $self->logcroak("Found $num_files matching '$pattern' ",
                    'where one was expected: ', pp(\@files));
  }

  return shift @files;
}

__PACKAGE__->meta->make_immutable;

no Moose;

1;

__END__

=head1 NAME

WTSI::NPG::HTS::Illumina::RunPublisher

=head1 DESCRIPTION

Publishes alignment, QC and ancillary files to iRODS, adds metadata and
sets permissions.

An instance of RunPublisher is responsible for copying Illumina
sequencing data from the instrument run folder to a collection in
iRODS for one or more data products, each of which is identified by a
JSON "composition" file describing the sample(s) within.

Files releated to a product are referred to in the API by their
product "name", which is the same as the string used as a prefix when
naming composition JSON files. i.e.

 <name>.composition.json

All files that are part of a product must share this name prefix.

Data files are divided into categories:

 - XML files; run metadata produced by the instrument.
 - InterOp files; run data produced by the instrument.
 - alignment files; the sequencing reads in BAM or CRAM format.
 - alignment index files; indices in the relevant format
 - ancillary files; files containing information about the run
 - genotype files; files with genotype calls from sequenced reads.
 - QC JSON files; JSON files containing information about the run.

A RunPublisher provides methods to list the files in these categories
and to copy ("publish") them.

As part of the copying process, metadata are added to, or updated on,
the files in iRODS. Following the metadata update, access permissions
are set. The information to do both of these operations is provided by
an instance of st::api::lims.

If a product is published multiple times to the same destination
collection, the following take place:

 - the RunPublisher checks local (run folder) file checksums against
   remote (iRODS) checksums and will not make unnecessary updates.

 - if a local file has changed, the copy in iRODS will be overwritten
   and additional metadata indicating the time of the update will be
   added.

 - the RunPublisher will proceed to make metadata and permissions
   changes to synchronise with the metadata supplied by st::api::lims,
   even if no files have been modified.

Caveats:

If you are publishing several products concurrently, take care that
you select a different restart file for each job.


=head1 AUTHOR

Keith James <kdj@sanger.ac.uk>

=head1 COPYRIGHT AND DISCLAIMER

Copyright (C) 2015, 2016, 2017, 2018 Genome Research Limited. All Rights
Reserved.

This program is free software: you can redistribute it and/or modify
it under the terms of the Perl Artistic License or the GNU General
Public License as published by the Free Software Foundation, either
version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

=cut
