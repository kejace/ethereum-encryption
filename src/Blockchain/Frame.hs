
module Blockchain.Frame (
  EthCryptState(..),
  EthCryptM,
  getEgressMac,
  getIngressMac,
  encryptAndPutFrame,
  getAndDecryptFrame
  ) where

--import qualified Data.ByteString.Base16 as B16
--import qualified Data.ByteString.Char8 as BC
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.State
import Crypto.Cipher.AES
import qualified Crypto.Hash.SHA3 as SHA3
import Data.Bits
import qualified Data.ByteString as B
import System.IO

import qualified Blockchain.AESCTR as AES

bXor::B.ByteString->B.ByteString->B.ByteString
bXor x y | B.length x == B.length y = B.pack $ B.zipWith xor x y 
bXor x y = error $
           "bXor called with two ByteStrings of different length: length string1 = " ++
           show (B.length x) ++ ", length string2 = " ++ show (B.length y)


data EthCryptState =
  EthCryptState {
    handle::Handle,
    encryptState::AES.AESCTRState,
    decryptState::AES.AESCTRState,
    egressMAC::SHA3.Ctx,
    ingressMAC::SHA3.Ctx,
    egressKey::B.ByteString,
    ingressKey::B.ByteString
    }

type EthCryptM a = StateT EthCryptState a

putBytes::MonadIO m=>B.ByteString->EthCryptM m ()
putBytes bytes = do
  cState <- get
  liftIO $ B.hPut (handle cState) bytes

getBytes::MonadIO m=>Int->EthCryptM m B.ByteString
getBytes size = do
  cState <- get
  liftIO $ B.hGet (handle cState) size
  
encrypt::MonadIO m=>B.ByteString->EthCryptM m B.ByteString
encrypt input = do
  cState <- get
  let aesState = encryptState cState
  let (aesState', output) = AES.encrypt aesState input
  put cState{encryptState=aesState'}
  return output

decrypt::MonadIO m=>B.ByteString->EthCryptM m B.ByteString
decrypt input = do
  cState <- get
  let aesState = decryptState cState
  let (aesState', output) = AES.decrypt aesState input
  put cState{decryptState=aesState'}
  return output

getEgressMac::MonadIO m=>EthCryptM m B.ByteString
getEgressMac = do
  cState <- get
  let mac = egressMAC cState
  return $ B.take 16 $ SHA3.finalize mac

rawUpdateEgressMac::MonadIO m=>B.ByteString->EthCryptM m B.ByteString
rawUpdateEgressMac value = do
  cState <- get
  let mac = egressMAC cState
  let mac' = SHA3.update mac value
  put cState{egressMAC=mac'}
  return $ B.take 16 $ SHA3.finalize mac'

updateEgressMac::MonadIO m=>B.ByteString->EthCryptM m B.ByteString
updateEgressMac value = do
  cState <- get
  let mac = egressMAC cState
  rawUpdateEgressMac $
    value `bXor` (encryptECB (initAES $ egressKey cState) (B.take 16 $ SHA3.finalize mac))

getIngressMac::MonadIO m=>EthCryptM m B.ByteString
getIngressMac = do
  cState <- get
  let mac = ingressMAC cState
  return $ B.take 16 $ SHA3.finalize mac

rawUpdateIngressMac::MonadIO m=>B.ByteString->EthCryptM m B.ByteString
rawUpdateIngressMac value = do
  cState <- get
  let mac = ingressMAC cState
  let mac' = SHA3.update mac value
  put cState{ingressMAC=mac'}
  return $ B.take 16 $ SHA3.finalize mac'

updateIngressMac::MonadIO m=>B.ByteString->EthCryptM m B.ByteString
updateIngressMac value = do
  cState <- get
  let mac = ingressMAC cState
  rawUpdateIngressMac $
    value `bXor` (encryptECB (initAES $ ingressKey cState) (B.take 16 $ SHA3.finalize mac))

encryptAndPutFrame::MonadIO m=>B.ByteString->EthCryptM m ()
encryptAndPutFrame bytes = do
  let frameSize = B.length bytes
      frameBuffSize = (16 - frameSize `mod` 16) `mod` 16
      header =
        B.pack [fromIntegral $ frameSize `shiftR` 16,
                fromIntegral $ frameSize `shiftR` 8,
                fromIntegral $ frameSize,
                0xc2,
                0x80,
                0x80,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

  headCipher <- encrypt header
  
  headMAC <- updateEgressMac headCipher

  putBytes headCipher
  putBytes headMAC

  frameCipher <- encrypt (bytes `B.append` B.replicate frameBuffSize 0)
  frameMAC <- updateEgressMac =<< rawUpdateEgressMac frameCipher

  putBytes frameCipher
  putBytes frameMAC

getAndDecryptFrame::MonadIO m=>EthCryptM m B.ByteString
getAndDecryptFrame = do
  headCipher <- getBytes 16
  headMAC <- getBytes 16

  expectedHeadMAC <- updateIngressMac headCipher
  when (expectedHeadMAC /= headMAC) $ error "oops, head mac isn't what I expected"

  header <- decrypt headCipher

  let frameSize = 
        (fromIntegral (header `B.index` 0) `shiftL` 16) +
        (fromIntegral (header `B.index` 1) `shiftL` 8) +
        fromIntegral (header `B.index` 2)
      frameBufferSize = (16 - (frameSize `mod` 16)) `mod` 16
  
  frameCipher <- getBytes (frameSize + frameBufferSize)
  frameMAC <- getBytes 16

  expectedFrameMAC <- updateIngressMac =<< rawUpdateIngressMac frameCipher

  when (expectedFrameMAC /= frameMAC) $ error "oops, frame mac isn't what I expected"

  fullFrame <- decrypt frameCipher
  return $ B.take frameSize fullFrame
