# Database Functions for tracks
#
# $Log$
# Revision 1.1  2005/10/11 08:28:35  tweety
# gpsdrive:
# - add Tracks(MySql) displaying
# - reindent files modified
# - Fix setting of Color for Grid
# - poi Text is different in size depending on Number of POIs shown on
#   screen
#
# geoinfo:
#  - get Proxy settings from Environment
#  - create tracks Table in Database and fill it
#    this separates Street Data from Track Data
#  - make geoinfo.pl download also Opengeodb Version 2
#  - add some poi-types
#  - Split off Filling DB with example Data
#  - extract some more Funtionality to Procedures
#  - Add some Example POI for Kirchheim(Munich) Area
#  - Adjust some Output for what is done at the moment
#  - Add more delayed index generations 'disable/enable key'
#  - If LANG=*de_DE* then only impert europe with --all option
#  - WDB will import more than one country if you wish
#  - add more things to be done with the --all option
#



package Geo::Gpsdrive::DB_tracks;

use strict;
use warnings;

use POSIX qw(strftime);
use Time::Local;
use DBI;
use Data::Dumper;
use IO::File;

use Geo::Gpsdrive::Utils;
use Geo::Gpsdrive::DBFuncs;

$|= 1;                          # Autoflush

BEGIN {
    use Exporter   ();
    our ($VERSION, @ISA, @EXPORT);

    # set the version for version checking for old CVS Version
    # $VERSION = sprintf "%d.%03d", q$Revision: 1190 $ =~ /(\d+)/g;

    @ISA         = qw(Exporter);
    @EXPORT = qw( &track_add
		  &tracks_add
		  );
}


END { } 

sub track_add($);
sub tracks_add($);


#############################################################################
# Add a single track into DB
sub track_add($){
    my $track_segment = shift;
    my $track_segment4db = {};
    my @columns = column_names("tracks");
    map { 
	$track_segment4db->{"tracks.$_"} = 
	    ( $track_segment->{"tracks.$_"} || $track_segment->{$_} || $track_segment->{lc($_)}) 
	} @columns;

    # ---------------------- SOURCE
    #print Dumper(\$track_segment4db);
    # TODO: put this out here for performance reason
    if ( $track_segment4db->{"source.name"} && ! $track_segment4db->{'tracks.source_id'}) {
	my $source_id = source_name2id($track_segment4db->{"source.name"});
	# print "Source: $track_segment4db->{'source.name'} -> $source_id\n";
	
	$track_segment4db->{'source.source_id'} = $source_id;
	$track_segment4db->{'tracks.source_id'}  = $source_id;
    }


    # ---------------------- ADDRESS
    $track_segment4db->{'tracks.address_id'}      ||= 0;

    # ---------------------- TYPE
    $track_segment4db->{'tracks.track_type_id'} ||= 2; # Old Track

    #---------------------- DATE
    $track_segment4db->{'tracks.date'} ||= 0;

    # ---------------------- TRACKS
    $track_segment4db->{'tracks.last_modified'}   ||= time();
    $track_segment4db->{'tracks.scale_min'}       ||= 0;
    $track_segment4db->{'tracks.scale_max'}       ||= 99999999999999;
    insert_hash("tracks",$track_segment4db);
}


#############################################################################
# Add a tracks to geoinfo.tracks 
# this includes splitting and categorizing
# 
sub tracks_add($){
    my $data = shift;

    unless ( 5 < @{$data->{segments}} ){
	print "ERROR: tracks_add(".scalar(@{$data->{segments}})." Segments): Not enough Segments\n"; #. Dumper($data);
	return;
    }	    
    my $wrote_tracks=0;
    my $street_nr=0;
    my $track_segments_in_street=0;

    my $tracks = {};

    my @columns = column_names("tracks");
    map { 
	$tracks->{"tracks.$_"} = 
	    ( $data->{"tracks.$_"} || $data->{$_} || $data->{lc($_)}) 
	} @columns;

    $tracks->{'tracks.track_type_id'} ||= 10;
    #print "tracks_add data:".Dumper(\$data);
    #print "tracks_add init:".Dumper(\$tracks);
    my $track_segment_count = scalar(@{$data->{segments}});
    debug("tracks_add( $track_segment_count Segments )");

    my $max_speed=0;

    my ($lat2,$lon2,$alt2,$time2,$heading2) = (1001.0,1001.0,0,0,-999);
    my $track_segment_number=0;

    my $statistic={};
    my @sub_segment;

    for my $track_segment ( @{$data->{segments}}
			    ,{lat=>1001,lon=>1001,alt=>1001} 
			    ){
	my ($lat1,$lon1,$alt1,$time1,$heading1) =  ($lat2,$lon2,$alt2,$time2,$heading2);

	if ( ref($track_segment) eq "ARRAY" ) {
	    $lat2  = $track_segment->[0];
	    $lon2  = $track_segment->[1];
	    $alt2  = $track_segment->[2];
	    $time2 = $track_segment->[3];
	} else {
	    $lat2  = $track_segment->{'lat'};
	    $lon2  = $track_segment->{'lon'};
	    $alt2  = $track_segment->{'alt'};
	    $time2 = $track_segment->{'time'};
	    $heading2 = $track_segment->{'heading'};
	};

	#debug("$lat2,$lon2,$alt2");
	next unless $track_segment_number++;

	my $valid=0;

	if ( defined $lat1 &&
	     defined $lon1 &&
	     defined $lat2 &&
	     defined $lon2) {
	    $valid=1;
	}

	if ( abs($lat1) > 500 ||
	     abs($lon1) > 500 ||
	     abs($lat2) > 500 ||
	     abs($lon2) > 500 
	     ) {
	    $valid = 0;
	}

	my $speed=0;
	my $dist=0;
	my $time_delta=0;
	my $split="";
	if ( $valid ) {
	    $dist = Geo::Gpsdrive::Gps::earth_distance($lat1,$lon1,$lat2,$lon2);
	    if (defined($time1) && defined($time2) ) {
		my $time_delta = $time2 - $time1;
	    }
	    if ( ref($track_segment) eq "HASH" ) {
		$speed = $track_segment->{speed};
	    }
	    my $calc_speed = ( $time_delta ? ($dist / $time_delta * 3.600) : -1);
	    $speed ||= $calc_speed;
#	    debug(sprintf "Dist: %.4f/%.2f =>  %.2f Km/h",$dist,$time_delta,$speed);

	    if ( $time_delta > 15 ) {
		$split .= "time";
		$valid = 0;
	    }

	    if ( $speed > 200 ) {
		$split .= "speed";
		$valid = 0;
	    }

	    if ( $valid && $speed < 0.001 ) {
		#printf "tracks_add(Seg:$track_segment_number): Low Speed = %.6f;	Dist=%.6f\n",$speed,$dist;
		#$valid = 0;
	    }

	    if ( $valid && $dist > 800  ) {
		$split .= "dist";
		$valid = 0;
	    }

	    if ( $split ) {
		printf "tracks_add(Seg:$track_segment_number): ";
		if ($dist > 1000) {
		    printf "\tdist: %6.2f Km, ",$dist/1000;
		} else {
		    printf "\tdist: %6.2f m, ",$dist;
		}
		printf "\tspeed %6.2f(%6.2f) Km/h ",$speed,$calc_speed;
		printf "\tTime diff = ";
		if ($time_delta > 3600) {
		    printf " %5.2f hours",$time_delta/3600;
		} elsif ( $time_delta > 60 ) {
		    printf " %5.2f min",$time_delta/60;
		} else {
		    printf " %5.2f sec",$time_delta;
		}
		printf "\tsplit: $split\n";
	    }
	} # of if $valid


	if ( $valid ) {
	    $track_segments_in_street++;
	    push( @sub_segment,
	      { 'tracks.lat1' => $lat1,
		'tracks.lon1' => $lon1,
		'tracks.alt1' => $alt1,
		'tracks.lat2' => $lat2,
		'tracks.lon2' => $lon2,
		'tracks.alt2 ' => $alt2
		});
	} else {
	    my $track_segment_count = scalar (@sub_segment);
	    if ( $track_segment_count ) {
		$tracks->{'tracks.comment'} = " $track_segment_count seg\t";

#		$tracks->{'tracks.comment'} .= sprintf( "start: %s\t",scalar localtime($statistic->{time}->{min}));
#		$tracks->{'tracks.comment'} .= sprintf( "end: %s\t",scalar localtime($statistic->{time}->{max}));
		
		for my $segment ( @sub_segment ){
		    my $track_segment4db;
		    (%{$track_segment4db}) = (%{$tracks},%{$segment});
		    #print "tracks: ".Dumper(\%{$tracks});
		    #print "segment: ".Dumper(\%{$segment});
		    #print "track_segment4db: ".Dumper(\%{$track_segment4db});
		    insert_hash("tracks",$track_segment4db);
		}
		#segments_add($tracks);
		$wrote_tracks++;
		$max_speed=0;
	    }
	    $tracks->{segments}=[];
	}
    }
    print "tracks_add wrote $wrote_tracks Sub-Tracks for $track_segment_count Segments\n"
	if $debug;
    
}

1;
