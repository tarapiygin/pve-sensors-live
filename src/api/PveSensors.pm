# SPDX-License-Identifier: MIT
package PVE::API2::PveSensors;

use strict;
use warnings;
use JSON::PP qw(decode_json);
use PVE::Exception qw(raise);
use PVE::JSONSchema qw(get_standard_option);
use PVE::Tools qw(file_get_contents);
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    name => 'snapshot',
    path => '',
    method => 'GET',
    description => 'Read the sanitized PVE Sensors Live snapshot.',
    proxyto => 'node',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => { node => get_standard_option('pve-node') },
    },
    returns => { type => 'object', additionalProperties => 1 },
    code => sub {
        # Collection and sanitization stay in the unprivileged agent. Never run
        # sensors, accept a filesystem path, or return raw read/decode errors.
        my $snapshot = eval {
            decode_json(file_get_contents('/run/pve-sensors/metrics.json'));
        };
        raise('Sensor snapshot unavailable', code => 503)
            if $@ || ref($snapshot) ne 'HASH' || ref($snapshot->{metrics}) ne 'ARRAY';
        return $snapshot;
    },
});

1;
