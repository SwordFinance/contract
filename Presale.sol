// SPDX-License-Identifier: MIT

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Presale is ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;
    // Maps user to the number of tokens owned
    mapping (address => uint256) public tokensOwned;
    // The number of unclaimed tokens the user has
    mapping (address => uint256) public tokensUnclaimed;

    // SWORD token
    IBEP20 SWORD;
    // Sale ended
    bool isSaleActive;
    // Starting timestamp normal
    uint256 startingTimeStamp;
    uint256 totalTokensSold = 0;
    uint256 tokensPerBUSD = 5;
    uint256 busdReceived = 0;
    // BUSD token
    IBEP20 BUSD;

    address payable owner;

    modifier onlyOwner(){
        require(msg.sender == owner, "You're not the owner");
        _;
    }

    event TokenBuy(address user, uint256 tokens);
    event TokenClaim(address user, uint256 tokens);

    constructor (address _SWORD, address _BUSD, uint256 _startingTimestamp) public {
        SWORD = IBEP20(_SWORD);
        BUSD = IBEP20(_BUSD);
        isSaleActive = true;
        owner = msg.sender;
        startingTimeStamp = _startingTimestamp;
    }

    function buy (uint256 _amount, address beneficiary) public nonReentrant {
        require(isSaleActive, "Presale has not started");

        address _buyer = beneficiary;
        uint256 tokens = _amount.mul(tokensPerBUSD);
        
        //Minimum purchase requirement
        require (_amount >= 5 ether, "Amount is lower than min value");
        //Maximum presale purchase per transaction
        require (_amount <= 3000 ether, "Amount is greater than max value");
        //Presale HardCap
        require (busdReceived +  _amount <= 200000 ether, "Presale hardcap reached");
        //Max presale purchase per wallet
        require (tokensOwned[_buyer] <= 3000 ether, "Max limit per wallet hit!");
        require(block.timestamp >= startingTimeStamp, "Presale has not started");

        BUSD.safeTransferFrom(beneficiary, address(this), _amount);

        tokensOwned[_buyer] = tokensOwned[_buyer].add(tokens);
        tokensUnclaimed[_buyer] = tokensUnclaimed[_buyer].add(tokens);
        totalTokensSold = totalTokensSold.add(tokens);
        busdReceived = busdReceived.add(_amount);
        emit TokenBuy(beneficiary, tokens);
    }

    function setSaleActive(bool _isSaleActive) external onlyOwner {
        isSaleActive = _isSaleActive;
    }

    function getTokensOwned () external view returns (uint256) {
        return tokensOwned[msg.sender];
    }

    function getTokensUnclaimed () external view returns (uint256) {
        return tokensUnclaimed[msg.sender];
    }

    function getSWORDTokensLeft () external view returns (uint256) {
        return SWORD.balanceOf(address(this));
    }

    function claimTokens (address claimer) external {
        require (isSaleActive == false, "Sale is still active");
        require (tokensOwned[msg.sender] > 0, "User should own some SWORD tokens");
        require (tokensUnclaimed[msg.sender] > 0, "User should have unclaimed SWORD tokens");
        require (SWORD.balanceOf(address(this)) >= tokensOwned[msg.sender], "There are not enough SWORD tokens to transfer. Contract is broke");

        tokensUnclaimed[msg.sender] = tokensUnclaimed[msg.sender].sub(tokensOwned[msg.sender]);

        SWORD.safeTransfer(msg.sender, tokensOwned[msg.sender]);
        emit TokenClaim(msg.sender, tokensOwned[msg.sender]);
    }

    function withdrawFunds () external onlyOwner {
        BUSD.safeTransfer(msg.sender, BUSD.balanceOf(address(this)));
    }

    function withdrawUnsoldSWORD() external onlyOwner {
        SWORD.safeTransfer(msg.sender, SWORD.balanceOf(address(this)));
    }
}