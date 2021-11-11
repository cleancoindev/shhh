// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.0;

import "./types/ERC20.sol";
import "./interfaces/IERC20.sol";

contract OUSD is ERC20 {

    modifier onlyVault() {
        require(msg.sender == vault, "Only Vault");
        _;
    }

    address public vault;

    constructor(address _vault) ERC20( 'Olympus USD', 'OUSD' ) { 
        require(_vault != address(0), "Zero address: Vault");
        vault = _vault;
    }

    function mint(address to, uint amount) external onlyVault {
        _mint(to, amount);
    }

    function burn(address from, uint amount) external onlyVault {
        _burn(from, amount);
    }
}