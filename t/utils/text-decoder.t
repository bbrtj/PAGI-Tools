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

subtest 'strict UTF-16/32: a split code unit or surrogate pair waits' => sub {
    my %cases = (
        'BOM, then !'            => ['UTF-16',   ["\xFF\xFEh\0i\0", "!\0"],                ['hi', '!', '']],
        'an odd trailing byte'   => ['UTF-16',   ["\xFF\xFEh\0i", "\0!\0"],                ['h', 'i!', '']],
        'surrogate pair split'   => ['UTF-16',   ["\xFF\xFEh\0\x3D\xD8", "\x00\xDE!\0"],    ['h', "\x{1F600}!", '']],
        'surrogate unit split'   => ['UTF-16',   ["\xFF\xFEh\0\x3D", "\xD8\x00\xDE!\0"],    ['h', "\x{1F600}!", '']],
        'the BOM split'          => ['UTF-16',   ["\xFF", "\xFEh\0", "i\0"],                ['', 'h', 'i', '']],
        'UTF-16BE without a BOM' => ['UTF-16BE', ["\0h\0i", "\0!"],                         ['hi', '!', '']],
        'UTF-32, split 4 ways'   => ['UTF-32',   ["\xFF\xFE\0", "\0h\0\0\0!", "\0\0\0"],     ['', 'h', '!', '']],
    );
    for my $label (sort keys %cases) {
        my ($name, $in, $out) = @{$cases{$label}};
        is chunks(decoder($name, strict => 1), @$in), $out, $label;
    }
    is join('', @{ chunks(decoder('UTF-16', strict => 1), split //, "\xFF\xFEh\0i\0!\0") }), 'hi!',
        'byte at a time';
};

subtest 'strict UTF-16: a whole surrogate pair at the end of a chunk is decoded' => sub {
    is chunks(decoder('UTF-16', strict => 1), "\xFF\xFEh\0i\0 \0\x3D\xD8\x00\xDE"), ["hi \x{1F600}", ''],
        'a body that ends with an emoji';
    is chunks(decoder('UTF-16', strict => 1), "\xFF\xFEa\0\x3D\xD8\x00\xDE", "!\0"), ["a\x{1F600}", '!', ''],
        'a chunk that ends after a pair, more to come';
    is join('', @{ chunks(decoder('UTF-16', strict => 1), split //, "\xFF\xFEa\0\x3D\xD8\x00\xDE!\0") }),
        "a\x{1F600}!", 'byte at a time over a pair';
    is chunks(decoder('UTF-16LE', strict => 1), "a\0\x3D\xD8\x00\xDE"), ["a\x{1F600}", ''], 'UTF-16LE by name';
    is chunks(decoder('UTF-16BE', strict => 1), "\0a\xD8\x3D\xDE\x00"), ["a\x{1F600}", ''], 'UTF-16BE by name';
    is chunks(decoder('UTF-16', strict => 1), "\0a\xD8\x3D\xDE\x00"), ["a\x{1F600}", ''],
        'UTF-16 without a BOM is big-endian, as in Encode';
};

subtest 'strict UTF-16/32: malformed input still dies' => sub {
    like dies { decoder('UTF-16', strict => 1)->decode("\xFF\xFEa\0\x00\xDCb\0") },
        qr/\APAGI::Utils::TextDecoder: not valid UTF-16: .*surrogate/, 'a lone low surrogate, on its chunk';
    my $lead = decoder('UTF-16', strict => 1);
    is $lead->decode("\xFF\xFEa\0\x3D\xD8"), 'a', 'text before a trailing lead surrogate';
    like dies { $lead->finish }, qr/not valid UTF-16: .*surrogate/, 'the lone lead dies at finish';
    my $odd = decoder('UTF-16', strict => 1);
    $odd->decode("\xFF\xFEa\0b");
    like dies { $odd->finish }, qr/not valid UTF-16/, 'an odd final byte dies at finish';
    like dies { decoder('UTF-32', strict => 1)->decode("\xFF\xFE\0\0\x00\xD8\0\0") },
        qr/not valid UTF-32/, 'a UTF-32 surrogate';
};

done_testing;
