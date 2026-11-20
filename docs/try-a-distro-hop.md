# Try your own distro hop first

[← Back to the README](../README.md)

Before wiping anything, you can check how your system would land on another distribution, in a VM, **without copying your files**. A *trial backup* (`--no-home`) contains only package lists, repositories, `/etc`, `/opt`, `/usr/local`, snap/flatpak lists and the KDE look & feel: no home, no SSH/GPG keys, no wallet. It is usually a few MB.

1. **Make a trial backup of your current system** (can be saved in your home, the folder is created if missing):

   ```bash
   bash migrate.sh save ~/distro-trial --no-home
   ```

2. **Start a VM of the distribution you want to try** (`fedora`, `debian`, `ubuntu`, `arch`):

   ```bash
   tests/vm/vm.sh create try ubuntu
   tests/vm/vm.sh start try            # optional: --gui --mem 6144 to see a desktop
   tests/vm/vm.sh wait try
   ```

3. **Copy the trial backup into the VM and restore it**:

   ```bash
   tests/vm/vm.sh push try ~/distro-trial/system-backup-* backup
   tests/vm/vm.sh ssh try bash backup/migrate.sh restore backup
   ```

4. **Read the summary at the end**: packages not available on the new distribution, repositories to add by hand, services that could not be re-enabled. The full log is `~/restore-*.log` inside the VM.

5. **Throw it away**: `tests/vm/vm.sh destroy try`

Optional steps, only if you want to go further:
- *(optional)* install your desktop in the VM before step 3 (e.g. `sudo apt install kubuntu-desktop`) and start it with `--gui`, to see the look & feel restored;
- *(optional)* compare package lists without a VM: `pkgs/packages-explicit.txt` in the trial backup is what will be asked for on the new system;
- *(optional)* copy a few single files to check them in the VM, e.g. `tests/vm/vm.sh push try ~/.config/<app> .config/<app>`; your real files are never needed for the trial;
- *(optional)* pull the log back to the host: `tests/vm/vm.sh pull try 'restore-*.log' .`

The VM's user is `tester`, not yours, and the restore will rename the VM's hostname to yours: both are expected in a trial.

