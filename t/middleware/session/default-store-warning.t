use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Middleware::Session;
use PAGI::Middleware::Session::Store::Memory;

# Sessions fall back to the in-memory store when no store is given. That
# store suits development and a single worker only, so the fallback says so,
# once per process. Choosing the Memory store explicitly is silent.

is(
    warns { eval { PAGI::Middleware::Session->new(bogus_option => 1) } },
    0,
    'a construction that dies on an unknown option announces nothing',
);

is(
    warns { PAGI::Middleware::Session->new(store => PAGI::Middleware::Session::Store::Memory->new) },
    0,
    'an explicit Memory store is a choice: no warning',
);

like(
    warnings { PAGI::Middleware::Session->new },
    [qr/\APAGI::Middleware::Session: no store given, so sessions are kept in this process's memory: lost on restart and not shared between workers\. Fine for development; pass store => session_store\(\.\.\.\) to choose one\.\n\z/],
    'the default store warns',
);

is(warns { PAGI::Middleware::Session->new }, 0, 'once per process');

done_testing;
