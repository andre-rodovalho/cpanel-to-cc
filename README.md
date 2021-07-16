# cPanel to SiteHost Containers Migration Tool

This tool has been built to automate website migrations from cPanel® servers (Source) to SiteHost Cloud Container servers (Destination).

This bash script leverages the [SiteHost API](https://docs.sitehost.nz/api/v1.1/) and [WHM API 1](https://api.docs.cpanel.net/whm/introduction/) to replicate the account's hosting environment on the Source to the Destination. We make use of rsync, ssh and other magic commands to put data in place rebuilding the website/account on the Destination server.

**This is a Work in Progress.** Still, can probably help you and save lots of time on migrations from cPanel® to Cloud Containers.

# Known issues, limitations and requirements

- The tool has been designed to run on the cPanel® (Source) server
- Root SSH access to the Source hosting server is required
- Designed to migrate PHP based applications only
- MySQL secrets cannot be retrieved from the Source server so you must reconfigure your website database credentials to get it working on the Destination
- There's no metadata to correlate databases and domains on the Source server but you can interact with the tool to selectively copy data over
- SiteHost API key with access to Cloud, Job and Server modules is required. SiteHost support can provide you with one

You may need to install a few extra packages on the Source server:

```
yum install jq oniguruma rsync curl sshpass
```

# Usage

Copy the `cpanel-to-cc.sh` script to the Source server. You can make it executable and run or invoke bash:

```
chmod u+x cpanel-to-cc.sh
./cpanel-to-cc.sh --help
```

```
bash cpanel-to-cc.sh --help
```

Check the `help` instructions to learn about the valid arguments, options and examples. 

# Disclaimer

Copyright (C) 2021-present Andre Campos Rodovalho.

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program. If not, see <https://www.gnu.org/licenses/>.

**cPanel® is a trademark of cPanel, Inc.**
**SiteHost Limited is a legal entity name owned by SiteTech Solutions Limited**

All trademarks, logos and brand names are the property of their respective owners. All company, product and service names used in this software are for identification purposes only. Use of these names, trademarks and brands does not imply endorsement.

