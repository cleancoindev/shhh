// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.0;

contract MockOracle {
    uint public price;

    // price should be 8 decimals
    function assetPrice() external view returns (uint) {
        return price;
    }

    function setPrice(uint _price) external {
        price = _price;
    }
}