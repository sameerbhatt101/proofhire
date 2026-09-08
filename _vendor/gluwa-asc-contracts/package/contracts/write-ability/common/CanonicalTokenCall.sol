// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Mintable} from "../abstract/IERC20MintBurn.sol";

library CanonicalTokenCall {
    function encode(
        bool mint,
        address receiver,
        uint256 amount
    ) internal pure returns (bytes memory) {
        return
            mint
                ? abi.encodeCall(IERC20Mintable.mint, (receiver, amount))
                : abi.encodeCall(IERC20.transfer, (receiver, amount));
    }
}
