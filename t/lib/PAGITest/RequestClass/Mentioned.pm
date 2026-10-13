package PAGITest::RequestClass::Mentioned;

# A Request subclass with a file whose package t/middleware/request-class.t
# names at compile time, before RequestClass requires it.
use strict;
use warnings;
use parent 'PAGI::Request';

1;
