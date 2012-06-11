#!/usr/bin/env perl
################################################################################
#
# exifsort.pl - exifsort@stalks.nooblet.org [2007.11.12]
# - Based on a concept by Lars Strand
#
# I've added
#   date/time checking
#   folder sorting, with folder creation,
#   md5 checksum comparision
#   Structured display output with useful statistics
#
################################################################################
use strict;


################################################################################
# MODULES
################################################################################
use Date::Manip;
use Digest::MD5;
use File::Glob qw( :globally :nocase );
use File::Basename;
use File::Copy;
use File::Find;
use File::Path;
use File::Spec;
use File::stat;
use Getopt::Long qw( :config bundling pass_through );
use Image::ExifTool;
use Pod::Usage;


################################################################################
# MAIN
################################################################################

# The date string we will use to rename the files.
my $DateFileString = "%Y%m%d-%H%M%S";
# The date string we will use to build the directories under the dest dir.
my $DatePathString = "%Y/%m";

my ($Debug, $Help, $Man, $Recursive, $Verbose);

# Process commandline arguments.
GetOptions (
   'd|debug+'     => sub { $Debug++; $Verbose++; },
   'h|help'       => \$Help,
   'm|man'        => \$Man,
   'r|recursive'  => \$Recursive,
   'v|verbose+'   => \$Verbose,
) or pod2usage( 2 );

pod2usage( 1 ) if $Help;
pod2usage( -message => "$0: Must specify a source and destination directory.\n" ) if $#ARGV < 1;

# The last directory is our target.
my $DestPath = pop @ARGV;
# The remaining are our source directories.
my @SrcDirs = @ARGV;


die "Destination directory \'$DestPath\' does not exist or is not writable.\n" unless (-d $DestPath && -w $DestPath);
foreach my $SrcDir (@SrcDirs) {
   die "Source directory \'$SrcDir\' doesn't exist or is not readable.\n" unless (-d $SrcDir && -r $SrcDir);
}


if ($Recursive) {
   finddepth( \&Process, @SrcDirs );
}
# Use &Preprocess to limit our depth.
else {
   find( { preprocess => \&PreProcess, wanted => \&Process }, @SrcDirs );
}

sub PreProcess {
   # Return just files if not recursive.
   return grep { not -d } @_;
}

sub Process {
   my $FilePath = $File::Find::dir;
   my $FileAbs = $File::Find::name;
   my $FileName = $_;
   
   # Only work on files.
   if (-f $FileAbs) {
      if ($Debug) { print "$FilePath | $FileAbs | $FileName\n"; }
      # Check if the file type is supported by ExifTool.
      my $Supported = Image::ExifTool::GetFileType( $FileAbs );
      if ($Supported) {
         if ($Debug) { print "$FileName: $Supported\n"; }
         # Read all of the metadata from the file.
         my $Info = Image::ExifTool::ImageInfo( $FileAbs );
         #foreach my $Key (sort {$a <=> $b} keys %$Info) {
         #   print "$FileName: $Key -> " . $Info->{$Key} . "\n";
         #}
         #print "$FileName: create date = " . $Info->{'CreateDate'} . "\n";
         my $ImgDate;
         # If CreateDate is in the metadata.
         if ($Info->{'CreateDate'}) {
            # Parse it.
            $ImgDate = Date::Manip::ParseDate( $Info->{'CreateDate'} );
         }
         # Not able to read date from metadata.
         else {
            # Getting the mtime is not working...
            #$ImgDate = ${stat $FileAbs}[9];
            #print "Mtime = $ImgDate\n";
            # So the safest thing is to just skip the file for now.
            if ($Verbose) { 
               print "Unable to read date from metadata, skipping file.\n";
            }
            next;
         }
         # Reformat the date into the date/time string we want.
         my $DateFile = Date::Manip::UnixDate( $ImgDate, $DateFileString );
         my $DatePath = Date::Manip::UnixDate( $ImgDate, $DatePathString );
         my ($Junk, $File, $Ext) = fileparse( $FileName, qr/\.[^.]*/ );
         print "$DestPath\n";
         my $NewFileAbs = $DestPath . $DatePath . '/' . $DateFile . $Ext;
                  
         print "$FileName -> $NewFileAbs\n";
      }
      else {
         if ($Verbose) { print "$FileName: File type is not supported.\n"; }
      }
      print "----------------------\n";
   }
}

__END__

=head1 NAME

sortpics.pl - Uses EXIF information to sort pics from SRC directories to DEST directory.

=head1 SYNOPSIS

sortpics.pl [options] SRC [SRC ...] DEST

 Options:
   -d, --debug       Enable debug output
   -h, --help        Brief help message
   -m, --man         Prints a man page.
   -v, --verbose     Enable more output

=head1 OPTIONS

=over 8

=item B<-d, --debug>

Enable debug output.  This causes more information to be outputted which may
be useful in debugging the script.

=item B<-h, --help>

Print a brief help message and exits.

=item B<-v, --verbose>

Enable verbose output.  This causes more information to be outputted which may
be useful in debugging the metadata.

=back

=head1 DESCRIPTION

B<sortpics.pl> will recursivley transverse the directories.

=cut
