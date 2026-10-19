# Security policy

updateguard runs as root inside pacman and apt hooks, so a bug in it can affect every package transaction on the machine. Reports are welcome.

## Supported versions

| Version | Supported |
| ------- | --------- |
| 0.2.x   | yes       |
| < 0.2   | no        |

## Reporting a vulnerability

Report privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability** (or go to <https://github.com/zkm/updateguard/security/advisories/new>). Please don't open a public issue for security problems.

Useful details:

- the updateguard version (`updateguard version`) and distro
- which hook or command is involved (`hook-pre`, `hook-post`, `check`, `install.sh`, ...)
- steps to reproduce, and what an attacker needs (local user, write access to a path, a crafted package name, ...)

You should get an acknowledgement within a week. Once a fix is released, the advisory is published with credit to the reporter unless you'd rather stay anonymous.

## Scope

In scope: the `updateguard` script, the pacman and apt hook files, `install.sh`, and the default `updateguard.conf`. The landing page in `site/` is static and out of scope unless it serves something harmful.
