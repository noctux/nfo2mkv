#!/usr/bin/perl
use strict;
use warnings;

# Relevant documentations
# MKV-Tagging:
#   https://www.matroska.org/technical/specs/tagging/index.html
#   https://matroska.org/technical/specs/tagging/example-video.html
#
# MKV Thumbnails:
#   https://www.matroska.org/technical/cover_art/index.html
#
# NFO:
#   https://kodi.wiki/view/NFO_files/TV_shows
#   https://kodi.wiki/view/NFO_files/Movies

# use module
use Data::Dumper;
use File::Temp;
use Getopt::Long;
use Time::Piece;
use XML::Simple;

use autodie qw(:all);

# Subclass XML::Simple to subclass tag-sorting
package MatroskaTagXML;
use base 'XML::Simple';

sub reorder {
	my ($prefix, $keys) = @_;

	my @old = @$keys;
	my @ordered;
	for my $key (@$prefix) {
		if (grep { $_ eq $key} @old) {
			push @ordered, $key;
			@old = grep {$_ ne $key} @old;
		}
	}
	push @ordered, @old;
	return @ordered;
}

sub sorted_keys {
	my ($self, $name, $hashref) = @_;

	if ($name eq "Tag") {
		return reorder(["Targets", "Simple"], [keys %$hashref]);
	} elsif ($name eq "Simple") {
		return reorder(["Name", "String", "Simple"], [keys %$hashref]);
	}

	return $self->SUPER::sorted_keys($name, $hashref);
}

package main;

# Parse arguments
my ($tvshownfo, $episodenfo, $movienfo, $mkvfile, $xmlfile);
my $verbose = '';
GetOptions( "--tvshow=s"  => \$tvshownfo
          , "--episode=s" => \$episodenfo
          , "--movie=s"   => \$movienfo
          , "--mkv=s"     => \$mkvfile
          , "--xml=s"     => \$xmlfile
          , "--verbose!"  => \$verbose
          );

sub parse_nfo {
	my ($filename) = @_;

	# read XML file
	my $xml = new XML::Simple;
	return $xml->XMLin($filename, SuppressEmpty => 1, KeepRoot => 0);
}

sub format_matroska_xml {
	my ($data) = @_;

	# Filter empty items in tags
	my @tags;
	for my $tag (@{$data->{Tag}}) {
		my $target = $tag->{Targets};
		my $simple = $tag->{Simple};
		die "Data misses required element 'Targets'" unless defined $target;
		die "Data misses required element 'Simole'"  unless defined $simple;

		# Only defined tags...
		my @simpleattrs = grep { defined $_ } @$simple;
		# Skip this level if we have no metadata whatsoever
		next unless @simpleattrs;
		# toemit...
		push @tags, { Targets => $target, Simple => \@simpleattrs };
	}

	my $xml = new MatroskaTagXML;
	return $xml->XMLout({Tag => \@tags},
		# Fake a doctype (which we do not really check... but we should be compliant :p)
		XMLDecl => '<?xml version="1.0" encoding="UTF-8"?>' . "\n" . '<!DOCTYPE Tags SYSTEM "matroskatags.dtd">',
		NoAttr => 1,        # Emit everything as xml tags, Matroska knows no xml attributes
		KeepRoot => 0,
		RootName => 'Tags', # Rename the root element
	);
}

sub spew {
	my ($filename, $data) = @_;

	open (my $fh, ">", $filename)
		or die "Failed to open file '$filename' for writing";
	print $fh $data or die "Writing data to file '$filename' failed";
	close($fh);

	return $filename;
}

sub make_string_tag {
	my ($type, $value) = @_;

	if ($value && "" eq ref $value) { # Plain scalar
		return ({ Name => $type, String => $value});
	} elsif  ("ARRAY"  eq ref $value && @$value) {
			return (map { make_string_tag($type, $_) } @{$value});
	} elsif(ref $value) { # Everything except undef
		die "make_string_tag: Unsupported reference type @{[ref $value]}";
	}

	return;
}

sub make_actor_tags {
	my ($actors) = @_;

	my @actortags;

	for my $actor (sort keys %$actors){
		my $tag = make_string_tag("ACTOR", $actor);
		my $role = $actors->{$actor}->{role};
		if ($role) {
			my $rtag = make_string_tag("CHARACTER", $role);
			$tag->{Simple} = $rtag;
		}
		push @actortags, $tag;
	}

	return @actortags;
}

# To support:
#  - Collection: (level 70)
#    TITLE    -> tvshow:<showtitle>|episode:<showtitle>
#    SUMMARY  -> tvshow:<plot>
#    [GENRE]  -> tvshow:<genre>
#    LAW_RATING -> tvshow:<mpaa>
#  - Season: (level 60)
#    PART_NUMBER -> <season>
#    (TOTAL_PARTS)
#    PRODUCTION_STUDIO -> <studio>
#  - Tag: (level 50)
#    TITLE     -> <title>
#    ORIGINAL_TITLE -> <originaltitle>
#    DATE_RELEASED -> <aired>|<premiered>
#    SUMMARY   -> <outline>|<plot>
#    PART_NUMBER -> <episode>
#    (TOTAL_PARTS)
#    DIRECTOR -> <director>
#    WRITTEN_BY -> <credits>
#    [ACTOR{CHARACTER}] -> <actor><name>|<actor><role>
#    PRODUCTION_STUDIO -> <studio>
#    LAW_RATING -> <mpaa>
sub handle_episode {
	my ($episodenfo, $shownfo) = @_;

	my $episodemeta = parse_nfo($episodenfo);
	my $showmeta = $shownfo ? parse_nfo($shownfo) : {};

	print "Parsed show metadata:\n" . Dumper($showmeta) . "\n"       if $verbose;
	print "Parsed episode metadata:\n" . Dumper($episodemeta) . "\n" if $verbose;

	# Sometimes, roles are tagged for the show, but not for the episodes
	for my $name (keys %{$episodemeta->{actor}}) {
		my $data     = $episodemeta->{actor}->{$name};
		my $showdata = $showmeta->{actor}->{$name};
		# So transfer them...
		if (!$data->{role} && $showdata->{role}) {
			$data->{role} = $showdata->{role};
		}
	}

	my %tags = (Tag => [
		{
			Targets => {
				# COLLECTION
				TargetTypeValue => 70
			},
			Simple => [
				make_string_tag("TITLE",      $showmeta->{showtitle} || $episodemeta->{showtitle}),
				make_string_tag("SUMMARY",    $showmeta->{plot}),
				make_string_tag("GENRE",      $showmeta->{genre}),
				make_actor_tags($showmeta->{actor}),
				make_string_tag("LAW_RATING", $showmeta->{mpaa}),
			]
		},{
			Targets => {
				# SEASON
				TargetTypeValue => 60
			},
			Simple => [
				make_string_tag("PART_NUMBER",       $episodemeta->{season}),
				make_string_tag("PRODUCTION_STUDIO", $episodemeta->{studio}),
			]
		},{
			Targets => {
				# EPISODE
				TargetTypeValue => 50
			},
			Simple => [
				make_string_tag("PART_NUMBER",       $episodemeta->{episode}),
				make_string_tag("TITLE",             $episodemeta->{title}),
				make_string_tag("ORIGINAL_TITLE",    $episodemeta->{originaltitle}),
				make_string_tag("SUMMARY",           $episodemeta->{plot} || $episodemeta->{outline}),
				make_string_tag("SYNOPSIS",          $episodemeta->{outline} || $episodemeta->{plot}),
				make_string_tag("DATE_RELEASED",     $episodemeta->{aired} || $episodemeta->{premiered}),
				make_string_tag("DIRECTOR",          $episodemeta->{director}),
				make_string_tag("WRITTEN_BY",        $episodemeta->{credits}),
				make_actor_tags($episodemeta->{actor}),
				make_string_tag("PRODUCTION_STUDIO", $episodemeta->{studio} || $showmeta->{studio}),
				make_string_tag("LAW_RATING",        $episodemeta->{mpaa} || $showmeta->{mpaa}),
				make_string_tag("DATE_TAGGED",       localtime->strftime('%Y-%m-%d')),
			]
		}
	]);

	print "Tag's perl datastructure:\n" . Dumper(\%tags) . "\n" if $verbose;

	return \%tags;
}


# To support:
#  - Collection: (level 70)
#    TITLE -> <set><name> if present
#  - Tag: (level 50)
#    TITLE     -> <title>
#    ORIGINAL_TITLE -> <originaltitle>
#    DATE_RELEASED -> <premiered>|<aired>
#    SUMMARY   -> <plot>|<outline>
#    [GENRE]  -> <genre>
#    SYNOPSIS  -> <outline>|<plot>
#    PART_NUMBER -> ?
#    (TOTAL_PARTS)
#    DIRECTOR -> <director>
#    WRITTEN_BY -> <credits>
#    [ACTOR{CHARACTER}] -> <actor><name>|<actor><role>
#    PRODUCTION_STUDIO -> <studio>
#    LAW_RATING -> <mpaa>
sub handle_movie {
	my ($movienfo) = @_;

	my $moviemeta = parse_nfo($movienfo);

	print "Parsed movie metadata:\n" . Dumper($showmeta) . "\n"       if $verbose;

	my %tags = (Tag => [
		{
			Targets => {
				# COLLECTION
				TargetTypeValue => 70
			},
			Simple => [
				make_string_tag("TITLE",      ($moviemeta->{set} // {})->{name}),
			]
		},{
			Targets => {
				# Movie
				TargetTypeValue => 50
			},
			Simple => [
				make_string_tag("TITLE",             $moviemeta->{title}),
				make_string_tag("ORIGINAL_TITLE",    $moviemeta->{originaltitle}),
				make_string_tag("SUMMARY",           $moviemeta->{plot} || $moviemeta->{outline}),
				make_string_tag("SYNOPSIS",          $moviemeta->{outline} || $moviemeta->{plot}),
				make_string_tag("DATE_RELEASED",     $moviemeta->{premiered}) || $moviemeta->{aired},
				make_string_tag("DIRECTOR",          $moviemeta->{director}),
				make_string_tag("WRITTEN_BY",        $moviemeta->{credits}),
				make_actor_tags($moviemeta->{actor}),
				make_string_tag("GENRE",             $moviemeta->{genre}),
				make_string_tag("PRODUCTION_STUDIO", $moviemeta->{studio}),
				make_string_tag("LAW_RATING",        $moviemeta->{mpaa}),
				make_string_tag("DATE_TAGGED",       localtime->strftime('%Y-%m-%d')),
			]
		}
	]);

	print "Tag's perl datastructure:\n" . Dumper(\%tags) . "\n" if $verbose;

	return \%tags;
}

sub apply_tags_to_file {
	my ($mkvfile, $tagsfile) = @_;

	system ("mkvpropedit", $mkvfile, "--tags", "all:$tagsfile") == 0
	   	or die "Mkvpropedit failed: $?";
}

sub main {
	my $tags = handle_episode($episodenfo, $tvshownfo);
	my $xmldata = format_matroska_xml($tags);
	print "Formatted XML data:\n" . $xmldata . "\n" if $verbose;

	# Output the xml file, use temporary file if we only have to interact
	# with mkvtoolnix
	my $outfile = $xmlfile || File::Temp->new();
	spew($outfile, $xmldata);

	if ($mkvfile) {
		apply_tags_to_file($mkvfile, $outfile);
	}
}

main();

# TODO: Handle movie nfos
#       record uniqueid fields (tvdb, imdb, ...)
#       write xml
#       apply to mkv with mkvtoolnix
#       coverimage: --attachment-name "cover" --attachment-mime-type "image/jpeg" --add-attachment "%%~nf.jpg"
#
#
#https://www.matroska.org/technical/cover_art/index.html
#
#       The pictures should only use the JPEG and PNG picture formats.
#
# There can be 2 different cover for a movie/album. A portrait one (like a DVD case) and a landscape one (like a banner ad for example, looking better on a wide screen).
#
# There can be 2 versions of the same cover, the normal one and the small one. The dimension of the normal one should be 600 on the smallest side (eg 960x600 for landscape and 600x800 for portrait, 600x600 for square). The dimension of the small one should be 120 (192x120 or 120x160).
#
# The way to differentiate between all these versions is by the filename. The default filename is cover.(png/jpg) for backward compatibility reasons. That is the "big" version of the file (600) in square or portrait mode. It should also be the first file in the attachments. The smaller resolution should be prefixed with "small_", ie small_cover.(jpg/png). The landscape variant should be suffixed with "_land", ie cover_land.jpg. The filenames are case sensitive and should all be lower case.
#
# In the end a file could contain these 4 basic cover art files:
# cover.jpg (portrait/square 600)
# small_cover.png (portrait/square 120)
# cover_land.png (landscape 600)
# small_cover_land.jpg (landscape 120)