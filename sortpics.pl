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
require 5.010.000;

################################################################################
# MODULES
################################################################################
use Date::Manip qw( ParseDate UnixDate );
use Digest::SHA;
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
my $DatePathString = "%Y/%m/%Y-%m-%d";
# List of filename patterns to outright delete.  I've found deleting these to be
# benign.
my @FileNamePatterns = (
   qr/NIKON.*\.DSC/, 
   'Thumbs.db',
   '.picasa.ini',
   'ZbThumbnail.info',
);

my ($Cleanup, $Copy, $Debug, $DryRun, $Force, $Help, $Man, $Move, $Recursive, $Verbose);

# Process commandline arguments.
GetOptions (
   'c|copy'       => \$Copy,
   'C|cleanup'    => \$Cleanup,
   'd|debug+'     => sub { $Debug++; $Verbose++; },
   'D|dryrun'     => \$DryRun,
   'f|force'      => \$Force,
   'h|help'       => \$Help,
   'M|man'        => \$Man,
   'm|move'       => \$Move,
   'r|recursive'  => \$Recursive,
   'v|verbose+'   => \$Verbose,
) or pod2usage( 2 );

pod2usage( 1 ) if $Help;
pod2usage( { -verbose => 2 } ) if $Man;
pod2usage( -message => "$0: Must specify a source and destination directory.\n" ) if $#ARGV < 1;

# The last directory is our target.
my $DestPath = pop @ARGV;
$DestPath = File::Spec->rel2abs( $DestPath ) ;
# The remaining are our source directories.
my @SrcDirs = @ARGV;


die "Destination directory \'$DestPath\' does not exist or is not writable.\n" unless (-d $DestPath && -w $DestPath);
foreach my $SrcDir (@SrcDirs) {
   $SrcDir = File::Spec->rel2abs( $SrcDir ) ;
   die "Source directory \'$SrcDir\' doesn't exist or is not readable.\n" unless (-d $SrcDir && -r $SrcDir);
}


if ($Recursive) {
   finddepth( \&Process, @SrcDirs );
}
# Use &Preprocess to limit our depth.
else {
   finddepth( { preprocess => \&PreProcess, wanted => \&Process }, @SrcDirs );
}

sub PreProcess {
   # Return just files if not recursive.
   return grep { not -d } @_;
}

sub Process {
   my $FilePath = $File::Find::dir;
   #my $FilePath = File::Spec->rel2abs( $Dir ) ;
   my $FileAbs = $File::Find::name;
   #my $FileAbs = File::Spec->rel2abs( $Path ) ;
   my $FileName = $_;
   #if ($Debug) { print "$Dir | $Path | $FileName\n"; }
   if ($Debug) { print "$FilePath | $FileAbs | $FileName\n"; }
   
   # Only work on files.
   if (-f $FileAbs) {
      if ($Cleanup) {
         # Remove the file if it matches the list of patterns using smart match.
         if ($FileName ~~ @FileNamePatterns) {
            if ($Verbose) { print "Deleting $FileName\n"; }
            unless ($DryRun) { unlink $FileAbs; }
            next;
         }
      }
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
            #$ImgDate = Date::Manip::ParseDate( $Info->{'CreateDate'} );
            $ImgDate = ParseDate( $Info->{'CreateDate'} );
         }
         # Not able to read date from metadata.
         else {
            # Getting the mtime is not working...
            #$ImgDate = ${stat $FileAbs}[9];
            #print "Mtime = $ImgDate\n";
            # So the safest thing is to just skip the file for now.
            if ($Verbose) { 
               print "$FileName: Unable to read date from metadata, skipping file.\n";
            }
            next;
         }
         
         my $Make = $Info->{'Make'} if $Info->{'Make'};
         # Captialize the first letter of each word.
         $Make =~ s/([\w']+)/\u\L$1/g;
         my $Model = $Info->{'Model'} if $Info->{'Model'};
         # Captialize the first letter of each word.
         $Model =~ s/([\w']+)/\u\L$1/g;
         # Remove any spaces.
         $Model =~ s/ //g;
         my $FileAppendString;
         # If the Model information already contains Make
         if ($Model =~ /^$Make/) {
            # Just use Model.
            $FileAppendString = $Model;
         }
         else {
            # Otherwise concatenate Make and Model.
            $FileAppendString = $Make . $Model;
         }
         
         # Reformat the date into the date/time string we want.
         my $DateFile = UnixDate( $ImgDate, $DateFileString );
         my $DatePath = UnixDate( $ImgDate, $DatePathString );
         my ($Junk, $File, $Ext) = fileparse( $FileName, qr/\.[^.]*/ );
         my $NewDestPath = File::Spec->catdir( $DestPath, $DatePath );
         my $NewFileName = $DateFile . '_' . $FileAppendString . lc( $Ext );
         my $NewFileAbs = File::Spec->catfile( $NewDestPath, $NewFileName );
         
         # Make sure the destination file doesn't exist.
         if (-f $NewFileAbs) {
            # Setup a file handler for the current file.
            open( SRCFILE, "$FileAbs" ) or die "Can't open $FileAbs: $!";
            open( DESTFILE, "$NewFileAbs" ) or die "Can't open $NewFileAbs: $!";
            # Use binary mode to cope with all file types.
            binmode( SRCFILE );
            binmode( DESTFILE );
            # Generate the checksum
            my $SrcSHA1 = Digest::SHA->new(1)->addfile( *SRCFILE )->hexdigest;
            my $DestSHA1 = Digest::SHA->new(1)->addfile( *DESTFILE )->hexdigest;
            # No need for the file handler anymore.
            close( SRCFILE );
            close( DESTFILE );
            if ($SrcSHA1 eq $DestSHA1) {
               if ($Force) {
                  unlink $SrcSHA1;
               }
               elsif ($Verbose) {
                  print "$FileName: Destination file already exists, skipping.\n";
               }
            }
         }
         # It doesn't, so continue.
         else {
            # Unless this is a dry run..
            unless ($DryRun) {
               unless (-w $NewDestPath) {
                  File::Path::make_path( $NewDestPath, {error => \my $Err} );
                  if (@$Err) {
                     foreach my $Diag (@$Err) {
                        my ($File, $Message) = %$Diag;
                        print "Error making path $NewDestPath: $Message\n";
                     }
                     die;
                  }
               }
            }
            if ($Move) {
               if ($Verbose) { print "Moving $FileName -> $NewFileAbs\n"; }
               unless ($DryRun) { move( $FileAbs, $NewFileAbs ); }
            }
            else {
               if ($Verbose) { print "Copying $FileName -> $NewFileAbs\n"; }
               unless ($DryRun) { copy( $FileAbs, $NewFileAbs ); }
            }
         }
      }
      else {
         if ($Verbose) { print "$FileName: File type is not supported, skipping.\n"; }
      }
   } #End -f $FileAbs
   # Otherwise if this is a directory.
   elsif (-d $FileAbs) {
      # If we were told to cleanup.
      if ($Cleanup && not $DryRun) {
         my $Rc = rmdir( $FileAbs );
         if ($Verbose) {
            if ($Rc) {
               print "Removing $FileAbs\n";
            }
            else {
               print "Unable to remove $FileAbs: $!\n";
            }
         }
      }
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
