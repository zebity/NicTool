package NicToolServer;

# NicTool v2.00-rc1 Copyright 2001 Damon Edwards, Abe Shelton & Greg Schueler
# NicTool v2.01+    Copyright 2004-2008 The Network People, Inc.
#
# NicTool is free software; you can redistribute it and/or modify it under
# the terms of the Affero General Public License as published by Affero,
# Inc.; either version 1 of the License, or any later version.
#
# NicTool is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE. See the Affero GPL for details.
#
# You should have received a copy of the Affero General Public License
# along with this program; if not, write to Affero Inc., 521 Third St,
# Suite 225, San Francisco, CA 94107, USA
#

use strict;
use RPC::XML;
use Data::Dumper;
use Net::IP;

$NicToolServer::VERSION = '2.09';

$NicToolServer::MIN_PROTOCOL_VERSION = '1.0';
$NicToolServer::MAX_PROTOCOL_VERSION = '1.0';

sub new {
    bless {
        'Apache' => $_[1],
        'client' => $_[2],
        'dbh'    => $_[3],
        'meta'   => $_[4],
        'user'   => $_[5],
        },
        $_[0];
}

sub debug             {0}
sub debug_session_sql {0}
sub debug_sql         {0}
sub debug_permissions {0}
sub debug_result      {0}
sub debug_request     {0}
sub debug_logs        {0}

sub handler {
    my $r = shift;

    my $dbh = &NicToolServer::dbh;
    my $dbix = &NicToolServer::dbix;

    # create & initialize required objects
    my $client_obj = NicToolServer::Client->new( $r, $dbh );
    my $self = NicToolServer->new( $r, $client_obj, $dbh, {} );
    my $response_obj = NicToolServer::Response->new( $r, $client_obj );

# process session verification, login or logouts by just responding with the user hash

    my $error = NicToolServer::Session->new( $r, $client_obj, $dbh )->verify();
    warn "request: " . Data::Dumper::Dumper( $client_obj->data )
        if $self->debug_request;
    warn "request: error: " . Data::Dumper::Dumper($error)
        if $self->debug_request and $error;
    return $response_obj->respond($error) if $error;
    my $action = uc( $client_obj->data()->{'action'} );
    if (   $action eq 'LOGIN'
        or $action eq 'VERIFY_SESSION'
        or $action eq 'LOGOUT' )
    {

#warn "result of session verify: ".Data::Dumper::Dumper($client_obj->data->{'user'});
        return $response_obj->respond( $client_obj->data()->{'user'} );
    };

    $self->{'user'} = $client_obj->data()->{'user'};

    my $cmd = $self->api_commands->{ $action } or do {
        # fart on unknown actions
        warn "unknown NicToolServer action: $action\n" if $self->debug;
        $response_obj->respond( $self->error_response( 500, $action ) );
    };

    # check permissions
    $error = $self->verify_obj_usage( $cmd, $client_obj->data(), $action);
    return $response_obj->respond($error) if $error;

    # create obj, call method, return response
    my $class = 'NicToolServer::' . $cmd->{'class'};
    my $obj   = $class->new(
        $self->{'Apache'}, $self->{'client'}, $self->{'dbh'},
        $self->{'meta'},   $self->{'user'}
    );
    my $method = $cmd->{'method'};
    warn "calling NicToolServer action: $cmd->{'class'}::$cmd->{'method'} ("
        . $action . ")\n" if $self->debug;
    my $res;
    eval { $res = $obj->$method( $client_obj->data() ) };
    warn "result: " . Data::Dumper::Dumper($res) if $self->debug_result;

    if ($@) {
        return $response_obj->send_error( $self->error_response( 508, $@ ) );
    }
    return $response_obj->respond($res);

    $dbh->disconnect;
}

#check the protocol version if included
sub ver_check {
    my $self = shift;
    my $pv   = $self->{'client'}->protocol_version;
    return undef unless $pv;
    return $self->error_response( 510,
        "This server requires at least protocol version $NicToolServer::MIN_PROTOCOL_VERSION. You have specified protocol version $pv"
    ) if $pv lt $NicToolServer::MIN_PROTOCOL_VERSION;
    return $self->error_response( 510,
        "This server allows at most protocol version $NicToolServer::MIN_PROTOCOL_VERSION. You have specified protocol version $pv"
    ) if $pv gt $NicToolServer::MAX_PROTOCOL_VERSION;
}

sub api_commands {
    my $self = shift;
    {

        # user API
        'get_user' => {
            'class'      => 'User',
            'method'     => 'get_user',
            'parameters' => {
                'nt_user_id' =>
                    { access => 'read', required => 1, type => 'USER' },
            },
        },
        'new_user' => {
            'class'      => 'User::Sanity',
            'method'     => 'new_user',
            'creation'   => 'USER',
            'parameters' => {
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
                'username'  => { required => 1 },
                'email'     => { required => 1 },
                'password'  => { required => 1 },
                'password2' => { required => 1 },
            },
        },
        'edit_user' => {
            'class'      => 'User::Sanity',
            'method'     => 'edit_user',
            'parameters' => {
                'nt_user_id' =>
                    { access => 'write', required => 1, type => 'USER' },
                'usable_nameservers' => {
                    access   => 'read',
                    type     => 'NAMESERVER',
                    list     => 1,
                    empty    => 1,
                    required => 0
                },
            },
        },
        'delete_users' => {
            'class'      => 'User',
            'method'     => 'delete_users',
            'parameters' => {
                'user_list' => {
                    access   => 'delete',
                    required => 1,
                    type     => 'USER',
                    list     => 1
                },
            },
        },
        'get_group_users' => {
            'class'      => 'User::Sanity',
            'method'     => 'get_group_users',
            'parameters' => {
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
            },
        },
        'get_user_list' => {
            'class'      => 'User::Sanity',
            'method'     => 'get_user_list',
            'parameters' => {
                'user_list' => {
                    access   => 'read',
                    required => 1,
                    type     => 'USER',
                    list     => 1
                },
            },
        },
        'move_users' => {
            'class'      => 'User::Sanity',
            'method'     => 'move_users',
            'parameters' => {
                'user_list' => {
                    access   => 'write',
                    required => 1,
                    type     => 'USER',
                    list     => 1
                },
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
            },
        },
        'get_user_global_log' => {
            'class'      => 'User::Sanity',
            'method'     => 'get_user_global_log',
            'parameters' => {
                'nt_user_id' =>
                    { access => 'read', required => 1, type => 'USER' },
            },
        },

        # group API

        'get_group' => {
            'class'      => 'Group',
            'method'     => 'get_group',
            'parameters' => {
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
            },
        },

        'save_group' => {    # deprecated
            'result' => $self->error_response(
                503, 'save_group, use new_group or edit_group'
            ),
        },

        'new_group' => {
            'class'      => 'Group::Sanity',
            'method'     => 'new_group',
            'creation'   => 'GROUP',
            'parameters' => {
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
                'name'               => { required => 1 },
                'usable_nameservers' => {
                    required => 0,
                    access   => 'read',
                    type     => 'NAMESERVER',
                    list     => 1
                },
            },
        },
        'edit_group' => {
            'class'      => 'Group::Sanity',
            'method'     => 'edit_group',
            'parameters' => {
                'nt_group_id' =>
                    { 'access' => 'write', required => 1, type => 'GROUP' },
                'usable_nameservers' => {
                    required => 0,
                    access   => 'read',
                    empty    => 1,
                    type     => 'NAMESERVER',
                    list     => 1
                },
            },
        },
        'delete_group' => {
            'class'      => 'Group',
            'method'     => 'delete_group',
            'parameters' => {
                'nt_group_id' =>
                    { 'access' => 'delete', required => 1, type => 'GROUP' },
            },
        },
        'get_group_groups' => {
            'class'      => 'Group',
            'method'     => 'get_group_groups',
            'parameters' => {
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
            },
        },
        'get_group_branch' => {
            'class'      => 'Group',
            'method'     => 'get_group_branch',
            'parameters' => {
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
            },
        },
        'get_group_subgroups' => {
            'class'      => 'Group::Sanity',
            'method'     => 'get_group_subgroups',
            'parameters' => {
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
            },
        },
        'get_global_application_log' => {
            'class'      => 'Group::Sanity',
            'method'     => 'get_global_application_log',
            'parameters' => {
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
            },
        },

        # zone API
        'get_zone' => {
            'class'      => 'Zone',
            'method'     => 'get_zone',
            'parameters' => {
                'nt_zone_id' =>
                    { access => 'read', required => 1, type => 'ZONE' },
            },
        },

        'get_group_zones' => {
            'class'      => 'Zone::Sanity',
            'method'     => 'get_group_zones',
            'parameters' => {
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
            },
        },
        'get_group_zones_log' => {
            'class'      => 'Zone::Sanity',
            'method'     => 'get_group_zones_log',
            'parameters' => {
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
            },
        },
        'get_group_zone_query_log' => {
            'class'      => 'Zone::Sanity',
            'method'     => 'get_group_zone_query_log',
            'parameters' => {
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
            },
        },
        'save_zone' => {
            'result' => $self->error_response(
                503, 'save_zone.  Use edit_zone or new_zone.'
            ),
        },
        'new_zone' => {
            'class'      => 'Zone::Sanity',
            'method'     => 'new_zone',
            'creation'   => 'ZONE',
            'parameters' => {
                'nameservers' => {
                    access   => 'read',
                    required => 0,
                    type     => 'NAMESERVER',
                    list     => 1
                },
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
                'zone' => { required => 1 },
            },
        },
        'edit_zone' => {
            'class'      => 'Zone::Sanity',
            'method'     => 'edit_zone',
            'parameters' => {
                'nt_zone_id' =>
                    { 'access' => 'write', required => 1, type => 'ZONE' },
                'nameservers' => {
                    access   => 'read',
                    required => 0,
                    type     => 'NAMESERVER',
                    list     => 1,
                    empty    => 1
                },
            },
        },
        'delete_zones' => {
            'class'      => 'Zone',
            'method'     => 'delete_zones',
            'parameters' => {
                'zone_list' => {
                    access   => 'delete',
                    delegate => 'none',
                    pseudo   => 'none',
                    required => 1,
                    type     => 'ZONE',
                    list     => 1
                },
            },
        },
        'get_zone_log' => {
            'class'      => 'Zone',
            'method'     => 'get_zone_log',
            'parameters' => {
                'nt_zone_id' =>
                    { 'access' => 'read', required => 1, type => 'ZONE' },
            },
        },
        'get_zone_records' => {
            'class'      => 'Zone::Sanity',
            'method'     => 'get_zone_records',
            'parameters' => {
                'nt_zone_id' =>
                    { 'access' => 'read', required => 1, type => 'ZONE' },
            },
        },

      #'get_zone_application_log' => {
      #'class'     => 'Zone',
      #'method'    => 'get_zone_application_log',
      #'parameters'=>{'nt_zone_id'=>{access=>'read',required=>1,type=>'ZONE'},
      #},
      #},
        'move_zones' => {
            'class'      => 'Zone::Sanity',
            'method'     => 'move_zones',
            'parameters' => {
                'zone_list' => {
                    access   => 'write',
                    required => 1,
                    type     => 'ZONE',
                    list     => 1
                },
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
            },
        },
        'get_zone_list' => {
            'class'      => 'Zone',
            'method'     => 'get_zone_list',
            'parameters' => {
                'zone_list' => {
                    access   => 'read',
                    required => 1,
                    type     => 'ZONE',
                    list     => 1
                },
            },
        },

        # zone_record API

        'save_zone_record' => {
            'result' => $self->error_response(
                503,
                'save_zone_record.  Use edit_zone_record or new_zone_record.'
            ),
        },
        'new_zone_record' => {
            'class'      => 'Zone::Record::Sanity',
            'method'     => 'new_zone_record',
            'creation'   => 'ZONERECORD',
            'parameters' => {
                'nt_zone_id' => {
                    access   => 'read',
                    pseudo   => 'none',
                    delgate  => 'zone_perm_add_records',
                    required => 1,
                    type     => 'ZONE'
                },
                'name' => { required => 1 },

                #'ttl'=>{required=>1},
                'address' => { required => 1 },
                'type'    => { required => 1 },
            },
        },
        'edit_zone_record' => {
            'class'      => 'Zone::Record::Sanity',
            'method'     => 'edit_zone_record',
            'parameters' => {
                'nt_zone_record_id' => {
                    access   => 'write',
                    required => 1,
                    type     => 'ZONERECORD'
                },
            },
        },
        'delete_zone_record' => {
            'class'      => 'Zone::Record',
            'method'     => 'delete_zone_record',
            'parameters' => {
                'nt_zone_record_id' => {
                    access   => 'delete',
                    pseudo   => 'zone_perm_delete_records',
                    delegate => 'none',
                    required => 1,
                    type     => 'ZONERECORD'
                },
            },
        },
        'get_zone_record' => {
            'class'      => 'Zone::Record',
            'method'     => 'get_zone_record',
            'parameters' => {
                'nt_zone_record_id' =>
                    { access => 'read', required => 1, type => 'ZONERECORD' },
            },
        },
        'get_zone_record_log' => {
            'class'      => 'Zone::Sanity',
            'method'     => 'get_zone_record_log',
            'parameters' => {
                'nt_zone_id' =>
                    { access => 'read', required => 1, type => 'ZONE' },
            },
        },
        'get_zone_record_log_entry' => {
            'class'      => 'Zone::Record',
            'method'     => 'get_zone_record_log_entry',
            'parameters' => {
                'nt_zone_record_log_id' => { required => 1, id => 1 },
                'nt_zone_record_id' =>
                    { access => 'read', required => 1, type => 'ZONERECORD' },
            },
        },

        # nameserver API
        'get_nameserver' => {
            'class'      => 'Nameserver',
            'method'     => 'get_nameserver',
            'parameters' => {

         #'nt_nameserver_id'=>{access=>'read',required=>1,type=>'NAMESERVER'},
                'nt_nameserver_id' => { required => 1, type => 'NAMESERVER' },
            },
        },
        'get_nameserver_tree' => {
            'result' => $self->error_response(
                503, 'get_nameserver_tree.  Use get_usable_nameservers.'
            ),

 #'class'     => 'Nameserver',
 #'method'    => 'get_usable_nameservers',
 #'parameters'=>{ 'nt_group_id'=>{'access'=>'read',required=>1,type=>'GROUP'},
 #},
        },
        'get_usable_nameservers' => {
            'class'      => 'Nameserver',
            'method'     => 'get_usable_nameservers',
            'parameters' => {
                'nt_group_id' =>
                    { 'access' => 'read', required => 0, type => 'GROUP' },
            },
        },
        'save_nameserver' => {
            'result' => $self->error_response(
                503,
                'save_nameserver.  Use edit_nameserver or new_nameserver.'
            ),
        },
        'new_nameserver' => {
            'class'      => 'Nameserver::Sanity',
            'method'     => 'new_nameserver',
            'creation'   => 'NAMESERVER',
            'parameters' => {
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
                'address'       => { required => 1 },
                'name'          => { required => 1 },
                'service_type'  => { required => 1 },
                'output_format' => { required => 1 },
            },
        },
        'edit_nameserver' => {
            'class'      => 'Nameserver::Sanity',
            'method'     => 'edit_nameserver',
            'parameters' => {
                'nt_nameserver_id' => {
                    access   => 'write',
                    required => 1,
                    type     => 'NAMESERVER'
                },
            },
        },
        'delete_nameserver' => {
            'class'      => 'Nameserver',
            'method'     => 'delete_nameserver',
            'parameters' => {
                'nt_nameserver_id' => {
                    access   => 'delete',
                    required => 1,
                    type     => 'NAMESERVER'
                },
            },
        },
        'get_group_nameservers' => {
            'class'      => 'Nameserver::Sanity',
            'method'     => 'get_group_nameservers',
            'parameters' => {
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
            },
        },
        'get_nameserver_list' => {
            'class'      => 'Nameserver',
            'method'     => 'get_nameserver_list',
            'parameters' => {
                'nameserver_list' => {
                    access   => 'read',
                    required => 1,
                    type     => 'NAMESERVER',
                    list     => 1
                },
            },
        },
        'move_nameservers' => {
            'class'      => 'Nameserver::Sanity',
            'method'     => 'move_nameservers',
            'parameters' => {
                'nameserver_list' => {
                    access   => 'write',
                    required => 1,
                    type     => 'NAMESERVER',
                    list     => 1
                },
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
            },
        },

        #Permissions API
        'get_group_permissions' => {
            'class'      => 'Permission',
            'method'     => 'get_group_permissions',
            'parameters' => {
                'nt_group_id' =>
                    { access => 'read', required => 1, type => 'GROUP' },
            },
        },
        'get_user_permissions' => {
            'class'      => 'Permission',
            'method'     => 'get_user_permissions',
            'parameters' => {
                'nt_user_id' =>
                    { access => 'read', required => 1, type => 'USER' },
            },
        },

#delegation
#'delegate_objects'=> {
#'class' =>  'Permission',
#'method'=>  'delegate_objects',
#'parameters'=>{'nt_object_id_list'=>{list=>1,access=>'delegate',required=>1,type=>'parameters:nt_object_type'},
#'nt_object_type'=>{required=>1},
#'nt_group_id'=>{'access'=>'read',required=>1,type=>'GROUP'},
#},
#},
#'delegate_groups'=> {
#'class' =>  'Permission',
#'method'=>  'delegate_groups',
#'parameters'=>{'group_list'=>{list=>1,access=>'delegate',required=>1,type=>'GROUP'},
#'nt_group_id'=>{'access'=>'read',required=>1,type=>'GROUP'},
#},
#},
        'delegate_zones' => {
            'class'      => 'Permission',
            'method'     => 'delegate_zones',
            'parameters' => {
                'zone_list' => {
                    list     => 1,
                    access   => 'delegate',
                    delegate => 'perm_delegate',
                    pseudo   => 'none',
                    required => 1,
                    type     => 'ZONE'
                },
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
            },
        },
        'delegate_zone_records' => {
            'class'      => 'Permission',
            'method'     => 'delegate_zone_records',
            'parameters' => {
                'zonerecord_list' => {
                    list     => 1,
                    access   => 'delegate',
                    delegate => 'perm_delegate',
                    pseudo   => 'none',
                    required => 1,
                    type     => 'ZONERECORD'
                },
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
            },
        },

#'delegate_nameservers'=> {
#'class' =>  'Permission',
#'method'=>  'delegate_nameservers',
#'parameters'=>{'nameserver_list'=>{list=>1,access=>'delegate',required=>1,type=>'NAMESERVER'},
#'nt_group_id'=>{'access'=>'read',required=>1,type=>'GROUP'},
#},
#},

#'edit_group_delegation'=> {
#'class' =>  'Permission',
#'method'=>  'edit_group_delegation',
#'parameters'=>{'delegate_nt_group_id'=>{access=>'delegate',required=>1,type=>'GROUP'},
#'nt_group_id'=>{'access'=>'read',required=>1,type=>'GROUP'},
#},
#},
        'edit_zone_delegation' => {
            'class'      => 'Permission',
            'method'     => 'edit_zone_delegation',
            'parameters' => {
                'nt_zone_id' => {
                    access   => 'delegate',
                    delegate => 'none',
                    pseudo   => 'none',
                    required => 1,
                    type     => 'ZONE'
                },
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
            },
        },
        'edit_zone_record_delegation' => {
            'class'      => 'Permission',
            'method'     => 'edit_zone_record_delegation',
            'parameters' => {
                'nt_zone_record_id' => {
                    access   => 'delegate',
                    delegate => 'none',
                    pseudo   => 'none',
                    required => 1,
                    type     => 'ZONERECORD'
                },
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
            },
        },

#'edit_nameserver_delegation'=> {
#'class' =>  'Permission',
#'method'=>  'edit_nameserver_delegation',
#'parameters'=>{'nt_nameserver_id'=>{access=>'delegate',required=>1,type=>'NAMESERVER'},
#'nt_group_id'=>{'access'=>'read',required=>1,type=>'GROUP'},
#},
#},

#'delete_object_delegation'=> {
#'class' =>  'Permission',
#'method'=>  'delete_object_delegation',
#'parameters'=>{'nt_object_id'=>{access=>'delete',required=>1,type=>'parameters:nt_object_type'},
#'nt_object_type'=>{required=>1},
#'nt_group_id'=>{'access'=>'read',required=>1,type=>'GROUP'},
#},
#},
#'delete_group_delegation'=> {
#'class' =>  'Permission',
#'method'=>  'delete_group_delegation',
#'parameters'=>{'delegate_nt_group_id'=>{access=>'delete',required=>1,type=>'GROUP'},
        ##'nt_group_id'=>{'access'=>'read',required=>1,type=>'GROUP'},
        #},
        #},
        'delete_zone_delegation' => {
            'class'      => 'Permission',
            'method'     => 'delete_zone_delegation',
            'parameters' => {
                'nt_zone_id' => {
                    access   => 'delegate',
                    delegate => 'perm_delete',
                    pseudo   => 'none',
                    required => 1,
                    type     => 'ZONE'
                },
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
            },
        },
        'delete_zone_record_delegation' => {
            'class'      => 'Permission',
            'method'     => 'delete_zone_record_delegation',
            'parameters' => {
                'nt_zone_record_id' => {
                    access   => 'delegate',
                    delegate => 'perm_delete',
                    pseudo   => 'none',
                    required => 1,
                    type     => 'ZONERECORD'
                },
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
            },
        },

#'delete_nameserver_delegation'=> {
#'class' =>  'Permission',
#'method'=>  'delete_nameserver_delegation',
#'parameters'=>{'nt_nameserver_id'=>{access=>'delete',required=>1,type=>'NAMESERVER'},
#'nt_group_id'=>{'access'=>'read',required=>1,type=>'GROUP'},
#},
#},
#'get_delegated_groups'=> {
#'class' =>  'Permission',
#'method'=>  'get_delegated_groups',
#'parameters'=>{ 'nt_group_id'=>{'access'=>'read',required=>1,type=>'GROUP'},
#},
#},
        'get_delegated_zones' => {
            'class'      => 'Permission',
            'method'     => 'get_delegated_zones',
            'parameters' => {
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
            },
        },
        'get_delegated_zone_records' => {
            'class'      => 'Permission',
            'method'     => 'get_delegated_zone_records',
            'parameters' => {
                'nt_group_id' =>
                    { 'access' => 'read', required => 1, type => 'GROUP' },
            },
        },
        'get_zone_delegates' => {
            'class'      => 'Permission',
            'method'     => 'get_zone_delegates',
            'parameters' => {
                'nt_zone_id' =>
                    { access => 'read', required => 1, type => 'ZONE' },
            },
        },
        'get_zone_record_delegates' => {
            'class'      => 'Permission',
            'method'     => 'get_zone_record_delegates',
            'parameters' => {
                'nt_zone_record_id' =>
                    { access => 'read', required => 1, type => 'ZONERECORD' },
            },
        },
    };
}

sub error_response {
    my ( $self, $code, $msg ) = @_;
    my $errs = {
        200 => 'OK',
        201 => 'Warning',

        #data error
        300 => 'Sanity error',
        301 => 'Required parameters missing',
        302 => 'Some parameters were invalid',

        #logical error
        403 => 'Invalid Username and/or password',

        #403=>'You are trying to access an object outside of your tree',
        404 => 'Access Permission denied',

        #405=>'Delegation Permission denied: ',
        #406=>'Creation Permission denied: ',
        #407=>'Delegate Access Permission denied: ',

        #transport/com error
        500 => 'Request for unknown action',
        501 => 'Data transport Content-Type not supported',
        502 => 'XML-RPC Parse Error',
        503 => 'Method has been deprecated',
        505 => 'SQL error',
        507 => 'Internal consistency error',
        508 => 'Internal Error',
        510 => 'Incorrect Protocol Version',

        #failure
        600 => 'Failure',
        601 => 'Object Not Found',

        #601=>'Group has no permissions',
        #602=>'User has no permissions',
        #603=>'The delegation already exists',
        #604=>'No such delegation exists',
        #610=>'Group not found',
        700 => 'Unknown Error',
    };
    $code ||= 700;
    $msg = join( ":", caller ) if $code == 700;

    my $res = {
        'error_code' => $code,
        'error_msg'  => $msg,
        'error_desc' => $errs->{$code}
    };
    return $res;
}

sub is_error_response {
    my ( $self, $data ) = @_;
    return ( !exists $data->{'error_code'} or $data->{'error_code'} != 200 );
}

sub verify_required {
    my ( $self, $req, $data ) = @_;
    my @missing;

    foreach my $p ( @{$req} ) {

        # must exist and be a integer
        push( @missing, $p ) if !exists $data->{$p};
        push( @missing, $p ) unless ( $data->{$p} || $data->{$p} == 0 );
        foreach ( split( /,/, $data->{$p} ) ) {
            push( @missing, $p ) unless ( $self->valid_integer($_) );
        }
    }
    return 0 unless (@missing);

    return $self->error_response( 301, join( " ", @missing ) );

}

sub get_group_id {
    my ( $self, $key, $id, $type ) = @_;
    my $sql;
    my $sth;
    my $dbh = $self->{'dbh'};
    my $rid = '';
    if ( $key eq 'nt_group_id' or uc($type) eq 'GROUP' ) {
        $sql = "SELECT parent_group_id FROM nt_group WHERE nt_group_id = $id";
        $sth = $dbh->prepare($sql);
        warn "$sql\n" if $self->debug_sql;
        $sth->execute || die $dbh->errstr;
        my $auth_data = $sth->fetchrow_hashref;
        my $return    = $auth_data->{'parent_group_id'};
        $return = 1 if $return eq 0;
        $rid = $return;
    }
    elsif ( $key eq 'nt_zone_id' or uc($type) eq 'ZONE' ) {
        $sql = "SELECT nt_group_id FROM nt_zone WHERE nt_zone_id = $id";
        $sth = $dbh->prepare($sql);
        warn "$sql\n" if $self->debug_sql;
        $sth->execute || die $dbh->errstr;
        my $auth_data = $sth->fetchrow_hashref;
        $rid = $auth_data->{'nt_group_id'} if $auth_data;
    }
    elsif ( $key eq 'nt_zone_record_id' or uc($type) eq 'ZONERECORD' ) {
        $sql = "SELECT nt_zone.nt_group_id FROM nt_zone_record,nt_zone "
            . "WHERE nt_zone_record.nt_zone_record_id = $id "
            . "AND nt_zone.nt_zone_id=nt_zone_record.nt_zone_id";
        $sth = $dbh->prepare($sql);
        warn "$sql\n" if $self->debug_sql;
        $sth->execute || die $dbh->errstr;
        my $auth_data = $sth->fetchrow_hashref;
        $rid = $auth_data->{'nt_group_id'} if $auth_data;
    }
    elsif ( $key eq 'nt_nameserver_id' or uc($type) eq 'NAMESERVER' ) {
        $sql = "SELECT nt_group_id FROM nt_nameserver "
             . "WHERE nt_nameserver_id = $id";
        $sth = $dbh->prepare($sql);
        warn "$sql\n" if $self->debug_sql;

        #warn "getting nameserver group id $id :$sql";
        $sth->execute || die $dbh->errstr;
        my $auth_data = $sth->fetchrow_hashref;

        #warn "found id $auth_data->{'nt_group_id'}";
        $rid = $auth_data->{'nt_group_id'} if $auth_data;
    }
    elsif ( $key eq 'nt_user_id' or uc($type) eq 'USER' ) {
        $sql = "SELECT nt_group_id FROM nt_user WHERE nt_user_id = $id";
        $sth = $dbh->prepare($sql);
        warn "$sql\n" if $self->debug_sql;
        $sth->execute || die $dbh->errstr;
        my $auth_data = $sth->fetchrow_hashref;
        $rid = $auth_data->{'nt_group_id'} if $auth_data;
    }

    #warn "returning ID $rid";
    return $rid;
}

sub get_group_permissions {
    my ( $self, $groupid ) = @_;
    my $sql;
    my $sth;
    my $dbh = $self->{'dbh'};
    $sql = "SELECT * FROM nt_perm WHERE nt_group_id = $groupid AND nt_user_id=0 AND deleted != '1'";
    $sth = $dbh->prepare($sql);
    warn "$sql\n" if $self->debug_sql;
    $sth->execute || die $dbh->errstr;
    my $auth_data = $sth->fetchrow_hashref;
    return $auth_data;
}

sub get_user_permissions {
    my ( $self, $userid ) = @_;
    my $sql;
    my $sth;
    my $dbh = $self->{'dbh'};
    $sql = "SELECT * FROM nt_perm WHERE nt_group_id = '0' AND nt_user_id='$userid' AND deleted != '1'";
    $sth = $dbh->prepare($sql);
    warn "$sql\n" if $self->debug_sql;
    $sth->execute || die $dbh->errstr;
    my $auth_data = $sth->fetchrow_hashref;
    return $auth_data;
}

# return 1 if user has $access permissions on the object $id of type $type, else 0
sub get_access_permission {
    my ( $self, $type, $id, $access ) = @_;
    warn "##############################\nget_access_permission ("
        . join( ",", caller )
        . ")\n##############################\n"

        #"      params: ".Data::Dumper::Dumper($params).""
        if $self->debug_permissions;
    my @error = $self->check_permission( '', $id, $access, $type );
    warn "get_access_permission: @error returning " . ( $error[0] ? 0 : 1 );
    return $error[0] ? 0 : 1;
}

sub check_permission {
    my ($self,   $key,      $id,       $access, $type,
        $islist, $creation, $delegate, $pseudo
    ) = @_;

    #my $access = $api->{'parameters'}->{$key}->{'access'};
    #my $creation = $api->{'creation'};

    my $user_id  = $self->{'user'}->{'nt_user_id'};
    my $group_id = $self->{'user'}->{'nt_group_id'};
    my $obj_group_id
        = $type =~ /group/i ? $id : $self->get_group_id( $key, $id, $type );

    my $group_ok = $self->group_usage_ok($obj_group_id);

    my $permissions = $self->{'user'};

    my $debug
        = "key:$key,id:$id,type:$type,access:$access,creation:$creation,obj_group_id:$obj_group_id,group_ok:$group_ok,delegate:$delegate,pseudo:$pseudo:("
        . join( ",", caller ) . ")";

    #check creation
    if ($creation) {
        unless ( $permissions->{ lc $creation . "_create" } ) {
            warn "NO creation of $creation. $debug"
                if $self->debug_permissions;
            return ( '404', "Not allowed to create new " . lc $creation );
        }
        else {
            warn "ALLOW creation of $creation." if $self->debug_permissions;
        }
    }

    #user access
    if ( $type eq 'USER' and $id eq $user_id ) {

        #self read always true, delete false.
        $self->set_param_meta( $key, self => 1 );
        if ( $access eq 'write' ) {
            if ( $permissions->{"self_write"} ) {
                warn "YES self write. $debug" if $self->debug_permissions;
                return undef;
            }
            else {
                warn "NO self write. $debug" if $self->debug_permissions;
                return ( '404', "Not allowed to modify self" );
            }
        }
        elsif ( $access eq 'delete' ) {
            warn "NO self delete access. $debug" if $self->debug_permissions;
            return ( '404', "Not allowed to delete self" );
        }
    }

    # can't delete your own group
    if ( $type eq 'GROUP' and $id eq $group_id ) {

        # not allowed to delete or edit your own group
        $self->set_param_meta( $key, selfgroup => 1 );
        if ( $access eq 'delete' ) {
            warn "NO self group delete. $debug" if $self->debug_permissions;
            return ( '404', "Not allowed to delete your own group" );
        }
        elsif ( $access eq 'write' ) {
            warn "NO self group write. $debug" if $self->debug_permissions;
            return ( '404', "Not allowed to edit your own group" );
        }
    }

# allow "publish" access to usable nameservers (when modifying/creating a zone)
    if ( $type eq 'NAMESERVER' and $access eq 'read' ) {
        foreach ( map {"usable_ns$_"} ( 0 .. 9 ) ) {
            if ( $permissions->{$_} eq $id ) {
                warn "YES usable nameserver: $debug"
                    if $self->debug_permissions;
                return undef;
            }
        }
    }

    if ($group_ok) {
        warn "OWN" if $self->debug_permissions;
        $self->set_param_meta( $islist ? "$key:$id" : $key, own => 1 );
        if ( $access ne 'read' ) {
            unless ( $permissions->{ lc $type . "_$access" } ) {
                warn "NO $access access for $type. $debug"
                    if $self->debug_permissions;
                return ( '404',
                          "You have no '$access' permission for "
                        . lc $type
                        . " objects" );
            }
            else {
                warn "YES $access access for $type. $debug"
                    if $self->debug_permissions;
                return undef;
            }
        }
    }
    else {

        #now we check access permissions for the delegated object
        my $del = $self->get_delegate_access( $id, $type );
        if ($del) {
            $self->set_param_meta( $islist ? "$key:$id" : $key,
                delegate => $del );
            if ( $del->{'pseudo'} and $pseudo ) {
                if ( $pseudo eq 'none' ) {
                    warn "NO pseudo '$pseudo': $debug"
                        if $self->debug_permissions;
                    return ( '404',
                        "You have no '$access' permission for the delegated object"
                    );

                }
                elsif ( $del->{$pseudo} ) {
                    warn "YES pseudo '$pseudo': $debug"
                        if $self->debug_permissions;
                    return undef;
                }
                else {
                    warn "NO pseudo '$pseudo': $debug"
                        if $self->debug_permissions;
                    return ( '404',
                        "You have no '$access' permission for the delegated object"
                    );
                }
            }
            elsif ($delegate) {
                if ( $delegate eq 'none' ) {
                    warn "NO delegate '$delegate' '$access': $debug"
                        if $self->debug_permissions;
                    return ( '404',
                        "You have no '$access' permission for the delegated object"
                    );
                }
                elsif ( $del->{$delegate} ) {
                    warn "YES delegate '$delegate' '$access': $debug"
                        if $self->debug_permissions;
                    return undef;
                }
                else {
                    warn "NO delegate '$delegate' '$access': $debug"
                        if $self->debug_permissions;
                    return ( '404',
                        "You have no '$access' permission for the delegated object"
                    );

                }
            }
            elsif ( $access ne 'read' ) {
                if ( !$del->{"perm_$access"} ) {
                    warn "NO delegate '$access': $debug"
                        if $self->debug_permissions;
                    warn Data::Dumper::Dumper($del);
                    return ( '404',
                        "You have no '$access' permission for the delegated object"
                    );
                }
                else {
                    warn Data::Dumper::Dumper($del);
                    warn "YES delegate '$access': $debug"
                        if $self->debug_permissions;
                }
            }
            else {
                warn "YES delegate read: $debug" if $self->debug_permissions;
            }
        }
        else {
            warn "NO access: $debug" if $self->debug_permissions;
            return ( '404',
                "No Access Allowed to that object ($type : $id)" );
        }
    }

    warn "YES fallthrough: $debug" if $self->debug_permissions;

    return undef;
}

sub get_delegate_access {
    my ( $self, $id, $type ) = @_;
    my $user_id  = $self->{'user'}->{'nt_user_id'};
    my $group_id = $self->{'user'}->{'nt_group_id'};

    #check delegation

    #XXX if we delegate more than just zones/zonerecords do something here:
    my %tables = ( ZONE => 'nt_zone' );
    my %fields = ( ZONE => 'nt_zone_id' );

    return undef unless $type eq 'ZONE' or $type eq 'ZONERECORD';
    my $dbh = $self->{'dbh'};
    my $sql;
    my $sth;
    if ( $type eq 'ZONERECORD' ) {
        return $self->get_zonerecord_delegate_access( $id, $type );
    }
    else {
        $sql
            = "SELECT nt_delegate.*,nt_group.name AS group_name FROM nt_delegate "
            . " INNER JOIN $tables{$type} on $tables{$type}.$fields{$type} = nt_delegate.nt_object_id AND nt_delegate.nt_object_type='$type'"
            . " INNER JOIN nt_group on $tables{$type}.nt_group_id = nt_group.nt_group_id"
            . " WHERE nt_delegate.nt_group_id=$group_id AND nt_delegate.nt_object_id=$id AND nt_delegate.nt_object_type='$type'";
        $sth = $dbh->prepare($sql);
        warn "$sql\n" if $self->debug_sql;
        $sth->execute || die $dbh->errstr;
        my $auth_data = $sth->fetchrow_hashref;

#warn "Auth data: ".Data::Dumper::Dumper($auth_data) if $self->debug_permissions;
        if ( !$auth_data && $type eq 'ZONE' ) {

#see if any records in the zone are delegated, if so then read access is allowed
            $sql
                = "SELECT count(*) AS count,nt_group.name AS group_name FROM nt_delegate "
                . " INNER JOIN nt_zone_record on nt_zone_record.nt_zone_record_id = nt_delegate.nt_object_id AND nt_delegate.nt_object_type='ZONERECORD'"
                . " INNER JOIN nt_zone on nt_zone.nt_zone_id = nt_zone_record.nt_zone_id"
                . " INNER JOIN nt_group on nt_delegate.nt_group_id = nt_group.nt_group_id"
                . " WHERE nt_delegate.nt_group_id=$group_id AND nt_zone.nt_zone_id=$id "
                . " GROUP BY nt_zone.zone";
            $sth = $dbh->prepare($sql);
            warn "$sql\n" if $self->debug_sql;
            $sth->execute || die $dbh->errstr;
            my $result = $sth->fetchrow_hashref;
            if ( $result && $result->{'count'} gt 0 ) {
                return +{
                    pseudo                     => 1,
                    'perm_write'               => 0,
                    'perm_delete'              => 0,
                    'perm_delegate'            => 0,
                    'zone_perm_add_records'    => 0,
                    'zone_perm_delete_records' => 0,
                    'group_name'               => $result->{'group_name'},
                };
            }

        }
        return $auth_data;
    }
}

sub get_zonerecord_delegate_access {
    my ( $self, $id, $type ) = @_;
    my $user_id  = $self->{'user'}->{'nt_user_id'};
    my $group_id = $self->{'user'}->{'nt_group_id'};

    #check delegation

    my $dbh = $self->{'dbh'};
    my $sql;
    my $sth;
    $sql
        = "SELECT nt_delegate.*,nt_group.name AS group_name FROM nt_delegate "
        . " INNER JOIN nt_zone_record on nt_zone_record.nt_zone_record_id= nt_delegate.nt_object_id AND nt_delegate.nt_object_type='ZONERECORD'"
        . " INNER JOIN nt_zone on nt_zone.nt_zone_id=nt_zone_record.nt_zone_id"
        . " INNER JOIN nt_group on nt_zone.nt_group_id = nt_group.nt_group_id"
        . " WHERE nt_delegate.nt_group_id=$group_id AND nt_delegate.nt_object_id=$id AND nt_delegate.nt_object_type='ZONERECORD'";
    $sth = $dbh->prepare($sql);
    warn "$sql\n" if $self->debug_sql;
    $sth->execute || die $dbh->errstr;
    my $auth_data = $sth->fetchrow_hashref;

#warn "Auth data: ".Data::Dumper::Dumper($auth_data) if $self->debug_permissions;
    return $auth_data if $auth_data;

    $sql
        = "SELECT nt_delegate.*, 1 AS pseudo, nt_group.name AS group_name FROM nt_delegate "
        . " INNER JOIN nt_zone on nt_zone.nt_zone_id=nt_delegate.nt_object_id AND nt_delegate.nt_object_type='ZONE'"
        . " INNER JOIN nt_zone_record on nt_zone_record.nt_zone_id= nt_zone.nt_zone_id"
        . " INNER JOIN nt_group on nt_zone.nt_group_id = nt_group.nt_group_id"
        . " WHERE nt_zone_record.nt_zone_record_id=$id";
    $sth = $dbh->prepare($sql);
    warn "$sql\n" if $self->debug_sql;
    $sth->execute || die $dbh->errstr;
    $auth_data = $sth->fetchrow_hashref;

#warn "Auth data: ".Data::Dumper::Dumper($auth_data) if $self->debug_permissions;
    return $auth_data;
}

sub verify_obj_usage {
    my ( $self, $api, $data, $cmd ) = @_;

    my @error;
    return $api->{'result'} if exists $api->{'result'};
    my $params = $api->{'parameters'};

    my $dbh = $self->{'dbh'};
    my $sql;
    my $sth;

    warn
        "##############################\n$cmd VERIFY OBJECT USAGE\n##############################\n"

        #"      params: ".Data::Dumper::Dumper($params).""
        if $self->debug_permissions;

    #verify that required parameters are present
    my @missing;
    foreach my $p ( grep { $$params{$_}->{'required'} } keys %$params ) {

        #warn "parameter $p exists:".exists $data->{$p};
        if ( ( !exists $data->{$p} ) or ( $data->{$p} eq '' ) ) {
            push @missing, $p;
        }
        elsif ( $$params{$p}->{'list'} ) {

            #warn "got list in call ".Data::Dumper::Dumper($data);
            if ( ref $data->{$p} eq 'ARRAY' ) {
                foreach ( @{ $data->{$p} } ) {
                    if ( $_ eq '' ) {
                        push( @missing, $p );
                        last;
                    }
                }
                $data->{$p} = join( ",", @{ $data->{$p} } );
            }
            else {
                my @blah = split( /,/, $data->{$p} );
                foreach (@blah) {
                    if ( $_ eq '' ) {
                        push( @missing, $p );
                        last;
                    }
                }
                push( @missing, $p ) unless @blah;
            }
        }
    }
    if (@missing) {
        return $self->error_response( 301, join( " ", @missing ) );
    }
    my @invalid;
    foreach my $p ( grep { exists $data->{$_} and $$params{$_}->{'type'} }
        keys %$params )
    {
        next
            if $$params{$p}->{'empty'}
                and ( !defined $data->{$p} or $data->{$p} eq '' );   #empty ok
            #warn "data is ".Data::Dumper::Dumper($data->{$p});
            #warn "checking value of $p.  is list? ".$$params{$p}->{'list'};
        if ( $$params{$p}->{'list'} ) {
            if ( ref $data->{$p} eq 'ARRAY' ) {

          #warn "got array ref $p in call ".Data::Dumper::Dumper($data->{$p});
                foreach ( @{ $data->{$p} } ) {
                    if ( !$self->valid_id($_) ) {
                        push( @invalid, $p );
                        last;
                    }
                }
                $data->{$p} = join( ",", @{ $data->{$p} } );
            }
            else {
                my @blah = split( /,/, $data->{$p} );
                foreach (@blah) {
                    if ( !$self->valid_id($_) ) {
                        push( @invalid, $p );
                        last;
                    }
                }
                push( @invalid, $p ) unless @blah;
            }

            #warn "list $p is now ".Data::Dumper::Dumper($data->{$p});
        }
        else {
            push @invalid, $p unless $self->valid_id( $data->{$p} );
        }
    }
    if (@invalid) {
        return $self->error_response( 302, join( " ", @invalid ) );
    }

    #verify that appropriate permission level is available for all objects
    foreach my $f ( grep { exists $data->{$_} and $$params{$_}->{'type'} }
        keys %$params )
    {

        next unless $$params{$f}->{'access'};
        my $type = $$params{$f}->{'type'};

        #if($type=~s/^parameters://){
        #$type=$data->{$type};
        #}
        if ( $$params{$f}->{'list'} ) {
            if ( ref $data->{$f} eq 'ARRAY' ) {
                $data->{$f} = join( ",", @{ $data->{$f} } );
            }
            my @items = split( /,/, $data->{$f} );
            foreach my $i (@items) {
                @error = $self->check_permission(
                    $f,
                    $i,
                    $api->{'parameters'}->{$f}->{'access'},
                    $type,
                    1,
                    $api->{'creation'},
                    $$params{$f}->{'delegate'},
                    $$params{$f}->{'pseudo'}
                );

                #warn @error if defined $error[0];
                last if defined $error[0];
            }
            last if defined $error[0];
        }
        else {
            @error = $self->check_permission(
                $f,
                $data->{$f},
                $api->{'parameters'}->{$f}->{'access'},
                $type,
                0,
                $api->{'creation'},
                $$params{$f}->{'delegate'},
                $$params{$f}->{'pseudo'}
            );
        }

        warn "ERROR: " . join( " ", @error )
            if $error[0] && $self->debug_permissions;
        return $self->error_response(@error) if $error[0];
    }
    return $error[0] ? $self->error_response(@error) : 0;
}

#gets keyed data for a certain parameter of the function call
sub get_param_meta {
    my $self  = shift;
    my $param = shift;
    my $key   = shift;

    #warn Data::Dumper::Dumper($self->{'meta'});
    return $self->{'meta'}->{$param}->{$key};
}

#Sets keyed info about a parameter for the function call
sub set_param_meta {
    my $self  = shift;
    my $param = shift;
    my $key   = shift;
    my $value = shift;

    #warn "setting param meta: param $param, key $key, value $value";
    #$self->{'meta'}={} unless exists $self->{'meta'};
    $self->{'meta'}->{$param} = {} unless exists $self->{'meta'}->{$param};
    $self->{'meta'}->{$param}->{$key} = $value;

#warn "final param meta: param $param, key $key, value ".Data::Dumper::Dumper($self->{'meta'});;

}

sub valid_id {
    my ( $self, $id ) = @_;
    return ( $id + 0 ne '0' ) && ( $self->valid_integer($id) );
}

sub valid_integer {
    my ( $self, $int ) = @_;

    #warn "checking integer: $int";
    return !1 unless $int =~ /^\d+$/;
    return !1 unless $int < 4500000000;
    return !1 unless $int >= 0;

    #warn "valid integer: $int";
    #if ($int =~ /^\d+$/ && $int < 4500000000 && $int >= 0) {
    return 1;

    #}
    #return 0;
}

sub valid_reverse_lookup {
    my ( $self, $hostname ) = @_;
    if ( $hostname =~ /\.in-addr\.arpa\.?$/i ) {
        $hostname =~ s/\.in-addr\.arpa\.?$//i;
        my $x = 0;

        #warn "checking addr: $hostname\n";
        foreach ( split( /\./, $hostname ) ) {
            ++$x;
            return 0 unless /^\d{1,3}$/ and $_ >= 0 and $_ <= 255;
            return 0 if $x > 4;
        }
        return 1;
    }
    else {
        return 0;
    }

}

sub valid_hostname {
    my ( $self, $hostname ) = @_;
    my @h = split( /\./, $hostname );

    #$hostname=~s/\.$//;
    #XXX have to change for multi-byte charsets
    foreach (@h) {
        return 0
            unless /^[a-zA-Z][-0-9a-zA-Z]*/
                and /[a-zA-Z0-9]$/;
    }
    return 0 unless @h gt 1;
    return 1;
}

sub valid_ip_address {
    my ( $self, $ip ) = @_;
    if ( Net::IP::ip_is_ipv6($ip) == 1 ) {
        return 1;
    }
    else {

        return 0 if grep( /\./, split( //, $ip ) ) != 3;    # need 3 dots

        my @x = split( /\./, $ip );
        return 0 unless @x == 4;                            # need 4 decimals

        return 0 unless $x[0] > 0;

        #return 0 unless $x[2] > 0;
        return 0 if 0 + $x[0] + $x[1] + $x[2] + $x[3] == 0;   #0.0.0.0 invalid
        return 0 if grep( $_ eq '255', @x ) == 4;    #255.255.255.255 invalid

        foreach (@x) {
            return 0 unless /^\d{1,3}$/ and $_ >= 0 and $_ <= 255;
            $_ = 0 + $_;
        }

        return join( ".", @x );
    }
}

sub group_usage_ok {
    my ( $self, $id ) = @_;

    my $user = $self->{'user'};
    my $res  = 0;
    if (   $user->{'nt_group_id'} == $id
        || $self->is_subgroup( $user->{'nt_group_id'}, $id ) )
    {
        $res = 1;
    }
    warn
        "::::group_usage_ok: $id subgroup of group $user->{'nt_group_id'} ? : $res"
        if $self->debug_permissions;
    return $res;
}

sub get_group_map {
    my ( $self, $top_group_id, $groups ) = @_;

    my $dbh = $self->{'dbh'};
    my %map;

    my @blah = @{$groups};
    if ( $#blah == -1 ) {
        warn
            "\n\nuhh, param passed, but nothing in it. get_group_map needs top_group_id + group list arrray for IN clause.\n";
        warn
            "this only happens when there are no groups within a zone? I think.. --ai\n\n\n";
        return \%map;
    }

    my $sql
        = "SELECT nt_group.name, nt_group.nt_group_id, nt_group_subgroups.nt_subgroup_id "
        . "FROM nt_group, nt_group_subgroups "
        . "WHERE nt_group_subgroups.nt_subgroup_id IN("
        . join( ',', @$groups ) . ") "
        . "AND nt_group.nt_group_id = nt_group_subgroups.nt_group_id "
        . "AND nt_group.deleted = '0' "
        . "ORDER BY nt_group_subgroups.nt_subgroup_id, nt_group_subgroups.rank DESC";

    my $sth = $dbh->prepare($sql);
    warn "$sql\n" if $self->debug_sql;
    if ( $sth->execute ) {
        my $skipping = 0;

        while ( my $row = $sth->fetchrow_hashref ) {

            if ( $row->{'nt_group_id'} == $top_group_id ) {
                $skipping = $row->{'nt_subgroup_id'};
            }
            elsif ( $row->{'nt_subgroup_id'} == $top_group_id ) {
                next;
            }
            elsif ($skipping) {
                if ( $skipping != $row->{'nt_subgroup_id'} ) {
                    $skipping = 0;
                }
                else {
                    next;
                }
            }

            unshift( @{ $map{ $row->{'nt_subgroup_id'} } }, $row );
        }
    }
    $sth->finish;

    return \%map;
}

sub get_subgroup_ids {
    my ( $self, $nt_group_id ) = @_;

    my $dbh = $self->{'dbh'};
    my $sql
        = "SELECT * FROM nt_group_subgroups "
        . " WHERE nt_group_id = "
        . $dbh->quote($nt_group_id);
    my $sth = $dbh->prepare($sql);
    warn "$sql\n" if $self->debug_sql;
    $sth->execute || die $dbh->errstr;

    my @list;
    while ( my $row = $sth->fetch ) { push( @list, $row->[1] ); }

    return \@list;
}

sub get_parentgroup_ids {
    my ( $self, $nt_group_id ) = @_;

    my $dbh = $self->{'dbh'};
    my $sql = "SELECT * FROM nt_group_subgroups WHERE nt_subgroup_id = "
        . $dbh->quote($nt_group_id);
    my $sth = $dbh->prepare($sql);
    warn "$sql\n" if $self->debug_sql;
    $sth->execute || die $dbh->errstr;

    my @list;
    while ( my $row = $sth->fetch ) { push( @list, $row->[0] ); }

    return \@list;
}

sub is_subgroup {
    my ( $self, $nt_group_id, $gid ) = @_;

    my $dbh = $self->{'dbh'};
    my $sql
        = "SELECT * FROM nt_group_subgroups WHERE nt_group_id = "
        . $dbh->quote($nt_group_id)
        . " AND nt_subgroup_id = "
        . $dbh->quote($gid);
    my $sth = $dbh->prepare($sql);
    warn "$sql\n" if $self->debug_sql;
    return 0 unless ( $sth->execute );

    return $sth->fetch ? 1 : 0;
}

sub get_group_branches {
    my ( $self, $nt_group_id ) = @_;
    my @groups;
    my $nextgroup = $nt_group_id;
    my $dbh       = $self->{'dbh'};
    my $sql;
    my $res;
    my $sth;
    while ($nextgroup) {
        $sql = "SELECT parent_group_id FROM nt_group WHERE nt_group_id = "
            . $dbh->quote($nextgroup);
        $sth = $dbh->prepare($sql);
        warn "$sql\n" if $self->debug_sql;
        $sth->execute || die $dbh->errstr;
        $res = $sth->fetchrow_hashref;
        unshift @groups, $nextgroup if $res;
        $nextgroup = $res->{'parent_group_id'};
    }
}

sub fetch_row {
    my $self  = shift;
    my $table = shift;
    my %cond  = @_;

    my $dbh = $self->{'dbh'};
    my $sql
        = "SELECT * FROM $table WHERE "
        . join( ' AND ',
        map( "$_ = " . $dbh->quote( $cond{$_} ), keys %cond ) );

    my $sth = $dbh->prepare($sql);
    warn "$sql\n" if $self->debug_sql;
    my $data = {};

    if ( $sth->execute ) {
        if ( $sth->rows ) {
            $data = $sth->fetchrow_hashref;
        }
        else {
            $data = $self->error_response(601);
        }
    }
    else {
        $data = $self->error_response( 600, $sth->errstr );
    }

    return $data;
}

sub get_dbix {

    my $dsn = shift;
    if ( $dsn !~ /^DBI/ ) {
        $dsn = "DBI:$NicToolServer::db_engine:"
            . "database=$NicToolServer::db;"
            . "host=$NicToolServer::db_host;"
            . "port=3306";
    };

    my $dbix = DBIx::Simple->connect( $dsn, 
            $NicToolServer::db_user, 
            $NicToolServer::db_pass, 
            { RaiseError => 1, AutoCommit => 1 },
        )
        or die DBIx::Simple->error;

    return $dbix;
};

sub dbh {

    my $dsn = "DBI:$NicToolServer::db_engine:database=$NicToolServer::db;"
            . "host=$NicToolServer::db_host;port=3306";

    my $dbh = DBI->connect( $dsn, $NicToolServer::db_user, $NicToolServer::db_pass);

    unless ($dbh) {
        die "unable to connect to database: " . $DBI::errstr . "\n";
    }

    return $dbh;
}

sub exec_query {
    my $self = shift;
    my ( $query, $params, $extra ) = @_;
    die "invalid arguments to exec_query!" if $extra;

    my @params; 
    if ( defined $params ) {  # dereference $params into @params
        @params = ref $params eq 'ARRAY' ? @$params : $params;
    };

    my $err = "query failed: $query\n" . join(',', @params);
    warn "$query\n" . join(',', @params) if $self->debug_sql;

    if ( $query =~ /INSERT INTO/ ) {
        my ( $table ) = $query =~ /INSERT INTO (\w+)\s/;
        $self->{dbix}->query( $query, @params );
        if ( $self->{dbix}->error ne 'DBI error: ' ) {
            die $self->{dbix}->error;
        };
        my $id = $self->{dbix}->last_insert_id(undef,undef,$table,undef)
            or die $err;
        return $id;
    }
    elsif ( $query =~ /DELETE/ ) {
        $self->{dbix}->query( $query, @params )->hashes 
            or return $self->error( $err );
        return $self->{dbix}->query("SELECT ROW_COUNT()")->list;
    };

    my $r = $self->{dbix}->query( $query, @params )->hashes or die $err;

    return $r;
};

sub escape {
    my ( $self, $toencode ) = @_;
    $toencode =~ s/([^a-zA-Z0-9_.-])/uc sprintf("%%%02x",ord($1))/eg;
    return $toencode;
}

sub check_object_deleted {
    my ( $self, $otype, $oid ) = @_;
    my $dbh = $self->{'dbh'};
    my $sql;
    my $sth;
    my %map = (
        zone => { table => 'nt_zone', field => 'nt_zone_id' },
        zonerecord =>
            { table => 'nt_zone_record', field => 'nt_zone_record_id' },
        nameserver =>
            { table => 'nt_nameserver', field => 'nt_nameserver_id' },
        group => { table => 'nt_group', field => 'nt_group_id' },
        user  => { table => 'nt_user',  field => 'nt_user_id' },
    );
    if ( my $dbst = $map{ lc($otype) } ) {
        $sql
            = "SELECT deleted FROM $dbst->{'table'} WHERE $dbst->{'field'} = $oid";
        $sth = $dbh->prepare($sql);
        warn "$sql\n" if $self->debug_sql;
        unless ( $sth->execute ) {
            warn $dbh->errstr . ": sql :$sql";
        }
        else {
            my $a = $sth->fetchrow_hashref;
            return $a->{'deleted'};
        }
    }
}

sub get_title {
    my ( $self, $otype, $oid ) = @_;
    my $dbh = $self->{'dbh'};
    my $sql;
    my $sth;
    if ( $otype =~ /^zone$/i ) {
        $sql = "SELECT zone AS title FROM nt_zone WHERE nt_zone_id = $oid";
    }
    elsif ( $otype =~ /^zonerecord$/i ) {
        $sql
            = "SELECT CONCAT(nt_zone_record.name,'.',nt_zone.zone) AS title FROM nt_zone_record"
            . " INNER JOIN nt_zone on nt_zone_record.nt_zone_id=nt_zone.nt_zone_id"
            . " WHERE nt_zone_record.nt_zone_record_id = $oid";
    }
    elsif ( $otype =~ /^nameserver$/i ) {
        $sql
            = "SELECT CONCAT(address,' (',name,')') AS title FROM nt_nameserver"
            . " WHERE nt_nameserver_id = $oid";
    }
    elsif ( $otype =~ /^group$/i ) {
        $sql = "SELECT name AS title FROM nt_group"
            . " WHERE nt_group_id = $oid";
    }
    elsif ( $otype =~ /^user$/i ) {
        $sql
            = "SELECT CONCAT(username,' (',first_name,' ',last_name,')') AS title FROM nt_user"
            . " WHERE nt_user_id = $oid";
    }
    else {
        return "($otype)";
    }

    $sth = $dbh->prepare($sql);
    warn "$sql\n" if $self->debug_sql;
    unless ( $sth->execute ) {
        warn $dbh->errstr;
        return "($otype)";
    }
    return $sth->fetchrow_hashref->{'title'};
}

sub diff_changes {
    my ( $self, $data, $prev_data ) = @_;
    my @changes;

    my %perms =

#map {$a=$_;local $_=$a; s/_/ /g;s/names/n s/g;s/zoner/z r/g;s/deleg/d g/g;s/(\S)\S+/$1/g;s/\s//g; ($a=>$_)} qw(user_create user_can_delegate user_delete user_write group_create group_delegate group_delete group_write zone_create zone_delegate zone_delete zone_write zonerecord_create zonerecord_delegate zonerecord_delete zonerecord_write nameserver_create nameserver_delegate nameserver_delete nameserver_write self_write);
        (
        'zonerecord_create'   => 'ZRC',
        'group_write'         => 'GW',
        'user_write'          => 'UW',
        'zone_delegate'       => 'ZDG',
        'nameserver_delete'   => 'NSD',
        'zone_create'         => 'ZC',
        'group_delete'        => 'GD',
        'zonerecord_delete'   => 'ZRD',
        'user_create'         => 'UC',
        'self_write'          => 'SW',
        'nameserver_write'    => 'NSW',
        'zone_delete'         => 'ZD',
        'zonerecord_write'    => 'ZRW',
        'nameserver_create'   => 'NSC',
        'user_delete'         => 'UD',
        'zonerecord_delegate' => 'ZRDG',
        'zone_write'          => 'ZW',
        'group_create'        => 'GC'
        );

    foreach my $f ( keys %$prev_data ) {
        next unless exists $data->{$f};
        if ( $f eq 'description' || $f eq 'password' )
        {    # description field is too long & not critical
            push( @changes, "changed $f" )
                if ( $data->{$f} ne $prev_data->{$f} );
            next;
        }
        elsif ( exists $perms{$f} ) {
            push( @changes,
                      "changed "
                    . $perms{$f}
                    . " from '"
                    . $prev_data->{$f}
                    . "' to '"
                    . $data->{$f}
                    . "'" )
                if ( $data->{$f} ne $prev_data->{$f} );
        }
        else {
            push( @changes,
                "changed $f from '$prev_data->{$f}' to '$data->{$f}'" )
                if ( $data->{$f} ne $prev_data->{$f} );
        }
    }
    if ( !@changes ) {
        push( @changes, "nothing modified" );
    }
    return join( ", ", @changes );
}

sub throw_sanity_error {
    my $self = shift;

    my $return = $self->error_response( 300,
        join( " AND ", @{ $self->{'error_messages'} } ) );
    $return->{'sanity_err'} = $self->{'errors'};
    $return->{'sanity_msg'} = $self->{'error_messages'};
    return $return;
}

sub format_search_conditions {
    my ( $self, $data, $field_map ) = @_;

    my $dbh = $self->{'dbh'};

    my @conditions;
    if ( $data->{'Search'} ) {
        for ( 1 .. 5 ) {
            next unless $data->{ $_ . '_field' };
            $data->{ $_ . '_option' } = 'CONTAINS'
                unless exists $data->{ $_ . '_option' };
            my $cond
                = $_ == 1 ? '' : uc( $data->{ $_ . '_inclusive' } ) . ' ';
            $cond .= $field_map->{ $data->{ $_ . '_field' } }->{'field'};

            if ( uc( $data->{ $_ . "_option" } ) eq 'EQUALS' ) {
                if ( $field_map->{ $data->{ $_ . '_field' } }->{'timefield'} )
                {
                    $cond
                        .= "="
                        . "UNIX_TIMESTAMP("
                        . $dbh->quote( $data->{ $_ . '_value' } ) . ")";
                }
                else {
                    $cond .= "=" . $dbh->quote( $data->{ $_ . '_value' } );
                }
            }
            elsif ( uc( $data->{ $_ . "_option" } ) eq 'CONTAINS' ) {
                if ( $field_map->{ $data->{ $_ . '_field' } }->{'timefield'} )
                {
                    $cond
                        .= "="
                        . "UNIX_TIMESTAMP("
                        . $dbh->quote( $data->{ $_ . '_value' } ) . ")";
                }
                else {
                    my $val = $dbh->quote( $data->{ $_ . '_value' } );
                    $val =~ s/^'/'%/;
                    $val =~ s/'$/%'/;
                    $cond .= " LIKE $val";
                }
            }
            elsif ( uc( $data->{ $_ . "_option" } ) eq 'STARTS WITH' ) {
                if ( $field_map->{ $data->{ $_ . '_field' } }->{'timefield'} )
                {
                    $cond
                        .= "="
                        . "UNIX_TIMESTAMP("
                        . $dbh->quote( $data->{ $_ . '_value' } ) . ")";
                }
                else {
                    my $val = $dbh->quote( $data->{ $_ . '_value' } );
                    $val =~ s/'$/%'/;
                    $cond .= " LIKE $val";
                }
            }
            elsif ( uc( $data->{ $_ . "_option" } ) eq 'ENDS WITH' ) {
                if ( $field_map->{ $data->{ $_ . '_field' } }->{'timefield'} )
                {
                    $cond
                        .= "="
                        . "UNIX_TIMESTAMP("
                        . $dbh->quote( $data->{ $_ . '_value' } ) . ")";
                }
                else {
                    my $val = $dbh->quote( $data->{ $_ . '_value' } );
                    $val =~ s/^'/'%/;
                    $cond .= " LIKE $val";
                }
            }
            else {
                if ( $field_map->{ $data->{ $_ . '_field' } }->{'timefield'} )
                {
                    $cond
                        .= $data->{ $_ . "_option" }
                        . "UNIX_TIMESTAMP("
                        . $dbh->quote( $data->{ $_ . '_value' } ) . ")";
                }
                else {
                    $cond .= $data->{ $_ . "_option" }
                        . $dbh->quote( $data->{ $_ . '_value' } );
                }
            }

            push( @conditions, $cond );
        }
    }

    if ( $data->{'quick_search'} ) {
        my $value = $dbh->quote( $data->{'search_value'} );
        $value =~ s/^'/'%/ unless $data->{'exact_match'};
        $value =~ s/'$/%'/ unless $data->{'exact_match'};

        my $x = 1;
        foreach ( keys %$field_map ) {
            if ( $field_map->{$_}->{'quicksearch'} ) {
                unless ( $data->{'exact_match'} ) {
                    push( @conditions,
                        ( $x++ == 1 ? " " : " OR " )
                            . "$field_map->{$_}->{'field'} LIKE $value" );
                }
                else {
                    push( @conditions,
                        ( $x++ == 1 ? " " : " OR " )
                            . "$field_map->{$_}->{'field'} = $value" );
                }
            }
        }
    }

    return \@conditions;
}

sub format_sort_conditions {
    my ( $self, $data, $field_map, $default ) = @_;

    my $dbh = $self->{'dbh'};

    my @sortby;

    if ( $data->{'Sort'} ) {
        foreach ( 1 .. 3 ) {
            if ( $data->{ $_ . '_sortfield' } ) {
                push(
                    @sortby,
                    $field_map->{ $data->{ $_ . '_sortfield' } }->{'field'}
                        . (
                        uc( $data->{ $_ . '_sortmod' } ) eq 'ASCENDING'
                        ? ''
                        : ' DESC'
                        )
                );
            }
        }
    }
    else {
        push( @sortby, $default )
            if ($default)
            ;    # if no default specified just return empty arrayref
    }

    return \@sortby;
}

sub set_paging_vars {
    my ( $self, $data, $r_data ) = @_;

    if ( $data->{'limit'} !~ /^\d+$/ ) {
        $r_data->{'limit'} = 20;
    }
    else {
        $r_data->{'limit'}
            = ( $data->{'limit'} <= 255 ? $data->{'limit'} : 255 );
    }

    if ( $data->{'page'} && ( $data->{'page'} =~ /^\d+$/ ) ) {
        $r_data->{'start'} = ( $data->{'page'} - 1 ) * $r_data->{'limit'} + 1;
    }
    elsif ( $data->{'start'} && ( $data->{'start'} =~ /^\d+$/ ) ) {
        $r_data->{'start'} = $data->{'start'};
    }
    else {
        $r_data->{'start'} = 1;
    }

    if ( $r_data->{'start'} >= $r_data->{'total'} ) {
        if ( $r_data->{'total'} % $r_data->{'limit'} ) {
            $r_data->{'start'}
                = int( $r_data->{'total'} / $r_data->{'limit'} )
                * $r_data->{'limit'} + 1;
        }
        else {
            $r_data->{'start'} = $r_data->{'total'} - $r_data->{'limit'} + 1;
        }
    }

    $r_data->{'end'} = ( $r_data->{'start'} + $r_data->{'limit'} ) - 1;
    $r_data->{'page'}
        = $r_data->{'end'} % $r_data->{'limit'}
        ? int( $r_data->{'end'} / $r_data->{'limit'} ) + 1
        : $r_data->{'end'} / $r_data->{'limit'};
    $r_data->{'total_pages'}
        = $r_data->{'total'} % $r_data->{'limit'}
        ? int( $r_data->{'total'} / $r_data->{'limit'} ) + 1
        : $r_data->{'total'} / $r_data->{'limit'};
}

sub search_params_sanity_check {
    my ( $self, $data, @fields ) = @_;
    my %f = map { $_ => 1 } @fields;
    my %o = map { $_ => 1 } (
        'contains', 'starts with', 'ends with', 'equals',
        '>',        '>=',          '<',         '<=',
        '='
    );
    my %i = map { $_ => 1 } ( 'and', 'or' );

    #search stuff
    if ( $data->{'Search'} ) {
        foreach my $int ( 1 .. 5 ) {
            next unless exists $data->{ $int . "_field" };
            foreach (qw(option value)) {
                $self->push_sanity_error(
                    $int . "_$_",
                    "Parameter $int"
                        . "_$_ must be included with $int"
                        . "_field ."
                ) unless exists $data->{ $int . "_$_" };
            }

            $self->push_sanity_error(
                $int . "_field",
                "Parameter $int"
                    . "_field is an invalid field : '"
                    . $data->{ $int . "_field" }
                    . "'. Use one of "
                    . join( ", ", map {"'$_'"} keys %f )
            ) unless exists $f{ $data->{ $int . "_field" } };
            $self->push_sanity_error(
                $int . "_option",
                "Parameter $int"
                    . "_option is invalid: '"
                    . $data->{ $int . "_option" }
                    . "'. Use one of "
                    . join( ", ", map {"'$_'"} keys %o )
            ) unless exists $o{ lc( $data->{ $int . "_option" } ) };

            next unless $int > 1;
            $self->push_sanity_error(
                $int . "_inclusive",
                "Parameter $int"
                    . "_inclusive is invalid: '"
                    . $data->{ $int . "_inclusive" }
                    . "'. Use one of "
                    . join( ", ", map {"'$_'"} keys %i )
            ) unless exists $i{ lc( $data->{ $int . "_inclusive" } ) };
        }
    }
    elsif ( $data->{'quick_search'} ) {
        $self->push_sanity_error( "search_value",
            "Must include parameter 'search_value' with 'quick_search'." )
            unless exists $data->{'search_value'};
    }

    #sort stuff
    if ( $data->{'Sort'} ) {
        foreach my $int ( 1 .. 3 ) {
            next unless exists $data->{ $int . "_sortfield" };
            $self->push_sanity_error(
                $int . "_sortfield",
                "Sort parameter $int"
                    . "_sortfield is invalid: '"
                    . $data->{ $int . "_sortfield" }
                    . "'.  Use one of "
                    . join( ", ", map {"'$_'"} keys %f )
            ) unless exists $f{ $data->{ $int . "_sortfield" } };
        }
    }

    #paging stuff
    #just make sure start,page,limit, are valid ints (or blank)
    foreach my $sort ( grep { $data->{$_} } qw(start page limit) ) {
        $self->push_sanity_error( $sort,
            "Paging field '$sort' must be an integer." )
            unless $data->{$sort} =~ /^\d+$/;
    }

}

sub push_sanity_error {
    my ( $self, $param, $message ) = @_;
    $self->{'errors'}->{$param} = 1;
    push( @{ $self->{'error_messages'} }, $message );
}

### serial number routines
#
# bump_serial is the only publicly-used method

sub bump_serial {
    my ( $self, $nt_zone_id, $current_serial ) = @_;

    my $serial;

    if ( $nt_zone_id eq 'new' ) {
        $serial = $self->new_serial;
    }
    else {
        if ( $current_serial eq '' ) {
            my $dbh = $self->{'dbh'};
            my $sql = "SELECT serial FROM nt_zone WHERE nt_zone_id = "
                . $dbh->quote($nt_zone_id);
            my $sth = $dbh->prepare($sql);
            warn "$sql\n" if $self->debug_sql;
            $sth->execute;
            my @row = $sth->fetchrow;
            $current_serial = $row[0];
        }
        $serial = $self->serial_increment($current_serial);
    }

    return $serial;
}

sub serial_increment {
    my ( $self, $serial_current ) = @_;

    my $serial_new;

    if (    ( length($serial_current) == 10 )
        and $serial_current > 1970000000
        and ( $serial_current =~ /^(\d{4,4})(\d{2,2})(\d{2,2})(\d{2,2})$/ ) )
    {

        # dated serials have 10 chars in form YYYYMMDDxx
        my $s_year  = $1;
        my $s_month = $2;
        my $s_day   = $3;
        my $s_digit = $4;

        my $serial_str = $s_year . $s_month . $s_day;
        my $new_str    = $self->serial_date_str;

        if ( $serial_str < $new_str ) {
            $serial_new = $new_str . '00';
        }
        else {

            # serial_str >= new_str, so do serial number math, jumping
            # into the next day/month/year as neccessary to keep incrementing

            $s_digit += 1;

            if ( $s_digit > 99 ) {
                $s_digit = '00';
                $s_day += 1;
                if ( $s_day > 99 ) {
                    $s_day = '01';
                    $s_month += 1;
                    if ( $s_month > 99 ) {
                        $s_month = '01';
                        $s_year = sprintf( "%04d", $s_year + 1 );
                    }
                    $s_month = sprintf( "%02d", $s_month );
                }
                $s_day = sprintf( "%02d", $s_day );
            }
            $s_digit = sprintf( "%02d", $s_digit );

            $serial_new = $s_year . $s_month . $s_day . $s_digit;
        }

    }
    else {
        $serial_new = $serial_current + 1;
    }

    if ( $serial_new > ( ( 2**32 ) - 1 ) ) {
        $serial_new = 1;

        # 4294967295 is the max. (32-bit int minus 1)
        # when we hit this, we have to roll over
    }

    return $serial_new;
}

sub new_serial {
    my $self = shift;

    my $serial;
    if ( $NicToolServer::serial_format eq 'dated' ) {
        my ( $year, $month, $day ) = $self->serial_date_str;
        $serial = $year . $month . $day . '00';
    }
    else {
        $serial = '1';
    }

    return $serial;
}

sub serial_date_str {
    my $self = shift;

    my @datestr = localtime(time);

    my $year  = $datestr[5] + 1900;
    my $month = sprintf( "%02d", $datestr[4] + 1 );
    my $day   = sprintf( "%02d", $datestr[3] );

    return ( $year . $month . $day );
}

1;
__END__

=head1 NAME

NicToolServer - NicTool API reference server implementation

=head1 AUTHOR

Dajoba, LLC - 2001 <info@dajoba.com>
The Network People, Inc. - 2008 <info@tnpi.net>

=cut
