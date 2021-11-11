// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

interface IgOHM {
    function balanceFrom(uint amount) external view returns (uint);
    function balanceTo(uint amount) external view returns (uint);
}