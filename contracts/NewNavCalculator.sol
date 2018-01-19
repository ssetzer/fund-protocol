pragma solidity ^0.4.13;

import "./NewFund.sol";
import "./FundLogic.sol";
import "./FundStorage.sol";
import "./DataFeed.sol";
import "./math/SafeMath.sol";
import "./math/Math.sol";
import "./zeppelin/DestructibleModified.sol";

/**
 * @title NavCalulator
 * @author CoinAlpha, Inc. <contact@coinalpha.com>
 *
 * @dev A module for calculating net asset value and other fund variables
 * This is a supporting module to the Fund contract that handles the logic entailed
 * in calculating an updated navPerShare and other fund-related variables given
 * time elapsed and changes in the value of the portfolio, as provided by the data feed.
 */

contract INewNavCalculator {
  function calculate()
    returns (
      uint lastCalcDate,
      uint navPerShare,
      uint lossCarryforward,
      uint accumulatedMgmtFees,
      uint accumulatedAdminFees
    ) {}
}

contract NewNavCalculator is DestructibleModified {
  using SafeMath for uint;
  using Math for uint;

  address public fundAddress;
  address public fundLogicAddress;
  address public fundStorageAddress;

  // Modules
  IDataFeed public dataFeed;
  INewFund newFund;
  IFundLogic fundLogic;
  IFundStorage fundStorage;

  // This modifier is applied to all external methods in this contract since only
  // the primary Fund contract can use this module
  modifier onlyFund {
    require(msg.sender == fundAddress);
    _;
  }

  function NewNavCalculator(address _dataFeed, address _fundStorage, address _fundLogic)
  {
    dataFeed = IDataFeed(_dataFeed);
    fundStorage = IFundStorage(_fundStorage);
    fundStorageAddress = _fundStorage;
    fundLogic = IFundLogic(_fundLogic);
    fundLogicAddress = _fundLogic;
  }

  event LogNavCalculation(
    uint shareClass,
    uint indexed timestamp,
    uint elapsedTime,
    uint grossAssetValueLessFees,
    uint netAssetValue,
    uint shareClassSupply,
    uint adminFeeInPeriod,
    uint mgmtFeeInPeriod,
    uint performFeeInPeriod,
    uint performFeeOffsetInPeriod,
    uint lossPaybackInPeriod
  );


  // Calculate nav and allocate fees
  function calcShareClassNav(uint _shareClass)
    onlyFund
    constant
    returns (
      uint, // lastCalcDate
      uint, // navPerShare
      uint, // lossCarryforward
      uint, // accumulatedMgmtFees,
      uint  // accumulatedAdminFees
    )
  {
    // Memory array for temp variables
    uint[17] memory temp;
    /**
     *  [0] = adminFeeBps
     *  [1] = mgmtFeeBps
     *  [2] = performFeeBps
     *  [3] = shareSupply
     *  [4] = netAssetValue             temp[4]
     *  [5] = elapsedTime               temp[5]
     *  [6] = grossAssetValueLessFees   temp[6]
     *  [7] = mgmtFee                   temp[7]
     *  [8] = adminFee                  temp[8]
     *  [9] = performFee                temp[9]
     *  [10] = performFeeOffset         temp[10]
     *  [11] = lossPayback              temp[11]

     *  [12] = lastCalcDate             temp[12]
     *  [13] = navPerShare              temp[13]
     *  [14] = navPerShare              temp[14]
     *  [15] = accumulatedMgmtFees      temp[15]
     *  [16] = accumulatedAdminFees     temp[16]
     */

  // temp[2]2
    // Get Fund and shareClass parameters
    // uint adminFeeBps;
    // uint mgmtFeeBps;
    // uint performFeeBps; 
    // uint shareSupply;
    (temp[0],
     temp[1],
     temp[2],
     temp[3],
     temp[12],
     temp[13],
     temp[14],
     temp[15],
     temp[16]
    ) = fundStorage.getShareClass(_shareClass);

    // Set the initial value of the variables below from the last NAV calculation
    temp[4] = fundLogic.sharesToUsd(_shareClass, temp[3]);
    temp[5] = now - temp[12];
    temp[12] = now;

    // The new grossAssetValue equals the updated value, denominated in ether, of the exchange account,
    // plus any amounts that sit in the fund contract, excluding unprocessed subscriptions
    // and unwithdrawn investor payments.
    // Removes the accumulated management and administrative fees from grossAssetValue
    // Prorates total asset value by Share Class share amount / total shares
    temp[6] = dataFeed.value().add(fundLogic.ethToUsd(newFund.getBalance())).sub(temp[15]).sub(temp[16]).mul(temp[3]).div(fundStorage.totalShareSupply());

    // Calculates the base management fee accrued since the last NAV calculation
    temp[7] = getAnnualFee(_shareClass, temp[3], temp[5], temp[1]);
    temp[8] = getAnnualFee(_shareClass, temp[3], temp[5], temp[0]);

    // Calculate the gain/loss based on the new grossAssetValue and the old netAssetValue
    int gainLoss = int(temp[6]) - int(temp[4]) - int(temp[7]) - int(temp[8]);

    // uint performFee = 0;
    // uint performFeeOffset = 0;

    // if current period gain
    if (gainLoss >= 0) {
      temp[11] = Math.min256(uint(gainLoss), temp[14]);

      // Update the lossCarryforward and netAssetValue variables
      temp[14] = temp[14].sub(temp[11]);
      temp[9] = getPerformFee(temp[2], uint(gainLoss).sub(temp[11]));
      temp[4] = temp[4].add(uint(gainLoss)).sub(temp[9]);
    
    // if current period loss
    } else {
      temp[10] = Math.min256(getPerformFee(temp[2], uint(-1 * gainLoss)), temp[15]);
      // Update the lossCarryforward and netAssetValue variables
      temp[14] = temp[14].add(uint(-1 * gainLoss)).sub(getGainGivenPerformFee(temp[10], temp[2]));
      temp[4] = temp[4].sub(uint(-1 * gainLoss)).add(temp[10]);
    }

    // Update the remaining state variables and return them to the fund contract
    temp[16] = temp[16].add(temp[8]);
    temp[15] = temp[15].add(temp[9]).sub(temp[10]);
    temp[13] = toNavPerShare(temp[4], temp[3]);

    LogNavCalculation(_shareClass, temp[12], temp[5], temp[6], temp[4], temp[3], temp[8], temp[7], temp[9], temp[10], temp[11]);

    return (temp[12], temp[13], temp[14], temp[15], temp[16]);
  }

  // ********* ADMIN *********

  // Update the address of the Fund contract
  function setFund(address _address)
    onlyOwner
  {
    newFund = INewFund(_address);
    fundAddress = _address;
  }

  // Update the address of the data feed contract
  function setDataFeed(address _address)
    onlyOwner
  {
    dataFeed = IDataFeed(_address);
  }

  // ********* HELPERS *********

  // Returns the fee amount associated with an annual fee accumulated given time elapsed and the annual fee rate
  // Equivalent to: annual fee percentage * fund totalSupply * (seconds elapsed / seconds in a year)
  // Has the same denomination as the fund totalSupply
  function getAnnualFee(uint _shareClass, uint _shareSupply, uint _elapsedTime, uint _annualFeeBps) 
    internal 
    constant 
    returns (uint feePayment) 
  {
    return _annualFeeBps.mul(fundLogic.sharesToUsd(_shareClass, _shareSupply)).div(10000).mul(_elapsedTime).div(31536000);
  }

  // Returns the performance fee for a given gain in portfolio value
  function getPerformFee(uint _performFeeBps, uint _usdGain) 
    internal 
    constant 
    returns (uint performFee)  
  {
    return _performFeeBps.mul(_usdGain).div(10 ** fundStorage.decimals());
  }

  // Returns the gain in portfolio value for a given performance fee
  function getGainGivenPerformFee(uint _performFee, uint _performFeeBps)
    internal 
    constant 
    returns (uint usdGain)  
  {
    return _performFee.mul(10 ** fundStorage.decimals()).div(_performFeeBps);
  }

  // Converts shares to a corresponding amount of USD based on the current nav per share
  // function sharesToUsd(uint _shares) 
  //   internal 
  //   constant 
  //   returns (uint usd) 
  // {
  //   return _shares.mul(newFund.navPerShare()).div(10 ** fundStorage.decimals());
  // }

  // Converts total fund NAV to NAV per share
  function toNavPerShare(uint _balance, uint _shareClassSupply)
    internal 
    constant 
    returns (uint) 
  {
    return _balance.mul(10 ** fundStorage.decimals()).div(_shareClassSupply);
  }
}
