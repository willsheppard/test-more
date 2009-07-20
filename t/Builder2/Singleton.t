#!/usr/bin/perl -w

use strict;
use warnings;

use Test::More;

{
    package Foo;

    use Mouse;
    with 'Test::Builder2::Singleton';
}

{
    my $foo = Foo->singleton;
    isa_ok $foo, "Foo";

    my $same = Foo->singleton;
    is $foo, $same;

    my $other = Foo->create;
    isa_ok $other, "Foo";
    isnt $foo, $other;

    ok !eval { Foo->new };
    like $@, qr/there is no new/;
}

# Set the singleton
{
    my $orig  = Foo->singleton;
    my $thing = Foo->create;
    Foo->singleton($thing);

    is( Foo->singleton, $thing );
}

done_testing();