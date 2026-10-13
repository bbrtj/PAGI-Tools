#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use File::Temp qw(tempdir);
use PAGI::Utils::ReceiveBuffer::TempFile;

sub take_all {
    my ($buffer) = @_;
    my @events;
    while (defined(my $event = $buffer->take->get)) {
        push @events, $event;
    }
    return \@events;
}

sub dir_entries {
    my ($dir) = @_;
    opendir my $dh, $dir or die "$dir: $!";
    return [grep { !/\A\.\.?\z/ } readdir $dh];
}

subtest 'a small body is kept in memory and handed back as the same events' => sub {
    my $buffer = PAGI::Utils::ReceiveBuffer::TempFile->new;
    my @events = (
        { type => 'http.request', body => 'name=', more => 1 },
        { type => 'http.request', body => 'Ada', more => 0 },
    );
    ok($buffer->append($_)->is_done, 'append returns a done Future') for @events;

    my $taken = take_all($buffer);
    is(scalar @$taken, 2, 'both events come back');
    ref_is($taken->[$_], $events[$_], "event $_ is the same hash, not a copy") for 0, 1;
    is($buffer->take->get, undef, 'an emptied buffer keeps answering undef');
};

subtest 'past spool_threshold the events move to a temp file and replay in order' => sub {
    # Each request event counts 21 bytes (type 12, body 8, more 1), so the
    # first two stay in memory and the third moves all three to the file.
    my $dir = tempdir(CLEANUP => 1);
    my $buffer = PAGI::Utils::ReceiveBuffer::TempFile->new(spool_threshold => 50, temp_dir => $dir);
    my $held = PAGI::Utils::ReceiveBuffer::TempFile->new(spool_threshold => 50, temp_dir => $dir);
    my @events = (
        { type => 'http.request', body => 'a' x 8, more => 1 },
        { type => 'http.request', body => 'b' x 8, more => 1 },
        { type => 'http.request', body => 'c' x 8, more => 1 },
        { type => 'http.disconnect', reason => 'client closed' },
    );
    $held->append($_)->get for @events[0, 1];
    my $kept = take_all($held);
    is(scalar @$kept, 2, 'under the threshold both events come back');
    ref_is($kept->[$_], $events[$_], "under the threshold event $_ is still held in memory") for 0, 1;

    $buffer->append($_)->get for @events;

    is(dir_entries($dir), [], 'the temp file has no name in temp_dir, so nothing is left behind');
    my $taken = take_all($buffer);
    is($taken, \@events, 'every event comes back in order, the disconnect included');
    ok(!grep({ $taken->[$_] == $events[$_] } 0 .. $#events), 'spooled events are copies');
};

subtest 'spool_threshold => 0 spools from the first event' => sub {
    my $buffer = PAGI::Utils::ReceiveBuffer::TempFile->new(spool_threshold => 0);
    my $event = { type => 'http.request', body => 'x', more => 0 };
    $buffer->append($event)->get;
    my $taken = take_all($buffer);
    is($taken, [$event], 'the event comes back');
    ok($taken->[0] != $event, 'from the temp file, as a copy');
};

subtest 'bytes survive the temp file unchanged' => sub {
    my $buffer = PAGI::Utils::ReceiveBuffer::TempFile->new(spool_threshold => 0);
    my $bytes = join '', map { chr } 0 .. 255;
    $buffer->append({ type => 'http.request', body => $bytes, more => 0 })->get;
    is($buffer->take->get->{body}, $bytes, 'every byte value round-trips');
};

subtest 'options are checked' => sub {
    like(dies { PAGI::Utils::ReceiveBuffer::TempFile->new(spool_threshold => -1) },
        qr/spool_threshold must be a number of bytes/, 'a negative threshold dies');
    like(dies { PAGI::Utils::ReceiveBuffer::TempFile->new(spool_threshold => 'big') },
        qr/spool_threshold must be a number of bytes/, 'a word dies');
    like(dies { PAGI::Utils::ReceiveBuffer::TempFile->new(bogus => 1) },
        qr/unknown option 'bogus'/, 'an unknown option dies');
};

done_testing;
