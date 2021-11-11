// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

import "./interfaces/IOracle.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IgOHM.sol";
import "./interfaces/IOwnable.sol";

import "./libraries/SafeERC20.sol";
import "./libraries/SafeMath.sol";

import "./types/ERC20.sol";
import "./types/Ownable.sol";

/**
 * OUSD is a CDP stablecoin backed by staked OHM deposits. It accepts both s and g OHM
 * as collateral. It charges a fixed interest rate plus an origination fee. 
 * Loan origination is constrained by a maximum loan-to-value and capped by a global
 * debt ceiling. Liquidations occur at a liquidation threshold, with the liquidator
 * compensated by an incentive. Liquidations occur in max tranches, as decided by the
 * close factor. Fees collected are sent to the Olympus treasury.
 */
contract OUSD is ERC20, Ownable {
    
    using SafeERC20 for IERC20;
    using SafeERC20 for IgOHM;
    using SafeMath for uint;

    IERC20 internal immutable sOHM; // collateral
    IgOHM internal immutable gOHM; // collateral

    struct UserInfo {
        uint collateral; // sOHM deposited (stored as g balance)
        uint borrowed; // OUSD borrowed
        uint lastBlock; // last interest taken
    }
    mapping(address => UserInfo) public userInfo;

    struct Global {
        uint LI; // liquidation incentive
        uint LT; // liquidation threshold
        uint LTV; // maximum loan to value
        uint CF; // close factor
        uint interest; // interest rate
        uint fee; // borrow fee
        uint ceiling; // max debt
        uint outstanding; // current debt
        uint accrued; // fees collected
    }
    Global public terms;
    
    IOracle public immutable oracle;
    address internal immutable treasury; // to send fees to

    constructor(
        address _sohm, 
        address _gohm,
        address _treasury,
        address _oracle
    ) ERC20( 'Olympus USD', 'OUSD' ) { 
        require(_sohm != address(0), "Zero address: sOHM");
        sOHM = IERC20(_sohm);
        require(_gohm != address(0), "Zero address: gOHM");
        gOHM = IgOHM(_gohm);
        require(_treasury != address(0), "Zero address: Treasury");
        treasury = _treasury;
        require(_oracle != address(0), "Zero address: Oracle");
        oracle = IOracle(_oracle);
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    // deposit collateral
    function deposit (
        uint amount,
        address depositor,
        bool staked // sOHM or gOHM
    ) public {
        if (staked) {
            sOHM.safeTransferFrom(msg.sender, address(this), amount);
            userInfo[depositor].collateral += gOHM.balanceTo(amount);
        } else {
            gOHM.safeTransferFrom(msg.sender, address(this), amount);
            userInfo[depositor].collateral += amount;
        }
    }

    // withdraw collateral
    function withdraw (uint amount, bool staked) public {
        require(amount <= canWithdraw(msg.sender), "Cannot withdraw amount");

        if (staked) {
            userInfo[msg.sender].collateral -= gOHM.balanceTo(amount);
            sOHM.safeTransfer(msg.sender, amount);
        } else {
            userInfo[msg.sender].collateral -= amount;
            gOHM.safeTransfer(msg.sender, amount);
        }
    }

    // borrow stablecoin
    function borrow (uint amount) public {
        _takeInterest(msg.sender);

        require(terms.ceiling >= terms.outstanding.add(amount), "Global debt limit");
        require(maxBorrow(userBalance(msg.sender)) >= amount.add(userInfo[msg.sender].borrowed), "Greater than max LTV");

        uint fee = amount.mul(terms.fee).div(1e4);

        terms.accrued += fee;
        terms.outstanding += amount.add(fee);
        userInfo[msg.sender].borrowed += amount.add(fee);

        _mint(msg.sender, amount);
    }

    // repay loan
    function repay (uint amount, address depositor) public {
        _takeInterest(depositor);

        userInfo[depositor].borrowed -= amount;
        _burn(msg.sender, amount);
    }

    // liquidate borrower
    function liquidate (address depositor, uint amount, bool staked) external {
        _takeInterest(depositor);

        uint max = debtCanLiquidate(depositor);
        require(amount <= max && max != 0, "Repayment too large");
        _burn(msg.sender, amount);

        uint liquidatable = userBalance(depositor).mul(terms.LT + terms.LI).div(1e4);
        uint liquidated = liquidatable.mul(amount).div(userInfo[depositor].borrowed);

        if (staked) {
            userInfo[depositor].collateral -= gOHM.balanceTo(liquidated);
            sOHM.safeTransfer(msg.sender, liquidated);
        } else {
            userInfo[depositor].collateral -= gOHM.balanceTo(liquidated);
            gOHM.safeTransfer(msg.sender, gOHM.balanceTo(liquidated));
        }
    }

    // send collected interest fees to treasury
    function collect() external {
        if (terms.accrued > 0) {
            _mint(treasury, terms.accrued);
            terms.accrued = 0;
        }
    }

    /* ========== HELPER FUNCTIONS ========== */

    // gas saving function
    function depositAndBorrow(
        uint amount,
        bool staked,
        uint toBorrow
    ) external {
        deposit(amount, msg.sender, staked);
        borrow(toBorrow);
    }

    // gas saving function
    function repayAndWithdraw(
        uint toRepay,
        uint amount,
        bool staked
    ) external {
        repay(toRepay, msg.sender);
        withdraw(amount, staked);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    // charge user interest accrued since last interaction
    function _takeInterest (address depositor) internal {
        uint blocks = block.number.sub(userInfo[depositor].lastBlock);
        uint interest = userInfo[depositor].borrowed.mul(terms.interest).div(1e12).mul(blocks);
        
        userInfo[depositor].borrowed += interest;
        terms.accrued += interest;
        terms.outstanding += interest;

        userInfo[depositor].lastBlock = block.number;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // maximum amount depositor can withdraw given outstanding loan
    function canWithdraw (address depositor) public view returns (uint) {
        uint balance = userBalance(depositor);
        uint locked = balance.mul(userInfo[depositor].borrowed).div(maxLoan(balance));
        return balance.sub(locked);
    }

    // amount of collateral can be liquidator for depositor
    function collateralCanLiquidate (address depositor) public view returns (uint) {
        uint balance = userBalance(depositor);
        if (maxLoan(balance) >= userInfo[depositor].borrowed) {
            return 0;
        }
        uint liquidatable = balance.mul(terms.LT + terms.LI).div(1e4);
        return liquidatable.mul(terms.CF).div(1e4);
    }

    // amount of debt can be repaid to liquidate depositor
    function debtCanLiquidate (address depositor) public view returns (uint) {
        uint borrowed = userInfo[depositor].borrowed;
        if (maxLoan(userBalance(depositor)) >= borrowed) {
            return 0;
        }
        return borrowed.mul(terms.CF).div(1e4);
    }

    // user balances converted to sOHM balance
    function userBalance (address depositor) public view returns (uint) {
        return gOHM.balanceFrom(userInfo[depositor].collateral);
    }

    // max a user with given balance can borrow
    function maxBorrow (uint balance) public view returns (uint) {
        return balance.mul(oracle.assetPrice()).mul(terms.LTV).div(1e3);
    }

    // max a user with given balance can have outstanding
    function maxLoan (uint balance) public view returns (uint) {
        return balance.mul(oracle.assetPrice()).mul(terms.LT).div(1e3);
    }

    /* ========== OWNABLE FUNCTIONS ========== */

    enum PARAM {LT, LI, LTV, CF, INTEREST, FEE, CEILING}

    // set term
    function set (PARAM param, uint input) external onlyOwner {
        if (param == PARAM.LT) { // Liquidation Threshold
            terms.LT = input; // 4 decimals
        } else if (param == PARAM.LI) { // Liquidation Incentive
            terms.LI = input; // 4 decimals
        } else if (param == PARAM.LTV) { // Max Loan-To-Value
            terms.LTV = input; // 4 decimals
        } else if (param == PARAM.CF) { // Close Factor
            terms.CF = input; // 4 decimals
        } else if (param == PARAM.INTEREST) { // Interest Per Block
            terms.interest = input; // 12 decimals
        } else if (param == PARAM.FEE) { // Open Fee
            terms.fee = input; // 4 decimals
        } else if (param == PARAM.CEILING) { // Debt Ceiling
            terms.ceiling = input; // 18 decimals
        }
    }
}