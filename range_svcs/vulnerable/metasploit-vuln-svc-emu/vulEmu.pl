#!/usr/bin/env perl

use JSON;
use Data::Dumper;
use IO::Socket;
use IO::Select;
use IO::Socket::INET;
use IO::Socket::SSL;
use Try::Tiny;
use IO::Compress::Gzip qw(gzip);
use Compress::Zlib qw(crc32);
use Storable qw(dclone);
use FindBin qw($Bin);
no warnings 'deprecated';
my $isWin = 0;
if ($^O =~ /mswin/i) { $isWin = 1;}

require "$Bin/userFuncs.pl";
my $CONNECT = 1;
my $DATA    = 2;
my $serviceType = {};
my $cfg;
my $srvSocks = {};
my $sock2module = {};
my $isSrvSock = {};
my $isSSLSock = {};
my $port2module = {};
my $ctx       = {};
my $refs      = {};
my $e;
my $saved;
my $sock;
my $keyFields = {desc => 1, comment => 1 };
my $sendFile = "";
my $lastSock = "";
my $ftpDataSock = "";
my $pendingAction = []; 
my $meteSock;
my $meteState = 0;
my $isServerTypeSet = 0;
my $recvedMetepreterData = 0;
my $defaultPorts = {};
my $peerHost;
my $debug2 = 0;
my $savedActCmd; #reactivate module after reloading service file
my @pendingActions;
my @results = (); #matched pieces from regex match, 
my $dataBuf = "";
my $allServices = {}; 

my $s = IO::Select->new();
my $s2 = IO::Select->new(); #test if a socket is SSL
use threads ('yield',
			 'stack_size' => 64*4096,
			 'exit' => 'threads_only',
			 'stringify');
use threads::shared;
my $threadVar :shared;
my $thr;
if ($isWin) {
	$thr = threads->create('input_thread');
} else {
	$s->add(\*STDIN);
}

system("ip addr add $ENV{'IP_ADDR'}/$ENV{'LEN'} dev net1; ip link set mtu 1450 dev net1; ip r d default; ip r a default via $ENV{'GATEWAY'}");

readCfg();
my @a;
my $showData = 0;
my $lhost = "127.0.0.1";
$extraCmd = "";
for (my $i=0; $i<=$#ARGV; $i++) {
	if ($ARGV[$i] eq "help" || $ARGV[$i] eq "-h") {
		print "$0 [ip 192.168.0.10] [show] [set activate:exploits/windows/iis/ms01_023_printer]\n";
		exit;
	} elsif ($ARGV[$i] eq "set") {
		@a = split(/:/, $ARGV[$i+1], 2);
		$extraCmd = "$a[0] $a[1]";
		print "Auto launch: $extraCmd\n";
		$i ++;
	} elsif ($ARGV[$i] eq "show") {
		print "Data received will be display\n";
		$showData = 1;
	} elsif ($ARGV[$i] eq "ip") {
		$lhost = $ARGV[$i+1]; $i++;
		print "lhost is now $lhost\n";
	}
}
if ($extraCmd ne "") { processCmd($extraCmd);}
#print Dumper($cfg);
my $ctrlSrvSock = IO::Socket::INET->new( Proto    => 'tcp',
                                 LocalPort => 1,
								Reuse     => 1,
                                Listen    => 500
   ) || die "failed to setup ctrl $@\n";
$s->add($ctrlSrvSock);
my $ctrlSock;
my $client;
my $len;
my $isTlv;
my $buff;
my %allServices;
my $lastTs = 0.0;
$| = 1;
print ">>";
while (1) {
	@readySocks = mySelect(0.5);
	checkDelayedJob();
	if ($isWin) {
		if ($threadVar ne "") {
			processCmd($threadVar);
			$threadVar = "";
		}
	}
	foreach $sock (@readySocks) {
		if ($isWin == 0) {
			if ($sock eq \*STDIN) {
				chomp($cmd = <STDIN>);
				processCmd($cmd);
				print ">>";
				next;
			}
		}
		#printf "sock=$sock|$meteSock| %d\n", $sock->sockport();
		if ($ctrlSrvSock eq $sock) {
			$ctrlSock = $sock->accept();
			$s->add($ctrlSock);
		} elsif ($ctrlSock eq $sock) {
			$buff = "";
			recv($sock, $buff, 0x10000,0);
			$len = length($buff);
			#print "len=$len\n";
			if (length($buff) <= 0) {
				$s->remove($sock);
				close $sock;
				next;
			}
			if ($buff eq "\n") { next;}
			print "$buff\n";
			processCmd($buff, 1);
		} elsif (defined $isSrvSock->{$sock}) {
			$client = $sock->accept();
			$peerHost = $client->peerhost();
			$refs->{$client}      = $client;
			check4SSL($client); #upgrade to SSL whenever client likes to.
			$s->add($client);
			#if ($isSSLSock->{$sock}) {
			#	$isSSLSock->{$client} = 1;
			#}
			if ($sock->sockport() == 20) { #assume it's ftp data channel
				$ftpDataSock = $client;
				next;
			}
			$sock2module->{$client} = $port2module->{$sock->sockport()};
			sequence($client, $CONNECT);
		} elsif ($meteSock eq $sock) { #can be used for metepreter
			$buff = "";
			sysread($sock, $buff, 0x100000);
			$len = length($buff);
			#print "len=$len\n";
			if ($len <= 0) {
				$s->remove($meteSock);
				close $sock;
				$recvedMetepreterData = 0;
				next;
			}
			$recvedMetepreterData = 1;
			handleMeteSock();
		} elsif ($sock->sockport() == 20) {
			
			$buff = readSock($sock);
			if (length($buff) <= 0) {
				$s->remove($sock);
				close $sock;
			}
		} else {
			$dataBuf = readSock($sock);
			if (length($dataBuf) <= 0) {
				$s->remove($sock);
				delete $refs->{$sock};
				delete $ctx->{$sock};
				delete $isSSLSock->{$sock};
				close $sock;
				next;
			}
			sequence($sock, $DATA, $dataBuf);
			if ($#pendingActions >= 0) {
				#printf "count of pending actions %d\n", $#pendingActions;
				$action = shift @pendingActions;
				execute($action);
			}
		}
	}
}
sub readSock {
	my $sock = shift;
	my $buff = "";
	if (defined $isSSLSock->{$sock}) {
		sysread($sock, $buff, 0x1000000);
		if ($showData) { printf("recved: $buff\n");}
	} else {
		sysread($sock, $buff, 0x100000);
	}
	return $buff;
}
sub checkDelayedJob {
	if ($lastTs != 0.0) {
		my $tmp = getTS();
		#printf("time elapsed %f\n", $tmp-$lastTs);
		if ( ($tmp - $lastTs) >= 1.0) {
			if ($recvedMetepreterData == 0) {
				print "sending >> to start with simple session\n";
				$meteSock->send(">>");
				$meteState = 1; 
			}
			$lastTs = 0.0;
		}
	}
}
sub processCmd {
	my ($cmd, $option) = @_;
	$cmd =~ s/^\s*//;
	my @a = split(/\s+/, $cmd);
	my @b;
	my $module;
	if ($a[0] =~ /^act/) { #activate
		$savedActCmd = $cmd;
		$pattern = $a[1];
		if (defined $option) { goto only1choice;}
		foreach $e (keys %$allServices) {
			if ($e =~ /$pattern/) {
				push @b, $e;
			}
		}
		if ($#b < 0) { 
			print "did not find a match\n";
			return;
		} elsif ($#b > 0) {
			print "multiple entries found, please make a choice by number:\n";
			$tmp = 1;
			foreach $e (@b) {
				printf "%2d $e\n", $tmp ++;
			}
			chomp($tmp = <STDIN>);
			$module = $allServices->{$b[$tmp-1]};
		} else {
only1choice:
			$module = $allServices->{$pattern};
		}
		my $ports2open = {};
		if (defined $a[2]) {
			for (my $i=2; $<=$#a; $i++) {
				$port2module->{$a[$i]} = $module;
				$ports2open->{$a[$i]} = 1;
				#setupSocket($port);
			}
		} else {
			foreach my $port (@{$module->{defaultPort}}) {
				$port2module->{$port} = $module;
				$ports2open->{$port} = 1;
			}
		}
		setupSocket($ports2open);
	} elsif (($a[0] eq "ls") || ($a[0] eq "list")) {
		foreach $e (keys %{$cfg->{$port}}) {
			if (defined $keyFields->{$e}) { next;}
			print "	$e\n";
		}
	} elsif ($a[0] eq "show") {
		$port = $a[1];
		print "$port is serviced by $port2module->{$port}->{name}\n";
	} elsif ($a[0] eq "reload") {
		readCfg();
		print "reloaded cfg\n";
	} elsif ($a[0] eq "exit") {
		print "Quitting...\n\n";
		exit;
	}
	print ">>";
}

sub handleMeteSock {
	#my $sock = shift;
	$isTlv = 0;
	if ($meteState == 1) { #simple
		chomp($buff);
		$tmp = `$buff`;
		$meteSock->send($tmp . ">>");
		return;
	}
	$accumBuf .= $buff;
	my $len = length($accumBuf);
accumBufTryAgain:	
	if ($len < 4) {
		return;
	} 
	#TODO need to look at the bytes in details
	$accumBuf = substr($accumBuf, $len+4);
	$len = length($accumBuf);
	if ($len == 0) { return; }
	goto accumBufTryAgain;
}
sub extraProc {
	my ($data, $extraParam) = @_;
	if (! defined $extraParam) { return;}
	if ($extraParam eq "saveHttpBody") {
		if ($data =~ /\r\n\r\n/) {
			print "saving...\n";
			$saved = $';
		} else {
			$saved = "";
		}
	}
}
sub sequence {
	my ($sock, $type, $data) = @_;
	my $seq = $sock2module->{$sock}->{seq};
	my $pattern;
	my $i;
	if (! defined $ctx->{$sock}) { $ctx->{$sock} = 0;}
	my $initMsg = $sock2module->{$sock}->{initMsg};
	if ($type == $CONNECT) {
		if (defined $initMsg) {
			sendit($sock, compact($initMsg));
		}
	} else {
		$len = scalar @$seq;
		#printHex($data, 32);
		for ($i=0; $i<$len; $i+=2) {
			$pattern = compact([$seq->[$i]->[1]]);
			#print "debug $seq->[$i]->[0] $pattern\n";
			#printHex($pattern,32);
			if ($seq->[$i]->[0] eq "regex") {
				#$pattern = $seq->[$i]->[1];
				if ($data =~ /$pattern/) {
					#print "match again regex $pattern|$1|\n";
					$results[1] = $1;
					$results[2] = $2;
					$results[3] = $3;
					extraProc($data, $seq->[$i]->[2]);
					return sendit($sock, compact($seq->[$i+1]));
				}
			} elsif ($seq->[$i]->[0] eq "substr") {
				if (index($data, $pattern) >= 0) {
					extraProc($data, $seq->[$i]->[2]);
					return sendit($sock, compact($seq->[$i+1]));
				}
			} elsif ($seq->[$i]->[0] eq "starts") {
				#print "got here $pattern\n";
				if (index($data, $pattern) == 0) {
					extraProc($data, $seq->[$i]->[2]);
					return sendit($sock, compact($seq->[$i+1]));
				}
			} elsif ($seq->[$i]->[0] eq "equal") {
				if ($data eq $pattern) {
					extraProc($data, $seq->[$i]->[2]);
					return sendit($sock, compact($seq->[$i+1]));
				}
			} elsif ($seq->[$i]->[0] eq "split") {
				@results = split($seq->[$i]->[1], $data);
				#print Dumper(\@results);
				extraProc($data, $seq->[$i]->[2]);
				return sendit($sock, compact($seq->[$i+1]));
			} elsif ($seq->[$i]->[0] eq "any") {
				extraProc($data, $seq->[$i]->[2]);
				return sendit($sock, compact($seq->[$i+1]));
			}
		}
		printf "can't find a match for request $data of size %d\n", length($data);
	}
	$ctx->{$sock} ++;
}

sub printHex {
	my ($x, $size) = @_;
	my @a = unpack("C*", $x);
	my $i;
	if (($size == 0) || ($size > $#a)) {
		$size = $#a;
	}
	for ($i=0; $i<=$size; $i++) {
		printf "%02x ", $a[$i];
		if (($i %16) == 15) { print "\n";}
	}
	if (($i % 16) != 15) {print "\n";}
}

sub compact {
	my ($a, $skips) = @_;
	my $ret;
	my $e;
	my $value;
	my $offset;
	my $pending = -1;
	my $j;
	if (! defined $skips) { $skip = 0; }
	foreach $e (@$a) {
		if ($skips > 0) {$skips --; next;}
		#print "e=$e|$e->[0]|\n";
		if ((ref $e) eq "ARRAY") {
			#if ($e->[1] =~ /^\$(\d)$/) { $e->[1] = $results[$1 - 1];}
			if ((ref $e->[0]) eq "ARRAY") {
				$value = compact($e->[0]);
			} elsif ($e->[0] eq "repeat") {
				$cnt = $e->[2];
				$value = $e->[1] x $cnt;
			} elsif ($e->[0] eq "nsize") {
				$offset = length($ret);
				$pending = $e->[1];
				next;
			} elsif ($e->[0] eq "crc32") {
				#print "calling crc on |$e->[1]|$results[0]|\n";
				$value = sprintf("%x", crc32(substr($e->[1], 0, $results[0])));
			} elsif ($e->[0] eq "action") {
				#print "got an action\n";
				for ($j=1; defined $e->[$j]; $j++) {
					push @pendingActions, $e->[$j];
				}
				next;
			} elsif ($e->[0] eq "eval") {
				#print Dumper($e);
				$tmp = $e->[1];
				my $newExp;
				while ($tmp =~ /\$(\d)/) {
					$newExp .= $` . "\$results[$1]";
					$tmp = $';
				}
				$newExp .= $tmp; 
				print "$newExp\n";
				eval ("\$value = \"" . $newExp . "\"");
			} elsif ($e->[0] eq "file") {
				$value = readFile($e->[1]);
			} elsif ($e->[0] eq "append") {
				$value = compact($e, 1);
			} elsif ($e->[0] eq "saved") {
				$value = $saved
			} elsif ($e->[0] eq "function") {
				$value = &{$e->[1]}();
			}  elsif ($e->[0] eq "gzip") {
				$value = "";
				$tmp = $e->[1];
				gzip \$tmp => \$value;
			} else {
				#print "debug $e->[0]|$e->[1]|\n";
				$value = pack($e->[0], @{$e}[1 .. 100]);
			}
		} elsif ((ref $e) eq "HASH") { #this part is not supported any more
			if (defined $e->{connect}) {
				connectTo($e->{connect});
			} elsif (defined $e->{sendFile}) {
				sendFileData($ftpDataSock, $e->{sendFile});
				if ($lastSock ne "") {sendit($lastSock, "200 transfer complete\r\n");}
				$sendFile = $e->{sendFile};
				$lastSock = $sock;
			}
			next;
		} else {
			$value = $e;
		}
		if ($pending > 0) {
			$pending --;
			if ($pending == 0) {
				substr($ret, $offset, 0) = length($value);
			}
		}
		$ret .= $value;
	}
	return $ret;
}


sub readCfg {
	open FD, "service.cfg" || die "Failed to open service.cfg $!\n";
	read FD, $buff, 0x100000;
	close FD;
	my $follow;
	my $mod;
	try {
		$allServices = decode_json($buff);
		foreach $e (keys %$allServices) {
			$allServices->{$e}->{name} = $e;
			$follow = $allServices->{$e}->{follow};
			if (defined $follow) {
				$mod = dclone($allServices->{$follow});
				splice @{$mod->{seq}}, 0,0, @{$allServices->{$e}->{seq}};
				if (defined $allServices->{$e}->{initMsg}) {
					$mod->{initMsg} = $allServices->{$e}->{initMsg};
				}
				$mod->{name} = $e;
				$allServices->{$e} = $mod;
			}
		}
	} catch {
		print "Failed to decode json $_\n";
		return;
	};
	if ($savedActCmd ne "") {
		processCmd($savedActCmd);
	}
}

sub connectTo {
	my $dst = shift;
	my ($dstHost, $port) = split(/:/, $dst);
	if ($dstHost eq "") {
		$dstHost = $peerHost;
		#print "dstHost is now $dstHost\n";
	}
	$meteSock = IO::Socket::INET->new( Proto    => 'tcp',
                                 PeerAddr => $dstHost,
                                 PeerPort => $port
                          ) || die "Failed to connect to $dstHost:$port\n";
	$meteState = 0;
	$s->add($meteSock);
	print "metepreter is connected $meteSock\n";
	$lastTs = getTS();
	return $meteSock;
}

sub readFile {
	my $fname = shift;
	my $buff;
	if (open (FD, $fname)) {
		read(FD, $buff, 0x1000000);
		close FD;
	} else {
		print "didnto find file $fname $!\n";
		$buff = "didnot find file $fname";
	}
	return $buff;
}
sub sendFileData {
	my ($sock, $fname) = @_;
	my $buff;
	if (open (FD, $fname)) {
		read(FD, $buff, 0x1000000);
		close FD;
	} else {
		print "didnto find file $fname $!\n";
		$buff = "didnot find file $fname";
	}
	sendit($sock, $buff);
}

sub execute {
	my $a = shift; #action
	try {
		if ($a->[0] eq "connect") {
			#TODO it's not always proper to use ftpDataSock here
			$ftpDataSock = $sock = connectTo($a->[1]);
		} elsif ($a->[0] eq "sendFile") {
			sendFileData($ftpDataSock, $a->[1]);
		} elsif ($a->[0] eq "send") {
			sendit($sock, $a->[1]);
		}
	} catch {
		warn "caught error: $_"; 
	}
}

sub sendit {
	my ($sock, $data) = @_;
	if ($data =~ /^HTTP\/1\.\d\s+/) {
		my $offset = index($data, "\r\n\r\n");
		if ($offset > 0) {
			my $bodyLen = length($data) - $offset - 4;
			my $header = substr($data, 0, $offset);
			my $body = substr($data, $offset);
			my $pattern = "Content-Length: $bodyLen";
			$header =~ s/Content-Length:\s*\$/$pattern/;
			$data = $header . $body;
		}
	}
	if (length($sock) <= 0) {
		print "closing socket since there is no data to send\n";
		$s->remove($sock);
		delete $refs->{$sock};
		delete $ctx->{$sock};
		delete $isSSLSock->{$sock};
		close($sock);
		return;
	}
	if ($showData) {print "sending $_[1]\n";}
	syswrite($sock, $data);
}

use Time::HiRes qw( gettimeofday );
sub getTS {
	my ($seconds, $microseconds) = gettimeofday;
	return $seconds + (0.0+ $microseconds)/1000000.0;
}

#set up a bunch of sockets
sub setupSocket {
	my $ports = shift;
	my $port;
	my $sock1;
	foreach $port (keys %$srvSocks) {
		$sock1 = $srvSocks->{$port};
		if (! defined $ports->{$port}) {
			$s->remove($sock1);
			delete $srvSocks->{$port};
			delete $isSrvSock->{$sock1};
			close($sock1);
		}
	}
	my $sock1;
	foreach $port (keys %$ports) {
		if (defined $srvSocks->{$port}) { next;}
		print "listening on port $port\n";
		$sock1 = IO::Socket::INET->new( Proto    => 'tcp',
									 LocalAddr => $lhost,
									 LocalPort => $port,
									 Reuse     => 1,
									 Listen    => 10
							  ) || die "Failed to bind to port $port\n";
		$srvSocks->{$port} = $sock1;
		$isSrvSock->{$sock1} = 1;
		$s->add($sock1);
	}
}

sub check4SSL {
	my $client = shift;
	$buffer = "";
	$s2->add ($client);
	@readySocks = $s2->can_read(0.5);
	$s2->remove ($client);
	if ($#readySocks < 0) { return; }
	recv($client, $buffer, 1000, MSG_PEEK );
	if (length($buffer) < 100) {return;}
	@a = unpack("C*", $buffer);
	#print "first byte: $a[0]\n";
	if (($a[0] != 22) || ($a[1] != 3) || ($a[2] > 3)) { 
		#print "not SSL $a[0]|$a[1]|$a[2]\n";
		return;}
	#print "start SSL\n";
	if (! IO::Socket::SSL->start_SSL( $client,
		SSL_server => 1,
		Timeout => 5,
		SSL_version => 'TLSv1',
		SSL_cert_file => 'certs/server-cert.pem',
		SSL_key_file => 'certs/server-key.pem',
	)) {
		print "SSL Handshake FAILED - $!\n";
		return;
	}
	$isSSLSock->{$client} = 1;
}
sub input_thread {
	my $tmp;
	while (<STDIN>) {
		chomp($tmp = $_);
		$threadVar = $tmp;
	}
}

#overcome the problem where on windows, $s->can_read(0.5) will return immediately if $s is empty
sub mySelect {
	my $timeout = shift;
	if ($s->count() == 0) {
		select (undef, undef, undef, $timeout);
		return ();
	} else {
		return $s->can_read($timeout);
	}
}