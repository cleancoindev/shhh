// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.0;

import "./interfaces/IOracle.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IgOHM.sol";
import "./interfaces/IOwnable.sol";
import "./interfaces/IOUSD.sol";

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
contract OUSDVault is Ownable {
    
    using SafeERC20 for IERC20;
    using SafeERC20 for IgOHM;

    IERC20 internal immutable sOHM; // collateral
    IgOHM internal immutable gOHM; // collateral
    IOUSD public OUSD; // debt token

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
    )  { 
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

        require(terms.ceiling >= terms.outstanding + amount, "Global debt limit");
        require(maxBorrow(userBalance(msg.sender)) >= amount + userInfo[msg.sender].borrowed, "Greater than max LTV");

        uint fee = amount * terms.fee / 1e4;

        terms.accrued += fee;
        terms.outstanding += (amount + fee);
        userInfo[msg.sender].borrowed += (amount + fee);

        OUSD.mint(msg.sender, amount);
    }

    // repay loan
    function repay (uint amount, address depositor) public {
        _takeInterest(depositor);

        userInfo[depositor].borrowed -= amount;
        OUSD.burn(msg.sender, amount);
    }

    // liquidate borrower
    function liquidate (address depositor, uint amount, bool staked) external {
        _takeInterest(depositor);

        uint max = debtCanLiquidate(depositor);
        require(amount <= max && max != 0, "Repayment too large");
        OUSD.burn(msg.sender, amount);

        uint liquidatable = userBalance(depositor) * (terms.LT + terms.LI) / 1e4;
        uint liquidated = liquidatable * amount / userInfo[depositor].borrowed;

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
            OUSD.mint(treasury, terms.accrued);
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
        uint blocks = block.number - userInfo[depositor].lastBlock;
        uint interest = userInfo[depositor].borrowed * terms.interest * blocks / 1e12;
        
        userInfo[depositor].borrowed += interest;
        terms.accrued += interest;
        terms.outstanding += interest;

        userInfo[depositor].lastBlock = block.number;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // maximum amount depositor can withdraw given outstanding loan
    function canWithdraw (address depositor) public view returns (uint) {
        uint balance = userBalance(depositor);
        uint locked = balance * userInfo[depositor].borrowed / maxLoan(balance);
        return balance - locked;
    }

    // amount of collateral can be liquidator for depositor
    function collateralCanLiquidate (address depositor) public view returns (uint) {
        uint balance = userBalance(depositor);
        if (maxLoan(balance) >= userInfo[depositor].borrowed) {
            return 0;
        }
        uint liquidatable = balance * (terms.LT + terms.LI) / 1e4;
        return liquidatable * terms.CF / 1e4;
    }

    // amount of debt can be repaid to liquidate depositor
    function debtCanLiquidate (address depositor) public view returns (uint) {
        uint borrowed = userInfo[depositor].borrowed;
        if (maxLoan(userBalance(depositor)) >= borrowed) {
            return 0;
        }
        return borrowed * terms.CF / 1e4;
    }

    // user balances converted to sOHM balance
    function userBalance (address depositor) public view returns (uint) {
        return gOHM.balanceFrom(userInfo[depositor].collateral);
    }

    // max a user with given balance can borrow
    function maxBorrow (uint balance) public view returns (uint) {
        return balance * oracle.assetPrice() * terms.LTV / 1e3;
    }

    // max a user with given balance can have outstanding
    function maxLoan (uint balance) public view returns (uint) {
        return balance * oracle.assetPrice() * terms.LT / 1e3;
    }

    /* ========== OWNABLE FUNCTIONS ========== */

    enum PARAM {LT, LI, LTV, CF, INTEREST, FEE, CEILING, OUSD}

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

    // set OUSD -- do first!
    function init(address _ousd) external onlyOwner {
        require(address(OUSD) == address(0), "Already set");
        require(_ousd != address(0), "Zero address: OUSD");
        OUSD = IOUSD(_ousd);
    }
}