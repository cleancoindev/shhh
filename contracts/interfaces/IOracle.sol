// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

interface IOracle {
    function assetPrice() external view returns (uint);
}