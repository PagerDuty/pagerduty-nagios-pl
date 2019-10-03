#!/usr/bin/env perl

# Nagios plugin that sends Nagios events to PagerDuty.
#
# Copyright (c) 2011, PagerDuty, Inc. <info@pagerduty.com>
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#     * Neither the name of PagerDuty Inc nor the
#       names of its contributors may be used to endorse or promote products
#       derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL PAGERDUTY INC BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


use Pod::Usage;
use Getopt::Long;
use Sys::Syslog;
use HTTP::Request::Common qw(POST);
use HTTP::Status qw(is_client_error);
use LWP::UserAgent;
use File::Path;
use Fcntl qw(:flock);
use Sys::Hostname;

# NEW FEATURES WERE DEVELOPED AGAINST PERL v 5.18
#################################################################################
# CONFIG BLOCK
# This is a hack that defines the fields
# that we DO care about and everything else is just filtered out.
# This is to prevent events from sending all 200+ fields that Nagios generates
# over to your phone when a page goes out.
# SOME OF these are defined in https://github.com/NagiosEnterprises/nagioscore/blob/master/include/macros.h
# (replace MACRO_ with NAGIOS_)
# Not all. Welcome to Nagios, enjoy your stay.
# Note that this does a SUBSTRING MATCH, any environment variable that contains
# these strings will be dropped.
# Please keep this list sorted.
# Note that any unpopulated fields will be dropped and Anot sent to Pagerduty.

my @keep_nagios_fields =(
	"NAGIOS_CONTACTPAGER",
	"NAGIOS_EVENTSTARTTIME",
	"NAGIOS_HOSTDISPLAYNAME",
	"NAGIOS_HOSTCHECKCOMMAND",
	"NAGIOS_HOSTNAME",
	"NAGIOS_HOSTSTATE",
	"NAGIOS_HOSTEVENTID",
	"NAGIOS_HOSTGROUPNAMES",
	"NAGIOS_HOSTGROUPNOTES",
	"NAGIOS_HOSTGROUPNOTESURL",
	"NAGIOS_HOSTINFOURL", # Unlike everything else, this is populated with an error message if unset, handled with @nagios_ignore_value_substrings
	"NAGIOS_HOSTNAME",
	"NAGIOS_HOSTNOTES",
	"NAGIOS_HOSTNOTESURL",
	"NAGIOS_HOSTOUTPUT",
	"NAGIOS_NOTIFICATIONTYPE",
	"NAGIOS_SERVICEDESC",
	"NAGIOS_SERVICEDISPLAYNAME",
	"NAGIOS_SERVICEINFOURL", # See note for NAGIOS_HOSTINFOURL
	"NAGIOS_SERVICEOUTPUT",
	"NAGIOS_SERVICESTATE",
	"NAGIOS__HOSTAWS_AZ",
	"NAGIOS_pd_nagios_object",
	"NAGIOS_pd_version",
);

# If NAGIOS_pd_nagios_object == "service", drop these fields even when set (since they're redundant)
my @delete_when_service = (
	"NAGIOS_HOSTOUTPUT",
	"NAGIOS_HOSTCHECKCOMMAND",
	"NAGIOS_HOSTGROUPNAMES",
	"NAGIOS_HOSTGROUPNOTES",
	"NAGIOS_HOSTGROUPNOTESURL",
	"NAGIOS_HOSTOUTPUT",
);

# If a value is one of these substrings, drop it as well.
my @nagios_ignore_value_substrings = (
	"website_url not set"
);

# END CONFIG BLOCK
################################################################################


=head1 NAME

pagerduty_nagios -- Send Nagios events to the PagerDuty alert system

=head1 SYNOPSIS

pagerduty_nagios enqueue [options]

pagerduty_nagios flush [options]

=head1 DESCRIPTION

  This script passes events from Nagios to the PagerDuty alert system. It's
  meant to be run as a Nagios notification plugin. For more details, please see
  the PagerDuty Nagios integration docs at:
  http://www.pagerduty.com/docs/nagios-integration.

  When called in the "enqueue" mode, the script loads a Nagios notification out
  of the environment and into the event queue.  It then tries to flush the
  queue by sending any enqueued events to the PagerDuty server.  The script is
  typically invoked in this mode from a Nagios notification handler.

  When called in the "flush" mode, the script simply tries to send any enqueued
  events to the PagerDuty server.  This mode is typically invoked by cron.  The
  purpose of this mode is to retry any events that couldn't be sent to the
  PagerDuty server for whatever reason when they were initially enqueued.

=head1 OPTIONS

  --api-base URL
    The base URL used to communicate with PagerDuty.  The default option here
    should be fine, but adjusting it may make sense if your firewall doesn't
    pass HTTPS traffic for some reason.  See the PagerDuty Nagios integration
    docs for details.

  --field KEY=VALUE
    Add this key-value pair to the event being passed to PagerDuty.  The script
    automatically gathers Nagios macros out of the environment, so there's no
    need to specify these explicitly.  This option can be repeated as many
    times as necessary to pass multiple key-value pairs.  This option is only
    useful when an event is being enqueued.0

  --help
    Display documentation for the script.

  --queue-dir DIR
    Path to the directory to use to store the event queue.  By default, we use
    /tmp/pagerduty_nagios.

  --verbose
    Turn on extra debugging information.  Useful for debugging.

  --proxy
    Use a proxy for the connections like "--proxy http://127.0.0.1:8888/"

=cut

# This release tested on:
# Debian Sarge (Perl 5.8.4)
# Ubuntu 9.04  (Perl 5.10.0)

my $opt_api_base = "https://events.pagerduty.com/nagios/2010-04-15";
my %opt_fields;
my $opt_help;
my $opt_queue_dir = "/tmp/pagerduty_nagios";
my $opt_verbose;
my $opt_proxy;

#** @method public is_variable_allowed ($variable_name, $variable_value)
# Given an variable name, see if we want to allow it to be put in a PagerDuty payload.
# Returns 1 if it should be carried over, 0 otherwise
#*
sub is_variable_allowed {
	my ($variable_name, $variable_value) = @_;
	my $is_allowed_var = 1;

	# First, check if it's an empty string.
	if ($variable_value eq "") {
		print STDERR "Skipping key $variable_name because its value is empty.\n" if $opt_verbose;
		$is_allowed_var = 0;
		return $is_allowed_var;
	}

	# Then, make sure that ICINGA or NAGIOS exists in the variable.
	if ($variable_name !~ /^(ICINGA|NAGIOS)_(.*)$/) {
		$is_allowed_var = 0;
		# We can just escape here.
		print STDERR "Skipping key $variable_name because it does not match ICINGA or NAGIOS\n" if $opt_verbose;
		return $is_allowed_var;
	};

	# Finally, make sure it's a field we want to keep.
	unless ($variable_name ~~ @keep_nagios_fields) {
		$is_allowed_var = 0;
		print STDERR "Skipping key $variable_name because it is not in \@keep_nagios_fields.\n" if $opt_verbose;
		return $is_allowed_var;
	}

	# And finally, filter out anything we know is a "bad" value.
	foreach (@nagios_ignore_value_substrings) {
		if (index($variable_value, $_) != -1) {
			$is_allowed_var = 0;
			print STDERR "Skipping key $variable_name beacuse value $variable_value was found in \@nagios_ignore_value_substrings\n" if $opt_verbose;
			return $is_allowed_var;
		}
	}

	return $is_allowed_var;
}

#** @method public filter_fields_for_service_type (%event_hash)
# Given a %event_hash, remove all the fields that are in @delete_when_service
# Returns the filtered hash.
#*
sub filter_fields_for_service_type {
	my (%events_hash) = @_;
	if ($events_hash{"NAGIOS_pd_nagios_object"} ne "service") {
		print STDERR "Expected this to be a service, it's $events_hash{'NAGIOS_pd_nagios_object'}. Returning untoutched.\n" if $opt_verbose;
		return %events_hash;
	}

	my $k;
	foreach $k (keys %events_hash) {
		if ($k ~~ @delete_when_service) {
			print STDERR "Removing key $k because it is \@delete_when_service\n" if $opt_verbose;
			delete $events_hash{$k};
		}
	}
	return %events_hash;
}

#** @method strip_appname_string_from_events_hash (%event_hash)
# Given %event_hash, rename all the keys so they don't start with INCINGA_ or NAGIOS_.
# Returns the altered hash.
#*
sub strip_appname_string_from_events_hash {
	my (%events_hash) = @_;
	my %cleaned_events_hash;
	foreach $k (keys %events_hash) {
		my $newkey = $k;
		$newkey =~ s/INCINGA_//;
		$newkey =~ s/NAGIOS_//;
		print STDERR "Writing cleaned output $k becomes $newkey = $events_hash{$k}\n" if $opt_verbose;
		$cleaned_events_hash{$newkey}  = $events_hash{$k};
	}
	return %cleaned_events_hash;
}

sub get_queue_from_dir {
	my $dh;

	unless (opendir($dh, $opt_queue_dir)) {
		syslog(LOG_ERR, "opendir %s failed: %s", $opt_queue_dir, $!);
		die $!;
	}

	my @files;
	while (my $f = readdir($dh)) {
		next unless $f =~ /^pd_(\d+)_\d+\.txt$/;
		push @files, [int($1), $f];
	}

	closedir($dh);

	@files = sort { @{$a}[0] <=> @{$b}[0] } @files;
	return map { @{$_}[1] } @files;
}


sub flush_queue {
	my @files = get_queue_from_dir();
	my $ua = LWP::UserAgent->new;

	# It's not a big deal if we don't get the message through the first time.
	# It will get sent the next time cron fires.
	$ua->timeout(15);

	if ($opt_proxy) {
		$ua->proxy (['http', 'https'], $opt_proxy);
	}

	foreach (@files) {
		my $filename = "$opt_queue_dir/$_";
		my $fd;
		my %event;

		print STDERR "==== Now processing: $filename\n" if $opt_verbose;

		unless (open($fd, "<", $filename)) {
			syslog(LOG_ERR, "open %s for read failed: %s", $filename, $!);
			die $!;
		}

		while (<$fd>) {
			chomp;
			my @fields = split("=", $_, 2);
			$event{$fields[0]} = $fields[1];
		}

		close($fd);

		my $req = POST("$opt_api_base/create_event", \%event);

		if ($opt_verbose) {
			my $s = $req->as_string;
			print STDERR "Request:\n$s\n";
		}

		my $resp = $ua->request($req);

		if ($opt_verbose) {
			my $s = $resp->as_string;
			print STDERR "Response:\n$s\n";
		}

		if ($resp->is_success) {
			syslog(LOG_INFO, "Nagios event in file %s ACCEPTED by the PagerDuty server.", $filename);
			unlink($filename);
		}
		elsif (is_client_error($resp->code)) {
			syslog(LOG_WARNING, "Nagios event in file %s REJECTED by the PagerDuty server.  Server says: %s", $filename, $resp->content);
			unlink($filename) if ($resp->content !~ /retry later/);
		}
		else {
			# Something else went wrong.
			syslog(LOG_WARNING, "Nagios event in file %s DEFERRED due to network/server problems.", $filename);
			return 0;
		}
	}

	# Everything that needed to be sent was sent.
	return 1;
}


sub lock_and_flush_queue {
	# Serialize access to the queue directory while we flush.
	# (We don't want more than one flush at once.)

	my $lock_filename = "$opt_queue_dir/lockfile";
	my $lock_fd;

	unless (open($lock_fd, ">", $lock_filename)) {
		syslog(LOG_ERR, "open %s for write failed: %s", $lock_filename, $!);
		die $!;
	}

	unless (flock($lock_fd, LOCK_EX)) {
		syslog(LOG_ERR, "flock %s failed: %s", $lock_filename, $!);
		die $!;
	}

	my $ret = flush_queue();

	close($lock_fd);

	return $ret;
}


sub enqueue_event {
	my %event;

	# Scoop all the Nagios related stuff out of the environment.
	while ((my $k, my $v) = each %ENV) {
		next unless (is_variable_allowed($k, $v));
		print STDERR "Writing out k=v $k = $v \n" if $opt_verbose;
		$event{$k} = $v;
	}

	# Filter out again anything that's Host-related when we're alerted on Services.
	if ($event{NAGIOS_pd_nagios_object} eq "service") {
		%event = filter_fields_for_service_type(%event);
	}

	%event = strip_appname_string_from_events_hash(%event);

	# Apply any other variables that were passed in.
	%event = (%event, %opt_fields);
	# Add in the local hostname to the fields (useful for figuring out which Nagios instance generated this event)
	$event{"NAGIOS_SERVER"} = hostname;

	$event{"pd_version"} = "1.0";

	# Right off the bat, enqueue the event.  Nothing tiem consuming should come
	# before here (i.e. no locks or remote connections), because we want to
	# make sure we get the event written out within the Nagios notification
	# timeout.  If we get killed off after that, it isn't a big deal.

	my $filename = sprintf("$opt_queue_dir/pd_%u_%u.txt", time(), $$);
	my $fd;

	unless (open($fd, ">", $filename)) {
		syslog(LOG_ERR, "open %s for write failed: %s", $filename, $!);
		die $!;
	}

	while ((my $k, my $v) = each %event) {
		# "=" can't occur in the keyname, and "\n" can't occur anywhere.
		# (Nagios follows this already, so I think we're safe)
		print $fd "$k=$v\n";
	}

	close($fd);
}

###########

GetOptions("api-base=s" => \$opt_api_base,
		   "field=s%" => \%opt_fields,
		   "help" => \$opt_help,
		   "queue-dir=s" => \$opt_queue_dir,
		   "verbose" => \$opt_verbose,
		   "proxy=s" => \$opt_proxy
		  ) || pod2usage(2);

pod2usage(2) if @ARGV < 1 ||
	 (($ARGV[0] ne "enqueue") && ($ARGV[0] ne "flush"));

pod2usage(-verbose => 3) if $opt_help;

my @log_mode = ("nofatal", "pid");
push(@log_mode, "perror") if $opt_verbose;

openlog("pagerduty_nagios", join(",", @log_mode), LOG_LOCAL0);

# This function automatically terminates the program on things like permission
# errors.
mkpath($opt_queue_dir);

if ($ARGV[0] eq "enqueue") {
	enqueue_event();
	lock_and_flush_queue();
}
elsif ($ARGV[0] eq "flush") {
	lock_and_flush_queue();
}
