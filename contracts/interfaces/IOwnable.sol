// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

interface IOwnable {
  function owner() external view returns (address);

  function renounceManagement() external;
  
  function pushManagement( address newOwner_ ) external;
  
  function pullManagement() external;
}