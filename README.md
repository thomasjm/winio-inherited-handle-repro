# WinIO: a file handle passed to a child process crashes the parent

Under the native Windows I/O manager (`--io-manager=native`), a Haskell program that passes a
file opened with `openFile`/`openTempFile` to a child process (`std_out = UseHandle h`) crashes
as soon as the child does overlapped I/O on that handle:

```
Access violation in generated code when writing 0x500000000020
```

Reproduced with stock GHC 9.12.4 (ghcup) on Windows 11, `process` as shipped with GHC.

## Run it

From PowerShell, in this directory:

```
.\build.ps1
.\repro.exe                               # crashes
.\repro.exe +RTS --io-manager=posix -RTS  # fine
.\repro.exe workaround                    # fine
```

`repro.exe` runs as the parent, then re-runs itself as the child.

## What happens

1. Under WinIO, `openTempFile` opens the file with `FILE_FLAG_OVERLAPPED` and associates it with
   the RTS's I/O completion port (`Mgr.associateHandle'` in `GHC.Internal.IO.Windows.Handle.openFile'`).
2. The parent passes it to a child as `UseHandle`. `process` duplicates it as inheritable, and the
   child gets a handle to the *same file object*. Completion-port association lives on the file
   object, so the child's handle is associated with the parent's port.
3. The child writes to its stdout with an `OVERLAPPED` in its own address space. Windows queues
   the completion to the parent's port, carrying the child's `lpOverlapped` pointer.
4. The parent's I/O manager treats every packet as one of its own requests. `processCompletion`
   does `I.exchangePtr ptr_lpol nullReq` with `ptr_lpol = lpOverlapped + cdOffset`, writing through
   the child's pointer in the parent's address space.

The child here places its `OVERLAPPED` at `0x500000000000` so that address is unmapped in the
parent and the crash is deterministic: the faulting write is `0x500000000000 + 0x20`. With an
ordinary stack or heap address in the child, the same write either faults at a random-looking
address or silently corrupts whatever the parent has mapped there.

The child is a stand-in for any program that does overlapped I/O on an inherited handle. The case
where we hit this was a server passing a log file to `wsl.exe` as its stdout: `wsl.exe` relays
the Linux process's output with overlapped writes, and the server died on the first line written.
In that case `createProcess` had already closed the parent's copy of the handle, so the packet's
completion key named a handle that no longer existed in the parent.

## Expected output

```
=== repro.exe ===
parent: passing .\repro-<uuid>.log to the child as its stdout
child: writing to stdout with an OVERLAPPED at 0x500000000000
child: wrote 21 bytes
Access violation in generated code when writing 0x500000000020
 Attempting to reconstruct a stack trace...
=== repro.exe +RTS --io-manager=posix -RTS ===
...
parent: still alive, no crash
=== repro.exe workaround ===
...
parent: still alive, no crash
```

(The child's last line and the crash message print concurrently and may interleave.)

## Workaround

Give the child a file that was never associated with the port: open it with `CreateFileW` without
`FILE_FLAG_OVERLAPPED` and wrap it with `mkHandleFromHANDLE` (see `openUnassociated`). Alternatively,
`ReOpenFile` on the handle creates a new, unassociated file object, at the cost of the child no
longer sharing the parent's file position.

## Possible fixes

- `process` could hand the child a `ReOpenFile`'d, non-overlapped copy of any `UseHandle` file
  under WinIO, rather than a duplicate of an associated handle.
- The I/O manager could ignore packets whose completion key isn't a handle it currently has
  associated, though that alone can't help while the parent still holds the handle.
