#!/usr/bin/env perl
# Wrapper script to generate the correct file format for DND.pm
# To be called from OP5.
#
# Licence: GPL
# Author:  Odd Eivind Ebbesen <odd@oddware.net>

package DNDSend;

use 5.008;
use strict;
use warnings;

use Carp;
use Getopt::Long;
use Pod::Usage;

BEGIN {
   use FindBin;
   use lib "$FindBin::Bin";
   use DND;

   our $VERSION = $main::VERSION = $DND::VERSION;
}

sub _parse_opts {
   my $opt = {
      created  => time,
      src_host => Sys::Hostname::hostname,    # Imported via DND
   };

   GetOptions(
      "help|h|?"            => \$opt->{help},
      "man"                 => \$opt->{man},
      "dndman"              => \$opt->{dndman},
      "dir=s"               => \$opt->{dir},
      "source-host=s"       => \$opt->{src_host},
      "destination-host=s@" => \$opt->{dst_host},
      "command=s@"          => \$opt->{cmd},
      "comments=s"          => \$opt->{comments},
      "kill"                => sub { exit(DND::_kill); },
      "V|version"           => sub { Getopt::Long::VersionMessage(0); exit(0); },
   ) or return 0;

   DND::show_manpage if ($opt->{dndman});
   pod2usage(-exitval => 0, -verbose => 1) if ($opt->{help});
   pod2usage(-exitval => 0, -verbose => 2) if ($opt->{man});

   # delete the entries that DND should not parse before returning
   delete($opt->{$_}) foreach (qw/help man dndman/);

   return $opt;
}

sub notify {
   my $opts = _parse_opts;
   if (!$opts) {
      pod2usage(-exitval => 2, -verbose => 1);
   }
   DND::notify($opts);
}

if (@ARGV) {
   notify;
}
else {
   pod2usage(-exitval => 1, -verbose => 1);
}

__END__

=pod

=head1 NAME

DNDSend - Write a file in correct format to the DND (Distributed Notification Daemon) queue.

=head1 DESCRIPTION

This is a wrapper script around C<DND.pm> that writes it's given arguments
in the correct format to the spooler queue defined in C<DND.pm> and
leaves the rest to any given running instance of C<DND.pm>. It does not
actually send anything itself. It only writes a file to save you from
the work of remembering the format yourself.

=head1 SYNOPSIS

C<< DNDSend.pl --destination-host <host> --command <...> [ --dir <path> | --source-host <host> | --comments <...> ] | --help | --man >> 

=head1 OPTIONS

Options are implemented using C<Getopt::Long>, which means that the usual
rules of how to pass options apply. Options can be shortened as long as
it's unique. This means you could just as well specify C<--source-host>
as C<-s> as there is no other option starting with 's'. For options like
C<--destination-host> and C<--dir>, they can be shortened down to C<--de>
and C<--di> since that's what it takes to make them unique. Options that
require values can be given either as the next parameter after the option,
or with an equal sign, eg. C<< --dir /tmp >> or C<< --dir=/tmp >>.

=over

=item C<< --destination-host | --dest >>

The host the file should be delivered to, given as either hostname or
IP. This option may be given several times in order to specify alternate
hosts to deliver to in case the preferred one is not reachable for
some reason.

=item C<< --command >>

The command to execute on the target host. It can be anything, but take
care to quote and escape properly so the shell does not interpret the
command before it's parsed by this script. This option may be given any
number of times, if you want to execute several commands in sequence on
the target host.

=item C<< --dir >>

The directory to write the file in. By default, this value is taken from
the C<DND.pm> module, but for debugging purposes, and maybe something
I havent't thought of yet, you can override it on the command line.

=item C<< --source-host | -s >>

This option is by default set to the hostname of the host you execute
this script on, but it may be overridden if you need to.

=item C<< --comments >>

If you want to include comments in the file, you can specify them with
this option. It may not be repeated, so you need to give it as one
single string. It should not contain any equal sign, as that is used as
the key-value separator in the file format. Should you forget, it's no
problem, but it will be stripped from the input before it's written to
the file.

=item C<< --kill >>

Tries to read the pidfile of C<DND.pm> and sends that PID the C<TERM>
signal. Just a shortcut for convenience.

=item C<< --help | -h | -? >>

Outputs a brief help message

=item C<< --man | -m >>

Outputs all POD in this file formatted as a man page. Exactly the same
result as if you run C<perldoc> on this file.

=item C<< --dndman >>

Outputs the man page of C<DND.pm>. Just a shortcut, as you could just
as well run C<perldoc> on C<DND.pm> directly.

=back

=head1 AUTHOR

Odd Eivind Ebbesen <odd@oddware.net>

=head1 VERSION

v0.1.8 @ 2013-05-28 14:21:34

=cut

