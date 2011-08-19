package Plack::Middleware::SubSpec::ServeCall;

use 5.010;
use strict;
use warnings;

use parent qw(Plack::Middleware);
use Plack::Util::Accessor qw(
                                allow_return_json
                                allow_return_yaml
                                allow_return_php
                                time_limit
                                default_output_format
                        );

use Log::Any::Adapter;
use Plack::Util::SubSpec qw(errpage);
use Sub::Spec::Caller qw(call_sub);
use Time::HiRes qw(gettimeofday);

# VERSION

sub prepare_app {
    my $self = shift;
    $self->{allow_return_json} //= 1;
    $self->{allow_return_yaml} //= 1;
    $self->{allow_return_php}  //= 1;
    $self->{default_output_format} //= 'json';
}

sub call {
    my ($self, $env) = @_;

    unless ($env->{'ss.request.opts'}{type} eq 'call') {
        return $self->app->($env);
    }

    die "This middleware needs psgi.streaming support"
        unless $env->{'psgi.streaming'};

    my $opts = $env->{'ss.request.opts'};
    my $ofmt = $opts->{output_format} // $self->default_output_format;
    return errpage("Unknown output format: $ofmt")
        unless $ofmt =~ /^\w+/ && $self->can("format_$ofmt");

    return sub {
        my $respond = shift;

        my $call_sub = sub {
            my $time_limit = $self->time_limit // 0;
            if (ref($time_limit) eq 'CODE') {
                $time_limit = $time_limit->($self, $env) // 0;
            }
            $time_limit += 0;

            my $sub_res;
            eval {
                local $SIG{ALRM} = sub { die "Timed out\n" };
                alarm $time_limit;
                $env->{'ss.start_call_time'} = [gettimeofday];
                $sub_res = call_sub(
                    $env->{'ss.request.module'},
                    $env->{'ss.request.sub'},
                    $env->{'ss.request.args'},
                    {load=>0, convert_datetime_objects=>1});
                $env->{'ss.finish_call_time'} = [gettimeofday];
            };
            alarm 0;
            $sub_res // [500,
                         $@ ? ($@ =~ /Timed out/ ?
                                   "Execution timed out" :
                                       "Exception: $@") : "BUG"];
        };

        my $writer;
        my $loglvl  = $opts->{'log_level'};
        my $marklog = $opts->{'mark_log'};
        my $sub_res;
        if ($loglvl) {
            unless ($loglvl =~ /\A(?:fatal|error|warn|info|debug|trace)\z/i) {
                $respond->(errpage("Unknown log level"));
                return;
            }
            $writer = $respond->([200, ["Content-Type" => "text/plain"]]);
            Log::Any::Adapter->set(
                {lexically=>\my $lex},
                "Callback",
                logging_cb => sub {
                    my ($method, $self, $format, @params) = @_;
                    my $msg = join(
                        "",
                        $marklog ? "L" : "",
                        "[$method]",
                        "[", scalar(localtime), "] ",
                        $format, "\n");
                    $writer->write($msg);
                },
            );
            $sub_res = $call_sub->();
        } else {
            $sub_res = $call_sub->();
        }

        my $fmt_method = "format_$ofmt";
        my ($res, $ct) = $self->$fmt_method($sub_res);

        if ($writer) {
            $writer->write($marklog ? "R$res" : $res);
            $writer->close;
        } else {
            $respond->([200, ["Content-Type" => $ct], [$res]]);
        }
    };
}

sub format_json {
    my ($self, $sub_res) = @_;
    require Data::Format::Pretty::JSON;
    return (Data::Format::Pretty::JSON::format_pretty($sub_res, {pretty=>0}),
            "application/json");
}

sub format_yaml {
    my ($self, $sub_res) = @_;
    require Data::Format::Pretty::YAML;
    return (Data::Format::Pretty::YAML::format_pretty($sub_res),
            "text/yaml");
}

sub format_php {
    my ($self, $sub_res) = @_;
    require Data::Format::Pretty::PHP;
    return (Data::Format::Pretty::PHP::format_pretty($sub_res),
            "application/vnd.php.serialized");
}

1;
# ABSTRACT: Call subroutine and format the result

=head1 SYNOPSIS

 # in your app.psgi
 use Plack::Builder;

 builder {
     # enable other middlewares ...
     enable "SubSpec::ServeCall";
     # enable other middlewares ...
 };


=head1 DESCRIPTION

This middleware uses L<Sub::Spec::Caller> to call the requested subroutine and
format its result. Will do nothing if request type
($env->{'ss.request.opts'}{'type'}) is not 'call'. Error 500 will be returned if
requested output format is unknown/unallowed.

Additionally, this middleware also provide timing information in
$env->{'ss.start_call_time'} and $env->{'ss.finish_call_time'} (utilized by the
AccessLog middleware).


=head1 CONFIGURATIONS

=over 4

=item * default_output_format => STR ('json'|'yaml'|'php'), default 'json'

The default format to use if client does not specify 'output_format' request
option.

=item * allow_return_json => BOOL (default 1)

Whether we should comply when client requests JSON-encoded return data.

=item * allow_return_yaml => BOOL (default 1)

Whether we should comply when client requests YAML-encoded return data.

=item * allow_return_php => BOOL (default 1)

Whether we should comply when client requests PHP serialization-encoded return
data.

=item * time_limit => INT | CODE

Impose time limit, using alarm(). If coderef is given, it will be called for
every request with ($self, $env) argument and expected to return the time limit.

=back


=head1 SEE ALSO

L<Plack::Middleware::SubSpec::ServeHelp>

=cut
