package MyApp::View;

use v5.40;
use PAGI::Routing::URL qw(path_for);

sub document($class, $request, $title, $body) {
    # An absolute name: the View is called from handlers in every namespace.
    my $stylesheet = path_for($request, '/static', { path => 'app.css' });
    return <<"HTML";
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$title</title>
  <link rel="stylesheet" href="$stylesheet">
</head>
<body>
  <main class="page">
$body
  </main>
</body>
</html>
HTML
}

1;
