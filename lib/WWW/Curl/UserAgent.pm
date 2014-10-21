package WWW::Curl::UserAgent;
{
  $WWW::Curl::UserAgent::VERSION = '0.9.1';
}

# ABSTRACT: UserAgent based on libcurl

use Moose;
use v5.10;

use WWW::Curl::Easy;
use WWW::Curl::Multi;
use HTTP::Response;
use Time::HiRes;
use IO::Select;

use WWW::Curl::UserAgent::Handler;
use WWW::Curl::UserAgent::Request;

# timeout in milliseconds
has timeout => (
    is      => 'rw',
    isa     => 'Int',
    default => 0,
);

# connection timeout in milliseconds
has connect_timeout => (
    is      => 'rw',
    isa     => 'Int',
    default => 300,
);

# maximum of requests done in parallel
has parallel_requests => (
    is      => 'rw',
    isa     => 'Int',
    default => 5,
);

# use connection keep-alive
has keep_alive => (
    is      => 'rw',
    isa     => 'Bool',
    default => 1,
);

# identifier in each request
has user_agent_string => (
    is      => 'rw',
    isa     => 'Str',
    default => sub {'www.curl.useragent/0.9.0'},
);

has _curl_multi => (
    is      => 'ro',
    isa     => 'WWW::Curl::Multi',
    default => sub { WWW::Curl::Multi->new },
);

has _handler_queue => (
    is      => 'ro',
    isa     => 'ArrayRef[WWW::Curl::UserAgent::Handler]',
    default => sub { [] },
    traits  => ['Array'],
    handles => {
        add_handler             => 'push',
        _get_handler_from_queue => 'shift',
        _has_handler_in_queue   => 'count',
        request_queue_size      => 'count',
    }
);

has _active_handler_map => (
    is      => 'ro',
    isa     => 'HashRef[WWW::Curl::UserAgent::Handler]',
    default => sub { {} },
    traits  => ['Hash'],
    handles => {
        _active_handlers    => 'count',
        _set_active_handler => 'set',
        _get_active_handler => 'delete',
    }
);

has _max_private_id => (
    is      => 'ro',
    isa     => 'Num',
    default => 1,
    traits  => ['Counter'],
    handles => { _inc_private_id => 'inc', }
);

sub request {
    my ( $self, $request, %args ) = @_;

    my $timeout         = $args{timeout}         // $self->timeout;
    my $connect_timeout = $args{connect_timeout} // $self->connect_timeout;
    my $keep_alive      = $args{keep_alive}      // $self->keep_alive;

    my $response;
    $self->add_handler(
        WWW::Curl::UserAgent::Handler->new(
            on_success => sub {
                my ( $req, $res ) = @_;
                $response = $res;
            },
            on_failure => sub {
                my ( $req, $msg, $desc ) = @_;
                $response = HTTP::Response->new( 500, $msg, [], $desc );
            },
            request => WWW::Curl::UserAgent::Request->new(
                http_request    => $request,
                connect_timeout => $connect_timeout,
                timeout         => $timeout,
                keep_alive      => $keep_alive,
            ),
        )
    );
    $self->perform;

    return $response;
}

sub add_request {
    my ( $self, %args ) = @_;

    my $on_success      = $args{on_success};
    my $on_failure      = $args{on_failure};
    my $request         = $args{request};
    my $timeout         = $args{timeout} // $self->timeout;
    my $connect_timeout = $args{connect_timeout} // $self->connect_timeout;
    my $keep_alive      = $args{keep_alive} // $self->keep_alive;

    my $handler = WWW::Curl::UserAgent::Handler->new(
        on_success => $on_success,
        on_failure => $on_failure,
        request    => WWW::Curl::UserAgent::Request->new(
            http_request    => $request,
            connect_timeout => $connect_timeout,
            timeout         => $timeout,
            keep_alive      => $keep_alive,
        ),
    );
    $self->add_handler($handler);

    return $handler;
}

sub perform {
    my $self = shift;

    my $active_handlers;

    # activate handlers by draining the queue
    while ( $active_handlers = $self->_drain_handler_queue ) {

        # loop until there is a response available
        $self->_wait_for_response($active_handlers);

        # execute callbacks for all received responses
        $self->_perform_callbacks;
    }
}

sub _wait_for_response {
    my $self            = shift;
    my $active_handlers = shift;

    my $curl_multi = $self->_curl_multi;

    while ( $curl_multi->perform == $active_handlers ) {
        Time::HiRes::nanosleep(1);
        my @select = map {
            my $s = IO::Select->new;
            $s->add( @{$_} );
            $s;
        } ( $curl_multi->fdset );
        IO::Select->select( @select, 0.1 );
    }
}

sub _perform_callbacks {
    my $self = shift;

    while ( my ( $active_transfer_id, $return_code ) = $self->_curl_multi->info_read ) {

        unless ($active_transfer_id) {
            Time::HiRes::nanosleep(1);    # do not eat the whole cpu
            next;
        }

        my $handler   = $self->_get_active_handler($active_transfer_id);
        my $request   = $handler->request;
        my $curl_easy = $request->curl_easy;

        if ( $return_code == 0 ) {
            my $response = $self->_build_http_response( ${ $request->header_ref }, ${ $request->content_ref } );
            $handler->on_success->( $request->http_request, $response, $curl_easy );
        }
        else {
            $handler->on_failure->(
                $request->http_request, $curl_easy->strerror($return_code),
                $curl_easy->errbuf, $curl_easy
            );
        }
    }
}

sub _drain_handler_queue {
    my $self = shift;

    while ( $self->_has_handler_in_queue && $self->_active_handlers < $self->parallel_requests ) {
        $self->_activate_handler( $self->_get_handler_from_queue );
    }

    return $self->_active_handlers;
}

sub _activate_handler {
    my $self    = shift;
    my $handler = shift;

    # set up curl easy
    $self->_inc_private_id;
    my $private_id = $self->_max_private_id;
    my $easy       = $handler->request->curl_easy;
    $easy->setopt( CURLOPT_PRIVATE,   $private_id );
    $easy->setopt( CURLOPT_USERAGENT, $self->user_agent_string );

    # reference the handler on its handler id (CURLOPT_PRIVATE)
    $self->_set_active_handler( $private_id => $handler );

    # finally add the curl easy to curl multi
    $self->_curl_multi->add_handle($easy);
}

sub _build_http_response {
    my $self    = shift;
    my $header  = shift;
    my $content = shift;

    # PUT requests may contain continue header
    while ( $header =~ s/^HTTP\/1.1 100 Continue\r\n\r\n// ) { }

    my $response = HTTP::Response->parse($header);
    $response->content($content) if defined $content;

    # message might include a bad char
    my $message = $response->message;
    $response->message($message)
        if $message =~ s/\r//g;

    return $response;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

__END__

=pod

=head1 NAME

WWW::Curl::UserAgent - UserAgent based on libcurl

=head1 VERSION

version 0.9.1

=head1 SYNOPSIS

    use HTTP::Request;
    use WWW::Curl::UserAgent;

    my $ua = WWW::Curl::UserAgent->new(
        timeout         => 10,
        connect_timeout => 1,
    );

    $ua->add_request(
        request    => HTTP::Request->new('http://search.cpan.org/'),
        on_success => sub {
            my ( $request, $response ) = @_;
            if ($response->is_success) {
                print $response->content;
            }
            else {
                die $response->status_line;
            }
        },
        on_failue  => sub {
            my ( $request, $error_msg, $error_desc ) = @_;
            die "$error_msg: $error_desc";
        },
    );
    $ua->perform;

=head1 DESCRIPTION

C<WWW::Curl::UserAgent> is a web user agent based on libcurl. It can be used
easily with C<HTTP::Request> and C<HTTP::Response> objects and handler
callbacks. For an easier interface there is also a method to map a single
request to a response.

C<WWW::Curl> is used for the power of libcurl, which e.g. handles connection
keep-alive, parallel requests, asynchronous callbacks and much more. This
package was written, because C<WWW::Curl::Simple> does not handle keep-alive
correctly and also does not consider PUT, HEAD and other request methods like
DELETE.

There is a simpler interface too, which just returns a C<HTTP::Response> for a
given C<HTTP::Request>, named request(). The normal approach to use this
library is to add as many requests with callbacks as your code allows to do and
run C<perform> afterwards. Then the callbacks will be excecuted sequentially
when the responses arrive beginning with the first received response. The
simple method request() does not support this of course, because there are no
callbacks defined.

=head1 CONSTRUCTOR METHODS

The following constructor methods are available:

=over 4

=item $ua = WWW::Curl::UserAgent->new( %options )

This method constructs a new C<WWW::Curl::UserAgent> object and returns it.
Key/value pair arguments may be provided to set up the initial state.
The default values should be based on the default values of libcurl.
The following options correspond to attribute methods described below:

    KEY                     DEFAULT
    -----------             --------------------
    user_agent_string       "www.curl.useragent/0.9.0"
    connect_timeout         300
    timeout                 0
    parallel_requests       5
    keep_alive              1

=back

=head1 ATTRIBUTES

=over

=item $ua->connect_timeout / $ua->connect_timeout($connect_timeout)

Get/set the timeout in milliseconds waiting for the response to be received. If the
response is not received within the timeout the on_failure handler is called.

=item $ua->timeout / $ua->timeout($timeout)

Get/set the timeout in milliseconds waiting for the response to be received. If the
response is not received within the timeout the on_failure handler is called.

=item $ua->parallel_requests / $ua->parallel_requests($parallel_requests)

Get/set the number of the maximum of requests performed in parallel. libcurl
itself may use less requests than this number but not more.

=item $ua->keep_alive / $ua->keep_alive($boolean)

Get/set if TCP connections should be reused with keep-alive. Therefor the
TCP connection is forced to be closed after receiving the response and the
corresponding header "Connection: close" is set. If keep-alive is enabled
(default) libcurl will handle the connections.

=item $ua->user_agent_string / $ua->user_agent_string($user_agent)

Get/set the user agent submitted in each request.

=item $ua->request_queue_size

Get the size of the not performed requests.

=item $ua->request( $request, %args )

Perform immediately a single C<HTTP::Request>. Parameters can be submitted
optionally, which will override the user agents settings for this single
request. Possible options are:

    connect_timeout
    timeout
    keep_alive

Some examples for a request

    my $request = HTTP::Request->new('http://search.cpan.org/');

    $response = $ua->request($request);
    $response = $ua->request($request,
        timeout    => 30,
        keep_alive => 0,
    );

If there is an error e.g. like a timeout the corresponding C<HTTP::Response>
object will have the statuscode 500, the short error description as message
and a longer message description as content. It runs perform() internally, so
queued requests will be performed, too.

=item $ua->add_request(%args)

Adds a request with some callback handler on receiving messages. The on_success
callback will be called for every successful read response, even those
containing error codes. The on_failure handler will be called when libcurl
reports errors, e.g. timeouts or bad curl settings. The parameters
C<request>, C<on_success> and C<on_failure> are mandatory. Optional are
C<timeout>, C<connect_timeout> and C<keep_alive>.

    $ua->add_request(
        request    => HTTP::Request->new('http://search.cpan.org/'),
        on_success => sub {
            my ( $request, $response, $easy ) = @_;
            print $request->as_string;
            print $response->as_string;
        },
        on_failure => sub {
            my ( $request, $err_msg, $err_desc, $easy ) = @_;
            # error handling
        }
    );

The callbacks provide as last parameter a C<WWW:Curl::Easy> object which was
used to perform the request. This can be used to obtain some informations like
statistical data about the request.

Chaining of C<add_request> calls is a feature of this module. If you add a
request within an C<on_success> handler it will be immediately executed when
the callback is executed. This can be useful to immediately react on a
response:

    $ua->add_request(
        request    => HTTP::Request->new( POST => 'http://search.cpan.org/', [], $form ),
        on_failure => sub { die },
        on_success => sub {
            my ( $request, $response ) = @_;

            my $target_url = get_target_from($response);
            $ua->add_request(
                request    => HTTP::Request->new( GET => $target_url ),
                on_failure => sub { die },
                on_success => sub {
                    my ( $request, $response ) = @_;
                    # actually do sth.
                }
            );
        },
    );
    $ua->perform; # executes both requests

=item $ua->add_handler($handler)

To have more control over the handler you can add a C<WWW::Curl::UserAgent::Handler>
by yourself. The C<WWW::Curl::UserAgent::Request> inside of the handler needs
all parameters provided to libcurl as mandatory to prevent defining duplicates of
default values. Within the C<WWW::Curl::UserAgent::Request> is the possiblity to
modify the C<WWW::Curl::Easy> object before it gets performed.

    my $handler = WWW::Curl::UserAgent::Handler->new(
        on_success => sub {
            my ( $request, $response, $easy ) = @_;
            print $request->as_string;
            print $response->as_string;
        },
        on_failure => sub {
            my ( $request, $err_msg, $err_desc, $easy ) = @_;
            # error handling
        }
        request    => WWW::Curl::UserAgent::Request->new(
            http_request    => HTTP::Request->new('http://search.cpan.org/'),
            connect_timeout => $ua->connect_timeout,
            timeout         => $ua->timeout,
            keep_alive      => $ua->keep_alive,
        ),
    );

    $handler->request->curl_easy->setopt( ... );

    $ua->add_handler($handler);

=item $ua->perform

Perform all queued requests. This method will return after all responses have
been received and handler have been processed.

=back

=head1 SEE ALSO

See L<HTTP::Request> and L<HTTP::Response> for a description of the
message objects dispatched and received.  See L<HTTP::Request::Common>
and L<HTML::Form> for other ways to build request objects.

See L<WWW::Curl> for a description of the settings and options possible
on libcurl.

=head1 AUTHORS

=over 4

=item *

Julian Knocke

=item *

Othello Maurer

=back

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2013 by XING AG.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
