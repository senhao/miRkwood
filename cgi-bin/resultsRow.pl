#!/usr/bin/perl -w
use strict;
use warnings;

use CGI;
use FindBin;                     # locate this script
use lib "$FindBin::Bin/../lib";  # use the parent directory
use PipelineMiRNA::WebTemplate;
use PipelineMiRNA::WebFunctions;
use PipelineMiRNA::Paths;
use PipelineMiRNA::Utils;

my $bioinfo_menu = PipelineMiRNA::WebTemplate::get_bioinfo_menu();
my $header_menu  = PipelineMiRNA::WebTemplate::get_header_menu();
my $footer       = PipelineMiRNA::WebTemplate::get_footer();

my $cgi            = CGI->new();
my $jobId          = $cgi->param('jobID');
my $name           = $cgi->param('nameSeq');
my $position       = $cgi->param('position');

my $candidate_name = $name.'__'.$position;
my $job = PipelineMiRNA::WebFunctions->jobId_to_jobPath($jobId);
my $returnlink = PipelineMiRNA::WebTemplate::get_link_back_to_results($jobId);

my %candidate;
my $html_contents;

if (! eval {%candidate = PipelineMiRNA::WebFunctions->retrieve_candidate_information($job, $name, $candidate_name);}) {
    # Catching exception
    $html_contents = "No results for the given identifiers";
}else{

    my $image_url = PipelineMiRNA::Paths->get_server_path($candidate{"image"});
    my $hairpin   = PipelineMiRNA::Utils::make_ASCII_viz($candidate{'DNASequence'}, $candidate{'Vienna'});
    my $size = length $candidate{'DNASequence'};

    my $linkFasta = "./getCandidateFasta.pl?jobId=$jobId&name=$name&position=$position";
    my $linkVienna = "./exportVienna.pl?jobId=$jobId&name=$name&position=$position";
    my $linkViennaOptimal = $linkVienna . '&optimal=1';

    my $Vienna_HTML = "<li><b>Stem-loop structure (dot-bracket format):</b> <a href='$linkVienna'>download</a>";
    if($candidate{'Vienna'} ne $candidate{'Vienna_optimal'}){
        $Vienna_HTML .= "</li><li><b>Optimal MFE secondary structure (dot-bracket format):</b> <a href='$linkViennaOptimal'>download</a></li>"
    } else {
        $Vienna_HTML .= "<br/><i>(This stem-loop structure is the MFE structure)</i></li>"
    }

    my $alignmentHTML;
    if($candidate{'alignment'}){
         $alignmentHTML = PipelineMiRNA::WebFunctions->make_alignments_HTML($job, $name, $candidate_name, $hairpin);
    } else {
        $alignmentHTML = "No alignment has been found.";
    }

    $html_contents ="
            <div id = 'showInfo'>
        <li>
          <b>Name: </b>$candidate{'name'}
        </li>
        <li>
          <b>Position:</b> $position ($size nt)
        </li>
        <li>
          <b>Strand:</b>
        </li>
        <li>
          <b>Sequence (FASTA format):</b> <a href='$linkFasta'>download</a>
        </li>
        <h2>Secondary structure</h2>
        <img id='structure' src='$image_url' height='400px' alt='$candidate_name secondary structure'>
        $Vienna_HTML
        <h2>Thermodynamics stability</h2>
        <li>
          <b>MFE:</b> $candidate{'mfe'} kcal/mol
        </li>
        <li>
          <b>AMFE:</b> $candidate{'amfe'}
        </li>
        <li>
          <b>MFEI:</b> $candidate{'mfei'}
        </li>

        <h2>Mirbase alignments</h2>
        $alignmentHTML

    </div><!-- showInfo -->
"
}

print <<"DATA" or die("Error when displaying HTML: $!");
Content-type: text/html

<html>
	<head>
		<LINK rel="stylesheet" type="text/css" href="/arn/style/results.css" />
		<script src="/arn/js/miARN.js" type="text/javascript" LANGUAGE="JavaScript"></script>
		<title>MicroRNA identification</title>
	</head>
	<body>
	    <a class="returnlink" href='$returnlink'>Return to results</a>
        $html_contents
	</body>
</html>

DATA
###End###
