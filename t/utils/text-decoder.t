use strict;
use warnings;
use utf8;
use Test2::V0;

use lib 'lib';
use PAGI::Utils::TextDecoder;

# A streaming decoder: bytes in, text out as soon as each character is whole.

sub chunks {
    my ($decoder, @chunks) = @_;
    return [ (map { $decoder->decode($_) } @chunks), $decoder->finish ];
}
sub decoder { PAGI::Utils::TextDecoder->new(@_) }

subtest 'one bad byte does not hold back the rest (not strict)' => sub {
    my $out = chunks(decoder('UTF-8'), "x\xFF" . ('a' x 1000), ('a' x 1000) x 4);
    is [map { length } @$out], [1002, 1000, 1000, 1000, 1000, 0], 'each chunk comes out whole';
    is substr($out->[0], 0, 2), "x\x{FFFD}", 'the bad byte is U+FFFD';
};

subtest 'UTF-16 keeps the byte order its BOM set (not strict)' => sub {
    is chunks(decoder('UTF-16'), "\xFF\xFEh\0i\0", "!\0"), ['hi', '!', ''], 'two chunks';
    is chunks(decoder('UTF-16'), "\xFF", "\xFEh\0", "i\0"), ['', 'h', 'i', ''], 'the BOM itself split';
};

subtest 'a character split across chunks waits for its other half' => sub {
    for my $strict (0, 1) {
        is chunks(decoder('UTF-8', strict => $strict), "cost: \xE2\x82", "\xAC5"), ['cost: ', '€5', ''],
            "UTF-8, strict=$strict";
    }
    is chunks(decoder('Shift_JIS', strict => 1), "a\x82", "\xA0b"), ['a', 'あb', ''], 'Shift_JIS lead byte, strict';
    is decoder('UTF-8')->decode(''), '', 'an empty chunk is empty text';
};

subtest 'strict: an invalid byte dies on the call that carries it' => sub {
    my $decoder = decoder('UTF-8', strict => 1);
    is $decoder->decode('ok'), 'ok', 'valid text first';
    is dies { $decoder->decode("a\xFFb") },
        qq{PAGI::Utils::TextDecoder: not valid UTF-8: UTF-8 "\\xFF" does not map to Unicode\n},
        "Encode's reason, no file or line";
    like dies { decoder('UTF-8', strict => 1)->decode("\xC0\x80") }, qr/not valid UTF-8/, 'an overlong form';
    like dies { decoder('utf8', strict => 1)->decode("\xED\xA0\x80") }, qr/not valid utf8/,
        "a client's 'utf8' is decoded as strict UTF-8 (an encoded surrogate is refused)";
};

subtest 'finish: the end of the input' => sub {
    is chunks(decoder('UTF-8'), 'ok'), ['ok', ''], 'nothing held: empty';
    is chunks(decoder('UTF-8'), "ok\xE2\x82"), ['ok', "\x{FFFD}"], 'a cut-off character: U+FFFD';
    my $strict = decoder('UTF-8', strict => 1);
    $strict->decode("ok\xE2\x82");
    is dies { $strict->finish },
        "PAGI::Utils::TextDecoder: not valid UTF-8: the input ends inside a character\n", 'strict: dies';
};

subtest 'a decoder is one-shot' => sub {
    my $done = decoder('UTF-8');
    $done->finish;
    like dies { $done->decode('x') }, qr/\APAGI::Utils::TextDecoder: already finished/, 'after finish';
    my $died = decoder('UTF-8', strict => 1);
    is $died->decode("ok\xE2"), 'ok', 'the decoder holds a partial character';
    ok dies { $died->decode("\xFFxyz") }, 'then dies on an invalid byte';
    like dies { $died->decode('abc') }, qr/already finished/, 'after a die, never a silent resume';
};

subtest 'mistakes croak at once' => sub {
    like dies { decoder('UTF-8')->decode("\x{263A}") }, qr/\APAGI::Utils::TextDecoder: expects bytes/,
        'a character string';
    like dies { decoder('x-bogus') }, qr/\APAGI::Utils::TextDecoder: unknown encoding 'x-bogus'/,
        'an unknown encoding';
    like dies { decoder('ISO-2022-JP') },
        qr/\APAGI::Utils::TextDecoder: 'ISO-2022-JP' cannot be decoded in chunks; decode the whole input/,
        'an encoding Encode decodes only line by line';
    like dies { decoder('UTF-8', strickt => 1) }, qr/\APAGI::Utils::TextDecoder: unknown option 'strickt'/,
        'an unknown option';
};

done_testing;
