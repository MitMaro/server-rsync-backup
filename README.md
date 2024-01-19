# Server Rsync Backup Script

[![GitHub license](https://img.shields.io/badge/license-ISC-blue.svg)](https://raw.githubusercontent.com/MitMaro/server-rsync-backup/master/LICENSE.md)

A wrapper around rsync to create backups from remote systems of any set of files on a schedule.

## Requirements

- Bash >= 5.1
- rsync >= 3.2
- ssh >= 8.9

## Install

Simply clone this repository.

```shell
git clone https://github.com/MitMaro/server-rsync-backup
```

## Update

To update, from the project directory, run:

```shell
git pull
``` 

## Usage

### Configuration Files

Most of the configuration for the script is stored in a set of configuration files.

All configuration files are contained in a single root configuration directory.

Inside this directory, the primary configuration file, called `config` contains the following options:

| name                 | default                | required | description                                                                                                      |
|----------------------|------------------------|----------|------------------------------------------------------------------------------------------------------------------|
| target               |                        | Yes      | The target directory for all backup files.                                                                       |
| ident_file           |                        | No       | The SSH private key to use for SSH connections. Default to no explict key.                                       |
| verbose              | false                  | No       | Set to true to enable verbose logging, false to disable                                                          |
| dry_run              | false                  | No       | Do not sync any files. Note some actions are still performed, like creating log directories                      |
| log_color            |                        | No       | Set to false to disable logging with colors, true to enable. Defaults to false for file logging, true for stdout |
| log_to_file          | false                  | No       | Log to a file instead of stdout                                                                                  |
| log_file_root        | /var/logs/rsync-backup | No       | The directory to store log files                                                                                 |
| log_file_date_format | +%Y-%m-%d              | No       | The date format for the log file name. Must work with `date`.                                                    |

Every directory inside the root config directory contains a backup batch, with a config file and a set of file patterns.

The config file supports the following:

| name        | default           | required | description                                                                                   |
|-------------|-------------------|----------|-----------------------------------------------------------------------------------------------|
| id          | Name of directory | No       | The unique identifier for the backup.                                                         |
| skip        | false             | No       | Ignore this set of configuration files and file patterns.                                     |
| remote_user | root              | No       | The remote user for the rsync/ssh connection                                                  |
| remote_host |                   | Yes      | The remote host/ip address                                                                    |
| ident_file  |                   | No       | The SSH private key to use for this particlar remote host. Overwrites the script level config |

Inside each batch, a directory called `files.d` contains config files that describe the files to back up. The config file contains:

| name          | Default | required | description                               |
|---------------|---------|----------|-------------------------------------------|
| path          |         | Yes      | The remote path to backup                 |
| target        |         | No       | Target path relative to root target       |
| allow_missing | false   | No       | Do not error if path is missing on remote |
| exclude       |         | No       | A pattern to pass rsync as an `--exclude` |
| include       |         | No       | A pattern to pass rsync as an `--include` |

The `include` and `exclude` configurations can be provided multiple times, are are passed to `rsync` in the order provided in the file.

The root configuration directory can also contain a `files.d` directory, in which case, these files are backed up for all batches.

#### Example Directory

```
backup.d
├── config
└── files.d
│   ├── readme
│   └── ssh-config
├── pihole
│   ├── config
│   └── files.d
│       ├── database
│       └── root
├── uptime
│   ├── config
│   └── files.d
│       └── default
└── vpn
    ├── config
    └── files.d
        ├── configuration
        └── private-keys
```

### Script Arguments

While the configuration files provide the majority of the options for the script, there are a handful of arguments that can be passed directly. These arguments take precedence over their config file counterparts. 

```
server rsync backup

Usage: backup.sh [options] <path-to-config-root>

Options:
  --verbose, -v     Show more verbose output of actions performed.

  --no-color        Disable colored output.

  --dry-run         Run rsync in dry run mode. Providing this options also assumes --verbose.

  --help            Show this usage message and exit.

```

## Use case

This script can be used to automatically back up a list of paths, generally useful in server environments. I use it to back up files from various Proxmox LXCs in my homelab.

## License

Server Rsync Backup is released under the ISC license. See [LICENSE](LICENSE).
