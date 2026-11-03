# SPDX-License-Identifier: MIT
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json);

# Portable unit harness: capture the native API registration and replace only
# PVE integration boundaries. This is NOT a real ticket/ACL integration test.
BEGIN {
    package PVE::RESTHandler;
    our $method;
    sub register_method { $method = $_[1]; }
    $INC{'PVE/RESTHandler.pm'} = 1;

    package PVE::JSONSchema;
    use Exporter 'import';
    our @EXPORT_OK = qw(get_standard_option);
    sub get_standard_option { return { type => 'string', format => $_[0] }; }
    $INC{'PVE/JSONSchema.pm'} = 1;

    package PVE::Exception;
    use Exporter 'import';
    our @EXPORT_OK = qw(raise);
    sub raise { my ($message, %args) = @_; die "$args{code}: $message\n"; }
    $INC{'PVE/Exception.pm'} = 1;

    package PVE::Tools;
    use Exporter 'import';
    our @EXPORT_OK = qw(file_get_contents);
    our ($body, $error, $path, $reads);
    sub file_get_contents {
        $path = $_[0]; $reads++;
        die $error if $error;
        return $body;
    }
    $INC{'PVE/Tools.pm'} = 1;
}

require './src/api/PveSensors.pm';
my $method = $PVE::RESTHandler::method;
is($method->{method}, 'GET', 'only GET is registered');
is($method->{path}, '', 'mounted directly at the sensors subpath');
is($method->{proxyto}, 'node', 'remote node requests use native node proxying');
is_deeply($method->{permissions}, {
    check => ['perm', '/nodes/{node}', ['Sys.Audit']],
}, 'native node-scoped Sys.Audit check; no public/user-all bypass');
is_deeply([sort keys %{$method->{parameters}->{properties}}], ['node'], 'no client-selected filesystem path');
is($method->{parameters}->{additionalProperties}, 0, 'unexpected parameters rejected');

my $snapshot = { version => '2.0.0', metrics => [{ id => 'cpu-1', name => 'CPU 1', value => 42.5 }], sequence => 7 };
$PVE::Tools::body = encode_json($snapshot);
is_deeply($method->{code}->({node => 'test-node'}), $snapshot, 'snapshot preserved without envelope or identifiers');
is($PVE::Tools::path, '/run/pve-sensors/metrics.json', 'fixed private runtime snapshot');
is($PVE::Tools::reads, 1, 'one file read per request');
$PVE::Tools::body = encode_json({%$snapshot, sequence => 8});
is($method->{code}->({node => 'test-node'})->{sequence}, 8, 'next call reads the current snapshot');

for my $body ('{private-invalid-json', 'null', '[]', '{}', '{"metrics":{}}') {
    $PVE::Tools::body = $body;
    eval { $method->{code}->({node => 'test-node'}); };
    is($@, "503: Sensor snapshot unavailable\n", 'invalid snapshot fails with generic 503');
}
$PVE::Tools::error = 'private hostname and low-level filesystem details';
eval { $method->{code}->({node => 'test-node'}); };
is($@, "503: Sensor snapshot unavailable\n", 'missing/unreadable snapshot does not expose raw error');
done_testing();
