# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [1.0.0] — 2026-10-28

### Added
- `extract-ipa.sh` — extract an installed app from a jailbroken iOS device
  over SSH and package it as a `.ipa`
- App discovery via binary `Info.plist` parsing (name, bundle ID, version)
- Single resumable download stream and parallel multi-stream download modes
- MD5 checksum verification of the transferred archive
- Config file support (`extract-ipa.conf`) with env var and CLI flag overrides
- `extract-ipa.conf.example` template
