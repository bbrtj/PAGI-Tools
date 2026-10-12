package PAGITest::PackageDefined::Outer;

# Loaded after PAGITest::PackageDefined::Outer::Inner in
# t/utils-package-is-defined.t, whose stash it then shares.
use strict;
use warnings;

sub tag { return 'outer' }

1;
