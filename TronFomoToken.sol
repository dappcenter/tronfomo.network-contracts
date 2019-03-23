pragma solidity ^0.4.23;

import "./TRC20Detailed.sol";
import "./SafeMath.sol";

contract TronFomoToken is TRC20Detailed {

  using SafeMath for uint;

  uint public constant  PRICE_INCREASE_PCT = 111; // 1.11 ie. 11%
  uint public constant SUPPLY_INCREASE_PCT = 125; // 1.25 ie. 25%
  uint public constant MINIMAL_TRX_FOR_BUY = 1e6; // 1 TRX min
  uint public constant SUPPLY_1ST_LEVEL = 100 * 1e6;
  uint public constant PRICE_1ST_LEVEL  = 1e4; // 0.01 TRX is initial price

  uint public constant DEV_FEE      = 1; // if no referral then 3% dev fee
  uint public constant REFERRAL_FEE = 2;
  uint public constant REFERRAL_THRESHOLD = 500 * 1e6; // After >500 TRX buy unlock referral privilege

  uint public level = 1;
  uint public pricePerToken   = PRICE_1ST_LEVEL;
  uint public supplyLevelLeft = SUPPLY_1ST_LEVEL;   // current supply
  uint public supplyLevel     = SUPPLY_1ST_LEVEL;   // total supply for level

  uint public trxBalance = 0;
  uint public boughtTotal = 0;
  uint public soldTotal = 0;
  uint public referralTotal = 0;

  mapping (address => uint) public address2Divs;
  mapping (address => uint) public address2Bought;
  address private DA;

  mapping (uint => uint) public supplyLevels;
  uint public soldAtLevel = 0;
  uint public levelViaSupply = 1;
  uint public maxLevelViaSupply = 1;

  constructor() TRC20Detailed("TronFomoToken", "TFT", 6) public {
    DA = msg.sender;
    supplyLevels[1] = SUPPLY_1ST_LEVEL;
  }

  event NewLevel(uint level, uint price, uint supply);

  event TokenPurchase(address buyerAddress, uint msgValue, uint valueAmt, uint devFee, uint referralFee, uint price, address referralAddress, uint tokenAmt, bool newLevel);

  event ChangeTransfer(address changeAddress, uint msgValue, uint change, uint valueAmt, uint devFee, uint referralFee);

  event TokenSold(address msgSender, address referralAddress, uint tokenAmt, uint sellPrice, uint sellValue, uint devFee, uint referralFee, uint sellValueNoFees, uint totSupplyBeforeSell, uint trxBalanceBeforeSell);

  event Withdraw(address msgSender, uint amt);

  function withdraw() public {
    uint amt = address2Divs[msg.sender];
    address2Divs[msg.sender] = 0;
    msg.sender.transfer(amt);
    emit Withdraw(msg.sender, amt);
  }

  function reinvest() public returns(uint tokenAmt, bool newLevel, uint devFee, uint referralFee, uint valueAmt) {
    (tokenAmt, newLevel, devFee, referralFee, valueAmt) = reinvestWithReferral(address(0));
  }

  function reinvestWithReferral(address referralAddress) public returns(uint tokenAmt, bool newLevel, uint devFee, uint referralFee, uint valueAmt) {
    uint amt = address2Divs[msg.sender];
    address2Divs[msg.sender] = 0;
    (tokenAmt, newLevel, devFee, referralFee, valueAmt) = buyWithReferralInternal(referralAddress, amt);
  }

  function buy() public payable returns(uint tokenAmt, bool newLevel, uint devFee, uint referralFee, uint valueAmt) {
    (tokenAmt, newLevel, devFee, referralFee, valueAmt) = buyWithReferralInternal(address(0), msg.value);
  }

  function buyWithReferral(address referralAddress) public payable returns(uint tokenAmt, bool newLevel, uint devFee, uint referralFee, uint valueAmt) {
    (tokenAmt, newLevel, devFee, referralFee, valueAmt) = buyWithReferralInternal(referralAddress, msg.value);
  }

  function buyWithReferralInternal(address referralAddress, uint msgValue) internal returns(uint tokenAmt, bool newLevel, uint devFee, uint referralFee, uint valueAmt) {

    require(msgValue >= MINIMAL_TRX_FOR_BUY, "Not enough TRX sent.");
    bool noReferral = checkReferral(referralAddress);

    devFee = noReferral ? (msgValue.mul(REFERRAL_FEE.add(DEV_FEE))).div(100) : msgValue.div(100);
    referralFee = noReferral ? 0 : (msgValue.mul(REFERRAL_FEE)).div(100);
    valueAmt = msgValue.sub(devFee.add(referralFee));
    tokenAmt = (valueAmt.mul(1e6)).div(pricePerToken);

    if (tokenAmt >= supplyLevelLeft) {

      valueAmt = (supplyLevelLeft.mul(pricePerToken)).div(1e6);
      devFee = noReferral ? (valueAmt.mul(REFERRAL_FEE.add(DEV_FEE))).div(100) : valueAmt.div(100);
      referralFee = noReferral ? 0 : (valueAmt.mul(REFERRAL_FEE)).div(100);

      uint change = msgValue.sub(valueAmt.add(devFee.add(referralFee)));
      if (change > 0 && change < msgValue) {
        msg.sender.transfer(change);
        emit ChangeTransfer(msg.sender, msgValue, change, valueAmt, devFee, referralFee);
      }

      tokenAmt = supplyLevelLeft;
      pricePerToken   = (pricePerToken.mul(PRICE_INCREASE_PCT)).div(100);
      calculateNewSupplyLevel(levelViaSupply);

      level += 1;
      newLevel = true;
      emit NewLevel(level, pricePerToken, supplyLevel);
    } else {
      supplyLevelLeft = supplyLevelLeft.sub(tokenAmt);
    }

    emit TokenPurchase(msg.sender, msgValue, valueAmt, devFee, referralFee, pricePerToken, referralAddress, tokenAmt, newLevel);
    trxBalance = trxBalance.add(valueAmt);
    boughtTotal = boughtTotal.add(valueAmt);
    address2Bought[msg.sender] = address2Bought[msg.sender].add(valueAmt);
    addCommissions(referralAddress, devFee, referralFee, noReferral);
    _mint(msg.sender, tokenAmt);
  }

  function sell(uint tokenAmt) public returns(uint devFee, uint referralFee, uint sellPrice, uint sellValue, uint sellValueNoFees) {
    (devFee, referralFee, sellPrice, sellValue, sellValueNoFees) = sellWithReferral(address(0), tokenAmt);
  }

  function sellWithReferral(address referralAddress, uint tokenAmt) public returns(uint devFee, uint referralFee, uint sellPrice, uint sellValue, uint sellValueNoFees) {

    uint balance = balanceOf(msg.sender);
    require(balance >= tokenAmt, "Not enough tokens.");
    bool noReferral = checkReferral(referralAddress);

    uint totSupply = totalSupply();
    _burn(msg.sender, tokenAmt);
    soldAtLevel = soldAtLevel.add(tokenAmt);
    sellPrice = (trxBalance.mul(1e6)).div(totSupply);
    sellValue = (tokenAmt.mul(sellPrice)).div(1e6);

    devFee = noReferral ? (sellValue.mul(REFERRAL_FEE.add(DEV_FEE))).div(100) : sellValue.div(100);
    referralFee = noReferral ? 0 : (sellValue.mul(REFERRAL_FEE)).div(100);
    sellValueNoFees = sellValue.sub(devFee.add(referralFee));

    emit TokenSold(msg.sender, referralAddress, tokenAmt, sellPrice, sellValue, devFee, referralFee, sellValueNoFees, totSupply, trxBalance);
    trxBalance = trxBalance.sub(sellValue);
    msg.sender.transfer(sellValueNoFees);

    soldTotal = soldTotal.add(sellValueNoFees);
    addCommissions(referralAddress, devFee, referralFee, noReferral);
  }

  function addCommissions(address referralAddress, uint devFee, uint referralFee, bool noReferral) internal {
    if (!noReferral) {
      address2Divs[referralAddress] = address2Divs[referralAddress].add(referralFee);
      referralTotal = referralTotal.add(referralFee);
    }
    address2Divs[DA] = address2Divs[DA].add(devFee);
  }

  function calculateNewSupplyLevel(uint lvl) internal {
    if (soldAtLevel >= supplyLevel) {
      soldAtLevel = soldAtLevel.sub(supplyLevel);
      levelViaSupply = lvl.sub(1);
      supplyLevel = supplyLevels[levelViaSupply];
      calculateNewSupplyLevel(levelViaSupply);
    } else {
      supplyLevel = (supplyLevel.mul(SUPPLY_INCREASE_PCT)).div(100);
      supplyLevelLeft = supplyLevel;

      soldAtLevel = 0;
      if (supplyLevel > supplyLevels[levelViaSupply])
        supplyLevels[++levelViaSupply] = supplyLevel;
    }
  }

  function checkReferral(address referralAddress) internal view returns(bool noReferral) {
    require(msg.sender != referralAddress, "Cannot refer to sender address.");
    noReferral = referralAddress == address(0);
    if (!noReferral && address2Bought[referralAddress] < REFERRAL_THRESHOLD)
      revert("Referral threshold isn't met.");
  }
}
