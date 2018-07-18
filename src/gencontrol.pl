#!/usr/bin/perl 
# SPDX-License-Identifier: GPL-2.0
# Copyright © 2007-2018 ANSSI. All Rights Reserved.

#
#  gencontrol.pl - generate a dpkg control file from gentoo 
#  "build-info" files.
#  Copyright (C) 2006-2009 SGDN/DCSSI
#  Copyright (C) 2009-2013 SGDSN/ANSSI
#  Author: Vincent Strubel <clipos@ssi.gouv.fr>
#
#  All rights reserved.
#
 
use strict;
use warnings;
use Getopt::Long;

############################## Protos #####################################
sub gver2Dver($$);
sub gentoo2Deb($);
sub uniq($);
sub getCommon ($$);

sub getOne($);
sub getMany($);
sub getDeps($);

sub getNameVers();
sub getArch();

sub filterUseConds($$);
sub explodeUnions($);
sub doMapDeps ($$$);
sub mapDeps ($$$);
sub mapDepsVar ($$$);

sub line2List($$);
sub printControl($);

############### Funky regexps that won't fit on one line :) ##############

# matches a gentoo ebuild name format (${P}), puts PN in $1, PV in $2
my $ebreg = '(\S+)-(\d+(?:\.\d+)*[[:alpha:]]?(?:(?:_alpha|_beta|_pre|_rc|_p)\d*)?\*?(?:-r\d+)?)';
# matches a gentoo version format (${PN}), extracts the corresponding 
# debian version components (prior to further transformation by gver2Dver)
my $gversreg = '(\d+(?:\.\d+)*[[:alpha:]]?)((?:(?:_alpha|_beta|_pre|_rc|_p)\d*)?\*?)((?:-r\d+)?)';

############################# Globals ####################################

my $g_useref;
my $g_section;
my $g_desc;
my $g_name;
my $g_version;
my $g_source;
my $g_arch;
my $g_size = "";
my $g_overlay = "";
my $g_distdir = "";
my $g_date = "";
my $g_maintainer = "CLIP";
my $g_builder = "";
my $g_priority = "Important";
my $g_urgency = "";
my $g_impact = "0";
my $g_license = "";
my $g_jails = "";

# National language descriptions
my %g_descs = ();
my %g_cats = ();

# National languages supported
my @g_nls = qw(fr);

my $g_distro;

my @g_deplist;
my @g_builddeps; 
my @g_conflist;
my @g_buildconflist;
my @g_provlist;
my @g_replist;
my @g_suggests;
my @g_recommends;
my $g_eclasses;
my @g_confdeps;

############################## Main ######################################

eval {
	GetOptions (
		'date=s'	=> \$g_date,
		'maintainer=s'	=> \$g_maintainer,
		'builder=s'	=> \$g_builder,
		'size=s'	=> \$g_size,
		'overlay=s'	=> \$g_overlay,
		'distdir=s'	=> \$g_distdir,
		'priority=s'	=> \$g_priority,
		'impact=s'	=> \$g_impact,
		'urgency=s'	=> \$g_urgency,
		'license=s'	=> \$g_license,
		'eclass=s'      => \$g_eclasses, 
	) or die 1;
};
die "Failed to parse command line" if ($@);
chomp $g_size;
chomp $g_overlay;
chomp $g_distdir;
chomp $g_date;
chomp $g_maintainer;
chomp $g_priority;
chomp $g_urgency;
chomp $g_license;

$g_impact = $g_impact." ";
chomp $g_impact;

if (not defined $ARGV[0]) {
	die "You must provide an output name";
}

die "No USE file ?" if (not -f "USE");
$g_useref = getMany("USE");

$g_section = getOne("CATEGORY");
$g_desc = ( -f "DESCRIPTION" ) ? getOne("DESCRIPTION")
	: "Automatically generated for CLIP";

$g_license = ( -f "LICENSE") ? getOne("LICENSE")
	: "GPL-2";

if ( -f "HOMEPAGE" ) {
	my $homepage = getOne("HOMEPAGE");
	chomp $homepage;
	$g_desc .= "\nHomepage: $homepage";
}

# We include the name of the original ebuild as Source:
($g_name, $g_version, $g_source) = getNameVers();
$g_arch = getArch();

mapDeps("RDEPEND", \@g_deplist, \@g_conflist);
# Map PDEPEND to Recommends:, to keep track of it
# => Not really a good idea, leads to circular dependencies
#if ( -f "PDEPEND" ) {
#	mapDeps("PDEPEND", \@g_recommends, \@g_conflist);
#}

if ($g_eclasses) {
	$g_eclasses =~ s/:/ /g;
	push @g_builddeps, (split /, /, $g_eclasses);
}

mapDeps("DEPEND", \@g_builddeps, \@g_buildconflist);

if (-f "PROVIDE") {
	my @fakeconf;
	mapDeps("PROVIDE", \@g_provlist, \@fakeconf);
	die "Error parsing PROVIDE: found unexpected conflicts"
						if ($#fakeconf != -1);
}

if (defined ($ENV{'DEB_SUGGESTS'}) and $ENV{'DEB_SUGGESTS'}) {
	my @fakeconf;
	mapDepsVar('DEB_SUGGESTS', \@g_suggests, \@fakeconf);
	die "Error parsing DEB_SUGGESTS: found unexpected conflicts"
						if ($#fakeconf != -1);
}

if (defined ($ENV{'CONF_DEPENDS'}) and $ENV{'CONF_DEPENDS'}) {
	my @fakedep;
	mapDepsVar('CONF_DEPENDS', \@g_confdeps, \@fakedep);
	die "Error parsing CONF_DEPENDS: found unexpected conflicts"
						if ($#fakedep != -1);
}

foreach my $lang (@g_nls) {
	my $var = "DESCRIPTION_".(uc $lang);
	$g_descs{$lang} = $ENV{$var} if (defined ($ENV{$var}));
	$var = "CATEGORY_".(uc $lang);
	$g_cats{$lang} = $ENV{$var} if (defined ($ENV{$var}));
}

if (defined($g_distro = $ENV{'DEB_DISTRIBUTION'})) {
	chomp $g_distro;
}

if (defined($g_jails = $ENV{'DEB_JAILS'})) {
	chomp $g_jails;
}

uniq(\@g_deplist);
uniq(\@g_recommends);
uniq(\@g_conflist);
uniq(\@g_provlist);
uniq(\@g_builddeps);
uniq(\@g_buildconflist);
push @g_replist, @{getCommon(\@g_provlist, \@g_conflist)};

if ($ARGV[0] eq "-") {
	printControl("/dev/stdout");
} else {
	printControl($ARGV[0]);
}

exit 0;



############################## Subs ######################################

sub uniq($) {
	my $listref = shift;
	my $len = $#{$listref};
	my $idx = 0;

	while ($idx < $len) {
		my $tok = ${$listref}[$idx];
		my $iter = $idx + 1;
		while ($iter <= $len) {
			if (${$listref}[$iter] eq $tok) {
				splice @{$listref}, $iter, 1;
				$len--;
			} else {
				$iter++;
			}
		}
		$idx++;
	}
}

sub getCommon($$) {
	my ($list1,$list2) = @_;
	my @common = ();

	foreach my $tok (@{$list1}) {
		push @common, $tok if (grep {$_ eq $tok} @{$list2});
	}

	return \@common;
}

sub gver2Dver($$) {
	my $gver = shift;
	my $is_depend = shift;

	# versioning conventions 
	# gentoo format is pkg-ver{_suf{#}}-{r#}.ebuild 
	# (see devrel handbook)
	# debian format is [epoch:]upstream_version[-debian_revision] 
	# (see debian-policy)
	# We basically do :
	# 	epoch := ""
	# 	upstream_version := ver{_suf{#}}
	# 	debian_revision := {r#}
	# But we must transform the _suf{#} part since upstream_version
	# may not contain a '_', and versions are ordered based solely
	# on dictionary order.
	# TODO: is there a way to map gentoo's SLOTs to debian's epochs ?
	my  ($ver,$suf,$rev);
	if ($gver =~ /^$gversreg$/) {
		$ver = $1;
		$suf = $2;
		$rev = $3;
	} else {
		die "Unrecognized version format : $gver";
	}
	#remove :XX in versions (used e.g. by KDE ebuilds)
	$suf =~ s/^_//;

	my $dver = $ver.$suf; 		# <upstream_version>
	$dver .= $rev; 			# + <debian_revision>

	return $dver;
}


sub gentoo2Deb($) {
	my $name = shift;
	my ($pkgname, $pkgver, $vercond, $negcond) = ("","","","");

	$name =~ s/([!><=~]*)[^\/ ]+\//$1/g;
	# for dependency atoms, drop the slot (EAPI 1) and use (EAPI 2) 
	# requirements, if any
	$name =~ s/\[[^\]]+\]//g;
	$name =~ s/:[\d\.]+$//;
	if ($name =~ /(!*)([><=~]*)$ebreg$/) {
		$negcond = $1;
		$vercond = $2;
		$pkgname = $3;
		$pkgver  = $4;
	} else {
		$name =~ s/_/-/g;
		return $name;
	}
	$pkgname =~ s/_/-/g;
	# deal with gtk-2* stuff, approximately
	if ($pkgver =~ s/(.*)\*/$1/) {
		if ($negcond) {
			$vercond = "<=";
		} else {
			$vercond = ">=";
		}
	}
	$pkgver = gver2Dver($pkgver, 1);
	$vercond =~ s/>$/>>/;
	$vercond =~ s/<$/<</;
	$vercond =~ s/~$/>=/;
	# Gentoo supports two types of conflicts from EAPI 3 up : 
	#  !foo means simultaneous installation of foo is temporarily 
	#  acceptable during qmerge
	#  !!foo means no simultaneous installation of foo at all
	# Both of these are mapped to regular Debian conflicts.
	$negcond =~ s/!+/!/;
	if ($vercond) {
		return "$negcond$pkgname ($vercond $pkgver)";
	} elsif ($pkgver) {
		return "$negcond$pkgname-$pkgver";
	} else {
		return "$negcond$pkgname";
	}
}

sub getOne($) {
	my $fname = shift;
	open IN, "<", "$fname" or die "Cannot open $fname";
	my $cat = <IN>;
	close IN;
	chomp $cat;

	return $cat;
}

sub getMany($) {
	my $fname = shift;
	my @deps = ();
	open IN, "<", "$fname" 
		or return \@deps;
	# Make sure parenthesis have a whitespace before and after them, 
	# then turn multiple whitespace characters into single spaces.
	my $tmp = join " ", (map {s/([\(\)])/ $1 /g; s/[\t\n ]+/ /g; $_} <IN>);
	close IN;
	push @deps, (split / +/, $tmp);

	return \@deps;
}

sub getDeps($) {
	my $fname = shift;
	my @deps = ();
	open IN, "<", "$fname" 
		or return \@deps;
	# Make sure parenthesis have a whitespace before and after them, 
	# then turn multiple whitespace characters into single spaces.
	my $tmp = join " ", (map {s/\([\+-]\)//g; s/([\(\)])/ $1 /g; s/[\t\n ]+/ /g; $_} <IN>);
	close IN;
	push @deps, (split / +/, $tmp);

	return \@deps;
}
	

sub getArch() {
	my $build = getOne("CBUILD");
	
	# Add additional arches here as needed
	$build =~ s/^([^-]+)-.*/$1/;
	if ($build =~ /^i\d86$/) {
		return "i386";
	} if ($build =~ /^arm/) {
		return "armel";
	} if ($build =~ /^x86_64$/) {
		return "amd64";
	} else {
		return "INVALIDARCH";
	}
}

sub getNameVers() {
	my ($name, $vers, $source);
	open IN, "<", "PF" or die "Cannot open PF";
	my $tmp = <IN>;
	close IN;

	if ($tmp =~ /^$ebreg$/) {
		$name = $1;
		$vers = $2;
		$name =~ s/_/-/g;
		$vers = gver2Dver($vers, 0);
		$source = "$name-$vers";
		$name = lc $name;
	} else {
		die "Unreadable PF";
	}

	# The following provides a workaround for SLOT management
	if (defined ($tmp = $ENV{'DEB_NAME_SUFFIX'})) {
		chomp $tmp;
		$name .= $tmp;
	}

	return ($name, $vers, $source);
}

# For a given list from which an opening parenthesis has already been 
# popped out, return the index in that list of the corresponding closing
# parenthesis.
sub findClosingParens($) {
	my $listref = shift;
	my $counter = 0; # count number of open parenthesis
	my $index = 0; # index in array
	my $token;
	foreach $token (@{$listref})	{
		$counter++ if ($token eq "(");
		$counter-- if ($token eq ")");
		return $index if ($counter < 0);
		$index++;
	}
	return 0;
}

# $inref is a ref to a gentoo-style list of depends, where a conditional
# ($useflag), and its opening parenthesis, have been popped out. Depending
# on the use set passed as $useref, we will either splice all the conditionned
# deps, or just the closing parenthesis for this conditionnal.
sub doUseCond($$$) {
	my ($inref, $useflag, $useref) = @_;
	my $neg = 0; # inverted use flag, ie !foo?
	my $keep = 0; # keep the conditionnal dep, or not
	my $endcond; # index in @{$inref} of closing parenthesis

	$neg = 1 if ($useflag =~ s/^!//);
	$keep = ($neg xor (grep { /^$useflag$/ } @{$useref}));

	$endcond = findClosingParens($inref);
	return 0 if ($endcond < 0);

	if ($keep) {
		splice @{$inref}, $endcond, 1; # just remove closing parenthesis
	} else {
		splice @{$inref}, 0, ($endcond+1); # remove the whole block
	}
	return 1;
}

sub filterUseConds($$) {
	my ($depref, $useref) = @_;
	my $token;
	my $useflag;
	my @outlist = ();

	while ($token = shift @{$depref}) {
		if ($token =~ /(\S+)\?$/) {
			$useflag = $1;
			shift @{$depref}; # drop opening parenthesis
			doUseCond($depref, $useflag, $useref) 
				or die "doUseCond error on $useflag";
		} else {
			push @outlist, ($token);
		}
	}
	
	return \@outlist;
}

sub getListToken($) {
	my $inref = shift;

	my @token = ();

	return undef if (not defined ${$inref}[0] or ${$inref}[0] eq ")");
	
	my $tok = shift @{$inref};

	# recurse...
	if ($tok eq "||") {
		unshift @{$inref}, $tok;
		$inref = explodeUnions($inref);
		$tok = shift @{$inref};
	}
	# and fall through...
	if (not ($tok eq "(")) {
		push @token, ($tok);
		return \@token;
	}
	my $endcond = findClosingParens($inref);
	push @token, splice @{$inref}, 0, $endcond;
	# pop closing parens
	shift @{$inref};

	return \@token;
}

sub mergeListToks($$) {
	my ($inref, $mergesep) = @_;
	my ($base, $toklist);

	return undef if (not defined ($base = getListToken($inref)));
	
	# Note: We may have a trivial merge (only one sublist), 
	# due to use-filtering
	while (defined ($toklist = getListToken($inref))) {
		my @out = ();
		foreach my $tok1 (@{$base}) {
		foreach my $tok2 (@{$toklist}) {
			push @out, ("$tok1$mergesep$tok2");
		}
		}
		$base = \@out;
	}
	
	return $base;
}

sub explodeUnions($) {
	my $inref = shift;
	my $token;
	my @outlist;

	while ($token = shift @{$inref}) {
			if ($token eq "||") {
				shift @{$inref}; # drop opening parenthesis
				my $endcond = findClosingParens($inref);
				# remove whole union
				my @tmplist = splice @{$inref}, 0, $endcond + 1;
				pop @tmplist;
				my $newlist = mergeListToks(\@tmplist, "|");
				push @outlist, @{$newlist};
			} else {
				push @outlist, ($token);
			}
	}
	return \@outlist;
			
}


sub doMapDeps($$$) {
	my ($inref, $depref, $confref) = @_;
	my $token;
	
	while ($token = shift @{$inref}) {
		if ($token =~ s/^!+//) {
			push @{$confref}, (lc $token);
		} else {
			push @{$depref}, (lc $token);
		}
	}
}

sub mapDeps($$$) {
	my ($fname, $depref, $confref) = @_;
	my $gdepref = getDeps($fname);
	$gdepref = filterUseConds($gdepref, $g_useref);

	my @g_debianizedlist = map {gentoo2Deb($_)} @{$gdepref};
	$gdepref = \@g_debianizedlist;

	$gdepref = explodeUnions($gdepref);
	doMapDeps($gdepref, $depref, $confref);
}

sub mapDepsVar($$$) {
	my ($var, $depref, $confref) = @_;

	my $tmp = $ENV{$var};
	$tmp =~ s/([\(\)])/ $1 /g; 
	$tmp =~ s/[\t\n ]+/ /g;
	$tmp =~ s/^ +//g;
	my @deplist = split / +/, $tmp;
	
	my $gdepref = filterUseConds(\@deplist, $g_useref);

	my @g_debianizedlist = map {s/^\s+//; gentoo2Deb($_)} @{$gdepref};
	$gdepref = \@g_debianizedlist;

	$gdepref = explodeUnions($gdepref);
	doMapDeps($gdepref, $depref, $confref);
}

sub list2Line($$) {
	my ($listref, $format) = @_;

	my $str = join ", ", @{$listref};

	return ($str) ? "\n$format: $str" : "";
}

sub scalar2Line($$) {
	my ($scalar, $format) = @_;

	return ($scalar) ? "\n$format: $scalar" : "";
}

sub printControl($) {
	my $outfile = shift;

	my $depend_line = list2Line(\@g_deplist, "Depends");
	my $recommends_line = list2Line(\@g_recommends, "Recommends");
	my $suggest_line = list2Line(\@g_suggests, "Suggests");
	my $confdeps_line = list2Line(\@g_confdeps, "ConfDepends");
	# Only for source packages
	my $builddepend_line = "";
	my $buildconflict_line = "";
	if (not($g_overlay eq "")) {
	  $builddepend_line = list2Line(\@g_builddeps, "Build-Depends");
	  $buildconflict_line = list2Line(\@g_buildconflist, "Build-Conflicts");
	}
	my $conflict_line = list2Line(\@g_conflist, "Conflicts");
	my $provide_line = list2Line(\@g_provlist, "Provides");
	my $replace_line = list2Line(\@g_replist, "Replaces");

	my $size_line = scalar2Line($g_size, "Installed-Size");
	my $overlay_line = scalar2Line($g_overlay, "Overlay");
	my $distdir_line = scalar2Line($g_distdir, "Distdir");
	my $rel_date_line = "";
	if ($g_section eq "clip-conf") {
		$rel_date_line = scalar2Line($g_date, "Release-Date");
	} 
	my $date_line = scalar2Line($g_date, "Build-Date");
	my $builder_line = scalar2Line($g_builder, "Built-By");
	my $distro_line = scalar2Line($g_distro, "Distribution");
	my $priority_line = scalar2Line($g_priority, "Priority");
	my $urgency_line =scalar2Line($g_urgency, "Urgency");
	my $impact_line = scalar2Line($g_impact, "Impact");
	my $license_line = scalar2Line($g_license, "License");
	my $jails_line = scalar2Line($g_jails, "CLIP-Jails");

	my $essential = "";
	if (defined $ENV{'DEB_ESSENTIAL'}) {
		$essential = "\nEssential: yes";
	}


	open OUT, ">", "$outfile"
		or die "Cannot open $outfile for writing";

	print OUT <<ENDPKG;
Package: $g_name$essential
Source: $g_source
Version: $g_version$priority_line$impact_line$urgency_line$license_line
Section: $g_section
Architecture: $g_arch$depend_line$conflict_line$provide_line$replace_line$recommends_line$suggest_line$builddepend_line$buildconflict_line$confdeps_line
Maintainer: $g_maintainer$size_line$overlay_line$distdir_line$builder_line$date_line$rel_date_line$distro_line$jails_line
Description: $g_desc
ENDPKG

	foreach my $lang (keys %g_descs) {
		print OUT "Description-$lang: $g_descs{$lang}\n"
	}
	foreach my $lang (keys %g_cats) {
		print OUT "Category-$lang: $g_cats{$lang}\n"
	}

	close OUT;
}


