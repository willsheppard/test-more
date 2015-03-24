package Test::Stream::Tester;
use strict;
use warnings;

use Test::Stream;
use Test::Stream::Util qw/try/;

use B;

use Scalar::Util qw/blessed reftype/;
use Test::Stream::Carp qw/croak carp/;

use Test::Stream::Tester::Checks;
use Test::Stream::Tester::Checks::Event;
use Test::Stream::Tester::Events;
use Test::Stream::Tester::Events::Event;

use Test::Stream::Toolset;
use Test::Stream::Exporter;
default_exports qw{
    intercept grab

    events_are
    check event directive
};

default_export dir => \&directive;
Test::Stream::Exporter->cleanup;

sub grab {
    require Test::Stream::Tester::Grab;
    return Test::Stream::Tester::Grab->new;
}

our $EVENTS;
sub check(&) {
    my ($code) = @_;

    my $o    = B::svref_2object($code);
    my $st   = $o->START;
    my $file = $st->file;
    my $line = $st->line;

    local $EVENTS = Test::Stream::Tester::Checks->new($file, $line);

    my @out = $code->($EVENTS);

    if (@out) {
        if ($EVENTS->populated) {
            carp "sub used in check(&) returned values, did you forget to prefix an event with 'event'?"
        }
        else {
            croak "No events were produced by sub in check(&), but the sub returned some values, did you forget to prefix an event with 'event'?";
        }
    }

    return $EVENTS;
}

sub event($$) {
    my ($type, $data) = @_;

    croak "event() cannot be used outside of a check { ... } block"
        unless $EVENTS;

    my $props;

    croak "event() takes a type, followed by a hashref"
        unless ref $data && reftype $data eq 'HASH';

    # Make a copy
    $props = { %{$data} };

    my @call = caller(0);
    $props->{debug_package} = $call[0];
    $props->{debug_file}    = $call[1];
    $props->{debug_line}    = $call[2];

    $EVENTS->add_event($type, $props);
    return ();
}

sub directive($;$) {
    my ($directive, @args) = @_;

    croak "directive() cannot be used outside of a check { ... } block"
        unless $EVENTS;

    croak "No directive specified"
        unless $directive;

    if (!ref $directive) {
        croak "Directive '$directive' requires exactly 1 argument"
            unless (@args && @args == 1) || $directive eq 'end';
    }
    else {
        croak "directives must be a predefined name, or a sub ref"
            unless reftype($directive) eq 'CODE';
    }

    $EVENTS->add_directive(@_);
    return ();
}

sub intercept(&) {
    my ($code) = @_;

    my @events;

    my ($ok, $error) = try {
        Test::Stream->intercept(
            sub {
                my $stream = shift;
                $stream->listen(
                    sub {
                        shift; # Stream
                        push @events => @_;
                    }
                );
                $code->();
            }
        );
    };

    die $error unless $ok || (blessed($error) && $error->isa('Test::Stream::Event'));

    return \@events;
}

sub events_are {
    my ($events, $checks, $name) = @_;

    croak "Did not get any events"
        unless $events;

    croak "Did not get any checks"
        unless $checks;

    croak "checks must be an instance of Test::Stream::Tester::Checks"
        unless blessed($checks)
            && $checks->isa('Test::Stream::Tester::Checks');

    my $ctx = context();

    # use $_[0] directly so that the variable used in the method call can be undef'd
    $events = $_[0]->finish
        if blessed($events)
            && $events->isa('Test::Stream::Tester::Grab');

    $events = Test::Stream::Tester::Events->new(@$events)
        if ref($events)
            && reftype($events) eq 'ARRAY';

    croak "'$events' is not a valid set of events."
        unless $events
            && blessed($events)
            && $events->isa('Test::Stream::Tester::Events');

    my ($ok, @diag) = $checks->run($events);

    $ctx->ok($ok, $name, \@diag);
    return $ok;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test::Stream::Tester - Tools for validating the events produced by your testing
tools.

=head1 DESCRIPTION

There are tools to validate your code. This library provides tools to validate
your tools!

=head1 SYNOPSIS

    use Test::More;
    use Test::Stream::Tester;

    events_are(
        # Capture all the events within the block
        intercept {
            ok(1, "pass");
            ok(0, "fail");
            diag("xxx");
        },

        # Describe what we expect to see
        check {
            event ok => {effective_pass => 1, name => 'pass'};
            event ok => {
                effective_pass => 0,
                name => 'fail',

                # Ignores any fields in the result we don't list
                # pass, line, file, tool_package, tool_name, etc...

                # Diagnostics generated by a test are typically linked to those
                # results (new and updated tools only) They can be validated.
                diag => qr/^Failed test /,
            };
            event diag => {message => 'xxx'};
            directive 'end'; # enforce that there are no more results
        },

        "This is the name of our test"
    );

    done_testing;

=head2 GRAB WITH NO ADDED STACK

    use Test::More;
    use Test::Stream::Tester;

    # Start capturing events. We use grab() instead of intercept {} to avoid
    # adding stack frames.
    my $grab = grab();

    # Generate some events.
    ok(1, "pass");
    ok(0, "fail");
    diag("xxx");

    # Stop capturing events, and validate the ones recieved.
    events_are(
        $grab,
        check {
            event ok => { effective_pass => 1, name => 'pass' };
            event ok => { effective_pass => 0, name => 'fail' };
            event diag => { message => 'xxx' };
            directive 'end';
        },
        'Validate our Grab results';
    );

    # $grab is now undef, it no longer exists.
    is($grab, undef, '$grab was destroyed for us.');

    ok(!$success, "Eval did not succeed, BAIL_OUT killed the test");

    # Make sure we got the event as an exception
    isa_ok($error, 'Test::Stream::Event::Bail');

    done_testing

=head1 EXPORTS

=over 4

=item $events = intercept { ... }

=item $events = intercept(sub { ... })

Capture the L<Test::Stream::Event> objects generated by tests inside the block.

=item events_are(\@events, $check)

=item events_are(\@events, $check, $name)

=item events_are($events, $check)

=item events_are($events, $check, $name)

=item events_are($grab, $check)

=item events_are($grab, $check, $name)

The first argument may be either an arrayref of L<Test::Stream::Event> objects,
an L<Test::Stream::Tester::Grab> object, or an L<Test::Stream::Tester::Events>
object. C<intercept { ... }> can be used to capture events within a block of
code, including plans such as C<skip_all>, and things that normally kill the
test like C<BAIL_OUT()>.

The second argument must be an L<Test::Stream::Tester::Checks> object.
Typically these are generated using C<check { ... }>.

The third argument is the name of the test, it is optional, but highly
recommended.

=item $checks = check { ... };

Produce an array of expected events for use in events_are.

    my $check = check {
        event ok   => { ... };
        event diag => { ... };
        directive 'end';
    };

If the block passed to check returns anything at all it will warn you as this
usually means you forgot to use the C<event> and/or C<diag> functions. If it
returns something AND has no events it will be fatal.

C<event()> and C<directive()> both return nothing, this means that if you use
them alone your codeblock will return nothing.

=item event TYPE => { ... };

Define an event and push it onto the list that will be returned by the
enclosing C<check { ... }> block. Will fail if run outside a check block. This
will fail if you give it an invalid event type.

If you wish to acknowledge the event, but not check anything you may simply
give it an empty hashref.

The line number where the event was generated is recorded for helpful debugging
in event of a failure.

B<CAVEAT> The line number is inexact because of the way perl records it. The
line number is taken from C<caller>.

=item dir 'DIRECTIVE';

=item dir DIRECTIVE => 'ARG';

=item dir sub { ... };

=item dir sub { ... }, $arg;

=item directive 'DIRECTIVE';

=item directive DIRECTIVE => 'ARG';

=item directive sub { ... };

=item directive sub { ... }, $arg;

Define a directive and push it onto the list that will be returned by the
enclosing C<check { ... }> block. This will fail if run outside of a check
block.

The first argument must be either a codeblock, or one of the name of a
predefined directive I<See the directives section>.

Coderefs will be given 3 arguments:

    sub {
        my ($checks, $events, $arg) = @_;
        ...
    }

C<$checks> is the L<Test::Stream::Tester::Checks> object. C<$events> is the
L<Test::Stream::Tester::Events> object. C<$arg> is whatever argument you passed
via the C<directive()> call.

Most directives will act on the C<$events> object to remove or alter events.

=back

=head1 INTERCEPTING EVENTS

    my $events = intercept {
        ok(1, "pass");
        ok(0, "fail");
        diag("xxx");
    };

Any events generated within the block will be intercepted and placed inside
the C<$events> array reference.

=head2 EVENT TYPES

All events will be subclasses of L<Test::Stream::Event>

=over 4

=item L<Test::Stream::Event::Ok>

=item L<Test::Stream::Event::Note>

=item L<Test::Stream::Event::Diag>

=item L<Test::Stream::Event::Plan>

=item L<Test::Stream::Event::Finish>

=item L<Test::Stream::Event::Bail>

=item L<Test::Stream::Event::Subtest>

=back

=head1 VALIDATING EVENTS

You can validate events by hand using traditional test tools such as
C<is_deeply()> against the $events array returned from C<intercept()>. However
it is easier to use C<events_are()> paried with C<checks> objects build using
C<checks { ... }>.

    events_are(
        intercept {
            ok(1, "pass");
            ok(0, "fail");
            diag("xxx");
        },

        check {
            event ok => { effective_pass => 1, name => 'pass' };
            event ok => { effective_pass => 0, name => 'fail' };
            event diag => {message => 'xxx'};
            directive 'end';
        },

        "This is the name of our test"
    );

=head2 WHAT DOES THIS BUY ME?

C<checks { ... }>, C<event()>, and C<directive()>, work together to produce a
nested set of objects to represent what you want to see. This was chosen over a
hash/list system for 2 reasons:

=over 4

=item Better Diagnostics

Whenever you use C<checks { ... }>, C<events()>, and C<directive()> it records
the filename and line number where they are called. When a test fails the
diagnostics will include this information so that you know where the error
occured. In a hash/list based system this information is not available.

A hash based system is not practical as you may generate several events of the
same type, and in a hash duplicated keys are squashed (last one wins).

A list based system works, but then a failure reports the index of the failure,
this requires you to manually count events to find the correct one. Originally
I tried letting you specify an ID for the events, but this proved annoying.

Ultimately I am very happy with the diagnostics this allows. It is very nice to
see what is essentially a simple trace showing where the event and check were
generated. It also shows you the items leading to the failure in the event of
nested checks.

=item Loops and other constructs

In a list based system you are limited in what you can produce. You can
generate the list in advance, then pass it in, but this is hard to debug.
Alternatively you can use C<map> to produce repeated events, but this is
equally hard to debug.

This system lets you call C<event()> and C<directive()> in loops directly. It
also lets you write functions that produce them based on input for reusable
test code.

=back

=head2 VALIDATING FIELDS

The hashref against which events are checked is composed of keys, and values.
The values may be regular values, which are checked for equality with the
corresponding property of the event object. Alternatively you can provide a
regex to match against, or an arrayref of regexes (each one must match).

=over 4

=item field => 'exact_value',

The specified field must exactly match the given value, be it number or string.

=item field => qr/.../,

The specified field must match the regular expression.

=item field => [qr/.../, qr/.../, ...],

The value of the field must match ALL the regexes.

=item field => sub { ... }

Specify a sub that will validate the value of the field.

    foo => sub {
        my ($key, $val) = @_;

        ...

        # Return true (valid) or false, and any desired diagnostics messages.
        return($bool, @diag);
    },

=back

=head2 WHAT FIELDS ARE AVAILABLE?

This is specific to the event type. All events inherit from
L<Test::Stream::Event> which provides a C<summary()> method. The C<summary()>
method returns a list of key/value pairs I<(not a reference!)> with all fields
that are for public consumption.

For each of the following modules see the B<SUMMARY FIELDS> section for a list
of fields made available. These fields are inherited when events are
subclassed, and all events have the summary fields present in
L<Test::Stream::Event>.

=over 4

=item L<Test::Stream::Event/"SUMMARY FIELDS">

=item L<Test::Stream::Event::Ok/"SUMMARY FIELDS">

=item L<Test::Stream::Event::Note/"SUMMARY FIELDS">

=item L<Test::Stream::Event::Diag/"SUMMARY FIELDS">

=item L<Test::Stream::Event::Plan/"SUMMARY FIELDS">

=item L<Test::Stream::Event::Finish/"SUMMARY FIELDS">

=item L<Test::Stream::Event::Bail/"SUMMARY FIELDS">

=item L<Test::Stream::Event::Subtest/"SUMMARY FIELDS">

=back

=head2 DIRECTIVES

Directives give you a chance to alter the list of events part-way through the
check, or to make the check skip/ignore events based on conditions.

=head3 skip

Skip will skip a specific number of events at that point in the check.

=over 4

=item directive skip => $num;

    my $events = intercept {
        ok(1, "foo");
        diag("XXX");

        ok(1, "bar");
        diag("YYY");

        ok(1, "baz");
        diag("ZZZ");
    };

    events_are(
        $events,
        ok => { name => "foo" },

        skip => 1, # Skips the diag 'XXX'

        ok => { name => "bar" },

        skip => 2, # Skips the diag 'YYY' and the ok 'baz'

        diag => { message => 'ZZZ' },
    );

=back

=head3 seek

When turned on (true), any unexpected events will be skipped. You can turn
this on and off any time by using it again with a false argument.

=over 4

=item directive seek => $BOOL;

    my $events = intercept {
        ok(1, "foo");

        diag("XXX");
        diag("YYY");

        ok(1, "bar");
        diag("ZZZ");

        ok(1, "baz");
    };

    events_are(
        $events,

        seek => 1,
        ok => { name => "foo" },
        # The diags are ignored, it will seek to the next 'ok'
        ok => { name => "bar" },

        seek => 0,

        # This will fail because the diag is not ignored anymore.
        ok => { name => "baz" },
    );

=back

=head3 end

Used to say that there should not be any more events. Without this any events
after your last check are simply ignored. This will generate a failure if any
unchecked events remain.

=over 4

=item directive 'end';

=back

=head1 SEE ALSO

=over 4

=item L<Test::Tester> *Deprecated*

A nice, but very limited tool for testing 'ok' results.

=item L<Test::Builder::Tester> *Deprecated*

The original test tester, checks TAP output as giant strings.

=back

=head1 SOURCE

The source code repository for Test::More can be found at
F<http://github.com/Test-More/test-more/>.

=head1 MAINTAINER

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

The following people have all contributed to the Test-More dist (sorted using
VIM's sort function).

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=item Fergal Daly E<lt>fergal@esatclear.ie>E<gt>

=item Mark Fowler E<lt>mark@twoshortplanks.comE<gt>

=item Michael G Schwern E<lt>schwern@pobox.comE<gt>

=item 唐鳳

=back

=head1 COPYRIGHT

There has been a lot of code migration between modules,
here are all the original copyrights together:

=over 4

=item Test::Stream

=item Test::Stream::Tester

Copyright 2014 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://www.perl.com/perl/misc/Artistic.html>

=item Test::Simple

=item Test::More

=item Test::Builder

Originally authored by Michael G Schwern E<lt>schwern@pobox.comE<gt> with much
inspiration from Joshua Pritikin's Test module and lots of help from Barrie
Slaymaker, Tony Bowden, blackstar.co.uk, chromatic, Fergal Daly and the perl-qa
gang.

Idea by Tony Bowden and Paul Johnson, code by Michael G Schwern
E<lt>schwern@pobox.comE<gt>, wardrobe by Calvin Klein.

Copyright 2001-2008 by Michael G Schwern E<lt>schwern@pobox.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://www.perl.com/perl/misc/Artistic.html>

=item Test::use::ok

To the extent possible under law, 唐鳳 has waived all copyright and related
or neighboring rights to L<Test-use-ok>.

This work is published from Taiwan.

L<http://creativecommons.org/publicdomain/zero/1.0>

=item Test::Tester

This module is copyright 2005 Fergal Daly <fergal@esatclear.ie>, some parts
are based on other people's work.

Under the same license as Perl itself

See http://www.perl.com/perl/misc/Artistic.html

=item Test::Builder::Tester

Copyright Mark Fowler E<lt>mark@twoshortplanks.comE<gt> 2002, 2004.

This program is free software; you can redistribute it
and/or modify it under the same terms as Perl itself.

=back
