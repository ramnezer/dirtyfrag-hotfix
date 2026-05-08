# dirtyfrag-hotfix

Temporary defensive mitigation helper for DirtyFrag-style Linux local privilege escalation.

This tool blocks the currently known DirtyFrag attack surface by preventing these kernel modules from loading:

- esp4
- esp6
- rxrpc

It also provides validation commands to verify that the target modules are not loaded and cannot be loaded through direct modprobe or known alias/autoload paths.

## Important warning

This is not a kernel patch.

The proper fix is an official patched vendor kernel or livepatch, followed by the required reboot if applicable.

Use this only as a temporary mitigation while waiting for vendor updates.

## Compatibility warning

Blocking these modules may break systems that rely on:

- IPsec ESP
- strongSwan
- Libreswan
- kernel IPsec data path
- AFS / kAFS / RxRPC workloads

Do not blindly apply this mitigation to production systems that terminate or transit IPsec tunnels.

## What this tool does

The apply command creates:

    /etc/modprobe.d/dirtyfrag.conf

With rules equivalent to:

    install esp4 /bin/false
    blacklist esp4

    install esp6 /bin/false
    blacklist esp6

    install rxrpc /bin/false
    blacklist rxrpc

The tool also tries to unload target modules if they are already loaded and rebuilds initramfs when update-initramfs or dracut is available.

## Commands

Make the script executable:     
    chmod +x dirtyfrag-hotfix.sh
     
Apply mitigation:

    sudo ./dirtyfrag-hotfix.sh apply

Check status:

    ./dirtyfrag-hotfix.sh status

Run safe check:

    ./dirtyfrag-hotfix.sh check

Run runtime load probe:

    sudo ./dirtyfrag-hotfix.sh probe-load

Drop page cache if exploitation is suspected before mitigation:

    sudo ./dirtyfrag-hotfix.sh drop-caches

Undo after installing a patched kernel:

    sudo ./dirtyfrag-hotfix.sh undo
    sudo reboot

## Expected successful check

    RESULT: protected-by-mitigation

## Expected successful runtime probe

    RESULT: runtime-load-probe-passed

## PoC validation summary

On the tested system:

- Without mitigation: the public DirtyFrag PoC obtained a root shell.
- With mitigation: the same PoC failed with dirtyfrag: failed (rc=1) and did not obtain root.

## Tested environment

Initial validation was performed on:

- Linux Mint 22.3
- Ubuntu 24.04 base
- Kernel 6.17.0-20-generic


## Scope

This repository does not include exploit code.

It provides a temporary defensive mitigation helper and validation checks.

## Disclaimer

This project is provided for defensive and educational purposes.

Use it at your own risk. The author is not responsible for damage, downtime, data loss, broken networking, broken VPN/IPsec/AFS workloads, or any other issue caused by applying or removing this mitigation.

This tool is a temporary workaround only. It does not replace official kernel security updates from your Linux distribution or vendor.

Always test in a non-production environment before applying it to important systems.
