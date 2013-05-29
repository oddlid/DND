#!/usr/bin/env perl
# Substitute for the original "sendsms".
# Does exactly the same as the original, but then monitors the smsd spool directories
# for success or failure by checking where the file ends up.
# To be used in combination with "DND", so one can dispatch the OP5 notification to another node
# if smsd is unable to send the SMS for some reason (like no coverage, no money, etc.).
#
# Licence: GPL
# Author:  Odd Eivind Ebbesen <odd@oddware.net>
#
# 2013-05-29 10:56:49

package SendSMS;

use strict;
use warnings;

use File::Temp;
use File::Basename;
use Linux::Inotify2;    # requires Linux >= 2.6.13

use constant SMS_OUT  => '/var/spool/sms/outgoing';
use constant SMS_SENT => '/var/spool/sms/sent';
use constant SMS_FAIL => '/var/spool/sms/failed';
use constant SMS_TMPL => 'send_XXXXXX';
use constant E_OK     => 0;
use constant E_FAIL   => 1;

my ($dest, $text) = @ARGV;

if (!$dest) {
   print("Destination: ");
   chomp($dest = <STDIN>);
}
if (!$text) {
   print("Text: ");
   chomp($dest = <STDIN>);
}

my $status;
my $notifier              = Linux::Inotify2->new;
my $fh                    = File::Temp->new(TEMPLATE => SMS_TMPL, DIR => SMS_OUT, UNLINK => 0);
my ($fname, undef, undef) = File::Basename::fileparse($fh->filename);

# Start watching sent/ and failed/
$notifier->watch(
   SMS_SENT, 
   IN_MOVED_TO,
   sub {
      my $e = shift;
      if ($e->name eq $fname) {
         $status = E_OK;
         $e->w->cancel;
      }
   }
);

$notifier->watch(
   SMS_FAIL, 
   IN_MOVED_TO,
   sub {
      my $e = shift;
      if ($e->name eq $fname) {
         $status = E_FAIL;
         $e->w->cancel;
      }
   }
);

# Do this after the notifiers have been set up, so we don't miss anything
printf($fh "To: %s\n\n%s", $dest, $text);
close($fh);

# Poll the two dirs until our file ends up in one of them.
# This loop gets cancelled from within the callback subs given to watch()
1 while ($notifier->poll);

# 0 = OK, file was moved to sent/
# 1 = FAIL, file was moved to failed/
exit($status);

__END__

