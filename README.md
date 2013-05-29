# Distributed Notification Daemon - DND

## Description:

A spooler solution intended to be used in conjunction with OP5 in a
distributed setup, to aid in making sure notifications are sent regardless
of unstable GSM modems or other flaky conditions.

## Technical:

DND contains a daemon that should be run on each OP5 node, and a rewritten
version of "sendsms" that will monitor smsd's spooler directories to
detect where the message ends up (sent/ or failed/) and then return an
exit status, as opposed to the regular version that just writes the file
and quits. This way, if an SMS is not sent due to lack of coverage or
the like, the daemon can hand over the message to the next node in the
host preference list and try to send the message from that one instead.

## Licence: 

GPLv2

## Platform:

[Linux](http://www.kernel.org)
[Perl](http://www.perl.org)

## Author:

Odd Eivind Ebbesen <odd@oddware.net>
