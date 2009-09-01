{-# LANGUAGE Rank2Types #-}
{- | This module defines the basic libffi machinery.
    You will need this to create support for new ffi types. -}
module Foreign.LibFFI.Base where

import Control.Monad
import Control.Exception
import Foreign.Ptr
import Foreign.Storable
import Foreign.Marshal

import Foreign.LibFFI.Internal
import Foreign.LibFFI.FFITypes

newtype Arg = Arg { unArg :: forall a. (Ptr CType -> Ptr CValue -> IO a) -> IO a }

customPointerArg :: (a -> IO (Ptr b)) -> (Ptr b -> IO ()) -> a -> Arg
customPointerArg newA freeA a = Arg $ \withArg ->
    bracket (newA a) freeA $ \p ->
        with p $ \pp ->
            withArg ffi_type_pointer (castPtr pp)

mkStorableArg :: Storable a => Ptr CType -> a -> Arg
mkStorableArg cType a = Arg $ \withArg ->
    with a $ \p ->
        withArg cType (castPtr p)

newtype RetType a = RetType { unRetType :: (Ptr CType -> Ptr CValue -> IO ()) -> IO a }

instance Functor RetType where
    fmap f  = withRetType (return . f)

withRetType :: (a -> IO b) -> RetType a -> RetType b
withRetType f (RetType withPoke) = RetType $ withPoke >=> f

mkStorableRetType :: Storable a => Ptr CType -> RetType a
mkStorableRetType cType
    = RetType $ \write -> alloca $ \cValue -> write cType (castPtr cValue) >> peek cValue

newStorableStructArgRet :: Storable a => [Ptr CType] -> IO (a -> Arg, RetType a, IO ())
newStorableStructArgRet cTypes = do
    (cType, freeit) <- newStructCType cTypes
    return (mkStorableArg cType, mkStorableRetType cType, freeit)

newStructCType  :: [Ptr CType] -> IO (Ptr CType, IO ())
newStructCType cTypes = do
    ffi_type <- mallocBytes sizeOf_ffi_type
    elements <- newArray0 nullPtr cTypes
    init_ffi_type ffi_type elements
    return (ffi_type, free ffi_type >> free elements)

callFFI :: FunPtr a -> RetType b -> [Arg] -> IO b
callFFI funPtr (RetType actRet) args
    = allocaBytes sizeOf_cif $ \cif ->
        allocaArray n $ \cTypesPtr ->
            allocaArray n $ \cValuesPtr ->
                let
                    go i [] = actRet $ \cRetType cRetValue -> do
                                status <- ffi_prep_cif cif ffi_default_abi (fromIntegral n) cRetType cTypesPtr
                                unless (status == ffi_ok) $
                                    error "callFFI: ffi_prep_cif failed"
                                ffi_call cif funPtr cRetValue cValuesPtr
                    go i (Arg actArg : args) = do
                        actArg $ \cType cValue -> do
                            pokeElemOff cTypesPtr i cType
                            pokeElemOff cValuesPtr i cValue
                            go (succ i) args
                in
                    go 0 args
    where
        n = length args
