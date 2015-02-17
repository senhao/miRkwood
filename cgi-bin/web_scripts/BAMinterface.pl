#!/usr/bin/perl -w
use strict;
use warnings;
use CGI;
use CGI::Carp qw(fatalsToBrowser);
use FindBin;
use File::Spec;

BEGIN { require File::Spec->catfile( $FindBin::Bin, 'requireLibrary.pl' ); }
use miRkwood::WebTemplate;

my @css = (miRkwood::WebTemplate->get_server_css_file(), miRkwood::WebTemplate->get_css_file());
my @js  = (miRkwood::WebTemplate->get_js_file());

my $help_page = File::Spec->catfile( miRkwood::WebPaths->get_html_path(), 'help.php');

my $page = <<"END_TXT";
<div class="main">
    <form id="form" onsubmit="return verifyBEDForm();" method="post" action="./BAMpipeline.pl" enctype="multipart/form-data">
        <fieldset id="fieldset">
            <div class="forms">
                <label for='job'><b>Job title</b> (optional)</label>
                <input type="text" id ='job' name="job" size="20"/>
            </div> 
            
            <div class="forms">
                <label for='bedFile'><b>Enter your set of reads </b>&nbsp;[<a href="$help_page">?</a>]</label>
                <br /><br />
                This must be a BED file created by our script <i>mirkwood-bam2bed.pl</i>.
                <p><input type="file" name="bedFile" id="bedFile" /></p>
                <a id="area_clear" onclick="resetElementByID('bedFile');">Clear BED</a>
            </div> 
            
            <div class="forms">
                <b>Enter your reference sequence </b>
                <br /><br />
                <label for="species">Select a genome in the list below: </label><br />
                <select name="species" id="species">
                    <option value="" selected>--Choose species--</option>
                    <option value="Arabidopsis_lyrata">Arabidopsis lyrata (v1.0)</option>
                    <option value="Arabidopsis_thaliana">Arabidopsis thaliana (TAIR10)</option>
                    <option value="Brassica_rapa">Brassica rapa (Brapa_1.1)</option>
                    <option value="Glycine_max">Glycine max (v1.0.23)</option>
                    <option value="Lotus_japonicus">Lotus japonicus (Lj2.5)</option>
                </select>  
                <br /><br />
                <label for='seqArea'>Or paste your reference sequence in FASTA format &nbsp;[<a href="$help_page">?</a>]</label>
                <br /><br />
                <textarea id='seqArea' name="seqArea"  rows="10" cols="150" ></textarea>
                <br />
                <a id="area_clear" onclick="resetElementByID('seqArea')">Clear</a> 
                
                <br /><br />
                
                <b>Parameters:</b>
                <p>
                    <input class="checkbox" type="checkbox" name='CDS' id ="CDS" onclick="showHideBlock()"/>
                    &#160;<label for='CDS'>Mask coding regions</label>  [<a href="$help_page#mask-coding-regions">?</a>]
                </p>
                <div id="menuDb">
                    <label class="choixDiv selectdb" for="db">Choose organism database:</label>
                    <select class="db" name="db" id='db'>
                        <option class="db" selected="selected">Arabidopsis_thaliana</option>
                        <option class="db">Oryza_sativa</option>
                        <option class="db">Medicago_truncatula</option> 
                    </select>
                </div>
                <p>
                    <input class="checkbox" type="checkbox" name='filter-tRNA-rRNA' id ="filter-tRNA-rRNA"/>
                    &#160;<label for='filter-tRNA-rRNA'>Filter out tRNA/rRNA</label>  [<a href="$help_page#filter_tRNA_rRNA">?</a>]
                </p>                
                
            </div>
            
            <div class="forms">
                <p>
                    <b>Parameters</b>: Choose the annotation criteria for the miRNA precursors [<a href="$help_page#parameters">?</a>]
                </p>
                <div id='listParam'>  
                    <p>
                        <input class="checkbox" type="checkbox" checked="checked" name="filter_multimapped" id="filter_multimapped" value="filter_multimappedChecked" />
                        &#160;<label for='filter_multimapped'>Filter out reads mapping at more than 5 positions</label>                        
                    </p>
                    <p>
                        <input class="checkbox" type="checkbox" checked="checked" name="mfei" id="mfei" value="mfeiChecked" />
                        &#160;<label for='mfei'>Select only sequences with MFEI &lt; -0.6</label>
                    </p>
                    <p>
                        <input class="checkbox" type="checkbox" name="randfold" id="randfold" value="randfoldChecked" />
                        &#160;<label for='randfold'>Compute thermodynamic stability <i>(shuffled sequences)</i></label>
                    </p>
                    <p>
                        <input class="checkbox" type="checkbox" checked="checked" name="align" id="align" value="alignChecked" />
                        &#160;<label for='align'>Flag conserved mature miRNAs <i>(alignment with miRBase + miRdup)</i></label>
                    </p>
                </div>
            </div>
            
            <div class="forms">
                <label for='mail'><b>E-mail address</b> (optional)</label>
                <input type="text" id='mail' name="mail" size="20"/>
            </div>
            
            <div class="center">
                <input type="reset" name="clear" id="clear" value="Clear form"/>
                <input type="submit" name="upload" id="upload" value="Run miRkwood"/>
            </div> 
        </fieldset>       
    </form>

</div><!-- main -->
END_TXT

my $html = miRkwood::WebTemplate::get_HTML_page_for_content($page, \@css, \@js);
print <<"DATA" or die("Error when displaying HTML: $!");
Content-type: text/html

$html
DATA
