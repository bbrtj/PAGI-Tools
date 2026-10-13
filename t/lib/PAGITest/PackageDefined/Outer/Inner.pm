package PAGITest::PackageDefined::Outer::Inner;

# Loading it alone gives PAGITest::PackageDefined::Outer a stash that holds
# only this nested package.
use strict;
use warnings;

sub tag { return 'inner' }

1;
