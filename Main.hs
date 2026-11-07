{-# LANGUAGE LambdaCase #-}

module Main (main) where

import Control.Concurrent (threadDelay)
import Foreign
import Foreign.C
import GHC.IO.Device (IODeviceType(RegularFile))
import GHC.IO.Handle.Windows (mkHandleFromHANDLE)
import GHC.IO.Windows.Handle (Io, NativeHandle, fromHANDLE)
import Numeric (showHex)
import System.Environment
import System.IO
import System.Process


type HANDLE = Ptr ()

foreign import ccall unsafe "windows.h GetStdHandle" c_GetStdHandle :: Word32 -> IO HANDLE
foreign import ccall unsafe "windows.h WriteFile" c_WriteFile :: HANDLE -> Ptr Word8 -> Word32 -> Ptr Word32 -> Ptr () -> IO CInt
foreign import ccall safe "windows.h GetOverlappedResult" c_GetOverlappedResult :: HANDLE -> Ptr () -> Ptr Word32 -> CInt -> IO CInt
foreign import ccall unsafe "windows.h VirtualAlloc" c_VirtualAlloc :: Ptr () -> CSize -> Word32 -> Word32 -> IO (Ptr ())
foreign import ccall unsafe "windows.h CreateFileW" c_CreateFileW :: CWString -> Word32 -> Word32 -> Ptr () -> Word32 -> Word32 -> HANDLE -> IO HANDLE

main :: IO ()
main = getArgs >>= \case
  ["child"] -> child
  ["workaround"] -> parent openUnassociated
  _ -> parent (openTempFile "." "repro.log")

-- Under the native I/O manager, openTempFile opens the file with FILE_FLAG_OVERLAPPED and
-- associates it with the RTS's I/O completion port. That association belongs to the file
-- object, so it is shared by every handle to it, including the child's inherited copy.
parent :: IO (FilePath, Handle) -> IO ()
parent open = do
  (path, h) <- open
  exe <- getExecutablePath
  hPutStrLn stderr ("parent: passing " ++ path ++ " to the child as its stdout")
  (_, _, _, ph) <- createProcess (proc exe ["child"]) { std_out = UseHandle h }
  ec <- waitForProcess ph
  hPutStrLn stderr ("parent: child exited with " ++ show ec)
  threadDelay 2000000
  hPutStrLn stderr "parent: still alive, no crash"

-- A file opened without FILE_FLAG_OVERLAPPED and never associated with the port, so the
-- child's I/O on it completes without queueing anything to the parent.
openUnassociated :: IO (FilePath, Handle)
openUnassociated = do
  let path = ".\\repro-workaround.log"
  hwnd <- withCWString path $ \p -> c_CreateFileW p 0x40000000 0x3 nullPtr 2 0x80 nullPtr
  h <- mkHandleFromHANDLE (fromHANDLE hwnd :: Io NativeHandle) RegularFile path WriteMode Nothing
  pure (path, h)

-- Any program that does overlapped I/O on an inherited handle behaves like this; the
-- real-world case was wsl.exe relaying its stdout. The OVERLAPPED goes at a fixed high
-- address so it is unmapped in the parent and the parent's crash is deterministic.
child :: IO ()
child = do
  out <- c_GetStdHandle 0xFFFFFFF5
  ov <- c_VirtualAlloc (wordPtrToPtr 0x500000000000) 4096 0x3000 0x04 >>= \case
    p | p == nullPtr -> mallocBytes 4096
      | otherwise -> pure p
  fillBytes ov 0 32
  let msg = map (fromIntegral . fromEnum) "hello from the child\n" :: [Word8]
  hPutStrLn stderr ("child: writing to stdout with an OVERLAPPED at 0x" ++ showHex (ptrToWordPtr ov) "")
  withArrayLen msg $ \len buf -> alloca $ \written -> do
    _ <- c_WriteFile out buf (fromIntegral len) nullPtr ov
    _ <- c_GetOverlappedResult out ov written 1
    n <- peek written
    hPutStrLn stderr ("child: wrote " ++ show n ++ " bytes")
