# Getting Started

If you don't already have a PagerDuty "Nagios" service, you should create one:

- In your account, under the Services tab, click "Add New Service".
- Enter a name for the service and select an escalation policy. Then, select "Nagios" for the Service Type.
- Click the "Add Service" button.
- Once the service is created, you'll be taken to the service page. On this page, you'll see the "Service key", which will be needed when you configure your Nagios server to send events to PagerDuty.

## Setup for Debian, Ubuntu, and other Debian-derived systems:

Install the necessary Perl dependencies:

    aptitude install libwww-perl libcrypt-ssleay-perl

Copy over `pagerduty_nagios.cfg`:

    wget https://raw.github.com/PagerDuty/pagerduty-nagios-pl/master/pagerduty_nagios.cfg

Open the file in your favorite editor. Enter the service key corresponding to your Nagios service into the pager field.  The service key is a 32 character string that can be found on the service's detail page.

Copy the Nagios configuration file into place:

    cp pagerduty_nagios.cfg /etc/nagios3/conf.d

Add the contact "pagerduty" to your Nagios configuration's main contact group. If you're using the default configuration, open `/etc/nagios3/conf.d/contacts_nagios2.cfg` and look for the "admins" contact group. Then, simply add the "pagerduty" contact.

    define contactgroup{ 
      contactgroup_name       admins
      alias                   Nagios Administrators
      members                 root,pagerduty   ; <-- Add 'pagerduty' here.
    }

Download `pagerduty_nagios.pl`:

    wget https://raw.github.com/PagerDuty/pagerduty-nagios-pl/master/pagerduty_nagios.pl
    cp pagerduty_nagios.pl /usr/local/bin

Make sure the file is executable by Nagios:

    chmod 755 /usr/local/bin/pagerduty_nagios.pl

Enable environment variable macros in `/etc/nagios3/nagios.cfg` (if not enabled already):

    enable_environment_macros=1

Edit the nagios user's crontab:

    crontab -u nagios -e

Add the following line to the crontab:

    * * * * * /usr/local/bin/pagerduty_nagios.pl flush

Restart Nagios:

    /etc/init.d/nagios3 restart

## Setup for RHEL, Fedora, CentOS, and other Redhat-derived systems: 

Install the necessary Perl dependencies:

    yum install perl-libwww-perl perl-Crypt-SSLeay

Download `pagerduty_nagios.cfg`:

    wget https://raw.github.com/PagerDuty/pagerduty-nagios-pl/master/pagerduty_nagios.cfg

Open the file in your favorite editor. Enter the service key corresponding to your Nagios service into the pager field. The service key is a 32 character string that can be found on the service's detail page.

Copy the Nagios configuration file into place:

    cp pagerduty_nagios.cfg /etc/nagios

Edit the Nagios config to load the PagerDuty config. To do this, open `/etc/nagios/nagios.cfg` and add this line to the file:

    cfg_file=/etc/nagios/pagerduty_nagios.cfg

Add the contact "pagerduty" to your Nagios configuration's main contact group. If you're using the default configuration, open `/etc/nagios/localhost.cfg` and look for the "admins" contact group. Then, simply add the "pagerduty" contact.

    define contactgroup{ 
      contactgroup_name       admins
      alias                   Nagios Administrators
      members                 root,pagerduty   ; <-- Add 'pagerduty' here.
    }

Download `pagerduty_nagios.pl` and copy it to /usr/local/bin:

    wget https://raw.github.com/PagerDuty/pagerduty-nagios-pl/master/pagerduty_nagios.pl
    cp pagerduty_nagios.pl /usr/local/bin

Make sure the file is executable by Nagios:

    chmod 755 /usr/local/bin/pagerduty_nagios.pl

Enable environment variable macros in `/etc/nagios/nagios.cfg` (if not enabled already):

    enable_environment_macros=1

Edit the nagios user's crontab:

    crontab -u nagios -e

Add the following line to the crontab:

    * * * * * /usr/local/bin/pagerduty_nagios.pl flush

Restart Nagios:

    /etc/init.d/nagios3 restart

# License

## License and Copyright
Copyright (c) 2014, PagerDuty
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

* Neither the name of [project] nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
