// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CrossChainOrderTypes} from "../CrossChainOrderTypes.sol";

/// @notice Registry of named intent templates. Each template is a semicolon-separated rule string
///         that describes how to match calldata and extract intent + proof requirements.
contract BridgeIntentTemplateRegistry is Ownable {
    error UnknownRuleKey(string key);
    error UnknownBodyType(string bodyType);
    error UnknownIntentType(string intentType);
    error UnknownProofField(string proofField);
    error TemplateNotFound(string name);
    error SelectorMismatch(bytes4 expected, bytes4 actual);
    error CalldataTooShort(uint256 length, uint256 required);

    struct ParsedTemplate {
        bytes4 selector;
        uint256 bodyOffset;
        BodyKind bodyKind;
        IntentKind intentKind;
        ProofKind proofKind;
    }

    enum BodyKind {
        None,
        CrossChainOrder,
        OpenForOrder,
        AddressUint256,
        AddressAddressUint256,
        RegisterLoan
    }

    enum IntentKind {
        None,
        CrossChainIntentFromOrderData
    }

    enum ProofKind {
        None,
        SourceProofRequirement
    }

    /// @notice Output of a successful template match.
    struct ExtractionResult {
        bool ok;
        bytes encodedBody;
        bytes encodedIntent;
        bytes32 proofRequirement;
        address addressArg;
        uint256 uintArg;
    }

    mapping(string => string) private _rules;
    mapping(string => ParsedTemplate) private _parsed;

    event TemplateSet(string indexed name, string rule);

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Registers or updates a template. The rule string is parsed once and stored.
    function setTemplate(string calldata name, string calldata rule) external onlyOwner {
        _rules[name] = rule;
        _parsed[name] = _parseRule(rule);
        emit TemplateSet(name, rule);
    }

    function getTemplate(string calldata name) external view returns (string memory) {
        return _rules[name];
    }

    function getParsedTemplate(string calldata name) external view returns (ParsedTemplate memory) {
        if (_parsed[name].bodyKind == BodyKind.None && bytes(_rules[name]).length == 0) {
            revert TemplateNotFound(name);
        }
        return _parsed[name];
    }

    /// @notice Applies a named template to calldata. Returns `ok=false` when selector/body do not match.
    function tryExtract(
        string calldata name,
        bytes calldata data
    ) external view returns (ExtractionResult memory result) {
        ParsedTemplate memory template_ = _parsed[name];
        if (template_.bodyKind == BodyKind.None && bytes(_rules[name]).length == 0) {
            revert TemplateNotFound(name);
        }
        return _extract(template_, data);
    }

    /// @notice Tries templates in order; returns the first match.
    function tryExtractFirst(
        string[] calldata names,
        bytes calldata data
    ) external view returns (string memory matchedName, ExtractionResult memory result) {
        for (uint256 i = 0; i < names.length; i++) {
            if (bytes(_rules[names[i]]).length == 0) {
                continue;
            }
            ParsedTemplate memory template_ = _parsed[names[i]];
            ExtractionResult memory candidate = _extract(template_, data);
            if (candidate.ok) {
                return (names[i], candidate);
            }
        }
        return ("", result);
    }

    function readSelector(bytes calldata data) public pure returns (bytes4 selector) {
        if (data.length < 4) {
            return bytes4(0);
        }
        selector = _readSelector(data);
    }

    function sliceCalldata(bytes calldata data, uint256 start) public pure returns (bytes memory slice) {
        if (start > data.length) {
            revert CalldataTooShort(data.length, start);
        }
        slice = new bytes(data.length - start);
        for (uint256 i = 0; i < slice.length; i++) {
            slice[i] = data[start + i];
        }
    }

    function _extract(
        ParsedTemplate memory template_,
        bytes calldata data
    ) internal view returns (ExtractionResult memory result) {
        if (data.length < template_.bodyOffset) {
            return result;
        }

        bytes4 selector = _readSelector(data);
        if (selector != template_.selector) {
            return result;
        }

        bytes memory bodyBytes = sliceCalldata(data, template_.bodyOffset);

        if (template_.bodyKind == BodyKind.CrossChainOrder) {
            CrossChainOrderTypes.CrossChainOrder memory order =
                abi.decode(bodyBytes, (CrossChainOrderTypes.CrossChainOrder));
            result.encodedBody = abi.encode(order);
            _fillIntentFields(template_, order.orderData, result);
            result.ok = true;
            return result;
        }

        if (template_.bodyKind == BodyKind.OpenForOrder) {
            (CrossChainOrderTypes.CrossChainOrder memory order, , ) = abi.decode(
                bodyBytes,
                (CrossChainOrderTypes.CrossChainOrder, bytes, bytes)
            );
            result.encodedBody = abi.encode(order);
            _fillIntentFields(template_, order.orderData, result);
            result.ok = true;
            return result;
        }

        if (template_.bodyKind == BodyKind.AddressUint256) {
            (result.addressArg, result.uintArg) = abi.decode(bodyBytes, (address, uint256));
            result.encodedBody = abi.encode(result.addressArg, result.uintArg);
            result.ok = true;
            return result;
        }

        if (template_.bodyKind == BodyKind.AddressAddressUint256) {
            address from;
            address to;
            (from, to, result.uintArg) = abi.decode(bodyBytes, (address, address, uint256));
            result.addressArg = to;
            result.encodedBody = abi.encode(from, to, result.uintArg);
            result.ok = true;
            return result;
        }

        if (template_.bodyKind == BodyKind.RegisterLoan) {
            result.encodedBody = bodyBytes;
            result.ok = true;
            return result;
        }

        return result;
    }

    function _fillIntentFields(
        ParsedTemplate memory template_,
        bytes memory orderData,
        ExtractionResult memory result
    ) internal view {
        if (template_.intentKind != IntentKind.CrossChainIntentFromOrderData) {
            return;
        }
        if (orderData.length == 0) {
            return;
        }

        try this.decodeCrossChainIntentPayload(orderData) returns (
            CrossChainOrderTypes.CrossChainIntent memory intent
        ) {
            result.encodedIntent = abi.encode(intent);
            if (template_.proofKind == ProofKind.SourceProofRequirement) {
                result.proofRequirement = intent.sourceProofRequirement;
            }
        } catch {}
    }

    /// @dev External helper so `_fillIntentFields` can use `try/catch` on ABI decode.
    function decodeCrossChainIntentPayload(bytes calldata orderData)
        external
        pure
        returns (CrossChainOrderTypes.CrossChainIntent memory intent)
    {
        return abi.decode(orderData, (CrossChainOrderTypes.CrossChainIntent));
    }

    function _parseRule(string memory rule) internal pure returns (ParsedTemplate memory parsed) {
        parsed.bodyOffset = 4;

        string[] memory parts = _split(rule, ";");
        for (uint256 i = 0; i < parts.length; i++) {
            (string memory key, string memory value) = _splitPair(parts[i], "=");
            parsed = _applyRuleKey(parsed, key, value);
        }

        if (parsed.selector == bytes4(0) || parsed.bodyKind == BodyKind.None) {
            revert UnknownRuleKey("selector/body");
        }
    }

    function _applyRuleKey(
        ParsedTemplate memory parsed,
        string memory key,
        string memory value
    ) internal pure returns (ParsedTemplate memory) {
        bytes32 keyHash = keccak256(bytes(key));

        if (keyHash == keccak256(bytes("selector"))) {
            parsed.selector = _parseSelector(value);
            return parsed;
        }
        if (keyHash == keccak256(bytes("bodyOffset"))) {
            parsed.bodyOffset = _parseUint(value);
            return parsed;
        }
        if (keyHash == keccak256(bytes("body"))) {
            bytes32 bodyHash = keccak256(bytes(value));
            if (bodyHash == keccak256(bytes("CrossChainOrder"))) {
                parsed.bodyKind = BodyKind.CrossChainOrder;
                return parsed;
            }
            if (bodyHash == keccak256(bytes("OpenForOrder"))) {
                parsed.bodyKind = BodyKind.OpenForOrder;
                return parsed;
            }
            if (bodyHash == keccak256(bytes("(address,uint256)"))) {
                parsed.bodyKind = BodyKind.AddressUint256;
                return parsed;
            }
            if (bodyHash == keccak256(bytes("(address,address,uint256)"))) {
                parsed.bodyKind = BodyKind.AddressAddressUint256;
                return parsed;
            }
            if (bodyHash == keccak256(bytes("RegisterLoan"))) {
                parsed.bodyKind = BodyKind.RegisterLoan;
                return parsed;
            }
            revert UnknownBodyType(value);
        }
        if (keyHash == keccak256(bytes("intent"))) {
            if (keccak256(bytes(value)) == keccak256(bytes("CrossChainIntent"))) {
                parsed.intentKind = IntentKind.CrossChainIntentFromOrderData;
                return parsed;
            }
            revert UnknownIntentType(value);
        }
        if (keyHash == keccak256(bytes("proof"))) {
            if (keccak256(bytes(value)) == keccak256(bytes("sourceProofRequirement"))) {
                parsed.proofKind = ProofKind.SourceProofRequirement;
                return parsed;
            }
            revert UnknownProofField(value);
        }

        revert UnknownRuleKey(key);
    }

    function _parseSelector(string memory hexValue) internal pure returns (bytes4 selector) {
        bytes memory raw = bytes(hexValue);
        require(raw.length == 10, "selector hex");
        require(raw[0] == "0" && raw[1] == "x", "selector 0x");
        selector = bytes4(
            (uint32(_hexNibble(raw[2])) << 28) |
                (uint32(_hexNibble(raw[3])) << 24) |
                (uint32(_hexNibble(raw[4])) << 20) |
                (uint32(_hexNibble(raw[5])) << 16) |
                (uint32(_hexNibble(raw[6])) << 12) |
                (uint32(_hexNibble(raw[7])) << 8) |
                (uint32(_hexNibble(raw[8])) << 4) |
                uint32(_hexNibble(raw[9]))
        );
    }

    function _parseUint(string memory value) internal pure returns (uint256 parsed) {
        bytes memory raw = bytes(value);
        for (uint256 i = 0; i < raw.length; i++) {
            uint8 c = uint8(raw[i]);
            require(c >= 48 && c <= 57, "uint dec");
            parsed = parsed * 10 + (c - 48);
        }
    }

    function _hexNibble(bytes1 char) internal pure returns (uint8 nibble) {
        uint8 c = uint8(char);
        if (c >= 48 && c <= 57) {
            return c - 48;
        }
        if (c >= 97 && c <= 102) {
            return c - 87;
        }
        if (c >= 65 && c <= 70) {
            return c - 55;
        }
        revert("hex");
    }

    function _split(string memory input, string memory delimiter)
        internal
        pure
        returns (string[] memory parts)
    {
        bytes memory inputBytes = bytes(input);
        bytes memory delimiterBytes = bytes(delimiter);
        require(delimiterBytes.length == 1, "delimiter");

        uint256 count = 1;
        for (uint256 i = 0; i < inputBytes.length; i++) {
            if (inputBytes[i] == delimiterBytes[0]) {
                count++;
            }
        }

        parts = new string[](count);
        uint256 partIndex;
        uint256 start;

        for (uint256 i = 0; i <= inputBytes.length; i++) {
            if (i == inputBytes.length || inputBytes[i] == delimiterBytes[0]) {
                bytes memory token = new bytes(i - start);
                for (uint256 j = 0; j < token.length; j++) {
                    token[j] = inputBytes[start + j];
                }
                parts[partIndex] = string(token);
                partIndex++;
                start = i + 1;
            }
        }
    }

    function _splitPair(string memory input, string memory delimiter)
        internal
        pure
        returns (string memory left, string memory right)
    {
        bytes memory inputBytes = bytes(input);
        bytes memory delimiterBytes = bytes(delimiter);
        require(delimiterBytes.length == 1, "delimiter");

        for (uint256 i = 0; i < inputBytes.length; i++) {
            if (inputBytes[i] == delimiterBytes[0]) {
                bytes memory leftBytes = new bytes(i);
                for (uint256 j = 0; j < i; j++) {
                    leftBytes[j] = inputBytes[j];
                }
                bytes memory rightBytes = new bytes(inputBytes.length - i - 1);
                for (uint256 j = 0; j < rightBytes.length; j++) {
                    rightBytes[j] = inputBytes[i + 1 + j];
                }
                return (string(leftBytes), string(rightBytes));
            }
        }
        revert UnknownRuleKey(input);
    }

    function _readSelector(bytes calldata data) private pure returns (bytes4 selector) {
        assembly {
            selector := calldataload(data.offset)
        }
        selector = bytes4(selector);
    }
}
