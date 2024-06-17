// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @dev Vendored CBOR reading utils. Copied from
 * [witnet-solidity-bridge](https://github.com/witnet/witnet-solidity-bridge/).
 */
library CborReader {
    using WitnetBuffer for WitnetBuffer.Buffer;
    using CborReader for CborReader.CBOR;

    /// Data struct following the RFC-7049 standard: Concise Binary Object Representation.
    struct CBOR {
        WitnetBuffer.Buffer buffer;
        uint8 initialByte;
        uint8 majorType;
        uint8 additionalInformation;
        uint64 len;
        uint64 tag;
    }

    uint8 internal constant MAJOR_TYPE_INT = 0;
    uint8 internal constant MAJOR_TYPE_NEGATIVE_INT = 1;
    uint8 internal constant MAJOR_TYPE_BYTES = 2;
    uint8 internal constant MAJOR_TYPE_STRING = 3;
    uint8 internal constant MAJOR_TYPE_ARRAY = 4;
    uint8 internal constant MAJOR_TYPE_MAP = 5;
    uint8 internal constant MAJOR_TYPE_TAG = 6;
    uint8 internal constant MAJOR_TYPE_CONTENT_FREE = 7;

    uint32 internal constant UINT32_MAX = type(uint32).max;
    uint64 internal constant UINT64_MAX = type(uint64).max;

    error EmptyArray();
    error InvalidLengthEncoding(uint256 length);
    error UnexpectedMajorType(uint256 read, uint256 expected);
    error UnsupportedPrimitive(uint256 primitive);
    error UnsupportedMajorType(uint256 unexpected);

    modifier isMajorType(CborReader.CBOR memory cbor, uint8 expected) {
        if (cbor.majorType != expected) {
            revert UnexpectedMajorType(cbor.majorType, expected);
        }
        _;
    }

    modifier notEmpty(WitnetBuffer.Buffer memory buffer) {
        if (buffer.data.length == 0) {
            revert WitnetBuffer.EmptyBuffer();
        }
        _;
    }

    function eof(CBOR memory cbor) internal pure returns (bool) {
        return cbor.buffer.cursor >= cbor.buffer.data.length;
    }

    /// @notice Decode a CBOR structure from raw bytes.
    /// @dev This is the main factory for CBOR instances, which can be later decoded into native EVM
    /// types.
    /// @param bytecode Raw bytes representing a CBOR-encoded value.
    /// @return A `CBOR` instance containing a partially decoded value.
    function fromBytes(bytes memory bytecode) internal pure returns (CBOR memory) {
        WitnetBuffer.Buffer memory buffer = WitnetBuffer.Buffer(bytecode, 0);
        return fromBuffer(buffer);
    }

    /// @notice Decode a CBOR structure from raw bytes.
    /// @dev This is an alternate factory for CBOR instances, which can be later decoded into native
    /// EVM types.
    /// @param buffer A Buffer structure representing a CBOR-encoded value.
    /// @return A `CBOR` instance containing a partially decoded value.
    function fromBuffer(WitnetBuffer.Buffer memory buffer)
        internal
        pure
        notEmpty(buffer)
        returns (CBOR memory)
    {
        uint8 initialByte;
        uint8 majorType = 255;
        uint8 additionalInformation;
        uint64 tag = UINT64_MAX;
        uint256 len;
        bool isTagged = true;
        while (isTagged) {
            // Extract basic CBOR properties from input bytes
            initialByte = buffer.readUint8();
            len++;
            majorType = initialByte >> 5;
            additionalInformation = initialByte & 0x1f;
            // Early CBOR tag parsing.
            if (majorType == MAJOR_TYPE_TAG) {
                uint256 _cursor = buffer.cursor;
                tag = readLength(buffer, additionalInformation);
                len += buffer.cursor - _cursor;
            } else {
                isTagged = false;
            }
        }
        if (majorType > MAJOR_TYPE_CONTENT_FREE) {
            revert UnsupportedMajorType(majorType);
        }
        return CBOR(buffer, initialByte, majorType, additionalInformation, uint64(len), tag);
    }

    function fork(CborReader.CBOR memory self) internal pure returns (CborReader.CBOR memory) {
        return CBOR({
            buffer: self.buffer.fork(),
            initialByte: self.initialByte,
            majorType: self.majorType,
            additionalInformation: self.additionalInformation,
            len: self.len,
            tag: self.tag
        });
    }

    function settle(CBOR memory self) internal pure returns (CborReader.CBOR memory) {
        if (!self.eof()) {
            return fromBuffer(self.buffer);
        } else {
            return self;
        }
    }

    function skip(CBOR memory self) internal pure returns (CborReader.CBOR memory) {
        if (
            self.majorType == MAJOR_TYPE_INT || self.majorType == MAJOR_TYPE_NEGATIVE_INT
                || (
                    self.majorType == MAJOR_TYPE_CONTENT_FREE && self.additionalInformation >= 25
                        && self.additionalInformation <= 27
                )
        ) {
            self.buffer.cursor += self.peekLength();
        } else if (self.majorType == MAJOR_TYPE_STRING || self.majorType == MAJOR_TYPE_BYTES) {
            uint64 len = readLength(self.buffer, self.additionalInformation);
            self.buffer.cursor += len;
        } else if (self.majorType == MAJOR_TYPE_ARRAY || self.majorType == MAJOR_TYPE_MAP) {
            self.len = readLength(self.buffer, self.additionalInformation);
        } else if (
            self.majorType != MAJOR_TYPE_CONTENT_FREE
                || (self.additionalInformation != 20 && self.additionalInformation != 21)
        ) {
            revert("CborReader.skip: unsupported major type");
        }
        return self;
    }

    function peekLength(CBOR memory self) internal pure returns (uint64) {
        if (self.additionalInformation < 24) {
            return 0;
        } else if (self.additionalInformation < 28) {
            return uint64(1 << (self.additionalInformation - 24));
        } else {
            revert InvalidLengthEncoding(self.additionalInformation);
        }
    }

    function readArray(CBOR memory self)
        internal
        pure
        isMajorType(self, MAJOR_TYPE_ARRAY)
        returns (CBOR[] memory items)
    {
        // read array's length and move self cursor forward to the first array element:
        uint64 len = readLength(self.buffer, self.additionalInformation);
        items = new CBOR[](len + 1);
        for (uint256 ix = 0; ix < len; ix++) {
            // settle next element in the array:
            self = self.settle();
            // fork it and added to the list of items to be returned:
            items[ix] = self.fork();
            if (self.majorType == MAJOR_TYPE_ARRAY) {
                CBOR[] memory _subitems = self.readArray();
                // move forward to the first element after inner array:
                self = _subitems[_subitems.length - 1];
            } else if (self.majorType == MAJOR_TYPE_MAP) {
                CBOR[] memory _subitems = self.readMap();
                // move forward to the first element after inner map:
                self = _subitems[_subitems.length - 1];
            } else {
                // move forward to the next element:
                self.skip();
            }
        }
        // return self cursor as extra item at the end of the list,
        // as to optimize recursion when jumping over nested arrays:
        items[len] = self;
    }

    function readMap(CBOR memory self)
        internal
        pure
        isMajorType(self, MAJOR_TYPE_MAP)
        returns (CBOR[] memory items)
    {
        // read number of items within the map and move self cursor forward to the first inner
        // element:
        uint64 len = readLength(self.buffer, self.additionalInformation) * 2;
        items = new CBOR[](len + 1);
        for (uint256 ix = 0; ix < len; ix++) {
            // settle next element in the array:
            self = self.settle();
            // fork it and added to the list of items to be returned:
            items[ix] = self.fork();
            if (ix % 2 == 0 && self.majorType != MAJOR_TYPE_STRING) {
                revert UnexpectedMajorType(self.majorType, MAJOR_TYPE_STRING);
            } else if (self.majorType == MAJOR_TYPE_ARRAY || self.majorType == MAJOR_TYPE_MAP) {
                CBOR[] memory _subitems =
                    (self.majorType == MAJOR_TYPE_ARRAY ? self.readArray() : self.readMap());
                // move forward to the first element after inner array or map:
                self = _subitems[_subitems.length - 1];
            } else {
                // move forward to the next element:
                self.skip();
            }
        }
        // return self cursor as extra item at the end of the list,
        // as to optimize recursion when jumping over nested arrays:
        items[len] = self;
    }

    /// Reads the length of the settle CBOR item from a buffer, consuming a different number of
    /// bytes depending on the
    /// value of the `additionalInformation` argument.
    function readLength(
        WitnetBuffer.Buffer memory buffer,
        uint8 additionalInformation
    )
        internal
        pure
        returns (uint64)
    {
        if (additionalInformation < 24) {
            return additionalInformation;
        }
        if (additionalInformation == 24) {
            return buffer.readUint8();
        }
        if (additionalInformation == 25) {
            return buffer.readUint16();
        }
        if (additionalInformation == 26) {
            return buffer.readUint32();
        }
        if (additionalInformation == 27) {
            return buffer.readUint64();
        }
        if (additionalInformation == 31) {
            return UINT64_MAX;
        }
        revert InvalidLengthEncoding(additionalInformation);
    }

    /// @notice Read a `CBOR` structure into a native `bool` value.
    /// @param cbor An instance of `CBOR`.
    /// @return The value represented by the input, as a `bool` value.
    function readBool(CBOR memory cbor)
        internal
        pure
        isMajorType(cbor, MAJOR_TYPE_CONTENT_FREE)
        returns (bool)
    {
        if (cbor.additionalInformation == 20) {
            return false;
        } else if (cbor.additionalInformation == 21) {
            return true;
        } else {
            revert UnsupportedPrimitive(cbor.additionalInformation);
        }
    }

    /// @notice Decode a `CBOR` structure into a native `bytes` value.
    /// @param cbor An instance of `CBOR`.
    /// @return output The value represented by the input, as a `bytes` value.
    function readBytes(CBOR memory cbor)
        internal
        pure
        isMajorType(cbor, MAJOR_TYPE_BYTES)
        returns (bytes memory output)
    {
        cbor.len = readLength(cbor.buffer, cbor.additionalInformation);
        if (cbor.len == UINT32_MAX) {
            // These checks look repetitive but the equivalent loop would be more expensive.
            uint32 length = uint32(_readIndefiniteStringLength(cbor.buffer, cbor.majorType));
            if (length < UINT32_MAX) {
                output = abi.encodePacked(cbor.buffer.read(length));
                length = uint32(_readIndefiniteStringLength(cbor.buffer, cbor.majorType));
                if (length < UINT32_MAX) {
                    output = abi.encodePacked(output, cbor.buffer.read(length));
                }
            }
        } else {
            return cbor.buffer.read(uint32(cbor.len));
        }
    }

    /// @notice Decode a `CBOR` structure into a `fixed16` value.
    /// @dev Due to the lack of support for floating or fixed point arithmetic in the EVM, this
    /// method offsets all values
    /// by 5 decimal orders so as to get a fixed precision of 5 decimal positions, which should be
    /// OK for most `fixed16`
    /// use cases. In other words, the output of this method is 10,000 times the actual value,
    /// encoded into an `int32`.
    /// @param cbor An instance of `CBOR`.
    /// @return The value represented by the input, as an `int128` value.
    function readFloat16(CBOR memory cbor)
        internal
        pure
        isMajorType(cbor, MAJOR_TYPE_CONTENT_FREE)
        returns (int32)
    {
        if (cbor.additionalInformation == 25) {
            return cbor.buffer.readFloat16();
        } else {
            revert UnsupportedPrimitive(cbor.additionalInformation);
        }
    }

    /// @notice Decode a `CBOR` structure into a `fixed32` value.
    /// @dev Due to the lack of support for floating or fixed point arithmetic in the EVM, this
    /// method offsets all values
    /// by 9 decimal orders so as to get a fixed precision of 9 decimal positions, which should be
    /// OK for most `fixed64`
    /// use cases. In other words, the output of this method is 10^9 times the actual value, encoded
    /// into an `int`.
    /// @param cbor An instance of `CBOR`.
    /// @return The value represented by the input, as an `int` value.
    function readFloat32(CBOR memory cbor)
        internal
        pure
        isMajorType(cbor, MAJOR_TYPE_CONTENT_FREE)
        returns (int256)
    {
        if (cbor.additionalInformation == 26) {
            return cbor.buffer.readFloat32();
        } else {
            revert UnsupportedPrimitive(cbor.additionalInformation);
        }
    }

    /// @notice Decode a `CBOR` structure into a `fixed64` value.
    /// @dev Due to the lack of support for floating or fixed point arithmetic in the EVM, this
    /// method offsets all values
    /// by 15 decimal orders so as to get a fixed precision of 15 decimal positions, which should be
    /// OK for most `fixed64`
    /// use cases. In other words, the output of this method is 10^15 times the actual value,
    /// encoded into an `int`.
    /// @param cbor An instance of `CBOR`.
    /// @return The value represented by the input, as an `int` value.
    function readFloat64(CBOR memory cbor)
        internal
        pure
        isMajorType(cbor, MAJOR_TYPE_CONTENT_FREE)
        returns (int256)
    {
        if (cbor.additionalInformation == 27) {
            return cbor.buffer.readFloat64();
        } else {
            revert UnsupportedPrimitive(cbor.additionalInformation);
        }
    }

    /// @notice Decode a `CBOR` structure into a native `int128[]` value whose inner values follow
    /// the same convention
    /// @notice as explained in `decodeFixed16`.
    /// @param cbor An instance of `CBOR`.
    function readFloat16Array(CBOR memory cbor)
        internal
        pure
        isMajorType(cbor, MAJOR_TYPE_ARRAY)
        returns (int32[] memory values)
    {
        uint64 length = readLength(cbor.buffer, cbor.additionalInformation);
        if (length < UINT64_MAX) {
            values = new int32[](length);
            for (uint64 i = 0; i < length;) {
                CBOR memory item = fromBuffer(cbor.buffer);
                values[i] = readFloat16(item);
                unchecked {
                    i++;
                }
            }
        } else {
            revert InvalidLengthEncoding(length);
        }
    }

    /// @notice Decode a `CBOR` structure into a native `int128` value.
    /// @param cbor An instance of `CBOR`.
    /// @return The value represented by the input, as an `int128` value.
    function readInt(CBOR memory cbor) internal pure returns (int256) {
        if (cbor.majorType == 1) {
            uint64 _value = readLength(cbor.buffer, cbor.additionalInformation);
            return int256(-1) - int256(uint256(_value));
        } else if (cbor.majorType == 0) {
            // Any `uint64` can be safely casted to `int128`, so this method supports majorType 1 as
            // well so as to have offer
            // a uniform API for positive and negative numbers
            return int256(readUint(cbor));
        } else {
            revert UnexpectedMajorType(cbor.majorType, 1);
        }
    }

    /// @notice Decode a `CBOR` structure into a native `int[]` value.
    /// @param cbor instance of `CBOR`.
    /// @return array The value represented by the input, as an `int[]` value.
    function readIntArray(CBOR memory cbor)
        internal
        pure
        isMajorType(cbor, MAJOR_TYPE_ARRAY)
        returns (int256[] memory array)
    {
        uint64 length = readLength(cbor.buffer, cbor.additionalInformation);
        if (length < UINT64_MAX) {
            array = new int256[](length);
            for (uint256 i = 0; i < length;) {
                CBOR memory item = fromBuffer(cbor.buffer);
                array[i] = readInt(item);
                unchecked {
                    i++;
                }
            }
        } else {
            revert InvalidLengthEncoding(length);
        }
    }

    /// @notice Decode a `CBOR` structure into a native `string` value.
    /// @param cbor An instance of `CBOR`.
    /// @return text The value represented by the input, as a `string` value.
    function readString(CBOR memory cbor)
        internal
        pure
        isMajorType(cbor, MAJOR_TYPE_STRING)
        returns (string memory text)
    {
        cbor.len = readLength(cbor.buffer, cbor.additionalInformation);
        if (cbor.len == UINT64_MAX) {
            bool _done;
            while (!_done) {
                uint64 length = _readIndefiniteStringLength(cbor.buffer, cbor.majorType);
                if (length < UINT64_MAX) {
                    text = string(abi.encodePacked(text, cbor.buffer.readText(length / 4)));
                } else {
                    _done = true;
                }
            }
        } else {
            return string(cbor.buffer.readText(cbor.len));
        }
    }

    /// @notice Decode a `CBOR` structure into a native `string[]` value.
    /// @param cbor An instance of `CBOR`.
    /// @return strings The value represented by the input, as an `string[]` value.
    function readStringArray(CBOR memory cbor)
        internal
        pure
        isMajorType(cbor, MAJOR_TYPE_ARRAY)
        returns (string[] memory strings)
    {
        uint256 length = readLength(cbor.buffer, cbor.additionalInformation);
        if (length < UINT64_MAX) {
            strings = new string[](length);
            for (uint256 i = 0; i < length;) {
                CBOR memory item = fromBuffer(cbor.buffer);
                strings[i] = readString(item);
                unchecked {
                    i++;
                }
            }
        } else {
            revert InvalidLengthEncoding(length);
        }
    }

    /// @notice Decode a `CBOR` structure into a native `uint64` value.
    /// @param cbor An instance of `CBOR`.
    /// @return The value represented by the input, as an `uint64` value.
    function readUint(CBOR memory cbor)
        internal
        pure
        isMajorType(cbor, MAJOR_TYPE_INT)
        returns (uint256)
    {
        return readLength(cbor.buffer, cbor.additionalInformation);
    }

    /// @notice Decode a `CBOR` structure into a native `uint64[]` value.
    /// @param cbor An instance of `CBOR`.
    /// @return values The value represented by the input, as an `uint64[]` value.
    function readUintArray(CBOR memory cbor)
        internal
        pure
        isMajorType(cbor, MAJOR_TYPE_ARRAY)
        returns (uint256[] memory values)
    {
        uint64 length = readLength(cbor.buffer, cbor.additionalInformation);
        if (length < UINT64_MAX) {
            values = new uint256[](length);
            for (uint256 ix = 0; ix < length;) {
                CBOR memory item = fromBuffer(cbor.buffer);
                values[ix] = readUint(item);
                unchecked {
                    ix++;
                }
            }
        } else {
            revert InvalidLengthEncoding(length);
        }
    }

    /// Read the length of a CBOR indifinite-length item (arrays, maps, byte strings and text) from
    /// a buffer, consuming
    /// as many bytes as specified by the first byte.
    function _readIndefiniteStringLength(
        WitnetBuffer.Buffer memory buffer,
        uint8 majorType
    )
        private
        pure
        returns (uint64 len)
    {
        uint8 initialByte = buffer.readUint8();
        if (initialByte == 0xff) {
            return UINT64_MAX;
        }
        len = readLength(buffer, initialByte & 0x1f);
        if (len >= UINT64_MAX) {
            revert InvalidLengthEncoding(len);
        } else if (majorType != (initialByte >> 5)) {
            revert UnexpectedMajorType((initialByte >> 5), majorType);
        }
    }
}

/// @title A convenient wrapper around the `bytes memory` type that exposes a buffer-like interface
/// @notice The buffer has an inner cursor that tracks the final offset of every read, i.e. any
/// subsequent read will
/// start with the byte that goes right after the last one in the previous read.
/// @dev `uint32` is used here for `cursor` because `uint16` would only enable seeking up to 8KB,
/// which could in some
/// theoretical use cases be exceeded. Conversely, `uint32` supports up to 512MB, which cannot
/// credibly be exceeded.
/// @author The Witnet Foundation.
library WitnetBuffer {
    error EmptyBuffer();
    error IndexOutOfBounds(uint256 index, uint256 range);
    error MissingArgs(uint256 expected, uint256 given);

    /// Iterable bytes buffer.
    struct Buffer {
        bytes data;
        uint256 cursor;
    }

    // Ensures we access an existing index in an array
    modifier withinRange(uint256 index, uint256 _range) {
        if (index > _range) {
            revert IndexOutOfBounds(index, _range);
        }
        _;
    }

    /// @notice Concatenate undefinite number of bytes chunks.
    /// @dev Faster than looping on `abi.encodePacked(output, _buffs[ix])`.
    function concat(bytes[] memory _buffs) internal pure returns (bytes memory output) {
        unchecked {
            uint256 destinationPointer;
            uint256 destinationLength;
            assembly {
                // get safe scratch location
                output := mload(0x40)
                // set starting destination pointer
                destinationPointer := add(output, 32)
            }
            for (uint256 ix = 1; ix <= _buffs.length; ix++) {
                uint256 source;
                uint256 sourceLength;
                uint256 sourcePointer;
                assembly {
                    // load source length pointer
                    source := mload(add(_buffs, mul(ix, 32)))
                    // load source length
                    sourceLength := mload(source)
                    // sets source memory pointer
                    sourcePointer := add(source, 32)
                }
                memcpy(destinationPointer, sourcePointer, sourceLength);
                assembly {
                    // increase total destination length
                    destinationLength := add(destinationLength, sourceLength)
                    // sets destination memory pointer
                    destinationPointer := add(destinationPointer, sourceLength)
                }
            }
            assembly {
                // protect output bytes
                mstore(output, destinationLength)
                // set final output length
                mstore(0x40, add(mload(0x40), add(destinationLength, 32)))
            }
        }
    }

    function fork(WitnetBuffer.Buffer memory buffer)
        internal
        pure
        returns (WitnetBuffer.Buffer memory)
    {
        return Buffer(buffer.data, buffer.cursor);
    }

    function mutate(
        WitnetBuffer.Buffer memory buffer,
        uint256 length,
        bytes memory pokes
    )
        internal
        pure
        withinRange(length, buffer.data.length - buffer.cursor + 1)
    {
        bytes[] memory parts = new bytes[](3);
        parts[0] = peek(buffer, 0, buffer.cursor);
        parts[1] = pokes;
        parts[2] = peek(buffer, buffer.cursor + length, buffer.data.length - buffer.cursor - length);
        buffer.data = concat(parts);
    }

    /// @notice Read and consume the next byte from the buffer.
    /// @param buffer An instance of `Buffer`.
    /// @return The next byte in the buffer counting from the cursor position.
    function next(Buffer memory buffer)
        internal
        pure
        withinRange(buffer.cursor, buffer.data.length)
        returns (bytes1)
    {
        // Return the byte at the position marked by the cursor and advance the cursor all at once
        return buffer.data[buffer.cursor++];
    }

    function peek(
        WitnetBuffer.Buffer memory buffer,
        uint256 offset,
        uint256 length
    )
        internal
        pure
        withinRange(offset + length, buffer.data.length)
        returns (bytes memory)
    {
        bytes memory data = buffer.data;
        bytes memory peeks = new bytes(length);
        uint256 destinationPointer;
        uint256 sourcePointer;
        assembly {
            destinationPointer := add(peeks, 32)
            sourcePointer := add(add(data, 32), offset)
        }
        memcpy(destinationPointer, sourcePointer, length);
        return peeks;
    }

    // @notice Extract bytes array from buffer starting from current cursor.
    /// @param buffer An instance of `Buffer`.
    /// @param length How many bytes to peek from the Buffer.
    // solium-disable-next-line security/no-assign-params
    function peek(
        WitnetBuffer.Buffer memory buffer,
        uint256 length
    )
        internal
        pure
        withinRange(length, buffer.data.length - buffer.cursor)
        returns (bytes memory)
    {
        return peek(buffer, buffer.cursor, length);
    }

    /// @notice Read and consume a certain amount of bytes from the buffer.
    /// @param buffer An instance of `Buffer`.
    /// @param length How many bytes to read and consume from the buffer.
    /// @return output A `bytes memory` containing the first `length` bytes from the buffer,
    /// counting from the cursor position.
    function read(
        Buffer memory buffer,
        uint256 length
    )
        internal
        pure
        withinRange(buffer.cursor + length, buffer.data.length)
        returns (bytes memory output)
    {
        // Create a new `bytes memory destination` value
        output = new bytes(length);
        // Early return in case that bytes length is 0
        if (length > 0) {
            bytes memory input = buffer.data;
            uint256 offset = buffer.cursor;
            // Get raw pointers for source and destination
            uint256 sourcePointer;
            uint256 destinationPointer;
            assembly {
                sourcePointer := add(add(input, 32), offset)
                destinationPointer := add(output, 32)
            }
            // Copy `length` bytes from source to destination
            memcpy(destinationPointer, sourcePointer, length);
            // Move the cursor forward by `length` bytes
            seek(buffer, length, true);
        }
    }

    /// @notice Read and consume the next 2 bytes from the buffer as an IEEE 754-2008 floating point
    /// number enclosed in an
    /// `int32`.
    /// @dev Due to the lack of support for floating or fixed point arithmetic in the EVM, this
    /// method offsets all values
    /// by 5 decimal orders so as to get a fixed precision of 5 decimal positions, which should be
    /// OK for most `float16`
    /// use cases. In other words, the integer output of this method is 10,000 times the actual
    /// value. The input bytes are
    /// expected to follow the 16-bit base-2 format (a.k.a. `binary16`) in the IEEE 754-2008
    /// standard.
    /// @param buffer An instance of `Buffer`.
    /// @return result The `int32` value of the next 4 bytes in the buffer counting from the cursor
    /// position.
    function readFloat16(Buffer memory buffer) internal pure returns (int32 result) {
        uint32 value = readUint16(buffer);
        // Get bit at position 0
        uint32 sign = value & 0x8000;
        // Get bits 1 to 5, then normalize to the [-15, 16] range so as to counterweight the IEEE
        // 754 exponent bias
        int32 exponent = (int32(value & 0x7c00) >> 10) - 15;
        // Get bits 6 to 15
        int32 fraction = int32(value & 0x03ff);
        // Add 2^10 to the fraction if exponent is not -15
        if (exponent != -15) {
            fraction |= 0x400;
        } else if (exponent == 16) {
            revert(
                string(
                    abi.encodePacked(
                        "WitnetBuffer.readFloat16: ", sign != 0 ? "negative" : hex"", " infinity"
                    )
                )
            );
        }
        // Compute `2 ^ exponent · (1 + fraction / 1024)`
        if (exponent >= 0) {
            result = int32(int256(int256(1 << uint256(int256(exponent))) * 10_000 * fraction) >> 10);
        } else {
            result = int32(
                int256(int256(fraction) * 10_000 / int256(1 << uint256(int256(-exponent)))) >> 10
            );
        }
        // Make the result negative if the sign bit is not 0
        if (sign != 0) {
            result *= -1;
        }
    }

    /// @notice Consume the next 4 bytes from the buffer as an IEEE 754-2008 floating point number
    /// enclosed into an `int`.
    /// @dev Due to the lack of support for floating or fixed point arithmetic in the EVM, this
    /// method offsets all values
    /// by 9 decimal orders so as to get a fixed precision of 9 decimal positions, which should be
    /// OK for most `float32`
    /// use cases. In other words, the integer output of this method is 10^9 times the actual value.
    /// The input bytes are
    /// expected to follow the 64-bit base-2 format (a.k.a. `binary32`) in the IEEE 754-2008
    /// standard.
    /// @param buffer An instance of `Buffer`.
    /// @return result The `int` value of the next 8 bytes in the buffer counting from the cursor
    /// position.
    function readFloat32(Buffer memory buffer) internal pure returns (int256 result) {
        uint256 value = readUint32(buffer);
        // Get bit at position 0
        uint256 sign = value & 0x80000000;
        // Get bits 1 to 8, then normalize to the [-127, 128] range so as to counterweight the IEEE
        // 754 exponent bias
        int256 exponent = (int256(value & 0x7f800000) >> 23) - 127;
        // Get bits 9 to 31
        int256 fraction = int256(value & 0x007fffff);
        // Add 2^23 to the fraction if exponent is not -127
        if (exponent != -127) {
            fraction |= 0x800000;
        } else if (exponent == 128) {
            revert(
                string(
                    abi.encodePacked(
                        "WitnetBuffer.readFloat32: ", sign != 0 ? "negative" : hex"", " infinity"
                    )
                )
            );
        }
        // Compute `2 ^ exponent · (1 + fraction / 2^23)`
        if (exponent >= 0) {
            result = (int256(1 << uint256(exponent)) * (10 ** 9) * fraction) >> 23;
        } else {
            result = (fraction * (10 ** 9) / int256(1 << uint256(-exponent))) >> 23;
        }
        // Make the result negative if the sign bit is not 0
        if (sign != 0) {
            result *= -1;
        }
    }

    /// @notice Consume the next 8 bytes from the buffer as an IEEE 754-2008 floating point number
    /// enclosed into an `int`.
    /// @dev Due to the lack of support for floating or fixed point arithmetic in the EVM, this
    /// method offsets all values
    /// by 15 decimal orders so as to get a fixed precision of 15 decimal positions, which should be
    /// OK for most `float64`
    /// use cases. In other words, the integer output of this method is 10^15 times the actual
    /// value. The input bytes are
    /// expected to follow the 64-bit base-2 format (a.k.a. `binary64`) in the IEEE 754-2008
    /// standard.
    /// @param buffer An instance of `Buffer`.
    /// @return result The `int` value of the next 8 bytes in the buffer counting from the cursor
    /// position.
    function readFloat64(Buffer memory buffer) internal pure returns (int256 result) {
        uint256 value = readUint64(buffer);
        // Get bit at position 0
        uint256 sign = value & 0x8000000000000000;
        // Get bits 1 to 12, then normalize to the [-1023, 1024] range so as to counterweight the
        // IEEE 754 exponent bias
        int256 exponent = (int256(value & 0x7ff0000000000000) >> 52) - 1023;
        // Get bits 6 to 15
        int256 fraction = int256(value & 0x000fffffffffffff);
        // Add 2^52 to the fraction if exponent is not -1023
        if (exponent != -1023) {
            fraction |= 0x10000000000000;
        } else if (exponent == 1024) {
            revert(
                string(
                    abi.encodePacked(
                        "WitnetBuffer.readFloat64: ", sign != 0 ? "negative" : hex"", " infinity"
                    )
                )
            );
        }
        // Compute `2 ^ exponent · (1 + fraction / 1024)`
        if (exponent >= 0) {
            result = (int256(1 << uint256(exponent)) * (10 ** 15) * fraction) >> 52;
        } else {
            result = (fraction * (10 ** 15) / int256(1 << uint256(-exponent))) >> 52;
        }
        // Make the result negative if the sign bit is not 0
        if (sign != 0) {
            result *= -1;
        }
    }

    // Read a text string of a given length from a buffer. Returns a `bytes memory` value for the
    // sake of genericness,
    /// but it can be easily casted into a string with `string(result)`.
    // solium-disable-next-line security/no-assign-params
    function readText(
        WitnetBuffer.Buffer memory buffer,
        uint64 length
    )
        internal
        pure
        returns (bytes memory text)
    {
        text = new bytes(length);
        unchecked {
            for (uint64 index = 0; index < length; index++) {
                uint8 char = readUint8(buffer);
                if (char & 0x80 != 0) {
                    if (char < 0xe0) {
                        char = (char & 0x1f) << 6 | (readUint8(buffer) & 0x3f);
                        length -= 1;
                    } else if (char < 0xf0) {
                        char = (char & 0x0f) << 12 | (readUint8(buffer) & 0x3f) << 6
                            | (readUint8(buffer) & 0x3f);
                        length -= 2;
                    } else {
                        char = (char & 0x0f) << 18 | (readUint8(buffer) & 0x3f) << 12
                            | (readUint8(buffer) & 0x3f) << 6 | (readUint8(buffer) & 0x3f);
                        length -= 3;
                    }
                }
                text[index] = bytes1(char);
            }
            // Adjust text to actual length:
            assembly {
                mstore(text, length)
            }
        }
    }

    /// @notice Read and consume the next byte from the buffer as an `uint8`.
    /// @param buffer An instance of `Buffer`.
    /// @return value The `uint8` value of the next byte in the buffer counting from the cursor
    /// position.
    function readUint8(Buffer memory buffer)
        internal
        pure
        withinRange(buffer.cursor, buffer.data.length)
        returns (uint8 value)
    {
        bytes memory data = buffer.data;
        uint256 offset = buffer.cursor;
        assembly {
            value := mload(add(add(data, 1), offset))
        }
        buffer.cursor++;
    }

    /// @notice Read and consume the next 2 bytes from the buffer as an `uint16`.
    /// @param buffer An instance of `Buffer`.
    /// @return value The `uint16` value of the next 2 bytes in the buffer counting from the cursor
    /// position.
    function readUint16(Buffer memory buffer)
        internal
        pure
        withinRange(buffer.cursor + 2, buffer.data.length)
        returns (uint16 value)
    {
        bytes memory data = buffer.data;
        uint256 offset = buffer.cursor;
        assembly {
            value := mload(add(add(data, 2), offset))
        }
        buffer.cursor += 2;
    }

    /// @notice Read and consume the next 4 bytes from the buffer as an `uint32`.
    /// @param buffer An instance of `Buffer`.
    /// @return value The `uint32` value of the next 4 bytes in the buffer counting from the cursor
    /// position.
    function readUint32(Buffer memory buffer)
        internal
        pure
        withinRange(buffer.cursor + 4, buffer.data.length)
        returns (uint32 value)
    {
        bytes memory data = buffer.data;
        uint256 offset = buffer.cursor;
        assembly {
            value := mload(add(add(data, 4), offset))
        }
        buffer.cursor += 4;
    }

    /// @notice Read and consume the next 8 bytes from the buffer as an `uint64`.
    /// @param buffer An instance of `Buffer`.
    /// @return value The `uint64` value of the next 8 bytes in the buffer counting from the cursor
    /// position.
    function readUint64(Buffer memory buffer)
        internal
        pure
        withinRange(buffer.cursor + 8, buffer.data.length)
        returns (uint64 value)
    {
        bytes memory data = buffer.data;
        uint256 offset = buffer.cursor;
        assembly {
            value := mload(add(add(data, 8), offset))
        }
        buffer.cursor += 8;
    }

    /// @notice Read and consume the next 16 bytes from the buffer as an `uint128`.
    /// @param buffer An instance of `Buffer`.
    /// @return value The `uint128` value of the next 16 bytes in the buffer counting from the
    /// cursor position.
    function readUint128(Buffer memory buffer)
        internal
        pure
        withinRange(buffer.cursor + 16, buffer.data.length)
        returns (uint128 value)
    {
        bytes memory data = buffer.data;
        uint256 offset = buffer.cursor;
        assembly {
            value := mload(add(add(data, 16), offset))
        }
        buffer.cursor += 16;
    }

    /// @notice Read and consume the next 32 bytes from the buffer as an `uint256`.
    /// @param buffer An instance of `Buffer`.
    /// @return value The `uint256` value of the next 32 bytes in the buffer counting from the
    /// cursor position.
    function readUint256(Buffer memory buffer)
        internal
        pure
        withinRange(buffer.cursor + 32, buffer.data.length)
        returns (uint256 value)
    {
        bytes memory data = buffer.data;
        uint256 offset = buffer.cursor;
        assembly {
            value := mload(add(add(data, 32), offset))
        }
        buffer.cursor += 32;
    }

    /// @notice Count number of required parameters for given bytes arrays
    /// @dev Wildcard format: "\#\", with # in ["0".."9"].
    /// @param input Bytes array containing strings.
    /// @param count Highest wildcard index found, plus 1.
    function argsCountOf(bytes memory input) internal pure returns (uint8 count) {
        if (input.length < 3) {
            return 0;
        }
        unchecked {
            uint256 ix = 0;
            uint256 length = input.length - 2;
            for (; ix < length;) {
                if (
                    input[ix] == bytes1("\\") && input[ix + 2] == bytes1("\\")
                        && input[ix + 1] >= bytes1("0") && input[ix + 1] <= bytes1("9")
                ) {
                    uint8 ax = uint8(uint8(input[ix + 1]) - uint8(bytes1("0")) + 1);
                    if (ax > count) {
                        count = ax;
                    }
                    ix += 3;
                } else {
                    ix++;
                }
            }
        }
    }

    /// @notice Replace bytecode indexed wildcards by correspondent substrings.
    /// @dev Wildcard format: "\#\", with # in ["0".."9"].
    /// @param input Bytes array containing strings.
    /// @param args Array of substring values for replacing indexed wildcards.
    /// @return output Resulting bytes array after replacing all wildcards.
    /// @return hits Total number of replaced wildcards.
    function replace(
        bytes memory input,
        string[] memory args
    )
        internal
        pure
        returns (bytes memory output, uint256 hits)
    {
        uint256 ix = 0;
        uint256 lix = 0;
        uint256 inputLength;
        uint256 inputPointer;
        uint256 outputLength;
        uint256 outputPointer;
        uint256 source;
        uint256 sourceLength;
        uint256 sourcePointer;

        if (input.length < 3) {
            return (input, 0);
        }

        assembly {
            // set starting input pointer
            inputPointer := add(input, 32)
            // get safe output location
            output := mload(0x40)
            // set starting output pointer
            outputPointer := add(output, 32)
        }

        unchecked {
            uint256 length = input.length - 2;
            for (; ix < length;) {
                if (
                    input[ix] == bytes1("\\") && input[ix + 2] == bytes1("\\")
                        && input[ix + 1] >= bytes1("0") && input[ix + 1] <= bytes1("9")
                ) {
                    inputLength = (ix - lix);
                    if (ix > lix) {
                        memcpy(outputPointer, inputPointer, inputLength);
                        inputPointer += inputLength + 3;
                        outputPointer += inputLength;
                    } else {
                        inputPointer += 3;
                    }
                    uint256 ax = uint256(uint8(input[ix + 1]) - uint8(bytes1("0")));
                    if (ax >= args.length) {
                        revert MissingArgs(ax + 1, args.length);
                    }
                    assembly {
                        source := mload(add(args, mul(32, add(ax, 1))))
                        sourceLength := mload(source)
                        sourcePointer := add(source, 32)
                    }
                    memcpy(outputPointer, sourcePointer, sourceLength);
                    outputLength += inputLength + sourceLength;
                    outputPointer += sourceLength;
                    ix += 3;
                    lix = ix;
                    hits++;
                } else {
                    ix++;
                }
            }
            ix = input.length;
        }
        if (outputLength > 0) {
            if (ix > lix) {
                memcpy(outputPointer, inputPointer, ix - lix);
                outputLength += (ix - lix);
            }
            assembly {
                // set final output length
                mstore(output, outputLength)
                // protect output bytes
                mstore(0x40, add(mload(0x40), add(outputLength, 32)))
            }
        } else {
            return (input, 0);
        }
    }

    /// @notice Replace string indexed wildcards by correspondent substrings.
    /// @dev Wildcard format: "\#\", with # in ["0".."9"].
    /// @param input String potentially containing wildcards.
    /// @param args Array of substring values for replacing indexed wildcards.
    /// @return output Resulting string after replacing all wildcards.
    function replace(
        string memory input,
        string[] memory args
    )
        internal
        pure
        returns (string memory)
    {
        (bytes memory _outputBytes,) = replace(bytes(input), args);
        return string(_outputBytes);
    }

    /// @notice Move the inner cursor of the buffer to a relative or absolute position.
    /// @param buffer An instance of `Buffer`.
    /// @param offset How many bytes to move the cursor forward.
    /// @param relative Whether to count `offset` from the last position of the cursor (`true`) or
    /// the beginning of the
    /// buffer (`true`).
    /// @return The final position of the cursor (will equal `offset` if `relative` is `false`).
    // solium-disable-next-line security/no-assign-params
    function seek(
        Buffer memory buffer,
        uint256 offset,
        bool relative
    )
        internal
        pure
        withinRange(offset, buffer.data.length)
        returns (uint256)
    {
        // Deal with relative offsets
        if (relative) {
            offset += buffer.cursor;
        }
        buffer.cursor = offset;
        return offset;
    }

    /// @notice Move the inner cursor a number of bytes forward.
    /// @dev This is a simple wrapper around the relative offset case of `seek()`.
    /// @param buffer An instance of `Buffer`.
    /// @param relativeOffset How many bytes to move the cursor forward.
    /// @return The final position of the cursor.
    function seek(Buffer memory buffer, uint256 relativeOffset) internal pure returns (uint256) {
        return seek(buffer, relativeOffset, true);
    }

    /// @notice Copy bytes from one memory address into another.
    /// @dev This function was borrowed from Nick Johnson's `solidity-stringutils` lib, and
    /// reproduced here under the terms
    /// of [Apache License
    /// 2.0](https://github.com/Arachnid/solidity-stringutils/blob/master/LICENSE).
    /// @param dest Address of the destination memory.
    /// @param src Address to the source memory.
    /// @param len How many bytes to copy.
    // solium-disable-next-line security/no-assign-params
    function memcpy(uint256 dest, uint256 src, uint256 len) private pure {
        unchecked {
            // Copy word-length chunks while possible
            for (; len >= 32; len -= 32) {
                assembly {
                    mstore(dest, mload(src))
                }
                dest += 32;
                src += 32;
            }
            if (len > 0) {
                // Copy remaining bytes
                uint256 _mask = 256 ** (32 - len) - 1;
                assembly {
                    let srcpart := and(mload(src), not(_mask))
                    let destpart := and(mload(dest), _mask)
                    mstore(dest, or(destpart, srcpart))
                }
            }
        }
    }
}
