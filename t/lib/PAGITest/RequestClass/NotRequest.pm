package PAGITest::RequestClass::NotRequest;

# A class with a file that is not a PAGI::Request, for
# t/middleware/request-class.t.
use strict;
use warnings;

sub new { return bless {}, shift }

1;
