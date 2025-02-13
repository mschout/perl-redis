#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Redis;
use lib 't/tlib';
use Test::SpawnRedisServer;
use Test::Deep;

use constant SSL_AVAILABLE => eval { require IO::Socket::SSL } || 0;

my ($c, $t, $srv) = redis();
END {
  $c->() if $c;
  $t->() if $t;
}

my $use_ssl = $t ? SSL_AVAILABLE : 0;

{
my $r = Redis->new(server => $srv, ssl => $use_ssl, SSL_verify_mode => 0);
eval { $r->multi( ); };
plan 'skip_all' => "multi without arguments not implemented on this redis server"  if $@ && $@ =~ /unknown command/;
}


ok(my $r = Redis->new(server => $srv,
                      ssl => $use_ssl,
                      SSL_verify_mode => 0), 'connected to our test redis-server');

sub pipeline_ok {
  my ($desc, @commands) = @_;
  my (@responses, @expected_responses);
  for my $cmd (@commands) {
    my ($method, $args, $expected, $expected_err) = @$cmd;
    push @expected_responses, [$expected, $expected_err];
    $r->$method(@$args, sub { push @responses, [@_] });
  }
  $r->wait_all_responses;

  cmp_deeply(\@responses, \@expected_responses, $desc);
}

pipeline_ok 'single-command pipeline', ([set => [foo => 'bar'], 'OK'],);

pipeline_ok 'pipeline with embedded error',
  ([set => [clunk => 'eth'], 'OK'], [oops => [], undef, re(qr{^ERR unknown command .OOPS.})], [get => ['clunk'], 'eth'],);

pipeline_ok 'keys in pipelined mode',
  ([keys => ['*'], bag(qw<foo clunk>)], [keys => [], undef, q[ERR wrong number of arguments for 'keys' command]],);

pipeline_ok 'info in pipelined mode',
  (
  [info => [], code(sub { ref $_[0] eq 'HASH' && keys %{ $_[0] } })],
  $r->info->{redis_version} eq '7.0.0' ? (
    [ info => [qw<oops oops>],
      {},
    ],
  ) : (
    [ info => [qw<oops oops>],
      undef,
      re(qr{^ERR (?:syntax error|wrong number of arguments for 'info' command)$})
    ],
  )
  );

pipeline_ok 'pipeline with multi-bulk reply',
  ([hmset => [kapow => (a => 1, b => 2, c => 3)], 'OK'], [hmget => [kapow => qw<c b a>], [3, 2, 1]],);

pipeline_ok 'large pipeline',
  (
  (map { [hset => [zzapp => $_ => -$_], 1] } 1 .. 5000),
  [hmget => [zzapp => (1 .. 5000)], [reverse -5000 .. -1]],
  [del => ['zzapp'], 1],
  );

subtest 'synchronous request with pending pipeline' => sub {
  my $clunk;
  is($r->get('clunk', sub { $clunk = $_[0] }), 1, 'queue a request');
  is($r->set('kapow', 'zzapp', sub { }), 1, 'queue another request');
  is($r->get('kapow'), 'zzapp', 'synchronous request has expected return');
  is($clunk,           'eth',   'synchronous request processes pending ones');
};

subtest 'transaction with error and pipeline' => sub {
    my @responses;
    my $s = sub { push @responses, [@_] };
    $r->multi($s);
    $r->set(clunk => 'eth', $s);
    $r->rpush(clunk => 'oops', $s);
    $r->get('clunk', $s);
    $r->exec($s);
    $r->wait_all_responses;

    is(shift(@responses)->[0], 'OK'    , 'multi started' );
    is(shift(@responses)->[0], 'QUEUED', 'queued');
    is(shift(@responses)->[0], 'QUEUED', 'queued');
    is(shift(@responses)->[0], 'QUEUED', 'queued');
    my $resp = shift @responses;
    is ($resp->[0]->[0]->[0], 'OK', 'set');
    is ($resp->[0]->[1]->[0], undef, 'bad rpush value should be undef');
    like ($resp->[0]->[1]->[1],
          qr/(?:ERR|WRONGTYPE) Operation against a key holding the wrong kind of value/,
          'bad rpush should give an error');
    is ($resp->[0]->[2]->[0], 'eth', 'get should work');
};

subtest 'transaction with error and no pipeline' => sub {
  is($r->multi, 'OK', 'multi');
  is($r->set('clunk', 'eth'), 'QUEUED', 'transactional SET');
  is($r->rpush('clunk', 'oops'), 'QUEUED', 'transactional bad RPUSH');
  is($r->get('clunk'), 'QUEUED', 'transactional GET');
  like(
    exception { $r->exec },
    qr{\[exec\] (?:WRONGTYPE|ERR) Operation against a key holding the wrong kind of value,},
    'synchronous EXEC dies for intervening error'
  );
};


subtest 'wait_one_response' => sub {
  my $first;
  my $second;

  $r->get('a', sub { $first++ });
  $r->get('a', sub { $second++ });
  $r->get('a', sub { $first++ });
  $r->get('a', sub { $second++ });

  $r->wait_one_response();
  is($first,  1,     'after first wait_one_response(), first callback called');
  is($second, undef, '... but not the second one');

  $r->wait_one_response();
  is($first,  1, 'after second wait_one_response(), first callback was not called again');
  is($second, 1, '... but the second one was called');

  $r->wait_all_responses();
  is($first,  2, 'after final wait_all_responses(), first callback was called again');
  is($second, 2, '... the second one was also called');

  $r->wait_one_response();
  is($first,  2, 'after final wait_one_response(), first callback was not called again');
  is($second, 2, '... nor was the second one');
};


done_testing();
