// SPDX-License-Identifier: MIT
pragma solidity >0.5.0 <0.8.0;

/* Inherited Interface Imports */
import { iOVM_SafetyChecker } from "../../iOVM/execution/iOVM_SafetyChecker.sol";

/**
 * @title OVM_SafetyChecker
 * @dev  The Safety Checker verifies that contracts deployed on L2 do not contain any
 * "unsafe" operations. An operation is considered unsafe if it would access state variables which
 * are specific to the environment (ie. L1 or L2) in which it is executed, as this could be used
 * to "escape the sandbox" of the OVM, resulting in non-deterministic fraud proofs. 
 * That is, an attacker would be able to "prove fraud" on an honestly applied transaction.
 * Note that a "safe" contract requires opcodes to appear in a particular pattern;
 * omission of "unsafe" opcodes is necessary, but not sufficient.
 *
 * Compiler used: solc
 * Runtime target: EVM
 */
contract OVM_SafetyChecker is iOVM_SafetyChecker {

    /********************
     * Public Functions *
     ********************/

    /**
     * Returns whether or not all of the provided bytecode is safe.
     * @param _bytecode The bytecode to safety check.
     * @return `true` if the bytecode is safe, `false` otherwise.
     */
    function isBytecodeSafe(
        bytes memory _bytecode
    )
        override
        external
        pure
        returns (
            bool
        )
    {
        // autogenerated by gen_safety_checker_constants.py
        // number of bytes to skip for each opcode
        uint256[8] memory opcodeSkippableBytes = [
            uint256(0x0001010101010101010101010000000001010101010101010101010101010000),
            uint256(0x0100000000000000000000000000000000000000010101010101000000010100),
            uint256(0x0000000000000000000000000000000001010101000000010101010100000000),
            uint256(0x0203040500000000000000000000000000000000000000000000000000000000),
            uint256(0x0101010101010101010101010101010101010101010101010101010101010101),
            uint256(0x0101010101000000000000000000000000000000000000000000000000000000),
            uint256(0x0000000000000000000000000000000000000000000000000000000000000000),
            uint256(0x0000000000000000000000000000000000000000000000000000000000000000)
        ];
        // Mask to gate opcode specific cases
        uint256 opcodeGateMask = ~uint256(0xffffffffffffffffffffffe000000000fffffffff070ffff9c0ffffec000f001);
        // Halting opcodes
        uint256 opcodeHaltingMask = ~uint256(0x4008000000000000000000000000000000000000004000000000000000000001);
        // PUSH opcodes
        uint256 opcodePushMask = ~uint256(0xffffffff000000000000000000000000);

        uint256 codeLength;
        uint256 _pc;
        assembly {
            _pc := add(_bytecode, 0x20)
        }
        codeLength = _pc + _bytecode.length;
        do {
            // current opcode: 0x00...0xff
            uint256 opNum;

            // inline assembly removes the extra add + bounds check
            assembly {
                let word := mload(_pc) //load the next 32 bytes at pc into word

                // Look up number of bytes to skip from opcodeSkippableBytes and then update indexInWord
                // E.g. the 02030405 in opcodeSkippableBytes is the number of bytes to skip for PUSH1->4
                // We repeat this 6 times, thus we can only skip bytes for up to PUSH4 ((1+4) * 6 = 30 < 32).
                // If we see an opcode that is listed as 0 skippable bytes e.g. PUSH5,
                // then we will get stuck on that indexInWord and then opNum will be set to the PUSH5 opcode.
                let indexInWord := byte(0, mload(add(opcodeSkippableBytes, byte(0, word))))
                indexInWord := add(indexInWord, byte(0, mload(add(opcodeSkippableBytes, byte(indexInWord, word)))))
                indexInWord := add(indexInWord, byte(0, mload(add(opcodeSkippableBytes, byte(indexInWord, word)))))
                indexInWord := add(indexInWord, byte(0, mload(add(opcodeSkippableBytes, byte(indexInWord, word)))))
                indexInWord := add(indexInWord, byte(0, mload(add(opcodeSkippableBytes, byte(indexInWord, word)))))
                indexInWord := add(indexInWord, byte(0, mload(add(opcodeSkippableBytes, byte(indexInWord, word)))))
                _pc := add(_pc, indexInWord)

                opNum := byte(indexInWord, word)
            }

            // + push opcodes
            // + stop opcodes [STOP(0x00),JUMP(0x56),RETURN(0xf3),INVALID(0xfe)]
            // + caller opcode CALLER(0x33)
            // + blacklisted opcodes
            uint256 opBit = 1 << opNum;
            if (opBit & opcodeGateMask == 0) {
                if (opBit & opcodePushMask == 0) {
                    // all pushes are valid opcodes
                    // subsequent bytes are not opcodes. Skip them.
                    _pc += (opNum - 0x5e); // PUSH1 is 0x60, so opNum-0x5f = PUSHed bytes and we +1 to
                    // skip the _pc++; line below in order to save gas ((-0x5f + 1) = -0x5e)
                    continue;
                } else if (opBit & opcodeHaltingMask == 0) {
                    // STOP or JUMP or RETURN or INVALID (Note: REVERT is blacklisted, so not included here)
                    // We are now inside unreachable code until we hit a JUMPDEST!
                    do {
                        _pc++;
                        assembly {
                            opNum := byte(0, mload(_pc))
                        }
                        // encountered a JUMPDEST
                        if (opNum == 0x5b) break;
                        // skip PUSHed bytes
                        if ((1 << opNum) & opcodePushMask == 0) _pc += (opNum - 0x5f); // opNum-0x5f = PUSHed bytes (PUSH1 is 0x60)
                    } while (_pc < codeLength);
                    // opNum is 0x5b, so we don't continue here since the pc++ is fine
                } else if (opNum == 0x33) { // Caller opcode
                    uint256 firstOps; // next 32 bytes of bytecode
                    uint256 secondOps; // following 32 bytes of bytecode

                    assembly {
                        firstOps := mload(_pc)
                        // 37 bytes total, 5 left over --> 32 - 5 bytes = 27 bytes = 216 bits
                        secondOps := shr(216, mload(add(_pc, 0x20)))
                    }

                    // Call identity precompile
                    // CALLER POP PUSH1 0x00 PUSH1 0x04 GAS CALL
                    // 32 - 8 bytes = 24 bytes = 192
                    if ((firstOps >> 192) == 0x3350600060045af1) {
                        _pc += 8;
                    // Call EM and abort execution if instructed
                    // CALLER PUSH1 0x00 SWAP1 GAS CALL PC PUSH1 0x0E ADD JUMPI RETURNDATASIZE PUSH1 0x00 DUP1 RETURNDATACOPY RETURNDATASIZE PUSH1 0x00 REVERT JUMPDEST RETURNDATASIZE PUSH1 0x01 EQ ISZERO PC PUSH1 0x0a ADD JUMPI PUSH1 0x01 PUSH1 0x00 RETURN JUMPDEST 
                    } else if (firstOps == 0x336000905af158600e01573d6000803e3d6000fd5b3d6001141558600a015760 && secondOps == 0x016000f35b) {
                        _pc += 37;
                    } else {
                        return false;
                    }
                    continue;
                } else {
                    // encountered a non-whitelisted opcode!
                    return false;
                }
            }
            _pc++;
        } while (_pc < codeLength);
        return true;
    }
}
