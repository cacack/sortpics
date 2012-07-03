#!/usr/bin/env perl
################################################################################
# sortpics.pl - Sort pictures using EXIF metadata information.
# 
# Written by Chris Clonch <chris@theclonchs.com>.  See man page using -M, --man
# for copyright and license notice.
# vim: set ts=3 sw=3 expandtab:
################################################################################
use strict;
require 5.010.000;


################################################################################
# MODULES
################################################################################
use Date::Manip qw( ParseDate UnixDate );
use Digest::SHA;
use File::Basename;
use File::Copy;
use File::Find;
use File::Path;
use File::Spec;
use File::Temp;
use Getopt::Long qw( :config bundling pass_through );
use Image::ExifTool;
use Pod::Usage;


################################################################################
# MAIN
################################################################################

#-------------------------------------------------------------------------------
# Items worth adjusting for your needs...
#-------------------------------------------------------------------------------

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

#-------------------------------------------------------------------------------
# Commandline args
#-------------------------------------------------------------------------------
my (
   $Cleanup, $Copy, $Debug, $Delta, $DryRun, $Force, $Help, $Logic, $Man, $Move,
   $Recursive, $Verbose,
);

# Process commandline arguments.
GetOptions (
   'c|copy'       => \$Copy,
   'C|cleanup'    => \$Cleanup,
   'd|debug+'     => sub { $Debug++; $Verbose++; },
   'delta=s'      => \$Delta,
   'D|dry-run'    => \$DryRun,
   'f|force'      => \$Force,
   'h|help'       => \$Help,
   'l|logic=i'    => \$Logic,
   'M|man'        => \$Man,
   'm|move'       => \$Move,
   'r|recursive'  => \$Recursive,
   'v|verbose+'   => \$Verbose,
) or pod2usage( -verbose => 0, -exitval => 1 );

pod2usage( -verbose => 0, -exitval => 0 ) if $Help;
pod2usage( -verbose => 2, -exitval => 0 ) if $Man;
if ($#ARGV < 1) {
   pod2usage(
      -message => "$0: Must specify a source and destination directory.\n",
      -verbose => 0,
      -exitval => 1,
   );
}

# The last directory is our target.
my $DestBase = pop @ARGV;
$DestBase = File::Spec->rel2abs( $DestBase ) ;
# The remaining are our source directories.
my @Sources = @ARGV;

# Destination directory must be a directory and writable.
unless (-d $DestBase && -w $DestBase) {
   die "Destination directory \'$DestBase\' does not exist or is not writable.\n";
}
# Make sure each source is either a file or directory and is readable.
foreach my $Source (@Sources) {
   $Source = File::Spec->rel2abs( $Source ) ;
   if (-d $Source || -f $Source) {
      if (not -r $Source) {
         die "Source \'$Source\' doesn't exist or is not readable.\n";
      }
   }
   else {
      die "Source \'$Source\' must be a directory or file.\n";
   }
}

#-------------------------------------------------------------------------------
# The real main bits.
#-------------------------------------------------------------------------------
# Record counts of files we process.
my %Counts = (
   'copy'   => 0,
   'dupe'   => 0,
   'skip'   => 0,
   'total'  => 0,
);

# Use &Preprocess to sort and optionally limit our depth.
finddepth( { preprocess => \&PreProcess, wanted => \&Process }, @Sources );

if ($Verbose && $Counts{'total'}) {
   print "\n-----\n";
   print " skipped ......: $Counts{'skip'}\n";
   print " duplicates ...: $Counts{'dupe'}\n";
   print " copied/moved .: $Counts{'copy'}\n";
   print "====================\n";
   print " TOTAL ........: $Counts{'total'}\n";
}


################################################################################
# SUBROUTINES
################################################################################

#-------------------------------------------------------------------------------
# Subroutine: PreProcess
#-------------------------------------------------------------------------------
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


#-------------------------------------------------------------------------------
# Subroutine: Process
#-------------------------------------------------------------------------------
sub Process {
   my $SrcFilePath   = $File::Find::dir;
   my $SrcFileAbs    = $File::Find::name;
   my $SrcFileName   = $_;
   if ($Debug) { print "$SrcFilePath | $SrcFileAbs | $SrcFileName\n"; }
   
   # Only work on files.
   if (-f $SrcFileAbs) {
      if ($Cleanup) {
         # Remove the file if it matches the list of patterns using smart match.
         if ($SrcFileName ~~ @FileNamePatterns) {
            if ($Verbose) { print "Deleting $SrcFileAbs\n"; }
            unless ($DryRun) {
               unlink $SrcFileAbs or print "$SrcFileAbs: Unable to delete: $!\n";
            }
            next;
         }
      }
      # Check if the file type is supported by ExifTool.
      my $Supported = Image::ExifTool::GetFileType( $SrcFileAbs );
      if ($Supported) {
         $Counts{'total'}++;
         if ($Debug) { print "$SrcFileAbs: $Supported\n"; }
         # Create a new Image::ExifTool object.
         my $ImgData = new Image::ExifTool;
         # Extract all of the tags from the file.
         $ImgData->ExtractInfo( $SrcFileAbs );
         # Read all of the metadata.
         my $Info = $ImgData->GetInfo( );
         # Output all of the metadata if -dd
         if ($Debug > 1) {
            foreach my $Key (sort keys %$Info) {
               print "$SrcFileName: $Key -> " . $Info->{$Key} . "\n";
            }
         }
         
         #----------------------------------------------------------------------
         # Parse metadata
         #----------------------------------------------------------------------
         my ($ImgDate, $DateTag);
         my $SubSec = 0;
         # Check for metadata 
         if ($Info->{'DateTimeOriginal'}) {
            # Parse it.
            $ImgDate = Date::Manip::ParseDate( $Info->{'DateTimeOriginal'} );
            # Parse subsec timing if its there.
            # Parse subsec timing if its there.
            if ($Info->{'SubSecTime'}) {
               $SubSec = $Info->{'SubSecTime'};
            }
            elsif ($Info->{'SubSecTimeOriginal'}) {
               $SubSec = $Info->{'SubSecTimeOriginal'};
            }
            elsif ($Info->{'SubSecDigitized'}) {
               $SubSec = $Info->{'SubSecDigitized'};
            }
         }
         elsif ($Info->{'DateTimeDigitized'}) {
            # Parse it.
            $ImgDate = Date::Manip::ParseDate( $Info->{'DateTimeDigitized'} );
            # Parse subsec timing if its there.
            if ($Info->{'SubSecTime'}) {
               $SubSec = $Info->{'SubSecTime'};
            }
            elsif ($Info->{'SubSecTimeOriginal'}) {
               $SubSec = $Info->{'SubSecTimeOriginal'};
            }
            elsif ($Info->{'SubSecDigitized'}) {
               $SubSec = $Info->{'SubSecDigitized'};
            }
         }
         # If CreateDate is in the metadata.
         elsif ($Info->{'CreateDate'}) {
            # Parse it.
            $ImgDate = Date::Manip::ParseDate( $Info->{'CreateDate'} );
            # Parse subsec timing if its there.
            if ($Info->{'SubSecTime'}) {
               $SubSec = $Info->{'SubSecTime'};
            }
            elsif ($Info->{'SubSecTimeOriginal'}) {
               $SubSec = $Info->{'SubSecTimeOriginal'};
            }
            elsif ($Info->{'SubSecDigitized'}) {
               $SubSec = $Info->{'SubSecDigitized'};
            }
         }
         
         #----------------------------------------------------------------------
         # Advanced date/time parsing logic
         #----------------------------------------------------------------------
         elsif ($Logic > 0) {
            # Start by examining parent folder for valid date.
            # Separate everything into its pieces.
            my ($Vol, $Path, $File) = File::Spec->splitpath( $SrcFileAbs );
            my @Dirs = File::Spec->splitdir( $Path );
            # Start with the current directory and work our way up.
            foreach my $Dir (reverse @Dirs) {
               # Cleanup the directory a bit.
               $Dir =~ s/_//g;
               $Dir =~ s/-//g;
               $Dir =~ s/ //g;
               # Parse it
               $ImgDate = Date::Manip::ParseDate( $Dir );
               if ($ImgDate) {
                  # If we found a date jump out of the loop.
                  last;
               }
            }
            # Now test the date.
            if ($ImgDate) {
               # This should test how complete the date we found is.
               # Date::Manip::Date::complete looks promising.
            }
            else {
               warn "$SrcFileAbs: Unable to determine date from directory, skipping.\n";
               if ($Debug) { print "Date = $ImgDate\n"; }
               next;
            }
         }
         elsif ($Logic > 1) {
            # Then check the file's mtime for valid date.
            my $Mtime = ${stat $SrcFileAbs}[9];
            $ImgDate = Date::Manip::ParseDateString( "epoch $Mtime" );
            if ($ImgDate) {
               
               # If we found a date jump out of the loop.
               last;
            }
         }   
         # Not able to read date from metadata.
         else {
            # So the safest thing is to just skip the file for now.
            if ($Verbose) { 
               print "$SrcFileAbs: Unable to read date from metadata, skipping.\n";
            }
            $Counts{'skip'}++;
            next;
         }
         
         #----------------------------------------------------------------------
         # Parse make/model metadata
         #----------------------------------------------------------------------
         my $Make = $Info->{'Make'} if $Info->{'Make'};
         # Capitalize the first letter of each word.
         $Make =~ s/([\w']+)/\u\L$1/g;
         # Remove any spaces.
         $Make =~ s/ //g;
         # Adjust 'LgElectonrics' to just 'Lg'
         if ($Make =~ /^Lg/ ) {
             $Make = 'Lg';
         }
         # Adjust 'ResearchInMotion' to just 'RIM'
         if ($Make =~ /^ResearchInMotion/ ) {
             $Make = 'RIM';
         }
         # Adjust 'Nikon*' to just 'Nikon'
         if ($Make =~ /^Nikon/ ) {
             $Make = 'Nikon';
         }

         my $Model = $Info->{'Model'} if $Info->{'Model'};
         # Capitalize the first letter of each word.
         $Model =~ s/([\w']+)/\u\L$1/g;
         # Remove any spaces.
         $Model =~ s/ //g;
         my $FileAppendString;

         unless ($Make || $Model) {
            # Don't have either so try alternate tags
            if ($Info->{'Information'}) {
               my $Tag = $Info->{'Information'};
               my @Pieces = split( ' ', $Tag );
               if ($Pieces[0] =~ /^Kodak/i) {
                  $Make = $Pieces[0];
                  $Model = $Pieces[1];
               }
            }
         }
         
         # If the Model information already contains Make
         if ($Model && $Model =~ /^$Make/) {
            # Just use Model.
            $FileAppendString = $Model;
         }
         # Else if we have either the Make or Model.
         elsif ($Make || $Model) {
            # Otherwise concatenate Make and Model.
            $FileAppendString = $Make . $Model;
         }
         # Otherwise default to unknown.
         else {
            $FileAppendString = 'Unknown';
         }
         
         #----------------------------------------------------------------------
         # Apply date/time delta
         #----------------------------------------------------------------------
         my ($DeltaValid, $ImgDateOrig);
         if ($Delta) {
            $DeltaValid = Date::Manip::ParseDateDelta( $Delta );
            if ($DeltaValid) {
               my $Err;
               # Save the original date/time
               $ImgDateOrig = $ImgDate;
               $ImgDate = Date::Manip::DateCalc( $ImgDate, $DeltaValid, \$Err, 0 );
               if ($Err && $Debug) {
                  print "Date calculation error: $!\n";
               }
            }
            elsif ($Debug) {
               print "Delta not valid.\n";
            }
         }
         
         #----------------------------------------------------------------------
         # Assemble new filename
         #----------------------------------------------------------------------
         # Reformat the dates into the date/time string we want.
         my $DateFile = UnixDate( $ImgDate, $DateFileString ) . '.' . sprintf( "%02d", $SubSec );
         my $DatePath = UnixDate( $ImgDate, $DatePathString );
         # Separate the filename from the extension.
         my ($Junk, $File, $Ext) = fileparse( $SrcFileName, qr/\.[^.]*/ );
         # Force the extension to lowercase.
         $Ext = lc $Ext;
         # Build path.
         my $DestPath = File::Spec->catdir( $DestBase, $DatePath );
         # Build filename (without extension in case we have to append more).
         my $DestFileName = $DateFile . '_' . $FileAppendString;
         # Build absoulte file path.
         my $DestFileAbs = File::Spec->catfile( $DestPath, $DestFileName.$Ext );
         
         #----------------------------------------------------------------------
         # Deal with duplicate filenames
         #----------------------------------------------------------------------
         # Make sure the destination file doesn't exist.
         my ($Dupe, $Skip) = 0;
         if (-f $DestFileAbs) {
            # It does so we use SHA1 hashes to identify if the files are the same
            
            # Generate the SHA1 hash for the source file.
            open( SRCFILE, "$SrcFileAbs" ) or die "Can't open $SrcFileAbs: $!";
            binmode( SRCFILE );
            my $SrcSHA1 = Digest::SHA->new(1)->addfile( *SRCFILE )->hexdigest;
            close( SRCFILE );
            
            # Loop on the new filename when we test the hashes so we can increment
            # the filename at the end until we find a filename that doesn't exist.
            my $Count = 0;
            while (-f $DestFileAbs) {
               # Generate the SHA1 hash for the source file.
               open( DESTFILE, "$DestFileAbs" ) or die "Can't open $DestFileAbs: $!";
               binmode( DESTFILE );
               my $DestSHA1 = Digest::SHA->new(1)->addfile( *DESTFILE )->hexdigest;
               close( DESTFILE );

               # If the SHA1 hashes match
               if ($SrcSHA1 eq $DestSHA1) {
                  # Files have identical content!

                  if ($Debug) { print "$SrcFileAbs: $SrcSHA1\n$DestFileAbs: $DestSHA1\n"; }
                  # If we're told to force cleanup.
                  if ($Cleanup && $Force) {
                     if ($Verbose) {
                        print "$SrcFileAbs: Destination file already exists; deletion forced.\n";
                     }
                     # Delete the file.
                     unlink $SrcFileAbs or print "$SrcFileAbs: Unable to delete: $!\n";
                  }
                  # Otherwise if we're being chatty, inform the user we're
                  # leaving the file be..
                  elsif ($Verbose) {
                     print "$SrcFileAbs: Destination file already exists, skipping.\n";
                  }
                  $Dupe = 1;
                  # Jump out of the while loop.
                  last;
               }
               
               # If forced, increment the filename.  Lather, rinse, repeat.
               if ($Force) {
                  $Count++;
                  my $Num = sprintf( "%04d", $Count );
                  $DestFileAbs = File::Spec->catfile(
                     $DestPath,
                     $DestFileName . '_' . $Num . $Ext
                  );
               }
               # Otherwise the safer thing is to leave it be to let a human
               # deal with it.
               else {
                  print "$SrcFileAbs: Destination file with same name, skipping.\n";
                  $Skip = 1;
                  # Jump out of the while loop.
                  last;
               }
            }
         }

         # If we found a duplicate file,
         if ($Dupe) {
            # Increment the counter.
            $Counts{'dupe'}++;
            # And jump to the next source file.
            next;
         }
         # If we found a file with the same name and we're not incrementing the
         # filename.
         if ($Skip) {
            # Increment the counter.
            $Counts{'skip'}++;
            # And jump to the next source file.
            next;
         }

         # At this point we are ready to actually process the source file!
         #----------------------------------------------------------------------
         # Process files
         #----------------------------------------------------------------------

         # Unless this is a dry run..
         unless ($DryRun) {
            # Unless the destination path exists.
            unless (-w $DestPath) {
               # Make the path in one fell swoop.
               File::Path::make_path( $DestPath, {error => \my $Err} );
               # If that had a problem, inform the user and die.
               if (@$Err) {
                  foreach my $Diag (@$Err) {
                     my ($File, $Message) = %$Diag;
                     print "Error making path $DestPath: $Message\n";
                  }
                  die;
               }
            }
         }
         
         if ($Move) {
            if ($Verbose) { print "Moving $SrcFileName -> $DestFileAbs\n"; }
            unless ($DryRun) { move( $SrcFileAbs, $DestFileAbs ); }
         }
         
         else {
            if ($Verbose) { print "Copying $SrcFileName -> $DestFileAbs\n"; }
            unless ($DryRun) { copy( $SrcFileAbs, $DestFileAbs ); }
         }
         $Counts{'copy'}++;
         
         #----------------------------------------------------------------------
         # Save adjusted date/time back to file.
         #----------------------------------------------------------------------
         if ($DeltaValid and not $DryRun) {
            # Verify we can write tags to the file
            if (Image::ExifTool::CanWrite( $DestFileAbs )) {
               if ($Debug) { print "Saving new date/time to $DestFileAbs.\n"; }
               # Create a new Image::ExifTool object.
               my $ImgData = new Image::ExifTool;
               # Extract all of the tags from the file.
               $ImgData->ExtractInfo( $DestFileAbs );
               # Read all of the metadata.
               my $Info = $ImgData->GetInfo( );
               # Tag list to work through
               my @DateTimeTags = (
                  qr/DateTimeOriginal/,
                  qr/DateTimeDigitized/,
                  qr/CreateDate/,
               );
               # Find all tags with Date or Time in their name
               foreach my $Tag (keys $Info) {
                  if ($Tag ~~ @DateTimeTags) {
                     # Parse the date/time.
                     my $ImgDateNew = Date::Manip::ParseDate( $Info->{$Tag} );
                     # Only work on date/times that equal the original date/time
                     if (Date::Manip::Date_Cmp( $ImgDateOrig, $ImgDateNew ) == 0) {
                        # Format the date/time into the EXIF format
                        my $NewDateFmt = Date::Manip::UnixDate( $ImgDate, "%Y:%m:%d %H:%M:%S" );
                        if ($Tag =~ /SubSec/) { $NewDateFmt .= $SubSec; }
                        if ($Debug) { print "Setting tag $Tag to $NewDateFmt.\n"; }
                        # Set a new value and capture any error message.
                        my ($Rc, $Err) = $ImgData->SetNewValue( $Tag, $NewDateFmt);
                        if ($Err) {
                           warn "Error setting $Tag to $NewDateFmt: $Err\n";
                        }
                     }
                     elsif ($Debug > 1) {
                        print "Original date/time $ImgDateOrig not equal to new $ImgDateNew.\n";
                     }
                  }
               }
               # Write the info into a temp file.
               my $TempFile = File::Temp::tmpnam( );
               my $Success = $ImgData->WriteInfo( $DestFileAbs, $TempFile );
               my $ErrMsg = $ImgData->GetValue( 'Error' );
               my $WarnMsg = $ImgData->GetValue( 'Warning' );
               unless ($Success) {
                  warn "Error writing metadata to $TempFile: $ErrMsg\n";
               }
               elsif ($WarnMsg and $Debug) {
                  warn "Warning while writing metadata to $TempFile: $WarnMsg\n";
               }
               
               # File::Copy may leave a partial destination file if problems
               # arise so be OCD and do a shell game to ensure file safety.
               # DestFile -> DestFile.bak
               my $M1 = move( $DestFileAbs, $DestFileAbs . '.bak' );
               if ($M1) {
                  # TempFile -> DestFile
                  my $M2 = move( $TempFile, $DestFileAbs );
                  if ($M2) {
                     unlink $DestFileAbs . '.bak';
                  }
                  else {
                     warn "Unable to replace $DestFileAbs: $!\n";
                     warn "Recovering from backup copy.\n";
                     # DestFile.bak -> DestFile
                     move( $DestFileAbs . '.bak', $DestFileAbs ) or
                        die "Problems moving backup copy back: $!\n";
                  }
                  unlink $TempFile;
               }

            } # END if (..CanWrite( $DestFileAbs ))
            else {
               warn "$SrcFileName: Unable to adjust date/time metadata for format $Supported.\n";
            }
         } # END if ($DeltaValid and not $DryRun)
      } # END if ($Supported)
      else {
         if ($Verbose) { print "$SrcFileName: File type is not supported, skipping.\n"; }
      }

   } #END if (-f $SrcFileAbs)
   elsif (-d $SrcFileAbs) {
      # Otherwise this is a directory.
      # If we were told to cleanup.
      if ($Cleanup && not $DryRun) {
         my $Rc = rmdir( $SrcFileAbs );
         if ($Verbose) {
            if ($Rc) {
               print "Delete directory $SrcFileAbs\n";
            }
            else {
               print "Unable to delete directory $SrcFileAbs: $!\n";
            }
         }
      }
   }

   if ($Debug) { print "\n"; }

}

__END__

=head1 NAME

sortpics.pl - Sort pictures using EXIF metadata information.

=head1 SYNOPSIS

sortpics.pl [options] SOURCE [SOURCE...] DESTINATION

 Options:
   -C, --cleanup           delete non-picture files and empty directories
   -d, --debug             enable debug output
   --delta DELTA           apply DELTA to the date/time             
   -D, --dry-run           perform a trial run without making any changes
   -f, --force             force deletion of duplicate files, rename others
   -h, --help              print a brief help message
   -l, --logic INTEGER     set advanced logic to INTEGER
   -M, --man               prints a detailed man page
   -m, --move              move files instead of just copying them
   -r, --recursive         recurse into directories
   -v, --verbose           enable output

=head1 DESCRIPTION

B<sortpics.pl> sorts pictures from SOURCE, or multiple SOURCES, to DESTINATION
directory using timestamp and the camera's make/model information from supported
metadata. Its purpose is to bring order and sanity to digital media organization.
By using the filename's create date/time, it creates a directory structure and
filename that arranges everything cronologically.

The script will use the either the "DateTimeOriginal", "DateTimeDigitized, 
"CreateDate" tags or their sub-second equals; whichever is found first.  This
can be adjusted using the B<-l, --logic INTEGER> argument to enable advanced
heursitics.

The script can also adjust the date/time found by using the B<--delta DELTA>
argument.  DELTA can be any date/time delta as definied by Date::Manip::Delta.
Examples include "+1 year" or "minus 2 months, 9 days".  The resulting date/time
is used in the new filename and the script attempts to write it back to the
metadata.  Writing the metadata depends on Image::ExifTool's write support for
the given filetype.

Safety is of the utmost importance so SHA1 hashes are used to verify duplicate
files.  Truely duplicate files, ones with identical hashes, will be skipped or
they can be cleaned up with the B<-C, --cleanup> and B<-f, --force> arguments.
Files with identical filenames, but differing hashes, will also be skipped
unless B<-f, --force> argument is given, in which case an incremented number
will be appended to the filename.

=head1 OPTIONS

=over 8

=item B<-C, --cleanup>

Causes the script to delete certain non-picture files that were created by digital
cameras and picture software.  It also causes the script to delete empty
directories as it processes files.

=item B<-d, --debug>

Enable debug output.  This causes more information to be outputted which may
be useful in debugging the script.  Can be repeated causing additional
information to be outputed.

=item B<--delta DELTA>

Applies a valid Date::Manip::Delta delta specified in DELTA to the date/time
found for each file.  This allows the date/time to be adjusted in cases where
the values found are wrong.  Date::Manip supports natural language expressions
such as "+ 1 year" or "subtract 1 month, 8 days".

=item B<D, --dry-run>

Enables dryrun mode, which steps through everything that will happen without
making any changes.  It works best with the -v, --verbose option to see what will
happen during a real run.
   
=item B<-f, --force>

Enables force mode.  In particular, this causes 2 major changes in the scripts
execution.  One, duplicate files (identical hashes) are deleted instead of being
left alone and two, files with the same filename have an incremented number
appended to them.  In the first instance, SHA1 hashes matching pretty much
guarantees the files are identical but the script plays it safe by leaving files
be.  However, in the second case, the script can not guarantee files with the
same names will end up in proper cronological order.  Since both actions may not
be the safest path they are left to the user to choose.

=item B<-h, --help>

Print a brief help message describing the options of the script and exits.

=item B<-l, --logic NUMBER>

Sets advanced date/time heuristics.  NUMBER corresponds to an integer that
represents an increasing amount of logic to use in determining a pictures
date when the metadata does not contain one.  Currently, the values are:

B<1> - Tests each directory for a date starting with the file's current directory
and working upwards through the file's path.  This is done first with the belief
a path that already contains a date was probably sorted before so it most likely
is more valid.

B<2> - Uses file's mtime.  This has the problem that files which have been modified
will likely have mtime's that differ from the real creation date.

=item B<-m, --move>

Move the files instead of copying them.  It is suggested to use the B<-D, --dry-run>
argument first to verify what will happen prior to running without it.

=item B<-M, --man>

Output a detailed help message formatted as a man page.

=item B<-r, --recursive>

This causes the script to process the SOURCE(S) recursively.  This also causes
the script to operate in a manner similar to "find -depth" so that it works from
the bottom up.

=item B<-v, --verbose>

Enable verbose output.  This causes more information to be outputted which may
be useful in following along with what the script is doing.

=back

=head1 DEPENDENCIES

Perl 5.10.0 or greater is required.

The following modules are used which are not part of the core perl distribution.

=over 8

=item Date::Manip

=item Digest::SHA

=item Image::ExifTool

=back

=head1 BUGS AND LIMITATIONS

When multiple destination files with the same name are found while using -d,
--dry-run and -f, --force options at the same time the script will not correctly
increment the counter used in the new filenames.

Please report problems to the author.  Patches are welcome.

=head1 AUTHOR

Written by Chris Clonch <chris@theclonchs.com>

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2012 Chris Clonch <chris@theclonchs.com>.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 3 of the License, or
(at your option) any later version <http://gnu.org/licenses/gpl.html>.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software Foundation,
Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA

=cut
