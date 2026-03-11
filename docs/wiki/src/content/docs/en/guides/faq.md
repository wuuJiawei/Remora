---
title: FAQ & Troubleshooting
description: Frequently asked questions and common issues.
---


## Frequently Asked Questions

### General

**Q: Is Remora free?**
A: Yes, Remora is open source and free to use under the MIT license.

**Q: What macOS versions are supported?**
A: Remora requires macOS 14.0 (Sonoma) or later.

**Q: Can I use Remora for commercial purposes?**
A: Yes, the MIT license allows commercial use.

### SSH

**Q: Does Remora support SSH keys?**
A: Yes, Remora supports RSA, Ed25519, and ECDSA keys. Place your keys in `~/.ssh/`.

**Q: Can I use SSH agent forwarding?**
A: Yes, enable SSH agent forwarding in host settings.

**Q: Why can't I connect to my server?**
A: Check:
- Server address and port are correct
- Username is correct
- Firewall allows SSH connections
- Server's SSH daemon is running

### SFTP

**Q: Can I resume interrupted transfers?**
A: Yes, SFTP resume is supported for compatible servers.

**Q: Does drag and drop work?**
A: Yes, drag files from Finder to upload, drag to Finder to download.

### Terminal

**Q: Why doesn't my terminal render correctly?**
A: Ensure your terminal emulator sends correct escape sequences. Most modern tools are supported.

**Q: Can I use my vim/emacs configuration?**
A: Yes, Remora's terminal is compatible with vim, neovim, emacs, and other terminal applications.

## Troubleshooting

### Connection Issues

**Problem: "Connection refused"**
- Verify the server is running
- Check the port (default is 22)
- Ensure firewall allows connections

**Problem: "Connection timeout"**
- Check network connectivity
- Increase connection timeout in settings
- Verify server is reachable with `ping`

**Problem: "Authentication failed"**
- Verify username and password
- Check SSH key is correctly configured
- Ensure key permissions are correct (600 for private key)

### Display Issues

**Problem: Terminal colors look wrong**
- Check $TERM environment variable
- Set to `xterm-256color` for 256 colors

**Problem: Characters display incorrectly**
- Ensure UTF-8 encoding is set
- Check locale settings

### Performance Issues

**Problem: Terminal is slow**
- Reduce scrollback buffer size
- Disable unnecessary features in your shell (e.g., git prompt)

**Problem: High CPU usage**
- Check for runaway processes in the session
- Reduce terminal refresh rate if needed

## Getting Help

If you encounter issues not covered here:

1. Check [GitHub Issues](https://github.com/wuuJiawei/Remora/issues)
2. Search for similar issues
3. Open a new issue with details about your problem
