#!/usr/bin/env perl
# Spooler solution for sending command files between hosts
# and execute the contents, and re-dispatch the file if execution 
# is not successful.
# Intended for use with a distributed OP5 setup, but runs standalone.
#
# NOTE: This does NOT solve the problem with SMSD not sending SMS due to 
# lack of GSM coverage, or similar, as neither "sendsms" or "smsd" itself 
# provides any return status indicating whether SMS is sucessfully sent.
# That would require another hack that follows smsd's logfile and detects
# if the message is sent or not. Rewriting "sendsms" would be a good start.
#
# Update:
#   I've written a new "sendsms" that solves this.
#
# Licence: GPL
# Author:  Odd Eivind Ebbesen <odd@oddware.net>

# Distributed Notification Daemon (name cred: Johannes Dagemark)
package DND;    

BEGIN { our $VERSION = '0.1.8'; }

use 5.008;
use strict;
use warnings;

use Carp;
use POSIX;
use Sys::Hostname;
use Linux::Inotify2;    # requires Linux >= 2.6.13
use List::Util;
use File::Spec;
use File::Temp;
use IO::File;
use Pod::Usage;

### Helper class DND::Pid ###
{

   package DND::Pid;

   use strict;
   use warnings;
   use Carp;

   use constant DEFAULT_PIDFILE => '/var/run/op5/dnd.pid';

   my $_self;

   sub new {
      my $class = shift;
      my $pfile = shift || DEFAULT_PIDFILE;
      if (!$_self) {
         $_self = bless({}, $class);
      }
      # file() and pid() returns $self when setting values, so one can chain it all
      return $_self->file($pfile)->pid($$);
   }

   # returns filename with no arg, $self with an argument
   sub file {
      my $self = shift;
      if (@_) {
         $self->{_file} = shift;
         return $self;
      }
      return $self->{_file};
   }

   # returns pid with no arg, $self with an argument
   sub pid {
      my $self = shift;
      if (@_) {
         $self->{_pid} = shift;
         return $self;
      }
      if (!defined($self->{_pid})) {
         $self->{_pid} = $$;
      }
      return $self->{_pid};
   }

   sub write {
      my $self = shift;
      my $file = $self->file;
      if (-f $file) {
         my $oldpid = $self->read;
         carp(qq(Stale pidfile: "$file" (pid: $oldpid). Previous instance may have crashed.));
      }

      open(my $fh, ">", $file) or croak($!);
      print($fh $self->pid, "\n");
      close($fh) or croak($!);

      return $self;
   }

   sub read {
      my $self = shift;
      open(my $fh, "<", $self->file) or return;    #croak($!);
      chomp(my $pid = <$fh>);
      close($fh) or croak($!);
      return $pid;
   }

   sub running {
      # This sub will only return true if there is a pidfile present on the system, either
      # because write() has been called by the current script, or by another instance.
      my $self    = shift;
      my $filepid = $self->read;

      return $filepid ? kill(0, $filepid) ? $filepid : undef : undef;
   }

   sub remove {
      my $self = shift;
      return unlink($self->file);
   }
}
### END DND::Pid ###

use constant {
   LOG_ERR    => 0,
   LOG_WARN   => 1,
   LOG_NOTICE => 2,
   LOG_INFO   => 3,
   LOG_DEBUG  => 4,
};

my $_log_fh;    # will be opened on demand
my $_log_level         = LOG_DEBUG;
my $_logfile           = '/opt/monitor/var/dnd.log';
my $_scp               = '/usr/bin/scp';
my $_spool_dir         = '/var/spool/dnd';
my $_instance_pid      = DND::Pid->new;
my $_run_in_foreground = 0;
my %_subfolders        = (
   q => 'queue',
   s => 'sent',
   f => 'failed',
   d => 'dispatched',
);

# ---------------------------------------------------------------- #

sub _get_user {
   return getpwuid($<) || getlogin();
}

sub _kill {
   # For external use, but prefixed name with _ to not confuse with the builtin kill
   my $pid = $_instance_pid->read;
   return 0 unless ($pid);
   return kill('TERM', $pid);
}

sub show_manpage {
   # For external use (DNDSend.pl)
   pod2usage(-exitval => 0, -verbose => 2, -input => __FILE__);
}

sub notify {
   # This sub is mainly for external use, when pulled in as a module.
   # Instead of keeping two files with shared variables in sync.
   # Writes a file of the expected format to the spool queue, with
   # the given params as key/value pairs in the file.

   _log(LOG_INFO, qq(Request to write spool file by user "%s"), _get_user);

   # pass hash ref with directives
   my $arg_href = shift;
   return unless (ref($arg_href) eq 'HASH');

   my $dir;
   if (exists($arg_href->{dir}) && defined($arg_href->{dir})) {
      $dir = $arg_href->{dir};
      delete($arg_href->{dir});
   }
   else {
      $dir = File::Spec->catdir($_spool_dir, $_subfolders{q});
   }

   my $tmpf = File::Temp->new(TEMPLATE => __PACKAGE__ . '_notify_XXXXXXXX', DIR => $dir, UNLINK => 0);
   my $line;

   while (my ($k, $v) = each(%{$arg_href})) {
      next unless ($v);
      # handle comments
      if ($k && $k eq 'comments') {
         $v =~ tr/=//d;    # remove separator if it happens to be in the string
         $tmpf->print("$v\n");
         next;
      }
      # If the value is an array, we will write one line for each value,
      # with the key repeated, to enable specifying alternate destination
      # hosts, in preferred order.
      # That way, you can have failover hosts to notify via, in case the
      # preferred host is unreachable for some reason.
      my $vtype = ref($v);
      if (!$vtype) {
         $line = sprintf("%s = %s\n", $k, $v);
      }
      elsif ($vtype eq 'ARRAY') {
         $line .= sprintf("%s = %s\n", $k, $_) foreach (@{$v});
      }
      $tmpf->print($line);
      $line = '';
   }
   _log(LOG_INFO, qq(Wrote file: "%s"), $tmpf);
   # Two possible returns:
   # undef if passed wrong parameter type (in the beginning),
   # 1/true if it got here
   return 1;
}

sub _timestamp {
   my ($sec, $min, $hour, $day, $mon, $year) = localtime;
   return sprintf("%04d-%02d-%02d %02d:%02d:%02d", $year + 1900, $mon + 1, $day, $hour, $min, $sec);
}

sub _log {
   my ($level, $msg, @params) = @_;
   return if ($level > $_log_level);
   if (!defined($_log_fh)) {
      $_log_fh = IO::File->new($_logfile, O_CREAT | O_WRONLY | O_APPEND);
      croak(qq(Unable to open logfile "$_logfile": $!)) unless ($_log_fh);
      $_log_fh->autoflush(1);
   }
   $msg = sprintf($msg, @params) if (scalar(@params));
   $msg = sprintf("%s [ %s ] => %s\n", _timestamp, hostname, $msg);
   $_log_fh->print($msg);
}

sub sig_handler {
   my $signal = shift;
   _log(LOG_INFO, qq(Cought signal "$signal". Cleaning up and preparing to die...));
   close($_logfile);
   $_instance_pid->remove;
   exit 0;
}

sub register_signals {
   $SIG{INT}  = \&sig_handler;
   $SIG{HUP}  = \&sig_handler;
   $SIG{ABRT} = \&sig_handler;
   $SIG{QUIT} = \&sig_handler;
   $SIG{TRAP} = \&sig_handler;
   $SIG{STOP} = \&sig_handler;
   $SIG{TERM} = \&sig_handler;
}

sub verify_spool {
   if (!-d $_spool_dir) {
      mkdir($_spool_dir, 0775) or croak($!);
   }
   foreach (values(%_subfolders)) {
      my $d = File::Spec->catdir($_spool_dir, $_);
      if (!-d $d) {
         mkdir($d, 0775) or croak($!);
      }
   }
}

sub _basename {
   my $file = shift || return;
   return (File::Spec->splitpath($file))[2];
}

sub satanize {    # pun on daemonize... :P
   close($_logfile);
   undef($_log_fh);

   my $pid = fork;
   if (!defined($pid)) {    # failed
      croak("fork failed: $!");
   }
   elsif ($pid) {           # I am parent
      exit 0;
   }

   POSIX::setsid or croak("setsid failed: $!");

   # if here, we're the child, and can continue
   chdir('/');              # change to top dir to not block mounted filesystems
   umask(0);                # reset file creation flags

   # Reset the PID as it might be different after the fork, and
   # write the file
   $_instance_pid->pid($$)->write;

   # close all open file descriptors
   foreach (0 .. POSIX::sysconf(POSIX::_SC_OPEN_MAX) || 1024) {
      POSIX::close($_);
   }

   # redirect IO
   open(STDIN,  '</dev/null') or croak($!);
   open(STDOUT, '>/dev/null') or croak($!);
   open(STDERR, '>&STDOUT')   or croak($!);

   _log(LOG_INFO, qq(Forked and running in background));
}

sub slurp_file {
   my $file = shift || return;    # undef in gives undef out
   open(my $fh, '<', $file) or return;
   chomp(my @lines = <$fh>);
   close($fh) or croak($!);
   return \@lines;
}

sub append_file {
   my $file = shift || return;
   my $data = shift || 'UNDEF';    # a string on purpose

   open(my $fh, '>>', $file) or croak($!);
   print($fh $data);
   close($fh) or croak($!);

   return 1;                       # always return true if we get to the end
}

sub move_file {
   my $file     = shift;
   my $dst      = shift || $_subfolders{s};
   my $new_file = File::Spec->catfile(($_spool_dir, $dst), _basename($file));
   return rename($file, $new_file);
}

sub dispatch {
   my $hostname = shift || return;
   my $file     = shift || return;
   my $cmd      = qq($_scp -qp "$file" $hostname:"$file");

   return system($cmd);    # maybe not flexible enough...
}

sub localexec {
   my $struct_ref = shift || return;    # hash ref to file content
   my ($ret, @res);
   foreach (@{ $struct_ref->{cmds} }) {
      $ret = system(qq($_));
      push(@res, [ $ret, $?, $_ ]);
   }
   # return a list with the first element being the sum of all
   # system call return values, and the rest is a list (array ref)
   # with return value, error code and command line for each system call made.
   return (List::Util::sum(map { $_->[0] } @res), \@res);
}

sub parse_incoming {
   my $file     = shift             || return;
   my $lines    = slurp_file($file) || return;
   my $basename = _basename($file)  || return;
   my $fstruct  = {};
   my @dhosts   = ();

   my $rx = qr/\s*(.*?)\s*=\s*(.*)/;    # split on "=". Change to use another format

   foreach (@{$lines}) {
      my ($k, $v) = $_ =~ /$rx/;
      # treat lines with no '=' as comments
      if (!$k || !$v) {
         push(@{ $fstruct->{comments} }, $_);
         next;
      }

      # remove trailing spaces in hostname/commands
      $v =~ s/\s+$//;

      if ($k eq 'dst_host') {
         # If hostname is localhost or 127.0.0.1, we don't want to copy to self, but
         # rather execute locally, so we set the proper hostname for localhost and go on.
         if (lc($v) eq 'localhost' || $v eq '127.0.0.1') {
            $v = hostname;
         }
         push(@dhosts, $v);
      }
      if ($k eq 'cmd') {
         push(@{ $fstruct->{cmds} }, $v);
      }
      else {
         $fstruct->{$k} = $v;
      }
   }

   my $err = 0;
   foreach my $dst_host (@dhosts) {
      if ($dst_host && lc(hostname) eq lc($dst_host)) {    # execute on this host
         my ($ex_sum, $ex_codes) = localexec($fstruct);
         if ($ex_sum == 0) {
            # move file to $spool/sent
            move_file($file, $_subfolders{s});
            _log(LOG_INFO, qq(File "%s" parsed and executed locally), $file);
            last;
         }
         else {
            # move file to $spool/failed
            # append a clue to why it failed
            move_file($file, $_subfolders{f});
            my $ex_printable =
              join(', ', map { sprintf("[ ret: %s, err: %s, cmd: %s ]\n", $_->[0], $_->[1], $_->[2]) } @{$ex_codes});
            my $failfile = File::Spec->catfile(($_spool_dir, $_subfolders{f}), $basename);
            append_file(
               $failfile,
               sprintf(
                  "\n\n%s (%s): Local execution failed. Return codes from system call: %s\n",
                  _timestamp, hostname, $ex_printable
               )
            );
            _log(LOG_INFO, qq(Errors when executing locally. Inspect file "%s" for more info.), $failfile);
            last;
         }
      }
      else {
         if ($dst_host && dispatch($dst_host, $file) == 0) {
            # move file to $spool/dispatched
            # append status msg to file?
            move_file($file, $_subfolders{d});
            append_file(
               File::Spec->catfile(($_spool_dir, $_subfolders{d}), $basename),
               sprintf(
                  qq(\n\n%s (%s): Successfully copied file "%s" to %s:"%s"\n),
                  _timestamp, hostname, $basename, $dst_host, $file
               )
            );
            _log(LOG_INFO, qq(File "%s" copied to host "%s"), $basename, $dst_host);
            $err = 0;
            last;
         }
         else {
            $err = 1;
            _log(LOG_WARN, qq(Error copying file "%s" via ssh), $file);
         }
      }
   }

   # means the loop above never succeded in any attempts
   if ($err) {
      # move file to $spool/failed
      # append a status msg to the file, giving a clue to why it failed
      move_file($file, $_subfolders{f});
      append_file(File::Spec->catfile(($_spool_dir, $_subfolders{f}), $basename),
         sprintf(qq(\n\n%s (%s): Error copying file "%s"\n), _timestamp, hostname, $file));
   }

   #...
   return $fstruct;
}

sub startup_scan {
   # If files have been written to the spool queue dir while this program was not running,
   # Inotify will not pick those up (unless you "touch" all those files afterwards),
   # so we need a way to process the queue at startup.
   my $qdir = File::Spec->catdir($_spool_dir, $_subfolders{q});
   opendir(my $dh, $qdir) or croak($!);
   # Sort files by modification time, oldest first, so that the files that got in
   # the queue first are processed first (FIFO).
   my @files =
     map { File::Spec->catfile($qdir, $_->[0]) }
     sort { $a->[1] <=> $b->[1] }
     map { [ $_, (stat(qq($qdir/$_)))[9] ] }    # index 9 from stat is timestamp for modified
     grep { !/^\./ && !-d qq($qdir/$_) } readdir($dh);

   closedir($dh) or croak($!);
   return @files;
}

sub run {
   # If something was passed, it means to show usage.
   # As we call this sub with package prefix at the end,
   # we need to check for > 1, not 0, as the package name
   # is passed as first arg.
   if (@_ > 1) {
      pod2usage(-verbose => 2, -exitval => 0);
   }

   # Check if there's already another instance of this program running,
   # and if so, bail out with an error.
   my $pid = $_instance_pid->running;
   if ($pid) {
      printf(STDERR "Another instance (pid: %d) seems to be running. Exiting.\n", $pid);
      exit(4);
   }

   _log(LOG_INFO, qq(Request to start up daemon as user "%s"), _get_user);
   # make sure we get killed the "right" way before we become a daemon
   _log(LOG_DEBUG, "Registering signals...");
   register_signals;
   # Make sure all directories we need are in place.
   # The script will croak if this sub fails.
   _log(LOG_DEBUG, "Verifying spool directory...");
   verify_spool;
   # become a daemon
   _log(LOG_DEBUG, "Becoming a daemon...");
   satanize unless ($_run_in_foreground);
   # parse files that might have been added while not running
   _log(LOG_DEBUG, "Running startup scan...");
   parse_incoming($_) foreach (startup_scan);

   # register poller
   my $inotify = Linux::Inotify2->new;
   $inotify->watch(
      File::Spec->catdir($_spool_dir, $_subfolders{q}),
      IN_CLOSE_WRITE,
      sub {
         my $e   = shift;
         my $ret = parse_incoming($e->fullname);
      }
   );
   _log(LOG_DEBUG, "Poller instance created. Entering event loop...");
   # Infinite event loop
   1 while $inotify->poll;
}

### Entry point ###

# Construct as modulino, to allow for both usage as a module or as a script
__PACKAGE__->run(@ARGV) unless (caller);

1;
__END__


=pod

=head1 NAME

B<DND> - Distributed Notification Daemon

=head1 DESCRIPTION

This daemon is to be run on every host that runs OP5 Monitor in the
distributed setup. It checks a spool folder, and if it finds anything in
the incoming queue there, read the file, which should contain info about
source/destination host and the command to execute for notification. If
the C<< dst-host >> is the same as the one it's running on, execute
the command. If exit status is 0, move the file to F<< $spool/sent >>,
otherwise to F<< $spool/failed >> and write info about why it failed in
the end of the file. If dst_host is another machine, copy the file over
to that machines spool so the remote host can take care of notifying
just as above. If moving fails, move the file to F<< $spool/failed >>,
and append info about why.

=head1 SYNOPSIS

=head2 Spool file format

 created  = <timestamp>
 src_host = <hostname>
 dst_host = <remote-hostname>
 dst_host = <remote-hostname2>
 cmd      = <command-to-execute>
 cmd      = <command-to-execute2 with params>
 This is just a comment, as the line does not contain the separator character, 
 the equal sign, so it will be ignored.

Lines that contain an equal sign (=) will be split up as key-value
pairs. The keys will be scanned for certain keywords (C<dst_host>,
C<cmd>), and given a match, it tries execute the command given as the
value of C<cmd>, either locally, if a value for C<dst_host> was found,
and matches the hostname of the running host, or by copying the file via
C<scp> to C<dst_host> if it's not the current host. If another instance
of C<DND.pm> is running on the remote host, it will pick up the file
and repeat this process.

You can specify several destination hosts or commands by repeating lines
for additional values. Commands specified this way will be executed
sequentially, while destination hosts will be tried until either it's
the local host, or the file can be copied to the host, and then stops
after whatever succeeds first. This enables you to give fallback hosts
to execute on, in case the preferred one is unreachable for some reason.

=head1 FILES

=over

=item Pidfile: 

F<< /var/run/op5/dnd.pid >>

=item Logfile:

F<< /opt/monitor/var/dnd.log >>

=item Spool directory: 

F<< /var/spool/dnd/{queue,sent,failed,dispatched} >>


=back

=head1 AUTHOR

Odd Eivind Ebbesen <odd@oddware.net>

=head1 VERSION

v0.1.8 @ 2013-05-28 14:21:34

=cut

