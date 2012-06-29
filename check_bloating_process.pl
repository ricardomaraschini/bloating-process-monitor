#!/usr/bin/perl

#
# Copyright (C) 2012 Ricardo Maraschini 
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#

use strict;
use Getopt::Long qw(:config no_ignore_case bundling);
use Statistics::OLS;
eval {
	require GD::Graph::lines;
	GD::Graph::lines->import();
};

use constant VERSION => 0.01;
use constant OK => 0;
use constant WARNING => 1;
use constant CRITICAL => 2;
use constant UNKNOWN => 3;
use constant FALSE => 0;
use constant TRUE => 1;
use constant MINENTRIES => 40;
use constant MAXENTRIES => 100;
use constant GROWTHTOLERANCE => 0;

sub main {

	our $opt_verb;
	our $opt_logf;
	our $opt_grph;
	our $opt_gpth;
	our $opt_proc;
	our $opt_tole;
	our $opt_tpth;
	our $opt_ppid;

	my $opt_help;
	my $rss = 0;
	my $vsz = 0;
	my $command;
	my $l;
	my $out_prefix;
	my @dirty_ret = ();
	my $exit_code;
	my $proc_descr;

	GetOptions(
	           "h"             => \$opt_help,
	           "v"             => \$opt_verb,
	           "p=s"           => \$opt_proc,
	           "g"             => \$opt_grph,
	           "t=s"           => \$opt_tole,
	           "graphpath=s"   => \$opt_gpth,
	           "tmppath=s"     => \$opt_tpth,
	           "P=i"           => \$opt_ppid,
	);

	print_usage() if (!defined $opt_proc && !defined $opt_ppid);
	
	if (!defined $opt_gpth) {
		$opt_gpth = "/tmp";
	}

	if (!defined $opt_tpth) {
		$opt_tpth = "/tmp";
	}

	if (!defined $opt_tole) {
		$opt_tole = GROWTHTOLERANCE;
	}
	
	# create path to history log file
	if (!defined $opt_ppid) {
		$opt_logf = $opt_tpth . "/bloating-". $opt_proc . ".log";
	} else {
		$opt_logf = $opt_tpth . "/bloating-". $opt_ppid . ".log";	
	}
	
	println("Running in verbose mode [-v]:\n") if ($opt_verb);
	println("log file path: $opt_logf") if ($opt_verb);

	if (!defined $opt_ppid) {
		$command = "/bin/ps -eopid,rss,vsz,comm |/bin/grep $opt_proc | grep -v grep";
	} else {
		$command = "/bin/ps --pid $opt_ppid -opid,rss,vsz,comm | /usr/bin/tail -1";
	}

	println("running $command") if ($opt_verb);
	@dirty_ret = `$command`;
	print @dirty_ret if ($opt_verb);
	
	foreach $l (@dirty_ret) {	
		if ($l =~ m/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(.+)$/) {
		
			$rss += $2;
			$vsz += $3;
			$proc_descr = $4;		
			
			println("...............") if ($opt_verb);
			println("rss:$rss") if ($opt_verb);
			println("vsz:$vsz") if ($opt_verb);
			
		}
		
	}
		
	println("...............") if ($opt_verb);
	
	if ($rss == 0 || $vsz == 0) {
		println("UNKNOWN - Unable to locate process $opt_proc");
		exit UNKNOWN;
	}

	$exit_code = process_new_entry($rss,$vsz);
	
	println("$proc_descr process utilization - rss: $rss  vsz: $vsz | rss=$rss;;;; vsz=$vsz;;;;");
	exit($exit_code);

}


sub process_new_entry {

	our $opt_logf;
	our $opt_verb;
	our $opt_grph;
	our $opt_tole;
	
	my @labels;
	my @time;
	my @rss_history;
	my @vsz_history;
	my @predicted_ys;
	my $rss = shift;
	my $vsz = shift;
	my $ret;
	my $i;
	my $ls;

	
	if (!-f $opt_logf) {
		return start_db_file($rss,$vsz);
	}
	
	$ret = read_db_file(\@rss_history, \@vsz_history);
	if ($ret != OK) {
		out_with_error("File $opt_logf appears to be corrupted");
	}

	push(@rss_history,$rss);
	push(@vsz_history,$vsz);
	
	if ($opt_verb) {
		println("parsed values:");
		println("RSS:\n");
		foreach(@rss_history) {
			println("\t#$_#");
		}

		println("VSZ:\n");
		foreach(@vsz_history) {
			println("\t#$_#");
		}
		
	}

	$i = 1;
	foreach( @rss_history ) {
		push(@time,$i);
		push(@labels,"");
		$i++;
	}

	$ls = Statistics::OLS->new;
	$ls->setData (\@time, \@rss_history);
	$ls->regress();
	
	@predicted_ys = $ls->predicted();
	my ($intercept, $slope) = $ls->coefficients();
	println("slope: $slope") if ($opt_verb);
	
	store_db_file(\@rss_history,\@vsz_history);

	if (defined $opt_grph) {
		gen_graph(\@labels,\@predicted_ys,\@rss_history);
	}
	
	if ($slope <= $opt_tole || $#rss_history < MINENTRIES) {
		return OK;
	}
	
	return CRITICAL;

}


sub gen_graph {

	our $opt_gpth;
	our $opt_proc;
	our $opt_ppid;
	
	my $labels = shift;
	my $trend = shift;
	my $collected = shift;
	my $graph;
	my $image;
	my @data;
	
	$graph = GD::Graph::lines->new(800, 300);
	$graph->set(
		x_label => 'Ticks',
		y_label => 'Memory usage',
		title => $opt_proc ." process memory usage"
	) or die out_with_error($graph->error);
	
	@data = ($labels, $trend, $collected);
	$graph->set_legend("trend line","collected data");
	my $image = $graph->plot(\@data) 
		or die out_with_error($graph->error);

	if (defined $opt_proc) {
		open(F,">$opt_gpth/bloating-$opt_proc.png")
			or die out_with_error("Unable to generate graph on $opt_gpth/$opt_ppid.png");
	} else {
		open(F,">$opt_gpth/bloating-$opt_ppid.png")
			or die out_with_error("Unable to generate graph on $opt_gpth/$opt_ppid.png");	
	}
	print F $image->png;
	close(F);

}


sub store_db_file {

	our $opt_verb;
	our $opt_logf;
	my $first;
	my $rss = shift;
	my $vsz = shift;
	my $skip_first = FALSE;
	my $count = 0;

	foreach (@$rss) {
		$count += 1;
	}
	
	if ($count >= MAXENTRIES){
		$skip_first = TRUE;
	}
	
	open(F,">$opt_logf")
		or die out_with_error("Unable to open $opt_logf for write");

	$first = TRUE;
	print F "rss:";
	foreach (@$rss) {
		if ($skip_first && $first) {
			$first = FALSE;
			next;
		}
		print F "$_;"
	}
	print F "\n";

	$first = TRUE;
	print F "vsz:";
	foreach (@$vsz) {
		if ($skip_first && $first) {
			$first = FALSE;
			next;
		}
		print F "$_;"
	}
	
	close(F);

}

sub print_usage {

	println("check_bloating_process.pl v.". VERSION);
	println("Copyright (c) Ricardo Maraschini <ricardo.maraschini\@opservices.com.br>");
	println("");
	println("This plugin is used to monitor memory usage growth(rss) of a given process");
	println("");
	println("Usage:");
	println("check_bloating_process.pl <-p procname | -P pid> [-h] [-v] [-g] [-t tolerance] [--graphpath=/my/path] [--tmppath=/my/path]");
	println("");
	println("Options:");
	println("-h");
	println("\tPrints this help message");
	println("-v");
	println("\tRun in verbose mode");
	println("-p procname");
	println("\tSearch for process with 'procname' string. If more than one process with ");
	println("\tthe same name is encountered, the memory usage used is the sum of all");
	println("\tprocesses together.");
	println("-P pid");
	println("\tMonitor process with the given pid. This option conflicts with -p above");
	println("-t tolerance");
	println("\tApply a tolerance of 'tolerance' bytes when analising the process growth");
	println("-g");
	println("\tEnable memory usage graph generation(requires GD::Graph::lines perl module)");
	println("--graphpath");
	println("\tDirectory where to create the memory utilization graph(requires -g option to take effect)");
	println("\tBy default, creates the graph on /tmp/bloating-<procname>.png");
	println("--tmppath");
	println("\tDirectory where to create the memory utilization history temporary file");
	println("\tBy default, creates the file on /tmp/bloating-<procname>.log");
	println("");
	println("Send email to ricardo.maraschini\@opservices.com.br if you have questions regarding use");
	println("of this software.");
	
	println("");
	exit UNKNOWN;

}

sub println {
	my $str = shift;
	print "$str\n";
}

sub read_db_file {

	our $opt_verb;
	our $opt_logf;
	my @slices;
	my $error;
	my $aux;
	my $i;
	my $rss = shift;
	my $vsz = shift;
	
	println("starting to read $opt_logf") if ($opt_verb);
	open(F,"<$opt_logf")
		or die out_with_error("Unable to open $opt_logf for reading.");
	
	$error = FALSE;
	foreach(<F>) {
	
		chomp();
		@slices = split(/[:;]/,$_);
		
		if ($opt_verb) {
			for ($i=0; $i<=$#slices; $i++) {
				print $slices[$i]."-";
			}
			println("");
		}
		
		if ($slices[0] ne "rss" && $slices[0] ne "vsz" ) {
			$error = TRUE;
		} else {
		
			if ($slices[0] eq "rss") {
				$aux = $rss;
			} else {
				$aux = $vsz;
			}

			for ($i=1; $i<=$#slices; $i++) {
				push(@$aux,$slices[$i]);
			}

		}
		
	}
	
	close(F);
	if ($error) {
		return CRITICAL;
	}
	
	return OK;
	
}

sub start_db_file {

	my $rss = shift;
	my $vsz = shift;
	our $opt_verb;
	our $opt_logf;

	println("creating a new db file: $opt_logf") if ($opt_verb);
		
	open(F,">$opt_logf")
		or die out_with_error("Unable to create file $opt_logf");
			
	print F "rss:$rss\n";
	print F "vsz:$vsz\n";
	
	close(F);
	
	println("$opt_logf created sucessfuly, returning OK") if ($opt_verb);
	
	return OK;

}

sub out_with_error {
	my $msg = shift;
	println($msg);
	exit UNKNOWN;
}

&main();
