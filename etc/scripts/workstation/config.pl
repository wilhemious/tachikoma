#!/usr/bin/perl
use strict;
use warnings;
require 'config.pl';

sub workstation_header {
    print <<'EOF';
v2
include services/config.tsl

make_node CommandInterpreter hosts
make_node JobController      jobs
make_node Ruleset            server_log:ruleset
make_node Tee                server_log:tee
make_node LogColor           server_log:color
make_node Tee                server_log
make_node Tee                error_log:tee
make_node LogColor           error_log:color
make_node Tee                error_log
make_node Ruleset            local_system_log:ruleset
make_node Ruleset            system_log:ruleset
make_node Tee                system_log:tee
make_node LogColor           system_log:color
make_node Tee                system_log
make_node Tee                silc_dn:tee
make_node Tee                http_log
make_node Null               null
make_node Echo               echo
make_node Scheduler          scheduler

cd server_log:ruleset:config
  add  100 cancel where payload=".* FROM: .* ID: tachikoma@<hostname>(?:[.].*)? COMMAND: .*"
  add  200 cancel where payload="silo '\S+' pub '\S+' user '\S+' addr '[\d.]+' is rfc1918"
  add  999 copy to error_log:tee where payload="ERROR:|FAILED:|TRAP:|COMMAND:"
  add 1000 redirect to server_log:tee
cd ..

cd local_system_log:ruleset:config
  add 100 cancel where payload='WirelessUtility\[\d+\]: -\[SiteSurveyPageController'
  add 1000 redirect to system_log:ruleset
cd ..

cd system_log:ruleset:config
  add 100  cancel where payload=ipmi0: KCS
  add 1000 redirect to system_log:tee
cd ..

command jobs start_job TailForks tails localhost:4230
cd tails
  add_tail /var/log/tachikoma/tachikoma-server.log server_log:ruleset
  add_tail /var/log/tachikoma/http-access.log      http_log
  add_tail /var/log/tachikoma/tasks-access.log     http_log
  add_tail /var/log/tachikoma/tables-access.log    http_log
cd ..

connect_node system_log               _responder
connect_node system_log:color         system_log
connect_node system_log:tee           system_log:color
connect_node error_log:color          error_log
connect_node error_log:tee            error_log:color
connect_node server_log:color         server_log
connect_node server_log:tee           server_log:color

EOF
}

sub workstation_benchmarks {
    print <<'EOF';


# benchmarks
func run_benchmarks_profiled {
    local time = <1>;
    env NYTPROF=addpid=1:file=/tmp/nytprof.out;
    env PERL5OPT=-d:NYTProf;
    start_service benchmarks;
    if (<time>) {
        command scheduler in <time> command jobs stop_job benchmarks;
    };
    env NYTPROF=;
    env PERL5OPT=;
}

EOF
}

sub workstation_partitions {
    print <<'EOF';


# partitions
command jobs start_job CommandInterpreter partitions
cd partitions
  make_node Partition scratch:log     --filename=/logs/scratch.log      \
                                      --segment_size=(32 * 1024 * 1024)
  make_node Partition follower:log    --filename=/logs/follower.log     \
                                      --segment_size=(32 * 1024 * 1024) \
                                      --leader=scratch:log
  make_node Partition offset:log      --filename=/logs/offset.log       \
                                      --segment_size=(256 * 1024)
  make_node Consumer scratch:consumer --partition=scratch:log           \
                                      --offsetlog=offset:log
  buffer_probe
  insecure
cd ..

EOF
}

sub workstation_services {
    print <<'EOF';


# services
var services = "<home>/.tachikoma/services";
func start_service {
    local service = <1>;
    command jobs  start_job Shell <service>:job <services>/<service>.tsl;
    command hosts connect_inet localhost:[var "tachikoma.<service>.port"] <service>:service;
    command tails add_tail /var/log/tachikoma/<service>.log server_log:ruleset;
}
func stop_service {
    local service = <1>;
    command jobs stop_job <service>:job;
    # rm <service>:service;
}
for service (<tachikoma.services>) {
    start_service <service>;
}



# ingest server logs
connect_node server_log:tee server_logs:service/server_log

EOF
}

sub workstation_sound_effects {
    print <<'EOF';


# sound effects
var username=`whoami`;
func get_sound { return "/System/Library/Sounds/<1>.aiff\n" }
func afplay    { send AfPlay:sieve <1>; return }

make_node MemorySieve AfPlay:sieve     1
make_node JobFarmer   AfPlay           4 AfPlay
make_node Function    server_log:sounds '{
    local sound = "";
    # if (<1> =~ "\sWARNING:\s")    [ sound = Tink;   ]
    if (<1> =~ "\sERROR:\s(.*)")  [ sound = Tink;   ]
    elsif (<1> =~ "\sFAILURE:\s") [ sound = Sosumi; ]
    elsif (<1> =~ "\sCOMMAND:\s") [ sound = Hero;   ];
    if (<sound>) { afplay { get_sound <sound> } };
}'
make_node Function silc:sounds '{
    local sound = Pop;
    if (<1> =~ "\b<username>\b(?!>)") [ sound = Glass ];
    afplay { get_sound <sound> };
}'
command AfPlay lazy on
connect_node AfPlay:sieve      AfPlay:load_balancer
connect_node server_log:sounds _responder
connect_node server_log:tee    server_log:sounds
connect_node silc:sounds       _responder
connect_node silc_dn:tee       silc:sounds

EOF
}

sub workstation_hosts {
    print <<'EOF';
cd hosts
  connect_inet --scheme=rsa-sha256 --use-ssl tachikoma:4231
  connect_inet --scheme=rsa-sha256 --use-ssl tachikoma:4232 server_logs
  connect_inet --scheme=rsa-sha256 --use-ssl tachikoma:4233 system_logs
  connect_inet --scheme=rsa-sha256 --use-ssl tachikoma:4234 silc_dn
cd ..

connect_node silc_dn     silc_dn:tee
connect_node system_logs system_log:ruleset
connect_node server_logs server_log:ruleset

EOF
}

sub workstation_footer {
    print <<'EOF';
cd tails
  tail_probe
  start_tail
  insecure
cd ..
EOF
}

1;
