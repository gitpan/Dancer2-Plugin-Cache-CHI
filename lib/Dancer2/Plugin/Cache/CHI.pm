package Dancer2::Plugin::Cache::CHI;
BEGIN {
  $Dancer2::Plugin::Cache::CHI::AUTHORITY = 'cpan:YANICK';
}
# ABSTRACT: Dancer plugin to cache response content (and anything else)
$Dancer2::Plugin::Cache::CHI::VERSION = '1.6.0';
use strict;
use warnings;
no warnings qw/ uninitialized /;

use Carp;
use CHI;

use Dancer2 0.140001;

use Dancer2::Plugin;

with 'Dancer2::Plugin';

register_hook 'before_create_cache';


my %cache;
my $cache_page; # actually hold the ref to the args
my $cache_page_key_generator = sub {
    return $_[0]->request->{path_info};
};

on_plugin_import {
    my $dsl = shift;

    $dsl->app->add_hook(
        Dancer2::Core::Hook->new(
            name => 'after',
            code => sub {
                return unless $cache_page;

                my $resp = shift;
                cache($dsl)->set( $cache_page_key_generator->($dsl),
                    {
                        status      => $resp->status,
                        headers     => $resp->headers_to_array,
                        content     => $resp->content
                    },
                    @$cache_page,
                );

                $cache_page = undef;
            }
    ));
};

register cache => sub {
    my $dsl = shift;
    return  $cache{$_[0]//''} ||= _create_cache( $dsl, @_ );
};

my $honor_no_cache = 0;

sub _create_cache {
    my $dsl = shift;
    my $namespace = shift;
    my $args = shift || {};

    $dsl->execute_hook( 'before_create_cache' );

    my %setting = %{
        $dsl->dancer_app->config->{plugins}{'Cache::CHI'} || {}
    };

    $setting{namespace} = $namespace if defined $namespace;

    while( my ( $k, $v ) = each %$args ) {
        $setting{$k} = $v;
    }

    $honor_no_cache = delete $setting{honor_no_cache}
        if exists $setting{honor_no_cache};

    return CHI->new(%setting);
}



register check_page_cache => sub {
    my $dsl = shift;

    my $hook = sub {
        my $context = shift;

        # Instead halt() now we use a more correct method - setting of a
        # response to Dancer2::Core::Response object for a more correct returning of
        # some HTTP headers (X-Powered-By, Server)

        my $cached = cache($dsl)->get( $cache_page_key_generator->($dsl) )
            or return;

        if ( $honor_no_cache ) {

            my $req =  $dsl->request;

            return if grep { 
                # eval is there to protect from a regression in Dancer 1.31
                # where headers can be undef
                eval { $req->header($_) eq 'no-cache' }
            } qw/ Cache-Control Pragma /;
        }

        $context->response(
            Dancer2::Core::Response->new(
                is_halted => 1,
                ref $cached eq 'HASH'
                ?
                (
                    status       => $cached->{status},
                    headers      => $cached->{headers},
                    content      => $cached->{content}
                )
                :
                ( content => $cached )
            )
        );
    };

    $dsl->app->add_hook( Dancer2::Core::Hook->new(
        name => 'before',
        code => $hook,
    ));
};


register cache_page => sub {
    shift;

    my ( $content, @args ) = @_;

    $cache_page = \@args;

    return $content;
};



register cache_page_key => sub {
    shift;
    return $cache_page_key_generator->();
};


register cache_page_key_generator => sub {
    shift;
    $cache_page_key_generator = shift;
};


for my $method ( qw/ set get remove clear compute / ) {
    register 'cache_'.$method => sub {
        my $dsl = shift;
        return cache($dsl)->$method( @_ );
    }
}


register_plugin for_versions => [1,2];

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Dancer2::Plugin::Cache::CHI - Dancer plugin to cache response content (and anything else)

=head1 VERSION

version 1.6.0

=head1 SYNOPSIS

In your configuration:

    plugins:
        'Cache::CHI':
            driver: Memory
            global: 1

In your application:

    use Dancer2;
    use Dancer2::Plugin::Cache::CHI;

    # caching pages' response

    check_page_cache;

    get '/cache_me' => sub {
        cache_page template 'foo';
    };

    # using the helper functions

    get '/clear' => sub {
        cache_clear;
    };

    put '/stash' => sub {
        cache_set secret_stash => request->body;
    };

    get '/stash' => sub {
        return cache_get 'secret_stash';
    };

    del '/stash' => {
        return cache_remove 'secret_stash';
    };

    # using the cache directly

    get '/something' => sub {
        my $thingy = cache->compute( 'thingy', sub { compute_thingy() } );

        return template 'foo' => { thingy => $thingy };
    };

=head1 DESCRIPTION

This plugin provides Dancer2 with an interface to a L<CHI> cache. Also, it
includes a mechanism to easily cache the response of routes.

=head1 CONFIGURATION

Unrecognized configuration elements are passed directly to the L<CHI> object's
constructor. For example, the configuration given in the L</SYNOPSIS>
will create a cache object equivalent to

    $cache = CHI->new( driver => 'Memory', global => 1, );

=head2 honor_no_cache

If the parameter 'C<honor_no_cache>' is set to true, a request with the http
header 'C<Cache-Control>' or 'C<Pragma>' set to 'I<no-cache>' will ignore any
content cached via 'C<cache_page>' and will have the page regenerated anew.

=head1 KEYWORDS

=head2 cache

Returns the L<CHI> cache object.

=head2 cache $namespace, \%args

L<CHI> only allows one namespace per object. But you can create more caches by
using I<cache $namespace, \%args>. The new cache uses the arguments as defined in
the configuration, which values can be overriden by the optional arguments
(which are only used on the first invocation of the namespace).

    get '/memory' => sub {
        cache('elephant')->get( 'stuff' );
    };

    get '/goldfish' => sub {
        cache( 'goldfish' => { expires_in => 300 } )->get( 'stuff' );
    };

Note that all the other keywords (C<cache_page>, C<cache_set>, etc) will still
use the main cache object.

=head2 check_page_cache

If invoked, returns the cached response of a route, if available.

The C<path_info> attribute of the request is used as the key for the route,
so the same route requested with different parameters will yield the same
cached content. Caveat emptor.

=head2 cache_page($content, $expiration)

Caches the I<$content> to be served to subsequent requests.
The headers and http status of the response are also cached.

The I<$expiration> parameter is optional.

=head2 cache_page_key

Returns the cache key used by 'C<cache_page>'. Defaults to
to the request's I<path_info>, but can be modified via
I<cache_page_key_generator>.

=head2 cache_page_key_generator( \&sub )

Sets the function that generates the cache key for I<cache_page>.

For example, to have the key contains both information about the request's
hostname and path_info (useful to deal with multi-machine applications):

    cache_page_key_generator sub {
        return join ':', request()->host, request()->path_info;
    };

=head2 cache_set, cache_get, cache_remove, cache_clear, cache_compute

Shortcut to the cache's object methods.

    get '/cache/:attr/:value' => sub {
        # equivalent to cache->set( ... );
        cache_set $params->{attr} => $params->{value};
    };

See the L<CHI> documentation for further info on these methods.

=head1 HOOKS

=head2 before_create_cache

Called before the creation of the cache, which is lazily done upon
its first use.

Useful, for example, to change the cache's configuration at run time:

    use Sys::Hostname;

    # set the namespace to the current hostname
    hook before_create_cache => sub {
        config->{plugins}{'Cache::CHI'}{namespace} = hostname;
    };

=head1 SEE ALSO

Dancer2 Web Framework - L<Dancer2>

L<CHI>

L<Dancer::Plugin::Memcached> - plugin that heavily inspired this one.

=head1 AUTHOR

Yanick Champoux <yanick@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2013 by Yanick Champoux.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
