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
#use feature 'fc';

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

#BEGIN {
#    if ($] < 5.016) {
#        require Unicode::CaseFold;
#    }
#}

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
   'Picasa.ini',
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

# Counts number of images processed
my %Counter = (
   'skip'  => 0,
   'copy'  => 0,
   'dupe'  => 0,
);

# Use &Preprocess to sort and optionally limit our depth.
finddepth( { preprocess => \&PreProcess, wanted => \&Process }, @SrcDirs );

sub PreProcess {
   if ($Recursive) {
     # Return the list sorted.
     return sort @_;
   }
   else {
     # Return just sorted files if not recursive.
     return sort( grep { not -d } @_ );
   }
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
            if ($Verbose) { print "Deleting $FileAbs\n"; }
            unless ($DryRun) { unlink $FileAbs or print "$FileAbs: Unable to delete: $!\n"; }
            next;
         }
      }
      # Check if the file type is supported by ExifTool.
      my $Supported = Image::ExifTool::GetFileType( $FileAbs );
      if ($Supported) {
         if ($Debug) { print "$FileAbs: $Supported\n"; }
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
               print "$FileAbs: Unable to read date from metadata, skipping.\n";
            }
            next;
         }
         
         my $Make = $Info->{'Make'} if $Info->{'Make'};
         # Captialize the first letter of each word.
         $Make =~ s/([\w']+)/\u\L$1/g;
         # Remove any spaces.
         $Make =~ s/ //g;
         # Adjust 'LgElectonrics' to just 'Lg'
         if ($Make =~ /^Lg/ ) {
             $Make = 'Lg';
         }

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
         $Ext = lc $Ext;
         my $NewDestPath = File::Spec->catdir( $DestPath, $DatePath );
         my $NewFileName = $DateFile . '_' . $FileAppendString;
         my $NewFileAbs = File::Spec->catfile( $NewDestPath, $NewFileName.$Ext );
         
         # Make sure the destination file doesn't exist.
         my $Dupe = 0;
         if (-f $NewFileAbs) {
            # It does so we use SHA1 hashes to identify if the files are the same
            
            # Generate the SHA1 hash for the source file.
            open( SRCFILE, "$FileAbs" ) or die "Can't open $FileAbs: $!";
            binmode( SRCFILE );
            my $SrcSHA1 = Digest::SHA->new(1)->addfile( *SRCFILE )->hexdigest;
            close( SRCFILE );
            
            # Loop on the new filename when we test the hashes so we can increment
            # the filename at the end until we find a filename that doesn't exist.
            my $Count = 0;
            while (-f $NewFileAbs) {
               # Generate the SHA1 hash for the source file.
               open( DESTFILE, "$NewFileAbs" ) or die "Can't open $NewFileAbs: $!";
               binmode( DESTFILE );
               my $DestSHA1 = Digest::SHA->new(1)->addfile( *DESTFILE )->hexdigest;
               close( DESTFILE );

               # If the SHA1 hashes match
               if ($SrcSHA1 eq $DestSHA1) {
                  # Files have identical content!

                  if ($Debug) { print "$FileAbs: $SrcSHA1\n$NewFileAbs: $DestSHA1\n"; }
                  # If we're told to force cleanup.
                  if ($Force) {
                     if ($Verbose) {
                        print "$FileAbs: Destination file already exists; deletion forced.\n";
                     }
                     # Delete the file.
                     unlink $FileAbs or print "$FileAbs: Unable to delte: $!\n";
                  }
                  # Otherwise if we're being chatty, inform the user we're
                  # leaving the file be..
                  elsif ($Verbose) {
                     print "$FileAbs: Destination file already exists, skipping.\n";
                  }
                  $Dupe = 1;
                  # Jump out of the while loop.
                  last;
               }
               
               # If forced, increment the filename.  Lather, rinse, repeat.
               if ($Force) {
                  $Count++;
                  $NewFileAbs = File::Spec->catfile(
                     $NewDestPath,
                     $NewFileName . '_' . $Count . $Ext
                  );
               }
               # Otherwise the safer thing is to leave it be to let a human
               # deal with it.
               else {
                  $Skip = 1;
                  # Jump out of the while loop.
                  last;
               }
            }
         }

         # If we found a duplicate file,
         if ($Dupe) {
           # Increment the counter.
           $Counter{'dupe'}++;
           # And jump to the next source file.
           next;
         }
         # If we found a file with the same name,
         if ($Skip) {
           # Increment the counter.
           $Counter{'skip'}++;
           # And jump to the next source file.
           next;
         }

         # At this point we are ready to actually process the source file!

         # Unless this is a dry run..
         unless ($DryRun) {
            # Unless the destination path exists.
            unless (-w $NewDestPath) {
               # Make the path in one fell swoop.
               File::Path::make_path( $NewDestPath, {error => \my $Err} );
               # If that had a problem, inform the user and die.
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

      } # END if ($Supported)

      else {
         if ($Verbose) { print "$FileName: File type is not supported, skipping.\n"; }
      }

   } #END if (-f $FileAbs)

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

   if ($Debug) { print "\n"; }

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
