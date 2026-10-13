use strict;
use warnings;
use Test2::V0;
use FindBin;
use lib 'lib', "$FindBin::Bin/lib";
use PAGI::Utils ();

# PAGI::Utils::_package_is_defined answers "this package already has symbols
# of its own, so do not require it": an application's Request class is often
# declared inline in app.pl, with no file.

{ package Local::OnlySub; sub tag { return 'x' } }
{ package Local::WithNew; sub new { return bless {}, shift } }
{ package Local::OnlyParent; use parent 'PAGI::Request'; }

sub defined_ok {
    my ($package) = @_;
    return PAGI::Utils::_package_is_defined($package);
}

subtest 'a package declared in the file is defined' => sub {
    is(defined_ok('Local::OnlySub'), 1, 'one with only a sub that is not new');
    is(defined_ok('Local::WithNew'), 1, 'one with new');
    is(defined_ok('Local::OnlyParent'), 1, 'one with only use parent');
};

subtest 'a file-backed package is defined once it is loaded' => sub {
    ok(!exists $INC{'PAGITest/PackageDefined/FileBacked.pm'}, 'not loaded yet');
    is(defined_ok('PAGITest::PackageDefined::FileBacked'), 0, 'not defined before require');
    require PAGITest::PackageDefined::FileBacked;
    is(defined_ok('PAGITest::PackageDefined::FileBacked'), 1, 'defined after require');
};

subtest 'a stash holding only a nested package is not defined' => sub {
    require PAGITest::PackageDefined::Outer::Inner;
    is(defined_ok('PAGITest::PackageDefined::Outer::Inner'), 1, 'the nested package is');
    is(defined_ok('PAGITest::PackageDefined::Outer'), 0, 'its parent stash is not');
    require PAGITest::PackageDefined::Outer;
    is(defined_ok('PAGITest::PackageDefined::Outer'), 1, 'until the parent is loaded');
};

subtest 'a name never declared is not defined' => sub {
    is(defined_ok('Local::NeverDeclared'), 0, 'before anything touches it');
    my $name = 'Local::NeverDeclared';
    my $can = $name->can('new');
    my $isa = $name->isa('PAGI::Request');
    is(defined_ok('Local::NeverDeclared'), 0, 'nor after ->can and ->isa on its name');
    my $bareword = Local::NeverBareword->isa('PAGI::Request');
    is(defined_ok('Local::NeverBareword'), 0, 'nor after ->isa on a bareword');
    { no strict 'refs'; my $count = keys %{'Local::Vivified::'}; }
    is(defined_ok('Local::Vivified'), 0, 'nor a stash a symbolic deref made empty');
    is(defined_ok('Local::Untouched::Deep'), 0, 'a nested name under nothing');
    ok(!exists $Local::{'Untouched::'}, 'and the check itself creates no stash');
};

done_testing;
