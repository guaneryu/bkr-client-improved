#!/bin/sh
# -*- tcl -*-
# The next line is executed by /bin/sh, but not tcl \
exec tclsh "$0" ${1+"$@"}

# Author: jiyin@redhat.com
# A beaker client tool, Read testlist from file/stdin(generated by lstest), and
#   call gen_job_xml.tcl generate xml files and submit them to beaker server.

lappend ::auto_path /usr/local/lib /usr/lib64 /usr/lib
package require getOpt
package require runtestlib
namespace import ::getOpt::* ::runtestlib::*

# global var
array set Opt {}
array set InvalidOpt {}
set Args [list]
set OptionList {
	help   {arg n	help {Print this usage}}	h {link help}
	dryrun {arg n	help {Just generate XML file(s), not submit job to beaker}}	n {link dryrun}
	merge  {arg n	help {Merge all recipeSets in one job XML}}	m {link merge}
	raw    {arg n	help {Do not parse subtest.desc}}	r {link raw}
	e      {arg o	help {Call `expand_testlist [ployConf]` to expand testList}}
	alone  {arg n	help {Submit all tests separately, one case one recipe}}
}

# _parse_ argument
getOptions $OptionList $::argv Opt InvalidOpt Args
puts "\[runtest.tcl\]: Args{$Args}"
parray InvalidOpt
parray Opt

# Usage
proc Usage {} {
	puts "Usage: $::argv0 <distro> \[options\] \[-|testList|caseDir ...\] \[-- gen_job_xml options\] "
	puts "Genarate job xml files from test case dir, test list file or stdin, then grouped submit to beaker\n"
	puts "Example 1: runtest RHEL-6.6 -n ~/git/test/kernel/filesystems/nfs/function/"
	puts "Example 1: runtest RHEL-6.6 -n ~/git/test/kernel/networking/bonding/failover -- --nay-nic-driver=tg3 --nay-nic-num=2"
	puts "Example 2: echo '/distribution/reservesys' | runtest RHEL-6.6 - -- --arch=x86_64 --kdump --nvr=kernel-2.6.32-570.el6"
	puts ""
	getUsage $::OptionList
	puts "Info: exec `gen_job_xml.tcl -h` to check bkr workflow options"
}
if [info exist Opt(help)] {
	Usage
	exit 0
}
if {[llength $Args] < 1} {
	Usage
	exit 1
}

set lstest_opts {}
if [info exist Opt(raw)] {
	append lstest_opts {-r}
}

set SubcmdOpt [list]
set TestArgList {}
set Idx [lsearch $Args {--}]
if {$Idx == -1} {
	set TestArgList [lrange $Args 1 end]
} else {
	set TestArgList [lrange $Args 1 [expr $Idx-1]]
	set SubcmdOpt [lrange $Args [expr $Idx+1] end]
}

set Distro [lindex $Args 0]
#If Distro is a errata name, process it.
if [regexp -- {^RH[A-Z]{2}-[0-9]{4}:[0-9]+} $Distro] {
	lassign [exec errata2distro_and_pkg $Distro] Distro pkgBuild
	set pkgOpt {--install}
	if [regexp -- {^kernel-} $pkgBuild] {set pkgOpt {--nvr}}
	lappend SubcmdOpt $pkgOpt=$pkgBuild
}

#If Distro is short format
set Distro [expandDistro $Distro]

# Get the test list
set TestList {}
if {[llength $TestArgList]==0} {
	if {![catch {set fp [open "|lstest . $lstest_opts" r]} err]} {
		while {-1 != [gets $fp line]} {
			lappend TestList $line
		}
		close $fp
	}
} else {
	foreach f $TestArgList {
		if {$f in "-"} {
			set fp stdin
			while {-1 != [gets $fp line]} {
				lappend TestList $line
			}
		} elseif [file isdirectory $f] {
			lappend TestDir $f
			if {![catch {set fp [open "|lstest $f $lstest_opts" r]} err]} {
				while {-1 != [gets $fp line]} {
					lappend TestList $line
				}
				close $fp
			}
		} elseif [file isfile $f] {
			if {![catch {set fp [open $f]} err]} {
				while {-1 != [gets $fp line]} {
					lappend TestList $line
				}
			}
		}
	}
}

# Expand test list
if [info exist Opt(e)] {
	set ployConf {}
	if {$Opt(e) != ""} {
		set ployConf "$Opt(e)"
	}
	set TestList_tmp [exec mktemp]
	set fp [open $TestList_tmp w]
	foreach test $TestList {
		puts $fp "$test"
	}
	close $fp

	set TestList {}
	if {![catch {set fp [open "|cat $TestList_tmp | expand_testlist $ployConf" r]} err]} {
		while {-1 != [gets $fp line]} {
			lappend TestList $line
		}
		close $fp
	}
	file delete $TestList_tmp
}

# Group the test list
set sschedCnt 0
foreach test $TestList {
	if {[regexp {^ *#} $test] == 1} continue
	if {[string trim $test] == ""} continue

	# get key {pkg= ssched= topo= GlobalSetup}
	set key [testinfo recipekey $test]
	if {$key == ""} {
		puts stderr "Warn: recipekey is nil!"
		continue
	}
	if [info exist Opt(alone)] {regsub {ssched=no} $key {ssched=yes} key}
	if [regexp {ssched=ye} [lindex $key 1]] {
		lset key 1 "ssched=yes.[incr sschedCnt]"
	}
	# fix me verify distro info, if distronin or distronotin specify
	#if ![verify_test $Distro] {continue}
	lappend TestGroup($key) $test
}

# Gen job xml[s] and submit
set TestCnt 0
set TestSumm {}
set gen_opts {}
if [info exist Opt(merge)] {
	set xmlf_merged "job_merged.[clock format [clock seconds] -format %Y%m%d_%H%M].[expr {int(rand()*10000)}].xml"
	lappend SubcmdOpt {-recipe}
}
foreach {tkey tvalue} [array get TestGroup] {
	lassign [genWhiteboard $Distro $tkey $tvalue] WB gset
	if {[string length $SubcmdOpt]>0} {append WB " {$SubcmdOpt}"}

	set jobinfo job_[regsub -all {[^-,=_a-zA-Z0-9]} $WB {_}]; # substitute special characters
	set jobinfo [regsub -all {_+} $jobinfo {_}];		  # merge duplicate underlines
	set xmlf [string range $jobinfo 0 128].[expr {int(rand()*10000)}].xml; # limit filename length

	if {![catch {set fp \
	  [open "|gen_job_xml.tcl -distro=$Distro -f - $SubcmdOpt {-wb=$WB} $gset >$xmlf" w]} err]} {
		foreach t $tvalue { puts $fp "$t" }
		close $fp

		puts "INFO: processing GlobalSetup: {$gset}"
		puts "Generate job XML ==> '$xmlf'"

		if [info exist xmlf_merged] {
			exec sed -n {/retention_tag/,/\/notify/p} $xmlf > ${xmlf_merged}.head
			exec sed -n {/recipeSet/,/\/recipeSet/p} $xmlf >> ${xmlf_merged}.body
			exec sed -n {/\/job/,/$/p} $xmlf > ${xmlf_merged}.tail

			file delete $xmlf
		} else {
			if ![info exist Opt(dryrun)] {
				set status [catch {exec bkr job-submit $xmlf} result]
				puts "$result"
				file delete $xmlf
			}
		}
		puts ""
	} else {
		puts "Error: fail to write $xmlf"
	}
}

if [info exist xmlf_merged] {
	puts "INFO: Merged all recipeSets to '$xmlf_merged'"
	set XML [exec cat ${xmlf_merged}.head ${xmlf_merged}.body ${xmlf_merged}.tail]
	file delete ${xmlf_merged}.head
	file delete ${xmlf_merged}.body
	file delete ${xmlf_merged}.tail

	if [info exist TestDir] {set TestList "$TestDir"}
	lassign [genWhiteboard $Distro {merged} $TestList] WB tmp
	regsub {<!--(<job .*?>)-->} $XML {\1} XML
	regsub -all {[\&\\]} $WB {\\&} NWB
	regsub {<!--<whiteboard>.*?</whiteboard>-->} $XML "<whiteboard>$NWB</whiteboard>" XML
	regsub {<!--(<notify>)} $XML {\1} XML
	regsub {(</notify>)-->} $XML {\1} XML
	regsub -linestop {<!--(</job>)-->$} $XML {\1} XML
	puts [open ${xmlf_merged} w+] $XML
	if ![info exist Opt(dryrun)] {
		set status [catch {exec bkr job-submit $xmlf_merged} result]
		puts "$result"
		file delete $xmlf_merged
	}
}
