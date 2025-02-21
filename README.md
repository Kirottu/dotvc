# DotVC
An automated version control software made for storing and sharing revisions of dotfiles.

# Features
- A background daemon that automatically keeps track of changes to the configured paths/files
- An interactive TUI app to search for specific revisions of dotfiles
- Ability to use an external server to sync dotfiles to different machines

# Sync
DotVC Sync is implemented so that every machine that is logged in to a specific user will get
a database of a specified name (hostname by default).

