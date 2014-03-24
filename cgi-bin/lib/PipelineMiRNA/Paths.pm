package PipelineMiRNA::Paths;

# ABSTRACT: Managing paths and path construction

use strict;
use warnings;
use Cwd;
use Carp;
use File::Spec;
use File::Basename;
use YAML::XS;

=method get_config

Get the YAML configuration file contents.

=cut

sub get_config {
    my ($self, @args) = @_;
    my $config_file = File::Spec->catfile(File::Basename::dirname(__FILE__), 'pipeline.cfg');
    my $yaml = get_yaml_file($config_file);
    return %{$yaml};
}

=method get_programs_config

Get the YAML programs configuration file contents.

=cut

sub get_programs_config {
    my ($self, @args) = @_;
    my $config_file = File::Spec->catfile(File::Basename::dirname(__FILE__), 'programs.cfg');
    my $yaml = get_yaml_file($config_file);
    return %{$yaml};
}

=method get_job_config_path

Given a job directory, return the path to the job configuration file

=cut

sub get_job_config_path {
    my ($self, @args) = @_;
    my ($dir_job) = shift @args;
    my $job_config_path = File::Spec->catfile( $dir_job, 'run_options.cfg' );
    return $job_config_path;
}

=method get_web_root

Return the web root
(ie in http://myserver.org/web_root/<pipeline.pl>)

=cut

sub get_web_root {
    my ($self, @args) = @_;
    my %config = $self->get_config();
    return $config{'web_root'};
}

=method get_css_path

Return the project CSS directory

=cut

sub get_css_path {
    my ($self, @args) = @_;
    my %config = $self->get_config();
    return $config{'css'};
}

=method get_server_css_path

Return the Server CSS directory

=cut

sub get_server_css_path {
    my ($self, @args) = @_;
    my %config = $self->get_config();
    return $config{'server_css'};
}

=method get_js_path

Return the project JavaScript directory

=cut

sub get_js_path {
    my ($self, @args) = @_;
    my %config = $self->get_config();
    return $config{'js'};
}

=method get_data_path

Return the project data directory

=cut

sub get_data_path {
    my ($self, @args) = @_;
    my %config = $self->get_config();
    return $config{'data'};
}

=method get_static_path

Return the project static directory

=cut

sub get_static_path {
    my ($self, @args) = @_;
    my %config = $self->get_config();
    return $config{'static'};
}

=method get_scripts_path

Return the project static directory

=cut

sub get_scripts_path {
    my ($self, @args) = @_;
    my %config = $self->get_config();
    return $config{'scripts'};
}

=method get_lib_path

Return the project static directory

=cut

sub get_lib_path {
    my ($self, @args) = @_;
    my %config = $self->get_config();
    return $config{'lib'};
}


=method get_results_web_path

Return the path to the results, as seen from the web

=cut

sub get_results_web_path {
    my ($self, @args) = @_;
    my %config = $self->get_config();
    return $config{'web_results'};
}

=method get_results_filesystem_path

Return the path to the results, as seen from the get_results_filesystem_path

=cut

sub get_results_filesystem_path {
    my ($self, @args) = @_;
    my %config = $self->get_config();
    return $config{'filesystem_results'};
}

=method get_candidate_paths

Return both the server and absolute paths for a given candidate

=cut

sub get_candidate_paths {
    my ($self, @args) = @_;
    my ($job_dir,  $dir, $subDir) = @args;
    my $candidate_dir = File::Spec->catdir($job_dir,  $dir, $subDir);
    return $candidate_dir;
}

=method filesystem_to_relative_path

Convert a filesystem path to a web path

=cut

sub filesystem_to_relative_path {
    my ($self, @args) = @_;
    my $path = shift @args;
    my $filesystem_path = PipelineMiRNA::Paths->get_results_filesystem_path();
    my $web_path        = PipelineMiRNA::Paths->get_results_web_path();
    $path =~ s/$filesystem_path/$web_path/g;
    return $path;
}

=method get_yaml_file

Check whether a given file is suitable for YAML deserialization,
and returns its content if so.

=cut

sub get_yaml_file {
    my @args      = @_;
    my $yaml_file = shift @args;
    ( -e $yaml_file )  or die("Error, YAML file $yaml_file does not exist");
    ( !-z $yaml_file ) or die("Error, YAML file $yaml_file is empty");
    ( -r $yaml_file )  or die("Error, YAML file $yaml_file is not readable");
    my $yaml;
    if ( !eval { $yaml = YAML::XS::LoadFile($yaml_file); } ) {
        croak("Error, YAML file $yaml_file is malformed");
    }
    else {
        return $yaml;
    }
}

1;
