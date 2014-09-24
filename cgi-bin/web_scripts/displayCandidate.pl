#!/usr/bin/perl -w
use strict;
use warnings;

use CGI;
use CGI::Carp qw(fatalsToBrowser);
use FindBin;

BEGIN { require File::Spec->catfile( $FindBin::Bin, 'requireLibrary.pl' ); }
use miRkwood;
use miRkwood::WebPaths;
use miRkwood::Utils;
use miRkwood::Results;
use miRkwood::Candidate;
use miRkwood::WebTemplate;

my $cgi            = CGI->new();
my $jobId          = $cgi->param('jobID');
my $candidate_id   = $cgi->param('id');

my @css = (File::Spec->catfile(miRkwood::WebPaths->get_css_path(), 'results.css'));
my @js  = (miRkwood::WebTemplate->get_js_file());

my $job = miRkwood::Results->jobId_to_jobPath($jobId);
my $returnlink = miRkwood::WebTemplate::get_link_back_to_results($jobId);
my $return_html = "<a class='returnlink' href='$returnlink'>Back to main results page</a>";

my $candidate;
my $html_contents;

my $cfg_path = miRkwood::Paths->get_job_config_path($job);
miRkwood->CONFIG_FILE($cfg_path);
$candidate = miRkwood::CandidateHandler->retrieve_candidate_information($job, $candidate_id);

if (! eval {$candidate = miRkwood::CandidateHandler->retrieve_candidate_information($job, $candidate_id);}) {
    # Catching exception
    $html_contents = "No results for the given identifiers";
}else{

    my $image_url = $candidate->get_relative_image();

    my $size = length $candidate->{'sequence'};

    my $export_link = "./getCandidate.pl?jobId=$jobId&id=$candidate_id";

    my $linkFasta = "$export_link&type=fas";
    my $linkVienna = "$export_link&type=dot";
    my $linkAlternatives = "$export_link&type=alt";
    my $linkViennaOptimal = $linkVienna . '&optimal=1';

    my $Vienna_HTML = "<li><b>Stem-loop structure (dot-bracket format):</b> <a href='$linkVienna'>download</a>";
    if($candidate->{'structure_stemloop'} ne $candidate->{'structure_optimal'}){
        $Vienna_HTML .= "</li><li><b>Optimal MFE secondary structure (dot-bracket format):</b> <a href='$linkViennaOptimal'>download</a></li>"
    } else {
        $Vienna_HTML .= "<br/>This stem-loop structure is the MFE structure.</li>"
    }

    my $alternatives_HTML = '<b>Alternative candidates (dot-bracket format):</b> ';
    if($candidate->{'alternatives'}){
        $alternatives_HTML .= "<a href='$linkAlternatives'>download</a>"
    } else {
        $alternatives_HTML .= "<i>None</i>"
    }
    my $cfg = miRkwood->CONFIG();

    my $alignmentHTML;

    if ( !$cfg->param('options.align') ) {
        $alignmentHTML = qw{};
    }
    else {
        $alignmentHTML = '<h2>Conserved mature miRNA</h2>';

        if ( $candidate->{'alignment'} ) {
            $alignmentHTML .=
              $candidate->make_alignments_HTML();
        }
        else {
            $alignmentHTML .= "No alignment has been found.";
        }
    }

    my $imgHTML = '';
    if ( $cfg->param('options.varna') ) {
        $imgHTML = "<img class='structure' id='structure' src='$image_url' height='300px' alt='$candidate->{'name'} secondary structure'>"
    }

    my $shufflesHTML = '';
    if ( $cfg->param('options.randfold') ) {
        $shufflesHTML = "<li>
          <b>Shuffles:</b> $candidate->{'shuffles'}
        </li>"
    }

    $html_contents = <<"END_TXT";
            <div id = 'showInfo'>
        <ul>
        <li>
          <b>Name: </b>$candidate->{'name'}
        </li>
        <li>
          <b>Position:</b> $candidate->{'position'} ($size nt)
        </li>
        <li>
          <b>Strand:</b> $candidate->{'strand'}
        </li>
        <li>
          <b>G+C content:</b> $candidate->{'%GC'}%
        </li>
        <li>
          <b>Sequence (FASTA format):</b> <a href='$linkFasta'>download</a>
        </li>
        $Vienna_HTML
        <li>
          $alternatives_HTML
        </li>
        </ul>
        $imgHTML
        <h2>Thermodynamics stability</h2>
        <ul>
        <li>
          <b>MFE:</b> $candidate->{'mfe'} kcal/mol
        </li>
        <li>
          <b>AMFE:</b> $candidate->{'amfe'}
        </li>
        <li>
          <b>MFEI:</b> $candidate->{'mfei'}
        </li>
        $shufflesHTML
        </ul>
        $alignmentHTML

    </div><!-- showInfo -->
END_TXT
}

my $body  = <<"END_TXT";
    <body>
       <h1>Results for $candidate->{'name'}, $candidate->{'position'}</h1>
        $return_html
        $html_contents
        $return_html
    </body>
END_TXT

my $html = miRkwood::WebTemplate::get_HTML_page_for_body($body, \@css, \@js);

print <<"DATA" or die("Error when displaying HTML: $!");
Content-type: text/html

$html
DATA
###End###