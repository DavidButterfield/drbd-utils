#!/usr/bin/perl
# vim: set sw=4 ts=4 et : 

use strict;
use warnings;

## MAYBE set 'sane' PATH ??

$ENV{LANG} = 'C';
$ENV{LC_ALL} = 'C';
$ENV{LANGUAGE} = 'C';

#use Data::Dumper;

# globals
my $PROC_DRBD = "/proc/drbd";
my ($HOSTNAME) = (`uname -n` =~ /(\S+)/);
my $stderr_to_dev_null = 1;
my $watch = 0;
my %drbd;
my %minor_of_name;
my $DRBD_VERSION;
my @DRBD_VERSION;

our $use_colors = (-t STDOUT) + 0;

my %xen_info;
my %virsh_info;

# sets $drbd{minor}->{name} (and possibly ->{ll_dev})
sub map_minor_to_resource_names()
{
	my @drbdadm_sh_status = `drbdadm sh-status`;
	my ($ll_res, $ll_dev, $ll_minor, $conf_res, $conf_vnr, $minor, $name, $vnr);

	for (@drbdadm_sh_status) {
		# volumes only present in >= 8.4
		# some things generated by drbdadm

		/^_conf_res_name=(.*)\n/	and $conf_res = $1, $name = $conf_res;
		/^_conf_volume=(\d+)\n/		and $conf_vnr = $1;

		/^_stacked_on=(.*?)\n/		and $ll_res = $1;
		# not always present:
		/^_stacked_on_device=(.*)\n/	and $ll_dev = $1;
		/^_stacked_on_minor=(\d+)\n/	and $ll_minor = $1;

		# rest generated by drbdsetup
		/^_minor=(.*?)\n/		and $minor = $1;
		/^_res_name=(.+?)\n/		and $name = $1;
		/^_volume=(\d+)\n/		and $vnr = $1;

		/^_sh_status_process/	or next;

		$drbd{$minor}{name} = $name;
		if (defined $conf_vnr) {
			# >= 8.4, append /volume to resource name.
			# If both are present, they should be the same.  But
			# just in case, prefer the kernel volume number, if it
			# is present and positive. Else, use the volume number
			# from the config.
			$drbd{$minor}{name} .= defined $vnr ? "/$vnr" : "/$conf_vnr";
		}
		$minor_of_name{$name} = $minor;
		$drbd{$minor}{ll_dev} = defined($ll_dev) ? $ll_minor : $ll_res
			if $ll_res;
	}

	# fix up hack for git versions 8.3.1 > x > 8.3.0:
	# _stacked_on_minor information is missing,
	# _stacked_on is resource name
	# may be defined (and reported) out of order.
	for my $i (keys %drbd) {
		next unless exists $drbd{$i}->{ll_dev};
		my $lower = $drbd{$i}->{ll_dev};
		next if $lower =~ /^\d+$/;
		next unless exists $minor_of_name{$lower};
		$drbd{$i}->{ll_dev} = $minor_of_name{$lower};
	}
	# fix up to be able to report "lower dev of:"
	for my $i (keys %drbd) {
		next unless exists $drbd{$i}->{ll_dev};
		my $lower = $drbd{$i}->{ll_dev};
		$drbd{$lower}->{ll_dev_of} = $i;
	}
}

sub ll_dev_info {
	my $i = shift;
	( "ll-dev of:", $i, $drbd{$i}{name} )
}

# sets $drbd{minor}->{state} and (and possibly ->{sync})
sub slurp_proc_drbd_or_exit() {
	unless (open(PD,$PROC_DRBD)) {
		print "drbd not loaded\n";
		exit 0;
	}

	$_=<PD>;
	my ($DRBD_VERSION) = /version: ([\d\.]+)/;
	@DRBD_VERSION = split(/\./, $DRBD_VERSION);
	my $minor;
	while (defined($_ = <PD>)) {
		chomp;
		/^ *(\d+):/ and do {
# skip unconfigured devices
			$minor = $1;
			if (/^ *(\d+): cs:Unconfigured/) {
				next
					unless exists $drbd{$minor}
				and exists $drbd{$minor}{name};
			}
			my $uc = /Unconfigured/ ? "." : undef;
			($drbd{$minor}{conn})   =  $uc || m{\bcs:(\w+)\b};
			($drbd{$minor}{role})   =  $uc || m{\bro:(\w+/\w+)\b};
			($drbd{$minor}{dstate}) =  $uc || m{\bds:(\w+/\w+)\b};
		};
		/^\t\[.*sync.ed:/ and do {
			$drbd{$minor}{sync} = $_;
		};
		/^\t[0-9 %]+oos:/ and do {
			$drbd{$minor}{sync} = $_;
		};
	}
	close PD;
	for (values %drbd) {
		$_->{conn} ||= "Unconfigured";
		$_->{role} ||= ".";
		$_->{dstate} ||= ".";
	}
}

our $ansi_color_re = qr{(\033\[[\d;]+?m)};

sub abbreviate {
	my($w, $max) = @_;

	$max ||= 15;

    my $col_pre  = ($w =~ s/^$ansi_color_re//o ) ? $1 : "";
    my $col_post = ($w =~  s/$ansi_color_re$//o) ? $1 : "";

# keep UPPERCase and a few lowercase characters.
	1 while length($w) > $max && $w =~ s/([a-z]+)[a-z]/$1/g;

	return $col_pre . substr($w, 0, $max) . $col_post;
}

# taking a sorted list of keys and a hash, produce a short output.
# eg. Connected(*)/WFConnection(alice)
sub shorten_list {
	my ($keys, $hash, $max) = @_;
	my %vals;
	my %vl;

	for my $k (@$keys) {
		$vals{ $hash->{$k} }{ $k }++;
		$vl{ $hash->{$k} }++;
	}


# only a single value? Fine!
#	return abbreviate($hash->{$keys->[0]}, 6) . "(*)"
	return $hash->{$keys->[0]} . "(" . (values %vl)[0] . "*)"
		if 1 == (keys %vals);

# only 1 or 2 keys, ie. 2 values? Fine, done.
	return join("/", map { abbreviate($hash->{$_}, 6); } @$keys)
		if (@$keys <= 2);

# get sorted counts.
	my @v = sort { $b <=> $a; } values %vl;

#print "=========", Dumper(\@v);
# use a wildcard if one element is 3 or more times used, and more often than every other.
	my ($wc_data) =
		(($v[0] >= 3) && ($v[0] != $v[1])) ?
		grep($vl{$_} == $v[0], keys %vl) : ();

	my @stg;
	my %done;
	push(@stg, abbreviate($wc_data, 4) . "(" . $v[0] . "*)"),
		$done{$wc_data}++
			if ($wc_data);

	for my $k2 (@$keys) {
		my $v = $hash->{$k2};
		next if $done{$v}++;

		push @stg, abbreviate($v, 4) .
			"(" . join(",", keys %{$vals{$v}} ) . ")";
	}
	return join("/", @stg);
}

sub slurp_drbdsetup() {
    unless (open(DS,"drbdsetup events2 --now --statistics " .
                ($use_colors ? "--color=always " : "") .
                " |")) {
		print "drbdsetup not started\n";
		exit 0;
	}

    my(%later, $my_role);
    while (<DS>) {
        chomp;
        next unless s/^exists //;
        last if /^-$/; # EOD
        s/^([\w.-]+) name:([\w.-]+) //;
        my $what = $1;
        my $res = $2;
        my %f = map { split(/:/, $_, 2); } split(/ +/, $_);

        if ($what eq "resource" &&
                ($my_role = $f{'role'})) {
            $later{$res}{peers}{states}{$HOSTNAME} = $my_role;
            # local node is always connected
            $later{$res}{peers}{conns}{$HOSTNAME} = "Connected";
        } elsif ($what eq "connection") {
            my $p = $f{'conn-name'};
            my $cs= $f{'connection'};
            my $r = $f{'role'};
# Increase difference between "Connecting" and "Connected"
            $cs =~ s/^Connecting/'ing/;
            $later{$res}{peers}{states}{$p} = $r;
            $later{$res}{peers}{conns}{$p}  = $cs;
            $later{$res}{hosts}{$p}++;
        } elsif ($what eq "device") {
            my $minor = $f{minor};
            my $vol = $f{volume};
            $later{$res}{vol_minor}{$vol} = $minor;
            $later{$res}{peers}{dstates}{$HOSTNAME}  = $f{disk};
        } elsif ($what eq "peer-device") {
            my $n = $f{"conn-name"};
            $later{$res}{peers}{dstates}{$n} = $f{"peer-disk"};
        } else {
            warn("unknown key $what\n");
        }
    }


    for my $res2 (keys %later) {
        my @h = sort keys %{$later{$res2}{hosts}};
        my @h_incl = ($HOSTNAME, @h);
        my $vol_minor = $later{$res2}{vol_minor};
        my $peers = $later{$res2}{peers};

        for my $vol2 (keys %$vol_minor) {
            my $minor2 = $vol_minor->{$vol2};

            my $name = length($vol2) ? "$res2/$vol2" : $res2;
# create hash
            $drbd{$minor2}{name} = $name;
            my $v = $drbd{$minor2};


# role with local=first
            $v->{role} = join("/", $my_role,
                    shorten_list(\@h, $peers->{states}));
# role with all mixed together
            $v->{role} = shorten_list(\@h_incl, $peers->{states});

            $v->{dstate} = shorten_list(\@h_incl, $peers->{dstates});
            $v->{conn} = shorten_list(\@h_incl, $peers->{conns});
        }
    }

	close DS;
}


# sets $drbd{minor}->{pv_info}
sub get_pv_info()
{
	for (`pvs --noheadings --units g -o pv_name,vg_name,pv_size,pv_used`) {
		m{^\s*/dev/drbd(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s*$} or next;
		#  PV  VG  PSize  Used
		$drbd{$1}{pv_info} = { vg => $2, size => $3, used => $4 };
	}
}

sub pv_info
{
	my $t = shift;
	"lvm-pv:", @{$t}{qw(vg size used)};
}

# sets $drbd{minor}->{df_info}
sub get_df_info()
{
	for (`df -TPhl -x tmpfs`) {
		#  Filesystem  Type  Size  Used  Avail  Use%  Mounted  on
		m{^/dev/drbd(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)} or next;
		$drbd{$1}{df_info} = { type => $2, size => $3, used => $4,
			avail => $5, use_percent => $6, mountpoint => $7 };
	}
}

sub df_info
{
	my $t = shift;
	@{$t}{qw(mountpoint type size used avail use_percent)};
}

# sets $drbd{minor}->{xen_info}
sub get_xen_info()
{
	my $dom;
	my $running = 0;
	my %i;
	for (`xm list --long`) {
		/^\s+\(name ([^)\n]+)\)/ and $dom = $1;
		/drbd:([^)\n]+)/ and $i{$minor_of_name{$1}}++;
		m{phy:/dev/drbd(\d+)} and $i{$1}++;
		/^\s+\(state r/ and $running = 1;
		if (/^\)$/) {
			for (keys %i) {
				$drbd{$_}{xen_info} =
					$running ?
					"\*$dom" : "_$dom";
			}
			$running = 0;
			%i = ();
		}
	}
}

# set $drbd{minor}->{virsh_info}
sub get_virsh_info()
{
	local $/ = undef;
	my $virsh_list = `virsh list --all`;
	#  Id Name                 State
	# ----------------------------------
	#   1 mail                 running
	#   2 support              running
	#   - debian-master        shut off
	#   - www                  shut off

	my %info;
	my $virsh_dumpxml;
	my $pid;

	$virsh_list =~ s/^\s+Id\s+Name\s+?State\s*-+\n//;
	while ($virsh_list =~ m{^\s*(\S+)\s+(\S+)\s+(\S.*?)\n}gm) {
		$info{$2} = { id => $1, name => $2, state => $3 };
		# print STDERR "$1, $2, $3\n";
	}
	for my $dom (keys %info) {
		# add error processing as above
		$pid = open(V, "-|");
		return unless defined $pid;

		if ($pid == 0) { # child
			exec("virsh", "dumpxml", $dom)
			or die "can't exec program: $!";
			# NOTREACHED
		}

		# parent
		$_ = <V>;
		close(V) or warn "virsh dumpxml exit code: $?\n";
		for (m{<disk\ [^>]*>.*?</disk>}gs) {
			m{<source\ (?:dev|file)='/dev/drbd([^']+)'/>} or next;
			my $dev = $1;
			if ($dev !~ /^\d+$/) {
				my @stat = stat("/dev/drbd$dev") or next;
				$dev = $stat[6] & 0xff;
			}
			m{<target\ dev='([^']*)'\s+bus='([^']*)'}xg;
			$drbd{$dev}{virsh_info} = {
				domname =>
					$info{$dom}->{state} eq 'running' ?
					"\*$dom" : "_$dom",
				vdev => $1,
				bus => $2,
			};
		}
	}
}

sub virsh_info
{
	my $t = shift;
	@{$t}{qw(domname vdev bus)};
}

# first, for debugging of this script and its regex'es,
# allow reading from a prepared file instead of /proc/drbd
# Getopt::Long is standard since quite some time, but in case it's not available somewhere we'll fail soft.
eval {
    use Getopt::Long;

    GetOptions(
            "proc-drbd=s" => \$PROC_DRBD,
            "stderr-to-dev-null|d" => \$stderr_to_dev_null,
            "color|colors|c:s" => \$use_colors) or 
        die "Unknown command line argument.\n";

    $use_colors = 0 if $use_colors =~ m/^(never|no|off)$/;
    $use_colors = 1 if $use_colors =~ m/^(always|yes|on)$/;
    warn "unrecognized value for --color" unless $use_colors =~ /^[01]$/;
};

open STDERR, "/dev/null"
	if $stderr_to_dev_null;

map_minor_to_resource_names;

slurp_proc_drbd_or_exit;
slurp_drbdsetup if $DRBD_VERSION[0] >= 9;

get_pv_info;
get_df_info;
get_xen_info;
get_virsh_info;


# generate output, adjust columns
my @out = [];
my @out_plain = [];
my @maxw = ();
my $line = 0;

my @minors_sorted = sort { $a <=> $b } keys %drbd;
my $max_minor = $minors_sorted[-1];
my $minor_width = $max_minor > 10 ? 1+int(log($max_minor)/log(10)) : 2;
for my $m (@minors_sorted) {
	my $t = $drbd{$m};
	my @used_by = exists $t->{xen_info} ? "xen-vbd: $t->{xen_info}"
		    : exists $t->{pv_info} ? pv_info $t->{pv_info}
		    : exists $t->{df_info} ? df_info $t->{df_info}
		    : exists $t->{virsh_info} ? virsh_info $t->{virsh_info}
		    : exists $t->{ll_dev_of} ? ll_dev_info $t->{ll_dev_of}
		    : ();

	$out[$line] = [
		sprintf("%*u:%s", $minor_width, $m, $t->{name} || "??not-found??"),
		defined($t->{ll_dev}) ? "^^$t->{ll_dev}" : "",
		$t->{conn},
		$t->{role},
		$t->{dstate},
		@used_by
	];
	for (my $c = 0; $c <  @{$out[$line]}; $c++) {
        # strip color codes for column width calculation
		my $w =  $out[$line][$c];
        $w =~ s/$ansi_color_re//og;

		my $l =  length($w) + 1;
        $out_plain[$line][$c] = $w;
		$maxw[$c] = $l unless $maxw[$c] and $l < $maxw[$c];
	}
	++$line;
	if (defined $t->{sync}) {
		$out[$line++] =  [ $t->{sync} ];
	}
}
for my $l (0 .. $#out) {
    $_ = $out[$l];
    for (my $c2 = 0; $c2 < @$_; $c2++) {
        # printf columns don't know about escape codes, need to pad manually.
        print $_->[$c2], ' ' x ($maxw[$c2] - length($out_plain[$l][$c2]));
    }
	print "\n";
}
