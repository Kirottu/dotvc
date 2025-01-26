# DotVC

# TODO

## Local:
- Configuration file and helper command for quickly adding a dotfile to the list of managed files
- sqlite database for storing file revisions
  - Database schema
- Easy to use command to quickly pull a revision of a config file and edit it
- Filesystem listener to add dotfile revisions as they are edited (inotify)
  - Constantly running daemon

## Sync:
- Web server
  - User authentication
  - Handling sqlite databases
    - Encryption
  - Options in the local client to interface with the server
