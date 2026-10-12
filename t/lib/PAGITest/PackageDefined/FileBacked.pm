package PAGITest::PackageDefined::FileBacked;

# A package with a file, for t/utils-package-is-defined.t: not defined until
# it is required.
use strict;
use warnings;

sub tag { return 'file-backed' }

1;
