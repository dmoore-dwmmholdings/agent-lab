# Windows stub for the Lume path.
#
# Lume drives a real macOS guest through Apple's Virtualization framework. That
# framework ships only with macOS on Apple Silicon, and Apple's licence does not
# permit macOS guests on non-Apple hardware, so there is nothing to port here.
# Keep the command installed anyway, so that a Windows user who follows the
# macOS instructions gets an explanation instead of "command not found".

Set-StrictMode -Version Latest

Write-Host @'
lume-lab is macOS-only.

It boots a real macOS guest with Apple's Virtualization framework, which exists
only on Apple Silicon Macs.

The Windows equivalent for GUI work is the Docker desktop path, which gives an
agent an X11 display, a window manager, and Framewatch's linux-x11 backend:

  codex-lab gui C:\path\to\project
  claude-lab gui C:\path\to\project

Then open http://localhost:6080/vnc.html in your browser.

To capture a native Windows application window instead, run Framewatch directly
on the Windows host; it is a host tool and does not need the lab.
'@

exit 69
