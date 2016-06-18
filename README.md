# sortpics

## What Is It?

This script sorts pictures from sources, or multiple sources, to a destination
directory using timestamp and the camera's make/model information from
supported metadata.  By using the filename's embedded creation date/time, it
creates a directory structure and filename that arranges everything
chronologically.

Its purpose is to bring order and sanity to digital media organization.  I
created this after becoming frustrated with problems using big photo management
software to simply import pictures off of my camera's sdcard.  It is easy to
use, yet offers enough advanced features to handle most situations.

## Installation
If perl is installed, simply clone the repo.
```
git clone git@github.com:cacack/sortpics.git
```

I wrote and use this script on Linux, which typically has perl installed by
default.  However, I have tried to wrap most operations so that it should be
OS agnostic -- but I haven't tried it outside of Linux.  See
[Contributing](#contributing) if it doesn't.

## Getting Help
The script is fairly well commented.  You can also run `sortpics.pl --help` to
get a terse, a la GNU styled reminder on commandline syntax, or run 
`sortpics.pl --man` to get a man page style help document.

## Contributing
I know I haven't thought of every use case.  And there may be bugs.  So creating
a [new issue](../../issues/new) and/or [pull requests](../../compare/) are
welcome.  Of course you're welcome to fork and make something better.  But if
you do, please drop me a line letting me know.
