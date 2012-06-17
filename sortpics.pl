#!/usr/bin/env perl
################################################################################
# sortpics.pl - Sort pictures using EXIF metadata information.
# 
# Written by Chris Clonch <chris@theclonchs.com>.  See man page using -M, --man
# for copyright and license notice.
################################################################################
use strict;
require 5.010.000;
#use feature 'fc';


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
   'D|dry-run'    => \$DryRun,
   'f|force'      => \$Force,
   'h|help'       => \$Help,
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
my $DestPath = pop @ARGV;
$DestPath = File::Spec->rel2abs( $DestPath ) ;
# The remaining are our source directories.
my @SrcDirs = @ARGV;

# Destination directory must be a directory and writable.
unless (-d $DestPath && -w $DestPath) {
   die "Destination directory \'$DestPath\' does not exist or is not writable.\n";
}
# Make sure each source directory is a directory and readable.
foreach my $SrcDir (@SrcDirs) {
   $SrcDir = File::Spec->rel2abs( $SrcDir ) ;
   unless (-d $SrcDir && -r $SrcDir) {
      die "Source directory \'$SrcDir\' doesn't exist or is not readable.\n";
   }
}

# Record counts of files we process.
my %Counts = (
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
   my $FileAbs = $File::Find::name;
   my $FileName = $_;
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
         # Output all of the metadata if -dd
         if ($Debug > 1) {
            foreach my $Key (sort {$a <=> $b} keys %$Info) {
               print "$FileName: $Key -> " . $Info->{$Key} . "\n";
            }
         }
         
         my $ImgDate;
         # If CreateDate is in the metadata.
         if ($Info->{'CreateDate'}) {
            # Parse it.
            #$ImgDate = Date::Manip::ParseDate( $Info->{'CreateDate'} );
            $ImgDate = ParseDate( $Info->{'CreateDate'} );
         }
         # Not able to read date from metadata.
         else {
            # Getting the mtime does not work reliablity.
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
         
         # Reformat the dates into the date/time string we want.
         my $DateFile = UnixDate( $ImgDate, $DateFileString );
         my $DatePath = UnixDate( $ImgDate, $DatePathString );
         # Seperate the filename from the extension.
         my ($Junk, $File, $Ext) = fileparse( $FileName, qr/\.[^.]*/ );
         # Force the extension to lowercase.
         $Ext = lc $Ext;
         my $NewDestPath = File::Spec->catdir( $DestPath, $DatePath );
         my $NewFileName = $DateFile . '_' . $FileAppendString;
         my $NewFileAbs = File::Spec->catfile( $NewDestPath, $NewFileName.$Ext );
         
         # Make sure the destination file doesn't exist.
         my ($Dupe, $Skip) = 0;
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
           $Counts{'dupe'}++;
           # And jump to the next source file.
           next;
         }
         # If we found a file with the same name,
         if ($Skip) {
           # Increment the counter.
           $Counts{'skip'}++;
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

sortpics.pl - Sort pictures using EXIF metadata information.

=head1 SYNOPSIS

sortpics.pl [options] SOURCE [SOURCE...] DESTINATION

 Options:
   -C, --cleanup     delete non-picture files and empty directories
   -d, --debug       enable debug output
   -D, --dry-run     perform a trial run without making any changes
   -f, --force       force deletion of duplicate files, rename others
   -h, --help        print a brief help message
   -M, --man         prints a detailed man page
   -m, --move        move files instead of just copying them
   -r, --recursive   recurse into directories
   -v, --verbose     enable output

=head1 OPTIONS

=over 8

=item B<-C, --cleanup>

Causes the script to delete certain non-picture files that were created by digital
cameras and picture software.  It also causes the script to delete empty
directories as it processes files.

=item B<-d, --debug>

Enable debug output.  This causes more information to be outputted which may
be useful in debugging the script.

=item B<D, --dry-run>

Enables dryrun mode, which steps through everything that will happen without
making any changes.  It works best with the -v, --verbose option to see what will
happen during a real run.
   
=item B<-f, --force>

Enables force mode.  In particular, this causes 2 major changes in the scripts
execution.  One, duplicate files are deleted instead of being left alone and two,
files with the same filename have an incremented number appended to them.  In the
first instance, SHA1 hashes matching pretty much guarantees the files are identical
but the script plays it safe by leaving files be.  However, in the second case, the script
can not guarantee files with the same names will end up in proper cronological
order.  Since both actions may not be the safest path they are left to the user
to choose.

=item B<-h, --help>

Print a brief help message describing the options of the script and exits.

=item B<-m, --move>

Move the files instead of copying them.

=item B<-M, --man>

Output a detailed help message formatted as a man page.

=item B<-r, --recursive>

This causes the script to process the source directories recursively.  This also
causes the script to operate in a manner similar to "find -depth" so that it
works from the bottom up.

=item B<-v, --verbose>

Enable verbose output.  This causes more information to be outputted which may
be useful in following along with what the script is doing.

=back

=head1 DESCRIPTION

B<sortpics.pl> sorts pictures from SOURCE directory, or multiple SOURCE directories
to DESTINATION directory using the "Create Date" timestamp and the camera's
make/model information from the EXIF metadata.  Its purpose is to bring order
and sanity to digital picture organization.  By using the pictures timestamp, it
creates a directory structure and filename that arranges everything cronologically.

Safety is of the utmost importance so SHA1 hashes are used to verify duplicate
files.

=head1 DEPENDENCIES

The following modules are used which are not part of the core perl distribution.

=item Date::Manip

=item Digest::SHA

=item Image::ExifTool

=head1 BUGS AND LIMITATIONS

When mltiple destination files with the same name are found while using -d,
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
