package PAGITest::RequestClass::Nested;

# A Request subclass whose stash holds only PAGITest::RequestClass::Nested::Part
# until RequestClass requires it, for t/middleware/request-class.t.
use strict;
use warnings;
use parent 'PAGI::Request';

1;
