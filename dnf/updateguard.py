# updateguard dnf plugin (dnf 4: RHEL, Rocky, Alma 8-10, CentOS Stream, Fedora 40 and older).
# Copyright (c) 2026 Zach Schneider. SPDX-License-Identifier: MIT
#
# pre_transaction runs after the test transaction, before rpm touches anything; raising
# dnf.exceptions.Error there aborts dnf. transaction runs after rpm and its scriptlets
# (kernel-install, dracut, DKMS) have finished, and never fails the dnf run.
# Must stay Python 3.6 compatible: RHEL 8's dnf runs on platform-python 3.6.
import os
import subprocess

import dnf
import dnf.exceptions

BIN = '/usr/bin/updateguard'   # install.sh rewrites this together with the binary's path


class UpdateGuard(dnf.Plugin):
    name = 'updateguard'

    def _active(self):
        conf = self.base.conf
        if conf.installroot not in ('', '/'):   # image builds and chroots aren't this machine
            return False
        if 'test' in (conf.tsflags or []):
            return False
        # a leftover plugin pointing at a removed binary must not break dnf
        return os.access(BIN, os.X_OK)

    def _names(self):
        t = self.base.transaction
        if t is None:
            return []
        return sorted({p.name for p in list(t.install_set) + list(t.remove_set)})

    def _run(self, hook, names):
        try:
            return subprocess.run([BIN, hook], input='\n'.join(names) + '\n',
                                  universal_newlines=True).returncode
        except OSError:
            return 0

    def pre_transaction(self):
        if not self._active():
            return
        names = self._names()
        if names and self._run('hook-pre', names) == 1:
            raise dnf.exceptions.Error('updateguard stopped the transaction (see the messages above)')

    def transaction(self):
        if self._active():
            self._run('hook-post', self._names())
