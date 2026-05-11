# infrastructure

## Hosts

### pbs1.thefutureisprivate.dev
Proxmox Backup Server for infrastructure backups.

Runs on Scaleway as an `STARDUST1-S` instance in the Amsterdam location. 
Proxmox Backup Server is installed on top of Scaleway's default Debian 13 `trixie` image with the server package only. 
The Datastore is Scaleway's Object Storage in the same location.
