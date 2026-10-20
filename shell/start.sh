#!/bin/sh
# Run by cage as its one client. Rotates the output first: the glass is 800x1280
# portrait and the page is 1280x800 landscape. Rotating in the compositor turns
# touch with the picture (wlroots maps the touchscreen onto the output), so the
# two can't drift apart -- the reason to rotate here and nowhere else.
# FRAME_ROTATE is a wlr-randr transform; 90 vs 270 depends on how the frame
# hangs, and is the one value to flip if the page comes up upside down.
wlr-randr --output "${FRAME_OUTPUT:-DSI-1}" --transform "${FRAME_ROTATE:-90}" ||
  echo "frame-shell: rotation failed, page will be sideways" >&2
# JavaScriptCore without its JIT. On this armv7 build the JIT died minutes into
# the live page ("JSC::CachedRecovery ... Assertion '__n < this->size()'
# failed" in the call-frame shuffler) and took the web process with it. The
# interpreter is slower but this page is light; frame-shell.py also reloads
# the page if the web process dies anyway.
export JSC_useJIT=false
exec python3 /usr/lib/frame-shell/frame-shell.py
