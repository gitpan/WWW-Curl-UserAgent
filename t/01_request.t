use strict;
use warnings;

use Test::More tests => 49;

use HTTP::Request;
use Test::MockObject;

BEGIN {
    use_ok('WWW::Curl::UserAgent');
}

{
    note '$ua->request with defaults';

    my $keep_alive      = int( rand(1) );
    my $timeout         = int( rand(1_000) );
    my $connect_timeout = int( rand(1_000) );

    my $handler;
    my $ua_mock = Test::MockObject->new;
    $ua_mock->set_true('perform');
    $ua_mock->set_always( timeout         => $timeout );
    $ua_mock->set_always( connect_timeout => $connect_timeout );
    $ua_mock->set_always( keep_alive      => $keep_alive );
    $ua_mock->mock( add_handler => sub { ( undef, $handler ) = @_ } );

    WWW::Curl::UserAgent::request( $ua_mock, HTTP::Request->new( GET => 'dummy' ) );

    ok $handler, 'handler was set';
    ok $handler->on_success, 'on_success handler was set';
    ok $handler->on_failure, 'on_failure handler was set';
    ok $handler->request,    'request was set';

    is $handler->request->connect_timeout, $connect_timeout, 'connect_timeout was set';
    is $handler->request->timeout,         $timeout,         'timeout was set';
    is $handler->request->keep_alive,      $keep_alive,      'keep_alive was set';

    ok $ua_mock->called('perform'),         'perform was called';
    ok $ua_mock->called('keep_alive'),      'keep_alive was called';
    ok $ua_mock->called('timeout'),         'timeout was called';
    ok $ua_mock->called('connect_timeout'), 'connect_timeout was called';
}

{
    note '$ua->request with parameters';

    my $keep_alive      = int( rand(1) );
    my $timeout         = int( rand(1_000) );
    my $connect_timeout = int( rand(1_000) );

    my $handler;
    my $ua_mock = Test::MockObject->new;
    $ua_mock->set_true('perform');
    $ua_mock->mock( add_handler => sub { ( undef, $handler ) = @_ } );

    WWW::Curl::UserAgent::request(
        $ua_mock,
        HTTP::Request->new( GET => 'dummy' ),
        connect_timeout => $connect_timeout,
        timeout         => $timeout,
        keep_alive      => $keep_alive,
    );

    ok $handler, 'handler was set';
    ok $handler->on_success, 'on_success handler was set';
    ok $handler->on_failure, 'on_failure handler was set';
    ok $handler->request,    'request was set';

    is $handler->request->connect_timeout, $connect_timeout, 'connect_timeout was set';
    is $handler->request->timeout,         $timeout,         'timeout was set';
    is $handler->request->keep_alive,      $keep_alive,      'keep_alive was set';

    ok $ua_mock->called('perform'), 'perform was called';
    ok !$ua_mock->called('keep_alive'),      'keep_alive was not called';
    ok !$ua_mock->called('timeout'),         'timeout was not called';
    ok !$ua_mock->called('connect_timeout'), 'connect_timeout was not called';
}

{
    note '$ua->add_request with defaults';

    my $keep_alive      = int( rand(1) );
    my $timeout         = int( rand(1_000) );
    my $connect_timeout = int( rand(1_000) );
    my $on_success      = sub {'on_success'};
    my $on_failure      = sub {'on_failure'};

    my $handler;
    my $ua_mock = Test::MockObject->new;
    $ua_mock->set_true('perform');
    $ua_mock->set_always( timeout         => $timeout );
    $ua_mock->set_always( connect_timeout => $connect_timeout );
    $ua_mock->set_always( keep_alive      => $keep_alive );
    $ua_mock->mock( add_handler => sub { ( undef, $handler ) = @_ } );

    WWW::Curl::UserAgent::add_request(
        $ua_mock,
        request    => HTTP::Request->new( GET => 'dummy' ),
        on_success => $on_success,
        on_failure => $on_failure,
    );

    ok $handler, 'handler was set';
    ok $handler->on_success, 'on_success handler was set';
    ok $handler->on_failure, 'on_failure handler was set';
    ok $handler->request,    'request was set';

    is $handler->request->connect_timeout, $connect_timeout, 'connect_timeout was set';
    is $handler->request->timeout,         $timeout,         'timeout was set';
    is $handler->request->keep_alive,      $keep_alive,      'keep_alive was set';
    is $handler->on_success, $on_success, 'on_success was set';
    is $handler->on_failure, $on_failure, 'on_failure was set';

    ok !$ua_mock->called('perform'), 'perform was not called';
    ok $ua_mock->called('keep_alive'),      'keep_alive was called';
    ok $ua_mock->called('timeout'),         'timeout was called';
    ok $ua_mock->called('connect_timeout'), 'connect_timeout was called';
}

{
    note '$ua->add_request with parameters';

    my $keep_alive      = int( rand(1) );
    my $timeout         = int( rand(1_000) );
    my $connect_timeout = int( rand(1_000) );
    my $on_success      = sub {'on_success'};
    my $on_failure      = sub {'on_failure'};

    my $handler;
    my $ua_mock = Test::MockObject->new;
    $ua_mock->set_true('perform');
    $ua_mock->mock( add_handler => sub { ( undef, $handler ) = @_ } );

    WWW::Curl::UserAgent::add_request(
        $ua_mock,
        request         => HTTP::Request->new( GET => 'dummy' ),
        on_success      => $on_success,
        on_failure      => $on_failure,
        connect_timeout => $connect_timeout,
        timeout         => $timeout,
        keep_alive      => $keep_alive,
    );

    ok $handler, 'handler was set';
    ok $handler->on_success, 'on_success handler was set';
    ok $handler->on_failure, 'on_failure handler was set';
    ok $handler->request,    'request was set';

    is $handler->request->connect_timeout, $connect_timeout, 'connect_timeout was set';
    is $handler->request->timeout,         $timeout,         'timeout was set';
    is $handler->request->keep_alive,      $keep_alive,      'keep_alive was set';
    is $handler->on_success, $on_success, 'on_success was set';
    is $handler->on_failure, $on_failure, 'on_failure was set';

    ok !$ua_mock->called('perform'),         'perform was not called';
    ok !$ua_mock->called('keep_alive'),      'keep_alive was not called';
    ok !$ua_mock->called('timeout'),         'timeout was not called';
    ok !$ua_mock->called('connect_timeout'), 'connect_timeout was not called';
}
