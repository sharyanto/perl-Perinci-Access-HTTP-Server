#!perl

package Test::ParseRequest;

our %SPEC;
$SPEC{add2} = {
    v=>1.1,
    args=>{
        a=>{req=>1, pos=>0, schema=>'num'},
        b=>{req=>1, pos=>1, schema=>'num'},
    },
};
sub add2 { my %args = @_; [200, "OK", $args{a} + $args{b}] }

package main;

use 5.010;
use strict;
use warnings;

use Plack::Builder;
use Plack::Test;
use Test::More;

test_ParseRequest_middleware(
    name => "default",
    args => {uri_pattern=>qr!^/api(?<uri>/[^?]*)!},
    requests => [
        {
            name      => 'default Riap request keys',
            args      => [GET => '/api/'],
            rr        => {v=>1.1, action=>'call', uri=>'pm:/', fmt=>'json'},
        },
        {
            name      => 'default fmt = html, errpage in html',
            args      => [GET => '/x', ['Accept'=>'text/html']],
            rr        => undef,
            ct        => 'text/html',
            content   => qr/match uri_pattern/,
        },
        {
            name      => 'default fmt = text, errpage in text',
            args      => [GET => '/x', ['Accept'=>'text/*']],
            rr        => undef,
            content   => qr/match uri_pattern/,
        },

        {
            name      => 'request keys from X-Riap-* header',
            args      => [GET => '/api/', ['X-Riap-Foo' => 42,
                                           'X-Riap-Bar-Baz-j-'=>'[2]']],
            rr        => {v=>1.1, action=>'call', uri=>'pm:/', fmt=>'json',
                          foo=>42, bar_baz=>[2]},
        },
        {
            name      => 'invalid json in from X-Riap-* header',
            args      => [GET => '/api/', ['X-Riap-Foo-j-' => '[a']],
            rr        => undef,
            ct        => 'application/json',
            content   => qr/invalid json/i,
        },

        {
            name      => 'parse args from body',
            args      => [POST => '/api/Foo/bar',
                          ['Content-Type'=>'application/json'],
                          '{"a":1,"b":[2,3]}'],
            rr        => {v=>1.1, action=>'call', uri=>'pm:/Foo/bar',
                          fmt=>'json', args=>{a=>1, b=>[2,3]}},
        },
        {
            name      => 'sanity check for args',
            args      => [POST => '/api/Foo/bar',
                          ['Content-Type'=>'application/json'],
                          '[]'],
            ct        => 'application/json',
            content   => qr/args.+must be hash/i,
        },
        {
            name      => 'args from body does not override X-Riap-Args header',
            args      => [POST => '/api/Foo/bar',
                          ['X-Riap-Args-j-'=>'{}',
                           'Content-Type'=>'application/json'],
                          '{"a":1,"b":[2,3]}'],
            rr        => {v=>1.1, action=>'call', uri=>'pm:/Foo/bar',
                          fmt=>'json', args=>{}},
        },
        {
            name      => 'uri_pattern',
            args      => [GET => '/x'],
            rr        => undef,
            ct        => 'application/json',
            content   => qr/match uri_pattern/,
        },
        {
            name      => 'uri_pattern does not override X-Riap-URI header',
            args      => [GET => '/api/M1/',
                          ['X-Riap-URI'=>'/M0/']],
            rr        => {v=>1.1, action=>'call', uri=>'pm:/M0/',
                          fmt=>'json'},
        },
        {
            name      => 'parse args from body (yaml, default off)',
            args      => [POST => '/api/Foo/bar',
                          ['Content-Type'=>'text/yaml'],
                          '{a: 1, b: [2, 3]}'],
            ct        => 'application/json',
            content   => qr/unsupported/i,
        },
        {
            name      => 'parse args from body (unknown type)',
            args      => [POST => '/api/Foo/bar',
                          ['Content-Type'=>'text/unknown'],
                          '123'],
            ct        => 'application/json',
            content   => qr/unsupported/i,
        },

        # XXX test parse from multipart body (not yet supported)

        {
            name      => 'parse args + request keys from form (get)',
            args      => [GET => '/api/Foo/bar?a=1&b:j=[2,3]&-riap-foo=bar'],
            rr        => {v=>1.1, action=>'call', uri=>'pm:/Foo/bar',
                          fmt=>'json', foo=>'bar', args=>{a=>1, b=>[2,3]}},
        },
        {
            name      => 'request/args keys from form does not override '.
                'X-Riap-* header & body',
            args      => [GET => '/api/Foo/bar?a=2&b:j=[2,3]&-riap-foo=bar&'.
                      '-riap-fmt=text&-riap-baz=qux',
                          ['X-Riap-Args-j-'=>'{"a":1}', 'X-Riap-Baz'=>1]],
            rr        => {v=>1.1, action=>'call', uri=>'pm:/Foo/bar',
                          fmt=>'text', foo=>'bar', baz=>1,
                          args=>{a=>1, b=>[2,3]}},
        },

    ],
);

test_ParseRequest_middleware(
    name => "uri_pattern as 2-element array",
    args => {uri_pattern=>[
        qr!^/ga/(?<mod>[^?/]+)(?:
               /?(?:
                   (?<func>[^?/]+)?
               )
           )!x,
        sub {
            my $m=shift;
            $m->{mod} =~ s!::!/!g;
            $m->{func} //= "";
            $m->{uri} = "/My/$m->{mod}/$m->{func}";
            delete $m->{mod};
            delete $m->{func};
        },
    ]},
    requests => [
        {
            name      => 'mod',
            args      => [GET => '/ga/Foo::Bar'],
            rr        => {v=>1.1, action=>'call', fmt=>'json',
                          uri=>'pm:/My/Foo/Bar/'},
        },
        {
            name      => 'mod + func',
            args      => [GET => '/ga/Foo::Bar/baz'],
            rr        => {v=>1.1, action=>'call', fmt=>'json',
                          uri=>'pm:/My/Foo/Bar/baz'},
        },
    ],
);

test_ParseRequest_middleware(
    name => "accept_yaml=1",
    args => {uri_pattern=>qr!^/api(?<uri>/[^?]*)!, accept_yaml=>1},
    requests => [
        {
            name      => 'parse args from body (yaml turned on)',
            args      => [GET => '/api/Foo/bar',
                          ['Content-Type'=>'text/yaml'],
                          '{a: 1, b: [2, 3]}'],
            rr        => {v=>1.1, action=>'call', uri=>'pm:/Foo/bar',
                          fmt=>'json', args=>{a=>1, b=>[2,3]}},
        },
    ],
);

test_ParseRequest_middleware(
    name => "parse_form=0",
    args => {uri_pattern=>qr!^/api(?<uri>/[^?]*)!, parse_form=>0},
    requests => [
        {
            name      => 'request/args keys from form (turned off)',
            args      => [GET => '/api/Foo/bar?a=1'],
            rr        => {v=>1.1, action=>'call', uri=>'pm:/Foo/bar',
                          fmt=>'json'},
        },
    ],
);

test_ParseRequest_middleware(
    name => "parse_path_info=1",
    args => {parse_path_info=>1,
             uri_pattern=>[
                 qr!^/ga/(?<mod>[^?/]+)(?:
                        /?(?:
                            (?<func>[^?/]+)?
                            (?<pi>/?[^?]*)
                        )
                    )!x,
                 sub {
                     my ($m, $env) = @_;
                     $m->{mod} =~ s!::!/!g;
                     $m->{func} //= "";
                     $m->{uri} = "/$m->{mod}/$m->{func}";
                     $env->{PATH_INFO} = $m->{pi};
                     delete $m->{mod};
                     delete $m->{func};
                     delete $m->{pi};
                 },
             ]},
    requests => [
        {
            name      => 'parse args from PATH_INFO (turned on)',
            args      => [GET => '/ga/Test::ParseRequest/add2/10%2E5/20%2E5'],
            rr        => {v=>1.1, action=>'call', fmt=>'json',
                          uri=>'pm:/Test/ParseRequest/add2',
                          args=>{a=>10.5, b=>20.5},
                      },
        },
    ],
);

# XXX test parse args + request keys from path info? (turned off by default)

done_testing;

sub test_ParseRequest_middleware {
    my %args = @_;
    my $rr;

    # if $rr is undef it means ParseRequest dies/bails and we do not get to the
    # app

    my $app = builder {
        enable sub {
            my $app = shift;
            sub { my $env = shift; $rr = undef; $app->($env) },
        };

        enable "PeriAHS::ParseRequest", %{$args{args}};

        sub {
            my $env = shift;
            $rr = $env->{"riap.request"};
            return [
                200,
                ['Content-Type' => 'text/plain'],
                ['Success']
            ];
        };
    };

    test_psgi app => $app, client => sub {
        my $cb = shift;

        subtest $args{name} => sub {
            for my $test (@{$args{requests}}) {
                subtest $test->{name} => sub {
                    my $res = $cb->(HTTP::Request->new(@{$test->{args}}));
                    #diag $res->as_string;

                    is($res->code, $test->{status} // 200, "status")
                        or diag $res->as_string;

                    if (exists $test->{rr}) {
                        if ($rr) {
                            $rr->{uri} = "$rr->{uri}"; # to ease comparison
                        }
                        is_deeply($rr, $test->{rr}, "rr") or diag explain $rr;
                    }

                    is($res->header('Content-Type'),
                       $test->{ct} // 'text/plain', "ct");

                    if ($test->{content}) {
                        if (ref($test->{content}) eq 'Regexp') {
                            like($res->content, $test->{content},
                                 "content (re)") or diag $res->content;
                        } else {
                            is($res->content, $>{content}, "content");
                        }
                    } else {
                        is($res->content, "Success", "default content (app)");
                    }

                    done_testing;
                };
            }
            done_testing;
        };

    };
}
